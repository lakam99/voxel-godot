extends SceneTree

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")


func _init() -> void:
	var seed := int(OS.get_environment("VOXEL_CITADEL_PHYSICAL_SEED"))
	if seed == 0:
		seed = 208158
	var site_key := OS.get_environment("VOXEL_CITADEL_PHYSICAL_SITE_KEY")
	if site_key.is_empty():
		site_key = "citadel-life"
	var blueprint = CastleCompoundBlueprintBuilderScript.build(seed, {
		"biome": "forest",
		"siteKey": site_key,
		"citadelScale": 1.25
	})
	var focused := OS.get_environment("VOXEL_CITADEL_PHYSICAL_FOCUSED") == "1"
	var critic_mode := OS.get_environment("VOXEL_CITADEL_PHYSICAL_CRITIC") == "1"
	var diagnostic_only := OS.get_environment("VOXEL_CITADEL_PHYSICAL_DIAGNOSTIC_ONLY") == "1"
	var integrity: Dictionary = {"passed": true, "checks": [], "checkedPartCount": 0, "violations": []} if focused and not critic_mode else blueprint.validate_physical_integrity()
	var failed_checks: Array[Dictionary] = []
	for check_value in integrity.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if not bool(check.get("passed", false)):
			failed_checks.append(check)
	var negative_controls := critic_dependency_negative_controls(blueprint) if critic_mode else {} if focused else dependency_negative_controls(blueprint)
	if not diagnostic_only:
		negative_controls["processionalFinalRoadbedRoot"] = processional_handoff_root_negative_check(blueprint, "processional_04a", "roadbed")
		negative_controls["processionalForecourtRoot"] = processional_handoff_root_negative_check(blueprint, "processional_04b", "transition")
	var ramp_support_clearance := {"passed": true, "failureCount": 0, "samples": [], "violations": []} if focused and not critic_mode else ramp_support_clearance_contract(blueprint)
	var raised_route_coverage := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var core_slice_coverage := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(core_blueprint_slice(blueprint))
	var forecourt_paving_handoff := level_keep_forecourt_paving_handoff_contract()
	var failed_negative_controls: Array[Dictionary] = []
	for control_name_value in negative_controls:
		var control_name := String(control_name_value)
		var control: Dictionary = negative_controls[control_name] as Dictionary
		if not bool(control.get("passed", false)):
			failed_negative_controls.append({"control": control_name, "details": control})
	var passed := bool(integrity.get("passed", false)) and bool(raised_route_coverage.get("passed", false)) and failed_negative_controls.is_empty() and bool(ramp_support_clearance.get("passed", false)) and bool(forecourt_paving_handoff.get("passed", false))
	var report := {
		"runnerId": "citadel_physical_integrity_contract",
		"evidenceLevel": "headless_recipe_contract",
		"focused": focused,
		"criticMode": critic_mode,
		"diagnosticOnly": diagnostic_only,
		"seed": seed,
		"siteKey": site_key,
		"blueprintId": String(blueprint.id),
		"partCount": blueprint.parts.size(),
		"physicalIntegrity": integrity,
		"stairAssemblyDiagnostics": stair_assembly_diagnostics(blueprint),
		"roofFrameDiagnostics": roof_frame_diagnostics(blueprint),
		"roofFrameFailureDiagnostics": roof_frame_failure_diagnostics(blueprint),
		"attachmentSocketFailureDiagnostics": attachment_socket_failure_diagnostics(blueprint),
		"rampSupportClearance": ramp_support_clearance,
		"routeGeometryDiagnostics": route_geometry_diagnostics(blueprint),
		"raisedRouteCoverage": raised_route_coverage,
		"coreSliceRouteCoverage": core_slice_coverage,
		"forecourtPavingHandoff": forecourt_paving_handoff,
		"negativeControls": negative_controls,
		"failedChecks": failed_checks,
		"failedNegativeControls": failed_negative_controls
	}
	var report_path := OS.get_environment("VOXEL_CITADEL_PHYSICAL_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print(JSON.stringify({
		"runnerId": report.get("runnerId", ""),
		"seed": seed,
		"passed": passed,
		"checkedPartCount": int(integrity.get("checkedPartCount", 0)),
		"failureCount": failed_checks.size() + failed_negative_controls.size() + int(ramp_support_clearance.get("failureCount", 0)),
		"violations": integrity.get("violations", []),
		"failedNegativeControls": failed_negative_controls,
		"rampSupportClearance": ramp_support_clearance
	}))
	quit(0 if passed else 1)


