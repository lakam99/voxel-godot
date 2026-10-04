extends RefCounted
class_name TerrainVolumeService

signal terrain_section_revision_changed(section_key: Vector3i, revision: int,
	changed_min_cell: Vector3i, changed_max_cell: Vector3i)

const SECTION_SIZE := 16
const SECTION_CELL_COUNT := SECTION_SIZE * SECTION_SIZE * SECTION_SIZE
const UNDERGROUND_AIR_BIOME := "underground_air"
const UNDERGROUND_AIR_SEARCH_STEP_CELLS := 4
const UNDERGROUND_AIR_MIN_CONNECTED_CELLS := 24
const UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS := 8
const UNDERGROUND_AIR_DEFAULT_SEARCH_DEPTH_CELLS := 72
const UNDERGROUND_AIR_VISUAL_MIN_SOLID_NEIGHBORS := 3
const MAX_BLOCK_LIGHT_LEVEL := 15
const SKY_LIGHT_COLUMNS_PER_PROCESS := 2
const FLUID_TYPE_NONE := 0
const FLUID_TYPE_WATER := 1
const FLUID_TYPE_LAVA := 2

# TerrainVolumeService is owned by WorldGenerationSystem. It must never retain
# either its owner or a worker's generation context: VoxelTerrain invokes
# generator callbacks on native worker threads and those otherwise form a
# RefCounted cycle (context -> generator -> service -> context). Keep only the
# scalar terrain contract and a non-owning callback reference.
var configured_cell_size := 1.35
var configured_min_height := 4.0
var configured_max_height := 120.0
var generator_ref: WeakRef
var sections := {}
var edited_cells := {}
# Durable save records are normalized and frozen when an edit changes. Autosave
# only assembles section references, instead of walking and deep-copying every
# live edit on the gameplay thread.
var durable_delta_cells_by_section := {}
var durable_delta_section_snapshots := {}
var durable_delta_dirty_sections := {}
var durable_delta_section_revisions := {}
var scene_block_cells := {}
var mesh_edited_column_counts := {}
var mesh_edited_cells_by_section := {}
var surface_projection_edited_column_counts := {}
var scene_block_previous_states := {}
var light_cells := {}
var light_cells_by_section := {}
var block_light_sources := {}
var pending_sky_light_columns := {}
var section_revisions := {}
var fluid_section_revisions := {}
var section_column_revisions := {}
var fluid_section_column_revisions := {}
var fluid_dirty_cells := {}
var dirty_sections := {}
var top_surface_y_cache := {}
var terrain_mesh_surface_cache := {}
var exposed_floor_cache := {}
var revision := 0
var fluid_revision := 0

func setup(main_node, generator_node) -> void:
	if main_node != null:
		configured_cell_size = float(main_node.get("CELL")) if main_node.get("CELL") != null else 1.35
		configured_min_height = float(main_node.get("MIN_HEIGHT")) if main_node.get("MIN_HEIGHT") != null else 4.0
		configured_max_height = float(main_node.get("MAX_HEIGHT")) if main_node.get("MAX_HEIGHT") != null else 120.0
	generator_ref = weakref(generator_node) if generator_node != null else null

func active_generator():
	return generator_ref.get_ref() if generator_ref != null else null

func reset() -> void:
	sections.clear()
	edited_cells.clear()
	durable_delta_cells_by_section.clear()
	durable_delta_section_snapshots.clear()
	durable_delta_dirty_sections.clear()
	durable_delta_section_revisions.clear()
	scene_block_cells.clear()
	mesh_edited_column_counts.clear()
	mesh_edited_cells_by_section.clear()
	surface_projection_edited_column_counts.clear()
	scene_block_previous_states.clear()
	light_cells.clear()
	light_cells_by_section.clear()
	block_light_sources.clear()
	pending_sky_light_columns.clear()
	section_revisions.clear()
	fluid_section_revisions.clear()
	section_column_revisions.clear()
	fluid_section_column_revisions.clear()
	fluid_dirty_cells.clear()
	dirty_sections.clear()
	top_surface_y_cache.clear()
	terrain_mesh_surface_cache.clear()
	exposed_floor_cache.clear()
	revision = 0
	fluid_revision = 0

func reset_for_seed() -> void:
	reset()

func section_key_for_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)

func local_cell_for(cell: Vector3i) -> Vector3i:
	return Vector3i(posmod(cell.x, SECTION_SIZE), posmod(cell.y, SECTION_SIZE), posmod(cell.z, SECTION_SIZE))

func section_cell_index(local: Vector3i) -> int:
	return int(local.x) + SECTION_SIZE * (int(local.y) + SECTION_SIZE * int(local.z))

func request_section(chunk_key, section_y := 0) -> Dictionary:
	var section_key := Vector3i.ZERO
	if chunk_key is Vector3i:
		section_key = chunk_key
	elif chunk_key is Vector2i:
		section_key = Vector3i(chunk_key.x, int(section_y), chunk_key.y)
	elif chunk_key is Dictionary:
		if chunk_key.has("sectionKey"):
			section_key = vector3i_from_value(chunk_key.get("sectionKey"), Vector3i.ZERO)
		else:
			section_key = Vector3i(int(chunk_key.get("x", 0)), int(chunk_key.get("y", section_y)), int(chunk_key.get("z", 0)))
	else:
		section_key = Vector3i(0, int(section_y), 0)
	return generate_section(section_key)

func request_sections_for_bounds(min_cell: Vector3i, max_cell: Vector3i) -> Array[Vector3i]:
	var from_cell := Vector3i(
		mini(min_cell.x, max_cell.x),
		mini(min_cell.y, max_cell.y),
		mini(min_cell.z, max_cell.z)
	)
	var to_cell := Vector3i(
		maxi(min_cell.x, max_cell.x),
		maxi(min_cell.y, max_cell.y),
		maxi(min_cell.z, max_cell.z)
	)
	var from_section := section_key_for_cell(from_cell)
	var to_section := section_key_for_cell(to_cell)
	var requested: Array[Vector3i] = []
	for section_z in range(from_section.z, to_section.z + 1):
		for section_y in range(from_section.y, to_section.y + 1):
			for section_x in range(from_section.x, to_section.x + 1):
				var section_key := Vector3i(section_x, section_y, section_z)
				generate_section(section_key)
				requested.append(section_key)
	return requested

func section_payload_for_bounds(min_cell: Vector3i, max_cell: Vector3i) -> Dictionary:
	var section_keys := request_sections_for_bounds(min_cell, max_cell)
	var payload_sections := []
	for section_key in section_keys:
		if not sections.has(section_key):
			continue
		var section: Dictionary = sections[section_key]
		payload_sections.append({
			"sectionKey": section_key,
			"sectionSize": int(section.get("sectionSize", SECTION_SIZE)),
			"channelSchema": int(section.get("channelSchema", 0)),
			"channels": section.get("channels", {}),
			"revision": int(section.get("revision", 0))
		})
	return {
		"schemaVersion": 1,
		"sectionSize": SECTION_SIZE,
		"cellSize": cell_size(),
		"minCell": min_cell,
		"maxCell": max_cell,
		"worldBottomCellY": world_bottom_cell_y(),
		"worldTopCellY": world_top_cell_y(),
		"revision": revision,
		"sections": payload_sections
	}

func section_payload_for_meshing_chunk(start_x: int, start_z: int, chunk_size: int, min_y: int, max_y: int, step_cells := 1) -> Dictionary:
	var step := maxi(1, int(step_cells))
	var safe_chunk_size := maxi(1, int(chunk_size))
	var native_min_y := int(min_y) - 1
	var native_max_y := int(max_y) + 1
	var payload_sections_by_key := {}
	var has_fluid := false
	for z in range(int(start_z) - step, int(start_z) + safe_chunk_size + step + 1, step):
		for x in range(int(start_x) - step, int(start_x) + safe_chunk_size + step + 1, step):
			for y in range(native_min_y, native_max_y + step + 1, step):
				var cell_state := write_sparse_payload_cell(payload_sections_by_key, Vector3i(x, y, z))
				if String(cell_state.get("fluid", "")) != "":
					has_fluid = true
	var payload_sections := []
	for section in payload_sections_by_key.values():
		payload_sections.append(section)
	return {
		"schemaVersion": 1,
		"sectionSize": SECTION_SIZE,
		"cellSize": cell_size(),
		"minCell": Vector3i(int(start_x) - step, native_min_y, int(start_z) - step),
		"maxCell": Vector3i(int(start_x) + safe_chunk_size + step, native_max_y + step, int(start_z) + safe_chunk_size + step),
		"worldBottomCellY": world_bottom_cell_y(),
		"worldTopCellY": world_top_cell_y(),
		"revision": revision,
		"terrainStepCells": step,
		"stepCells": step,
		"sparse": true,
		"hasFluid": has_fluid,
		"sections": payload_sections
	}

func begin_section_payload_for_meshing_chunk(start_x: int, start_z: int, chunk_size: int, min_y: int, max_y: int, step_cells := 1) -> Dictionary:
	var step := maxi(1, int(step_cells))
	var safe_chunk_size := maxi(1, int(chunk_size))
	var native_min_y := int(min_y) - 1
	var native_max_y := int(max_y) + 1
	var min_sample_x := int(start_x) - step
	var max_sample_x := int(start_x) + safe_chunk_size + step
	var min_sample_y := native_min_y
	var max_sample_y := native_max_y + step
	var min_sample_z := int(start_z) - step
	var max_sample_z := int(start_z) + safe_chunk_size + step
	return {
		"schemaVersion": 1,
		"sectionSize": SECTION_SIZE,
		"cellSize": cell_size(),
		"minCell": Vector3i(min_sample_x, native_min_y, min_sample_z),
		"maxCell": Vector3i(max_sample_x, max_sample_y, max_sample_z),
		"worldBottomCellY": world_bottom_cell_y(),
		"worldTopCellY": world_top_cell_y(),
		"revision": revision,
		"terrainStepCells": step,
		"sparse": true,
		"chunkSize": safe_chunk_size,
		"startX": int(start_x),
		"startZ": int(start_z),
		"minY": int(min_y),
		"maxY": int(max_y),
		"stepCells": step,
		"minSampleX": min_sample_x,
		"maxSampleX": max_sample_x,
		"minSampleY": min_sample_y,
		"maxSampleY": max_sample_y,
		"minSampleZ": min_sample_z,
		"maxSampleZ": max_sample_z,
		"cursorX": min_sample_x,
		"cursorY": min_sample_y,
		"cursorZ": min_sample_z,
		"payloadSectionsByKey": {},
		"hasFluid": false,
		"cellsProcessed": 0,
		"complete": false
	}

func advance_section_payload_state(state: Dictionary, budget_ms := 2.0, max_cells := 192) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if state.is_empty() or bool(state.get("complete", false)):
		return {
			"state": state,
			"complete": bool(state.get("complete", false)),
			"payload": finalized_section_payload_from_state(state) if bool(state.get("complete", false)) else {},
			"cellsProcessed": 0,
			"preparedSections": 0,
			"elapsedMs": 0.0
		}
	var step := maxi(1, int(state.get("stepCells", 1)))
	var min_x := int(state.get("minSampleX", 0))
	var max_x := int(state.get("maxSampleX", min_x))
	var min_y := int(state.get("minSampleY", 0))
	var max_y := int(state.get("maxSampleY", min_y))
	var min_z := int(state.get("minSampleZ", 0))
	var max_z := int(state.get("maxSampleZ", min_z))
	var cursor_x := int(state.get("cursorX", min_x))
	var cursor_y := int(state.get("cursorY", min_y))
	var cursor_z := int(state.get("cursorZ", min_z))
	var sections_by_key: Dictionary = state.get("payloadSectionsByKey", {}) if state.get("payloadSectionsByKey", {}) is Dictionary else {}
	var processed := 0
	var cell_cap := maxi(1, int(max_cells))
	var time_cap := maxf(0.1, float(budget_ms))
	while cursor_z <= max_z:
		var cell_state := write_sparse_payload_cell(sections_by_key, Vector3i(cursor_x, cursor_y, cursor_z))
		if String(cell_state.get("fluid", "")) != "":
			state["hasFluid"] = true
		processed += 1
		cursor_y += step
		if cursor_y > max_y:
			cursor_y = min_y
			cursor_x += step
			if cursor_x > max_x:
				cursor_x = min_x
				cursor_z += step
		if processed >= cell_cap:
			break
		if float(Time.get_ticks_usec() - started_usec) / 1000.0 >= time_cap:
			break
	var complete := cursor_z > max_z
	state["cursorX"] = cursor_x
	state["cursorY"] = cursor_y
	state["cursorZ"] = cursor_z
	state["payloadSectionsByKey"] = sections_by_key
	state["cellsProcessed"] = int(state.get("cellsProcessed", 0)) + processed
	state["complete"] = complete
	var payload := finalized_section_payload_from_state(state) if complete else {}
	return {
		"state": state,
		"complete": complete,
		"payload": payload,
		"cellsProcessed": processed,
		"preparedSections": sections_by_key.size(),
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
	}

