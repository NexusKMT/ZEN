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
through the persistent map. Conversion is deliberately scoped to
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

The successful command writes:

```text
Saved/ZenMigration/ue427-bridge-report.json
```

The adapter deliberately targets UE 4.27.2. The workflow pulls Epic's documented
`dev-4.27` tag and then requires `Engine/Build/Build.version` to report exactly
4.27.2 before compiling. Its build must fail if Epic moves or changes the
private converter implementation, because silently running a different
conversion path would make the migration result untrustworthy.
