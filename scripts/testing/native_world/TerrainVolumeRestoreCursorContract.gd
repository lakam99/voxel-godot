extends SceneTree

const SERVICE := preload("res://scripts/TerrainVolumeService.gd")
const CURSOR := preload("res://scripts/terrain/TerrainVolumeRestoreCursor.gd")

class FixtureGenerator extends RefCounted:
	func generate_cell_state(cell: Vector3i) -> Dictionary:
		var solid := cell.y <= -2
		return {
			"cell": cell,
			"material": "stone" if solid else "air",
			"biome": "plains",
			"solid": solid,
			"density": 1.35 if solid else -1.35,
			"fluid": "",
			"light": {"sky": 0 if solid else 15, "block": 0},
			"metadata": {}
		}

	func world_bottom_cell_y() -> int:
		return -4

var failures: Array[String] = []
var checks := 0
var observations: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func check(value: bool, label: String, details: Variant = {}) -> void:
	checks += 1
	if not value:
		failures.append(label)
	observations.append({"label": label, "passed": value, "details": details})

func run() -> void:
	var generator := FixtureGenerator.new()
	var source = SERVICE.new()
	source.setup(null, generator)
	var edits := [
		{"cell": Vector3i(-1, -2, 0), "state": _state("air", false, "", 0, "restore-air")},
		{"cell": Vector3i(0, -2, 0), "state": _state("air", false, "", 0, "restore-air")},
		{"cell": Vector3i(1, -2, 0), "state": _state("air", false, "water", 0, "restore-water")},
		{"cell": Vector3i(0, -1, 0), "state": _state("air", false, "", 0, "restore-air")},
		{"cell": Vector3i(0, -2, 16), "state": _state("air", false, "", 0, "restore-air")}
	]
	for entry in edits:
		source.set_cell_state(entry.cell, entry.state, "fixture_edit", false)
	var snapshot: Dictionary = source.save_all_section_deltas()
	var source_revision := int(source.revision)
	var source_fluid_revision := int(source.fluid_revision)
	var snapshot_before: Dictionary = snapshot.duplicate(true)
	var oracle = SERVICE.new()
	oracle.setup(null, generator)
	oracle.configured_cell_size = source.configured_cell_size
	oracle.configured_min_height = source.configured_min_height
	oracle.configured_max_height = source.configured_max_height
	oracle.load_section_deltas(snapshot)

	var cursor = CURSOR.new()
	var begin_result: Dictionary = cursor.begin(source, snapshot, 71)
	check(begin_result.get("status") == "input", "canonical snapshot begins", begin_result)
	check(cursor.staged_service_if_complete(71) == null, "incomplete stage is not exposed")
	check(cursor.advance(72, 1, 1).get("status") == "stale", "wrong-generation advance is inert")
	check(cursor.status(71).get("status") == "input", "stale advance preserves current lease")
	check(cursor.cancel(72).get("status") == "stale", "wrong-generation cancel is inert")
	var input_calls := 0
	var sky_calls := 0
	var cursor_steps := 0
	var max_input_items := 0
	var max_input_cells := 0
	var max_sky_y_cells := 0
	while cursor.status(71).get("status") in ["input", "section_sky"] and cursor_steps < 10000:
		var state := String(cursor.status(71).get("status", ""))
		var result: Dictionary = cursor.advance(71, 1, 1)
		if state == "input":
			max_input_items = maxi(max_input_items, int(result.get("itemsProcessed", 0)))
			max_input_cells = maxi(max_input_cells, int(result.get("cellsProcessed", 0)))
			input_calls += 1
		else:
			max_sky_y_cells = maxi(max_sky_y_cells, int(result.get("skyYCellsProcessed", 0)))
			sky_calls += 1
		cursor_steps += 1
	check(cursor.status(71).get("status") == "complete", "staged restore completes", cursor.status(71))
	check(input_calls > 0 and sky_calls > 0, "contract crosses both bounded phases", {"inputCalls": input_calls, "skyCalls": sky_calls})
	check(max_input_items <= 1 and max_input_cells <= 1 and max_sky_y_cells <= 1,
		"every cursor call respects record and Y budgets", {
			"maxInputItems": max_input_items, "maxInputCells": max_input_cells,
			"maxSkyYCells": max_sky_y_cells
		})
	var staged = cursor.staged_service_if_complete(71)
	check(staged != null and staged != source, "only detached complete stage is exposed")
	if staged != null:
		check(_service_parity(staged, oracle), "staged state matches synchronous load_section_deltas oracle", _parity_details(staged, oracle))
		check(int(staged.revision) == int(oracle.revision) and int(staged.revision) == source_revision,
			"global revision preserves current loader behavior")
		check(int(staged.fluid_revision) == int(oracle.fluid_revision), "fluid revision parity")
		check(staged.save_all_section_deltas() == oracle.save_all_section_deltas(), "durable save delta parity")
	check(source.save_all_section_deltas() == snapshot_before and int(source.revision) == source_revision
		and int(source.fluid_revision) == source_fluid_revision,
		"live source remains unchanged during staging")
	check(snapshot == snapshot_before, "cursor retains but does not rewrite decoded input")
	var completion_disposal := _drain(cursor, 71, 3)
	check(completion_disposal.get("status") == "disposed"
		and int(completion_disposal.get("maxItemsCleared", 0)) <= 3,
		"completed stage has bounded disposal", completion_disposal)
	var completed_residue := _staged_residue(staged)
	check(completed_residue.is_empty(), "completed stage storage is actually empty after bounded disposal", completed_residue)
	check(cursor.retained_staging_bookkeeping_count() == 0,
		"completed cursor drains cell and skylight bookkeeping incrementally")
	var replacement_cursor = CURSOR.new()
	check(replacement_cursor.begin(source, snapshot, 72).get("status") == "input", "new cursor accepts replacement lease")
	check(replacement_cursor.advance(71, 1, 1).get("status") == "stale"
		and replacement_cursor.status(72).get("status") == "input",
		"old generation cannot mutate replacement lease")
	replacement_cursor.cancel(72)
	_drain(replacement_cursor, 72, 2)

	_test_malformed_and_ordering(generator, snapshot)
	_test_cancel_during_sky(generator, source, snapshot)
	_write_report()
	quit(1 if not failures.is_empty() else 0)

