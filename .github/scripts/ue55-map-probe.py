import unreal


MAP_PATH = "/Game/Maps/Zen_Movie"
SEQUENCE_PATH = "/Game/Maps/MatineeActor_MovieLevelSequence"


unreal.log("ZEN_UE55_PROBE_BEGIN")

world = unreal.EditorLoadingAndSavingUtils.load_map(MAP_PATH)
if world is None:
    raise RuntimeError(f"Could not load required map: {MAP_PATH}")

world_path = world.get_path_name()
if "Zen_Movie" not in world_path:
    raise RuntimeError(f"Loaded the wrong world: {world_path}")
unreal.log(f"ZEN_UE55_PROBE_MAP_LOADED world={world_path}")

sequence = unreal.load_asset(SEQUENCE_PATH)
if sequence is None:
    raise RuntimeError(f"Could not load generated Level Sequence: {SEQUENCE_PATH}")

sequence_class = sequence.get_class().get_name()
if sequence_class != "LevelSequence":
    raise RuntimeError(
        f"Generated asset has class {sequence_class}, expected LevelSequence"
    )
unreal.log(
    "ZEN_UE55_PROBE_SEQUENCE_LOADED "
    f"asset={sequence.get_path_name()} class={sequence_class}"
)
unreal.log("ZEN_UE55_PROBE_SUCCESS")
