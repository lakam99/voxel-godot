extends SceneTree

const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")
const SECTION_SIZE := 16
const FLUID_NONE := 0
const FLUID_WATER := 1
const FLUID_LAVA := 2

class FixtureGenerator:
	extends RefCounted

	var states := {}

	func _init(initial_states := {}) -> void:
		states = initial_states.duplicate(true) if initial_states is Dictionary else {}

	func generate_cell_state(cell: Vector3i) -> Dictionary:
		if states.has(cell):
			return (states[cell] as Dictionary).duplicate(true)
		return {
			"blockId": "air",
			"material": "air",
			"biome": "underground_air",
			"solid": false,
			"density": -1.35,
			"fluid": "",
			"light": {"sky": 0, "block": 0}
		}

	func world_bottom_cell_y() -> int:
		return -4

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_EXACT_FLUID_PAYLOAD_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vox43/exact-fluid-payload-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())

	var target := Vector3i(1, 0, 0)
	var halo_target := Vector3i(2, 0, 0)
	var solid_neighbor := Vector3i(0, 0, 0)
	var lava_target := Vector3i(1, 0, 1)
	var generator := FixtureGenerator.new({
		target: fluid_state("water"),
		halo_target: fluid_state("water"),
		solid_neighbor: solid_state(),
		lava_target: fluid_state("lava")
	})
	var service = TerrainVolumeServiceScript.new()
	service.setup(null, generator)
	service.request_section(Vector3i.ZERO)
	var lazy_exact_state := service.begin_exact_fluid_payload_for_meshing_chunk(0, 0, 2, 0, 0, 14)
	add_result(
		"exact_payload_defers_dense_channel_allocation_until_fluid_probe",
		String(lazy_exact_state.get("phase", "")) == "probe" \
			and not bool(lazy_exact_state.get("denseChannelsAllocated", true)) \
			and not lazy_exact_state.has("solidValues") \
			and not lazy_exact_state.has("fluidTypeIds"),
		{
			"phase": lazy_exact_state.get("phase", ""),
			"denseChannelsAllocated": lazy_exact_state.get("denseChannelsAllocated", true),
			"hasSolidValues": lazy_exact_state.has("solidValues"),
			"hasFluidTypeIds": lazy_exact_state.has("fluidTypeIds")
		}
	)

	var coarse_payload := service.section_payload_for_meshing_chunk(0, 0, 2, 0, 0, 14)
	add_result(
		"terrain_payload_keeps_explicit_lod_step",
		int(coarse_payload.get("terrainStepCells", -1)) == 14 and int(coarse_payload.get("stepCells", -1)) == 14,
		{
			"terrainStepCells": coarse_payload.get("terrainStepCells", -1),
			"stepCells": coarse_payload.get("stepCells", -1)
		}
	)

	var build := build_snapshot(service, 14, 7)
	var payload: Dictionary = build.get("payload", {})
	var payload_shape_ok: bool = int(payload.get("terrainStepCells", -1)) == 14 \
		and int(payload.get("fluidStepCells", -1)) == 1 \
		and int(payload.get("stepCells", -1)) == 1 \
		and payload.get("minCell", Vector3i.ZERO) == Vector3i(-1, -1, -1) \
		and payload.get("maxCell", Vector3i.ZERO) == Vector3i(2, 1, 2) \
		and bool(payload.get("boundsInclusive", false)) \
		and bool(payload.get("immutable", false))
	add_result("exact_payload_step_and_halo_contract", payload_shape_ok, payload_header(payload, build))

	var target_sample := sample_payload(payload, target)
	var halo_sample := sample_payload(payload, halo_target)
	var solid_sample := sample_payload(payload, solid_neighbor)
	var lava_sample := sample_payload(payload, lava_target)
	add_result(
		"exact_payload_numeric_cell_contents",
		int(target_sample.get("fluidType", -1)) == FLUID_WATER \
			and not bool(target_sample.get("solid", true)) \
			and int(halo_sample.get("fluidType", -1)) == FLUID_WATER \
			and int(solid_sample.get("fluidType", -1)) == FLUID_NONE \
			and bool(solid_sample.get("solid", false)) \
			and int(lava_sample.get("fluidType", -1)) == FLUID_LAVA,
		{
			"target": target_sample,
			"haloTarget": halo_sample,
			"solidNeighbor": solid_sample,
			"lavaTarget": lava_sample
		}
	)
	add_result(
		"exact_payload_is_minimal_numeric_only",
		payload_sections_are_minimal(payload),
		{"sectionCount": (payload.get("sections", []) as Array).size()}
	)
	add_result(
		"exact_payload_build_is_incremental",
		int(build.get("iterations", 0)) > 1 and int(build.get("maxBatchCells", 0)) <= 7,
		build
	)

	var old_revision := int(payload.get("fluidRevision", -1))
	var old_signature := String(payload.get("signature", ""))
	service.set_cell_state(target, fluid_state("lava"), "payload_contract_edit", false)
	var edited_build := build_snapshot(service, 14, 9)
	var edited_payload: Dictionary = edited_build.get("payload", {})
	add_result(
		"snapshot_is_immutable_and_revisioned",
		int(sample_payload(payload, target).get("fluidType", -1)) == FLUID_WATER \
			and int(sample_payload(edited_payload, target).get("fluidType", -1)) == FLUID_LAVA \
			and int(edited_payload.get("fluidRevision", -1)) > old_revision \
			and String(edited_payload.get("signature", "")) != old_signature,
		{
			"oldTarget": sample_payload(payload, target),
			"newTarget": sample_payload(edited_payload, target),
			"oldFluidRevision": old_revision,
			"newFluidRevision": edited_payload.get("fluidRevision", -1),
			"signatureChanged": String(edited_payload.get("signature", "")) != old_signature
		}
	)

	var saved_deltas := service.save_all_section_deltas()
	var repeated_deltas := service.save_all_section_deltas()
	var saved_sections: Array = saved_deltas.get("sections",[])
	var repeated_sections: Array = repeated_deltas.get("sections",[])
	var retained_section_identity: bool = saved_sections.size()==1 and repeated_sections.size()==1 \
		and is_same(saved_sections[0],repeated_sections[0])
	var retained_record_immutable: bool = retained_section_identity and saved_sections[0].is_read_only() \
		and saved_sections[0].cells.is_read_only() and saved_sections[0].cells[0].is_read_only() \
		and saved_sections[0].cells[0].state.is_read_only()
	add_result("durable_delta_snapshot_reuses_deep_immutable_section",retained_record_immutable,
		{"sectionCount":saved_sections.size(),"retainedIdentity":retained_section_identity})
	var loaded_service = TerrainVolumeServiceScript.new()
	loaded_service.setup(null, FixtureGenerator.new(generator.states))
	loaded_service.load_section_deltas(saved_deltas)
	var loaded_payload: Dictionary = build_snapshot(loaded_service, 14, 11).get("payload", {})
	add_result(
		"save_loaded_edit_updates_fluid_revision",
		int(sample_payload(loaded_payload, target).get("fluidType", -1)) == FLUID_LAVA \
			and int(loaded_payload.get("fluidRevision", 0)) > 0 \
			and not (loaded_payload.get("sectionRevisions", []) as Array).is_empty(),
		{
			"target": sample_payload(loaded_payload, target),
			"fluidRevision": loaded_payload.get("fluidRevision", -1),
			"sectionRevisions": loaded_payload.get("sectionRevisions", [])
		}
	)
	service.clear_cell_state(target,"payload_contract_clear")
	var cleared_deltas: Dictionary = service.save_all_section_deltas()
	add_result("durable_delta_snapshot_invalidates_only_changed_section",
		saved_sections.size()==1 and sample_saved_delta(saved_deltas,target).get("fluid")=="lava" \
		and sample_saved_delta(cleared_deltas,target).is_empty(),
		{"before":sample_saved_delta(saved_deltas,target),"after":sample_saved_delta(cleared_deltas,target)})

	var stale_state := service.begin_exact_fluid_payload_for_meshing_chunk(0, 0, 2, 0, 0, 14)
	service.set_cell_state(Vector3i(0, 0, 1), fluid_state("water"), "payload_contract_stale", false)
	var stale_advance: Dictionary = service.advance_exact_fluid_payload_state(stale_state, 10.0, 7)
	add_result(
		"authority_change_rejects_stale_snapshot",
		bool(stale_advance.get("complete", false)) and bool(stale_advance.get("stale", false)) and (stale_advance.get("payload", {}) as Dictionary).is_empty(),
		stale_advance
	)

	var cancelled_state := service.begin_exact_fluid_payload_for_meshing_chunk(0, 0, 2, 0, 0, 14)
	cancelled_state = service.cancel_exact_fluid_payload_state(cancelled_state)
	var cancelled_advance: Dictionary = service.advance_exact_fluid_payload_state(cancelled_state, 10.0, 7)
	add_result(
		"cancelled_snapshot_produces_no_payload",
		bool(cancelled_advance.get("complete", false)) and bool(cancelled_advance.get("cancelled", false)) and (cancelled_advance.get("payload", {}) as Dictionary).is_empty(),
		cancelled_advance
	)

	var empty_service = TerrainVolumeServiceScript.new()
	empty_service.setup(null, FixtureGenerator.new())
	var empty_payload: Dictionary = build_snapshot(empty_service, 14, 13).get("payload", {})
	add_result(
		"fluid_free_bounds_elide_section_payload",
		not bool(empty_payload.get("hasFluid", true)) \
			and int(empty_payload.get("fluidCellCount", -1)) == 0 \
			and (empty_payload.get("sections", []) as Array).is_empty(),
		payload_header(empty_payload, {})
	)

	var scene_block_service = TerrainVolumeServiceScript.new()
	scene_block_service.setup(null, FixtureGenerator.new())
	scene_block_service.set_cell_state(target, fluid_state("water"), "payload_contract_scene_block_fluid", false)
	var revision_before_scene_block := int(scene_block_service.fluid_revision)
	var scene_block := solid_state()
	scene_block["metadata"] = {
		"source": "scene_block",
		"renderedBySceneBlock": true,
		"terrainMeshAffects": false
	}
	scene_block_service.set_cell_state(solid_neighbor, scene_block, "payload_contract_scene_block", false)
	var scene_block_payload: Dictionary = build_snapshot(scene_block_service, 14, 17).get("payload", {})
	add_result(
		"scene_rendered_blocks_do_not_enter_fluid_occupancy",
		not bool(sample_payload(scene_block_payload, solid_neighbor).get("solid", true)) \
			and int(scene_block_service.fluid_revision) == revision_before_scene_block,
		{
			"sceneBlockSample": sample_payload(scene_block_payload, solid_neighbor),
			"fluidRevisionBefore": revision_before_scene_block,
			"fluidRevisionAfter": scene_block_service.fluid_revision
		}
	)

	var boundary_service = TerrainVolumeServiceScript.new()
	boundary_service.setup(null, FixtureGenerator.new())
	var boundary_cell := Vector3i(1, 0, 1)
	boundary_service.set_cell_state(boundary_cell, fluid_state("water"), "payload_contract_boundary_fluid", false)
	var boundary_dirty_chunks: Array = boundary_service.consume_dirty_chunk_keys(2)
	add_result(
		"boundary_fluid_edit_invalidates_halo_chunks",
		boundary_service.fluid_chunk_revision_with_halo(Vector2i(0, 0), 2) > 0 \
			and boundary_service.fluid_chunk_revision_with_halo(Vector2i(1, 0), 2) > 0 \
			and boundary_service.fluid_chunk_revision_with_halo(Vector2i(0, 1), 2) > 0 \
			and not boundary_service.chunk_has_edits(Vector2i(0, 0), 2) \
			and boundary_dirty_chunks.size() == 3 \
			and boundary_dirty_chunks.has(Vector2i(0, 0)) \
			and boundary_dirty_chunks.has(Vector2i(1, 0)) \
			and boundary_dirty_chunks.has(Vector2i(0, 1)),
		{
			"ownerRevision": boundary_service.fluid_chunk_revision_with_halo(Vector2i(0, 0), 2),
			"eastRevision": boundary_service.fluid_chunk_revision_with_halo(Vector2i(1, 0), 2),
			"southRevision": boundary_service.fluid_chunk_revision_with_halo(Vector2i(0, 1), 2),
			"solidTerrainDirty": boundary_service.chunk_has_edits(Vector2i(0, 0), 2),
			"dirtyChunks": boundary_dirty_chunks
		}
	)
	finish()

