extends SceneTree

## Synthetic graph/source-service evidence only; no publication or visibility.
## Actual frozen load_review runs once by default. Set
## VOXEL_FACADE_VISUAL_PLAN_ACTUAL=0 for explicitly synthetic-only checks.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const MAX_MSEC := 80000
var checks: Array = []
var cases: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _run() -> void:
	var output: String = OS.get_environment("VOXEL_FACADE_VISUAL_PLAN_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var started: int = Time.get_ticks_msec()
	var helper_sha: String = FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
	_synthetic()
	var mapping: Dictionary = Plan.DependencyMap.proof()
	_check("exact_camera_only_projection", mapping.get("ready", false) and mapping.get("projectedWholeFileSha256") == Plan.DependencyMap.OLD)
	_check("mapped_expected_revision_admitted", Plan.DependencyMap.accepts(Plan.DependencyMap.PATH, Plan.DependencyMap.OLD, Plan.DependencyMap.NEW))
	_check("unknown_new_revision_rejected", not Plan.DependencyMap.accepts(Plan.DependencyMap.PATH, Plan.DependencyMap.OLD, "0".repeat(64)))
	_check("unknown_recorded_revision_rejected", not Plan.DependencyMap.accepts(Plan.DependencyMap.PATH, "0".repeat(64), Plan.DependencyMap.NEW))
	_check("different_dependency_not_exempt", not Plan.DependencyMap.accepts("res://scripts/buildings/BuildingPartPublisher.gd", Plan.DependencyMap.OLD, Plan.DependencyMap.NEW))
	var actual_mode: String = OS.get_environment("VOXEL_FACADE_VISUAL_PLAN_ACTUAL")
	_check("actual_mode_valid", actual_mode in ["", "0", "1"])
	var actual: Dictionary = {"executed": false, "ready": false, "reason": "explicit_synthetic_only"}
	if actual_mode in ["", "1"]: actual = _actual()
	_check("helper_unchanged", FileAccess.get_sha256("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd") == helper_sha)
	_check("bounded_elapsed", Time.get_ticks_msec() - started < MAX_MSEC)
	var passed: bool = checks.all(func(row): return row.passed)
	var report: Dictionary = {"passed": passed, "checks": checks, "checkCount": checks.size(), "syntheticCases": cases, "actual": actual,
		"dependencyMapping": mapping,
		"helperSha256": helper_sha, "contractSha256": FileAccess.get_sha256(get_script().resource_path),
		"elapsedMsec": Time.get_ticks_msec() - started, "evidenceLevel": "synthetic_graph_and_optional_actual_frozen_source_service",
		"doesNotProve": "No renderer, physics, camera visibility, visual readiness or gameplay acceptance."}
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written and Time.get_ticks_msec() - started < MAX_MSEC else 2)

func _record(id: String, position: Vector3, size: Vector3, material: String = "timber_beam", seats: Array = []) -> Dictionary:
	return {"id": id, "kind": "beam", "material": material, "position": position, "rotation": Vector3.ZERO, "size": size,
		"collision": true, "semantic": "synthetic_review_member", "physicalIntent": "structural_mass",
		"recipe": {"physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": seats.duplicate()}}

