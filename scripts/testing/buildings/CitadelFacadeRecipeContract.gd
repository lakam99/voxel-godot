extends SceneTree

## Actual add_street_house producer/service contract, not synthetic wall boxes.
## VOXEL_FACADE_RECIPE_REPORT: new absolute JSON path in an existing directory.
## Default main shard retains small rollback and before/final/emitted validation.
## Mandatory companion: VOXEL_FACADE_CONTRACT_MODE=full_rollback, with
## VOXEL_FACADE_ROLLBACK_SOURCE + VOXEL_FACADE_ROLLBACK_SHA256 from main export.
## No launch/publication/physics/navigation; remaining failures stay visible.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Recipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
# Regression fixture only, never a placement/ownership input in the recipe.
const WHOLE_FIXTURE := {"seed": 208159, "biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25, "furnitureSeed": 208159 * 7919 + 37}
var _progress_file: FileAccess
var _progress_path := ""
var _progress_ok := true
var _progress_count := 0
var _progress_started := 0
var _progress_label := "fixture"
var _last_callback: Dictionary = {}
var _pending_export: Dictionary = {}
var _export_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var mode := OS.get_environment("VOXEL_FACADE_CONTRACT_MODE").strip_edges()
	if mode.is_empty(): mode = "main"
	if mode not in ["main", "full_rollback"] or (mode == "full_rollback" and OS.get_environment("VOXEL_FACADE_EXPORT_CANDIDATE") == "1"):
		push_error("Require main or full_rollback mode; rollback cannot export a candidate")
		quit(2)
		return
	var path := OS.get_environment("VOXEL_FACADE_RECIPE_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		push_error("Require a new VOXEL_FACADE_RECIPE_REPORT path")
		quit(2)
		return
	if OS.get_environment("VOXEL_FACADE_EXPORT_CANDIDATE") == "1":
		_export_path = path.get_base_dir().path_join("facade-candidate.bin")
		if OS.get_environment("VOXEL_FACADE_WHOLE_CITADEL") != "1" or FileAccess.file_exists(_export_path) or FileAccess.file_exists(_export_path + ".pending"):
			push_error("Facade export requires full contract and new candidate/pending paths")
			quit(2)
			return
	_progress_path = path.get_basename() + ".progress.jsonl"
	if FileAccess.file_exists(_progress_path):
		push_error("Require a fresh facade progress artifact")
		quit(2)
		return
	_progress_file = FileAccess.open(_progress_path, FileAccess.WRITE)
	if _progress_file == null:
		quit(2)
		return
	_progress_started = Time.get_ticks_usec()
	if mode == "full_rollback":
		var rollback_report := _full_rollback_shard()
		_fixture_progress("fixture_end")
		rollback_report["progressArtifact"] = _progress_path
		rollback_report["progressRecords"] = _progress_count
		rollback_report["progressPassed"] = _progress_ok
		rollback_report.passed = bool(rollback_report.passed) and _progress_ok
		rollback_report["pairedAcceptancePending"] = not rollback_report.passed
		_write_report(path, rollback_report)
		return
	_fixture_progress("small_contract_begin")
	var started := Time.get_ticks_msec()
	var grid_controls := _grid_controls()
	var cases: Array = []
	var narrow_cases: Array = []
	for side in [-1.0, 1.0]:
		for dimensions in [Vector3(7.2, 6.2, 9.45), Vector3(8.0, 9.3, 11.2)]:
			cases.append(_case(side, dimensions, cases.size()))
			narrow_cases.append(_narrow_case(side, dimensions, narrow_cases.size()))
	var furnishing_controls := _furnishing_bounds_controls()
	var support_controls := _support_closure_controls()
	var broad_controls := _broad_paving_controls()
	var door_controls := _door_bearing_controls()
	var inset_controls := _inset_bearing_controls()
	var batch_controls := _batch_transaction_controls()
	_fixture_progress("small_contract_end")
	# Opt in to expensive fresh integrated composition; no new artifact loader,
	# substitute world, or prototype pipeline. Uses this runner's existing JSON.
	var whole_enabled: bool = OS.get_environment("VOXEL_FACADE_WHOLE_CITADEL") == "1"
	var whole: Dictionary = _whole_citadel_case() if whole_enabled else {"enabled": false, "status": "not_requested"}
	_fixture_progress("fixture_end")
	var report := {"evidenceLevel": "actual_street_house_producer_source_contract", "cases": cases,
		"wholeCitadel": whole,
		"supportClosureControls": support_controls,
		"broadPavingControls": broad_controls,
		"doorBearingControls": door_controls,
		"insetBearingControls": inset_controls,
		"batchTransactionControls": batch_controls,
		"progressArtifact": _progress_path, "progressRecords": _progress_count, "progressPassed": _progress_ok,
		"narrowPierCases": narrow_cases, "furnishingBoundsControls": furnishing_controls,
		"gridWorkControls": grid_controls,
		"passed": cases.size() == 4 and cases.all(func(row): return row.passed) and narrow_cases.size() == 4 and narrow_cases.all(func(row): return row.passed) and furnishing_controls.all(func(row): return row.passed) and support_controls.all(func(row): return row.passed) and broad_controls.all(func(row): return row.passed) and batch_controls.all(func(row): return row.passed) and grid_controls.all(func(row): return row.passed) and _progress_ok and (not whole_enabled or bool(whole.get("passed", false))), "elapsedMsec": Time.get_ticks_msec() - started,
		"limitations": "Representative cases plus opt-in fresh whole-citadel bottom-bay composition. Full physical before/after remains red where unresolved; completion is not a zero gate. No opening-header, publisher, traversal, NPC or visual acceptance."}
	report.passed = bool(report.passed) and door_controls.all(func(row): return bool(row.passed))
	report.passed = bool(report.passed) and inset_controls.all(func(row): return bool(row.passed))
	if not _export_path.is_empty() and report.passed:
		var exported := _export_candidate()
		report["candidateArtifact"] = exported
		if not exported.ready: report.passed = false
	report["contractMode"] = "main"
	report["pairedAcceptancePending"] = whole_enabled
	report["acceptanceRequirement"] = "Main and mandatory full_rollback shard must both pass with matching artifact SHA, source/fixture/policy digests and contract identity; shard passed alone is not paired acceptance."
	_write_report(path, report)


func _write_report(path: String, report: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	_progress_file.close()
	print("Actual facade recipe contract: ", report.passed, " in ", report.elapsedMsec, " ms")
	quit(0 if written and report.passed else 2)


func _export_candidate() -> Dictionary:
	# Immutable evidence transfer, never a baseline replacement. Encode only
	# ordinary Variants (no objects): consumer uses bytes_to_var(file bytes).
	if _pending_export.is_empty() or FileAccess.file_exists(_export_path) or FileAccess.file_exists(_export_path + ".pending"): return {"ready": false, "reason": "candidate_export_missing_or_exists"}
	var payload: PackedByteArray = var_to_bytes(_pending_export)
	var pending := _export_path + ".pending"
	var file := FileAccess.open(pending, FileAccess.WRITE)
	if file == null: return {"ready": false, "reason": "candidate_export_open_failed"}
	file.store_buffer(payload)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_length() == payload.size()
	file.close()
	if not written: return {"ready": false, "reason": "candidate_export_write_failed", "pendingPath": pending}
	if FileAccess.file_exists(_export_path): return {"ready": false, "reason": "candidate_export_exists", "pendingPath": pending}
	if DirAccess.rename_absolute(pending, _export_path) != OK: return {"ready": false, "reason": "candidate_export_publish_failed", "pendingPath": pending}
	return {"ready": true, "path": _export_path, "sha256": FileAccess.get_sha256(_export_path), "schemaVersion": 1, "encoding": "var_to_bytes", "bytes": payload.size(), "pairedAcceptancePending": true}


func _fixture_progress(phase: String) -> void:
	_write_progress({"scope": "fixture", "phase": phase, "elapsedUsec": Time.get_ticks_usec() - _progress_started})


func _record_batch_progress(summary: Dictionary) -> void:
	_progress_ok = _progress_ok and summary.is_read_only() and summary.get("memberIds") is Array and summary.memberIds.is_read_only() and _scalar_progress(summary)
	_last_callback = summary.duplicate(true)
	_write_progress({"scope": _progress_label, "fixtureElapsedUsec": Time.get_ticks_usec() - _progress_started, "summary": summary})


func _scalar_progress(value: Variant) -> bool:
	if value is Dictionary:
		return value.keys().all(func(key): return key is String and _scalar_progress(value[key]))
	if value is Array: return value.all(func(item): return _scalar_progress(item))
	return typeof(value) in [TYPE_NIL, TYPE_STRING, TYPE_BOOL, TYPE_INT, TYPE_FLOAT]


func _write_progress(record: Dictionary) -> void:
	_progress_count += 1
	# Recipe loops are bounded; this also bounds the whole fixture sidecar.
	if _progress_count > 20000:
		_progress_ok = false
		return
	_progress_file.store_line(JSON.stringify(record))
	_progress_file.flush()
	_progress_ok = _progress_ok and _progress_file.get_error() == OK


func _grid_controls() -> Array:
	var rows: Array = []
	for rotated in [false, true]:
		var b = Blueprint.new("grid_work_control", 701, "timber")
		b.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
		Urban.add_street_house(b, "producer", Vector3(7, 0, 0), 7.2, 9.45, 6.2, 1.0, 0.62, "painted_brick_cream", 0.0)
		var producer_ids: Array = b.parts.map(func(part): return part.id)
		# Unrelated source geometry must also be bounded before full validation.
		# The second case is tiny in local XZ: only transformed corners expose it.
		b.add_part({"id": "grid_extent_control", "kind": "beam", "material": "timber",
			"position": Vector3(100, 100, 100), "size": Vector3(1, 1.0e12, 1) if rotated else Vector3(1.0e12, 1, 1),
			"rotation": Vector3(0, 0, PI * 0.25) if rotated else Vector3.ZERO, "collision": true})
		var before := _digest(b.snapshot())
		var result: Dictionary = Recipe.add_one_bay(b, producer_ids, {"furnitureParts": [], "reservedVolumes": []})
		rows.append({"rotatedTallPart": rotated, "result": result,
			"passed": not result.ready and result.get("reason") == "validation_grid_work_limit_exceeded" and result.get("phase") == "before" and _digest(b.snapshot()) == before})
	return rows


func _case(side: float, dimensions: Vector3, index: int) -> Dictionary:
	var b = Blueprint.new("actual_facade_%d" % index, 701 + index, "timber")
	b.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
	var start_count: int = b.parts.size()
	# The authoritative producer generates walls, partitioned openings, roof,
	# door/access, household clutter and all their variation. No ID grammar copy.
	Urban.add_street_house(b, "producer_%d" % index, Vector3(side * 7.0, 0, index * 3.0), dimensions.x, dimensions.z, dimensions.y, side, 0.62, "painted_brick_cream", float(index) * 0.01)
	var producer_ids: Array = b.parts.slice(start_count).map(func(part): return part.id)
	var original: Dictionary = b.snapshot()
	var furniture_before = Furniture.build(Recipe.copy_blueprint(original), 813)
	var row := {"passed": false, "side": side, "dimensions": dimensions, "producerIds": producer_ids, "checks": {}}
	if furniture_before == null:
		row["reason"] = "actual_furnishing_planner_failed"
		return row
	var furniture_snapshot: Dictionary = furniture_before.snapshot()
	var policy := {"furnitureParts": furniture_snapshot.parts, "reservedVolumes": furniture_before.protected_access_reservations.duplicate()}
	var policy_before := _digest(policy)
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Recipe.add_one_bay(b, producer_ids, policy)
	var output: Dictionary = b.snapshot()
	row["recipeResult"] = result
	row["furnitureBefore"] = furniture_snapshot
	# This producer emits household contents directly as source parts; it does
	# not populate courtyardResidences consumed by CastleFurnishingPlanner.
	var contents_before: Array = _household_contents(original)
	var contents_after: Array = _household_contents(output)
	row["householdContentsBefore"] = contents_before
	row["householdContentsAfter"] = contents_after
	row.checks["actual_producer_contents_nonempty_and_exact"] = not contents_before.is_empty() and _digest(contents_before) == _digest(contents_after)
	row.checks["ready"] = bool(result.get("ready", false))
	row.checks["policy_unchanged"] = _digest(policy) == policy_before
	if not row.checks.ready:
		row.checks["failure_atomic"] = _digest(original) == _digest(output)
		return row
	row.checks["original_aliases_retained"] = range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i]))
	row.checks["only_declared_panel_contracts_and_additions"] = _preserved(original, output, result.memberIds, result.partIds)
	row.checks["actual_failed_panels_reduced"] = not result.resolvedFacadeIds.is_empty()
	var successful_attempts: Array = result.attempts.filter(func(attempt): return attempt.result.ready)
	row.checks["bounded_geometry_derived_footing_plan"] = successful_attempts.size() == 1 and successful_attempts[0].has("footingPlan") and successful_attempts[0].footingPlan.projectionWork <= 131072
	var bay_panels: Array = b.parts.filter(func(part): return result.memberIds.has(part.id))
	var bay_bounds: AABB = Recipe.Frame._bounds(bay_panels[0])
	for panel in bay_panels: bay_bounds = bay_bounds.merge(Recipe.Frame._bounds(panel))
	var bay_posts: Array = b.parts.filter(func(part): return successful_attempts[0].result.postIds.has(part.id))
	var inset_limit: float = Recipe.Frame.maximum_post_inset(bay_bounds.size.z)
	row.checks["posts_remain_within_full_bay_bearing_envelope"] = bay_posts.size() == 2 and bay_posts.all(func(part): return minf(part.position.z - bay_bounds.position.z, bay_bounds.end.z - part.position.z) <= inset_limit and part.position.z > bay_bounds.position.z and part.position.z < bay_bounds.end.z)
	var old_failed := Recipe.failed_ids(result.beforePhysical)
	var new_failed := Recipe.failed_ids(result.afterPhysical)
	row.checks["no_new_failed_part_ids"] = new_failed.all(func(id): return old_failed.has(id))
	row.checks["remaining_panel_ids_explicit"] = result.remainingFacadeIds == b.parts.filter(func(part): return part.semantic == "citadel_urban_facade" and new_failed.has(part.id)).map(func(part): return part.id)
	var furniture_after = Furniture.build(Recipe.copy_blueprint(output), 813)
	row["furnitureAfter"] = furniture_after.snapshot() if furniture_after != null else {}
	row["furniturePlannerScope"] = "Courtyard residence planner; empty plans are not evidence for furnished interiors. Nonempty source household contents checked separately."
	row.checks["residence_furniture_plan_exact"] = furniture_after != null and _digest(furniture_snapshot) == _digest(furniture_after.snapshot())
	row.checks["actual_furniture_reservations_exact"] = furniture_after != null and _digest(furniture_before.protected_access_reservations) == _digest(furniture_after.protected_access_reservations)
	var emitted = Recipe.copy_blueprint(output)
	Recipe.clear_caches(emitted)
	var emitted_physical: Dictionary = emitted.validate_physical_integrity()
	row["emittedPhysical"] = emitted_physical
	row.checks["emitted_failures_match_staging"] = Recipe.failed_ids(emitted_physical) == new_failed
	var new_roots: Array = emitted.parts.filter(func(part): return result.partIds.has(part.id) and part.kind == "foundation")
	row.checks["new_roots_are_real_grounded_volumes"] = not new_roots.is_empty() and new_roots.all(func(part): return emitted.is_grounded_structural_root(part) and part.size.y >= 0.62 and part.collision_enabled)
	var foot_width: float = Recipe.Frame.FOOT_WIDTH
	row.checks["new_roots_have_real_footing_margin"] = new_roots.all(func(part): return part.size.x > foot_width and part.size.z > foot_width)
	var controls: Array = []
	for root in new_roots:
		var broken = Recipe.copy_blueprint(output)
		broken.parts.erase(broken.find_part(root.id))
		Recipe.clear_caches(broken)
		var physical: Dictionary = broken.validate_physical_integrity()
		var failures := Recipe.failed_ids(physical)
		controls.append({"removedRoot": root.id, "passed": result.memberIds.all(func(id): return failures.has(id)), "failedPartIds": failures})
	row["removedFootingControls"] = controls
	row.checks["removed_real_footings_break_bay"] = controls.size() == new_roots.size() and controls.all(func(control): return control.passed)
	var blocked = Recipe.copy_blueprint(original)
	var blocked_policy: Dictionary = policy.duplicate(true)
	# Negative reservation spans this producer's actual complete source bounds.
	var envelope: AABB = Recipe.Frame._bounds(blocked.parts[0])
	for part in blocked.parts: envelope = envelope.merge(Recipe.Frame._bounds(part))
	blocked_policy.reservedVolumes.append(envelope.grow(1.0))
	var rejected: Dictionary = Recipe.add_one_bay(blocked, producer_ids, blocked_policy)
	row.checks["blocked_frontage_rejected_atomically"] = not rejected.ready and _digest(blocked.snapshot()) == _digest(original)
	row["blockedFrontageResult"] = rejected
	row["addedPartSnapshots"] = output.parts.filter(func(part): return result.partIds.has(part.id))
	row["passed"] = row.checks.values().all(func(value): return bool(value))
	return row