func build_snapshot(service, terrain_step_cells: int, max_cells: int) -> Dictionary:
	var state: Dictionary = service.begin_exact_fluid_payload_for_meshing_chunk(0, 0, 2, 0, 0, terrain_step_cells)
	var iterations := 0
	var max_batch_cells := 0
	var payload := {}
	while iterations < 1000:
		iterations += 1
		var advanced: Dictionary = service.advance_exact_fluid_payload_state(state, 10.0, max_cells)
		state = advanced.get("state", state)
		max_batch_cells = maxi(max_batch_cells, int(advanced.get("cellsProcessed", 0)))
		if bool(advanced.get("complete", false)):
			payload = advanced.get("payload", {}) if advanced.get("payload", {}) is Dictionary else {}
			break
	return {
		"payload": payload,
		"iterations": iterations,
		"maxBatchCells": max_batch_cells,
		"complete": bool(state.get("complete", false)),
		"stale": bool(state.get("stale", false)),
		"cancelled": bool(state.get("cancelled", false))
	}

func fluid_state(fluid_id: String) -> Dictionary:
	return {
		"blockId": fluid_id,
		"material": fluid_id,
		"biome": "underground_air",
		"solid": false,
		"density": -1.35,
		"fluid": fluid_id,
		"light": {"sky": 0, "block": 0}
	}

