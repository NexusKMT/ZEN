#include "ZenMatineeBridgeCommandlet.h"

#include "AssetToolsModule.h"
#include "Dom/JsonObject.h"
#include "EdGraph/EdGraph.h"
#include "EdGraph/EdGraphNode.h"
#include "EdGraph/EdGraphPin.h"
#include "EdGraphSchema_K2.h"
#include "Engine/LevelScriptActor.h"
#include "K2Node_MacroInstance.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Editor.h"
#include "Engine/Blueprint.h"
#include "Engine/Level.h"
#include "Engine/World.h"
#include "EngineUtils.h"
#include "FileHelpers.h"
#include "HAL/FileManager.h"
#include "LevelSequence.h"
#include "LevelSequenceActor.h"
#include "K2Node_CallFunction.h"
#include "K2Node_Event.h"
#include "K2Node_Literal.h"
#include "K2Node_MacroInstance.h"
#include "K2Node_MatineeController.h"
#include "Engine/LevelScriptBlueprint.h"
#include "K2Node_CustomEvent.h"
#include "Kismet/KismetSystemLibrary.h"
#include "MovieSceneSequencePlayer.h"
#include "K2Node_Variable.h"
#include "Matinee/InterpData.h"
#include "Matinee/InterpGroup.h"
#include "Matinee/InterpTrack.h"
#include "Matinee/InterpTrackEvent.h"
#include "Matinee/MatineeActor.h"
#include "Misc/FileHelper.h"
#include "Misc/OutputDevice.h"
#include "Misc/OutputDeviceRedirector.h"
#include "Misc/PackageName.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"
#include "MovieScene.h"
#include "MovieSceneTrack.h"
#include "Sections/MovieSceneEventTriggerSection.h"
#include "Tracks/MovieSceneEventTrack.h"
#include "Policies/PrettyJsonPrintPolicy.h"
#include "Serialization/JsonSerializer.h"
#include "UObject/Package.h"
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

class FSaveErrorCapture final : public FOutputDevice
{
public:
    virtual void Serialize(
        const TCHAR* Message,
        ELogVerbosity::Type Verbosity,
        const FName& Category
    ) override
    {
        if (Verbosity <= ELogVerbosity::Error)
        {
            Errors.Add(FString::Printf(TEXT("%s: %s"), *Category.ToString(), Message));
        }
    }

    bool HasErrors() const
    {
        return Errors.Num() > 0;
    }

    FString JoinErrors() const
    {
        return FString::Join(Errors, TEXT(" | "));
    }

private:
    TArray<FString> Errors;
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

void CountSourceTrackKeys(UInterpTrack* Track, TMap<FString, int32>& KeyCounts)
{
    if (Track == nullptr)
    {
        return;
    }

    KeyCounts.FindOrAdd(Track->GetClass()->GetName()) += Track->GetNumKeyframes();
    for (UInterpTrack* SubTrack : Track->SubTracks)
    {
        CountSourceTrackKeys(SubTrack, KeyCounts);
    }
}

void CountSourceTrackKeys(AMatineeActor* Actor, TMap<FString, int32>& KeyCounts)
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
            CountSourceTrackKeys(Track, KeyCounts);
        }
    }
}

struct FSourceEventTrackRecord
{
    int32 GroupIndex = INDEX_NONE;
    int32 TrackIndex = INDEX_NONE;
    UInterpGroup* Group = nullptr;
    UInterpTrackEvent* Track = nullptr;
};

TArray<FSourceEventTrackRecord> GatherSourceEventTracks(AMatineeActor* Actor)
{
    TArray<FSourceEventTrackRecord> Records;
    if (Actor == nullptr || Actor->MatineeData == nullptr)
    {
        return Records;
    }

    for (int32 GroupIndex = 0; GroupIndex < Actor->MatineeData->InterpGroups.Num(); ++GroupIndex)
    {
        UInterpGroup* Group = Actor->MatineeData->InterpGroups[GroupIndex];
        if (Group == nullptr)
        {
            continue;
        }

        for (int32 TrackIndex = 0; TrackIndex < Group->InterpTracks.Num(); ++TrackIndex)
        {
            UInterpTrackEvent* EventTrack = Cast<UInterpTrackEvent>(Group->InterpTracks[TrackIndex]);
            if (EventTrack == nullptr)
            {
                continue;
            }

            FSourceEventTrackRecord& Record = Records.AddDefaulted_GetRef();
            Record.GroupIndex = GroupIndex;
            Record.TrackIndex = TrackIndex;
            Record.Group = Group;
            Record.Track = EventTrack;
        }
    }
    return Records;
}

TArray<TSharedPtr<FJsonValue>> CaptureSourceEventTracks(AMatineeActor* Actor)
{
    TArray<TSharedPtr<FJsonValue>> TrackValues;
    const TArray<FSourceEventTrackRecord> Records = GatherSourceEventTracks(Actor);
    for (int32 EventTrackIndex = 0; EventTrackIndex < Records.Num(); ++EventTrackIndex)
    {
        const FSourceEventTrackRecord& Record = Records[EventTrackIndex];
        TSharedPtr<FJsonObject> TrackJson = MakeShared<FJsonObject>();
        TrackJson->SetNumberField(TEXT("eventTrackIndex"), EventTrackIndex);
        TrackJson->SetNumberField(TEXT("groupIndex"), Record.GroupIndex);
        TrackJson->SetNumberField(TEXT("trackIndex"), Record.TrackIndex);
        TrackJson->SetStringField(TEXT("groupName"), Record.Group->GroupName.ToString());
        TrackJson->SetStringField(TEXT("trackTitle"), Record.Track->TrackTitle);
        TrackJson->SetStringField(TEXT("trackPath"), Record.Track->GetPathName());
        TrackJson->SetBoolField(TEXT("fireForwards"), Record.Track->bFireEventsWhenForwards != 0);
        TrackJson->SetBoolField(TEXT("fireBackwards"), Record.Track->bFireEventsWhenBackwards != 0);
        TrackJson->SetBoolField(
            TEXT("fireWhenJumpingForwards"),
            Record.Track->bFireEventsWhenJumpingForwards != 0
        );
        TrackJson->SetBoolField(TEXT("useCustomEventName"), Record.Track->bUseCustomEventName != 0);

        TArray<TSharedPtr<FJsonValue>> KeyValues;
        for (int32 KeyIndex = 0; KeyIndex < Record.Track->EventTrack.Num(); ++KeyIndex)
        {
            const FEventTrackKey& Key = Record.Track->EventTrack[KeyIndex];
            TSharedPtr<FJsonObject> KeyJson = MakeShared<FJsonObject>();
            KeyJson->SetNumberField(TEXT("keyIndex"), KeyIndex);
            KeyJson->SetNumberField(TEXT("timeSeconds"), Key.Time);
            KeyJson->SetStringField(TEXT("eventName"), Key.EventName.ToString());
            KeyValues.Add(MakeShared<FJsonValueObject>(KeyJson));
        }
        TrackJson->SetNumberField(TEXT("keyCount"), KeyValues.Num());
        TrackJson->SetArrayField(TEXT("keys"), KeyValues);
        TrackValues.Add(MakeShared<FJsonValueObject>(TrackJson));
    }
    return TrackValues;
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

FString PinDirectionToString(EEdGraphPinDirection Direction)
{
    return Direction == EGPD_Input ? TEXT("input") : TEXT("output");
}

FString PinContainerToString(const FEdGraphPinType& PinType)
{
    if (PinType.IsArray())
    {
        return TEXT("array");
    }
    if (PinType.IsSet())
    {
        return TEXT("set");
    }
    if (PinType.IsMap())
    {
        return TEXT("map");
    }
    return TEXT("none");
}

void AddNodeIdentity(TSharedRef<FJsonObject> Json, UEdGraphNode* Node)
{
    Json->SetStringField(TEXT("class"), Node->GetClass()->GetName());
    Json->SetStringField(TEXT("objectPath"), Node->GetPathName());
    Json->SetStringField(TEXT("title"), Node->GetNodeTitle(ENodeTitleType::FullTitle).ToString());
    Json->SetStringField(TEXT("nodeGuid"), Node->NodeGuid.ToString());
    Json->SetNumberField(TEXT("nodePosX"), Node->NodePosX);
    Json->SetNumberField(TEXT("nodePosY"), Node->NodePosY);
    Json->SetStringField(TEXT("nodeComment"), Node->NodeComment);
    Json->SetStringField(
        TEXT("graphPath"),
        Node->GetGraph() != nullptr ? Node->GetGraph()->GetPathName() : FString()
    );

    if (UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node))
    {
        Json->SetStringField(TEXT("functionName"), CallNode->GetFunctionName().ToString());
        if (UFunction* TargetFunction = CallNode->GetTargetFunction())
        {
            Json->SetStringField(TEXT("functionPath"), TargetFunction->GetPathName());
            Json->SetStringField(
                TEXT("functionOwnerClass"),
                TargetFunction->GetOuterUClass()->GetPathName()
            );
        }
    }

    if (UK2Node_Event* EventNode = Cast<UK2Node_Event>(Node))
    {
        Json->SetStringField(TEXT("eventName"), EventNode->GetFunctionName().ToString());
    }

    if (UK2Node_Variable* VariableNode = Cast<UK2Node_Variable>(Node))
    {
        Json->SetStringField(TEXT("variableName"), VariableNode->GetVarName().ToString());
        if (UClass* SourceClass = VariableNode->GetVariableSourceClass())
        {
            Json->SetStringField(TEXT("variableSourceClass"), SourceClass->GetPathName());
        }
    }

    if (UK2Node_MacroInstance* MacroNode = Cast<UK2Node_MacroInstance>(Node))
    {
        if (UEdGraph* MacroGraph = MacroNode->GetMacroGraph())
        {
            Json->SetStringField(TEXT("macroGraphPath"), MacroGraph->GetPathName());
        }
    }
}

TSharedRef<FJsonObject> CaptureBlueprintNode(UEdGraphNode* Node)
{
    TSharedRef<FJsonObject> NodeJson = MakeShared<FJsonObject>();
    AddNodeIdentity(NodeJson, Node);

    if (UK2Node_MatineeController* Controller = Cast<UK2Node_MatineeController>(Node))
    {
        NodeJson->SetStringField(TEXT("semantic"), TEXT("matineeEventController"));
        NodeJson->SetStringField(
            TEXT("referencedObject"),
            Controller->MatineeActor != nullptr
                ? Controller->MatineeActor->GetPathName()
                : FString()
        );
    }
    else if (UK2Node_Literal* Literal = Cast<UK2Node_Literal>(Node))
    {
        NodeJson->SetStringField(TEXT("semantic"), TEXT("levelActorLiteral"));
        NodeJson->SetStringField(
            TEXT("referencedObject"),
            Literal->GetObjectRef() != nullptr
                ? Literal->GetObjectRef()->GetPathName()
                : FString()
        );
    }

    TArray<TSharedPtr<FJsonValue>> PinValues;
    for (int32 PinIndex = 0; PinIndex < Node->Pins.Num(); ++PinIndex)
    {
        UEdGraphPin* Pin = Node->Pins[PinIndex];
        if (Pin == nullptr)
        {
            continue;
        }

        TSharedPtr<FJsonObject> PinJson = MakeShared<FJsonObject>();
        PinJson->SetNumberField(TEXT("index"), PinIndex);
        PinJson->SetStringField(TEXT("pinId"), Pin->PinId.ToString());
        PinJson->SetStringField(TEXT("persistentGuid"), Pin->PersistentGuid.ToString());
        PinJson->SetStringField(TEXT("name"), Pin->PinName.ToString());
        PinJson->SetStringField(TEXT("direction"), PinDirectionToString(Pin->Direction));
        PinJson->SetStringField(TEXT("category"), Pin->PinType.PinCategory.ToString());
        PinJson->SetStringField(TEXT("subCategory"), Pin->PinType.PinSubCategory.ToString());
        PinJson->SetStringField(TEXT("container"), PinContainerToString(Pin->PinType));
        PinJson->SetBoolField(TEXT("isReference"), Pin->PinType.bIsReference != 0);
        PinJson->SetBoolField(TEXT("isConst"), Pin->PinType.bIsConst != 0);
        PinJson->SetBoolField(TEXT("isWeakPointer"), Pin->PinType.bIsWeakPointer != 0);
        PinJson->SetBoolField(TEXT("hidden"), Pin->bHidden != 0);
        PinJson->SetBoolField(TEXT("notConnectable"), Pin->bNotConnectable != 0);
        PinJson->SetBoolField(TEXT("orphaned"), Pin->bOrphanedPin != 0);
        PinJson->SetStringField(TEXT("defaultValue"), Pin->DefaultValue);
        PinJson->SetStringField(TEXT("autogeneratedDefaultValue"), Pin->AutogeneratedDefaultValue);
        PinJson->SetStringField(TEXT("defaultTextValue"), Pin->DefaultTextValue.ToString());
        PinJson->SetStringField(
            TEXT("defaultObject"),
            Pin->DefaultObject != nullptr ? Pin->DefaultObject->GetPathName() : FString()
        );
        PinJson->SetStringField(
            TEXT("subCategoryObject"),
            Pin->PinType.PinSubCategoryObject.IsValid()
                ? Pin->PinType.PinSubCategoryObject->GetPathName()
                : FString()
        );

        struct FLinkRecord
        {
            FString SortKey;
            TSharedPtr<FJsonObject> Json;
        };
        TArray<FLinkRecord> LinkRecords;
        for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
        {
            if (LinkedPin == nullptr || LinkedPin->GetOwningNodeUnchecked() == nullptr)
            {
                continue;
            }

            UEdGraphNode* LinkedNode = LinkedPin->GetOwningNode();
            FLinkRecord& LinkRecord = LinkRecords.AddDefaulted_GetRef();
            LinkRecord.SortKey = LinkedNode->GetPathName() + TEXT(":") + LinkedPin->PinName.ToString();
            LinkRecord.Json = MakeShared<FJsonObject>();
            AddNodeIdentity(LinkRecord.Json.ToSharedRef(), LinkedNode);
            LinkRecord.Json->SetStringField(TEXT("pinName"), LinkedPin->PinName.ToString());
            LinkRecord.Json->SetStringField(
                TEXT("pinDirection"),
                PinDirectionToString(LinkedPin->Direction)
            );
            LinkRecord.Json->SetStringField(
                TEXT("pinCategory"),
                LinkedPin->PinType.PinCategory.ToString()
            );
        }
        LinkRecords.Sort([](const FLinkRecord& Left, const FLinkRecord& Right)
        {
            return Left.SortKey < Right.SortKey;
        });

        TArray<TSharedPtr<FJsonValue>> LinkValues;
        for (const FLinkRecord& LinkRecord : LinkRecords)
        {
            LinkValues.Add(MakeShared<FJsonValueObject>(LinkRecord.Json));
        }
        PinJson->SetNumberField(TEXT("linkCount"), LinkValues.Num());
        PinJson->SetArrayField(TEXT("links"), LinkValues);
        PinValues.Add(MakeShared<FJsonValueObject>(PinJson));
    }

    NodeJson->SetNumberField(TEXT("pinCount"), PinValues.Num());
    NodeJson->SetArrayField(TEXT("pins"), PinValues);
    return NodeJson;
}

TSharedRef<FJsonObject> CaptureBlueprintGraph(UEdGraph* Graph)
{
    struct FNodeRecord
    {
        FString ObjectPath;
        TSharedPtr<FJsonObject> Json;
    };

    TArray<FNodeRecord> NodeRecords;
    for (UEdGraphNode* Node : Graph->Nodes)
    {
        if (Node == nullptr)
        {
            continue;
        }

        FNodeRecord& Record = NodeRecords.AddDefaulted_GetRef();
        Record.ObjectPath = Node->GetPathName();
        Record.Json = CaptureBlueprintNode(Node);
    }
    NodeRecords.Sort([](const FNodeRecord& Left, const FNodeRecord& Right)
    {
        return Left.ObjectPath < Right.ObjectPath;
    });

    TArray<TSharedPtr<FJsonValue>> NodeValues;
    for (const FNodeRecord& Record : NodeRecords)
    {
        NodeValues.Add(MakeShared<FJsonValueObject>(Record.Json));
    }

    TSharedRef<FJsonObject> GraphJson = MakeShared<FJsonObject>();
    GraphJson->SetStringField(TEXT("graphPath"), Graph->GetPathName());
    GraphJson->SetStringField(TEXT("package"), Graph->GetOutermost()->GetName());
    GraphJson->SetNumberField(TEXT("nodeCount"), NodeValues.Num());
    GraphJson->SetArrayField(TEXT("nodes"), NodeValues);
    return GraphJson;
}


TSharedRef<FJsonObject> CaptureDataPinSnapshot(UEdGraphPin* Pin)
{
    TSharedRef<FJsonObject> PinJson = MakeShared<FJsonObject>();
    PinJson->SetStringField(TEXT("name"), Pin->PinName.ToString());
    PinJson->SetStringField(TEXT("direction"), PinDirectionToString(Pin->Direction));
    PinJson->SetStringField(TEXT("category"), Pin->PinType.PinCategory.ToString());
    PinJson->SetStringField(TEXT("defaultValue"), Pin->DefaultValue);
    PinJson->SetStringField(
        TEXT("defaultObject"),
        Pin->DefaultObject != nullptr ? Pin->DefaultObject->GetPathName() : FString()
    );

    TArray<TSharedPtr<FJsonValue>> LinkValues;
    for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
    {
        if (LinkedPin == nullptr || LinkedPin->GetOwningNodeUnchecked() == nullptr)
        {
            continue;
        }

        UEdGraphNode* LinkedNode = LinkedPin->GetOwningNode();
        TSharedPtr<FJsonObject> LinkJson = MakeShared<FJsonObject>();
        AddNodeIdentity(LinkJson.ToSharedRef(), LinkedNode);
        LinkJson->SetStringField(TEXT("pinName"), LinkedPin->PinName.ToString());
        LinkValues.Add(MakeShared<FJsonValueObject>(LinkJson));
    }
    PinJson->SetNumberField(TEXT("linkCount"), LinkValues.Num());
    PinJson->SetArrayField(TEXT("links"), LinkValues);
    return PinJson;
}

