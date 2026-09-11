extends RefCounted
class_name NavigationPublicationSource

## Capture owned producer output, not arbitrary scene snapshots. Only the fields
## consumed by NavigationBakeDescriptor plus world identity cross the worker boundary. Geometry and
## source revision decisions remain with GeneratedWorldNavigationAdapter.
const ARRAY_FIELDS := ["surfaces", "semanticRegions", "doorPortals", "doorLinks", "buildingSurfaces", "crossingLinks"]
const MAX_DEPTH := 32
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
		"sourceKind": "generated_navigation_tile", "captureVersion": 1,
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
