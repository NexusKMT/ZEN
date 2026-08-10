def actor($map; $name):
  first(.matineeInventory[] | select(.map == $map and .actor == $name));

def blueprint_graph($path):
  first(.blueprintGraphs[] | select(.graphPath == $path));

def target_events:
  ["EndOfMatinee", "Hitcher"];

def target_custom_events:
  ["ZenSeq_EndOfMatinee", "ZenSeq_Hitcher"];

def valid_control_chain($audit):
  . as $chain |
  .dataChainValid == true and
  .executionChainValid == true and
  .controlSelfLinkCount == 1 and
  .matchingGetSequencePlayerLinks == 1 and
  .getSequencePlayerSelfLinkCount == 1 and
  .matchingSequenceActorLiterals == 1 and
  .incomingExecCount == 1 and
  (.outgoingExecCount == 0 or .outgoingExecCount == 1) and
  (.incomingExec | length) == 1 and
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

.engineVersion == "4.27.2" and
.targetMap == "/Game/Maps/Zen_P" and
.expectedActor == "MatineeActor" and
.expectedTargetMapMatinees == 2 and
.expectedConversions == 1 and
.mapsScanned == 9 and
.mapsConverted == 1 and
.matineesFound == 2 and
.matineesConverted == 1 and
.sourceCleanupRequested == $source_cleanup_requested and
(if $source_cleanup_requested then
  .uniqueMatineesDiscovered == 2 and
  (.matineeInventory | length) == 2 and
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
  "InterpTrackFade",
  "InterpTrackFloatProp",
  "InterpTrackMove",
  "InterpTrackToggle"
] and
(.requiredSequenceTrackClasses | sort) == [
  "MovieScene3DTransformTrack",
  "MovieSceneCameraCutTrack",
  "MovieSceneEventTrack",
  "MovieSceneFadeTrack",
  "MovieSceneFloatTrack",
  "MovieSceneParticleTrack"
] and
.sourceTrackClasses == {
  "InterpTrackMove": 2,
  "InterpTrackFloatProp": 2,
  "InterpTrackDirector": 1,
  "InterpTrackFade": 1,
  "InterpTrackToggle": 1,
  "InterpTrackEvent": 1
} and
.sequenceTrackClasses == {
  "MovieScene3DTransformTrack": 2,
  "MovieSceneCameraCutTrack": 1,
  "MovieSceneEventTrack": 1,
  "MovieSceneFadeTrack": 1,
  "MovieSceneFloatTrack": 2,
  "MovieSceneParticleTrack": 1
} and
.conversionWarnings == 1 and
.knownConversionWarnings == 1 and
.unexpectedConversionWarnings == 0 and
.converterWarningMessages == [$known_warning] and
.generatedSequences == [
  "/Game/Maps/MatineeActorLevelSequence.MatineeActorLevelSequence"
] and
(.generatedSequenceAudits | length) == 1 and
(actor("/Game/Maps/Zen_P"; "MatineeActor") |
  .objectName == "MatineeActor_0" and
  .playOnLevelLoad == false and
  .looping == true and
  .rewindOnPlay == false and
  .playRate == 1 and
  .forceStartPositionEnabled == false and
  .forceStartPosition == 0 and
  .controllerName == "K2Node_MatineeController_13" and
  (.sourceEventTracks | length) == 1 and
  .sourceEventTracks[0].keyCount == 2 and
  ([.sourceEventTracks[0].keys[].eventName] | sort) == target_events and
  ([.referenceContexts[].referencers[] |
    select(.class == "K2Node_Literal") |
    .blueprintNode.pins[0].links[].functionName
  ] | sort) == ["Play", "Stop", "Stop"]
) and
(actor("/Game/Maps/Zen_P"; "MatineeActor3") |
  .objectName == "MatineeActor_3" and
  .controllerName == "K2Node_MatineeController_2" and
  .sourceTrackClasses == {
    "InterpTrackMove": 2,
    "InterpTrackFloatProp": 2,
    "InterpTrackEvent": 2,
    "InterpTrackDirector": 1,
    "InterpTrackSound": 6,
    "InterpTrackToggle": 2
  }
) and
(blueprint_graph("/Game/Maps/Zen_P.Zen_P:PersistentLevel.Zen_P.EventGraph") |
  .package == "/Game/Maps/Zen_P" and
  .nodeCount == 186 and
  .nodeCount == (.nodes | length) and
  ([.nodes[].pins[].links[]] | length) == 410 and
  ([.nodes[] | select(.class == "K2Node_MatineeController")] | length) == 2
) and
(.generatedSequenceAudits[0] |
  . as $audit |
  .mappingVerified == true and
  .sourceActor == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0" and
  .sequence == "/Game/Maps/MatineeActorLevelSequence.MatineeActorLevelSequence" and
  .sequencePackage == "/Game/Maps/MatineeActorLevelSequence" and
  (.sequenceFilename | endswith("/Content/Maps/MatineeActorLevelSequence.uasset")) and
  .levelSequenceActor.present == true and
  .levelSequenceActor.actorPath == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActorLevelSequence" and
  .levelSequenceActor.levelSequencePath == "/Game/Maps/MatineeActorLevelSequence.MatineeActorLevelSequence" and
  .levelSequenceActor.playbackSettings.autoPlay == false and
  .levelSequenceActor.playbackSettings.loopCount == -1 and
  .levelSequenceActor.playbackSettings.playRate == 1 and
  .levelSequenceActor.playbackSettings.startTime == 0 and
  .sourceEventTrackCount == 1 and
  .targetEventTrackCount == 1 and
  .eventKeyCount == 2 and
  .uniqueEndpointCount == 2 and
  (.eventTracks | length) == 1 and
  ([.eventTracks[0].keys[].sourceEventName] | sort) == target_events and
  all(.eventTracks[].keys[];
    .frameNumber == .expectedFrameNumber and
    .endpointClass == "K2Node_CustomEvent" and
    (.endpointObjectPath | length) > 0
  ) and
  .eventRewritePlan.eventPlanCount == 2 and
  (.eventRewritePlan.eventPlans | length) == 2 and
  ([.eventRewritePlan.eventPlans[].sourceEventName] | sort) == target_events and
  all(.eventRewritePlan.eventPlans[];
    .controllerPinLinkCount == 1 and
    (.execClosure | length) >= 1
  ) and
  ([.eventRewritePlan.playbackControlCalls[].functionName] | sort) == [
    "Play", "Stop", "Stop"
  ] and
  all(.eventRewritePlan.playbackControlCalls[];
    .incomingExecCount == 1 and
    (.thenClosure | type) == "array"
  ) and
  .eventRewriteResult.applied == true and
  .eventRewriteResult.wiredEventCount == 2 and
  .eventRewriteResult.clonedNodeCount == 4 and
  (.eventRewriteResult.wiredEvents | length) == 2 and
  all(.eventRewriteResult.wiredEvents[];
    .thenLinkCount == 1 and
    .clonedNodeCount == 2 and
    .levelCustomEventName == ("ZenSeq_" + .sourceEventName) and
    .consoleCommand == ("CE ZenSeq_" + .sourceEventName)
  ) and
  .playbackRewriteResult.applied == true and
  .playbackRewriteResult.retargetedPlayCount == 1 and
  .playbackRewriteResult.retargetedControlCount == 3 and
  .playbackRewriteResult.retargetedControlCounts == {"Play": 1, "Stop": 2} and
  (.playbackRewriteResult.details | length) == 3 and
  ([.playbackRewriteResult.details[].functionName] | sort) == [
    "Play", "Stop", "Stop"
  ] and
  ([.playbackRewriteResult.details[].outgoingExecBefore | length] | sort) == [0, 1, 1] and
  all(.playbackRewriteResult.details[];
    (.originalControlNode | length) > 0 and
    (.newControlNode | length) > 0 and
    (.incomingExecBefore | length) == 1 and
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
    .graphs[0].nodeCount == 194 and
    .graphs[0].nodeCount == (.graphs[0].nodes | length) and
    .expectedZenSeqCustomEventCount == 2 and
    .zenSeqCustomEventCount == 2 and
    .eventAuditCount == 2 and
    (.events | length) == 2 and
    .allEventFirstHopsMatch == true and
    ([.events[].sourceEventName] | sort) == target_events and
    ([.events[].customEventName] | sort) == target_custom_events and
    all(.events[];
      .matchingCustomEventCount == 1 and
      .firstHopsMatch == true and
      .controllerFirstHopCount == 1 and
      .customEventFirstHopCount == 1 and
      .controllerFirstHops == .customEventFirstHops
    ) and
    .matineePlayCallCount == 1 and
    .sourceMatineePlayCallCount == 0 and
    .sourceMatineePlaybackControlCallCount == 0 and
    .sequencePlayerPlayCallCount == 1 and
    .validSequencePlaybackChainCount == 1 and
    .expectedSequencePlayerControlCallCount == 3 and
    .sequencePlayerControlCallCount == 3 and
    .validSequencePlaybackControlChainCount == 3 and
    .sequencePlayerControlCounts == {"Play": 1, "Stop": 2} and
    .validSequencePlaybackControlCounts == {"Play": 1, "Stop": 2} and
    (.playbackControlChains | length) == 3 and
    ([.playbackControlChains[].outgoingExecCount] | sort) == [0, 1, 1] and
    all(.playbackControlChains[]; valid_control_chain($audit))
  ) and
  (.directorBlueprint |
    .graphCount == (.graphs | length) and
    .graphCount > 0 and
    ([.graphs[].nodes[] |
      select(
        .class == "K2Node_CallFunction" and
        .functionName == "ExecuteConsoleCommand"
      ) |
      .pins[] |
      select(.name == "Command" and .direction == "input") |
      .defaultValue
    ] | sort) == ["CE ZenSeq_EndOfMatinee", "CE ZenSeq_Hitcher"] and
    ([.graphs[].nodes[] | select(.class == "K2Node_Literal")] | length) == 0
  ) and
  (.sourceCleanup |
    .requested == $source_cleanup_requested and
    if $source_cleanup_requested then
      .applied == true and
      .verified == true and
      .sourceActorPath == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0" and
      .controllersRemoved == 1 and
      .sourceActorLiteralsRemoved == 3 and
      .sourceActorLiteralLinkCountBeforeRemoval == 0 and
      .remainingTargetControllerCount == 0 and
      .remainingTargetLiteralCount == 0 and
      .remainingMatineePlayCallCount == 1 and
      .remainingSourceMatineePlaybackControlCallCount == 0 and
      .sequencePlayerPlayCallCount == 1 and
      .validSequencePlaybackChainCount == 1 and
      .expectedSequencePlayerControlCallCount == 3 and
      .sequencePlayerControlCallCount == 3 and
      .validSequencePlaybackControlChainCount == 3 and
      .sequencePlayerControlCounts == {"Play": 1, "Stop": 2} and
      .validSequencePlaybackControlCounts == {"Play": 1, "Stop": 2} and
      (.playbackControlChains | length) == 3 and
      ([.playbackControlChains[].outgoingExecCount] | sort) == [0, 1, 1] and
      all(.playbackControlChains[]; valid_control_chain($audit)) and
      .remainingWorldActorCount == 0 and
      .remainingMapMatineeActorCount == 1 and
      .remainingMapMatineeActors == [{
        "actor": "MatineeActor3",
        "objectPath": "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3"
      }] and
      .sequenceActorCount == 1 and
      .expectedCustomEventCount == 2 and
      .verifiedCustomEventCount == 2 and
      .eventAuditCount == 2 and
      (.events | length) == 2 and
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
      .graphs[0].nodeCount == 190 and
      .graphs[0].nodeCount == (.graphs[0].nodes | length) and
      ([.graphs[0].nodes[] |
        select(
          .class == "K2Node_MatineeController" and
          .referencedObject == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0"
        )
      ] | length) == 0 and
      ([.graphs[0].nodes[] |
        select(
          .class == "K2Node_Literal" and
          .referencedObject == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_0"
        )
      ] | length) == 0 and
      ([.graphs[0].nodes[] |
        select(
          .class == "K2Node_MatineeController" and
          .referencedObject == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3"
        )
      ] | length) == 1 and
      ([.graphs[0].nodes[] |
        select(
          .class == "K2Node_Literal" and
          .referencedObject == "/Game/Maps/Zen_P.Zen_P:PersistentLevel.MatineeActor_3"
        )
      ] | length) == 3
    else
      .applied == false and
      .verified == false
    end
  )
)
