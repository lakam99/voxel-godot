extends Node
class_name RegionStoryGenerator

const GENERATION_VERSION := 1

var world_seed_text := ""
var world_seed_hash := 0
var region_cell_size := 1

func setup(seed_text: String, seed_hash: int, town_region_cells: int) -> void:
    world_seed_text = seed_text
    world_seed_hash = seed_hash
    region_cell_size = maxi(1, town_region_cells)

func region_id_for_cell(cell: Vector2i) -> String:
    var region_x := floori(float(cell.x) / float(region_cell_size))
    var region_z := floori(float(cell.y) / float(region_cell_size))
    return "r:%d,%d" % [region_x, region_z]

func region_coords(region_id: String) -> Vector2i:
    if not region_id.begins_with("r:"):
        return Vector2i.ZERO
    var body := region_id.substr(2)
    var comma := body.find(",")
    if comma < 0:
        return Vector2i.ZERO
    return Vector2i(int(body.substr(0, comma)), int(body.substr(comma + 1)))

func region_id_from_coords(coords: Vector2i) -> String:
    return "r:%d,%d" % [coords.x, coords.y]

func region_center_cell(region_id: String) -> Vector2i:
    var coords := region_coords(region_id)
    return Vector2i(
        coords.x * region_cell_size + floori(float(region_cell_size) * 0.5),
        coords.y * region_cell_size + floori(float(region_cell_size) * 0.5)
    )

func generate_region_record(seed_text: String, seed_hash: int, region_id: String, dominant_biome := "") -> Dictionary:
    var coords := region_coords(region_id)
    var stable_seed := stable_hash("%s|%d|%s|region-story-v1" % [seed_text, seed_hash, region_id])
    var biome := dominant_biome
    if biome == "":
        biome = stable_pick(["forest", "taiga", "plains", "swamp", "savanna", "alpine"], stable_seed, "biome")
    return {
        "schemaVersion": 1,
        "generationVersion": GENERATION_VERSION,
        "id": region_id,
        "regionX": coords.x,
        "regionZ": coords.y,
        "seed": stable_seed,
        "dominantBiome": biome,
        "state": "rumored",
        "worldmark": {
            "id": "worldmark:%s" % region_id,
            "definitionId": "pending_worldmark",
            "domain": stable_pick(["storm_and_light", "roots_and_memory", "stone_and_echo", "mist_and_paths"], stable_seed, "domain"),
            "condition": stable_pick(["bound", "wounded", "lost", "guarding"], stable_seed, "condition"),
            "desire": stable_pick(["quiet", "repair", "return", "safe_boundary"], stable_seed, "desire"),
            "publicBeliefId": "pending_public:%s" % region_id,
            "hiddenTruthId": "pending_truth:%s" % region_id,
            "foundClueIds": [],
            "preparationFlags": {},
            "encounterState": {},
            "resolution": ""
        },
        "settlement": {
            "tier": 0,
            "flags": {}
        },
        "generatedText": {}
    }

func record_for_region_id(region_id: String, dominant_biome := "") -> Dictionary:
    return generate_region_record(world_seed_text, world_seed_hash, region_id, dominant_biome)

func stable_pick(options: Array, seed_value: int, salt: String) -> String:
    if options.is_empty():
        return ""
    var index := stable_hash("%d|%s" % [seed_value, salt]) % options.size()
    return String(options[index])

func stable_hash(text: String) -> int:
    var value := 2166136261
    for index in range(text.length()):
        value = int((value ^ text.unicode_at(index)) & 0x7fffffff)
        value = int((value * 16777619) & 0x7fffffff)
    return value
