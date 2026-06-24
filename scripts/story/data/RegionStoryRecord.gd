extends RefCounted
class_name RegionStoryRecord

const WorldmarkStateScript := preload("res://scripts/story/data/WorldmarkState.gd")

const SCHEMA_VERSION := 1

static func default_record(region_id: String, region_coords: Vector2i, stable_seed: int, dominant_biome: String, generation_version: int) -> Dictionary:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generationVersion": generation_version,
        "id": region_id,
        "regionX": region_coords.x,
        "regionZ": region_coords.y,
        "seed": stable_seed,
        "dominantBiome": dominant_biome,
        "state": "rumored",
        "worldmark": WorldmarkStateScript.default_state(region_id),
        "settlement": {
            "tier": 0,
            "flags": {}
        },
        "generatedText": {}
    }

static func normalize(value) -> Dictionary:
    if not (value is Dictionary):
        return {}
    var record: Dictionary = value.duplicate(true)
    var region_id := String(record.get("id", ""))
    record["schemaVersion"] = int(record.get("schemaVersion", SCHEMA_VERSION))
    record["generationVersion"] = int(record.get("generationVersion", 1))
    record["id"] = region_id
    record["regionX"] = int(record.get("regionX", 0))
    record["regionZ"] = int(record.get("regionZ", 0))
    record["seed"] = int(record.get("seed", 0))
    record["dominantBiome"] = String(record.get("dominantBiome", ""))
    record["state"] = String(record.get("state", "rumored"))
    record["worldmark"] = WorldmarkStateScript.normalize(region_id, record.get("worldmark", {}))
    if not record.has("settlement") or not (record["settlement"] is Dictionary):
        record["settlement"] = { "tier": 0, "flags": {} }
    if not record.has("generatedText") or not (record["generatedText"] is Dictionary):
        record["generatedText"] = {}
    return record

static func validate(value) -> Dictionary:
    var problems: Array[String] = []
    if not (value is Dictionary):
        problems.append("record is not a dictionary")
        return { "ok": false, "problems": problems }
    var record: Dictionary = value
    var region_id := String(record.get("id", ""))
    if region_id == "":
        problems.append("missing id")
    if int(record.get("schemaVersion", 0)) != SCHEMA_VERSION:
        problems.append("schemaVersion must be %d" % SCHEMA_VERSION)
    if int(record.get("generationVersion", 0)) <= 0:
        problems.append("generationVersion must be positive")
    for key in ["regionX", "regionZ", "seed", "dominantBiome", "state", "worldmark", "settlement", "generatedText"]:
        if not record.has(key):
            problems.append("missing %s" % key)
    var worldmark_validation: Dictionary = WorldmarkStateScript.validate(region_id, record.get("worldmark", {}))
    if not bool(worldmark_validation.get("ok", false)):
        for problem in worldmark_validation.get("problems", []):
            problems.append("worldmark.%s" % String(problem))
    return { "ok": problems.is_empty(), "problems": problems }
