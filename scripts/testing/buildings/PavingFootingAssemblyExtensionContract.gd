extends SceneTree

## Synthetic recipe transaction evidence only. No rendered/gameplay acceptance.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Assembly = preload("res://scripts/buildings/PavingFootingAssemblyRecipe.gd")
var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _copy(snapshot: Dictionary):
	var b = Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.recipe = snapshot.recipe.duplicate(true)
	b.rooms = snapshot.rooms.duplicate(true)
	for record in snapshot.parts:
		var part = b.add_part(record)
		part.physical_intent = record.physicalIntent
	return b

func _part(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

func _foot(id: String, x: float):
	return Part.new({"id": id, "kind": "beam", "material": "stone_foundation", "collision": true,
		"position": Vector3(x, 0.25, 0), "size": Vector3(0.25, 0.5, 0.25)})

func _finish(b, id: String, x: float):
	return b.add_part({"id": id, "kind": "foundation", "material": "cobblestone", "collision": false,
		"position": Vector3(x, 0.0625, 0), "size": Vector3(4, 0.125, 4), "recipe": {"pavingFamily": "civic_setts"}})

func _attempt(label: String, b, request: Dictionary, expected: bool, joint := 0.01) -> Dictionary:
	var before := var_to_bytes(b.snapshot())
	var proposed: Array = []
	for value in request.values():
		if value is Array:
			for foot in value:
				if foot is Part: proposed.append([foot, var_to_bytes(foot.snapshot())])
	var result: Dictionary = Assembly.prepare_extension(b, request, joint)
	checks.append({"label": label, "passed": bool(result.get("ready", false)) == expected,
		"actualReady": result.get("ready", false), "actualReason": result.get("reason", "")})
	_check(label + "_source_unchanged", before == var_to_bytes(b.snapshot()))
	_check(label + "_proposals_unchanged", proposed.all(func(row): return row[1] == var_to_bytes(row[0].snapshot())))
	return result

func _commit(b, result: Dictionary, feet: Array) -> void:
	for foot in feet:
		if _part(b, foot.id) == null: b.add_part(foot.snapshot())
	for id in result.joints: _part(b, id).recipe["pavingFootingJoints"] = result.joints[id].duplicate(true)

func _replay(b, label: String) -> void:
	for finish in b.parts:
		if not finish.recipe.has("pavingFootingJoints"): continue
		var declaration: Dictionary = finish.recipe.pavingFootingJoints
		var feet: Array = []
		var boxes: Array[AABB] = []
		for id in declaration.footPartIds:
			var foot = _part(b, id)
			feet.append(foot)
			boxes.append(AABB(foot.position - foot.size * 0.5, foot.size))
		var replay: Dictionary = Assembly.prepare(b, [finish.id], feet, declaration.nominalJoint)
		_check(label + "_" + finish.id + "_ready", replay.ready)
		if not replay.ready: continue
		_check(label + "_" + finish.id + "_exact_joint", var_to_bytes(replay.joints[finish.id]) == var_to_bytes(declaration))
		var clear: Dictionary = Assembly.Artifact.clear_of_boxes(replay.artifacts[finish.id], boxes)
		_check(label + "_" + finish.id + "_all_feet_clear", clear.completed and clear.get("clear", false))

func _run() -> void:
	var output := OS.get_environment("VOXEL_PAVING_EXTENSION_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var b = Blueprint.new("synthetic_extension", 41, "timber")
	b.recipe = {"sourceBlueprintId": "synthetic_extension_history"}
	_finish(b, "finish", 0.0)
	var a = _foot("a", -0.75)
	var c = _foot("c", 0.75)
	var fresh := _attempt("fresh", b, {"finish": [a]}, true)
	if fresh.ready:
		_commit(b, fresh, [a])
		var baseline: Dictionary = b.snapshot()
		var extended := _attempt("extend", b, {"finish": [c]}, true)
		if extended.ready:
			var one_shot: Dictionary = Assembly.prepare(b, ["finish"], [_part(b, "a"), c], 0.01)
			_check("union_equals_one_shot", one_shot.ready and var_to_bytes(one_shot.joints) == var_to_bytes(extended.joints))
			var committed = _copy(baseline)
			_commit(committed, extended, [c])
			_replay(committed, "committed_union")
			_check("retains_both_foot_ids", _part(committed, "finish").recipe.pavingFootingJoints.footPartIds == ["a", "c"])
		var d = _foot("d", 1.35)
		var ordered := _attempt("ordered_proposals", b, {"finish": [c, d]}, true)
		var reversed := _attempt("reversed_proposals", b, {"finish": [d, c]}, true)
		_check("proposal_order_deterministic", ordered.ready and reversed.ready and var_to_bytes(ordered.joints) == var_to_bytes(reversed.joints))
		for mode in ["moved_old_foot", "moved_finish", "history", "digest", "missing_old_foot", "malformed", "duplicate_old", "hidden_finish"]:
			var damaged = _copy(baseline)
			match mode:
				"moved_old_foot": _part(damaged, "a").position.x += 0.125
				"moved_finish": _part(damaged, "finish").position.x += 0.25
				"history": damaged.recipe.sourceBlueprintId = "different_history"
				"digest": _part(damaged, "finish").recipe.pavingFootingJoints.geometryDigest = "0".repeat(64)
				"missing_old_foot": damaged.parts.erase(_part(damaged, "a"))
				"malformed": _part(damaged, "finish").recipe.pavingFootingJoints = {"footPartIds": ["a"]}
				"duplicate_old": _part(damaged, "finish").recipe.pavingFootingJoints.footPartIds.append("a")
				"hidden_finish": _part(damaged, "finish").recipe.visual = false
			_attempt(mode, damaged, {"finish": [c]}, false)
		_attempt("joint_change", b, {"finish": [c]}, false, 0.02)
		_attempt("empty_request", b, {}, false)
		_attempt("empty_membership", b, {"finish": []}, false)
		_attempt("wrong_membership_type", b, {"finish": 7}, false)
		_attempt("missing_finish", b, {"missing": [c]}, false)
		_attempt("duplicate_proposal", b, {"finish": [c, c]}, false)
		_attempt("old_foot_reproposal", b, {"finish": [_part(b, "a")]}, false)
		_attempt("non_part_proposal", b, {"finish": [7]}, false)
		for mode in ["eave", "weathering", "declaration"]:
			var bad = _foot("bad", 0.75)
			match mode:
				"eave": bad.semantic = "roof_eave"
				"weathering": bad.recipe.weatheringEave = true
				"declaration": bad.recipe.pavingFootingJoints = {}
			_attempt("policy_" + mode, b, {"finish": [bad]}, false)
		var alias_source = _copy(baseline)
		alias_source.add_part(c.snapshot())
		_attempt("source_object_alias", alias_source, {"finish": [c]}, false)
		_attempt("existing_object", alias_source, {"finish": [_part(alias_source, "c")]}, true)
		var two = _copy(baseline)
		_finish(two, "second", 6.0)
		var remote = _foot("remote", 6.0)
		var two_before := var_to_bytes(_part(two, "finish").snapshot())
		var untouched := _attempt("untouched_prior_finish", two, {"second": [remote]}, true)
		if untouched.ready:
			_commit(two, untouched, [remote])
			_check("untouched_joint_exact", two_before == var_to_bytes(_part(two, "finish").snapshot()))
			_replay(two, "untouched_commit")
		var multi = _copy(baseline)
		_finish(multi, "second", 6.0)
		var disjoint := _attempt("per_finish_not_cartesian", multi, {"finish": [c], "second": [remote]}, true)
		var reordered := _attempt("reversed_finish_order", multi, {"second": [remote], "finish": [c]}, true)
		_check("finish_order_deterministic", disjoint.ready and reordered.ready and var_to_bytes(disjoint.joints) == var_to_bytes(reordered.joints))
		if disjoint.ready:
			_commit(multi, disjoint, [c, remote])
			_replay(multi, "multi_commit")
		var late = _copy(baseline)
		_finish(late, "second", 6.0)
		_attempt("late_prepare_failure_atomic", late, {"finish": [c], "second": [_foot("miss", 20.0)]}, false)
		var history_changed = _copy(baseline)
		history_changed.recipe.landscapeTrees = [{"id": "synthetic_history_tree", "position": Vector3.ZERO,
			"canopyRadius": 4.0, "rootButtressFootprints": [{"start": Vector3(-1, 0, 0), "end": Vector3(1, 0, 0), "radiusStart": 0.5, "radiusEnd": 0.3}]}]
		_attempt("changed_actual_history_events", history_changed, {"finish": [c]}, false)
		var shared = Blueprint.new("synthetic_shared", 41, "timber")
		_finish(shared, "first", 0.0)
		_finish(shared, "second", 0.0)
		var shared_foot = _foot("shared", 0.0)
		var sharing := _attempt("same_object_multiple_finishes", shared, {"first": [shared_foot], "second": [shared_foot]}, true)
		if sharing.ready:
			_commit(shared, sharing, [shared_foot])
			_replay(shared, "shared_commit")
		var aliases = Blueprint.new("synthetic_aliases", 41, "timber")
		_finish(aliases, "first", 0.0)
		_finish(aliases, "second", 0.0)
		_attempt("different_objects_same_id", aliases, {"first": [_foot("alias", 0.0)], "second": [_foot("alias", 0.0)]}, false)
		var cap = _copy(baseline)
		var request: Dictionary = {}
		for index in range(4):
			var id := "finish_%d" % index
			_finish(cap, id, float(index + 1) * 6.0)
			request[id] = [_foot("cap_%d" % index, float(index + 1) * 6.0)]
		_attempt("global_finish_cap", cap, request, false)
		var overflow = _copy(baseline)
		_finish(overflow, "second", 6.0)
		var left: Array = []
		var right: Array = []
		for index in range(8):
			left.append(_foot("left_%d" % index, 0.75))
			right.append(_foot("right_%d" % index, 6.0))
		_attempt("global_unique_foot_cap", overflow, {"finish": left, "second": right}, false)
		var full = _copy(baseline)
		for index in range(10000 - full.parts.size()): full.add_part(_foot("filler_%d" % index, 50.0).snapshot())
		_attempt("projected_source_cap", full, {"finish": [c]}, false)
	var passed := not checks.is_empty() and checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": checks, "checkCount": checks.size(), "elapsedMsec": Time.get_ticks_msec() - started,
		"assemblySha256": FileAccess.get_sha256("res://scripts/buildings/PavingFootingAssemblyRecipe.gd"),
		"contractSha256": FileAccess.get_sha256(get_script().resource_path), "evidenceLevel": "synthetic_recipe_transaction_and_committed_replay",
		"doesNotProve": "No live generator integration, rendering, collision traversal, furniture changes, navigation, runtime performance or physical gate-zero acceptance."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
