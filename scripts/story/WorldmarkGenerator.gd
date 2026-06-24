extends RefCounted
class_name WorldmarkGenerator

const WorldmarkDefinitionScript := preload("res://scripts/story/data/WorldmarkDefinition.gd")
const CompatibilityRules := preload("res://scripts/story/WorldmarkCompatibilityRules.gd")

var world_seed_text := ""
var world_seed_hash := 0

func setup(seed_text: String, seed_hash: int) -> void:
    world_seed_text = seed_text
    world_seed_hash = seed_hash

func definition_ids() -> Array[String]:
    return WorldmarkDefinitionScript.definition_ids()

func definition_for_id(definition_id: String) -> Dictionary:
    return WorldmarkDefinitionScript.definition_for_id(definition_id)

func generate_worldmark_record(seed_text: String, seed_hash: int, region_id: String, dominant_biome := "") -> Dictionary:
    var definition := definition_for_region(seed_text, seed_hash, region_id, dominant_biome)
    return WorldmarkDefinitionScript.worldmark_state(region_id, definition)

func record_for_region(region_id: String, dominant_biome := "") -> Dictionary:
    return generate_worldmark_record(world_seed_text, world_seed_hash, region_id, dominant_biome)

func definition_for_region(seed_text: String, seed_hash: int, region_id: String, dominant_biome := "") -> Dictionary:
    return definition_for_id(definition_id_for_region(seed_text, seed_hash, region_id, dominant_biome))

func definition_id_for_region(seed_text: String, seed_hash: int, region_id: String, dominant_biome := "") -> String:
    var biome := dominant_biome
    if biome == "swamp":
        return "mire_bloom_colossus"
    if biome in ["desert", "savanna", "alpine", "tundra"]:
        return "cinderwing_ember"
    var options := ["mire_bloom_colossus", "cinderwing_ember"]
    var index := stable_hash("%s|%d|%s|worldmark-concept-v1" % [seed_text, seed_hash, region_id]) % options.size()
    return options[index]

func validate_all_definitions() -> Dictionary:
    var problems: Array[String] = []
    for definition_id in definition_ids():
        var validation: Dictionary = CompatibilityRules.validate_definition(definition_for_id(definition_id))
        if not bool(validation.get("ok", false)):
            for problem in validation.get("problems", []):
                problems.append(String(problem))
    return {
        "ok": problems.is_empty(),
        "problems": problems
    }

func stable_hash(text: String) -> int:
    var value := 2166136261
    for index in range(text.length()):
        value = int((value ^ text.unicode_at(index)) & 0x7fffffff)
        value = int((value * 16777619) & 0x7fffffff)
    return value
