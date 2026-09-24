extends RefCounted
class_name NativeDecodedSaveRetirement

## Consumes the terrain arrays of an exclusively owned decoded file save after
## both script restore and native admission have completed. Caller-provided
## snapshot overrides are not eligible because their nested aliases may remain
## live outside the loading operation.
const MAX_RECORDS_PER_ADVANCE := 64

var _snapshot: Dictionary = {}
var _sections: Array = []
var _legacy: Array = []
var _state := "new"
var _removed_records := 0
var _max_advance_usec := 0

func start_owned_file_save(snapshot: Dictionary) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"retirement_already_started"}
	if snapshot.is_empty(): return {"status":"failed", "reason":"owned_save_missing"}
	var volume_value = snapshot.get("terrainVolume", {})
	if not volume_value is Dictionary: return {"status":"failed", "reason":"terrain_volume_invalid"}
	var sections_value = (volume_value as Dictionary).get("sections", [])
	if not sections_value is Array: return {"status":"failed", "reason":"terrain_sections_invalid"}
	var legacy_value = snapshot.get("terrain", [])
	if not legacy_value is Array: return {"status":"failed", "reason":"legacy_terrain_invalid"}
	_snapshot = snapshot
	_sections = sections_value
	_legacy = legacy_value
	_state = "retiring"
	return {"status":"pending", "reason":"owned_save_terrain_retirement_pending"}

func advance(max_records: int = MAX_RECORDS_PER_ADVANCE) -> Dictionary:
	if _state == "ready": return {"status":"ready", "removedRecords":_removed_records}
	if _state != "retiring" or max_records <= 0 or max_records > MAX_RECORDS_PER_ADVANCE:
		return {"status":"failed", "reason":"retirement_budget_or_state_invalid"}
	var started := Time.get_ticks_usec()
	var removed := 0
	while removed < max_records and not _sections.is_empty():
		var section_value = _sections.back()
		if not section_value is Dictionary:
			return {"status":"failed", "reason":"terrain_section_invalid", "ownerMustBeRetained":true}
		var cells_value = (section_value as Dictionary).get("cells", [])
		if not cells_value is Array:
			return {"status":"failed", "reason":"terrain_cells_invalid", "ownerMustBeRetained":true}
		var cells: Array = cells_value
		if cells.is_empty():
			_sections.pop_back()
			continue
		cells.pop_back()
		removed += 1
	while removed < max_records and not _legacy.is_empty():
		_legacy.pop_back()
		removed += 1
	_removed_records += removed
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)
	if not _sections.is_empty() or not _legacy.is_empty():
		return {"status":"pending", "reason":"owned_save_terrain_retirement_pending",
			"removedRecords":_removed_records, "lastAdvanceRecords":removed}
	var release_started := Time.get_ticks_usec()
	_snapshot.erase("terrainVolume")
	_snapshot.erase("terrain")
	_sections = []
	_legacy = []
	_snapshot = {}
	_state = "ready"
	return {"status":"ready", "removedRecords":_removed_records,
		"maxAdvanceUsec":_max_advance_usec,
		"finalReleaseUsec":Time.get_ticks_usec() - release_started}

func snapshot() -> Dictionary:
	return {"state":_state, "removedRecords":_removed_records,
		"sectionsRemaining":_sections.size(), "legacyRemaining":_legacy.size(),
		"maxAdvanceUsec":_max_advance_usec, "ownerRetained":not _snapshot.is_empty()}