func level_keep_forecourt_paving_handoff_contract() -> Dictionary:
	var blueprint = BuildingBlueprintScript.new("contract.level_keep_forecourt_paving", 1, "masonry")
	var foundation_height := 0.62
	CastleCompoundBlueprintBuilderScript.add_courtyard_foundation_and_paving(blueprint, [], 24.0, 24.0, foundation_height, 0.0)
	CastleCompoundBlueprintBuilderScript.add_keep_palace_entry_court(blueprint, Vector3.ZERO, 18.0, 14.0, foundation_height, 0.0, 5.2, 2.8, -7.0, {})
	blueprint.resolve_physical_contracts()
	var forecourt = blueprint.find_part("castle_keep_palace_entry_forecourt")
	var paving = blueprint.find_part("castle_compound_paving_segment_00")
	if forecourt == null or paving == null:
		return {"passed": false, "reason": "missing_level_handoff_parts"}
	var forecourt_top := float(forecourt.position.y) + float(forecourt.size.y) * 0.5
	var paving_top := float(paving.position.y) + float(paving.size.y) * 0.5
	var aligned := absf(paving_top - forecourt_top) <= 0.001
	return {
		"passed": aligned,
		"reason": "" if aligned else "keep_forecourt_paving_plane_mismatch",
		"forecourtTop": forecourt_top,
		"pavingTop": paving_top,
		"foundationHeight": foundation_height
	}


func route_geometry_diagnostics(blueprint) -> Array[Dictionary]:
	var diagnostics: Array[Dictionary] = []
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		if not part_id.begins_with("castle_district_processional_04") and not part_id.begins_with("castle_keep_palace_entry_") and not part_id.begins_with("castle_terrace_stair_"):
			continue
		diagnostics.append({
			"partId": part_id,
			"semantic": String(part.semantic),
			"position": part.position,
			"size": part.size,
			"rotation": part.rotation,
			"collisionEnabled": bool(part.collision_enabled),
			"physicalRoot": bool(part.recipe.get("physicalRoot", false)),
			"supportIds": part.recipe.get("physicalRequiredSupportPartIds", [])
		})
	return diagnostics


func core_blueprint_slice(source):
	var core = BuildingBlueprintScript.new(String(source.id), int(source.seed), String(source.style))
	core.set_recipe(source.recipe)
	core.set_room_records(source.rooms)
	for part in source.parts:
		if part != null and String(part.recipe.get("castleResidenceId", "")).is_empty():
			core.add_part(part.snapshot())
	return core
	return core


func stair_assembly_diagnostics(blueprint) -> Dictionary:
	var assemblies: Array[Dictionary] = []
	var categories: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.recipe.get("physicalAssemblyRole", "")) != "stair_sloped_span":
			continue
		var joint_facts: Array = part.recipe.get("physicalRequiredSeatFacts", []) as Array
		var joint_valid := joint_facts.size() == 2 and joint_facts.all(func(fact_value) -> bool:
			var fact: Dictionary = fact_value as Dictionary
			return String(fact.get("contactMode", "")) == "housed_overlap" and blueprint.has_rooted_bearer_seat(part, fact)
		)
		var category := stair_category(String(part.id))
		var record := {
			"partId": String(part.id),
			"assemblyId": String(part.recipe.get("physicalStairAssemblyId", "")),
			"category": category,
			"assemblyValid": blueprint.has_valid_stair_carriage_assembly(part),
			"jointCount": joint_facts.size(),
			"housedJointsValid": joint_valid,
			"minimumEmbedment": joint_facts.map(func(fact_value) -> float: return (fact_value as Dictionary).get("localOverlapHalfExtents", Vector3.ZERO).z * 2.0),
			"minimumVerticalOverlap": joint_facts.map(func(fact_value) -> float: return (fact_value as Dictionary).get("localOverlapHalfExtents", Vector3.ZERO).y * 2.0)
		}
		assemblies.append(record)
		if not categories.has(category):
			categories[category] = {"count": 0, "failed": 0}
		var category_summary: Dictionary = categories[category] as Dictionary
		category_summary["count"] = int(category_summary.get("count", 0)) + 1
		if not bool(record.get("assemblyValid", false)) or not bool(record.get("housedJointsValid", false)):
			category_summary["failed"] = int(category_summary.get("failed", 0)) + 1
	return {"assemblies": assemblies, "categories": categories}


