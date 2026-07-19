extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const DEFAULT_SEED := "atlas-1492"
const SAMPLE_CELLS := [
    Vector2i(-84, -84), Vector2i(-56, 0), Vector2i(-28, 42), Vector2i(0, 0),
    Vector2i(28, 28), Vector2i(56, -28), Vector2i(84, 56), Vector2i(112, -56),
    Vector2i(140, 70), Vector2i(196, 0), Vector2i(280, 0), Vector2i(280, 25)
]
const SIGNATURE_READINESS_MAX_FRAMES := 1800
const SIGNATURE_STABLE_FRAMES := 12
const SURFACE_PROP_ATTEMPTS_PER_CHUNK := 28
const SIGNATURE_TOWN_CELL_OFFSET := Vector2i(0, 5)
const SIGNATURE_CHUNK_RADIUS := 3

var main
var output_path := ""
var seed := DEFAULT_SEED
var signature_center_chunk := Vector2i(2147483647, 2147483647)

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    output_path = OS.get_environment("VOXEL_WORLD_SIGNATURE_OUTPUT")
    if output_path == "":
        output_path = ProjectSettings.globalize_path("res://artifacts/world-signature/latest/atlas-1492.json")
    ensure_dir(output_path.get_base_dir())
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = DEFAULT_SEED
    OS.set_environment("VOXEL_TEST_SEED", seed)
    OS.set_environment("VOXEL_PLAYTEST", "1")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    if not await wait_for_signature_chunk_readiness("initial world"):
        finish(1)
        return
    prepare_world()
    if not await wait_for_signature_chunk_readiness("signature town"):
        finish(1)
        return
    freeze_world()
    complete_signature_surface_props()
    var signature := build_signature()
    write_json(output_path, signature)
    finish(0)

func finish(exit_code: int) -> void:
    # The signature fixture instantiates the real Main scene.  Its exit must
    # therefore use the same ordered shutdown as production, so generated
    # terrain and navigation resources retire before Godot tears down servers.
    # A direct SceneTree quit bypasses that contract and leaks the live-world
    # navigation graph even when the signature itself is correct.
    if main != null and is_instance_valid(main) and main.has_method("request_graceful_quit"):
        main.call("request_graceful_quit", exit_code)
        return
    get_tree().quit(exit_code)

func prepare_world() -> void:
    var town: Dictionary = main.town_region(1, 0)
    var cell := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))) + SIGNATURE_TOWN_CELL_OFFSET
    signature_center_chunk = main.call("cell_to_chunk", cell.x, cell.y)
    if main.has_method("teleport_to_cell"):
        main.teleport_to_cell(cell, "World signature")

func freeze_world() -> void:
    main.set_process(false)
    var player = main.get("player") as CharacterBody3D
    if player:
        player.set_physics_process(false)

func wait_for_signature_chunk_readiness(stage: String) -> bool:
    var stable_frames := 0
    var previous_chunk_count := -1
    for frame in range(SIGNATURE_READINESS_MAX_FRAMES):
        await get_tree().process_frame
        var chunks_value = main.get("chunks")
        var pending_loads_value = main.get("pending_chunk_loads")
        var chunk_count: int = int(chunks_value.size()) if chunks_value is Dictionary else -1
        var pending_load_count: int = int(pending_loads_value.size()) if pending_loads_value is Dictionary else -1
        var loading_active := bool(main.get("startup_loading_active"))
        var canonical_window_ready := true
        if signature_center_chunk.x != 2147483647 and chunks_value is Dictionary:
            canonical_window_ready = signature_window_is_loaded(chunks_value as Dictionary)
        var chunk_queue_drained: bool = not loading_active and pending_load_count == 0 and canonical_window_ready
        if chunk_queue_drained and chunk_count == previous_chunk_count:
            stable_frames += 1
        else:
            stable_frames = 0
        previous_chunk_count = chunk_count
        if stable_frames >= SIGNATURE_STABLE_FRAMES:
            print("World signature chunk readiness: %s chunks=%d frame=%d" % [stage, chunk_count, frame])
            return true
    push_error("World signature chunk readiness timed out: %s chunks=%d" % [stage, previous_chunk_count])
    return false