TArray<TSharedPtr<FJsonValue>> CaptureExecClosure(UEdGraphPin* StartOutputPin, int32 MaxNodes = 64)
{
    TArray<TSharedPtr<FJsonValue>> Steps;
    if (StartOutputPin == nullptr)
    {
        return Steps;
    }

    TSet<UEdGraphNode*> VisitedNodes;
    TArray<UEdGraphPin*> Queue;
    for (UEdGraphPin* LinkedPin : StartOutputPin->LinkedTo)
    {
        if (LinkedPin != nullptr)
        {
            Queue.Add(LinkedPin);
        }
    }

    while (Queue.Num() > 0 && Steps.Num() < MaxNodes)
    {
        UEdGraphPin* InputPin = Queue[0];
        Queue.RemoveAt(0);
        if (InputPin == nullptr || InputPin->GetOwningNodeUnchecked() == nullptr)
        {
            continue;
        }

        UEdGraphNode* Node = InputPin->GetOwningNode();
        if (VisitedNodes.Contains(Node))
        {
            continue;
        }
        VisitedNodes.Add(Node);

        TSharedPtr<FJsonObject> StepJson = MakeShared<FJsonObject>();
        AddNodeIdentity(StepJson.ToSharedRef(), Node);
        StepJson->SetStringField(TEXT("enteredViaPin"), InputPin->PinName.ToString());

        TArray<TSharedPtr<FJsonValue>> DataPins;
        for (UEdGraphPin* Pin : Node->Pins)
        {
            if (Pin == nullptr || Pin->PinType.PinCategory == UEdGraphSchema_K2::PC_Exec)
            {
                continue;
            }

            const bool bHasDefault =
                !Pin->DefaultValue.IsEmpty() ||
                Pin->DefaultObject != nullptr ||
                Pin->LinkedTo.Num() > 0;
            if (!bHasDefault)
            {
                continue;
            }
            DataPins.Add(MakeShared<FJsonValueObject>(CaptureDataPinSnapshot(Pin)));
        }
        StepJson->SetNumberField(TEXT("dataPinCount"), DataPins.Num());
        StepJson->SetArrayField(TEXT("dataPins"), DataPins);
        Steps.Add(MakeShared<FJsonValueObject>(StepJson));

        for (UEdGraphPin* Pin : Node->Pins)
        {
            if (Pin == nullptr ||
                Pin->Direction != EGPD_Output ||
                Pin->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
            {
                continue;
            }
            for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
            {
                if (LinkedPin != nullptr)
                {
                    Queue.Add(LinkedPin);
                }
            }
        }
    }

    return Steps;
}

UK2Node_MatineeController* FindMatineeControllerNode(AMatineeActor* SourceActor, UEdGraph*& OutGraph)
{
    OutGraph = nullptr;
    if (SourceActor == nullptr || SourceActor->GetLevel() == nullptr)
    {
        return nullptr;
    }

    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel()->GetLevelScriptBlueprint(true)
    );
    if (LevelBlueprint == nullptr)
    {
        return nullptr;
    }

    for (UEdGraph* Graph : LevelBlueprint->UbergraphPages)
    {
        if (Graph == nullptr)
        {
            continue;
        }
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_MatineeController* Controller = Cast<UK2Node_MatineeController>(Node);
            if (Controller != nullptr && Controller->MatineeActor == SourceActor)
            {
                OutGraph = Graph;
                return Controller;
            }
        }
    }
    return nullptr;
}

TArray<TSharedPtr<FJsonValue>> CapturePlaybackControlCalls(AMatineeActor* SourceActor)
{
    TArray<TSharedPtr<FJsonValue>> Controls;
    if (SourceActor == nullptr || SourceActor->GetLevel() == nullptr)
    {
        return Controls;
    }

    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel()->GetLevelScriptBlueprint(true)
    );
    if (LevelBlueprint == nullptr)
    {
        return Controls;
    }

    const TArray<FName> ControlNames = {
        FName(TEXT("Play")),
        FName(TEXT("Pause")),
        FName(TEXT("Stop")),
        FName(TEXT("SetPosition")),
        FName(TEXT("Reverse"))
    };

    for (UEdGraph* Graph : LevelBlueprint->UbergraphPages)
    {
        if (Graph == nullptr)
        {
            continue;
        }
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node);
            if (CallNode == nullptr)
            {
                continue;
            }

            const FName FunctionName = CallNode->GetFunctionName();
            if (!ControlNames.Contains(FunctionName))
            {
                continue;
            }

            UFunction* TargetFunction = CallNode->GetTargetFunction();
            if (TargetFunction == nullptr ||
                TargetFunction->GetOuterUClass() == nullptr ||
                TargetFunction->GetOuterUClass()->GetName() != TEXT("MatineeActor"))
            {
                continue;
            }

            bool bTargetsSourceActor = false;
            if (UEdGraphPin* SelfPin = CallNode->FindPin(UEdGraphSchema_K2::PN_Self))
            {
                for (UEdGraphPin* LinkedPin : SelfPin->LinkedTo)
                {
                    UK2Node_Literal* Literal = LinkedPin != nullptr
                        ? Cast<UK2Node_Literal>(LinkedPin->GetOwningNodeUnchecked())
                        : nullptr;
                    if (Literal != nullptr && Literal->GetObjectRef() == SourceActor)
                    {
                        bTargetsSourceActor = true;
                        break;
                    }
                }
            }
            if (!bTargetsSourceActor)
            {
                continue;
            }

            TSharedPtr<FJsonObject> ControlJson = MakeShared<FJsonObject>();
            AddNodeIdentity(ControlJson.ToSharedRef(), CallNode);
            ControlJson->SetStringField(TEXT("functionName"), FunctionName.ToString());
            ControlJson->SetStringField(
                TEXT("functionPath"),
                TargetFunction->GetPathName()
            );

            UEdGraphPin* ExecIn = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
            TArray<TSharedPtr<FJsonValue>> Incoming;
            if (ExecIn != nullptr)
            {
                for (UEdGraphPin* LinkedPin : ExecIn->LinkedTo)
                {
                    if (LinkedPin == nullptr || LinkedPin->GetOwningNodeUnchecked() == nullptr)
                    {
                        continue;
                    }
                    TSharedPtr<FJsonObject> LinkJson = MakeShared<FJsonObject>();
                    AddNodeIdentity(LinkJson.ToSharedRef(), LinkedPin->GetOwningNode());
                    LinkJson->SetStringField(TEXT("pinName"), LinkedPin->PinName.ToString());
                    Incoming.Add(MakeShared<FJsonValueObject>(LinkJson));
                }
            }
            ControlJson->SetNumberField(TEXT("incomingExecCount"), Incoming.Num());
            ControlJson->SetArrayField(TEXT("incomingExec"), Incoming);

            UEdGraphPin* ThenPin = CallNode->FindPin(UEdGraphSchema_K2::PN_Then);
            ControlJson->SetArrayField(
                TEXT("thenClosure"),
                CaptureExecClosure(ThenPin)
            );
            Controls.Add(MakeShared<FJsonValueObject>(ControlJson));
        }
    }

    Controls.Sort([](const TSharedPtr<FJsonValue>& Left, const TSharedPtr<FJsonValue>& Right)
    {
        return Left->AsObject()->GetStringField(TEXT("objectPath")) <
            Right->AsObject()->GetStringField(TEXT("objectPath"));
    });
    return Controls;
}

TSharedRef<FJsonObject> CaptureLevelSequenceActorAudit(ALevelSequenceActor* SequenceActor)
{
    TSharedRef<FJsonObject> ActorJson = MakeShared<FJsonObject>();
    if (SequenceActor == nullptr)
    {
        ActorJson->SetBoolField(TEXT("present"), false);
        return ActorJson;
    }

    ActorJson->SetBoolField(TEXT("present"), true);
    ActorJson->SetStringField(TEXT("actorPath"), SequenceActor->GetPathName());
    ActorJson->SetStringField(TEXT("actorLabel"), SequenceActor->GetActorLabel());
    ActorJson->SetStringField(TEXT("levelSequencePath"), SequenceActor->LevelSequence.ToString());
    ActorJson->SetBoolField(TEXT("overrideInstanceData"), SequenceActor->bOverrideInstanceData != 0);
    ActorJson->SetBoolField(TEXT("replicatePlayback"), SequenceActor->bReplicatePlayback != 0);

    const FMovieSceneSequencePlaybackSettings& Settings = SequenceActor->PlaybackSettings;
    TSharedPtr<FJsonObject> SettingsJson = MakeShared<FJsonObject>();
    SettingsJson->SetBoolField(TEXT("autoPlay"), Settings.bAutoPlay != 0);
    SettingsJson->SetNumberField(TEXT("loopCount"), Settings.LoopCount.Value);
    SettingsJson->SetNumberField(TEXT("playRate"), Settings.PlayRate);
    SettingsJson->SetNumberField(TEXT("startTime"), Settings.StartTime);
    SettingsJson->SetBoolField(TEXT("randomStartTime"), Settings.bRandomStartTime != 0);
    SettingsJson->SetBoolField(TEXT("restoreState"), Settings.bRestoreState != 0);
    SettingsJson->SetBoolField(TEXT("disableMovementInput"), Settings.bDisableMovementInput != 0);
    SettingsJson->SetBoolField(TEXT("disableLookAtInput"), Settings.bDisableLookAtInput != 0);
    SettingsJson->SetBoolField(TEXT("hidePlayer"), Settings.bHidePlayer != 0);
    SettingsJson->SetBoolField(TEXT("hideHud"), Settings.bHideHud != 0);
    SettingsJson->SetBoolField(TEXT("disableCameraCuts"), Settings.bDisableCameraCuts != 0);
    SettingsJson->SetBoolField(TEXT("pauseAtEnd"), Settings.bPauseAtEnd != 0);
    ActorJson->SetObjectField(TEXT("playbackSettings"), SettingsJson);
    return ActorJson;
}

UEdGraphPin* FindPinByName(UEdGraphNode* Node, FName PinName, EEdGraphPinDirection Direction)
{
    if (Node == nullptr) { return nullptr; }
    for (UEdGraphPin* Pin : Node->Pins)
    {
        if (Pin != nullptr && Pin->PinName == PinName && Pin->Direction == Direction)
        {
            return Pin;
        }
    }
    return nullptr;
}

void CopyPinDefaultsForRewrite(UEdGraphPin* SourcePin, UEdGraphPin* DestPin)
{
    if (SourcePin == nullptr || DestPin == nullptr) { return; }
    DestPin->DefaultValue = SourcePin->DefaultValue;
    DestPin->DefaultObject = SourcePin->DefaultObject;
    DestPin->DefaultTextValue = SourcePin->DefaultTextValue;
    DestPin->AutogeneratedDefaultValue = SourcePin->AutogeneratedDefaultValue;
}

UEdGraphPin* FindExecPinForRewrite(UEdGraphNode* Node, EEdGraphPinDirection Direction)
{
    if (Node == nullptr)
    {
        return nullptr;
    }
    for (UEdGraphPin* Pin : Node->Pins)
    {
        if (Pin != nullptr &&
            Pin->Direction == Direction &&
            Pin->PinType.PinCategory == UEdGraphSchema_K2::PC_Exec)
        {
            return Pin;
        }
    }
    return nullptr;
}

UK2Node* CloneNodeForRewrite(UEdGraphNode* SourceNode, UEdGraph* DestGraph, int32 NodePosX, int32 NodePosY)
{
    if (SourceNode == nullptr || DestGraph == nullptr) { return nullptr; }

    if (UK2Node_CallFunction* SourceCall = Cast<UK2Node_CallFunction>(SourceNode))
    {
        UK2Node_CallFunction* NewCall = NewObject<UK2Node_CallFunction>(DestGraph);
        DestGraph->AddNode(NewCall, false, false);
        NewCall->CreateNewGuid();
        NewCall->PostPlacedNewNode();
        if (UFunction* Function = SourceCall->GetTargetFunction())
        {
            NewCall->SetFromFunction(Function);
        }
        else
        {
            NewCall->FunctionReference = SourceCall->FunctionReference;
        }
        if (NewCall->Pins.Num() == 0)
        {
            NewCall->AllocateDefaultPins();
        }
        NewCall->ReconstructNode();
        NewCall->NodePosX = NodePosX;
        NewCall->NodePosY = NodePosY;
        if (FindExecPinForRewrite(NewCall, EGPD_Input) == nullptr &&
            FindExecPinForRewrite(SourceCall, EGPD_Input) != nullptr)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR clone_call_without_exec source=%s pins=%d function=%s"),
                *SourceCall->GetPathName(),
                NewCall->Pins.Num(),
                *SourceCall->GetFunctionName().ToString()
            );
            return nullptr;
        }
        return NewCall;
    }

    if (UK2Node_Literal* SourceLiteral = Cast<UK2Node_Literal>(SourceNode))
    {
        UK2Node_Literal* NewLiteral = NewObject<UK2Node_Literal>(DestGraph);
        DestGraph->AddNode(NewLiteral, false, false);
        NewLiteral->CreateNewGuid();
        NewLiteral->PostPlacedNewNode();
        NewLiteral->SetObjectRef(SourceLiteral->GetObjectRef());
        NewLiteral->AllocateDefaultPins();
        NewLiteral->ReconstructNode();
        NewLiteral->NodePosX = NodePosX;
        NewLiteral->NodePosY = NodePosY;
        return NewLiteral;
    }

    if (UK2Node_MacroInstance* SourceMacro = Cast<UK2Node_MacroInstance>(SourceNode))
    {
        UK2Node_MacroInstance* NewMacro = NewObject<UK2Node_MacroInstance>(DestGraph);
        DestGraph->AddNode(NewMacro, false, false);
        NewMacro->CreateNewGuid();
        NewMacro->PostPlacedNewNode();
        NewMacro->SetMacroGraph(SourceMacro->GetMacroGraph());
        NewMacro->AllocateDefaultPins();
        NewMacro->ReconstructNode();
        NewMacro->NodePosX = NodePosX;
        NewMacro->NodePosY = NodePosY;
        return NewMacro;
    }

    UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_unsupported_node class=%s path=%s"),
        *SourceNode->GetClass()->GetName(), *SourceNode->GetPathName());
    return nullptr;
}

bool CloneExecClosureToEndpoint(
    UEdGraphPin* ControllerEventPin,
    UK2Node_CustomEvent* Endpoint,
    UEdGraph* DirectorGraph,
    ALevelScriptActor* LevelScriptActor,
    int32& OutClonedNodeCount
)
{
    OutClonedNodeCount = 0;
    if (ControllerEventPin == nullptr || Endpoint == nullptr || DirectorGraph == nullptr) { return false; }

    UEdGraphPin* EndpointThen = FindPinByName(Endpoint, UEdGraphSchema_K2::PN_Then, EGPD_Output);
    if (EndpointThen == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR endpoint_then_missing path=%s"), *Endpoint->GetPathName());
        return false;
    }
    if (EndpointThen->LinkedTo.Num() > 0)
    {
        OutClonedNodeCount = EndpointThen->LinkedTo.Num();
        return true;
    }
    if (ControllerEventPin->LinkedTo.Num() == 0)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR controller_pin_has_no_links pin=%s"), *ControllerEventPin->PinName.ToString());
        return false;
    }

    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    TMap<UEdGraphNode*, UK2Node*> ClonedNodes;
    TArray<UEdGraphNode*> VisitOrder;
    TSet<UEdGraphNode*> Queued;
    TArray<UEdGraphNode*> Queue;

    for (UEdGraphPin* LinkedPin : ControllerEventPin->LinkedTo)
    {
        if (LinkedPin != nullptr && LinkedPin->GetOwningNodeUnchecked() != nullptr)
        {
            UEdGraphNode* Node = LinkedPin->GetOwningNode();
            if (!Queued.Contains(Node)) { Queued.Add(Node); Queue.Add(Node); }
        }
    }

    for (int32 Index = 0; Index < Queue.Num(); ++Index)
    {
        UEdGraphNode* Node = Queue[Index];
        VisitOrder.Add(Node);
        for (UEdGraphPin* Pin : Node->Pins)
        {
            if (Pin == nullptr) { continue; }
            // Pull supporting non-exec dependencies (literals, etc).
            if (Pin->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
            {
                for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
                {
                    if (LinkedPin == nullptr || LinkedPin->GetOwningNodeUnchecked() == nullptr) { continue; }
                    UEdGraphNode* LinkedNode = LinkedPin->GetOwningNode();
                    if (LinkedNode->GetGraph() != Node->GetGraph() || Queued.Contains(LinkedNode)) { continue; }
                    // Only literals are safe data dependencies. Exec BFS already
                    // discovers call/macro nodes on the gameplay path.
                    if (Cast<UK2Node_Literal>(LinkedNode) != nullptr)
                    {
                        Queued.Add(LinkedNode);
                        Queue.Add(LinkedNode);
                    }
                }
            }
            if (Pin->Direction == EGPD_Output && Pin->PinType.PinCategory == UEdGraphSchema_K2::PC_Exec)
            {
                for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
                {
                    if (LinkedPin != nullptr && LinkedPin->GetOwningNodeUnchecked() != nullptr)
                    {
                        UEdGraphNode* Next = LinkedPin->GetOwningNode();
                        if (!Queued.Contains(Next)) { Queued.Add(Next); Queue.Add(Next); }
                    }
                }
            }
        }
    }

    const int32 BaseX = Endpoint->NodePosX + 300;
    const int32 BaseY = Endpoint->NodePosY;
    int32 Column = 0;
    for (UEdGraphNode* SourceNode : VisitOrder)
    {
        UK2Node* Cloned = CloneNodeForRewrite(SourceNode, DirectorGraph, BaseX + (Column * 250), BaseY + ((Column % 3) * 40));
        if (Cloned == nullptr) { return false; }
        ClonedNodes.Add(SourceNode, Cloned);
        ++Column;
        ++OutClonedNodeCount;
    }

    for (const TPair<UEdGraphNode*, UK2Node*>& Pair : ClonedNodes)
    {
        UEdGraphNode* SourceNode = Pair.Key;
        UK2Node* DestNode = Pair.Value;
        for (UEdGraphPin* SourcePin : SourceNode->Pins)
        {
            if (SourcePin == nullptr) { continue; }
            UEdGraphPin* DestPin = DestNode->FindPin(SourcePin->PinName, SourcePin->Direction);
            if (DestPin == nullptr) { continue; }
            CopyPinDefaultsForRewrite(SourcePin, DestPin);
            if (SourcePin->Direction != EGPD_Output) { continue; }
            for (UEdGraphPin* SourceLinked : SourcePin->LinkedTo)
            {
                if (SourceLinked == nullptr || SourceLinked->GetOwningNodeUnchecked() == nullptr) { continue; }
                UK2Node** DestLinkedNode = ClonedNodes.Find(SourceLinked->GetOwningNode());
                if (DestLinkedNode == nullptr || *DestLinkedNode == nullptr) { continue; }
                UEdGraphPin* DestLinkedPin = (*DestLinkedNode)->FindPin(SourceLinked->PinName, SourceLinked->Direction);
                if (DestLinkedPin == nullptr) { continue; }
                if (!Schema->TryCreateConnection(DestPin, DestLinkedPin))
                {
                    DestPin->MakeLinkTo(DestLinkedPin);
                }
            }
        }
    }

    UK2Node_Literal* SharedLsaLiteral = nullptr;
    for (const TPair<UEdGraphNode*, UK2Node*>& Pair : ClonedNodes)
    {
        UK2Node_CallFunction* DestCall = Cast<UK2Node_CallFunction>(Pair.Value);
        if (DestCall == nullptr) { continue; }
        UFunction* Function = DestCall->GetTargetFunction();
        if (Function == nullptr || Function->GetOuterUClass() == nullptr) { continue; }
        if (!Function->GetOuterUClass()->IsChildOf(ALevelScriptActor::StaticClass())) { continue; }
        UEdGraphPin* SelfPin = DestCall->FindPin(UEdGraphSchema_K2::PN_Self);
        if (SelfPin == nullptr || SelfPin->LinkedTo.Num() > 0) { continue; }
        if (SharedLsaLiteral == nullptr)
        {
            if (LevelScriptActor == nullptr)
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR level_script_actor_missing_for_remote_event"));
                return false;
            }
            SharedLsaLiteral = NewObject<UK2Node_Literal>(DirectorGraph);
            SharedLsaLiteral->CreateNewGuid();
            SharedLsaLiteral->PostPlacedNewNode();
            SharedLsaLiteral->SetObjectRef(LevelScriptActor);
            SharedLsaLiteral->AllocateDefaultPins();
            SharedLsaLiteral->NodePosX = BaseX - 200;
            SharedLsaLiteral->NodePosY = BaseY;
            DirectorGraph->AddNode(SharedLsaLiteral, false, false);
            ++OutClonedNodeCount;
        }
        UEdGraphPin* LiteralOut = SharedLsaLiteral->Pins.Num() > 0 ? SharedLsaLiteral->Pins[0] : nullptr;
        if (LiteralOut != nullptr)
        {
            if (!Schema->TryCreateConnection(LiteralOut, SelfPin)) { LiteralOut->MakeLinkTo(SelfPin); }
        }
    }

    for (UEdGraphPin* SourceLinked : ControllerEventPin->LinkedTo)
    {
        if (SourceLinked == nullptr || SourceLinked->GetOwningNodeUnchecked() == nullptr) { continue; }
        UK2Node** DestNode = ClonedNodes.Find(SourceLinked->GetOwningNode());
        if (DestNode == nullptr || *DestNode == nullptr) { continue; }
        UEdGraphPin* DestExec = (*DestNode)->FindPin(SourceLinked->PinName, SourceLinked->Direction);
        if (DestExec == nullptr)
        {
            DestExec = FindPinByName(*DestNode, UEdGraphSchema_K2::PN_Execute, EGPD_Input);
        }
        if (DestExec == nullptr)
        {
            DestExec = FindExecPinForRewrite(*DestNode, EGPD_Input);
        }
        if (DestExec == nullptr)
        {
            FString PinNames;
            for (const UEdGraphPin* Pin : (*DestNode)->Pins)
            {
                if (Pin != nullptr)
                {
                    PinNames += FString::Printf(
                        TEXT("%s:%s:%s;"),
                        *Pin->PinName.ToString(),
                        Pin->Direction == EGPD_Input ? TEXT("in") : TEXT("out"),
                        *Pin->PinType.PinCategory.ToString()
                    );
                }
            }
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR clone_exec_pin_missing node=%s class=%s pins=%s wanted=%s"),
                *(*DestNode)->GetPathName(),
                *(*DestNode)->GetClass()->GetName(),
                *PinNames,
                *SourceLinked->PinName.ToString()
            );
            return false;
        }
        if (!Schema->TryCreateConnection(EndpointThen, DestExec)) { EndpointThen->MakeLinkTo(DestExec); }
    }

    if (EndpointThen->LinkedTo.Num() == 0)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR endpoint_not_wired path=%s"), *Endpoint->GetPathName());
        return false;
    }
    return true;
}

