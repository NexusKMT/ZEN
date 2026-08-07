# ZEN

ZEN is the public migration and CI harness for validating the Epic Zen Garden
sample against newer Unreal Engine toolchains.

The repository intentionally does not contain:

- the Zen Garden content archive;
- Unreal Engine source from EpicGames/UnrealEngine;
- files from any other private Epic Games repository;
- rclone configuration or cloud credentials.

Authorized workflows will obtain the project archive at runtime. Repository
secrets are used only to create temporary runner-local configuration.

## UE 4.27 to 5.5.4 migration workflow

The manually dispatched `UE 4.27 to 5.5.4 migration probe` workflow stages and
optionally converts the clean Zen Garden project without adding licensed
content to this public repository. It:

1. reclaims the preinstalled runner payload with the same pinned
   `jlumbroso/free-disk-space` action validated by the disk-probe repository;
2. installs the pinned rclone 1.75.0 Linux binary after verifying its release
   archive;
3. retrieves the project ZIP, SHA-256 sidecar, and archive metadata from the
   `ZEN/` directory of the single remote in the repository rclone config;
4. compares OneDrive's server-side QuickXorHash, the local QuickXorHash, the
   SHA-256 sidecar, the local SHA-256, and the expected archive length;
5. rejects paths or symbolic links that could escape the extraction root, then
   verifies the expanded project's file count and logical byte count;
6. optionally creates a writable project copy without the stale UE 4.23 DDC,
   builds the repository's bridge commandlet with Epic's documented
   `ghcr.io/epicgames/unreal-engine:dev-4.27` image, verifies that the image
   contains UE 4.27.2, inventories all Matinee actors, converts only
   `/Game/Maps/Zen_Movie:MatineeActor_Movie`, retains that legacy actor for
   comparison, and resaves the project with UE 4.27.2;
7. optionally pulls Epic's `ghcr.io/epicgames/unreal-engine:dev-5.5.4` image
   and starts a read-only probe against the completed UE 4.27 output.

The original expanded UE 4.23 project is always retained unchanged. The bridge
commandlet verifies the expected Director, Fade, Sound, Event, and Toggle
tracks before conversion and the resulting Camera Cut, Fade, Audio, Event, and
Particle tracks before it saves anything. Converter warnings are fatal except
for UE 4.27's exact, captured Fade false positive when the generated Fade track
is independently verified. Source Matinee cleanup remains a separate audited
decision after functional comparison. See
[`automation/ue427/README.md`](automation/ue427/README.md) for its boundary and
implementation rationale.

The workflow enforces the migration order. `run_ue_container=true` is rejected
unless `run_ue427_bridge=true`, so UE 5.5.4 cannot be pointed at the original
UE 4.23 input by this workflow.

### Required repository secrets

| Secret | Used for |
| --- | --- |
| `RCLONE_CONFIG` | Complete rclone configuration containing exactly one remote. Required for every run. |
| `GHCR_TOKEN` | Classic GitHub PAT belonging to the repository owner, with `read:packages` and Epic Unreal Engine access. Required for either engine stage. |

The workflow is `workflow_dispatch` only, so pull requests and forks cannot
cause cloud downloads or receive secrets. The rclone config is written with
owner-only permissions below `RUNNER_TEMP` and removed when the transfer step
ends. The downloaded archive and expanded project remain runner-local and are
never uploaded as GitHub artifacts.

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

Set both inputs to `true` to pull UE 5.5.4, verify its embedded engine version,
and run only an image/read-only-mount probe against the UE 4.27 bridge output.
This step does not open or save the converted project with UE 5.5.4. Engine-stage
outputs remain runner-local and are not uploaded to GitHub artifacts or written
back to OneDrive.

Epic's public container documentation does not enumerate private patch tags.
The workflow therefore treats `dev-5.5.4` as a runtime assertion: the pull must
succeed after licensed GHCR authentication, and `Engine/Build/Build.version`
must report exactly 5.5.4 before the image is accepted.

## Upstream references

Selected public Epic Games material is retained under references/EpicGames.
Every imported file has a narrow purpose, a pinned upstream commit, and its
original license. The references are not automatically compiled as project
plugins.

See docs/epicgames-org-selection.md for the selection rationale and
references/EpicGames/UPSTREAMS.md for exact provenance.