func _narrow_case(side: float, dimensions: Vector3, index: int) -> Dictionary:
	var b = Blueprint.new("narrow_actual_%d" % index, 701 + index, "timber")
	b.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
	var start: int = b.parts.size()
	Urban.add_street_house(b, "narrow_producer_%d" % index, Vector3(side * 7.0, 0, index * 3.0), dimensions.x, dimensions.z, dimensions.y, side, 0.62, "painted_brick_cream", float(index) * 0.01)
	var ids: Array = b.parts.slice(start).map(func(part): return part.id)
	var original: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var policy := {"furnitureParts": [], "reservedVolumes": []}
	var result: Dictionary = Recipe.add_one_narrow_pier(b, ids, policy)
	var row := {"passed": false, "dimensions": dimensions, "side": side, "result": result, "checks": {}}
	row.checks["ready"] = bool(result.ready)
	if not result.ready:
		row.checks["failure_atomic"] = _digest(original) == _digest(b.snapshot())
		return row
	var output: Dictionary = b.snapshot()
	var attempt: Dictionary = result.attempts.filter(func(value): return value.result.ready)[0]
	var setup: Dictionary = attempt.result
	# Use authoritative returned membership, not a copied producer ID grammar.
	var current: Dictionary = {}
	for part in b.parts: current[part.id] = part
	var panel = current[result.memberIds[0]]
	var cap = current[setup.sillId]
	var post = current[setup.postIds[0]]
	var cap_bounds: AABB = Recipe.Frame._bounds(cap)
	var panel_bounds: AABB = Recipe.Frame._bounds(panel)
	row.checks["one_whole_panel_one_post"] = result.memberIds.size() == 1 and setup.postIds.size() == 1 and setup.mode == "narrow_pier" and panel.size.z < 1.2
	# Exact represented geometry comparisons, not real_t-vs-double equality.
	row.checks["sections_not_thinned"] = cap.size == Vector3(Recipe.Frame.POST_WIDTH, Recipe.Frame.SILL_HEIGHT, Recipe.Frame.PIER_CAP_SPAN) and Vector2(post.size.x, post.size.z) == Vector2(Recipe.Frame.POST_WIDTH, Recipe.Frame.POST_WIDTH)
	row.checks["cap_under_unchanged_panel"] = absf(cap_bounds.end.y - panel_bounds.position.y) < Recipe.Frame.EPS and cap_bounds.position.x >= panel_bounds.position.x - Recipe.Frame.EPS and cap_bounds.end.x <= panel_bounds.end.x + Recipe.Frame.EPS and cap_bounds.position.z >= panel_bounds.position.z and cap_bounds.end.z <= panel_bounds.end.z and panel.position.z >= cap_bounds.position.z and panel.position.z <= cap_bounds.end.z
	row.checks["bounded_source_regions"] = attempt.footingPlan.projectionWork <= 131072 and attempt.footingPlan.regionCount <= 256
	row.checks["original_aliases_retained"] = range(aliases.size()).all(func(i): return is_same(b.parts[i], aliases[i]))
	row.checks["source_geometry_rooms_and_recipes_preserved"] = _preserved(original, output, result.memberIds, result.partIds)
	row.checks["nonempty_household_contents_exact"] = not _household_contents(original).is_empty() and _digest(_household_contents(original)) == _digest(_household_contents(output))
	var failures_before := Recipe.failed_ids(result.beforePhysical)
	var failures_after := Recipe.failed_ids(result.afterPhysical)
	row.checks["reduced_no_added_failures"] = not result.resolvedFacadeIds.is_empty() and failures_after.all(func(id): return failures_before.has(id))
	var emitted = Recipe.copy_blueprint(output)
	Recipe.clear_caches(emitted)
	row["emittedPhysical"] = emitted.validate_physical_integrity()
	row.checks["emitted_validation_matches"] = Recipe.failed_ids(row.emittedPhysical) == failures_after
	var clear := true
	for id in result.partIds:
		var added_bounds: AABB = Recipe.Frame._bounds(current[id])
		for room in b.rooms:
			if room.get("role", "") != "courtyard" and Recipe.Frame._penetrates(added_bounds.grow(Recipe.CLEARANCE), room.bounds): clear = false
			for access in room.get("accesses", []):
				if Recipe.Frame._penetrates(added_bounds.grow(Recipe.CLEARANCE), AABB(access.position - access.size * 0.5, access.size)): clear = false
	row.checks["actual_rooms_and_access_clear"] = clear
	var controls: Array = []
	# Mandatory chain, including cap and post: either deletion or movement
	# must break the selected panel, even if unrelated source supports remain.
	for id in result.partIds:
		for moved in [false, true]:
			var broken = Recipe.copy_blueprint(output)
			var target = broken.find_part(id)
			if moved: target.position += Vector3.UP * (panel.size.y + 2.0)
			else: broken.parts.erase(target)
			Recipe.clear_caches(broken)
			var physical: Dictionary = broken.validate_physical_integrity()
			controls.append({"id": id, "moved": moved, "passed": Recipe.failed_ids(physical).has(panel.id)})
	row["brokenChainControls"] = controls
	row.checks["mandatory_chain_breaks"] = not controls.is_empty() and controls.all(func(control): return control.passed)
	var blocked = Recipe.copy_blueprint(original)
	var envelope: AABB = Recipe.Frame._bounds(blocked.parts[0])
	for part in blocked.parts: envelope = envelope.merge(Recipe.Frame._bounds(part))
	var blocked_result: Dictionary = Recipe.add_one_narrow_pier(blocked, ids, {"furnitureParts": [], "reservedVolumes": [envelope.grow(1.0)]})
	row.checks["blocked_atomic"] = not blocked_result.ready and _digest(blocked.snapshot()) == _digest(original)
	# A furnishing whose upper occupied half alone crosses the new cap. This
	# would miss under the old vertically centred BuildingPart interpretation.
	var furnishing := {"position": Vector3(cap.position.x, cap_bounds.position.y - 0.6, cap.position.z + (Recipe.Frame.POST_WIDTH + Recipe.Frame.PIER_CAP_SPAN) * 0.25), "occupiedSize": Vector3(0.10, 0.8, 0.04), "rotation": Vector3.ZERO}
	var lower_half_top: float = furnishing.position.y + furnishing.occupiedSize.y * 0.5
	row.checks["floor_origin_counterexample_setup"] = lower_half_top < cap_bounds.position.y and furnishing.position.y + furnishing.occupiedSize.y > cap_bounds.position.y
	var frame_source = Recipe.copy_blueprint(original)
	for record in output.parts:
		if setup.foundationIds.has(record.id) and not ids.has(record.id): frame_source.add_part(record)
	var frame_before: Dictionary = frame_source.snapshot()
	var frame_policy := {"outward": Vector3(side, 0, 0), "foundationPartIds": setup.foundationIds, "furnitureParts": [furnishing], "reservedVolumes": [], "bearingWidth": cap.size.x, "bearingNormalCenter": cap.position.x, "capSpanCenter": cap.position.z}
	var furniture_reject: Dictionary = Recipe.Frame.add_narrow_pier(frame_source, panel.id, frame_policy)
	row["furnitureRejection"] = furniture_reject
	row.checks["helper_rejects_floor_center_occupied_volume_atomically"] = not furniture_reject.ready and furniture_reject.reason == "reserved_interior_access_or_furniture_blocked" and _digest(frame_source.snapshot()) == _digest(frame_before)
	var furnished_source = Recipe.copy_blueprint(original)
	var furnishing_before := _digest(furnishing)
	var furnished_result: Dictionary = Recipe.add_one_narrow_pier(furnished_source, ids, {"furnitureParts": [furnishing], "reservedVolumes": []})
	var occupied: Dictionary = Recipe.Frame.furnishing_bounds(furnishing)
	var furnishing_clear := true
	if furnished_result.ready:
		for part in furnished_source.parts:
			if furnished_result.partIds.has(part.id) and Recipe.Frame._penetrates(Recipe.Frame._bounds(part).grow(Recipe.CLEARANCE), occupied.bounds): furnishing_clear = false
	else:
		furnishing_clear = _digest(furnished_source.snapshot()) == _digest(original)
	row.checks["adapter_avoids_same_floor_center_volume_or_rejects_atomically"] = furnishing_clear and _digest(furnishing) == furnishing_before
	# Bad declared cap geometry cannot commit a partial frame.
	frame_policy.furnitureParts = []
	var replay_source = Recipe.copy_blueprint(frame_before)
	var replay: Dictionary = Recipe.Frame.add_narrow_pier(replay_source, panel.id, frame_policy)
	row["storedWidthReplay"] = replay
	var replay_exact: bool = bool(replay.ready)
	if replay.ready:
		for part in replay_source.parts:
			if replay.partIds.has(part.id):
				var expected = current[part.id]
				if part.position != expected.position or part.rotation != expected.rotation or part.size != expected.size or part.material_id != expected.material_id or part.collision_enabled != expected.collision_enabled: replay_exact = false
	row.checks["stored_width_roundtrip_geometry_exact"] = replay_exact
	var below_policy: Dictionary = frame_policy.duplicate(true)
	below_policy.bearingWidth = cap.size.x - Recipe.CLEARANCE
	var thin_result: Dictionary = Recipe.Frame.add_narrow_pier(frame_source, panel.id, below_policy)
	row["thinSectionRejection"] = thin_result
	row.checks["below_stored_width_rejected_atomically"] = not thin_result.ready and thin_result.reason == "invalid_bearing_section" and _digest(frame_source.snapshot()) == _digest(frame_before)
	frame_policy.capSpanCenter = panel_bounds.end.z + cap.size.z
	var invalid: Dictionary = Recipe.Frame.add_narrow_pier(frame_source, panel.id, frame_policy)
	row["invalidCapRejection"] = invalid
	row.checks["invalid_cap_atomic"] = not invalid.ready and invalid.reason == "cap_outside_panel_bearing_envelope" and _digest(frame_source.snapshot()) == _digest(frame_before)
	var reversed_source: Dictionary = original.duplicate(true)
	reversed_source.parts.reverse()
	var reordered = Recipe.copy_blueprint(reversed_source)
	var reversed_ids := ids.duplicate()
	reversed_ids.reverse()
	var repeat: Dictionary = Recipe.add_one_narrow_pier(reordered, reversed_ids, policy)
	row.checks["reorder_same_selection"] = repeat.ready and repeat.memberIds == result.memberIds
	if repeat.ready:
		var repeat_records: Dictionary = {}
		for part in reordered.parts: repeat_records[part.id] = part.snapshot()
		row.checks["reorder_same_geometry"] = result.partIds.all(func(id): return _digest(repeat_records.get(id, {})) == _digest(current[id].snapshot()))
	row["addedPartSnapshots"] = output.parts.filter(func(record): return result.partIds.has(record.id))
	row["passed"] = row.checks.values().all(func(value): return bool(value))
	return row


