extends SceneTree
## Source/service proposal evidence only; no gameplay acceptance.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/HouseholdSignPlacementRecipe.gd")
const Mount = preload("res://scripts/buildings/HouseholdSignMountRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Doors = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
var checks := {}
var report := {}
func _initialize() -> void: call_deferred("_run")
func _read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() > 32 * 1024 * 1024: return {}
	var raw: Variant = f.get_var(false)
	f.close()
	return raw if raw is Dictionary else {}
func _run() -> void:
	var started := Time.get_ticks_usec()
	var out := OS.get_environment("VOXEL_SIGN_PLACEMENT_REPORT")
	var input := OS.get_environment("VOXEL_SIGN_PLACEMENT_INPUT")
	var reference := OS.get_environment("VOXEL_SIGN_PLACEMENT_REFERENCE")
	if not out.is_absolute_path() or FileAccess.file_exists(out) or not DirAccess.dir_exists_absolute(out.get_base_dir()): quit(2); return
	if FileAccess.get_sha256(input) != OS.get_environment("VOXEL_SIGN_PLACEMENT_INPUT_SHA") or FileAccess.get_sha256(reference) != OS.get_environment("VOXEL_SIGN_PLACEMENT_REFERENCE_SHA"): quit(2); return
	var raw := _read(input)
	var ref := _read(reference)
	if not raw.get("afterSnapshot") is Dictionary or not raw.get("protected") is Array or not ref.get("handoff", {}).get("blueprint") is Dictionary: quit(2); return
	report["inputSha256"] = FileAccess.get_sha256(input)
	report["referenceSha256"] = FileAccess.get_sha256(reference)
	var b = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(b)
	if not Copy.validation_grid_work(b).ready: quit(2); return
	var before: Dictionary = b.validate_physical_integrity()
	print("PLACEMENT actual validated ", Time.get_ticks_usec()-started)
	var prefix := "urban_civic_house_east"
	var owner: Dictionary = b.recipe.citadelStreetHouseStructuralRecipes[prefix]
	var arm = b.find_part(owner.signAssembly.armId)
	var board = b.find_part(owner.signAssembly.boardId)
	var door = b.find_part(owner.doorId)
	var frozen := var_to_bytes(b.snapshot())
	var plan_started := Time.get_ticks_usec()
	var plan := Recipe.propose(b, arm, board, door, owner.facadeDeclarationKeys, raw.protected)
	report["planUsec"] = Time.get_ticks_usec()-plan_started
	report["actualPlan"] = plan
	checks["actual_candidate_ready"] = plan.ready
	checks["input_immutable"] = frozen == var_to_bytes(b.snapshot())
	checks["deterministic"] = var_to_bytes(plan) == var_to_bytes(Recipe.propose(b, arm, board, door, owner.facadeDeclarationKeys, raw.protected))
	if plan.ready:
		var next_arm = Part.new(plan.armRecord)
		var next_board = Part.new(plan.boardRecord)
		checks["finite_rooted_socket"] = b.has_rooted_attachment_socket(next_arm, plan.anchorFact)
		checks["existing_mount_rigid_construction_exact"] = plan.sourceDelta == next_arm.position-arm.position and next_board.position == next_arm.position+(board.position-arm.position)
		report["relative_offset_bit_exact_after_translation"] = next_board.position-next_arm.position == board.position-arm.position
		checks["initial_domain_not_fake_bounded_correction"] = Vector2(plan.sourceDelta.y, plan.sourceDelta.z).length() > Mount.MAX_IN_PLANE_TRANSLATION and plan.preferredSourceCorrectionBound == 1.25 and plan.mode == "initial_frontage_choice"
		var panels: Array = b.parts.filter(func(p): return p.id.begins_with(prefix+"_") and p.semantic == "citadel_urban_facade").map(func(p): return p.id)
		var clear := Mount._clear(b, next_arm, next_board, arm.id, board.id, prefix, plan.anchorFact.anchorId, panels, raw.protected.map(func(value): return value.bounds if value is Dictionary else value))
		report["existing_mount_clearance"] = clear
		checks["unchanged_mount_clearance_also_passes"] = clear.ready
		var expected_arm: Dictionary = arm.snapshot()
		expected_arm.position = plan.armRecord.position
		expected_arm.recipe["physicalRequiredAnchorPartIds"] = plan.armRecord.recipe.physicalRequiredAnchorPartIds
		expected_arm.recipe["physicalRequiredAnchorFacts"] = plan.armRecord.recipe.physicalRequiredAnchorFacts
		var expected_board: Dictionary = board.snapshot()
		expected_board.position = plan.boardRecord.position
		checks["design_records_exact_except_pose_and_anchor"] = var_to_bytes(expected_arm) == var_to_bytes(plan.armRecord) and var_to_bytes(expected_board) == var_to_bytes(plan.boardRecord)
		var candidate_b = Copy.copy_blueprint(b.snapshot())
		var staged_arm = candidate_b.find_part(arm.id)
		staged_arm.position = plan.armRecord.position
		staged_arm.recipe["physicalRequiredAnchorPartIds"] = plan.armRecord.recipe.physicalRequiredAnchorPartIds.duplicate(true)
		staged_arm.recipe["physicalRequiredAnchorFacts"] = plan.armRecord.recipe.physicalRequiredAnchorFacts.duplicate(true)
		candidate_b.find_part(board.id).position = plan.boardRecord.position
		var candidate_snapshot: Dictionary = candidate_b.snapshot()
		Copy.clear_caches(candidate_b)
		if not Copy.validation_grid_work(candidate_b).ready: quit(2); return
		var after: Dictionary = candidate_b.validate_physical_integrity()
		var before_ids: Array = Copy.failed_ids(before)
		var after_ids: Array = Copy.failed_ids(after)
		checks["full_snapshot_sign_failure_removed_no_added_failures"] = before_ids.has(arm.id) and not after_ids.has(arm.id) and after_ids.size() == before_ids.size()-1 and after_ids.all(func(id):return before_ids.has(id))
		report["physicalDelta"] = {"beforeFailedCount":before_ids.size(),"afterFailedCount":after_ids.size(),"removed":before_ids.filter(func(id):return not after_ids.has(id)),"added":after_ids.filter(func(id):return not before_ids.has(id))}
		var f := FileAccess.open(out.get_base_dir().path_join("candidate.bin"), FileAccess.WRITE)
		f.store_var({"inputSha256":report.inputSha256,"proposal":plan,"candidateSnapshot":candidate_snapshot},false)
		f.close()
	var r = Copy.copy_blueprint(ref.handoff.blueprint)
	Copy.clear_caches(r)
	if not Copy.validation_grid_work(r).ready: quit(2); return
	r.validate_physical_integrity()
	print("PLACEMENT reference validated ",Time.get_ticks_usec()-started)
	var protected: Array = []
	for record: Dictionary in ref.handoff.furnishingPlan.parts:
		protected.append(Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(Vector3(-record.occupiedSize.x*0.5,0,-record.occupiedSize.z*0.5),record.occupiedSize))
	protected.append_array(ref.handoff.furnishingPlan.get("accessReservations",[]))
	var rows: Array = []
	var ref_frozen := var_to_bytes(r.snapshot())
	for key in r.recipe.citadelStreetHouseStructuralRecipes:
		var household: Dictionary = r.recipe.citadelStreetHouseStructuralRecipes[key]
		if household.signAssembly.is_empty(): continue
		var a = r.find_part(household.signAssembly.armId)
		var sign = r.find_part(household.signAssembly.boardId)
		var d = r.find_part(household.doorId)
		var own_panels: Array = r.parts.filter(func(p): return p.id.begins_with(String(key)+"_") and p.semantic == "citadel_urban_facade").map(func(p): return p.id)
		var original_facts: Array = a.recipe.get("physicalRequiredAnchorFacts", [])
		var original_anchor := String(original_facts[0].get("anchorId","")) if original_facts.size()==1 else ""
		var original_clear := Mount._clear(r,a,sign,a.id,sign.id,String(key),original_anchor,own_panels,protected.map(func(value):return value.bounds if value is Dictionary else value))
		var result := Recipe.propose(r, a, sign, d, household.facadeDeclarationKeys, protected)
		rows.append({"armId":a.id,"originalClear":original_clear,"ready":result.ready,"reason":result.reason,"mode":result.get("mode"),"exact":result.ready and var_to_bytes(result.armRecord)==var_to_bytes(a.snapshot()) and var_to_bytes(result.boardRecord)==var_to_bytes(sign.snapshot()),"detail":result if not result.ready else {}})
		if not rows.back().exact:
			rows.back()["sourceProposal"] = result
			rows.back()["originalArm"] = a.snapshot()
			rows.back()["originalBoard"] = sign.snapshot()
			rows.back()["rootedAnchorChain"] = r.has_rooted_anchor_chain(a,{})
			rows.back()["declaredAnchors"] = a.recipe.get("physicalAnchorPartIds",[]).map(func(id):return r.find_part(id).snapshot())
		report["referenceRows"] = rows
	# Preserve the failed historical comparison explicitly. The critic-approved
	# source policy repairs invalid signs; it does not pretend this is parity.
	report["whole_reference_signs_exact"] = not rows.is_empty() and rows.all(func(row):return row.ready and row.exact and row.mode == "existing_clear_exact")
	var clear_rows: Array = rows.filter(func(row):return row.originalClear.ready)
	var blocked_rows: Array = rows.filter(func(row):return not row.originalClear.ready)
	checks["already_clear_reference_signs_exact"] = not clear_rows.is_empty() and clear_rows.all(func(row):return row.ready and row.exact and row.mode == "existing_clear_exact")
	checks["blocked_reference_has_explicit_source_repair"] = not blocked_rows.is_empty() and blocked_rows.all(func(row):return row.ready and not row.exact and row.mode in ["original_template_preferred","initial_frontage_choice"])
	report["referenceCounts"] = {"total":rows.size(),"alreadyClear":clear_rows.size(),"blockedBeforeProposal":blocked_rows.size()}
	# Original 16/17 rejection and contract are retained under contract-06.
	# Production final-source and non-sign/furniture equality are separate gates.
	var invalid_arm = Part.new(arm.snapshot())
	invalid_arm.id = "foreign_sign_arm"
	checks["foreign_template_rejected"] = not Recipe.propose(b,invalid_arm,board,door,owner.facadeDeclarationKeys,raw.protected).ready
	checks["invalid_protected_volume_rejected"] = not Recipe.propose(b,arm,board,door,owner.facadeDeclarationKeys,[AABB()]).ready
	checks["duplicate_declaration_rejected"] = not Recipe.propose(b,arm,board,door,owner.facadeDeclarationKeys + owner.facadeDeclarationKeys,raw.protected).ready
	var angle_checks: Array = []
	for value in ["bad","0",true,INF]:
		var bad = Copy.copy_blueprint(b.snapshot())
		bad.find_part(door.id).recipe["openSwing"] = value
		var bad_frozen := var_to_bytes(bad.snapshot())
		var invalid = Recipe.propose(bad,bad.find_part(arm.id),bad.find_part(board.id),bad.find_part(door.id),owner.facadeDeclarationKeys,raw.protected)
		angle_checks.append(not invalid.ready and invalid.reason in ["invalid_door_angle","invalid_door_sweep"] and bad_frozen == var_to_bytes(bad.snapshot()))
	checks["malformed_and_nonfinite_door_angles_rejected_atomically"] = angle_checks.all(func(v):return v==true)
	checks["reference_immutable"] = ref_frozen == var_to_bytes(r.snapshot())
	checks["frozen_files_unchanged"] = FileAccess.get_sha256(input) == report.inputSha256 and FileAccess.get_sha256(reference) == report.referenceSha256
	report["checks"] = checks
	report["passed"] = checks.values().all(func(c):return c==true)
	report["elapsedUsec"] = Time.get_ticks_usec()-started
	report["limitations"] = "Direct source proposal contract. Does not exercise production orchestration, full facade preparation, rendered geometry, live physics, navigation or gameplay acceptance."
	var f := FileAccess.open(out,FileAccess.WRITE)
	f.store_string(JSON.stringify(_json(report),"\t"))
	f.close()
	print("PLACEMENT RESULT ",report.passed," ",checks)
	quit(0 if report.passed else 1)
func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x,value.y,value.z]
	if value is Vector2: return [value.x,value.y]
	if value is Dictionary:
		var out := {}
		for key in value: out[str(key)] = _json(value[key])
		return out
	if value is Array: return value.map(func(v):return _json(v))
	return value
