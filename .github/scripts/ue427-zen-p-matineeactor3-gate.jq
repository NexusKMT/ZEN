def actor($map; $name):
  first(.matineeInventory[] | select(.map == $map and .actor == $name));

def blueprint_graph($path):
  first(.blueprintGraphs[] | select(.graphPath == $path));

def node_basename:
  split(".")[-1];

def target_events:
  ["End", "StopButterflies", "SwitchLevel"];

def target_custom_events:
  ["ZenSeq_End", "ZenSeq_StopButterflies", "ZenSeq_SwitchLevel"];

def valid_control_chain($audit):
  . as $chain |
  .dataChainValid == true and
  .executionChainValid == true and
  .controlSelfLinkCount == 1 and
  .matchingGetSequencePlayerLinks == 1 and
  .getSequencePlayerSelfLinkCount == 1 and
  .matchingSequenceActorLiterals == 1 and
  .incomingExecCount >= 1 and
  (.outgoingExecCount == 0 or .outgoingExecCount == 1) and
  (.incomingExec | length) == .incomingExecCount and
  (.outgoingExec | length) == .outgoingExecCount and
  any($audit.postRewriteLevelBlueprint.graphs[].nodes[];
    .objectPath == $chain.controlNode and
    .class == "K2Node_CallFunction" and
    .functionName == $chain.functionName
  ) and
  any($audit.postRewriteLevelBlueprint.graphs[].nodes[];
    .objectPath == $chain.getSequencePlayerNode and
    .class == "K2Node_CallFunction" and
    .functionName == "GetSequencePlayer"
  ) and
  any($audit.postRewriteLevelBlueprint.graphs[].nodes[];
    .objectPath == $chain.sequenceActorLiteralNode and
    .class == "K2Node_Literal" and
    .referencedObject == $audit.levelSequenceActor.actorPath
  );

def matinee_control_signature:
  {
    node: (.objectPath | node_basename),
    nodeGuid,
    functionName,
    selfLiteral: (.selfLiteralNode | node_basename),
    selfLiteralNodeGuid,
    selfLiteralReferencedObject,
    selfLinkCount,
    selfLiteralLinkCount,
    incomingExecCount,
    outgoingExecCount,
    executionEntryReachable
  };

def unresolved_cleanup_signature:
  {
    node: (.objectPath | node_basename),
    nodeGuid,
    functionName,
    literalNode: (.literalNode | node_basename),
    literalNodeGuid,
    incomingExecCount,
    outgoingExecCount,
    executionEntryReachable
  };

def known_unresolved_matinee_controls($control_audit):
  ($control_audit |
    .callCount == 4 and
    .playCallCount == 2 and
    .resolvedActorLiteralCallCount == 0 and
    .unresolvedActorLiteralCallCount == 4 and
    .otherSelfTargetCallCount == 0 and
    .resolvedActorLiteralPlayCallCount == 0 and
    .unresolvedActorLiteralPlayCallCount == 2 and
    .otherSelfTargetPlayCallCount == 0 and
    .resolvedActorLiteralControlCounts == {} and
    .unresolvedActorLiteralControlCounts == {"Pause": 1, "Play": 2, "SetPosition": 1} and
    .otherSelfTargetControlCounts == {} and
    (.resolvedActorLiteralCalls | length) == 0 and
    (.otherSelfTargetCalls | length) == 0 and
    ([.unresolvedActorLiteralCalls[] | matinee_control_signature] | sort_by(.node)) == [
      {
        "node": "K2Node_CallFunction_357829",
        "nodeGuid": "157FEE274C8EBA0E7735368B1984712F",
        "functionName": "Play",
        "selfLiteral": "K2Node_Literal_46",
        "selfLiteralNodeGuid": "160C243D4C72F7DC480027AE53085FC0",
        "selfLiteralReferencedObject": "",
        "selfLinkCount": 1,
        "selfLiteralLinkCount": 1,
        "incomingExecCount": 0,
        "outgoingExecCount": 0,
        "executionEntryReachable": false
      },
      {
        "node": "K2Node_CallFunction_357986",
        "nodeGuid": "D6A4EB744E1C600AEAA8DE95F9D5F567",
        "functionName": "SetPosition",
        "selfLiteral": "K2Node_Literal_46",
        "selfLiteralNodeGuid": "160C243D4C72F7DC480027AE53085FC0",
        "selfLiteralReferencedObject": "",
        "selfLinkCount": 1,
        "selfLiteralLinkCount": 1,
        "incomingExecCount": 1,
        "outgoingExecCount": 1,
        "executionEntryReachable": false
      },
      {
        "node": "K2Node_CallFunction_373072",
        "nodeGuid": "8E6373D1451055BC7AA27D816851DE41",
        "functionName": "Play",
        "selfLiteral": "K2Node_Literal_46",
        "selfLiteralNodeGuid": "160C243D4C72F7DC480027AE53085FC0",
        "selfLiteralReferencedObject": "",
        "selfLinkCount": 1,
        "selfLiteralLinkCount": 1,
        "incomingExecCount": 1,
        "outgoingExecCount": 1,
        "executionEntryReachable": false
      },
      {
        "node": "K2Node_CallFunction_373489",
        "nodeGuid": "C653867A44E50C4D4BCB88A8CE60F258",
        "functionName": "Pause",
        "selfLiteral": "K2Node_Literal_46",
        "selfLiteralNodeGuid": "160C243D4C72F7DC480027AE53085FC0",
        "selfLiteralReferencedObject": "",
        "selfLinkCount": 1,
        "selfLiteralLinkCount": 1,
        "incomingExecCount": 1,
        "outgoingExecCount": 0,
        "executionEntryReachable": false
      }
    ]
  );

