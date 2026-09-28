extends RefCounted
class_name TerrainVolumeRestoreCursor

const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")
const SCHEMA_VERSION := 1
const SECTION_SIZE := 16
const MAX_ITEMS_PER_ADVANCE := 256
const MAX_SKY_CELLS_PER_ADVANCE := 4096

# A restore cursor owns the decoded terrainVolume reference for iteration. The
# caller must relinquish mutable aliases after begin(); cloning or freezing the
# complete decoded tree here would itself be unbounded Main-thread work.
# GDScript nested Dictionary/Array aliasing makes this a protocol lease, not an
# enforceable immutable type: the owner that parsed the save must be the sole
# authority allowed to retain/mutate it until this cursor is terminal.
#
# All writes go to a detached TerrainVolumeService with copied scalar setup and
# only the source generator weak reference. The live service is never mutated.
# This is a staging/test mechanism; it has no publish/adopt operation.
# Per-call limits bound input records/section headers and skyline Y samples,
# not CPU time for normalization or arbitrarily complex per-cell metadata.
var _generation := -1
var _state := "idle"
var _snapshot: Dictionary = {}
var _sections: Array = []
var _section_index := 0
var _cell_index := 0
var _current_section_key := Vector3i.ZERO
var _current_section_loaded := false
var _previous_section_key := Vector3i.ZERO
var _has_previous_section := false
var _previous_cell := Vector3i.ZERO
var _has_previous_cell := false
var _total_cells := 0
var _staging_service
var _section_sky_columns := {}
var _section_sky_column_seen := {}
var _section_sky_column_count := 0
var _sky_column_index := 0
var _sky_y := 0
var _sky_open_to_sky := true
var _sky_started := false
var _dispose_cells: Array[Vector3i] = []
var _dispose_cell_seen := {}

func begin(source_service, terrain_volume_snapshot: Dictionary, lease_generation: int) -> Dictionary:
	if _state != "idle":
		return _result("rejected", "cursor_instances_are_single_lease")
	if lease_generation <= 0:
		return _result("rejected", "invalid_lease_generation")
	if source_service == null or not source_service.has_method("active_generator"):
		return _result("rejected", "source_service_invalid")
	if int(terrain_volume_snapshot.get("schemaVersion", -1)) != SCHEMA_VERSION \
			or int(terrain_volume_snapshot.get("sectionSize", -1)) != SECTION_SIZE \
			or not (terrain_volume_snapshot.get("sections", null) is Array) \
			or int(terrain_volume_snapshot.get("revision", -1)) < 0:
		return _result("rejected", "snapshot_header_invalid")
	_generation = lease_generation
	_snapshot = terrain_volume_snapshot
	_sections = terrain_volume_snapshot.get("sections", [])
	_section_index = 0
	_cell_index = 0
	_current_section_loaded = false
	_has_previous_section = false
	_has_previous_cell = false
	_total_cells = 0
	_section_sky_column_count = 0
	_sky_column_index = 0
	_sky_started = false
	_dispose_cells.clear()
	_dispose_cell_seen.clear()
	_staging_service = TerrainVolumeServiceScript.new()
	_staging_service.configured_cell_size = float(source_service.configured_cell_size)
	_staging_service.configured_min_height = float(source_service.configured_min_height)
	_staging_service.configured_max_height = float(source_service.configured_max_height)
	# setup() stores a WeakRef only. Do not retain the generator or source service.
	var source_generator = source_service.active_generator()
	_staging_service.setup(null, source_generator)
	_staging_service.configured_cell_size = float(source_service.configured_cell_size)
	_staging_service.configured_min_height = float(source_service.configured_min_height)
	_staging_service.configured_max_height = float(source_service.configured_max_height)
	_state = "input"
	if _sections.is_empty():
		_state = "complete"
	return _result(_state, "")

func advance(lease_generation: int, max_items := 256, max_sky_y_cells := 1024) -> Dictionary:
	if lease_generation != _generation:
		return _result("stale", "lease_generation_mismatch")
	if _state == "input":
		return _advance_input(maxi(1, mini(MAX_ITEMS_PER_ADVANCE, int(max_items))))
	if _state == "section_sky":
		return _advance_sky(maxi(1, mini(MAX_SKY_CELLS_PER_ADVANCE, int(max_sky_y_cells))))
	return _result(_state, "")

func cancel(lease_generation: int) -> Dictionary:
	if lease_generation != _generation:
		return _result("stale", "lease_generation_mismatch")
	if _state == "complete" or _state == "disposed":
		return _result(_state, "cannot_cancel_terminal_cursor")
	if _state == "cancelled":
		return _result("cancelled", "")
	_state = "cancelled"
	return _result(_state, "")