func solid_state() -> Dictionary:
	return {
		"blockId": "stone",
		"material": "stone",
		"biome": "underground",
		"solid": true,
		"density": 1.35,
		"fluid": "",
		"light": {"sky": 0, "block": 0}
	}

func sample_payload(payload: Dictionary, cell: Vector3i) -> Dictionary:
	var cells: Dictionary = payload.get("cells", {}) if payload.get("cells", {}) is Dictionary else {}
	if not cells.is_empty():
		var min_cell: Vector3i = payload.get("minCell", Vector3i.ZERO)
		var size: Vector3i = cells.get("size", Vector3i.ZERO)
		var local := cell - min_cell
		var index := local.y + size.y * (local.x + size.x * local.z)
		var solid_values: PackedByteArray = cells.get("solid", PackedByteArray())
		var fluid_values: PackedByteArray = cells.get("fluidTypeIds", PackedByteArray())
		return {
			"found": index >= 0 and index < solid_values.size() and index < fluid_values.size(),
			"solid": index >= 0 and index < solid_values.size() and int(solid_values[index]) > 0,
			"fluidType": int(fluid_values[index]) if index >= 0 and index < fluid_values.size() else -1
		}
	var section_key := Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)
	for value in payload.get("sections", []):
		if not (value is Dictionary):
			continue
		var section: Dictionary = value
		if section.get("sectionKey", Vector3i.ZERO) != section_key:
			continue
		var local := Vector3i(posmod(cell.x, SECTION_SIZE), posmod(cell.y, SECTION_SIZE), posmod(cell.z, SECTION_SIZE))
		var index := local.x + SECTION_SIZE * (local.y + SECTION_SIZE * local.z)
		var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
		var solid_values: PackedByteArray = channels.get("solid", PackedByteArray())
		var fluid_values: PackedByteArray = channels.get("fluidTypeIds", PackedByteArray())
		return {
			"found": index < solid_values.size() and index < fluid_values.size(),
			"solid": index < solid_values.size() and int(solid_values[index]) > 0,
			"fluidType": int(fluid_values[index]) if index < fluid_values.size() else -1
		}
	return {"found": false, "solid": false, "fluidType": -1}

