extends RefCounted
class_name BiomeEnvironmentCatalog

const PROFILE_PATHS := [
	"res://resources/visual/biomes/default.tres",
	"res://resources/visual/biomes/ocean.tres",
	"res://resources/visual/biomes/beach.tres",
	"res://resources/visual/biomes/plains.tres",
	"res://resources/visual/biomes/forest.tres",
	"res://resources/visual/biomes/taiga.tres",
	"res://resources/visual/biomes/snow.tres",
	"res://resources/visual/biomes/tundra.tres",
	"res://resources/visual/biomes/alpine.tres",
	"res://resources/visual/biomes/savanna.tres",
	"res://resources/visual/biomes/desert.tres",
	"res://resources/visual/biomes/swamp.tres",
	"res://resources/visual/biomes/town.tres",
]

var profiles_by_biome := {}
var last_errors: Array[Dictionary] = []
var loaded := false

func setup(profile_paths: Array = PROFILE_PATHS) -> bool:
	profiles_by_biome.clear()
	last_errors.clear()
	for path_variant in profile_paths:
		var path := String(path_variant)
		if not ResourceLoader.exists(path):
			append_error("missing_or_invalid_profile", path, "BiomeEnvironmentProfile resource does not exist")
			continue
		var profile := load(path) as BiomeEnvironmentProfile
		if profile == null:
			append_error("missing_or_invalid_profile", path, "BiomeEnvironmentProfile resource could not be loaded")
			continue
		var validation := validate_profile(profile, path)
		if not bool(validation.get("ok", false)):
			append_error(String(validation.get("code", "invalid_profile")), path, String(validation.get("message", "Profile validation failed")))
			continue
		if profiles_by_biome.has(profile.biome_id):
			append_error("duplicate_biome_id", path, "Duplicate biome id '%s'" % profile.biome_id)
			continue
		profiles_by_biome[profile.biome_id] = profile
	loaded = profiles_by_biome.has("default") and last_errors.is_empty()
	return loaded

func is_ready() -> bool:
	return loaded

func profile_count() -> int:
	return profiles_by_biome.size()

func biome_ids() -> Array[String]:
	var result: Array[String] = []
	for biome_variant in profiles_by_biome.keys():
		result.append(String(biome_variant))
	result.sort()
	return result

func profile_for_biome(biome: String) -> BiomeEnvironmentProfile:
	var profile := profiles_by_biome.get(biome) as BiomeEnvironmentProfile
	if profile != null:
		return profile
	return profiles_by_biome.get("default") as BiomeEnvironmentProfile

func detail_choice(biome: String, height: float, water_level: float, roll: float) -> Dictionary:
	var profile := profile_for_biome(biome)
	if profile == null or height > water_level + profile.detail_max_height_above_water:
		return {}
	for index in range(profile.detail_thresholds.size()):
		if roll >= float(profile.detail_thresholds[index]):
			continue
		var detail_type := String(profile.detail_types[index])
		if detail_type == "":
			return {}
		return {
			"type": detail_type,
			"yOffset": float(profile.detail_y_offsets[index]),
			"scaleMin": float(profile.detail_scale_mins[index]),
			"scaleMax": float(profile.detail_scale_maxs[index])
		}
	return {}

func validate_profile(profile: BiomeEnvironmentProfile, path := "") -> Dictionary:
	if profile.biome_id.strip_edges() == "":
		return invalid("missing_biome_id", "biome_id is empty", path)
	if profile.tree_families.is_empty() or profile.rock_families.is_empty():
		return invalid("missing_asset_family", "tree_families and rock_families must be non-empty", path)
	var detail_count := profile.detail_types.size()
	if detail_count == 0 \
		or profile.detail_thresholds.size() != detail_count \
		or profile.detail_y_offsets.size() != detail_count \
		or profile.detail_scale_mins.size() != detail_count \
		or profile.detail_scale_maxs.size() != detail_count:
		return invalid("invalid_detail_schema", "detail arrays must be non-empty and have matching lengths", path)
	var previous := 0.0
	for index in range(detail_count):
		var threshold := float(profile.detail_thresholds[index])
		if threshold <= previous or threshold > 1.0:
			return invalid("invalid_detail_threshold", "detail thresholds must be ascending in (0, 1]", path)
		if float(profile.detail_scale_mins[index]) > float(profile.detail_scale_maxs[index]):
			return invalid("invalid_detail_scale", "detail scale minimum exceeds maximum", path)
		previous = threshold
	if previous < 1.0:
		return invalid("incomplete_detail_distribution", "last detail threshold must be 1.0", path)
	if profile.forage_drop_min > profile.forage_drop_max:
		return invalid("invalid_forage_range", "forage drop minimum exceeds maximum", path)
	if profile.tree_height_min < 0.0 or profile.tree_height_max < profile.tree_height_min:
		return invalid("invalid_tree_height_range", "tree height range must be ordered and non-negative", path)
	if profile.crown_radius_min < 0.0 or profile.crown_radius_max < profile.crown_radius_min:
		return invalid("invalid_crown_radius_range", "crown radius range must be ordered and non-negative", path)
	if profile.trunk_radius_min < 0.0 or profile.trunk_radius_max < profile.trunk_radius_min:
		return invalid("invalid_trunk_radius_range", "trunk radius range must be ordered and non-negative", path)
	return {"ok": true}

func invalid(code: String, message: String, path: String) -> Dictionary:
	return {"ok": false, "code": code, "path": path, "message": message}

func append_error(code: String, path: String, message: String) -> void:
	last_errors.append({"code": code, "path": path, "message": message})