func staged_service_if_complete(lease_generation: int):
	if lease_generation != _generation or _state != "complete":
		return null
	return _staging_service

func dispose_step(lease_generation: int, max_items := 128) -> Dictionary:
	if lease_generation != _generation:
		return _result("stale", "lease_generation_mismatch")
	if not (_state in ["cancelled", "rejected", "complete", "disposing"]):
		return _result(_state, "cursor_not_terminal")
	_state = "disposing"
	var limit := maxi(1, mini(MAX_ITEMS_PER_ADVANCE, int(max_items)))
	var cleared := 0
	while cleared < limit and not _dispose_cells.is_empty():
		var cell: Vector3i = _dispose_cells.pop_back()
		_dispose_cell_seen.erase(cell)
		_dispose_staged_cell(cell)
		cleared += 1
	while cleared < limit and _section_sky_column_count > 0:
		var column: Vector2i = _section_sky_columns[_sky_column_index]
		_section_sky_columns.erase(_sky_column_index)
		_section_sky_column_seen.erase(column)
		_sky_column_index += 1
		_section_sky_column_count -= 1
		cleared += 1
	if _dispose_cells.is_empty() and _section_sky_column_count == 0:
		# All mutable entries produced by set_cell_state and skyline writes are
		# keyed by a tracked cell/section. Clear scalar state only after the last
		# bounded item has been removed.
		if _staging_service != null:
			_staging_service.revision = 0
			_staging_service.fluid_revision = 0
		_staging_service = null
		_state = "disposed"
	return {
		"status": _state,
		"reason": "",
		"itemsCleared": cleared,
		"itemsRemaining": _dispose_cells.size() + _section_sky_column_count
	}

func status(lease_generation: int) -> Dictionary:
	if lease_generation != _generation:
		return _result("stale", "lease_generation_mismatch")
	return _result(_state, "")

func _advance_input(item_limit: int) -> Dictionary:
	var items_processed := 0
	var cells_processed := 0
	while items_processed < item_limit and _state == "input":
		if not _current_section_loaded:
			if _section_index >= _sections.size():
				_state = "complete"
				break
			var section_value: Variant = _sections[_section_index]
			if not (section_value is Dictionary):
				return _reject("section_not_dictionary", items_processed, cells_processed)
			var section: Dictionary = section_value
			var section_result := _read_vector3i(section.get("sectionKey", null))
			if not bool(section_result.valid):
				return _reject("section_key_invalid", items_processed, cells_processed)
			_current_section_key = section_result.value
			if _has_previous_section and not _vector3i_less(_previous_section_key, _current_section_key):
				return _reject("section_order_or_duplicate_invalid", items_processed, cells_processed)
			if section.has("schemaVersion") and int(section.get("schemaVersion", -1)) != SCHEMA_VERSION:
				return _reject("section_schema_invalid", items_processed, cells_processed)
			if section.has("originCell"):
				var origin_result := _read_vector3i(section.get("originCell", null))
				if not bool(origin_result.valid) or origin_result.value != _current_section_key * SECTION_SIZE:
					return _reject("section_origin_mismatch", items_processed, cells_processed)
			if not (section.get("cells", null) is Array) or (section.get("cells", []) as Array).is_empty():
				return _reject("section_cells_invalid", items_processed, cells_processed)
			if int(section.get("revision", 0)) < 0:
				return _reject("section_revision_invalid", items_processed, cells_processed)
			_previous_section_key = _current_section_key
			_has_previous_section = true
			_cell_index = 0
			_current_section_loaded = true
			_section_sky_column_count = 0
			_sky_column_index = 0
			_sky_started = false
			items_processed += 1
			continue
		var current_section: Dictionary = _sections[_section_index]
		var cells: Array = current_section.get("cells", [])
		if _cell_index >= cells.size():
			_section_index += 1
			_current_section_loaded = false
			_has_previous_cell = false
			if not _section_sky_columns.is_empty():
				_state = "section_sky"
				break
			continue
		var record_value: Variant = cells[_cell_index]
		if not (record_value is Dictionary):
			return _reject("cell_record_not_dictionary", items_processed, cells_processed)
		var record: Dictionary = record_value
		var cell_result := _read_vector3i(record.get("cell", null))
		var local_result := _read_vector3i(record.get("local", null))
		if not bool(cell_result.valid) or not bool(local_result.valid):
			return _reject("cell_identity_invalid", items_processed, cells_processed)
		var cell: Vector3i = cell_result.value
		var expected_local: Vector3i = _staging_service.local_cell_for(cell)
		if _staging_service.section_key_for_cell(cell) != _current_section_key or local_result.value != expected_local:
			return _reject("cell_section_or_local_mismatch", items_processed, cells_processed)
		if _has_previous_cell and not _vector3i_less(_previous_cell, cell):
			return _reject("cell_order_or_duplicate_invalid", items_processed, cells_processed)
		var state_value: Variant = record.get("state", null)
		if not (state_value is Dictionary):
			return _reject("cell_state_invalid", items_processed, cells_processed)
		var cell_state: Dictionary = state_value
		if cell_state.has("cell"):
			var state_cell := _read_vector3i(cell_state.get("cell", null))
			if not bool(state_cell.valid) or state_cell.value != cell:
				return _reject("state_cell_identity_mismatch", items_processed, cells_processed)
		if cell_state.has("sectionKey"):
			var state_section := _read_vector3i(cell_state.get("sectionKey", null))
			if not bool(state_section.valid) or state_section.value != _current_section_key:
				return _reject("state_section_identity_mismatch", items_processed, cells_processed)
		if cell_state.has("localCell"):
			var state_local := _read_vector3i(cell_state.get("localCell", null))
			if not bool(state_local.valid) or state_local.value != expected_local:
				return _reject("state_local_identity_mismatch", items_processed, cells_processed)
		var previous_state: Dictionary = _staging_service.edited_cells.get(cell, {})
		if _staging_service.terrain_edit_updates_sky_light(cell_state) \
				or _staging_service.terrain_edit_updates_sky_light(previous_state):
			_add_sky_column(Vector2i(cell.x, cell.z))
		_staging_service.set_cell_state(cell, cell_state, "loaded_delta", false)
		_track_dispose_cell(cell)
		_previous_cell = cell
		_has_previous_cell = true
		_cell_index += 1
		_total_cells += 1
		items_processed += 1
		cells_processed += 1
	if _state == "input" and _section_index >= _sections.size() and not _current_section_loaded:
		_state = "complete"
	return {
		"status": _state,
		"reason": "",
		"itemsProcessed": items_processed,
		"cellsProcessed": cells_processed,
		"totalCells": _total_cells,
		"sectionIndex": _section_index,
		"skyColumns": _section_sky_column_count
	}