func complete_signature_surface_props() -> void:
    var pending_value = main.get("pending_chunk_prop_spawns")
    if not (pending_value is Dictionary):
        return
    var pending: Dictionary = pending_value
    var keys: Array = pending.keys()
    keys.sort_custom(func(first, second): return chunk_key_text(first) < chunk_key_text(second))
    var completed_attempts := 0
    for key in keys:
        var state_value = pending.get(key)
        if not (state_value is Dictionary):
            continue
        var state: Dictionary = state_value
        var rng := state.get("rng") as RandomNumberGenerator
        if rng == null:
            continue
        var prop_index := int(state.get("propIndex", 0))
        while prop_index < SURFACE_PROP_ATTEMPTS_PER_CHUNK:
            main.call("spawn_chunk_prop_attempt", state, prop_index, rng)
            prop_index += 1
            completed_attempts += 1
        state["propIndex"] = prop_index
    print("World signature completed pending surface prop attempts: %d" % completed_attempts)

func chunk_key_text(value) -> String:
    if value is Vector2i:
        return "%08d,%08d" % [value.x + 100000, value.y + 100000]
    return String(value)

func build_signature() -> Dictionary:
    return {
        "schemaVersion": 2,
        "fixtureContract": "explicit_canonical_chunk_window_with_completed_surface_prop_attempts",
        "fixtureWindow": {
            "centerChunk": vec2i(signature_center_chunk),
            "radius": SIGNATURE_CHUNK_RADIUS,
            "keys": signature_window_chunk_keys()
        },
        "seed": seed,
        "terrainSamples": terrain_samples(),
        "loadedChunkKeys": loaded_chunk_keys(),
        "props": prop_records(),
        "structureCounts": sorted_dictionary(main.structure_counts()),
        "generatedTierCounts": sorted_dictionary(main.generated_tier_counts()),
        "generatedBlocks": generated_block_records(),
        "townHomeRecords": town_home_records()
    }

func terrain_samples() -> Array:
    var samples := []
    for cell in SAMPLE_CELLS:
        samples.append({
            "cell": vec2i(cell),
            "height": snapped_float(float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))),
            "biome": String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
        })
    return samples

func loaded_chunk_keys() -> Array:
    # The fixture has one declared observation window. Readiness proves the
    # whole window is published before serializing it, rather than recording
    # whichever chunks the streaming loop happened to retain.
    return signature_window_chunk_keys()

func signature_window_chunk_keys() -> Array:
    var keys: Array[String] = []
    if signature_center_chunk.x == 2147483647:
        return keys
    for x in range(signature_center_chunk.x - SIGNATURE_CHUNK_RADIUS, signature_center_chunk.x + SIGNATURE_CHUNK_RADIUS + 1):
        for z in range(signature_center_chunk.y - SIGNATURE_CHUNK_RADIUS, signature_center_chunk.y + SIGNATURE_CHUNK_RADIUS + 1):
            keys.append("%d,%d" % [x, z])
    keys.sort()
    return keys

func signature_window_is_loaded(chunks: Dictionary) -> bool:
    if signature_center_chunk.x == 2147483647:
        return true
    for x in range(signature_center_chunk.x - SIGNATURE_CHUNK_RADIUS, signature_center_chunk.x + SIGNATURE_CHUNK_RADIUS + 1):
        for z in range(signature_center_chunk.y - SIGNATURE_CHUNK_RADIUS, signature_center_chunk.y + SIGNATURE_CHUNK_RADIUS + 1):
            if not chunks.has(Vector2i(x, z)):
                return false
    return true

func prop_records() -> Array:
    var records := []
    collect_prop_records(main.get("chunk_root") as Node, records)
    collect_prop_records(main.get("prop_root") as Node, records)
    records.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
    return records

func collect_prop_records(root: Node, records: Array) -> void:
    if root == null:
        return
    for child in root.get_children():
        var node := child as Node
        if node == null:
            continue
        if String(node.get_meta("kind", "")) == "prop":
            var material_id := String(node.get_meta("material", ""))
            var stable_position: Vector3 = (node as Node3D).global_position if node is Node3D else Vector3.ZERO
            if material_id == "wildlife" and node.has_meta("wildlife_home"):
                stable_position = node.get_meta("wildlife_home", stable_position)
            if not prop_in_signature_window(stable_position):
                continue
            records.append({
                "id": String(node.get_meta("prop_id", node.name)),
                "kind": String(node.get_meta("kind", "")),
                "material": material_id,
                "drop": String(node.get_meta("drop", "")),
                "position": vec3(stable_position)
            })
        collect_prop_records(node, records)