func payload_sections_are_minimal(payload: Dictionary) -> bool:
	var cells: Dictionary = payload.get("cells", {}) if payload.get("cells", {}) is Dictionary else {}
	if cells.keys().size() != 3 or not cells.has("size") or not cells.has("solid") or not cells.has("fluidTypeIds"):
		return false
	if not (cells.get("size") is Vector3i) or not (cells.get("solid") is PackedByteArray) or not (cells.get("fluidTypeIds") is PackedByteArray):
		return false
	var size: Vector3i = cells.get("size", Vector3i.ZERO)
	var expected_size := size.x * size.y * size.z
	if (cells.get("solid") as PackedByteArray).size() != expected_size or (cells.get("fluidTypeIds") as PackedByteArray).size() != expected_size:
		return false
	if not (payload.get("sections", []) as Array).is_empty():
		return false
	for value in payload.get("sections", []):
		if not (value is Dictionary):
			return false
		var section: Dictionary = value
		var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
		if channels.keys().size() != 2 or not channels.has("solid") or not channels.has("fluidTypeIds"):
			return false
		if not (channels.get("solid") is PackedByteArray) or not (channels.get("fluidTypeIds") is PackedByteArray):
			return false
		if (channels.get("solid") as PackedByteArray).size() != SECTION_SIZE * SECTION_SIZE * SECTION_SIZE:
			return false
		if (channels.get("fluidTypeIds") as PackedByteArray).size() != SECTION_SIZE * SECTION_SIZE * SECTION_SIZE:
			return false
	return true

