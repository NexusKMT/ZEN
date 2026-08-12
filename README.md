# ZEN

ZEN is a public migration and CI harness for validating a licensed UE 4.23
sample against newer Unreal Engine toolchains.

The repository intentionally does not contain:

- the licensed source content archive;
- Unreal Engine source from EpicGames/UnrealEngine;
- files from any other private Epic Games repository;
- cloud storage configuration or credentials.

Authorized workflows will obtain the project archive at runtime. Repository
secrets are used only to create temporary runner-local configuration.

## UE 4.27 to UE 5 migration workflow

The manually dispatched `UE 4.27 to UE 5 migration probe` workflow stages and
optionally converts the clean licensed project without adding source content to
this public repository. It:

1. reclaims the preinstalled runner payload with the same pinned
   `jlumbroso/free-disk-space` action validated by the disk-probe repository;
2. installs a pinned transfer client after verifying its release archive;
3. retrieves the project ZIP, SHA-256 sidecar, and archive metadata from the
   single authorized remote configured through repository secrets;
4. compares OneDrive's server-side QuickXorHash, the local QuickXorHash, the
   SHA-256 sidecar, the local SHA-256, and the expected archive length;
5. rejects paths or symbolic links that could escape the extraction root, then
   verifies the expanded project's file count and logical byte count;
6. optionally creates a writable project copy without the stale UE 4.23 DDC,
   builds the repository's bridge commandlet with Epic's documented
   `ghcr.io/epicgames/unreal-engine:dev-4.27` image, verifies that the image
   contains UE 4.27.2, inventories all Matinee actors, and serially converts
   `/Game/Maps/Zen_Movie:MatineeActor_Movie`,
   `/Game/Maps/Zen_P:MatineeActor`, and
   `/Game/Maps/Zen_P:MatineeActor3`. It retains those legacy actors by default
   or removes each one through an explicit audited input; the final `Zen_P`
   cleanup also validates and removes the exact unreachable historical
   `Unknown` Matinee-control cluster. It then resaves the runner-local project
   copy with UE 4.27.2, directly uploads its reusable project directories to
   the authorized private remote with rclone, and verifies the transfer with
   `rclone check`;
7. when a UE 5 stage is requested, downloads that private rclone transfer into
   a separate fresh project root, selects it as the UE 5 input, then pulls
   the selected Epic UE 5 development image, verifies its `Build.version`, and
   starts a Python commandlet against the completed UE 4.27
   output, and loads both `/Game/Maps/Zen_Movie` and `/Game/Maps/Zen_P` plus
   all three generated Level Sequences while Content remains mounted
   read-only;
8. optionally runs Epic's command-line Cook flow for Linux against those two
   maps, proves all three generated Level Sequences reached the cooked output,
   and uploads only its text log and sorted file manifest;
9. optionally uses Unreal Automation Tool to build, cook, stage, package, and
   archive a Linux Development build, rejects loose source asset packages,
   verifies the staged launcher, Pak payload, and Linux binaries, then
   headlessly launches both maps from the staged package and enumerates all
   three generated Level Sequences at runtime.

The original expanded UE 4.23 project is always retained unchanged. The bridge
commandlet verifies the expected Director, Fade, Sound, Event, and Toggle
tracks before conversion and the resulting Camera Cut, Fade, Audio, Event, and
keyed Toggle outputs before it saves anything. Converter warnings are fatal except
for UE 4.27's exact, captured Fade false positive when the generated Fade track
is independently verified. Its post-rewrite audits require all twelve target
Level Blueprint event entries, including the two separate Event Tracks on
`MatineeActor3`, to retain their original first-hop behavior. They require
every rewritten `Play`, `Pause`, or `Stop` call to preserve its complete set of incoming and
outgoing execution links and its complete LevelSequenceActor player data
chain, and requires zero source-targeted Blueprint Matinee controls or compile
errors. With `remove_source_matinee=true`, each commandlet invocation requires
exactly one target Controller and all target Actor literals to be disconnected
by the verified rewrite, removes those nodes and the target source Actor,
recompiles, and proves the event first-hop paths and all Level Sequence control
chains still match. When the target is the final Matinee in a map, cleanup
additionally requires every unresolved Matinee literal link to be a known,
execution-unreachable Matinee control before removing that historical cluster,
then proves the map and Level Blueprint contain no Matinee actors or controls.
See
[`automation/ue427/README.md`](automation/ue427/README.md) for its boundary and
implementation rationale.

