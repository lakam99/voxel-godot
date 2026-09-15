extends SceneTree

## Source-level contract for the citadel exterior-ground policy.
## This deliberately does not exercise or alter production routing.
## VOXEL_PROCESSIONAL_SUPPORT_REPORT: fresh absolute JSON; parent must exist.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Landmark = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
var _checks: Array = []
var _audits: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_PROCESSIONAL_SUPPORT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	for case in [
		{"label": "minimum_width_right", "gateWidth": 12.0, "routeSign": 1.0},
		{"label": "interior_width_left", "gateWidth": 17.0, "routeSign": -1.0},
		{"label": "maximum_width_right", "gateWidth": 24.0, "routeSign": 1.0}
	]:
		_audit_sampled_ground_policy(case as Dictionary)
	_audit_terrace_publisher_noop()
	_audit_full_compound()
	var passed: bool = not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {
		"fixture": "CitadelProcessionalSupportContract",
		"passed": passed,
		"checks": _checks,
		"audits": _audits,
		"evidenceLevel": "actual_producer_source_geometry_contract",
		"doesNotProve": "No published scene, terrain conformity, live collision, routing, navigation or gameplay acceptance."
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Citadel exterior-ground source contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))


func _audit_sampled_ground_policy(case: Dictionary) -> void:
	var palace := {"entryApproach": {"routeTerminalZ": 18.0, "rampStartZ": 14.0}}
	var grid: Dictionary = Landmark.castle_courtyard_occupancy_lattice(96.0, 104.0, 30.0, 24.0, 0.18, float(case.gateWidth), 13.0, true, float(case.routeSign), palace)
	var repeated: Dictionary = Landmark.castle_courtyard_occupancy_lattice(96.0, 104.0, 30.0, 24.0, 0.18, float(case.gateWidth), 13.0, true, float(case.routeSign), palace)
	var label := String(case.label)
	var lot_pairs: Array = grid.get("lotPairs", []) as Array
	var streets: Array = grid.get("streetRecords", []) as Array
	var transitions: Array = grid.get("processionalTransitions", []) as Array
	var records: Dictionary = {}
	for value in streets:
		if value is Dictionary:
			var record: Dictionary = value as Dictionary
			records[String(record.get("id", ""))] = record
	var all_lots_at_ground := not lot_pairs.is_empty() and lot_pairs.all(func(pair): return pair is Dictionary and is_zero_approx(float((pair as Dictionary).get("terraceElevation", INF))))
	var all_streets_at_ground := not streets.is_empty() and streets.all(func(record): return record is Dictionary and is_zero_approx(float((record as Dictionary).get("elevation", INF))))
	var positive_street_extents := streets.all(func(record): return record is Dictionary and float((record as Dictionary).get("width", 0.0)) > 0.20 and float((record as Dictionary).get("depth", 0.0)) > 0.20)
	var continuous := is_equal_approx(_street_end(records, "processional_00_gate_lane"), float(grid.get("firstTurnZ", INF))) \
		and is_equal_approx(_street_start(records, "processional_02a_civic_approach"), float(grid.get("firstTurnZ", -INF))) \
		and is_equal_approx(_street_end(records, "processional_02a_civic_approach"), _street_start(records, "processional_02b_civic_climb")) \
		and is_equal_approx(_street_end(records, "processional_02b_civic_climb"), float(grid.get("finalTurnZ", INF))) \
		and is_equal_approx(_street_start(records, "processional_04a_palace_approach"), float(grid.get("finalTurnZ", -INF))) \
		and is_equal_approx(_street_end(records, "processional_04a_palace_approach"), _street_start(records, "processional_04b_palace_reveal")) \
		and is_equal_approx(_street_end(records, "processional_04b_palace_reveal"), _street_start(records, "processional_04c_palace_entry_transition"))
	_check(label + ":deterministic", var_to_bytes(grid) == var_to_bytes(repeated))
	_check(label + ":district_grid", String(grid.get("mode", "")) == "district_grid")
	_check(label + ":no_artificial_terrace_height", is_zero_approx(float(grid.get("terraceStepHeight", INF))))
	_check(label + ":no_exterior_processional_transitions", transitions.is_empty())
	_check(label + ":building_lots_do_not_request_terrace_elevation", all_lots_at_ground)
	_check(label + ":street_surfaces_share_ground_datum", all_streets_at_ground)
	_check(label + ":street_extents_are_positive", positive_street_extents)
	_check(label + ":retired_stair_spans_are_filled_by_ground_lanes", continuous)
	_audits.append({"label": label, "lotPairCount": lot_pairs.size(), "streetCount": streets.size(), "terraceStepHeight": grid.get("terraceStepHeight"), "transitionCount": transitions.size(), "continuousGroundLane": continuous})


