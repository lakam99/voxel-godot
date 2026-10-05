extends RefCounted
class_name OrdinaryStructureVisualSourceCapture

## A producer-owned, resumable description of ordinary generated structures.
## It carries weak scene references. Admission and receipts still belong to the
## visible-world manifest and must be checked against their live owners there.
const StandaloneSourceScript := preload("res://scripts/world/StandaloneStructureCandidate.gd")
const CitadelPublicationServiceScript := preload("res://scripts/world/CitadelPublicationService.gd")
const OrdinaryGeometryAdapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const MAX_EXPECTED_PER_SOURCE := 8192
const MAX_EXPECTED_PER_QUERY := 16384
const CAPTURE_PHASE_NAMES := ["town_regions", "standalone_regions", "sources",
	"cells", "sort_cells", "hash", "validate"]

var _system_ref: WeakRef
var _system_id := 0
var _main_ref: WeakRef
var _main_id := 0
var _bounds := Rect2i()
var _seed := ""
var _source_generation := 0
var _regional_revision := 0
var _ordinary_revision := 0
var _dependency_revision: Array = []
var _town_size := 0
var _structure_size := 0
var _town_low := Vector2i.ZERO
var _town_high := Vector2i.ZERO
var _standalone_low := Vector2i.ZERO
var _standalone_high := Vector2i.ZERO
var _region_cursor := Vector2i.ZERO
var _source_ids: Dictionary = {}
var _ids: Array = []
var _source_index := 0
var _source: Dictionary = {}
var _source_id := ""
var _source_cells: Array = []
var _unsorted_cells: Array = []
var _sort_cursor := 0
var _cell_cursor := 0
var _expected_scanned := 0
var _candidates: Array[Dictionary] = []
var _bindings: Array = []
var _pending_ids: Array[String] = []
var _hasher: HashingContext
var _hash_cursor := 0
var _validation_cursor := 0
var _output: Array[Dictionary] = []
var _membership_only := false
var _membership_sources: Array = []
var _membership_rows: Array[Dictionary] = []
var _membership_tombstones: Array[Dictionary] = []
var _stage := ""
var _result: Dictionary = {}
var _phase_usec: Dictionary = {}


func begin(system: Object, bounds: Rect2i) -> void:
	_begin(system, bounds, false)


## Captures producer membership as sealed values only. Unlike the legacy
## observer result, this reusable census never retains Nodes or WeakRefs; each
## section resolves current owners and recipe resources after selecting its
## local members.
func begin_membership(system: Object, bounds: Rect2i) -> void:
	_begin(system, bounds, true)


func _begin(system: Object, bounds: Rect2i, membership_only: bool) -> void:
	_membership_only = membership_only
	if not is_instance_valid(system) or not is_instance_valid(system.get("main")) \
			or not CitadelPublicationServiceScript._bounded_region_rectangle(bounds):
		_result = {"status": "failed", "reason": "invalid_ordinary_visual_source_bounds"}
		return
	var main: Object = system.get("main")
	if not system.has_method("region_dependency_scheduling_revision") \
			or not system.has_method("_regional_town_bounds") \
			or not system.has_method("_ordinary_visible_renderable") \
			or not system.has_method("_ordinary_visual_block_key"):
		_result = {"status": "failed", "reason": "invalid_ordinary_visual_source_owner"}
		return
	_town_size = int(main.get("TOWN_REGION_CELLS"))
	_structure_size = int(main.get("STRUCTURE_REGION_CELLS"))
	if _town_size <= 0 or _structure_size <= 0:
		_result = {"status": "failed", "reason": "invalid_ordinary_visual_source_grid"}
		return
	_town_low = Vector2i(floori(float(bounds.position.x) / _town_size),
		floori(float(bounds.position.y) / _town_size)) - Vector2i.ONE
	_town_high = Vector2i(floori(float(bounds.end.x - 1) / _town_size),
		floori(float(bounds.end.y - 1) / _town_size)) + Vector2i.ONE
	_standalone_low = Vector2i(floori(float(bounds.position.x) / _structure_size),
		floori(float(bounds.position.y) / _structure_size)) - Vector2i.ONE
	_standalone_high = Vector2i(floori(float(bounds.end.x - 1) / _structure_size),
		floori(float(bounds.end.y - 1) / _structure_size)) + Vector2i.ONE
	if (_town_high.x - _town_low.x + 1) * (_town_high.y - _town_low.y + 1) > 256 \
			or (_standalone_high.x - _standalone_low.x + 1) \
			* (_standalone_high.y - _standalone_low.y + 1) > 256:
		_result = {"status": "failed", "reason": "ordinary_visual_source_region_limit"}
		return
	_system_ref = weakref(system)
	_system_id = system.get_instance_id()
	_main_ref = weakref(main)
	_main_id = main.get_instance_id()
	_bounds = bounds
	_seed = String(main.get("seed_text"))
	_source_generation = int(system.get("regional_source_generation"))
	_regional_revision = int(system.get("regional_source_revision"))
	_ordinary_revision = int(system.get("ordinary_visual_revision"))
	_dependency_revision = system.call("region_dependency_scheduling_revision", bounds)
	_region_cursor = _town_low
	_stage = "town_regions"