func _advance_sky(y_limit: int) -> Dictionary:
	var y_processed := 0
	while y_processed < y_limit and _state == "section_sky":
		if _section_sky_column_count <= 0:
			_state = "complete" if _section_index >= _sections.size() else "input"
			break
		if not _section_sky_columns.has(_sky_column_index):
			_state = "complete" if _section_index >= _sections.size() else "input"
			break
		if not _sky_started:
			_sky_y = _staging_service.world_top_cell_y()
			_sky_open_to_sky = true
			_sky_started = true
		var column: Vector2i = _section_sky_columns[_sky_column_index]
		var cell := Vector3i(column.x, _sky_y, column.y)
		var state: Dictionary = _staging_service.get_cell_state(cell)
		var solid := bool(state.get("solid", false))
		var existing_light: Dictionary = state.get("light", {}) if state.get("light", {}) is Dictionary else {}
		var next_sky := 15 if _sky_open_to_sky and not solid else 0
		var next_light := {"sky": next_sky, "block": int(existing_light.get("block", 0))}
		if int(existing_light.get("sky", 0)) != next_sky:
			_staging_service.store_light_cell(cell, next_light)
			_staging_service.write_loaded_section_cell_light(cell, next_light)
			_staging_service.mark_section_dirty(_staging_service.section_key_for_cell(cell), {
				"reason": "loaded_delta", "cell": cell, "lightOnly": true, "skyColumn": true
			})
			_track_dispose_cell(cell)
		if solid:
			_sky_open_to_sky = false
		_sky_y -= 1
		y_processed += 1
		if _sky_y < _staging_service.world_bottom_cell_y():
			_section_sky_columns.erase(_sky_column_index)
			_section_sky_column_seen.erase(column)
			_sky_column_index += 1
			_section_sky_column_count -= 1
			_sky_started = false
	if _state == "section_sky" and _section_sky_column_count == 0:
		_state = "complete" if _section_index >= _sections.size() else "input"
	return {
		"status": _state,
		"reason": "",
		"skyYCellsProcessed": y_processed,
		"skyColumnsCompleted": _sky_column_index,
		"skyColumnsTotal": _sky_column_index + _section_sky_column_count,
		"totalCells": _total_cells
	}

func _reject(reason: String, items_processed: int, cells_processed: int) -> Dictionary:
	_state = "rejected"
	return {
		"status": _state,
		"reason": reason,
		"itemsProcessed": items_processed,
		"cellsProcessed": cells_processed,
		"totalCells": _total_cells
	}