func finalized_section_payload_from_state(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return {}
	var sections_by_key: Dictionary = state.get("payloadSectionsByKey", {}) if state.get("payloadSectionsByKey", {}) is Dictionary else {}
	var payload_sections := []
	for section in sections_by_key.values():
		payload_sections.append(section)
	return {
		"schemaVersion": int(state.get("schemaVersion", 1)),
		"sectionSize": SECTION_SIZE,
		"cellSize": cell_size(),
		"minCell": state.get("minCell", Vector3i.ZERO),
		"maxCell": state.get("maxCell", Vector3i.ZERO),
		"worldBottomCellY": world_bottom_cell_y(),
		"worldTopCellY": world_top_cell_y(),
		"revision": int(state.get("revision", revision)),
		"terrainStepCells": maxi(1, int(state.get("terrainStepCells", state.get("stepCells", 1)))),
		"sparse": true,
		"hasFluid": bool(state.get("hasFluid", false)),
		"chunkSize": int(state.get("chunkSize", SECTION_SIZE)),
		"startX": int(state.get("startX", 0)),
		"startZ": int(state.get("startZ", 0)),
		"minY": int(state.get("minY", 0)),
		"maxY": int(state.get("maxY", 0)),
		"stepCells": maxi(1, int(state.get("stepCells", 1))),
		"sections": payload_sections
	}

func begin_exact_fluid_payload_for_meshing_chunk(
	start_x: int,
	start_z: int,
	chunk_size: int,
	min_y: int,
	max_y: int,
	terrain_step_cells := 1
) -> Dictionary:
	var safe_chunk_size := maxi(1, int(chunk_size))
	var from_y := mini(int(min_y), int(max_y))
	var to_y := maxi(int(min_y), int(max_y))
	var requested_from_y := from_y
	var requested_to_y := to_y
	var generation = active_generator()
	if generation != null and generation.has_method("generated_fluid_cell_y_bounds"):
		var generated_bounds_value = generation.call("generated_fluid_cell_y_bounds")
		if generated_bounds_value is Dictionary:
			var generated_bounds: Dictionary = generated_bounds_value
			var generated_from_y := maxi(from_y, int(generated_bounds.get("minY", from_y)))
			var generated_to_y := mini(to_y, int(generated_bounds.get("maxY", to_y)))
			if generated_to_y >= generated_from_y:
				from_y = generated_from_y
				to_y = generated_to_y
	var edit_min_x := int(start_x) - 1
	var edit_max_x := int(start_x) + safe_chunk_size
	var edit_min_z := int(start_z) - 1
	var edit_max_z := int(start_z) + safe_chunk_size
	for cell_value in edited_cells.keys():
		var edited_cell: Vector3i = cell_value
		if edited_cell.x < edit_min_x or edited_cell.x > edit_max_x or edited_cell.z < edit_min_z or edited_cell.z > edit_max_z:
			continue
		var edited_state: Dictionary = edited_cells[edited_cell] if edited_cells[edited_cell] is Dictionary else {}
		if bool(edited_state.get("solid", false)) or fluid_type_id(String(edited_state.get("fluid", ""))) == FLUID_TYPE_NONE:
			continue
		if edited_cell.y >= requested_from_y and edited_cell.y <= requested_to_y:
			from_y = mini(from_y, edited_cell.y)
			to_y = maxi(to_y, edited_cell.y)
	var min_cell := Vector3i(int(start_x) - 1, from_y - 1, int(start_z) - 1)
	var max_cell := Vector3i(int(start_x) + safe_chunk_size, to_y + 1, int(start_z) + safe_chunk_size)
	var payload_size := max_cell - min_cell + Vector3i.ONE
	var payload_cell_count := payload_size.x * payload_size.y * payload_size.z
	return {
		"schemaVersion": 1,
		"terrainStepCells": maxi(1, int(terrain_step_cells)),
		"fluidStepCells": 1,
		"stepCells": 1,
		"chunkSize": safe_chunk_size,
		"startX": int(start_x),
		"startZ": int(start_z),
		"minY": from_y,
		"maxY": to_y,
		"minCell": min_cell,
		"maxCell": max_cell,
		"boundsInclusive": true,
		"volumeRevision": revision,
		"fluidRevision": fluid_revision,
		"cursorX": min_cell.x,
		"cursorY": min_cell.y,
		"cursorZ": min_cell.z,
		"payloadSize": payload_size,
		# Most streamed chunks do not contain fluid.  Do the exact, bounded probe
		# before allocating dense channels, so opening a mesh job cannot synchronously
		# allocate a full chunk-sized buffer on the gameplay frame.  A fluid-bearing
		# chunk promotes itself to capture only after that probe completes.
		"phase": "probe",
		"denseChannelsAllocated": false,
		"sectionKeySeen": {},
		"sectionKeys": [],
		"hasFluid": false,
		"fluidCellCount": 0,
		"solidCellCount": 0,
		"cellsProcessed": 0,
		"complete": false,
		"cancelled": false,
		"stale": false
	}

func cancel_exact_fluid_payload_state(state: Dictionary) -> Dictionary:
	state["cancelled"] = true
	return state

func advance_exact_fluid_payload_state(state: Dictionary, budget_ms := 2.0, max_cells := 512) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if state.is_empty():
		return exact_fluid_payload_advance_result(state, {}, 0, 0.0)
	if bool(state.get("complete", false)):
		var existing_payload: Dictionary = state.get("payload", {}) if state.get("payload", {}) is Dictionary else {}
		return exact_fluid_payload_advance_result(state, existing_payload, 0, 0.0)
	if bool(state.get("cancelled", false)):
		state["complete"] = true
		state["payload"] = {}
		return exact_fluid_payload_advance_result(state, {}, 0, elapsed_ms_since(started_usec))
	if int(state.get("volumeRevision", -1)) != revision or int(state.get("fluidRevision", -1)) != fluid_revision:
		state["stale"] = true
		state["complete"] = true
		state["payload"] = {}
		return exact_fluid_payload_advance_result(state, {}, 0, elapsed_ms_since(started_usec))
	var min_cell: Vector3i = state.get("minCell", Vector3i.ZERO)
	var max_cell: Vector3i = state.get("maxCell", min_cell)
	var cursor_x := int(state.get("cursorX", min_cell.x))
	var cursor_y := int(state.get("cursorY", min_cell.y))
	var cursor_z := int(state.get("cursorZ", min_cell.z))
	var phase := String(state.get("phase", "capture"))
	if phase == "capture_allocate":
		# Dense exact channels are required only once fluid was proven in the
		# preceding bounded probe.  Keep this separate from sampling so the
		# allocation cannot combine with a full terrain/fluid step in one frame.
		var allocation_size := maxi(0, int(state.get("payloadCellCount", 0)))
		if allocation_size <= 0:
			var allocation_bounds_size: Vector3i = state.get("payloadSize", Vector3i.ZERO)
			allocation_size = allocation_bounds_size.x * allocation_bounds_size.y * allocation_bounds_size.z
		var allocated_solid_values := PackedByteArray()
		var allocated_fluid_type_ids := PackedByteArray()
		allocated_solid_values.resize(allocation_size)
		allocated_fluid_type_ids.resize(allocation_size)
		state["solidValues"] = allocated_solid_values
		state["fluidTypeIds"] = allocated_fluid_type_ids
		state["denseChannelsAllocated"] = true
		state["phase"] = "capture"
		state["cursorX"] = min_cell.x
		state["cursorY"] = min_cell.y
		state["cursorZ"] = min_cell.z
		state["sectionKeySeen"] = {}
		state["sectionKeys"] = []
		state["hasFluid"] = false
		state["fluidCellCount"] = 0
		state["solidCellCount"] = 0
		state["cellsProcessed"] = 0
		return exact_fluid_payload_advance_result(state, {}, 0, elapsed_ms_since(started_usec))
	var capture_payload := phase == "capture"
	var solid_values: PackedByteArray = state.get("solidValues", PackedByteArray())
	var fluid_type_ids: PackedByteArray = state.get("fluidTypeIds", PackedByteArray())
	var payload_size: Vector3i = state.get("payloadSize", Vector3i.ZERO)
	var section_key_seen: Dictionary = state.get("sectionKeySeen", {}) if state.get("sectionKeySeen", {}) is Dictionary else {}
	var section_keys: Array = state.get("sectionKeys", []) if state.get("sectionKeys", []) is Array else []
	var processed := 0
	var cell_cap := maxi(1, int(max_cells))
	var time_cap := maxf(0.1, float(budget_ms))
	while cursor_z <= max_cell.z:
		var cell := Vector3i(cursor_x, cursor_y, cursor_z)
		var authoritative_state := get_cell_state(cell)
		var fluid_state := fluid_mesh_payload_state(authoritative_state)
		var local := cell - min_cell
		var payload_index := local.y + payload_size.y * (local.x + payload_size.x * local.z)
		var solid := bool(fluid_state.get("solid", false))
		var fluid_type := fluid_type_id(String(fluid_state.get("fluid", "")))
		if capture_payload:
			solid_values[payload_index] = 1 if solid else 0
			fluid_type_ids[payload_index] = fluid_type
		if solid:
			state["solidCellCount"] = int(state.get("solidCellCount", 0)) + 1
		elif fluid_type != FLUID_TYPE_NONE:
			state["hasFluid"] = true
			state["fluidCellCount"] = int(state.get("fluidCellCount", 0)) + 1
		var section_key := section_key_for_cell(cell)
		var section_key_text := "%d,%d,%d" % [section_key.x, section_key.y, section_key.z]
		if not section_key_seen.has(section_key_text):
			section_key_seen[section_key_text] = true
			section_keys.append(section_key)
		processed += 1
		cursor_y += 1
		if cursor_y > max_cell.y:
			cursor_y = min_cell.y
			cursor_x += 1
			if cursor_x > max_cell.x:
				cursor_x = min_cell.x
				cursor_z += 1
		if processed >= cell_cap or elapsed_ms_since(started_usec) >= time_cap:
			break
	state["cursorX"] = cursor_x
	state["cursorY"] = cursor_y
	state["cursorZ"] = cursor_z
	state["solidValues"] = solid_values
	state["fluidTypeIds"] = fluid_type_ids
	state["sectionKeySeen"] = section_key_seen
	state["sectionKeys"] = section_keys
	state["cellsProcessed"] = int(state.get("cellsProcessed", 0)) + processed
	var complete := cursor_z > max_cell.z
	if complete and phase == "probe" and bool(state.get("hasFluid", false)):
		# The probe has established that dense exact data is necessary.  Reset the
		# accounting for the capture pass; the final payload still represents one
		# immutable snapshot, while both scans remain independently frame-budgeted.
		state["phase"] = "capture_allocate"
		state["complete"] = false
		return exact_fluid_payload_advance_result(state, {}, processed, elapsed_ms_since(started_usec))
	state["complete"] = complete
	var payload := finalized_exact_fluid_payload_from_state(state) if complete else {}
	if complete:
		state["payload"] = payload
	return exact_fluid_payload_advance_result(state, payload, processed, elapsed_ms_since(started_usec))

func exact_fluid_payload_advance_result(state: Dictionary, payload: Dictionary, cells_processed: int, elapsed_ms: float) -> Dictionary:
	return {
		"state": state,
		"complete": bool(state.get("complete", false)),
		"cancelled": bool(state.get("cancelled", false)),
		"stale": bool(state.get("stale", false)),
		"payload": payload,
		"cellsProcessed": int(cells_processed),
		"preparedSections": (state.get("sectionKeys", []) as Array).size() if state.get("sectionKeys", []) is Array else 0,
		"elapsedMs": elapsed_ms
	}

func finalized_exact_fluid_payload_from_state(state: Dictionary) -> Dictionary:
	if state.is_empty() or bool(state.get("cancelled", false)) or bool(state.get("stale", false)):
		return {}
	var has_fluid := bool(state.get("hasFluid", false))
	var revision_entries := []
	var signature_parts := PackedStringArray()
	var section_keys: Array = state.get("sectionKeys", []) if state.get("sectionKeys", []) is Array else []
	for key_value in section_keys:
		var section_key: Vector3i = key_value
		var key_text := "%d,%d,%d" % [section_key.x, section_key.y, section_key.z]
		var section_revision := exact_fluid_section_revision(section_key)
		revision_entries.append({"sectionKey": section_key, "revision": section_revision})
		signature_parts.append("%s:%d" % [key_text, section_revision])
	var volume_revision := int(state.get("volumeRevision", revision))
	var snapshot_fluid_revision := int(state.get("fluidRevision", fluid_revision))
	var cells := {}
	if has_fluid:
		cells = {
			"size": state.get("payloadSize", Vector3i.ZERO),
			"solid": state.get("solidValues", PackedByteArray()),
			"fluidTypeIds": state.get("fluidTypeIds", PackedByteArray())
		}
	return {
		"schemaVersion": 1,
		"immutable": true,
		"sectionSize": SECTION_SIZE,
		"cellSize": cell_size(),
		"terrainStepCells": maxi(1, int(state.get("terrainStepCells", 1))),
		"fluidStepCells": 1,
		"stepCells": 1,
		"chunkSize": int(state.get("chunkSize", SECTION_SIZE)),
		"startX": int(state.get("startX", 0)),
		"startZ": int(state.get("startZ", 0)),
		"minY": int(state.get("minY", 0)),
		"maxY": int(state.get("maxY", 0)),
		"minCell": state.get("minCell", Vector3i.ZERO),
		"maxCell": state.get("maxCell", Vector3i.ZERO),
		"boundsInclusive": true,
		"revision": volume_revision,
		"fluidRevision": snapshot_fluid_revision,
		"sectionRevisions": revision_entries,
		"signature": "exact-fluid-v1:%d:%d:%s" % [volume_revision, snapshot_fluid_revision, ";".join(signature_parts)],
		"hasFluid": has_fluid,
		"fluidCellCount": int(state.get("fluidCellCount", 0)),
		"solidCellCount": int(state.get("solidCellCount", 0)),
		"cellCount": int(state.get("cellsProcessed", 0)),
		"fluidTypeSchema": {"none": FLUID_TYPE_NONE, "water": FLUID_TYPE_WATER, "lava": FLUID_TYPE_LAVA},
		"cells": cells,
		"sections": []
	}

func exact_fluid_section_revision(section_key: Vector3i) -> int:
	var result := int(section_revisions.get(section_key, 0))
	result = maxi(result, int(fluid_section_revisions.get(section_key, 0)))
	if sections.has(section_key):
		var section: Dictionary = sections[section_key]
		result = maxi(result, int(section.get("revision", 0)))
	return result

func fluid_type_id(fluid_id: String) -> int:
	match fluid_id:
		"water":
			return FLUID_TYPE_WATER
		"lava":
			return FLUID_TYPE_LAVA
		_:
			return FLUID_TYPE_NONE

func fluid_state_changed(before: Dictionary, after: Dictionary) -> bool:
	return bool(before.get("solid", false)) != bool(after.get("solid", false)) \
		or fluid_type_id(String(before.get("fluid", ""))) != fluid_type_id(String(after.get("fluid", "")))

func classify_fluid_only_edit(before: Dictionary, after: Dictionary) -> Dictionary:
	var normalized := after.duplicate(true)
	var metadata: Dictionary = normalized.get("metadata", {}) if normalized.get("metadata", {}) is Dictionary else {}
	if metadata.has("terrainMeshAffects"):
		return normalized
	var changes_fluid := fluid_type_id(String(before.get("fluid", ""))) != fluid_type_id(String(normalized.get("fluid", "")))
	if changes_fluid and not bool(before.get("solid", false)) and not bool(normalized.get("solid", false)):
		metadata = metadata.duplicate(true)
		metadata["terrainMeshAffects"] = false
		normalized["metadata"] = metadata
	return normalized

func fluid_mesh_payload_state(state: Dictionary) -> Dictionary:
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	var source := String(metadata.get("source", ""))
	if bool(metadata.get("renderedBySceneBlock", false)) or source == "scene_block":
		var empty_state := state.duplicate(true)
		empty_state["solid"] = false
		empty_state["fluid"] = ""
		return empty_state
	return state

func mark_fluid_section_changed(cell: Vector3i, notify_section_candidate := true) -> void:
	fluid_revision += 1
	var section_key := section_key_for_cell(cell)
	fluid_section_revisions[section_key] = fluid_revision
	update_section_column_revision(fluid_section_column_revisions, section_key, fluid_revision)
	fluid_dirty_cells[cell] = true
	if notify_section_candidate:
		terrain_section_revision_changed.emit(section_key, fluid_revision, cell, cell)

func elapsed_ms_since(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0

func write_sparse_payload_cell(payload_sections_by_key: Dictionary, cell: Vector3i) -> Dictionary:
	var section_key := section_key_for_cell(cell)
	var key_text := "%d,%d,%d" % [section_key.x, section_key.y, section_key.z]
	var section: Dictionary = {}
	if payload_sections_by_key.has(key_text):
		section = payload_sections_by_key[key_text]
	else:
		section = {
			"sectionKey": section_key,
			"sectionSize": SECTION_SIZE,
			"channelSchema": 1,
			"channels": empty_sparse_section_channels(),
			"revision": revision,
			"sparse": true
		}
		payload_sections_by_key[key_text] = section
	var channels: Dictionary = section.get("channels", {})
	var state := get_cell_state(cell)
	var payload_state := terrain_mesh_payload_state(cell, state)
	write_state_to_sparse_section_channels(channels, section_cell_index(local_cell_for(cell)), payload_state)
	section["channels"] = channels
	payload_sections_by_key[key_text] = section
	return payload_state

func terrain_mesh_payload_state(_cell: Vector3i, state: Dictionary) -> Dictionary:
	if cell_state_affects_terrain_mesh(state):
		return state
	var payload_state := state.duplicate(true)
	payload_state["blockId"] = "air"
	payload_state["material"] = "air"
	payload_state["solid"] = false
	payload_state["density"] = -cell_size()
	payload_state["fluid"] = ""
	var metadata: Dictionary = payload_state.get("metadata", {}) if payload_state.get("metadata", {}) is Dictionary else {}
	metadata = metadata.duplicate(true)
	metadata["source"] = "non_terrain_scene_block_payload_air"
	metadata["terrainMeshAffects"] = false
	payload_state["metadata"] = metadata
	return payload_state

func generate_section(section_key: Vector3i) -> Dictionary:
	if sections.has(section_key):
		return sections[section_key]
	var states := {}
	var channels := empty_section_channels()
	var origin := section_key * SECTION_SIZE
	for z in range(SECTION_SIZE):
		for y in range(SECTION_SIZE):
			for x in range(SECTION_SIZE):
				var cell := Vector3i(origin.x + x, origin.y + y, origin.z + z)
				var local := Vector3i(x, y, z)
				var state := (edited_cells[cell] as Dictionary).duplicate(true) if edited_cells.has(cell) else generated_cell_state(cell)
				state = with_light_override(cell, state)
				states[local] = state
				write_state_to_section_channels(channels, section_cell_index(local), state)
	var section := {
		"sectionKey": section_key,
		"sectionSize": SECTION_SIZE,
		"channelSchema": 1,
		"channels": channels,
		"states": states,
		"generated": true,
		"revision": revision
	}
	sections[section_key] = section
	return section

func empty_section_channels() -> Dictionary:
	var block_ids := PackedStringArray()
	var material_ids := PackedStringArray()
	var biome_ids := PackedStringArray()
	var fluid_ids := PackedStringArray()
	var solid_cells := PackedByteArray()
	var sky_light := PackedByteArray()
	var block_light := PackedByteArray()
	var density := PackedFloat32Array()
	var surface_y := PackedFloat32Array()
	block_ids.resize(SECTION_CELL_COUNT)
	material_ids.resize(SECTION_CELL_COUNT)
	biome_ids.resize(SECTION_CELL_COUNT)
	fluid_ids.resize(SECTION_CELL_COUNT)
	solid_cells.resize(SECTION_CELL_COUNT)
	sky_light.resize(SECTION_CELL_COUNT)
	block_light.resize(SECTION_CELL_COUNT)
	density.resize(SECTION_CELL_COUNT)
	surface_y.resize(SECTION_CELL_COUNT)
	return {
		"blockIds": block_ids,
		"materialIds": material_ids,
		"biomeIds": biome_ids,
		"fluidIds": fluid_ids,
		"solid": solid_cells,
		"skyLight": sky_light,
		"blockLight": block_light,
		"density": density,
		"surfaceY": surface_y,
		"metadataByIndex": {}
	}

func empty_air_section_channels() -> Dictionary:
	var channels := empty_section_channels()
	var block_ids: PackedStringArray = channels.get("blockIds", PackedStringArray())
	var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
	var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
	var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
	var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
	var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
	var surface_y_values: PackedFloat32Array = channels.get("surfaceY", PackedFloat32Array())
	var air_density := -cell_size()
	for index in range(SECTION_CELL_COUNT):
		block_ids[index] = "air"
		material_ids[index] = "air"
		biome_ids[index] = "plains"
		fluid_ids[index] = ""
		solid_cells[index] = 0
		sky_light[index] = 15
		block_light[index] = 0
		density_values[index] = air_density
		surface_y_values[index] = 0.0
	channels["blockIds"] = block_ids
	channels["materialIds"] = material_ids
	channels["biomeIds"] = biome_ids
	channels["fluidIds"] = fluid_ids
	channels["solid"] = solid_cells
	channels["skyLight"] = sky_light
	channels["blockLight"] = block_light
	channels["density"] = density_values
	channels["surfaceY"] = surface_y_values
	return channels

func empty_sparse_section_channels() -> Dictionary:
	return {
		"sparseCellIndices": PackedInt32Array(),
		"sparseIndexByCellIndex": {},
		"blockIds": PackedStringArray(),
		"materialIds": PackedStringArray(),
		"biomeIds": PackedStringArray(),
		"fluidIds": PackedStringArray(),
		"solid": PackedByteArray(),
		"skyLight": PackedByteArray(),
		"blockLight": PackedByteArray(),
		"density": PackedFloat32Array(),
		"surfaceY": PackedFloat32Array(),
		"metadataBySparseIndex": {}
	}

func write_state_to_sparse_section_channels(channels: Dictionary, cell_index: int, state: Dictionary) -> void:
	if cell_index < 0 or cell_index >= SECTION_CELL_COUNT:
		return
	var lookup: Dictionary = channels.get("sparseIndexByCellIndex", {}) if channels.get("sparseIndexByCellIndex", {}) is Dictionary else {}
	var sparse_index := -1
	if lookup.has(cell_index):
		sparse_index = int(lookup[cell_index])
	else:
		var sparse_indices: PackedInt32Array = channels.get("sparseCellIndices", PackedInt32Array())
		var block_ids: PackedStringArray = channels.get("blockIds", PackedStringArray())
		var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
		var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
		var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
		var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
		var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
		var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
		var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
		var surface_y_values: PackedFloat32Array = channels.get("surfaceY", PackedFloat32Array())
		sparse_index = sparse_indices.size()
		lookup[cell_index] = sparse_index
		sparse_indices.append(cell_index)
		block_ids.append("")
		material_ids.append("")
		biome_ids.append("")
		fluid_ids.append("")
		solid_cells.append(0)
		sky_light.append(15)
		block_light.append(0)
		density_values.append(-cell_size())
		surface_y_values.append(0.0)
		channels["sparseCellIndices"] = sparse_indices
		channels["blockIds"] = block_ids
		channels["materialIds"] = material_ids
		channels["biomeIds"] = biome_ids
		channels["fluidIds"] = fluid_ids
		channels["solid"] = solid_cells
		channels["skyLight"] = sky_light
		channels["blockLight"] = block_light
		channels["density"] = density_values
		channels["surfaceY"] = surface_y_values
	channels["sparseIndexByCellIndex"] = lookup
	write_sparse_state_at_index(channels, sparse_index, state)

func write_sparse_state_at_index(channels: Dictionary, sparse_index: int, state: Dictionary) -> void:
	if sparse_index < 0:
		return
	var block_ids: PackedStringArray = channels.get("blockIds", PackedStringArray())
	var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
	var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
	var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
	var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
	var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
	var surface_y_values: PackedFloat32Array = channels.get("surfaceY", PackedFloat32Array())
	if sparse_index >= material_ids.size() or sparse_index >= biome_ids.size() or sparse_index >= solid_cells.size() or sparse_index >= density_values.size():
		return
	var material := String(state.get("material", "air"))
	var solid := bool(state.get("solid", material != "air"))
	var light := normalize_light(state.get("light", {}), solid)
	block_ids[sparse_index] = String(state.get("blockId", material))
	material_ids[sparse_index] = material
	biome_ids[sparse_index] = String(state.get("biome", "plains"))
	fluid_ids[sparse_index] = String(state.get("fluid", ""))
	solid_cells[sparse_index] = 1 if solid else 0
	sky_light[sparse_index] = clampi(int(light.get("sky", 0)), 0, 15)
	block_light[sparse_index] = clampi(int(light.get("block", 0)), 0, MAX_BLOCK_LIGHT_LEVEL)
	density_values[sparse_index] = float(state.get("density", cell_size() if solid else -cell_size()))
	if sparse_index < surface_y_values.size():
		surface_y_values[sparse_index] = float(state.get("surfaceY", 0.0))
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	var metadata_by_sparse_index: Dictionary = channels.get("metadataBySparseIndex", {}) if channels.get("metadataBySparseIndex", {}) is Dictionary else {}
	if metadata.is_empty():
		metadata_by_sparse_index.erase(sparse_index)
	else:
		metadata_by_sparse_index[sparse_index] = metadata.duplicate(true)
	channels["blockIds"] = block_ids
	channels["materialIds"] = material_ids
	channels["biomeIds"] = biome_ids
	channels["fluidIds"] = fluid_ids
	channels["solid"] = solid_cells
	channels["skyLight"] = sky_light
	channels["blockLight"] = block_light
	channels["density"] = density_values
	channels["surfaceY"] = surface_y_values
	channels["metadataBySparseIndex"] = metadata_by_sparse_index

func write_state_to_section_channels(channels: Dictionary, index: int, state: Dictionary) -> void:
	if index < 0 or index >= SECTION_CELL_COUNT:
		return
	var block_ids: PackedStringArray = channels.get("blockIds", PackedStringArray())
	var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
	var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
	var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
	var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
	var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
	var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
	var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
	var surface_y_values: PackedFloat32Array = channels.get("surfaceY", PackedFloat32Array())
	if material_ids.size() <= index or biome_ids.size() <= index or solid_cells.size() <= index or density_values.size() <= index:
		return
	var material := String(state.get("material", "air"))
	var solid := bool(state.get("solid", material != "air"))
	var light := normalize_light(state.get("light", {}), solid)
	block_ids[index] = String(state.get("blockId", material))
	material_ids[index] = material
	biome_ids[index] = String(state.get("biome", "plains"))
	fluid_ids[index] = String(state.get("fluid", ""))
	solid_cells[index] = 1 if solid else 0
	sky_light[index] = clampi(int(light.get("sky", 0)), 0, 15)
	block_light[index] = clampi(int(light.get("block", 0)), 0, MAX_BLOCK_LIGHT_LEVEL)
	density_values[index] = float(state.get("density", cell_size() if solid else -cell_size()))
	if surface_y_values.size() > index:
		surface_y_values[index] = float(state.get("surfaceY", 0.0))
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	var metadata_by_index: Dictionary = channels.get("metadataByIndex", {})
	if metadata.is_empty():
		metadata_by_index.erase(index)
	else:
		metadata_by_index[index] = metadata.duplicate(true)
	channels["blockIds"] = block_ids
	channels["materialIds"] = material_ids
	channels["biomeIds"] = biome_ids
	channels["fluidIds"] = fluid_ids
	channels["solid"] = solid_cells
	channels["skyLight"] = sky_light
	channels["blockLight"] = block_light
	channels["density"] = density_values
	channels["surfaceY"] = surface_y_values
	channels["metadataByIndex"] = metadata_by_index

func section_cell_state(section: Dictionary, local: Vector3i, world_cell: Vector3i) -> Dictionary:
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	if not channels.is_empty():
		var index := section_cell_index(local)
		var material_ids: PackedStringArray = channels.get("materialIds", PackedStringArray())
		var biome_ids: PackedStringArray = channels.get("biomeIds", PackedStringArray())
		var solid_cells: PackedByteArray = channels.get("solid", PackedByteArray())
		var density_values: PackedFloat32Array = channels.get("density", PackedFloat32Array())
		if index >= 0 and index < material_ids.size() and index < biome_ids.size() and index < solid_cells.size() and index < density_values.size():
			var block_ids: PackedStringArray = channels.get("blockIds", PackedStringArray())
			var fluid_ids: PackedStringArray = channels.get("fluidIds", PackedStringArray())
			var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
			var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
			var surface_y_values: PackedFloat32Array = channels.get("surfaceY", PackedFloat32Array())
			var metadata_by_index: Dictionary = channels.get("metadataByIndex", {}) if channels.get("metadataByIndex", {}) is Dictionary else {}
			var material := String(material_ids[index])
			var solid := int(solid_cells[index]) > 0
			return {
				"cell": world_cell,
				"sectionKey": section_key_for_cell(world_cell),
				"localCell": local,
				"blockId": String(block_ids[index]) if index < block_ids.size() else material,
				"material": material,
				"biome": String(biome_ids[index]),
				"solid": solid,
				"density": float(density_values[index]),
				"surfaceY": float(surface_y_values[index]) if index < surface_y_values.size() else float(world_cell.y) * cell_size(),
				"fluid": String(fluid_ids[index]) if index < fluid_ids.size() else "",
				"light": {
					"sky": int(sky_light[index]) if index < sky_light.size() else (0 if solid else 15),
					"block": int(block_light[index]) if index < block_light.size() else 0
				},
				"metadata": (metadata_by_index.get(index, {}) as Dictionary).duplicate(true) if metadata_by_index.get(index, {}) is Dictionary else {},
				"generated": true,
				"edited": false
			}
	var states: Dictionary = section.get("states", {})
	if states.has(local):
		return (states[local] as Dictionary).duplicate(true)
	return generated_cell_state(world_cell)

func write_loaded_section_cell_state(cell: Vector3i, state: Dictionary) -> void:
	var section_key := section_key_for_cell(cell)
	if not sections.has(section_key):
		return
	var section: Dictionary = sections[section_key]
	var local := local_cell_for(cell)
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	if not channels.is_empty():
		write_state_to_section_channels(channels, section_cell_index(local), state)
		section["channels"] = channels
	var states: Dictionary = section.get("states", {}) if section.get("states", {}) is Dictionary else {}
	if not states.is_empty():
		states[local] = state.duplicate(true)
		section["states"] = states
	section["revision"] = revision
	sections[section_key] = section

func write_loaded_section_cell_light(cell: Vector3i, light: Dictionary) -> void:
	var section_key := section_key_for_cell(cell)
	if not sections.has(section_key):
		return
	var section: Dictionary = sections[section_key]
	var local := local_cell_for(cell)
	var index := section_cell_index(local)
	var channels: Dictionary = section.get("channels", {}) if section.get("channels", {}) is Dictionary else {}
	if not channels.is_empty():
		var sky_light: PackedByteArray = channels.get("skyLight", PackedByteArray())
		var block_light: PackedByteArray = channels.get("blockLight", PackedByteArray())
		if index >= 0 and index < sky_light.size() and index < block_light.size():
			sky_light[index] = clampi(int(light.get("sky", 0)), 0, 15)
			block_light[index] = clampi(int(light.get("block", 0)), 0, MAX_BLOCK_LIGHT_LEVEL)
			channels["skyLight"] = sky_light
			channels["blockLight"] = block_light
			section["channels"] = channels
	var states: Dictionary = section.get("states", {}) if section.get("states", {}) is Dictionary else {}
	if states.has(local):
		var state: Dictionary = (states[local] as Dictionary).duplicate(true) if states[local] is Dictionary else {}
		state["light"] = light.duplicate(true)
		states[local] = state
		section["states"] = states
	section["revision"] = revision
	sections[section_key] = section

func get_cell_state(cell: Vector3i) -> Dictionary:
	if scene_block_cells.has(cell):
		return with_light_override(cell, (scene_block_cells[cell] as Dictionary).duplicate(true))
	if edited_cells.has(cell):
		return with_light_override(cell, (edited_cells[cell] as Dictionary).duplicate(true))
	var section_key := section_key_for_cell(cell)
	if sections.has(section_key):
		var section: Dictionary = sections[section_key]
		var local := local_cell_for(cell)
		return with_light_override(cell, section_cell_state(section, local, cell))
	return with_light_override(cell, generated_cell_state(cell))

func set_scene_block_overlay(cell: Vector3i, state: Dictionary, reason := "") -> Dictionary:
	var normalized := normalize_cell_state(cell, state, true)
	normalized["editReason"] = String(reason)
	scene_block_cells[cell] = normalized
	revision += 1
	return normalized.duplicate(true)

func clear_scene_block_overlay(cell: Vector3i) -> bool:
	if not scene_block_cells.has(cell):
		return false
	scene_block_cells.erase(cell)
	revision += 1
	return true

func set_cell_state(cell: Vector3i, state: Dictionary, reason := "", rebuild_sky_light := true) -> Dictionary:
	var previous_fluid_state := get_cell_state(cell)
	return set_cell_state_with_previous(cell, state, previous_fluid_state, reason, rebuild_sky_light)

func set_cell_state_with_previous(cell: Vector3i, state: Dictionary, previous_fluid_state: Dictionary, reason := "", rebuild_sky_light := true) -> Dictionary:
	var previous_state := {}
	var previous_mesh_affects := false
	var previous_surface_affects := false
	if edited_cells.has(cell):
		previous_state = edited_cells[cell]
		previous_mesh_affects = cell_state_affects_terrain_mesh(previous_state)
		previous_surface_affects = cell_state_affects_surface_projection(previous_state)
	var normalized := normalize_cell_state(cell, state, true)
	normalized = classify_fluid_only_edit(previous_fluid_state, normalized)
	normalized["editReason"] = String(reason)
	var normalized_metadata: Dictionary = normalized.get("metadata", {}) if normalized.get("metadata", {}) is Dictionary else {}
	var previous_metadata: Dictionary = previous_fluid_state.get("metadata", {}) if previous_fluid_state.get("metadata", {}) is Dictionary else {}
	if String(normalized_metadata.get("source", "")) == "scene_block" and String(previous_metadata.get("source", "")) != "scene_block":
		scene_block_previous_states[cell] = previous_fluid_state.duplicate(true)
	elif String(normalized_metadata.get("source", "")) != "scene_block":
		scene_block_previous_states.erase(cell)
	if previous_mesh_affects:
		adjust_mesh_edited_column_count(cell, -1)
		set_mesh_edited_cell_index(cell, false)
	if previous_surface_affects:
		adjust_surface_projection_edited_column_count(cell, -1)
	edited_cells[cell] = normalized
	if cell_state_affects_terrain_mesh(normalized):
		adjust_mesh_edited_column_count(cell, 1)
		set_mesh_edited_cell_index(cell, true)
	if cell_state_affects_surface_projection(normalized):
		adjust_surface_projection_edited_column_count(cell, 1)
	revision += 1
	_update_durable_delta_cell(cell,normalized)
	if fluid_state_changed(fluid_mesh_payload_state(previous_fluid_state), fluid_mesh_payload_state(normalized)):
		mark_fluid_section_changed(cell)
	var skip_loaded_section_write := String(normalized_metadata.get("source", "")) == "scene_block" \
		and bool(normalized_metadata.get("renderedBySceneBlock", false)) \
		and not bool(normalized_metadata.get("terrainMeshAffects", false))
	if not skip_loaded_section_write:
		write_loaded_section_cell_state(cell, normalized)
	if previous_mesh_affects or cell_state_affects_terrain_mesh(normalized):
		mark_section_dirty(section_key_for_cell(cell), { "reason": reason, "cell": cell })
	if rebuild_sky_light and (terrain_edit_updates_sky_light(normalized) or terrain_edit_updates_sky_light(previous_state)):
		rebuild_sky_light_column(cell.x, cell.z, reason)
	return normalized.duplicate(true)

func clear_cell_state(cell: Vector3i, reason := "") -> void:
	if not edited_cells.has(cell):
		return
	var previous: Dictionary = edited_cells[cell]
	edited_cells.erase(cell)
	var restored_state: Dictionary
	if scene_block_previous_states.has(cell):
		restored_state = (scene_block_previous_states[cell] as Dictionary).duplicate(true)
		scene_block_previous_states.erase(cell)
	else:
		restored_state = generated_cell_state(cell)
	if cell_state_affects_terrain_mesh(previous):
		adjust_mesh_edited_column_count(cell, -1)
		set_mesh_edited_cell_index(cell, false)
	if cell_state_affects_surface_projection(previous):
		adjust_surface_projection_edited_column_count(cell, -1)
	revision += 1
	_update_durable_delta_cell(cell,{})
	if fluid_state_changed(fluid_mesh_payload_state(previous), fluid_mesh_payload_state(restored_state)):
		mark_fluid_section_changed(cell)
	var previous_metadata: Dictionary = previous.get("metadata", {}) if previous.get("metadata", {}) is Dictionary else {}
	var skipped_loaded_section_write := String(previous_metadata.get("source", "")) == "scene_block" \
		and bool(previous_metadata.get("renderedBySceneBlock", false)) \
		and not bool(previous_metadata.get("terrainMeshAffects", false))
	if not skipped_loaded_section_write:
		write_loaded_section_cell_state(cell, restored_state)
	if cell_state_affects_terrain_mesh(previous):
		mark_section_dirty(section_key_for_cell(cell), { "reason": reason, "cell": cell })
	if terrain_edit_updates_sky_light(previous):
		rebuild_sky_light_column(cell.x, cell.z, reason)

func set_cell_light(cell: Vector3i, light: Dictionary, reason := "") -> Dictionary:
	var state := get_cell_state(cell)
	var normalized_light := normalize_light(light, bool(state.get("solid", false)))
	var previous_level := int(block_light_sources.get(cell, 0))
	var new_level := int(normalized_light.get("block", 0))
	if new_level > 0:
		block_light_sources[cell] = mini(MAX_BLOCK_LIGHT_LEVEL, new_level)
	else:
		block_light_sources.erase(cell)
	revision += 1
	var radius := maxi(previous_level, new_level)
	radius = maxi(1, mini(MAX_BLOCK_LIGHT_LEVEL, radius))
	rebuild_block_light_neighborhood(cell, radius, reason)
	return get_cell_state(cell)

func begin_cell_light_update(cell: Vector3i, light: Dictionary, reason := "", rebuild_radius := -1) -> Dictionary:
	var previous_level := int(block_light_sources.get(cell, 0))
	var new_level := clampi(int(light.get("block", 0)), 0, MAX_BLOCK_LIGHT_LEVEL)
	if new_level > 0:
		block_light_sources[cell] = new_level
	else:
		block_light_sources.erase(cell)
	revision += 1
	var source_radius := maxi(previous_level, new_level)
	var occlusion_radius := clampi(int(rebuild_radius), 0, MAX_BLOCK_LIGHT_LEVEL) if rebuild_radius >= 0 else 0
	var radius := maxi(1, mini(MAX_BLOCK_LIGHT_LEVEL, maxi(source_radius, occlusion_radius)))
	var clear_distance := maxi(1, source_radius)
	if occlusion_radius > 0:
		clear_distance = maxi(clear_distance, occlusion_radius + MAX_BLOCK_LIGHT_LEVEL)
	var additive_update := new_level > 0 and new_level >= previous_level and occlusion_radius <= 0
	var min_section := section_key_for_cell(cell - Vector3i.ONE * clear_distance)
	var max_section := section_key_for_cell(cell + Vector3i.ONE * clear_distance)
	var section_keys: Array[Vector3i] = []
	for section_x in range(min_section.x, max_section.x + 1):
		for section_y in range(min_section.y, max_section.y + 1):
			for section_z in range(min_section.z, max_section.z + 1):
				var section_key := Vector3i(section_x, section_y, section_z)
				if light_cells_by_section.has(section_key):
					section_keys.append(section_key)
	return {
		"cell": cell,
		"reason": reason,
		"previousLevel": previous_level,
		"newLevel": new_level,
		"radius": radius,
		"sourceRadius": source_radius,
		"occlusionRadius": occlusion_radius,
		"clearDistance": clear_distance,
		"sectionKeys": section_keys,
		"sectionIndex": 0,
		"sectionCells": [],
		"sectionCellIndex": 0,
		"sourceCells": [],
		"sourceIndex": 0,
		"affectedSources": [cell] if additive_update else [],
		"propagation": {},
		"propagationInitialized": false,
		"phase": "propagate" if additive_update else "clear",
		"dirtySections": {},
		"clearedCount": 0,
		"lightWriteCount": 0,
		"complete": false
	}

func advance_cell_light_update(state_value, frame_budget_ms := 0.5, max_work_units := 96) -> Dictionary:
	var state: Dictionary = state_value if state_value is Dictionary else {}
	if state.is_empty() or bool(state.get("complete", false)):
		return { "state": state, "complete": true, "processedWorkUnits": 0, "elapsedMs": 0.0 }
	var started_usec := Time.get_ticks_usec()
	var budget_usec := 0 if frame_budget_ms <= 0.0 else maxi(1, roundi(frame_budget_ms * 1000.0))
	var work_limit := maxi(1, max_work_units)
	var processed_work_units := 0
	while processed_work_units < work_limit:
		if budget_usec > 0 and Time.get_ticks_usec() - started_usec >= budget_usec:
			break
		var phase := String(state.get("phase", "clear"))
		if phase == "clear":
			var section_cells_value: Variant = state.get("sectionCells", [])
			var section_cells: Array = section_cells_value if section_cells_value is Array else []
			var section_cell_index := int(state.get("sectionCellIndex", 0))
			if section_cell_index < section_cells.size():
				var light_cell_value: Variant = section_cells[section_cell_index]
				state["sectionCellIndex"] = section_cell_index + 1
				if light_cell_value is Vector3i:
					var light_cell: Vector3i = light_cell_value
					var center: Vector3i = state.get("cell", Vector3i.ZERO)
					if manhattan_distance(light_cell, center) <= int(state.get("clearDistance", MAX_BLOCK_LIGHT_LEVEL + 1)) and light_cells.has(light_cell):
						erase_light_cell(light_cell)
						write_loaded_section_cell_light(light_cell, base_light_for_cell(light_cell))
						record_block_light_batch_dirty_section(state, light_cell)
						state["clearedCount"] = int(state.get("clearedCount", 0)) + 1
						state["lightWriteCount"] = int(state.get("lightWriteCount", 0)) + 1
				processed_work_units += 1
				continue
			var section_keys_value: Variant = state.get("sectionKeys", [])
			var section_keys: Array = section_keys_value if section_keys_value is Array else []
			var section_index := int(state.get("sectionIndex", 0))
			if section_index < section_keys.size():
				var section_key_value: Variant = section_keys[section_index]
				state["sectionIndex"] = section_index + 1
				var next_cells: Array = []
				if section_key_value is Vector3i:
					var bucket_value: Variant = light_cells_by_section.get(section_key_value, {})
					if bucket_value is Dictionary:
						next_cells = (bucket_value as Dictionary).keys()
				state["sectionCells"] = next_cells
				state["sectionCellIndex"] = 0
				processed_work_units += 1
				continue
			state["sourceCells"] = block_light_sources.keys()
			state["sourceIndex"] = 0
			state["sectionCells"] = []
			state["phase"] = "sources"
			continue
		if phase == "sources":
			var source_cells_value: Variant = state.get("sourceCells", [])
			var source_cells: Array = source_cells_value if source_cells_value is Array else []
			var source_index := int(state.get("sourceIndex", 0))
			if source_index < source_cells.size():
				var source_cell_value: Variant = source_cells[source_index]
				state["sourceIndex"] = source_index + 1
				if source_cell_value is Vector3i:
					var source_cell: Vector3i = source_cell_value
					var source_level := int(block_light_sources.get(source_cell, 0))
					var center: Vector3i = state.get("cell", Vector3i.ZERO)
					if source_level > 0 and manhattan_distance(source_cell, center) <= int(state.get("clearDistance", MAX_BLOCK_LIGHT_LEVEL + 1)) + source_level:
						var affected_value: Variant = state.get("affectedSources", [])
						var affected_sources: Array = affected_value if affected_value is Array else []
						affected_sources.append(source_cell)
						state["affectedSources"] = affected_sources
				processed_work_units += 1
				continue
			state["phase"] = "propagate"
			continue
		if phase == "propagate":
			var propagation_value: Variant = state.get("propagation", {})
			var propagation: Dictionary = propagation_value if propagation_value is Dictionary else {}
			if not bool(state.get("propagationInitialized", false)):
				var affected_value: Variant = state.get("affectedSources", [])
				var affected_sources: Array = affected_value if affected_value is Array else []
				propagation = begin_all_block_light_propagation(affected_sources)
				state["propagation"] = propagation
				state["propagationInitialized"] = true
			var dirty_value: Variant = state.get("dirtySections", {})
			var dirty_sections: Dictionary = dirty_value if dirty_value is Dictionary else {}
			var propagation_result := advance_block_light_propagation(propagation, String(state.get("reason", "")), dirty_sections)
			state["propagation"] = propagation_result.get("state", propagation)
			state["dirtySections"] = dirty_sections
			processed_work_units += maxi(1, int(propagation_result.get("processedWorkUnits", 0)))
			if bool(propagation_result.get("complete", false)):
				flush_block_light_batch_dirty_sections(state)
				state["complete"] = true
				state["phase"] = "complete"
				break
			continue
		state["complete"] = true
		break
	return {
		"state": state,
		"complete": bool(state.get("complete", false)),
		"processedWorkUnits": processed_work_units,
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
	}

func set_cell_lights_batch(changes: Array, reason := "") -> Dictionary:
	var state := begin_cell_lights_batch(changes, reason)
	while not bool(state.get("complete", false)):
		var advanced: Dictionary = advance_cell_lights_batch(state, -1.0, 1000000)
		state = advanced.get("state", state)
	return cell_lights_batch_summary(state)

func begin_cell_lights_batch(changes: Array, reason := "") -> Dictionary:
	var changed_count := 0
	for change_value in changes:
		if not (change_value is Dictionary):
			continue
		var change: Dictionary = change_value
		var cell_value: Variant = change.get("cell", Vector3i.ZERO)
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		var light_value: Variant = change.get("light", {})
		var light: Dictionary = light_value if light_value is Dictionary else {}
		var state := get_cell_state(cell)
		var normalized_light := normalize_light(light, bool(state.get("solid", false)))
		var new_level := int(normalized_light.get("block", 0))
		if new_level > 0:
			block_light_sources[cell] = mini(MAX_BLOCK_LIGHT_LEVEL, new_level)
		else:
			block_light_sources.erase(cell)
		revision += 1
		changed_count += 1
	var clear_cells: Array[Vector3i] = []
	var source_cells: Array[Vector3i] = []
	if changed_count > 0:
		for cell_value in light_cells.keys():
			if cell_value is Vector3i:
				clear_cells.append(cell_value)
		for cell_value in block_light_sources.keys():
			if cell_value is Vector3i:
				source_cells.append(cell_value)
		sort_light_cells(clear_cells)
		sort_light_cells(source_cells)
	return {
		"changedCount": changed_count,
		"sourceCount": block_light_sources.size(),
		"reason": reason,
		"clearCells": clear_cells,
		"clearIndex": 0,
		"sourceCells": source_cells,
		"sourceIndex": 0,
		"propagation": {},
		"propagationInitialized": false,
		"dirtySections": {},
		"lightWriteCount": 0,
		"clearedCount": 0,
		"propagatedSourceCount": 0,
		"complete": changed_count <= 0
	}

func advance_cell_lights_batch(state_value, frame_budget_ms := 2.0, max_work_units := 192) -> Dictionary:
	var state: Dictionary = state_value if state_value is Dictionary else {}
	if state.is_empty() or bool(state.get("complete", false)):
		return {
			"state": state,
			"complete": true,
			"processedWorkUnits": 0,
			"elapsedMs": 0.0
		}
	var started_usec := Time.get_ticks_usec()
	var processed_work_units := 0
	var work_limit := maxi(1, max_work_units)
	var budget_usec: int = 0 if frame_budget_ms <= 0.0 else maxi(1, roundi(frame_budget_ms * 1000.0))
	while processed_work_units < work_limit:
		if budget_usec > 0 and Time.get_ticks_usec() - started_usec >= budget_usec:
			break
		var clear_cells_value: Variant = state.get("clearCells", [])
		var clear_cells: Array = clear_cells_value if clear_cells_value is Array else []
		var clear_index := int(state.get("clearIndex", 0))
		if clear_index < clear_cells.size():
			var light_cell_value: Variant = clear_cells[clear_index]
			state["clearIndex"] = clear_index + 1
			if light_cell_value is Vector3i:
				var light_cell: Vector3i = light_cell_value
				erase_light_cell(light_cell)
				write_loaded_section_cell_light(light_cell, base_light_for_cell(light_cell))
				record_block_light_batch_dirty_section(state, light_cell)
				state["lightWriteCount"] = int(state.get("lightWriteCount", 0)) + 1
				state["clearedCount"] = int(state.get("clearedCount", 0)) + 1
			processed_work_units += 1
			continue
		var propagation_value: Variant = state.get("propagation", {})
		var propagation: Dictionary = propagation_value if propagation_value is Dictionary else {}
		if not bool(state.get("propagationInitialized", false)):
			var source_cells_value: Variant = state.get("sourceCells", [])
			var source_cells: Array = source_cells_value if source_cells_value is Array else []
			propagation = begin_all_block_light_propagation(source_cells)
			state["propagation"] = propagation
			state["propagationInitialized"] = true
			state["sourceIndex"] = source_cells.size()
		var dirty_sections_value: Variant = state.get("dirtySections", {})
		var dirty_sections: Dictionary = dirty_sections_value if dirty_sections_value is Dictionary else {}
		var propagation_result: Dictionary = advance_block_light_propagation(propagation, String(state.get("reason", "")), dirty_sections)
		state["propagation"] = propagation_result.get("state", propagation)
		state["dirtySections"] = dirty_sections
		processed_work_units += int(propagation_result.get("processedWorkUnits", 0))
		if bool(propagation_result.get("complete", false)):
			var source_count := int(state.get("sourceCount", 0))
			state["propagatedSourceCount"] = source_count
			flush_block_light_batch_dirty_sections(state)
			state["complete"] = true
			break
	return {
		"state": state,
		"complete": bool(state.get("complete", false)),
		"processedWorkUnits": processed_work_units,
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
	}

func begin_all_block_light_propagation(source_cells: Array) -> Dictionary:
	var buckets: Array = []
	for _level in range(MAX_BLOCK_LIGHT_LEVEL + 1):
		buckets.append([])
	var levels := {}
	var source_set := {}
	for source_cell_value in source_cells:
		if not (source_cell_value is Vector3i):
			continue
		var source_cell: Vector3i = source_cell_value
		var source_level := int(block_light_sources.get(source_cell, 0))
		if source_level <= 0:
			continue
		source_set[source_cell] = true
		if source_level <= int(levels.get(source_cell, 0)):
			continue
		levels[source_cell] = source_level
		var bucket_value: Variant = buckets[source_level]
		var bucket: Array = bucket_value if bucket_value is Array else []
		bucket.append({ "cell": source_cell, "level": source_level })
		buckets[source_level] = bucket
	return {
		"buckets": buckets,
		"levels": levels,
		"sourceCells": source_set
	}

func advance_block_light_propagation(propagation_value, reason := "", dirty_sections: Dictionary = {}) -> Dictionary:
	var propagation: Dictionary = propagation_value if propagation_value is Dictionary else {}
	var buckets_value: Variant = propagation.get("buckets", [])
	var buckets: Array = buckets_value if buckets_value is Array else []
	var levels_value: Variant = propagation.get("levels", {})
	var levels: Dictionary = levels_value if levels_value is Dictionary else {}
	var source_cells_value: Variant = propagation.get("sourceCells", {})
	var source_cells: Dictionary = source_cells_value if source_cells_value is Dictionary else {}
	var bucket_level := highest_pending_block_light_level(buckets)
	if bucket_level <= 0:
		return { "state": propagation, "complete": true, "processedWorkUnits": 0 }
	var bucket_value: Variant = buckets[bucket_level]
	var bucket: Array = bucket_value if bucket_value is Array else []
	var entry_value: Variant = bucket.pop_back()
	buckets[bucket_level] = bucket
	if not (entry_value is Dictionary):
		propagation["buckets"] = buckets
		return { "state": propagation, "complete": highest_pending_block_light_level(buckets) <= 0, "processedWorkUnits": 1 }
	var entry: Dictionary = entry_value
	var cell_value: Variant = entry.get("cell", Vector3i.ZERO)
	var cell_level := int(entry.get("level", 0))
	if not (cell_value is Vector3i) or cell_level <= 0:
		propagation["buckets"] = buckets
		return { "state": propagation, "complete": highest_pending_block_light_level(buckets) <= 0, "processedWorkUnits": 1 }
	var cell: Vector3i = cell_value
	if cell_level != int(levels.get(cell, 0)):
		propagation["buckets"] = buckets
		return { "state": propagation, "complete": highest_pending_block_light_level(buckets) <= 0, "processedWorkUnits": 1 }
	var cell_state := get_cell_state(cell)
	var solid := bool(cell_state.get("solid", false))
	if not (solid and not source_cells.has(cell)):
		var current_light := base_light_for_cell(cell)
		if light_cells.has(cell):
			current_light = (light_cells[cell] as Dictionary).duplicate(true)
		if cell_level > int(current_light.get("block", 0)):
			current_light["block"] = cell_level
			store_light_cell(cell, current_light)
			write_loaded_section_cell_light(cell, current_light)
			record_block_light_batch_dirty_section_lookup(dirty_sections, cell)
		if cell_level > 1:
			var next_level := cell_level - 1
			for direction in cardinal_directions():
				var next_cell := cell + direction
				if next_level <= int(levels.get(next_cell, 0)):
					continue
				var next_state := get_cell_state(next_cell)
				if bool(next_state.get("solid", false)) and not source_cells.has(next_cell):
					continue
				levels[next_cell] = next_level
				var next_bucket_value: Variant = buckets[next_level]
				var next_bucket: Array = next_bucket_value if next_bucket_value is Array else []
				next_bucket.append({ "cell": next_cell, "level": next_level })
				buckets[next_level] = next_bucket
	propagation["buckets"] = buckets
	propagation["levels"] = levels
	return {
		"state": propagation,
		"complete": highest_pending_block_light_level(buckets) <= 0,
		"processedWorkUnits": 1
	}

func highest_pending_block_light_level(buckets: Array) -> int:
	for level in range(MAX_BLOCK_LIGHT_LEVEL, 0, -1):
		if level >= buckets.size():
			continue
		var bucket_value: Variant = buckets[level]
		if bucket_value is Array and not (bucket_value as Array).is_empty():
			return level
	return 0

func record_block_light_batch_dirty_section(state: Dictionary, cell: Vector3i) -> void:
	var dirty_value: Variant = state.get("dirtySections", {})
	var dirty_sections: Dictionary = dirty_value if dirty_value is Dictionary else {}
	record_block_light_batch_dirty_section_lookup(dirty_sections, cell)
	state["dirtySections"] = dirty_sections

func record_block_light_batch_dirty_section_lookup(dirty_sections: Dictionary, cell: Vector3i) -> void:
	var section_key := section_key_for_cell(cell)
	dirty_sections[section_key] = int(dirty_sections.get(section_key, 0)) + 1

func store_light_cell(cell: Vector3i, light: Dictionary) -> void:
	light_cells[cell] = light
	var section_key := section_key_for_cell(cell)
	var bucket: Dictionary = light_cells_by_section.get(section_key, {}) if light_cells_by_section.get(section_key, {}) is Dictionary else {}
	bucket[cell] = true
	light_cells_by_section[section_key] = bucket

func erase_light_cell(cell: Vector3i) -> void:
	light_cells.erase(cell)
	var section_key := section_key_for_cell(cell)
	if not light_cells_by_section.has(section_key):
		return
	var bucket: Dictionary = light_cells_by_section.get(section_key, {}) if light_cells_by_section.get(section_key, {}) is Dictionary else {}
	bucket.erase(cell)
	if bucket.is_empty():
		light_cells_by_section.erase(section_key)
	else:
		light_cells_by_section[section_key] = bucket

func flush_block_light_batch_dirty_sections(state: Dictionary) -> void:
	var dirty_value: Variant = state.get("dirtySections", {})
	var dirty_sections: Dictionary = dirty_value if dirty_value is Dictionary else {}
	var reason := String(state.get("reason", ""))
	for section_value in dirty_sections.keys():
		if not (section_value is Vector3i):
			continue
		var section_key: Vector3i = section_value
		mark_section_dirty(section_key, {
			"reason": reason,
			"lightOnly": true,
			"batched": true,
			"cellCount": int(dirty_sections.get(section_key, 0))
		})
	state["dirtySectionCount"] = dirty_sections.size()
	state["dirtySections"] = {}

func cell_lights_batch_summary(state_value) -> Dictionary:
	var state: Dictionary = state_value if state_value is Dictionary else {}
	return {
		"changedCount": int(state.get("changedCount", 0)),
		"sourceCount": int(state.get("sourceCount", block_light_sources.size())),
		"clearedCount": int(state.get("clearedCount", 0)),
		"propagatedSourceCount": int(state.get("propagatedSourceCount", 0)),
		"dirtySectionCount": int(state.get("dirtySectionCount", 0)),
		"lightWriteCount": int(state.get("lightWriteCount", 0)),
		"complete": bool(state.get("complete", false))
	}

func light_at_cell(cell: Vector3i) -> Dictionary:
	var state := get_cell_state(cell)
	return normalize_light(state.get("light", {}), bool(state.get("solid", false)))

func with_light_override(cell: Vector3i, state: Dictionary) -> Dictionary:
	if light_cells.has(cell):
		state["light"] = (light_cells[cell] as Dictionary).duplicate(true)
	return state

func base_light_for_cell(cell: Vector3i) -> Dictionary:
	var state := {}
	if scene_block_cells.has(cell):
		state = (scene_block_cells[cell] as Dictionary).duplicate(true)
	elif edited_cells.has(cell):
		state = (edited_cells[cell] as Dictionary).duplicate(true)
	else:
		state = generated_cell_state(cell)
	return normalize_light(state.get("light", {}), bool(state.get("solid", false)))

func rebuild_block_light_neighborhood(center_cell: Vector3i, radius: int, reason := "") -> void:
	var clamped_radius := maxi(1, mini(MAX_BLOCK_LIGHT_LEVEL, radius))
	var cleared_cells: Array[Vector3i] = []
	for cell_value in light_cells.keys():
		var light_cell: Vector3i = cell_value
		if manhattan_distance(light_cell, center_cell) <= clamped_radius + MAX_BLOCK_LIGHT_LEVEL:
			cleared_cells.append(light_cell)
	for light_cell in cleared_cells:
		erase_light_cell(light_cell)
		write_loaded_section_cell_light(light_cell, base_light_for_cell(light_cell))
		mark_section_dirty(section_key_for_cell(light_cell), { "reason": reason, "cell": light_cell, "lightOnly": true })
	for source_value in block_light_sources.keys():
		var source_cell: Vector3i = source_value
		var source_level := int(block_light_sources[source_cell])
		if source_level <= 0:
			continue
		if manhattan_distance(source_cell, center_cell) > clamped_radius + source_level:
			continue
		propagate_block_light_from_source(source_cell, source_level, reason)

func rebuild_all_block_light_sources(reason := "") -> void:
	var cleared_cells: Array[Vector3i] = []
	for cell_value in light_cells.keys():
		if cell_value is Vector3i:
			cleared_cells.append(cell_value)
	sort_light_cells(cleared_cells)
	for light_cell in cleared_cells:
		erase_light_cell(light_cell)
		write_loaded_section_cell_light(light_cell, base_light_for_cell(light_cell))
		mark_section_dirty(section_key_for_cell(light_cell), { "reason": reason, "cell": light_cell, "lightOnly": true })
	var source_cells: Array[Vector3i] = []
	for cell_value in block_light_sources.keys():
		if cell_value is Vector3i:
			source_cells.append(cell_value)
	sort_light_cells(source_cells)
	for source_cell in source_cells:
		var source_level := int(block_light_sources.get(source_cell, 0))
		if source_level > 0:
			propagate_block_light_from_source(source_cell, source_level, reason)

func sort_light_cells(cells: Array[Vector3i]) -> void:
	cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		if a.y != b.y:
			return a.y < b.y
		return a.z < b.z
	)

func propagate_block_light_from_source(source_cell: Vector3i, source_level: int, reason := "") -> void:
	var level := mini(MAX_BLOCK_LIGHT_LEVEL, maxi(0, source_level))
	if level <= 0:
		return
	var queue: Array[Vector3i] = [source_cell]
	var levels := { source_cell: level }
	var read_index := 0
	while read_index < queue.size():
		var cell: Vector3i = queue[read_index]
		read_index += 1
		var cell_level := int(levels[cell])
		var state := get_cell_state(cell)
		var solid := bool(state.get("solid", false))
		if solid and cell != source_cell:
			continue
		var current_light := base_light_for_cell(cell)
		if light_cells.has(cell):
			current_light = (light_cells[cell] as Dictionary).duplicate(true)
		if cell_level > int(current_light.get("block", 0)):
			current_light["block"] = cell_level
			store_light_cell(cell, current_light)
			write_loaded_section_cell_light(cell, current_light)
			mark_section_dirty(section_key_for_cell(cell), { "reason": reason, "cell": cell, "lightOnly": true })
		if cell_level <= 1:
			continue
		for direction in cardinal_directions():
			var next_cell := cell + direction
			if levels.has(next_cell) and int(levels[next_cell]) >= cell_level - 1:
				continue
			var next_state := get_cell_state(next_cell)
			if bool(next_state.get("solid", false)) and next_cell != source_cell:
				continue
			levels[next_cell] = cell_level - 1
			queue.append(next_cell)

func manhattan_distance(a: Vector3i, b: Vector3i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y) + absi(a.z - b.z)

func apply_sphere_edit(center: Vector3, radius: float, state: Dictionary, reason := "") -> Array[Vector3i]:
	var changed: Array[Vector3i] = []
	if radius <= 0.0:
		return changed
	var s := cell_size()
	var target_solid := bool(state.get("solid", false))
	var state_metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	var defer_sky_light := bool(state_metadata.get("deferSkyLight", false))
	var shell_radius := radius if target_solid else radius + s * 1.15
	var min_cell := Vector3i(floori((center.x - shell_radius) / s), floori((center.y - shell_radius) / s), floori((center.z - shell_radius) / s))
	var max_cell := Vector3i(ceili((center.x + shell_radius) / s), ceili((center.y + shell_radius) / s), ceili((center.z + shell_radius) / s))
	var radius_sq := radius * radius
	var shell_radius_sq := shell_radius * shell_radius
	var skylight_columns := {}
	for z in range(min_cell.z, max_cell.z + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				var cell_center := Vector3((float(x) + 0.5) * s, (float(y) + 0.5) * s, (float(z) + 0.5) * s)
				var distance_sq := cell_center.distance_squared_to(center)
				if distance_sq > shell_radius_sq:
					continue
				var distance := sqrt(distance_sq)
				var edited_state := {}
				var previous_state: Dictionary = {}
				if edited_cells.has(cell):
					previous_state = edited_cells[cell]
				if distance_sq <= radius_sq or target_solid:
					edited_state = state.duplicate(true)
					edited_state["density"] = sphere_edit_density(distance, radius, target_solid)
				else:
					var existing := get_cell_state(cell)
					if not bool(existing.get("solid", false)):
						continue
					edited_state = existing.duplicate(true)
					edited_state["density"] = clampf(distance - radius, s * 0.05, s * 1.35)
					var metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
					metadata = metadata.duplicate(true)
					metadata["source"] = "excavation_boundary"
					if defer_sky_light:
						metadata["deferSkyLight"] = true
					edited_state["metadata"] = metadata
				if terrain_edit_updates_sky_light(edited_state) or terrain_edit_updates_sky_light(previous_state):
					skylight_columns[Vector2i(cell.x, cell.z)] = true
				set_cell_state(cell, edited_state, reason, false)
				changed.append(cell)
	if defer_sky_light:
		queue_sky_light_columns(skylight_columns, reason)
	else:
		for column_value in skylight_columns.keys():
			var column: Vector2i = column_value
			rebuild_sky_light_column(column.x, column.y, reason)
	return changed

func apply_surface_deformation_edit(center: Vector3, radius: float, drop_depth: float, state: Dictionary, reason := "") -> Array[Vector3i]:
	var changed: Array[Vector3i] = []
	var s := cell_size()
	var safe_radius := maxf(radius, s * 0.75)
	var safe_drop := maxf(drop_depth, s * 0.35)
	var min_cell_x := floori((center.x - safe_radius) / s) - 1
	var max_cell_x := ceili((center.x + safe_radius) / s) + 1
	var min_cell_z := floori((center.z - safe_radius) / s) - 1
	var max_cell_z := ceili((center.z + safe_radius) / s) + 1
	var column_targets := {}
	var skylight_columns := {}
	for z in range(min_cell_z, max_cell_z + 1):
		for x in range(min_cell_x, max_cell_x + 1):
			var column_center := Vector2((float(x) + 0.5) * s, (float(z) + 0.5) * s)
			var horizontal_distance := column_center.distance_to(Vector2(center.x, center.z))
			if horizontal_distance > safe_radius:
				continue
			var t := clampf(horizontal_distance / safe_radius, 0.0, 1.0)
			var falloff := 1.0 - smoothstep01(t)
			if falloff <= 0.001:
				continue
			var column_cell := Vector3i(x, 0, z)
			var surface_y := current_surface_projection_y_for_column(column_cell)
			var surface_target_y := surface_y - safe_drop * falloff
			var impact_strength := clampf(falloff * 1.35, 0.0, 1.0)
			var impact_target_y: float = lerp(surface_y, center.y - safe_drop * 0.72, impact_strength)
			var target_y := minf(surface_target_y, impact_target_y)
			if target_y >= surface_y - s * 0.08:
				continue
			column_targets[column_cell] = {
				"surfaceY": surface_y,
				"targetY": target_y,
				"falloff": falloff
			}
	for column_value in column_targets.keys():
		var column: Vector3i = column_value
		var target: Dictionary = column_targets[column]
		var surface_y := float(target.get("surfaceY", 0.0))
		var target_y := float(target.get("targetY", surface_y))
		var high_y := ceili((surface_y + s * 0.60) / s)
		var low_y := floori((target_y - s * 0.85) / s)
		for y in range(high_y, low_y - 1, -1):
			var cell := Vector3i(column.x, y, column.z)
			var cell_center_y := (float(y) + 0.5) * s
			var existing := get_cell_state(cell)
			var edited_state := {}
			if cell_center_y > target_y and cell_center_y <= surface_y + s * 0.65:
				edited_state = state.duplicate(true)
				edited_state["density"] = clampf(target_y - cell_center_y, -s * 2.0, -s * 0.05)
				var air_metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
				air_metadata = air_metadata.duplicate(true)
				air_metadata["source"] = String(air_metadata.get("source", "player_dig"))
				air_metadata["terrainMeshAffects"] = true
				air_metadata["surfaceProjectionAffects"] = true
				air_metadata["saveDelta"] = true
				edited_state["metadata"] = air_metadata
			elif bool(existing.get("solid", false)) and cell_center_y <= target_y and cell_center_y >= target_y - s * 1.25:
				edited_state = existing.duplicate(true)
				edited_state["density"] = clampf(target_y - cell_center_y, s * 0.05, s * 1.35)
				var solid_metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
				solid_metadata = solid_metadata.duplicate(true)
				solid_metadata["source"] = "surface_excavation_boundary"
				solid_metadata["terrainMeshAffects"] = true
				solid_metadata["surfaceProjectionAffects"] = true
				solid_metadata["saveDelta"] = true
				edited_state["metadata"] = solid_metadata
			else:
				continue
			if terrain_edit_updates_sky_light(edited_state) or terrain_edit_updates_sky_light(existing):
				skylight_columns[Vector2i(cell.x, cell.z)] = true
			set_cell_state(cell, edited_state, reason, false)
			changed.append(cell)
	queue_sky_light_columns(skylight_columns, reason)
	return changed

func begin_sphere_edit_incremental(center: Vector3, radius: float, state: Dictionary, reason := "") -> Dictionary:
	var candidates: Array[Vector3i] = []
	if radius <= 0.0:
		return { "kind": "sphere", "complete": true, "changedCells": [], "removedMaterials": {} }
	var s := cell_size()
	var target_solid := bool(state.get("solid", false))
	var shell_radius := radius if target_solid else radius + s * 1.15
	var min_cell := Vector3i(floori((center.x - shell_radius) / s), floori((center.y - shell_radius) / s), floori((center.z - shell_radius) / s))
	var max_cell := Vector3i(ceili((center.x + shell_radius) / s), ceili((center.y + shell_radius) / s), ceili((center.z + shell_radius) / s))
	for z in range(min_cell.z, max_cell.z + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				candidates.append(Vector3i(x, y, z))
	return {
		"kind": "sphere",
		"complete": false,
		"center": center,
		"radius": radius,
		"radiusSq": radius * radius,
		"shellRadiusSq": shell_radius * shell_radius,
		"state": state.duplicate(true),
		"reason": reason,
		"targetSolid": target_solid,
		"deferSkyLight": terrain_edit_defer_sky_light(state),
		"candidates": candidates,
		"candidateIndex": 0,
		"changedCells": [],
		"removedMaterials": {},
		"skylightColumns": {}
	}

func begin_surface_deformation_edit_incremental(center: Vector3, radius: float, drop_depth: float, state: Dictionary, reason := "") -> Dictionary:
	var s := cell_size()
	var safe_radius := maxf(radius, s * 0.75)
	var columns: Array[Vector2i] = []
	var min_cell_x := floori((center.x - safe_radius) / s) - 1
	var max_cell_x := ceili((center.x + safe_radius) / s) + 1
	var min_cell_z := floori((center.z - safe_radius) / s) - 1
	var max_cell_z := ceili((center.z + safe_radius) / s) + 1
	for z in range(min_cell_z, max_cell_z + 1):
		for x in range(min_cell_x, max_cell_x + 1):
			columns.append(Vector2i(x, z))
	return {
		"kind": "surface_deformation",
		"phase": "plan_columns",
		"complete": false,
		"center": center,
		"safeRadius": safe_radius,
		"safeDrop": maxf(drop_depth, s * 0.35),
		"state": state.duplicate(true),
		"reason": reason,
		"columns": columns,
		"columnIndex": 0,
		"columnTargets": [],
		"targetIndex": 0,
		"activeColumn": {},
		"changedCells": [],
		"removedMaterials": {},
		"skylightColumns": {}
	}

func advance_incremental_edit(job: Dictionary, frame_budget_ms := 0.35, max_work_units := 8) -> Dictionary:
	if bool(job.get("complete", false)):
		return { "state": job, "complete": true, "processedWorkUnits": 0 }
	var started_usec := Time.get_ticks_usec()
	var budget_usec := 0 if frame_budget_ms <= 0.0 else maxi(1, roundi(frame_budget_ms * 1000.0))
	var processed := 0
	var work_limit := maxi(1, max_work_units)
	while processed < work_limit and (budget_usec <= 0 or Time.get_ticks_usec() - started_usec < budget_usec):
		if String(job.get("kind", "")) == "surface_deformation":
			advance_surface_deformation_edit_unit(job)
		else:
			advance_sphere_edit_unit(job)
		processed += 1
		if bool(job.get("complete", false)):
			break
	return {
		"state": job,
		"complete": bool(job.get("complete", false)),
		"processedWorkUnits": processed,
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
	}

func advance_sphere_edit_unit(job: Dictionary) -> void:
	var candidates_value: Variant = job.get("candidates", [])
	var candidates: Array = candidates_value if candidates_value is Array else []
	var index := int(job.get("candidateIndex", 0))
	if index >= candidates.size():
		finish_incremental_edit(job)
		return
	job["candidateIndex"] = index + 1
	var cell_value: Variant = candidates[index]
	if not (cell_value is Vector3i):
		return
	var cell: Vector3i = cell_value
	var s := cell_size()
	var center: Vector3 = job.get("center", Vector3.ZERO)
	var cell_center := Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s)
	var distance_sq := cell_center.distance_squared_to(center)
	if distance_sq > float(job.get("shellRadiusSq", 0.0)):
		return
	var distance := sqrt(distance_sq)
	var radius := float(job.get("radius", 0.0))
	var target_solid := bool(job.get("targetSolid", false))
	var state_value: Variant = job.get("state", {})
	var state: Dictionary = state_value if state_value is Dictionary else {}
	var existing := get_cell_state(cell)
	var edited_state := {}
	if distance_sq <= float(job.get("radiusSq", 0.0)) or target_solid:
		edited_state = state.duplicate(true)
		edited_state["density"] = sphere_edit_density(distance, radius, target_solid)
	else:
		if not bool(existing.get("solid", false)):
			return
		edited_state = existing.duplicate(true)
		edited_state["density"] = clampf(distance - radius, s * 0.05, s * 1.35)
		var metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
		metadata = metadata.duplicate(true)
		metadata["source"] = "excavation_boundary"
		if bool(job.get("deferSkyLight", false)):
			metadata["deferSkyLight"] = true
		edited_state["metadata"] = metadata
	record_incremental_edit_change(job, cell, existing, edited_state)
	set_cell_state_with_previous(cell, edited_state, existing, String(job.get("reason", "")), false)

func advance_surface_deformation_edit_unit(job: Dictionary) -> void:
	var phase := String(job.get("phase", "plan_columns"))
	if phase == "plan_columns":
		var columns_value: Variant = job.get("columns", [])
		var columns: Array = columns_value if columns_value is Array else []
		var column_index := int(job.get("columnIndex", 0))
		if column_index >= columns.size():
			job["phase"] = "edit_columns"
			return
		job["columnIndex"] = column_index + 1
		var column_value: Variant = columns[column_index]
		if not (column_value is Vector2i):
			return
		var column: Vector2i = column_value
		var s := cell_size()
		var center: Vector3 = job.get("center", Vector3.ZERO)
		var safe_radius := float(job.get("safeRadius", s))
		var column_center := Vector2((float(column.x) + 0.5) * s, (float(column.y) + 0.5) * s)
		var horizontal_distance := column_center.distance_to(Vector2(center.x, center.z))
		if horizontal_distance > safe_radius:
			return
		var t := clampf(horizontal_distance / safe_radius, 0.0, 1.0)
		var falloff := 1.0 - smoothstep01(t)
		if falloff <= 0.001:
			return
		var surface_y := current_surface_projection_y_for_column(Vector3i(column.x, 0, column.y))
		var safe_drop := float(job.get("safeDrop", s * 0.35))
		var surface_target_y := surface_y - safe_drop * falloff
		var impact_strength := clampf(falloff * 1.35, 0.0, 1.0)
		var impact_target_y: float = lerp(surface_y, center.y - safe_drop * 0.72, impact_strength)
		var target_y := minf(surface_target_y, impact_target_y)
		if target_y >= surface_y - s * 0.08:
			return
		var targets_value: Variant = job.get("columnTargets", [])
		var targets: Array = targets_value if targets_value is Array else []
		targets.append({ "x": column.x, "z": column.y, "surfaceY": surface_y, "targetY": target_y })
		job["columnTargets"] = targets
		return
	if phase != "edit_columns":
		finish_incremental_edit(job)
		return
	var active_value: Variant = job.get("activeColumn", {})
	var active: Dictionary = active_value if active_value is Dictionary else {}
	if active.is_empty():
		var targets_value: Variant = job.get("columnTargets", [])
		var targets: Array = targets_value if targets_value is Array else []
		var target_index := int(job.get("targetIndex", 0))
		if target_index >= targets.size():
			finish_incremental_edit(job)
			return
		var target_value: Variant = targets[target_index]
		job["targetIndex"] = target_index + 1
		if not (target_value is Dictionary):
			return
		active = (target_value as Dictionary).duplicate(true)
		var s := cell_size()
		active["nextY"] = ceili((float(active.get("surfaceY", 0.0)) + s * 0.60) / s)
		active["lowY"] = floori((float(active.get("targetY", 0.0)) - s * 0.85) / s)
		job["activeColumn"] = active
		return
	var next_y := int(active.get("nextY", 0))
	var low_y := int(active.get("lowY", 0))
	if next_y < low_y:
		job["activeColumn"] = {}
		return
	active["nextY"] = next_y - 1
	job["activeColumn"] = active
	var cell := Vector3i(int(active.get("x", 0)), next_y, int(active.get("z", 0)))
	var s := cell_size()
	var cell_center_y := (float(next_y) + 0.5) * s
	var surface_y := float(active.get("surfaceY", 0.0))
	var target_y := float(active.get("targetY", surface_y))
	var existing := get_cell_state(cell)
	var state_value: Variant = job.get("state", {})
	var state: Dictionary = state_value if state_value is Dictionary else {}
	var edited_state := {}
	if cell_center_y > target_y and cell_center_y <= surface_y + s * 0.65:
		edited_state = state.duplicate(true)
		edited_state["density"] = clampf(target_y - cell_center_y, -s * 2.0, -s * 0.05)
		var air_metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
		air_metadata = air_metadata.duplicate(true)
		air_metadata["source"] = String(air_metadata.get("source", "player_dig"))
		air_metadata["terrainMeshAffects"] = true
		air_metadata["surfaceProjectionAffects"] = true
		air_metadata["saveDelta"] = true
		edited_state["metadata"] = air_metadata
	elif bool(existing.get("solid", false)) and cell_center_y <= target_y and cell_center_y >= target_y - s * 1.25:
		edited_state = existing.duplicate(true)
		edited_state["density"] = clampf(target_y - cell_center_y, s * 0.05, s * 1.35)
		var solid_metadata: Dictionary = edited_state.get("metadata", {}) if edited_state.get("metadata", {}) is Dictionary else {}
		solid_metadata = solid_metadata.duplicate(true)
		solid_metadata["source"] = "surface_excavation_boundary"
		solid_metadata["terrainMeshAffects"] = true
		solid_metadata["surfaceProjectionAffects"] = true
		solid_metadata["saveDelta"] = true
		edited_state["metadata"] = solid_metadata
	else:
		return
	record_incremental_edit_change(job, cell, existing, edited_state)
	set_cell_state_with_previous(cell, edited_state, existing, String(job.get("reason", "")), false)

func record_incremental_edit_change(job: Dictionary, cell: Vector3i, existing: Dictionary, edited_state: Dictionary) -> void:
	var changed_value: Variant = job.get("changedCells", [])
	var changed: Array = changed_value if changed_value is Array else []
	changed.append(cell)
	job["changedCells"] = changed
	if bool(existing.get("solid", false)) and not bool(edited_state.get("solid", false)):
		var material_id := String(existing.get("material", ""))
		if material_id != "" and material_id != "air":
			var removed_value: Variant = job.get("removedMaterials", {})
			var removed: Dictionary = removed_value if removed_value is Dictionary else {}
			removed[material_id] = int(removed.get(material_id, 0)) + 1
			job["removedMaterials"] = removed
	if terrain_edit_updates_sky_light(edited_state) or terrain_edit_updates_sky_light(existing):
		var columns_value: Variant = job.get("skylightColumns", {})
		var columns: Dictionary = columns_value if columns_value is Dictionary else {}
		columns[Vector2i(cell.x, cell.z)] = true
		job["skylightColumns"] = columns

func finish_incremental_edit(job: Dictionary) -> void:
	if bool(job.get("finalized", false)):
		job["complete"] = true
		return
	var columns_value: Variant = job.get("skylightColumns", {})
	var columns: Dictionary = columns_value if columns_value is Dictionary else {}
	queue_sky_light_columns(columns, String(job.get("reason", "")))
	job["finalized"] = true
	job["complete"] = true

func terrain_edit_defer_sky_light(state: Dictionary) -> bool:
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	return bool(metadata.get("deferSkyLight", false))

func current_surface_projection_y_for_column(cell: Vector3i) -> float:
	var generation = active_generator()
	if generation != null and generation.has_method("volume_surface_y_for_cell"):
		return float(generation.call("volume_surface_y_for_cell", Vector3i(cell.x, 0, cell.z)))
	if generation != null and generation.has_method("surface_y_for_cell"):
		return float(generation.call("surface_y_for_cell", Vector3i(cell.x, 0, cell.z)))
	return surface_y_for_cell(Vector3i(cell.x, 0, cell.z))

func smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func queue_sky_light_columns(columns: Dictionary, reason := "") -> void:
	for column_value in columns.keys():
		if column_value is Vector2i:
			pending_sky_light_columns[column_value] = String(reason)

func process_pending_sky_light_columns(max_columns := SKY_LIGHT_COLUMNS_PER_PROCESS) -> int:
	var processed := 0
	var limit := maxi(1, int(max_columns))
	for column_value in pending_sky_light_columns.keys():
		if processed >= limit:
			break
		if not (column_value is Vector2i):
			pending_sky_light_columns.erase(column_value)
			continue
		var column: Vector2i = column_value
		var reason := String(pending_sky_light_columns.get(column, "deferred_sky_light"))
		pending_sky_light_columns.erase(column)
		rebuild_sky_light_column(column.x, column.y, reason)
		processed += 1
	return processed

func pending_sky_light_column_count() -> int:
	return pending_sky_light_columns.size()

func apply_box_edit(min_cell: Vector3i, max_cell: Vector3i, state: Dictionary, reason := "") -> Array[Vector3i]:
	var changed: Array[Vector3i] = []
	var from_cell := Vector3i(
		mini(min_cell.x, max_cell.x),
		mini(min_cell.y, max_cell.y),
		mini(min_cell.z, max_cell.z)
	)
	var to_cell := Vector3i(
		maxi(min_cell.x, max_cell.x),
		maxi(min_cell.y, max_cell.y),
		maxi(min_cell.z, max_cell.z)
	)
	var dirty_lookup := {}
	var skylight_columns := {}
	revision += 1
	for z in range(from_cell.z, to_cell.z + 1):
		for y in range(from_cell.y, to_cell.y + 1):
			for x in range(from_cell.x, to_cell.x + 1):
				var cell := Vector3i(x, y, z)
				var previous_state := {}
				var previous_mesh_affects := false
				var previous_surface_affects := false
				if edited_cells.has(cell):
					previous_state = edited_cells[cell]
					previous_mesh_affects = cell_state_affects_terrain_mesh(previous_state)
					previous_surface_affects = cell_state_affects_surface_projection(previous_state)
				var normalized := normalize_cell_state(cell, state, true)
				normalized["editReason"] = String(reason)
				if previous_mesh_affects:
					adjust_mesh_edited_column_count(cell, -1)
					set_mesh_edited_cell_index(cell, false)
				if previous_surface_affects:
					adjust_surface_projection_edited_column_count(cell, -1)
				edited_cells[cell] = normalized
				_update_durable_delta_cell(cell,normalized)
				write_loaded_section_cell_state(cell, normalized)
				if previous_mesh_affects or cell_state_affects_terrain_mesh(normalized):
					dirty_lookup[section_key_for_cell(cell)] = true
				if cell_state_affects_terrain_mesh(normalized):
					adjust_mesh_edited_column_count(cell, 1)
					set_mesh_edited_cell_index(cell, true)
				if cell_state_affects_surface_projection(normalized):
					adjust_surface_projection_edited_column_count(cell, 1)
				if terrain_edit_updates_sky_light(normalized) or terrain_edit_updates_sky_light(previous_state):
					skylight_columns[Vector2i(cell.x, cell.z)] = true
				changed.append(cell)
	for section_value in dirty_lookup.keys():
		mark_section_dirty(section_value, { "reason": reason, "boxMin": from_cell, "boxMax": to_cell })
	for column_value in skylight_columns.keys():
		var column: Vector2i = column_value
		rebuild_sky_light_column(column.x, column.y, reason)
	return changed

func terrain_edit_updates_sky_light(state_value) -> bool:
	if not cell_state_affects_terrain_mesh(state_value):
		return false
	var state: Dictionary = state_value if state_value is Dictionary else {}
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	var source := String(metadata.get("source", ""))
	if source.begins_with("structure_"):
		return false
	if bool(metadata.get("renderedBySceneBlock", false)):
		return false
	return true

func rebuild_sky_light_column(cell_x: int, cell_z: int, reason := "") -> void:
	var open_to_sky := true
	for y in range(world_top_cell_y(), world_bottom_cell_y() - 1, -1):
		var cell := Vector3i(cell_x, y, cell_z)
		var state := get_cell_state(cell)
		var solid := bool(state.get("solid", false))
		var existing_light: Dictionary = state.get("light", {}) if state.get("light", {}) is Dictionary else {}
		var next_sky := 15 if open_to_sky and not solid else 0
		var next_light := {
			"sky": next_sky,
			"block": int(existing_light.get("block", 0))
		}
		if int(existing_light.get("sky", 0)) != next_sky:
			store_light_cell(cell, next_light)
			write_loaded_section_cell_light(cell, next_light)
			mark_section_dirty(section_key_for_cell(cell), { "reason": reason, "cell": cell, "lightOnly": true, "skyColumn": true })
		if solid:
			open_to_sky = false

func adjust_mesh_edited_column_count(cell: Vector3i, delta: int) -> void:
	var key := Vector2i(cell.x, cell.z)
	var next_count := int(mesh_edited_column_counts.get(key, 0)) + int(delta)
	if next_count <= 0:
		mesh_edited_column_counts.erase(key)
	else:
		mesh_edited_column_counts[key] = next_count

func set_mesh_edited_cell_index(cell: Vector3i, enabled: bool) -> void:
	var section_key := section_key_for_cell(cell)
	if enabled:
		var bucket: Dictionary = mesh_edited_cells_by_section.get(section_key, {}) if mesh_edited_cells_by_section.get(section_key, {}) is Dictionary else {}
		bucket[cell] = true
		mesh_edited_cells_by_section[section_key] = bucket
		return
	if not mesh_edited_cells_by_section.has(section_key):
		return
	var existing: Dictionary = mesh_edited_cells_by_section.get(section_key, {}) if mesh_edited_cells_by_section.get(section_key, {}) is Dictionary else {}
	existing.erase(cell)
	if existing.is_empty():
		mesh_edited_cells_by_section.erase(section_key)
	else:
		mesh_edited_cells_by_section[section_key] = existing

func column_has_mesh_affecting_edits(cell: Vector3i) -> bool:
	return int(mesh_edited_column_counts.get(Vector2i(cell.x, cell.z), 0)) > 0

func adjust_surface_projection_edited_column_count(cell: Vector3i, delta: int) -> void:
	var key := Vector2i(cell.x, cell.z)
	var next_count := int(surface_projection_edited_column_counts.get(key, 0)) + int(delta)
	if next_count <= 0:
		surface_projection_edited_column_counts.erase(key)
	else:
		surface_projection_edited_column_counts[key] = next_count

func column_has_surface_projection_affecting_edits(cell: Vector3i) -> bool:
	return int(surface_projection_edited_column_counts.get(Vector2i(cell.x, cell.z), 0)) > 0

func sphere_edit_density(distance: float, radius: float, solid_target: bool) -> float:
	var signed := radius - distance if solid_target else distance - radius
	return clampf(signed, -cell_size() * 2.0, cell_size() * 2.0)

func mark_section_dirty(section_key: Vector3i, flags := {}) -> void:
	var entry := {
		"sectionKey": section_key,
		"flags": flags.duplicate(true) if flags is Dictionary else {},
		"revision": revision
	}
	section_revisions[section_key] = revision
	update_section_column_revision(section_column_revisions, section_key, revision)
	dirty_sections[section_key] = entry
	var section_min := section_key * SECTION_SIZE
	var section_max := section_min + Vector3i.ONE * (SECTION_SIZE - 1)
	var changed_min := section_min
	var changed_max := section_max
	if flags is Dictionary:
		if flags.get("cell") is Vector3i:
			changed_min = flags.cell
			changed_max = flags.cell
		elif flags.get("boxMin") is Vector3i and flags.get("boxMax") is Vector3i:
			changed_min = flags.boxMin
			changed_max = flags.boxMax
	changed_min = Vector3i(maxi(changed_min.x, section_min.x),
		maxi(changed_min.y, section_min.y), maxi(changed_min.z, section_min.z))
	changed_max = Vector3i(mini(changed_max.x, section_max.x),
		mini(changed_max.y, section_max.y), mini(changed_max.z, section_max.z))
	terrain_section_revision_changed.emit(section_key, revision, changed_min, changed_max)

func save_section_delta(section_key: Vector3i) -> Dictionary:
	_refresh_durable_delta_section(section_key)
	if durable_delta_section_snapshots.has(section_key):
		return durable_delta_section_snapshots[section_key]
	var empty_cells: Array = []
	empty_cells.make_read_only()
	var empty := {"schemaVersion":1,"sectionKey":vector3i_to_array(section_key),
		"originCell":vector3i_to_array(section_key*SECTION_SIZE),"revision":revision,"cells":empty_cells}
	empty.make_read_only()
	return empty

func load_section(section_key: Vector3i, delta: Dictionary) -> void:
	var cells_value = delta.get("cells", [])
	if not (cells_value is Array):
		return
	var skylight_columns := {}
	for item in cells_value:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		var cell := Vector3i.ZERO
		if entry.has("cell"):
			cell = vector3i_from_value(entry.get("cell"), Vector3i.ZERO)
		else:
			var local = entry.get("local", Vector3i.ZERO)
			cell = section_key * SECTION_SIZE + vector3i_from_value(local, Vector3i.ZERO)
		var state: Dictionary = entry.get("state", {}) if entry.get("state", {}) is Dictionary else {}
		var previous_state: Dictionary = edited_cells[cell] if edited_cells.has(cell) else {}
		if terrain_edit_updates_sky_light(state) or terrain_edit_updates_sky_light(previous_state):
			skylight_columns[Vector2i(cell.x, cell.z)] = true
		set_cell_state(cell, state, "loaded_delta", false)
	for column_value in skylight_columns.keys():
		var column: Vector2i = column_value
		rebuild_sky_light_column(column.x, column.y, "loaded_delta")

func save_all_section_deltas() -> Dictionary:
	var section_keys: Array = durable_delta_cells_by_section.keys()
	section_keys.sort_custom(_vector3i_less)
	var deltas: Array = []
	for section_key: Vector3i in section_keys:
		_refresh_durable_delta_section(section_key)
		var delta: Dictionary = durable_delta_section_snapshots.get(section_key,{})
		if not delta.is_empty(): deltas.append(delta)
	deltas.make_read_only()
	return {
		"schemaVersion": 1,
		"sectionSize": SECTION_SIZE,
		"revision": revision,
		"sections": deltas
	}

func _update_durable_delta_cell(cell: Vector3i, state: Dictionary) -> void:
	var section_key := section_key_for_cell(cell)
	var bucket: Dictionary = durable_delta_cells_by_section.get(section_key,{})
	if state.is_empty() or not cell_state_saved_in_delta(state):
		bucket.erase(cell)
	else:
		var saved_state: Dictionary = state.duplicate(true)
		saved_state["cell"] = vector3i_to_array(cell)
		saved_state["sectionKey"] = vector3i_to_array(section_key)
		saved_state["localCell"] = vector3i_to_array(local_cell_for(cell))
		var record: Variant = _freeze_durable_delta_value({"local":vector3i_to_array(local_cell_for(cell)),
			"cell":vector3i_to_array(cell),"state":saved_state})
		if record is Dictionary: bucket[cell]=record
	if bucket.is_empty(): durable_delta_cells_by_section.erase(section_key)
	else: durable_delta_cells_by_section[section_key]=bucket
	durable_delta_dirty_sections[section_key]=true
	durable_delta_section_revisions[section_key]=revision

func _refresh_durable_delta_section(section_key: Vector3i) -> void:
	if not durable_delta_dirty_sections.has(section_key): return
	durable_delta_dirty_sections.erase(section_key)
	var bucket: Dictionary = durable_delta_cells_by_section.get(section_key,{})
	if bucket.is_empty():
		durable_delta_section_snapshots.erase(section_key)
		return
	var cells: Array = []
	var cell_keys: Array = bucket.keys()
	cell_keys.sort_custom(_vector3i_less)
	for cell: Vector3i in cell_keys: cells.append(bucket[cell])
	cells.make_read_only()
	var delta := {"schemaVersion":1,"sectionKey":vector3i_to_array(section_key),
		"originCell":vector3i_to_array(section_key*SECTION_SIZE),
		"revision":int(durable_delta_section_revisions.get(section_key,revision)),"cells":cells}
	delta.make_read_only()
	durable_delta_section_snapshots[section_key]=delta

static func _vector3i_less(a: Vector3i, b: Vector3i) -> bool:
	return a.z<b.z or a.z==b.z and (a.y<b.y or a.y==b.y and a.x<b.x)

static func _freeze_durable_delta_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen_dictionary: Dictionary = {}
		for key in value: frozen_dictionary[key]=_freeze_durable_delta_value(value[key])
		frozen_dictionary.make_read_only()
		return frozen_dictionary
	if value is Array:
		var frozen_array: Array = []
		for item in value: frozen_array.append(_freeze_durable_delta_value(item))
		frozen_array.make_read_only()
		return frozen_array
	return value

func load_section_deltas(snapshot_value) -> void:
	var snapshot: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
	var sections_value = snapshot.get("sections", [])
	if not (sections_value is Array):
		return
	for value in sections_value:
		if not (value is Dictionary):
			continue
		var delta: Dictionary = value
		var section_key := vector3i_from_value(delta.get("sectionKey", Vector3i.ZERO), Vector3i.ZERO)
		load_section(section_key, delta)

func chunk_has_edits(chunk_key: Vector2i, chunk_size: int) -> bool:
	var start_x := chunk_key.x * chunk_size
	var start_z := chunk_key.y * chunk_size
	var end_x := start_x + chunk_size
	var end_z := start_z + chunk_size
	for section_key in mesh_edited_section_keys_for_chunk(chunk_key, chunk_size):
		var bucket: Dictionary = mesh_edited_cells_by_section.get(section_key, {}) if mesh_edited_cells_by_section.get(section_key, {}) is Dictionary else {}
		for cell_value in bucket.keys():
			var cell: Vector3i = cell_value
			if cell.x >= start_x and cell.x < end_x and cell.z >= start_z and cell.z < end_z:
				return true
	return false

func chunk_edited_y_bounds(chunk_key: Vector2i, chunk_size: int) -> Dictionary:
	var start_x := chunk_key.x * chunk_size
	var start_z := chunk_key.y * chunk_size
	return mesh_edited_y_bounds_for_region(start_x, start_x + chunk_size - 1, start_z, start_z + chunk_size - 1)

func mesh_edited_y_bounds_for_region(min_x: int, max_x: int, min_z: int, max_z: int) -> Dictionary:
	var from_x := mini(min_x, max_x)
	var to_x := maxi(min_x, max_x)
	var from_z := mini(min_z, max_z)
	var to_z := maxi(min_z, max_z)
	var min_y := 999999
	var max_y := -999999
	var count := 0
	for section_value in mesh_edited_cells_by_section.keys():
		var section_key: Vector3i = section_value
		var section_start_x := section_key.x * SECTION_SIZE
		var section_start_z := section_key.z * SECTION_SIZE
		var section_end_x := section_start_x + SECTION_SIZE - 1
		var section_end_z := section_start_z + SECTION_SIZE - 1
		if section_end_x < from_x or section_start_x > to_x:
			continue
		if section_end_z < from_z or section_start_z > to_z:
			continue
		var bucket: Dictionary = mesh_edited_cells_by_section.get(section_key, {}) if mesh_edited_cells_by_section.get(section_key, {}) is Dictionary else {}
		for cell_value in bucket.keys():
			var cell: Vector3i = cell_value
			if cell.x < from_x or cell.x > to_x or cell.z < from_z or cell.z > to_z:
				continue
			min_y = mini(min_y, cell.y)
			max_y = maxi(max_y, cell.y)
			count += 1
	if count <= 0:
		return { "found": false, "count": 0 }
	return {
		"found": true,
		"minY": min_y,
		"maxY": max_y,
		"count": count
	}

func edited_mesh_cells_for_chunk(chunk_key: Vector2i, chunk_size: int) -> Array[Vector3i]:
	var start_x := chunk_key.x * chunk_size
	var start_z := chunk_key.y * chunk_size
	var end_x := start_x + chunk_size
	var end_z := start_z + chunk_size
	var cells: Array[Vector3i] = []
	for section_key in mesh_edited_section_keys_for_chunk(chunk_key, chunk_size):
		var bucket: Dictionary = mesh_edited_cells_by_section.get(section_key, {}) if mesh_edited_cells_by_section.get(section_key, {}) is Dictionary else {}
		for cell_value in bucket.keys():
			var cell: Vector3i = cell_value
			if cell.x < start_x or cell.x >= end_x or cell.z < start_z or cell.z >= end_z:
				continue
			var state: Dictionary = edited_cells[cell] if edited_cells.has(cell) and edited_cells[cell] is Dictionary else {}
			if bool(state.get("solid", false)):
				continue
			cells.append(cell)
	return cells

func mesh_edited_section_keys_for_chunk(chunk_key: Vector2i, chunk_size: int) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var start_x := chunk_key.x * chunk_size
	var start_z := chunk_key.y * chunk_size
	var end_x := start_x + chunk_size
	var end_z := start_z + chunk_size
	for section_value in mesh_edited_cells_by_section.keys():
		var section_key: Vector3i = section_value
		var section_start_x := section_key.x * SECTION_SIZE
		var section_start_z := section_key.z * SECTION_SIZE
		var section_end_x := section_start_x + SECTION_SIZE
		var section_end_z := section_start_z + SECTION_SIZE
		if section_end_x <= start_x or section_start_x >= end_x:
			continue
		if section_end_z <= start_z or section_start_z >= end_z:
			continue
		result.append(section_key)
	return result

func chunk_revision(chunk_key: Vector2i, chunk_size: int) -> int:
	var start_x := chunk_key.x * chunk_size
	var start_z := chunk_key.y * chunk_size
	var end_x := start_x + chunk_size
	var end_z := start_z + chunk_size
	return max_section_column_revision(section_column_revisions, start_x, start_z, end_x, end_z)

func fluid_chunk_revision_with_halo(chunk_key: Vector2i, chunk_size: int) -> int:
	var size := maxi(1, int(chunk_size))
	var start_x := chunk_key.x * size - 1
	var start_z := chunk_key.y * size - 1
	var end_x := (chunk_key.x + 1) * size + 1
	var end_z := (chunk_key.y + 1) * size + 1
	return max_section_column_revision(fluid_section_column_revisions, start_x, start_z, end_x, end_z)

func update_section_column_revision(index: Dictionary, section_key: Vector3i, value: int) -> void:
	var column_key := Vector2i(section_key.x, section_key.z)
	index[column_key] = maxi(int(index.get(column_key, 0)), value)

func max_section_column_revision(index: Dictionary, start_x: int, start_z: int, end_x: int, end_z: int) -> int:
	if end_x <= start_x or end_z <= start_z:
		return 0
	var min_section_x := floori(float(start_x) / float(SECTION_SIZE))
	var max_section_x := floori(float(end_x - 1) / float(SECTION_SIZE))
	var min_section_z := floori(float(start_z) / float(SECTION_SIZE))
	var max_section_z := floori(float(end_z - 1) / float(SECTION_SIZE))
	var max_revision := 0
	for section_x in range(min_section_x, max_section_x + 1):
		for section_z in range(min_section_z, max_section_z + 1):
			max_revision = maxi(max_revision, int(index.get(Vector2i(section_x, section_z), 0)))
	return max_revision

func edited_cell_count(include_non_mesh := true) -> int:
	if include_non_mesh:
		return edited_cells.size()
	var count := 0
	for cell_value in edited_cells.keys():
		if cell_state_affects_terrain_mesh(edited_cells[cell_value]):
			count += 1
	return count

func chunk_has_generated_underground_air_boundary(chunk_key: Vector2i, chunk_size: int, step_cells := 4, vertical_step_cells := 4, max_depth_cells := 0) -> bool:
	var size := maxi(1, int(chunk_size))
	var step := maxi(1, int(step_cells))
	var vertical_step := maxi(1, int(vertical_step_cells))
	var start_x := chunk_key.x * size
	var start_z := chunk_key.y * size
	var end_x := start_x + size
	var end_z := start_z + size
	for z in range(start_z - step, end_z + step + 1, step):
		for x in range(start_x - step, end_x + step + 1, step):
			var surface_y := reference_surface_y_for_cell(Vector3i(x, 0, z))
			var surface_cell_y := floori(surface_y / cell_size())
			var depth_limit := surface_cell_y - world_bottom_cell_y() - 1
			if max_depth_cells > 0:
				depth_limit = mini(depth_limit, int(max_depth_cells))
			if depth_limit <= 0:
				continue
			for depth in range(1, depth_limit + 1, vertical_step):
				var cell := Vector3i(x, surface_cell_y - depth, z)
				var state := get_cell_state(cell)
				if bool(state.get("solid", false)):
					continue
				if String(state.get("biome", "")) != UNDERGROUND_AIR_BIOME:
					continue
				if not cell_has_solid_neighbor(cell):
					continue
				return true
	return false

func consume_dirty_chunk_keys(chunk_size: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var lookup := {}
	var size := maxi(1, int(chunk_size))
	for section_value in dirty_sections.keys():
		var section_key: Vector3i = section_value
		var section_start_x := section_key.x * SECTION_SIZE
		var section_start_z := section_key.z * SECTION_SIZE
		var section_end_x := section_start_x + SECTION_SIZE - 1
		var section_end_z := section_start_z + SECTION_SIZE - 1
		var chunk_min_x := floori(float(section_start_x) / float(size))
		var chunk_max_x := floori(float(section_end_x) / float(size))
		var chunk_min_z := floori(float(section_start_z) / float(size))
		var chunk_max_z := floori(float(section_end_z) / float(size))
		for chunk_z in range(chunk_min_z, chunk_max_z + 1):
			for chunk_x in range(chunk_min_x, chunk_max_x + 1):
				lookup[Vector2i(chunk_x, chunk_z)] = true
	for cell_value in fluid_dirty_cells.keys():
		var cell: Vector3i = cell_value
		for offset in [Vector2i.ZERO, Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var neighbor_cell := Vector2i(cell.x + offset.x, cell.z + offset.y)
			lookup[Vector2i(floori(float(neighbor_cell.x) / float(size)), floori(float(neighbor_cell.y) / float(size)))] = true
	dirty_sections.clear()
	fluid_dirty_cells.clear()
	for key_value in lookup.keys():
		result.append(key_value)
	return result

func sample_world(position: Vector3) -> Dictionary:
	var cell := world_to_cell3(position)
	var state := get_cell_state(cell)
	var generated := generated_sample(position)
	var column_surface_y := float(generated.get("surfaceY", position.y))
	if column_has_surface_projection_affecting_edits(cell):
		var generation = active_generator()
		if generation != null and generation.has_method("volume_surface_y_for_cell"):
			column_surface_y = float(generation.call("volume_surface_y_for_cell", Vector3i(cell.x, 0, cell.z)))
		else:
			column_surface_y = surface_y_for_cell(Vector3i(cell.x, 0, cell.z))
	var state_solid := bool(state.get("solid", false))
	var density := float(state.get("density", cell_size() if state_solid else -cell_size()))
	var sample := generated.duplicate(true)
	sample["cell"] = cell
	sample["solid"] = state_solid
	sample["biome"] = String(state.get("biome", sample.get("biome", "plains")))
	sample["material"] = String(state.get("material", sample.get("material", "air")))
	sample["fluid"] = String(state.get("fluid", ""))
	sample["light"] = state.get("light", { "sky": 0, "block": 0 })
	sample["density"] = density
	sample["surface"] = absf(density) <= cell_size() * 0.75
	sample["surfaceY"] = column_surface_y
	sample["depthCells"] = maxf(0.0, (column_surface_y - position.y) / maxf(0.001, cell_size()))
	sample["cellState"] = state
	sample["sectionKey"] = section_key_for_cell(cell)
	return sample

func sample_cell(cell: Vector3i) -> Dictionary:
	var s := cell_size()
	return sample_world(Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s))

func numeric_sample_world(position: Vector3) -> Vector3:
	var cell := world_to_cell3(position)
	var generated := generated_sample(position)
	var state := get_cell_state(cell)
	if not cell_state_affects_terrain_mesh(state):
		return Vector3(-cell_size(), INF, float(generated.get("surfaceY", position.y)))
	var solid := bool(state.get("solid", false))
	var density := float(state.get("density", cell_size() if solid else -cell_size()))
	var surface_y := float(generated.get("surfaceY", position.y))
	var underground_air := String(state.get("biome", "")) == "underground_air" and not solid
	return Vector3(density, 0.0 if underground_air else INF, surface_y)

func find_underground_air_sample(search_radius := 16, min_depth_cells := 4, max_depth_cells := UNDERGROUND_AIR_DEFAULT_SEARCH_DEPTH_CELLS) -> Dictionary:
	var radius_cells := maxi(UNDERGROUND_AIR_SEARCH_STEP_CELLS, int(search_radius))
	var min_depth := maxi(1, int(min_depth_cells))
	var max_depth := maxi(min_depth, int(max_depth_cells))
	var step := UNDERGROUND_AIR_SEARCH_STEP_CELLS
	var depth_step := 1
	if radius_cells > 64 or max_depth - min_depth > 36:
		depth_step = UNDERGROUND_AIR_SEARCH_STEP_CELLS
	var fallback_result := {}
	for radius in range(0, radius_cells + 1, step):
		for z in range(-radius, radius + 1, step):
			for x in range(-radius, radius + 1, step):
				if radius > 0 and absi(x) != radius and absi(z) != radius:
					continue
				var surface_cell := Vector3i(x, 0, z)
				var surface_biome := surface_biome_for_cell(surface_cell)
				if surface_biome in ["ocean", "beach", "town"]:
					continue
				var surface_y := surface_y_for_cell(surface_cell)
				var column_max_depth := mini(max_depth, maxi(min_depth, floori(surface_y / cell_size()) - world_bottom_cell_y() - 2))
				for depth in range(min_depth, column_max_depth + 1, depth_step):
					var position := Vector3(float(x) * cell_size(), surface_y - float(depth) * cell_size(), float(z) * cell_size())
					var sample := sample_world(position)
					if String(sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
						continue
					if bool(sample.get("solid", true)):
						continue
					if String(sample.get("fluid", "")) != "":
						continue
					if float(sample.get("density", 0.0)) > -cell_size() * 0.22:
						continue
					var cell := world_to_cell3(position)
					var boundary := underground_air_sample_boundary_summary(cell)
					if int(boundary.get("solidNeighbors", 0)) < 2 or int(boundary.get("airNeighbors", 0)) < 2:
						continue
					var connected_region := underground_air_connected_region_summary(cell, UNDERGROUND_AIR_MIN_CONNECTED_CELLS * 4, UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS)
					if int(connected_region.get("airCells", 0)) < UNDERGROUND_AIR_MIN_CONNECTED_CELLS:
						continue
					var sample_id := "underground-air:%d,%d,%d" % [cell.x, cell.y, cell.z]
					var result := {
						"id": sample_id,
						"sampleId": sample_id,
						"cell": cell,
						"surfaceCell": Vector2i(x, z),
						"position": position,
						"surfaceY": surface_y,
						"depthCells": depth,
						"sample": sample,
						"connectedRegion": connected_region
					}
					if underground_air_sample_is_visually_enclosed(cell):
						return result
					if fallback_result.is_empty():
						fallback_result = result
	return fallback_result

func underground_air_sample_has_solid_boundary(cell: Vector3i) -> bool:
	return int(underground_air_sample_boundary_summary(cell).get("solidNeighbors", 0)) >= 2

func underground_air_connected_region_summary(start_cell: Vector3i, max_cells := 96, max_radius := UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS) -> Dictionary:
	var start_sample := sample_cell(start_cell)
	if bool(start_sample.get("solid", true)) or String(start_sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
		return {
			"airCells": 0,
			"branchDirections": 0,
			"solidBoundarySamples": 0,
			"span": Vector3i.ZERO
		}
	var directions := cardinal_directions()
	var queue: Array[Vector3i] = [start_cell]
	var visited := { start_cell: true }
	var read_index := 0
	var min_cell := start_cell
	var max_cell := start_cell
	var branch_lookup := {}
	var solid_boundary_samples := 0
	while read_index < queue.size() and visited.size() < maxi(1, int(max_cells)):
		var cell: Vector3i = queue[read_index]
		read_index += 1
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		min_cell.z = mini(min_cell.z, cell.z)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
		max_cell.z = maxi(max_cell.z, cell.z)
		for direction in directions:
			var next: Vector3i = cell + direction
			if absi(next.x - start_cell.x) > max_radius or absi(next.y - start_cell.y) > max_radius or absi(next.z - start_cell.z) > max_radius:
				continue
			if visited.has(next):
				continue
			var sample := sample_cell(next)
			if bool(sample.get("solid", false)):
				solid_boundary_samples += 1
				continue
			if String(sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
				continue
			visited[next] = true
			queue.append(next)
			var branch_direction := Vector3i(signi(next.x - start_cell.x), signi(next.y - start_cell.y), signi(next.z - start_cell.z))
			if branch_direction != Vector3i.ZERO:
				branch_lookup[branch_direction] = true
	var span := Vector3i(max_cell.x - min_cell.x + 1, max_cell.y - min_cell.y + 1, max_cell.z - min_cell.z + 1)
	return {
		"airCells": visited.size(),
		"branchDirections": branch_lookup.size(),
		"solidBoundarySamples": solid_boundary_samples,
		"span": span,
		"minCell": min_cell,
		"maxCell": max_cell,
		"truncated": read_index < queue.size()
	}

func underground_air_sample_boundary_summary(cell: Vector3i) -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	for direction in cardinal_directions():
		var sample := sample_cell(cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
		elif String(sample.get("biome", "")) == UNDERGROUND_AIR_BIOME:
			air_neighbors += 1
	return {
		"solidNeighbors": solid_neighbors,
		"airNeighbors": air_neighbors
	}

func underground_air_sample_is_visually_enclosed(cell: Vector3i) -> bool:
	var boundary := underground_air_sample_boundary_summary(cell)
	if int(boundary.get("solidNeighbors", 0)) < UNDERGROUND_AIR_VISUAL_MIN_SOLID_NEIGHBORS:
		return false
	var has_vertical_boundary := solid_at_cell(cell + Vector3i(0, 1, 0)) or solid_at_cell(cell + Vector3i(0, -1, 0))
	if not has_vertical_boundary:
		return false
	var horizontal_solid_neighbors := 0
	for direction in [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]:
		if solid_at_cell(cell + direction):
			horizontal_solid_neighbors += 1
	return horizontal_solid_neighbors > 0

func underground_air_sample_has_surface_exposure(start_cell: Vector3i, max_cells := 512, max_radius := 32) -> bool:
	var start_sample := sample_cell(start_cell)
	if bool(start_sample.get("solid", true)):
		return false
	var queue: Array[Vector3i] = [start_cell]
	var visited := { start_cell: true }
	var read_index := 0
	while read_index < queue.size() and read_index < maxi(1, int(max_cells)):
		var cell: Vector3i = queue[read_index]
		read_index += 1
		var surface_y := surface_y_for_cell(Vector3i(cell.x, 0, cell.z))
		var cell_world_y := (float(cell.y) + 0.5) * cell_size()
		if cell_world_y >= surface_y - cell_size() * 0.5:
			return true
		for direction in cardinal_directions():
			var next := cell + direction
			if visited.has(next):
				continue
			if absi(next.x - start_cell.x) > max_radius or absi(next.y - start_cell.y) > max_radius or absi(next.z - start_cell.z) > max_radius:
				continue
			var sample := sample_cell(next)
			if bool(sample.get("solid", false)):
				continue
			visited[next] = true
			queue.append(next)
	return false

func cardinal_directions() -> Array[Vector3i]:
	return [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]

func surface_y_for_cell(cell: Vector3i) -> float:
	return column_top_surface_y_for_cell(cell)

## Return the surface represented by the VoxelTerrain payload. Scene-rendered
## building blocks intentionally become air in that payload, while terrain
## edits and generated density remain authoritative. Collision publication
## uses this contract instead of comparing the edited mesh to the original
## heightfield.
func terrain_mesh_surface_projection_for_cell(cell: Vector3i) -> Dictionary:
	var key := Vector2i(cell.x, cell.z)
	if terrain_mesh_surface_cache.has(key):
		var cached_value = terrain_mesh_surface_cache[key]
		if cached_value is Dictionary and int(cached_value.get("revision", -1)) == revision:
			return (cached_value as Dictionary).get("projection", {}).duplicate(true)
	var projection := {"found": false, "columnCell": Vector3i(cell.x, 0, cell.z)}
	for y in range(world_top_cell_y(), world_bottom_cell_y() - 1, -1):
		var solid_cell := Vector3i(cell.x, y, cell.z)
		var solid_state := terrain_mesh_payload_state(solid_cell, get_cell_state(solid_cell))
		if not bool(solid_state.get("solid", false)):
			continue
		var air_cell := solid_cell + Vector3i(0, 1, 0)
		var air_state := terrain_mesh_payload_state(air_cell, get_cell_state(air_cell))
		if bool(air_state.get("solid", false)):
			continue
		projection = {
			"found": true,
			"solidCell": solid_cell,
			"airCell": air_cell,
			"position": Vector3((float(cell.x) + 0.5) * cell_size(), float(air_cell.y) * cell_size(), (float(cell.z) + 0.5) * cell_size()),
			"solidState": solid_state,
			"airState": air_state
		}
		break
	terrain_mesh_surface_cache[key] = {"revision": revision, "projection": projection.duplicate(true)}
	return projection

func reference_surface_y_for_cell(cell: Vector3i) -> float:
	var generation = active_generator()
	if generation != null and generation.has_method("terrain_reference_surface_y_for_cell"):
		return float(generation.call("terrain_reference_surface_y_for_cell", cell))
	var sample := generated_sample(Vector3(float(cell.x) * cell_size(), 0.0, float(cell.z) * cell_size()))
	return float(sample.get("surfaceY", 0.0))

func column_top_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if top_surface_y_cache.has(key):
		var cached_value = top_surface_y_cache[key]
		if cached_value is Dictionary:
			var cached: Dictionary = cached_value
			if int(cached.get("revision", -1)) == revision:
				return float(cached.get("surfaceY", 0.0))
	var reference_y := reference_surface_y_for_cell(cell)
	var top_y := mini(world_top_cell_y(), floori(reference_y / cell_size()) + 16)
	var bottom_y := world_bottom_cell_y()
	for y in range(top_y, bottom_y - 1, -1):
		var solid_cell := Vector3i(cell.x, y, cell.z)
		if not solid_at_cell(solid_cell):
			continue
		if solid_at_cell(solid_cell + Vector3i(0, 1, 0)):
			continue
		var surface_y := float(y + 1) * cell_size()
		top_surface_y_cache[key] = {
			"revision": revision,
			"surfaceY": surface_y
		}
		return surface_y
	top_surface_y_cache[key] = {
		"revision": revision,
		"surfaceY": reference_y
	}
	return reference_y

func surface_biome_for_cell(cell: Vector3i) -> String:
	var generation = active_generator()
	if generation != null and generation.has_method("surface_biome_for_cell3"):
		return String(generation.call("surface_biome_for_cell3", cell))
	return String(generated_sample(Vector3(float(cell.x) * cell_size(), 0.0, float(cell.z) * cell_size())).get("biome", "plains"))

func solid_at_cell(cell: Vector3i) -> bool:
	return bool(get_cell_state(cell).get("solid", false))

func is_air_at_cell(cell: Vector3i) -> bool:
	return not solid_at_cell(cell)

func terrain_occupancy_at_cell(cell: Vector3i) -> Dictionary:
	var state := get_cell_state(cell)
	var above := get_cell_state(cell + Vector3i(0, 1, 0))
	var below := get_cell_state(cell + Vector3i(0, -1, 0))
	return {
		"cell": cell,
		"solid": bool(state.get("solid", false)),
		"air": not bool(state.get("solid", false)),
		"material": String(state.get("material", "air")),
		"biome": String(state.get("biome", "")),
		"fluid": String(state.get("fluid", "")),
		"light": state.get("light", { "sky": 0, "block": 0 }),
		"floorSolid": bool(below.get("solid", false)),
		"ceilingSolid": bool(above.get("solid", false)),
		"walkableAir": not bool(state.get("solid", false)) and bool(below.get("solid", false)) and not bool(above.get("solid", false))
	}

func surface_projection_for_cell(column_cell: Vector3i, max_up_cells := 32, max_down_cells := 96) -> Dictionary:
	var start_y := column_cell.y
	var top_y := mini(world_top_cell_y(), start_y + maxi(1, int(max_up_cells)))
	var bottom_y := maxi(world_bottom_cell_y(), start_y - maxi(1, int(max_down_cells)))
	for y in range(top_y, bottom_y - 1, -1):
		var solid_cell := Vector3i(column_cell.x, y, column_cell.z)
		var air_cell := Vector3i(column_cell.x, y + 1, column_cell.z)
		if solid_at_cell(solid_cell) and not solid_at_cell(air_cell):
			return {
				"found": true,
				"solidCell": solid_cell,
				"airCell": air_cell,
				"position": Vector3((float(air_cell.x) + 0.5) * cell_size(), float(air_cell.y) * cell_size(), (float(air_cell.z) + 0.5) * cell_size()),
				"solidState": get_cell_state(solid_cell),
				"airState": get_cell_state(air_cell)
			}
	return { "found": false, "columnCell": column_cell }

func walkable_surface_cell_near(cell: Vector3i, max_up_cells := 16, max_down_cells := 32) -> Dictionary:
	var projection := surface_projection_for_cell(cell, max_up_cells, max_down_cells)
	if projection.is_empty() or not bool(projection.get("found", false)):
		return projection
	var air_cell: Vector3i = projection.get("airCell", cell)
	var above_air_cell := air_cell + Vector3i(0, 1, 0)
	projection["walkable"] = not solid_at_cell(air_cell) and not solid_at_cell(above_air_cell)
	projection["occupancy"] = terrain_occupancy_at_cell(air_cell)
	return projection

## Validate the exact smooth surface boundary already resolved by the world
## generator. Navigation used to follow that authoritative height with another
## broad vertical search for every edited column. Keep the broad search as the
## caller's mismatch fallback, while the ordinary case reads only the three
## cells that prove support and standing headroom at this boundary.
func navigation_surface_projection_at_known_height(column_cell: Vector3i, surface_y: float) -> Dictionary:
	var probe_y := floori(surface_y / cell_size())
	var states := {}
	var solid_cell := Vector3i(2147483000, 2147483000, 2147483000)
	var solid_state := {}
	var air_state := {}
	var above_state := {}
	# Smooth density boundaries and discrete occupancy can straddle an integer
	# lattice plane. Inspect only the four cells adjacent to the already-known
	# boundary, from highest to lowest, instead of scanning an arbitrary column.
	for candidate_y in range(probe_y, probe_y - 3, -1):
		var candidate := Vector3i(column_cell.x, candidate_y, column_cell.z)
		for offset in range(3):
			var sample_cell := candidate + Vector3i(0, offset, 0)
			if not states.has(sample_cell): states[sample_cell] = get_cell_state(sample_cell)
		var candidate_solid: Dictionary = states[candidate]
		var candidate_air: Dictionary = states[candidate + Vector3i(0, 1, 0)]
		var candidate_above: Dictionary = states[candidate + Vector3i(0, 2, 0)]
		if bool(candidate_solid.get("solid", false)) and not bool(candidate_air.get("solid", false)) \
				and not bool(candidate_above.get("solid", false)):
			solid_cell = candidate
			solid_state = candidate_solid
			air_state = candidate_air
			above_state = candidate_above
			break
	if solid_cell.x == 2147483000:
		return {
			"status": "mismatch",
			"reason": "known_surface_boundary_occupancy_mismatch",
			"found": false,
			"columnCell": Vector3i(column_cell.x, 0, column_cell.z)
		}
	var air_cell := solid_cell + Vector3i(0, 1, 0)
	return {
		"status": "ready",
		"reason": "",
		"volumeRevision": revision,
		"found": true,
		"solidCell": solid_cell,
		"airCell": air_cell,
		"position": Vector3(float(column_cell.x) * cell_size(), surface_y, float(column_cell.z) * cell_size()),
		"solidState": solid_state,
		"airState": air_state,
		"walkable": true,
		"occupancy": {
			"cell": air_cell,
			"solid": false,
			"air": true,
			"material": String(air_state.get("material", "air")),
			"biome": String(air_state.get("biome", "")),
			"fluid": String(air_state.get("fluid", "")),
			"light": air_state.get("light", {"sky": 0, "block": 0}),
			"floorSolid": true,
			"ceilingSolid": false,
			"walkableAir": true
		}
	}

func exposed_surface_cells(chunk_key: Vector2i, chunk_size := SECTION_SIZE) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var size := maxi(1, int(chunk_size))
	var start_x := chunk_key.x * size
	var start_z := chunk_key.y * size
	var top_y := world_top_cell_y()
	var bottom_y := world_bottom_cell_y()
	for z in range(start_z, start_z + size):
		for x in range(start_x, start_x + size):
			for y in range(top_y, bottom_y - 1, -1):
				var solid_cell := Vector3i(x, y, z)
				if not bool(get_cell_state(solid_cell).get("solid", false)):
					continue
				if cell_has_air_neighbor(solid_cell):
					result.append(solid_cell)
	return result

func exposed_underground_floor_cells(chunk_key: Vector2i, chunk_size := SECTION_SIZE, max_candidates := 36, max_scan_cells := 0) -> Array[Vector3i]:
	var size := maxi(1, int(chunk_size))
	var candidate_cap := maxi(1, int(max_candidates))
	var scan_cap := int(max_scan_cells)
	var cache_key := "%d,%d:%d:%d:%d" % [chunk_key.x, chunk_key.y, size, candidate_cap, scan_cap]
	if exposed_floor_cache.has(cache_key):
		var cached: Dictionary = exposed_floor_cache[cache_key]
		if int(cached.get("revision", -1)) == revision:
			var cached_cells: Array = cached.get("cells", [])
			var copy: Array[Vector3i] = []
			for value in cached_cells:
				if value is Vector3i:
					copy.append(value)
			return copy
	var result: Array[Vector3i] = []
	var start_x := chunk_key.x * size
	var start_z := chunk_key.y * size
	var bottom_y := world_bottom_cell_y()
	var scanned := 0
	for z in range(start_z, start_z + size):
		for x in range(start_x, start_x + size):
			var surface_y := reference_surface_y_for_cell(Vector3i(x, 0, z))
			var top_y := mini(world_top_cell_y(), floori(surface_y / cell_size()) + 1)
			for y in range(top_y, bottom_y, -1):
				if scan_cap > 0 and scanned >= scan_cap:
					exposed_floor_cache[cache_key] = { "revision": revision, "cells": result.duplicate() }
					return result
				scanned += 1
				var air_cell := Vector3i(x, y, z)
				if not underground_air_floor_cell_is_spawnable(air_cell):
					continue
				result.append(air_cell + Vector3i(0, -1, 0))
				if result.size() >= candidate_cap:
					exposed_floor_cache[cache_key] = { "revision": revision, "cells": result.duplicate() }
					return result
				break
	exposed_floor_cache[cache_key] = { "revision": revision, "cells": result.duplicate() }
	return result

func begin_exposed_underground_floor_scan(chunk_key: Vector2i, chunk_size := SECTION_SIZE) -> Dictionary:
	var size := maxi(1, int(chunk_size))
	return {
		"chunkKey": chunk_key,
		"chunkSize": size,
		"columnIndex": 0,
		"scanY": 0,
		"columnStarted": false,
		"complete": false,
		"revision": chunk_revision(chunk_key, size)
	}

func generated_underground_floor_source_proven_empty(chunk_key: Vector2i,
		chunk_size: int) -> bool:
	var generation = active_generator()
	if generation == null or not generation.has_method("generated_cave_near_surface_footprint"):
		return false
	var size := maxi(1, int(chunk_size))
	var start_x := chunk_key.x * size
	var start_z := chunk_key.y * size
	var end_x := start_x + size
	var end_z := start_z + size
	# Only an explicit underground-air edit can create a candidate outside a
	# cave recipe. Solid town blocks in the same XZ footprint cannot do so.
	for cell_value in edited_cells.keys():
		var cell: Vector3i = cell_value
		if cell.x >= start_x and cell.x < end_x and cell.z >= start_z and cell.z < end_z \
				and _cell_may_add_underground_air(edited_cells[cell]):
			return false
	for cell_value in scene_block_cells.keys():
		var cell: Vector3i = cell_value
		if cell.x >= start_x and cell.x < end_x and cell.z >= start_z and cell.z < end_z \
				and _cell_may_add_underground_air(scene_block_cells[cell]):
			return false
	var half_extent := float(size) * cell_size() * 0.5
	var center := Vector3((float(start_x) + float(size) * 0.5) * cell_size(),
		0.0, (float(start_z) + float(size) * 0.5) * cell_size())
	var radius := half_extent * sqrt(2.0) + cell_size()
	return not bool(generation.call("generated_cave_near_surface_footprint",
		center, radius))


func _cell_may_add_underground_air(state_value: Variant) -> bool:
	if not state_value is Dictionary:
		return true
	var state: Dictionary = state_value
	return not bool(state.get("solid", true)) \
		and String(state.get("biome", "")) == UNDERGROUND_AIR_BIOME


func advance_exposed_underground_floor_scan(state_value, sample_budget := 128, time_budget_ms := -1.0, budget_start_usec := 0) -> Dictionary:
	var state: Dictionary = state_value if state_value is Dictionary else {}
	if state.is_empty():
		return {
			"state": state,
			"complete": true,
			"newCandidates": [],
			"processed": 0
		}
	var chunk_key: Vector2i = state.get("chunkKey", Vector2i.ZERO)
	var size := maxi(1, int(state.get("chunkSize", SECTION_SIZE)))
	var source_revision := chunk_revision(chunk_key, size)
	var restarted := int(state.get("revision", source_revision)) != source_revision
	if restarted:
		state = begin_exposed_underground_floor_scan(chunk_key, size)
	if int(state.get("columnIndex", 0)) == 0 \
			and not bool(state.get("columnStarted", false)) \
			and generated_underground_floor_source_proven_empty(chunk_key, size):
		state["columnIndex"] = size * size
		state["complete"] = true
		state["revision"] = source_revision
		return {"state": state, "complete": true, "newCandidates": [],
			"processed": 0, "restarted": restarted,
			"emptyProof": "no_cave_recipe_or_local_edits"}
	var start_x := chunk_key.x * size
	var start_z := chunk_key.y * size
	var total_columns := size * size
	var column_index := int(state.get("columnIndex", 0))
	var y := int(state.get("scanY", 0))
	var column_started := bool(state.get("columnStarted", false))
	var bottom_y := world_bottom_cell_y()
	var processed := 0
	var new_candidates: Array[Vector3i] = []
	var start_usec := budget_start_usec if int(budget_start_usec) > 0 else Time.get_ticks_usec()
	while column_index < total_columns and processed < maxi(1, int(sample_budget)):
		if processed > 0 and float(time_budget_ms) > 0.0 and float(Time.get_ticks_usec() - start_usec) / 1000.0 >= float(time_budget_ms):
			break
		var lx := column_index % size
		var lz := floori(float(column_index) / float(size))
		var cell_x := start_x + lx
		var cell_z := start_z + lz
		if not column_started:
			var surface_y := reference_surface_y_for_cell(Vector3i(cell_x, 0, cell_z))
			y = mini(world_top_cell_y(), floori(surface_y / cell_size()) + 1)
			column_started = true
		var finished_column := false
		while y > bottom_y and processed < maxi(1, int(sample_budget)):
			if processed > 0 and float(time_budget_ms) > 0.0 and float(Time.get_ticks_usec() - start_usec) / 1000.0 >= float(time_budget_ms):
				break
			var air_cell := Vector3i(cell_x, y, cell_z)
			processed += 1
			if underground_air_floor_cell_is_spawnable(air_cell):
				new_candidates.append(air_cell + Vector3i(0, -1, 0))
				finished_column = true
				break
			y -= 1
		if finished_column or y <= bottom_y:
			column_index += 1
			y = 0
			column_started = false
		else:
			break
	var complete := column_index >= total_columns
	state["columnIndex"] = column_index
	state["scanY"] = y
	state["columnStarted"] = column_started
	state["complete"] = complete
	state["revision"] = source_revision
	return {
		"state": state,
		"complete": complete,
		"newCandidates": new_candidates,
		"processed": processed,
		"restarted": restarted
	}

func underground_air_floor_cell_is_spawnable(air_cell: Vector3i) -> bool:
	var air_state := get_cell_state(air_cell)
	if bool(air_state.get("solid", true)):
		return false
	if String(air_state.get("biome", "")) != UNDERGROUND_AIR_BIOME:
		return false
	if String(air_state.get("fluid", "")) != "":
		return false
	var head_state := get_cell_state(air_cell + Vector3i(0, 1, 0))
	if bool(head_state.get("solid", false)):
		return false
	var floor_state := get_cell_state(air_cell + Vector3i(0, -1, 0))
	if not bool(floor_state.get("solid", false)):
		return false
	var material := String(floor_state.get("material", ""))
	return material != "" and material != "air" and material != "water" and material != "lava"

func cell_has_air_neighbor(cell: Vector3i) -> bool:
	for direction in cardinal_directions():
		if not bool(get_cell_state(cell + direction).get("solid", true)):
			return true
	return false

func cell_has_solid_neighbor(cell: Vector3i) -> bool:
	for direction in cardinal_directions():
		if bool(get_cell_state(cell + direction).get("solid", false)):
			return true
	return false

func generated_cell_state(cell: Vector3i) -> Dictionary:
	var generation = active_generator()
	if generation != null and generation.has_method("generate_cell_state"):
		return normalize_cell_state(cell, generation.call("generate_cell_state", cell), false)
	var sample := generated_sample(Vector3((float(cell.x) + 0.5) * cell_size(), (float(cell.y) + 0.5) * cell_size(), (float(cell.z) + 0.5) * cell_size()))
	return normalize_cell_state(cell, sample, false)

func normalize_cell_state(cell: Vector3i, state: Dictionary, edited := false) -> Dictionary:
	var material := String(state.get("material", "air"))
	var solid := bool(state.get("solid", material != "air"))
	var biome := String(state.get("biome", "plains"))
	var normalized := {
		"cell": cell,
		"sectionKey": section_key_for_cell(cell),
		"localCell": local_cell_for(cell),
		"blockId": String(state.get("blockId", material)),
		"material": material,
		"biome": biome,
		"solid": solid,
		"density": float(state.get("density", cell_size() if solid else -cell_size())),
		"fluid": String(state.get("fluid", "")),
		"light": normalize_light(state.get("light", {}), solid),
		"metadata": (state.get("metadata", {}) as Dictionary).duplicate(true) if state.get("metadata", {}) is Dictionary else {},
		"generated": not edited,
		"edited": edited
	}
	return normalized

func cell_state_affects_terrain_mesh(state_value) -> bool:
	if not (state_value is Dictionary):
		return true
	var state: Dictionary = state_value
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	if metadata.has("terrainMeshAffects"):
		return bool(metadata.get("terrainMeshAffects", true))
	if bool(metadata.get("renderedBySceneBlock", false)):
		return false
	return String(metadata.get("source", "")) != "scene_block"

func cell_state_affects_surface_projection(state_value) -> bool:
	if not (state_value is Dictionary):
		return true
	var state: Dictionary = state_value
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	if bool(metadata.get("renderedBySceneBlock", false)):
		return false
	var source := String(metadata.get("source", ""))
	if source == "scene_block" or source.begins_with("structure_"):
		return false
	if metadata.has("terrainMeshAffects"):
		return bool(metadata.get("terrainMeshAffects", true))
	return true

func cell_state_saved_in_delta(state_value) -> bool:
	if not (state_value is Dictionary):
		return true
	var state: Dictionary = state_value
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	if metadata.has("saveDelta"):
		return bool(metadata.get("saveDelta", true))
	return true

func normalize_light(light_value, solid: bool) -> Dictionary:
	var light: Dictionary = light_value if light_value is Dictionary else {}
	return {
		"sky": int(light.get("sky", 0 if solid else 15)),
		"block": int(light.get("block", 0))
	}

func generated_sample(position: Vector3) -> Dictionary:
	var generation = active_generator()
	if generation != null and generation.has_method("generate_sample_without_volume"):
		return generation.call("generate_sample_without_volume", position)
	return {
		"cell": world_to_cell3(position),
		"position": position,
		"density": -cell_size(),
		"solid": false,
		"biome": "plains",
		"material": "air",
		"surface": false,
		"surfaceY": position.y,
		"baseSurfaceY": position.y,
		"depthCells": 0.0,
		"generatedDepthCells": 0
	}

func world_to_cell3(position: Vector3) -> Vector3i:
	var s := cell_size()
	return Vector3i(floori(position.x / s), floori(position.y / s), floori(position.z / s))

func cell_size() -> float:
	return configured_cell_size

func world_bottom_cell_y() -> int:
	var generation = active_generator()
	if generation != null and generation.has_method("world_bottom_cell_y"):
		return int(generation.call("world_bottom_cell_y"))
	var min_height := configured_min_height
	return floori((min_height - cell_size() * 36.0) / cell_size())

func world_top_cell_y() -> int:
	var max_height := configured_max_height
	return ceili((max_height + cell_size() * 4.0) / cell_size())

func vector3i_to_array(value: Vector3i) -> Array:
	return [value.x, value.y, value.z]

func vector3i_from_value(value, fallback: Vector3i) -> Vector3i:
	if value is Vector3i:
		return value
	if value is Vector3:
		return Vector3i(int(value.x), int(value.y), int(value.z))
	if value is Array and value.size() >= 3:
		return Vector3i(int(value[0]), int(value[1]), int(value[2]))
	if value is Dictionary:
		return Vector3i(int(value.get("x", fallback.x)), int(value.get("y", fallback.y)), int(value.get("z", fallback.z)))
	return fallback
