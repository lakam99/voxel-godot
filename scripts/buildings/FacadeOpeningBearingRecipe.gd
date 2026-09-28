extends RefCounted

## Unwired actual-producer adapter: single-bay APIs plus a private whole batch.
## producer_ids must be the complete IDs appended by one add_street_house call.
## Batch ownership uses the producer's semantic door/room/prefix declarations;
## no seed interpretation or copied partition grammar. Opening/header
## transfers are not implemented: exact remaining failed panel IDs are returned.
## Ground reference is that producer's actual grounded masonry foundation;
## new visible foundations extend from its bottom plane to its top, never float.
## Narrow piers can instead seat on an exposed actual paving/floor surface;
## the complete unchanged source closure must prove real contact down to ground.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Frame = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const MAX_PRODUCER_PARTS := 512
const MAX_ATTEMPTS := 16
const CLEARANCE := 0.01
# Real masonry ledge around each foot, not relaxed containment arithmetic.
const GROUND_FOOTING_MARGIN := 0.02
# Per-validation spatial work, not a wall-clock guarantee. Include every part:
# intent resolution can promote candidates, and non-candidates can query them.
const MAX_GRID_CELLS_PER_PART := 4096.0
const MAX_GRID_CELLS_TOTAL := 65536.0
const MAX_GRID_COORDINATE := 10000000.0
const MAX_BATCH_HOUSES := 64
const MAX_BATCH_CALLS := 128
const MAX_BATCH_ADDITIONS := 512
const MAX_BEARING_SURFACES := 64
const MAX_SUPPORT_CONTEXT := 96
const MAX_REDUNDANCY_PARTS := 1024
const MAX_BROAD_NORMAL_CANDIDATES := 128


static func street_house_memberships(b) -> Dictionary:
	# add_street_house declares a semantic door, its roomId, and a common ID
	# prefix. Use that producer contract; never infer ownership by proximity,
	# row number, seed, or a hand-maintained list of individual part suffixes.
	if b == null or b.parts.size() > Frame.MAX_PARTS or b.rooms.size() > Frame.MAX_RESERVATIONS: return _fail("batch_source_limit")
	var by_id: Dictionary = {}
	var rooms: Dictionary = {}
	for room in b.rooms:
		if not room is Dictionary or not room.get("id") is String or rooms.has(room.id): return _fail("invalid_batch_room")
		rooms[room.id] = room
	for part in b.parts:
		if part == null or part.id.is_empty() or by_id.has(part.id) or not b.has_finite_positive_bounds(part): return _fail("invalid_batch_source")
		by_id[part.id] = part
	var houses: Array = []
	var prefixes: Dictionary = {}
	for part in b.parts:
		if part.semantic != "citadel_urban_door": continue
		var room_id: Variant = part.recipe.get("roomId")
		if part.kind != "door" or not part.id.ends_with("_door") or not room_id is String: return _fail("invalid_street_house_declaration")
		var prefix: String = part.id.trim_suffix("_door")
		if prefix.is_empty() or prefixes.has(prefix) or room_id != prefix + "_interior" or not rooms.has(room_id) or not bool(rooms[room_id].get("citadelUrbanRoom", false)): return _fail("inconsistent_street_house_declaration")
		var foundation_id: String = prefix + "_foundation"
		if not by_id.has(foundation_id) or by_id[foundation_id].semantic != "citadel_urban_house_foundation": return _fail("missing_street_house_foundation_declaration")
		prefixes[prefix] = true
		houses.append({"prefix": prefix, "roomId": room_id, "doorId": part.id, "foundationId": foundation_id, "memberIds": [], "facadeIds": []})
		if houses.size() > MAX_BATCH_HOUSES: return _fail("batch_house_limit")
	houses.sort_custom(func(a, c): return a.prefix < c.prefix)
	var owned: Dictionary = {}
	for house in houses:
		for part in b.parts:
			if not part.id.begins_with(house.prefix + "_"): continue
			if owned.has(part.id): return _fail("overlapping_street_house_membership")
			owned[part.id] = house.prefix
			house.memberIds.append(part.id)
			if part.semantic == "citadel_urban_facade": house.facadeIds.append(part.id)
			if house.memberIds.size() > MAX_PRODUCER_PARTS: return _fail("batch_producer_part_limit")
		house.memberIds.sort()
		house.facadeIds.sort()
		if house.facadeIds.is_empty(): return _fail("street_house_without_facade")
	for part in b.parts:
		if part.semantic == "citadel_urban_facade" and not owned.has(part.id): return _fail("unowned_generated_facade")
	return {"ready": true, "houses": houses}