The workflow enforces the migration order. `run_ue_container=true` is rejected
unless `run_ue427_bridge=true`, so the selected UE 5 runtime cannot be pointed
at the original UE 4.23 input by this workflow. The `ue5_version` choice is
restricted to `5.4.4` and the previously validated `5.5.4`; `5.4.4` is the
default target. `run_ue5_cook=true` additionally requires source cleanup and a
strict UE 5 load probe in the same run. `run_ue5_stage=true` additionally
requires that strict Linux Cook in the same run.

### Required repository secrets

| Purpose | Requirement |
| --- | --- |
| Cloud archive and intermediate access | Repository secret containing exactly one authorized remote configuration. It supplies the source archive and stores reusable private stage transfers. Required for every run. |
| `GHCR_TOKEN` | Classic GitHub PAT belonging to the repository owner, with `read:packages` and Epic Unreal Engine access. Required for either engine stage. |

The workflow is `workflow_dispatch` only, so pull requests and forks cannot
cause cloud downloads or receive secrets. The transfer configuration is written with
owner-only permissions below `RUNNER_TEMP` and removed when the transfer step
ends. The downloaded archive and expanded project remain runner-local and are
never uploaded as GitHub artifacts.

### Private rclone stage boundaries

The authorized private rclone remote is the durable boundary between expensive
engine stages. A completed UE 4.27 bridge uploads the project directory directly
below `ZEN/intermediate/v1/<stage>/<transfer-key>/project`, where `<stage>` is
`ue427-retained` or `ue427-clean`. It includes the project descriptor,
`Config`, `Content`, `Build`, `Plugins`, `Source`, `Binaries`, and
`Saved/ZenMigration`; it excludes DDC, `Intermediate`, and other transient
`Saved` output. No tar or custom checkpoint envelope is created.

Every upload is followed by an exact `rclone check`. When the same run continues
into UE 5, it downloads that remote directory into a separate fresh project
root, selects the download as the consumer input, and runs another exact
`rclone check`.
This makes the UE 5 stage consume the rclone transfer rather than files left by
the producer step. The Actions summary records the stage and transfer key, so a
later workflow can accept the same key without rebuilding UE 4.27.

This is the first extraction boundary for gradually decomposing the current
workflow. The `UE 5 probe from rclone transfer` workflow is the first independent
consumer: it accepts an existing stage and transfer key, downloads the project,
and runs the same strict UE 5 probe without repeating archive retrieval or UE
4.27 conversion. A later UE 5-native project boundary can use the same
direct-directory convention before Linux Cook and packaging are separated.
Cook or package outputs should become additional rclone boundaries only when a
downstream workflow actually consumes them.

Licensed GHCR image pulls retry only when GitHub explicitly reports a
`secondary rate limit`. In that case the workflow makes at most three attempts
with 60-second and 120-second waits, following GitHub's minimum one-minute and
exponential-backoff guidance. Authentication, missing-tag, and other pull
failures are not retried.

Run the asset-only verification with:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --field run_ue427_bridge=false \
  --field run_ue_container=false
```

After configuring `GHCR_TOKEN`, run the UE 4.27 conversion with:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --field run_ue427_bridge=true \
  --field run_ue_container=false
```

Set `run_ue427_bridge=true` and `run_ue_container=true` to pull the selected
UE 5 image, verify its embedded engine version, and run the map and Level
Sequence load probe against the UE 4.27 bridge output. The UE 5 commandlet gets
a writable temporary project shell, but its Content directory is a symbolic
link into the read-only bridge mount, so it cannot save
or upgrade licensed assets. The reusable UE 4.27 project is written to the
authorized private remote for later stage reuse. GitHub artifacts still contain
only the JSON migration audit and the text UE 4.27/UE 5 probe logs.