func roof_frame_diagnostics(blueprint) -> Dictionary:
	const MAX_FAILURES := 24
	var failure_samples: Array[Dictionary] = []
	var total_spans := 0
	var valid_spans := 0
	for part in blueprint.parts:
		if part == null or String(part.recipe.get("physicalAssemblyRole", "")) != "roof_sloped_span":
			continue
		total_spans += 1
		var joint_valid := true
		for fact_value in part.recipe.get("physicalRequiredSeatFacts", []) as Array:
			var fact: Dictionary = fact_value as Dictionary
			var seat = blueprint.find_part(String(fact.get("seatId", "")))
			if seat == null or not blueprint.has_rooted_bearer_seat(part, fact):
				joint_valid = false
				if failure_samples.size() < MAX_FAILURES:
					failure_samples.append({"partId": String(part.id), "seatId": String(fact.get("seatId", "")), "details": blueprint.housed_overlap_diagnostics(part, seat, fact) if seat != null else {}})
		var assembly_valid: bool = blueprint.has_valid_roof_frame_assembly(part)
		if assembly_valid and joint_valid:
			valid_spans += 1
		elif failure_samples.size() < MAX_FAILURES:
			failure_samples.append({"partId": String(part.id), "frameId": String(part.recipe.get("physicalRoofFrameId", "")), "assemblyValid": assembly_valid, "jointsValid": joint_valid})
	return {"totalSpans": total_spans, "validSpans": valid_spans, "failedSpans": total_spans - valid_spans, "reportedFailures": failure_samples, "truncated": total_spans - valid_spans > failure_samples.size()}


func roof_frame_failure_diagnostics(blueprint) -> Dictionary:
	const MAX_FAILURES := 24
	var diagnostics: Array[Dictionary] = []
	var total_failures := 0
	for part in blueprint.parts:
		if part == null or String(part.recipe.get("physicalRoofFrameId", "")).is_empty():
			continue
		for fact_value in part.recipe.get("physicalRequiredSeatFacts", []) as Array:
			var fact: Dictionary = fact_value as Dictionary
			var seat = blueprint.find_part(String(fact.get("seatId", "")))
			if seat != null and not blueprint.has_rooted_bearer_seat(part, fact):
				total_failures += 1
				if diagnostics.size() < MAX_FAILURES:
					diagnostics.append({"partId": String(part.id), "seatId": String(fact.get("seatId", "")), "contactMode": String(fact.get("contactMode", "world_down")), "details": blueprint.housed_overlap_diagnostics(part, seat, fact) if String(fact.get("contactMode", "")) == "housed_overlap" else blueprint.gravity_bearing_diagnostics(part, seat, fact)})
		for fact_value in part.recipe.get("physicalRequiredAnchorFacts", []) as Array:
			var anchor_fact: Dictionary = fact_value as Dictionary
			if not blueprint.has_rooted_attachment_socket(part, anchor_fact):
				total_failures += 1
				if diagnostics.size() < MAX_FAILURES:
					diagnostics.append({"partId": String(part.id), "anchorId": String(anchor_fact.get("anchorId", "")), "contactMode": "attachment_socket", "details": blueprint.attachment_socket_diagnostics(part, anchor_fact)})
	return {"totalFailures": total_failures, "reportedFailures": diagnostics, "truncated": total_failures > diagnostics.size()}


func attachment_socket_failure_diagnostics(blueprint) -> Dictionary:
	const MAX_FAILURES := 24
	var failures: Array[Dictionary] = []
	var total_failures := 0
	for part in blueprint.parts:
		if part == null or String(part.physical_intent) != "facade_attachment":
			continue
		for fact_value in part.recipe.get("physicalRequiredAnchorFacts", []) as Array:
			var fact: Dictionary = fact_value as Dictionary
			if blueprint.has_rooted_attachment_socket(part, fact):
				continue
			total_failures += 1
			if failures.size() < MAX_FAILURES:
				failures.append({
					"partId": String(part.id),
					"anchorId": String(fact.get("anchorId", "")),
					"details": blueprint.attachment_socket_diagnostics(part, fact)
				})
	return {"totalFailures": total_failures, "reportedFailures": failures, "truncated": total_failures > failures.size()}