static func compose_bottom_bays(b, policy: Dictionary) -> Dictionary:
	# Each bay retains its fresh complete local Frame validation. All additions
	# stay private; global before/after are evaluated only at transaction edges.
	# Baseline failures guide eligibility, not claims about intermediate truth.
	var callback: Variant = policy.get("progressCallback", Callable())
	if not callback is Callable or (policy.has("progressCallback") and not callback.is_valid()): return _fail("invalid_progress_callback")
	var limit: Variant = policy.get("maxBatchCalls", MAX_BATCH_CALLS)
	var addition_limit: Variant = policy.get("maxBatchAdditions", MAX_BATCH_ADDITIONS)
	if not limit is int or limit < 1 or limit > MAX_BATCH_CALLS or not addition_limit is int or addition_limit < 1 or addition_limit > MAX_BATCH_ADDITIONS: return _fail("invalid_batch_budget")
	if not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes", []) is Array: return _fail("invalid_batch_policy")
	if policy.furnitureParts.size() + policy.get("reservedVolumes", []).size() > Frame.MAX_RESERVATIONS: return _fail("batch_reservation_limit")
	for record in policy.furnitureParts:
		var occupied := Frame.furnishing_bounds(record)
		if not occupied.ready: return occupied
	for volume in policy.get("reservedVolumes", []):
		if not volume is AABB or not Frame._valid_bounds(volume): return _fail("invalid_batch_reservation")
	var membership := street_house_memberships(b)
	if not membership.ready: return membership
	if membership.houses.is_empty(): return _fail("no_declared_street_houses")
	var reservation_count: int = policy.furnitureParts.size() + policy.get("reservedVolumes", []).size()
	for room in b.rooms:
		if not room.get("bounds") is AABB or not Frame._valid_bounds(room.bounds) or not room.get("accesses", []) is Array: return _fail("invalid_batch_room_bounds")
		if room.get("role", "") != "courtyard": reservation_count += 1
		for access in room.get("accesses", []):
			reservation_count += 1
			if reservation_count > Frame.MAX_RESERVATIONS: return _fail("batch_reservation_limit")
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3: return _fail("invalid_batch_access")
			if not Frame._valid_bounds(AABB(access.position - access.size * 0.5, access.size)): return _fail("invalid_batch_access")
	if reservation_count > Frame.MAX_RESERVATIONS: return _fail("batch_reservation_limit")
	var source: Dictionary = b.snapshot()
	var staged = copy_blueprint(source)
	var grid := validation_grid_work(staged)
	if not grid.ready: return grid
	var validation_source = copy_blueprint(source)
	clear_caches(validation_source)
	var state := {"deferFullValidation": true, "callback": callback, "startedUsec": Time.get_ticks_usec(), "sequence": 0,
		"fullValidations": 0, "fullValidationsStarted": 0, "fullValidationUsec": 0, "localFrameCalls": 0, "localFrameUsec": 0,
		"localSuccessfulCalls": 0, "bayCalls": 0, "stagedPartCount": staged.parts.size(), "prefix": "",
		"localClosureIds": [], "skippedTargetIds": [], "redundancyReviews": [], "redundancyValidationCount": 0, "redundancyValidationUsec": 0}
	var before := _batch_validate(validation_source, state, "baseline")
	state["beforePhysical"] = before
	var calls: Array = []
	var members: Array = []
	var additions: Array = []
	var changed_finishes: Array = []
	var completed_houses: Array = []
	for house in membership.houses:
		while true:
			if calls.size() >= limit or staged.parts.size() + 9 > Frame.MAX_PARTS:
				return _batch_abort("batch_work_limit_exceeded", calls, state)
			var call_started := Time.get_ticks_usec()
			state.bayCalls += 1
			state.prefix = house.prefix
			_batch_progress(state, "bay_begin")
			var result: Dictionary = _add_one_bay(staged, house.memberIds, policy, false, state)
			var summaries: Array = []
			for attempt in result.get("attempts", []):
				var bearing: Dictionary = attempt.get("footingPlan", attempt.result)
				summaries.append({"memberIds": attempt.memberIds, "ready": attempt.result.ready, "reason": attempt.result.get("reason", ""), "partId": attempt.result.get("partId", ""), "otherId": attempt.result.get("otherId", ""), "addedPartCount": attempt.result.get("partIds", []).size(),
					"supportId": bearing.get("supportId", ""), "supportTop": bearing.get("supportTop"), "upstreamIds": bearing.get("upstreamIds", []), "supportCoverage": bearing.get("supportCoverage", []), "supportAttempts": bearing.get("supportAttempts", []), "mode": bearing.get("mode", ""), "sillSpanBounds": bearing.get("sillSpanBounds"), "broadWork": bearing.get("broadWork", {}), "projectionWork": bearing.get("projectionWork")})
			var call := {"prefix": house.prefix, "ready": result.ready, "localValidated": result.get("localValidated", false), "globalValidationDeferred": true, "reason": result.get("reason", ""), "attempts": summaries, "memberIds": result.get("memberIds", []), "partIds": result.get("partIds", []), "elapsedUsec": Time.get_ticks_usec() - call_started}
			calls.append(call)
			state.stagedPartCount = staged.parts.size()
			if result.ready: state.localSuccessfulCalls += 1
			_batch_progress(state, "bay_end", result.get("memberIds", []), result.get("reason", ""))
			var fatal := _batch_fatal_reason(result)
			if not fatal.is_empty(): return _batch_abort(fatal, calls, state)
			if not result.ready:
				completed_houses.append({"prefix": house.prefix, "stopReason": "all_current_bottom_candidates_examined"})
				break
			for id in result.memberIds:
				if members.has(id): return _batch_abort("batch_repeated_member_without_progress", calls, state)
				members.append(id)
			additions.append_array(result.partIds)
			for id in result.get("pavingFinishPartIds", []):
				if not changed_finishes.has(id): changed_finishes.append(id)
			if additions.size() > addition_limit: return _batch_abort("batch_addition_limit_exceeded", calls, state)
	# Snapshot BEFORE validation clears/derives any caches. Only these original
	# authored records can be committed after both regression and preservation.
	var final_source: Dictionary = staged.snapshot()
	var paving_replay := _replay_batch_paving(staged, changed_finishes)
	if not paving_replay.ready: return _batch_abort(paving_replay.reason, calls, state)
	var final_validation_source = copy_blueprint(final_source)
	clear_caches(final_validation_source)
	var final_grid := validation_grid_work(final_validation_source)
	if not final_grid.ready: return _batch_abort(final_grid.reason, calls, state)
	var after := _batch_validate(final_validation_source, state, "final")
	state["afterPhysical"] = after
	var failed_before := failed_ids(before)
	var failed_after := failed_ids(after)
	if failed_after.any(func(id): return not failed_before.has(id)): return _batch_abort("batch_added_physical_failures", calls, state)
	var passing: Dictionary = {}
	for check in after.checks: passing[check.partId] = bool(check.passed)
	if after.checks.size() != staged.parts.size() or (members + additions + state.skippedTargetIds).any(func(id): return not passing.get(id, false)): return _batch_abort("batch_selected_added_or_skipped_parts_failed", calls, state)
	# Check the entire transaction before the first write to caller objects.
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var target_records: Dictionary = {}
	for record in final_source.parts: target_records[record.id] = record
	var source_shell := source.duplicate(true)
	var final_shell := final_source.duplicate(true)
	source_shell.erase("parts")
	final_shell.erase("parts")
	if not _batch_same_value(source_shell, final_shell) or final_source.parts.size() != source.parts.size() + additions.size(): return _batch_abort("batch_source_preservation_failed", calls, state)
	for index in range(source.parts.size()):
		var original: Dictionary = source.parts[index]
		var current: Dictionary = final_source.parts[index]
		if original.id != current.id: return _batch_abort("batch_source_order_changed", calls, state)
		var expected := original.duplicate(true)
		if members.has(original.id):
			var expected_part = Blueprint.BuildingPartScript.new(original)
			expected_part.physical_intent = original.physicalIntent
			Frame._clean_derived(expected_part)
			expected = expected_part.snapshot()
			expected.physicalIntent = "structural_mass"
			expected.recipe["physicalIntent"] = "structural_mass"
			for key in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]: expected.recipe[key] = current.recipe.get(key)
		if changed_finishes.has(original.id): expected.recipe["pavingFootingJoints"] = current.recipe.get("pavingFootingJoints")
		if not _batch_same_value(expected, current): return _batch_abort("batch_unexpected_source_change", calls, state)
	var facade_ids: Array = []
	for house in membership.houses: facade_ids.append_array(house.facadeIds)
	var unresolved := _remaining_facade_rows(staged, membership.houses, after)
	for house in completed_houses:
		house["remainingFacadeIds"] = unresolved.filter(func(row): return row.ownerPrefix == house.prefix).map(func(row): return row.partId)
	for id in members:
		by_id[id].physical_intent = target_records[id].physicalIntent
		by_id[id].recipe = target_records[id].recipe.duplicate(true)
	for id in changed_finishes:
		by_id[id].recipe["pavingFootingJoints"] = target_records[id].recipe.pavingFootingJoints.duplicate(true)
	for record in final_source.parts.slice(source.parts.size()): b.add_part(record)
	_batch_progress(state, "committed")
	return {"ready": true, "complete": true, "physicalPassed": after.passed, "calls": calls, "houses": completed_houses,
		"memberIds": members, "partIds": additions, "pavingFinishPartIds": changed_finishes, "pavingReplay": paving_replay, "beforePhysical": before, "afterPhysical": after,
		"fullValidationCount": state.fullValidations, "fullValidationUsec": state.fullValidationUsec, "houseCount": membership.houses.size(),
		"fullValidationsStarted": state.fullValidationsStarted, "localFrameCalls": state.localFrameCalls, "localFrameUsec": state.localFrameUsec, "lastProgress": state.lastProgress,
		"redundancyReviews": state.redundancyReviews, "skippedIncidentallySupportedIds": state.skippedTargetIds, "redundancyValidationCount": state.redundancyValidationCount, "redundancyValidationUsec": state.redundancyValidationUsec,
		"facadeFailuresBefore": facade_ids.filter(func(id): return failed_before.has(id)).size(),
		"facadeFailuresAfter": facade_ids.filter(func(id): return failed_after.has(id)).size(),
		"resolvedFacadeIds": facade_ids.filter(func(id): return failed_before.has(id) and not failed_after.has(id)),
		"remainingFacadeIds": facade_ids.filter(func(id): return failed_after.has(id)), "remainingPanels": unresolved,
		"limitation": "Baseline failures are eligibility hints. A bounded owning-house/prior-frame closure review skips proven incidental support and final authority rechecks those targets; this is not a universal minimal-frame proof. Resolved IDs come only from final authority. No headers, publisher, access or gameplay acceptance. Rebuild lookup before find_part on new IDs."}


static func _replay_batch_paving(b, finish_ids: Array) -> Dictionary:
	if finish_ids.size() > Frame.PavingAssembly.MAX_FINISHES: return _fail("batch_paving_finish_limit")
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var rows: Array = []
	for id in finish_ids:
		if not by_id.has(id): return _fail("batch_paving_missing_finish")
		var declaration: Variant = by_id[id].recipe.get("pavingFootingJoints")
		if not declaration is Dictionary or not declaration.get("footPartIds") is Array or declaration.footPartIds.size() > Frame.PavingAssembly.FootCuts.MAX_FEET: return _fail("batch_paving_invalid_declaration")
		var feet: Array = []
		for foot_id in declaration.footPartIds:
			if not by_id.has(foot_id): return _fail("batch_paving_missing_foot")
			feet.append(by_id[foot_id])
		var replay: Dictionary = Frame.PavingAssembly.prepare(b, [id], feet, declaration.get("nominalJoint", 0.0))
		if not replay.ready: return _fail("batch_paving_replay:" + String(replay.get("reason", "")))
		if var_to_bytes(replay.joints[id]) != var_to_bytes(declaration): return _fail("batch_paving_stale_declaration")
		rows.append({"finishId": id, "footPartIds": declaration.footPartIds.duplicate(), "geometryDigest": declaration.geometryDigest, "allRetainedFeetClear": true})
	return {"ready": true, "finishes": rows}


static func _batch_abort(reason: String, calls: Array, state: Dictionary) -> Dictionary:
	_batch_progress(state, "aborted", [], reason)
	var result := {"ready": false, "complete": false, "reason": reason, "calls": calls, "fullValidationCount": state.fullValidations, "fullValidationUsec": state.fullValidationUsec,
		"fullValidationsStarted": state.fullValidationsStarted, "localFrameCalls": state.localFrameCalls, "localFrameUsec": state.localFrameUsec,
		"redundancyReviews": state.redundancyReviews, "redundancyValidationCount": state.redundancyValidationCount, "redundancyValidationUsec": state.redundancyValidationUsec,
		"privateSuccessfulCalls": state.localSuccessfulCalls, "committed": false, "lastProgress": state.lastProgress}
	# Failure evidence stays bounded to actual failed IDs/counts, not another
	# full-world report retained by every budget/rollback control.
	if state.has("beforePhysical"): result["beforeFailedIds"] = failed_ids(state.beforePhysical)
	if state.has("afterPhysical"): result["afterFailedIds"] = failed_ids(state.afterPhysical)
	return result


static func _batch_validate(b, state: Dictionary, phase: String) -> Dictionary:
	state.fullValidationsStarted += 1
	_batch_progress(state, phase + "_validation_begin")
	var started := Time.get_ticks_usec()
	var physical: Dictionary = b.validate_physical_integrity()
	state.fullValidationUsec += Time.get_ticks_usec() - started
	state.fullValidations += 1
	_batch_progress(state, phase + "_validation_end")
	return physical


static func _batch_progress(state: Dictionary, phase: String, member_ids: Array = [], reason: String = "") -> void:
	# Detached scalar/ID-only evidence. No policy, geometry, source object,
	# report graph or writable array is exposed to the observing callback.
	state.sequence += 1
	var ids: Array = member_ids.duplicate()
	ids.make_read_only()
	var summary := {"sequence": state.sequence, "phase": phase, "prefix": state.prefix, "memberIds": ids, "reason": reason,
		"elapsedUsec": Time.get_ticks_usec() - state.startedUsec, "bayCalls": state.bayCalls, "localSuccessfulCalls": state.localSuccessfulCalls,
		"localFrameCalls": state.localFrameCalls, "localFrameUsec": state.localFrameUsec, "stagedPartCount": state.stagedPartCount,
		"redundancyValidationCount": state.redundancyValidationCount, "redundancyValidationUsec": state.redundancyValidationUsec, "skippedTargetCount": state.skippedTargetIds.size(),
		"fullValidationsStarted": state.fullValidationsStarted, "fullValidationsCompleted": state.fullValidations, "fullValidationUsec": state.fullValidationUsec}
	summary.make_read_only()
	state["lastProgress"] = summary
	if state.callback.is_valid(): state.callback.call(summary)


