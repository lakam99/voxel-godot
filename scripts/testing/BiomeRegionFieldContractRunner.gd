extends SceneTree

const BiomeRegionFieldScript := preload("res://scripts/world/BiomeRegionField.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_BIOME_REGION_FIELD_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/terrain/biome-region-field-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var field = BiomeRegionFieldScript.new()
	test_repeatability(field)
	test_kilometre_core_contract(field)
	test_long_transects(field)
	test_ecotone_bounds(field)
	test_current_save_format_is_the_only_authority()
	finish()

func test_repeatability(field) -> void:
	var first: Dictionary = field.sample("atlas-1492", Vector2(14250.75, -8810.25))
	var second: Dictionary = field.sample("atlas-1492", Vector2(14250.75, -8810.25))
	var changed: Dictionary = field.sample("atlas-other", Vector2(14250.75, -8810.25))
	add_result("field_repeats_exactly_without_shared_rng", first == second and String(first.get("regionId", "")) != String(changed.get("regionId", "")), {
		"first": first,
		"changedSeedRegion": changed.get("regionId", "")
	})

func test_kilometre_core_contract(field) -> void:
	var failures: Array[Dictionary] = []
	var checked := 0
	for seed_text in ["atlas-1492", "atlas-38477129", "atlas-90211044"]:
		for region_z in range(-3, 4):
			for region_x in range(-3, 4):
				var region := Vector2i(region_x, region_z)
				var site: Vector2 = field.site_position(seed_text, region)
				var sample: Dictionary = field.sample(seed_text, site)
				checked += 1
				var probes := [
					site + Vector2(1000.0, 0.0),
					site + Vector2(-1000.0, 0.0),
					site + Vector2(0.0, 1000.0),
					site + Vector2(0.0, -1000.0),
					site + Vector2(707.1068, 707.1068),
					site + Vector2(-707.1068, -707.1068)
				]
				var stable_core := float(sample.get("edgeDistanceMeters", 0.0)) >= BiomeRegionFieldScript.MINIMUM_CORE_RADIUS_METERS
				for probe in probes:
					var probe_sample: Dictionary = field.sample(seed_text, probe)
					stable_core = stable_core and probe_sample.get("region", Vector2i.ZERO) == region and String(probe_sample.get("biome", "")) == String(sample.get("biome", ""))
				if not stable_core:
					failures.append({"seed": seed_text, "region": region, "sample": sample})
	add_result("every_sampled_region_has_a_two_kilometre_core", failures.is_empty(), {
		"checkedRegions": checked,
		"minimumCoreDiameterMeters": BiomeRegionFieldScript.MINIMUM_CORE_DIAMETER_METERS,
		"failures": failures
	})

func test_ecotone_bounds(field) -> void:
	var failures: Array[Dictionary] = []
	var allowed_biomes := {"snow": true, "tundra": true, "taiga": true, "swamp": true, "desert": true, "savanna": true, "forest": true, "plains": true}
	for z in range(-8, 9):
		for x in range(-8, 9):
			var sample: Dictionary = field.sample("atlas-1492", Vector2(float(x) * 1700.0 + 311.0, float(z) * 1700.0 - 719.0))
			if float(sample.get("ecotoneWeight", -1.0)) < 0.0 or float(sample.get("ecotoneWeight", 2.0)) > 1.0 or float(sample.get("edgeDistanceMeters", -1.0)) < 0.0 or not allowed_biomes.has(String(sample.get("biome", ""))):
				failures.append(sample)
	add_result("ecotone_and_climate_outputs_are_bounded", failures.is_empty(), {"failures": failures})

func test_long_transects(field) -> void:
	var sampled_regions := {}
	var failures: Array[Dictionary] = []
	var directions := [Vector2.RIGHT, Vector2.DOWN, Vector2(1.0, 1.0).normalized(), Vector2(1.0, -1.0).normalized()]
	for seed_text in ["atlas-1492", "atlas-38477129"]:
		for direction in directions:
			for distance in range(-12000, 12001, 250):
				var sample: Dictionary = field.sample(seed_text, direction * float(distance))
				sampled_regions["%s:%s" % [seed_text, String(sample.get("regionId", ""))]] = {
					"seed": seed_text,
					"region": sample.get("region", Vector2i.ZERO),
					"biome": sample.get("biome", "")
				}
	for record_value in sampled_regions.values():
		var record: Dictionary = record_value
		var seed_text := String(record.get("seed", ""))
		var region: Vector2i = record.get("region", Vector2i.ZERO)
		var site: Vector2 = field.site_position(seed_text, region)
		var center: Dictionary = field.sample(seed_text, site)
		var all_core_probes_match := float(center.get("edgeDistanceMeters", 0.0)) >= BiomeRegionFieldScript.MINIMUM_CORE_RADIUS_METERS
		for probe in [site + Vector2(1000.0, 0.0), site + Vector2(-1000.0, 0.0), site + Vector2(0.0, 1000.0), site + Vector2(0.0, -1000.0)]:
			var probe_sample: Dictionary = field.sample(seed_text, probe)
			all_core_probes_match = all_core_probes_match and probe_sample.get("region", Vector2i.ZERO) == region and String(probe_sample.get("biome", "")) == String(center.get("biome", ""))
		if not all_core_probes_match:
			failures.append({"seed": seed_text, "region": region, "biome": center.get("biome", ""), "center": center})
	add_result("cardinal_and_diagonal_transects_prove_each_sampled_region_has_a_two_kilometre_core", failures.is_empty(), {
		"transectLengthMeters": 24000,
		"sampleStepMeters": 250,
		"sampledRegionCount": sampled_regions.size(),
		"minimumCoreDiameterMeters": BiomeRegionFieldScript.MINIMUM_CORE_DIAMETER_METERS,
		"failures": failures
	})

func test_current_save_format_is_the_only_authority() -> void:
	var save_path := "user://biome_region_field_authority_contract.json"
	var stem := save_path.substr(0, save_path.length() - 5)
	var legacy_slot_path := "%s_slot_legacy.json" % stem
	var binary_slot_path := "%s_slot_fresh.bin" % stem
	var active_seed_path := "%s_active_seed.txt" % stem
	for target_path in [save_path, legacy_slot_path, binary_slot_path, active_seed_path, "%s_slot_fresh.json" % stem]:
		remove_test_file(target_path)
	write_test_text(legacy_slot_path, JSON.stringify({"version": 1, "seed": "legacy", "marker": "obsolete"}))
	write_test_text(save_path, JSON.stringify({"legacy": {"version": 1, "seed": "legacy"}, SaveSystemScript.ACTIVE_SEED_KEY: "legacy"}))
	write_test_text(active_seed_path, "legacy")
	var save_system = SaveSystemScript.new(save_path)
	var legacy_files_remaining := {
		"save": FileAccess.file_exists(save_path),
		"legacySlot": FileAccess.file_exists(legacy_slot_path),
		"activeSeed": FileAccess.file_exists(active_seed_path)
	}
	var legacy_purged: bool = not bool(legacy_files_remaining.get("save", true)) \
		and not bool(legacy_files_remaining.get("legacySlot", true)) \
		and not bool(legacy_files_remaining.get("activeSeed", true))
	var fresh_saved := save_system.save("fresh", {"marker": "current"})
	var fresh: Dictionary = save_system.load("fresh")
	var binary_file := FileAccess.open(binary_slot_path, FileAccess.READ)
	var binary_header := binary_file.get_buffer(4) if binary_file != null else PackedByteArray()
	if binary_file != null: binary_file.close()
	var current_format_written := fresh_saved and FileAccess.file_exists(binary_slot_path) \
		and binary_header.get_string_from_ascii() == "VBW2" \
		and int(fresh.get("version", 0)) == SaveSystemScript.SAVE_VERSION and int(fresh.get("version", 0)) == 2
	var read_stats: Dictionary = save_system.stats()
	var read_file_ms := float(read_stats.get("lastReadFileMs", -1.0))
	var decode_ms := float(read_stats.get("lastBinaryDecodeMs", -1.0))
	var total_ms := float(read_stats.get("lastReadParseMs", -1.0))
	var read_bytes := int(read_stats.get("lastReadBytes", 0))
	var read_metrics_present := read_stats.has("lastReadFileMs") and read_stats.has("lastBinaryDecodeMs") \
		and read_stats.has("lastReadParseMs") and read_stats.has("lastReadBytes") \
		and read_file_ms >= 0.0 and decode_ms >= 0.0 and total_ms >= read_file_ms \
		and total_ms >= decode_ms and read_bytes > 0
	add_result("incompatible_saves_are_purged_current_format_loads_and_read_phases_are_reported", legacy_purged and current_format_written and read_metrics_present, {
		"legacyPurged": legacy_purged,
		"legacyFilesRemaining": legacy_files_remaining,
		"currentFormatWritten": current_format_written,
		"saveVersion": SaveSystemScript.SAVE_VERSION,
		"loadedMarker": fresh.get("marker", ""),
		"readMetrics": {
			"fileReadMs": read_file_ms,
			"binaryDecodeMs": decode_ms,
			"compatibleTotalMs": total_ms,
			"bytes": read_bytes,
			"present": read_metrics_present
		}
	})
	for target_path in [save_path, legacy_slot_path, binary_slot_path, active_seed_path, "%s_slot_fresh.json" % stem]:
		remove_test_file(target_path)

func write_test_text(target_path: String, value: String) -> void:
	var file := FileAccess.open(target_path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)
		file.close()

func remove_test_file(target_path: String) -> void:
	if FileAccess.file_exists(target_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(target_path))

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "biome_region_field_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Pure global biome-region geometry, deterministic climate classification, ecotone bounds, and save-format authority. This is contract evidence, not headed gameplay acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
	quit(0 if failure_count == 0 else 1)
