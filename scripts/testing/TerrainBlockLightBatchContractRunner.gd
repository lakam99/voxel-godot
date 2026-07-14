extends SceneTree

const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")

class FixtureGenerator:
	extends RefCounted

	func generate_cell_state(_cell: Vector3i) -> Dictionary:
		return {
			"blockId": "air",
			"material": "air",
			"biome": "underground_air",
			"solid": false,
			"density": -1.35,
			"fluid": "",
			"light": { "sky": 0, "block": 0 }
		}

	func world_bottom_cell_y() -> int:
		return -32

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TERRAIN_BLOCK_LIGHT_BATCH_REPORT").strip_edges()
	test_multi_source_batch_matches_sequential()
	test_batch_removal_and_level_change_matches_sequential()
	test_incremental_batch_matches_synchronous_authority()
	finish()

func test_multi_source_batch_matches_sequential() -> void:
	var entries: Array[Dictionary] = [
		{ "cell": Vector3i(0, 0, 0), "level": 12 },
		{ "cell": Vector3i(4, 0, 0), "level": 12 },
		{ "cell": Vector3i(12, 1, 5), "level": 9 },
		{ "cell": Vector3i(-7, 2, -4), "level": 15 }
	]
	var sequential = make_service()
	apply_sequential(sequential, entries, "block_light_batch_contract_sequential")
	var batched = make_service()
	var batch_result: Dictionary = batched.set_cell_lights_batch(light_changes(entries), "block_light_batch_contract_batch")
	var reordered = make_service()
	var reordered_result: Dictionary = reordered.set_cell_lights_batch(light_changes(reversed_entries(entries)), "block_light_batch_contract_reordered")
	var field_check := expected_light_field_check(batched, entries)
	var passed := source_signature(sequential) == source_signature(batched) \
		and light_signature(batched) == light_signature(reordered) \
		and bool(field_check.get("passed", false)) \
		and int(batch_result.get("changedCount", -1)) == entries.size() \
		and int(batch_result.get("sourceCount", -1)) == entries.size() \
		and int(reordered_result.get("sourceCount", -1)) == entries.size() \
		and section_channel_matches_expected(batched, entries)
	add_result("batched_multi_source_light_rebuild_is_complete_and_order_independent", passed, {
		"sequentialSources": source_signature(sequential),
		"batchedSources": source_signature(batched),
		"sequentialLightCellCount": sequential.light_cells.size(),
		"batchedLightCellCount": batched.light_cells.size(),
		"reorderedLightCellCount": reordered.light_cells.size(),
		"field": field_check,
		"batch": batch_result,
		"reorderedBatch": reordered_result
	})

func test_batch_removal_and_level_change_matches_sequential() -> void:
	var initial: Array[Dictionary] = [
		{ "cell": Vector3i(-3, 0, 2), "level": 15 },
		{ "cell": Vector3i(2, 0, 2), "level": 12 },
		{ "cell": Vector3i(8, 0, 2), "level": 10 }
	]
	var updates: Array[Dictionary] = [
		{ "cell": Vector3i(-3, 0, 2), "level": 0 },
		{ "cell": Vector3i(2, 0, 2), "level": 7 },
		{ "cell": Vector3i(10, 1, -3), "level": 13 }
	]
	var sequential = make_service()
	apply_sequential(sequential, initial, "block_light_batch_contract_initial")
	apply_sequential(sequential, updates, "block_light_batch_contract_updates")
	var batched = make_service()
	batched.set_cell_lights_batch(light_changes(initial), "block_light_batch_contract_initial")
	var update_result: Dictionary = batched.set_cell_lights_batch(light_changes(updates), "block_light_batch_contract_updates")
	var expected_entries: Array[Dictionary] = [
		{ "cell": Vector3i(2, 0, 2), "level": 7 },
		{ "cell": Vector3i(8, 0, 2), "level": 10 },
		{ "cell": Vector3i(10, 1, -3), "level": 13 }
	]
	var field_check := expected_light_field_check(batched, expected_entries)
	var expected_sources := 3
	var passed := source_signature(sequential) == source_signature(batched) \
		and bool(field_check.get("passed", false)) \
		and int(update_result.get("changedCount", -1)) == updates.size() \
		and int(update_result.get("sourceCount", -1)) == expected_sources \
		and section_channel_matches_expected(batched, expected_entries)
	add_result("batched_light_removal_and_level_change_keep_authoritative_field", passed, {
		"sequentialSources": source_signature(sequential),
		"batchedSources": source_signature(batched),
		"sequentialLightCellCount": sequential.light_cells.size(),
		"batchedLightCellCount": batched.light_cells.size(),
		"field": field_check,
		"batch": update_result
	})