func _furnishing_bounds_controls() -> Array:
	var rows: Array = []
	for rotation in [Vector3.ZERO, Vector3(0, PI * 0.5, 0), Vector3(0.2, -0.4, 0.1)]:
		var record := {"position": Vector3(2, 3, 4), "occupiedSize": Vector3(2, 4, 6), "size": Vector3.ONE * 0.1, "rotation": rotation}
		var before := _digest(record)
		var result: Dictionary = Recipe.Frame.furnishing_bounds(record)
		var basis := Basis.from_euler(rotation)
		var expected := AABB(record.position + basis * Vector3(-1, 0, -3), Vector3.ZERO)
		for x in [-1.0, 1.0]:
			for y in [0.0, 4.0]:
				for z in [-3.0, 3.0]: expected = expected.expand(record.position + basis * Vector3(x, y, z))
		rows.append({"rotation": rotation, "passed": result.ready and result.bounds.is_equal_approx(expected) and _digest(record) == before})
	for size in [Vector3(1, -1, 1), Vector3(NAN, 1, 1), Vector3.ZERO]:
		var record := {"position": Vector3.ZERO, "occupiedSize": size}
		rows.append({"invalidSize": str(size), "passed": not Recipe.Frame.furnishing_bounds(record).ready})
	return rows