bool ApplyDirectorEventRewrite(
    AMatineeActor* SourceActor,
    ULevelSequence* Sequence,
    TSharedPtr<FJsonObject>& OutRewriteResult
)
{
    OutRewriteResult = MakeShared<FJsonObject>();
    OutRewriteResult->SetBoolField(TEXT("applied"), false);
    if (SourceActor == nullptr || Sequence == nullptr) { return false; }

    UBlueprint* DirectorBlueprint = Sequence->GetDirectorBlueprint();
    if (DirectorBlueprint == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_director_missing"));
        return false;
    }

    UEdGraph* ControllerGraph = nullptr;
    UK2Node_MatineeController* Controller = FindMatineeControllerNode(SourceActor, ControllerGraph);
    if (Controller == nullptr || ControllerGraph == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_controller_missing"));
        return false;
    }

    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel() != nullptr ? SourceActor->GetLevel()->GetLevelScriptBlueprint(true) : nullptr);
    if (LevelBlueprint == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_level_script_missing"));
        return false;
    }

    UEdGraph* SequencerEventsGraph = nullptr;
    for (UEdGraph* Graph : DirectorBlueprint->UbergraphPages)
    {
        if (Graph != nullptr && Graph->GetName() == TEXT("Sequencer Events"))
        {
            SequencerEventsGraph = Graph;
            break;
        }
    }
    if (SequencerEventsGraph == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequencer_events_graph_missing"));
        return false;
    }

    const TArray<FSourceEventTrackRecord> SourceTracks = GatherSourceEventTracks(SourceActor);
    TArray<UMovieSceneEventTrack*> TargetTracks;
    for (UMovieSceneTrack* Track : Sequence->GetMovieScene()->GetMasterTracks())
    {
        if (UMovieSceneEventTrack* EventTrack = Cast<UMovieSceneEventTrack>(Track))
        {
            TargetTracks.Add(EventTrack);
        }
    }
    if (SourceTracks.Num() != 1 || TargetTracks.Num() != 1)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_event_track_mismatch"));
        return false;
    }

    const TArray<UMovieSceneSection*>& Sections = TargetTracks[0]->GetAllSections();
    if (Sections.Num() != 1) { return false; }
    const UMovieSceneEventTriggerSection* TriggerSection = Cast<UMovieSceneEventTriggerSection>(Sections[0]);
    if (TriggerSection == nullptr) { return false; }
    const TMovieSceneChannelData<const FMovieSceneEvent> ChannelData = TriggerSection->EventChannel.GetData();
    const TArrayView<const FMovieSceneEvent> Events = ChannelData.GetValues();
    if (Events.Num() != SourceTracks[0].Track->EventTrack.Num()) { return false; }

    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    UFunction* ExecuteConsoleCommandFunction = UKismetSystemLibrary::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(UKismetSystemLibrary, ExecuteConsoleCommand));
    if (ExecuteConsoleCommandFunction == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR execute_console_command_function_missing"));
        return false;
    }

    DirectorBlueprint->Modify();
    SequencerEventsGraph->Modify();
    LevelBlueprint->Modify();
    ControllerGraph->Modify();

    TArray<TSharedPtr<FJsonValue>> WiredEvents;
    int32 TotalCloned = 0;
    for (int32 KeyIndex = 0; KeyIndex < Events.Num(); ++KeyIndex)
    {
        const FEventTrackKey& SourceKey = SourceTracks[0].Track->EventTrack[KeyIndex];
        UK2Node_CustomEvent* Endpoint = Cast<UK2Node_CustomEvent>(Events[KeyIndex].WeakEndpoint.Get());
        UEdGraphPin* ControllerPin = Controller->FindPin(SourceKey.EventName);
        if (Endpoint == nullptr || ControllerPin == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR rewrite_endpoint_or_pin_missing event=%s"), *SourceKey.EventName.ToString());
            return false;
        }
        if (ControllerPin->LinkedTo.Num() == 0)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR controller_pin_has_no_links pin=%s"), *ControllerPin->PinName.ToString());
            return false;
        }

        const FName SeqEventName(*FString::Printf(TEXT("ZenSeq_%s"), *SourceKey.EventName.ToString()));

        UK2Node_CustomEvent* LevelSeqEvent = nullptr;
        for (UEdGraphNode* Node : ControllerGraph->Nodes)
        {
            if (UK2Node_CustomEvent* Existing = Cast<UK2Node_CustomEvent>(Node))
            {
                if (Existing->CustomFunctionName == SeqEventName)
                {
                    LevelSeqEvent = Existing;
                    break;
                }
            }
        }
        if (LevelSeqEvent == nullptr)
        {
            LevelSeqEvent = NewObject<UK2Node_CustomEvent>(ControllerGraph);
            ControllerGraph->AddNode(LevelSeqEvent, false, false);
            LevelSeqEvent->CreateNewGuid();
            LevelSeqEvent->PostPlacedNewNode();
            LevelSeqEvent->bIsEditable = true;
            LevelSeqEvent->CustomFunctionName = SeqEventName;
            LevelSeqEvent->AllocateDefaultPins();
            LevelSeqEvent->NodePosX = Controller->NodePosX - 250;
            LevelSeqEvent->NodePosY = Controller->NodePosY + (KeyIndex * 80);
            ++TotalCloned;
        }

        UEdGraphPin* LevelThen = FindPinByName(LevelSeqEvent, UEdGraphSchema_K2::PN_Then, EGPD_Output);
        if (LevelThen == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR level_seq_event_then_missing name=%s"), *SeqEventName.ToString());
            return false;
        }
        for (UEdGraphPin* FirstHopInput : ControllerPin->LinkedTo)
        {
            if (FirstHopInput == nullptr) { continue; }
            bool bAlreadyLinked = false;
            for (UEdGraphPin* ExistingLink : LevelThen->LinkedTo)
            {
                if (ExistingLink == FirstHopInput) { bAlreadyLinked = true; break; }
            }
            if (!bAlreadyLinked)
            {
                if (!Schema->TryCreateConnection(LevelThen, FirstHopInput))
                {
                    LevelThen->MakeLinkTo(FirstHopInput);
                }
            }
        }
        if (LevelThen->LinkedTo.Num() == 0)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR level_seq_event_not_joined name=%s"), *SeqEventName.ToString());
            return false;
        }

        UEdGraphPin* EndpointThen = FindPinByName(Endpoint, UEdGraphSchema_K2::PN_Then, EGPD_Output);
        if (EndpointThen == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR endpoint_then_missing path=%s"), *Endpoint->GetPathName());
            return false;
        }
        if (EndpointThen->LinkedTo.Num() == 0)
        {
            UK2Node_CallFunction* ConsoleCall = NewObject<UK2Node_CallFunction>(SequencerEventsGraph);
            SequencerEventsGraph->AddNode(ConsoleCall, false, false);
            ConsoleCall->CreateNewGuid();
            ConsoleCall->PostPlacedNewNode();
            ConsoleCall->FunctionReference.SetExternalMember(
                ExecuteConsoleCommandFunction->GetFName(),
                UKismetSystemLibrary::StaticClass());
            ConsoleCall->AllocateDefaultPins();
            ConsoleCall->NodePosX = Endpoint->NodePosX + 300;
            ConsoleCall->NodePosY = Endpoint->NodePosY;
            ++TotalCloned;

            UEdGraphPin* ConsoleExec = FindExecPinForRewrite(ConsoleCall, EGPD_Input);
            UEdGraphPin* CommandPin = ConsoleCall->FindPin(TEXT("Command"), EGPD_Input);
            if (ConsoleExec == nullptr || CommandPin == nullptr)
            {
                FString PinNames;
                for (const UEdGraphPin* Pin : ConsoleCall->Pins)
                {
                    if (Pin != nullptr) { PinNames += Pin->PinName.ToString() + TEXT(";"); }
                }
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR execute_console_command_pins_missing pins=%s"), *PinNames);
                return false;
            }

            const FString ConsoleCommand = FString::Printf(TEXT("CE %s"), *SeqEventName.ToString());
            CommandPin->DefaultValue = ConsoleCommand;
            if (!Schema->TryCreateConnection(EndpointThen, ConsoleExec)) { EndpointThen->MakeLinkTo(ConsoleExec); }
        }

        if (EndpointThen->LinkedTo.Num() == 0)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR endpoint_not_wired path=%s"), *Endpoint->GetPathName());
            return false;
        }

        TSharedPtr<FJsonObject> Wired = MakeShared<FJsonObject>();
        Wired->SetNumberField(TEXT("keyIndex"), KeyIndex);
        Wired->SetStringField(TEXT("sourceEventName"), SourceKey.EventName.ToString());
        Wired->SetStringField(TEXT("endpointObjectPath"), Endpoint->GetPathName());
        Wired->SetStringField(TEXT("levelCustomEventName"), SeqEventName.ToString());
        Wired->SetStringField(TEXT("consoleCommand"), FString::Printf(TEXT("CE %s"), *SeqEventName.ToString()));
        Wired->SetNumberField(TEXT("clonedNodeCount"), 2);
        Wired->SetNumberField(TEXT("thenLinkCount"), EndpointThen->LinkedTo.Num());
        WiredEvents.Add(MakeShared<FJsonValueObject>(Wired));
    }

    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(LevelBlueprint);
    FKismetEditorUtilities::CompileBlueprint(LevelBlueprint);
    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(DirectorBlueprint);
    FKismetEditorUtilities::CompileBlueprint(DirectorBlueprint);
    if (LevelBlueprint->Status == BS_Error || DirectorBlueprint->Status == BS_Error)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR event_rewrite_compile_failed level_status=%d director_status=%d"),
            static_cast<int32>(LevelBlueprint->Status),
            static_cast<int32>(DirectorBlueprint->Status)
        );
        return false;
    }

    OutRewriteResult->SetBoolField(TEXT("applied"), true);
    OutRewriteResult->SetStringField(TEXT("strategy"), TEXT("level_custom_event_dual_entry_plus_director_console_event"));
    OutRewriteResult->SetNumberField(TEXT("wiredEventCount"), WiredEvents.Num());
    OutRewriteResult->SetNumberField(TEXT("clonedNodeCount"), TotalCloned);
    OutRewriteResult->SetArrayField(TEXT("wiredEvents"), WiredEvents);
    UE_LOG(LogZenMatineeBridge, Display, TEXT("ZEN_BRIDGE_EVENT_REWRITE wired=%d cloned=%d strategy=console_event"), WiredEvents.Num(), TotalCloned);
    return true;
}


void CopyMatineePlaybackSettingsToSequenceActor(AMatineeActor* SourceActor, ALevelSequenceActor* SequenceActor)
{
    if (SourceActor == nullptr || SequenceActor == nullptr) { return; }
    SequenceActor->Modify();
    SequenceActor->PlaybackSettings.PlayRate = SourceActor->PlayRate;
    SequenceActor->PlaybackSettings.bDisableMovementInput = SourceActor->bDisableMovementInput;
    SequenceActor->PlaybackSettings.bDisableLookAtInput = SourceActor->bDisableLookAtInput;
    SequenceActor->PlaybackSettings.bHidePlayer = SourceActor->bHidePlayer;
    SequenceActor->PlaybackSettings.bHideHud = SourceActor->bHideHud;
    if (SourceActor->bLooping)
    {
        SequenceActor->PlaybackSettings.LoopCount.Value = -1;
    }
    if (SourceActor->bForceStartPos)
    {
        SequenceActor->PlaybackSettings.StartTime = SourceActor->ForceStartPosition;
    }
}

TArray<FString> CaptureLinkedPinIdentities(UEdGraphPin* Pin);
TArray<TSharedPtr<FJsonValue>> StringsToJson(const TArray<FString>& Strings);

bool ApplyPlaybackControlRewrite(
    AMatineeActor* SourceActor,
    ALevelSequenceActor* SequenceActor,
    TSharedPtr<FJsonObject>& OutResult
)
{
    OutResult = MakeShared<FJsonObject>();
    OutResult->SetBoolField(TEXT("applied"), false);
    OutResult->SetNumberField(TEXT("retargetedPlayCount"), 0);
    OutResult->SetNumberField(TEXT("retargetedControlCount"), 0);
    if (SourceActor == nullptr || SequenceActor == nullptr || SourceActor->GetLevel() == nullptr) { return false; }

    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel()->GetLevelScriptBlueprint(true));
    if (LevelBlueprint == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR playback_rewrite_level_bp_missing"));
        return false;
    }

    const UEdGraphSchema_K2* Schema = GetDefault<UEdGraphSchema_K2>();
    UFunction* GetPlayerFunction = ALevelSequenceActor::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ALevelSequenceActor, GetSequencePlayer));
    const TArray<FName> SupportedControlNames = {
        FName(TEXT("Play")),
        FName(TEXT("Pause")),
        FName(TEXT("Stop"))
    };
    TMap<FName, UFunction*> SequenceControlFunctions;
    for (const FName& ControlName : SupportedControlNames)
    {
        UFunction* ControlFunction = ULevelSequencePlayer::StaticClass()->FindFunctionByName(
            ControlName);
        if (ControlFunction == nullptr)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR sequence_control_function_missing function=%s"),
                *ControlName.ToString()
            );
            return false;
        }
        SequenceControlFunctions.Add(ControlName, ControlFunction);
    }
    if (GetPlayerFunction == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequence_player_function_missing"));
        return false;
    }

    const int32 ExpectedControlCount = CapturePlaybackControlCalls(SourceActor).Num();
    if (ExpectedControlCount <= 0)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR playback_rewrite_control_not_found"));
        return false;
    }

    int32 Retargeted = 0;
    int32 RetargetedPlays = 0;
    TMap<FString, int32> RetargetedControlCounts;
    TArray<TSharedPtr<FJsonValue>> Details;
    LevelBlueprint->Modify();

    for (UEdGraph* Graph : LevelBlueprint->UbergraphPages)
    {
        if (Graph == nullptr) { continue; }
        TArray<UEdGraphNode*> Nodes = Graph->Nodes;
        for (UEdGraphNode* Node : Nodes)
        {
            UK2Node_CallFunction* ControlCall = Cast<UK2Node_CallFunction>(Node);
            if (ControlCall == nullptr) { continue; }
            const FName ControlName = ControlCall->GetFunctionName();
            if (!SupportedControlNames.Contains(ControlName)) { continue; }
            UFunction* TargetFunction = ControlCall->GetTargetFunction();
            if (TargetFunction == nullptr || TargetFunction->GetOuterUClass() == nullptr ||
                TargetFunction->GetOuterUClass()->GetName() != TEXT("MatineeActor"))
            {
                continue;
            }

            UEdGraphPin* SelfPin = ControlCall->FindPin(UEdGraphSchema_K2::PN_Self);
            bool bTargetsSource = false;
            if (SelfPin != nullptr)
            {
                for (UEdGraphPin* LinkedPin : SelfPin->LinkedTo)
                {
                    UK2Node_Literal* Literal = LinkedPin != nullptr
                        ? Cast<UK2Node_Literal>(LinkedPin->GetOwningNodeUnchecked()) : nullptr;
                    if (Literal != nullptr && Literal->GetObjectRef() == SourceActor)
                    {
                        bTargetsSource = true;
                        break;
                    }
                }
            }
            if (!bTargetsSource) { continue; }

            Graph->Modify();
            ControlCall->Modify();
            const FString OriginalControlNodePath = ControlCall->GetPathName();
            UFunction* SequenceControlFunction = SequenceControlFunctions.FindRef(ControlName);
            if (SequenceControlFunction == nullptr)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR playback_rewrite_unsupported_control function=%s"),
                    *ControlName.ToString()
                );
                return false;
            }

            UK2Node_Literal* SeqLiteral = NewObject<UK2Node_Literal>(Graph);
            SeqLiteral->CreateNewGuid();
            SeqLiteral->PostPlacedNewNode();
            SeqLiteral->SetObjectRef(SequenceActor);
            SeqLiteral->AllocateDefaultPins();
            SeqLiteral->NodePosX = ControlCall->NodePosX - 350;
            SeqLiteral->NodePosY = ControlCall->NodePosY + 80;
            Graph->AddNode(SeqLiteral, false, false);

            UK2Node_CallFunction* GetPlayerCall = NewObject<UK2Node_CallFunction>(Graph);
            Graph->AddNode(GetPlayerCall, false, false);
            GetPlayerCall->CreateNewGuid();
            GetPlayerCall->PostPlacedNewNode();
            GetPlayerCall->FunctionReference.SetExternalMember(GetPlayerFunction->GetFName(), ALevelSequenceActor::StaticClass());
            GetPlayerCall->AllocateDefaultPins();
            GetPlayerCall->NodePosX = ControlCall->NodePosX - 150;
            GetPlayerCall->NodePosY = ControlCall->NodePosY + 80;

            UK2Node_CallFunction* SeqControlCall = NewObject<UK2Node_CallFunction>(Graph);
            Graph->AddNode(SeqControlCall, false, false);
            SeqControlCall->CreateNewGuid();
            SeqControlCall->PostPlacedNewNode();
            SeqControlCall->FunctionReference.SetExternalMember(
                SequenceControlFunction->GetFName(),
                ULevelSequencePlayer::StaticClass());
            SeqControlCall->AllocateDefaultPins();
            SeqControlCall->NodePosX = ControlCall->NodePosX;
            SeqControlCall->NodePosY = ControlCall->NodePosY + 80;

            UEdGraphPin* LiteralOut = SeqLiteral->Pins.Num() > 0 ? SeqLiteral->Pins[0] : nullptr;
            UEdGraphPin* GetPlayerSelf = GetPlayerCall->FindPin(UEdGraphSchema_K2::PN_Self);
            UEdGraphPin* GetPlayerReturn = GetPlayerCall->GetReturnValuePin();
            UEdGraphPin* SeqControlSelf = SeqControlCall->FindPin(UEdGraphSchema_K2::PN_Self);
            UEdGraphPin* SeqControlExec = SeqControlCall->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* SeqControlThen = SeqControlCall->FindPin(UEdGraphSchema_K2::PN_Then);
            UEdGraphPin* OldExec = ControlCall->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* OldThen = ControlCall->FindPin(UEdGraphSchema_K2::PN_Then);
            if (LiteralOut == nullptr || GetPlayerSelf == nullptr || GetPlayerReturn == nullptr ||
                SeqControlSelf == nullptr || SeqControlExec == nullptr || SeqControlThen == nullptr ||
                OldExec == nullptr || OldThen == nullptr)
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR playback_rewrite_pins_missing"));
                return false;
            }

            const TArray<FString> IncomingBefore = CaptureLinkedPinIdentities(OldExec);
            const TArray<FString> OutgoingBefore = CaptureLinkedPinIdentities(OldThen);
            TArray<UEdGraphPin*> Incoming = OldExec->LinkedTo;
            for (UEdGraphPin* IncomingPin : Incoming)
            {
                IncomingPin->BreakLinkTo(OldExec);
                if (!Schema->TryCreateConnection(IncomingPin, SeqControlExec)) { IncomingPin->MakeLinkTo(SeqControlExec); }
            }
            TArray<UEdGraphPin*> Outgoing = OldThen->LinkedTo;
            for (UEdGraphPin* OutgoingPin : Outgoing)
            {
                OldThen->BreakLinkTo(OutgoingPin);
                if (!Schema->TryCreateConnection(SeqControlThen, OutgoingPin)) { SeqControlThen->MakeLinkTo(OutgoingPin); }
            }
            if (!Schema->TryCreateConnection(LiteralOut, GetPlayerSelf)) { LiteralOut->MakeLinkTo(GetPlayerSelf); }
            if (!Schema->TryCreateConnection(GetPlayerReturn, SeqControlSelf)) { GetPlayerReturn->MakeLinkTo(SeqControlSelf); }

            const TArray<FString> IncomingAfter = CaptureLinkedPinIdentities(SeqControlExec);
            const TArray<FString> OutgoingAfter = CaptureLinkedPinIdentities(SeqControlThen);
            if (IncomingBefore.Num() != 1 || IncomingBefore != IncomingAfter ||
                OutgoingBefore != OutgoingAfter)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR playback_rewrite_exec_links_changed function=%s incoming_before=%d incoming_after=%d outgoing_before=%d outgoing_after=%d"),
                    *ControlName.ToString(),
                    IncomingBefore.Num(),
                    IncomingAfter.Num(),
                    OutgoingBefore.Num(),
                    OutgoingAfter.Num()
                );
                return false;
            }

            if (SelfPin != nullptr) { SelfPin->BreakAllPinLinks(); }
            OldExec->BreakAllPinLinks();
            OldThen->BreakAllPinLinks();
            ControlCall->DestroyNode();

            ++Retargeted;
            RetargetedControlCounts.FindOrAdd(ControlName.ToString())++;
            if (ControlName == FName(TEXT("Play")))
            {
                ++RetargetedPlays;
            }
            TSharedPtr<FJsonObject> Detail = MakeShared<FJsonObject>();
            Detail->SetStringField(TEXT("graphPath"), Graph->GetPathName());
            Detail->SetStringField(TEXT("sequenceActor"), SequenceActor->GetPathName());
            Detail->SetStringField(TEXT("functionName"), ControlName.ToString());
            Detail->SetStringField(TEXT("originalControlNode"), OriginalControlNodePath);
            Detail->SetStringField(TEXT("newControlNode"), SeqControlCall->GetPathName());
            Detail->SetArrayField(TEXT("incomingExecBefore"), StringsToJson(IncomingBefore));
            Detail->SetArrayField(TEXT("incomingExecAfter"), StringsToJson(IncomingAfter));
            Detail->SetArrayField(TEXT("outgoingExecBefore"), StringsToJson(OutgoingBefore));
            Detail->SetArrayField(TEXT("outgoingExecAfter"), StringsToJson(OutgoingAfter));
            if (ControlName == FName(TEXT("Play")))
            {
                Detail->SetStringField(TEXT("newPlayNode"), SeqControlCall->GetPathName());
            }
            Details.Add(MakeShared<FJsonValueObject>(Detail));
        }
    }

    if (Retargeted != ExpectedControlCount)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR playback_rewrite_count_mismatch expected=%d retargeted=%d"),
            ExpectedControlCount,
            Retargeted
        );
        return false;
    }

    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(LevelBlueprint);
    FKismetEditorUtilities::CompileBlueprint(LevelBlueprint);

    OutResult->SetBoolField(TEXT("applied"), true);
    OutResult->SetNumberField(TEXT("retargetedPlayCount"), RetargetedPlays);
    OutResult->SetNumberField(TEXT("retargetedControlCount"), Retargeted);
    OutResult->SetObjectField(TEXT("retargetedControlCounts"), CountsToJson(RetargetedControlCounts));
    OutResult->SetArrayField(TEXT("details"), Details);
    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_PLAYBACK_REWRITE controls=%d plays=%d"),
        Retargeted,
        RetargetedPlays
    );
    return true;
}


