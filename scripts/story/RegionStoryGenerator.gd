extends Node
class_name RegionStoryGenerator

const WorldmarkGeneratorScript := preload("res://scripts/story/WorldmarkGenerator.gd")

const GENERATION_VERSION := 1

var world_seed_text := ""
var world_seed_hash := 0
var region_cell_size := 1
var worldmark_generator

func setup(seed_text: String, seed_hash: int, town_region_cells: int) -> void:
    world_seed_text = seed_text
    world_seed_hash = seed_hash
    region_cell_size = maxi(1, town_region_cells)
    if worldmark_generator == null:
        worldmark_generator = WorldmarkGeneratorScript.new()
    worldmark_generator.setup(seed_text, seed_hash)

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
    var worldmark := {}
    if worldmark_generator != null and worldmark_generator.has_method("generate_worldmark_record"):
        worldmark = worldmark_generator.generate_worldmark_record(seed_text, seed_hash, region_id, biome)
    return {
        "schemaVersion": 1,
        "generationVersion": GENERATION_VERSION,
        "id": region_id,
        "regionX": coords.x,
        "regionZ": coords.y,
        "seed": stable_seed,
        "dominantBiome": biome,
        "state": "rumored",
        "worldmark": worldmark,
        "settlement": {
            "tier": 0,
            "flags": {}
        },
        "generatedText": {}
    }

func record_for_region_id(region_id: String, dominant_biome := "") -> Dictionary:
    return generate_region_record(world_seed_text, world_seed_hash, region_id, dominant_biome)

func worldmark_definition(definition_id: String) -> Dictionary:
    if worldmark_generator == null:
        worldmark_generator = WorldmarkGeneratorScript.new()
        worldmark_generator.setup(world_seed_text, world_seed_hash)
    if worldmark_generator.has_method("definition_for_id"):
        return worldmark_generator.definition_for_id(definition_id)
    return {}

func worldmark_definition_ids() -> Array[String]:
    if worldmark_generator == null:
        worldmark_generator = WorldmarkGeneratorScript.new()
        worldmark_generator.setup(world_seed_text, world_seed_hash)
    if worldmark_generator.has_method("definition_ids"):
        return worldmark_generator.definition_ids()
    return []

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
