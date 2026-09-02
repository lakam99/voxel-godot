extends SceneTree
## Synthetic graph/patch contracts plus one actual frozen source-only load.
## No publication, camera, visibility, physics or gameplay acceptance.
const Assembly = preload("res://scripts/testing/buildings/CitadelAssemblyReviewPlan.gd")
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const MAX_MSEC := 80000
var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	_checks[label] = passed

func _record(id: String, position: Vector3, size: Vector3, seat_ids: Array = []) -> Dictionary:
	var facts: Array = []
	for seat_id in seat_ids:
		facts.append(Seats.world_down_seat_fact(seat_id, Vector3(0, -size.y * 0.5, 0), Vector2(0.05, 0.05)))
	return {"id": id, "kind": "beam", "semantic": "facade_bearing_frame", "material": "timber_beam",
		"position": position, "size": size, "rotation": Vector3.ZERO,
		"recipe": {"physicalRequiredSeatPartIds": seat_ids.duplicate(), "physicalRequiredSeatFacts": facts}}

func _fixture() -> Dictionary:
	var panel: Dictionary = _record("panel", Vector3(0, 3, 0), Vector3(3, 1, 0.4), ["cap"])
	panel.semantic = "citadel_urban_facade"
	panel.material = "timber_board"
	var records: Array = [panel,
		_record("cap", Vector3(0, 2.375, 0), Vector3(4, 0.25, 0.6), ["leg_a", "leg_b"]),
		_record("leg_a", Vector3(-1.25, 1.125, 0), Vector3(0.3, 2.25, 0.3)),
		_record("leg_b", Vector3(1.25, 1.125, 0), Vector3(0.3, 2.25, 0.3)),
		{"id": "unrelated", "rotation": Vector3(0.2, 0.7, 0.1)}]
	return {"snapshot": {"parts": records}, "group": {"id": "synthetic",
		"partIds": ["leg_b", "cap", "leg_a"], "servedIds": ["panel"], "bounds": AABB(Vector3(-2, 0, -1), Vector3(4, 4, 2))}}

func _call(label: String, data: Dictionary) -> Dictionary:
	var before: PackedByteArray = var_to_bytes(data)
	var result: Dictionary = Assembly.build(data.snapshot, data.group)
	_check(label + "_immutable", before == var_to_bytes(data))
	return result