Reuse a completed clean UE 4.27 transfer without rerunning its producer with:

```bash
gh workflow run ue5-transfer-probe.yml \
  --repo NexusKMT/ZEN \
  --ref main \
  --field ue427_transfer_stage=ue427-clean \
  --field ue427_transfer_key=<key-from-the-producer-summary> \
  --field ue5_version=5.4.4
```

Run the source-cleanup gate only after the retained-source comparison has
passed:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --ref main \
  --field run_ue427_bridge=true \
  --field remove_source_matinee=true \
  --field run_ue_container=true \
  --field ue5_version=5.4.4
```

After the strict load probe passes, enable the next runtime-content gate with:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --ref main \
  --field run_ue427_bridge=true \
  --field remove_source_matinee=true \
  --field run_ue_container=true \
  --field run_ue5_cook=true \
  --field ue5_version=5.4.4
```

The opt-in cook stage follows
[Epic's command-line Cook contract](https://dev.epicgames.com/documentation/en-us/unreal-engine/cooking-content-in-unreal-engine)
and targets Linux with both converted maps. It requires the three generated
Level Sequences to appear in the cooked output and rejects Blueprint, Matinee
`CreateExport`, package, linker, asset-registry, material, texture, audio,
streaming, Level Sequence, and any other UE category errors or warnings. The
only allowed diagnostic is Epic's fixed three-shader-worker performance notice
from the constrained GitHub runner. Cooked licensed content remains
runner-local; GitHub receives only the text cook log and a sorted cooked-file
manifest.

After the strict Cook has passed, enable the Linux distribution gate with:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --ref main \
  --field run_ue427_bridge=true \
  --field remove_source_matinee=true \
  --field run_ue_container=true \
  --field run_ue5_cook=true \
  --field run_ue5_stage=true \
  --field ue5_version=5.4.4
```

The stage/runtime gate follows Epic's documented Linux `BuildCookRun` path and
uses `-build -cook -stage -package -pak -archive` with a runner-local archive
directory. It refuses a missing launcher, missing Linux binary or Pak payload,
or loose `.umap`/`.uasset` source packages in the distributable output. It
then starts `Zen_Movie` and `Zen_P` from that staged launcher using NullRHI,
no sound, and `-ExecCmds="obj list class=LevelSequence,quit"`. Each launch
must cleanly exit after loading its requested map with no UE error or warning;
the combined logs must enumerate every converted Level Sequence. The staged
package itself, executable, and licensed data remain runner-local. The uploaded
audit is limited to the UAT/runtime text logs and sorted staged file manifest.

The cleanup input is rejected unless the UE 4.27 bridge is enabled. It affects
only that stage's writable copy; the expanded UE 4.23 input remains unchanged.
Retained-source mode remains available for UE 4.27 bridge comparison, but the
strict UE 5 runtime probe rejects its serialized Matinee Blueprint residue.
With `remove_source_matinee=true`, the selected UE 5 probe requires zero
Blueprint compiler errors, zero Blueprint compiler warnings, zero Matinee
`CreateExport` warnings, two clean MapCheck results, and successful loading of
all three generated Level Sequences. Any warning or missing success marker
fails the run.

Epic's public container documentation does not enumerate private patch tags.
The workflow therefore treats both `dev-5.4.4` and `dev-5.5.4` as runtime
assertions: the selected pull must succeed after licensed GHCR authentication,
and `Engine/Build/Build.version` must exactly match `ue5_version` before the
image is accepted.

## Upstream references

Selected public Epic Games material is retained under references/EpicGames.
Every imported file has a narrow purpose, a pinned upstream commit, and its
original license. The references are not automatically compiled as project
plugins.

See docs/epicgames-org-selection.md for the selection rationale and
references/EpicGames/UPSTREAMS.md for exact provenance.