def empty_matinee_control_audit:
  .callCount == 0 and
  .playCallCount == 0 and
  .resolvedActorLiteralCallCount == 0 and
  .unresolvedActorLiteralCallCount == 0 and
  .otherSelfTargetCallCount == 0 and
  .resolvedActorLiteralPlayCallCount == 0 and
  .unresolvedActorLiteralPlayCallCount == 0 and
  .otherSelfTargetPlayCallCount == 0 and
  .resolvedActorLiteralControlCounts == {} and
  .unresolvedActorLiteralControlCounts == {} and
  .otherSelfTargetControlCounts == {} and
  .resolvedActorLiteralCalls == [] and
  .unresolvedActorLiteralCalls == [] and
  .otherSelfTargetCalls == [];

(blueprint_graph("/Game/Maps/Zen_P.Zen_P:PersistentLevel.Zen_P.EventGraph").nodeCount) as $pre_node_count |
.engineVersion == "4.27.2" and
.targetMap == "/Game/Maps/Zen_P" and
.expectedActor == "MatineeActor3" and
.expectedTargetMapMatinees == (if $source_cleanup_requested then 1 else 2 end) and
.expectedConversions == 1 and
.mapsScanned == 9 and
.mapsConverted == 1 and
.matineesFound == (if $source_cleanup_requested then 1 else 2 end) and
.matineesConverted == 1 and
.sourceCleanupRequested == $source_cleanup_requested and
(if $source_cleanup_requested then
  .uniqueMatineesDiscovered == 1 and
  (.matineeInventory | length) == 1 and
  .sourceActorsRetained == 0 and
  .sourceActorsRemoved == 1
else
  .uniqueMatineesDiscovered == 3 and
  (.matineeInventory | length) == 3 and
  .sourceActorsRetained == 1 and
  .sourceActorsRemoved == 0
end) and
(.requiredSourceTrackClasses | sort) == [
  "InterpTrackDirector",
  "InterpTrackEvent",
  "InterpTrackFloatProp",
  "InterpTrackMove",
  "InterpTrackSound",
  "InterpTrackToggle"
] and
(.requiredSequenceTrackClasses | sort) == [
  "MovieScene3DTransformTrack",
  "MovieSceneAudioTrack",
  "MovieSceneCameraCutTrack",
  "MovieSceneEventTrack",
  "MovieSceneFloatTrack",
  "MovieSceneParticleTrack"
] and
.sourceTrackClasses == {
  "InterpTrackMove": 2,
  "InterpTrackFloatProp": 2,
  "InterpTrackEvent": 2,
  "InterpTrackDirector": 1,
  "InterpTrackSound": 6,
  "InterpTrackToggle": 2
} and
.sourceTrackKeyCounts.InterpTrackEvent == 3 and
.sourceTrackKeyCounts.InterpTrackToggle > 0 and
.sequenceTrackClasses.MovieScene3DTransformTrack > 0 and
.sequenceTrackClasses.MovieSceneAudioTrack > 0 and
.sequenceTrackClasses.MovieSceneCameraCutTrack == 1 and
.sequenceTrackClasses.MovieSceneEventTrack == 2 and
.sequenceTrackClasses.MovieSceneFloatTrack > 0 and
.sequenceTrackClasses.MovieSceneParticleTrack > 0 and
.conversionWarnings == 0 and
.knownConversionWarnings == 0 and
.unexpectedConversionWarnings == 0 and
.converterWarningMessages == [] and
.generatedSequences == [
  "/Game/Maps/MatineeActor3LevelSequence.MatineeActor3LevelSequence"
] and
(.generatedSequenceAudits | length) == 1 and
(actor("/Game/Maps/Zen_P"; "MatineeActor3") |
  .objectName == "MatineeActor_3" and
  .playOnLevelLoad == false and
  .looping == false and
  .rewindOnPlay == false and
  .playRate == 1 and
  .forceStartPositionEnabled == false and
  .forceStartPosition == 0 and
  .controllerName == "K2Node_MatineeController_2" and
  (.sourceEventTracks | length) == 2 and
  [.sourceEventTracks[] | {eventTrackIndex, groupIndex, trackIndex, groupName, keyCount}] == [
    {"eventTrackIndex": 0, "groupIndex": 0, "trackIndex": 2, "groupName": "Pull-out", "keyCount": 2},
    {"eventTrackIndex": 1, "groupIndex": 1, "trackIndex": 1, "groupName": "DirGroup", "keyCount": 1}
  ] and
  ([.sourceEventTracks[].keys[].eventName] | sort) == target_events and
  .sourceEventTracks[0].keys == [
    {"keyIndex": 0, "timeSeconds": 8.253929138183594, "eventName": "StopButterflies"},
    {"keyIndex": 1, "timeSeconds": 242.14059448242188, "eventName": "End"}
  ] and
  .sourceEventTracks[1].keys == [
    {"keyIndex": 0, "timeSeconds": 4.559261798858643, "eventName": "SwitchLevel"}
  ] and
  ([.referenceContexts[].referencers[] |
    select(.class == "K2Node_Literal") |
    .blueprintNode |
    {
      node: (.objectPath | node_basename),
      nodeGuid,
      links: ([.pins[].links[].functionName] | sort)
    }
  ] | sort_by(.node)) == [
    {"node": "K2Node_Literal_1030", "nodeGuid": "A780163E49B36BA493FBBA8593703BF6", "links": ["Pause"]},
    {"node": "K2Node_Literal_504", "nodeGuid": "F6DB15B04E3A63EC46989A82EF210CE5", "links": ["Pause", "Play"]},
    {"node": "K2Node_Literal_713", "nodeGuid": "64EB20324F3911376439ED92DA249C6A", "links": []}
  ] and
  (first(.referenceContexts[].referencers[] |
    select(.class == "K2Node_MatineeController") |
    .blueprintNode) |
    .nodeGuid == "DE2E7C1149AEB9E6657EE1A6D9507960" and
    [.pins[] | {name, linkCount}] == [
      {"name": "Finished", "linkCount": 0},
      {"name": "StopButterflies", "linkCount": 1},
      {"name": "End", "linkCount": 1},
      {"name": "SwitchLevel", "linkCount": 1}
    ]
  )
) and
(blueprint_graph("/Game/Maps/Zen_P.Zen_P:PersistentLevel.Zen_P.EventGraph") |
  .package == "/Game/Maps/Zen_P" and
  .nodeCount == (if $source_cleanup_requested then 190 else 194 end) and
  .nodeCount == (.nodes | length) and
  (first(.nodes[] | select(.nodeGuid == "160C243D4C72F7DC480027AE53085FC0")) |
    .class == "K2Node_Literal" and
    .referencedObject == "" and
    .pins[0].subCategoryObject == "/Script/Engine.MatineeActor" and
    ([.pins[].links[] | {
      node: (.objectPath | node_basename),
      nodeGuid,
      functionName,
      pinName
    }] | sort_by(.node)) == [
      {"node": "K2Node_CallFunction_357829", "nodeGuid": "157FEE274C8EBA0E7735368B1984712F", "functionName": "Play", "pinName": "self"},
      {"node": "K2Node_CallFunction_357986", "nodeGuid": "D6A4EB744E1C600AEAA8DE95F9D5F567", "functionName": "SetPosition", "pinName": "self"},
      {"node": "K2Node_CallFunction_373072", "nodeGuid": "8E6373D1451055BC7AA27D816851DE41", "functionName": "Play", "pinName": "self"},
      {"node": "K2Node_CallFunction_373489", "nodeGuid": "C653867A44E50C4D4BCB88A8CE60F258", "functionName": "Pause", "pinName": "self"}
    ]
  )
) and
(.generatedSequenceAudits[0] |
  . as $audit |
  .mappingVerified == true and
  .sourceActor == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3" and
  .sequence == "/Game/Maps/MatineeActor3LevelSequence.MatineeActor3LevelSequence" and
  .sequencePackage == "/Game/Maps/MatineeActor3LevelSequence" and
  (.sequenceFilename | endswith("/Content/Maps/MatineeActor3LevelSequence.uasset")) and
  .levelSequenceActor.present == true and
  .levelSequenceActor.actorPath == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor3LevelSequence" and
  .levelSequenceActor.levelSequencePath == "/Game/Maps/MatineeActor3LevelSequence.MatineeActor3LevelSequence" and
  .levelSequenceActor.playbackSettings.autoPlay == false and
  .levelSequenceActor.playbackSettings.loopCount == 0 and
  .levelSequenceActor.playbackSettings.playRate == 1 and
  .levelSequenceActor.playbackSettings.startTime == 0 and
  .sourceEventTrackCount == 2 and
  .targetEventTrackCount == 2 and
  .eventKeyCount == 3 and
  .uniqueEndpointCount == 3 and
  (.eventTracks | length) == 2 and
  [.eventTracks[].keyCount] == [2, 1] and
  ([.eventTracks[].keys[].sourceEventName] | sort) == target_events and
  all(.eventTracks[].keys[];
    .frameNumber == .expectedFrameNumber and
    .endpointClass == "K2Node_CustomEvent" and
    (.endpointObjectPath | length) > 0
  ) and
  .eventRewritePlan.eventPlanCount == 3 and
  (.eventRewritePlan.eventPlans | length) == 3 and
  ([.eventRewritePlan.eventPlans[].sourceEventName] | sort) == target_events and
  ([.eventRewritePlan.eventPlans[].eventTrackIndex] | sort) == [0, 0, 1] and
  all(.eventRewritePlan.eventPlans[];
    .controllerPinLinkCount == 1 and
    (.execClosure | length) >= 1
  ) and
  ([.eventRewritePlan.playbackControlCalls[] | {
    node: (.objectPath | node_basename), nodeGuid, functionName, incomingExecCount
  }] | sort_by(.node)) == [
    {"node": "K2Node_CallFunction_118301", "nodeGuid": "33010D334437BF8FA55D798B8A943761", "functionName": "Pause", "incomingExecCount": 1},
    {"node": "K2Node_CallFunction_1915238", "nodeGuid": "63F5FB1D44FBC5F1CD28B19D1E703E66", "functionName": "Play", "incomingExecCount": 1},
    {"node": "K2Node_CallFunction_2751992", "nodeGuid": "293D72A84780A5CCE58DEFABB7297E1F", "functionName": "Pause", "incomingExecCount": 1}
  ] and
  .eventRewriteResult.applied == true and
  .eventRewriteResult.wiredEventCount == 3 and
  .eventRewriteResult.clonedNodeCount == 6 and
  (.eventRewriteResult.wiredEvents | length) == 3 and
  ([.eventRewriteResult.wiredEvents[].eventTrackIndex] | sort) == [0, 0, 1] and
  all(.eventRewriteResult.wiredEvents[];
    .thenLinkCount == 1 and
    .clonedNodeCount == 2 and
    .levelCustomEventName == ("ZenSeq_" + .sourceEventName) and
    .consoleCommand == ("CE ZenSeq_" + .sourceEventName)
  ) and
  .playbackRewriteResult.applied == true and
  .playbackRewriteResult.retargetedPlayCount == 1 and
  .playbackRewriteResult.retargetedControlCount == 3 and
  .playbackRewriteResult.retargetedControlCounts == {"Pause": 2, "Play": 1} and
  (.playbackRewriteResult.details | length) == 3 and
  ([.playbackRewriteResult.details[].incomingExecBefore | length] | sort) == [1, 1, 2] and
  ([.playbackRewriteResult.details[].outgoingExecBefore | length] | sort) == [0, 0, 1] and
  all(.playbackRewriteResult.details[];
    (.originalControlNode | length) > 0 and
    (.newControlNode | length) > 0 and
    .incomingExecAfter == .incomingExecBefore and
    .outgoingExecAfter == .outgoingExecBefore
  ) and
  (.postRewriteLevelBlueprint |
    .verified == true and
    .package == "/Game/Maps/Zen_P" and
    .levelBlueprintHasCompileError == false and
    .directorBlueprintHasCompileError == false and
    .graphCount == 1 and
    (.graphs | length) == 1 and
    .graphs[0].nodeCount == ((if $source_cleanup_requested then 190 else 194 end) + 9) and
    .graphs[0].nodeCount == (.graphs[0].nodes | length) and
    .expectedZenSeqCustomEventCount == 3 and
    .zenSeqCustomEventCount == 5 and
    .matchingExpectedZenSeqCustomEventCount == 3 and
    .eventAuditCount == 3 and
    (.events | length) == 3 and
    ([.events[].eventTrackIndex] | sort) == [0, 0, 1] and
    ([.events[].sourceEventName] | sort) == target_events and
    ([.events[].customEventName] | sort) == target_custom_events and
    .allEventFirstHopsMatch == true and
    all(.events[];
      .matchingCustomEventCount == 1 and
      .firstHopsMatch == true and
      .controllerFirstHopCount == 1 and
      .customEventFirstHopCount == 1 and
      .controllerFirstHops == .customEventFirstHops
    ) and
    .matineePlayCallCount == 2 and
    .resolvedMatineePlayCallCount == 0 and
    .unresolvedMatineePlayCallCount == 2 and
    .otherSelfTargetMatineePlayCallCount == 0 and
    known_unresolved_matinee_controls(.matineePlaybackControlAudit) and
    .sourceMatineePlayCallCount == 0 and
    .sourceMatineePlaybackControlCallCount == 0 and
    .sequencePlayerPlayCallCount == 1 and
    .validSequencePlaybackChainCount == 1 and
    .expectedSequencePlayerControlCallCount == 3 and
    .sequencePlayerControlCallCount == 3 and
    .validSequencePlaybackControlChainCount == 3 and
    .sequencePlayerControlCounts == {"Pause": 2, "Play": 1} and
    .validSequencePlaybackControlCounts == {"Pause": 2, "Play": 1} and
    (.playbackControlChains | length) == 3 and
    ([.playbackControlChains[].incomingExecCount] | sort) == [1, 1, 2] and
    ([.playbackControlChains[].outgoingExecCount] | sort) == [0, 0, 1] and
    all(.playbackControlChains[]; valid_control_chain($audit))
  ) and
  (.directorBlueprint |
    .graphCount == (.graphs | length) and
    .graphCount > 0 and
    ([.graphs[].nodes[] |
      select(.class == "K2Node_CallFunction" and .functionName == "ExecuteConsoleCommand") |
      .pins[] |
      select(.name == "Command" and .direction == "input") |
      .defaultValue
    ] | sort) == [
      "CE ZenSeq_End",
      "CE ZenSeq_StopButterflies",
      "CE ZenSeq_SwitchLevel"
    ]
  ) and
  (.sourceCleanup |
    .requested == $source_cleanup_requested and
    if $source_cleanup_requested then
      .applied == true and
      .verified == true and
      .sourceActorPath == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3" and
      .mapMatineeActorCountBeforeCleanup == 1 and
      .finalMapMatineeCleanup == true and
      .controllersRemoved == 1 and
      .sourceActorLiteralsRemoved == 3 and
      .sourceActorLiteralLinkCountBeforeRemoval == 0 and
      .unresolvedMatineeLiteralsRemoved == 1 and
      .unresolvedMatineeControlCallsRemoved == 4 and
      .unresolvedMatineeLiteralLinkCountBeforeRemoval == 4 and
      ([.unresolvedMatineeControlCallDetails[] | unresolved_cleanup_signature] | sort_by(.node)) == [
        {"node": "K2Node_CallFunction_357829", "nodeGuid": "157FEE274C8EBA0E7735368B1984712F", "functionName": "Play", "literalNode": "K2Node_Literal_46", "literalNodeGuid": "160C243D4C72F7DC480027AE53085FC0", "incomingExecCount": 0, "outgoingExecCount": 0, "executionEntryReachable": false},
        {"node": "K2Node_CallFunction_357986", "nodeGuid": "D6A4EB744E1C600AEAA8DE95F9D5F567", "functionName": "SetPosition", "literalNode": "K2Node_Literal_46", "literalNodeGuid": "160C243D4C72F7DC480027AE53085FC0", "incomingExecCount": 1, "outgoingExecCount": 1, "executionEntryReachable": false},
        {"node": "K2Node_CallFunction_373072", "nodeGuid": "8E6373D1451055BC7AA27D816851DE41", "functionName": "Play", "literalNode": "K2Node_Literal_46", "literalNodeGuid": "160C243D4C72F7DC480027AE53085FC0", "incomingExecCount": 1, "outgoingExecCount": 1, "executionEntryReachable": false},
        {"node": "K2Node_CallFunction_373489", "nodeGuid": "C653867A44E50C4D4BCB88A8CE60F258", "functionName": "Pause", "literalNode": "K2Node_Literal_46", "literalNodeGuid": "160C243D4C72F7DC480027AE53085FC0", "incomingExecCount": 1, "outgoingExecCount": 0, "executionEntryReachable": false}
      ] and
      .remainingTargetControllerCount == 0 and
      .remainingTargetLiteralCount == 0 and
      .remainingMatineePlayCallCount == 0 and
      .remainingResolvedMatineePlayCallCount == 0 and
      .remainingUnresolvedMatineePlayCallCount == 0 and
      .remainingOtherSelfTargetMatineePlayCallCount == 0 and
      (.remainingMatineePlaybackControlAudit | empty_matinee_control_audit) and
      .remainingSourceMatineePlaybackControlCallCount == 0 and
      .sequencePlayerPlayCallCount == 1 and
      .validSequencePlaybackChainCount == 1 and
      .expectedSequencePlayerControlCallCount == 3 and
      .sequencePlayerControlCallCount == 3 and
      .validSequencePlaybackControlChainCount == 3 and
      .sequencePlayerControlCounts == {"Pause": 2, "Play": 1} and
      .validSequencePlaybackControlCounts == {"Pause": 2, "Play": 1} and
      (.playbackControlChains | length) == 3 and
      ([.playbackControlChains[].incomingExecCount] | sort) == [1, 1, 2] and
      all(.playbackControlChains[]; valid_control_chain($audit)) and
      .remainingWorldActorCount == 0 and
      .remainingMapMatineeActorCount == 0 and
      .remainingMapMatineeActors == [] and
      .sequenceActorCount == 1 and
      .expectedCustomEventCount == 3 and
      .verifiedCustomEventCount == 3 and
      .eventAuditCount == 3 and
      (.events | length) == 3 and
      .allEventFirstHopsPreserved == true and
      ([.events[].customEventName] | sort) == target_custom_events and
      all(.events[];
        .matchingCustomEventCount == 1 and
        .firstHopsPreserved == true and
        (.expectedFirstHops | length) == 1 and
        .actualFirstHops == .expectedFirstHops
      ) and
      .levelBlueprintHasCompileError == false and
      .graphCount == 1 and
      (.graphs | length) == 1 and
      .graphs[0].package == "/Game/Maps/Zen_P" and
      .graphs[0].nodeCount == $pre_node_count and
      .graphs[0].nodeCount == ($audit.postRewriteLevelBlueprint.graphs[0].nodeCount - 9) and
      .graphs[0].nodeCount == (.graphs[0].nodes | length) and
      ([.graphs[0].nodes[] | select(.class == "K2Node_MatineeController")] | length) == 0 and
      ([.graphs[0].nodes[] |
        select(.class == "K2Node_Literal" and .pins[0].subCategoryObject == "/Script/Engine.MatineeActor")
      ] | length) == 0 and
      ([.graphs[0].nodes[] |
        select(.class == "K2Node_CallFunction" and .functionOwnerClass == "/Script/Engine.MatineeActor")
      ] | length) == 0
    else
      .applied == false and
      .verified == false
    end
  )
)