func ramp_support_clearance_contract(blueprint) -> Dictionary:
	var vestibule = blueprint.find_part("castle_keep_palace_entry_vestibule")
	var threshold = blueprint.find_part("castle_keep_palace_entry_threshold")
	if vestibule == null or threshold == null:
		return {"passed": false, "failureCount": 1, "violations": ["missing_keep_entry_vestibule_or_threshold"], "samples": []}
	var vestibule_top: float = float(vestibule.position.y) + float(vestibule.size.y) * 0.5
	var threshold_bottom: float = float(threshold.position.y) - float(threshold.size.y) * 0.5
	var overlap_x: float = minf(float(vestibule.position.x) + float(vestibule.size.x) * 0.5, float(threshold.position.x) + float(threshold.size.x) * 0.5) - maxf(float(vestibule.position.x) - float(vestibule.size.x) * 0.5, float(threshold.position.x) - float(threshold.size.x) * 0.5)
	var overlap_z: float = minf(float(vestibule.position.z) + float(vestibule.size.z) * 0.5, float(threshold.position.z) + float(threshold.size.z) * 0.5) - maxf(float(vestibule.position.z) - float(vestibule.size.z) * 0.5, float(threshold.position.z) - float(threshold.size.z) * 0.5)
	var contact_gap: float = threshold_bottom - vestibule_top
	var passed := absf(contact_gap) <= 0.01 and overlap_x > 0.20 and overlap_z > 0.08
	var sample := {"vestibuleId": String(vestibule.id), "thresholdId": String(threshold.id), "contactGap": contact_gap, "overlapX": overlap_x, "overlapZ": overlap_z, "passed": passed}
	return {"contract": "vestibule_threshold_contact", "passed": passed, "failureCount": 0 if passed else 1, "violations": [] if passed else ["keep entry vestibule and threshold do not form a supported interior handoff"], "samples": [sample]}


func dependency_negative_controls(blueprint) -> Dictionary:
	var bridge_id := first_part_id_ending_with(blueprint, "__manor_solar_tower_bridge")
	var ceiling_bearer_id := first_part_id_containing(blueprint, "__manor_solar_upper_ceiling_bearer_0")
	var ceiling_header_id := ""
	var ceiling_bearer = blueprint.find_part(ceiling_bearer_id)
	if ceiling_bearer != null:
		var seat_ids: Array = ceiling_bearer.recipe.get("physicalRequiredSeatPartIds", []) as Array
		if not seat_ids.is_empty():
			ceiling_header_id = String(seat_ids.front())
	return {
		"forecourtRoot": displaced_dependency_negative_check(blueprint, "castle_keep_palace_entry_forecourt", "castle_keep_palace_entry_forecourt_root", Vector3(0.0, -8.0, 0.0)),
		"vestibuleRoot": publisher_dependency_negative_check(blueprint, "castle_keep_palace_entry_vestibule", "castle_keep_palace_entry_vestibule_root", Vector3(0.0, -8.0, 0.0)),
		"thresholdVestibule": publisher_dependency_negative_check(blueprint, "castle_keep_palace_entry_threshold", "castle_keep_palace_entry_vestibule", Vector3(0.0, -8.0, 0.0)),
		"transitionSameRecordRouteInjection": transition_route_collision_negative_check(blueprint, "processional_04b_palace_reveal", "same_record"),
		"transitionForeignRouteOverlap": transition_route_collision_negative_check(blueprint, "processional_04c_palace_entry_transition", "foreign_overlap"),
		"bridgeUnderframe": displaced_dependency_negative_check(blueprint, bridge_id, "%s_underframe" % bridge_id, Vector3(0.0, -8.0, 0.0)),
		"roofWallPlate": displaced_dependency_negative_check(blueprint, "castle_keep_civic_core_roof_left", "castle_keep_civic_core_roof_left_plate", Vector3(0.0, -8.0, 0.0)),
		"heraldicSocket": displaced_dependency_negative_check(blueprint, "castle_gatehouse_heraldic_recess", "castle_gatehouse_lintel", Vector3(0.0, -8.0, 0.0)),
		"ceilingHeader": displaced_dependency_negative_check(blueprint, ceiling_bearer_id, ceiling_header_id, Vector3(0.0, -8.0, 0.0))
	}


