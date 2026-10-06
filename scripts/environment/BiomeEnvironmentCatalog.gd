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

var _profiles_by_biome := {}
var _profile_value_rows := {}
var _published_envelope := {}
var _not_ready_envelope := {}
var last_errors: Array[Dictionary] = []
var loaded := false
var generation_revision := 0
var snapshot_seal_count := 0
var snapshot_serialization_count := 0

func _init() -> void:
	_not_ready_envelope = {"schema": "producer-catalog-owner-publication/v1", "ownerKind": "biome_environment",
		"status": "not_ready", "contentDigest": "", "ownerReceipt": {"ownerInstanceId": get_instance_id(), "publicationRevision": 0, "ready": false}, "payload": {}}
	_freeze_value_graph(_not_ready_envelope)

func setup(profile_paths: Array = PROFILE_PATHS) -> bool:
	var staged_profiles := {}
	var staged_errors: Array[Dictionary] = []
	for path_variant in profile_paths:
		var path := String(path_variant)
		if not ResourceLoader.exists(path):
			staged_errors.append({"code": "missing_or_invalid_profile", "path": path, "message": "BiomeEnvironmentProfile resource does not exist"})
			continue
		var profile := load(path) as BiomeEnvironmentProfile
		if profile == null:
			staged_errors.append({"code": "missing_or_invalid_profile", "path": path, "message": "BiomeEnvironmentProfile resource could not be loaded"})
			continue
		var validation := validate_profile(profile, path)
		if not bool(validation.get("ok", false)):
			staged_errors.append({"code": String(validation.get("code", "invalid_profile")), "path": path, "message": String(validation.get("message", "Profile validation failed"))})
			continue
		if staged_profiles.has(profile.biome_id):
			staged_errors.append({"code": "duplicate_biome_id", "path": path, "message": "Duplicate biome id '%s'" % profile.biome_id})
			continue
		# The registry owns a deep copy. ResourceLoader's cached source remains an
		# authoring input and is never the published runtime authority.
		staged_profiles[profile.biome_id] = profile.duplicate(true) as BiomeEnvironmentProfile
	var candidate_receipt := {"ownerInstanceId": get_instance_id(), "publicationRevision": generation_revision + 1, "ready": true}
	snapshot_seal_count += 1
	var captured := ActiveBiomeEnvironmentSnapshot.capture_profiles(staged_profiles, candidate_receipt)
	if bool(captured.get("ok", false)):
		snapshot_serialization_count += 1
	if not staged_profiles.has("default") or not staged_errors.is_empty() or not bool(captured.get("ok", false)):
		if not bool(captured.get("ok", false)):
			staged_errors.append({"code": "snapshot_capture_failed", "path": "", "message": String(captured.get("reason", "Snapshot capture failed"))})
		# Before the first successful publication, retain the prior compatibility
		# behavior that allows diagnostics to inspect any valid staged fallback.
		# Once a publication exists, a failed reload cannot replace its owners.
		if not loaded:
			_profiles_by_biome = staged_profiles
		last_errors = staged_errors
		return false
	# Publish all owner state together. A failed reload leaves the last valid
	# snapshot available while reporting the failed attempt through last_errors.
	generation_revision += 1
	_profiles_by_biome = staged_profiles
	_profile_value_rows = captured.get("valueRows", {}).duplicate(true)
	captured.erase("valueRows")
	_freeze_value_graph(_profile_value_rows)
	var envelope := {"schema": "producer-catalog-owner-publication/v1", "ownerKind": "biome_environment",
		"status": "ready", "contentDigest": String(captured.get("contentIdentity", "")),
		"ownerReceipt": candidate_receipt.duplicate(true), "payload": captured}
	_freeze_value_graph(envelope)
	_published_envelope = envelope
	last_errors = []
	loaded = true
	return true

func is_ready() -> bool:
	return loaded

func generation_receipt() -> Dictionary:
	return {"ownerInstanceId": get_instance_id(), "publicationRevision": generation_revision, "ready": loaded}

func published_catalog_snapshot() -> Dictionary:
	return _published_envelope if loaded and not _published_envelope.is_empty() else _not_ready_envelope

static func _freeze_value_graph(value: Variant) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			_freeze_value_graph(dictionary[key])
		dictionary.make_read_only()
	elif value is Array:
		var array: Array = value
		for item in array:
			_freeze_value_graph(item)
		array.make_read_only()

func profile_values_for_biome(biome: String) -> Dictionary:
	if not loaded:
		return {}
	return _profile_value_rows.get(biome, _profile_value_rows.get("default", {}))

func profile_count() -> int:
	return _profiles_by_biome.size()

func biome_ids() -> Array[String]:
	var result: Array[String] = []
	for biome_variant in _profiles_by_biome.keys():
		result.append(String(biome_variant))
	result.sort()
	return result

func profile_for_biome(biome: String) -> BiomeEnvironmentProfile:
	return profile_resource_copy_for_biome(biome)

func profile_resource_copy_for_biome(biome: String) -> BiomeEnvironmentProfile:
	var profile := _profiles_by_biome.get(biome) as BiomeEnvironmentProfile
	if profile != null:
		return profile.duplicate(true) as BiomeEnvironmentProfile
	profile = _profiles_by_biome.get("default") as BiomeEnvironmentProfile
	if profile == null:
		return null
	return profile.duplicate(true) as BiomeEnvironmentProfile

func detail_choice(biome: String, height: float, water_level: float, roll: float) -> Dictionary:
	var profile := profile_values_for_biome(biome)
	if profile.is_empty() or height > water_level + float(profile.detail_max_height_above_water):
		return {}
	var thresholds: Array = profile.detail_thresholds
	for index in range(thresholds.size()):
		if roll >= float(thresholds[index]):
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
	if profile.tree_architecture not in ["broadleaf", "conifer", "savanna"]:
		return invalid("invalid_tree_architecture", "tree_architecture must be broadleaf, conifer, or savanna", path)
	if profile.tree_age_min_years < 0.0 \
		or profile.tree_age_typical_years < profile.tree_age_min_years \
		or profile.tree_age_max_years < profile.tree_age_typical_years:
		return invalid("invalid_tree_age_range", "tree ages must be ordered min <= typical <= max", path)
	if profile.tree_maturity_cell_scale < 8.0:
		return invalid("invalid_tree_maturity_scale", "tree maturity correlation scale must be at least eight cells", path)
	if profile.tree_age_band_thresholds.size() != 4:
		return invalid("invalid_tree_age_bands", "tree age bands require four normalized thresholds", path)
	var previous_age_threshold := 0.0
	for threshold_variant in profile.tree_age_band_thresholds:
		var age_threshold := float(threshold_variant)
		if age_threshold <= previous_age_threshold or age_threshold >= 1.0:
			return invalid("invalid_tree_age_bands", "tree age band thresholds must ascend within (0, 1)", path)
		previous_age_threshold = age_threshold
	return {"ok": true}

func invalid(code: String, message: String, path: String) -> Dictionary:
	return {"ok": false, "code": code, "path": path, "message": message}

func append_error(code: String, path: String, message: String) -> void:
	last_errors.append({"code": code, "path": path, "message": message})