func advance(max_atoms: int = 128, max_usec: int = 3000) -> Dictionary:
	if not _result.is_empty(): return _result.duplicate(false)
	var slice_phase_usec := _empty_phase_usec()
	if max_atoms <= 0 or max_usec <= 0:
		var no_budget := _pending_budget()
		no_budget["sliceUsec"] = 0
		no_budget["phaseUsec"] = _cumulative_phase_usec()
		no_budget["slicePhaseUsec"] = _seal_phase_usec(slice_phase_usec)
		return no_budget
	var context := _context()
	if context.is_empty():
		_result = {"status": "pending", "reason": "ordinary_visual_capture_source_changed",
			"retryable": true, "stage": _stage, "sliceUsec": 0,
			"phaseUsec":_cumulative_phase_usec(),
			"slicePhaseUsec":_seal_phase_usec(slice_phase_usec)}
		return _result
	var started := Time.get_ticks_usec()
	var atoms := 0
	while atoms < max_atoms and Time.get_ticks_usec() - started < max_usec:
		var stage_before := _stage
		var atom_started := Time.get_ticks_usec()
		var outcome := _advance_one(context.system, context.main)
		var atom_usec := maxi(0, Time.get_ticks_usec() - atom_started)
		_phase_usec[stage_before] = int(_phase_usec.get(stage_before, 0)) + atom_usec
		slice_phase_usec[stage_before] = int(slice_phase_usec.get(stage_before, 0)) + atom_usec
		atoms += 1
		if not outcome.is_empty():
			var reported: Dictionary = outcome.duplicate(false)
			var phase_times: Dictionary = _phase_usec.duplicate(false)
			if _membership_only:
				phase_times.make_read_only()
			reported["phaseUsec"] = phase_times
			reported["slicePhaseUsec"] = _seal_phase_usec(slice_phase_usec)
			reported["sliceUsec"] = maxi(0, Time.get_ticks_usec() - started)
			if _membership_only:
				reported.make_read_only()
			_result = reported
			return _result
	var budget := _pending_budget()
	budget["sliceUsec"] = maxi(0, Time.get_ticks_usec() - started)
	budget["phaseUsec"] = _cumulative_phase_usec()
	budget["slicePhaseUsec"] = _seal_phase_usec(slice_phase_usec)
	return budget


func _empty_phase_usec() -> Dictionary:
	var result := {}
	for phase_name: String in CAPTURE_PHASE_NAMES:
		result[phase_name] = 0
	return result


func _seal_phase_usec(value: Dictionary) -> Dictionary:
	var result := value.duplicate(false)
	result.make_read_only()
	return result


func _cumulative_phase_usec() -> Dictionary:
	var result := _phase_usec.duplicate(false)
	if _membership_only:
		result.make_read_only()
	return result


func eligible_for(system: Object, bounds: Rect2i) -> bool:
	return _bounds == bounds and is_instance_valid(system) \
		and system.get_instance_id() == _system_id \
		and (_result.is_empty() or _result.get("status") == "described") \
		and not _context().is_empty()