static func _batch_redundancy_review(b, producer_ids: Array, target_ids: Array, state: Dictionary) -> Dictionary:
	if target_ids.is_empty() or state.localClosureIds.is_empty(): return {"ready": true}
	var ids: Array = producer_ids.duplicate()
	for id in state.localClosureIds:
		if not ids.has(id): ids.append(id)
	if ids.size() > MAX_REDUNDANCY_PARTS or state.redundancyValidationCount >= MAX_BATCH_CALLS: return _fail("redundancy_context_limit_exceeded")
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var context = Blueprint.new(b.id, b.seed, b.style)
	for id in ids:
		if not by_id.has(id): return _fail("missing_redundancy_source_part")
		var original = by_id[id]
		var part = context.add_part(original.snapshot())
		part.physical_intent = original.physical_intent
		var recipe_intent: Variant = original.recipe.get("physicalIntent", "")
		if not recipe_intent is String or (not recipe_intent.is_empty() and not original.physical_intent.is_empty() and recipe_intent != original.physical_intent): return _fail("inconsistent_redundancy_source_intent")
		if part.physical_intent.is_empty(): part.physical_intent = recipe_intent
		Frame._clean_derived(part)
	var grid := validation_grid_work(context)
	if not grid.ready: return grid
	_batch_progress(state, "redundancy_review_begin", target_ids)
	var started := Time.get_ticks_usec()
	var physical: Dictionary = context.validate_physical_integrity()
	state.redundancyValidationCount += 1
	state.redundancyValidationUsec += Time.get_ticks_usec() - started
	var skipped: Array = []
	var supports: Array = []
	for check in physical.checks:
		if not target_ids.has(check.partId) or not check.passed: continue
		if not state.skippedTargetIds.has(check.partId): state.skippedTargetIds.append(check.partId)
		skipped.append(check.partId)
		supports.append({"partId": check.partId, "supportPartIds": check.get("supportPartIds", []).duplicate()})
	state.redundancyReviews.append({"contextPartCount": ids.size(), "targetIds": target_ids.duplicate(), "skippedTargetIds": skipped, "supports": supports,
		"scope": "Fresh owning-house plus prior complete local-frame closures. A sufficient local proof only; skipped targets must also pass final global authority. Not a universal minimum-frame proof."})
	_batch_progress(state, "redundancy_review_end", skipped)
	return {"ready": true}


static func _batch_same_value(a: Variant, c: Variant) -> bool:
	# Dictionary insertion order is not source geometry. All leaf values,
	# including vector/float representations, remain byte-exact.
	if typeof(a) != typeof(c): return false
	if a is Dictionary:
		if a.size() != c.size(): return false
		for key in a:
			if not c.has(key) or not _batch_same_value(a[key], c[key]): return false
		return true
	if a is Array:
		if a.size() != c.size(): return false
		for index in range(a.size()):
			if not _batch_same_value(a[index], c[index]): return false
		return true
	return var_to_bytes(a) == var_to_bytes(c)


static func _batch_fatal_reason(result: Dictionary) -> String:
	var no_fit := ["no_clear_bearing_section", "no_clear_broad_bearing_region", "no_clear_narrow_bearing_region", "no_narrow_bearing_region", "insufficient_narrow_post_height", "no_clear_footing_within_sill_envelope", "insufficient_footing_search_envelope", "insufficient_post_height", "new_footing_blocks_reservation", "existing_source_geometry_blocked", "reserved_interior_access_or_furniture_blocked", "ordinary_door_visual_geometry_blocked", "missing_or_ambiguous_grounded_footing_seat", "panel_has_no_finite_sill_seat", "no_actual_paving_foot_overlap", "frame_member_not_clear_of_cut_paving"]
	for attempt in result.get("attempts", []):
		if attempt.result.ready: continue
		var reason: String = attempt.result.get("reason", "missing_attempt_reason")
		if not no_fit.has(reason) and not reason.begins_with("new_footing_blocks_source:"): return reason
	if not result.ready and result.get("reason") != "no_clear_actual_bottom_bay": return result.get("reason", "invalid_batch_result")
	return ""


static func _remaining_facade_rows(b, houses: Array, physical: Dictionary) -> Array:
	var parts: Dictionary = {}
	var failed: Dictionary = {}
	for part in b.parts: parts[part.id] = part
	for check in physical.checks:
		if not check.passed: failed[check.partId] = check
	var rows: Array = []
	for house in houses:
		var datum := INF
		for id in house.facadeIds: datum = minf(datum, Frame._bounds(parts[id]).position.y)
		for id in house.facadeIds:
			if not failed.has(id): continue
			var bounds: AABB = Frame._bounds(parts[id])
			var bottom: bool = absf(bounds.position.y - datum) < Frame.EPS
			rows.append({"partId": id, "ownerPrefix": house.prefix, "bottomRow": bottom, "bounds": bounds,
				"supportPartIds": failed[id].get("supportPartIds", []),
				"reason": "bottom_bearing_unresolved_under_current_policy" if bottom else "higher_panel_requires_rooted_jamb_or_opening_header_not_implemented"})
	return rows


static func add_one_bay(b, producer_ids: Array, policy: Dictionary) -> Dictionary:
	return _add_one_bay(b, producer_ids, policy, false)


static func add_one_narrow_pier(b, producer_ids: Array, policy: Dictionary) -> Dictionary:
	return _add_one_bay(b, producer_ids, policy, true)