func _door_bearing_controls() -> Array:
	var rows: Array = []
	# Deliberately synthetic placement of REAL shared ordinary-door geometry.
	# Its source box clears the post, while the protruding DoorBrace does not.
	for trapped in [false, true]:
		var b = _producer_support_stack(true)
		var panel = b.parts.filter(func(part): return part.id == "panel")[0]
		var root = b.parts.filter(func(part): return part.semantic == "castle_courtyard_foundation")[0]
		var paving = b.parts.filter(func(part): return part.semantic == "castle_courtyard_paving")[0]
		var baseline := Recipe._narrow_region(b, panel, root, Vector3.RIGHT, [], paving)
		var checks := {"otherwise_placeable": bool(baseline.ready)}
		if not baseline.ready:
			rows.append({"name": "door_brace_fixture_setup", "passed": false, "result": baseline})
			continue
		var post_bottom: float = Recipe.Frame._bounds(paving).end.y + Recipe.Frame.FOOT_HEIGHT
		var post_top: float = Recipe.Frame._bounds(panel).position.y - Recipe.Frame.SILL_HEIGHT
		var post_center := Vector3(baseline.center, (post_bottom + post_top) * 0.5, baseline.capSpanCenter)
		var post_size := Vector3(Recipe.Frame.POST_WIDTH, post_top - post_bottom, Recipe.Frame.POST_WIDTH)
		var original_post := AABB(post_center - post_size * 0.5, post_size)
		var door_size := Vector3(0.14, 0.8, 1.0)
		var description: Dictionary = Recipe.Frame.DoorGeometry.describe(door_size)
		var brace_reach: float = description.brace.position.z + description.brace.size.z * 0.5
		var door_position: Vector3 = post_center - description.brace.position
		# Two penetration depths exercise a feasible alternative and genuine
		# no-fit within the unchanged narrow-cap bearing policy respectively.
		door_position.z = post_center.z - brace_reach + (0.09 if trapped else 0.01)
		var door = b.add_part({"id": "ordinary_door", "kind": "door", "material": "timber", "position": door_position, "size": door_size, "collision": true})
		var before: Dictionary = b.snapshot()
		var furnishing := {"id": "retained_furniture", "position": Vector3(2, 0.76, 2), "occupiedSize": Vector3(0.3, 0.4, 0.3), "rotation": Vector3.ZERO, "recipe": {}}
		var furniture: Array = [furnishing]
		var furniture_digest := _digest(furniture)
		var visual: Dictionary = Recipe.Frame.closed_door_reservations(b)
		checks["shared_ten_primitives"] = visual.ready and visual.records.size() == 10
		var braces: Array = visual.records.filter(func(piece): return piece.name == "brace")
		checks["source_box_clear_actual_brace_blocks"] = not Recipe.Frame._penetrates(original_post.grow(Recipe.CLEARANCE), Recipe.Frame._bounds(door)) and braces.size() == 1 and Recipe.Frame._penetrates(original_post, braces[0].bounds)
		var policy := {"outward": Vector3.RIGHT, "reservedVolumes": [], "furnitureParts": furniture, "bearingWidth": Recipe.Frame.POST_WIDTH, "bearingNormalCenter": baseline.center, "capSpanCenter": baseline.capSpanCenter}
		var rejected: Dictionary = Recipe.Frame.add_frame_on_support(b, [panel.id], policy, paving.id, [root.id], true)
		checks["final_rederives_brace_without_caller_reservations"] = not rejected.ready and rejected.get("reason") == "ordinary_door_visual_geometry_blocked" and rejected.get("otherId") == door.id and rejected.get("primitive") == "brace"
		checks["final_rejection_atomic"] = _digest(b.snapshot()) == _digest(before)
		var reserved: Array = visual.volumes.duplicate()
		reserved.append(Recipe.Frame.furnishing_bounds(furnishing).bounds)
		var plan: Dictionary = Recipe._narrow_region(b, panel, root, Vector3.RIGHT, reserved, paving)
		var repeated: Dictionary = Recipe._narrow_region(b, panel, root, Vector3.RIGHT, reserved, paving)
		checks["deterministic_planning"] = _digest(plan) == _digest(repeated)
		checks["planning_source_and_furniture_immutable"] = _digest(b.snapshot()) == _digest(before) and _digest(furniture) == furniture_digest
		var final_result: Dictionary = {}
		if trapped:
			checks["closed_brace_reservations_force_no_fit"] = not plan.ready and plan.get("reason") == "no_clear_narrow_bearing_region"
		else:
			checks["clear_alternative_found"] = bool(plan.ready)
			if plan.ready:
				policy.bearingNormalCenter = plan.center
				policy.capSpanCenter = plan.capSpanCenter
				final_result = Recipe.Frame.add_frame_on_support(b, [panel.id], policy, paving.id, [root.id], true)
				checks["planned_frame_validates"] = bool(final_result.ready)
				if final_result.ready:
					var clear := true
					for part in b.parts:
						if not final_result.partIds.has(part.id): continue
						for primitive in visual.records:
							if Recipe.Frame._penetrates(Recipe.Frame._bounds(part).grow(Recipe.CLEARANCE), primitive.bounds): clear = false
					checks["every_new_part_clears_all_closed_primitives"] = clear
					checks["door_source_geometry_and_furniture_preserved"] = _preserved(before, b.snapshot(), final_result.memberIds, final_result.partIds) and _digest(furniture) == furniture_digest and b.parts.has(door)
		rows.append({"name": "shared_door_brace_" + ("no_fit" if trapped else "clear_alternative"), "evidenceLevel": "synthetic_bearing_placement_actual_courtyard_and_door_geometry", "passed": checks.values().all(func(value): return bool(value)), "checks": checks, "rejection": rejected, "plan": plan, "finalResult": final_result})
	# All door poses use transformed primitive corners, never world-axis size
	# guesses. Portcullis geometry deliberately remains outside this descriptor.
	for rotation in [Vector3.ZERO, Vector3(0, PI * 0.5, 0), Vector3(0, PI, 0), Vector3(0, PI * 1.5, 0), Vector3(0.17, 0.31, -0.23)]:
		var b = Blueprint.new("door_pose_geometry_control", 1, "timber")
		b.add_part({"id": "ordinary", "kind": "door", "position": Vector3(2, 3, -4), "size": Vector3(0.8, 2.1, 0.18), "rotation": rotation})
		b.add_part({"id": "gate", "kind": "door", "position": Vector3.ZERO, "size": Vector3.ONE, "recipe": {"doorPresentation": "portcullis"}})
		var before := _digest(b.snapshot())
		var visual: Dictionary = Recipe.Frame.closed_door_reservations(b)
		var exact: bool = visual.ready and visual.records.size() == 10 and visual.unsupportedPortcullisIds == ["gate"]
		for primitive in visual.get("records", []):
			var corner_bounds := AABB(primitive.transform * (-primitive.size * 0.5), Vector3.ZERO)
			for x in [-0.5, 0.5]:
				for y in [-0.5, 0.5]:
					for z in [-0.5, 0.5]: corner_bounds = corner_bounds.expand(primitive.transform * (primitive.size * Vector3(x, y, z)))
			exact = exact and corner_bounds.position.is_equal_approx(primitive.bounds.position) and corner_bounds.end.is_equal_approx(primitive.bounds.end)
		rows.append({"name": "closed_door_transformed_corners", "rotation": rotation, "passed": exact and _digest(b.snapshot()) == before, "scope": "Source geometry/corner comparison, not door-motion or portcullis acceptance"})
	return rows


func _support_stack(narrow: bool):
	# Explicit synthetic stacked-source contract, not generated-citadel proof.
	var b = Blueprint.new("synthetic_facade_paving_chain", 1, "timber")
	b.add_part({"id": "root", "kind": "foundation", "material": "stone_foundation", "position": Vector3(0, 0.31, 0), "size": Vector3(8, 0.62, 8), "collision": true, "physicalIntent": "structural_mass"})
	b.add_part({"id": "paving", "kind": "foundation", "material": "cobblestone", "position": Vector3(0, 0.69, 0), "size": Vector3(6, 0.14, 6), "collision": true, "recipe": {"physicalRequiredSupportPartIds": ["root"]}})
	b.add_part({"id": "panel", "kind": "wall", "material": "painted_brick_cream", "position": Vector3(0, 3, 0), "size": Vector3(0.3, 1, 0.88 if narrow else 3.0), "collision": true})
	for part in b.parts: b.physical_parts_by_id[part.id] = part
	return b


func _producer_support_stack(narrow: bool):
	# Actual courtyard producer: paving is an implicit structural-mass
	# foundation with navigationRole=walkable_support, not walkable_surface.
	var b = Blueprint.new("courtyard_producer_facade_chain", 1, "timber")
	Castle.add_courtyard_foundation_and_paving(b, [], 8.0, 8.0, 0.62, 0.0)
	b.add_part({"id": "panel", "kind": "wall", "material": "painted_brick_cream", "position": Vector3(0, 3, 0), "size": Vector3(0.3, 1, 0.88 if narrow else 3.0), "collision": true})
	for part in b.parts: b.physical_parts_by_id[part.id] = part
	return b


