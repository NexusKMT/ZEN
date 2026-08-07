#include "ZenMatineeBridgeCommandlet.h"

#include "AssetToolsModule.h"
#include "Dom/JsonObject.h"
#include "Editor.h"
#include "Engine/Level.h"
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
#include "Misc/OutputDevice.h"
#include "Misc/OutputDeviceRedirector.h"
#include "Misc/PackageName.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "MovieScene.h"
#include "MovieSceneTrack.h"
#include "Policies/PrettyJsonPrintPolicy.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/ReferencerFinder.h"

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
class FMatineeWarningCapture final : public FOutputDevice
{
public:
    FMatineeWarningCapture()
    {
        GLog->AddOutputDevice(this);
    }

    virtual ~FMatineeWarningCapture() override
    {
        GLog->RemoveOutputDevice(this);
    }

    virtual void Serialize(
        const TCHAR* Message,
        ELogVerbosity::Type Verbosity,
        const FName& Category
    ) override
    {
        static const FName ConverterCategory(TEXT("LogMatineeToLevelSequence"));
        if (Category == ConverterCategory && Verbosity == ELogVerbosity::Warning)
        {
            Warnings.Add(Message);
        }
    }

    const TArray<FString>& GetWarnings() const
    {
        return Warnings;
    }

private:
    TArray<FString> Warnings;
};

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

