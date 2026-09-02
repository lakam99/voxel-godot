extends SceneTree

## SYNTHETIC SOURCE INTEGRATION ONLY: directly exercises the private threshold
## completion stage with real BuildingBlueprint validation. No publication,
## physics frames, rendering, gameplay, NPC/navigation or headed evidence.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Completion = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Threshold = preload("res://scripts/buildings/CitadelThresholdBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Frame = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const Sampler = preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const MAX_REPORT_BYTES := 262144
var _checks: Array = []
var _cases: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for dependency in [Blueprint, Completion, Threshold, Copy, Frame]:
		if not dependency.can_instantiate():
			push_error("Threshold completion integration dependency failed to compile")
			quit(2)
			return
	var path := OS.get_environment("VOXEL_THRESHOLD_INTEGRATION_REPORT").strip_edges().simplify_path()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_INTEGRATION_REPORT requires a fresh absolute JSON path")
		quit(2)
		return
	_success_and_determinism()
	_already_valid_no_op()
	_atomic_failure()
	_fail_closed_inputs()
	_bound_binding_fail_closed()
	_source_limit_contract()
	_seated_completion_contract()
	_two_course_completion_contract()
	_verified_assembly_fitting_contract()
	_thin_source_preservation_contract()
	_inferred_source_role_contract()
	_proven_elevated_seat_contract()
	_stage_order_source_audit()
	_check("report:binding_suite_completed", _cases.any(func(row): return row.get("case", "") == "bound_binding_fail_closed"))
	var check_ids: Array = _checks.map(func(row): return row.id)
	_check("report:unique_check_ids", check_ids.size() == _unique(check_ids).size())
	var passed := not _checks.is_empty() and _checks.all(func(row): return row.passed == true)
	var report := {"fixture": "CitadelThresholdCompletionIntegrationContract", "passed": passed,
		"evidenceLevel": "synthetic_source_integration_contract", "checks": _checks, "cases": _cases,
		"doesNotProve": "No publisher, live physics, rendered clearance, gameplay, NPC/navigation, headed acceptance or general generated-Citadel coverage."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES or not _fresh_path(path):
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_buffer(bytes)
	output.flush()
	var error := output.get_error()
	output.close()
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if error != OK or FileAccess.get_file_as_bytes(path) != bytes or not parsed is Dictionary \
			or parsed.get("fixture") != report.fixture or parsed.get("passed") != passed:
		quit(2)
		return
	print("Synthetic threshold completion integration: ", passed, " checks=", _checks.size(), " report=", path)
	quit(0 if passed else 1)


func _success_and_determinism() -> void:
	var fixture := _fixture(true)
	var source = fixture.source
	var records: Array = fixture.records
	var obstacles: Array = []
	var baseline: Dictionary = fixture.baseline
	_check("success:fixture_intended_initial_state", _row(baseline, "unrelated_root").get("passed") == true
		and _row(baseline, "unrelated_decor").get("passed") == true
		and _row(baseline, "house_alpha_door_threshold").get("passed") == false
		and _row(baseline, "house_beta_door_threshold").get("passed") == false
		and _row(baseline, "house_gamma_door_threshold").get("passed") == true)
	var canonical_parts: Array = fixture.get("canonicalSnapshot", {}).get("parts", [])
	var canonical_intents_complete := canonical_parts.all(func(part):
		return part.get("physicalIntent") is String and not String(part.get("physicalIntent", "")).is_empty())
	_check("success:fixture_canonical_clear_is_idempotent",
		fixture.get("canonicalStable") == true and canonical_intents_complete)
	var frozen := var_to_bytes([source.snapshot(), records, obstacles])
	var canonical = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(canonical)
	var canonical_snapshot: Dictionary = canonical.snapshot()
	_check("success:fixture_canonical_snapshot_exact", var_to_bytes(canonical_snapshot) == var_to_bytes(fixture.canonicalSnapshot))
	var canonical_bytes := var_to_bytes(canonical_snapshot)
	var result: Dictionary = Completion._complete_thresholds(source, records, obstacles)
	_check("success:inputs_immutable", frozen == var_to_bytes([source.snapshot(), records, obstacles]))
	_check("success:stage_kind_and_selected_order", result.get("ready", false) and result.get("kind") == "threshold"
		and result.get("selectedIds") == ["house_alpha_door_threshold", "house_beta_door_threshold"]
		and result.get("acceptedIds") == result.get("selectedIds") and result.get("attempts") == 2)
	_check("success:exactly_two_global_physical_validations", result.get("globalPhysicalValidations") == 2)
	var events: Array = result.get("validationEvents", [])
	_check("success:validation_events_bound_and_hashed", events.size() == 2
		and events[0].get("phase") == "initial" and events[1].get("phase") == "final"
		and String(events[0].get("sourceSha256", "")).length() == 64
		and String(events[1].get("sourceSha256", "")).length() == 64
		and events[0].get("sourceSha256") == result.get("proofSourceSha256")
		and events[0].get("sourceSha256") != events[1].get("sourceSha256")
		and events[0].get("sourceSha256") == _sha256(canonical_bytes)
		and events[1].get("sourceSha256") == _sha256(var_to_bytes(result.get("afterSnapshot", {})))
		and result.get("proofSourceByteCount") == canonical_bytes.size())
	var proof: Dictionary = result.get("_terminalProof", {})
	var final_report: Dictionary = proof.get("report", {})
	var details: Array = result.get("details", [])
	var exact_details := details.size() == 2
	var position_semantic := result.get("afterSnapshot") is Dictionary
	for id: String in result.get("acceptedIds", []):
		var bearing_id := id + "_bearing"
		var detail := _detail(details, bearing_id)
		var contact: Dictionary = detail.get("contact", {})
		var normalization: Dictionary = detail.get("normalization", {})
		exact_details = exact_details and detail.get("ready") == true and detail.get("changed") == true \
			and detail.get("globalPhysicalValidations") == 0 and not detail.has("afterSnapshot") and contact.get("ready") == true \
			and contact.get("exactTopContact") == true and contact.get("meetsGroundPlane") == true \
			and contact.get("verticalGap") == 0.0 and float(contact.get("contactArea", 0.0)) > 0.0 \
			and normalization.get("exactSharedPlane") == true
		var bearing := _part(result.get("afterSnapshot", {}), bearing_id)
		var threshold := _part(result.get("afterSnapshot", {}), id)
		var foundation := _part(result.get("afterSnapshot", {}), id.trim_suffix("_door_threshold") + "_foundation")
		position_semantic = position_semantic and not bearing.is_empty() and not threshold.is_empty() and not foundation.is_empty() \
			and bearing.get("semantic") == "citadel_threshold_bearing" and bearing.get("kind") == "foundation" \
			and bearing.get("physicalIntent") == "structural_mass" and bearing.get("recipe", {}).get("physicalIntent") == "structural_mass" \
			and bearing.get("position").y == foundation.get("position").y and bearing.get("size").y == foundation.get("size").y \
			and bearing.get("position").y + bearing.get("size").y * 0.5 == threshold.get("position").y - threshold.get("size").y * 0.5
		_check("success:" + id + ":threshold_and_bearing_pass", _row(final_report, id).get("passed") == true
			and _row(final_report, bearing_id).get("passed") == true)
	_check("success:details_exact_contact_evidence", exact_details)
	_check("success:stage_position_semantic", position_semantic)
	_check("success:terminal_proof_clear", proof.get("failedIds", ["missing"]).is_empty()
		and final_report.get("violations", ["missing"]).is_empty())
	_check("success:initially_passing_unrelated_and_threshold_preserved",
		_row(final_report, "unrelated_root").get("passed") == true and _row(final_report, "unrelated_decor").get("passed") == true
		and _row(final_report, "house_gamma_door_threshold").get("passed") == true
		and var_to_bytes(_part(canonical_snapshot, "unrelated_root")) == var_to_bytes(_part(result.get("afterSnapshot", {}), "unrelated_root"))
		and var_to_bytes(_part(canonical_snapshot, "unrelated_decor")) == var_to_bytes(_part(result.get("afterSnapshot", {}), "unrelated_decor"))
		and var_to_bytes(_part(canonical_snapshot, "house_gamma_door_threshold")) == var_to_bytes(_part(result.get("afterSnapshot", {}), "house_gamma_door_threshold")))
	var repeat: Dictionary = Completion._complete_thresholds(source, records, obstacles)
	var warm = Copy.copy_blueprint(source.snapshot())
	warm.validate_physical_integrity()
	var warm_result: Dictionary = Completion._complete_thresholds(warm, records, obstacles)
	var cleared = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(cleared)
	var cleared_result: Dictionary = Completion._complete_thresholds(cleared, records, obstacles)
	var expected := var_to_bytes(_stable_stage(result))
	_check("success:deterministic_repeat_byte_exact", expected == var_to_bytes(_stable_stage(repeat)))
	_check("success:warm_output_byte_exact", expected == var_to_bytes(_stable_stage(warm_result)))
	_check("success:cache_cleared_output_byte_exact", expected == var_to_bytes(_stable_stage(cleared_result)))
	_cases.append({"case": "success", "selectedIds": result.get("selectedIds", []),
		"acceptedIds": result.get("acceptedIds", []), "globalPhysicalValidations": result.get("globalPhysicalValidations", -1),
		"detailBearingIds": details.map(func(value): return value.get("bearingId", ""))})


func _already_valid_no_op() -> void:
	var fixture := _fixture(false)
	var source = fixture.source
	var canonical = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(canonical)
	var before: Dictionary = canonical.snapshot()
	var result: Dictionary = Completion._complete_thresholds(source, fixture.records, [])
	var threshold_id := "house_gamma_door_threshold"
	_check("already_valid:fixture_precondition", _row(fixture.baseline, threshold_id).get("passed") == true
		and fixture.get("canonicalStable") == true)
	_check("already_valid:stage_no_op", result.get("ready", false) and result.get("kind") == "threshold"
		and result.get("selectedIds", []) == [] and result.get("acceptedIds", []) == [] and result.get("attempts") == 0
		and result.get("globalPhysicalValidations") == 2)
	_check("already_valid:final_snapshot_byte_identical", var_to_bytes(result.get("afterSnapshot")) == var_to_bytes(before))
	_check("already_valid:threshold_record_byte_identical", var_to_bytes(_part(result.get("afterSnapshot", {}), threshold_id))
		== var_to_bytes(_part(before, threshold_id)))
	_check("already_valid:terminal_check_passes", _row(result.get("_terminalProof", {}).get("report", {}), threshold_id).get("passed") == true)
	_cases.append({"case": "already_valid", "selectedIds": result.get("selectedIds", []),
		"globalPhysicalValidations": result.get("globalPhysicalValidations", -1)})


func _atomic_failure() -> void:
	var fixture := _fixture(true)
	var successful: Dictionary = Completion._complete_thresholds(fixture.source, fixture.records, [])
	var beta := _part(successful.get("afterSnapshot", {}), "house_beta_door_threshold_bearing")
	_check("atomic:unblocked_setup_accepts_beta", successful.get("ready", false) and not beta.is_empty())
	_check("atomic:shuffled_input_and_sorted_prefix_precondition",
		fixture.records.map(func(record): return record.threshold.id) == ["house_beta_door_threshold", "house_gamma_door_threshold", "house_alpha_door_threshold"]
		and successful.get("selectedIds") == ["house_alpha_door_threshold", "house_beta_door_threshold"])
	if beta.is_empty():
		_cases.append({"case": "atomic_failure", "reason": "unblocked_setup_failed"})
		return
	var obstacles := [{"id": "obstruct_beta_after_alpha", "bounds": AABB(beta.position - beta.size * 0.5, beta.size).grow(0.01)}]
	var frozen := var_to_bytes([fixture.source.snapshot(), fixture.records, obstacles])
	var failed: Dictionary = Completion._complete_thresholds(fixture.source, fixture.records, obstacles)
	var failure_events: Array = failed.get("validationEvents", [])
	_check("atomic:failure_after_alphabetic_alpha_candidate", not failed.get("ready", true)
		and failed.get("reason") == "threshold_completion_failed" and failed.get("id") == "house_beta_door_threshold"
		and failed.get("acceptedIdsBeforeFailure", []) == ["house_alpha_door_threshold"]
		and failed.get("globalPhysicalValidations") == 1 and failure_events.size() == 1
		and failure_events[0].get("phase") == "initial"
		and String(failure_events[0].get("sourceSha256", "")).length() == 64)
	_check("atomic:no_snapshot_or_terminal_proof", not failed.has("afterSnapshot") and not failed.has("_terminalProof"))
	_check("atomic:no_input_mutation", frozen == var_to_bytes([fixture.source.snapshot(), fixture.records, obstacles]))
	var detail: Dictionary = failed.get("detail", {})
	_check("atomic:obstruction_evidence", not detail.get("ready", true)
		and detail.get("reason") == "threshold_bearing_reserved_overlap"
		and detail.get("partId") == "obstruct_beta_after_alpha" and not detail.has("afterSnapshot"))
	_cases.append({"case": "atomic_failure", "reason": failed.get("reason", ""), "id": failed.get("id", ""),
		"detailReason": detail.get("reason", ""), "globalPhysicalValidations": failed.get("globalPhysicalValidations", -1)})


func _fail_closed_inputs() -> void:
	var fixture := _fixture(true)
	var duplicate_snapshot: Dictionary = fixture.source.snapshot()
	duplicate_snapshot.parts.append(_part(duplicate_snapshot, "house_alpha_door_threshold").duplicate(true))
	var duplicate_source = Copy.copy_blueprint(duplicate_snapshot)
	var duplicate_bytes := var_to_bytes(duplicate_source.snapshot())
	var duplicate: Dictionary = Completion._complete_thresholds(duplicate_source, fixture.records, [])
	_check("fail_closed:duplicate_physical_check", not duplicate.get("ready", true)
		and duplicate.get("reason") == "duplicate_threshold_stage_check" and not duplicate.has("afterSnapshot")
		and duplicate_bytes == var_to_bytes(duplicate_source.snapshot()))
	var missing_records: Array = fixture.records.duplicate(true)
	missing_records[0].threshold.id = "house_beta_missing_threshold"
	var missing_bytes := var_to_bytes([fixture.source.snapshot(), missing_records])
	var missing: Dictionary = Completion._complete_thresholds(fixture.source, missing_records, [])
	_check("fail_closed:missing_manifest_check", not missing.get("ready", true)
		and missing.get("reason") == "missing_manifest_threshold_check" and not missing.has("afterSnapshot")
		and missing_bytes == var_to_bytes([fixture.source.snapshot(), missing_records]))
	_cases.append({"case": "fail_closed", "duplicateReason": duplicate.get("reason", ""),
		"missingReason": missing.get("reason", "")})


func _bound_binding_fail_closed() -> void:
	var fixture := _fixture(true)
	var snapshot: Dictionary = fixture.canonicalSnapshot.duplicate(true)
	var ownership: Dictionary = fixture.records.filter(func(record):
		return record.threshold.id == "house_alpha_door_threshold")[0]
	var alpha_check := _row(fixture.baseline, "house_alpha_door_threshold")
	var proof_checks: Dictionary = {}
	for row: Dictionary in fixture.baseline.checks: proof_checks[row.partId] = row
	var binding := {"partId": "house_alpha_door_threshold", "check": alpha_check.duplicate(true),
		"proofSourceBytes": var_to_bytes(snapshot), "currentSourceBytes": var_to_bytes(snapshot), "proofChecks": proof_checks}
	var valid: Dictionary = Threshold._prepare_bound(snapshot, ownership, [], binding)
	_check("binding:exact_source_and_target_accepted", valid.get("ready", false)
		and valid.get("changed", false) and valid.get("globalPhysicalValidations") == 0)
	for bad: Variant in [null, {}, [], {"bogus": true}]:
		var bad_binding := binding.duplicate(true)
		bad_binding.proofChecks = bad
		_check("binding:malformed_or_missing_map:%s" % str(bad), not Threshold._prepare_bound(snapshot, ownership, [], bad_binding).ready)
	var contradiction := binding.duplicate(true)
	contradiction.check.intent = "portal"
	var contradicted := Threshold._prepare_bound(snapshot, ownership, [], contradiction)
	_check("binding:same_id_contradiction", not contradicted.ready and contradicted.reason == "mismatched_bound_threshold_check")
	for field: String in ["row", "partId", "passed", "intent", "collisionEnabled"]:
		var malformed := binding.duplicate(true)
		if field == "row": malformed.proofChecks[binding.partId] = false
		else: malformed.proofChecks[binding.partId][field] = []
		var refused := Threshold._prepare_bound(snapshot, ownership, [], malformed)
		_check("binding:malformed_check:" + field, not refused.ready and not refused.has("afterSnapshot"))
	if valid.get("ready", false):
		var beta_owner: Dictionary = fixture.records.filter(func(row): return row.threshold.id == "house_beta_door_threshold")[0]
		var continued := {"partId": beta_owner.threshold.id, "check": proof_checks[beta_owner.threshold.id],
			"proofSourceBytes": var_to_bytes(snapshot), "currentSourceBytes": var_to_bytes(valid.afterSnapshot),
			"proofChecks": proof_checks, "permittedThresholdEdits": {binding.partId: var_to_bytes(_part(valid.afterSnapshot, binding.partId))}}
		var accepted := Threshold._prepare_bound(valid.afterSnapshot, beta_owner, [], continued)
		_check("binding:owner_permitted_prior_threshold", accepted.ready and accepted.changed and accepted.globalPhysicalValidations == 0)
		for rebind_permit: bool in [false, true]:
			var altered: Dictionary = valid.afterSnapshot.duplicate(true)
			var altered_part: Dictionary = _part(altered, binding.partId)
			altered_part.material = "unauthorized_material"
			var invalid_continuation := continued.duplicate(true)
			invalid_continuation.currentSourceBytes = var_to_bytes(altered)
			if rebind_permit: invalid_continuation.permittedThresholdEdits[binding.partId] = var_to_bytes(altered_part)
			_check("binding:unauthorized_prior_change:%s" % str(rebind_permit), not Threshold._prepare_bound(altered, beta_owner, [], invalid_continuation).ready)
	var swapped := binding.duplicate(true)
	swapped.check = _row(fixture.baseline, "house_gamma_door_threshold").duplicate(true)
	var swapped_result: Dictionary = Threshold._prepare_bound(snapshot, ownership, [], swapped)
	_check("binding:swapped_check_rejected", not swapped_result.get("ready", true)
		and swapped_result.get("reason") == "invalid_bound_threshold_check")
	var changed_source := snapshot.duplicate(true)
	changed_source.recipe["postProofMutation"] = true
	var stale_source: Dictionary = Threshold._prepare_bound(changed_source, ownership, [], binding)
	_check("binding:stale_current_source_rejected", not stale_source.get("ready", true)
		and stale_source.get("reason") == "stale_bound_threshold_source")
	var changed_target := snapshot.duplicate(true)
	for row: Dictionary in changed_target.parts:
		if row.id == "house_alpha_door_threshold":
			var changed_position: Vector3 = row.position
			changed_position.x += 0.01
			row.position = changed_position
	var stale_target_binding := binding.duplicate(true)
	stale_target_binding.currentSourceBytes = var_to_bytes(changed_target)
	var stale_target: Dictionary = Threshold._prepare_bound(changed_target, ownership, [], stale_target_binding)
	_check("binding:proof_target_mutation_rejected", not stale_target.get("ready", true)
		and stale_target.get("reason") == "stale_bound_threshold_target")
	_cases.append({"case": "bound_binding_fail_closed", "valid": valid.get("ready", false),
		"swappedReason": swapped_result.get("reason", ""), "staleSourceReason": stale_source.get("reason", ""),
		"staleTargetReason": stale_target.get("reason", "")})


func _source_limit_contract() -> void:
	var record := {"id": "bounded_part", "recipe": {}, "physicalIntent": "structural_mass",
		"position": Vector3.ZERO, "rotation": Vector3.ZERO, "size": Vector3.ONE}
	var parts: Array = []
	parts.resize(Frame.MAX_PARTS)
	parts.fill(record)
	var at_limit := {"id": "bounded_threshold_source", "seed": 1, "style": "stone",
		"recipe": {}, "parts": parts, "rooms": []}
	_check("source_limit:shared_authoritative_part_cap", Threshold.MAX_PARTS == Frame.MAX_PARTS
		and Frame.MAX_PARTS == 10000)
	_check("source_limit:exact_cap_is_valid", Threshold._snapshot_valid(at_limit))
	var over_limit := at_limit.duplicate(true)
	over_limit.parts.append(record)
	_check("source_limit:cap_plus_one_rejected", not Threshold._snapshot_valid(over_limit))
	var thin_positive := at_limit.duplicate(true)
	thin_positive.parts.resize(1)
	var thin_record: Dictionary = record.duplicate(true)
	thin_record.size = Vector3(0.018, 0.001, 0.015)
	thin_positive.parts[0] = thin_record
	_check("source_limit:authoritative_positive_thin_bounds_accepted", Threshold._snapshot_valid(thin_positive))
	var zero_thickness := thin_positive.duplicate(true)
	var zero_record: Dictionary = zero_thickness.parts[0]
	var zero_size: Vector3 = zero_record.size
	zero_size.y = 0.0
	zero_record.size = zero_size
	zero_thickness.parts[0] = zero_record
	_check("source_limit:zero_thickness_rejected", not Threshold._snapshot_valid(zero_thickness))
	_cases.append({"case": "source_limit", "maxParts": Threshold.MAX_PARTS,
		"atLimitValid": Threshold._snapshot_valid(at_limit), "overLimitValid": Threshold._snapshot_valid(over_limit),
		"thinPositiveValid": Threshold._snapshot_valid(thin_positive), "zeroThicknessValid": Threshold._snapshot_valid(zero_thickness)})


func _fixture(include_failures: bool) -> Dictionary:
	var b = Blueprint.new("synthetic_threshold_completion", 310917, "stone")
	b.set_recipe({"contractMarker": {"preserve": [17, "threshold_completion", true]}})
	var records: Array = []
	if include_failures:
		records.append(_add_house(b, "house_beta", 14.0, false))
	records.append(_add_house(b, "house_gamma", 28.0 if include_failures else 0.0, true))
	if include_failures:
		records.append(_add_house(b, "house_alpha", 0.0, false))
	b.add_part({"id": "unrelated_root", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(-18, 0.25, 8), "size": Vector3(2, 0.5, 2), "collision": true,
		"semantic": "unrelated_root", "physicalIntent": "structural_mass"})
	b.add_part({"id": "unrelated_decor", "kind": "decor", "material": "wood",
		"position": Vector3(-18, 1.0, 8), "size": Vector3(0.4, 0.8, 0.4), "collision": false,
		"semantic": "unrelated_decor", "physicalIntent": "visual_detail"})
	# Stabilize resolver-derived declarations so no-op and warm/cold comparisons
	# concern the completion stage rather than first-validation annotation.
	var baseline: Dictionary = b.validate_physical_integrity()
	var canonical = Copy.copy_blueprint(b.snapshot())
	Copy.clear_caches(canonical)
	var canonical_snapshot: Dictionary = canonical.snapshot()
	Copy.clear_caches(canonical)
	return {"source": b, "records": records, "baseline": baseline, "canonicalSnapshot": canonical_snapshot,
		"canonicalStable": var_to_bytes(canonical_snapshot) == var_to_bytes(canonical.snapshot())}


func _add_house(b, prefix: String, base_x: float, already_valid: bool) -> Dictionary:
	var height := 0.62
	var width := 4.0
	var depth := 5.0
	var thickness := 0.14
	var threshold_x := base_x + (1.8 if already_valid else width * 0.5 + 0.30 + 0.46)
	b.add_part({"id": prefix + "_foundation", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(base_x, height * 0.5, 0), "size": Vector3(width, height, depth),
		"collision": true, "semantic": "citadel_urban_house_foundation", "physicalIntent": "structural_mass"})
	b.add_part({"id": prefix + "_door", "kind": "door", "material": "painted_door",
		"position": Vector3(threshold_x - 0.53, height + 1.25, depth + 3.0),
		"size": Vector3(0.14, 2.5, 1.25), "collision": true,
		"semantic": "citadel_urban_door", "physicalIntent": "portal", "recipe": {"roomId": prefix + "_interior"}})
	b.add_part({"id": prefix + "_door_threshold", "kind": "foundation", "material": "worn_cobble",
		"position": Vector3(threshold_x, height + thickness * 0.5, 0), "size": Vector3(0.92, thickness, 1.58),
		"collision": false, "semantic": "citadel_threshold_wear", "physicalIntent": "facade_attachment",
		"recipe": {"variation": -0.04}})
	b.rooms.append({"id": prefix + "_interior", "citadelUrbanRoom": true,
		"bounds": AABB(Vector3(base_x - width * 0.5 + 0.34, height + 0.18, -depth * 0.5 + 0.34),
			Vector3(width - 0.68, 3.0, depth - 0.68)), "accesses": [], "wallMountInset": 0.30})
	return {"producerPrefix": prefix, "roomId": prefix + "_interior", "doorId": prefix + "_door",
		"threshold": {"id": prefix + "_door_threshold", "foundationId": prefix + "_foundation"}}


func _seated_fixture(seat_height: float):
	var source = Blueprint.new("seated_threshold_fixture", 1203, "citadel")
	var record := _add_house(source, "seated_house", 0.0, false)
	var foundation = source.parts.filter(func(part): return part.id == "seated_house_foundation")[0]
	foundation.position.y = 2.0
	foundation.size.y = 4.0
	var threshold = source.parts.filter(func(part): return part.id == "seated_house_door_threshold")[0]
	threshold.position.y = 4.125
	threshold.size.y = 0.25
	var door = source.parts.filter(func(part): return part.id == "seated_house_door")[0]
	door.position.y = 5.25
	var room_bounds: AABB = source.rooms[0].bounds
	room_bounds.position.y = 4.18
	source.rooms[0].bounds = room_bounds
	source.add_part({"id": "courtyard_slab", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(threshold.position.x, seat_height * 0.5, 0.0), "size": Vector3(2.0, seat_height, 3.0),
		"collision": true, "semantic": "courtyard_foundation", "physicalIntent": "structural_mass"})
	return {"source": source, "record": record}


func _proven_elevated_seat_contract() -> void:
	var fixture: Dictionary = _seated_fixture(0.62)
	var source = fixture.source
	var root = source.parts.back()
	source.add_part({"id": "raised_roadbed", "kind": "foundation", "material": "stone_foundation",
		"position": Vector3(root.position.x, 1.62, 0), "size": Vector3(2.0, 2.0, 3.0), "collision": true,
		"recipe": {"physicalAssemblyRole": "walkable_subfloor", "physicalRequiredSeatPartIds": [root.id], "physicalRequiredSupportPartIds": [root.id]}})
	# An existing finish below the roadbed top must not be pierced by new work.
	source.add_part({"id": "buried_paving", "kind": "foundation", "material": "cobblestone",
		"position": Vector3(root.position.x, 0.69, 0), "size": Vector3(2.0, 0.14, 3.0), "collision": false})
	var frozen := var_to_bytes(source.snapshot())
	var initial := Threshold._physical(source)
	_check("proven:private_initial_proof", initial.ready and frozen == var_to_bytes(source.snapshot())
		and initial.checks.raised_roadbed.passed == true and initial.checks.raised_roadbed.reachesGroundRoot == true)
	var original: Dictionary = source.snapshot()
	var eligible := Threshold._proof_seats(original, original, initial.checks)
	_check("proven:roadbed_authorized", eligible.ready and eligible.records.has("raised_roadbed"))
	var target = source.parts.filter(func(part): return part.id == "seated_house_door_threshold")[0]
	for bad: Variant in [true, var_to_bytes({"stale": true})]:
		var stale_inventory: Dictionary = eligible.records.duplicate(true)
		stale_inventory.raised_roadbed = bad
		var refused := Threshold.Seats.prepare(source, target, target.position, Vector3(target.size.x, 4, target.size.z), 2, stale_inventory)
		_check("proven:invalid_inventory_no_lower_fallback:%s" % str(bad), refused.get("ready") == false
			and refused.get("reason") == "stale_threshold_seat_proof")
	var absent: Dictionary = eligible.records.duplicate(true)
	absent["missing_seat"] = var_to_bytes({})
	_check("proven:missing_inventory_member_rejected", not Threshold.Seats.prepare(source, target, target.position,
		Vector3(target.size.x, 4, target.size.z), 2, absent).ready)
	var result := Completion._complete_thresholds(source, [fixture.record], [])
	_check("proven:ordinary_completion_ready", result.get("ready") == true and result.get("globalPhysicalValidations") == 2)
	var details: Array = result.get("details", [])
	var contact: Dictionary = details[0].get("contact", {}) if details.size() == 1 else {}
	_check("proven:highest_proven_housed_seat", contact.get("seatId") == "raised_roadbed"
		and contact.get("seatPlane") == float(source.parts[-2].position.y) + float(source.parts[-2].size.y) * 0.5
		and contact.get("contactMode") == "housed_overlap" and contact.get("exactSeatContact") == false
		and contact.get("actualEmbedment", 0.0) >= 0.06 and contact.get("actualEmbedment", 1.0) <= 0.08
		and contact.get("exactTopContact") == true)
	_check("proven:source_immutable", frozen == var_to_bytes(source.snapshot()))
	var repeated := Completion._complete_thresholds(source, [fixture.record], [])
	_check("proven:deterministic_repeat", var_to_bytes(_stable_stage(result)) == var_to_bytes(_stable_stage(repeated)))
	var standalone := Threshold.prepare(original, fixture.record, [])
	_check("proven:standalone_agrees", standalone.get("ready") == true
		and var_to_bytes(standalone.get("afterSnapshot", {})) == var_to_bytes(result.get("afterSnapshot", {})))
	var obstruction = Copy.copy_blueprint(original)
	obstruction.add_part({"id": "buried_nonseat_blocker", "kind": "decor", "material": "wood", "collision": false,
		"position": Vector3(root.position.x, 2.59, 0), "size": Vector3(1.2, 0.04, 2.0), "physicalIntent": "visual_detail"})
	var blocked := Completion._complete_thresholds(obstruction, [fixture.record], [])
	_check("proven:nonseat_intersection_rejected", blocked.get("ready") == false and not blocked.has("afterSnapshot")
		and blocked.get("globalPhysicalValidations") == 1 and blocked.get("validationEvents", []).size() == 1
		and blocked.get("acceptedIdsBeforeFailure") == []
		and blocked.get("detail", {}).get("reason") == "threshold_bearing_source_overlap"
		and blocked.get("detail", {}).get("partId") == "buried_nonseat_blocker")
	var blocked_reservation := Completion._complete_thresholds(source, [fixture.record], [
		{"id": "housing_reservation", "bounds": AABB(Vector3(root.position.x - 0.6, 2.58, -1), Vector3(1.2, 0.04, 2))}])
	_check("proven:housing_reservation_rejected", blocked_reservation.get("ready") == false and not blocked_reservation.has("afterSnapshot")
		and blocked_reservation.get("globalPhysicalValidations") == 1 and blocked_reservation.get("validationEvents", []).size() == 1
		and blocked_reservation.get("acceptedIdsBeforeFailure") == []
		and blocked_reservation.get("detail", {}).get("reason") == "threshold_bearing_reserved_overlap")
	var partial = Copy.copy_blueprint(original)
	partial.add_part({"id": "partial_furniture", "kind": "decor", "material": "wood", "collision": false,
		"position": Vector3(root.position.x - 0.3, 4.125, 0), "size": Vector3(0.4, 0.5, 0.8), "physicalIntent": "visual_detail"})
	partial.add_part({"id": "partial_buried_finish", "kind": "decor", "material": "cobblestone", "collision": false,
		"position": Vector3(root.position.x + 0.2, 2.59, -0.4), "size": Vector3(0.4, 0.07, 0.6), "physicalIntent": "visual_detail"})
	var partial_bytes := var_to_bytes(partial.snapshot())
	var fitted := Completion._complete_thresholds(partial, [fixture.record], [])
	_check("proven:fit_around_unchanged_objects", fitted.get("ready") == true and fitted.get("globalPhysicalValidations") == 2
		and var_to_bytes(partial.snapshot()) == partial_bytes)
	var fitted_after: Dictionary = fitted.get("afterSnapshot", {})
	for id: String in ["partial_furniture", "partial_buried_finish"]:
		_check("proven:obstacle_preserved:" + id, var_to_bytes(_part(fitted_after, id)) == var_to_bytes(_part(partial.snapshot(), id)))
	if fitted.get("ready", false):
		var fitting_contact: Dictionary = fitted.details[0].contact
		_check("proven:positive_reduced_footprint", fitting_contact.contactArea > 0.0 and fitting_contact.contactArea < contact.contactArea
			and fitting_contact.contactMode == "housed_overlap" and fitting_contact.exactTopContact)
		var replay := Completion._complete_thresholds(partial, [fixture.record], [])
		_check("proven:obstacle_fit_deterministic", var_to_bytes(_stable_stage(fitted)) == var_to_bytes(_stable_stage(replay)))
	if result.get("ready", false):
		var bearing = Threshold.Part.new(_part(result.afterSnapshot, "seated_house_door_threshold_bearing"))
		var housing: Dictionary = contact.get("housing", {})
		_check("proven:bound_housing_admission", Threshold._admit(source, bearing, [], housing, eligible.records).ready)
		_check("proven:no_proof_no_overlap_exception", not Threshold._admit(source, bearing, [], housing, {}).ready)
		var stale_records: Dictionary = eligible.records.duplicate(true)
		stale_records.raised_roadbed = var_to_bytes({"wrong": "source revision"})
		_check("proven:stale_record_no_overlap_exception", not Threshold._admit(source, bearing, [], housing, stale_records).ready)
		var wrong_housing: Dictionary = housing.duplicate(true)
		wrong_housing.seatId = "courtyard_slab"
		_check("proven:wrong_seat_no_overlap_exception", not Threshold._admit(source, bearing, [], wrong_housing, eligible.records).ready)
		bearing.recipe.physicalRequiredSeatFacts[0].localOverlapCenter.y += 0.1
		_check("proven:changed_witness_no_overlap_exception", not Threshold._admit(source, bearing, [], housing, eligible.records).ready)
	var changed := original.duplicate(true)
	for row: Dictionary in changed.parts:
		if row.id == "courtyard_slab": row.position.x += 0.01
	var stale := Threshold._proof_seats(changed, original, initial.checks)
	_check("proven:changed_dependency_rejected", not stale.ready and stale.reason == "stale_threshold_seat_substrate")
	changed = original.duplicate(true)
	changed.parts.append(changed.parts[0].duplicate(true))
	_check("proven:duplicate_rejected", not Threshold._proof_seats(changed, original, initial.checks).ready)
	changed = original.duplicate(true)
	for row: Dictionary in changed.parts:
		if row.id == "buried_paving": row.recipe["physicalIntent"] = "structural_mass"
	_check("proven:noncollision_dependency_edit_rejected", not Threshold._proof_seats(changed, original, initial.checks).ready)
	var missing: Dictionary = initial.checks.duplicate(true)
	missing.erase("courtyard_slab")
	_check("proven:incomplete_proof_rejected", not Threshold._proof_seats(original, original, missing).ready)
	var failed: Dictionary = initial.checks.duplicate(true)
	failed.raised_roadbed.passed = false
	_check("proven:failed_seat_not_authorized", not Threshold._proof_seats(original, original, failed).records.has("raised_roadbed"))
	_cases.append({"id": "proven_elevated_seat", "ready": result.get("ready"), "contact": contact,
		"failure": result.get("detail", {}), "validationEvents": result.get("validationEvents", [])})


func _seated_completion_contract() -> void:
	var fixture: Dictionary = _seated_fixture(0.5)
	var source = fixture.source
	var frozen := var_to_bytes(source.snapshot())
	var result := Completion._complete_thresholds(source, [fixture.record], [])
	_check("seated:completion_ready", result.get("ready") == true and result.get("acceptedIds") == ["seated_house_door_threshold"])
	_check("seated:representable_remains_singleton", result.get("details", [{}])[0].get("courseIds") == ["seated_house_door_threshold_bearing"])
	_check("seated:two_global_validations", result.get("globalPhysicalValidations") == 2)
	_check("seated:source_immutable", frozen == var_to_bytes(source.snapshot()))
	var after: Dictionary = result.get("afterSnapshot", {})
	var bearing := _part(after, "seated_house_door_threshold_bearing")
	var details: Array = result.get("details", [])
	var contact: Dictionary = details[0].get("contact", {}) if details.size() == 1 else {}
	_check("seated:real_seat_not_ground", contact.get("seatId") == "courtyard_slab" and contact.get("exactSeatContact") == true
		and contact.get("exactTopContact") == true and contact.get("seatGap") == 0.0 and contact.get("verticalGap") == 0.0
		and contact.get("meetsGroundPlane") == false and contact.get("groundGap") == 0.5)
	_check("seated:one_matching_gravity_seat", bearing.get("recipe", {}).get("physicalRequiredSeatPartIds") == ["courtyard_slab"]
		and bearing.get("recipe", {}).get("physicalRequiredSeatFacts", []).size() == 1
		and bearing.recipe.physicalRequiredSeatFacts[0].get("loadDirection") == "world_down")
	var proof: Dictionary = result.get("_terminalProof", {})
	_check("seated:ordinary_proof_passes", proof.get("failedIds", ["missing"]).is_empty()
		and _row(proof.get("report", {}), "seated_house_door_threshold_bearing").get("hasRootedSeats") == true)
	_check("seated:single_addition", after.get("parts", []).size() == source.parts.size() + 1)
	var preserved := not after.is_empty()
	for part in source.parts:
		if part.id == "seated_house_door_threshold": continue
		preserved = preserved and var_to_bytes(part.snapshot()) == var_to_bytes(_part(after, part.id))
	_check("seated:existing_geometry_and_room_preserved", preserved and var_to_bytes(source.rooms) == var_to_bytes(after.get("rooms", [])))
	var repeated := Completion._complete_thresholds(source, [fixture.record], [])
	_check("seated:repeat_deterministic", var_to_bytes(_stable_stage(result)) == var_to_bytes(_stable_stage(repeated)))
	_cases.append({"id": "elevated_seat", "ready": result.get("ready"), "contact": contact, "validations": result.get("globalPhysicalValidations")})
	var blocked := Completion._complete_thresholds(source, [fixture.record], [{"id": "furniture_above_seat",
		"bounds": AABB(Vector3(2.2, 1.0, -1.0), Vector3(1.2, 0.5, 2.0))}])
	_check("seated:obstruction_still_rejects_atomically", blocked.get("ready") == false and not blocked.has("afterSnapshot")
		and blocked.get("acceptedIdsBeforeFailure") == [] and blocked.get("globalPhysicalValidations") == 1
		and blocked.get("detail", {}).get("reason") == "threshold_bearing_reserved_overlap")
	_cases.append({"id": "elevated_seat_obstruction", "result": blocked})
	var floating: Dictionary = _seated_fixture(0.5)
	floating.source.parts.filter(func(part): return part.id == "courtyard_slab")[0].position.y = 1.0
	# Keep this negative genuinely unsupported, not embedded in the house root.
	floating.source.parts.filter(func(part): return part.id == "courtyard_slab")[0].position.x += 0.5
	var floating_proof := Threshold._physical(floating.source)
	_check("seated:floating_negative_is_unrooted", floating_proof.ready and floating_proof.checks.courtyard_slab.passed == false
		and floating_proof.checks.courtyard_slab.reachesGroundRoot == false)
	var floating_rejected := Completion._complete_thresholds(floating.source, [floating.record], [])
	_check("seated:ineligible_floating_source_still_blocks", floating_rejected.get("ready") == false
		and not floating_rejected.has("afterSnapshot") and floating_rejected.get("acceptedIdsBeforeFailure") == []
		and floating_rejected.get("globalPhysicalValidations") == 1
		and floating_rejected.get("detail", {}).get("reason") == "threshold_bearing_source_overlap"
		and floating_rejected.get("detail", {}).get("partId") == "courtyard_slab")
	_cases.append({"id": "ineligible_floating_source_obstruction", "result": floating_rejected})
	var unrepresentable: Dictionary = _seated_fixture(0.5 + 1.0 / 16777216.0)
	var rejected := Completion._complete_thresholds(unrepresentable.source, [unrepresentable.record], [])
	_check("seated:unrepresentable_rejects_atomically", rejected.get("ready") == false and not rejected.has("afterSnapshot")
		and rejected.get("acceptedIdsBeforeFailure") == [] and rejected.get("globalPhysicalValidations") == 1
		and rejected.get("detail", {}).get("reason") == "unrepresentable_threshold_seated_courses")
	var unverified_detail: Dictionary = rejected.get("detail", {})
	_check("seated:unrepresentable_preserves_failure_without_fitting", not unverified_detail.has("assemblyBounds")
		and not unverified_detail.has("fitAttempts") and not unverified_detail.has("noFeasibleFit")
		and not unverified_detail.has("fullFootprintRejection"))
	_cases.append({"id": "unrepresentable_seat", "result": rejected})


func _two_course_completion_contract() -> void:
	# Source-derived endpoint, not a rounded diagnostic string. This calls the
	# ordinary sampler + street sequence but deliberately omits whole-Citadel
	# completion/publication. Only the isolated threshold transaction is tested.
	var seed := 237207443
	var compound := Sampler.sample_compound(seed, "castle", {"biome": "forest", "siteKey": "river-citadel",
		"citadelScale": 1.25, "settlementTier": "city", "style": "masonry"})
	var grammar: Dictionary = compound.castleGrammar
	var front: float = -float(grammar.courtyardDepth) * 0.5
	var keep_front: float = float(grammar.courtyardDepth) * float(grammar.keepOffset.z) - float(grammar.keepDepth) * 0.5
	var layout := Urban.sample_urban_layout(seed, grammar, front, keep_front, 0.62)
	var produced = Blueprint.new("source_endpoint_fixture", seed, "masonry")
	produced.recipe["castleGrammar"] = grammar.duplicate(true)
	var sequence := Urban.add_street_sequence(produced, front, keep_front, 0.62, float(seed % 19) / 100.0 - 0.09, layout)
	_check("courses:ordinary_street_sequence_ready", sequence.get("ready") == true)
	var source_foundation := _part(produced.snapshot(), "urban_row_03_left_foundation")
	var source_threshold := _part(produced.snapshot(), "urban_row_03_left_door_threshold")
	if source_foundation.is_empty() or source_threshold.is_empty():
		_check("courses:source_endpoint_parts_present", false)
		return
	_check("courses:source_endpoint_parts_present", true)
	for label: String in ["integer", "source_seed"]:
		var fixture: Dictionary = _seated_fixture(0.62)
		if label == "source_seed":
			for part in fixture.source.parts:
				if part.id == "seated_house_foundation":
					part.position.y = source_foundation.position.y
					part.size.y = source_foundation.size.y
				elif part.id == "seated_house_door_threshold":
					part.position.y = source_threshold.position.y
					part.size.y = source_threshold.size.y
		var frozen := var_to_bytes(fixture.source.snapshot())
		var result := Completion._complete_thresholds(fixture.source, [fixture.record], [])
		var ids := ["seated_house_door_threshold_bearing_base", "seated_house_door_threshold_bearing"]
		var detail: Dictionary = result.get("details", [{}])[0]
		var after: Dictionary = result.get("afterSnapshot", {})
		_check(label + ":courses_ready", result.get("ready") == true and detail.get("courseIds") == ids)
		_check(label + ":two_validations_and_two_additions", result.get("globalPhysicalValidations") == 2
			and after.get("parts", []).size() == fixture.source.parts.size() + 2)
		_check(label + ":source_immutable", frozen == var_to_bytes(fixture.source.snapshot()))
		var retained := not after.is_empty() and var_to_bytes(after.get("rooms", [])) == var_to_bytes(fixture.source.rooms)
		for part in fixture.source.parts:
			if part.id == "seated_house_door_threshold": continue
			retained = retained and var_to_bytes(part.snapshot()) == var_to_bytes(_part(after, part.id))
		_check(label + ":unrelated_output_geometry_unchanged", retained)
		var proof: Dictionary = result.get("_terminalProof", {}).get("report", {})
		var all_course_checks_pass := true
		for course_id: String in ids:
			all_course_checks_pass = all_course_checks_pass and _row(proof, course_id).get("passed") == true \
				and _row(proof, course_id).get("hasRootedSeats") == true
		_check(label + ":both_course_rows_pass", all_course_checks_pass)
		var lower := _part(after, ids[0])
		var upper := _part(after, ids[1])
		var threshold := _part(after, "seated_house_door_threshold")
		var exact := not lower.is_empty() and not upper.is_empty() and not threshold.is_empty()
		if exact:
			exact = float(lower.position.y) - float(lower.size.y) * 0.5 == float(Vector3(0.62, 0, 0).x) \
				and float(lower.position.y) + float(lower.size.y) * 0.5 == float(upper.position.y) - float(upper.size.y) * 0.5 \
				and float(upper.position.y) + float(upper.size.y) * 0.5 == float(threshold.position.y) - float(threshold.size.y) * 0.5
		_check(label + ":exact_constructed_partition", exact)
		_check(label + ":mandatory_chain", not lower.is_empty() and not upper.is_empty() and not threshold.is_empty()
			and lower.recipe.get("physicalRequiredSeatPartIds") == ["courtyard_slab"]
			and upper.recipe.get("physicalRequiredSeatPartIds") == [ids[0]]
			and threshold.recipe.get("physicalRequiredAnchorPartIds") == [ids[1]])
		var standalone := Threshold.prepare(fixture.source.snapshot(), fixture.record, [])
		_check(label + ":standalone_proves_every_course", standalone.get("ready") == true
			and standalone.get("globalPhysicalValidations") == 2 and standalone.get("courseChecks", []).size() == 2
			and standalone.courseChecks.all(func(row): return row.get("passed") == true))
		var repeat := Completion._complete_thresholds(fixture.source, [fixture.record], [])
		_check(label + ":repeat_exact", var_to_bytes(_stable_stage(result)) == var_to_bytes(_stable_stage(repeat)))
		var warm = Copy.copy_blueprint(fixture.source.snapshot())
		warm.validate_physical_integrity()
		Copy.clear_caches(warm)
		# Cache population may classify roots; restore the original canonical
		# source intent before comparing the same source, not different recipes.
		for index in range(warm.parts.size()):
			warm.parts[index].physical_intent = fixture.source.parts[index].physical_intent
			warm.parts[index].recipe = fixture.source.parts[index].recipe.duplicate(true)
		var warmed := Completion._complete_thresholds(warm, [fixture.record], [])
		_check(label + ":cache_cleared_exact", var_to_bytes(_stable_stage(result)) == var_to_bytes(_stable_stage(warmed)))
		_cases.append({"id": "two_courses_" + label, "seed": seed if label == "source_seed" else 1203,
			"ready": result.get("ready"), "courseIds": detail.get("courseIds", []), "contact": detail.get("contact", {}),
			"sourceFoundationY": float(source_foundation.position.y), "sourceFoundationHeight": float(source_foundation.size.y),
			"sourceThresholdY": float(source_threshold.position.y), "sourceThresholdHeight": float(source_threshold.size.y),
			"sourceEndpointRecordsSha256": _sha256(var_to_bytes([source_foundation, source_threshold]))})
		for obstacle_y: float in [0.7, 2.0]:
			var blocked := Completion._complete_thresholds(fixture.source, [fixture.record], [{"id": "course_obstruction",
				"bounds": AABB(Vector3(2.2, obstacle_y, -1.0), Vector3(1.2, 0.1, 2.0))}])
			_check(label + ":obstruction_%.1f_atomic" % obstacle_y, blocked.get("ready") == false and not blocked.has("afterSnapshot")
				and blocked.get("acceptedIdsBeforeFailure") == [] and blocked.get("globalPhysicalValidations") == 1
				and blocked.get("detail", {}).get("reason") == "threshold_bearing_reserved_overlap")
	var duplicate: Dictionary = _seated_fixture(0.62)
	duplicate.source.add_part({"id": "seated_house_door_threshold_bearing_base", "kind": "foundation",
		"position": Vector3(100.0, 0.25, 0.0), "size": Vector3(1.0, 0.5, 1.0),
		"collision": true, "physicalIntent": "structural_mass"})
	var duplicate_result := Completion._complete_thresholds(duplicate.source, [duplicate.record], [])
	_check("courses:base_id_collision_atomic", duplicate_result.get("ready") == false and not duplicate_result.has("afterSnapshot")
		and duplicate_result.get("acceptedIdsBeforeFailure") == [] and duplicate_result.get("globalPhysicalValidations") == 1
		and duplicate_result.get("detail", {}).get("reason") == "threshold_course_id_collision")
	# Direct-helper capacity contract, not a 10k-part global validation claim.
	var capacity: Dictionary = _seated_fixture(0.62)
	while capacity.source.parts.size() < Threshold.MAX_PARTS - 1:
		capacity.source.add_part({"id": "capacity_%d" % capacity.source.parts.size(), "kind": "decor",
			"position": Vector3(100.0, 10.0, 0.0), "size": Vector3.ONE, "collision": false, "physicalIntent": "visual_detail"})
	var capacity_threshold = capacity.source.parts.filter(func(part): return part.id == "seated_house_door_threshold")[0]
	var capacity_foundation = capacity.source.parts.filter(func(part): return part.id == "seated_house_foundation")[0]
	var domain: Array = Threshold.Fitter._bounds(capacity_threshold)
	domain[1] = 0.0
	domain[4] = 4.0
	var capacity_result := Threshold._candidate(capacity.source, capacity_threshold, capacity_foundation,
		"seated_house_door_threshold_bearing", domain, [])
	_check("courses:all_appended_parts_capacity_preflight", capacity_result.get("reason") == "threshold_course_part_limit"
		and not capacity_result.has("bearings") and capacity.source.parts.size() == Threshold.MAX_PARTS - 1)


func _verified_assembly_fitting_contract() -> void:
	# Direct-helper synthetic controls. Derive the expected envelope from actual
	# constructed Parts, never the door or a requested/described course extent.
	var fixture: Dictionary = _seated_fixture(0.62)
	var source = fixture.source
	var threshold = source.parts.filter(func(part): return part.id == "seated_house_door_threshold")[0]
	var foundation = source.parts.filter(func(part): return part.id == "seated_house_foundation")[0]
	var domain: Array = Threshold.Fitter._bounds(threshold)
	domain[1] = float(foundation.position.y) - float(foundation.size.y) * 0.5
	domain[4] = float(foundation.position.y) + float(foundation.size.y) * 0.5
	var bearing_id: String = threshold.id + "_bearing"
	var frozen := var_to_bytes(source.snapshot())
	var clear := Threshold._candidate(source, threshold, foundation, bearing_id, domain, [])
	var courses: Array = clear.get("bearings", [])
	_check("assembly_fit:two_constructed_courses_precondition", clear.get("ready") == true and courses.size() == 2
		and clear.get("courseIds") == [bearing_id + "_base", bearing_id])
	if clear.get("ready") != true or courses.size() != 2: return
	var lower: Array = Threshold.Fitter._bounds(courses[0])
	var upper: Array = Threshold.Fitter._bounds(courses[1])
	var expected: Array = lower.duplicate()
	expected[4] = upper[4]
	_check("assembly_fit:actual_courses_exact_partition", lower[4] == upper[1] and lower[4] < upper[4]
		and lower[0] == upper[0] and lower[2] == upper[2] and lower[3] == upper[3] and lower[5] == upper[5])
	var volumes: Array = [{"id": "first_course_only", "bounds": AABB(
		courses[0].position - courses[0].size * 0.5, courses[0].size)}]
	var inputs := var_to_bytes([source.snapshot(), domain, volumes])
	var full := Threshold._candidate(source, threshold, foundation, bearing_id, domain, volumes)
	_check("assembly_fit:first_course_obstructed", full.get("ready") == false
		and full.get("reason") == "threshold_bearing_reserved_overlap" and full.get("partId") == "first_course_only"
		and full.get("courseId") == bearing_id + "_base" and full.get("courseBounds") == lower
		and full.get("selectedSeatId") == "courtyard_slab" and full.get("seated") == true)
	_check("assembly_fit:first_rejection_has_full_verified_envelope", full.get("assemblyBounds") == expected
		and expected[4] > lower[4] and not full.has("bearings") and not full.has("afterSnapshot"))
	# The fixture contains its ordinary door: missing assembly data must not
	# silently substitute that door's height band, nor return fitting candidates.
	for label: String in ["missing", "malformed", "degenerate"]:
		var invalid: Dictionary = full.duplicate(true)
		if label == "missing":
			invalid.erase("assemblyBounds")
		elif label == "malformed":
			invalid["assemblyBounds"] = [0.0, 0.0, 0.0]
		else:
			invalid["assemblyBounds"] = expected.duplicate()
			invalid.assemblyBounds[4] = invalid.assemblyBounds[1]
		var invalid_bytes := var_to_bytes(invalid)
		var refused := Threshold._fit_obstacles(source, domain, volumes, invalid)
		_check("assembly_fit:" + label + "_assembly_rejected", refused.get("ready") == false
			and refused.get("reason") == "threshold_fit_requires_verified_assembly"
			and not refused.has("candidates") and invalid_bytes == var_to_bytes(invalid))
	# Pass the full failed attempt as the binding, just as production does.
	# Independently corrupt the seat, low plane and high plane; a tiny exact
	# scalar change must fail even though it would pass an approximate comparison.
	var fitted_domain: Array = domain.duplicate()
	fitted_domain[0] += 0.125
	fitted_domain[3] -= 0.125
	var binding_results: Array = []
	for label: String in ["wrong_seat", "wrong_low", "wrong_high"]:
		var wrong: Dictionary = full.duplicate(true)
		if label == "wrong_seat":
			wrong["selectedSeatId"] = foundation.id
		else:
			wrong["assemblyBounds"] = expected.duplicate()
			wrong.assemblyBounds[1 if label == "wrong_low" else 4] += 1.0 / 16777216.0
		var wrong_bytes := var_to_bytes(wrong)
		var refused := Threshold._candidate(source, threshold, foundation, bearing_id, fitted_domain, volumes, {}, wrong)
		_check("assembly_fit:" + label + "_rejected_before_overlap", refused.get("ready") == false
			and refused.get("reason") == "threshold_fit_changed_seat_or_band"
			and not refused.has("bearings") and not refused.has("afterSnapshot")
			and wrong_bytes == var_to_bytes(wrong))
		binding_results.append({"id": label, "reason": refused.get("reason")})
	var full_bytes := var_to_bytes(full)
	var still_blocked := Threshold._candidate(source, threshold, foundation, bearing_id, fitted_domain, volumes, {}, full)
	_check("assembly_fit:correct_binding_still_runs_overlap_admission", still_blocked.get("ready") == false
		and still_blocked.get("reason") == "threshold_bearing_reserved_overlap"
		and still_blocked.get("partId") == "first_course_only" and still_blocked.get("courseId") == bearing_id + "_base")
	var accepted := Threshold._candidate(source, threshold, foundation, bearing_id, fitted_domain, [], {}, full)
	var fitted_courses: Array = accepted.get("bearings", [])
	_check("assembly_fit:correct_binding_clear_candidate_accepted", accepted.get("ready") == true
		and accepted.get("courseIds") == clear.get("courseIds") and fitted_courses.size() == 2
		and accepted.get("contact", {}).get("seatId") == full.get("selectedSeatId")
		and accepted.get("contact", {}).get("exactTopContact") == true)
	var same_band := fitted_courses.size() == 2
	if same_band:
		var fitted_lower: Array = Threshold.Fitter._bounds(fitted_courses[0])
		var fitted_upper: Array = Threshold.Fitter._bounds(fitted_courses[1])
		same_band = fitted_lower[1] == expected[1] and fitted_upper[4] == expected[4] \
			and fitted_lower[4] == fitted_upper[1] and fitted_lower[0] > expected[0] and fitted_lower[3] < expected[3]
	_check("assembly_fit:accepted_fit_changes_xz_not_exact_y_band", same_band)
	_check("assembly_fit:source_inputs_and_binding_immutable", frozen == var_to_bytes(source.snapshot())
		and inputs == var_to_bytes([source.snapshot(), domain, volumes]) and full_bytes == var_to_bytes(full))
	_cases.append({"id": "verified_assembly_fitting", "evidenceLevel": "synthetic_direct_helper_contract",
		"firstCourseFailure": full, "actualCourseBounds": [lower, upper], "expectedAssemblyBounds": expected,
		"bindingRejections": binding_results, "correctBindingBlockedReason": still_blocked.get("reason"),
		"correctBindingClearReady": accepted.get("ready")})


func _thin_source_preservation_contract() -> void:
	var fixture: Dictionary = _seated_fixture(0.62)
	var thin = fixture.source.add_part({"id": "thin_source_detail", "kind": "decor", "collision": false,
		"position": Vector3(50.0, 1.0, 0.0), "size": Vector3.ONE, "physicalIntent": "visual_detail"})
	# Construction recipes may assign an already represented, positive thin
	# detail after default part creation. Copying must not re-run that default.
	thin.size = Vector3(0.018, 0.001, 0.015)
	var expected: Dictionary = thin.snapshot()
	var source_bytes := var_to_bytes(fixture.source.snapshot())
	var before = Copy.copy_blueprint(fixture.source.snapshot())
	var before_report: Dictionary = before.validate_physical_integrity()
	_check("thin:initial_row_passes", _row(before_report, thin.id).get("passed") == true)
	var copied = Copy.copy_blueprint(fixture.source.snapshot())
	_check("thin:copier_preserves_actual_record", var_to_bytes(_part(copied.snapshot(), thin.id)) == var_to_bytes(expected))
	_check("thin:ordinary_source_roundtrip", var_to_bytes(copied.snapshot()) == source_bytes)
	var constructed = Blueprint.BuildingPartScript.new(expected)
	_check("thin:new_part_constructor_policy_unchanged", constructed.size != thin.size
		and constructed.size == Vector3(0.02, 0.02, 0.02))
	for invalid_size: Vector3 in [Vector3.ZERO, Vector3(-1.0, 0.1, 0.1), Vector3(NAN, 0.1, 0.1)]:
		var invalid_snapshot: Dictionary = fixture.source.snapshot()
		invalid_snapshot.parts[-1].size = invalid_size
		var old_constructor = Blueprint.BuildingPartScript.new(invalid_snapshot.parts[-1])
		var invalid_copy = Copy.copy_blueprint(invalid_snapshot)
		_check("thin:invalid_constructor_policy:" + str(invalid_size),
			var_to_bytes(invalid_copy.parts[-1].size) == var_to_bytes(old_constructor.size))
	var result := Completion._complete_thresholds(fixture.source, [fixture.record], [])
	_check("thin:whole_stage_ready_two_validations", result.get("ready") == true and result.get("globalPhysicalValidations") == 2)
	_check("thin:whole_stage_output_record_exact", var_to_bytes(_part(result.get("afterSnapshot", {}), thin.id)) == var_to_bytes(expected))
	_check("thin:source_immutable", source_bytes == var_to_bytes(fixture.source.snapshot()))
	_check("thin:passing_detail_still_passes", _row(result.get("_terminalProof", {}).get("report", {}), thin.id).get("passed") == true)
	var standalone := Threshold.prepare(fixture.source.snapshot(), fixture.record, [])
	_check("thin:standalone_output_exact", standalone.get("ready") == true and standalone.get("globalPhysicalValidations") == 2
		and var_to_bytes(_part(standalone.get("afterSnapshot", {}), thin.id)) == var_to_bytes(expected))
	_cases.append({"id": "thin_source_preservation", "ready": result.get("ready"),
		"beforeRecordSha256": _sha256(var_to_bytes(expected)),
		"afterRecordSha256": _sha256(var_to_bytes(_part(result.get("afterSnapshot", {}), thin.id))),
		"dimensions": [float(thin.size.x), float(thin.size.y), float(thin.size.z)]})


func _inferred_source_role_contract() -> void:
	var fixture: Dictionary = _seated_fixture(0.62)
	var slab = fixture.source.parts.filter(func(part): return part.id == "courtyard_slab")[0]
	slab.physical_intent = ""
	slab.recipe["physicalRoot"] = true
	Copy.clear_caches(fixture.source)
	_check("inferred:fixture_blank_role_cleared_cache", slab.physical_intent == "" and not slab.recipe.has("physicalRoot")
		and fixture.source.inferred_physical_intent(slab) == "structural_mass")
	var frozen := var_to_bytes(fixture.source.snapshot())
	var result := Completion._complete_thresholds(fixture.source, [fixture.record], [])
	_check("inferred:two_course_completion_ready", result.get("ready") == true and result.get("globalPhysicalValidations") == 2)
	_check("inferred:source_immutable", frozen == var_to_bytes(fixture.source.snapshot()))
	var details: Array = result.get("details", [])
	_check("inferred:geometry_proven_seat_selected", details.size() == 1
		and details[0].get("contact", {}).get("seatId") == slab.id and details[0].get("courseIds", []).size() == 2)
	var explicit = Copy.copy_blueprint(fixture.source.snapshot())
	explicit.parts.filter(func(part): return part.id == "courtyard_slab")[0].physical_intent = "structural_mass"
	var equivalent := Completion._complete_thresholds(explicit, [fixture.record], [])
	var same_courses: bool = result.get("ready") == true and equivalent.get("ready") == true
	for id: String in ["seated_house_door_threshold_bearing_base", "seated_house_door_threshold_bearing"]:
		same_courses = same_courses and var_to_bytes(_part(result.get("afterSnapshot", {}), id)) == var_to_bytes(_part(equivalent.get("afterSnapshot", {}), id))
	_check("inferred:explicit_role_same_course_geometry", same_courses)
	fixture.source.add_part({"id": "higher_wrong_role", "kind": "foundation", "physicalIntent": "walkable_surface",
		"position": Vector3(slab.position.x, 0.5, 0.0), "size": Vector3(2.0, 1.0, 3.0), "collision": true,
		"recipe": {"navigationRole": "structural_mass", "physicalRoot": true}})
	var blocked := Completion._complete_thresholds(fixture.source, [fixture.record], [])
	_check("inferred:explicit_wrong_role_still_blocks", blocked.get("ready") == false and not blocked.has("afterSnapshot")
		and blocked.get("globalPhysicalValidations") == 1 and blocked.get("acceptedIdsBeforeFailure") == []
		and blocked.get("detail", {}).get("partId") == "higher_wrong_role"
		and blocked.get("detail", {}).get("selectedSeatId") == "courtyard_slab" and blocked.get("detail", {}).get("seated") == true)
	_cases.append({"id": "inferred_ground_role", "ready": result.get("ready"), "sourceIntent": "",
		"effectiveIntent": "structural_mass", "higherWrongRoleRejection": blocked})


func _stage_order_source_audit() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
	var retry_index := source.find("var bracket_retry := _complete_brackets")
	var threshold_index := source.find("var threshold := _complete_thresholds", retry_index + 1)
	var terminal_index := source.find("if not final.failedIds.is_empty()", threshold_index + 1)
	_check("source_order:threshold_after_retry_before_terminal_gate", retry_index >= 0
		and threshold_index > retry_index and terminal_index > threshold_index)
	var expected := '["chimney", "bracket_first", "sign", "party_wall", "bracket_retry", "threshold"]'
	for path: String in [
		"res://scripts/testing/buildings/CitadelStructuralCompletionCurrentContract.gd",
		"res://scripts/testing/buildings/CitadelStructuralCompletionComposerContract.gd",
		"res://scripts/testing/buildings/CitadelStructuralCompletionComposerPhaseAContract.gd",
		"res://scripts/testing/buildings/CitadelStructuralCompletionComposerPhaseBContract.gd",
	]:
		_check("source_order:expected_stage_list:" + path.get_file(),
			FileAccess.get_file_as_string(path).contains(expected))


func _stable_stage(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	var terminal: Dictionary = result.get("_terminalProof", {})
	terminal.erase("proof") # Live proof identity is intentionally not output evidence.
	result["_terminalProof"] = terminal
	return result


func _part(snapshot: Dictionary, id: String) -> Dictionary:
	for row: Variant in snapshot.get("parts", []):
		if row is Dictionary and row.get("id") == id: return row
	return {}


func _detail(details: Array, bearing_id: String) -> Dictionary:
	for row: Variant in details:
		if row is Dictionary and row.get("bearingId") == bearing_id: return row
	return {}


func _row(report: Dictionary, id: String) -> Dictionary:
	for row: Variant in report.get("checks", []):
		if row is Dictionary and row.get("partId") == id: return row
	return {}


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) and not FileAccess.file_exists(path) \
		and not DirAccess.dir_exists_absolute(path)


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK: return ""
	return context.finish().hex_encode()


func _unique(values: Array) -> Array:
	var seen: Dictionary = {}
	var result: Array = []
	for value: Variant in values:
		if seen.has(value): continue
		seen[value] = true
		result.append(value)
	return result


func _check(id: String, passed: bool) -> void:
	_checks.append({"id": id, "passed": passed})
	if not passed: push_error("Threshold completion integration failed: " + id)
