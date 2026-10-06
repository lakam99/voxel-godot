extends RefCounted
class_name ActiveBiomeEnvironmentSnapshot

## Seals the mutable authoring Resources into owned value data during catalog
## setup. Runtime consumers read the catalog's published copy of this snapshot.

const SCHEMA_VERSION := 1
const IDS := ["alpine", "beach", "default", "desert", "forest", "ocean", "plains", "savanna", "snow", "swamp", "taiga", "town", "tundra"]
const TEXT_FIELDS := ["biome_id", "forage_material", "forage_drop", "tree_architecture"]
const BOOL_FIELDS := ["cold_weather"]
const INT_FIELDS := ["forage_drop_min", "forage_drop_max"]
const SCALAR_FIELDS := [
	"tree_scale", "rock_scale", "tree_chance", "rock_base_chance", "forage_chance",
	"wildlife_chance", "forage_radius", "weather_precip", "weather_clouds",
	"detail_max_height_above_water", "tree_height_min", "tree_height_max",
	"crown_radius_min", "crown_radius_max", "trunk_radius_min", "trunk_radius_max",
	"old_growth_chance", "wind_response", "canopy_density", "natural_prop_exclusion_margin",
	"tree_visibility_range", "tree_shadow_range", "tree_age_min_years",
	"tree_age_typical_years", "tree_age_max_years", "tree_maturity_cell_scale",
	"tree_maturity_influence", "tree_local_age_span", "tree_age_distribution_skew",
	"tree_height_growth_exponent", "tree_girth_growth_exponent", "tree_crown_growth_exponent",
]
const STRING_ARRAY_FIELDS := ["tree_families", "rock_families", "detail_types"]
const FLOAT32_ARRAY_FIELDS := [
	"detail_thresholds", "detail_y_offsets", "detail_scale_mins", "detail_scale_maxs",
	"tree_age_band_thresholds",
]

static func capture(catalog: BiomeEnvironmentCatalog) -> Dictionary:
	if catalog == null:
		return _failed("catalog_not_ready")
	var publication := catalog.published_catalog_snapshot()
	if String(publication.get("status", "")) != "ready":
		return _failed("catalog_not_ready")
	return publication.get("payload", {})

static func is_current(catalog: BiomeEnvironmentCatalog, snapshot: Dictionary) -> bool:
	if catalog == null or not bool(snapshot.get("ok", false)):
		return false
	var publication := catalog.published_catalog_snapshot()
	return String(publication.get("status", "")) == "ready" \
		and is_same(publication.get("payload", {}), snapshot) \
		and publication.get("contentDigest", "") == snapshot.get("contentIdentity", "")

static func capture_profiles(profiles_by_biome: Dictionary, owner_receipt: Dictionary) -> Dictionary:
	if profiles_by_biome.size() != IDS.size():
		return _failed("catalog_ids_invalid")
	var ids: Array[String] = []
	for key in profiles_by_biome.keys():
		ids.append(String(key))
	ids.sort()
	if ids != IDS:
		return _failed("catalog_ids_invalid")
	var normalized_rows: Array[Dictionary] = []
	var value_rows: Dictionary = {}
	var validator := BiomeEnvironmentCatalog.new()
	for id in IDS:
		var profile := profiles_by_biome.get(id) as BiomeEnvironmentProfile
		if profile == null or String(profile.biome_id) != id \
				or not bool(validator.validate_profile(profile).get("ok", false)):
			return _failed("profile_invalid:" + id)
		var normalized := {"biomeId": id}
		var values := {"biome_id": id}
		for field in TEXT_FIELDS:
			var text_value := String(profile.get(field))
			normalized[field] = text_value
			values[field] = text_value
		for field in BOOL_FIELDS:
			var bool_value := bool(profile.get(field))
			normalized[field] = bool_value
			values[field] = bool_value
		for field in INT_FIELDS:
			var int_value := int(profile.get(field))
			normalized[field] = int_value
			values[field] = int_value
		for field in SCALAR_FIELDS:
			var value := float(profile.get(field))
			if not is_finite(value):
				return _failed("nonfinite_scalar:" + id + ":" + field)
			normalized[field] = _numeric(value)
			values[field] = value
		for field in STRING_ARRAY_FIELDS:
			var string_values: Array[String] = []
			for item in profile.get(field):
				string_values.append(String(item))
			normalized[field] = string_values.duplicate()
			values[field] = string_values.duplicate()
		for field in FLOAT32_ARRAY_FIELDS:
			var normalized_array: Array[Dictionary] = []
			var float_values: Array[float] = []
			for item in profile.get(field):
				var value := float(item)
				if not is_finite(value):
					return _failed("nonfinite_array:" + id + ":" + field)
				normalized_array.append(_numeric(value))
				float_values.append(value)
			normalized[field] = normalized_array
			values[field] = float_values
		normalized_rows.append(normalized)
		value_rows[id] = values
	var canonical := JSON.stringify({"domain": "biome_environment_resolved_catalog",
		"schemaVersion": SCHEMA_VERSION, "fallbackId": "default", "profiles": normalized_rows})
	return {"ok": true, "schemaVersion": SCHEMA_VERSION,
		"fallbackId": "default",
		"contentIdentity": _sha256(canonical), "profiles": normalized_rows.duplicate(true),
		"valueRows": value_rows.duplicate(true)}

static func _numeric(value: float) -> Dictionary:
	return {"value": value, "float32BytesHex": PackedFloat32Array([value]).to_byte_array().hex_encode(),
		"float64BytesHex": PackedFloat64Array([value]).to_byte_array().hex_encode()}

static func _sha256(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()

static func _failed(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