TSharedRef<FJsonObject> CaptureReferenceContext(
    AMatineeActor* Actor,
    const FString& LoadedMap
)
{
    struct FReferencerRecord
    {
        FString ClassName;
        FString ObjectPath;
        FString PackageName;
        bool bInsideSourceActor = false;
        bool bOwningLevel = false;
        bool bSamePackage = false;
    };

    TArray<UObject*> Referencees;
    Referencees.Add(Actor);
    const TArray<UObject*> Referencers = FReferencerFinder::GetAllReferencers(
        Referencees,
        nullptr,
        EReferencerFinderFlags::SkipInnerReferences
    );

    TArray<FReferencerRecord> Records;
    for (UObject* Referencer : Referencers)
    {
        if (Referencer == nullptr)
        {
            continue;
        }

        FReferencerRecord& Record = Records.AddDefaulted_GetRef();
        Record.ClassName = Referencer->GetClass()->GetName();
        Record.ObjectPath = Referencer->GetPathName();
        Record.PackageName = Referencer->GetOutermost()->GetName();
        Record.bInsideSourceActor = Referencer->IsIn(Actor);
        Record.bOwningLevel = Referencer == Actor->GetLevel();
        Record.bSamePackage = Referencer->GetOutermost() == Actor->GetOutermost();
    }
    Records.Sort([](const FReferencerRecord& Left, const FReferencerRecord& Right)
    {
        if (Left.ObjectPath == Right.ObjectPath)
        {
            return Left.ClassName < Right.ClassName;
        }
        return Left.ObjectPath < Right.ObjectPath;
    });

    TArray<TSharedPtr<FJsonValue>> ReferencerValues;
    for (const FReferencerRecord& Record : Records)
    {
        TSharedPtr<FJsonObject> ReferencerJson = MakeShared<FJsonObject>();
        ReferencerJson->SetStringField(TEXT("class"), Record.ClassName);
        ReferencerJson->SetStringField(TEXT("objectPath"), Record.ObjectPath);
        ReferencerJson->SetStringField(TEXT("package"), Record.PackageName);
        ReferencerJson->SetBoolField(TEXT("insideSourceActor"), Record.bInsideSourceActor);
        ReferencerJson->SetBoolField(TEXT("owningLevel"), Record.bOwningLevel);
        ReferencerJson->SetBoolField(TEXT("samePackage"), Record.bSamePackage);
        ReferencerValues.Add(MakeShared<FJsonValueObject>(ReferencerJson));

        UE_LOG(
            LogZenMatineeBridge,
            Display,
            TEXT("ZEN_BRIDGE_REFERENCER loaded_map=%s actor=%s class=%s path=%s same_package=%d owning_level=%d"),
            *LoadedMap,
            *Actor->GetActorLabel(),
            *Record.ClassName,
            *Record.ObjectPath,
            Record.bSamePackage ? 1 : 0,
            Record.bOwningLevel ? 1 : 0
        );
    }

    TSharedRef<FJsonObject> Context = MakeShared<FJsonObject>();
    Context->SetStringField(TEXT("loadedMap"), LoadedMap);
    Context->SetNumberField(TEXT("referencerCount"), ReferencerValues.Num());
    Context->SetArrayField(TEXT("referencers"), ReferencerValues);

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_REFERENCE_CONTEXT loaded_map=%s source_map=%s actor=%s referencers=%d"),
        *LoadedMap,
        *Actor->GetOutermost()->GetName(),
        *Actor->GetActorLabel(),
        ReferencerValues.Num()
    );
    return Context;
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
    FString TargetMap = TEXT("/Game/Maps/Zen_Movie");
    FString ExpectedActor = TEXT("MatineeActor_Movie");
    int32 ExpectedMatinees = 1;
    FParse::Value(*Params, TEXT("TargetMap="), TargetMap);
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

    FString TargetMapFile;
    for (const FString& MapFile : MapFiles)
    {
        FString MapPackage;
        if (FPackageName::TryConvertFilenameToLongPackageName(MapFile, MapPackage) &&
            MapPackage == TargetMap)
        {
            TargetMapFile = MapFile;
            break;
        }
    }

    if (TargetMapFile.IsEmpty())
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR target_map_not_found map=%s"),
            *TargetMap
        );
        return 12;
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
    int32 UniqueMatineesDiscovered = 0;
    int32 MatineesConverted = 0;
    int32 MatineesRetained = 0;
    int32 ConversionWarnings = 0;
    int32 KnownConversionWarnings = 0;
    int32 UnexpectedConversionWarnings = 0;
    bool bFoundExpectedActor = false;
    TMap<FString, int32> SourceTrackCounts;
    TMap<FString, int32> SequenceTrackCounts;
    TSet<FString> InventoriedActors;
    TMap<FString, TSharedPtr<FJsonObject>> InventoryEntriesByActor;
    TMap<FString, TArray<TSharedPtr<FJsonValue>>> ReferenceContextsByActor;
    TArray<TSharedPtr<FJsonValue>> MatineeInventory;
    TArray<TSharedPtr<FJsonValue>> ConverterWarningMessages;
    TArray<TSharedPtr<FJsonValue>> GeneratedSequences;

    // Inventory every physical actor before creating or saving any asset.
    // Persistent maps can load the same streaming-level actor, so package and
    // object identity are used to avoid counting it twice.
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
            const FString ActorMap = Actor->GetLevel() != nullptr
                ? Actor->GetLevel()->GetOutermost()->GetName()
                : FString();
            const FString ActorKey = ActorMap + TEXT(":") + Actor->GetName();
            const FString LoadedMap = World->GetOutermost()->GetName();
            const bool bFirstEncounter = !InventoriedActors.Contains(ActorKey);

            ReferenceContextsByActor.FindOrAdd(ActorKey).Add(
                MakeShared<FJsonValueObject>(CaptureReferenceContext(Actor, LoadedMap))
            );

            if (!bFirstEncounter)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Display,
                    TEXT("ZEN_BRIDGE_MATINEE_DUPLICATE loaded_map=%s source_map=%s actor=%s"),
                    *LoadedMap,
                    *ActorMap,
                    *ActorLabel
                );
                continue;
            }

            InventoriedActors.Add(ActorKey);
            UniqueMatineesDiscovered++;

            TSharedPtr<FJsonObject> InventoryEntry = MakeShared<FJsonObject>();
            InventoryEntry->SetStringField(TEXT("map"), ActorMap);
            InventoryEntry->SetStringField(TEXT("actor"), ActorLabel);
            InventoryEntry->SetStringField(TEXT("objectName"), Actor->GetName());
            InventoryEntry->SetBoolField(TEXT("playOnLevelLoad"), Actor->bPlayOnLevelLoad != 0);
            InventoryEntry->SetBoolField(TEXT("looping"), Actor->bLooping != 0);
            InventoryEntry->SetBoolField(TEXT("rewindOnPlay"), Actor->bRewindOnPlay != 0);
            InventoryEntry->SetNumberField(TEXT("playRate"), Actor->PlayRate);
            InventoryEntry->SetBoolField(TEXT("forceStartPositionEnabled"), Actor->bForceStartPos != 0);
            InventoryEntry->SetNumberField(TEXT("forceStartPosition"), Actor->ForceStartPosition);
            InventoryEntry->SetBoolField(TEXT("noResetOnRewind"), Actor->bNoResetOnRewind != 0);
            InventoryEntry->SetBoolField(TEXT("rewindIfAlreadyPlaying"), Actor->bRewindIfAlreadyPlaying != 0);
            InventoryEntry->SetBoolField(TEXT("disableRadioFilter"), Actor->bDisableRadioFilter != 0);
            InventoryEntry->SetBoolField(TEXT("clientSideOnly"), Actor->bClientSideOnly != 0);
            InventoryEntry->SetBoolField(TEXT("skipUpdateIfNotVisible"), Actor->bSkipUpdateIfNotVisible != 0);
            InventoryEntry->SetBoolField(TEXT("skippable"), Actor->bIsSkippable != 0);
            InventoryEntry->SetNumberField(TEXT("preferredSplitScreenNumber"), Actor->PreferredSplitScreenNum);
            InventoryEntry->SetBoolField(TEXT("disableMovementInput"), Actor->bDisableMovementInput != 0);
            InventoryEntry->SetBoolField(TEXT("disableLookAtInput"), Actor->bDisableLookAtInput != 0);
            InventoryEntry->SetBoolField(TEXT("hidePlayer"), Actor->bHidePlayer != 0);
            InventoryEntry->SetBoolField(TEXT("hideHud"), Actor->bHideHud != 0);
            InventoryEntry->SetStringField(TEXT("controllerName"), Actor->MatineeControllerName.ToString());

            TMap<FString, int32> ActorSourceTrackCounts;
            CountSourceTracks(Actor, ActorSourceTrackCounts);
            InventoryEntry->SetObjectField(
                TEXT("sourceTrackClasses"),
                CountsToJson(ActorSourceTrackCounts)
            );
            for (const TPair<FString, int32>& Pair : ActorSourceTrackCounts)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Display,
                    TEXT("ZEN_BRIDGE_INVENTORY_TRACK map=%s actor=%s class=%s count=%d"),
                    *ActorMap,
                    *ActorLabel,
                    *Pair.Key,
                    Pair.Value
                );
            }
            MatineeInventory.Add(MakeShared<FJsonValueObject>(InventoryEntry));
            InventoryEntriesByActor.Add(ActorKey, InventoryEntry);

            const bool bIsTargetMap = ActorMap == TargetMap;
            const bool bIsExpectedActor = bIsTargetMap && ActorLabel == ExpectedActor;
            if (bIsTargetMap)
            {
                MatineesFound++;
            }
            if (bIsExpectedActor)
            {
                bFoundExpectedActor = true;
                CountSourceTracks(Actor, SourceTrackCounts);
            }

            UE_LOG(
                LogZenMatineeBridge,
                Display,
                TEXT("ZEN_BRIDGE_MATINEE_FOUND loaded_map=%s source_map=%s actor=%s target=%d"),
                *World->GetOutermost()->GetName(),
                *ActorMap,
                *ActorLabel,
                bIsExpectedActor ? 1 : 0
            );
        }
    }

    for (const TPair<FString, TSharedPtr<FJsonObject>>& Pair : InventoryEntriesByActor)
    {
        Pair.Value->SetArrayField(
            TEXT("referenceContexts"),
            ReferenceContextsByActor.FindChecked(Pair.Key)
        );
    }

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_INVENTORY unique=%d target_map=%s target_found=%d expected_actor=%d"),
        UniqueMatineesDiscovered,
        *TargetMap,
        MatineesFound,
        bFoundExpectedActor ? 1 : 0
    );

    if (MatineesFound != ExpectedMatinees || !bFoundExpectedActor)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR preflight_target_mismatch map=%s expected=%d found=%d actor=%s actor_found=%d"),
            *TargetMap,
            ExpectedMatinees,
            MatineesFound,
            *ExpectedActor,
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

    UE_LOG(LogZenMatineeBridge, Display, TEXT("ZEN_BRIDGE_MAP_CONVERT path=%s"), *TargetMapFile);
    if (!FEditorFileUtils::LoadMap(TargetMapFile, false, false))
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR map_load_failed path=%s"), *TargetMapFile);
        return 16;
    }

    UWorld* World = GEditor->GetEditorWorldContext().World();
    if (World == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR world_missing path=%s"), *TargetMapFile);
        return 17;
    }

    TArray<AMatineeActor*> Actors;
    for (TActorIterator<AMatineeActor> ActorIt(World); ActorIt; ++ActorIt)
    {
        AMatineeActor* Actor = *ActorIt;
        const FString ActorMap = Actor->GetLevel() != nullptr
            ? Actor->GetLevel()->GetOutermost()->GetName()
            : FString();
        if (ActorMap == TargetMap && Actor->GetActorLabel() == ExpectedActor)
        {
            Actors.Add(Actor);
        }
    }

    if (Actors.Num() != ExpectedMatinees)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR conversion_target_mismatch expected=%d found=%d"),
            ExpectedMatinees,
            Actors.Num()
        );
        return 18;
    }

    for (AMatineeActor* Actor : Actors)
    {
        const FString ActorLabel = Actor->GetActorLabel();
        int32 ActorWarnings = 0;
        TWeakObjectPtr<ALevelSequenceActor> NewActor;
        TArray<FString> ActorWarningMessages;
        {
            FMatineeWarningCapture WarningCapture;
            NewActor = Converter.ConvertSingleMatineeToLevelSequence(Actor, ActorWarnings);
            ActorWarningMessages = WarningCapture.GetWarnings();
        }
        if (!NewActor.IsValid())
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR conversion_failed actor=%s"), *ActorLabel);
            return 19;
        }

        ULevelSequence* Sequence = Cast<ULevelSequence>(NewActor->LevelSequence.TryLoad());
        if (Sequence == nullptr || Sequence->GetMovieScene() == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequence_missing actor=%s"), *ActorLabel);
            return 21;
        }

        CountSequenceTracks(Sequence->GetMovieScene(), SequenceTrackCounts);
        if (!RequireTrackClasses(SequenceTrackCounts, RequiredSequenceTracks, TEXT("sequence")))
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR required_sequence_track_missing"));
            return 22;
        }

        if (ActorWarningMessages.Num() != ActorWarnings)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR warning_capture_mismatch actor=%s reported=%d captured=%d"),
                *ActorLabel,
                ActorWarnings,
                ActorWarningMessages.Num()
            );
            return 23;
        }

        int32 ActorKnownWarnings = 0;
        for (const FString& WarningMessage : ActorWarningMessages)
        {
            ConverterWarningMessages.Add(MakeShared<FJsonValueString>(WarningMessage));

            // UE 4.27's generic group pass warns for Fade, then the dedicated
            // director pass converts that same track. Accept only that exact
            // false positive after both source and output tracks are proven.
            const bool bKnownFadeWarning =
                WarningMessage == TEXT("Unsupported track 'Fade'.") &&
                SourceTrackCounts.FindRef(TEXT("InterpTrackFade")) == 1 &&
                SequenceTrackCounts.FindRef(TEXT("MovieSceneFadeTrack")) > 0;
            if (!bKnownFadeWarning)
            {
                UnexpectedConversionWarnings++;
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR unexpected_conversion_warning actor=%s message=%s"),
                    *ActorLabel,
                    *WarningMessage
                );
                return 24;
            }

            ActorKnownWarnings++;
            UE_LOG(
                LogZenMatineeBridge,
                Display,
                TEXT("ZEN_BRIDGE_KNOWN_WARNING actor=%s message=%s"),
                *ActorLabel,
                *WarningMessage
            );
        }

        if (ActorKnownWarnings != ActorWarnings)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR unexplained_conversion_warning actor=%s reported=%d known=%d"),
                *ActorLabel,
                ActorWarnings,
                ActorKnownWarnings
            );
            return 25;
        }

        const FString SequencePath = Sequence->GetPathName();
        GeneratedSequences.Add(MakeShared<FJsonValueString>(SequencePath));
        ConversionWarnings += ActorWarnings;
        KnownConversionWarnings += ActorKnownWarnings;
        MatineesConverted++;

        if (!IsValid(Actor) || Actor->GetWorld() != World)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_actor_not_retained actor=%s"), *ActorLabel);
            return 26;
        }
        MatineesRetained++;

        UE_LOG(
            LogZenMatineeBridge,
            Display,
            TEXT("ZEN_BRIDGE_CONVERTED map=%s actor=%s sequence=%s warnings=%d"),
            *TargetMap,
            *ActorLabel,
            *SequencePath,
            ActorWarnings
        );
    }

    World->MarkPackageDirty();
    if (!FEditorFileUtils::SaveDirtyPackages(false, true, true, true, false, false))
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR save_failed path=%s"), *TargetMapFile);
        return 27;
    }
    ConvertedMaps = 1;

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
        return 28;
    }

    TSharedRef<FJsonObject> Report = MakeShared<FJsonObject>();
    Report->SetStringField(TEXT("engineVersion"), TEXT("4.27.2"));
    Report->SetNumberField(TEXT("mapsScanned"), MapFiles.Num());
    Report->SetNumberField(TEXT("mapsConverted"), ConvertedMaps);
    Report->SetNumberField(TEXT("uniqueMatineesDiscovered"), UniqueMatineesDiscovered);
    Report->SetNumberField(TEXT("matineesFound"), MatineesFound);
    Report->SetNumberField(TEXT("matineesConverted"), MatineesConverted);
    Report->SetNumberField(TEXT("sourceActorsRetained"), MatineesRetained);
    Report->SetNumberField(TEXT("sourceActorsRemoved"), 0);
    Report->SetNumberField(TEXT("conversionWarnings"), ConversionWarnings);
    Report->SetNumberField(TEXT("knownConversionWarnings"), KnownConversionWarnings);
    Report->SetNumberField(TEXT("unexpectedConversionWarnings"), UnexpectedConversionWarnings);
    Report->SetStringField(TEXT("targetMap"), TargetMap);
    Report->SetStringField(TEXT("expectedActor"), ExpectedActor);
    Report->SetArrayField(TEXT("matineeInventory"), MatineeInventory);
    Report->SetArrayField(TEXT("converterWarningMessages"), ConverterWarningMessages);
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
        return 29;
    }

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_SUCCESS maps=%d converted=%d retained=%d warnings=%d known=%d unexpected=%d report=%s"),
        MapFiles.Num(),
        MatineesConverted,
        MatineesRetained,
        ConversionWarnings,
        KnownConversionWarnings,
        UnexpectedConversionWarnings,
        *ReportPath
    );
    return 0;
}