TArray<FString> CaptureLinkedPinIdentities(UEdGraphPin* Pin)
{
    TArray<FString> Identities;
    if (Pin == nullptr)
    {
        return Identities;
    }

    for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
    {
        if (LinkedPin == nullptr || LinkedPin->GetOwningNodeUnchecked() == nullptr)
        {
            continue;
        }
        Identities.Add(FString::Printf(
            TEXT("%s:%s:%s"),
            *LinkedPin->GetOwningNode()->GetPathName(),
            *LinkedPin->PinName.ToString(),
            *PinDirectionToString(LinkedPin->Direction)
        ));
    }
    Identities.Sort();
    return Identities;
}

TArray<TSharedPtr<FJsonValue>> StringsToJson(const TArray<FString>& Strings)
{
    TArray<TSharedPtr<FJsonValue>> Values;
    for (const FString& String : Strings)
    {
        Values.Add(MakeShared<FJsonValueString>(String));
    }
    return Values;
}

bool FunctionCallTargetsObject(UK2Node_CallFunction* CallNode, UObject* Target)
{
    if (CallNode == nullptr || Target == nullptr)
    {
        return false;
    }

    UEdGraphPin* SelfPin = CallNode->FindPin(UEdGraphSchema_K2::PN_Self);
    if (SelfPin == nullptr)
    {
        return false;
    }

    for (UEdGraphPin* LinkedPin : SelfPin->LinkedTo)
    {
        UK2Node_Literal* Literal = LinkedPin != nullptr
            ? Cast<UK2Node_Literal>(LinkedPin->GetOwningNodeUnchecked())
            : nullptr;
        if (Literal != nullptr && Literal->GetObjectRef() == Target)
        {
            return true;
        }
    }
    return false;
}

bool HasReachableExecutionEntry(UEdGraphNode* StartNode)
{
    if (StartNode == nullptr)
    {
        return false;
    }

    TSet<UEdGraphNode*> Visited;
    TArray<UEdGraphNode*> Queue;
    Queue.Add(StartNode);
    int32 QueueIndex = 0;
    while (QueueIndex < Queue.Num())
    {
        UEdGraphNode* Node = Queue[QueueIndex++];
        if (Node == nullptr || Visited.Contains(Node))
        {
            continue;
        }
        Visited.Add(Node);

        bool bHasExecInput = false;
        for (UEdGraphPin* Pin : Node->Pins)
        {
            if (Pin == nullptr || Pin->Direction != EGPD_Input ||
                Pin->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
            {
                continue;
            }

            bHasExecInput = true;
            for (UEdGraphPin* LinkedPin : Pin->LinkedTo)
            {
                if (LinkedPin == nullptr || LinkedPin->Direction != EGPD_Output ||
                    LinkedPin->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
                {
                    continue;
                }
                if (UEdGraphNode* UpstreamNode = LinkedPin->GetOwningNodeUnchecked())
                {
                    Queue.Add(UpstreamNode);
                }
            }
        }

        // Blueprint event/controller nodes originate execution and have no
        // execution input pins. An impure node with an unlinked input does not.
        if (!bHasExecInput)
        {
            return true;
        }
    }
    return false;
}

TSharedRef<FJsonObject> CaptureMatineePlaybackControlAudit(
    const TMap<FString, UEdGraph*>& GraphsByPath,
    int32& OutPlayCallCount,
    int32& OutResolvedPlayCallCount,
    int32& OutUnresolvedPlayCallCount,
    int32& OutOtherSelfTargetPlayCallCount,
    int32& OutOtherSelfTargetCallCount
)
{
    OutPlayCallCount = 0;
    OutResolvedPlayCallCount = 0;
    OutUnresolvedPlayCallCount = 0;
    OutOtherSelfTargetPlayCallCount = 0;
    OutOtherSelfTargetCallCount = 0;

    const TArray<FName> ControlNames = {
        FName(TEXT("Play")),
        FName(TEXT("Pause")),
        FName(TEXT("Stop")),
        FName(TEXT("SetPosition")),
        FName(TEXT("Reverse"))
    };
    TMap<FString, int32> ResolvedControlCounts;
    TMap<FString, int32> UnresolvedControlCounts;
    TMap<FString, int32> OtherSelfTargetControlCounts;

    struct FCallRecord
    {
        FString ObjectPath;
        TSharedPtr<FJsonObject> Json;
    };
    TArray<FCallRecord> ResolvedCalls;
    TArray<FCallRecord> UnresolvedCalls;
    TArray<FCallRecord> OtherSelfTargetCalls;

    TArray<FString> GraphPaths;
    GraphsByPath.GetKeys(GraphPaths);
    GraphPaths.Sort();
    for (const FString& GraphPath : GraphPaths)
    {
        UEdGraph* Graph = GraphsByPath.FindChecked(GraphPath);
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node);
            if (CallNode == nullptr || !ControlNames.Contains(CallNode->GetFunctionName()))
            {
                continue;
            }

            UFunction* TargetFunction = CallNode->GetTargetFunction();
            if (TargetFunction == nullptr || TargetFunction->GetOuterUClass() == nullptr ||
                TargetFunction->GetOuterUClass()->GetName() != TEXT("MatineeActor"))
            {
                continue;
            }

            const FString FunctionName = CallNode->GetFunctionName().ToString();
            const bool bIsPlay = CallNode->GetFunctionName() == FName(TEXT("Play"));
            if (bIsPlay)
            {
                ++OutPlayCallCount;
            }

            UEdGraphPin* SelfPin = CallNode->FindPin(UEdGraphSchema_K2::PN_Self);
            int32 SelfLiteralLinkCount = 0;
            int32 ResolvedLiteralLinkCount = 0;
            int32 UnresolvedLiteralLinkCount = 0;
            UK2Node_Literal* SelfLiteral = nullptr;
            if (SelfPin != nullptr)
            {
                for (UEdGraphPin* LinkedPin : SelfPin->LinkedTo)
                {
                    UK2Node_Literal* Literal = LinkedPin != nullptr
                        ? Cast<UK2Node_Literal>(LinkedPin->GetOwningNodeUnchecked())
                        : nullptr;
                    if (Literal == nullptr)
                    {
                        continue;
                    }
                    ++SelfLiteralLinkCount;
                    SelfLiteral = Literal;
                    if (Literal->GetObjectRef() != nullptr)
                    {
                        ++ResolvedLiteralLinkCount;
                    }
                    else
                    {
                        ++UnresolvedLiteralLinkCount;
                    }
                }
            }

            const int32 SelfLinkCount = SelfPin != nullptr ? SelfPin->LinkedTo.Num() : 0;
            const bool bResolvedActorLiteral =
                SelfLinkCount == 1 && SelfLiteralLinkCount == 1 &&
                ResolvedLiteralLinkCount == 1;
            const bool bUnresolvedActorLiteral =
                SelfLinkCount == 1 && SelfLiteralLinkCount == 1 &&
                UnresolvedLiteralLinkCount == 1;

            UEdGraphPin* ExecIn = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* ExecOut = CallNode->FindPin(UEdGraphSchema_K2::PN_Then);
            TSharedPtr<FJsonObject> CallJson = MakeShared<FJsonObject>();
            AddNodeIdentity(CallJson.ToSharedRef(), CallNode);
            CallJson->SetNumberField(TEXT("selfLinkCount"), SelfLinkCount);
            CallJson->SetNumberField(TEXT("selfLiteralLinkCount"), SelfLiteralLinkCount);
            CallJson->SetStringField(
                TEXT("selfLiteralNode"),
                SelfLiteral != nullptr ? SelfLiteral->GetPathName() : FString()
            );
            CallJson->SetStringField(
                TEXT("selfLiteralNodeGuid"),
                SelfLiteral != nullptr ? SelfLiteral->NodeGuid.ToString() : FString()
            );
            CallJson->SetStringField(
                TEXT("selfLiteralReferencedObject"),
                SelfLiteral != nullptr && SelfLiteral->GetObjectRef() != nullptr
                    ? SelfLiteral->GetObjectRef()->GetPathName()
                    : FString()
            );
            CallJson->SetNumberField(
                TEXT("incomingExecCount"),
                ExecIn != nullptr ? ExecIn->LinkedTo.Num() : 0
            );
            CallJson->SetNumberField(
                TEXT("outgoingExecCount"),
                ExecOut != nullptr ? ExecOut->LinkedTo.Num() : 0
            );
            CallJson->SetArrayField(
                TEXT("incomingExec"),
                StringsToJson(CaptureLinkedPinIdentities(ExecIn))
            );
            CallJson->SetArrayField(
                TEXT("outgoingExec"),
                StringsToJson(CaptureLinkedPinIdentities(ExecOut))
            );
            CallJson->SetBoolField(
                TEXT("executionEntryReachable"),
                HasReachableExecutionEntry(CallNode)
            );

            FCallRecord Record;
            Record.ObjectPath = CallNode->GetPathName();
            Record.Json = CallJson;
            if (bResolvedActorLiteral)
            {
                ResolvedControlCounts.FindOrAdd(FunctionName) += 1;
                ResolvedCalls.Add(Record);
                if (bIsPlay)
                {
                    ++OutResolvedPlayCallCount;
                }
            }
            else if (bUnresolvedActorLiteral)
            {
                UnresolvedControlCounts.FindOrAdd(FunctionName) += 1;
                UnresolvedCalls.Add(Record);
                if (bIsPlay)
                {
                    ++OutUnresolvedPlayCallCount;
                }
            }
            else
            {
                OtherSelfTargetControlCounts.FindOrAdd(FunctionName) += 1;
                OtherSelfTargetCalls.Add(Record);
                ++OutOtherSelfTargetCallCount;
                if (bIsPlay)
                {
                    ++OutOtherSelfTargetPlayCallCount;
                }
            }
        }
    }

    const auto SortRecords = [](TArray<FCallRecord>& Records)
    {
        Records.Sort([](const FCallRecord& Left, const FCallRecord& Right)
        {
            return Left.ObjectPath < Right.ObjectPath;
        });
    };
    SortRecords(ResolvedCalls);
    SortRecords(UnresolvedCalls);
    SortRecords(OtherSelfTargetCalls);

    const auto RecordsToJson = [](const TArray<FCallRecord>& Records)
    {
        TArray<TSharedPtr<FJsonValue>> Values;
        for (const FCallRecord& Record : Records)
        {
            Values.Add(MakeShared<FJsonValueObject>(Record.Json));
        }
        return Values;
    };

    TSharedRef<FJsonObject> Audit = MakeShared<FJsonObject>();
    Audit->SetNumberField(
        TEXT("callCount"),
        ResolvedCalls.Num() + UnresolvedCalls.Num() + OtherSelfTargetCalls.Num()
    );
    Audit->SetNumberField(TEXT("playCallCount"), OutPlayCallCount);
    Audit->SetNumberField(TEXT("resolvedActorLiteralCallCount"), ResolvedCalls.Num());
    Audit->SetNumberField(TEXT("unresolvedActorLiteralCallCount"), UnresolvedCalls.Num());
    Audit->SetNumberField(TEXT("otherSelfTargetCallCount"), OtherSelfTargetCalls.Num());
    Audit->SetNumberField(TEXT("resolvedActorLiteralPlayCallCount"), OutResolvedPlayCallCount);
    Audit->SetNumberField(TEXT("unresolvedActorLiteralPlayCallCount"), OutUnresolvedPlayCallCount);
    Audit->SetNumberField(
        TEXT("otherSelfTargetPlayCallCount"),
        OutOtherSelfTargetPlayCallCount
    );
    Audit->SetObjectField(
        TEXT("resolvedActorLiteralControlCounts"),
        CountsToJson(ResolvedControlCounts)
    );
    Audit->SetObjectField(
        TEXT("unresolvedActorLiteralControlCounts"),
        CountsToJson(UnresolvedControlCounts)
    );
    Audit->SetObjectField(
        TEXT("otherSelfTargetControlCounts"),
        CountsToJson(OtherSelfTargetControlCounts)
    );
    Audit->SetArrayField(TEXT("resolvedActorLiteralCalls"), RecordsToJson(ResolvedCalls));
    Audit->SetArrayField(TEXT("unresolvedActorLiteralCalls"), RecordsToJson(UnresolvedCalls));
    Audit->SetArrayField(TEXT("otherSelfTargetCalls"), RecordsToJson(OtherSelfTargetCalls));
    return Audit;
}

