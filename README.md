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

## Upstream references

Selected public Epic Games material is retained under references/EpicGames.
Every imported file has a narrow purpose, a pinned upstream commit, and its
original license. The references are not automatically compiled as project
plugins.

See docs/epicgames-org-selection.md for the selection rationale and
references/EpicGames/UPSTREAMS.md for exact provenance.
