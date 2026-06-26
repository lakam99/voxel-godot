extends RefCounted
class_name SafeIntervalPlanner

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

func find_interval(resource_id: String, request: Dictionary, existing: Array, capacity := 1) -> Dictionary:
	var duration := maxf(0.001, float(request.get("duration", NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS)))
	var earliest := float(request.get("earliestStart", 0.0))
	var latest := float(request.get("latestStart", earliest + NpcConstantsScript.TRAFFIC_RESERVATION_HORIZON_SECONDS))
	var clearance := maxf(0.0, float(request.get("clearanceSeconds", NpcConstantsScript.TRAFFIC_INTERVAL_CLEARANCE_SECONDS)))
	var candidate := earliest
	var sorted := existing.duplicate()
	sorted.sort_custom(Callable(self, "_sort_by_start"))
	var delayed_by := []
	while candidate <= latest:
		var blockers := interval_blockers(resource_id, candidate, candidate + duration, sorted, capacity)
		if blockers.is_empty():
			return {
				"ok": true,
				"start": candidate,
				"end": candidate + duration,
				"blockers": delayed_by
			}
		var next_candidate := candidate
		for blocker in blockers:
			if not delayed_by.has(blocker):
				delayed_by.append(blocker)
			next_candidate = maxf(next_candidate, float(blocker.get("interval_end")) + clearance)
		if next_candidate <= candidate + 0.0001:
			next_candidate += clearance + 0.001
		candidate = next_candidate
	return {
		"ok": false,
		"start": latest,
		"end": latest + duration,
		"blockers": interval_blockers(resource_id, earliest, earliest + duration, sorted, capacity),
		"reason": "no_safe_interval"
	}

func interval_blockers(resource_id: String, start_time: float, end_time: float, existing: Array, capacity := 1) -> Array:
	var blockers := []
	for reservation in existing:
		if reservation == null:
			continue
		if not bool(reservation.call("is_active")):
			continue
		if not reservation.call("overlaps", start_time, end_time):
			continue
		if String(reservation.get("resource_id")) == resource_id:
			blockers.append(reservation)
			continue
		var metadata = reservation.get("metadata")
		if metadata is Dictionary and String((metadata as Dictionary).get("oppositeResourceId", "")) == resource_id:
			blockers.append(reservation)
	if blockers.size() < maxi(1, capacity):
		return []
	return blockers

func has_overlap(resource_id: String, start_time: float, end_time: float, existing: Array, capacity := 1) -> bool:
	return not interval_blockers(resource_id, start_time, end_time, existing, capacity).is_empty()

func _sort_by_start(a, b) -> bool:
	var start_a := float(a.get("interval_start")) if a != null else INF
	var start_b := float(b.get("interval_start")) if b != null else INF
	if not is_equal_approx(start_a, start_b):
		return start_a < start_b
	return String(a.get("owner_id")) < String(b.get("owner_id"))