func payload_header(payload: Dictionary, build: Dictionary) -> Dictionary:
	return {
		"terrainStepCells": payload.get("terrainStepCells", -1),
		"fluidStepCells": payload.get("fluidStepCells", -1),
		"stepCells": payload.get("stepCells", -1),
		"minCell": vector3i(payload.get("minCell", Vector3i.ZERO)),
		"maxCell": vector3i(payload.get("maxCell", Vector3i.ZERO)),
		"hasFluid": payload.get("hasFluid", false),
		"fluidCellCount": payload.get("fluidCellCount", -1),
		"solidCellCount": payload.get("solidCellCount", -1),
		"cellCount": payload.get("cellCount", -1),
		"sectionCount": (payload.get("sections", []) as Array).size(),
		"fluidRevision": payload.get("fluidRevision", -1),
		"signature": payload.get("signature", ""),
		"build": build
	}

func add_result(name: String, passed: bool, details: Dictionary) -> void:
	results.append({"name": name, "passed": passed, "details": json_safe(details)})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, JSON.stringify(json_safe(details))])

func vector3i(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func json_safe(value):
	if value is Vector3i:
		return vector3i(value)
	if value is Vector2i:
		return {"x": value.x, "z": value.y}
	if value is PackedStringArray:
		return Array(value)
	if value is Dictionary:
		var result := {}
		for key in value.keys():
			if key == "state" or key == "payload":
				continue
			result[key] = json_safe(value[key])
		return result
	if value is Array:
		var result := []
		for item in value:
			result.append(json_safe(item))
		return result
	return value

func sample_saved_delta(snapshot: Dictionary, cell: Vector3i) -> Dictionary:
	for section: Dictionary in snapshot.get("sections",[]):
		for record: Dictionary in section.get("cells",[]):
			var coordinates: Array = record.get("cell",[])
			if coordinates.size()==3 and Vector3i(int(coordinates[0]),int(coordinates[1]),int(coordinates[2]))==cell:
				return record.get("state",{})
	return {}

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func finish() -> void:
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "exact_fluid_payload_contract",
		"testId": "vox_43_exact_fluid_payload_contract",
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "contract",
		"scope": "TerrainVolumeService exact immutable fluid payload contract. This does not alter or accept rendering behavior.",
		"resultCount": results.size(),
		"failureCount": failures,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))
	quit(0 if bool(report.get("passed", false)) else 1)
