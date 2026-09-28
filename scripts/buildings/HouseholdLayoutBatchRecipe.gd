extends RefCounted

## Deterministic, transactional composition of the existing single-household
## planner. Private source copy only; no publication or caller mutation.
## Run as bounded recipe preparation, not in a visible gameplay frame.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Layout = preload("res://scripts/buildings/RigidHouseholdLayoutRecipe.gd")
const MAX_HOUSEHOLDS := 8
## At most 2*N orders with N calls each: 128 calls for eight households.
## Each Layout call retains its own 5m work cap; this is not one 5m batch.
const MAX_PLANNER_CALLS := 2 * MAX_HOUSEHOLDS * MAX_HOUSEHOLDS

static func plan(source, households: Array, planner: Callable, fixed_reservations: Array[Rect2] = []) -> Dictionary:
	if source == null or households.is_empty() or households.size() > MAX_HOUSEHOLDS or not planner.is_valid():
		return {"ready": false, "reason": "invalid_household_batch"}
	if source.parts.size() > Layout.MAX_PARTS:
		return {"ready": false, "reason": "source_limit_exceeded"}
	if fixed_reservations.size() > Layout.MAX_COLLECTION or not fixed_reservations.all(func(rect): return Layout._valid_rect(rect)):
		return {"ready": false, "reason": "invalid_fixed_reservations"}
	var source_parts: Dictionary = {}
	for part in source.parts:
		if part == null or source_parts.has(part.id) or not Layout._valid_part(part):
			return {"ready": false, "reason": "invalid_or_duplicate_source"}
		source_parts[part.id] = part
	var all_members: Dictionary = {}
	var ordered: Array = []
	for group in households:
		if not group is Dictionary or not group.get("memberIds") is Array or not group.get("front") is Vector3:
			return {"ready": false, "reason": "invalid_household_declaration"}
		var ids: Array = group.memberIds.duplicate()
		if ids.is_empty() or ids.size() > Layout.MAX_COLLECTION:
			return {"ready": false, "reason": "invalid_household_size"}
		for id in ids:
			if not id is String or not source_parts.has(id) or all_members.has(id):
				return {"ready": false, "reason": "missing_duplicate_or_shared_member"}
			all_members[id] = true
		ids.sort()
		ordered.append({"memberIds": ids, "front": group.front, "key": ids[0]})
	ordered.sort_custom(func(a, b): return String(a.key) < String(b.key))
	# Try each cyclic priority order and its reverse, deterministically. This
	# avoids one greedy household consuming the only space for a later one.
	# Exhaustion is bounded-search failure, not proof of geometric impossibility.
	var started := Time.get_ticks_usec()
	var last_failure: Dictionary = {}
	var attempts := 0
	var calls := 0
	for reverse in [false, true]:
		var base: Array = ordered.duplicate()
		if reverse:
			base.reverse()
		for shift in range(base.size()):
			var priority: Array = []
			for index in range(base.size()):
				priority.append(base[(index + shift) % base.size()])
			attempts += 1
			var result := _plan_order(source, priority, all_members, source_parts, planner, fixed_reservations)
			calls += int(result.get("plannerCalls", 0))
			result["plannerCalls"] = calls
			result["maximumPlannerCalls"] = MAX_PLANNER_CALLS
			result["orderAttempts"] = attempts
			result["elapsedUsec"] = Time.get_ticks_usec() - started
			if result.get("ready", false):
				return result
			# Only a completed no-fit search permits trying a different order.
			# Malformed input, incomplete/resource-limited work, and unknown
			# failures must never disappear behind a later geometric no-fit.
			if not result.get("retryableOrder", false):
				return result
			last_failure = result
	return {"ready": false, "reason": "bounded_order_search_exhausted", "lastFailure": last_failure,
		"plannerCalls": calls, "maximumPlannerCalls": MAX_PLANNER_CALLS,
		"orderAttempts": attempts, "elapsedUsec": Time.get_ticks_usec() - started}

static func _plan_order(source, ordered: Array, all_members: Dictionary, source_parts: Dictionary, planner: Callable, fixed_reservations: Array[Rect2] = []) -> Dictionary:
	var scratch = Blueprint.new(source.id, source.seed, source.style)
	scratch.recipe = source.recipe.duplicate(true)
	scratch.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		if not all_members.has(part.id):
			var copy = scratch.add_part(part.snapshot())
			scratch.physical_parts_by_id[copy.id] = copy
	var reservations: Array[Rect2] = []
	reservations.append_array(fixed_reservations)
	var decisions: Array = []
	for group in ordered:
		for id in group.memberIds:
			var copy = scratch.add_part(source_parts[id].snapshot())
			scratch.physical_parts_by_id[id] = copy
		var result: Dictionary = planner.call(scratch, group.memberIds, group.front, reservations)
		if not result.get("ready", false) or not result.get("transform") is Transform3D or not result.get("circulationFootprint") is Rect2 or not result.get("approach") is Rect2:
			# Never expose a partial layout or publish previous successes.
			var reason: String = String(result.get("reason", "unknown_planner_failure")) if not result.get("ready", false) else "invalid_ready_planner_result"
			return {"ready": false, "reason": reason, "failedHousehold": group.key,
				"retryableOrder": reason == "no_recipe_placement", "plannerCalls": decisions.size() + 1,
				"detail": result, "completedBeforeFailure": decisions.size()}
		var transform: Transform3D = result.transform
		for id in group.memberIds:
			var part = scratch.find_part(id)
			var pose: Transform3D = transform * scratch.part_transform(part)
			part.position = pose.origin
			part.rotation = pose.basis.get_euler()
		reservations.append(result.circulationFootprint)
		reservations.append(result.approach)
		decisions.append(result)
	return {"ready": true, "reason": "", "households": decisions,
		"plannerCalls": decisions.size(),
		"ordering": "sorted_first_member_id_cyclic_then_reverse", "partialPublication": false}