func _test_malformed_and_ordering(generator, source_snapshot: Dictionary) -> void:
	var reversed_sections: Dictionary = source_snapshot.duplicate(true)
	var section_array: Array = reversed_sections.sections
	section_array.reverse()
	var out_of_order = CURSOR.new()
	check(out_of_order.begin(_new_source(generator), reversed_sections, 81).get("status") == "input",
		"reversed section fixture begins")
	var section_result := _run_until_terminal(out_of_order, 81)
	check(section_result.get("status") == "rejected" and section_result.get("reason") == "section_order_or_duplicate_invalid",
		"out-of-order section rejected", section_result)
	check(out_of_order.staged_service_if_complete(81) == null, "rejected section stream never exposes stage")
	check(_drain(out_of_order, 81, 1).get("status") == "disposed", "rejected section input cleans up")

	var duplicate_sections: Dictionary = source_snapshot.duplicate(true)
	(duplicate_sections.sections as Array).append((duplicate_sections.sections as Array)[0].duplicate(true))
	var duplicate_section_cursor = CURSOR.new()
	duplicate_section_cursor.begin(_new_source(generator), duplicate_sections, 82)
	var duplicate_section_result := _run_until_terminal(duplicate_section_cursor, 82)
	check(duplicate_section_result.get("status") == "rejected"
		and duplicate_section_result.get("reason") == "section_order_or_duplicate_invalid",
		"duplicate section rejected", duplicate_section_result)
	_drain(duplicate_section_cursor, 82, 1)

	var malformed: Dictionary = source_snapshot.duplicate(true)
	var malformed_sections: Array = malformed.sections
	var target_section: Dictionary = malformed_sections[1]
	var target_cells: Array = target_section.cells
	# The last canonical cell is corrupted, after earlier records have staged.
	var last_record: Dictionary = target_cells[target_cells.size() - 1]
	last_record["local"] = [15, 15, 15]
	var malformed_cursor = CURSOR.new()
	var malformed_source = _new_source(generator)
	var live_before: Dictionary = malformed_source.save_all_section_deltas()
	malformed_cursor.begin(malformed_source, malformed, 83)
	var malformed_result := _run_until_terminal(malformed_cursor, 83)
	check(malformed_result.get("status") == "rejected"
		and malformed_result.get("reason") == "cell_section_or_local_mismatch",
		"late malformed cell rejected", malformed_result)
	check(malformed_cursor.staged_service_if_complete(83) == null,
		"late malformed import cannot finalize")
	check(malformed_source.save_all_section_deltas() == live_before,
		"late rejection leaves live service untouched")
	var rejected_stage = malformed_cursor._staging_service
	check(rejected_stage != null and rejected_stage.edited_cells.size() > 0,
		"late rejection retains previously staged records until disposal")
	var bounded := malformed_cursor.dispose_step(83, 1)
	check(int(bounded.get("itemsCleared", 0)) <= 1, "rejection cleanup respects one-item bound", bounded)
	var rejected_cleanup := _drain(malformed_cursor, 83, 1)
	check(rejected_cleanup.get("status") == "disposed", "late rejected data drains fully", rejected_cleanup)
	if rejected_stage != null:
		var rejected_residue := _staged_residue(rejected_stage)
		check(rejected_residue.is_empty(), "bounded cleanup reaches zero staged cell ownership", rejected_residue)
	check(malformed_cursor.retained_staging_bookkeeping_count() == 0,
		"rejected cursor drains retained bookkeeping")

	var reversed_cells: Dictionary = source_snapshot.duplicate(true)
	var reverse_target: Dictionary = reversed_cells.sections[1]
	(reverse_target.cells as Array).reverse()
	var reversed_cell_cursor = CURSOR.new()
	reversed_cell_cursor.begin(_new_source(generator), reversed_cells, 84)
	var reversed_cell_result := _run_until_terminal(reversed_cell_cursor, 84)
	check(reversed_cell_result.get("status") == "rejected"
		and reversed_cell_result.get("reason") == "cell_order_or_duplicate_invalid",
		"reverse cell order rejected", reversed_cell_result)
	_drain(reversed_cell_cursor, 84, 2)

	var duplicate_cells: Dictionary = source_snapshot.duplicate(true)
	var duplicate_cell_section: Dictionary = duplicate_cells.sections[1]
	(duplicate_cell_section.cells as Array).append((duplicate_cell_section.cells as Array)[0].duplicate(true))
	var duplicate_cell_cursor = CURSOR.new()
	duplicate_cell_cursor.begin(_new_source(generator), duplicate_cells, 85)
	var duplicate_cell_result := _run_until_terminal(duplicate_cell_cursor, 85)
	check(duplicate_cell_result.get("status") == "rejected"
		and duplicate_cell_result.get("reason") == "cell_order_or_duplicate_invalid",
		"duplicate cell rejected", duplicate_cell_result)
	_drain(duplicate_cell_cursor, 85, 2)