func _synthetic() -> void:
	var data: Dictionary = _fixture()
	var good: Dictionary = _call("readable_source_graph", data)
	_check("three_pairs_four_targets", good.ready and good.pairs.size() == 3 and good.targets == ["cap", "leg_a", "leg_b", "panel"])
	if good.ready:
		var pair: Dictionary = good.pairs[0]
		_check("full_contact_not_fact_crop", pair.contactBounds.position.x == -1.5 and pair.contactBounds.end.x == 1.5 and pair.contactBounds.size.x > pair.seatFact.localPatchHalfExtents.x * 2)
		_check("thickness_derived_window", pair.reviewBounds == pair.contactBounds.grow(pair.memberThickness))
		_check("both_participants_retained", pair.patches.size() == 2 and pair.patches[0].partId == "panel" and pair.patches[1].partId == "cap")
		_check("lower_panel_and_sill_window", pair.patches[0].bounds.position.y == 2.5 and pair.patches[1].bounds.size.y == 0.25)
		_check("source_fact_exact", var_to_bytes(pair.seatFact) == var_to_bytes(data.snapshot.parts[0].recipe.physicalRequiredSeatFacts[0]))
		var altered_result: Dictionary = Assembly.build(data.snapshot, data.group)
		altered_result.pairs[0].seatFact.seatId = "changed"
		_check("returned_facts_not_aliased", data.snapshot.parts[0].recipe.physicalRequiredSeatFacts[0].seatId == "cap")
	var reversed: Dictionary = data.duplicate(true)
	reversed.snapshot.parts.reverse()
	reversed.group.partIds.reverse()
	reversed.snapshot.parts[3].recipe.physicalRequiredSeatPartIds.reverse()
	reversed.snapshot.parts[3].recipe.physicalRequiredSeatFacts.reverse()
	_check("reverse_order_exact", var_to_bytes(good) == var_to_bytes(_call("reverse", reversed)))
	for mode in ["duplicate_source", "duplicate_member", "missing_member", "duplicate_seat", "missing_fact", "duplicate_fact", "foreign_fact", "foreign_sill", "foreign_post", "self_cycle", "cross_role_cycle", "wrong_sill", "wrong_post", "nan_selected", "tilted_selected", "negative_size", "nonoverlap", "malformed_refs", "nonfinite_fact", "mixed_fact", "bad_group_bounds"]:
		var bad: Dictionary = data.duplicate(true)
		match mode:
			"duplicate_source": bad.snapshot.parts.append(bad.snapshot.parts[0])
			"duplicate_member": bad.group.partIds.append("cap")
			"missing_member": bad.group.partIds.append("absent")
			"duplicate_seat": bad.snapshot.parts[1].recipe.physicalRequiredSeatPartIds = ["leg_a", "leg_a"]
			"missing_fact": bad.snapshot.parts[0].recipe.physicalRequiredSeatFacts = []
			"duplicate_fact": bad.snapshot.parts[1].recipe.physicalRequiredSeatFacts[1] = bad.snapshot.parts[1].recipe.physicalRequiredSeatFacts[0].duplicate(true)
			"foreign_fact": bad.snapshot.parts[0].recipe.physicalRequiredSeatFacts[0].seatId = "unrelated"
			"foreign_sill": bad.group.partIds.erase("cap")
			"foreign_post": bad.group.partIds.erase("leg_a")
			"self_cycle":
				bad.snapshot.parts[1].recipe.physicalRequiredSeatPartIds[0] = "cap"
				bad.snapshot.parts[1].recipe.physicalRequiredSeatFacts[0].seatId = "cap"
			"cross_role_cycle":
				var extra: Dictionary = bad.snapshot.parts[0].duplicate(true)
				extra.id = "panel_b"
				extra.recipe.physicalRequiredSeatPartIds = ["leg_a"]
				extra.recipe.physicalRequiredSeatFacts[0].seatId = "leg_a"
				bad.snapshot.parts.append(extra)
				bad.group.servedIds.append("panel_b")
				bad.snapshot.parts[2].recipe = bad.snapshot.parts[0].recipe.duplicate(true)
			"wrong_sill": bad.snapshot.parts[1].material = "stone_foundation"
			"wrong_post": bad.snapshot.parts[2].kind = "roof"
			"nan_selected": bad.snapshot.parts[0].position.x = NAN
			"tilted_selected": bad.snapshot.parts[2].rotation.z = 0.2
			"negative_size": bad.snapshot.parts[0].size.x = -1
			"nonoverlap": bad.snapshot.parts[0].position.x = 30
			"malformed_refs": bad.snapshot.parts[0].recipe.physicalRequiredSeatPartIds = "cap"
			"nonfinite_fact": bad.snapshot.parts[0].recipe.physicalRequiredSeatFacts[0].localPatchCenter.x = NAN
			"mixed_fact": bad.snapshot.parts[0].recipe.physicalRequiredSeatFacts[0].contactMode = "housed_overlap"
			"bad_group_bounds": bad.group.bounds = AABB()
		var rejected: Dictionary = _call(mode, bad)
		_check(mode + "_rejected_atomic", not rejected.ready and rejected.pairs.is_empty() and rejected.targets.is_empty())
	_check("repeat_exact", var_to_bytes(good) == var_to_bytes(_call("repeat", data)))
	var terminal: Dictionary = data.duplicate(true)
	terminal.snapshot.parts[2].recipe.physicalRequiredSeatPartIds = ["outside_untraversed_root_scope"]
	_check("only_two_seat_layers", _call("terminal_post_not_root_certified", terminal).ready)
	var capped: Dictionary = data.duplicate(true)
	capped.group.partIds.resize(Assembly.MAX_GROUP_PARTS + 1)
	_check("group_array_cap", not _call("group_cap", capped).ready)