func _fixture() -> Dictionary:
	var records: Array = [_record("ground", Vector3(2, 0.25, 0), Vector3(8, 0.5, 4), "stone_foundation")]
	records[0].kind = "foundation"
	var added: Array = []
	var served: Array = []
	for index in range(2):
		var prefix: String = "group_%d_" % index
		var x: float = index * 4.0
		records.append(_record(prefix + "foot", Vector3(x, 0.75, 0), Vector3(0.5, 0.5, 0.5), "stone_foundation", ["ground"]))
		records.append(_record(prefix + "post", Vector3(x, 1.75, 0), Vector3(0.25, 1.5, 0.25), "timber_beam", [prefix + "foot"]))
		records.append(_record(prefix + "sill", Vector3(x, 2.625, 0), Vector3(0.25, 0.25, 1), "timber_beam", [prefix + "post"]))
		records.append(_record(prefix + "panel", Vector3(x, 3.25, 0), Vector3(0.25, 1, 1), "timber_board", [prefix + "sill"]))
		added.append_array([prefix + "foot", prefix + "post", prefix + "sill"])
		served.append(prefix + "panel")
	# Two real source records reference both feet: exposes accidental dependence
	# on record traversal order without inventing a second grouping algorithm.
	for id in ["finish_a", "finish_b"]:
		var finish: Dictionary = _record(id, Vector3(2, 0.55, 0), Vector3(8, 0.1, 4), "cobblestone")
		finish.kind = "foundation"
		finish.collision = false
		finish.recipe.pavingFootingJoints = {"footPartIds": ["group_0_foot", "group_1_foot"]}
		records.append(finish)
	return {"snapshot": {"parts": records}, "newIds": added, "servedIds": served}

func _part(fixture: Dictionary, id: String) -> Dictionary:
	for record in fixture.snapshot.parts:
		if record.id == id: return record
	return {}

func _call(label: String, fixture: Dictionary) -> Dictionary:
	var before: PackedByteArray = var_to_bytes(fixture)
	var result: Dictionary = Plan.build_groups(fixture.snapshot, fixture.newIds, fixture.servedIds)
	_check(label + ":source_and_input_arrays_unchanged", before == var_to_bytes(fixture))
	cases.append({"label": label, "ready": result.get("ready", false), "reason": result.get("reason", "")})
	return result

