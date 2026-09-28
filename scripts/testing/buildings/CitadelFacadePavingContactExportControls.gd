extends "res://scripts/testing/buildings/CitadelFacadePavingContactExport.gd"

## Synthetic conversion controls only. No input artifacts or file writes.
var _sentinels: Array = []
var _entered_types: Array = []

func _json_value(value: Variant, depth: int) -> Variant:
	_entered_types.append(typeof(value))
	if value is String and value.begins_with("sentinel:"): _sentinels.append(value)
	return super._json_value(value, depth)

func _reset_control(visits: int = 0) -> void:
	_started = Time.get_ticks_msec()
	_failure = ""
	_visits = visits
	_sentinels = []
	_entered_types = []

func _run() -> void:
	var checks: Dictionary = {}
	_reset_control(MAX_VISITS - 1)
	_json_value([0, "sentinel:array"], 0)
	checks["array_sibling_unvisited_at_cap"] = _failure == "conversion_work_bound" and _visits == MAX_VISITS and _sentinels.is_empty() and _entered_types.size() == 2
	_reset_control(MAX_VISITS - 1)
	_json_value({"first": 0, "second": "sentinel:dictionary"}, 0)
	checks["dictionary_sibling_unvisited_at_cap"] = _failure == "conversion_work_bound" and _visits == MAX_VISITS and _sentinels.is_empty() and _entered_types.size() == 2
	_reset_control(MAX_VISITS - 2)
	_json_value([[0, "sentinel:inner"], "sentinel:outer"], 0)
	checks["all_parent_siblings_unvisited_at_cap"] = _failure == "conversion_work_bound" and _visits == MAX_VISITS and _sentinels.is_empty() and _entered_types.size() == 3
	_reset_control(MAX_VISITS - 2)
	_json_value(Transform3D.IDENTITY, 0)
	checks["transform_basis_unvisited_after_origin_exhaustion"] = _failure == "conversion_work_bound" and not _entered_types.has(TYPE_BASIS) and _entered_types.size() == 3
	_reset_control()
	_json_value([NAN, "sentinel:after_nonfinite"], 0)
	checks["sticky_failure_stops_array"] = _failure == "nonfinite_json_number" and _sentinels.is_empty() and _entered_types.size() == 2
	_reset_control()
	_json_value({"first": INF, "second": "sentinel:after_nonfinite"}, 0)
	checks["sticky_failure_stops_dictionary"] = _failure == "nonfinite_json_number" and _sentinels.is_empty() and _entered_types.size() == 2
	_reset_control()
	_started -= MAX_MSEC + 1
	_json_value(["sentinel:time"], 0)
	checks["time_budget_stops_before_children"] = _failure == "soft_time_limit" and _visits == 0 and _sentinels.is_empty() and _entered_types.size() == 1
	_reset_control()
	_failure = "existing_failure"
	_started -= MAX_MSEC + 1
	_json_value(["sentinel:latched"], 0)
	checks["failure_sticky_no_remaining_visits"] = _failure == "existing_failure" and _visits == 0 and _sentinels.is_empty() and _entered_types.size() == 1
	_reset_control()
	var result: Variant = _json_value({"point": Vector3(1.0, 2.0, 3.0), "values": [1, false, null]}, 0)
	checks["ordinary_values_preserved"] = _failure.is_empty() and result == {"point": [1.0, 2.0, 3.0], "values": [1, false, null]}
	var passed: bool = checks.values().all(func(value): return value == true)
	print(JSON.stringify({"passed": passed, "checks": checks, "evidenceLevel": "synthetic_converter_early_exit_controls_only"}))
	quit(0 if passed else 2)
