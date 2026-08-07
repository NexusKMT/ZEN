#include "ZenMatineeBridgeCommandlet.h"

#include "AssetToolsModule.h"
#include "Dom/JsonObject.h"
#include "Editor.h"
#include "Engine/World.h"
#include "EngineUtils.h"
#include "FileHelpers.h"
#include "HAL/FileManager.h"
#include "LevelSequence.h"
#include "LevelSequenceActor.h"
#include "Matinee/InterpData.h"
#include "Matinee/InterpGroup.h"
#include "Matinee/InterpTrack.h"
#include "Matinee/MatineeActor.h"
#include "Misc/FileHelper.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "MovieScene.h"
#include "MovieSceneTrack.h"
#include "Policies/PrettyJsonPrintPolicy.h"
#include "Serialization/JsonSerializer.h"

#include "MatineeToLevelSequenceLog.h"

DEFINE_LOG_CATEGORY_STATIC(LogZenMatineeBridge, Log, All);
DEFINE_LOG_CATEGORY(LogMatineeToLevelSequence);

// UE 4.27 exposes track extension registration but not its conversion entry
// point. Compile the pinned engine implementation into this adapter and swap
// its interactive asset picker for the equivalent unattended CreateAsset API.
#define private public
#include "MatineeToLevelSequenceConverter.h"
#undef private

#include "MatineeConverter.cpp"

#define CreateAssetWithDialog CreateAsset
#include "MatineeToLevelSequenceConverter.cpp"
#undef CreateAssetWithDialog

namespace
{
void CountSourceTrack(UInterpTrack* Track, TMap<FString, int32>& Counts)
{
    if (Track == nullptr)
    {
        return;
    }

    Counts.FindOrAdd(Track->GetClass()->GetName())++;
    for (UInterpTrack* SubTrack : Track->SubTracks)
    {
        CountSourceTrack(SubTrack, Counts);
    }
}

void CountSourceTracks(AMatineeActor* Actor, TMap<FString, int32>& Counts)
{
    if (Actor == nullptr || Actor->MatineeData == nullptr)
    {
        return;
    }

    for (UInterpGroup* Group : Actor->MatineeData->InterpGroups)
    {
        if (Group == nullptr)
        {
            continue;
        }

        for (UInterpTrack* Track : Group->InterpTracks)
        {
            CountSourceTrack(Track, Counts);
        }
    }
}

void CountSequenceTrack(UMovieSceneTrack* Track, TMap<FString, int32>& Counts)
{
    if (Track != nullptr)
    {
        Counts.FindOrAdd(Track->GetClass()->GetName())++;
    }
}

void CountSequenceTracks(UMovieScene* MovieScene, TMap<FString, int32>& Counts)
{
    if (MovieScene == nullptr)
    {
        return;
    }

    for (UMovieSceneTrack* Track : MovieScene->GetMasterTracks())
    {
        CountSequenceTrack(Track, Counts);
    }

    for (const FMovieSceneBinding& Binding : MovieScene->GetBindings())
    {
        for (UMovieSceneTrack* Track : Binding.GetTracks())
        {
            CountSequenceTrack(Track, Counts);
        }
    }
}

bool RequireTrackClasses(
    const TMap<FString, int32>& Counts,
    const TArray<FString>& RequiredClasses,
    const TCHAR* Stage
)
{
    bool bComplete = true;
    for (const FString& RequiredClass : RequiredClasses)
    {
        const int32 Count = Counts.FindRef(RequiredClass);
        UE_LOG(
            LogZenMatineeBridge,
            Display,
            TEXT("ZEN_BRIDGE_TRACK stage=%s class=%s count=%d"),
            Stage,
            *RequiredClass,
            Count
        );
        bComplete &= Count > 0;
    }
    return bComplete;
}

TSharedRef<FJsonObject> CountsToJson(const TMap<FString, int32>& Counts)
{
    TSharedRef<FJsonObject> Json = MakeShared<FJsonObject>();
    for (const TPair<FString, int32>& Pair : Counts)
    {
        Json->SetNumberField(Pair.Key, Pair.Value);
    }
    return Json;
}
}

UZenMatineeBridgeCommandlet::UZenMatineeBridgeCommandlet()
{
    IsClient = false;
    IsEditor = true;
    IsServer = false;
    LogToConsole = true;
    ShowErrorCount = true;
}