func _synthetic() -> void:
	var fixture: Dictionary = _fixture()
	var good: Dictionary = _call("synthetic_valid_graph", fixture)
	_check("synthetic_valid_graph_ready", good.get("ready", false))
	if good.get("ready", false):
		_check("synthetic_exact_coverage", good.groups.size() == 2 and good.footCount == 2 and good.coveredNewCount == 6 and good.coveredServedCount == 2)
		var repeat: Dictionary = _call("repeat", fixture)
		_check("repeat_exact", var_to_bytes(good) == var_to_bytes(repeat))
		var reversed: Dictionary = fixture.duplicate(true)
		reversed.snapshot.parts.reverse()
		reversed.newIds.reverse()
		reversed.servedIds.reverse()
		var ordered: Dictionary = _call("reverse_all_source_order", reversed)
		_check("stable_order_exact", var_to_bytes(good) == var_to_bytes(ordered))
	for mode in ["missing_new", "duplicate_new", "duplicate_served", "duplicate_record", "missing_reference", "duplicate_reference", "orphan", "invalid_foot_kind", "noncollision_foot", "missing_foot_support", "nan_position"]:
		var bad: Dictionary = fixture.duplicate(true)
		match mode:
			"missing_new": bad.newIds.append("absent")
			"duplicate_new": bad.newIds.append(bad.newIds[0])
			"duplicate_served": bad.servedIds.append(bad.servedIds[0])
			"duplicate_record": bad.snapshot.parts.append(bad.snapshot.parts[0].duplicate(true))
			"missing_reference": _part(bad, "group_0_post").recipe.physicalRequiredSeatPartIds = ["absent"]
			"duplicate_reference": _part(bad, "group_0_post").recipe.physicalRequiredSeatPartIds = ["group_0_foot", "group_0_foot"]
			"orphan":
				bad.snapshot.parts.append(_record("orphan", Vector3(8, 1, 0), Vector3.ONE))
				bad.newIds.append("orphan")
			"invalid_foot_kind": _part(bad, "group_0_foot").kind = "roof"
			"noncollision_foot": _part(bad, "group_0_foot").collision = false
			"missing_foot_support": _part(bad, "group_0_foot").recipe.physicalRequiredSeatPartIds = []
			"nan_position": _part(bad, "group_0_foot").position = Vector3(NAN, 0.75, 0)
		var result: Dictionary = _call(mode, bad)
		_check(mode + ":rejected", not result.get("ready", false))
	# Both declared-reference channels have the same bounded Array[String]
	# schema. These must reject before traversal, without a script error.
	for key in ["physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]:
		for malformed in ["group_0_foot", [""], [null], [7], ["group_0_foot", "group_0_foot"]]:
			var bad: Dictionary = fixture.duplicate(true)
			_part(bad, "group_0_post").recipe[key] = malformed
			var label: String = key + ":malformed_" + str(cases.size())
			var rejected: Dictionary = _call(label, bad)
			_check(label + ":reference_schema", not rejected.get("ready", false) and rejected.get("reason") == "reference_schema")
	var oversized: Dictionary = fixture.duplicate(true)
	var too_many: Array = []
	for index in range(Plan.MAX_NEW + 1): too_many.append("reference_%d" % index)
	_part(oversized, "group_0_post").recipe.physicalRequiredAnchorPartIds = too_many
	var limited: Dictionary = _call("reference_array_limit", oversized)
	_check("reference_array_limit:reference_schema", not limited.get("ready", false) and limited.get("reason") == "reference_schema")
	var unresolved: Dictionary = fixture.duplicate(true)
	_part(unresolved, "group_0_panel").recipe.physicalRequiredSeatPartIds.append("missing_external_support")
	var missing: Dictionary = _call("served_missing_external_reference", unresolved)
	_check("served_missing_external_reference:rejected", not missing.get("ready", false) and missing.get("reason") == "unresolved_reference")

func _actual() -> Dictionary:
	var source: Dictionary = Plan.read_input("candidate")
	_check("actual_bound_candidate_loaded", not source.is_empty())
	var before: String = Plan.digest(source)
	var result: Dictionary = Plan.load_review()
	var summary: Dictionary = {"executed": true, "ready": result.get("ready", false), "reason": result.get("reason", "")}
	_check("actual_load_review_ready", summary.ready)
	_check("actual_source_archive_unchanged", before == Plan.digest(source) and before == Plan.digest(Plan.read_input("candidate")))
	if not summary.ready: return summary
	var ids: Array = []
	var panels: Array = []
	var feet: Array = []
	for group in result.groups:
		ids.append_array(group.partIds)
		panels.append_array(group.servedIds)
		for foot in group.footInterfaces: feet.append(foot.footId)
	ids.sort()
	panels.sort()
	var expected_ids: Array = source.partIds.duplicate()
	var expected_panels: Array = source.memberIds.duplicate()
	expected_ids.sort()
	expected_panels.sort()
	var unique_feet: Dictionary = {}
	for id in feet: unique_feet[id] = true
	_check("actual_four_groups", result.groups.size() == 4)
	_check("actual_sixteen_complete_members", ids.size() == 16 and ids == expected_ids)
	_check("actual_five_complete_panels", panels.size() == 5 and panels == expected_panels)
	_check("actual_five_distinct_feet", feet.size() == 5 and unique_feet.size() == 5 and result.footCount == 5)
	_check("actual_source_copy_exact", var_to_bytes(result.blueprint.snapshot()) == var_to_bytes(source.afterSnapshot))
	_check("actual_152_furniture_exact", result.furniture.parts.size() == 152 and var_to_bytes(result.furniture.snapshot()) == var_to_bytes(source.furnitureSnapshot))
	_check("actual_reservations_exact", var_to_bytes(result.furniture.protected_access_reservations) == var_to_bytes(source.protectedReservations))
	_check("actual_bound_inputs_still_current", Plan.inputs_current(result.identity))
	summary.merge({"groupCount": result.groups.size(), "memberCount": ids.size(), "panelCount": panels.size(), "footCount": feet.size(), "furnitureCount": result.furniture.parts.size()})
	return summary
