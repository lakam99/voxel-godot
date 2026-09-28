extends RefCounted
class_name NavigationPublicationSource

## Capture owned producer output, not arbitrary scene snapshots. Only the fields
## consumed by NavigationBakeDescriptor plus world identity cross the worker boundary. Geometry and
## source revision decisions remain with GeneratedWorldNavigationAdapter.
const ARRAY_FIELDS := ["surfaces", "semanticRegions", "doorPortals", "doorLinks", "buildingSurfaces", "crossingLinks"]
const MAX_DEPTH := 32
const NpcConstants = preload("res://scripts/npc_ai/NpcConstants.gd")
var _filter_tiles: Array = []
var _capture_mode := "accepted"
var _prepared_fact_lists: Array = []
var _prepared_fact_count := 0
var _prepared_list_usec := 0
var _visited_values := 0
var _sealed_containers := 0
var _failure := ""
var _captured := false

## Producer-only fast path for new lists assembled exclusively from the sealed
## BuildingNavigationTilePreparation artifact supplied by its validated owner.
## Readonly alone is not general proof of a value-only graph: unregistered lists
## always take the recursive path in capture(), even when already readonly.
func seal_prepared_fact_list(owned_list: Array) -> void:
	var started := Time.get_ticks_usec()
	if _captured:
		_failure = "capture_already_consumed"
		return
	if owned_list.get_typed_builtin() not in [TYPE_NIL, TYPE_DICTIONARY]:
		_failure = "invalid_prepared_fact_list_type"
		_prepared_list_usec += Time.get_ticks_usec() - started
		return
	for fact in owned_list:
		if not fact is Dictionary or not fact.is_read_only():
			_failure = "unsealed_prepared_navigation_fact"
			_prepared_list_usec += Time.get_ticks_usec() - started
			return
	owned_list.make_read_only()
	_prepared_fact_lists.append(owned_list)
	_prepared_fact_count += owned_list.size()
	_sealed_containers += 1
	_prepared_list_usec += Time.get_ticks_usec() - started


## Only GeneratedWorldNavigationAdapter calls this with a validated production
## BuildingScenePublicationJob artifact. Readonly arbitrary graphs are not trusted.
func retain_filter_building_tile(source: Dictionary) -> Dictionary:
	if _captured or source.get("status") != "ready" or not source.get("tile") is Dictionary or not source.get("binding") is Dictionary:
		_failure = "invalid_filter_building_source"
		return {}
	var tile: Dictionary = source.tile
	if not tile.get("unresolvedCrossings",[]).is_empty():
		_failure = "source_crossings_unresolved"
		return {}
	var binding: Dictionary = source.binding.duplicate(true)
	if not _seal_owned_value(binding): return {}
	var retained := {"binding":binding}
	for field: String in ["surfaces","collisionRecords","crossingLinks"]:
		var records = tile.get(field,[])
		if not records is Array or (not records.is_empty() and not records.is_read_only()):
			_failure = "unsealed_filter_building_source"
			return {}
		seal_prepared_fact_list(records)
		if not _failure.is_empty(): return {}
		retained[field] = records
	retained.make_read_only()
	_filter_tiles.append(retained)
	return retained