static func _add_one_bay(b, producer_ids: Array, policy: Dictionary, narrow_only: bool, batch_state: Dictionary = {}) -> Dictionary:
	if b == null or b.parts.size() > Frame.MAX_PARTS or b.rooms.size() > Frame.MAX_RESERVATIONS or producer_ids.is_empty() or producer_ids.size() > MAX_PRODUCER_PARTS or not policy.get("furnitureParts") is Array or not policy.get("reservedVolumes", []) is Array:
		return _fail("invalid_or_oversized_input")
	var by_id: Dictionary = {}
	for part in b.parts:
		if part == null or not b.has_finite_positive_bounds(part) or by_id.has(part.id): return _fail("invalid_source")
		by_id[part.id] = part
	var owned: Array = []
	for id in producer_ids:
		if not id is String or not by_id.has(id) or owned.has(by_id[id]): return _fail("invalid_producer_membership")
		owned.append(by_id[id])
	var panels: Array = owned.filter(func(part): return part.semantic == "citadel_urban_facade" and part.kind == "wall" and part.collision_enabled)
	var foundations: Array = owned.filter(func(part): return part.semantic == "citadel_urban_house_foundation" and b.is_grounded_structural_root(part))
	var doors: Array = owned.filter(func(part): return part.kind == "door" and part.recipe.has("roomId"))
	if panels.is_empty() or foundations.size() != 1 or doors.size() != 1: return _fail("requires_one_actual_street_house")
	var ground = foundations[0]
	if not _root_compatible(b, ground): return _fail("incompatible_ground_reference")
	var rooms: Array = b.rooms.filter(func(room): return room.get("id") == doors[0].recipe.roomId)
	if rooms.size() != 1 or not rooms[0].get("bounds") is AABB: return _fail("missing_producer_room")
	var plane: float = panels[0].position.x
	var outward := Vector3(signf(plane - rooms[0].bounds.get_center().x), 0, 0)
	if outward == Vector3.ZERO: return _fail("ambiguous_facade_side")
	var datum := INF
	for part in panels:
		if part.rotation != Vector3.ZERO or absf(part.position.x - plane) > Frame.EPS: return _fail("nonplanar_producer_facade")
		datum = minf(datum, part.position.y - part.size.y * 0.5)
	var furniture: Array = []
	var reserved: Array = policy.get("reservedVolumes", []).duplicate()
	if policy.furnitureParts.size() + reserved.size() > Frame.MAX_RESERVATIONS: return _fail("reservation_limit")
	for record in policy.furnitureParts:
		var occupied := Frame.furnishing_bounds(record)
		if not occupied.ready: return occupied
		furniture.append(record.duplicate(true))
		reserved.append(occupied.bounds)
	for room in b.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not room.get("accesses", []) is Array: return _fail("invalid_room")
		if room.get("role", "") != "courtyard": reserved.append(room.bounds)
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3: return _fail("invalid_access")
			reserved.append(AABB(access.position - access.size * 0.5, access.size))
		if reserved.size() > Frame.MAX_RESERVATIONS: return _fail("reservation_limit")
	for volume in reserved:
		if not volume is AABB or not Frame._valid_bounds(volume): return _fail("invalid_reservation")
	var door_visuals := Frame.closed_door_reservations(b)
	if not door_visuals.ready: return door_visuals
	if reserved.size() + door_visuals.volumes.size() > Frame.MAX_RESERVATIONS: return _fail("reservation_limit")
	reserved.append_array(door_visuals.volumes)
	var snapshot: Dictionary = b.snapshot()
	var before_work := validation_grid_work(b)
	if not before_work.ready:
		before_work["phase"] = "before"
		return before_work
	var before: Dictionary
	if batch_state.has("beforePhysical"):
		before = batch_state.beforePhysical
	else:
		var before_b = copy_blueprint(snapshot)
		clear_caches(before_b)
		before = before_b.validate_physical_integrity()
	var failed_before := failed_ids(before)
	var bottom: Array = panels.filter(func(part): return absf(part.position.y - part.size.y * 0.5 - datum) < Frame.EPS and not part.recipe.has("physicalRequiredSeatPartIds"))
	if not batch_state.is_empty():
		bottom = bottom.filter(func(part): return not batch_state.skippedTargetIds.has(part.id))
		var review := _batch_redundancy_review(b, producer_ids, bottom.filter(func(part): return failed_before.has(part.id)).map(func(part): return part.id), batch_state)
		if not review.ready: return review
		bottom = bottom.filter(func(part): return not batch_state.skippedTargetIds.has(part.id))
	bottom.sort_custom(func(a, c): return a.position.z < c.position.z)
	# Keep whole producer panels. A doorway cut never crops a panel or a sill.
	var groups: Array = []
	var group: Array = []
	var end := -INF
	for part in bottom:
		var bounds := Frame._bounds(part)
		var crosses_access := false
		for access in rooms[0].get("accesses", []):
			if bounds.position.z < access.position.z + access.size.z * 0.5 + CLEARANCE and bounds.end.z > access.position.z - access.size.z * 0.5 - CLEARANCE:
				crosses_access = true
		if crosses_access or (not group.is_empty() and (absf(bounds.position.z - end) > Frame.EPS or bounds.end.z - Frame._bounds(group[0]).position.z > 5.0)):
			if not group.is_empty(): groups.append(group)
			group = []
		if not crosses_access:
			group.append(part)
			end = bounds.end.z
	if not group.is_empty(): groups.append(group)
	# Preserve two-post ordering/geometry. Only after those candidates, try
	# individual short panels using actual under-panel occupied volumes.
	var candidates: Array = []
	if not narrow_only:
		for bay in groups: candidates.append({"panels": bay, "narrow": false})
	for panel in bottom:
		if panel.size.z >= Frame.PIER_CAP_SPAN and panel.size.z < 1.2:
			candidates.append({"panels": [panel], "narrow": true})
	var attempts: Array = []
	for entry in candidates:
		if attempts.size() >= MAX_ATTEMPTS:
			if not batch_state.is_empty(): return {"ready": false, "reason": "batch_candidate_limit_exceeded", "attempts": attempts}
			break
		var bay: Array = entry.panels
		var narrow: bool = entry.narrow
		var ids: Array = bay.map(func(part): return part.id)
		if not ids.any(func(id): return failed_before.has(id)): continue
		if not batch_state.is_empty(): _batch_progress(batch_state, "candidate_begin", ids)
		var low_z: float = Frame._bounds(bay[0]).position.z
		var high_z: float = Frame._bounds(bay.back()).end.z
		if not narrow and high_z - low_z < 1.2: continue
		var section: Dictionary = _narrow_region(b, bay[0], ground, outward, reserved) if narrow else _section(b, bay[0], low_z, high_z, datum, reserved)
		if narrow and not section.ready and section.get("reason") in ["no_clear_narrow_bearing_region", "no_narrow_bearing_region", "insufficient_narrow_post_height"]:
			section = _supported_narrow_region(b, bay[0], ground, outward, reserved)
		if not narrow and not section.ready and section.get("reason") == "no_clear_bearing_section":
			section = _supported_broad_region(b, bay, outward, reserved, true,
				_prepare_cut_bay_candidate.bind(b, ids, outward, policy, furniture))
		if not batch_state.is_empty():
			batch_state.localFrameCalls += int(section.get("cutCandidateCount", 0))
			batch_state.localFrameUsec += int(section.get("cutCandidateUsec", 0))
		if not section.ready:
			attempts.append({"memberIds": ids, "result": section})
			var fatal := _batch_fatal_reason({"ready": true, "attempts": [{"result": section}]})
			if not fatal.is_empty(): return {"ready": false, "reason": fatal, "attempts": attempts}
			continue
		var prepared_trial = section.get("preparedTrial")
		var prepared_frame: Dictionary = section.get("preparedFrame", {})
		# Private source objects never enter attempt reports or saved recipes.
		section.erase("preparedTrial")
		section.erase("preparedFrame")
		var trial = prepared_trial if prepared_trial != null else copy_blueprint(snapshot)
		var roots: Array = []
		var added_roots: Array = []
		var rejected := ""
		var center := Vector3(section.center, datum - Frame.SILL_HEIGHT * 0.5, (low_z + high_z) * 0.5)
		if narrow: center.z = section.capSpanCenter
		var footing_plan: Dictionary = section if narrow or section.has("supportId") else Frame.plan_footing_offsets(b, center, 2, high_z - low_z, outward, ground.position.y + ground.size.y * 0.5, reserved, CLEARANCE)
		if not footing_plan.ready:
			attempts.append({"memberIds": ids, "result": footing_plan})
			continue
		var placements: Array = [{"side": 0.0, "postCenter": center, "footCenter": center + outward * ((Frame.FOOT_WIDTH - Frame.POST_WIDTH) * 0.5)}] if narrow else Frame.footing_layout(center, 2, high_z - low_z, outward, footing_plan.offsets)
		for placement in placements:
			if section.has("supportId"):
				if not roots.has(section.supportId): roots.append(section.supportId)
				continue
			var foot_center: Vector3 = placement.footCenter
			var ground_top: float = ground.position.y + ground.size.y * 0.5
			var ground_bottom: float = ground.position.y - ground.size.y * 0.5
			var root_width := Frame.FOOT_WIDTH + 2.0 * GROUND_FOOTING_MARGIN
			var root_size := Vector3(root_width, ground_top - ground_bottom, root_width)
			foot_center.y = (ground_top + ground_bottom) * 0.5
			var root_bounds := AABB(foot_center - root_size * 0.5, root_size)
			var available: Array = b.parts.filter(func(part): return _root_compatible(b, part) and absf(Frame._bounds(part).end.y - ground_top) < Frame.EPS and _covers_xz(Frame._bounds(part), root_bounds))
			available.sort_custom(func(a, c): return a.id < c.id)
			if not available.is_empty():
				if not roots.has(available[0].id): roots.append(available[0].id)
				continue
			for volume in reserved:
				if Frame._penetrates(root_bounds.grow(CLEARANCE), volume): rejected = "new_footing_blocks_reservation"
			for other in b.parts:
				if Frame._penetrates(root_bounds, Frame._bounds(other)): rejected = "new_footing_blocks_source:" + other.id
			if not rejected.is_empty(): break
			var id: String = "facade_bearing_" + String(ids[0]) + "_ground_%d" % int(placement.side)
			if by_id.has(id):
				rejected = "existing_footing_id"
				break
			trial.add_part({"id": id, "kind": "foundation", "material": ground.material_id, "position": foot_center, "size": root_size, "collision": true,
				"semantic": "facade_bearing_ground_footing", "physicalIntent": "structural_mass",
				"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true, "groundReferencePartId": ground.id, "bearingPanelIds": ids.duplicate()}})
			roots.append(id)
			added_roots.append(id)
		if not rejected.is_empty():
			attempts.append({"memberIds": ids, "result": _fail(rejected)})
			continue
		var frame_policy := {"outward": outward, "foundationPartIds": roots, "reservedVolumes": policy.get("reservedVolumes", []), "furnitureParts": furniture,
			"clearance": CLEARANCE, "bearingWidth": Frame.POST_WIDTH, "bearingNormalCenter": section.center}
		if narrow: frame_policy["capSpanCenter"] = center.z
		else: frame_policy["postSpanOffsets"] = footing_plan.offsets
		if section.has("sillSpanBounds"): frame_policy["sillSpanBounds"] = section.sillSpanBounds
		if section.has("pavingFinishPartIds"): frame_policy["pavingFinishPartIds"] = section.pavingFinishPartIds
		var setup: Dictionary
		var local_started := Time.get_ticks_usec()
		if not batch_state.is_empty():
			if prepared_frame.is_empty(): batch_state.localFrameCalls += 1
			_batch_progress(batch_state, "local_frame_begin", ids)
		if not prepared_frame.is_empty():
			setup = prepared_frame
		elif section.has("supportId"):
			setup = Frame.add_frame_on_support(trial, ids, frame_policy, section.supportId, section.upstreamIds, narrow)
		else:
			setup = Frame.add_narrow_pier(trial, ids[0], frame_policy) if narrow else Frame.add_frame(trial, ids, frame_policy)
		if not batch_state.is_empty():
			if prepared_frame.is_empty(): batch_state.localFrameUsec += Time.get_ticks_usec() - local_started
			_batch_progress(batch_state, "local_frame_end", ids, setup.get("reason", ""))
		attempts.append({"memberIds": ids, "result": setup, "footingPlan": footing_plan})
		if not setup.ready:
			var fatal := _batch_fatal_reason({"ready": true, "attempts": [{"result": setup}]})
			if not fatal.is_empty(): return {"ready": false, "reason": fatal, "attempts": attempts}
			continue
		var candidate: Dictionary = trial.snapshot()
		var additions: Array = added_roots + setup.partIds
		if bool(batch_state.get("deferFullValidation", false)):
			var closure_ids: Array = batch_state.localClosureIds.duplicate()
			for check in setup.stagedPhysical.checks:
				if not closure_ids.has(check.partId): closure_ids.append(check.partId)
			if closure_ids.size() > MAX_REDUNDANCY_PARTS: return _fail("redundancy_context_limit_exceeded")
			# Commit only to compose_bottom_bays' private staging blueprint.
			# No resolved IDs or pretend afterPhysical report are produced here.
			for record in candidate.parts:
				if ids.has(record.id):
					by_id[record.id].physical_intent = record.physicalIntent
					by_id[record.id].recipe = record.recipe.duplicate(true)
				elif setup.get("pavingFinishPartIds", []).has(record.id): by_id[record.id].recipe["pavingFootingJoints"] = record.recipe.pavingFootingJoints.duplicate(true)
				elif additions.has(record.id): b.add_part(record)
			batch_state.localClosureIds = closure_ids
			return {"ready": true, "localValidated": true, "globalValidationDeferred": true, "reason": "locally_validated_private_bay", "memberIds": ids, "partIds": additions, "pavingFinishPartIds": setup.get("pavingFinishPartIds", []), "attempts": attempts}
		clear_caches(trial)
		var after_work := validation_grid_work(trial)
		if not after_work.ready:
			after_work["phase"] = "trial"
			after_work["beforePhysical"] = before
			after_work["attempts"] = attempts
			return after_work
		var validation_started := Time.get_ticks_usec()
		var after: Dictionary = trial.validate_physical_integrity()
		if not batch_state.is_empty():
			batch_state.fullValidations += 1
			batch_state.fullValidationUsec += Time.get_ticks_usec() - validation_started
		var failed_after := failed_ids(after)
		if failed_after.any(func(id): return not failed_before.has(id)) or (ids + additions).any(func(id): return failed_after.has(id)):
			return {"ready": false, "reason": "new_or_unresolved_bay_failures", "beforePhysical": before, "afterPhysical": after, "attempts": attempts,
				"remainingFacadeIds": panels.filter(func(part): return failed_after.has(part.id)).map(func(part): return part.id)}
		# Commit only declared panel contracts plus genuinely new geometry. Keep
		# all original objects/order, rooms, roof, openings and unrelated recipes.
		for record in candidate.parts:
			if ids.has(record.id):
				by_id[record.id].physical_intent = record.physicalIntent
				by_id[record.id].recipe = record.recipe.duplicate(true)
			elif setup.get("pavingFinishPartIds", []).has(record.id): by_id[record.id].recipe["pavingFootingJoints"] = record.recipe.pavingFootingJoints.duplicate(true)
			elif additions.has(record.id): b.add_part(record)
		return {"ready": true, "reason": "one_actual_narrow_pier" if narrow else "one_actual_bottom_bay", "mode": "narrow_pier" if narrow else "two_post", "memberIds": ids, "partIds": additions, "groundReferenceId": ground.id,
			"beforePhysical": before, "afterPhysical": after, "attempts": attempts, "pavingFinishPartIds": setup.get("pavingFinishPartIds", []),
			"remainingFacadeIds": panels.filter(func(part): return failed_after.has(part.id)).map(func(part): return part.id),
			"resolvedFacadeIds": panels.filter(func(part): return failed_before.has(part.id) and not failed_after.has(part.id)).map(func(part): return part.id),
			"limitation": "One bottom-row bay only. Remaining facade panels, opening headers, publisher contacts and traversal require separate proof."}
	return {"ready": false, "reason": "no_clear_actual_bottom_bay", "beforePhysical": before, "attempts": attempts,
		"remainingFacadeIds": panels.filter(func(part): return failed_before.has(part.id)).map(func(part): return part.id)}


static func _prepare_cut_bay_candidate(section: Dictionary, b, ids: Array, outward: Vector3, policy: Dictionary, furniture: Array) -> Dictionary:
	var trial = copy_blueprint(b.snapshot())
	var frame_policy := {"outward": outward, "foundationPartIds": [section.supportId],
		"reservedVolumes": policy.get("reservedVolumes", []), "furnitureParts": furniture,
		"clearance": CLEARANCE, "bearingWidth": Frame.POST_WIDTH, "bearingNormalCenter": section.center,
		"postSpanOffsets": section.offsets, "pavingFinishPartIds": section.pavingFinishPartIds}
	if section.has("sillSpanBounds"): frame_policy["sillSpanBounds"] = section.sillSpanBounds
	var result: Dictionary = Frame.add_frame_on_support(trial, ids, frame_policy, section.supportId, section.upstreamIds)
	if not result.ready:
		var fatal := _batch_fatal_reason({"ready": true, "attempts": [{"result": result}]})
		return {"ready": false, "reason": result.get("reason", "invalid_cut_candidate"), "fatal": not fatal.is_empty(), "frameResult": result}
	return {"ready": true, "trial": trial, "frameResult": result}


static func _supported_broad_region(b, bay: Array, outward: Vector3, reserved: Array, filter_obstacles := true, candidate_validator: Callable = Callable()) -> Dictionary:
	if bay.is_empty() or bay.size() > Frame.MAX_MEMBERS or b.parts.size() > Frame.MAX_PARTS or reserved.size() > Frame.MAX_RESERVATIONS: return _fail("broad_source_limit")
	var bounds: AABB = Frame._bounds(bay[0])
	for panel in bay: bounds = bounds.merge(Frame._bounds(panel))
	var span: float = bounds.size.z
	if span < 1.2 or span > 5.0: return _fail("unsupported_bay_span")
	var datum: float = bounds.position.y
	var reach := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z)).grow(Frame.FOOT_WIDTH)
	var obstacles: Array[AABB] = []
	var surfaces: Array = []
	var surface_bounds: Dictionary = {}
	var footing_obstacles: Array[AABB] = []
	var obstacle_finishes: Array[String] = []
	var budget := {"remaining": 131072}
	var work := {"sourceBuilds": 1, "sourceScans": 0, "filterScans": 0, "normalBuilds": 0, "normalReuses": 0, "fullSillChecks": 0, "fullSillReuses": 0, "filterEnabled": filter_obstacles}
	var minimum_support_top := INF
	for part in b.parts:
		budget.remaining -= 1
		work.sourceScans += 1
		if budget.remaining < 0: return _fail("broad_projection_work_limit")
		var volume: AABB = Frame._bounds(part)
		footing_obstacles.append(volume)
		obstacle_finishes.append(part.id if Frame.PavingAssembly._valid_finish(b, part) else "")
		# Same XZ construction clearance as the narrow-region recipe. Bearing
		# faces retain exact vertical contact; reservations also expand in Y.
		obstacles.append(AABB(volume.position - Vector3(CLEARANCE, 0, CLEARANCE), volume.size + Vector3(2 * CLEARANCE, 0, 2 * CLEARANCE)))
		if part.kind not in ["foundation", "floor"] or not part.collision_enabled or part.rotation != Vector3.ZERO: continue
		if not Frame.Materials.is_masonry_material(part.material_id) and not Frame.Materials.is_cobble_material(part.material_id): continue
		if volume.end.y + Frame.FOOT_HEIGHT + 0.8 >= datum - Frame.SILL_HEIGHT: continue
		if not reach.intersects(Rect2(Vector2(volume.position.x, volume.position.z), Vector2(volume.size.x, volume.size.z))): continue
		surfaces.append(part)
		surface_bounds[part.id] = volume
		minimum_support_top = minf(minimum_support_top, volume.end.y)
		if surfaces.size() > MAX_BEARING_SURFACES: return _fail("bearing_surface_collection_limit")
	for volume in reserved:
		budget.remaining -= 1
		work.sourceScans += 1
		if budget.remaining < 0: return _fail("broad_projection_work_limit")
		obstacles.append(volume.grow(CLEARANCE))
		footing_obstacles.append(volume.grow(CLEARANCE))
		obstacle_finishes.append("") # Reservations can never become cut proposals.
	if surfaces.is_empty(): return {"ready": false, "reason": "no_clear_broad_bearing_region", "supportAttempts": [], "projectionWork": 131072 - budget.remaining, "broadWork": work}
	# Every allowed post centre is within the original panel XZ bounds.
	# FOOT_WIDTH conservatively exceeds foot half-width + outward offset;
	# Z covers the full original span, Y all collected support tops to datum.
	# This filters queries, never source records or final collision validation.
	var region := AABB(Vector3(bounds.position.x - Frame.FOOT_WIDTH, minimum_support_top, bounds.position.z - Frame.FOOT_WIDTH), Vector3(bounds.size.x + 2 * Frame.FOOT_WIDTH, datum - minimum_support_top, bounds.size.z + 2 * Frame.FOOT_WIDTH)).grow(2 * CLEARANCE)
	var local_obstacles: Array[AABB] = []
	var local_footing: Array[AABB] = []
	var local_finishes: Array[String] = []
	for index in range(obstacles.size()):
		budget.remaining -= 1
		work.filterScans += 1
		if budget.remaining < 0: return _fail("broad_projection_work_limit")
		if not filter_obstacles or region.intersects(obstacles[index]):
			local_obstacles.append(obstacles[index])
			local_footing.append(footing_obstacles[index])
			local_finishes.append(obstacle_finishes[index])
	work["allObstacleCount"] = obstacles.size()
	work["localObstacleCount"] = local_obstacles.size()
	work["queryBounds"] = region
	obstacles = local_obstacles
	footing_obstacles = local_footing
	surfaces.sort_custom(func(a, c):
		var at: float = surface_bounds[a.id].end.y
		var ct: float = surface_bounds[c.id].end.y
		return at > ct if at != ct else a.id < c.id)
	var context := {"bounds": bounds, "outward": outward, "obstacles": obstacles, "footingObstacles": footing_obstacles, "obstacleFinishes": local_finishes, "candidateValidator": candidate_validator,
		"surfaces": surfaces, "surfaceBounds": surface_bounds, "budget": budget, "work": work, "normals": {}, "fullSills": {}, "insets": {}, "cutCandidateCount": 0, "cutCandidateUsec": 0}
	# Finish the original full-span pass before ANY inset candidate. Both
	# consume the same one-job context; caches are discarded on return.
	var full: Dictionary = _broad_pass(b, bay, context, false)
	work["fullSpanProjectionWork"] = 131072 - budget.remaining
	var result: Dictionary = full
	if not full.ready and full.get("reason") == "no_clear_broad_bearing_region":
		result = _broad_pass(b, bay, context, true)
		result["fullSpanSupportAttempts"] = full.get("supportAttempts", [])
	work["insetProjectionWork"] = 131072 - budget.remaining - work.fullSpanProjectionWork
	result["projectionWork"] = 131072 - budget.remaining
	result["broadWork"] = work.duplicate(true)
	result["cutCandidateCount"] = context.cutCandidateCount
	result["cutCandidateUsec"] = context.cutCandidateUsec
	return result