func _advance_one(system: Object, main: Object) -> Dictionary:
	match _stage:
		"town_regions":
			if _region_cursor.y > _town_high.y:
				_region_cursor = _standalone_low
				_stage = "standalone_regions"
				return {}
			var key := _region_cursor
			_advance_region_cursor(_town_low, _town_high)
			var cache_value: Variant = main.get("town_region_cache")
			var cache: Dictionary = cache_value if cache_value is Dictionary else {}
			if cache_value is Dictionary and not cache.has(key):
				return {"status": "pending", "reason": "ordinary_visual_town_description_pending",
					"retryable": true, "region": key}
			var town: Dictionary = cache.get(key, {}) if cache_value is Dictionary \
				else main.call("town_region", key.x, key.y)
			if not town.is_empty() and (system.call("_regional_town_bounds", town) as Rect2i).intersects(_bounds):
				_source_ids["town:" + String(system.call("town_key_for", town))] = true
			return {}
		"standalone_regions":
			if _region_cursor.y > _standalone_high.y:
				_ids = _source_ids.keys()
				_ids.sort()
				_stage = "sources"
				return {}
			var region := _region_cursor
			_advance_region_cursor(_standalone_low, _standalone_high)
			var candidate: Dictionary = StandaloneSourceScript.candidate_for_region(
				_seed, region, _structure_size, float(main.get("STRUCTURE_SPAWN_CHANCE")))
			if candidate.is_empty(): return {}
			var influence: Dictionary = StandaloneSourceScript.terrain_influence_for_candidate(candidate)
			if not bool(influence.get("bounded", false)):
				return {"status": "failed", "reason": "standalone_visual_source_bounds_missing"}
			if not (influence.influenceCells as Rect2i).intersects(_bounds): return {}
			if (system.get("generated_structures") as Dictionary).get(region, null) != false:
				_source_ids["standalone:%d,%d" % [region.x, region.y]] = true
			return {}
		"sources":
			if _source_index >= _ids.size():
				_begin_hash()
				return {}
			_source_id = String(_ids[_source_index])
			_source_index += 1
			_source = (system.get("ordinary_visual_sources") as Dictionary).get(_source_id, {})
			if _source.is_empty() or not bool(_source.get("completed", false)):
				_pending_ids.append(_source_id)
				return {}
			_bindings.append([_source_id, int(_source.get("revision", 0))])
			if _membership_only:
				_membership_sources.append([_source_id, int(_source.get("revision", 0))])
			var expected: Dictionary = _source.get("expected", {})
			if expected.size() > MAX_EXPECTED_PER_SOURCE \
					or _expected_scanned + expected.size() > MAX_EXPECTED_PER_QUERY:
				return {"status": "pending", "reason": "ordinary_visual_source_capacity",
					"retryable": true, "sourceId": _source_id,
					"expectedCount": expected.size(), "scannedCount": _expected_scanned}
			_expected_scanned += expected.size()
			if not (_source.get("failed", {}) as Dictionary).is_empty():
				_pending_ids.append(_source_id + ":unaccepted_block_output")
			if expected.is_empty() and (_source.get("omitted", {}) as Dictionary).is_empty():
				_pending_ids.append(_source_id + ":no_emitted_blocks")
				return {}
			_source_cells = _source.get("sortedExpectedCells", [])
			if int(_source.get("sortedExpectedRevision", -1)) != int(_source.get("revision", 0)):
				_source_cells = []
				_unsorted_cells = expected.keys()
				_sort_cursor = 0
				_stage = "sort_cells"
			else:
				_cell_cursor = 0
				_stage = "cells"
			return {}
		"sort_cells":
			if _sort_cursor >= _unsorted_cells.size():
				_source.sortedExpectedCells = _source_cells
				_source.sortedExpectedRevision = int(_source.get("revision", 0))
				_unsorted_cells = []
				_cell_cursor = 0
				_stage = "cells"
				return {}
			var cell: Vector3i = _unsorted_cells[_sort_cursor]
			_sort_cursor += 1
			var low := 0
			var high := _source_cells.size()
			while low < high:
				var middle := (low + high) / 2
				if _cell_less(_source_cells[middle], cell): low = middle + 1
				else: high = middle
			_source_cells.insert(low, cell)
			return {}
		"cells":
			if _cell_cursor >= _source_cells.size():
				_source_cells = []
				_source = {}
				_stage = "sources"
				return {}
			var cell: Vector3i = _source_cells[_cell_cursor]
			_cell_cursor += 1
			if not _bounds.has_point(Vector2i(cell.x, cell.z)): return {}
			var block_type := String((_source.expected as Dictionary)[cell])
			var durable_id := String(system.call("_ordinary_visual_block_key", _source_id, cell, block_type))
			if (system.get("removed_generated_structure_blocks") as Dictionary).has(durable_id):
				if _membership_only:
					_membership_tombstones.append({"sourceId":_source_id,
						"sourceRevision":int(_source.get("revision", 0)),
						"cell":cell, "blockType":block_type,
						"durableId":durable_id})
				return {}
			if _membership_only:
				var recipes: Dictionary = _source.get("visualRecipeInputs", {})
				var recipe_value: Variant = recipes.get(cell, null)
				if not _valid_recipe_value(recipe_value, block_type):
					return {"status":"pending", "reason":"ordinary_visual_recipe_input_pending",
						"retryable":true, "sourceId":_source_id, "cell":cell}
				var recipe_input: Dictionary = _freeze_value((recipe_value as Dictionary).duplicate(true))
				var member_id := "ordinary:%s:cell:%d,%d,%d" % [
					_source_id, cell.x, cell.y, cell.z]
				_membership_rows.append({"memberId":member_id,
					"sourceId":_source_id,
					"sourceRevision":int(_source.get("revision", 0)),
					"cell":cell, "blockType":block_type,
					"recipeDigest":String(recipe_input.get("digest", "")),
					"recipeInput":recipe_input})
				_bindings.append([member_id, block_type,
					String(recipe_input.get("digest", ""))])
				return {}
			var body := (main.get("blocks") as Dictionary).get(cell) as Node3D
			if not _valid_body(body, _source_id, block_type): body = null
			var representation := system.call("_ordinary_visible_renderable", body) as Node3D \
				if is_instance_valid(body) else null
			var candidate_id := "ordinary:%s:%d,%d,%d:%s" % [
				_source_id, cell.x, cell.y, cell.z, block_type]
			_candidates.append({"candidateId": candidate_id,
				"positionXZ": Vector2(float(cell.x) + 0.5, float(cell.z) + 0.5),
				"cell": cell, "sourceId": _source_id, "blockType": block_type,
				"owner": weakref(body) if is_instance_valid(body) else null,
				"ownerId": body.get_instance_id() if is_instance_valid(body) else 0,
				"representation": weakref(representation) if is_instance_valid(representation) else null,
				"representationId": representation.get_instance_id() \
					if is_instance_valid(representation) else 0})
			_bindings.append([candidate_id, body.get_instance_id() if is_instance_valid(body) else 0,
				representation.get_instance_id() if is_instance_valid(representation) else 0])
			if _candidates.size() > 100000:
				return {"status": "pending", "reason": "ordinary_visual_source_capacity",
					"retryable": true, "candidateCount": _candidates.size()}
			return {}
		"hash":
			if _hash_cursor >= _bindings.size():
				_hasher.update("]]".to_utf8_buffer())
				_stage = "validate"
				return {}
			var separator := "," if _hash_cursor > 0 else ""
			_hasher.update((separator + JSON.stringify(_bindings[_hash_cursor])).to_utf8_buffer())
			_hash_cursor += 1
			return {}
		"validate":
			if _validation_cursor >= _candidates.size():
				if not _membership_only and not _final_revision_matches(system):
					return {"status": "pending", "reason": "ordinary_visual_capture_source_changed",
						"retryable": true, "stage": _stage}
				var revision := _hasher.finish().hex_encode()
				if _membership_only:
					var frozen_members: Array[Dictionary] = []
					for row: Dictionary in _membership_rows:
						row.make_read_only()
						frozen_members.append(row)
					frozen_members.make_read_only()
					var frozen_tombstones: Array[Dictionary] = []
					for row: Dictionary in _membership_tombstones:
						row.make_read_only()
						frozen_tombstones.append(row)
					frozen_tombstones.make_read_only()
					var frozen_sources: Array = _membership_sources.duplicate(true)
					for source_row: Variant in frozen_sources:
						if source_row is Array:
							source_row.make_read_only()
					frozen_sources.make_read_only()
					var pending_ids: Array[String] = _pending_ids.duplicate()
					pending_ids.make_read_only()
					var phase_times: Dictionary = _phase_usec.duplicate(false)
					phase_times.make_read_only()
					var membership_result := {"status":"pending" if not _pending_ids.is_empty() else "described",
						"reason":"ordinary_visual_sources_pending" if not _pending_ids.is_empty() else "",
						"censusSchema":"ordinary-source-membership-census/v1",
						"sourceRevision":revision, "bounds":_bounds,
						"sources":frozen_sources, "members":frozen_members,
						"tombstones":frozen_tombstones,
						"pendingSourceIds":pending_ids,
						"sourceCount":_ids.size(), "memberCount":frozen_members.size(),
						"tombstoneCount":frozen_tombstones.size(),
						"phaseUsec":phase_times}
					membership_result.make_read_only()
					return membership_result
				return {"status": "pending" if not _pending_ids.is_empty() else "described",
					"reason": "ordinary_visual_sources_pending" if not _pending_ids.is_empty() else "",
					"sourceRevision": revision, "candidates": _output,
					"pendingSourceIds": _pending_ids,
					"sourceCount": _ids.size(), "candidateCount": _output.size(),
					"phaseUsec": _phase_usec.duplicate()}
			var raw: Dictionary = _candidates[_validation_cursor]
			_validation_cursor += 1
			var cell: Vector3i = raw.cell
			var source_id := String(raw.sourceId)
			var block_type := String(raw.blockType)
			if (system.get("removed_generated_structure_blocks") as Dictionary).has(
					String(system.call("_ordinary_visual_block_key", source_id, cell, block_type))):
				return {"status": "pending", "reason": "ordinary_visual_capture_source_changed",
					"retryable": true, "stage": _stage}
			var body := (main.get("blocks") as Dictionary).get(cell) as Node3D
			if not _valid_body(body, source_id, block_type): body = null
			var representation := system.call("_ordinary_visible_renderable", body) as Node3D \
				if is_instance_valid(body) else null
			if (body.get_instance_id() if is_instance_valid(body) else 0) != int(raw.ownerId) \
					or (representation.get_instance_id() if is_instance_valid(representation) else 0) \
					!= int(raw.representationId):
				return {"status": "pending", "reason": "ordinary_visual_capture_owner_changed",
					"retryable": true, "stage": _stage}
			var sealed := raw.duplicate(false)
			sealed["installed"] = is_instance_valid(representation)
			_output.append(sealed)
			return {}
	return {"status": "failed", "reason": "ordinary_visual_capture_stage_invalid"}


