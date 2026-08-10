# UE 4.27 bridge automation

`ZenMatineeBridge` is a project-local editor commandlet built specifically for
the clean UE 4.23 Zen Garden sample and compiled by the UE 4.27.2 development
container.

Epic's 4.27 `MatineeToLevelSequence` plugin does not expose its conversion
entry point through its public module interface and creates assets through an
interactive picker. The bridge therefore compiles the converter implementation
from the engine image into a narrow adapter and substitutes the matching
non-interactive `CreateAsset` call. No Unreal Engine source is copied into this
public repository.

Before saving anything, the commandlet inventories Matinee actors across every
map by their owning level package and object name. This prevents an actor from
being counted twice when it is seen both in its own streaming-level map and
through the persistent map. Every loaded-map context is still retained for a
deduplicated actor so cross-level references are not hidden. The report records
each actor's track classes, playback/cinematic settings, and every in-memory
hard referencer found by UE 4.27's `FReferencerFinder` with inner-object
references excluded. This is a deletion preflight, not proof that a reference
can be rewritten automatically.

For referenced `K2Node_MatineeController` and `K2Node_Literal` objects, the
audit also serializes the containing graph, node GUID and title, every pin's
type/direction/default, and every direct pin connection. Controller output pins
compile to Matinee delegate events, while actor literals compile to level-actor
reference properties; those are separate migration problems and must remain
distinguishable in the report.

The report additionally captures every node and connection in each Level
Blueprint graph that contains one of those hard references. This preserves the
downstream event chains, function and variable identities, pin defaults, asset
defaults, and level-Actor bindings needed to design a behavior-preserving graph
rewrite. The workflow uploads only this JSON audit for seven days; it does not
upload project packages or Unreal Engine content.

Source Matinee Event Track keys are recorded with their names, times, and
forward/backward/jump flags. After conversion, every generated Sequencer event
key is matched back to the source key by track order and exact frame conversion,
and its serialized Director Blueprint endpoint is captured along with the full
Director graph. The audit also proves that repeated source names reuse one
endpoint and distinct source names never share an endpoint. This is necessary
because Epic's 4.27 converter creates generic `MatineeEvent` endpoint names;
the original Matinee event name is otherwise only present in a temporary map
during conversion.

UE 4.27 event endpoints cannot call Level Blueprint graphs by themselves. They
are `UK2Node_CustomEvent` nodes owned by the Sequence Director blueprint and are
invoked only through Sequencer's director compilation path
(`MovieSceneEventUtils`). The official converter leaves those endpoints
unconnected. The bridge therefore records an `eventRewritePlan` that pairs each
source event name and frame with its Director endpoint and the exact Level
Blueprint execution closure currently driven by `K2Node_MatineeController`,
plus every Level Blueprint Play/Pause/Stop/SetPosition call that still targets
the legacy Matinee actor. It also records the generated `ALevelSequenceActor`
path and playback settings so play-control rewrites have a concrete target.
After the plan is captured, the bridge rewrites graphs in-place: each Director
endpoint receives a clone of the MatineeController execution closure (with
LevelScriptActor self pins rebound for RemoteEvent), and Level Blueprint
Play calls that targeted the legacy Matinee actor are retargeted through the
generated LevelSequenceActor player. Playback settings such as force-start
time are copied onto the LevelSequenceActor. The legacy Matinee actor and
MatineeController nodes remain for comparison until a later cleanup step.


An unconnected actor literal is still a serialized hard reference. It is
reported and must be removed during graph cleanup even though it has no runtime
behavior to translate.

Conversion is deliberately scoped to
`/Game/Maps/Zen_Movie:MatineeActor_Movie`; the two additional Matinee actors
observed while `Zen_P` was loaded are inventoried but not modified.

The commandlet requires the target actor's Director, Fade, Sound, Event, and
Toggle tracks, then requires the generated Sequencer asset to contain Camera
Cut, Fade, Audio, Event, and Particle tracks before it saves anything.

Epic's 4.27 converter emits one false-positive `Unsupported track 'Fade'.`
warning from its generic group pass, then converts that Fade track in its
dedicated Director pass. The bridge captures converter warnings and accepts
only that exact text when the expected source Fade and generated
`MovieSceneFadeTrack` are both present. A changed warning count, changed text,
missing Fade output, or any additional warning is a hard failure because truly
unsupported tracks can otherwise be dropped. The first bridge deliberately
retains the legacy Matinee actor beside the generated Level Sequence so their
behavior can be compared before source cleanup is authorized as a separate
migration step.

This reference audit is required because Epic's 4.27 Matinee documentation
describes Level Blueprint function nodes as the usual way to control a Matinee
actor, while Epic's converter implementation only creates the new asset, actor,
bindings, and tracks. It does not rewrite Blueprint nodes or copy the source
actor's playback settings. Relevant official sources:

- [Matinee User Guide (UE 4.27)](https://dev.epicgames.com/documentation/en-us/unreal-engine/matinee-user-guide?application_version=4.27)
- [Matinee to Sequencer Conversion Tool (UE 4.27)](https://dev.epicgames.com/documentation/en-us/unreal-engine/converting-matinee-files-to-sequencer?application_version=4.27)

The successful command writes:

```text
Saved/ZenMigration/ue427-bridge-report.json
```

The adapter deliberately targets UE 4.27.2. The workflow pulls Epic's documented
`dev-4.27` tag and then requires `Engine/Build/Build.version` to report exactly
4.27.2 before compiling. Its build must fail if Epic moves or changes the
private converter implementation, because silently running a different
conversion path would make the migration result untrustworthy.