static func _broad_pass(b, bay: Array, context: Dictionary, inset_only: bool) -> Dictionary:
	var bounds: AABB = context.bounds
	var span: float = bounds.size.z
	var datum: float = bounds.position.y
	var outward: Vector3 = context.outward
	var obstacles: Array[AABB] = context.obstacles
	var budget: Dictionary = context.budget
	var work: Dictionary = context.work
	var attempts: Array = []
	for surface in context.surfaces:
		var seat: AABB = context.surfaceBounds[surface.id]
		var candidate_obstacles: Array[AABB] = []
		var candidate_footing: Array[AABB] = []
		var finish_ids: Array = []
		var foot_region := AABB(Vector3(bounds.position.x - Frame.FOOT_WIDTH, seat.end.y, bounds.position.z - Frame.FOOT_WIDTH),
			Vector3(bounds.size.x + 2 * Frame.FOOT_WIDTH, Frame.FOOT_HEIGHT, bounds.size.z + 2 * Frame.FOOT_WIDTH))
		for index in range(obstacles.size()):
			budget.remaining -= 1
			if budget.remaining < 0: return _fail("broad_projection_work_limit")
			var finish_id: String = context.obstacleFinishes[index]
			if context.candidateValidator.is_valid() and not finish_id.is_empty() and foot_region.intersects(context.footingObstacles[index]):
				finish_ids.append(finish_id)
				if finish_ids.size() > Frame.PavingAssembly.MAX_FINISHES: return _fail("paving_membership_collection_limit")
			else:
				candidate_obstacles.append(obstacles[index])
				candidate_footing.append(context.footingObstacles[index])
		var normal_plan: Dictionary
		if context.normals.has(surface.id):
			normal_plan = context.normals[surface.id]
			work.normalReuses += 1
		else:
			normal_plan = _broad_normal_candidates(bounds, seat, outward, obstacles, budget)
			context.normals[surface.id] = normal_plan
			work.normalBuilds += 1
		if not normal_plan.ready:
			if String(normal_plan.reason).contains("limit"): return normal_plan
			attempts.append({"supportId": surface.id, "reason": normal_plan.reason})
			continue
		var last_reason := "no_clear_broad_bearing_region"
		for normal in normal_plan.centers:
			var center := Vector3(normal, datum - Frame.SILL_HEIGHT * 0.5, bounds.get_center().z)
			var sill_size := Vector3(Frame.POST_WIDTH, Frame.SILL_HEIGHT, span)
			var sill := AABB(center - sill_size * 0.5, sill_size)
			var clear: Dictionary
			# Same represented sill geometry can recur across support surfaces.
			if context.fullSills.has(center.x):
				clear = context.fullSills[center.x]
				work.fullSillReuses += 1
			else:
				clear = _broad_envelopes_clear([sill], obstacles, budget)
				context.fullSills[center.x] = clear
				work.fullSillChecks += 1
			var inset: Dictionary = {}
			if inset_only:
				if clear.ready: continue # This is an end-obstruction repair only.
				if String(clear.reason).contains("limit"): return clear
				if not context.insets.has(center.x): context.insets[center.x] = _inset_sill_interval(bounds, center.x, obstacles, budget)
				inset = context.insets[center.x]
				if not inset.ready:
					if String(inset.reason).contains("work_limit"): return inset
					last_reason = inset.reason
					continue
				sill.position.z = inset.interval.x
				sill.size.z = inset.interval.y - inset.interval.x
				clear = _broad_envelopes_clear([sill], obstacles, budget)
			if not clear.ready:
				if String(clear.reason).contains("limit"): return clear
				continue
			var feet := Frame._plan_footing_offsets_from_bounds(center, 2, span, outward, seat.end.y, candidate_footing, CLEARANCE, seat, budget, inset.get("interval"))
			if not feet.ready:
				if String(feet.reason).contains("limit") and feet.reason != "inset_sill_exceeds_end_support_limit": return feet
				last_reason = feet.reason
				continue
			var envelopes: Array = []
			for placement in Frame.footing_layout(center, 2, span, outward, feet.offsets):
				var foot_center: Vector3 = placement.footCenter
				foot_center.y = seat.end.y + Frame.FOOT_HEIGHT * 0.5
				var foot_size := Vector3(Frame.FOOT_WIDTH, Frame.FOOT_HEIGHT, Frame.FOOT_WIDTH)
				envelopes.append(AABB(foot_center - foot_size * 0.5, foot_size))
				var bottom: float = seat.end.y + Frame.FOOT_HEIGHT
				var top: float = datum - Frame.SILL_HEIGHT
				var post_center: Vector3 = placement.postCenter
				post_center.y = (bottom + top) * 0.5
				var post_size := Vector3(Frame.POST_WIDTH, top - bottom, Frame.POST_WIDTH)
				envelopes.append(AABB(post_center - post_size * 0.5, post_size))
			clear = _broad_envelopes_clear(envelopes, candidate_obstacles, budget)
			if not clear.ready:
				if String(clear.reason).contains("limit"): return clear
				continue
			var closure := _discover_support_closure(b, surface.id, bay.map(func(panel): return panel.id))
			if not closure.ready:
				if String(closure.reason).contains("limit"): return closure
				last_reason = closure.reason
				break # Closure covers the entire same surface, independent of X.
			feet["center"] = normal
			feet["supportId"] = surface.id
			feet["supportTop"] = closure.supportTop
			feet["upstreamIds"] = closure.partIds.filter(func(id): return id != surface.id)
			feet["supportCoverage"] = closure.coverage
			feet["supportAttempts"] = attempts
			feet["projectionWork"] = 131072 - budget.remaining
			feet["mode"] = "same_support_two_post"
			if inset_only:
				feet["sillSpanBounds"] = inset.interval
				feet["mode"] = "same_support_inset_end_two_post"
			if not finish_ids.is_empty():
				if context.cutCandidateCount >= MAX_ATTEMPTS: return _fail("cut_candidate_work_limit")
				context.cutCandidateCount += 1
				feet["pavingFinishPartIds"] = finish_ids.duplicate()
				var started := Time.get_ticks_usec()
				var prepared: Dictionary = context.candidateValidator.call(feet)
				context.cutCandidateUsec += Time.get_ticks_usec() - started
				if not prepared.ready:
					if prepared.get("fatal", true): return prepared
					last_reason = prepared.get("reason", "cut_candidate_rejected")
					continue # A rejected normal cannot conceal later candidates.
				feet["preparedTrial"] = prepared.trial
				feet["preparedFrame"] = prepared.frameResult
			return feet
		attempts.append({"supportId": surface.id, "reason": last_reason})
	return {"ready": false, "reason": "no_clear_broad_bearing_region", "supportAttempts": attempts, "projectionWork": 131072 - budget.remaining}


