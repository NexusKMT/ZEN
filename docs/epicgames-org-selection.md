# EpicGames organization selection

Inventory date: 2026-08-07

The authenticated organization inventory contained 62 visible repositories:

- 56 public repositories;
- 6 private repositories;
- 24 archived repositories;
- 6 forks.

The scan covered repository metadata, default branches, license detection,
root trees, and recursive searches for Unreal project descriptors, Unreal
plugin descriptors, and GitHub Actions workflows.

## Selection rules

Files are imported only when all of the following are true:

1. The source repository is public.
2. Redistribution terms are explicit and copied with the selected files.
3. The material has a direct role in Zen Garden asset validation or headless
   Unreal automation.
4. Version-specific code is isolated under references and is not silently
   enabled in the UE5.5.4 project.
5. Binary assets, generated output, and unrelated examples are excluded.

## Selected sources

### EpicGames/Linter

Purpose: retain a concrete baseline for texture, Blueprint, path, naming, and
content-layout audits.

Only the guideline document and MIT license are retained. The plugin itself is
not imported because its descriptor targets Unreal Engine 4.26 and its README
still describes pending 4.27 work.

### EpicGames/CommandletPlugin

Purpose: retain the smallest official example of a headless Unreal commandlet
module as a reference for a future Zen migration audit command.

The source targets Unreal Engine 4.19. It therefore remains under references
instead of Plugins and is not compiled. Any production commandlet must be
ported deliberately to UE5.5.4 APIs.

## Deliberately excluded

### Private and EULA-gated repositories

EpicGames/UnrealEngine, EpicGames/zen, EpicGames/UnrealTournament,
EpicGames/UGCExample, EpicGames/ARTv2, and EpicGames/Shave-And-A-Haircut are
not copied into this public repository.

### Version-mismatched public examples

EpicGames/EOS-Getting-Started currently targets UE5.8. The public Linter
plugin targets UE4.26, CommandletPlugin targets UE4.19, and the ShotGrid
turntable fixtures stop at UE5.4. Their project or binary assets are not
injected into a UE5.5.4 migration.

### Unrelated active plugins

EpicGames/deadline is for Thinkbox Deadline render-farm submission and Movie
Render Pipeline distribution. It does not help package or migrate Zen Garden.

### Agent integration

EpicGames/unreal-engine-skills-for-claude-code-plugin requires the
ModelContextProtocol and AllToolsets editor plugins. Those requirements are
not assumed for the UE5.5.4 target, so its project configuration is not copied.

### GitHub Actions

The public organization workflows belong to Pixel Streaming, OpenRigLogic,
Lore, shader tools, and repository administration. No public Epic Games
workflow found in the scan builds a normal Unreal project with the licensed
engine container. The ZEN workflow must therefore be authored for this
project rather than copied from an unrelated repository.