func test_incremental_batch_matches_synchronous_authority() -> void:
	var entries: Array[Dictionary] = [
		{ "cell": Vector3i(-11, 1, 4), "level": 15 },
		{ "cell": Vector3i(-1, 0, -6), "level": 12 },
		{ "cell": Vector3i(7, 2, 3), "level": 10 },
		{ "cell": Vector3i(15, 0, -2), "level": 14 }
	]
	var synchronous = make_service()
	var synchronous_result: Dictionary = synchronous.set_cell_lights_batch(light_changes(entries), "block_light_batch_contract_synchronous")
	var incremental = make_service()
	var state: Dictionary = incremental.begin_cell_lights_batch(light_changes(entries), "block_light_batch_contract_incremental")
	var steps := 0
	var max_step_ms := 0.0
	while not bool(state.get("complete", false)) and steps < 4096:
		var advanced: Dictionary = incremental.advance_cell_lights_batch(state, 0.0, 48)
		state = advanced.get("state", state)
		max_step_ms = maxf(max_step_ms, float(advanced.get("elapsedMs", 0.0)))
		steps += 1
	var summary: Dictionary = incremental.cell_lights_batch_summary(state)
	var field_check := expected_light_field_check(incremental, entries)
	var passed := (
		steps > 1
		and bool(summary.get("complete", false))
		and source_signature(synchronous) == source_signature(incremental)
		and light_signature(synchronous) == light_signature(incremental)
		and bool(field_check.get("passed", false))
		and section_channel_matches_expected(incremental, entries)
		and int(summary.get("changedCount", -1)) == int(synchronous_result.get("changedCount", -2))
	)
	add_result("incremental_batch_matches_synchronous_authoritative_light_field", passed, {
		"steps": steps,
		"maxStepMs": max_step_ms,
		"synchronousLightCellCount": synchronous.light_cells.size(),
		"incrementalLightCellCount": incremental.light_cells.size(),
		"field": field_check,
		"summary": summary
	})

func make_service():
	var service = TerrainVolumeServiceScript.new()
	service.setup(null, FixtureGenerator.new())
	return service

func apply_sequential(service, entries: Array[Dictionary], reason: String) -> void:
	for entry in entries:
		service.set_cell_light(entry["cell"], { "sky": 0, "block": int(entry.get("level", 0)) }, reason)

func light_changes(entries: Array[Dictionary]) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	for entry in entries:
		changes.append({
			"cell": entry["cell"],
			"light": { "sky": 0, "block": int(entry.get("level", 0)) }
		})
	return changes

func reversed_entries(entries: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(entries.size() - 1, -1, -1):
		result.append(entries[index])
	return result

func source_signature(service) -> Array[String]:
	var rows: Array[String] = []
	for cell_value in service.block_light_sources.keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		rows.append("%d,%d,%d:%d" % [cell.x, cell.y, cell.z, int(service.block_light_sources[cell])])
	rows.sort()
	return rows

func light_signature(service) -> Array[String]:
	var rows: Array[String] = []
	for cell_value in service.light_cells.keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		var light_value = service.light_cells[cell]
		var light: Dictionary = light_value if light_value is Dictionary else {}
		rows.append("%d,%d,%d:%d,%d" % [
			cell.x,
			cell.y,
			cell.z,
			int(light.get("sky", 0)),
			int(light.get("block", 0))
		])
	rows.sort()
	return rows

func expected_light_field_check(service, entries: Array[Dictionary]) -> Dictionary:
	if entries.is_empty():
		return { "passed": true, "sampleCount": 0, "mismatches": [] }
	var min_cell: Vector3i = entries[0].get("cell", Vector3i.ZERO)
	var max_cell := min_cell
	for entry in entries:
		var cell_value = entry.get("cell", Vector3i.ZERO)
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		min_cell.z = mini(min_cell.z, cell.z)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
		max_cell.z = maxi(max_cell.z, cell.z)
	var mismatches: Array[String] = []
	var samples := 0
	for z in range(min_cell.z - 15, max_cell.z + 16):
		for y in range(min_cell.y - 15, max_cell.y + 16):
			for x in range(min_cell.x - 15, max_cell.x + 16):
				var cell := Vector3i(x, y, z)
				var expected := expected_block_light_at(entries, cell)
				var actual := int(service.light_at_cell(cell).get("block", 0))
				samples += 1
				if expected != actual and mismatches.size() < 12:
					mismatches.append("%d,%d,%d expected=%d actual=%d" % [x, y, z, expected, actual])
	return {
		"passed": mismatches.is_empty(),
		"sampleCount": samples,
		"mismatches": mismatches
	}

func expected_block_light_at(entries: Array[Dictionary], cell: Vector3i) -> int:
	var expected := 0
	for entry in entries:
		var source_value = entry.get("cell", Vector3i.ZERO)
		if not (source_value is Vector3i):
			continue
		var source: Vector3i = source_value
		var level := maxi(0, int(entry.get("level", 0)))
		var distance := absi(cell.x - source.x) + absi(cell.y - source.y) + absi(cell.z - source.z)
		if distance < level:
			expected = maxi(expected, level - distance)
	return expected

func section_channel_matches_expected(service, entries: Array[Dictionary]) -> bool:
	for entry in entries:
		var cell_value = entry.get("cell", Vector3i.ZERO)
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		if section_block_light(service, cell) != expected_block_light_at(entries, cell):
			return false
	return true

func section_block_light(service, cell: Vector3i) -> int:
	var section: Dictionary = service.request_section(service.section_key_for_cell(cell))
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	var lights: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var index := int(service.section_cell_index(service.local_cell_for(cell)))
	return int(lights[index]) if index >= 0 and index < lights.size() else -1

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({ "name": name, "passed": passed, "details": details })
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, JSON.stringify(details)])

func finish() -> void:
	var passed := true
	for result in results:
		passed = passed and bool(result.get("passed", false))
	var report := {
		"schemaVersion": 1,
		"runnerId": "terrain_block_light_batch_contract",
		"evidenceLevel": "contract",
		"passed": passed,
		"results": results
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print(JSON.stringify(report, "  "))
	quit(0 if passed else 1)