func _actual() -> Dictionary:
	var loaded: Dictionary = Plan.load_review()
	var report: Dictionary = {"executed": true, "evidence": "actual_frozen_recipe_plan_only", "ready": loaded.get("ready", false), "reason": loaded.get("reason", ""), "groups": [], "day02Records": []}
	_check("actual_load_review_ready", report.ready)
	if not report.ready: return report
	var snapshot: Dictionary = loaded.blueprint.snapshot()
	var before: String = Plan.digest([snapshot, loaded.groups, loaded.furniture.snapshot()])
	var all_ready: bool = true
	for group in loaded.groups:
		var planned: Dictionary = Assembly.build(snapshot, group)
		report.groups.append({"id": group.id, "plan": planned})
		all_ready = all_ready and bool(planned.ready)
		if group.id == "frame_02":
			var diagnostic_ids: Array = group.partIds + group.servedIds
			for record in snapshot.parts:
				if diagnostic_ids.has(record.id):
					report.day02Records.append({"id": record.id, "kind": record.kind, "semantic": record.semantic,
						"material": record.material, "size": record.size, "position": record.position, "rotation": record.rotation})
	_check("actual_all_four_groups_planned", loaded.groups.size() == 4 and all_ready)
	_check("actual_day02_diagnostics_present", not report.day02Records.is_empty())
	_check("actual_snapshots_and_arrays_exact", before == Plan.digest([snapshot, loaded.groups, loaded.furniture.snapshot()]) and Plan.digest(loaded.blueprint.snapshot()) == loaded.sourceDigest)
	_check("actual_furniture_count", loaded.furniture.parts.size() == 152)
	_check("actual_bound_inputs_current", Plan.inputs_current(loaded.identity))
	report.ready = all_ready
	report.sourceDigest = loaded.sourceDigest
	report.bindings = loaded.bindings
	report.furnitureCount = loaded.furniture.parts.size()
	return report

func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Vector2: return [value.x, value.y]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Array:
		var array: Array = []
		for item in value: array.append(_json(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key in value: dictionary[key] = _json(value[key])
		return dictionary
	return value

func _run() -> void:
	var path: String = OS.get_environment("VOXEL_ASSEMBLY_REVIEW_PLAN_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started: int = Time.get_ticks_msec()
	var helper_sha: String = FileAccess.get_sha256("res://scripts/testing/buildings/CitadelAssemblyReviewPlan.gd")
	_synthetic()
	var mode: String = OS.get_environment("VOXEL_ASSEMBLY_REVIEW_PLAN_ACTUAL")
	_check("actual_mode_valid", mode in ["", "0", "1"])
	var actual: Dictionary = _actual() if mode in ["", "1"] else {"executed": false, "ready": false, "reason": "explicit_synthetic_only"}
	_check("helper_unchanged", FileAccess.get_sha256("res://scripts/testing/buildings/CitadelAssemblyReviewPlan.gd") == helper_sha)
	_check("bounded_time", Time.get_ticks_msec() - started < MAX_MSEC)
	var passed: bool = not _checks.values().has(false)
	var report: Dictionary = {"passed": passed, "checkCount": _checks.size(), "checks": _checks, "syntheticEvidence": "graph_and_source_patch_rules_only",
		"actualRecipePlan": actual, "syntheticVisibilityExecuted": false, "helperSha256": helper_sha,
		"elapsedMsec": Time.get_ticks_msec() - started, "doesNotProve": "No publication, exposure, renderer, bearing certification or gameplay acceptance."}
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	var complete: bool = passed and written and Time.get_ticks_msec() - started < MAX_MSEC
	print(JSON.stringify({"passed": complete, "checkCount": _checks.size(), "report": path}))
	quit(0 if complete else 2)