func _test_cancel_during_sky(generator, live_source, snapshot: Dictionary) -> void:
	var cursor = CURSOR.new()
	cursor.begin(live_source, snapshot, 91)
	var result := _run_input_to_sky(cursor, 91)
	check(result.get("status") == "section_sky", "cancellation fixture reached skyline phase", result)
	var sky_result: Dictionary = cursor.advance(91, 1, 1)
	check(int(sky_result.get("skyYCellsProcessed", 0)) <= 1, "partial skyline work is bounded", sky_result)
	check(cursor.cancel(91).get("status") == "cancelled", "active staging cancellation accepted")
	check(cursor.advance(91, 1, 1).get("status") == "cancelled", "cancelled cursor cannot advance")
	var cleanup := _drain(cursor, 91, 1)
	check(cleanup.get("status") == "disposed" and int(cleanup.get("maxItemsCleared", 0)) <= 1,
		"cancelled stage drains boundedly", cleanup)
	check(cursor.retained_staging_bookkeeping_count() == 0, "cancelled cursor drains owned queues")
	check(live_source.save_all_section_deltas() == snapshot,
		"sky-stage cancellation does not mutate live save authority")

func _run_input_to_sky(cursor, generation: int) -> Dictionary:
	for _i in range(100):
		var value: Dictionary = cursor.status(generation)
		if value.get("status") != "input":
			return value
		cursor.advance(generation, 2, 1)
	return cursor.status(generation)

