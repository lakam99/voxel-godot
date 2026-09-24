extends RefCounted
class_name NativeDecodedSaveRetirement

## Consumes the terrain arrays of an exclusively owned decoded file save after
## both script restore and native admission have completed. Caller-provided
## snapshot overrides are not eligible because their nested aliases may remain
## live outside the loading operation.
const MAX_RECORDS_PER_ADVANCE := 64
const MAX_ATOMIC_CONTAINER_VALUES := 128

var _snapshot: Dictionary = {}
var _sections: Array = []
var _legacy: Array = []
var _state := "new"
var _failure := ""
var _invalid_start := false
var _failure_drain_stack: Array = []
var _retirement_drain_stack: Array = []
var _removed_records := 0
var _max_advance_usec := 0

func start_owned_file_save(snapshot: Dictionary) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"retirement_already_started"}
	_snapshot = snapshot
	if snapshot.is_empty(): return _start_failed("owned_save_missing")
	var volume_value = snapshot.get("terrainVolume", {})
	if not volume_value is Dictionary: return _start_failed("terrain_volume_invalid")
	var sections_value = (volume_value as Dictionary).get("sections", [])
	if not sections_value is Array: return _start_failed("terrain_sections_invalid")
	var legacy_value = snapshot.get("terrain", [])
	if not legacy_value is Array: return _start_failed("legacy_terrain_invalid")
	_sections = sections_value
	_legacy = legacy_value
	_state = "retiring"
	return {"status":"pending", "reason":"owned_save_terrain_retirement_pending"}

func _start_failed(reason: String) -> Dictionary:
	_failure = reason
	_invalid_start = true
	_state = "failed"
	return {"status":"failed", "reason":reason,
		"ownerMustBeRetained":not _snapshot.is_empty()}

func advance(max_records: int = MAX_RECORDS_PER_ADVANCE) -> Dictionary:
	if _state == "ready": return {"status":"ready", "removedRecords":_removed_records}
	if _state != "retiring" or max_records <= 0 or max_records > MAX_RECORDS_PER_ADVANCE:
		return {"status":"failed", "reason":"retirement_budget_or_state_invalid"}
	var started := Time.get_ticks_usec()
	var removed := 0
	var work_units := 0
	while work_units < max_records:
		if not _retirement_drain_stack.is_empty():
			_drain_container_unit(_retirement_drain_stack)
			work_units += 1
			continue
		if _sections.is_empty(): break
		var section_value = _sections.back()
		if not section_value is Dictionary:
			_removed_records += removed
			_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
			_state = "failed"
			_failure = "terrain_section_invalid"
			_invalid_start = true
			_retirement_drain_stack = []
			return {"status":"failed", "reason":_failure, "ownerMustBeRetained":true}
		var cells_value = (section_value as Dictionary).get("cells", [])
		if not cells_value is Array:
			_removed_records += removed
			_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
			_state = "failed"
			_failure = "terrain_cells_invalid"
			_invalid_start = true
			_retirement_drain_stack = []
			return {"status":"failed", "reason":_failure, "ownerMustBeRetained":true}
		var cells: Array = cells_value
		if cells.is_empty():
			if not _bounded_container_tree(section_value):
				_retirement_drain_stack.append(section_value)
				work_units += 1
				continue
			_sections.pop_back()
			work_units += 1
			continue
		if not _bounded_container_tree(cells.back()):
			_retirement_drain_stack.append(cells.back())
			work_units += 1
			continue
		cells.pop_back()
		removed += 1
		work_units += 1
	while work_units < max_records and not _legacy.is_empty():
		if not _retirement_drain_stack.is_empty():
			_drain_container_unit(_retirement_drain_stack)
			work_units += 1
			continue
		if not _bounded_container_tree(_legacy.back()):
			_retirement_drain_stack.append(_legacy.back())
			work_units += 1
			continue
		_legacy.pop_back()
		removed += 1
		work_units += 1
	_removed_records += removed
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
	if not _sections.is_empty() or not _legacy.is_empty() or not _retirement_drain_stack.is_empty():
		return {"status":"pending", "reason":"owned_save_terrain_retirement_pending",
			"removedRecords":_removed_records, "lastAdvanceRecords":removed}
	if not _bounded_container_tree(_snapshot):
		_retirement_drain_stack.append(_snapshot)
		return {"status":"pending", "reason":"owned_save_terrain_retirement_pending",
			"removedRecords":_removed_records, "lastAdvanceRecords":removed}
	var release_started := Time.get_ticks_usec()
	_snapshot.erase("terrainVolume")
	_snapshot.erase("terrain")
	_sections = []
	_legacy = []
	_retirement_drain_stack = []
	_snapshot = {}
	_state = "ready"
	return {"status":"ready", "removedRecords":_removed_records,
		"maxAdvanceUsec":_max_advance_usec,
		"finalReleaseUsec":Time.get_ticks_usec() - release_started}

