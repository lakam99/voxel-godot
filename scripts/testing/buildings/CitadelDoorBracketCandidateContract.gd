extends SceneTree

## Frozen, production-equivalent source experiment. Not live/visual acceptance.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Mount = preload("res://scripts/buildings/DoorHoodBracketMountRecipe.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_DOOR_BRACKET_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var source: Dictionary = Plan.read_input("candidate")
	if source.is_empty():
		quit(2)
		return
	var source_digest := Plan.digest(source)
	var b = Copy.copy_blueprint(source.afterSnapshot)
	var baseline = Copy.copy_blueprint(source.afterSnapshot)
	Copy.clear_caches(baseline)
	print("door bracket: independent baseline validation")
	var before: Dictionary = baseline.validate_physical_integrity()
	var membership: Dictionary = Copy.street_house_memberships(b)
	if not membership.ready:
		quit(2)
		return
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var rows: Array = []
	var changed: Array = []
	for house in membership.houses:
		var panels: Array = house.facadeIds.map(func(id): return by_id[id])
		for id in house.memberIds:
			if not id.begins_with(house.prefix + "_door_bracket_"): continue
			var target = by_id[id]
			var snapshot: Dictionary = target.snapshot()
			var result: Dictionary = Mount.prepare(b, target, by_id[house.doorId], by_id.get(house.prefix + "_door_hood"), panels)
			var row := {"id": id, "before": snapshot, "plan": result}
			if result.ready:
				target.position = result.part.position
				changed.append(id)
			row["after"] = target.snapshot()
			rows.append(row)
	var candidate_snapshot: Dictionary = b.snapshot()
	var unchanged := true
	for index in range(b.parts.size()):
		var record: Dictionary = candidate_snapshot.parts[index].duplicate(true)
		if changed.has(record.id): record.position = source.afterSnapshot.parts[index].position
		unchanged = unchanged and Plan.digest(record) == Plan.digest(source.afterSnapshot.parts[index])
	Copy.clear_caches(b)
	print("door bracket: independent candidate validation")
	var after: Dictionary = b.validate_physical_integrity()
	var old_failed := Copy.failed_ids(before)
	var new_failed := Copy.failed_ids(after)
	for row in rows:
		row["beforeCheck"] = before.checks.filter(func(check): return check.partId == row.id)
		row["afterCheck"] = after.checks.filter(func(check): return check.partId == row.id)
		row["selectedPierRooted"] = row.plan.ready and b.has_rooted_support_chain(b.find_part(row.plan.pierId), {})
		var owner: String = String(row.id).split("_door_bracket_")[0]
		row["ownRootedAnchorIds"] = []
		for anchor_id in row.afterCheck[0].get("anchorPartIds", []):
			var anchor = b.find_part(anchor_id)
			if anchor != null and anchor.id.begins_with(owner + "_") and b.has_rooted_support_chain(anchor, {}):
				row.ownRootedAnchorIds.append(anchor_id)
	var checks := {"baseline170": old_failed.size() == 170, "all32Observed": rows.size() == 32,
		"onlyBracketPositionsChanged": unchanged, "frozenInputUnchanged": Plan.digest(source) == source_digest,
		"noNewFailures": new_failed.all(func(id): return old_failed.has(id)),
		"allPlansReady": rows.all(func(row): return row.plan.ready)}
	var report := {"evidenceLevel": "source_only_unwired_recipe_candidate", "seed": source.fixture.seed,
		"scale": source.fixture.citadelScale, "sourceDigest": Plan.digest(source.afterSnapshot),
		"checks": checks, "observed": true, "candidateReady": checks.values().all(func(value): return value),
		"beforeFailureCount": old_failed.size(), "afterFailureCount": new_failed.size(),
		"removedFailedIds": old_failed.filter(func(id): return not new_failed.has(id)),
		"addedFailedIds": new_failed.filter(func(id): return not old_failed.has(id)),
		"rows": rows, "changedCount": changed.size(), "elapsedMsec": Time.get_ticks_msec() - started,
		"limitations": "No production wiring, published geometry, finite socket proof, clearance or headed visual acceptance. Partial plans are diagnostic only, never published. Existing furniture data is untouched, not regenerated."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("door bracket candidate: ", old_failed.size(), " -> ", new_failed.size(), "; ready=", report.candidateReady)
	quit(0 if written else 2)