func capture_filter_input(result: Dictionary, input: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	_capture_mode = "filter_input"
	if _captured: return _finish("failed",{},"capture_already_consumed",started)
	_captured = true
	if not _failure.is_empty(): return _finish("failed",{},_failure,started)
	if result.get("publicationStatus") != "ready" or not result.get("worldSeed") is String or result.worldSeed.strip_edges().is_empty():
		return _finish("failed",{},"invalid_filter_source_header",started)
	for field: String in ["tileKey","sourceKey","regionId"]:
		if not result.get(field) is String or result[field].is_empty():
			return _finish("failed",{},"invalid_"+field,started)
	var parts: PackedStringArray = result.tileKey.split(",")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return _finish("failed",{},"invalid_tileKey",started)
	var tile := Vector2i(int(parts[0]),int(parts[1]))
	if result.tileKey != "%d,%d" % [tile.x,tile.y] or result.regionId != "region:chunk:"+result.tileKey or result.get("unloaded",false):
		return _finish("failed",{},"invalid_filter_tile_identity",started)
	var header := {"worldSeed":result.worldSeed,"tileKey":result.tileKey,
		"sourceKey":result.sourceKey,"regionId":result.regionId,"unloaded":false}
	for field: String in ["sourceRevision","semanticRevision"]:
		if not result.get(field) is int or result[field] < 0:
			return _finish("failed",{},"invalid_"+field,started)
		header[field] = result[field]
	if not _valid_filter_input(input,tile):
		return _finish("failed",{},_failure,started)
	if not _seal_owned_value(input) or not _seal_owned_value(header):
		return _finish("failed",{},_failure,started)
	var result_envelope := _finish("prepared",header,"",started).duplicate(false)
	result_envelope["filterInput"] = input
	result_envelope.make_read_only()
	return result_envelope

func _valid_filter_input(input: Dictionary, tile: Vector2i) -> bool:
	_failure = "invalid_navigation_filter_input"
	for field: String in ["terrainCells","staticCollision","buildingTiles","doorPortals","doorLinks"]:
		if not input.get(field) is Array: return false
	if not input.get("waterLevel") is float or not is_finite(input.waterLevel) or not input.get("diagnostics") is Dictionary: return false
	var size: int = NpcConstants.NAV_TILE_CELL_SIZE
	if input.terrainCells.size() != size*size: return false
	for index in range(size*size):
		var fact = input.terrainCells[index]
		var expected := Vector2i(tile.x*size+index%size,tile.y*size+floori(float(index)/size))
		if not fact is Dictionary or fact.get("cell") != expected or not fact.get("height") is float or not is_finite(fact.height): return false
		for field: String in ["staticBlocked","propBlocked","path"]:
			if not fact.get(field) is bool: return false
		for field: String in ["door","staticEvidence","propEvidence"]:
			if not fact.get(field) is Dictionary: return false
		if not fact.door.is_empty():
			if not fact.door.get("state") is String or not fact.door.get("evidence") is Dictionary: return false
			for field: String in ["locked","jammed","destroyed","unloaded"]:
				if not fact.door.get(field) is bool: return false
	for record in input.staticCollision:
		if not record is Dictionary or not record.get("terrainNodeValid") is bool or record.has("node"): return false
		if not record.get("id") is String or not record.get("cell") is Vector2i: return false
		for field: String in ["minX","maxX","minY","maxY","minZ","maxZ","inflation"]:
			if not record.get(field) is float or not is_finite(record[field]): return false
		if record.minX > record.maxX or record.minY > record.maxY or record.minZ > record.maxZ: return false
		if record.has("footprint"):
			if not record.footprint is Array: return false
			for point in record.footprint:
				if not point is Vector3 or not point.is_finite(): return false
	for tile_value in input.buildingTiles:
		var admitted := false
		for retained in _filter_tiles:
			if is_same(retained,tile_value): admitted = true; break
		if not admitted: return false
	for portal in input.doorPortals:
		if not portal is Dictionary or not portal.get("id") is String or portal.id.is_empty(): return false
		for field: String in ["entrance","exit"]:
			if not portal.get(field) is Vector3 or not portal[field].is_finite(): return false
	for link in input.doorLinks:
		if not link is Dictionary or not link.get("id") is String or link.id.is_empty() or not link.get("portalId") is String or link.portalId.is_empty() or not link.get("cell") is Vector2i: return false
		for field: String in ["start","end"]:
			if not link.get(field) is Vector3 or not link[field].is_finite(): return false
	_failure = ""
	return true

func capture(result: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	if _captured: return _finish("failed", {}, "capture_already_consumed", started)
	_captured = true
	if not _failure.is_empty(): return _finish("failed", {}, _failure, started)
	if String(result.get("publicationStatus", "ready")) != "ready":
		return _finish("failed", {}, "navigation_source_not_ready", started)
	if not result.get("worldSeed") is String or result.worldSeed.strip_edges().is_empty():
		return _finish("failed", {}, "invalid_worldSeed", started)
	for field: String in ["tileKey", "sourceKey"]:
		if not result.get(field) is String or result[field].is_empty():
			return _finish("failed", {}, "invalid_" + field, started)
	var snapshot := {
		"worldSeed": result.worldSeed,
		"tileKey": result.tileKey,
		"sourceKey": result.sourceKey,
		"regionId": result.get("regionId", "region:chunk:" + result.tileKey),
		"sourceRevision": result.get("sourceRevision", result.get("topologyRevision", 1)),
		"semanticRevision": result.get("semanticRevision", 0),
		"unloaded": result.get("unloaded", false)
	}
	if not snapshot.regionId is String or snapshot.regionId.is_empty() or not snapshot.unloaded is bool:
		return _finish("failed", {}, "invalid_navigation_source_header", started)
	for field: String in ["sourceRevision", "semanticRevision"]:
		if not snapshot[field] is int or snapshot[field] < 0:
			return _finish("failed", {}, "invalid_" + field, started)
	if not snapshot.unloaded and not (result.get("surfaces") is Array or result.get("buildingSurfaces") is Array):
		return _finish("failed", {}, "missing_navigation_surface_source", started)
	for field: String in ARRAY_FIELDS:
		var records = result.get(field, [])
		if not records is Array:
			return _finish("failed", {}, "invalid_" + field, started)
		var prepared_list := false
		if field in ["buildingSurfaces", "crossingLinks"]:
			for admitted in _prepared_fact_lists:
				if is_same(records, admitted):
					prepared_list = true
					break
		if not prepared_list:
			for record in records:
				if not record is Dictionary:
					return _finish("failed", {}, "invalid_" + field + "_record", started)
			if not _seal_owned_value(records):
				return _finish("failed", {}, "invalid_" + field + ":" + _failure, started)
		snapshot[field] = records
	snapshot.make_read_only()
	_sealed_containers += 1
	return _finish("prepared", snapshot, "", started)

func _seal_owned_value(value: Variant, depth := 0) -> bool:
	_visited_values += 1
	var kind := typeof(value)
	if _capture_mode == "filter_input" and kind == TYPE_DICTIONARY:
		for retained in _filter_tiles:
			if is_same(value,retained): return true
	if kind <= TYPE_NODE_PATH:
		if kind == TYPE_FLOAT and not is_finite(value):
			_failure = "nonfinite_value"
			return false
		return true
	if (kind != TYPE_ARRAY and kind != TYPE_DICTIONARY) or depth >= MAX_DEPTH:
		_failure = "unsupported_value_or_cyclic_graph"
		return false
	if kind == TYPE_DICTIONARY:
		if value.get_typed_key_builtin() > TYPE_NODE_PATH or not _container_type_supported(value.get_typed_value_builtin()):
			_failure = "unsupported_dictionary_type"
			return false
		for key in value:
			if typeof(key) > TYPE_NODE_PATH:
				_failure = "unsupported_dictionary_key"
				return false
			if not _seal_owned_value(value[key], depth + 1): return false
	else:
		if not _container_type_supported(value.get_typed_builtin()):
			_failure = "unsupported_array_type"
			return false
		for item in value:
			if not _seal_owned_value(item, depth + 1): return false
	value.make_read_only()
	_sealed_containers += 1
	return true

static func _container_type_supported(kind: int) -> bool:
	return kind <= TYPE_NODE_PATH or kind == TYPE_ARRAY or kind == TYPE_DICTIONARY

func _finish(status: String, snapshot: Dictionary, reason: String, started: int) -> Dictionary:
	var profile := {
		"sourceKind": "generated_navigation_tile", "captureVersion": 2 if _capture_mode == "filter_input" else 1,
		"captureMode": _capture_mode,
		"worldSeed": snapshot.get("worldSeed", ""),
		"captureUsec": Time.get_ticks_usec() - started + _prepared_list_usec,
		"preparedListSealUsec": _prepared_list_usec,
		"retainedPreparedFactCount": _prepared_fact_count,
		"visitedValueCount": _visited_values, "sealedContainerCount": _sealed_containers,
		"captureThreadId": OS.get_thread_caller_id()
	}
	profile.make_read_only()
	var envelope := {"status": status, "profile": profile}
	if status == "prepared": envelope["snapshot"] = snapshot
	else: envelope["reason"] = reason
	envelope.make_read_only()
	return envelope