func _run_until_terminal(cursor, generation: int) -> Dictionary:
	for _i in range(1000):
		var value: Dictionary = cursor.status(generation)
		if value.get("status") in ["rejected", "complete", "cancelled", "disposed"]:
			return value
		value = cursor.advance(generation, 1, 1)
		if value.get("status") == "rejected":
			return value
	return cursor.status(generation)

func _drain(cursor, generation: int, cap: int) -> Dictionary:
	var max_items_cleared := 0
	for _i in range(200000):
		var value: Dictionary = cursor.dispose_step(generation, cap)
		max_items_cleared = maxi(max_items_cleared, int(value.get("itemsCleared", 0)))
		if value.get("status") == "disposed":
			value["maxItemsCleared"] = max_items_cleared
			return value
		if value.get("status") != "disposing":
			return value
	return cursor.status(generation)

func _new_source(generator):
	var service = SERVICE.new()
	service.setup(null, generator)
	return service

func _state(material: String, solid: bool, fluid: String, sky: int, source: String) -> Dictionary:
	return {
		"material": material,
		"biome": "underground_air" if not solid else "deep_underground",
		"solid": solid,
		"density": 1.35 if solid else -1.35,
		"fluid": fluid,
		"light": {"sky": sky, "block": 0},
		"metadata": {"saveDelta": true, "terrainMeshAffects": true, "source": source}
	}

func _service_parity(a, b) -> bool:
	return a.edited_cells == b.edited_cells \
		and a.durable_delta_cells_by_section == b.durable_delta_cells_by_section \
		and a.durable_delta_section_snapshots == b.durable_delta_section_snapshots \
		and a.durable_delta_dirty_sections == b.durable_delta_dirty_sections \
		and a.mesh_edited_column_counts == b.mesh_edited_column_counts \
		and a.mesh_edited_cells_by_section == b.mesh_edited_cells_by_section \
		and a.surface_projection_edited_column_counts == b.surface_projection_edited_column_counts \
		and a.scene_block_previous_states == b.scene_block_previous_states \
		and a.light_cells == b.light_cells \
		and a.light_cells_by_section == b.light_cells_by_section \
		and a.block_light_sources == b.block_light_sources \
		and a.pending_sky_light_columns == b.pending_sky_light_columns \
		and a.section_revisions == b.section_revisions \
		and a.fluid_section_revisions == b.fluid_section_revisions \
		and a.section_column_revisions == b.section_column_revisions \
		and a.fluid_section_column_revisions == b.fluid_section_column_revisions \
		and a.fluid_dirty_cells == b.fluid_dirty_cells \
		and a.dirty_sections == b.dirty_sections \
		and a.revision == b.revision and a.fluid_revision == b.fluid_revision