func _audit_terrace_publisher_noop() -> void:
	var blueprint = Blueprint.new("terrace_noop", 208159, "stone")
	var grid := {"mode": "district_grid", "rowCenters": [-20.0, 0.0, 20.0], "terraceStepHeight": 0.0, "processionalTransitions": [], "streetRecords": []}
	var before := var_to_bytes(blueprint.snapshot())
	Castle.add_citadel_terraces(blueprint, {"courtyardGrid": grid}, 96.0, 104.0, 0.62, 0.0)
	_check("zero_height_terrace_publisher_emits_nothing", before == var_to_bytes(blueprint.snapshot()))


func _audit_full_compound() -> void:
	var blueprint = Castle.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25})
	_check("full_compound_exists", blueprint != null)
	if blueprint == null:
		return
	var forbidden: Array = blueprint.parts.filter(func(part):
		var id := String(part.id)
		var semantic := String(part.semantic)
		return id.begins_with("castle_terrace_block_") or id.begins_with("castle_terrace_stair_") \
			or semantic in ["castle_inhabited_terrace_block", "castle_terrace_route_wall", "castle_processional_step"])
	var foundations: Array = blueprint.parts.filter(func(part): return String(part.semantic) in ["castle_residence_foundation", "castle_keep_foundation", "castle_gatehouse_foundation", "castle_keep_palace_entry_forecourt_root"])
	var forecourt = _find(blueprint, "castle_keep_palace_entry_forecourt")
	var forecourt_root = _find(blueprint, "castle_keep_palace_entry_forecourt_root")
	var ground_surfaces: Array = blueprint.parts.filter(func(part): return String(part.semantic) in ["castle_route_terrace_walkway", "castle_route_junction"])
	var surface_tops: Array[float] = []
	for part in ground_surfaces:
		surface_tops.append(snappedf(float(part.position.y) + float(part.size.y) * 0.5, 0.0001))
	var one_ground_datum := not surface_tops.is_empty() and surface_tops.all(func(top): return is_equal_approx(float(top), surface_tops[0]))
	_check("full_compound_has_no_exterior_terrace_or_processional_stair_parts", forbidden.is_empty(), forbidden.map(func(part): return String(part.id)))
	_check("full_compound_preserves_real_structure_foundations", not foundations.is_empty())
	_check("full_compound_preserves_keep_entry_foundation", forecourt != null and forecourt_root != null and forecourt.collision_enabled and forecourt_root.collision_enabled)
	_check("full_compound_street_and_junction_surfaces_share_one_datum", one_ground_datum, surface_tops)
	_audits.append({"label": "full_compound", "partCount": blueprint.parts.size(), "forbiddenPartIds": forbidden.map(func(part): return String(part.id)), "structureFoundationCount": foundations.size(), "groundSurfaceCount": ground_surfaces.size(), "groundSurfaceTops": surface_tops})


func _street_start(records: Dictionary, id: String) -> float:
	var record: Dictionary = records.get(id, {}) as Dictionary
	return float(record.get("z", INF)) - float(record.get("depth", 0.0)) * 0.5


func _street_end(records: Dictionary, id: String) -> float:
	var record: Dictionary = records.get(id, {}) as Dictionary
	return float(record.get("z", -INF)) + float(record.get("depth", 0.0)) * 0.5


func _find(blueprint, id: String):
	for part in blueprint.parts:
		if String(part.id) == id:
			return part
	return null


func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": label, "passed": passed, "detail": detail})


static func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [_json(value.x), _json(value.y), _json(value.z)]
	if value is Vector2:
		return [_json(value.x), _json(value.y)]
	if value is AABB:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value):
		return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