static func _inset_sill_interval(panel: AABB, normal: float, obstacles: Array[AABB], budget: Dictionary) -> Dictionary:
	# Derive new sill END planes from real obstacles. Never notch a retained
	# panel/frame, bridge an interior blocker, or treat visual parts as absent.
	var sill := AABB(Vector3(normal - Frame.POST_WIDTH * 0.5, panel.position.y - Frame.SILL_HEIGHT, panel.position.z), Vector3(Frame.POST_WIDTH, Frame.SILL_HEIGHT, panel.size.z))
	var interval := Vector2(panel.position.z + CLEARANCE, panel.end.z - CLEARANCE)
	var inset_limit: float = Frame.maximum_post_inset(panel.size.z)
	var left_limit: float = panel.position.z + inset_limit - Frame.POST_WIDTH * 0.5 - CLEARANCE
	var right_limit: float = panel.end.z - inset_limit + Frame.POST_WIDTH * 0.5 + CLEARANCE
	var cuts := 0
	for obstacle in obstacles:
		budget.remaining -= 1
		if budget.remaining < 0: return _fail("inset_projection_work_limit")
		if not Frame._penetrates(sill, obstacle): continue
		# Obstacles already include policy clearance; an additional construction
		# margin keeps represented sill endpoints off equality-sensitive edges.
		var left_end: float = obstacle.end.z + CLEARANCE
		var right_end: float = obstacle.position.z - CLEARANCE
		if left_end <= left_limit:
			interval.x = maxf(interval.x, left_end)
		elif right_end >= right_limit:
			interval.y = minf(interval.y, right_end)
		else:
			return _fail("sill_obstacle_exceeds_end_repair_envelope")
		cuts += 1
	if cuts == 0 or interval.y - interval.x < 1.20: return _fail("no_finite_inset_sill_span")
	return {"ready": true, "interval": interval, "obstacleCuts": cuts}