func critic_dependency_negative_controls(blueprint) -> Dictionary:
	return {
		"vestibuleRoot": publisher_dependency_negative_check(blueprint, "castle_keep_palace_entry_vestibule", "castle_keep_palace_entry_vestibule_root", Vector3(0.0, -8.0, 0.0)),
		"thresholdVestibule": publisher_dependency_negative_check(blueprint, "castle_keep_palace_entry_threshold", "castle_keep_palace_entry_vestibule", Vector3(0.0, -8.0, 0.0)),
		"transitionSameRecordRouteInjection": transition_route_collision_negative_check(blueprint, "processional_04b_palace_reveal", "same_record"),
		"transitionForeignRouteOverlap": transition_route_collision_negative_check(blueprint, "processional_04c_palace_entry_transition", "foreign_overlap"),
		"routeJunctionCollision": route_junction_negative_check(blueprint, "collision"),
		"routeJunctionRoot": route_junction_negative_check(blueprint, "root"),
		"routeJunctionClipping": route_junction_negative_check(blueprint, "clipping")
	}


func processional_handoff_root_negative_check(blueprint, street_token: String, side_name: String) -> Dictionary:
	var baseline_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var baseline := raised_route_record(baseline_validation, street_token)
	if baseline.is_empty() or not bool(baseline.get("passed", false)):
		return {"passed": false, "reason": "missing_baseline_%s_route_coverage" % street_token, "baseline": baseline}
	var target_sample: Dictionary = {}
	var handoff: Dictionary = baseline.get("handoffSeam", {}) as Dictionary
	var handoff_side: Dictionary = handoff.get(side_name, {}) as Dictionary
	if not bool(handoff.get("declared", false)) or not bool(handoff_side.get("passed", false)):
		return {"passed": false, "reason": "%s_has_no_valid_declared_%s_handoff" % [street_token, side_name], "baseline": baseline}
	target_sample = handoff_side
	if target_sample.is_empty():
		return {"passed": false, "reason": "%s_has_no_mutable_named_root" % street_token, "baseline": baseline}
	var support_id := String(target_sample.get("foundationSupportId", ""))
	if support_id.is_empty():
		support_id = String(target_sample.get("rootSupportId", ""))
	var support = blueprint.find_part(support_id)
	if support == null:
		return {"passed": false, "reason": "missing_named_route_root", "supportId": support_id, "sampleId": String(target_sample.get("id", ""))}
	var original_position: Vector3 = support.position
	support.position += Vector3(0.0, -8.0, 0.0)
	var corrupted_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var corrupted := raised_route_record(corrupted_validation, street_token)
	var publication_root := Node3D.new()
	get_root().add_child(publication_root)
	var publisher = BuildingPartPublisherScript.new()
	var publication_summary: Dictionary = publisher.publish(blueprint, publication_root, {"batchStaticParts": true})
	publication_root.queue_free()
	support.position = original_position
	var publisher_route_coverage: Dictionary = publication_summary.get("raisedRouteCoverage", {}) as Dictionary
	var publisher_rejected := not bool(publisher_route_coverage.get("passed", true)) and int(publication_summary.get("publishedPartCount", -1)) == 0
	var failed_sample: Dictionary = (corrupted.get("handoffSeam", {}) as Dictionary).get(side_name, {}) as Dictionary
	return {
		"passed": not bool(corrupted_validation.get("passed", true)) and not bool(corrupted.get("passed", true)) and not bool(failed_sample.get("passed", true)) and publisher_rejected,
		"streetId": String(baseline.get("streetId", "")),
		"supportId": support_id,
		"sampleId": "%s_handoff_%s" % [street_token, side_name],
		"corruptedSample": failed_sample,
		"violations": corrupted_validation.get("violations", []),
		"publisherSummary": publication_summary,
		"publisherRejected": publisher_rejected
	}


func raised_route_record(validation: Dictionary, token: String) -> Dictionary:
	for coverage_value in validation.get("records", []) as Array:
		if not coverage_value is Dictionary:
			continue
		var coverage: Dictionary = coverage_value as Dictionary
		if String(coverage.get("streetId", "")).contains(token):
			return coverage
	return {}