func _begin_hash() -> void:
	_hasher = HashingContext.new()
	_hasher.start(HashingContext.HASH_SHA256)
	_hasher.update(("[" + JSON.stringify(_seed) + "," \
		+ JSON.stringify(_source_generation) + "," + JSON.stringify(_ids) + ",[").to_utf8_buffer())
	_hash_cursor = 0
	_stage = "hash"


func _advance_region_cursor(low: Vector2i, high: Vector2i) -> void:
	_region_cursor.x += 1
	if _region_cursor.x > high.x:
		_region_cursor.x = low.x
		_region_cursor.y += 1


func _context() -> Dictionary:
	var system: Object = _system_ref.get_ref() if _system_ref != null else null
	var main: Object = _main_ref.get_ref() if _main_ref != null else null
	if not is_instance_valid(system) or not is_instance_valid(main) \
			or system.get_instance_id() != _system_id or main.get_instance_id() != _main_id \
			or system.get("main") != main \
			or String(main.get("seed_text")) != _seed \
			or int(system.get("regional_source_generation")) != _source_generation \
			or int(system.get("regional_source_revision")) != _regional_revision \
			or int(system.get("ordinary_visual_revision")) != _ordinary_revision:
		return {}
	return {"system": system, "main": main}


func _final_revision_matches(system: Object) -> bool:
	return not _context().is_empty() \
		and system.call("region_dependency_scheduling_revision", _bounds) == _dependency_revision