static func _broad_normal_candidates(panel: AABB, seat: AABB, outward: Vector3, obstacles: Array[AABB], budget: Dictionary) -> Dictionary:
	var foot_offset: float = outward.x * (Frame.FOOT_WIDTH - Frame.POST_WIDTH) * 0.5
	var low: float = maxf(panel.position.x + Frame.POST_WIDTH * 0.5 + CLEARANCE, seat.position.x + Frame.FOOT_WIDTH * 0.5 + CLEARANCE - foot_offset)
	var high: float = minf(panel.end.x - Frame.POST_WIDTH * 0.5 - CLEARANCE, seat.end.x - Frame.FOOT_WIDTH * 0.5 - CLEARANCE - foot_offset)
	if high <= low: return _fail("no_shared_broad_support_region")
	var edges: Array[float] = [low, high]
	for obstacle in obstacles:
		budget.remaining -= 1
		if budget.remaining < 0: return _fail("broad_projection_work_limit")
		if obstacle.end.y <= seat.end.y + Frame.EPS or obstacle.position.y >= panel.position.y - Frame.EPS or obstacle.end.z <= panel.position.z or obstacle.position.z >= panel.end.z: continue
		for section in [Vector2(Frame.POST_WIDTH * 0.5, 0), Vector2(Frame.FOOT_WIDTH * 0.5, foot_offset)]:
			for edge in [obstacle.position.x - section.x - section.y, obstacle.end.x + section.x - section.y]:
				if edge > low and edge < high and not edges.has(edge): edges.append(edge)
				if edges.size() > MAX_BROAD_NORMAL_CANDIDATES: return _fail("broad_normal_candidate_limit")
	edges.sort()
	var centers: Array[float] = [clampf(panel.get_center().x, low, high)]
	for index in range(edges.size() - 1):
		var center: float = (edges[index] + edges[index + 1]) * 0.5
		if not centers.has(center): centers.append(center)
	centers.sort_custom(func(a, c): return absf(a - panel.get_center().x) < absf(c - panel.get_center().x) if absf(a - panel.get_center().x) != absf(c - panel.get_center().x) else a < c)
	return {"ready": true, "centers": centers}


static func _broad_envelopes_clear(envelopes: Array, obstacles: Array[AABB], budget: Dictionary) -> Dictionary:
	for envelope in envelopes:
		for obstacle in obstacles:
			budget.remaining -= 1
			if budget.remaining < 0: return _fail("broad_projection_work_limit")
			if Frame._penetrates(envelope, obstacle): return _fail("broad_source_or_reservation_blocked")
	return {"ready": true}


static func _supported_narrow_region(b, panel, ground, outward: Vector3, reserved: Array) -> Dictionary:
	var surfaces: Array = []
	var panel_bounds: AABB = Frame._bounds(panel)
	var reach := Rect2(Vector2(panel_bounds.position.x, panel_bounds.position.z), Vector2(panel_bounds.size.x, panel_bounds.size.z)).grow(Frame.FOOT_WIDTH)
	for part in b.parts:
		if part.kind not in ["foundation", "floor"] or not part.collision_enabled or part.rotation != Vector3.ZERO: continue
		if not Frame.Materials.is_masonry_material(part.material_id) and not Frame.Materials.is_cobble_material(part.material_id): continue
		var bounds: AABB = Frame._bounds(part)
		if bounds.end.y + Frame.FOOT_HEIGHT + 0.8 >= panel_bounds.position.y - Frame.SILL_HEIGHT: continue
		if not reach.intersects(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))): continue
		surfaces.append(part)
		if surfaces.size() > MAX_BEARING_SURFACES: return _fail("bearing_surface_collection_limit")
	surfaces.sort_custom(func(a, c):
		var at: float = Frame._bounds(a).end.y
		var ct: float = Frame._bounds(c).end.y
		return at > ct if at != ct else a.id < c.id)
	var attempts: Array = []
	for surface in surfaces:
		var region := _narrow_region(b, panel, ground, outward, reserved, surface)
		if not region.ready:
			attempts.append({"supportId": surface.id, "reason": region.reason})
			if region.reason in ["narrow_projection_work_limit", "narrow_region_collection_limit"]: return region
			continue
		var closure := _discover_support_closure(b, surface.id, [panel.id])
		if not closure.ready:
			attempts.append({"supportId": surface.id, "reason": closure.reason})
			if String(closure.reason).contains("limit"): return closure
			continue
		region["supportId"] = surface.id
		region["supportTop"] = closure.supportTop
		region["upstreamIds"] = closure.partIds.filter(func(id): return id != surface.id)
		region["supportCoverage"] = closure.coverage
		region["supportAttempts"] = attempts
		return region
	return {"ready": false, "reason": "no_clear_narrow_bearing_region", "supportAttempts": attempts}


