import unreal


PROBES = (
    (
        "/Game/Maps/Zen_Movie",
        "Zen_Movie",
        "/Game/Maps/MatineeActor_MovieLevelSequence",
    ),
    (
        "/Game/Maps/Zen_P",
        "Zen_P",
        "/Game/Maps/MatineeActorLevelSequence",
    ),
)


unreal.log("ZEN_UE5_PROBE_BEGIN")

for map_path, expected_world_name, sequence_path in PROBES:
    world = unreal.EditorLoadingAndSavingUtils.load_map(map_path)
    if world is None:
        raise RuntimeError(f"Could not load required map: {map_path}")

    world_path = world.get_path_name()
    if expected_world_name not in world_path:
        raise RuntimeError(f"Loaded the wrong world: {world_path}")
    unreal.log(f"ZEN_UE5_PROBE_MAP_LOADED world={world_path}")

    sequence = unreal.load_asset(sequence_path)
    if sequence is None:
        raise RuntimeError(
            f"Could not load generated Level Sequence: {sequence_path}"
        )

    sequence_class = sequence.get_class().get_name()
    if sequence_class != "LevelSequence":
        raise RuntimeError(
            f"Generated asset has class {sequence_class}, expected LevelSequence"
        )
    unreal.log(
        "ZEN_UE5_PROBE_SEQUENCE_LOADED "
        f"asset={sequence.get_path_name()} class={sequence_class}"
    )
unreal.log("ZEN_UE5_PROBE_SUCCESS")
