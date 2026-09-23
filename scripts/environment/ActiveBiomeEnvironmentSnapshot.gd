extends RefCounted
class_name ActiveBiomeEnvironmentSnapshot

## Capture-only value boundary for the active production catalog. The snapshot
## owns no profiles and never reloads resources or selects gameplay policy.

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
	if catalog == null or not catalog.is_ready():
		return _failed("catalog_not_ready")
	var before := catalog.generation_receipt()
	if not bool(before.get("ready", false)) or int(before.get("revision", 0)) <= 0:
		return _failed("catalog_receipt_invalid")
	var first := _read_values(catalog)
	if not bool(first.get("ok", false)):
		return first
	var middle := catalog.generation_receipt()
	var second := _read_values(catalog)
	var after := catalog.generation_receipt()
	if before != middle or middle != after or not bool(second.get("ok", false)) \
			or first.get("contentIdentity") != second.get("contentIdentity"):
		return _failed("catalog_changed_during_capture")
	return {"ok": true, "schemaVersion": SCHEMA_VERSION, "ownerReceipt": before.duplicate(true),
		"fallbackId": "default", "contentIdentity": first.contentIdentity,
		"profiles": (first.profiles as Array).duplicate(true)}

static func is_current(catalog: BiomeEnvironmentCatalog, snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("ok", false)) or int(snapshot.get("schemaVersion", -1)) != SCHEMA_VERSION \
			or snapshot.get("fallbackId") != "default" or not snapshot.get("profiles") is Array \
			or not snapshot.get("contentIdentity") is String \
			or catalog == null or not catalog.is_ready() \
			or catalog.generation_receipt() != snapshot.get("ownerReceipt", {}):
		return false
	var current := capture(catalog)
	return bool(current.get("ok", false)) and current.get("contentIdentity") == snapshot.get("contentIdentity") \
		and current.get("ownerReceipt") == snapshot.get("ownerReceipt") \
		and current.get("profiles") == snapshot.get("profiles")

static func _read_values(catalog: BiomeEnvironmentCatalog) -> Dictionary:
	if catalog.biome_ids() != IDS or catalog.profile_count() != IDS.size():
		return _failed("catalog_ids_invalid")
	var fallback := catalog.profile_for_biome("future_unknown_biome")
	if fallback == null or fallback.biome_id != "default":
		return _failed("fallback_invalid")
	var rows: Array[Dictionary] = []
	for id in IDS:
		var profile := catalog.profiles_by_biome.get(id) as BiomeEnvironmentProfile
		if profile == null or String(profile.biome_id) != id \
				or not bool(catalog.validate_profile(profile).get("ok", false)):
			return _failed("profile_invalid:" + id)
		var row := {"biomeId": id}
		for field in TEXT_FIELDS:
			row[field] = String(profile.get(field))
		for field in BOOL_FIELDS:
			row[field] = bool(profile.get(field))
		for field in INT_FIELDS:
			row[field] = int(profile.get(field))
		for field in SCALAR_FIELDS:
			var value := float(profile.get(field))
			if not is_finite(value):
				return _failed("nonfinite_scalar:" + id + ":" + field)
			row[field] = _numeric(value)
		for field in STRING_ARRAY_FIELDS:
			var values: Array[String] = []
			for value in profile.get(field):
				values.append(String(value))
			row[field] = values
		for field in FLOAT32_ARRAY_FIELDS:
			var values: Array[Dictionary] = []
			for value in profile.get(field):
				if not is_finite(float(value)):
					return _failed("nonfinite_array:" + id + ":" + field)
				values.append(_numeric(float(value)))
			row[field] = values
		rows.append(row)
	var canonical := JSON.stringify({"domain": "biome_environment_resolved_catalog",
		"schemaVersion": SCHEMA_VERSION, "fallbackId": "default", "profiles": rows})
	return {"ok": true, "profiles": rows, "contentIdentity": _sha256(canonical)}

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