static func _discover_support_closure(b, support_id: String, excluded: Array) -> Dictionary:
	# Bounded actual source context, resolved locally. No global validation,
	# caller cache trust, or generated stand-in foundation.
	var records: Dictionary = {}
	for part in b.parts: records[part.id] = part
	if not records.has(support_id): return _fail("missing_support_closure_part")
	var selected = records[support_id]
	var bounds: AABB = Frame._bounds(selected)
	var footprint := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
	var pool_ids: Array = [support_id]
	for part in b.parts:
		if part.id == support_id or excluded.has(part.id) or part.kind not in ["foundation", "floor"] or not part.collision_enabled or part.position.y >= selected.position.y: continue
		var other: AABB = Frame._bounds(part)
		if footprint.intersects(Rect2(Vector2(other.position.x, other.position.z), Vector2(other.size.x, other.size.z))): pool_ids.append(part.id)
		if pool_ids.size() > MAX_SUPPORT_CONTEXT: return _fail("support_context_limit")
	var cursor := 0
	while cursor < pool_ids.size():
		var part = records[pool_ids[cursor]]
		for key in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
			var dependencies: Variant = part.recipe.get(key, [])
			if not dependencies is Array or dependencies.size() > Frame.MAX_SUPPORT_CLOSURE: return _fail("invalid_support_closure_schema")
			for id in dependencies:
				if not id is String or not records.has(id) or excluded.has(id): return _fail("missing_support_dependency")
				if not pool_ids.has(id): pool_ids.append(id)
				if pool_ids.size() > MAX_SUPPORT_CONTEXT: return _fail("support_context_limit")
		cursor += 1
	pool_ids.sort()
	var pool = Blueprint.new(b.id, b.seed, b.style)
	for id in pool_ids:
		var original = records[id]
		if not Frame.SupportContracts._support_schema_valid(original.recipe, pool_ids): return _fail("invalid_support_closure_schema")
		var source_intent := Frame.support_source_intent(b, original)
		if not source_intent.ready: return source_intent
		var part = pool.add_part(original.snapshot())
		part.physical_intent = source_intent.intent
		Frame._clean_derived(part)
	var guard: Dictionary = Frame.SupportContracts._validation_work(pool)
	if not guard.ready: return guard
	pool.resolve_physical_contracts()
	var pending: Array = [support_id]
	cursor = 0
	while cursor < pending.size():
		var part = pool.find_part(pending[cursor])
		if part == null: return _fail("missing_support_dependency")
		var dependencies: Array = []
		for key in ["physicalSupportPartIds", "physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
			dependencies.append_array(part.recipe.get(key, []))
		if not pool.is_grounded_structural_root(part):
			for sample in pool.footprint_bottom_samples(part, 5):
				var contact: Dictionary = pool.structural_support_at(part, sample.position)
				if not contact.get("id", "").is_empty(): dependencies.append(contact.id)
		for id in dependencies:
			if not pending.has(id): pending.append(id)
			if pending.size() > Frame.MAX_SUPPORT_CLOSURE: return _fail("support_closure_limit")
		cursor += 1
	return Frame.validate_support_closure(b, support_id, pending.filter(func(id): return id != support_id))


static func _narrow_region(b, panel, ground, outward: Vector3, reserved: Array, support = null) -> Dictionary:
	# Variable is post/cap centre XZ. Subtract the configuration-space obstacle
	# of EACH real volume, not the union of the whole panel/access projections.
	# These fixed sections match Frame.add_narrow_pier, without cropped panels.
	var bounds: AABB = Frame._bounds(panel)
	var datum: float = bounds.position.y
	var ground_bounds: AABB = Frame._bounds(ground if support == null else support)
	var post_bottom: float = ground_bounds.end.y + Frame.FOOT_HEIGHT
	var post_top: float = datum - Frame.SILL_HEIGHT
	if post_top - post_bottom <= 0.8: return _fail("insufficient_narrow_post_height")
	var cap_half := Vector2(Frame.POST_WIDTH, Frame.PIER_CAP_SPAN) * 0.5
	var low := Vector2(bounds.position.x, bounds.position.z) + cap_half + Vector2.ONE * CLEARANCE
	var high := Vector2(bounds.end.x, bounds.end.z) - cap_half - Vector2.ONE * CLEARANCE
	# Panel centre must lie over the cap; unsupported ends <= two cap depths.
	low.y = maxf(low.y, maxf(panel.position.z - cap_half.y, bounds.end.z - cap_half.y - Frame.SILL_HEIGHT * 2.0))
	high.y = minf(high.y, minf(panel.position.z + cap_half.y, bounds.position.z + cap_half.y + Frame.SILL_HEIGHT * 2.0))
	if high.x <= low.x or high.y <= low.y: return _fail("no_narrow_bearing_region")
	var foot_offset := Vector2(outward.x, outward.z) * ((Frame.FOOT_WIDTH - Frame.POST_WIDTH) * 0.5)
	if support != null:
		var foot_half := Vector2.ONE * (Frame.FOOT_WIDTH * 0.5 + CLEARANCE)
		low = low.max(Vector2(ground_bounds.position.x, ground_bounds.position.z) + foot_half - foot_offset)
		high = high.min(Vector2(ground_bounds.end.x, ground_bounds.end.z) - foot_half - foot_offset)
		if high.x <= low.x or high.y <= low.y: return _fail("no_narrow_bearing_region")
	var free: Array[Rect2] = [Rect2(low, high - low)]
	var root_width := Frame.FOOT_WIDTH + 2.0 * GROUND_FOOTING_MARGIN
	var envelopes: Array = [
		{"lowY": ground_bounds.position.y, "highY": ground_bounds.end.y, "half": Vector2.ONE * root_width * 0.5, "offset": foot_offset},
		{"lowY": ground_bounds.end.y, "highY": post_bottom, "half": Vector2.ONE * Frame.FOOT_WIDTH * 0.5, "offset": foot_offset},
		{"lowY": post_bottom, "highY": post_top, "half": Vector2.ONE * Frame.POST_WIDTH * 0.5, "offset": Vector2.ZERO},
		{"lowY": post_top, "highY": datum, "half": cap_half, "offset": Vector2.ZERO}]
	# Existing support is retained, not replaced by another overlapping root.
	if support != null: envelopes.remove_at(0)
	var obstacles: Array = reserved.duplicate()
	for part in b.parts: obstacles.append(Frame._bounds(part))
	obstacles.sort_custom(func(a: AABB, c: AABB):
		for axis in range(3):
			if a.position[axis] != c.position[axis]: return a.position[axis] < c.position[axis]
		for axis in range(3):
			if a.size[axis] != c.size[axis]: return a.size[axis] < c.size[axis]
		return false)
	var work := 0
	for envelope in envelopes:
		for obstacle in obstacles:
			work += 1
			if work > 131072: return _fail("narrow_projection_work_limit")
			if minf(envelope.highY, obstacle.end.y) - maxf(envelope.lowY, obstacle.position.y) <= Frame.EPS: continue
			var blocked_low: Vector2 = Vector2(obstacle.position.x, obstacle.position.z) - envelope.half - envelope.offset - Vector2.ONE * CLEARANCE
			var blocked_high: Vector2 = Vector2(obstacle.end.x, obstacle.end.z) + envelope.half - envelope.offset + Vector2.ONE * CLEARANCE
			var next: Array[Rect2] = []
			for region in free:
				work += 1
				if work > 131072: return _fail("narrow_projection_work_limit")
				var cut: Rect2 = region.intersection(Rect2(blocked_low, blocked_high - blocked_low))
				if not cut.has_area(): next.append(region)
				else:
					for remainder in [Rect2(region.position, Vector2(cut.position.x - region.position.x, region.size.y)), Rect2(Vector2(cut.end.x, region.position.y), Vector2(region.end.x - cut.end.x, region.size.y)), Rect2(Vector2(cut.position.x, region.position.y), Vector2(cut.size.x, cut.position.y - region.position.y)), Rect2(Vector2(cut.position.x, cut.end.y), Vector2(cut.size.x, region.end.y - cut.end.y))]:
						if remainder.has_area(): next.append(remainder)
				if next.size() > 256: return _fail("narrow_region_collection_limit")
			free = next
			if free.is_empty(): return _fail("no_clear_narrow_bearing_region")
	# Region centres have positive construction margin at all derived edges.
	# Total ordering removes source/obstacle enumeration as a selection policy.
	var target := Vector2(panel.position.x, panel.position.z)
	free.sort_custom(func(a: Rect2, c: Rect2):
		var da := a.get_center().distance_squared_to(target)
		var dc := c.get_center().distance_squared_to(target)
		if da != dc: return da < dc
		if a.position.x != c.position.x: return a.position.x < c.position.x
		return a.position.y < c.position.y)
	var chosen: Vector2 = free[0].get_center()
	return {"ready": true, "center": chosen.x, "capSpanCenter": chosen.y, "region": free[0], "projectionWork": work, "regionCount": free.size()}


static func _section(b, panel, low_z: float, high_z: float, datum: float, reserved: Array) -> Dictionary:
	# Source-derived free X intervals throughout the bay's sub-facade height.
	# This is conservative: no trim, furniture or wear-semantic exemptions.
	var free: Array[Vector2] = [Vector2(panel.position.x - panel.size.x * 0.5 - Frame.POST_WIDTH * 0.5, panel.position.x + panel.size.x * 0.5 + Frame.POST_WIDTH * 0.5)]
	var obstacles: Array = reserved.duplicate()
	for part in b.parts: obstacles.append(Frame._bounds(part))
	for bounds in obstacles:
		if bounds.position.y >= datum - Frame.EPS or bounds.end.y <= Frame.EPS or bounds.position.z >= high_z or bounds.end.z <= low_z: continue
		var next: Array[Vector2] = []
		for interval in free:
			var low: float = maxf(interval.x, bounds.position.x - CLEARANCE)
			var high: float = minf(interval.y, bounds.end.x + CLEARANCE)
			if high <= low: next.append(interval)
			else:
				if low > interval.x: next.append(Vector2(interval.x, low))
				if high < interval.y: next.append(Vector2(high, interval.y))
		free = next
	var best := INF
	var distance := INF
	for interval in free:
		if interval.y - interval.x < Frame.POST_WIDTH: continue
		var center := clampf(panel.position.x, interval.x + Frame.POST_WIDTH * 0.5, interval.y - Frame.POST_WIDTH * 0.5)
		if absf(center - panel.position.x) < distance:
			best = center
			distance = absf(center - panel.position.x)
	return {"ready": is_finite(best), "center": best, "reason": "" if is_finite(best) else "no_clear_bearing_section"}


static func _root_compatible(b, part) -> bool:
	var intent: Variant = part.recipe.get("physicalIntent", "")
	return part.rotation == Vector3.ZERO and b.is_grounded_structural_root(part) and Frame.Materials.is_masonry_material(part.material_id) and part.physical_intent in ["", "structural_mass", "structural_root"] and intent is String and intent in ["", "structural_mass", "structural_root"] and (part.physical_intent.is_empty() or intent.is_empty() or part.physical_intent == intent) and not part.recipe.keys().any(func(key): return String(key).begins_with("physicalRequired"))


static func _covers_xz(a: AABB, c: AABB) -> bool:
	return a.position.x <= c.position.x and a.end.x >= c.end.x and a.position.z <= c.position.z and a.end.z >= c.end.z


static func copy_blueprint(snapshot: Dictionary):
	var b = Blueprint.new(snapshot.id, snapshot.seed, snapshot.style)
	b.set_recipe(snapshot.recipe)
	b.set_room_records(snapshot.rooms)
	for record in snapshot.parts:
		var part = b.add_part(record)
		# Copy existing represented geometry, not the constructor's minimum-size
		# policy for NEW parts. Recipes can legitimately retain thinner details.
		# Leave malformed/nonpositive-source handling exactly as before.
		var source_size: Variant = record.get("size")
		if source_size is Vector3 and source_size.is_finite() and source_size.x > 0.0 and source_size.y > 0.0 and source_size.z > 0.0:
			part.size = source_size
		part.physical_intent = record.physicalIntent
		b.physical_parts_by_id[part.id] = part
	return b


static func validation_grid_work(b) -> Dictionary:
	if b == null or b.parts.size() > Frame.MAX_PARTS: return _fail("validation_grid_work_limit_exceeded")
	var total := 0.0
	for part in b.parts:
		if not b.has_finite_positive_bounds(part): return _fail("invalid_validation_bounds")
		# Same transformed corners and expansion as the owner's overlap query;
		# this also bounds its smaller, unexpanded grid-insertion rectangle.
		var bounds: AABB = b.transformed_part_bounds(part).grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite():
			return {"ready": false, "reason": "invalid_transformed_validation_bounds", "partId": part.id}
		var low_x := floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var high_x := floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var low_z := floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var high_z := floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		# Check floating endpoints BEFORE integer conversion or cell products.
		for coordinate in [low_x, high_x, low_z, high_z]:
			if not is_finite(coordinate) or absf(coordinate) > MAX_GRID_COORDINATE:
				return {"ready": false, "reason": "validation_grid_work_limit_exceeded", "partId": part.id, "detail": "coordinate_range"}
		var cells_x := high_x - low_x + 1.0
		var cells_z := high_z - low_z + 1.0
		if cells_x < 1.0 or cells_z < 1.0 or cells_x > MAX_GRID_CELLS_PER_PART or cells_z > MAX_GRID_CELLS_PER_PART:
			return {"ready": false, "reason": "validation_grid_work_limit_exceeded", "partId": part.id, "detail": "axis_span"}
		var cells := cells_x * cells_z
		total += cells
		if cells > MAX_GRID_CELLS_PER_PART or total > MAX_GRID_CELLS_TOTAL:
			return {"ready": false, "reason": "validation_grid_work_limit_exceeded", "partId": part.id, "partCells": cells, "totalCells": total}
	return {"ready": true, "expandedCells": total}


static func clear_caches(b) -> void:
	for part in b.parts: Frame._clean_derived(part)


static func failed_ids(report: Dictionary) -> Array:
	return report.checks.filter(func(check): return not check.passed).map(func(check): return check.partId)


static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
