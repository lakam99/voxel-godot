extends RefCounted

## Unwired, one-panel source proposal. No publication, load rating or gameplay claim.
## Existing panel geometry is immutable; a sill and two housed corbels are additive.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const Layout = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const Door = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Completion = preload("res://scripts/buildings/DeterministicRecipeCompletion.gd")
const HEIGHT := 0.24
const MAX_PARTS := 10000
const MAX_VOLUMES := 4096
const MAX_SEATS := 32
const HALF := Vector3(0.07, 0.04, 0.07)
const MAX_BATCH_PANELS := 4
const MAX_COMPLETION_BATCHES := 128

## Production completion for generated facade bottoms. Eligibility is derived
## from sealed aperture declarations and structured current root checks; no
## seed, fixture ID, test offset, or authored repair list participates.
##
## One panel is revalidated and attempted at a time. Explicit immutable-geometry
## rejection is exhausted once; infrastructure/schema/work failures abort the
## private transaction rather than being mistaken for ordinary rejection.
static func prepare_all_bottom_rows(snapshot: Dictionary, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "lower_facade_started"): return _fail("cancelled")
	if not snapshot.get("parts") is Array or snapshot.parts.size() > MAX_PARTS:
		return _fail("invalid_completion_source")
	var source: Dictionary = snapshot.duplicate(true)
	var root_context := _build_root_context(Copy.copy_blueprint(source), continuation)
	if root_context.get("reason", "") == "cancelled": return root_context
	if not _continue(continuation, "lower_facade_roots_completed"): return _fail("cancelled")
	if not root_context.ready: return root_context
	var stage_policy: Dictionary = policy.duplicate(true)
	stage_policy["_independentMasonryRootContext"] = root_context.context
	var driven := _run_independent_completion(source, stage_policy, continuation)
	if not driven.get("ready", false): return driven
	if not _continue(continuation, "lower_facade_verification_started"): return _fail("cancelled")
	var verified := _verify_completion(source, driven.state, driven.accepted, continuation)
	if verified.get("reason", "") == "cancelled": return verified
	if not _continue(continuation, "lower_facade_completed"): return _fail("cancelled")
	if not verified.ready: return verified
	return {"ready": true, "exhausted": true, "fullyResolved": driven.remainingCandidateIds.is_empty(), "afterSnapshot": driven.state,
		"accepted": driven.accepted, "rejected": driven.rejected,
		"remainingUnsupportedPanelIds": driven.remainingCandidateIds,
		"batchCount": driven.attemptCount, "verification": verified,
		"scope": "Generated facade-bottom recipe completion; publication and rendered appearance remain unproven."}

static func _run_independent_completion(source: Dictionary, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation, "lower_facade_initial_proof_started"): return _fail("cancelled")
	var initial := _current_unsupported_bottom_panels(source, continuation)
	if initial.get("reason", "") == "cancelled": return initial
	if not _continue(continuation, "lower_facade_initial_proof_completed"): return _fail("cancelled")
	if not initial.ready: return initial
	var candidate_ids: Array = initial.eligible.duplicate()
	if candidate_ids.size() > MAX_COMPLETION_BATCHES: return _fail("completion_attempt_limit")
	var state: Dictionary = source.duplicate(true)
	var accepted: Array = []
	var rejected: Array = []
	var rooted: Dictionary = initial.rooted.duplicate(true)
	var support_graph: Dictionary = initial.supportGraph.duplicate(true)
	var attempt_count := 0
	for panel_id: String in candidate_ids:
		if not _continue(continuation, "lower_facade_panel:" + panel_id): return _fail("cancelled")
		if rooted.has(panel_id): continue
		attempt_count += 1
		var proposal := prepare(state, panel_id, policy, continuation)
		if proposal.get("reason", "") == "cancelled": return proposal
		var outcome := _completion_outcome(proposal)
		if not _continue(continuation, "lower_facade_panel_completed:" + panel_id): return _fail("cancelled")
		if outcome.ready:
			var support_delta := _accepted_change_support_delta(state, outcome.afterState, panel_id)
			if not support_delta.ready:
				return {"ready": false, "reason": "lower_completion_support_delta_failed", "panelId": panel_id, "detail": support_delta}
			state = outcome.afterState
			accepted.append(panel_id)
			rooted[panel_id] = true
			for id: String in support_delta.rootedTargetIds: rooted[id] = true
			_propagate_rooted_supports(rooted, support_graph)
		elif outcome.get("monotone") == true and outcome.get("reason") is String and not outcome.reason.is_empty():
			rejected.append({"panelId": panel_id, "reason": outcome.reason})
		else:
			return {"ready": false, "reason": "completion_attempt_failed", "candidateId": panel_id, "detail": outcome}
	if not _continue(continuation, "lower_facade_remaining_proof_started"): return _fail("cancelled")
	var remaining := _current_unsupported_bottom_panels(state, continuation)
	if remaining.get("reason", "") == "cancelled": return remaining
	if not _continue(continuation, "lower_facade_remaining_proof_completed"): return _fail("cancelled")
	if not remaining.ready: return remaining
	return {"ready": true, "exhausted": true, "state": state, "accepted": accepted, "rejected": rejected,
		"remainingCandidateIds": remaining.eligible, "attemptCount": attempt_count,
		"incrementalSupportProof": "Every accepted member is independently rooted; all exact new ordinary-support edges into existing parts are propagated through the immutable initial support graph."}

static func _continue(continuation: Callable, stage: String) -> bool:
	return not continuation.is_valid() or continuation.call(stage) == true