func _valid_body(body: Node3D, source_id: String, block_type: String) -> bool:
	return is_instance_valid(body) and body.is_inside_tree() \
		and not body.is_queued_for_deletion() \
		and String(body.get_meta("generated_visual_source_id", "")) == source_id \
		and String(body.get_meta("block_type", "")) == block_type


static func _cell_less(a: Vector3i, b: Vector3i) -> bool:
	return a.z < b.z if a.z != b.z else (a.x < b.x if a.x != b.x else a.y < b.y)


func _pending_budget() -> Dictionary:
	return {"status": "pending", "reason": "ordinary_visual_capture_budget",
		"retryable": true, "stage": _stage,
		"cursor": _cell_cursor if _stage == "cells" else _sort_cursor \
			if _stage == "sort_cells" else _hash_cursor if _stage == "hash" \
			else _validation_cursor if _stage == "validate" else _source_index}


func _valid_recipe_value(value: Variant, block_type: String) -> bool:
	if not value is Dictionary or not value.is_read_only() \
			or String(value.get("schema", "")) != "ordinary-structure-visual-recipe-input/v1" \
			or String(value.get("blockType", "")) != block_type \
			or String(value.get("digest", "")).length() != 64:
		return false
	var options: Variant = value.get("options", null)
	return options is Dictionary and options.is_read_only() \
		and OrdinaryGeometryAdapter._visual_recipe_digest(block_type, options) \
			== String(value.get("digest", ""))


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key: Variant in dictionary.keys():
			dictionary[key] = _freeze_value(dictionary[key])
		dictionary.make_read_only()
		return dictionary
	if value is Array:
		var array: Array = value
		for index in array.size():
			array[index] = _freeze_value(array[index])
		array.make_read_only()
		return array
	return value