func advance_failed_drain(max_records: int = MAX_RECORDS_PER_ADVANCE) -> Dictionary:
	if _state == "ready": return {"status":"ready", "drained":true, "reason":_failure}
	if _state not in ["failed", "draining"] or max_records <= 0 or max_records > MAX_RECORDS_PER_ADVANCE:
		return {"status":"failed", "reason":"retirement_drain_budget_or_state_invalid",
			"ownerMustBeRetained":true}
	_state = "draining"
	if _invalid_start:
		return _advance_invalid_start_drain(max_records)
	var work_units := 0
	while work_units < max_records and not _sections.is_empty():
		var section_value = _sections.back()
		if section_value is Dictionary and (section_value as Dictionary).get("cells", []) is Array:
			var cells: Array = (section_value as Dictionary).get("cells", [])
			if not cells.is_empty():
				cells.pop_back()
				work_units += 1
				continue
		_sections.pop_back()
		work_units += 1
	while work_units < max_records and not _legacy.is_empty():
		_legacy.pop_back()
		work_units += 1
	if not _sections.is_empty() or not _legacy.is_empty():
		return {"status":"pending", "reason":"failed_save_terrain_drain_pending",
			"ownerMustBeRetained":true}
	_snapshot.erase("terrainVolume")
	_snapshot.erase("terrain")
	_sections = []
	_legacy = []
	_snapshot = {}
	_state = "ready"
	return {"status":"ready", "drained":true, "reason":_failure}

func _advance_invalid_start_drain(max_records: int) -> Dictionary:
	if _failure_drain_stack.is_empty() and not _snapshot.is_empty():
		_failure_drain_stack.append(_snapshot)
	var work_units := 0
	while work_units < max_records and not _failure_drain_stack.is_empty():
		_drain_container_unit(_failure_drain_stack)
		work_units += 1
	if not _failure_drain_stack.is_empty() or not _snapshot.is_empty():
		return {"status":"pending", "reason":"invalid_owned_save_drain_pending",
			"ownerMustBeRetained":true}
	_failure_drain_stack = []
	_sections = []
	_legacy = []
	_snapshot = {}
	_state = "ready"
	return {"status":"ready", "drained":true, "reason":_failure}

func _bounded_container_tree(value: Variant) -> bool:
	var pending: Array = [value]
	var visited := 0
	while not pending.is_empty():
		var current = pending.pop_back()
		visited += 1
		if visited + pending.size() > MAX_ATOMIC_CONTAINER_VALUES: return false
		if current is Array:
			var values: Array = current
			if visited + pending.size() + values.size() > MAX_ATOMIC_CONTAINER_VALUES: return false
			for item in values: pending.append(item)
		elif current is Dictionary:
			var values: Dictionary = current
			if visited + pending.size() + values.size() > MAX_ATOMIC_CONTAINER_VALUES: return false
			for key in values: pending.append(values[key])
	return true

func _drain_container_unit(stack: Array) -> void:
	var container = stack.back()
	if container is Array:
		var values: Array = container
		if values.is_empty():
			stack.pop_back()
			return
		var value = values.back()
		if (value is Array and not (value as Array).is_empty()) \
				or (value is Dictionary and not (value as Dictionary).is_empty()):
			stack.append(value)
			return
		values.pop_back()
	elif container is Dictionary:
		var values: Dictionary = container
		if values.is_empty():
			stack.pop_back()
			return
		var key: Variant = null
		for candidate in values:
			key = candidate
			break
		var value = values[key]
		if (value is Array and not (value as Array).is_empty()) \
				or (value is Dictionary and not (value as Dictionary).is_empty()):
			stack.append(value)
			return
		values.erase(key)
	else:
		stack.pop_back()

func snapshot() -> Dictionary:
	return {"state":_state, "removedRecords":_removed_records,
		"sectionsRemaining":_sections.size(), "legacyRemaining":_legacy.size(),
		"maxAdvanceUsec":_max_advance_usec, "ownerRetained":not _snapshot.is_empty(),
		"failure":_failure, "invalidStart":_invalid_start,
		"failureDrainDepth":_failure_drain_stack.size(),
		"retirementDrainDepth":_retirement_drain_stack.size()}