func _support_closure_controls() -> Array:
	var rows: Array = []
	var policy := {"outward": Vector3.RIGHT, "furnitureParts": [], "reservedVolumes": [], "bearingWidth": Recipe.Frame.POST_WIDTH, "bearingNormalCenter": 0.0, "capSpanCenter": 0.0}
	for narrow in [false, true]:
		var b = _producer_support_stack(narrow)
		var root = b.parts.filter(func(part): return part.semantic == "castle_courtyard_foundation")[0]
		var paving = b.parts.filter(func(part): return part.semantic == "castle_courtyard_paving")[0]
		var root_id: String = root.id
		var paving_id: String = paving.id
		var before: Dictionary = b.snapshot()
		var result: Dictionary = Recipe.Frame.add_frame_on_support(b, ["panel"], policy, paving_id, [root_id], narrow)
		var checks := {"ready": bool(result.ready)}
		checks["actual_producer_structural_paving_class"] = paving.kind == "foundation" and paving.material_id == "cobblestone" and paving.recipe.get("navigationRole") == "walkable_support" and b.inferred_physical_intent(paving) == "structural_mass"
		if result.ready:
			var output: Dictionary = b.snapshot()
			checks["source_support_geometry_intents_and_declarations_exact"] = _preserved(before, output, result.memberIds, result.partIds)
			checks["paving_25_of_25"] = result.supportCoverage.size() == 1 and result.supportCoverage[0].partId == paving_id and result.supportCoverage[0].sampleCount == 25 and result.supportCoverage[0].supportedCount == 25
			var lookup: Dictionary = {}
			for part in b.parts: lookup[part.id] = part
			var support_top: float = Recipe.Frame._bounds(lookup[paving_id]).end.y
			var feet: Array = result.partIds.filter(func(id): return lookup[id].material_id == "stone_foundation")
			checks["actual_bearing_height_not_foundation_height"] = not feet.is_empty() and feet.all(func(id): return absf(Recipe.Frame._bounds(lookup[id]).position.y - support_top) <= Recipe.Frame.EPS) and support_top > Recipe.Frame._bounds(lookup[root_id]).end.y
			checks["finite_paving_seats_retained"] = feet.all(func(id): return lookup[id].recipe.get("physicalRequiredSeatPartIds", []) == [paving_id] and lookup[id].recipe.get("physicalRequiredSeatFacts", []).size() == 1 and not lookup[id].recipe.has("physicalRequiredSupportPartIds"))
			var emitted = Recipe.copy_blueprint(output)
			Recipe.clear_caches(emitted)
			checks["emitted_complete_physical_pass"] = emitted.validate_physical_integrity().violations.is_empty()
			for remove_id in [root_id, paving_id]:
				var broken = Recipe.copy_blueprint(output)
				broken.parts.erase(broken.find_part(remove_id))
				Recipe.clear_caches(broken)
				checks["removed_" + remove_id + "_breaks_panel"] = Recipe.failed_ids(broken.validate_physical_integrity()).has("panel")
		rows.append({"name": "stacked_source_" + ("narrow" if narrow else "two_post"), "evidenceLevel": "actual_courtyard_producer_support_with_synthetic_panel_contract", "passed": checks.values().all(func(value): return bool(value)), "checks": checks, "result": result})
	for mode in ["missing_root", "foreign_root", "extra_foreign_root", "duplicate_ancestor", "floating_paving", "forged_paving_root", "incompatible_root_intent", "conflicting_root_intents", "blocked_seat", "missing_mandatory_dependency", "closure_collection_limit", "closure_spatial_limit", "walkable_only_seat", "recipe_only_walkable_seat"]:
		var b = _support_stack(true)
		var upstream: Array = ["root"]
		match mode:
			"missing_root": b.parts.erase(b.find_part("root"))
			"foreign_root": b.find_part("root").position.x += 20.0
			"extra_foreign_root":
				b.add_part({"id": "unrelated", "kind": "foundation", "material": "stone_foundation", "position": Vector3(20, 0.31, 0), "size": Vector3(2, 0.62, 2), "collision": true})
				upstream.append("unrelated")
			"duplicate_ancestor": upstream.append("root")
			"floating_paving": b.find_part("paving").position.y += 0.04
			"forged_paving_root": b.find_part("paving").recipe["physicalRoot"] = true
			"incompatible_root_intent":
				b.find_part("root").physical_intent = "visual_detail"
				b.find_part("root").recipe["physicalIntent"] = "visual_detail"
			"conflicting_root_intents": b.find_part("root").recipe["physicalIntent"] = "visual_detail"
			"blocked_seat":
				var support_top: float = Recipe.Frame._bounds(b.find_part("paving")).end.y
				b.add_part({"id": "actual_seat_blocker", "kind": "beam", "position": Vector3(0, support_top + 0.1, 0), "size": Vector3(0.8, 0.2, 0.8), "collision": true})
			"missing_mandatory_dependency": b.find_part("paving").recipe.physicalRequiredSupportPartIds = ["absent"]
			"closure_collection_limit":
				for index in range(Recipe.Frame.MAX_SUPPORT_CLOSURE): upstream.append("extra_%d" % index)
			"closure_spatial_limit": b.find_part("root").size.x = 1.0e12
			"walkable_only_seat":
				b.find_part("paving").physical_intent = "walkable_surface"
				b.find_part("paving").recipe["physicalIntent"] = "walkable_surface"
			"recipe_only_walkable_seat":
				b.find_part("paving").physical_intent = ""
				b.find_part("paving").recipe["physicalIntent"] = "walkable_surface"
		var before := var_to_bytes(b.snapshot())
		var result: Dictionary = Recipe.Frame.add_frame_on_support(b, ["panel"], policy, "paving", upstream, true)
		rows.append({"name": mode, "passed": not result.ready and var_to_bytes(b.snapshot()) == before and (mode not in ["walkable_only_seat", "recipe_only_walkable_seat"] or result.reason == "unsupported_bearing_intent"), "result": result})
	# Nine corner/centre samples can all pass while intermediate floor samples
	# are unsupported. The new closure must reject that actual coverage gap.
	var sparse = _support_stack(true)
	sparse.parts.erase(sparse.find_part("root"))
	var roots: Array = []
	for index in range(3):
		var id := "strip_%d" % index
		roots.append(id)
		sparse.add_part({"id": id, "kind": "foundation", "material": "stone_foundation", "position": Vector3(float(index - 1) * 3.0, 0.31, 0), "size": Vector3(0.5, 0.62, 6.2), "collision": true})
	sparse.find_part("paving").recipe.physicalRequiredSupportPartIds = roots.duplicate()
	sparse.find_part("paving").physical_intent = "walkable_surface"
	sparse.find_part("paving").recipe["physicalIntent"] = "walkable_surface"
	# Structural seat above the walkable layer keeps the selected seat class
	# valid; the incomplete 25-point coverage must fail in its upstream layer.
	var paving_top: float = Recipe.Frame._bounds(sparse.find_part("paving")).end.y
	sparse.add_part({"id": "structural_seat", "kind": "foundation", "material": "stone_foundation", "position": Vector3(0, paving_top + 0.1, 0), "size": Vector3(0.4, 0.2, 0.4), "collision": true, "recipe": {"physicalRequiredSupportPartIds": ["paving"]}})
	var sparse_before := var_to_bytes(sparse.snapshot())
	var normal = Recipe.copy_blueprint(sparse.snapshot())
	Recipe.clear_caches(normal)
	var normal_physical: Dictionary = normal.validate_physical_integrity()
	var paving_checks: Array = normal_physical.checks.filter(func(check): return check.partId == "paving")
	var rejected: Dictionary = Recipe.Frame.validate_support_closure(sparse, "structural_seat", roots + ["paving"])
	rows.append({"name": "nine_samples_pass_but_25_gap_rejected", "passed": paving_checks.size() == 1 and paving_checks[0].passed and not rejected.ready and rejected.reason in ["incomplete_25_point_support_coverage", "support_sample_has_no_real_rooted_contact"] and var_to_bytes(sparse.snapshot()) == sparse_before, "result": rejected})
	return rows


func _broad_paving_controls() -> Array:
	var rows: Array = []
	for side in [-1.0, 1.0]:
		var b = _producer_support_stack(false)
		var original: Dictionary = b.snapshot()
		var panel = b.find_part("panel")
		var outward := Vector3(side, 0, 0)
		var plan: Dictionary = Recipe._supported_broad_region(b, [panel], outward, [])
		var checks := {"planned": bool(plan.ready), "planning_source_unchanged": _digest(original) == _digest(b.snapshot())}
		var unfiltered: Dictionary = Recipe._supported_broad_region(b, [panel], outward, [], false)
		checks["filtered_unfiltered_full_span_choice_exact"] = _same_broad_choice(plan, unfiltered)
		checks["one_source_build_initial_scan_charged"] = plan.get("broadWork", {}).get("sourceBuilds") == 1 and plan.broadWork.sourceScans == b.parts.size() and plan.projectionWork >= plan.broadWork.sourceScans + plan.broadWork.filterScans
		var result: Dictionary = {}
		if plan.ready:
			var policy := {"outward": outward, "reservedVolumes": [], "furnitureParts": [], "bearingWidth": Recipe.Frame.POST_WIDTH, "bearingNormalCenter": plan.center, "postSpanOffsets": plan.offsets}
			result = Recipe.Frame.add_frame_on_support(b, [panel.id], policy, plan.supportId, plan.upstreamIds)
			checks["constructed"] = bool(result.ready)
			checks["bounded_projection"] = plan.projectionWork <= 131072
			if result.ready:
				var support = b.find_part(plan.supportId)
				var feet: Array = b.parts.filter(func(part): return result.partIds.has(part.id) and part.material_id == "stone_foundation")
				var bounds: AABB = Recipe.Frame._bounds(support)
				var footprint := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
				checks["actual_producer_paving_selected"] = support.semantic == "castle_courtyard_paving" and plan.mode == "same_support_two_post"
				checks["two_feet_same_actual_surface"] = feet.size() == 2 and feet.all(func(foot):
					var box: AABB = Recipe.Frame._bounds(foot)
					return footprint.encloses(Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))) and absf(box.position.y - bounds.end.y) <= Recipe.Frame.EPS and foot.recipe.physicalRequiredSeatPartIds == [support.id])
				checks["unchanged_source_and_real_25_point_closure"] = _preserved(original, b.snapshot(), result.memberIds, result.partIds) and result.supportCoverage.all(func(coverage): return coverage.sampleCount == 25 and coverage.supportedCount == 25)
				var emitted = Recipe.copy_blueprint(b.snapshot())
				Recipe.clear_caches(emitted)
				checks["emitted_complete_physical_pass"] = emitted.validate_physical_integrity().passed
		rows.append({"name": "actual_courtyard_broad_paving_" + str(side), "evidenceLevel": "actual_courtyard_producer_support_with_synthetic_broad_panel", "passed": checks.values().all(func(value): return bool(value)), "checks": checks, "plan": plan, "result": result})
	for mode in ["only_one_foot_supported", "support_gap", "foreign_furniture"]:
		var b = _producer_support_stack(false)
		var panel = b.find_part("panel")
		var paving = b.parts.filter(func(part): return part.semantic == "castle_courtyard_paving")[0]
		var root = b.parts.filter(func(part): return part.semantic == "castle_courtyard_foundation")[0]
		var furniture: Array = []
		var reserved: Array = []
		match mode:
			"only_one_foot_supported":
				paving.position.z = -1.05
				paving.size.z = 0.9
			"support_gap": paving.position.y += 0.04
			"foreign_furniture":
				var top: float = Recipe.Frame._bounds(paving).end.y
				var record := {"id": "foreign_fixture_bench", "position": Vector3(0, top, 0), "occupiedSize": Vector3(2, 1.4, 4), "rotation": Vector3.ZERO}
				furniture.append(record)
				reserved.append(Recipe.Frame.furnishing_bounds(record).bounds)
		var original: Dictionary = b.snapshot()
		var furniture_before := _digest(furniture)
		var plan: Dictionary = Recipe._supported_broad_region(b, [panel], Vector3.RIGHT, reserved)
		var unfiltered: Dictionary = Recipe._supported_broad_region(b, [panel], Vector3.RIGHT, reserved, false)
		var policy := {"outward": Vector3.RIGHT, "reservedVolumes": [], "furnitureParts": furniture, "bearingWidth": Recipe.Frame.POST_WIDTH, "bearingNormalCenter": 0.0}
		var rejected: Dictionary = Recipe.Frame.add_frame_on_support(b, [panel.id], policy, paving.id, [root.id])
		var expected := {"only_one_foot_supported": "missing_or_ambiguous_grounded_footing_seat", "support_gap": "support_sample_has_no_real_rooted_contact", "foreign_furniture": "reserved_interior_access_or_furniture_blocked"}
		rows.append({"name": mode, "passed": not plan.ready and not rejected.ready and rejected.reason == expected[mode] and _same_broad_choice(plan, unfiltered) and _digest(original) == _digest(b.snapshot()) and _digest(furniture) == furniture_before, "plan": plan, "frameResult": rejected})
	return rows


