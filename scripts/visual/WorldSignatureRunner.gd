extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const SEED := "atlas-1492"
const SAMPLE_CELLS := [
    Vector2i(-84, -84), Vector2i(-56, 0), Vector2i(-28, 42), Vector2i(0, 0),
    Vector2i(28, 28), Vector2i(56, -28), Vector2i(84, 56), Vector2i(112, -56),
    Vector2i(140, 70), Vector2i(196, 0), Vector2i(280, 0), Vector2i(280, 25)
]

var main
var output_path := ""

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    output_path = OS.get_environment("VOXEL_WORLD_SIGNATURE_OUTPUT")
    if output_path == "":
        output_path = ProjectSettings.globalize_path("res://artifacts/world-signature/latest/atlas-1492.json")
    ensure_dir(output_path.get_base_dir())
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_frames(90)
    prepare_world()
    var signature := build_signature()
    write_json(output_path, signature)
    get_tree().quit(0)

func prepare_world() -> void:
    var town: Dictionary = main.town_region(1, 0)
    var cell := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)) + 5)
    if main.has_method("teleport_to_cell"):
        main.teleport_to_cell(cell, "World signature")
    main.set_process(false)
    var player = main.get("player") as CharacterBody3D
    if player:
        player.set_physics_process(false)

func build_signature() -> Dictionary:
    return {
        "seed": SEED,
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
            "height": snapped_float(main.terrain_height_cell(cell.x, cell.y)),
            "biome": main.biome_at_cell(cell.x, cell.y)
        })
    return samples

func loaded_chunk_keys() -> Array:
    var keys := []
    var chunks: Dictionary = main.get("chunks")
    for key_variant in chunks.keys():
        var key: Vector2i = key_variant
        keys.append("%d,%d" % [key.x, key.y])
    keys.sort()
    return keys

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
            records.append({
                "id": String(node.get_meta("prop_id", node.name)),
                "kind": String(node.get_meta("kind", "")),
                "material": material_id,
                "drop": String(node.get_meta("drop", "")),
                "position": vec3(stable_position)
            })
        collect_prop_records(node, records)

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
