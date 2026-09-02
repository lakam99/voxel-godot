extends SceneTree

## DIAGNOSTIC SOURCE CONTRACT ONLY. Intentionally stops the real composer at
## street_and_civic_completed. Does NOT prove completed composition, furniture
## (not yet prepared), publication, visuals, navigation, NPCs or gameplay.
## Isolated root/threshold/course closure proof is NOT full-source admission.
## A separate ordinary threshold-completion case uses the entire captured source
## and its initial proof, including eligible elevated seats; still no late stages.
## Critic review is mandatory before any Godot launch; caller owns <=120s budget.
## Required: fresh absolute VOXEL_THRESHOLD_PRODUCTION_GROUND_REPORT (.json).
## Optional: fresh absolute VOXEL_THRESHOLD_PRODUCTION_GROUND_SOURCE (.bin),
## written once as var_to_bytes(captured snapshot), never used as an input here.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Planes = preload("res://scripts/buildings/ThresholdBearingConstructionPlanes.gd")
const Fitter = preload("res://scripts/buildings/ThresholdBearingFootprintFitter.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Seats = preload("res://scripts/buildings/ThresholdBearingSeatRecipe.gd")
const Threshold = preload("res://scripts/buildings/CitadelThresholdBearingRecipe.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const Completion = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const SEED := 237207443
const LEFT_REGRESSION_ROOT_ID := "castle_compound_foundation_segment_28"
const STOP_STAGE := "street_and_civic_completed"
const MAX_REPORT_BYTES := 512 * 1024
const MAX_SOURCE_BYTES := 64 * 1024 * 1024

var _checks: Array = []
var _check_ids: Dictionary = {}
var _cases: Array = []
var _captured: Dictionary = {}
var _stages: Array = []
var _capture_count := 0
var _report_path := ""
var _source_path := ""
var _report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_report_path = OS.get_environment("VOXEL_THRESHOLD_PRODUCTION_GROUND_REPORT").simplify_path()
	_source_path = OS.get_environment("VOXEL_THRESHOLD_PRODUCTION_GROUND_SOURCE")
	if not _source_path.is_empty(): _source_path = _source_path.simplify_path()
	if not _fresh(_report_path, "json") or (not _source_path.is_empty() and
			(not _fresh(_source_path, "bin") or _source_path.to_lower() == _report_path.to_lower())):
		push_error("Require fresh absolute output paths with existing parent directories")
		quit(2)
		return
	_report = {"schema": "citadel-threshold-production-ground-v1", "seed": SEED,
		"context": {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25},
		"scope": "Early-composition diagnostic source contract; isolated closure is not admission",
		"notProven": ["completed composer", "furniture not yet prepared", "publication", "visuals", "navigation", "NPC/gameplay"],
		"engine": Engine.get_version_info(), "reportPath": _report_path,
		"sourceFiles": _source_fingerprints(), "admissionReady": false, "thresholdCompletionReady": false}
	var started: int = Time.get_ticks_msec()
	var source = Castle.build(SEED, _report.context)
	_check("capture:castle_build", source != null)
	if source == null:
		_finish()
		return
	var castle_bytes: PackedByteArray = var_to_bytes(source.snapshot())
	var castle_root = Manifest.find_part(source, LEFT_REGRESSION_ROOT_ID)
	var original_root: Dictionary = {} if castle_root == null else castle_root.snapshot()
	_report["castleSource"] = _byte_identity(castle_bytes)
	_report["castleBuildMs"] = Time.get_ticks_msec() - started
	var compose_started: int = Time.get_ticks_msec()
	var prepared: Dictionary = Urban.compose_prepared(source, SEED, _capture.bind(source))
	_report["earlyComposeMs"] = Time.get_ticks_msec() - compose_started
	_report["composerResult"] = {"ready": prepared.get("ready", false), "reason": prepared.get("reason", "")}
	_report["observedStages"] = _stages
	_check("capture:deliberate_early_stop", _capture_count == 1 and not _captured.is_empty()
		and prepared.get("ready") == false and _stages.back() == STOP_STAGE)
	if _captured.is_empty():
		_finish()
		return
	var captured_bytes: PackedByteArray = var_to_bytes(_captured)
	_report["capturedSource"] = _byte_identity(captured_bytes)
	_report.capturedSource["partCount"] = _captured.parts.size()
	_report.capturedSource["roomCount"] = _captured.rooms.size()
	_report.capturedSource["snapshotPath"] = _source_path
	_check("capture:source_roundtrip", captured_bytes.size() <= MAX_SOURCE_BYTES
		and var_to_bytes(bytes_to_var(captured_bytes)) == captured_bytes)
	_check("capture:stopped_object_exact", var_to_bytes(source.snapshot()) == captured_bytes)
	_check("capture:production_root_retained", not original_root.is_empty()
		and var_to_bytes(original_root) == var_to_bytes(_record(_captured, LEFT_REGRESSION_ROOT_ID)))
	if not _source_path.is_empty():
		_check("capture:fresh_binary_roundtrip", captured_bytes.size() <= MAX_SOURCE_BYTES
			and _write_fresh(_source_path, "bin", captured_bytes))
		_report.capturedSource["fileSha256"] = _sha(FileAccess.get_file_as_bytes(_source_path))
	var working = Copy.copy_blueprint(_captured)
	_check("copy:exact_before_cache_clear", var_to_bytes(working.snapshot()) == captured_bytes)
	Copy.clear_caches(working)
	var clean_bytes: PackedByteArray = var_to_bytes(working.snapshot())
	_report["cacheClearedSource"] = _byte_identity(clean_bytes)
	var root = Manifest.find_part(working, LEFT_REGRESSION_ROOT_ID)
	_check("source:root_present", root != null)
	if root == null:
		_finish()
		return
	_report["root"] = _part_evidence(root, working)
	_report.root["rawCapturedRecord"] = _record(_captured, LEFT_REGRESSION_ROOT_ID)
	_report.root["scope"] = "Concrete left-side blank-intent regression; not a shared support for all candidates"
	_check("source:blank_root_infers_without_cache", root.physical_intent == ""
		and _record(_captured, LEFT_REGRESSION_ROOT_ID).get("physicalIntent") == ""
		and not root.recipe.has("physicalRoot") and working.inferred_physical_intent(root) == "structural_mass"
		and working.is_grounded_structural_root(root) and Fitter._bounds(root)[1] == 0.0
		and Seats._full_box_source(root))
	var manifest: Dictionary = Manifest.read(working)
	_check("source:production_manifest", manifest.get("ready") == true)
	if not manifest.get("ready", false):
		_report["manifestFailure"] = manifest
		_finish()
		return
	var completion_records: Array = []
	for prefix: String in ["urban_row_03_left", "urban_row_03_right"]:
		var owners: Array = manifest.records.filter(func(row: Dictionary) -> bool: return row.producerPrefix == prefix)
		_check(prefix + ":unique_owner", owners.size() == 1)
		if owners.size() == 1:
			_threshold_case(working.snapshot(), owners[0])
			completion_records.append(owners[0])
	_full_source_threshold_completion(working, completion_records)
	_check("source:helper_input_immutable", var_to_bytes(working.snapshot()) == clean_bytes
		and var_to_bytes(_captured) == captured_bytes and var_to_bytes(source.snapshot()) == captured_bytes)
	_report["admissionReady"] = _cases.size() == 2 and _cases.all(func(row: Dictionary) -> bool: return row.get("admissionReady") == true)
	_report["admissionScope"] = "Full captured source plus ordinary doors/rooms/accesses, after private normalization; no furniture or later composer stages"
	_report["elapsedMs"] = Time.get_ticks_msec() - started
	_finish()


func _capture(stage: String, source) -> bool:
	_stages.append(stage)
	if stage != STOP_STAGE: return true
	_capture_count += 1
	_captured = source.snapshot().duplicate(true)
	return false


func _full_source_threshold_completion(working, records: Array) -> void:
	# Exactly ONE production stage invocation, AFTER ground-only diagnostics.
	# No mock proof, injected proven-seat map, extra validation, or source pruning.
	var before: Dictionary = working.snapshot()
	var before_bytes: PackedByteArray = var_to_bytes(before)
	var record_bytes: PackedByteArray = var_to_bytes(records)
	var expected_ids: Array = ["urban_row_03_left_door_threshold", "urban_row_03_right_door_threshold"]
	var actual_ids: Array = records.map(func(row: Dictionary) -> String: return String(row.threshold.id))
	_check("completion:actual_capture_and_two_manifest_records", working.parts.size() == 3578
		and working.parts.size() == _captured.parts.size() and actual_ids == expected_ids)
	var started: int = Time.get_ticks_msec()
	var result: Dictionary = Completion._complete_thresholds(working, records, [])
	var source_unchanged: bool = before_bytes == var_to_bytes(working.snapshot())
	var records_unchanged: bool = record_bytes == var_to_bytes(records)
	var ready: bool = result.get("ready") == true
	_report["thresholdCompletionReady"] = ready
	var events: Array = result.get("validationEvents", [])
	var after: Dictionary = result.get("afterSnapshot", {})
	var terminal: Dictionary = result.get("_terminalProof", {})
	var final_rows: Array = terminal.get("report", {}).get("checks", [])
	var final_by_id: Dictionary = {}
	var remaining: Array = []
	for row: Dictionary in final_rows:
		final_by_id[String(row.partId)] = row
		if row.get("passed") != true: remaining.append(String(row.partId))
	var events_bound: bool = (events.size() == 2 and events[0].get("phase") == "initial"
		and events[1].get("phase") == "final" and events[0].get("sourceSha256") == _sha(before_bytes)
		and events[0].get("sourceSha256") == result.get("proofSourceSha256")
		and events[1].get("sourceSha256") == _sha(var_to_bytes(after))
		and events[0].get("sourceSha256") != events[1].get("sourceSha256")
		and result.get("proofSourceByteCount") == before_bytes.size())
	var evidence: Dictionary = {"scope": "One ordinary threshold-completion stage on the FULL early captured source; no furniture/late-composer/publication/gameplay claim",
		"ready": ready, "stage": result.get("kind", ""), "reason": result.get("reason", ""),
		"elapsedMs": Time.get_ticks_msec() - started, "inputPartCount": working.parts.size(),
		"inputSource": _byte_identity(before_bytes), "manifestThresholdIds": actual_ids,
		"acceptedIds": result.get("acceptedIds", []), "selectedIds": result.get("selectedIds", []),
		"acceptedIdsBeforeFailure": result.get("acceptedIdsBeforeFailure", []), "attempts": result.get("attempts"),
		"globalPhysicalValidations": result.get("globalPhysicalValidations"), "validationEvents": events,
		"validationEventsBound": events_bound, "sourceUnchanged": source_unchanged, "manifestRecordsUnchanged": records_unchanged,
		"terminalProofAvailable": terminal.get("ready") == true, "finalCheckCount": final_rows.size(),
		"remainingFailureIds": remaining if terminal.has("report") else null,
		"initiallyPassingPreserved": ready and events_bound,
		"preservationEvidence": "Production _complete_thresholds rejects any initially passing ID absent/failing in final checks; no additional validation performed here",
		"details": [], "changedThresholdAndCourseChecks": [], "failureDiagnostic": _completion_failure_detail(result)}
	_report["thresholdCompletion"] = evidence
	_check("completion:positive_ready", ready)
	_check("completion:inputs_unchanged", source_unchanged and records_unchanged)
	_check("completion:ordinary_two_global_validations", result.get("globalPhysicalValidations") == 2 and events_bound)
	_check("completion:both_actual_thresholds_accepted", ready and result.get("kind") == "threshold"
		and result.get("acceptedIds") == expected_ids and result.get("selectedIds") == expected_ids and result.get("attempts") == 2)
	var changed_ids: Array = expected_ids.duplicate()
	var details: Array = result.get("details", [])
	_check("completion:two_details", details.size() == 2)
	for index in range(details.size()):
		var detail: Dictionary = details[index]
		var course_ids: Array = detail.get("courseIds", [])
		var contact: Dictionary = detail.get("contact", {})
		var contact_witness: Dictionary = _completion_contact_witness(after, course_ids, contact, final_by_id)
		evidence.details.append({"bearingId": detail.get("bearingId", ""), "courseIds": course_ids,
			"ready": detail.get("ready", false), "changed": detail.get("changed", false),
			"globalPhysicalValidations": detail.get("globalPhysicalValidations", -1), "contact": contact,
			"contactWitness": contact_witness})
		_check("completion:detail:%d" % index, detail.get("ready") == true and detail.get("changed") == true
			and detail.get("globalPhysicalValidations") == 0 and course_ids.size() >= 1 and course_ids.size() <= 2
			and contact.get("exactTopContact") == true and contact.get("verticalGap") == 0.0
			and float(contact.get("contactArea", 0.0)) > 0.0 and contact_witness.get("ordinarySeatsProven") == true
			and (contact_witness.get("verifiedExactButt") == true or contact_witness.get("verifiedBoundedHousing") == true))
		for id: String in course_ids:
			_check("completion:unique_course:" + id, not changed_ids.has(id))
			changed_ids.append(id)
	for id: String in changed_ids:
		var row: Dictionary = final_by_id.get(id, {})
		var compact: Dictionary = {"partId": id}
		for key: String in ["passed", "intent", "collisionEnabled", "physicalRoot", "reachesGroundRoot", "hasRootedSeats",
			"requiredSeatPartIds", "requiredSupportPartIds", "requiredAnchorPartIds", "hasRequiredAnchorFacts"]:
			if row.has(key): compact[key] = row[key]
		evidence.changedThresholdAndCourseChecks.append(compact)
		_check("completion:final_changed_check:" + id, row.get("passed") == true and row.get("reachesGroundRoot") == true)
		if not expected_ids.has(id):
			_check("completion:final_course_rooted_seats:" + id, row.get("hasRootedSeats") == true)
	var after_by_id: Dictionary = {}
	for record: Dictionary in after.get("parts", []): after_by_id[String(record.id)] = record
	var unrelated_exact: bool = (not after.is_empty() and var_to_bytes(after.get("rooms")) == var_to_bytes(before.rooms)
		and var_to_bytes(after.get("recipe")) == var_to_bytes(before.recipe))
	for record: Dictionary in before.parts:
		if not expected_ids.has(record.id):
			unrelated_exact = unrelated_exact and var_to_bytes(record) == var_to_bytes(after_by_id.get(record.id, {}))
	var final_inventory_complete: bool = (terminal.get("ready") == true and final_rows.size() == after.get("parts", []).size()
		and final_by_id.size() == final_rows.size() and after_by_id.size() == final_rows.size()
		and remaining == terminal.get("failedIds", []))
	evidence["unrelatedRecordsRoomsRecipeExact"] = unrelated_exact
	evidence["finalInventoryComplete"] = final_inventory_complete
	evidence["initiallyPassingPreserved"] = ready and events_bound and final_inventory_complete
	_check("completion:all_passing_preserved_by_stage", ready and events_bound and final_inventory_complete)
	_check("completion:unrelated_geometry_and_metadata_exact", unrelated_exact)
	_check("completion:only_declared_course_additions", after_by_id.size() == before.parts.size() + changed_ids.size() - expected_ids.size())


func _completion_contact_witness(after: Dictionary, course_ids: Array, contact: Dictionary, checks: Dictionary) -> Dictionary:
	# Full-completion evidence only. Ground-only helpers below keep exact butt
	# expectations. Housing is real bounded intersection, never a zero-gap claim.
	var result: Dictionary = {"verifiedExactButt": false, "verifiedBoundedHousing": false, "ordinarySeatsProven": false}
	if course_ids.is_empty() or course_ids.size() > 2: return result
	var course: Dictionary = _record(after, String(course_ids[0]))
	var seat_id: String = String(contact.get("seatId", ""))
	var support: Dictionary = _record(after, seat_id)
	if course.is_empty() or support.is_empty(): return result
	var course_box: Array = Planes._bounds(course.position, course.size)
	var support_box: Array = Planes._bounds(support.position, support.size)
	var intersection: Array = Threshold.Boxes.intersection(course_box, support_box)
	var actual_gap: float = float(course_box[1]) - float(support_box[4])
	var embedment: float = -actual_gap
	var mode: String = String(contact.get("contactMode", ""))
	var housing: Dictionary = contact.get("housing", {})
	var facts: Array = course.recipe.get("physicalRequiredSeatFacts", [])
	var fact: Dictionary = facts[0] if facts.size() == 1 else {}
	var support_check: Dictionary = checks.get(seat_id, {})
	var ordinary_seats: bool = (support_check.get("passed") == true
		and (support_check.get("physicalRoot") == true or support_check.get("reachesGroundRoot") == true))
	for index in range(course_ids.size()):
		var row: Dictionary = checks.get(String(course_ids[index]), {})
		var required_seat: String = seat_id if index == 0 else String(course_ids[index - 1])
		ordinary_seats = ordinary_seats and row.get("passed") == true and row.get("reachesGroundRoot") == true \
			and row.get("hasRootedSeats") == true and row.get("requiredSeatPartIds") == [required_seat]
	var declared_seat: bool = (fact.get("seatId") == seat_id and course.recipe.get("physicalRequiredSeatPartIds") == [seat_id]
		and contact.get("seatPlane") == support_box[4] and contact.get("seatGap") == actual_gap)
	var verified_butt: bool = (declared_seat and mode == "butt_seat" and contact.get("exactSeatContact") == true
		and actual_gap == 0.0 and intersection.is_empty() and fact.get("loadDirection") == "world_down"
		and fact.get("contactMode", "") != "housed_overlap" and housing.is_empty())
	var verified_housing: bool = (declared_seat and mode == "housed_overlap" and contact.get("exactSeatContact") == false
		and actual_gap < 0.0 and embedment >= 0.06 and embedment <= 0.08 and contact.get("actualEmbedment") == embedment
		and housing.get("ready") == true and housing.get("contactMode") == "housed_overlap"
		and housing.get("actualEmbedment") == embedment and housing.get("seatPlane") == support_box[4]
		and housing.get("seatId") == seat_id and housing.get("position") == course.position and housing.get("size") == course.size
		and fact.get("contactMode") == "housed_overlap" and var_to_bytes(housing.get("seatFact")) == var_to_bytes(fact)
		and intersection.size() == 6 and float(intersection[4]) - float(intersection[1]) == embedment)
	result.merge({"verifiedExactButt": verified_butt and ordinary_seats, "verifiedBoundedHousing": verified_housing and ordinary_seats,
		"ordinarySeatsProven": ordinary_seats, "contactMode": mode, "seatId": seat_id,
		"actualSeatGap": actual_gap, "actualEmbedment": embedment, "embedmentRange": [0.06, 0.08],
		"courseBounds": course_box, "supportBounds": support_box, "intersectionBounds": intersection,
		"mandatorySeatWitness": fact, "witnessMatchesHousing": var_to_bytes(housing.get("seatFact")) == var_to_bytes(fact)}, true)
	return result


func _completion_failure_detail(value: Dictionary, depth: int = 0) -> Dictionary:
	# Explicit small projection: never serialize afterSnapshot, sourceBytes,
	# _terminalProof, live proof objects, or thousands of private physical rows.
	var result: Dictionary = {}
	for key: String in ["reason", "id", "partId", "courseId", "selectedSeatId", "seatId", "seatPlane",
		"thresholdBottom", "courseBounds", "noFeasibleFit", "measurement"]:
		if value.has(key): result[key] = value[key]
	if value.get("detail") is Dictionary and depth < 4:
		result["detail"] = _completion_failure_detail(value.detail, depth + 1)
	if value.get("fitAttempts") is Array and depth < 4:
		result["fitAttempts"] = []
		for attempt: Dictionary in value.fitAttempts.slice(0, Fitter.MAX_CANDIDATES):
			result.fitAttempts.append(_completion_failure_detail(attempt, depth + 1))
	return result


func _threshold_case(snapshot: Dictionary, owner: Dictionary) -> void:
	var label: String = owner.producerPrefix
	var source = Copy.copy_blueprint(snapshot)
	Copy.clear_caches(source)
	var threshold = Manifest.find_part(source, owner.threshold.id)
	var foundation = Manifest.find_part(source, owner.threshold.foundationId)
	var case: Dictionary = {"id": label, "ownership": owner, "admissionReady": false, "candidates": []}
	_cases.append(case)
	_check(label + ":members_present", threshold != null and foundation != null)
	if threshold == null or foundation == null: return
	case["rawThreshold"] = _part_evidence(threshold, source)
	case["foundation"] = _part_evidence(foundation, source)
	var before: PackedByteArray = var_to_bytes(source.snapshot())
	var normalized: Dictionary = Planes.normalize(threshold, foundation)
	_check(label + ":planes_helper_immutable", before == var_to_bytes(source.snapshot()))
	case["normalization"] = normalized
	_check(label + ":planes_ready", normalized.get("ready") == true)
	if not normalized.get("ready", false): return
	threshold.size = normalized.record.size
	case["normalizedThreshold"] = _part_evidence(threshold, source)
	_check(label + ":normalization_preserves_xz_shape", _xz_shape(threshold.snapshot()) == _xz_shape(_record(snapshot, threshold.id)))
	var protected: Dictionary = Threshold._protected(source, [])
	_check(label + ":protected_source_ready", protected.get("ready") == true)
	if not protected.get("ready", false):
		case["protectedFailure"] = protected
		return
	case["furniturePrepared"] = false
	case["protectedVolumeCount"] = protected.volumes.size()
	var changed_faces: Dictionary = Threshold._admit_changed_faces(source, threshold.id, normalized.addedVolumes, protected.volumes)
	case["normalizationAdmission"] = changed_faces
	var domain: Array = Fitter._bounds(threshold)
	var foundation_bounds: Array = Fitter._bounds(foundation)
	domain[1] = foundation_bounds[1]
	domain[4] = foundation_bounds[4]
	var door_bounds: Array = []
	for row: Dictionary in protected.volumes:
		if String(row.id).begins_with("door:"): door_bounds.append(row.bounds)
	var fit: Dictionary = Fitter.derive(domain, door_bounds)
	case["fit"] = fit
	_check(label + ":bounded_fitter", fit.get("ready") == true and fit.get("candidates", []).size() + 1 <= Fitter.MAX_CANDIDATES)
	var domains: Array = [domain]
	if fit.get("ready", false):
		for fitted: Array in fit.candidates:
			if fitted != domain: domains.append(fitted)
	if domains.size() > Fitter.MAX_CANDIDATES: return
	var seated_count: int = 0
	var closure_count: int = 0
	for index in range(domains.size()):
		var result: Dictionary = _candidate_case(source, threshold, foundation, domains[index], protected.volumes, label + ":%02d" % index)
		result["domainKind"] = "full" if index == 0 else "door_fitted"
		case.candidates.append(result)
		if result.get("seat", {}).get("seated", false): seated_count += 1
		if result.get("isolatedClosure", {}).get("passed", false): closure_count += 1
		if result.get("admission", {}).get("ready", false) and changed_faces.get("ready", false): case.admissionReady = true
	_check(label + ":actual_root_selected_somewhere", seated_count > 0)
	_check(label + ":isolated_closure_proven_somewhere", closure_count > 0)


func _candidate_case(source, threshold, foundation, domain: Array, volumes: Array, label: String) -> Dictionary:
	var result: Dictionary = {"id": label, "domain": domain}
	var fitted: Dictionary = Connection._inside_box(domain)
	result["insideBox"] = fitted
	if fitted.is_empty():
		result["diagnosticRefusal"] = "unrepresentable_threshold_bearing"
		result["admission"] = Threshold._without_bearing(Threshold._candidate(source, threshold, foundation, threshold.id + "_bearing", domain, volumes))
		return result
	var center: Vector3 = fitted.position
	var size: Vector3 = fitted.size
	center.y = foundation.position.y
	size.y = foundation.size.y
	result["proposedCenter"] = center
	result["proposedSize"] = size
	var frozen: PackedByteArray = var_to_bytes(source.snapshot())
	var seat: Dictionary = Seats.prepare(source, threshold, center, size, 2)
	result["seat"] = seat
	result["threshold"] = _part_evidence(threshold, source)
	_check(label + ":seat_input_immutable", frozen == var_to_bytes(source.snapshot()))
	var admission: Dictionary = Threshold._candidate(source, threshold, foundation, threshold.id + "_bearing", domain, volumes)
	result["admission"] = Threshold._without_bearing(admission)
	result["diagnosticRefusal"] = admission.get("reason", "")
	_check(label + ":full_candidate_input_immutable", frozen == var_to_bytes(source.snapshot()))
	# Resolve the helper's selected source record, never a fixture-wide root.
	# Different real XZ footprints legitimately seat the two houses on different
	# courtyard segments. Failed proposals may still expose a selected seatId.
	var selected_id: String = String(seat.get("seatId", ""))
	var root = Manifest.find_part(source, selected_id) if not selected_id.is_empty() else null
	result["selectedSeatId"] = selected_id
	if root == null:
		_check(label + ":unresolved_seat_not_claimed", not seat.get("seated", false) and selected_id.is_empty())
		result["rootDiagnosticsNotRun"] = "No selected support record; no isolated seat closure claimed"
		return result
	result["root"] = _part_evidence(root, source)
	result["rootInsetIntersection"] = Seats._inset_patch(center, size, root)
	var captured_root_record: Dictionary = _record(_captured, selected_id)
	_check(label + ":selected_record_exists_in_capture", not captured_root_record.is_empty())
	if captured_root_record.is_empty(): return result
	var captured_root_source = Copy.copy_blueprint({"id": "captured_support_record", "seed": SEED,
		"style": "masonry", "recipe": {}, "rooms": [], "parts": [captured_root_record]})
	Copy.clear_caches(captured_root_source)
	_check(label + ":selected_record_matches_capture", var_to_bytes(root.snapshot())
		== var_to_bytes(captured_root_source.parts[0].snapshot()))
	var explicit = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(explicit)
	var explicit_root = Manifest.find_part(explicit, selected_id)
	explicit_root.physical_intent = explicit.inferred_physical_intent(explicit_root)
	var explicit_bytes: PackedByteArray = var_to_bytes(explicit.snapshot())
	var equivalent: Dictionary = Seats.prepare(explicit, Manifest.find_part(explicit, threshold.id), center, size, 2)
	_check(label + ":explicit_role_equivalent", var_to_bytes(equivalent) == var_to_bytes(seat))
	_check(label + ":explicit_copy_immutable", explicit_bytes == var_to_bytes(explicit.snapshot()))
	result["explicitEquivalent"] = {"selectedSeatId": selected_id, "rawIntent": explicit_root.physical_intent,
		"resultSha256": _sha(var_to_bytes(equivalent)), "blankResultSha256": _sha(var_to_bytes(seat))}
	var explicit_admission: Dictionary = Threshold._candidate(explicit, Manifest.find_part(explicit, threshold.id),
		Manifest.find_part(explicit, foundation.id), threshold.id + "_bearing", domain, volumes)
	_check(label + ":explicit_role_admission_equivalent", var_to_bytes(Threshold._without_bearing(explicit_admission))
		== var_to_bytes(result.admission) and explicit_bytes == var_to_bytes(explicit.snapshot()))
	if seat.get("ready", false) and seat.get("seated", false):
		_check(label + ":selected_actual_raw_blank_root", root.id == selected_id and root.physical_intent == ""
			and not root.recipe.has("physicalRoot") and source.inferred_physical_intent(root) == "structural_mass"
			and source.is_grounded_structural_root(root) and Fitter._bounds(root)[1] == 0.0
			and Seats._full_box_source(root) and not result.rootInsetIntersection.is_empty())
		if threshold.id == "urban_row_03_left_door_threshold":
			_check(label + ":left_segment28_regression", selected_id == LEFT_REGRESSION_ROOT_ID)
		result["isolatedClosure"] = _isolated_closure(source, threshold, foundation, root, domain, seat, label)
		result["foundationAndDoorDiagnostics"] = _local_blockers(source, root, result.isolatedClosure.get("courses", []), volumes)
		result["wrongHigherRole"] = _wrong_role(source, threshold, root, center, size, seat, result.isolatedClosure.get("courses", []), label)
	_check(label + ":all_helpers_input_immutable", frozen == var_to_bytes(source.snapshot()))
	return result


func _isolated_closure(source, threshold, foundation, root, domain: Array, seat: Dictionary, label: String) -> Dictionary:
	# Explicit diagnostic isolation: remove EVERY other source part and room.
	# Preserve the real root and normalized threshold records byte-for-byte;
	# use production _candidate to construct courses, with no full-admission claim.
	var isolated: Dictionary = {"id": "isolated_production_ground_closure", "seed": SEED, "style": "masonry",
		"recipe": {}, "rooms": [], "parts": [root.snapshot(), threshold.snapshot()]}
	var closure = Copy.copy_blueprint(isolated)
	Copy.clear_caches(closure)
	var candidate: Dictionary = Threshold._candidate(closure, Manifest.find_part(closure, threshold.id), foundation,
		threshold.id + "_bearing", domain, [])
	var result: Dictionary = {"scope": "ISOLATED root + normalized threshold + courses; NOT full-source admission",
		"omittedPartCount": source.parts.size() - 2, "omittedRoomCount": source.rooms.size(),
		"candidate": Threshold._without_bearing(candidate), "passed": false, "courses": []}
	_check(label + ":isolated_candidate_ready", candidate.get("ready") == true)
	if not candidate.get("ready", false): return result
	_check(label + ":isolated_uses_actual_selected_root", candidate.get("contact", {}).get("seatId") == root.id
		and seat.get("seatId") == root.id)
	var courses: Array = candidate.bearings
	var bounds: Array = courses.map(func(part) -> Array: return Fitter._bounds(part))
	var exact: bool = bounds[0][1] == Fitter._bounds(root)[4] and bounds[-1][4] == Fitter._bounds(threshold)[1]
	var patches: Array = []
	for index in range(courses.size()):
		var course = courses[index]
		if index > 0: exact = exact and bounds[index - 1][4] == bounds[index][1]
		var support = root if index == 0 else courses[index - 1]
		var facts: Array = course.recipe.get("physicalRequiredSeatFacts", [])
		var fact: Dictionary = facts[0] if facts.size() == 1 else {}
		var patch: Dictionary = _patch_evidence(course, support, fact)
		patches.append(patch)
		_check(label + ":positive_inset_patch:%d" % index, patch.get("passed", false))
		_check(label + ":mandatory_seat:%d" % index, course.recipe.get("physicalRequiredSeatPartIds") == [support.id]
			and fact.get("seatId") == support.id and fact.get("loadDirection") == "world_down")
		result.courses.append(course.snapshot())
		isolated.parts.append(course.snapshot())
	_check(label + ":exact_two_courses", courses.size() == 2 and seat.get("courses", []).size() == 2 and exact)
	isolated.parts[1].recipe["physicalRequiredAnchorPartIds"] = [threshold.id + "_bearing"]
	var expected: PackedByteArray = var_to_bytes(isolated)
	var proof_source = Copy.copy_blueprint(isolated)
	_check(label + ":closure_records_exact", var_to_bytes(proof_source.snapshot()) == expected
		and _xz_shape(isolated.parts[0]) == _xz_shape(root.snapshot())
		and _xz_shape(isolated.parts[1]) == _xz_shape(threshold.snapshot()))
	# The real BuildingBlueprint validator, on the explicitly tiny closure only.
	var proof: Dictionary = proof_source.validate_physical_integrity()
	var rows: Array = proof.get("checks", [])
	var ids: Array = rows.map(func(row: Dictionary) -> String: return String(row.partId))
	var unique: Dictionary = {}
	for id: String in ids: unique[id] = true
	var passed: bool = rows.size() == isolated.parts.size() and unique.size() == rows.size() and rows.all(func(row: Dictionary) -> bool: return row.get("passed") == true)
	_check(label + ":real_isolated_blueprint_proof", passed)
	result.merge({"passed": passed and exact and patches.all(func(row: Dictionary) -> bool: return row.get("passed") == true),
		"courseBounds": bounds, "patches": patches, "proofChecks": rows, "proofSource": _byte_identity(expected),
		"closureRecords": isolated.parts}, true)
	return result


func _wrong_role(source, threshold, root, center: Vector3, size: Vector3, seat: Dictionary, courses: Array, label: String) -> Dictionary:
	# Synthetic NEGATIVE CONTROL only: copy the actual root's XZ/shape, increase
	# its height by 1/8 and explicitly declare a nonstructural role. No source edit.
	var copy = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(copy)
	var wrong_record: Dictionary = root.snapshot()
	wrong_record.id = "diagnostic_wrong_role_higher_root"
	wrong_record.physicalIntent = "visual_detail"
	wrong_record.recipe["physicalIntent"] = "visual_detail"
	wrong_record.size.y += 0.125
	wrong_record.position.y = wrong_record.size.y * 0.5
	var wrong = copy.add_part(wrong_record)
	var frozen: PackedByteArray = var_to_bytes(copy.snapshot())
	var selected: Dictionary = Seats.prepare(copy, Manifest.find_part(copy, threshold.id), center, size, 2)
	_check(label + ":wrong_role_not_selected", var_to_bytes(selected) == var_to_bytes(seat)
		and Fitter._bounds(wrong)[4] > Fitter._bounds(root)[4] and Fitter._bounds(wrong)[1] == 0.0
		and Fitter._bounds(wrong)[4] < Fitter._bounds(threshold)[1]
		and copy.is_grounded_structural_root(wrong) and Seats._full_box_source(wrong)
		and not Seats._inset_patch(center, size, wrong).is_empty())
	_check(label + ":wrong_role_helper_immutable", frozen == var_to_bytes(copy.snapshot()))
	var blocker_source = Copy.copy_blueprint({"id": "isolated_wrong_role_blocker", "seed": SEED,
		"style": "masonry", "recipe": {}, "rooms": [], "parts": [wrong.snapshot()]})
	var blocker_results: Array = []
	for record: Dictionary in courses:
		var course = Threshold.Part.new(record)
		blocker_results.append(Threshold._admit(blocker_source, course, []))
	var blocks: bool = false
	for row: Dictionary in blocker_results:
		if row.get("ready") == false and row.get("reason") == "threshold_bearing_source_overlap" and row.get("partId") == wrong.id:
			blocks = true
	_check(label + ":wrong_role_still_blocks", blocks)
	return {"scope": "Synthetic higher-role negative control; isolated obstruction witness, not full admission",
		"copiedSelectedRootId": root.id,
		"record": wrong.snapshot(), "bounds": Fitter._bounds(wrong), "selectedSeatId": selected.get("seatId", ""),
		"ineligibleAsSeat": selected == seat, "blockerResults": blocker_results}


func _local_blockers(source, root, courses: Array, volumes: Array) -> Dictionary:
	# Bounded detail census, NOT another admission authority. _candidate above
	# uses all source records and all reservations. Here expose ground/paving and
	# doors separately so the first reserved blocker cannot hide a paving overlap.
	var rows: Array = []
	var count: int = 0
	var root_contacts: Array = []
	for record: Dictionary in courses:
		var pose: Transform3D = Transform3D(Basis.from_scale(record.size), record.position)
		root_contacts.append(Admission.measure(pose, Transform3D(Basis.from_scale(root.size), root.position)))
		for part in source.parts:
			if part.kind != "foundation": continue
			var measured: Dictionary = Admission.measure(pose, Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position))
			if measured.get("valid", false) and measured.get("clear", false): continue
			count += 1
			if rows.size() < 32:
				rows.append({"courseId": record.id, "partId": part.id, "semantic": part.semantic,
					"bounds": Fitter._bounds(part), "rotation": part.rotation, "measurement": measured,
					"rawIntent": part.physical_intent, "shapeRecipe": part.recipe})
		for row: Dictionary in volumes:
			if not String(row.id).begins_with("door:"): continue
			var box: AABB = row.bounds
			var measured: Dictionary = Admission.measure(pose, Transform3D(Basis.from_scale(box.size), box.get_center()))
			if measured.get("valid", false) and measured.get("clear", false): continue
			count += 1
			if rows.size() < 32: rows.append({"courseId": record.id, "partId": row.id, "bounds": box, "measurement": measured})
	return {"scope": "Foundation and door witnesses only; full admission result reported separately",
		"rootContacts": root_contacts, "blockerCount": count, "rows": rows, "omittedDetailCount": count - rows.size()}


func _patch_evidence(course, support, fact: Dictionary) -> Dictionary:
	if not fact.get("localPatchCenter") is Vector3 or not fact.get("localPatchHalfExtents") is Vector2:
		return {"passed": false, "reason": "missing_patch"}
	var local: Vector3 = fact.localPatchCenter
	var half: Vector2 = fact.localPatchHalfExtents
	var a: Array = Fitter._bounds(course)
	var b: Array = Fitter._bounds(support)
	var x: float = float(course.position.x) + float(local.x)
	var z: float = float(course.position.z) + float(local.z)
	var patch: Array = [x - float(half.x), z - float(half.y), x + float(half.x), z + float(half.y)]
	var passed: bool = half.is_finite() and half.x > 0.0 and half.y > 0.0
	for box: Array in [a, b]:
		passed = passed and patch[0] >= box[0] + Seats.PATCH_INSET and patch[2] <= box[3] - Seats.PATCH_INSET \
			and patch[1] >= box[2] + Seats.PATCH_INSET and patch[3] <= box[5] - Seats.PATCH_INSET
	passed = passed and float(course.position.y) + float(local.y) == a[1] and a[1] == b[4]
	return {"passed": passed, "fact": fact, "worldXZBounds": patch, "positiveArea": 4.0 * float(half.x) * float(half.y),
		"requiredInset": Seats.PATCH_INSET, "courseBounds": a, "supportBounds": b}


func _part_evidence(part, source) -> Dictionary:
	return {"record": part.snapshot(), "bounds": Fitter._bounds(part), "rawIntent": part.physical_intent,
		"effectiveIntent": source.inferred_physical_intent(part) if part.physical_intent.is_empty() else part.physical_intent,
		"clearedRootCache": not part.recipe.has("physicalRoot"), "recordBytes": _byte_identity(var_to_bytes(part.snapshot()))}


func _xz_shape(record: Dictionary) -> Dictionary:
	var copy: Dictionary = record.duplicate(true)
	copy.position.y = 0.0
	copy.size.y = 0.0
	copy.recipe.erase("physicalRequiredAnchorPartIds")
	return copy


func _record(snapshot: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in snapshot.get("parts", []):
		if row.id == id: return row
	return {}


func _source_fingerprints() -> Array:
	var rows: Array = []
	for path: String in [get_script().resource_path,
		"res://scripts/buildings/CastleCompoundBlueprintBuilder.gd",
		"res://scripts/buildings/CitadelUrbanPocComposer.gd",
		"res://scripts/buildings/FacadeOpeningBearingRecipe.gd",
		"res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd",
		"res://scripts/buildings/ThresholdBearingConstructionPlanes.gd",
		"res://scripts/buildings/ThresholdBearingFootprintFitter.gd",
		"res://scripts/buildings/OpeningHeadConnectionRecipe.gd",
		"res://scripts/buildings/ThresholdBearingSeatRecipe.gd",
		"res://scripts/buildings/ThresholdBearingHousingRecipe.gd",
		"res://scripts/buildings/CitadelThresholdBearingRecipe.gd",
		"res://scripts/buildings/CitadelStructuralCompletionRecipe.gd",
		"res://scripts/buildings/ConstructionBoxAdmission.gd",
		"res://scripts/buildings/BuildingBlueprint.gd", "res://scripts/buildings/BuildingPart.gd",
		"res://scripts/buildings/ThresholdBearingCourseSplitter.gd"]:
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
		rows.append({"path": path, "byteCount": bytes.size(), "sha256": _sha(bytes)})
	return rows


func _byte_identity(bytes: PackedByteArray) -> Dictionary:
	return {"encoding": "Godot var_to_bytes, no objects", "byteCount": bytes.size(), "sha256": _sha(bytes)}


func _sha(bytes: PackedByteArray) -> String:
	var context: HashingContext = HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK: return ""
	return context.finish().hex_encode()


func _fresh(path: String, extension: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == extension \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _write_fresh(path: String, extension: String, bytes: PackedByteArray) -> bool:
	if not _fresh(path, extension): return false
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	return error == OK and FileAccess.get_file_as_bytes(path) == bytes


func _json(value: Variant) -> Variant:
	if value is Vector3: return [float(value.x), float(value.y), float(value.z)]
	if value is Vector2: return [float(value.x), float(value.y)]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value: result.append(_json(item))
		return result
	if value is float and not is_finite(value): return str(value)
	return value


func _check(id: String, passed: bool) -> void:
	if _check_ids.has(id):
		push_error("Duplicate production-ground check: " + id)
		_checks.append({"id": "duplicate:%d" % _checks.size(), "passed": false})
		return
	_check_ids[id] = true
	_checks.append({"id": id, "passed": passed})
	if not passed: push_error("Production-ground diagnostic failed: " + id)


func _finish() -> void:
	_check("report:unique_check_ids", _check_ids.size() == _checks.size())
	_report["checks"] = _checks
	_report["cases"] = _cases
	_report["sourceContractPassed"] = not _checks.is_empty() and _checks.all(func(row: Dictionary) -> bool: return row.get("passed") == true)
	_report["passed"] = _report.sourceContractPassed
	_report["admissionNotRequiredForSourceContract"] = true
	var bytes: PackedByteArray = JSON.stringify(_json(_report), "\t", true, true).to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES:
		push_error("Production-ground JSON exceeds 512 KiB; refusing truncated evidence")
		quit(2)
		return
	var parser: JSON = JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		quit(2)
		return
	var parsed: Dictionary = parser.data
	if parsed.get("sourceContractPassed") != _report.sourceContractPassed or parsed.get("checks", []).size() != _checks.size() \
		or not _write_fresh(_report_path, "json", bytes):
		quit(2)
		return
	# Byte-exact disk roundtrip above includes every numeric bound and source hash.
	print("PRODUCTION_GROUND_DIAGNOSTIC " + JSON.stringify({"path": _report_path,
		"sha256": _sha(bytes), "byteCount": bytes.size(), "sourceContractPassed": _report.sourceContractPassed,
		"admissionReady": _report.admissionReady, "thresholdCompletionReady": _report.thresholdCompletionReady, "scope": _report.scope}))
	quit(0 if _report.sourceContractPassed else 1)
