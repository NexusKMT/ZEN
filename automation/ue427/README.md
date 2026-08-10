# UE 4.27 bridge automation

`ZenMatineeBridge` is a project-local editor commandlet built specifically for
the clean licensed UE 4.23 source project and compiled by the UE 4.27.2
development container.

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
endpoint executes the built-in `CE ZenSeq_*` console command for a new Level
Blueprint custom event that joins the existing MatineeController execution
chain. This name-based dispatch avoids serializing a LevelScriptActor literal
or its map-owned generated class into the standalone Level Sequence package.
Level Blueprint `Play`, `Pause`, and `Stop` calls that target a selected legacy
Matinee actor are retargeted to the same function on the generated
LevelSequenceActor player. Each rewrite records the exact incoming and outgoing
execution-pin identities before and after replacement; a changed link fails
the commandlet. Playback settings
such as force-start time are copied onto the LevelSequenceActor. By default,
the legacy Matinee actor and MatineeController node remain for comparison.
After both Blueprint rewrites compile, the report captures the final Level
Blueprint graphs separately from the preflight snapshots. It requires the
exact target-specific `ZenSeq_*` custom events, proves that each event reaches
the same first-hop execution pin as its source MatineeController output, proves
every LevelSequenceActor literal and `GetSequencePlayer` data chain into the
corresponding playback control, and requires the preserved incoming and
outgoing execution links. Any remaining source-targeted Matinee playback
control or either Blueprint compile status reporting an error fails the
commandlet and the workflow audit.
The generated Level Sequence package is then saved explicitly and its on-disk
size is verified before the bridge reports success; an in-memory asset path is
not accepted as evidence that the selected UE 5 runtime can load the conversion
output.


An unconnected actor literal is still a serialized hard reference. It is
reported and must be removed during graph cleanup even though it has no runtime
behavior to translate.

Source cleanup is an explicit opt-in through `-RemoveSourceMatinee`, passed by
the workflow only when `remove_source_matinee=true`. After the post-rewrite
audit and explicit Level Sequence package save, the commandlet requires exactly
one Controller for the target source Actor and at least one source-Actor
literal, with every literal reduced to zero pin links by the verified playback
rewrite. It deletes those Blueprint nodes, recompiles without a Blueprint
error, and verifies the final graph contains no target Controller, target
source-Actor literal, or source-targeted Matinee playback control. It also
rechecks every target `ZenSeq_*` first-hop destination before deleting the
target Actor from the world. After deletion it proves the generated Sequence
Actor remains unique, revalidates every complete
`LevelSequenceActor -> GetSequencePlayer -> playback control` data and
execution chain, inventories the remaining Matinee actors in that map, and
captures the resulting graph.

The workflow invokes the commandlet serially for
`/Game/Maps/Zen_Movie:MatineeActor_Movie` and
`/Game/Maps/Zen_P:MatineeActor` in its writable UE 4.27 copy. The clean expanded
UE 4.23 input is never overwritten, and `Zen_P:MatineeActor3` remains untouched.
When the cleaned output is opened by the selected UE 5 probe, only the exact
three known transitional warnings for that deferred actor are accepted;
retained-source mode requires the exact nine-warning set for all three legacy
actors. The workflow currently allows exact `5.4.4` and `5.5.4` runtime checks,
with `5.4.4` as the default.

Conversion is deliberately scoped to the two targets above. The additional
`Zen_P:MatineeActor3` is inventoried and asserted to remain after the second
target cleanup, but is not converted in this stage.

`Zen_P` also contains one source-authored `Unknown` Matinee actor literal. Its
four linked `Play`, `Pause`, and `SetPosition` calls predate the bridge and are
not references to either migration target. The bridge preserves this historical
graph content, but classifies every remaining Matinee control by its self target
and audits whether its execution chain reaches an event/controller entry. The
target gate accepts only the exact known node and literal GUIDs: all four
unresolved calls must remain disconnected from an execution entry, while the
three resolved calls must still target the deliberately deferred
`MatineeActor3`. Any additional or differently wired Matinee control fails the
gate. Source playback-control identities are captured before their nodes are
rewritten, so the recorded plan and the final rewrite count must also agree.

Each invocation receives an explicit target-specific source and Sequencer track
contract. The Movie target requires Director, Fade, Sound, Event, Toggle,
Movement, and Float tracks and their corresponding outputs. The first `Zen_P`
target has no Sound track, so it instead requires Director, Fade, Event,
Toggle, Movement, and Float tracks and the matching non-audio outputs. The
bridge separately audits Toggle key counts: a keyed source Toggle requires a
generated Particle track, while an empty source Toggle does not require an
empty Sequencer track.

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
- [Custom Events (UE 4.27)](https://dev.epicgames.com/documentation/en-us/unreal-engine/custom-events-in-unreal-engine?application_version=4.27)
- [Execute Console Command](https://dev.epicgames.com/documentation/en-us/unreal-engine/BlueprintAPI/Development/ExecuteConsoleCommand)

The successful serial conversion writes:

```text
Saved/ZenMigration/ue427-bridge-report-zen-movie.json
Saved/ZenMigration/ue427-bridge-report-zen-p-matineeactor.json
```

The adapter deliberately targets UE 4.27.2. The workflow pulls Epic's documented
`dev-4.27` tag and then requires `Engine/Build/Build.version` to report exactly
4.27.2 before compiling. Its build must fail if Epic moves or changes the
private converter implementation, because silently running a different
conversion path would make the migration result untrustworthy.