bool CaptureSequencePlaybackControlChains(
    const TMap<FString, UEdGraph*>& GraphsByPath,
    ALevelSequenceActor* SequenceActor,
    int32& OutControlCallCount,
    int32& OutValidControlChainCount,
    TMap<FString, int32>& OutControlCounts,
    TMap<FString, int32>& OutValidControlCounts,
    TArray<TSharedPtr<FJsonValue>>& OutControlChains
)
{
    OutControlCallCount = 0;
    OutValidControlChainCount = 0;
    OutControlCounts.Reset();
    OutValidControlCounts.Reset();
    OutControlChains.Reset();
    if (SequenceActor == nullptr)
    {
        return false;
    }

    UFunction* GetPlayerFunction = ALevelSequenceActor::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ALevelSequenceActor, GetSequencePlayer));
    const TArray<FName> ControlNames = {
        FName(TEXT("Play")),
        FName(TEXT("Pause")),
        FName(TEXT("Stop"))
    };
    TMap<UFunction*, FName> ControlNamesByFunction;
    for (const FName& ControlName : ControlNames)
    {
        UFunction* ControlFunction = ULevelSequencePlayer::StaticClass()->FindFunctionByName(
            ControlName);
        if (ControlFunction == nullptr)
        {
            return false;
        }
        ControlNamesByFunction.Add(ControlFunction, ControlName);
    }
    if (GetPlayerFunction == nullptr)
    {
        return false;
    }

    for (const TPair<FString, UEdGraph*>& Pair : GraphsByPath)
    {
        UEdGraph* Graph = Pair.Value;
        if (Graph == nullptr)
        {
            continue;
        }
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node);
            if (CallNode == nullptr)
            {
                continue;
            }
            const FName* ControlName = ControlNamesByFunction.Find(
                CallNode->GetTargetFunction());
            if (ControlName == nullptr)
            {
                continue;
            }

            UEdGraphPin* ControlSelf = CallNode->FindPin(UEdGraphSchema_K2::PN_Self);
            UEdGraphPin* ControlExec = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* ControlThen = CallNode->FindPin(UEdGraphSchema_K2::PN_Then);
            int32 MatchingGetPlayerLinks = 0;
            int32 GetPlayerSelfLinkCount = 0;
            int32 MatchingSequenceActorLiterals = 0;
            FString GetPlayerNodePath;
            FString SequenceActorLiteralPath;
            if (ControlSelf != nullptr)
            {
                for (UEdGraphPin* LinkedPin : ControlSelf->LinkedTo)
                {
                    UK2Node_CallFunction* GetPlayerCall = LinkedPin != nullptr
                        ? Cast<UK2Node_CallFunction>(LinkedPin->GetOwningNodeUnchecked())
                        : nullptr;
                    if (GetPlayerCall == nullptr ||
                        GetPlayerCall->GetTargetFunction() != GetPlayerFunction)
                    {
                        continue;
                    }

                    ++MatchingGetPlayerLinks;
                    GetPlayerNodePath = GetPlayerCall->GetPathName();
                    UEdGraphPin* GetPlayerSelf = GetPlayerCall->FindPin(
                        UEdGraphSchema_K2::PN_Self);
                    GetPlayerSelfLinkCount = GetPlayerSelf != nullptr
                        ? GetPlayerSelf->LinkedTo.Num()
                        : 0;
                    if (GetPlayerSelf == nullptr)
                    {
                        continue;
                    }
                    for (UEdGraphPin* ActorPin : GetPlayerSelf->LinkedTo)
                    {
                        UK2Node_Literal* ActorLiteral = ActorPin != nullptr
                            ? Cast<UK2Node_Literal>(ActorPin->GetOwningNodeUnchecked())
                            : nullptr;
                        if (ActorLiteral != nullptr &&
                            ActorLiteral->GetObjectRef() == SequenceActor)
                        {
                            ++MatchingSequenceActorLiterals;
                            SequenceActorLiteralPath = ActorLiteral->GetPathName();
                        }
                    }
                }
            }

            // Ignore controls belonging to a different generated sequence in
            // the same Level Blueprint. A malformed target chain is caught by
            // comparing this count with the rewrite result.
            if (MatchingSequenceActorLiterals == 0)
            {
                continue;
            }

            const int32 ControlSelfLinkCount = ControlSelf != nullptr
                ? ControlSelf->LinkedTo.Num()
                : 0;
            const int32 IncomingExecCount = ControlExec != nullptr
                ? ControlExec->LinkedTo.Num()
                : 0;
            const int32 OutgoingExecCount = ControlThen != nullptr
                ? ControlThen->LinkedTo.Num()
                : 0;
            const bool bDataChainValid =
                ControlSelfLinkCount == 1 &&
                MatchingGetPlayerLinks == 1 &&
                GetPlayerSelfLinkCount == 1 &&
                MatchingSequenceActorLiterals == 1;
            const bool bExecutionChainValid =
                ControlExec != nullptr &&
                ControlThen != nullptr &&
                IncomingExecCount == 1 &&
                OutgoingExecCount <= 1;
            const FString ControlNameString = ControlName->ToString();
            ++OutControlCallCount;
            OutControlCounts.FindOrAdd(ControlNameString)++;
            if (bDataChainValid && bExecutionChainValid)
            {
                ++OutValidControlChainCount;
                OutValidControlCounts.FindOrAdd(ControlNameString)++;
            }

            TSharedPtr<FJsonObject> ChainJson = MakeShared<FJsonObject>();
            ChainJson->SetStringField(TEXT("graphPath"), Graph->GetPathName());
            ChainJson->SetStringField(TEXT("functionName"), ControlNameString);
            ChainJson->SetStringField(TEXT("controlNode"), CallNode->GetPathName());
            ChainJson->SetStringField(TEXT("playNode"), CallNode->GetPathName());
            ChainJson->SetStringField(TEXT("getSequencePlayerNode"), GetPlayerNodePath);
            ChainJson->SetStringField(TEXT("sequenceActorLiteralNode"), SequenceActorLiteralPath);
            ChainJson->SetNumberField(TEXT("controlSelfLinkCount"), ControlSelfLinkCount);
            ChainJson->SetNumberField(TEXT("playSelfLinkCount"), ControlSelfLinkCount);
            ChainJson->SetNumberField(TEXT("matchingGetSequencePlayerLinks"), MatchingGetPlayerLinks);
            ChainJson->SetNumberField(TEXT("getSequencePlayerSelfLinkCount"), GetPlayerSelfLinkCount);
            ChainJson->SetNumberField(TEXT("matchingSequenceActorLiterals"), MatchingSequenceActorLiterals);
            ChainJson->SetNumberField(TEXT("incomingExecCount"), IncomingExecCount);
            ChainJson->SetNumberField(TEXT("outgoingExecCount"), OutgoingExecCount);
            ChainJson->SetArrayField(
                TEXT("incomingExec"),
                StringsToJson(CaptureLinkedPinIdentities(ControlExec))
            );
            ChainJson->SetArrayField(
                TEXT("outgoingExec"),
                StringsToJson(CaptureLinkedPinIdentities(ControlThen))
            );
            ChainJson->SetBoolField(TEXT("dataChainValid"), bDataChainValid);
            ChainJson->SetBoolField(TEXT("executionChainValid"), bExecutionChainValid);
            OutControlChains.Add(MakeShared<FJsonValueObject>(ChainJson));
        }
    }
    return true;
}

bool CapturePostRewriteLevelBlueprintAudit(
    AMatineeActor* SourceActor,
    ALevelSequenceActor* SequenceActor,
    ULevelSequence* Sequence,
    int32 ExpectedPlaybackControlCount,
    TSharedPtr<FJsonObject>& OutAudit
)
{
    OutAudit = MakeShared<FJsonObject>();
    OutAudit->SetBoolField(TEXT("verified"), false);
    if (SourceActor == nullptr || SequenceActor == nullptr || Sequence == nullptr ||
        SourceActor->GetLevel() == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR post_rewrite_audit_inputs_missing"));
        return false;
    }

    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel()->GetLevelScriptBlueprint(true));
    UBlueprint* DirectorBlueprint = Sequence->GetDirectorBlueprint();
    if (LevelBlueprint == nullptr || DirectorBlueprint == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR post_rewrite_blueprint_missing"));
        return false;
    }

    UEdGraph* ControllerGraph = nullptr;
    UK2Node_MatineeController* Controller = FindMatineeControllerNode(SourceActor, ControllerGraph);
    const TArray<FSourceEventTrackRecord> SourceTracks = GatherSourceEventTracks(SourceActor);
    if (Controller == nullptr || ControllerGraph == nullptr || SourceTracks.Num() != 1)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR post_rewrite_source_event_shape_invalid"));
        return false;
    }

    TMap<FString, UEdGraph*> GraphsByPath;
    for (UEdGraph* Graph : LevelBlueprint->UbergraphPages)
    {
        if (Graph != nullptr)
        {
            GraphsByPath.Add(Graph->GetPathName(), Graph);
        }
    }
    for (UEdGraph* Graph : LevelBlueprint->FunctionGraphs)
    {
        if (Graph != nullptr)
        {
            GraphsByPath.Add(Graph->GetPathName(), Graph);
        }
    }

    TArray<FString> GraphPaths;
    GraphsByPath.GetKeys(GraphPaths);
    GraphPaths.Sort();
    TArray<TSharedPtr<FJsonValue>> GraphValues;
    TArray<UK2Node_CustomEvent*> ZenSeqEvents;
    for (const FString& GraphPath : GraphPaths)
    {
        UEdGraph* Graph = GraphsByPath.FindChecked(GraphPath);
        GraphValues.Add(MakeShared<FJsonValueObject>(CaptureBlueprintGraph(Graph)));
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_CustomEvent* EventNode = Cast<UK2Node_CustomEvent>(Node);
            if (EventNode != nullptr && EventNode->CustomFunctionName.ToString().StartsWith(TEXT("ZenSeq_")))
            {
                ZenSeqEvents.Add(EventNode);
            }
        }
    }

    TSet<FName> ExpectedEventNames;
    TArray<TSharedPtr<FJsonValue>> EventValues;
    bool bAllEventFirstHopsMatch = true;
    for (const FEventTrackKey& SourceKey : SourceTracks[0].Track->EventTrack)
    {
        const FName ExpectedName(*FString::Printf(TEXT("ZenSeq_%s"), *SourceKey.EventName.ToString()));
        ExpectedEventNames.Add(ExpectedName);

        TArray<UK2Node_CustomEvent*> Matches;
        for (UK2Node_CustomEvent* EventNode : ZenSeqEvents)
        {
            if (EventNode != nullptr && EventNode->CustomFunctionName == ExpectedName)
            {
                Matches.Add(EventNode);
            }
        }

        UEdGraphPin* ControllerPin = Controller->FindPin(SourceKey.EventName);
        UK2Node_CustomEvent* EventNode = Matches.Num() == 1 ? Matches[0] : nullptr;
        UEdGraphPin* EventThen = EventNode != nullptr
            ? FindPinByName(EventNode, UEdGraphSchema_K2::PN_Then, EGPD_Output)
            : nullptr;
        const TArray<FString> ControllerFirstHops = CaptureLinkedPinIdentities(ControllerPin);
        const TArray<FString> EventFirstHops = CaptureLinkedPinIdentities(EventThen);
        const bool bFirstHopsMatch =
            EventNode != nullptr &&
            ControllerPin != nullptr &&
            ControllerFirstHops.Num() > 0 &&
            ControllerFirstHops == EventFirstHops;
        bAllEventFirstHopsMatch = bAllEventFirstHopsMatch && bFirstHopsMatch;

        TSharedPtr<FJsonObject> EventJson = MakeShared<FJsonObject>();
        EventJson->SetStringField(TEXT("sourceEventName"), SourceKey.EventName.ToString());
        EventJson->SetStringField(TEXT("customEventName"), ExpectedName.ToString());
        EventJson->SetNumberField(TEXT("matchingCustomEventCount"), Matches.Num());
        EventJson->SetStringField(
            TEXT("eventObjectPath"),
            EventNode != nullptr ? EventNode->GetPathName() : FString()
        );
        EventJson->SetStringField(
            TEXT("graphPath"),
            EventNode != nullptr && EventNode->GetGraph() != nullptr
                ? EventNode->GetGraph()->GetPathName()
                : FString()
        );
        EventJson->SetNumberField(
            TEXT("controllerFirstHopCount"),
            ControllerFirstHops.Num()
        );
        EventJson->SetNumberField(TEXT("customEventFirstHopCount"), EventFirstHops.Num());
        EventJson->SetArrayField(TEXT("controllerFirstHops"), StringsToJson(ControllerFirstHops));
        EventJson->SetArrayField(TEXT("customEventFirstHops"), StringsToJson(EventFirstHops));
        EventJson->SetBoolField(TEXT("firstHopsMatch"), bFirstHopsMatch);
        EventValues.Add(MakeShared<FJsonValueObject>(EventJson));
    }

    UFunction* MatineePlayFunction = AMatineeActor::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(AMatineeActor, Play));
    UFunction* GetPlayerFunction = ALevelSequenceActor::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ALevelSequenceActor, GetSequencePlayer));
    UFunction* SequencePlayFunction = ULevelSequencePlayer::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ULevelSequencePlayer, Play));
    if (MatineePlayFunction == nullptr || GetPlayerFunction == nullptr || SequencePlayFunction == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR post_rewrite_functions_missing"));
        return false;
    }

    int32 MatineePlayCallCount = 0;
    int32 ResolvedMatineePlayCallCount = 0;
    int32 UnresolvedMatineePlayCallCount = 0;
    int32 OtherSelfTargetMatineePlayCallCount = 0;
    int32 OtherSelfTargetMatineeControlCallCount = 0;
    TSharedRef<FJsonObject> MatineePlaybackControlAudit =
        CaptureMatineePlaybackControlAudit(
            GraphsByPath,
            MatineePlayCallCount,
            ResolvedMatineePlayCallCount,
            UnresolvedMatineePlayCallCount,
            OtherSelfTargetMatineePlayCallCount,
            OtherSelfTargetMatineeControlCallCount
        );
    int32 SourceMatineePlayCallCount = 0;
    int32 SequencePlayerPlayCallCount = 0;
    int32 ValidSequencePlaybackChainCount = 0;
    TArray<TSharedPtr<FJsonValue>> PlaybackChains;
    for (const FString& GraphPath : GraphPaths)
    {
        UEdGraph* Graph = GraphsByPath.FindChecked(GraphPath);
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node);
            if (CallNode == nullptr)
            {
                continue;
            }

            UFunction* TargetFunction = CallNode->GetTargetFunction();
            if (TargetFunction == MatineePlayFunction)
            {
                if (FunctionCallTargetsObject(CallNode, SourceActor))
                {
                    ++SourceMatineePlayCallCount;
                }
            }
            if (TargetFunction != SequencePlayFunction)
            {
                continue;
            }

            ++SequencePlayerPlayCallCount;
            UEdGraphPin* PlaySelf = CallNode->FindPin(UEdGraphSchema_K2::PN_Self);
            UEdGraphPin* PlayExec = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* PlayThen = CallNode->FindPin(UEdGraphSchema_K2::PN_Then);
            int32 MatchingGetPlayerLinks = 0;
            int32 GetPlayerSelfLinkCount = 0;
            int32 MatchingSequenceActorLiterals = 0;
            FString GetPlayerNodePath;
            FString SequenceActorLiteralPath;
            if (PlaySelf != nullptr)
            {
                for (UEdGraphPin* LinkedPin : PlaySelf->LinkedTo)
                {
                    UK2Node_CallFunction* GetPlayerCall = LinkedPin != nullptr
                        ? Cast<UK2Node_CallFunction>(LinkedPin->GetOwningNodeUnchecked())
                        : nullptr;
                    if (GetPlayerCall == nullptr || GetPlayerCall->GetTargetFunction() != GetPlayerFunction)
                    {
                        continue;
                    }

                    ++MatchingGetPlayerLinks;
                    GetPlayerNodePath = GetPlayerCall->GetPathName();
                    UEdGraphPin* GetPlayerSelf = GetPlayerCall->FindPin(UEdGraphSchema_K2::PN_Self);
                    GetPlayerSelfLinkCount = GetPlayerSelf != nullptr ? GetPlayerSelf->LinkedTo.Num() : 0;
                    if (GetPlayerSelf == nullptr)
                    {
                        continue;
                    }
                    for (UEdGraphPin* ActorPin : GetPlayerSelf->LinkedTo)
                    {
                        UK2Node_Literal* ActorLiteral = ActorPin != nullptr
                            ? Cast<UK2Node_Literal>(ActorPin->GetOwningNodeUnchecked())
                            : nullptr;
                        if (ActorLiteral != nullptr && ActorLiteral->GetObjectRef() == SequenceActor)
                        {
                            ++MatchingSequenceActorLiterals;
                            SequenceActorLiteralPath = ActorLiteral->GetPathName();
                        }
                    }
                }
            }

            const int32 PlaySelfLinkCount = PlaySelf != nullptr ? PlaySelf->LinkedTo.Num() : 0;
            const int32 IncomingExecCount = PlayExec != nullptr ? PlayExec->LinkedTo.Num() : 0;
            const int32 OutgoingExecCount = PlayThen != nullptr ? PlayThen->LinkedTo.Num() : 0;
            const bool bDataChainValid =
                PlaySelfLinkCount == 1 &&
                MatchingGetPlayerLinks == 1 &&
                GetPlayerSelfLinkCount == 1 &&
                MatchingSequenceActorLiterals == 1;
            const bool bExecutionChainValid = IncomingExecCount == 1 && OutgoingExecCount == 1;
            if (bDataChainValid && bExecutionChainValid)
            {
                ++ValidSequencePlaybackChainCount;
            }

            TSharedPtr<FJsonObject> ChainJson = MakeShared<FJsonObject>();
            ChainJson->SetStringField(TEXT("graphPath"), Graph->GetPathName());
            ChainJson->SetStringField(TEXT("playNode"), CallNode->GetPathName());
            ChainJson->SetStringField(TEXT("getSequencePlayerNode"), GetPlayerNodePath);
            ChainJson->SetStringField(TEXT("sequenceActorLiteralNode"), SequenceActorLiteralPath);
            ChainJson->SetNumberField(TEXT("playSelfLinkCount"), PlaySelfLinkCount);
            ChainJson->SetNumberField(TEXT("matchingGetSequencePlayerLinks"), MatchingGetPlayerLinks);
            ChainJson->SetNumberField(TEXT("getSequencePlayerSelfLinkCount"), GetPlayerSelfLinkCount);
            ChainJson->SetNumberField(TEXT("matchingSequenceActorLiterals"), MatchingSequenceActorLiterals);
            ChainJson->SetNumberField(TEXT("incomingExecCount"), IncomingExecCount);
            ChainJson->SetNumberField(TEXT("outgoingExecCount"), OutgoingExecCount);
            ChainJson->SetArrayField(
                TEXT("incomingExec"),
                StringsToJson(CaptureLinkedPinIdentities(PlayExec))
            );
            ChainJson->SetArrayField(
                TEXT("outgoingExec"),
                StringsToJson(CaptureLinkedPinIdentities(PlayThen))
            );
            ChainJson->SetBoolField(TEXT("dataChainValid"), bDataChainValid);
            ChainJson->SetBoolField(TEXT("executionChainValid"), bExecutionChainValid);
            PlaybackChains.Add(MakeShared<FJsonValueObject>(ChainJson));
        }
    }

    const int32 SourceMatineePlaybackControlCallCount =
        CapturePlaybackControlCalls(SourceActor).Num();
    int32 SequencePlayerControlCallCount = 0;
    int32 ValidSequencePlaybackControlChainCount = 0;
    TMap<FString, int32> SequencePlayerControlCounts;
    TMap<FString, int32> ValidSequencePlaybackControlCounts;
    TArray<TSharedPtr<FJsonValue>> PlaybackControlChains;
    if (!CaptureSequencePlaybackControlChains(
        GraphsByPath,
        SequenceActor,
        SequencePlayerControlCallCount,
        ValidSequencePlaybackControlChainCount,
        SequencePlayerControlCounts,
        ValidSequencePlaybackControlCounts,
        PlaybackControlChains
    ))
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR post_rewrite_control_chain_capture_failed")
        );
        return false;
    }

    const bool bLevelBlueprintHasCompileError = LevelBlueprint->Status == BS_Error;
    const bool bDirectorBlueprintHasCompileError = DirectorBlueprint->Status == BS_Error;
    const bool bVerified =
        !bLevelBlueprintHasCompileError &&
        !bDirectorBlueprintHasCompileError &&
        ExpectedEventNames.Num() == SourceTracks[0].Track->EventTrack.Num() &&
        ZenSeqEvents.Num() == ExpectedEventNames.Num() &&
        EventValues.Num() == ExpectedEventNames.Num() &&
        bAllEventFirstHopsMatch &&
        SourceMatineePlayCallCount == 0 &&
        SourceMatineePlaybackControlCallCount == 0 &&
        OtherSelfTargetMatineeControlCallCount == 0 &&
        SequencePlayerPlayCallCount > 0 &&
        ValidSequencePlaybackChainCount == SequencePlayerPlayCallCount &&
        SequencePlayerControlCallCount == ExpectedPlaybackControlCount &&
        ValidSequencePlaybackControlChainCount == ExpectedPlaybackControlCount;

    OutAudit->SetStringField(TEXT("blueprintPath"), LevelBlueprint->GetPathName());
    OutAudit->SetStringField(TEXT("package"), LevelBlueprint->GetOutermost()->GetName());
    OutAudit->SetNumberField(TEXT("levelBlueprintStatus"), static_cast<int32>(LevelBlueprint->Status));
    OutAudit->SetBoolField(TEXT("levelBlueprintHasCompileError"), bLevelBlueprintHasCompileError);
    OutAudit->SetNumberField(TEXT("directorBlueprintStatus"), static_cast<int32>(DirectorBlueprint->Status));
    OutAudit->SetBoolField(TEXT("directorBlueprintHasCompileError"), bDirectorBlueprintHasCompileError);
    OutAudit->SetNumberField(TEXT("graphCount"), GraphValues.Num());
    OutAudit->SetArrayField(TEXT("graphs"), GraphValues);
    OutAudit->SetNumberField(TEXT("expectedZenSeqCustomEventCount"), ExpectedEventNames.Num());
    OutAudit->SetNumberField(TEXT("zenSeqCustomEventCount"), ZenSeqEvents.Num());
    OutAudit->SetNumberField(TEXT("eventAuditCount"), EventValues.Num());
    OutAudit->SetArrayField(TEXT("events"), EventValues);
    OutAudit->SetBoolField(TEXT("allEventFirstHopsMatch"), bAllEventFirstHopsMatch);
    OutAudit->SetNumberField(TEXT("matineePlayCallCount"), MatineePlayCallCount);
    OutAudit->SetNumberField(
        TEXT("resolvedMatineePlayCallCount"),
        ResolvedMatineePlayCallCount
    );
    OutAudit->SetNumberField(
        TEXT("unresolvedMatineePlayCallCount"),
        UnresolvedMatineePlayCallCount
    );
    OutAudit->SetNumberField(
        TEXT("otherSelfTargetMatineePlayCallCount"),
        OtherSelfTargetMatineePlayCallCount
    );
    OutAudit->SetObjectField(TEXT("matineePlaybackControlAudit"), MatineePlaybackControlAudit);
    OutAudit->SetNumberField(TEXT("sourceMatineePlayCallCount"), SourceMatineePlayCallCount);
    OutAudit->SetNumberField(
        TEXT("sourceMatineePlaybackControlCallCount"),
        SourceMatineePlaybackControlCallCount
    );
    OutAudit->SetNumberField(TEXT("sequencePlayerPlayCallCount"), SequencePlayerPlayCallCount);
    OutAudit->SetNumberField(TEXT("validSequencePlaybackChainCount"), ValidSequencePlaybackChainCount);
    OutAudit->SetArrayField(TEXT("playbackChains"), PlaybackChains);
    OutAudit->SetNumberField(
        TEXT("expectedSequencePlayerControlCallCount"),
        ExpectedPlaybackControlCount
    );
    OutAudit->SetNumberField(
        TEXT("sequencePlayerControlCallCount"),
        SequencePlayerControlCallCount
    );
    OutAudit->SetNumberField(
        TEXT("validSequencePlaybackControlChainCount"),
        ValidSequencePlaybackControlChainCount
    );
    OutAudit->SetObjectField(
        TEXT("sequencePlayerControlCounts"),
        CountsToJson(SequencePlayerControlCounts)
    );
    OutAudit->SetObjectField(
        TEXT("validSequencePlaybackControlCounts"),
        CountsToJson(ValidSequencePlaybackControlCounts)
    );
    OutAudit->SetArrayField(TEXT("playbackControlChains"), PlaybackControlChains);
    OutAudit->SetBoolField(TEXT("verified"), bVerified);

    if (!bVerified)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR post_rewrite_audit_failed expected_events=%d zen_events=%d event_audits=%d first_hops=%d source_controls=%d expected_controls=%d sequence_controls=%d valid_control_chains=%d level_status=%d director_status=%d"),
            ExpectedEventNames.Num(),
            ZenSeqEvents.Num(),
            EventValues.Num(),
            bAllEventFirstHopsMatch ? 1 : 0,
            SourceMatineePlaybackControlCallCount,
            ExpectedPlaybackControlCount,
            SequencePlayerControlCallCount,
            ValidSequencePlaybackControlChainCount,
            static_cast<int32>(LevelBlueprint->Status),
            static_cast<int32>(DirectorBlueprint->Status)
        );
        return false;
    }

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_POST_REWRITE_AUDIT events=%d first_hops=%d source_controls=%d sequence_controls=%d valid_control_chains=%d level_status=%d director_status=%d"),
        ZenSeqEvents.Num(),
        bAllEventFirstHopsMatch ? 1 : 0,
        SourceMatineePlaybackControlCallCount,
        SequencePlayerControlCallCount,
        ValidSequencePlaybackControlChainCount,
        static_cast<int32>(LevelBlueprint->Status),
        static_cast<int32>(DirectorBlueprint->Status)
    );
    return true;
}