int32 UZenMatineeBridgeCommandlet::Main(const FString& Params)
{
    FString ExpectedActor = TEXT("Zen_Movie");
    int32 ExpectedMatinees = 1;
    FParse::Value(*Params, TEXT("ExpectedActor="), ExpectedActor);
    FParse::Value(*Params, TEXT("ExpectedMatinees="), ExpectedMatinees);

    if (GEditor == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR editor_not_initialized"));
        return 10;
    }

    TArray<FString> MapFiles;
    IFileManager::Get().FindFilesRecursive(
        MapFiles,
        *FPaths::ConvertRelativePathToFull(FPaths::ProjectContentDir()),
        TEXT("*.umap"),
        true,
        false
    );
    MapFiles.Sort();

    if (MapFiles.Num() == 0)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR no_maps_found"));
        return 11;
    }

    const TArray<FString> RequiredSourceTracks = {
        TEXT("InterpTrackDirector"),
        TEXT("InterpTrackFade"),
        TEXT("InterpTrackSound"),
        TEXT("InterpTrackEvent"),
        TEXT("InterpTrackToggle")
    };
    const TArray<FString> RequiredSequenceTracks = {
        TEXT("MovieSceneCameraCutTrack"),
        TEXT("MovieSceneFadeTrack"),
        TEXT("MovieSceneAudioTrack"),
        TEXT("MovieSceneEventTrack"),
        TEXT("MovieSceneParticleTrack")
    };

    int32 ConvertedMaps = 0;
    int32 MatineesFound = 0;
    int32 MatineesConverted = 0;
    int32 MatineesRetained = 0;
    int32 ConversionWarnings = 0;
    bool bFoundExpectedActor = false;
    TMap<FString, int32> SourceTrackCounts;
    TMap<FString, int32> SequenceTrackCounts;
    TArray<TSharedPtr<FJsonValue>> GeneratedSequences;

    // Inventory every map before creating or saving any asset. This makes an
    // unexpected actor count or track layout a hard preflight failure.
    for (const FString& MapFile : MapFiles)
    {
        UE_LOG(LogZenMatineeBridge, Display, TEXT("ZEN_BRIDGE_PREFLIGHT_MAP path=%s"), *MapFile);
        if (!FEditorFileUtils::LoadMap(MapFile, false, false))
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR preflight_map_load_failed path=%s"), *MapFile);
            return 12;
        }

        UWorld* World = GEditor->GetEditorWorldContext().World();
        if (World == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR preflight_world_missing path=%s"), *MapFile);
            return 13;
        }

        for (TActorIterator<AMatineeActor> ActorIt(World); ActorIt; ++ActorIt)
        {
            AMatineeActor* Actor = *ActorIt;
            const FString ActorLabel = Actor->GetActorLabel();
            MatineesFound++;
            bFoundExpectedActor |= ActorLabel == ExpectedActor;
            CountSourceTracks(Actor, SourceTrackCounts);

            UE_LOG(
                LogZenMatineeBridge,
                Display,
                TEXT("ZEN_BRIDGE_MATINEE_FOUND map=%s actor=%s"),
                *World->GetOutermost()->GetName(),
                *ActorLabel
            );
        }
    }

    if (MatineesFound != ExpectedMatinees || !bFoundExpectedActor)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR preflight_count_mismatch expected=%d found=%d expected_actor=%d"),
            ExpectedMatinees,
            MatineesFound,
            bFoundExpectedActor ? 1 : 0
        );
        return 14;
    }

    if (!RequireTrackClasses(SourceTrackCounts, RequiredSourceTracks, TEXT("source")))
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR required_source_track_missing"));
        return 15;
    }

    FMatineeConverter TrackConverter;
    FMatineeToLevelSequenceConverter Converter(&TrackConverter);

    for (const FString& MapFile : MapFiles)
    {
        UE_LOG(LogZenMatineeBridge, Display, TEXT("ZEN_BRIDGE_MAP_SCAN path=%s"), *MapFile);
        if (!FEditorFileUtils::LoadMap(MapFile, false, false))
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR map_load_failed path=%s"), *MapFile);
            return 16;
        }

        UWorld* World = GEditor->GetEditorWorldContext().World();
        if (World == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR world_missing path=%s"), *MapFile);
            return 17;
        }

        TArray<AMatineeActor*> Actors;
        for (TActorIterator<AMatineeActor> ActorIt(World); ActorIt; ++ActorIt)
        {
            Actors.Add(*ActorIt);
        }

        int32 ConvertedInMap = 0;
        for (AMatineeActor* Actor : Actors)
        {
            const FString ActorLabel = Actor->GetActorLabel();
            int32 ActorWarnings = 0;
            TWeakObjectPtr<ALevelSequenceActor> NewActor =
                Converter.ConvertSingleMatineeToLevelSequence(Actor, ActorWarnings);
            if (!NewActor.IsValid())
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR conversion_failed actor=%s"), *ActorLabel);
                return 18;
            }

            // Epic warns that unsupported tracks are dropped. Reject any
            // warning before a dirty package is saved so no lossy conversion
            // can become accepted bridge output.
            if (ActorWarnings != 0)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR conversion_warning actor=%s warnings=%d"),
                    *ActorLabel,
                    ActorWarnings
                );
                return 19;
            }

            ULevelSequence* Sequence = Cast<ULevelSequence>(NewActor->LevelSequence.TryLoad());
            if (Sequence == nullptr || Sequence->GetMovieScene() == nullptr)
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequence_missing actor=%s"), *ActorLabel);
                return 20;
            }

            CountSequenceTracks(Sequence->GetMovieScene(), SequenceTrackCounts);
            if (ActorLabel == ExpectedActor &&
                !RequireTrackClasses(SequenceTrackCounts, RequiredSequenceTracks, TEXT("sequence")))
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR required_sequence_track_missing"));
                return 21;
            }

            const FString SequencePath = Sequence->GetPathName();
            GeneratedSequences.Add(MakeShared<FJsonValueString>(SequencePath));
            ConversionWarnings += ActorWarnings;
            MatineesConverted++;
            ConvertedInMap++;

            if (!IsValid(Actor) || Actor->GetWorld() != World)
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_actor_not_retained actor=%s"), *ActorLabel);
                return 22;
            }
            MatineesRetained++;

            UE_LOG(
                LogZenMatineeBridge,
                Display,
                TEXT("ZEN_BRIDGE_CONVERTED actor=%s sequence=%s warnings=%d"),
                *ActorLabel,
                *SequencePath,
                ActorWarnings
            );
        }

        if (ConvertedInMap > 0)
        {
            World->MarkPackageDirty();
            if (!FEditorFileUtils::SaveDirtyPackages(false, true, true, true, false, false))
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR save_failed path=%s"), *MapFile);
                return 23;
            }
            ConvertedMaps++;
        }
    }

    if (MatineesFound != ExpectedMatinees ||
        MatineesConverted != ExpectedMatinees ||
        MatineesRetained != ExpectedMatinees ||
        !bFoundExpectedActor)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR count_mismatch expected=%d found=%d converted=%d retained=%d expected_actor=%d"),
            ExpectedMatinees,
            MatineesFound,
            MatineesConverted,
            MatineesRetained,
            bFoundExpectedActor ? 1 : 0
        );
        return 24;
    }

    TSharedRef<FJsonObject> Report = MakeShared<FJsonObject>();
    Report->SetStringField(TEXT("engineVersion"), TEXT("4.27.2"));
    Report->SetNumberField(TEXT("mapsScanned"), MapFiles.Num());
    Report->SetNumberField(TEXT("mapsConverted"), ConvertedMaps);
    Report->SetNumberField(TEXT("matineesFound"), MatineesFound);
    Report->SetNumberField(TEXT("matineesConverted"), MatineesConverted);
    Report->SetNumberField(TEXT("sourceActorsRetained"), MatineesRetained);
    Report->SetNumberField(TEXT("sourceActorsRemoved"), 0);
    Report->SetNumberField(TEXT("conversionWarnings"), ConversionWarnings);
    Report->SetStringField(TEXT("expectedActor"), ExpectedActor);
    Report->SetArrayField(TEXT("generatedSequences"), GeneratedSequences);
    Report->SetObjectField(TEXT("sourceTrackClasses"), CountsToJson(SourceTrackCounts));
    Report->SetObjectField(TEXT("sequenceTrackClasses"), CountsToJson(SequenceTrackCounts));

    FString ReportText;
    TSharedRef<TJsonWriter<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>> Writer =
        TJsonWriterFactory<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>::Create(&ReportText);
    FJsonSerializer::Serialize(Report, Writer);

    const FString ReportPath = FPaths::Combine(
        FPaths::ProjectSavedDir(),
        TEXT("ZenMigration"),
        TEXT("ue427-bridge-report.json")
    );
    IFileManager::Get().MakeDirectory(*FPaths::GetPath(ReportPath), true);
    if (!FFileHelper::SaveStringToFile(
        ReportText,
        *ReportPath,
        FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM
    ))
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR report_write_failed path=%s"), *ReportPath);
        return 25;
    }

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_SUCCESS maps=%d converted=%d retained=%d warnings=%d report=%s"),
        MapFiles.Num(),
        MatineesConverted,
        MatineesRetained,
        ConversionWarnings,
        *ReportPath
    );
    return 0;
}
