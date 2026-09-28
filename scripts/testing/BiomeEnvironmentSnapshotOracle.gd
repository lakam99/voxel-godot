extends SceneTree

## Contract oracle for the resolved production catalog, including Resource
## defaults omitted by .tres files. No generated-world or gameplay claim.

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const SCHEMA_VERSION := 1
const SCALAR_FIELDS := [
	"tree_scale", "rock_scale", "tree_chance", "rock_base_chance",
	"forage_chance", "wildlife_chance", "forage_radius",
	"weather_precip", "weather_clouds", "detail_max_height_above_water",
	"tree_height_min", "tree_height_max", "crown_radius_min", "crown_radius_max",
	"trunk_radius_min", "trunk_radius_max", "old_growth_chance",
	"wind_response", "canopy_density", "natural_prop_exclusion_margin",
	"tree_visibility_range", "tree_shadow_range", "tree_age_min_years",
	"tree_age_typical_years", "tree_age_max_years", "tree_maturity_cell_scale",
	"tree_maturity_influence", "tree_local_age_span", "tree_age_distribution_skew",
	"tree_height_growth_exponent", "tree_girth_growth_exponent",
	"tree_crown_growth_exponent",
]
const INT_FIELDS := ["forage_drop_min", "forage_drop_max"]
const TEXT_FIELDS := ["biome_id", "forage_material", "forage_drop", "tree_architecture"]
const BOOL_FIELDS := ["cold_weather"]
const STRING_ARRAY_FIELDS := ["tree_families", "rock_families", "detail_types"]
const FLOAT32_ARRAY_FIELDS := [
	"detail_thresholds", "detail_y_offsets", "detail_scale_mins",
	"detail_scale_maxs", "tree_age_band_thresholds",
]

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var report_path := OS.get_environment("VOXEL_BIOME_ENVIRONMENT_SNAPSHOT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/native-world-backend/biome-environment-snapshot-oracle.json")
	var first := snapshot()
	var second := snapshot()
	var profiles: Array = first.get("profiles", [])
	var source_files: Array = first.get("sourceFiles", [])
	var semantic_profiles: Array[Dictionary] = []
	for profile_row_value in profiles:
		semantic_profiles.append(semantic_fields(profile_row_value))
	var canonical := JSON.stringify({
		"domain": "biome_environment_resolved_catalog",
		"schemaVersion": SCHEMA_VERSION,
		"fallbackId": first.get("fallbackId", ""),
		"profiles": semantic_profiles,
	})
	var resolved_digest := sha256_text(canonical)
	var ids: Array[String] = []
	for row in profiles:
		ids.append(String(row.get("biomeId", "")))
	var passed: bool = bool(first.get("ready", false)) and bool(second.get("ready", false)) \
		and profiles.size() == CatalogScript.PROFILE_PATHS.size() \
		and profiles == second.get("profiles", []) \
		and ids == first.get("sortedIds", []) \
		and ids.has("default") and ids.size() == 13 \
		and String(first.get("fallbackId", "")) == "default" \
		and source_files == second.get("sourceFiles", [])
	var report := {
		"schemaVersion": SCHEMA_VERSION,
		"runnerId": "biome_environment_snapshot_oracle",
		"finished": true,
		"passed": passed,
		"evidenceLevel": "contract",
		"scope": "Direct resolved Godot BiomeEnvironmentCatalog profiles and exact numeric sink bits; no native parity, runtime publication, collision, or live gameplay claim.",
		"catalogProfileCount": profiles.size(),
		"fallbackId": first.get("fallbackId", ""),
		"resolvedSnapshotSha256": resolved_digest,
		"sourceFiles": source_files,
		"profiles": profiles,
		"errors": first.get("errors", []),
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	quit(0 if passed else 1)

func snapshot() -> Dictionary:
	var catalog = CatalogScript.new()
	var ready: bool = catalog.setup()
	var rows: Array[Dictionary] = []
	for biome_id in catalog.biome_ids():
		var profile = catalog.profile_for_biome(biome_id)
		rows.append(profile_row(profile))
	var paths: Array[String] = [
		"res://scripts/environment/BiomeEnvironmentCatalog.gd",
		"res://scripts/environment/BiomeEnvironmentProfile.gd",
	]
	for path_variant in CatalogScript.PROFILE_PATHS:
		paths.append(String(path_variant))
	var source_files: Array[Dictionary] = []
	for path in paths:
		source_files.append({"path": path, "sha256": FileAccess.get_sha256(path)})
	var fallback = catalog.profile_for_biome("future_unknown_biome")
	return {
		"ready": ready,
		"errors": catalog.last_errors,
		"sortedIds": catalog.biome_ids(),
		"fallbackId": fallback.biome_id if fallback != null else "",
		"sourceFiles": source_files,
		"profiles": rows,
	}

func profile_row(profile) -> Dictionary:
	var source_path: String = String(profile.resource_path)
	var row := {"biomeId": String(profile.biome_id)}
	for field in TEXT_FIELDS:
		row[field] = String(profile.get(field))
	for field in BOOL_FIELDS:
		row[field] = bool(profile.get(field))
	for field in INT_FIELDS:
		row[field] = int(profile.get(field))
	for field in SCALAR_FIELDS:
		row[field] = numeric_value(float(profile.get(field)))
	for field in STRING_ARRAY_FIELDS:
		var values: Array[String] = []
		for value in profile.get(field):
			values.append(String(value))
		row[field] = values
	for field in FLOAT32_ARRAY_FIELDS:
		var values: Array[Dictionary] = []
		for value in profile.get(field):
			values.append(numeric_value(float(value)))
		row[field] = values
	row["resolvedProfileSha256"] = sha256_text(JSON.stringify({
		"domain": "biome_environment_resolved_profile",
		"schemaVersion": SCHEMA_VERSION,
		"fields": row,
	}))
	row["sourcePath"] = source_path
	row["sourceResourceSha256"] = FileAccess.get_sha256(source_path)
	return row

func semantic_fields(row: Dictionary) -> Dictionary:
	var fields := row.duplicate(true)
	fields.erase("resolvedProfileSha256")
	fields.erase("sourcePath")
	fields.erase("sourceResourceSha256")
	return fields

func numeric_value(value: float) -> Dictionary:
	return {
		"value": value,
		"float32BytesHex": PackedFloat32Array([value]).to_byte_array().hex_encode(),
		"float64BytesHex": PackedFloat64Array([value]).to_byte_array().hex_encode(),
	}

func sha256_text(value: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(value.to_utf8_buffer())
	return context.finish().hex_encode()