bool CaptureSequencePlaybackChainCounts(
    const TMap<FString, UEdGraph*>& GraphsByPath,
    ALevelSequenceActor* SequenceActor,
    int32& OutSequencePlayerPlayCallCount,
    int32& OutValidSequencePlaybackChainCount
)
{
    OutSequencePlayerPlayCallCount = 0;
    OutValidSequencePlaybackChainCount = 0;
    if (SequenceActor == nullptr)
    {
        return false;
    }

    UFunction* GetPlayerFunction = ALevelSequenceActor::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ALevelSequenceActor, GetSequencePlayer));
    UFunction* SequencePlayFunction = ULevelSequencePlayer::StaticClass()->FindFunctionByName(
        GET_FUNCTION_NAME_CHECKED(ULevelSequencePlayer, Play));
    if (GetPlayerFunction == nullptr || SequencePlayFunction == nullptr)
    {
        return false;
    }

    for (const TPair<FString, UEdGraph*>& Pair : GraphsByPath)
    {
        if (Pair.Value == nullptr)
        {
            continue;
        }
        for (UEdGraphNode* Node : Pair.Value->Nodes)
        {
            UK2Node_CallFunction* CallNode = Cast<UK2Node_CallFunction>(Node);
            if (CallNode == nullptr || CallNode->GetTargetFunction() != SequencePlayFunction)
            {
                continue;
            }

            ++OutSequencePlayerPlayCallCount;
            UEdGraphPin* PlaySelf = CallNode->FindPin(UEdGraphSchema_K2::PN_Self);
            UEdGraphPin* PlayExec = CallNode->FindPin(UEdGraphSchema_K2::PN_Execute);
            UEdGraphPin* PlayThen = CallNode->FindPin(UEdGraphSchema_K2::PN_Then);
            int32 MatchingGetPlayerLinks = 0;
            int32 GetPlayerSelfLinkCount = 0;
            int32 MatchingSequenceActorLiterals = 0;
            if (PlaySelf != nullptr)
            {
                for (UEdGraphPin* LinkedPin : PlaySelf->LinkedTo)
                {
                    UK2Node_CallFunction* GetPlayerCall = LinkedPin != nullptr
                        ? Cast<UK2Node_CallFunction>(LinkedPin->GetOwningNodeUnchecked())
                        : nullptr;
                    if (GetPlayerCall == nullptr ||
                        GetPlayerCall->GetTargetFunction() != GetPlayerFunction)
                    {
                        continue;
                    }

                    ++MatchingGetPlayerLinks;
                    UEdGraphPin* GetPlayerSelf = GetPlayerCall->FindPin(
                        UEdGraphSchema_K2::PN_Self);
                    GetPlayerSelfLinkCount = GetPlayerSelf != nullptr
                        ? GetPlayerSelf->LinkedTo.Num()
                        : 0;
                    if (GetPlayerSelf == nullptr)
                    {
                        continue;
                    }
                    for (UEdGraphPin* ActorPin : GetPlayerSelf->LinkedTo)
                    {
                        UK2Node_Literal* ActorLiteral = ActorPin != nullptr
                            ? Cast<UK2Node_Literal>(ActorPin->GetOwningNodeUnchecked())
                            : nullptr;
                        if (ActorLiteral != nullptr &&
                            ActorLiteral->GetObjectRef() == SequenceActor)
                        {
                            ++MatchingSequenceActorLiterals;
                        }
                    }
                }
            }

            const bool bDataChainValid =
                PlaySelf != nullptr &&
                PlaySelf->LinkedTo.Num() == 1 &&
                MatchingGetPlayerLinks == 1 &&
                GetPlayerSelfLinkCount == 1 &&
                MatchingSequenceActorLiterals == 1;
            const bool bExecutionChainValid =
                PlayExec != nullptr &&
                PlayThen != nullptr &&
                PlayExec->LinkedTo.Num() == 1 &&
                PlayThen->LinkedTo.Num() == 1;
            if (bDataChainValid && bExecutionChainValid)
            {
                ++OutValidSequencePlaybackChainCount;
            }
        }
    }
    return true;
}


bool ApplySourceMatineeCleanup(
    AMatineeActor* SourceActor,
    ALevelSequenceActor* SequenceActor,
    int32 ExpectedPlaybackControlCount,
    TSharedPtr<FJsonObject>& OutAudit
)
{
    OutAudit = MakeShared<FJsonObject>();
    OutAudit->SetBoolField(TEXT("requested"), true);
    OutAudit->SetBoolField(TEXT("applied"), false);
    OutAudit->SetBoolField(TEXT("verified"), false);
    if (SourceActor == nullptr || SequenceActor == nullptr || SourceActor->GetLevel() == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_cleanup_inputs_missing"));
        return false;
    }

    UWorld* World = SourceActor->GetWorld();
    ULevelScriptBlueprint* LevelBlueprint = Cast<ULevelScriptBlueprint>(
        SourceActor->GetLevel()->GetLevelScriptBlueprint(true));
    UEdGraph* ControllerGraph = nullptr;
    UK2Node_MatineeController* SourceController = FindMatineeControllerNode(
        SourceActor,
        ControllerGraph
    );
    const TArray<FSourceEventTrackRecord> SourceTracks = GatherSourceEventTracks(SourceActor);
    if (World == nullptr || LevelBlueprint == nullptr || SourceController == nullptr ||
        ControllerGraph == nullptr || SourceTracks.Num() != 1)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_cleanup_shape_invalid"));
        return false;
    }

    const FString SourceActorPath = SourceActor->GetPathName();
    const FString SourceActorLabel = SourceActor->GetActorLabel();
    const FString SourceMap = SourceActor->GetLevel()->GetOutermost()->GetName();
    TMap<FName, TArray<FString>> ExpectedFirstHops;
    TSet<FName> ExpectedCustomEvents;
    for (const FEventTrackKey& SourceKey : SourceTracks[0].Track->EventTrack)
    {
        UEdGraphPin* ControllerPin = SourceController->FindPin(SourceKey.EventName);
        const TArray<FString> FirstHops = CaptureLinkedPinIdentities(ControllerPin);
        if (ControllerPin == nullptr || FirstHops.Num() != 1)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR source_cleanup_first_hop_invalid event=%s links=%d"),
                *SourceKey.EventName.ToString(),
                FirstHops.Num()
            );
            return false;
        }
        const FName CustomEventName(*FString::Printf(
            TEXT("ZenSeq_%s"),
            *SourceKey.EventName.ToString()
        ));
        ExpectedCustomEvents.Add(CustomEventName);
        ExpectedFirstHops.Add(CustomEventName, FirstHops);
    }

    TMap<FString, UEdGraph*> GraphsByPath;
    for (UEdGraph* Graph : LevelBlueprint->UbergraphPages)
    {
        if (Graph != nullptr)
        {
            GraphsByPath.Add(Graph->GetPathName(), Graph);
        }
    }
    for (UEdGraph* Graph : LevelBlueprint->FunctionGraphs)
    {
        if (Graph != nullptr)
        {
            GraphsByPath.Add(Graph->GetPathName(), Graph);
        }
    }

    TArray<UK2Node_MatineeController*> ControllersToRemove;
    TArray<UK2Node_Literal*> LiteralsToRemove;
    for (const TPair<FString, UEdGraph*>& Pair : GraphsByPath)
    {
        UEdGraph* Graph = Pair.Value;
        for (UEdGraphNode* Node : Graph->Nodes)
        {
            if (UK2Node_MatineeController* Controller = Cast<UK2Node_MatineeController>(Node))
            {
                if (Controller->MatineeActor == SourceActor)
                {
                    ControllersToRemove.Add(Controller);
                }
            }
            else if (UK2Node_Literal* Literal = Cast<UK2Node_Literal>(Node))
            {
                if (Literal->GetObjectRef() == SourceActor)
                {
                    LiteralsToRemove.Add(Literal);
                }
            }
        }
    }
    if (ControllersToRemove.Num() != 1 || LiteralsToRemove.Num() <= 0)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_node_count controllers=%d literals=%d"),
            ControllersToRemove.Num(),
            LiteralsToRemove.Num()
        );
        return false;
    }

    int32 SourceActorLiteralLinkCountBeforeRemoval = 0;
    for (UK2Node_Literal* Literal : LiteralsToRemove)
    {
        if (Literal == nullptr)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_cleanup_literal_missing"));
            return false;
        }
        for (UEdGraphPin* Pin : Literal->Pins)
        {
            if (Pin != nullptr)
            {
                SourceActorLiteralLinkCountBeforeRemoval += Pin->LinkedTo.Num();
            }
        }
    }
    if (SourceActorLiteralLinkCountBeforeRemoval != 0)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_literal_connected links=%d"),
            SourceActorLiteralLinkCountBeforeRemoval
        );
        return false;
    }

    LevelBlueprint->Modify();
    for (UK2Node_MatineeController* Controller : ControllersToRemove)
    {
        if (Controller != nullptr)
        {
            Controller->Modify();
            Controller->DestroyNode();
        }
    }
    for (UK2Node_Literal* Literal : LiteralsToRemove)
    {
        if (Literal != nullptr)
        {
            Literal->Modify();
            Literal->DestroyNode();
        }
    }

    FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(LevelBlueprint);
    FKismetEditorUtilities::CompileBlueprint(LevelBlueprint);
    const bool bLevelBlueprintHasCompileError = LevelBlueprint->Status == BS_Error;
    if (bLevelBlueprintHasCompileError)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_compile_failed status=%d"),
            static_cast<int32>(LevelBlueprint->Status)
        );
        return false;
    }

    int32 RemainingTargetControllers = 0;
    int32 RemainingTargetLiterals = 0;
    int32 RemainingMatineePlayCalls = 0;
    int32 RemainingResolvedMatineePlayCalls = 0;
    int32 RemainingUnresolvedMatineePlayCalls = 0;
    int32 RemainingOtherSelfTargetMatineePlayCalls = 0;
    int32 RemainingOtherSelfTargetMatineeControlCalls = 0;
    TSharedRef<FJsonObject> RemainingMatineePlaybackControlAudit =
        CaptureMatineePlaybackControlAudit(
            GraphsByPath,
            RemainingMatineePlayCalls,
            RemainingResolvedMatineePlayCalls,
            RemainingUnresolvedMatineePlayCalls,
            RemainingOtherSelfTargetMatineePlayCalls,
            RemainingOtherSelfTargetMatineeControlCalls
        );
    int32 SequencePlayerPlayCallCount = 0;
    int32 ValidSequencePlaybackChainCount = 0;
    int32 SequencePlayerControlCallCount = 0;
    int32 ValidSequencePlaybackControlChainCount = 0;
    TMap<FString, int32> SequencePlayerControlCounts;
    TMap<FString, int32> ValidSequencePlaybackControlCounts;
    TArray<TSharedPtr<FJsonValue>> PlaybackControlChains;
    int32 VerifiedCustomEvents = 0;
    bool bAllEventFirstHopsPreserved = true;
    TArray<TSharedPtr<FJsonValue>> EventValues;
    for (const FName& CustomEventName : ExpectedCustomEvents)
    {
        TArray<UK2Node_CustomEvent*> Matches;
        for (const TPair<FString, UEdGraph*>& Pair : GraphsByPath)
        {
            for (UEdGraphNode* Node : Pair.Value->Nodes)
            {
                UK2Node_CustomEvent* EventNode = Cast<UK2Node_CustomEvent>(Node);
                if (EventNode != nullptr && EventNode->CustomFunctionName == CustomEventName)
                {
                    Matches.Add(EventNode);
                }
            }
        }

        UK2Node_CustomEvent* EventNode = Matches.Num() == 1 ? Matches[0] : nullptr;
        UEdGraphPin* EventThen = EventNode != nullptr
            ? FindPinByName(EventNode, UEdGraphSchema_K2::PN_Then, EGPD_Output)
            : nullptr;
        const TArray<FString> ActualFirstHops = CaptureLinkedPinIdentities(EventThen);
        const TArray<FString>& ExpectedLinks = ExpectedFirstHops.FindChecked(CustomEventName);
        const bool bFirstHopsPreserved =
            Matches.Num() == 1 &&
            ActualFirstHops == ExpectedLinks;
        if (bFirstHopsPreserved)
        {
            ++VerifiedCustomEvents;
        }
        bAllEventFirstHopsPreserved =
            bAllEventFirstHopsPreserved && bFirstHopsPreserved;

        TSharedPtr<FJsonObject> EventJson = MakeShared<FJsonObject>();
        EventJson->SetStringField(TEXT("customEventName"), CustomEventName.ToString());
        EventJson->SetNumberField(TEXT("matchingCustomEventCount"), Matches.Num());
        EventJson->SetStringField(
            TEXT("eventObjectPath"),
            EventNode != nullptr ? EventNode->GetPathName() : FString()
        );
        EventJson->SetArrayField(TEXT("expectedFirstHops"), StringsToJson(ExpectedLinks));
        EventJson->SetArrayField(TEXT("actualFirstHops"), StringsToJson(ActualFirstHops));
        EventJson->SetBoolField(TEXT("firstHopsPreserved"), bFirstHopsPreserved);
        EventValues.Add(MakeShared<FJsonValueObject>(EventJson));
    }

    for (const TPair<FString, UEdGraph*>& Pair : GraphsByPath)
    {
        for (UEdGraphNode* Node : Pair.Value->Nodes)
        {
            if (UK2Node_MatineeController* Controller = Cast<UK2Node_MatineeController>(Node))
            {
                if (Controller->MatineeActor == SourceActor)
                {
                    ++RemainingTargetControllers;
                }
            }
            else if (UK2Node_Literal* Literal = Cast<UK2Node_Literal>(Node))
            {
                if (Literal->GetObjectRef() == SourceActor)
                {
                    ++RemainingTargetLiterals;
                }
            }
        }
    }
    const int32 RemainingSourceMatineePlaybackControlCalls =
        CapturePlaybackControlCalls(SourceActor).Num();

    SourceActor->Modify();
    if (!World->EditorDestroyActor(SourceActor, true))
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_actor_destroy_failed actor=%s"),
            *SourceActorPath
        );
        return false;
    }

    int32 RemainingWorldActors = 0;
    int32 RemainingMapMatineeActors = 0;
    TArray<TSharedPtr<FJsonValue>> RemainingMapMatineeActorValues;
    for (TActorIterator<AMatineeActor> ActorIt(World); ActorIt; ++ActorIt)
    {
        AMatineeActor* Actor = *ActorIt;
        const FString ActorMap = Actor->GetLevel() != nullptr
            ? Actor->GetLevel()->GetOutermost()->GetName()
            : FString();
        if (ActorMap == SourceMap && Actor->GetActorLabel() == SourceActorLabel)
        {
            ++RemainingWorldActors;
        }
        if (ActorMap == SourceMap)
        {
            ++RemainingMapMatineeActors;
            TSharedPtr<FJsonObject> ActorJson = MakeShared<FJsonObject>();
            ActorJson->SetStringField(TEXT("actor"), Actor->GetActorLabel());
            ActorJson->SetStringField(TEXT("objectPath"), Actor->GetPathName());
            RemainingMapMatineeActorValues.Add(MakeShared<FJsonValueObject>(ActorJson));
        }
    }

    int32 SequenceActorCount = 0;
    for (TActorIterator<ALevelSequenceActor> ActorIt(World); ActorIt; ++ActorIt)
    {
        if (*ActorIt == SequenceActor)
        {
            ++SequenceActorCount;
        }
    }

    if (!CaptureSequencePlaybackChainCounts(
        GraphsByPath,
        SequenceActor,
        SequencePlayerPlayCallCount,
        ValidSequencePlaybackChainCount
    ))
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_sequence_chain_capture_failed")
        );
        return false;
    }
    if (!CaptureSequencePlaybackControlChains(
        GraphsByPath,
        SequenceActor,
        SequencePlayerControlCallCount,
        ValidSequencePlaybackControlChainCount,
        SequencePlayerControlCounts,
        ValidSequencePlaybackControlCounts,
        PlaybackControlChains
    ))
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_control_chain_capture_failed")
        );
        return false;
    }

    TArray<FString> GraphPaths;
    GraphsByPath.GetKeys(GraphPaths);
    GraphPaths.Sort();
    TArray<TSharedPtr<FJsonValue>> GraphValues;
    for (const FString& GraphPath : GraphPaths)
    {
        GraphValues.Add(MakeShared<FJsonValueObject>(
            CaptureBlueprintGraph(GraphsByPath.FindChecked(GraphPath))
        ));
    }

    const bool bVerified =
        ControllersToRemove.Num() == 1 &&
        LiteralsToRemove.Num() > 0 &&
        SourceActorLiteralLinkCountBeforeRemoval == 0 &&
        RemainingTargetControllers == 0 &&
        RemainingTargetLiterals == 0 &&
        RemainingSourceMatineePlaybackControlCalls == 0 &&
        RemainingOtherSelfTargetMatineeControlCalls == 0 &&
        SequencePlayerControlCallCount == ExpectedPlaybackControlCount &&
        ValidSequencePlaybackControlChainCount == ExpectedPlaybackControlCount &&
        RemainingWorldActors == 0 &&
        SequenceActorCount == 1 &&
        VerifiedCustomEvents == ExpectedCustomEvents.Num() &&
        bAllEventFirstHopsPreserved &&
        !bLevelBlueprintHasCompileError;

    OutAudit->SetStringField(TEXT("sourceActorPath"), SourceActorPath);
    OutAudit->SetNumberField(TEXT("controllersRemoved"), ControllersToRemove.Num());
    OutAudit->SetNumberField(TEXT("sourceActorLiteralsRemoved"), LiteralsToRemove.Num());
    OutAudit->SetNumberField(
        TEXT("sourceActorLiteralLinkCountBeforeRemoval"),
        SourceActorLiteralLinkCountBeforeRemoval
    );
    OutAudit->SetNumberField(TEXT("remainingTargetControllerCount"), RemainingTargetControllers);
    OutAudit->SetNumberField(TEXT("remainingTargetLiteralCount"), RemainingTargetLiterals);
    OutAudit->SetNumberField(TEXT("remainingMatineePlayCallCount"), RemainingMatineePlayCalls);
    OutAudit->SetNumberField(
        TEXT("remainingResolvedMatineePlayCallCount"),
        RemainingResolvedMatineePlayCalls
    );
    OutAudit->SetNumberField(
        TEXT("remainingUnresolvedMatineePlayCallCount"),
        RemainingUnresolvedMatineePlayCalls
    );
    OutAudit->SetNumberField(
        TEXT("remainingOtherSelfTargetMatineePlayCallCount"),
        RemainingOtherSelfTargetMatineePlayCalls
    );
    OutAudit->SetObjectField(
        TEXT("remainingMatineePlaybackControlAudit"),
        RemainingMatineePlaybackControlAudit
    );
    OutAudit->SetNumberField(
        TEXT("remainingSourceMatineePlaybackControlCallCount"),
        RemainingSourceMatineePlaybackControlCalls
    );
    OutAudit->SetNumberField(TEXT("sequencePlayerPlayCallCount"), SequencePlayerPlayCallCount);
    OutAudit->SetNumberField(
        TEXT("validSequencePlaybackChainCount"),
        ValidSequencePlaybackChainCount
    );
    OutAudit->SetNumberField(
        TEXT("expectedSequencePlayerControlCallCount"),
        ExpectedPlaybackControlCount
    );
    OutAudit->SetNumberField(
        TEXT("sequencePlayerControlCallCount"),
        SequencePlayerControlCallCount
    );
    OutAudit->SetNumberField(
        TEXT("validSequencePlaybackControlChainCount"),
        ValidSequencePlaybackControlChainCount
    );
    OutAudit->SetObjectField(
        TEXT("sequencePlayerControlCounts"),
        CountsToJson(SequencePlayerControlCounts)
    );
    OutAudit->SetObjectField(
        TEXT("validSequencePlaybackControlCounts"),
        CountsToJson(ValidSequencePlaybackControlCounts)
    );
    OutAudit->SetArrayField(TEXT("playbackControlChains"), PlaybackControlChains);
    OutAudit->SetNumberField(TEXT("remainingWorldActorCount"), RemainingWorldActors);
    OutAudit->SetNumberField(
        TEXT("remainingMapMatineeActorCount"),
        RemainingMapMatineeActors
    );
    OutAudit->SetArrayField(
        TEXT("remainingMapMatineeActors"),
        RemainingMapMatineeActorValues
    );
    OutAudit->SetNumberField(TEXT("sequenceActorCount"), SequenceActorCount);
    OutAudit->SetNumberField(TEXT("expectedCustomEventCount"), ExpectedCustomEvents.Num());
    OutAudit->SetNumberField(TEXT("verifiedCustomEventCount"), VerifiedCustomEvents);
    OutAudit->SetNumberField(TEXT("eventAuditCount"), EventValues.Num());
    OutAudit->SetArrayField(TEXT("events"), EventValues);
    OutAudit->SetBoolField(TEXT("allEventFirstHopsPreserved"), bAllEventFirstHopsPreserved);
    OutAudit->SetNumberField(TEXT("levelBlueprintStatus"), static_cast<int32>(LevelBlueprint->Status));
    OutAudit->SetBoolField(TEXT("levelBlueprintHasCompileError"), bLevelBlueprintHasCompileError);
    OutAudit->SetNumberField(TEXT("graphCount"), GraphValues.Num());
    OutAudit->SetArrayField(TEXT("graphs"), GraphValues);
    OutAudit->SetBoolField(TEXT("applied"), true);
    OutAudit->SetBoolField(TEXT("verified"), bVerified);

    if (!bVerified)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR source_cleanup_audit_failed controllers=%d literals=%d literal_links=%d source_controls=%d expected_controls=%d sequence_controls=%d valid_control_chains=%d world_actors=%d sequence_actors=%d events=%d first_hops=%d status=%d"),
            RemainingTargetControllers,
            RemainingTargetLiterals,
            SourceActorLiteralLinkCountBeforeRemoval,
            RemainingSourceMatineePlaybackControlCalls,
            ExpectedPlaybackControlCount,
            SequencePlayerControlCallCount,
            ValidSequencePlaybackControlChainCount,
            RemainingWorldActors,
            SequenceActorCount,
            VerifiedCustomEvents,
            bAllEventFirstHopsPreserved ? 1 : 0,
            static_cast<int32>(LevelBlueprint->Status)
        );
        return false;
    }

    World->MarkPackageDirty();
    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_SOURCE_CLEANUP controllers_removed=%d literals_removed=%d literal_links=%d sequence_controls=%d valid_control_chains=%d world_actors=%d map_matinees=%d sequence_actors=%d events=%d first_hops=%d status=%d"),
        ControllersToRemove.Num(),
        LiteralsToRemove.Num(),
        SourceActorLiteralLinkCountBeforeRemoval,
        SequencePlayerControlCallCount,
        ValidSequencePlaybackControlChainCount,
        RemainingWorldActors,
        RemainingMapMatineeActors,
        SequenceActorCount,
        VerifiedCustomEvents,
        bAllEventFirstHopsPreserved ? 1 : 0,
        static_cast<int32>(LevelBlueprint->Status)
    );
    return true;
}