static func _accepted_change_support_delta(before: Dictionary, after: Dictionary, panel_id: String) -> Dictionary:
	if not before.get("parts") is Array or not after.get("parts") is Array or after.parts.size() < before.parts.size(): return _fail("invalid_independence_source")
	var before_by_id: Dictionary = {}
	for record: Dictionary in before.parts: before_by_id[record.id] = record
	var influences: Array = []
	for record: Dictionary in after.parts:
		if not before_by_id.has(record.id): influences.append(Part.new(record))
	if influences.size() != after.parts.size() - before.parts.size(): return _fail("invalid_independence_change_inventory")
	var excluded: Dictionary = {panel_id: true}
	for influence in influences: excluded[influence.id] = true
	var rooted_targets: Array = []
	for record: Dictionary in before.parts:
		if excluded.has(record.id): continue
		var target := Part.new(record)
		if not target.collision_enabled or _resolved_intent(target) not in ["structural_mass", "structural_root", "walkable_surface"]: continue
		for influence in influences:
			if _could_supply_ordinary_support(target, influence):
				rooted_targets.append(target.id)
				break
	rooted_targets.sort()
	return {"ready": true, "rootedTargetIds": rooted_targets}

static func _propagate_rooted_supports(rooted: Dictionary, support_graph: Dictionary) -> void:
	var changed := true
	while changed:
		changed = false
		for id: String in support_graph:
			if rooted.has(id): continue
			var supports: Array = support_graph[id]
			if supports.any(func(support_id): return rooted.has(String(support_id))):
				rooted[id] = true
				changed = true

static func _resolved_intent(part) -> String:
	if not part.physical_intent.is_empty(): return part.physical_intent
	if part.kind in ["door", "window"]: return "portal"
	if part.collision_enabled:
		return "walkable_surface" if part.kind in ["floor", "ramp"] else "structural_mass"
	return "facade_attachment" if part.kind in ["roof", "wall", "beam", "floor", "foundation", "window"] else "visual_detail"

static func _could_supply_ordinary_support(target, candidate) -> bool:
	if not candidate.collision_enabled or _resolved_intent(candidate) not in ["structural_root", "structural_mass", "walkable_surface"]: return false
	if candidate.id == String(target.recipe.get("physicalSupportsPartId", "")): return false
	var target_pose := Transform3D(Basis.from_euler(target.rotation), target.position)
	var candidate_pose := Transform3D(Basis.from_euler(candidate.rotation), candidate.position)
	var inverse := candidate_pose.affine_inverse()
	var candidate_bottom: float = candidate.position.y - candidate.size.y * 0.5
	var candidate_top: float = candidate.position.y + candidate.size.y * 0.5
	var target_bottom: float = target.position.y - target.size.y * 0.5
	var target_top: float = target.position.y + target.size.y * 0.5
	var candidate_encloses_target: bool = bool(target.recipe.get("allowEnclosingStructuralSupport", false)) \
		and candidate_bottom <= target_bottom + 0.04 and candidate_top >= target_top - 0.04 and candidate.size.y >= target.size.y + 0.30
	var candidate_is_lower: bool = candidate.position.y < target.position.y - 0.05 or candidate_encloses_target or bool(candidate.recipe.get("physicalRoot", false))
	for x_index in range(5):
		for z_index in range(5):
			var point := target_pose * Vector3(lerpf(-target.size.x * 0.5, target.size.x * 0.5, float(x_index) / 4.0),
				-target.size.y * 0.5, lerpf(-target.size.z * 0.5, target.size.z * 0.5, float(z_index) / 4.0))
			var local_point: Vector3 = inverse * point
			if absf(local_point.x) > candidate.size.x * 0.5 + 0.05 or absf(local_point.z) > candidate.size.z * 0.5 + 0.05: continue
			if candidate_is_lower and local_point.y >= -candidate.size.y * 0.5 - 0.08 and local_point.y <= candidate.size.y * 0.5 + 0.10: return true
			var surface := candidate_pose * Vector3(local_point.x, candidate.size.y * 0.5, local_point.z)
			var gap: float = point.y - surface.y
			if gap >= -0.14 and gap <= 0.26: return true
	return false