func displaced_dependency_negative_check(blueprint, dependent_id: String, support_id: String, displacement: Vector3) -> Dictionary:
	var dependent = blueprint.find_part(dependent_id)
	var support = blueprint.find_part(support_id)
	if dependent == null or support == null:
		return {"dependentId": dependent_id, "supportId": support_id, "passed": false, "reason": "missing named production parts"}
	var original_position: Vector3 = support.position
	support.position += displacement
	var corrupt_integrity: Dictionary = blueprint.validate_physical_integrity()
	var dependent_failed := failed_check_for_part(corrupt_integrity, dependent_id)
	support.position = original_position
	blueprint.validate_physical_integrity()
	return {"dependentId": dependent_id, "supportId": support_id, "passed": dependent_failed, "displacement": displacement}


func publisher_dependency_negative_check(blueprint, dependent_id: String, support_id: String, displacement: Vector3) -> Dictionary:
	var dependent = blueprint.find_part(dependent_id)
	var support = blueprint.find_part(support_id)
	if dependent == null or support == null:
		return {"dependentId": dependent_id, "supportId": support_id, "passed": false, "reason": "missing named production parts"}
	var original_position: Vector3 = support.position
	support.position += displacement
	var corrupt_integrity: Dictionary = blueprint.validate_physical_integrity()
	var dependent_failed := failed_check_for_part(corrupt_integrity, dependent_id)
	var publication_root := Node3D.new()
	get_root().add_child(publication_root)
	var publisher = BuildingPartPublisherScript.new()
	var publication_summary: Dictionary = publisher.publish(blueprint, publication_root, {"batchStaticParts": true})
	publication_root.queue_free()
	support.position = original_position
	blueprint.validate_physical_integrity()
	var publisher_rejected := not bool((publication_summary.get("physicalIntegrity", {}) as Dictionary).get("passed", true)) and int(publication_summary.get("publishedPartCount", -1)) == 0
	return {"dependentId": dependent_id, "supportId": support_id, "passed": dependent_failed and publisher_rejected, "displacement": displacement, "publisherRejected": publisher_rejected, "publisherSummary": publication_summary}


func transition_route_collision_negative_check(blueprint, street_id: String, mutation: String) -> Dictionary:
	var baseline_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var baseline := raised_route_record(baseline_validation, street_id)
	if baseline.is_empty() or not bool(baseline.get("passed", false)):
		return {"streetId": street_id, "mutation": mutation, "passed": false, "reason": "missing_baseline_transition_coverage"}
	var roadbed = null
	for part in blueprint.parts:
		if part != null and bool(part.collision_enabled) and not String(part.recipe.get("routeStreetId", "")).is_empty():
			roadbed = part
			break
	if roadbed == null:
		return {"streetId": street_id, "mutation": mutation, "passed": false, "reason": "missing_route_owned_collision_part"}
	var original_route_street_id := String(roadbed.recipe.get("routeStreetId", ""))
	var original_position: Vector3 = roadbed.position
	if mutation == "same_record":
		roadbed.recipe["routeStreetId"] = street_id
	else:
		var transition_owner_id := String(((baseline.get("collisionExclusivity", {}) as Dictionary).get("overlaps", []) as Array).front().get("transitionOwnerId", "")) if not ((baseline.get("collisionExclusivity", {}) as Dictionary).get("overlaps", []) as Array).is_empty() else "castle_keep_palace_entry_forecourt"
		var transition_owner = blueprint.find_part(transition_owner_id)
		if transition_owner == null:
			return {"streetId": street_id, "mutation": mutation, "passed": false, "reason": "missing_transition_owner"}
		roadbed.position = transition_owner.position
	var corrupted_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var corrupted := raised_route_record(corrupted_validation, street_id)
	var publication_root := Node3D.new()
	get_root().add_child(publication_root)
	var publisher = BuildingPartPublisherScript.new()
	var publication_summary: Dictionary = publisher.publish(blueprint, publication_root, {"batchStaticParts": true})
	publication_root.queue_free()
	roadbed.recipe["routeStreetId"] = original_route_street_id
	roadbed.position = original_position
	var publisher_rejected := not bool((publication_summary.get("raisedRouteCoverage", {}) as Dictionary).get("passed", true)) and int(publication_summary.get("publishedPartCount", -1)) == 0
	return {"streetId": street_id, "mutation": mutation, "roadbedId": String(roadbed.id), "passed": not bool(corrupted_validation.get("passed", true)) and not bool(corrupted.get("passed", true)) and publisher_rejected, "violations": corrupted.get("violations", []), "publisherRejected": publisher_rejected, "publisherSummary": publication_summary}