bool SaveGeneratedSequencePackage(ULevelSequence* Sequence, FString& OutFilename)
{
    if (Sequence == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequence_save_object_missing"));
        return false;
    }

    UPackage* SequencePackage = Sequence->GetOutermost();
    if (SequencePackage == nullptr)
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR sequence_save_package_missing"));
        return false;
    }

    OutFilename = FPackageName::LongPackageNameToFilename(
        SequencePackage->GetName(),
        FPackageName::GetAssetPackageExtension()
    );
    SequencePackage->MarkPackageDirty();
    FSaveErrorCapture SaveErrors;
    const bool bSaved = UPackage::SavePackage(
        SequencePackage,
        Sequence,
        RF_Public | RF_Standalone,
        *OutFilename,
        &SaveErrors,
        nullptr,
        false,
        true,
        SAVE_None
    );
    if (!bSaved || SaveErrors.HasErrors())
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR sequence_save_failed package=%s filename=%s details=%s"),
            *SequencePackage->GetName(),
            *OutFilename,
            *SaveErrors.JoinErrors()
        );
        return false;
    }

    const int64 SavedBytes = IFileManager::Get().FileSize(*OutFilename);
    if (SavedBytes <= 0)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR sequence_file_missing package=%s filename=%s"),
            *SequencePackage->GetName(),
            *OutFilename
        );
        return false;
    }

    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_SEQUENCE_SAVED package=%s filename=%s bytes=%lld"),
        *SequencePackage->GetName(),
        *OutFilename,
        SavedBytes
    );
    return true;
}


bool CaptureGeneratedSequenceAudit(
    AMatineeActor* SourceActor,
    ALevelSequenceActor* SequenceActor,
    ULevelSequence* Sequence,
    const TArray<TSharedPtr<FJsonValue>>& SourcePlaybackControlCalls,
    TSharedPtr<FJsonObject>& OutAudit
)
{
    const TArray<FSourceEventTrackRecord> SourceTracks = GatherSourceEventTracks(SourceActor);
    TArray<UMovieSceneEventTrack*> TargetTracks;
    for (UMovieSceneTrack* Track : Sequence->GetMovieScene()->GetMasterTracks())
    {
        if (UMovieSceneEventTrack* EventTrack = Cast<UMovieSceneEventTrack>(Track))
        {
            TargetTracks.Add(EventTrack);
        }
    }

    if (SourceTracks.Num() != TargetTracks.Num())
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR event_track_count_mismatch actor=%s source=%d target=%d"),
            *SourceActor->GetActorLabel(),
            SourceTracks.Num(),
            TargetTracks.Num()
        );
        return false;
    }

    TSharedPtr<FJsonObject> Audit = MakeShared<FJsonObject>();
    Audit->SetStringField(TEXT("sourceActor"), SourceActor->GetPathName());
    Audit->SetStringField(TEXT("sequence"), Sequence->GetPathName());
    Audit->SetObjectField(TEXT("levelSequenceActor"), CaptureLevelSequenceActorAudit(SequenceActor));
    Audit->SetNumberField(TEXT("sourceEventTrackCount"), SourceTracks.Num());
    Audit->SetNumberField(TEXT("targetEventTrackCount"), TargetTracks.Num());

    const FFrameRate TickResolution = Sequence->GetMovieScene()->GetTickResolution();
    Audit->SetNumberField(TEXT("tickResolutionNumerator"), TickResolution.Numerator);
    Audit->SetNumberField(TEXT("tickResolutionDenominator"), TickResolution.Denominator);

    TArray<TSharedPtr<FJsonValue>> EventTrackValues;
    int32 TotalEventKeys = 0;
    TSet<FString> UniqueEndpoints;
    for (int32 EventTrackIndex = 0; EventTrackIndex < SourceTracks.Num(); ++EventTrackIndex)
    {
        const FSourceEventTrackRecord& SourceRecord = SourceTracks[EventTrackIndex];
        UMovieSceneEventTrack* TargetTrack = TargetTracks[EventTrackIndex];
        const TArray<UMovieSceneSection*>& Sections = TargetTrack->GetAllSections();
        if (Sections.Num() != 1)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR event_section_count_mismatch actor=%s track=%d sections=%d"),
                *SourceActor->GetActorLabel(),
                EventTrackIndex,
                Sections.Num()
            );
            return false;
        }

        const UMovieSceneEventTriggerSection* TriggerSection =
            Cast<UMovieSceneEventTriggerSection>(Sections[0]);
        if (TriggerSection == nullptr)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR event_trigger_section_missing actor=%s track=%d"),
                *SourceActor->GetActorLabel(),
                EventTrackIndex
            );
            return false;
        }

        const TMovieSceneChannelData<const FMovieSceneEvent> ChannelData =
            TriggerSection->EventChannel.GetData();
        const TArrayView<const FFrameNumber> Times = ChannelData.GetTimes();
        const TArrayView<const FMovieSceneEvent> Events = ChannelData.GetValues();
        if (Times.Num() != Events.Num() || Events.Num() != SourceRecord.Track->EventTrack.Num())
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR event_key_count_mismatch actor=%s track=%d source=%d times=%d events=%d"),
                *SourceActor->GetActorLabel(),
                EventTrackIndex,
                SourceRecord.Track->EventTrack.Num(),
                Times.Num(),
                Events.Num()
            );
            return false;
        }

        TMap<FName, FString> EndpointBySourceEvent;
        TMap<FString, FName> SourceEventByEndpoint;
        TArray<TSharedPtr<FJsonValue>> KeyValues;
        for (int32 KeyIndex = 0; KeyIndex < Events.Num(); ++KeyIndex)
        {
            const FEventTrackKey& SourceKey = SourceRecord.Track->EventTrack[KeyIndex];
            const FFrameNumber ExpectedFrame = (SourceKey.Time * TickResolution).RoundToFrame();
            if (Times[KeyIndex] != ExpectedFrame)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR event_time_mismatch actor=%s track=%d key=%d expected=%d actual=%d"),
                    *SourceActor->GetActorLabel(),
                    EventTrackIndex,
                    KeyIndex,
                    ExpectedFrame.Value,
                    Times[KeyIndex].Value
                );
                return false;
            }

            UObject* Endpoint = Events[KeyIndex].WeakEndpoint.Get();
            if (Endpoint == nullptr)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR event_endpoint_missing actor=%s track=%d key=%d"),
                    *SourceActor->GetActorLabel(),
                    EventTrackIndex,
                    KeyIndex
                );
                return false;
            }

            const FString EndpointPath = Endpoint->GetPathName();
            if (const FString* ExistingEndpoint = EndpointBySourceEvent.Find(SourceKey.EventName))
            {
                if (*ExistingEndpoint != EndpointPath)
                {
                    UE_LOG(
                        LogZenMatineeBridge,
                        Error,
                        TEXT("ZEN_BRIDGE_ERROR source_event_endpoint_changed actor=%s event=%s"),
                        *SourceActor->GetActorLabel(),
                        *SourceKey.EventName.ToString()
                    );
                    return false;
                }
            }
            else
            {
                EndpointBySourceEvent.Add(SourceKey.EventName, EndpointPath);
            }

            if (const FName* ExistingSourceEvent = SourceEventByEndpoint.Find(EndpointPath))
            {
                if (*ExistingSourceEvent != SourceKey.EventName)
                {
                    UE_LOG(
                        LogZenMatineeBridge,
                        Error,
                        TEXT("ZEN_BRIDGE_ERROR endpoint_shared_by_source_events actor=%s endpoint=%s"),
                        *SourceActor->GetActorLabel(),
                        *EndpointPath
                    );
                    return false;
                }
            }
            else
            {
                SourceEventByEndpoint.Add(EndpointPath, SourceKey.EventName);
            }
            UniqueEndpoints.Add(EndpointPath);

            TSharedPtr<FJsonObject> KeyJson = MakeShared<FJsonObject>();
            KeyJson->SetNumberField(TEXT("keyIndex"), KeyIndex);
            KeyJson->SetStringField(TEXT("sourceEventName"), SourceKey.EventName.ToString());
            KeyJson->SetNumberField(TEXT("sourceTimeSeconds"), SourceKey.Time);
            KeyJson->SetNumberField(TEXT("expectedFrameNumber"), ExpectedFrame.Value);
            KeyJson->SetNumberField(TEXT("frameNumber"), Times[KeyIndex].Value);
            KeyJson->SetStringField(TEXT("endpointClass"), Endpoint->GetClass()->GetName());
            KeyJson->SetStringField(TEXT("endpointObjectPath"), EndpointPath);
            KeyJson->SetStringField(
                TEXT("compiledFunctionName"),
                Events[KeyIndex].CompiledFunctionName.ToString()
            );
            KeyJson->SetStringField(
                TEXT("boundObjectPinName"),
                Events[KeyIndex].BoundObjectPinName.ToString()
            );
            KeyJson->SetStringField(
                TEXT("runtimeFunctionPath"),
                Events[KeyIndex].Ptrs.Function != nullptr
                    ? Events[KeyIndex].Ptrs.Function->GetPathName()
                    : FString()
            );
            KeyValues.Add(MakeShared<FJsonValueObject>(KeyJson));
        }

        TSharedPtr<FJsonObject> TrackJson = MakeShared<FJsonObject>();
        TrackJson->SetNumberField(TEXT("eventTrackIndex"), EventTrackIndex);
        TrackJson->SetStringField(TEXT("sourceGroupName"), SourceRecord.Group->GroupName.ToString());
        TrackJson->SetStringField(TEXT("sourceTrackPath"), SourceRecord.Track->GetPathName());
        TrackJson->SetStringField(TEXT("targetTrackPath"), TargetTrack->GetPathName());
        TrackJson->SetStringField(TEXT("targetDisplayName"), TargetTrack->GetDisplayName().ToString());
        TrackJson->SetBoolField(TEXT("sourceFireForwards"), SourceRecord.Track->bFireEventsWhenForwards != 0);
        TrackJson->SetBoolField(TEXT("sourceFireBackwards"), SourceRecord.Track->bFireEventsWhenBackwards != 0);
        TrackJson->SetBoolField(
            TEXT("sourceFireWhenJumpingForwards"),
            SourceRecord.Track->bFireEventsWhenJumpingForwards != 0
        );
        TrackJson->SetBoolField(
            TEXT("sourceUseCustomEventName"),
            SourceRecord.Track->bUseCustomEventName != 0
        );
        TrackJson->SetBoolField(TEXT("targetFireForwards"), TargetTrack->bFireEventsWhenForwards != 0);
        TrackJson->SetBoolField(TEXT("targetFireBackwards"), TargetTrack->bFireEventsWhenBackwards != 0);
        TrackJson->SetNumberField(TEXT("keyCount"), KeyValues.Num());
        TrackJson->SetArrayField(TEXT("keys"), KeyValues);
        EventTrackValues.Add(MakeShared<FJsonValueObject>(TrackJson));
        TotalEventKeys += KeyValues.Num();
    }
    Audit->SetNumberField(TEXT("eventKeyCount"), TotalEventKeys);
    Audit->SetNumberField(TEXT("uniqueEndpointCount"), UniqueEndpoints.Num());
    Audit->SetArrayField(TEXT("eventTracks"), EventTrackValues);

    UBlueprint* DirectorBlueprint = Sequence->GetDirectorBlueprint();
    if (SourceTracks.Num() > 0 && DirectorBlueprint == nullptr)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR director_blueprint_missing actor=%s"),
            *SourceActor->GetActorLabel()
        );
        return false;
    }

    if (DirectorBlueprint != nullptr)
    {
        TSharedPtr<FJsonObject> DirectorJson = MakeShared<FJsonObject>();
        DirectorJson->SetStringField(TEXT("blueprintPath"), DirectorBlueprint->GetPathName());

        TMap<FString, UEdGraph*> DirectorGraphsByPath;
        for (UEdGraph* Graph : DirectorBlueprint->UbergraphPages)
        {
            if (Graph != nullptr)
            {
                DirectorGraphsByPath.Add(Graph->GetPathName(), Graph);
            }
        }
        for (UEdGraph* Graph : DirectorBlueprint->FunctionGraphs)
        {
            if (Graph != nullptr)
            {
                DirectorGraphsByPath.Add(Graph->GetPathName(), Graph);
            }
        }

        TArray<FString> DirectorGraphPaths;
        DirectorGraphsByPath.GetKeys(DirectorGraphPaths);
        DirectorGraphPaths.Sort();
        TArray<TSharedPtr<FJsonValue>> DirectorGraphValues;
        for (const FString& GraphPath : DirectorGraphPaths)
        {
            DirectorGraphValues.Add(MakeShared<FJsonValueObject>(
                CaptureBlueprintGraph(DirectorGraphsByPath.FindChecked(GraphPath))
            ));
        }
        DirectorJson->SetNumberField(TEXT("graphCount"), DirectorGraphValues.Num());
        DirectorJson->SetArrayField(TEXT("graphs"), DirectorGraphValues);
        Audit->SetObjectField(TEXT("directorBlueprint"), DirectorJson);
    }

    TSharedPtr<FJsonObject> RewritePlan = MakeShared<FJsonObject>();
    RewritePlan->SetStringField(
        TEXT("endpointInvocationModel"),
        TEXT("sequence_director_custom_event_only")
    );
    RewritePlan->SetBoolField(TEXT("endpointsInvokeLevelBlueprintDirectly"), false);
    RewritePlan->SetStringField(
        TEXT("engineBasis"),
        TEXT("UE 4.27 CopyInterpEventTrack creates empty MatineeEvent endpoints in the Sequence Director; MovieSceneEventUtils binds those endpoints only inside the director blueprint.")
    );
    RewritePlan->SetArrayField(TEXT("playbackControlCalls"), SourcePlaybackControlCalls);

    UEdGraph* ControllerGraph = nullptr;
    UK2Node_MatineeController* Controller = FindMatineeControllerNode(SourceActor, ControllerGraph);
    TArray<TSharedPtr<FJsonValue>> EventPlans;
    if (Controller == nullptr)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR matinee_controller_missing actor=%s"),
            *SourceActor->GetActorLabel()
        );
        return false;
    }

    RewritePlan->SetStringField(TEXT("controllerObjectPath"), Controller->GetPathName());
    RewritePlan->SetStringField(
        TEXT("controllerGraphPath"),
        ControllerGraph != nullptr ? ControllerGraph->GetPathName() : FString()
    );

    for (const TSharedPtr<FJsonValue>& TrackValue : EventTrackValues)
    {
        const TSharedPtr<FJsonObject> TrackJson = TrackValue->AsObject();
        const TArray<TSharedPtr<FJsonValue>>* KeyValues = nullptr;
        if (!TrackJson->TryGetArrayField(TEXT("keys"), KeyValues) || KeyValues == nullptr)
        {
            continue;
        }
        for (const TSharedPtr<FJsonValue>& KeyValue : *KeyValues)
        {
            const TSharedPtr<FJsonObject> KeyJson = KeyValue->AsObject();
            const FString SourceEventName = KeyJson->GetStringField(TEXT("sourceEventName"));
            UEdGraphPin* EventPin = Controller->FindPin(FName(*SourceEventName));
            if (EventPin == nullptr)
            {
                UE_LOG(
                    LogZenMatineeBridge,
                    Error,
                    TEXT("ZEN_BRIDGE_ERROR controller_event_pin_missing actor=%s event=%s"),
                    *SourceActor->GetActorLabel(),
                    *SourceEventName
                );
                return false;
            }

            TSharedPtr<FJsonObject> PlanJson = MakeShared<FJsonObject>();
            PlanJson->SetNumberField(TEXT("keyIndex"), KeyJson->GetNumberField(TEXT("keyIndex")));
            PlanJson->SetStringField(TEXT("sourceEventName"), SourceEventName);
            PlanJson->SetStringField(
                TEXT("endpointObjectPath"),
                KeyJson->GetStringField(TEXT("endpointObjectPath"))
            );
            PlanJson->SetNumberField(TEXT("frameNumber"), KeyJson->GetNumberField(TEXT("frameNumber")));
            PlanJson->SetStringField(TEXT("controllerPinName"), EventPin->PinName.ToString());
            PlanJson->SetNumberField(TEXT("controllerPinLinkCount"), EventPin->LinkedTo.Num());
            PlanJson->SetArrayField(TEXT("execClosure"), CaptureExecClosure(EventPin));
            EventPlans.Add(MakeShared<FJsonValueObject>(PlanJson));
        }
    }
    RewritePlan->SetNumberField(TEXT("eventPlanCount"), EventPlans.Num());
    RewritePlan->SetArrayField(TEXT("eventPlans"), EventPlans);
    Audit->SetObjectField(TEXT("eventRewritePlan"), RewritePlan);

    Audit->SetBoolField(TEXT("mappingVerified"), true);
    OutAudit = Audit;
    UE_LOG(
        LogZenMatineeBridge,
        Display,
        TEXT("ZEN_BRIDGE_EVENT_MAPPING actor=%s tracks=%d keys=%d endpoints=%d"),
        *SourceActor->GetActorLabel(),
        SourceTracks.Num(),
        TotalEventKeys,
        UniqueEndpoints.Num()
    );
    return true;
}