func _staged_residue(service) -> Array[String]:
	var residue: Array[String] = []
	if service == null:
		return residue
	for property_name in [
		"sections", "edited_cells", "durable_delta_cells_by_section", "durable_delta_section_snapshots",
		"durable_delta_dirty_sections", "durable_delta_section_revisions", "scene_block_cells",
		"mesh_edited_column_counts", "mesh_edited_cells_by_section", "surface_projection_edited_column_counts",
		"scene_block_previous_states", "light_cells", "light_cells_by_section", "block_light_sources",
		"pending_sky_light_columns", "section_revisions", "fluid_section_revisions", "section_column_revisions",
		"fluid_section_column_revisions", "fluid_dirty_cells", "dirty_sections", "top_surface_y_cache",
		"terrain_mesh_surface_cache", "exposed_floor_cache"
	]:
		if not (service.get(property_name) as Dictionary).is_empty():
			residue.append(property_name)
	if int(service.revision) != 0:
		residue.append("revision=%d" % int(service.revision))
	if int(service.fluid_revision) != 0:
		residue.append("fluid_revision=%d" % int(service.fluid_revision))
	return residue

func _parity_details(a, b) -> Dictionary:
	return {
		"fieldParity": {
			"editedCells": a.edited_cells == b.edited_cells,
			"durableCells": a.durable_delta_cells_by_section == b.durable_delta_cells_by_section,
			"durableSnapshots": a.durable_delta_section_snapshots == b.durable_delta_section_snapshots,
			"durableDirty": a.durable_delta_dirty_sections == b.durable_delta_dirty_sections,
			"meshColumnCounts": a.mesh_edited_column_counts == b.mesh_edited_column_counts,
			"meshCells": a.mesh_edited_cells_by_section == b.mesh_edited_cells_by_section,
			"surfaceCounts": a.surface_projection_edited_column_counts == b.surface_projection_edited_column_counts,
			"scenePrevious": a.scene_block_previous_states == b.scene_block_previous_states,
			"lightCells": a.light_cells == b.light_cells,
			"lightBySection": a.light_cells_by_section == b.light_cells_by_section,
			"blockSources": a.block_light_sources == b.block_light_sources,
			"pendingSky": a.pending_sky_light_columns == b.pending_sky_light_columns,
			"sectionRevisions": a.section_revisions == b.section_revisions,
			"fluidSectionRevisions": a.fluid_section_revisions == b.fluid_section_revisions,
			"sectionColumnRevisions": a.section_column_revisions == b.section_column_revisions,
			"fluidSectionColumns": a.fluid_section_column_revisions == b.fluid_section_column_revisions,
			"fluidDirty": a.fluid_dirty_cells == b.fluid_dirty_cells,
			"dirtySections": a.dirty_sections == b.dirty_sections
		},
		"revision": [a.revision, b.revision],
		"fluidRevision": [a.fluid_revision, b.fluid_revision],
		"editedCells": [a.edited_cells.size(), b.edited_cells.size()],
		"lightCells": [a.light_cells.size(), b.light_cells.size()],
		"dirtySections": [a.dirty_sections.size(), b.dirty_sections.size()],
		"fluidDirtyCells": [a.fluid_dirty_cells.size(), b.fluid_dirty_cells.size()]
	}

func _write_report() -> void:
	var report_path := OS.get_environment("N3_TERRAIN_RESTORE_REPORT")
	if report_path.is_empty():
		report_path = "user://terrain-volume-restore-cursor-contract.json"
	var absolute_path := ProjectSettings.globalize_path(report_path)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	var report := {
		"schema": "terrain-volume-restore-cursor-contract/v1",
		"passed": failures.is_empty(),
		"checks": checks,
		"failures": failures,
		"observations": observations,
		"scope": "isolated staged restore parity/cancellation contract; no Main or live-service integration; synchronous decoded-snapshot input only",
		"inputLease": "caller must transfer exclusive mutation ownership of parsed terrainVolume until cursor terminal; nested Dictionary/Array aliases are not mechanically immutable",
		"limitations": [
			"Does not make SaveSystem whole-file read or binary decode asynchronous.",
			"Input item and skylight Y-count caps are not CPU-time bounds for normalization or complex metadata.",
			"No active-service install, Main/Continue wiring, N5 physical readiness, or Gate5/no-lag acceptance is claimed."
		]
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print(JSON.stringify({"reportPath": report_path, "passed": failures.is_empty(), "checks": checks, "failures": failures}))
