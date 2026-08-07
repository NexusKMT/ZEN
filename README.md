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

## UE 5.5.4 asset workflow

The manually dispatched `UE 5.5.4 asset probe` workflow stages the clean Zen
Garden project without adding licensed content to this public repository. It:

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
6. optionally pulls Epic's `ghcr.io/epicgames/unreal-engine:dev-5.5.4` image
   and starts the editor version probe with the project mounted read-only.

The optional container stage is deliberately non-destructive. It does not
convert the UE 4.23 project or save it with UE 5.5.4. The UE 4.27 bridge and
Matinee-to-Sequencer conversion remain separate migration work.

### Required repository secrets

| Secret | Used for |
| --- | --- |
| `RCLONE_CONFIG` | Complete rclone configuration containing exactly one remote. Required for every run. |
| `GHCR_TOKEN` | Classic GitHub PAT belonging to the repository owner, with `read:packages` and Epic Unreal Engine access. Required only when `run_ue_container` is enabled. |

The workflow is `workflow_dispatch` only, so pull requests and forks cannot
cause cloud downloads or receive secrets. The rclone config is written with
owner-only permissions below `RUNNER_TEMP` and removed when the transfer step
ends. The downloaded archive and expanded project remain runner-local and are
never uploaded as GitHub artifacts.

Run the asset-only verification with:

```bash
gh workflow run ue55-asset-probe.yml \
  --repo NexusKMT/ZEN \
  --field run_ue_container=false
```

After configuring `GHCR_TOKEN`, set `run_ue_container=true` to include the
official UE 5.5.4 image probe.

## Upstream references

Selected public Epic Games material is retained under references/EpicGames.
Every imported file has a narrow purpose, a pinned upstream commit, and its
original license. The references are not automatically compiled as project
plugins.

See docs/epicgames-org-selection.md for the selection rationale and
references/EpicGames/UPSTREAMS.md for exact provenance.