func route_junction_negative_check(blueprint, mutation: String) -> Dictionary:
	var baseline_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	if not bool(baseline_validation.get("passed", false)):
		return {"mutation": mutation, "passed": false, "reason": "missing_baseline_route_partition"}
	var junction = null
	for part in blueprint.parts:
		if part != null and String(part.semantic) == "castle_route_junction" and bool(part.collision_enabled):
			junction = part
			break
	if junction == null:
		return {"mutation": mutation, "passed": false, "reason": "missing_route_junction"}
	var incident_streets: Array = junction.recipe.get("routeIncidentStreetIds", []) as Array
	if incident_streets.is_empty():
		return {"mutation": mutation, "junctionId": String(junction.id), "passed": false, "reason": "missing_junction_incident_streets"}
	var target_street_id := String(incident_streets.front())
	var original_collision_enabled := bool(junction.collision_enabled)
	var original_size: Vector3 = junction.size
	var root = null
	var original_root_collision_enabled := false
	if mutation == "root":
		var support_ids: Array = junction.recipe.get("physicalRequiredSupportPartIds", []) as Array
		if support_ids.is_empty():
			return {"mutation": mutation, "junctionId": String(junction.id), "passed": false, "reason": "missing_junction_root"}
		root = blueprint.find_part(String(support_ids.front()))
		if root == null:
			return {"mutation": mutation, "junctionId": String(junction.id), "passed": false, "reason": "missing_named_junction_root"}
		original_root_collision_enabled = bool(root.collision_enabled)
		root.collision_enabled = false
	elif mutation == "collision":
		junction.collision_enabled = false
	elif mutation == "clipping":
		junction.size = Vector3(0.01, original_size.y, 0.01)
	else:
		return {"mutation": mutation, "junctionId": String(junction.id), "passed": false, "reason": "unknown_mutation"}
	var corrupted_validation := CastleCompoundBlueprintBuilderScript.validate_raised_route_coverage(blueprint)
	var corrupted := raised_route_record(corrupted_validation, target_street_id)
	var publication_root := Node3D.new()
	get_root().add_child(publication_root)
	var publisher = BuildingPartPublisherScript.new()
	var publication_summary: Dictionary = publisher.publish(blueprint, publication_root, {"batchStaticParts": true})
	publication_root.queue_free()
	junction.collision_enabled = original_collision_enabled
	junction.size = original_size
	if root != null:
		root.collision_enabled = original_root_collision_enabled
	var publisher_rejected := not bool((publication_summary.get("raisedRouteCoverage", {}) as Dictionary).get("passed", true)) and int(publication_summary.get("publishedPartCount", -1)) == 0
	return {"mutation": mutation, "junctionId": String(junction.id), "streetId": target_street_id, "passed": not bool(corrupted_validation.get("passed", true)) and not bool(corrupted.get("passed", true)) and publisher_rejected, "violations": corrupted.get("violations", []), "publisherRejected": publisher_rejected, "publisherSummary": publication_summary}


func failed_check_for_part(integrity: Dictionary, part_id: String) -> bool:
	for check_value in integrity.get("checks", []) as Array:
		var check: Dictionary = check_value as Dictionary
		if String(check.get("partId", "")) == part_id:
			return not bool(check.get("passed", false))
	return false


func first_part_id_containing(blueprint, token: String) -> String:
	for part in blueprint.parts:
		if part != null and String(part.id).contains(token):
			return String(part.id)
	return ""


func first_part_id_ending_with(blueprint, suffix: String) -> String:
	for part in blueprint.parts:
		if part != null and String(part.id).ends_with(suffix):
			return String(part.id)
	return ""


func stair_category(part_id: String) -> String:
	if part_id.contains("gatehouse"):
		return "gatehouse"
	if part_id.begins_with("castle_keep_"):
		return "keep"
	if part_id.contains("__manor_"):
		return "transformed_manor"
	return "manor"