func prop_in_signature_window(position: Vector3) -> bool:
    if signature_center_chunk.x == 2147483647:
        return true
    var cell := Vector2i(main.call("world_to_cell", position.x), main.call("world_to_cell", position.z))
    var chunk: Vector2i = main.call("cell_to_chunk", cell.x, cell.y)
    return abs(chunk.x - signature_center_chunk.x) <= SIGNATURE_CHUNK_RADIUS \
        and abs(chunk.y - signature_center_chunk.y) <= SIGNATURE_CHUNK_RADIUS

func generated_block_records() -> Array:
    var records := []
    var blocks: Dictionary = main.get("blocks")
    for cell_variant in blocks.keys():
        var body := blocks[cell_variant] as Node
        if body == null or not is_instance_valid(body):
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if not block_in_signature_town(cell):
            continue
        records.append({
            "cell": vec3i(cell),
            "type": String(body.get_meta("block_type", "")),
            "generated": bool(body.get_meta("generated", false)),
            "generatedTier": String(body.get_meta("generatedTier", "")),
            "secondary": bool(body.get_meta("secondary", false))
        })
    records.sort_custom(func(a, b): return block_sort_key(a) < block_sort_key(b))
    return records

func block_in_signature_town(cell: Vector3i) -> bool:
    var town: Dictionary = main.town_region(1, 0)
    var center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS)) + 22
    return abs(cell.x - center.x) <= radius and abs(cell.z - center.y) <= radius

func block_sort_key(record: Dictionary) -> String:
    var cell: Dictionary = record["cell"]
    return "%08d,%08d,%08d,%s" % [int(cell["x"]) + 100000, int(cell["y"]) + 100000, int(cell["z"]) + 100000, String(record["type"])]

func town_home_records() -> Dictionary:
    var structure_system = main.get("structure_system")
    if structure_system == null or not structure_system.has_method("town_home_records_snapshot"):
        return {}
    var source: Dictionary = structure_system.town_home_records_snapshot()
    var result := {}
    var keys := []
    for key in source.keys():
        keys.append(String(key))
    keys.sort()
    for key in keys:
        var records := []
        for record_value in source[key]:
            var record: Dictionary = record_value
            records.append({
                "id": String(record.get("id", "")),
                "townKey": String(record.get("townKey", "")),
                "townCenter": vec2i(record.get("townCenter", Vector2i.ZERO)),
                "townRadius": int(record.get("townRadius", 0)),
                "level": snapped_float(float(record.get("level", 0.0))),
                "homeCell": vec2i(record.get("homeCell", Vector2i.ZERO)),
                "porchCell": vec2i(record.get("porchCell", Vector2i.ZERO)),
                "guardCell": vec2i(record.get("guardCell", Vector2i.ZERO)),
                "buildingIndex": int(record.get("buildingIndex", 0))
            })
        records.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
        result[key] = records
    return result

func sorted_dictionary(source: Dictionary) -> Dictionary:
    var result := {}
    var keys := []
    for key in source.keys():
        keys.append(String(key))
    keys.sort()
    for key in keys:
        result[key] = source[key]
    return result

func wait_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func ensure_dir(path: String) -> void:
    var err := DirAccess.make_dir_recursive_absolute(path)
    if err != OK and err != ERR_ALREADY_EXISTS:
        push_error("Could not create directory %s: %s" % [path, str(err)])

func write_json(path: String, value) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write world signature: %s" % path)
        return
    file.store_string(JSON.stringify(value, "  "))
    file.close()

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3i(value: Vector3i) -> Dictionary:
    return { "x": value.x, "y": value.y, "z": value.z }

func vec3(value: Vector3) -> Dictionary:
    return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }

func snapped_float(value: float) -> float:
    return snappedf(value, 0.001)