func _add_sky_column(column: Vector2i) -> void:
	if _section_sky_column_seen.has(column):
		return
	_section_sky_column_seen[column] = true
	_section_sky_columns[_section_sky_column_count + _sky_column_index] = column
	_section_sky_column_count += 1

func _track_dispose_cell(cell: Vector3i) -> void:
	if _dispose_cell_seen.has(cell):
		return
	_dispose_cell_seen[cell] = true
	_dispose_cells.append(cell)

func retained_staging_bookkeeping_count() -> int:
	return _dispose_cells.size() + _dispose_cell_seen.size() \
		+ _section_sky_columns.size() + _section_sky_column_seen.size()

func _dispose_staged_cell(cell: Vector3i) -> void:
	if _staging_service == null:
		return
	var section_key: Vector3i = _staging_service.section_key_for_cell(cell)
	var state: Dictionary = _staging_service.edited_cells.get(cell, {})
	if not state.is_empty():
		if _staging_service.cell_state_affects_terrain_mesh(state):
			_staging_service.adjust_mesh_edited_column_count(cell, -1)
			_staging_service.set_mesh_edited_cell_index(cell, false)
		if _staging_service.cell_state_affects_surface_projection(state):
			_staging_service.adjust_surface_projection_edited_column_count(cell, -1)
	_staging_service.edited_cells.erase(cell)
	_staging_service.scene_block_previous_states.erase(cell)
	_staging_service.fluid_dirty_cells.erase(cell)
	_staging_service.light_cells.erase(cell)
	_staging_service.block_light_sources.erase(cell)
	var light_bucket: Dictionary = _staging_service.light_cells_by_section.get(section_key, {})
	light_bucket.erase(cell)
	if light_bucket.is_empty():
		_staging_service.light_cells_by_section.erase(section_key)
	else:
		_staging_service.light_cells_by_section[section_key] = light_bucket
	var mesh_bucket: Dictionary = _staging_service.mesh_edited_cells_by_section.get(section_key, {})
	mesh_bucket.erase(cell)
	if mesh_bucket.is_empty():
		_staging_service.mesh_edited_cells_by_section.erase(section_key)
	else:
		_staging_service.mesh_edited_cells_by_section[section_key] = mesh_bucket
	var durable_bucket: Dictionary = _staging_service.durable_delta_cells_by_section.get(section_key, {})
	durable_bucket.erase(cell)
	if durable_bucket.is_empty():
		_staging_service.durable_delta_cells_by_section.erase(section_key)
	else:
		_staging_service.durable_delta_cells_by_section[section_key] = durable_bucket
	_staging_service.durable_delta_section_snapshots.erase(section_key)
	_staging_service.durable_delta_dirty_sections.erase(section_key)
	_staging_service.durable_delta_section_revisions.erase(section_key)
	_staging_service.section_revisions.erase(section_key)
	_staging_service.fluid_section_revisions.erase(section_key)
	var section_column_key := Vector2i(section_key.x, section_key.z)
	_staging_service.section_column_revisions.erase(section_column_key)
	_staging_service.fluid_section_column_revisions.erase(section_column_key)
	_staging_service.dirty_sections.erase(section_key)
	_staging_service.top_surface_y_cache.erase(Vector2i(cell.x, cell.z))
	_staging_service.terrain_mesh_surface_cache.erase(Vector2i(cell.x, cell.z))
	_staging_service.exposed_floor_cache.erase(Vector2i(cell.x, cell.z))
	_staging_service.pending_sky_light_columns.erase(Vector2i(cell.x, cell.z))

func _read_vector3i(value: Variant) -> Dictionary:
	if value is Vector3i:
		return {"valid": true, "value": value}
	if value is Vector3:
		if not is_equal_approx(value.x, roundf(value.x)) or not is_equal_approx(value.y, roundf(value.y)) or not is_equal_approx(value.z, roundf(value.z)):
			return {"valid": false, "value": Vector3i.ZERO}
		return {"valid": true, "value": Vector3i(roundi(value.x), roundi(value.y), roundi(value.z))}
	if value is Array and value.size() == 3:
		var parts: Array[int] = []
		for component in value:
			if not (component is int or component is float) or not is_equal_approx(float(component), roundf(float(component))):
				return {"valid": false, "value": Vector3i.ZERO}
			parts.append(roundi(float(component)))
		return {"valid": true, "value": Vector3i(parts[0], parts[1], parts[2])}
	return {"valid": false, "value": Vector3i.ZERO}

func _vector3i_less(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z or a.z == b.z and (a.y < b.y or a.y == b.y and a.x < b.x)

func _result(status_value: String, reason_value: String) -> Dictionary:
	return {"status": status_value, "reason": reason_value, "totalCells": _total_cells}