func _inset_bearing_controls() -> Array:
	var rows: Array = []
	for end_side in [-1.0, 1.0]:
		var b = _producer_support_stack(false)
		var panel = b.find_part("panel")
		var panel_bounds: AABB = Recipe.Frame._bounds(panel)
		# Synthetic retained joinery placed from panel edges, using real frame
		# sections. No special production owner/seed or authored repair pose.
		var corner_z: float = panel_bounds.get_center().z + end_side * (panel_bounds.size.z * 0.5 - Recipe.Frame.POST_WIDTH * 0.75)
		var corner = b.add_part({"id": "retained_corner", "kind": "beam", "material": "timber_beam", "position": Vector3(-0.2, 2.36, corner_z), "size": Vector3(Recipe.Frame.POST_WIDTH, 2.0, Recipe.Frame.POST_WIDTH), "collision": false, "semantic": "citadel_urban_frame"})
		var furnishing := {"id": "retained_contents", "position": Vector3(2, 0.76, 2), "occupiedSize": Vector3(0.3, 0.4, 0.3), "recipe": {}}
		var furniture: Array = [furnishing]
		var furniture_digest := _digest(furniture)
		var reserved: Array = [Recipe.Frame.furnishing_bounds(furnishing).bounds]
		var original: Dictionary = b.snapshot()
		var corner_before := _digest(corner.snapshot())
		var plan: Dictionary = Recipe._supported_broad_region(b, [panel], Vector3.LEFT, reserved)
		var checks := {"inset_planned": plan.ready and plan.get("mode") == "same_support_inset_end_two_post", "planning_source_furniture_immutable": _digest(b.snapshot()) == _digest(original) and _digest(furniture) == furniture_digest}
		var unfiltered: Dictionary = Recipe._supported_broad_region(b, [panel], Vector3.LEFT, reserved, false)
		checks["filtered_unfiltered_inset_choice_exact"] = _same_broad_choice(plan, unfiltered)
		checks["single_context_normals_reused_and_far_reservation_eliminated"] = plan.get("broadWork", {}).get("sourceBuilds") == 1 and plan.broadWork.normalReuses > 0 and plan.broadWork.localObstacleCount < plan.broadWork.allObstacleCount
		var result: Dictionary = {}
		if plan.ready:
			var reordered = Recipe.copy_blueprint(original)
			reordered.parts.reverse()
			var again: Dictionary = Recipe._supported_broad_region(reordered, [reordered.find_part(panel.id)], Vector3.LEFT, reserved)
			checks["geometry_deterministic_under_reorder"] = again.ready and again.get("sillSpanBounds") == plan.get("sillSpanBounds") and again.center == plan.center and again.offsets == plan.offsets and again.supportId == plan.supportId
			var policy := {"outward": Vector3.LEFT, "reservedVolumes": [], "furnitureParts": furniture, "bearingWidth": Recipe.Frame.POST_WIDTH, "bearingNormalCenter": plan.center, "postSpanOffsets": plan.offsets, "sillSpanBounds": plan.get("sillSpanBounds")}
			result = Recipe.Frame.add_frame_on_support(b, [panel.id], policy, plan.supportId, plan.upstreamIds)
			checks["inset_constructed"] = result.ready and result.get("mode") == "inset_end_two_post"
			if result.ready:
				var by_id: Dictionary = {}
				for part in b.parts: by_id[part.id] = part
				var sill_bounds: AABB = Recipe.Frame._bounds(by_id[result.sillId])
				checks["full_sections_and_inset_endpoints"] = by_id[result.sillId].size.x == Vector3(Recipe.Frame.POST_WIDTH, 0, 0).x and by_id[result.sillId].size.y == Vector3(0, Recipe.Frame.SILL_HEIGHT, 0).y and sill_bounds.size.z < panel_bounds.size.z
				var seat_contained := true
				for id in result.memberIds:
					var member = by_id[id]
					var bounds: AABB = Recipe.Frame._bounds(member)
					var facts: Array = member.recipe.get("physicalRequiredSeatFacts", [])
					seat_contained = seat_contained and facts.size() == 1
					for fact in facts:
						seat_contained = seat_contained and fact.seatId == result.sillId and fact.localPatchHalfExtents.x > 0 and fact.localPatchHalfExtents.y > 0
						for x in [-1.0, 1.0]:
							for z in [-1.0, 1.0]:
								var point: Vector3 = b.part_transform(member) * (fact.localPatchCenter + Vector3(x * fact.localPatchHalfExtents.x, 0, z * fact.localPatchHalfExtents.y))
								seat_contained = seat_contained and point.x >= bounds.position.x and point.x <= bounds.end.x and point.z >= bounds.position.z and point.z <= bounds.end.z and point.x >= sill_bounds.position.x and point.x <= sill_bounds.end.x and point.z >= sill_bounds.position.z and point.z <= sill_bounds.end.z and absf(point.y - sill_bounds.end.y) <= Recipe.Frame.EPS
				checks["finite_panel_seat_corners_inside_both_actual_parts"] = seat_contained
				var left_post = by_id[result.postIds[0]]
				var right_post = by_id[result.postIds[1]]
				checks["original_panel_end_support_limit_retained"] = left_post.position.z - panel_bounds.position.z <= Recipe.Frame.maximum_post_inset(panel_bounds.size.z) and panel_bounds.end.z - right_post.position.z <= Recipe.Frame.maximum_post_inset(panel_bounds.size.z)
				checks["corner_contents_and_original_source_exact"] = _preserved(original, b.snapshot(), result.memberIds, result.partIds) and _digest(corner.snapshot()) == corner_before and _digest(furniture) == furniture_digest
				var clear := true
				for id in result.partIds:
					if Recipe.Frame._penetrates(Recipe.Frame._bounds(by_id[id]).grow(Recipe.CLEARANCE), Recipe.Frame._bounds(corner)): clear = false
				checks["all_added_parts_clear_retained_corner"] = clear
				checks["complete_real_support_and_joint_validation"] = result.stagedPhysical.passed and result.supportCoverage.all(func(coverage): return coverage.sampleCount == 25 and coverage.supportedCount == 25)
				if end_side < 0:
					for mode in ["end_limit", "post_seat", "corner_collision", "missing_panel_seat", "door", "furniture", "deep_corner", "interior_blocker"]:
						var bad = Recipe.copy_blueprint(original)
						var bad_policy: Dictionary = policy.duplicate(true)
						var member_ids: Array = [panel.id]
						var expected := ""
						match mode:
							"end_limit":
								bad_policy.postSpanOffsets.x = -panel_bounds.size.z * 0.5 + Recipe.Frame.maximum_post_inset(panel_bounds.size.z) + 0.02
								expected = "post_span_offsets_exceed_bearing_envelope"
							"post_seat":
								bad_policy.sillSpanBounds.x = left_post.position.z
								expected = "post_not_fully_seated_under_inset_sill"
							"corner_collision":
								bad_policy.sillSpanBounds.x = panel_bounds.position.z + Recipe.CLEARANCE
								expected = "existing_source_geometry_blocked"
							"missing_panel_seat":
								var full = bad.find_part(panel.id)
								var edge_record: Dictionary = full.snapshot()
								edge_record.id = "edge_panel"
								edge_record.size.z = 0.2
								edge_record.position.z = panel_bounds.position.z + 0.1
								full.size.z = panel_bounds.size.z - 0.2
								full.position.z = panel_bounds.position.z + 0.2 + full.size.z * 0.5
								bad.add_part(edge_record)
								member_ids.append(edge_record.id)
								expected = "panel_has_no_finite_sill_seat"
							"door":
								var door_size := Vector3(0.14, 0.8, 1.0)
								var door_desc: Dictionary = Recipe.Frame.DoorGeometry.describe(door_size)
								var door_position: Vector3 = left_post.position - door_desc.brace.position
								door_position.z = left_post.position.z - door_desc.brace.position.z - door_desc.brace.size.z * 0.5 + 0.01
								bad.add_part({"id": "blocking_door", "kind": "door", "material": "timber", "position": door_position, "size": door_size})
								expected = "ordinary_door_visual_geometry_blocked"
							"furniture":
								bad_policy.furnitureParts.append({"id": "blocking_furniture", "position": Vector3(left_post.position.x, Recipe.Frame._bounds(left_post).position.y, left_post.position.z), "occupiedSize": Vector3(0.4, 0.5, 0.4)})
								expected = "reserved_interior_access_or_furniture_blocked"
							"deep_corner":
								bad.find_part(corner.id).position.z += Recipe.Frame.POST_WIDTH
								expected = "existing_source_geometry_blocked"
							"interior_blocker":
								bad.add_part({"id": "interior_sill_obstacle", "kind": "beam", "material": "timber_beam", "position": Vector3(plan.center, sill_bounds.get_center().y, panel_bounds.get_center().z), "size": Vector3(0.3, 0.3, 0.3)})
								expected = "existing_source_geometry_blocked"
						var bad_before := _digest(bad.snapshot())
						var policy_before := _digest(bad_policy)
						var rejected: Dictionary = Recipe.Frame.add_frame_on_support(bad, member_ids, bad_policy, plan.supportId, plan.upstreamIds)
						var no_fit := true
						var equivalent := true
						if mode in ["door", "furniture"]:
							var test_reserved: Array = reserved.duplicate()
							var doors: Dictionary = Recipe.Frame.closed_door_reservations(bad)
							test_reserved.append_array(doors.volumes)
							for record in bad_policy.furnitureParts: test_reserved.append(Recipe.Frame.furnishing_bounds(record).bounds)
							var filtered_plan: Dictionary = Recipe._supported_broad_region(bad, [bad.find_part(panel.id)], Vector3.LEFT, test_reserved)
							var full_plan: Dictionary = Recipe._supported_broad_region(bad, [bad.find_part(panel.id)], Vector3.LEFT, test_reserved, false)
							equivalent = _same_broad_choice(filtered_plan, full_plan)
						if mode in ["deep_corner", "interior_blocker"]:
							var failed_plan: Dictionary = Recipe._supported_broad_region(bad, [bad.find_part(panel.id)], Vector3.LEFT, reserved)
							no_fit = not failed_plan.ready and failed_plan.reason == "no_clear_broad_bearing_region"
						rows.append({"name": "inset_reject_" + mode, "passed": not rejected.ready and rejected.get("reason") == expected and no_fit and equivalent and _digest(bad.snapshot()) == bad_before and _digest(bad_policy) == policy_before, "result": rejected, "noFitWhereRequired": no_fit, "filteredUnfilteredEquivalent": equivalent})
		rows.append({"name": "inset_end_" + str(end_side), "evidenceLevel": "actual_courtyard_support_synthetic_retained_corner_and_panel", "passed": checks.values().all(func(value): return bool(value)), "checks": checks, "plan": plan, "result": result})
	return rows


