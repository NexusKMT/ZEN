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

Before saving anything, the commandlet requires the expected `Zen_Movie` actor
and the source Director, Fade, Sound, Event, and Toggle tracks. It then requires
the generated Sequencer asset to contain Camera Cut, Fade, Audio, Event, and
Particle tracks before it saves anything. Any warning from Epic's converter is
a hard failure because unsupported tracks can otherwise be dropped. The first
bridge deliberately retains the legacy Matinee actor beside the generated
Level Sequence so their behavior can be compared before source cleanup is
authorized as a separate migration step.

The successful command writes:

```text
Saved/ZenMigration/ue427-bridge-report.json
```

The adapter deliberately targets UE 4.27.2. The workflow pulls Epic's documented
`dev-4.27` tag and then requires `Engine/Build/Build.version` to report exactly
4.27.2 before compiling. Its build must fail if Epic moves or changes the
private converter implementation, because silently running a different
conversion path would make the migration result untrustworthy.
