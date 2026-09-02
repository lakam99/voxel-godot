extends "res://scripts/testing/buildings/CitadelFacadeBearingFrameContract.gd"

## Synthetic two-bay transaction, not gameplay or rendered acceptance.
var checks: Array = []

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _run() -> void:
	var path := OS.get_environment("VOXEL_SHARED_PAVING_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var fixture := _fixture(Vector3.RIGHT, 2.4)
	var b = fixture.blueprint
	b.rooms = []
	b.find_part("foundation").size.z = 8.0
	var second_ids: Array = []
	for id in fixture.members:
		var original = b.find_part(id)
		original.position.z -= 2.0
		var record: Dictionary = original.snapshot()
		record.id = "second_" + id
		record.position.z += 4.0
		b.add_part(record)
		second_ids.append(record.id)
	var root_part = b.find_part("foundation")
	var top: float = root_part.position.y + root_part.size.y * 0.5
	var finish = b.add_part({"id": "shared_finish", "kind": "foundation", "material": "cobblestone", "collision": false,
		"position": Vector3(0, top + 0.05, 0), "size": Vector3(1.4, 0.1, 8.0), "recipe": {"pavingFamily": "civic_setts"}})
	fixture.policy["pavingFinishPartIds"] = [finish.id]
	var first: Dictionary = Builder.add_frame(b, fixture.members, fixture.policy)
	_check("first_complete_frame", first.ready)
	var second: Dictionary = {}
	if first.ready:
		_index(b)
		var after_first: Dictionary = b.snapshot()
		var aliases: Array = b.parts.duplicate()
		var old_joint: Dictionary = finish.recipe.pavingFootingJoints.duplicate(true)
		second = Builder.add_frame(b, second_ids, fixture.policy)
		_check("second_complete_frame", second.ready)
		_check("prior_aliases_and_order", _aliases(b, aliases))
		if second.ready:
			var combined: Dictionary = b.snapshot()
			var declaration: Dictionary = finish.recipe.pavingFootingJoints
			_check("four_distinct_feet", declaration.footPartIds.size() == 4 and old_joint.footPartIds.all(func(id): return declaration.footPartIds.has(id)))
			var by_id: Dictionary = {}
			for part in b.parts: by_id[part.id] = part
			var feet: Array = declaration.footPartIds.map(func(id): return by_id[id])
			var replay: Dictionary = Builder.PavingAssembly.prepare(b, [finish.id], feet, declaration.nominalJoint)
			_check("whole_union_exact_replay", replay.ready and var_to_bytes(replay.joints[finish.id]) == var_to_bytes(declaration))
			var allowed := after_first.duplicate(true)
			for record in allowed.parts:
				if record.id == finish.id: record.recipe.pavingFootingJoints = declaration.duplicate(true)
			_check("only_second_panels_and_joint_changed", _preserved(allowed, combined, second_ids))
			var validated = _copy(combined)
			_clear_derived(validated)
			var physical: Dictionary = validated.validate_physical_integrity()
			_check("both_frames_and_panels_physically_pass", (fixture.members + first.partIds + second_ids + second.partIds).all(func(id): return _passes(physical, id)))
		for mode in ["stale", "late_reservation", "late_source"]:
			var trial = _copy(after_first)
			var policy: Dictionary = fixture.policy.duplicate(true)
			var expected := ""
			var panel = trial.find_part(second_ids[0])
			var obstruction := AABB(Vector3(panel.position.x - 0.05, panel.position.y - panel.size.y * 0.5 - Builder.SILL_HEIGHT * 0.75, 1.95), Vector3(0.1, Builder.SILL_HEIGHT * 0.5, 0.1))
			if mode == "stale":
				trial.find_part(old_joint.footPartIds[0]).position.x += 0.05
				expected = "stale_prior_declaration"
			elif mode == "late_reservation":
				policy.reservedVolumes.append(obstruction)
				expected = "reserved_interior_access_or_furniture_blocked"
			else:
				trial.add_part({"id": "synthetic_late_blocker", "kind": "beam", "material": "timber_beam", "position": obstruction.get_center(), "size": obstruction.size, "collision": false})
				expected = "existing_source_geometry_blocked"
			var before := var_to_bytes(trial.snapshot())
			var rejected: Dictionary = Builder.add_frame(trial, second_ids, policy)
			checks.append({"label": mode, "passed": not rejected.ready and rejected.get("reason") == expected and var_to_bytes(trial.snapshot()) == before, "reason": rejected.get("reason", "")})
	var passed := checks.size() >= 10 and checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": checks, "elapsedMsec": Time.get_ticks_msec() - started, "first": first, "second": second,
		"evidenceLevel": "synthetic_two_frame_source_transaction", "doesNotProve": "No live composer, rendered contact, gameplay, navigation, runtime performance or zero gate.",
		"frameSha256": FileAccess.get_sha256("res://scripts/buildings/FacadeBearingFrameBuilder.gd")}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)