func _same_broad_choice(a: Dictionary, c: Dictionary) -> bool:
	# Budget counts differ intentionally; selection, geometry and support do not.
	for key in ["ready", "reason", "center", "offsets", "supportId", "supportTop", "upstreamIds", "mode", "sillSpanBounds"]:
		if var_to_bytes(a.get(key)) != var_to_bytes(c.get(key)): return false
	return true


func _batch_transaction_controls() -> Array:
	var b = Blueprint.new("small_actual_facade_batch", 701, "timber")
	b.set_recipe({"foundationHeight": 0.62, "courtyardResidences": []})
	Urban.add_street_house(b, "producer", Vector3(-7, 0, 0), 7.2, 9.45, 6.2, -1.0, 0.62, "painted_brick_cream", 0.0)
	var source: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var policy := {"furnitureParts": [], "reservedVolumes": [], "maxBatchCalls": 8, "progressCallback": Callable(self, "_record_batch_progress")}
	_progress_label = "small_batch"
	var result: Dictionary = Recipe.compose_bottom_bays(b, policy)
	var checks := {"ready": bool(result.ready)}
	if result.ready:
		var old_failed := Recipe.failed_ids(result.beforePhysical)
		var new_failed := Recipe.failed_ids(result.afterPhysical)
		var passing: Dictionary = {}
		for check in result.afterPhysical.checks: passing[check.partId] = bool(check.passed)
		checks["two_actual_global_validations"] = result.fullValidationCount == 2 and result.fullValidationsStarted == 2
		checks["locals_not_reported_as_global_truth"] = result.calls.all(func(call): return call.globalValidationDeferred and not call.has("resolvedFacadeIds") and (not call.ready or call.localValidated))
		checks["final_members_additions_and_skipped_targets_pass"] = (result.memberIds + result.partIds + result.skippedIncidentallySupportedIds).all(func(id): return passing.get(id, false))
		checks["no_new_failures_and_actual_reduction"] = new_failed.all(func(id): return old_failed.has(id)) and not result.resolvedFacadeIds.is_empty() and result.resolvedFacadeIds.all(func(id): return old_failed.has(id) and not new_failed.has(id))
		checks["source_preserved"] = _preserved(source, b.snapshot(), result.memberIds, result.partIds) and range(aliases.size()).all(func(index): return is_same(aliases[index], b.parts[index]))
		var distinct: Dictionary = {}
		for id in result.memberIds: distinct[id] = true
		checks["distinct_repaired_targets"] = distinct.size() == result.memberIds.size()
		checks["compact_read_only_progress_completed"] = _progress_ok and _last_callback.get("phase") == "committed" and _last_callback.get("fullValidationsCompleted") == 2 and _last_callback.get("localSuccessfulCalls") == result.calls.filter(func(call): return call.ready).size()
	var rows: Array = [{"name": "actual_producer_private_batch", "passed": checks.values().all(func(value): return bool(value)), "checks": checks, "result": result}]
	var exhausted = Recipe.copy_blueprint(source)
	var budget_policy: Dictionary = policy.duplicate(true)
	budget_policy.maxBatchCalls = 1
	_progress_label = "small_budget_rollback"
	var budget: Dictionary = Recipe.compose_bottom_bays(exhausted, budget_policy)
	rows.append({"name": "private_success_then_budget_exhaustion_atomic", "passed": not budget.ready and budget.reason == "batch_work_limit_exceeded" and budget.get("privateSuccessfulCalls", 0) == 1 and budget.fullValidationCount == 1 and _digest(exhausted.snapshot()) == _digest(source), "result": budget})
	var invalid_source = Recipe.copy_blueprint(source)
	var invalid_policy: Dictionary = policy.duplicate(true)
	invalid_policy.progressCallback = 1
	var invalid: Dictionary = Recipe.compose_bottom_bays(invalid_source, invalid_policy)
	rows.append({"name": "invalid_progress_callback_atomic", "passed": not invalid.ready and invalid.reason == "invalid_progress_callback" and _digest(invalid_source.snapshot()) == _digest(source)})
	return rows


func _whole_citadel_case() -> Dictionary:
	var started := Time.get_ticks_usec()
	_fixture_progress("whole_compose_begin")
	var row := {"enabled": true, "passed": false, "fixture": WHOLE_FIXTURE.duplicate(true), "checks": {}, "input": "fresh Castle.build + integrated Urban.compose; no prototype shop edits"}
	var b = Castle.build(WHOLE_FIXTURE.seed, {"biome": WHOLE_FIXTURE.biome, "siteKey": WHOLE_FIXTURE.siteKey, "citadelScale": WHOLE_FIXTURE.citadelScale})
	if b == null or Urban.compose(b, WHOLE_FIXTURE.seed) == null:
		row["reason"] = "fresh_integrated_composition_failed"
		return row
	var source: Dictionary = b.snapshot()
	row["sourceDigest"] = _digest(source)
	row["fixtureDigest"] = _digest(WHOLE_FIXTURE)
	row["contractIdentity"] = _contract_identity()
	row["pairedAcceptancePending"] = true
	row["sourcePartCount"] = b.parts.size()
	row["composeUsec"] = Time.get_ticks_usec() - started
	_fixture_progress("whole_compose_end")
	var aliases: Array = b.parts.duplicate()
	var furniture = Furniture.build(Recipe.copy_blueprint(source), WHOLE_FIXTURE.furnitureSeed)
	if furniture == null:
		row["reason"] = "whole_furnishing_failed"
		return row
	var furniture_source: Dictionary = furniture.snapshot()
	var reservations: Array = furniture.protected_access_reservations.duplicate(true)
	var policy := {"furnitureParts": furniture_source.parts, "reservedVolumes": reservations}
	var policy_digest := _digest(policy)
	row["policyDigest"] = policy_digest
	policy["progressCallback"] = Callable(self, "_record_batch_progress")
	_progress_label = "whole_batch"
	var batch_started := Time.get_ticks_usec()
	var result: Dictionary = Recipe.compose_bottom_bays(b, policy)
	row["batchUsec"] = Time.get_ticks_usec() - batch_started
	row["batch"] = result # The only complete before/after physical reports.
	row.checks["complete"] = bool(result.get("complete", false)) and bool(result.ready)
	var policy_records: Dictionary = policy.duplicate(true)
	policy_records.erase("progressCallback")
	row.checks["policy_furniture_and_reservations_immutable"] = _digest(policy_records) == policy_digest and policy.progressCallback == Callable(self, "_record_batch_progress") and _digest(furniture.snapshot()) == _digest(furniture_source) and _digest(furniture.protected_access_reservations) == _digest(reservations)
	if not result.ready:
		row.checks["failure_atomic"] = _digest(b.snapshot()) == row.sourceDigest
		return row
	var output: Dictionary = b.snapshot()
	row["outputDigest"] = _digest(output)
	row.checks["all_original_geometry_rooms_recipe_and_contents_preserved"] = _preserved(source, output, result.memberIds, result.partIds, result.get("pavingFinishPartIds", []))
	row.checks["committed_paving_unions_replay_and_retain_feet"] = result.get("pavingReplay", {}).get("ready", false) and result.pavingReplay.finishes.size() == result.get("pavingFinishPartIds", []).size() and result.pavingReplay.finishes.all(func(record): return record.allRetainedFeetClear)
	row.checks["original_aliases_preserved"] = range(aliases.size()).all(func(i): return is_same(aliases[i], b.parts[i]))
	var old_failures := Recipe.failed_ids(result.beforePhysical)
	var new_failures := Recipe.failed_ids(result.afterPhysical)
	row["physicalFailuresBefore"] = old_failures.size()
	row["physicalFailuresAfter"] = new_failures.size()
	row["observedBaselineMatchesReviewed226"] = old_failures.size() == 226
	row["facadeResolvedCount"] = result.resolvedFacadeIds.size()
	row.checks["actual_facade_failures_reduced"] = not result.resolvedFacadeIds.is_empty() and result.facadeFailuresBefore - result.facadeFailuresAfter == result.resolvedFacadeIds.size()
	row.checks["no_added_failed_ids"] = new_failures.all(func(id): return old_failures.has(id))
	row.checks["remaining_headers_and_bottom_rows_explicit"] = result.remainingPanels.size() == result.remainingFacadeIds.size() and result.remainingPanels.all(func(panel): return result.remainingFacadeIds.has(panel.partId) and not String(panel.reason).is_empty())
	row.checks["two_global_validations_with_local_frames"] = result.fullValidationCount == 2 and result.fullValidationsStarted == 2 and result.calls.all(func(call): return not call.ready or call.localValidated)
	row.checks["no_intermediate_resolved_claims"] = result.calls.all(func(call): return not call.has("resolvedFacadeIds") and call.globalValidationDeferred)
	row.checks["all_declared_houses_examined"] = result.houses.size() == result.houseCount and result.houses.all(func(house): return house.stopReason == "all_current_bottom_candidates_examined")
	row.checks["per_call_reports_compact"] = result.calls.all(func(call): return not call.has("beforePhysical") and not call.has("afterPhysical") and call.attempts.all(func(attempt): return not attempt.has("stagedPhysical") and not attempt.has("result")))
	var next_furniture = Furniture.build(Recipe.copy_blueprint(output), WHOLE_FIXTURE.furnitureSeed)
	row["furniturePartCount"] = furniture_source.parts.size()
	row["reservationCount"] = reservations.size()
	row.checks["nonempty_full_furniture_exact"] = not furniture_source.parts.is_empty() and next_furniture != null and _digest(next_furniture.snapshot()) == _digest(furniture_source)
	row.checks["full_reservations_exact"] = next_furniture != null and _digest(next_furniture.protected_access_reservations) == _digest(reservations)
	# Independent emitted-source check; retain only IDs/time, not a third copy
	# of every whole-world physical check in the JSON artifact.
	var emitted = Recipe.copy_blueprint(output)
	Recipe.clear_caches(emitted)
	var emitted_started := Time.get_ticks_usec()
	_fixture_progress("whole_emitted_validation_begin")
	var emitted_physical: Dictionary = emitted.validate_physical_integrity()
	_fixture_progress("whole_emitted_validation_end")
	row["emittedValidationUsec"] = Time.get_ticks_usec() - emitted_started
	row.checks["emitted_physical_matches_batch"] = Recipe.failed_ids(emitted_physical) == new_failures
	row["physicalGatePassed"] = emitted_physical.passed
	# These exact full-source budget assertions run in the mandatory companion
	# against this immutable input, not a repeated generation or cached report.
	row["budgetRollback"] = {"status": "mandatory_companion_pending", "contractMode": "full_rollback", "sourceDigest": row.sourceDigest, "fixtureDigest": row.fixtureDigest}
	row["elapsedUsec"] = Time.get_ticks_usec() - started
	row["passed"] = row.checks.values().all(func(value): return bool(value))
	if row.passed and not _export_path.is_empty():
		_pending_export = {"schemaVersion": 1, "provenance": "successful_full_facade_recipe_contract", "fixture": WHOLE_FIXTURE.duplicate(true),
			"beforeSnapshot": source, "afterSnapshot": output, "furnitureSnapshot": furniture_source, "protectedReservations": reservations,
			"partIds": result.partIds.duplicate(), "memberIds": result.memberIds.duplicate(), "pavingFinishPartIds": result.get("pavingFinishPartIds", []).duplicate(), "sourceDigest": row.sourceDigest, "outputDigest": row.outputDigest,
			"fixtureDigest": row.fixtureDigest, "policyDigest": policy_digest, "contractIdentity": row.contractIdentity,
			"mainShardPassed": true, "pairedAcceptancePending": true}
	return row