static func _current_unsupported_bottom_panels(snapshot: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var blueprint = Copy.copy_blueprint(snapshot)
	Copy.clear_caches(blueprint)
	var grid := Copy.validation_grid_work(blueprint)
	if not grid.ready:
		return grid
	var report: Dictionary = blueprint.validate_physical_integrity_cancellable(continuation)
	if report.get("cancelled", false): return _fail("cancelled")
	var checks: Dictionary = {}
	var rooted: Dictionary = {}
	for check: Dictionary in report.checks:
		if not check.get("partId") is String or checks.has(check.partId):
			return _fail("invalid_completion_physical_report")
		checks[check.partId] = check
		if bool(check.get("physicalRoot", false)) or bool(check.get("reachesGroundRoot", false)): rooted[check.partId] = true
	var by_id: Dictionary = {}
	for part in blueprint.parts:
		if by_id.has(part.id):
			return _fail("duplicate_completion_part")
		by_id[part.id] = part
	var eligible: Array = []
	var support_graph: Dictionary = {}
	for id: String in by_id:
		support_graph[id] = by_id[id].recipe.get("physicalSupportPartIds", []).duplicate()
	var declarations: Variant = snapshot.get("recipe", {}).get("facadeApertures", {})
	if not declarations is Dictionary or declarations.is_empty():
		return _fail("missing_completion_declarations")
	var keys: Array = declarations.keys()
	keys.sort()
	for key: Variant in keys:
		var declaration: Variant = declarations[key]
		if not declaration is Dictionary or not Aperture.validate(declaration, by_id):
			return _fail("invalid_completion_declaration")
		var bottom := INF
		for id: String in declaration.partIds:
			bottom = minf(bottom, Connection._bounds(by_id[id])[1])
		for id: String in declaration.partIds:
			var part = by_id[id]
			var check: Dictionary = checks.get(id, {})
			var unsupported: bool = not check.is_empty() and not bool(check.get("passed", true)) \
				and check.get("classification", "") == "building_part_taxonomy" \
				and check.get("intent", "") == "structural_mass" \
				and not bool(check.get("physicalRoot", false)) and not bool(check.get("reachesGroundRoot", false))
			if unsupported and not _has_obligation(part.recipe) and Connection._bounds(part)[1] == bottom and not eligible.has(id):
				eligible.append(id)
	eligible.sort()
	return {"ready": true, "eligible": eligible, "failureCount": report.violations.size(),
		"rooted": rooted, "supportGraph": support_graph}

static func _completion_outcome(result: Dictionary) -> Dictionary:
	if result.get("ready", false):
		return {"ready": true, "afterState": result.get("afterSnapshot")}
	return {"ready": false, "monotone": _monotone_rejection(result),
		"reason": String(result.get("reason", "")), "detail": result}

static func _monotone_rejection(result: Dictionary) -> bool:
	if _contains_hard_failure(result): return false
	var reason := String(result.get("reason", ""))
	match reason:
		"protected_volume_blocked":
			return result.get("proposedBounds") is Array and result.get("protectedBounds") is Array \
				and result.get("intersection") is Array and not result.intersection.is_empty()
		"foreign_solid_blocked":
			var measurement: Variant = result.get("measurement")
			return measurement is Dictionary and measurement.get("valid") == true and measurement.get("clear") == false
		"unrepresentable_exact_panel_seat", "panel_too_narrow_for_gravity_patch", "empty_connection_socket_domain":
			return true
		"no_clear_connection_in_socket_domain":
			var attempts: Variant = result.get("attempts")
			var empty_count: Variant = result.get("emptyPlacementCount")
			var blocked: Variant = result.get("blockedPlacements")
			if not attempts is int or attempts <= 0 or not empty_count is int or empty_count < 0 or not blocked is Array \
				or empty_count + blocked.size() != attempts:
				return false
			for placement: Variant in blocked:
				if not placement is Dictionary or not placement.get("blockingPartId") is String or placement.blockingPartId.is_empty(): return false
				var measurement: Variant = placement.get("measurement")
				if not measurement is Dictionary or measurement.get("valid") != true or measurement.get("clear") != false: return false
			return true
		"no_admitted_rooted_bottom_bearing":
			var work: Variant = result.get("work")
			var attempts: Variant = result.get("attempts")
			if not work is Dictionary or float(work.get("satPairs", Connection.MAX_SAT_WORK)) >= Connection.MAX_SAT_WORK or not attempts is Array or attempts.is_empty(): return false
			for attempt: Variant in attempts:
				if not attempt is Dictionary or not attempt.get("failure") is Dictionary or not _monotone_rejection(attempt.failure): return false
			return true
	return false

static func _contains_hard_failure(value: Variant) -> bool:
	if value is Dictionary:
		var reason: Variant = value.get("reason")
		if reason is String and (reason.contains("work_limit") or reason.ends_with("_limit") or reason.begins_with("invalid_") or reason.begins_with("malformed_")):
			return true
		for child: Variant in value.values():
			if _contains_hard_failure(child): return true
	elif value is Array:
		for child: Variant in value:
			if _contains_hard_failure(child): return true
	return false

static func _verify_completion(source: Dictionary, staged: Dictionary, accepted: Array, continuation: Callable = Callable()) -> Dictionary:
	var before = Copy.copy_blueprint(source)
	var after = Copy.copy_blueprint(staged)
	Copy.clear_caches(before)
	Copy.clear_caches(after)
	var before_grid := Copy.validation_grid_work(before)
	var after_grid := Copy.validation_grid_work(after)
	if not before_grid.ready or not after_grid.ready:
		return _fail("completion_validation_work_limit")
	var before_report: Dictionary = before.validate_physical_integrity_cancellable(continuation)
	if before_report.get("cancelled", false): return _fail("cancelled")
	var after_report: Dictionary = after.validate_physical_integrity_cancellable(continuation)
	if after_report.get("cancelled", false): return _fail("cancelled")
	var before_failed: Array = Copy.failed_ids(before_report)
	var after_failed: Array = Copy.failed_ids(after_report)
	if after_failed.any(func(id): return not before_failed.has(id)):
		return _fail("completion_added_physical_failure")
	var source_shell := source.duplicate(true)
	var staged_shell := staged.duplicate(true)
	source_shell.erase("parts")
	staged_shell.erase("parts")
	if var_to_bytes(source_shell) != var_to_bytes(staged_shell):
		return _fail("completion_changed_blueprint_shell")
	var expected_additions := accepted.size() * 3
	if staged.parts.size() != source.parts.size() + expected_additions:
		return _fail("completion_addition_count_mismatch")
	return {"ready": true, "beforeFailureCount": before_report.violations.size(),
		"afterFailureCount": after_report.violations.size(),
		"addedFailureCount": after_failed.filter(func(id): return not before_failed.has(id)).size(),
		"acceptedPanelCount": accepted.size(), "addedPartCount": expected_additions}

## Bounded offline source composition. Every later proposal sees all earlier
## accepted colliders; rejected requests remain explicit and earn no credit.
static func prepare_batch(snapshot: Dictionary, panel_ids: Array, policy: Dictionary) -> Dictionary:
	if panel_ids.is_empty() or panel_ids.size() > MAX_BATCH_PANELS: return _fail("invalid_batch_size")
	var seen: Dictionary = {}
	for id: Variant in panel_ids:
		if not id is String or id.strip_edges().is_empty() or seen.has(id): return _fail("invalid_or_duplicate_batch_panel")
		seen[id] = true
	var ordered := panel_ids.duplicate()
	ordered.sort()
	var staged := snapshot.duplicate(true)
	var accepted: Array = []
	var rejected: Array = []
	for id: String in ordered:
		var proposal := prepare(staged, id, policy)
		if not proposal.get("ready", false):
			rejected.append({"panelId": id, "reason": proposal.get("reason", "unknown_rejection"), "evidence": proposal})
			continue
		if not proposal.get("afterSnapshot") is Dictionary or not proposal.afterSnapshot.get("parts") is Array or proposal.afterSnapshot.parts.size() > MAX_PARTS: return _fail("invalid_batch_candidate")
		staged = proposal.afterSnapshot
		proposal.erase("afterSnapshot")
		accepted.append(proposal)
	if accepted.is_empty(): return {"ready": false, "reason": "no_admitted_batch_panels", "accepted": [], "rejected": rejected}
	return {"ready": true, "afterSnapshot": staged, "accepted": accepted, "rejected": rejected,
		"requestedPanelIds": ordered, "allRequestedAccepted": rejected.is_empty(),
		"scope": "Partial source proposal only. Rejected panels remain unresolved; no publication, visual or gate acceptance."}

static func prepare(snapshot: Dictionary, panel_id: String, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var input := _read(snapshot, panel_id, policy)
	if not input.ready: return input
	var b = input.blueprint
	var panel = b.find_part(panel_id)
	var pb: Array = Connection._bounds(panel)
	# Fit the represented top EXACTLY to the unchanged represented panel bottom.
	var center := Vector3(panel.position.x, pb[1] - HEIGHT * 0.5, panel.position.z)
	var size := Vector3(panel.size.x, 2.0 * (pb[1] - float(center.y)), panel.size.z)
	var body := Part.new({"id": panel.id + "_lower_bearing", "kind": "beam", "material": "timber_beam",
		"position": center, "size": size, "collision": true, "semantic": "lower_facade_bearing",
		"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true}})
	var bb: Array = Connection._bounds(body)
	if bb[4] != pb[1] or body.size.y < 2.0 * (HALF.y + Connection.PAD): return _fail("unrepresentable_exact_panel_seat")
	for id: String in [body.id, body.id + "_connection_0", body.id + "_connection_1"]:
		if b.find_part(id) != null: return _fail("existing_proposal_id")
	var body_clear := _admit(body, input.obstacles, input.volumes)
	var body_fit: Dictionary = {}
	if not body_clear.ready:
		body_fit = _shorten_body(body, panel, input.obstacles, input.volumes)
		if not body_fit.ready:
			body_clear["shorteningFailure"] = body_fit
			return body_clear
		body = body_fit.body
		body_fit.erase("body")
		bb = Connection._bounds(body)
	# This graph excludes every mutable facade/timber record. Batch completion may
	# reuse it only while its byte-bound masonry source remains exact.
	var root_context := _root_context_for(b, policy, continuation)
	if not root_context.ready: return root_context
	var roots = root_context.roots
	var rooted: Dictionary = root_context.rooted
	var candidates: Array = []
	for seat in roots.parts:
		if seat.kind != "wall" or seat.rotation != Vector3.ZERO or seat.physical_intent not in ["structural_mass", "structural_root"] or not rooted.has(seat.id): continue
		var core: Array = Connection._bounds_values(seat.position, Connection.Core.bed_size(seat.size))
		if core[1] >= bb[4] or core[4] <= bb[1] or core[2] >= body.position.z or core[5] <= body.position.z: continue
		if signf(body.position.x - seat.position.x) == 0.0: continue
		candidates.append(seat)
	if candidates.size() > MAX_SEATS: return _fail("rooted_seat_candidate_limit")
	candidates.sort_custom(func(a, c):
		var da: float = absf(a.position.x - body.position.x)
		var dc: float = absf(c.position.x - body.position.x)
		return da < dc if da != dc else a.id < c.id)
	var attempts: Array = []
	var work := {"satPairs": 0}
	for seat in candidates:
		var trial := _fit(b, roots, panel, body, seat, input, work, continuation)
		if trial.get("reason", "") == "cancelled": return trial
		if trial.ready:
			trial["independentSeatCheck"] = rooted[seat.id]
			trial["apertureDeclarationKey"] = input.declarationKey
			trial["protectedVolumeCount"] = input.volumes.size()
			if not body_fit.is_empty(): trial["bodyFit"] = body_fit
			trial["scope"] = "One-panel source geometry and independent finite rooted joints only; no whole-world physical, rendered mesh, navigation, engineering or gameplay acceptance."
			return trial
		attempts.append({"seatId": seat.id, "failure": trial})
		if work.satPairs >= Connection.MAX_SAT_WORK: break
	return {"ready": false, "reason": "no_admitted_rooted_bottom_bearing", "panelId": panel_id, "attempts": attempts, "work": work}

static func _build_root_context(source, continuation: Callable = Callable()) -> Dictionary:
	if source == null: return _fail("invalid_independent_masonry_source")
	var records := _independent_masonry_records(source)
	if not records.ready: return records
	var roots = Blueprint.new("lower_bearing_independent_masonry", source.seed, source.style)
	for record: Dictionary in records.records: roots.add_part(record)
	Copy.clear_caches(roots)
	var grid: Dictionary = Copy.validation_grid_work(roots)
	if not grid.ready: return grid
	var root_report: Dictionary = roots.validate_physical_integrity_cancellable(continuation)
	if root_report.get("cancelled", false): return _fail("cancelled")
	var rooted: Dictionary = {}
	for check: Dictionary in root_report.checks:
		if check.passed and check.get("intent") in ["structural_mass", "structural_root"] \
				and (check.get("reachesGroundRoot", false) or check.get("physicalRoot", false)):
			rooted[check.partId] = check
	return {"ready": true, "context": {"sourceBytes": var_to_bytes(records.records),
		"rootSnapshot": roots.snapshot(), "rooted": rooted}}

static func _root_context_for(source, policy: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var supplied: Variant = policy.get("_independentMasonryRootContext")
	if supplied is Dictionary and supplied.get("sourceBytes") is PackedByteArray \
			and supplied.get("rootSnapshot") is Dictionary and supplied.get("rooted") is Dictionary:
		var records := _independent_masonry_records(source)
		if not records.ready: return records
		if supplied.sourceBytes != var_to_bytes(records.records): return _fail("stale_independent_masonry_root_context")
		return {"ready": true, "roots": Copy.copy_blueprint(supplied.rootSnapshot), "rooted": supplied.rooted.duplicate(true)}
	var built := _build_root_context(source, continuation)
	if not built.ready: return built
	return {"ready": true, "roots": Copy.copy_blueprint(built.context.rootSnapshot), "rooted": built.context.rooted.duplicate(true)}

static func _independent_masonry_records(source) -> Dictionary:
	if source == null or source.parts.size() > MAX_PARTS: return _fail("invalid_independent_masonry_source")
	var records: Array = []
	for part in source.parts:
		if part.kind not in ["wall", "foundation"] or not part.collision_enabled or not Connection.Materials.is_masonry_material(part.material_id): continue
		if part.physical_intent not in ["", "structural_mass", "structural_root"]: continue
		if part.semantic == "citadel_urban_facade" or _has_obligation(part.recipe): continue
		records.append(part.snapshot())
	return {"ready": true, "records": records}

## The original fixed gravity patch chooses exactly one possible contiguous
## free interval. Reduce only a NEW sill, never a panel, obstacle or reservation.
## Rotated obstacle AABBs are conservative proposal exclusions; ordinary SAT
## admission remains required after construction and for both actual corbels.
static func _shorten_body(original, panel, obstacles: Array, volumes: Array) -> Dictionary:
	if obstacles.size() + volumes.size() > MAX_PARTS + MAX_VOLUMES: return _fail("body_fit_work_limit")
	var bounds: Array = Connection._bounds(original)
	var patch_half := Vector2(minf(0.06, panel.size.x * 0.5 - 0.06), minf(0.06, panel.size.z * 0.5 - 0.06))
	if patch_half.x <= 0.0 or patch_half.y <= 0.0: return _fail("panel_too_narrow_for_gravity_patch")
	var patch_low: float = float(panel.position.z) - float(patch_half.y)
	var patch_high: float = float(panel.position.z) + float(patch_half.y)
	var low: float = bounds[2]
	var high: float = bounds[5]
	var occupied: Array = []
	for obstacle: Dictionary in obstacles: occupied.append({"id": obstacle.id, "bounds": obstacle.bounds, "kind": "solid"})
	for volume: Dictionary in volumes:
		var box: AABB = volume.bounds
		occupied.append({"id": volume.id, "bounds": [float(box.position.x), float(box.position.y), float(box.position.z), float(box.end.x), float(box.end.y), float(box.end.z)], "kind": "protected"})
	var intersecting := 0
	for record: Dictionary in occupied:
		var box: Array = record.bounds
		if not Connection._overlaps(bounds, box): continue
		intersecting += 1
		if box[5] <= patch_low:
			low = maxf(low, box[5])
		elif box[2] >= patch_high:
			high = minf(high, box[2])
		else:
			return {"ready": false, "reason": "original_gravity_patch_blocked", "patchBlockerId": record.id,
				"patchBlockerKind": record.kind, "patchBoundsZ": [patch_low, patch_high], "blockerBounds": box}
	if low > patch_low or high < patch_high or low >= high or (low == bounds[2] and high == bounds[5]): return _fail("no_shortened_patch_interval")
	var domain := bounds.duplicate()
	domain[2] = low
	domain[5] = high
	var represented := Connection._inside_box(domain)
	if represented.is_empty(): return _fail("unrepresentable_shortened_body")
	var body := Part.new(original.snapshot())
	# _inside_box supplies only Z. Keep the exact existing X/Y and top bearing.
	body.position.z = represented.position.z
	body.size.z = represented.size.z
	var actual: Array = Connection._bounds(body)
	if actual[0] != bounds[0] or actual[1] != bounds[1] or actual[3] != bounds[3] or actual[4] != bounds[4] or actual[2] < low or actual[5] > high or actual[2] > patch_low or actual[5] < patch_high: return _fail("shortened_body_outside_patch_domain")
	var admission := _admit(body, obstacles, volumes)
	if not admission.ready: return admission
	return {"ready": true, "body": body, "originalBounds": bounds, "actualBounds": actual,
		"interval": [low, high], "unchangedGravityPatchZ": [patch_low, patch_high],
		"testedBounds": occupied.size(), "intersectingBounds": intersecting,
		"scope": "New sill fit only; two finite rooted connections and all final admissions still required."}

static func _fit(b, roots, panel, original_body, seat, input: Dictionary, work: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	var body := Part.new(original_body.snapshot())
	var core: Array = Connection._bounds_values(seat.position, Connection.Core.bed_size(seat.size))
	var bb: Array = Connection._bounds(body)
	var side: float = signf(body.position.x - seat.position.x)
	var outer: float = core[3] if side > 0.0 else core[0]
	var socket_x: float = outer - side * (HALF.x + Connection.PAD)
	var obstacles: Array = input.obstacles.filter(func(o): return o.id != seat.id)
	var additions: Array = []
	var facts: Array = []
	var joints: Array = []
	for end_index in range(2):
		# Each connection and socket must remain wholly on its half of the panel.
		var domain: Array = bb.duplicate()
		if end_index == 0: domain[5] = float(body.position.z)
		else: domain[2] = float(body.position.z)
		var neutral := Vector3(socket_x, body.position.y, (domain[2] + domain[5]) * 0.5)
		var placed: Dictionary = Connection._place_connection(domain, core, neutral, HALF, obstacles, work)
		if not placed.ready: return placed
		var end := Part.new({"id": body.id + "_connection_" + str(end_index), "kind": "beam", "material": "timber_beam",
			"position": placed.end.position, "size": placed.end.size, "collision": true, "semantic": "lower_facade_connection",
			"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true}})
		var socket: Vector3 = placed.socket
		var end_fact := _joint(seat.id, "x", socket - end.position, HALF)
		end.recipe["physicalRequiredSeatPartIds"] = [seat.id]
		end.recipe["physicalRequiredSeatFacts"] = [end_fact]
		var body_center := Vector3(body.position.x, socket.y, socket.z)
		facts.append(_joint(end.id, "z", body_center - body.position, Connection.HALF))
		# No whole-seat exemption: record the actual intersection and bound it
		# to the constructed socket sleeve, from core embedment to outer face.
		var eb: Array = Connection._bounds(end)
		var sb: Array = Connection._bounds(seat)
		var overlap: Array = Connection.ReplacementOccupancy.intersection(eb, sb)
		if overlap.is_empty(): return _fail("missing_actual_seat_overlap")
		for axis in range(3):
			if float(socket[axis]) - HALF[axis] < core[axis] or float(socket[axis]) + HALF[axis] > core[axis + 3]: return _fail("socket_outside_actual_masonry_core")
		for axis in [1, 2]:
			if overlap[axis] < float(socket[axis]) - HALF[axis] - Connection.PAD or overlap[axis + 3] > float(socket[axis]) + HALF[axis] + Connection.PAD: return _fail("unintended_seat_overlap")
		var deep: float = float(socket.x) - side * (HALF.x + Connection.PAD)
		if (side > 0.0 and overlap[0] < deep) or (side < 0.0 and overlap[3] > deep): return _fail("excessive_socket_depth")
		var clear := _admit(end, obstacles, input.volumes)
		if not clear.ready: return clear
		for prior: Dictionary in additions:
			var pair: Dictionary = Connection.Admission.measure(_pose(end), _pose(Part.new(prior)))
			if not pair.valid or not pair.clear: return _fail("connections_overlap")
		additions.append(end.snapshot())
		joints.append({"seatId": seat.id, "socket": socket, "coreBounds": core, "actualOverlap": overlap, "placement": placed.evidence})
	body.recipe["physicalRequiredSeatPartIds"] = facts.map(func(f): return f.seatId)
	body.recipe["physicalRequiredSeatFacts"] = facts
	var changed := Part.new(panel.snapshot())
	Copy.Frame._clean_derived(changed)
	var half_patch := Vector2(minf(0.06, panel.size.x * 0.5 - 0.06), minf(0.06, panel.size.z * 0.5 - 0.06))
	if half_patch.x <= 0.0 or half_patch.y <= 0.0: return _fail("panel_too_narrow_for_gravity_patch")
	changed.recipe["physicalRequiredSeatPartIds"] = [body.id]
	changed.recipe["physicalRequiredSeatFacts"] = [{"seatId": body.id, "loadDirection": "world_down", "seatFace": "max_y",
		"localPatchCenter": Vector3(0.0, -panel.size.y * 0.5, 0.0), "localPatchHalfExtents": half_patch}]
	additions.push_front(body.snapshot())
	var proof = Copy.copy_blueprint(roots.snapshot())
	for record: Dictionary in additions: proof.add_part(record)
	proof.add_part(changed.snapshot())
	Copy.clear_caches(proof)
	var proof_grid: Dictionary = Copy.validation_grid_work(proof)
	if not proof_grid.ready:
		proof_grid["phase"] = "complete_assembly_before_validation"
		return proof_grid
	var physical: Dictionary = proof.validate_physical_integrity_cancellable(continuation)
	if physical.get("cancelled", false): return _fail("cancelled")
	var wanted: Array = additions.map(func(record): return record.id)
	wanted.append(panel.id)
	var checks: Array = physical.checks.filter(func(check): return wanted.has(check.partId))
	if checks.size() != wanted.size() or checks.any(func(check): return not check.passed): return {"ready": false, "reason": "finite_rooted_assembly_failed", "checks": checks}
	# Verify every fact explicitly: inferred support cannot substitute for one.
	for id: String in wanted:
		var part = proof.find_part(id)
		for fact: Dictionary in part.recipe.physicalRequiredSeatFacts:
			if not proof.has_rooted_bearer_seat(part, fact): return _fail("required_finite_joint_failed")
	var after: Dictionary = b.snapshot()
	for index in range(after.parts.size()):
		if after.parts[index].id == panel.id: after.parts[index] = changed.snapshot()
	for record: Dictionary in additions: after.parts.append(record)
	return {"ready": true, "afterSnapshot": after, "panelId": panel.id, "panel": changed.snapshot(), "additions": additions,
		"joints": joints, "checks": checks, "work": work.duplicate(), "proofGridWork": proof_grid, "sourceGeometryUnchanged": true}

static func _read(snapshot: Dictionary, panel_id: String, policy: Dictionary) -> Dictionary:
	if not snapshot.get("id") is String or not snapshot.get("seed") is int or not snapshot.get("style") is String or not snapshot.get("recipe") is Dictionary or not snapshot.get("parts") is Array or not snapshot.get("rooms") is Array: return _fail("invalid_snapshot")
	if snapshot.parts.is_empty() or snapshot.parts.size() > MAX_PARTS or snapshot.rooms.size() > 512: return _fail("source_limit")
	var by_id: Dictionary = {}
	for record: Variant in snapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or by_id.has(record.id) or not record.get("recipe") is Dictionary or not record.get("physicalIntent") is String: return _fail("invalid_part_record")
		for key: String in ["kind", "material", "semantic"]:
			if not record.get(key) is String or record[key].is_empty(): return _fail("invalid_part_identity")
		if not record.get("collision") is bool: return _fail("invalid_collision_flag")
		for key: String in ["position", "rotation", "size"]:
			if not record.get(key) is Vector3 or not record[key].is_finite(): return _fail("invalid_part_geometry")
		if record.recipe.has("physicalIntent") and not record.recipe.physicalIntent is String: return _fail("invalid_recipe_intent")
		var part := Part.new(record)
		# Copy.copy_blueprint preserves the top-level snapshot authority. Reject
		# any recipe override/normalisation that would make Part.new disagree.
		if part.physical_intent != record.physicalIntent:
			return {"ready": false, "reason": "conflicting_physical_intent", "partId": record.id,
				"snapshotIntent": record.physicalIntent, "constructedIntent": part.physical_intent}
		# Native Vector3 stores the canonical minimum as float32. Compare with
		# the owner's exact round trip, not the double literal or an epsilon.
		if part.size != record.size:
			return {"ready": false, "reason": "degenerate_part", "partId": record.id,
				"sourceSize": record.size, "canonicalSize": part.size}
		if not Connection.Admission._valid(_pose(part)): return _fail("invalid_part_pose")
		by_id[part.id] = part
	if not by_id.has(panel_id): return _fail("missing_panel")
	var panel = by_id[panel_id]
	if panel.kind != "wall" or panel.semantic != "citadel_urban_facade" or panel.physical_intent not in ["", "structural_mass"] or panel.rotation != Vector3.ZERO or not panel.collision_enabled or not Connection.Materials.is_masonry_material(panel.material_id) or _has_obligation(panel.recipe): return _fail("ineligible_panel")
	var declarations: Variant = snapshot.recipe.get("facadeApertures")
	if not declarations is Dictionary or declarations.is_empty() or declarations.size() > 128: return _fail("missing_aperture_declarations")
	var volumes: Array = []
	var owner := ""
	var declared_ids: Dictionary = {}
	var keys: Array = declarations.keys()
	if keys.any(func(key): return not key is String): return _fail("invalid_declaration_key")
	keys.sort()
	for key: Variant in keys:
		var declaration: Variant = declarations[key]
		if not key is String or not Aperture.validate(declaration, by_id): return _fail("invalid_aperture_binding")
		if declaration.get("producerPrefix") != key or not declaration.get("semantic") is String or not declaration.get("wallDomain") is AABB or not Copy.Frame._valid_bounds(declaration.wallDomain) or not declaration.get("openings") is Array: return _fail("invalid_aperture_schema")
		if declaration.openings.size() + volumes.size() > MAX_VOLUMES: return _fail("aperture_volume_limit")
		for id: String in declaration.partIds:
			if declared_ids.has(id) or by_id[id].semantic != declaration.semantic: return _fail("ambiguous_declaration_membership")
			declared_ids[id] = key
		if declaration.partIds.has(panel_id): owner = key
		for opening: Variant in declaration.openings:
			if not opening is Dictionary or not opening.get("input") is Dictionary or not opening.get("fullVolume") is AABB or not Copy.Frame._valid_bounds(opening.fullVolume): return _fail("invalid_aperture_volume")
			volumes.append({"id": "aperture:" + str(opening.get("id", "")), "bounds": opening.fullVolume})
	if owner.is_empty(): return _fail("undeclared_panel")
	var bottom: float = Connection._bounds(panel)[1]
	for id: String in declarations[owner].partIds:
		if Connection._bounds(by_id[id])[1] < bottom: return _fail("not_bottom_row")
	var protected: Dictionary = _protected(snapshot, policy, by_id.values())
	if not protected.ready: return protected
	volumes.append_array(protected.volumes)
	if volumes.size() > MAX_VOLUMES: return _fail("protected_volume_limit")
	var obstacles: Dictionary = Connection._obstacles(by_id.values())
	if not obstacles.ready: return obstacles
	return {"ready": true, "blueprint": Copy.copy_blueprint(snapshot), "declarationKey": owner, "volumes": volumes, "obstacles": obstacles.boxes}

static func _protected(snapshot: Dictionary, policy: Dictionary, parts: Array) -> Dictionary:
	if not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes") is Array or policy.furnitureParts.size() + policy.reservedVolumes.size() > 2048: return _fail("invalid_contents_policy")
	var volumes: Array = []
	for record: Variant in policy.furnitureParts:
		var occupied: Dictionary = Copy.Frame.furnishing_bounds(record)
		if not occupied.ready: return occupied
		volumes.append({"id": "furniture:" + str(record.get("id", "")), "bounds": occupied.bounds})
	for bounds: Variant in policy.reservedVolumes:
		if not bounds is AABB or not Copy.Frame._valid_bounds(bounds): return _fail("invalid_reservation")
		volumes.append({"id": "reservation", "bounds": bounds})
	for room: Variant in snapshot.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not Copy.Frame._valid_bounds(room.bounds) or not room.get("accesses", []) is Array: return _fail("invalid_room")
		for access: Variant in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.position.is_finite(): return _fail("invalid_access")
			var size: Variant = access.get("furnishingSize", access.get("size"))
			if not size is Vector3 or not Copy.Frame._valid_bounds(AABB(Vector3.ZERO, size)): return _fail("invalid_access_size")
			volumes.append({"id": "access:" + str(access.get("id", "")), "bounds": Layout.access_reservation(access)})
	for part in parts:
		if part.kind == "window": volumes.append({"id": "window:" + part.id, "bounds": Transform3D(Basis.from_euler(part.rotation), part.position) * AABB(-part.size * 0.5, part.size)})
		if part.kind != "door": continue
		var presentation: Variant = part.recipe.get("doorPresentation", "door")
		var motion: Variant = part.recipe.get("doorMotion", "swing")
		if presentation == "portcullis" and motion == "raise":
			# Work forecast only: the shared descriptor owns all actual geometry,
			# moving bounds, stationary lever pieces and the published raise offset.
			if maxi(4, ceili(part.size.x / 0.30)) + 5 + volumes.size() > MAX_VOLUMES: return _fail("protected_volume_limit")
			var world := Transform3D(Basis.from_euler(part.rotation), part.position)
			var swept: Array = Door.portcullis_sweep_bounds(part.size, world)
			if swept.is_empty() or swept.size() + volumes.size() > MAX_VOLUMES: return _fail("invalid_portcullis_sweep")
			for index in range(swept.size()):
				var bounds: Variant = swept[index]
				if not bounds is AABB or not Copy.Frame._valid_bounds(bounds): return _fail("invalid_portcullis_sweep")
				volumes.append({"id": "door_sweep:" + part.id + ":" + str(index), "bounds": bounds})
			continue
		# Unrecognised presentation/motion combinations never use a proxy.
		if presentation not in ["", "door"] or motion != "swing": return _fail("unsupported_door_sweep:" + part.id)
		var swept: Array = Door.ordinary_sweep_bounds(part.size, Transform3D(Basis.from_euler(part.rotation), part.position))
		if swept.is_empty() or swept.size() + volumes.size() > MAX_VOLUMES: return _fail("invalid_ordinary_door_sweep")
		for primitive: Dictionary in swept:
			if not primitive.get("bounds") is AABB or not Copy.Frame._valid_bounds(primitive.bounds): return _fail("invalid_ordinary_door_sweep")
			volumes.append({"id": "door_sweep:" + part.id + ":" + String(primitive.name), "bounds": primitive.bounds})
		if volumes.size() > MAX_VOLUMES: return _fail("protected_volume_limit")
	return {"ready": true, "volumes": volumes}

static func _admit(part, obstacles: Array, volumes: Array) -> Dictionary:
	for obstacle: Dictionary in obstacles:
		var measured: Dictionary = Connection.Admission.measure(_pose(part), obstacle.pose)
		if not measured.valid or not measured.clear: return {"ready": false, "reason": "foreign_solid_blocked", "blockingPartId": obstacle.id, "measurement": measured}
	var bounds: Array = Connection._bounds(part)
	for volume: Dictionary in volumes:
		var box: AABB = volume.bounds
		var protected_bounds: Array = [float(box.position.x), float(box.position.y), float(box.position.z), float(box.end.x), float(box.end.y), float(box.end.z)]
		if Connection._overlaps(bounds, protected_bounds):
			return {"ready": false, "reason": "protected_volume_blocked", "blockingPartId": volume.id,
				"proposedPartId": part.id, "proposedBounds": bounds, "protectedBounds": protected_bounds,
				"intersection": Connection.ReplacementOccupancy.intersection(bounds, protected_bounds)}
	return {"ready": true}

static func _joint(id: String, axis: String, center: Vector3, half: Vector3) -> Dictionary:
	return {"seatId": id, "contactMode": "housed_overlap", "localSpanAxis": axis, "localOverlapCenter": center,
		"localOverlapHalfExtents": half, "minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}

static func _has_obligation(recipe: Dictionary) -> bool:
	return recipe.keys().any(func(key): return String(key).begins_with("physicalRequired") and recipe[key] != [])

static func _pose(part) -> Transform3D:
	return Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position)

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