TSharedRef<FJsonObject> CaptureReferenceContext(
    AMatineeActor* Actor,
    const FString& LoadedMap,
    TMap<FString, TSharedPtr<FJsonObject>>& BlueprintGraphsByPath
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
        TSharedPtr<FJsonObject> BlueprintNode;
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
        if (UEdGraphNode* GraphNode = Cast<UEdGraphNode>(Referencer))
        {
            Record.BlueprintNode = CaptureBlueprintNode(GraphNode);
            if (UEdGraph* Graph = GraphNode->GetGraph())
            {
                const FString GraphPath = Graph->GetPathName();
                if (!BlueprintGraphsByPath.Contains(GraphPath))
                {
                    TSharedPtr<FJsonObject> GraphJson = CaptureBlueprintGraph(Graph);
                    UE_LOG(
                        LogZenMatineeBridge,
                        Display,
                        TEXT("ZEN_BRIDGE_BLUEPRINT_GRAPH path=%s nodes=%d"),
                        *GraphPath,
                        GraphJson->GetIntegerField(TEXT("nodeCount"))
                    );
                    BlueprintGraphsByPath.Add(GraphPath, GraphJson);
                }
            }
        }
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
        if (Record.BlueprintNode.IsValid())
        {
            ReferencerJson->SetObjectField(TEXT("blueprintNode"), Record.BlueprintNode);
        }
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
    FString RequiredSourceTrackList =
        TEXT("InterpTrackDirector,InterpTrackFade,InterpTrackSound,InterpTrackEvent,InterpTrackToggle");
    FString RequiredSequenceTrackList =
        TEXT("MovieSceneCameraCutTrack,MovieSceneFadeTrack,MovieSceneAudioTrack,MovieSceneEventTrack,MovieSceneParticleTrack");
    FString ReportName = TEXT("ue427-bridge-report.json");
    int32 ExpectedMatinees = 1;
    const int32 ExpectedConversions = 1;
    const bool bRemoveSourceMatinee = FParse::Param(*Params, TEXT("RemoveSourceMatinee"));
    FParse::Value(*Params, TEXT("TargetMap="), TargetMap);
    FParse::Value(*Params, TEXT("ExpectedActor="), ExpectedActor);
    FParse::Value(*Params, TEXT("ExpectedMatinees="), ExpectedMatinees);
    FParse::Value(*Params, TEXT("RequiredSourceTracks="), RequiredSourceTrackList, false);
    FParse::Value(*Params, TEXT("RequiredSequenceTracks="), RequiredSequenceTrackList, false);
    FParse::Value(*Params, TEXT("ReportName="), ReportName);

    TArray<FString> RequiredSourceTracks;
    TArray<FString> RequiredSequenceTracks;
    RequiredSourceTrackList.ParseIntoArray(RequiredSourceTracks, TEXT(","), true);
    RequiredSequenceTrackList.ParseIntoArray(RequiredSequenceTracks, TEXT(","), true);
    RequiredSourceTracks.Sort();
    RequiredSequenceTracks.Sort();
    if (ExpectedMatinees <= 0 || RequiredSourceTracks.Num() == 0 ||
        RequiredSequenceTracks.Num() == 0 ||
        FPaths::GetCleanFilename(ReportName) != ReportName ||
        !ReportName.EndsWith(TEXT(".json")))
    {
        UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR invalid_commandlet_contract"));
        return 9;
    }

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

    int32 ConvertedMaps = 0;
    int32 MatineesFound = 0;
    int32 UniqueMatineesDiscovered = 0;
    int32 MatineesConverted = 0;
    int32 MatineesRetained = 0;
    int32 MatineesRemoved = 0;
    int32 ConversionWarnings = 0;
    int32 KnownConversionWarnings = 0;
    int32 UnexpectedConversionWarnings = 0;
    bool bFoundExpectedActor = false;
    TMap<FString, int32> SourceTrackCounts;
    TMap<FString, int32> SourceTrackKeyCounts;
    TMap<FString, int32> SequenceTrackCounts;
    TSet<FString> InventoriedActors;
    TMap<FString, TSharedPtr<FJsonObject>> InventoryEntriesByActor;
    TMap<FString, TArray<TSharedPtr<FJsonValue>>> ReferenceContextsByActor;
    TMap<FString, TSharedPtr<FJsonObject>> BlueprintGraphsByPath;
    TArray<TSharedPtr<FJsonValue>> MatineeInventory;
    TArray<TSharedPtr<FJsonValue>> ConverterWarningMessages;
    TArray<TSharedPtr<FJsonValue>> GeneratedSequences;
    TArray<TSharedPtr<FJsonValue>> GeneratedSequenceAudits;

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
                MakeShared<FJsonValueObject>(CaptureReferenceContext(
                    Actor,
                    LoadedMap,
                    BlueprintGraphsByPath
                ))
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
            InventoryEntry->SetArrayField(TEXT("sourceEventTracks"), CaptureSourceEventTracks(Actor));

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
                CountSourceTrackKeys(Actor, SourceTrackKeyCounts);
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

    if (Actors.Num() != ExpectedConversions)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR conversion_target_mismatch expected=%d found=%d"),
            ExpectedConversions,
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

        const int32 SourceToggleKeyCount =
            SourceTrackKeyCounts.FindRef(TEXT("InterpTrackToggle"));
        const int32 SequenceParticleTrackCount =
            SequenceTrackCounts.FindRef(TEXT("MovieSceneParticleTrack"));
        UE_LOG(
            LogZenMatineeBridge,
            Display,
            TEXT("ZEN_BRIDGE_TOGGLE_MAPPING source_keys=%d sequence_tracks=%d"),
            SourceToggleKeyCount,
            SequenceParticleTrackCount
        );
        if (SourceToggleKeyCount > 0 && SequenceParticleTrackCount <= 0)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR keyed_toggle_output_missing")
            );
            return 29;
        }

        CopyMatineePlaybackSettingsToSequenceActor(Actor, NewActor.Get());

        // Capture source call identities before playback rewrite destroys those
        // nodes. The generated-sequence audit is assembled after all rewrites.
        const TArray<TSharedPtr<FJsonValue>> SourcePlaybackControlCalls =
            CapturePlaybackControlCalls(Actor);
        if (SourcePlaybackControlCalls.Num() <= 0)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR playback_plan_control_not_found actor=%s"),
                *ActorLabel
            );
            return 32;
        }

        TSharedPtr<FJsonObject> EventRewriteResult;
        if (!ApplyDirectorEventRewrite(Actor, Sequence, EventRewriteResult))
        {
            return 31;
        }

        TSharedPtr<FJsonObject> PlaybackRewriteResult;
        if (!ApplyPlaybackControlRewrite(Actor, NewActor.Get(), PlaybackRewriteResult))
        {
            return 32;
        }
        const int32 RewrittenPlaybackControlCount =
            PlaybackRewriteResult->GetIntegerField(TEXT("retargetedControlCount"));
        if (SourcePlaybackControlCalls.Num() != RewrittenPlaybackControlCount)
        {
            UE_LOG(
                LogZenMatineeBridge,
                Error,
                TEXT("ZEN_BRIDGE_ERROR playback_plan_rewrite_count_mismatch actor=%s plan=%d rewritten=%d"),
                *ActorLabel,
                SourcePlaybackControlCalls.Num(),
                RewrittenPlaybackControlCount
            );
            return 33;
        }

        TSharedPtr<FJsonObject> PostRewriteLevelBlueprintAudit;
        if (!CapturePostRewriteLevelBlueprintAudit(
            Actor,
            NewActor.Get(),
            Sequence,
            RewrittenPlaybackControlCount,
            PostRewriteLevelBlueprintAudit
        ))
        {
            return 34;
        }

        TSharedPtr<FJsonObject> SequenceAudit;
        if (!CaptureGeneratedSequenceAudit(
            Actor,
            NewActor.Get(),
            Sequence,
            SourcePlaybackControlCalls,
            SequenceAudit
        ))
        {
            return 30;
        }
        SequenceAudit->SetObjectField(TEXT("eventRewriteResult"), EventRewriteResult);
        SequenceAudit->SetObjectField(TEXT("playbackRewriteResult"), PlaybackRewriteResult);
        SequenceAudit->SetObjectField(
            TEXT("postRewriteLevelBlueprint"),
            PostRewriteLevelBlueprintAudit
        );
        GeneratedSequenceAudits.Add(MakeShared<FJsonValueObject>(SequenceAudit));

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

        FString SequenceFilename;
        if (!SaveGeneratedSequencePackage(Sequence, SequenceFilename))
        {
            return 33;
        }
        SequenceAudit->SetStringField(TEXT("sequencePackage"), Sequence->GetOutermost()->GetName());
        SequenceAudit->SetStringField(TEXT("sequenceFilename"), SequenceFilename);

        TSharedPtr<FJsonObject> SourceCleanupAudit = MakeShared<FJsonObject>();
        SourceCleanupAudit->SetBoolField(TEXT("requested"), bRemoveSourceMatinee);
        SourceCleanupAudit->SetBoolField(TEXT("applied"), false);
        SourceCleanupAudit->SetBoolField(TEXT("verified"), false);
        if (bRemoveSourceMatinee)
        {
            if (!ApplySourceMatineeCleanup(
                Actor,
                NewActor.Get(),
                RewrittenPlaybackControlCount,
                SourceCleanupAudit
            ))
            {
                return 35;
            }
            ++MatineesRemoved;
        }
        SequenceAudit->SetObjectField(TEXT("sourceCleanup"), SourceCleanupAudit);

        const FString SequencePath = Sequence->GetPathName();
        GeneratedSequences.Add(MakeShared<FJsonValueString>(SequencePath));
        ConversionWarnings += ActorWarnings;
        KnownConversionWarnings += ActorKnownWarnings;
        MatineesConverted++;

        if (bRemoveSourceMatinee)
        {
            if (MatineesRemoved != MatineesConverted)
            {
                UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_actor_not_removed actor=%s"), *ActorLabel);
                return 26;
            }
        }
        else if (!IsValid(Actor) || Actor->GetWorld() != World)
        {
            UE_LOG(LogZenMatineeBridge, Error, TEXT("ZEN_BRIDGE_ERROR source_actor_not_retained actor=%s"), *ActorLabel);
            return 26;
        }
        else
        {
            MatineesRetained++;
        }

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
        MatineesConverted != ExpectedConversions ||
        MatineesRetained != (bRemoveSourceMatinee ? 0 : ExpectedConversions) ||
        MatineesRemoved != (bRemoveSourceMatinee ? ExpectedConversions : 0) ||
        !bFoundExpectedActor)
    {
        UE_LOG(
            LogZenMatineeBridge,
            Error,
            TEXT("ZEN_BRIDGE_ERROR count_mismatch expected=%d found=%d converted=%d retained=%d removed=%d expected_actor=%d"),
            ExpectedMatinees,
            MatineesFound,
            MatineesConverted,
            MatineesRetained,
            MatineesRemoved,
            bFoundExpectedActor ? 1 : 0
        );
        return 28;
    }

    TArray<FString> BlueprintGraphPaths;
    BlueprintGraphsByPath.GetKeys(BlueprintGraphPaths);
    BlueprintGraphPaths.Sort();
    TArray<TSharedPtr<FJsonValue>> BlueprintGraphs;
    for (const FString& GraphPath : BlueprintGraphPaths)
    {
        BlueprintGraphs.Add(MakeShared<FJsonValueObject>(BlueprintGraphsByPath.FindChecked(GraphPath)));
    }

    TSharedRef<FJsonObject> Report = MakeShared<FJsonObject>();
    Report->SetStringField(TEXT("engineVersion"), TEXT("4.27.2"));
    Report->SetNumberField(TEXT("mapsScanned"), MapFiles.Num());
    Report->SetNumberField(TEXT("mapsConverted"), ConvertedMaps);
    Report->SetNumberField(TEXT("uniqueMatineesDiscovered"), UniqueMatineesDiscovered);
    Report->SetNumberField(TEXT("matineesFound"), MatineesFound);
    Report->SetNumberField(TEXT("matineesConverted"), MatineesConverted);
    Report->SetNumberField(TEXT("sourceActorsRetained"), MatineesRetained);
    Report->SetNumberField(TEXT("sourceActorsRemoved"), MatineesRemoved);
    Report->SetBoolField(TEXT("sourceCleanupRequested"), bRemoveSourceMatinee);
    Report->SetNumberField(TEXT("conversionWarnings"), ConversionWarnings);
    Report->SetNumberField(TEXT("knownConversionWarnings"), KnownConversionWarnings);
    Report->SetNumberField(TEXT("unexpectedConversionWarnings"), UnexpectedConversionWarnings);
    Report->SetStringField(TEXT("targetMap"), TargetMap);
    Report->SetStringField(TEXT("expectedActor"), ExpectedActor);
    Report->SetNumberField(TEXT("expectedTargetMapMatinees"), ExpectedMatinees);
    Report->SetNumberField(TEXT("expectedConversions"), ExpectedConversions);
    Report->SetArrayField(
        TEXT("requiredSourceTrackClasses"),
        StringsToJson(RequiredSourceTracks)
    );
    Report->SetArrayField(
        TEXT("requiredSequenceTrackClasses"),
        StringsToJson(RequiredSequenceTracks)
    );
    Report->SetArrayField(TEXT("matineeInventory"), MatineeInventory);
    Report->SetArrayField(TEXT("blueprintGraphs"), BlueprintGraphs);
    Report->SetArrayField(TEXT("converterWarningMessages"), ConverterWarningMessages);
    Report->SetArrayField(TEXT("generatedSequences"), GeneratedSequences);
    Report->SetArrayField(TEXT("generatedSequenceAudits"), GeneratedSequenceAudits);
    Report->SetObjectField(TEXT("sourceTrackClasses"), CountsToJson(SourceTrackCounts));
    Report->SetObjectField(TEXT("sourceTrackKeyCounts"), CountsToJson(SourceTrackKeyCounts));
    Report->SetObjectField(TEXT("sequenceTrackClasses"), CountsToJson(SequenceTrackCounts));

    FString ReportText;
    TSharedRef<TJsonWriter<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>> Writer =
        TJsonWriterFactory<TCHAR, TPrettyJsonPrintPolicy<TCHAR>>::Create(&ReportText);
    FJsonSerializer::Serialize(Report, Writer);

    const FString ReportPath = FPaths::Combine(
        FPaths::ProjectSavedDir(),
        TEXT("ZenMigration"),
        ReportName
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