func _contract_identity() -> Dictionary:
	var identity: Dictionary = {}
	for path in ["res://scripts/testing/buildings/CitadelFacadeRecipeContract.gd", "res://scripts/buildings/FacadeOpeningBearingRecipe.gd", "res://scripts/buildings/FacadeBearingFrameBuilder.gd", "res://scripts/buildings/BuildingDoorGeometry.gd", "res://scripts/buildings/BuildingBlueprint.gd", "res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd", "res://scripts/buildings/TerminalShopFrameBuilder.gd"]:
		identity[path] = FileAccess.get_sha256(path)
	return identity


func _full_rollback_shard() -> Dictionary:
	var started := Time.get_ticks_msec()
	var row := {"contractMode": "full_rollback", "evidenceLevel": "frozen_actual_full_source_budget_rollback_contract", "passed": false, "checks": {}, "elapsedMsec": 0,
		"pairedAcceptancePending": true, "limitations": "Mandatory companion to the successful main shard, not an independent physical/visual gate. No regeneration, publication, or cached physical authority."}
	var path := OS.get_environment("VOXEL_FACADE_ROLLBACK_SOURCE").strip_edges().simplify_path()
	var expected_sha := OS.get_environment("VOXEL_FACADE_ROLLBACK_SHA256").strip_edges().to_lower()
	if not path.is_absolute_path() or not FileAccess.file_exists(path) or expected_sha.length() != 64 or FileAccess.get_sha256(path) != expected_sha:
		row["reason"] = "missing_or_mismatched_main_artifact_sha"
		return row
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		row["reason"] = "main_artifact_open_failed"
		return row
	var length := file.get_length()
	if length <= 0 or length > 268435456:
		file.close()
		row["reason"] = "main_artifact_size_limit"
		return row
	var bytes: PackedByteArray = file.get_buffer(length)
	var read_complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	if not read_complete or FileAccess.get_sha256(path) != expected_sha:
		row["reason"] = "main_artifact_read_incomplete_or_changed"
		return row
	var decoded: Variant = bytes_to_var(bytes) # Object deserialization remains disabled.
	if not decoded is Dictionary:
		row["reason"] = "invalid_main_artifact"
		return row
	var artifact: Dictionary = decoded
	for key in ["beforeSnapshot", "afterSnapshot", "furnitureSnapshot", "fixture", "contractIdentity"]:
		if not artifact.get(key) is Dictionary:
			row["reason"] = "invalid_main_artifact_" + key
			return row
	if not artifact.get("protectedReservations") is Array or not artifact.furnitureSnapshot.get("parts") is Array:
		row["reason"] = "invalid_main_artifact_policy"
		return row
	var policy := {"furnitureParts": artifact.furnitureSnapshot.parts, "reservedVolumes": artifact.protectedReservations}
	row["artifactPath"] = path
	row["artifactSha256"] = expected_sha
	row["sourceDigest"] = _digest(artifact.beforeSnapshot)
	row["fixtureDigest"] = _digest(artifact.fixture)
	row["policyDigest"] = _digest(policy)
	row["contractIdentity"] = _contract_identity()
	row.checks["successful_main_shard_provenance"] = artifact.get("schemaVersion") == 1 and artifact.get("provenance") == "successful_full_facade_recipe_contract" and artifact.get("mainShardPassed") == true and artifact.get("pairedAcceptancePending") == true
	row.checks["matching_frozen_input_and_output"] = row.sourceDigest == artifact.get("sourceDigest") and _digest(artifact.afterSnapshot) == artifact.get("outputDigest")
	row.checks["matching_fixture"] = row.fixtureDigest == artifact.get("fixtureDigest") and row.fixtureDigest == _digest(WHOLE_FIXTURE)
	row.checks["matching_furniture_reservations_policy"] = row.policyDigest == artifact.get("policyDigest")
	row.checks["matching_contract_identity"] = row.contractIdentity == artifact.contractIdentity and row.contractIdentity.values().all(func(value): return String(value).length() == 64)
	if not row.checks.values().all(func(value): return bool(value)):
		row["reason"] = "main_shard_pairing_mismatch"
		return row
	var source: Dictionary = artifact.beforeSnapshot
	var budget_source = Recipe.copy_blueprint(source)
	row.checks["frozen_input_roundtrip_exact"] = _digest(budget_source.snapshot()) == row.sourceDigest
	if not row.checks.frozen_input_roundtrip_exact:
		row["reason"] = "frozen_input_roundtrip_mismatch"
		return row
	var budget_policy: Dictionary = policy.duplicate(true)
	budget_policy["maxBatchCalls"] = 1
	budget_policy["progressCallback"] = Callable(self, "_record_batch_progress")
	_progress_label = "whole_budget_rollback"
	var budget_result: Dictionary = Recipe.compose_bottom_bays(budget_source, budget_policy)
	row["budgetRollback"] = budget_result
	row.checks["batch_budget_atomic"] = not budget_result.ready and budget_result.get("reason") == "batch_work_limit_exceeded" and _digest(budget_source.snapshot()) == row.sourceDigest
	var invalid_source = Recipe.copy_blueprint(source)
	var invalid_policy: Dictionary = policy.duplicate(true)
	invalid_policy["maxBatchCalls"] = Recipe.MAX_BATCH_CALLS + 1
	var invalid: Dictionary = Recipe.compose_bottom_bays(invalid_source, invalid_policy)
	row.checks["invalid_budget_atomic"] = not invalid.ready and invalid.reason == "invalid_batch_budget" and _digest(invalid_source.snapshot()) == row.sourceDigest
	row.checks["frozen_policy_preserved"] = _digest(policy) == row.policyDigest
	row.checks["artifact_still_immutable"] = FileAccess.get_sha256(path) == expected_sha
	row["elapsedMsec"] = Time.get_ticks_msec() - started
	row["passed"] = row.checks.values().all(func(value): return bool(value)) and _progress_ok
	row["pairedAcceptancePending"] = not row.passed
	return row


func _household_contents(snapshot: Dictionary) -> Array:
	return snapshot.parts.filter(func(part): return part.semantic in ["citadel_household_storage", "citadel_household_firewood", "citadel_household_tools", "citadel_household_window_box", "citadel_shopfront_goods"])


func _preserved(before: Dictionary, after: Dictionary, members: Array, additions: Array, paving_finishes: Array = []) -> bool:
	var a := before.duplicate(true)
	var c := after.duplicate(true)
	a.erase("parts")
	c.erase("parts")
	if _digest(a) != _digest(c) or after.parts.size() != before.parts.size() + additions.size(): return false
	for i in range(before.parts.size()):
		var old: Dictionary = before.parts[i].duplicate(true)
		var current: Dictionary = after.parts[i].duplicate(true)
		if members.has(old.id):
			for part in [old, current]:
				part.erase("physicalIntent")
				for key in part.recipe.keys():
					if String(key).begins_with("physical"): part.recipe.erase(key)
		if paving_finishes.has(old.id):
			if not current.recipe.get("pavingFootingJoints") is Dictionary: return false
			old.recipe["pavingFootingJoints"] = current.recipe.pavingFootingJoints
		if _digest(old) != _digest(current): return false
	return after.parts.slice(before.parts.size()).map(func(part): return part.id).all(func(id): return additions.has(id))


func _digest(value: Variant) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()
