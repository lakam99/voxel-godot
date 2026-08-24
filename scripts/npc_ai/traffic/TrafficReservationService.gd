extends RefCounted
class_name TrafficReservationService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const TrafficReservationScript := preload("res://scripts/npc_ai/contracts/TrafficReservation.gd")
const BottleneckClassifierScript := preload("res://scripts/npc_ai/traffic/BottleneckClassifier.gd")
const SafeIntervalPlannerScript := preload("res://scripts/npc_ai/traffic/SafeIntervalPlanner.gd")
const WaitForGraphScript := preload("res://scripts/npc_ai/traffic/WaitForGraph.gd")
const TrafficPriorityPolicyScript := preload("res://scripts/npc_ai/traffic/TrafficPriorityPolicy.gd")

var classifier = BottleneckClassifierScript.new()
var planner = SafeIntervalPlannerScript.new()
var wait_graph = WaitForGraphScript.new()
var priority_policy = TrafficPriorityPolicyScript.new()
var now := 0.0
var sequence := 0
var reservations_by_id := {}
var reservations_by_resource := {}
var reservations_by_owner := {}
var reservations_by_group := {}
var owner_generations := {}
var owner_requests := {}
var queues_by_resource := {}
var cycle_resolution_by_owner := {}
var trace: Array[Dictionary] = []
var metrics := {
	"requests": 0,
	"granted": 0,
	"waiting": 0,
	"pending": 0,
	"released": 0,
	"expired": 0,
	"denied": 0,
	"queueLengthMax": 0,
	"maxWaitSeconds": 0.0,
	"starvationPreventions": 0,
	"cyclesDetected": 0,
	"cyclesResolved": 0,
	"priorityInheritance": 0,
	"directionalBatches": 0,
	"activeContinuity": 0,
	"leaksPrevented": 0,
	"unresolvedReasons": {}
}

func setup(p_classifier = null, p_planner = null, p_wait_graph = null, p_priority_policy = null) -> void:
	if p_classifier != null:
		classifier = p_classifier
	if p_planner != null:
		planner = p_planner
	if p_wait_graph != null:
		wait_graph = p_wait_graph
	if p_priority_policy != null:
		priority_policy = p_priority_policy

func advance(delta: float) -> void:
	now += maxf(0.0, delta)
	_expire_old_reservations()
	_update_wait_metrics()
	resolve_wait_cycles()

func request_portal_crossing(portal, actor_id: String, direction: String, request := {}) -> Dictionary:
	if portal == null:
		return { "ok": false, "status": "failed", "reason": "missing_portal" }
	var resources: Array = classifier.portal_resources(portal, direction)
	if resources.is_empty():
		return { "ok": false, "status": "failed", "reason": "unclassified_portal" }
	var portal_id := String(portal.get("portal_id"))
	var current_position: Vector3 = request.get("currentPosition", Vector3.ZERO)
	var data := request.duplicate(true) if request is Dictionary else {}
	data["ownerId"] = actor_id
	var requested_group_id := String(data.get("groupId", ""))
	data["groupId"] = requested_group_id if requested_group_id != "" else "portal:%s:%s:%d:%d" % [portal_id, actor_id, int(data.get("ownerGeneration", 0)), int(data.get("actionGeneration", 0))]
	data["kind"] = "portal"
	data["duration"] = float(data.get("duration", NpcConstantsScript.TRAFFIC_PORTAL_CROSSING_SECONDS))
	data["priorityClass"] = String(data.get("priorityClass", "idle"))
	data["metadata"] = _merged_metadata(data.get("metadata", {}), { "portalId": portal_id, "direction": direction })
	var result := request_resources(actor_id, resources, data)
	result["portalId"] = portal_id
	result["direction"] = direction
	if not bool(result.get("ok", false)):
		result["stagePosition"] = classifier.stage_position_for_portal(portal, actor_id, direction, current_position)
		result["classification"] = "traffic_reservation"
	return result

func request_movement_step(owner_id: String, from_node: String, to_node: String, request := {}) -> Dictionary:
	var data := request.duplicate(true) if request is Dictionary else {}
	data["ownerId"] = owner_id
	data["kind"] = "movement"
	data["duration"] = float(data.get("duration", NpcConstantsScript.TRAFFIC_MOVEMENT_STEP_SECONDS))
	data["groupId"] = "movement:%s:%d:%s>%s" % [owner_id, int(data.get("ownerGeneration", 0)), from_node, to_node]
	_release_owner_groups_by_kind(owner_id, "movement", String(data.get("groupId", "")), "route_step_replaced")
	return request_resources(owner_id, classifier.movement_resources(from_node, to_node, data.get("metadata", {})), data)

func request_span(owner_id: String, resource_id: String, request := {}) -> Dictionary:
	var data := request.duplicate(true) if request is Dictionary else {}
	var classification: Dictionary = classifier.classify_span(resource_id, data.get("metadata", {}))
	data["ownerId"] = owner_id
	data["kind"] = String(classification.get("kind", "span"))
	data["groupId"] = String(data.get("groupId", "span:%s:%s:%d" % [resource_id, owner_id, int(data.get("ownerGeneration", 0))]))
	var resources: Array = [{
		"resourceId": String(classification.get("resourceId", "span:%s" % resource_id)),
		"resourceKind": String(classification.get("kind", "span")),
		"capacity": int(classification.get("capacity", 1)),
		"direction": String(data.get("direction", "unknown")),
		"metadata": data.get("metadata", {})
	}]
	return request_resources(owner_id, resources, data)

func request_interaction_slot(owner_id: String, slot_id: String, request := {}) -> Dictionary:
	var data := request.duplicate(true) if request is Dictionary else {}
	var classification: Dictionary = classifier.classify_interaction_slot(slot_id, data.get("metadata", {}))
	data["ownerId"] = owner_id
	data["kind"] = "interaction_slot"
	data["groupId"] = String(data.get("groupId", "interaction:%s:%s:%d" % [slot_id, owner_id, int(data.get("ownerGeneration", 0))]))
	var resources: Array = [{
		"resourceId": String(classification.get("resourceId", "span:interaction:%s" % slot_id)),
		"resourceKind": "interaction_slot",
		"capacity": int(classification.get("capacity", 1)),
		"direction": String(data.get("direction", "slot")),
		"metadata": data.get("metadata", {})
	}]
	return request_resources(owner_id, resources, data)

func request_resources(owner_id: String, resources: Array, request := {}) -> Dictionary:
	metrics["requests"] = int(metrics.get("requests", 0)) + 1
	if owner_id == "" or resources.is_empty():
		metrics["denied"] = int(metrics.get("denied", 0)) + 1
		return { "ok": false, "status": "failed", "reason": "missing_request" }
	var data := request.duplicate(true) if request is Dictionary else {}
	data["ownerId"] = owner_id
	data["waitStartedAt"] = float(data.get("waitStartedAt", _wait_started_for_owner(owner_id)))
	var owner_generation := int(data.get("ownerGeneration", 0))
	_adopt_generation(owner_id, owner_generation)
	var group_id := String(data.get("groupId", _next_group_id(owner_id)))
	data["groupId"] = group_id
	owner_requests[owner_id] = data.duplicate(true)
	var existing_result := _existing_group_result(owner_id, group_id, data)
	if not existing_result.is_empty():
		return existing_result
	_displace_lower_pending(resources, data)
	var interval := _plan_group_interval(resources, data)
	var blockers: Array = interval.get("blockers", [])
	if not bool(interval.get("ok", false)):
		wait_graph.set_wait(owner_id, _blocker_owner_ids(blockers), String(interval.get("reason", "no_safe_interval")))
		_queue_owner(resources, owner_id, data, blockers)
		metrics["denied"] = int(metrics.get("denied", 0)) + 1
		return _waiting_result(group_id, data, blockers, String(interval.get("reason", "no_safe_interval")), interval)
	var start := float(interval.get("start", now))
	var end := float(interval.get("end", start + float(data.get("duration", NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS))))
	var status := TrafficReservationScript.STATUS_GRANTED if start <= now + NpcConstantsScript.TRAFFIC_GRANT_EPSILON_SECONDS else TrafficReservationScript.STATUS_PENDING
	var reservations := _create_group_reservations(group_id, owner_id, resources, data, start, end, status)
	if status == TrafficReservationScript.STATUS_GRANTED:
		metrics["granted"] = int(metrics.get("granted", 0)) + 1
		wait_graph.clear_actor(owner_id)
		_dequeue_owner(owner_id)
		return {
			"ok": true,
			"status": "granted",
			"reason": "",
			"groupId": group_id,
			"reservationIds": _reservation_ids(reservations),
			"interval": { "start": start, "end": end },
			"queueLength": 0
		}
	metrics["pending"] = int(metrics.get("pending", 0)) + 1
	metrics["waiting"] = int(metrics.get("waiting", 0)) + 1
	wait_graph.set_wait(owner_id, _blocker_owner_ids(blockers), "waiting_for_interval")
	_queue_owner(resources, owner_id, data, blockers)
	return _waiting_result(group_id, data, blockers, "traffic_wait", interval)

func release_owner(owner_id: String, reason := "released") -> int:
	var ids: Array = (reservations_by_owner.get(owner_id, []) as Array).duplicate()
	var count := 0
	for reservation_id in ids:
		if _release_reservation(String(reservation_id), reason):
			count += 1
	wait_graph.clear_actor(owner_id)
	owner_requests.erase(owner_id)
	_dequeue_owner(owner_id)
	cycle_resolution_by_owner.erase(owner_id)
	metrics["released"] = int(metrics.get("released", 0)) + count
	return count

func release_owner_except_group(owner_id: String, preserved_group_id: String, reason := "released") -> int:
	var ids: Array = (reservations_by_owner.get(owner_id, []) as Array).duplicate()
	var count := 0
	for reservation_id in ids:
		var reservation = reservations_by_id.get(reservation_id)
		if reservation != null and String(reservation.get("group_id")) == preserved_group_id:
			continue
		if _release_reservation(String(reservation_id), reason):
			count += 1
	wait_graph.clear_actor(owner_id)
	owner_requests.erase(owner_id)
	_dequeue_owner(owner_id)
	cycle_resolution_by_owner.erase(owner_id)
	metrics["released"] = int(metrics.get("released", 0)) + count
	return count

func cancel_owner(owner_id: String) -> int:
	return release_owner(owner_id, "cancelled")

func release_owner_generation(owner_id: String, generation: int, reason := "generation_replaced") -> int:
	var ids: Array = (reservations_by_owner.get(owner_id, []) as Array).duplicate()
	var count := 0
	for reservation_id in ids:
		var reservation = reservations_by_id.get(reservation_id)
		if reservation != null and int(reservation.get("owner_generation")) == generation:
			if bool(reservation.get("active_crossing")) and String(reservation.get("status")) == TrafficReservationScript.STATUS_GRANTED:
				continue
			if _release_reservation(String(reservation_id), reason):
				count += 1
	if count > 0:
		metrics["released"] = int(metrics.get("released", 0)) + count
	return count

func release_group(group_id: String, reason := "released") -> int:
	var ids: Array = (reservations_by_group.get(group_id, []) as Array).duplicate()
	var count := 0
	for reservation_id in ids:
		if _release_reservation(String(reservation_id), reason):
			count += 1
	if count > 0:
		metrics["released"] = int(metrics.get("released", 0)) + count
	return count

func release_resource_prefix(prefix: String, reason := "resource_removed") -> int:
	var count := 0
	for reservation_id in reservations_by_id.keys().duplicate():
		var reservation = reservations_by_id.get(reservation_id)
		if reservation != null and String(reservation.get("resource_id")).begins_with(prefix):
			if _release_reservation(String(reservation_id), reason):
				count += 1
	if count > 0:
		metrics["released"] = int(metrics.get("released", 0)) + count
		metrics["leaksPrevented"] = int(metrics.get("leaksPrevented", 0)) + 1
	return count

func destroy_portal(portal_id: String) -> int:
	return release_resource_prefix("portal:%s" % portal_id, "portal_destroyed")

func actor_removed(owner_id: String) -> int:
	return release_owner(owner_id, "actor_removed")

func actor_demoted(owner_id: String) -> int:
	return release_owner(owner_id, "actor_demoted")

func actor_died(owner_id: String) -> int:
	return release_owner(owner_id, "actor_died")

func route_replaced(owner_id: String) -> int:
	return release_owner(owner_id, "route_replaced")

func resolve_wait_cycles() -> Array:
	var before_detected := int(wait_graph.stats().get("cyclesDetected", 0))
	var cycles: Array = wait_graph.detect_cycles()
	var after_detected := int(wait_graph.stats().get("cyclesDetected", 0))
	metrics["cyclesDetected"] = int(metrics.get("cyclesDetected", 0)) + maxi(0, after_detected - before_detected)
	var resolved: Array = []
	for cycle in cycles:
		var yielder: String = priority_policy.pick_cycle_yielder(cycle, owner_requests, now)
		if yielder == "":
			wait_graph.mark_unresolved("no_yielder")
			_note_unresolved("no_yielder")
			continue
		cycle_resolution_by_owner[yielder] = {
			"kind": "retreat",
			"reason": "wait_cycle",
			"cycle": cycle.duplicate()
		}
		_release_owner_groups_by_kind(yielder, "", "", "cycle_retreat")
		wait_graph.clear_actor(yielder)
		wait_graph.mark_cycle_resolved(cycle, "retreat")
		metrics["cyclesResolved"] = int(metrics.get("cyclesResolved", 0)) + 1
		metrics["directionalBatches"] = int(metrics.get("directionalBatches", 0)) + 1
		resolved.append({ "ownerId": yielder, "cycle": cycle.duplicate() })
	return resolved

func active_reservation_count() -> int:
	var count := 0
	for reservation in reservations_by_id.values():
		if reservation != null and bool(reservation.call("is_active")):
			count += 1
	return count

func queue_length(resource_id := "") -> int:
	if resource_id != "":
		return (queues_by_resource.get(resource_id, {}) as Dictionary).size()
	var owners := {}
	for queue in queues_by_resource.values():
		for owner_id in (queue as Dictionary).keys():
			owners[String(owner_id)] = true
	return owners.size()

func queued_owners_for_resource_prefix(prefix: String) -> Array:
	var owners := []
	for resource_id in queues_by_resource.keys():
		if not String(resource_id).begins_with(prefix):
			continue
		var queue: Dictionary = queues_by_resource.get(resource_id, {})
		for owner_id in queue.keys():
			var id := String(owner_id)
			if id != "" and not owners.has(id):
				owners.append(id)
	owners.sort()
	return owners

func queued_owners_for_portal(portal_id: String) -> Array:
	if portal_id == "":
		return []
	var base := "portal:%s" % portal_id
	var owners := []
	var resource_ids := [
		"%s:threshold" % base,
		"%s:edge:x+" % base,
		"%s:edge:x-" % base,
		"%s:edge:z+" % base,
		"%s:edge:z-" % base
	]
	for resource_id in resource_ids:
		var queue: Dictionary = queues_by_resource.get(resource_id, {})
		for owner_id in queue.keys():
			var id := String(owner_id)
			if id != "" and not owners.has(id):
				owners.append(id)
	owners.sort()
	return owners

func owner_group_summaries(owner_id: String) -> Array:
	var summaries := []
	for reservation_id in (reservations_by_owner.get(owner_id, []) as Array):
		var reservation = reservations_by_id.get(reservation_id)
		if reservation != null:
			summaries.append(reservation.call("to_summary"))
	return summaries

func stats() -> Dictionary:
	var result := metrics.duplicate(true)
	result["activeReservations"] = active_reservation_count()
	result["reservationCount"] = reservations_by_id.size()
	result["ownerCount"] = reservations_by_owner.size()
	result["queueLength"] = queue_length()
	result["waitGraph"] = wait_graph.stats()
	result["now"] = now
	return result

func to_summary() -> Dictionary:
	var reservations := []
	for reservation in reservations_by_id.values():
		if reservation != null:
			reservations.append(reservation.call("to_summary"))
	return {
		"stats": stats(),
		"reservations": reservations,
		"queues": queues_by_resource.duplicate(true),
		"cycleResolutions": cycle_resolution_by_owner.duplicate(true),
		"traceSize": trace.size()
	}

func certify_active_group(group_id: String, owner_id: String, expected_reservation_ids: Array) -> Dictionary:
	if group_id.is_empty() or owner_id.is_empty() or expected_reservation_ids.is_empty():
		return {"ok": false, "reason": "missing_group_identity"}
	var indexed_ids: Array = (reservations_by_group.get(group_id, []) as Array).duplicate()
	var expected_ids: Array = expected_reservation_ids.duplicate()
	indexed_ids.sort()
	expected_ids.sort()
	if indexed_ids != expected_ids:
		return {"ok": false, "reason": "reservation_set_changed", "activeReservationIds": indexed_ids, "expectedReservationIds": expected_ids}
	for reservation_id_value in expected_ids:
		var reservation_id := String(reservation_id_value)
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null or not bool(reservation.call("is_active")):
			return {"ok": false, "reason": "reservation_inactive", "reservationId": reservation_id}
		if String(reservation.get("group_id")) != group_id or String(reservation.get("owner_id")) != owner_id:
			return {"ok": false, "reason": "reservation_owner_changed", "reservationId": reservation_id}
		if String(reservation.get("status")) != TrafficReservationScript.STATUS_GRANTED or not bool(reservation.get("active_crossing")):
			return {"ok": false, "reason": "reservation_not_granted_crossing", "reservationId": reservation_id}
	return {"ok": true, "reason": "", "groupId": group_id, "ownerId": owner_id, "reservationIds": expected_ids}

func _existing_group_result(owner_id: String, group_id: String, request: Dictionary) -> Dictionary:
	var ids: Array = reservations_by_group.get(group_id, [])
	if ids.is_empty():
		return {}
	var reservations := []
	var all_granted := true
	var earliest := INF
	var latest_end := 0.0
	for reservation_id in ids:
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null or not bool(reservation.call("is_active")):
			continue
		reservations.append(reservation)
		earliest = minf(earliest, float(reservation.get("interval_start")))
		latest_end = maxf(latest_end, float(reservation.get("interval_end")))
		if String(reservation.get("status")) != TrafficReservationScript.STATUS_GRANTED:
			all_granted = false
	if reservations.is_empty():
		return {}
	if all_granted or now >= earliest - NpcConstantsScript.TRAFFIC_GRANT_EPSILON_SECONDS:
		for reservation in reservations:
			reservation.call("mark_granted", now)
			reservation.set("interval_end", maxf(float(reservation.get("interval_end")), now + float(request.get("duration", NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS))))
			reservation.set("active_crossing", bool(request.get("activeCrossing", reservation.get("active_crossing"))))
		wait_graph.clear_actor(owner_id)
		_dequeue_owner(owner_id)
		metrics["granted"] = int(metrics.get("granted", 0)) + 1
		metrics["activeContinuity"] = int(metrics.get("activeContinuity", 0)) + 1
		return {
			"ok": true,
			"status": "granted",
			"reason": "",
			"groupId": group_id,
			"reservationIds": _reservation_ids(reservations),
			"interval": { "start": earliest, "end": latest_end },
			"activeContinuity": true
		}
	release_group(group_id, "pending_replan")
	return {}

func _plan_group_interval(resources: Array, request: Dictionary) -> Dictionary:
	var duration := maxf(0.001, float(request.get("duration", NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS)))
	var start := float(request.get("earliestStart", now))
	var latest := float(request.get("latestStart", now + NpcConstantsScript.TRAFFIC_RESERVATION_HORIZON_SECONDS))
	var blockers := []
	var delayed_blockers := []
	var guard := 0
	while guard < 16 and start <= latest:
		guard += 1
		var changed := false
		blockers.clear()
		for spec_value in resources:
			var spec: Dictionary = spec_value
			var existing: Array = _relevant_reservations_for_spec(spec, request)
			var capacity := maxi(1, int(spec.get("capacity", 1)))
			var active_crossing_blockers: Array = existing.filter(func(reservation) -> bool:
				return reservation != null \
					and String(reservation.get("status")) == TrafficReservationScript.STATUS_GRANTED \
					and bool(reservation.get("active_crossing"))
			)
			if active_crossing_blockers.size() >= capacity:
				return {"ok": false, "reason": "active_crossing_occupied", "start": start, "end": start + duration, "blockers": active_crossing_blockers}
			var interval: Dictionary = planner.find_interval(String(spec.get("resourceId", "")), _merged_metadata(request, { "earliestStart": start, "latestStart": latest, "duration": duration }), existing, capacity)
			if not bool(interval.get("ok", false)):
				return interval
			for blocker in (interval.get("blockers", []) as Array):
				if not delayed_blockers.has(blocker):
					delayed_blockers.append(blocker)
			var candidate_start := float(interval.get("start", start))
			if candidate_start > start + NpcConstantsScript.TRAFFIC_GRANT_EPSILON_SECONDS:
				start = candidate_start
				changed = true
				break
			blockers.append_array(planner.interval_blockers(String(spec.get("resourceId", "")), start, start + duration, existing, capacity))
		if not changed:
			if blockers.is_empty():
				return { "ok": true, "start": start, "end": start + duration, "blockers": delayed_blockers }
			var next_start := start
			for blocker in blockers:
				if not delayed_blockers.has(blocker):
					delayed_blockers.append(blocker)
				next_start = maxf(next_start, float(blocker.get("interval_end")) + NpcConstantsScript.TRAFFIC_INTERVAL_CLEARANCE_SECONDS)
			if next_start <= start + 0.0001:
				next_start += NpcConstantsScript.TRAFFIC_INTERVAL_CLEARANCE_SECONDS + 0.001
			start = next_start
	if start > latest:
		return { "ok": false, "reason": "no_safe_interval", "start": start, "end": start + duration, "blockers": delayed_blockers if not delayed_blockers.is_empty() else blockers }
	return { "ok": false, "reason": "planner_guard", "start": start, "end": start + duration, "blockers": delayed_blockers if not delayed_blockers.is_empty() else blockers }

func _create_group_reservations(group_id: String, owner_id: String, resources: Array, request: Dictionary, start: float, end: float, status: String) -> Array:
	var result := []
	for spec_value in resources:
		var spec: Dictionary = spec_value
		sequence += 1
		var metadata := _merged_metadata(spec.get("metadata", {}), request.get("metadata", {}))
		var reservation = TrafficReservationScript.make({
			"reservationId": "traffic:%d" % sequence,
			"groupId": group_id,
			"ownerId": owner_id,
			"ownerGeneration": int(request.get("ownerGeneration", 0)),
			"actionGeneration": int(request.get("actionGeneration", 0)),
			"resourceId": String(spec.get("resourceId", "")),
			"resourceKind": String(spec.get("resourceKind", request.get("kind", "traffic"))),
			"intervalStart": start,
			"intervalEnd": end,
			"capacity": int(spec.get("capacity", 1)),
			"direction": String(spec.get("direction", request.get("direction", "unknown"))),
			"fromNode": String(spec.get("fromNode", "")),
			"toNode": String(spec.get("toNode", "")),
			"priority": int(request.get("priority", 0)),
			"priorityClass": String(request.get("priorityClass", "idle")),
			"status": status,
			"activeCrossing": bool(request.get("activeCrossing", false)) or String(request.get("kind", "")) == "portal",
			"waitStartedAt": float(request.get("waitStartedAt", now)),
			"metadata": metadata
		})
		_add_reservation(reservation)
		result.append(reservation)
	_record("reserve", { "group": group_id, "owner": owner_id, "status": status, "start": start, "end": end, "resources": resources.size() })
	return result

func _add_reservation(reservation) -> void:
	reservations_by_id[reservation.get("reservation_id")] = reservation
	var resource_id := String(reservation.get("resource_id"))
	var resource_ids: Array = reservations_by_resource.get(resource_id, [])
	resource_ids.append(String(reservation.get("reservation_id")))
	reservations_by_resource[resource_id] = resource_ids
	var owner_ids: Array = reservations_by_owner.get(String(reservation.get("owner_id")), [])
	owner_ids.append(String(reservation.get("reservation_id")))
	reservations_by_owner[String(reservation.get("owner_id"))] = owner_ids
	var group_ids: Array = reservations_by_group.get(String(reservation.get("group_id")), [])
	group_ids.append(String(reservation.get("reservation_id")))
	reservations_by_group[String(reservation.get("group_id"))] = group_ids

func _release_reservation(reservation_id: String, reason := "released") -> bool:
	var reservation = reservations_by_id.get(reservation_id)
	if reservation == null:
		return false
	reservation.call("mark_released")
	reservations_by_id.erase(reservation_id)
	_erase_index_value(reservations_by_resource, String(reservation.get("resource_id")), reservation_id)
	_erase_index_value(reservations_by_owner, String(reservation.get("owner_id")), reservation_id)
	_erase_index_value(reservations_by_group, String(reservation.get("group_id")), reservation_id)
	_record("release", { "reservationId": reservation_id, "owner": String(reservation.get("owner_id")), "reason": reason })
	return true

func _erase_index_value(index: Dictionary, key: String, value: String) -> void:
	if not index.has(key):
		return
	var values: Array = index.get(key, [])
	values.erase(value)
	if values.is_empty():
		index.erase(key)
	else:
		index[key] = values

func _relevant_reservations_for_spec(spec: Dictionary, request: Dictionary) -> Array:
	var resource_id := String(spec.get("resourceId", ""))
	var result := []
	for reservation in reservations_by_id.values():
		if reservation == null or not bool(reservation.call("is_active")):
			continue
		if String(reservation.get("owner_id")) == String(request.get("ownerId", "")):
			continue
		if _spec_conflicts_with_reservation(spec, reservation):
			result.append(reservation)
	return result

func _conflicts_for_spec(spec: Dictionary, start: float, end: float, request: Dictionary) -> Array:
	var result := []
	for reservation in _relevant_reservations_for_spec(spec, request):
		if bool(reservation.call("overlaps", start, end)):
			result.append(reservation)
	return result

func _spec_conflicts_with_reservation(spec: Dictionary, reservation) -> bool:
	var resource_id := String(spec.get("resourceId", ""))
	if resource_id == String(reservation.get("resource_id")):
		return true
	var metadata: Dictionary = spec.get("metadata", {}) if spec.get("metadata", {}) is Dictionary else {}
	var reservation_metadata = reservation.get("metadata")
	if String(metadata.get("oppositeResourceId", "")) == String(reservation.get("resource_id")):
		return true
	if reservation_metadata is Dictionary and String((reservation_metadata as Dictionary).get("oppositeResourceId", "")) == resource_id:
		return true
	var from_node := String(spec.get("fromNode", ""))
	var to_node := String(spec.get("toNode", ""))
	return from_node != "" and to_node != "" and from_node == String(reservation.get("to_node")) and to_node == String(reservation.get("from_node"))

func _displace_lower_pending(resources: Array, request: Dictionary) -> void:
	var start := float(request.get("earliestStart", now))
	var duration := float(request.get("duration", NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS))
	var end := start + duration
	var shifted_groups := {}
	for spec_value in resources:
		var spec: Dictionary = spec_value
		for blocker in _relevant_reservations_for_spec(spec, request):
			if String(blocker.get("status")) != TrafficReservationScript.STATUS_PENDING:
				continue
			if bool(blocker.get("active_crossing")):
				continue
			var inherited: int = priority_policy.inherited_priority_for(String(blocker.get("owner_id")), wait_graph, owner_requests, now)
			if priority_policy.beats_request(request, blocker, now, -INF, inherited):
				var group_id := String(blocker.get("group_id"))
				if shifted_groups.has(group_id):
					continue
				_shift_group_after(group_id, float(blocker.get("interval_start")) + duration + NpcConstantsScript.TRAFFIC_INTERVAL_CLEARANCE_SECONDS)
				shifted_groups[group_id] = true
				metrics["starvationPreventions"] = int(metrics.get("starvationPreventions", 0)) + 1

func _shift_group_after(group_id: String, start_time: float) -> void:
	var ids: Array = reservations_by_group.get(group_id, [])
	if ids.is_empty():
		return
	var old_start := INF
	var old_end := 0.0
	for reservation_id in ids:
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null:
			continue
		old_start = minf(old_start, float(reservation.get("interval_start")))
		old_end = maxf(old_end, float(reservation.get("interval_end")))
	var duration := maxf(0.001, old_end - old_start)
	for reservation_id in ids:
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null:
			continue
		reservation.set("interval_start", start_time)
		reservation.set("interval_end", start_time + duration)
		reservation.set("status", TrafficReservationScript.STATUS_PENDING)
	_record("shift_group", { "group": group_id, "start": start_time })

func _blocking_before(start_time: float, existing_group: Array) -> Array:
	var blockers := []
	for reservation in reservations_by_id.values():
		if reservation == null or not bool(reservation.call("is_active")):
			continue
		if existing_group.has(reservation):
			continue
		for own in existing_group:
			if _spec_conflicts_with_reservation({
				"resourceId": String(own.get("resource_id")),
				"metadata": own.get("metadata"),
				"fromNode": String(own.get("from_node")),
				"toNode": String(own.get("to_node"))
			}, reservation) and float(reservation.get("interval_end")) <= start_time:
				blockers.append(reservation)
	return blockers

func _queue_owner(resources: Array, owner_id: String, request: Dictionary, blockers: Array) -> void:
	for spec_value in resources:
		var spec: Dictionary = spec_value
		var resource_id := String(spec.get("resourceId", ""))
		if resource_id == "":
			continue
		var queue: Dictionary = queues_by_resource.get(resource_id, {})
		queue[owner_id] = {
			"ownerId": owner_id,
			"groupId": String(request.get("groupId", "")),
			"priorityClass": String(request.get("priorityClass", "idle")),
			"priority": int(request.get("priority", 0)),
			"waitStartedAt": float(request.get("waitStartedAt", now)),
			"blockers": _blocker_owner_ids(blockers)
		}
		queues_by_resource[resource_id] = queue
		metrics["queueLengthMax"] = maxi(int(metrics.get("queueLengthMax", 0)), queue.size())
		for blocker in blockers:
			if blocker != null and String(blocker.get("direction")) != "" and String(blocker.get("direction")) == String(request.get("direction", spec.get("direction", ""))):
				metrics["directionalBatches"] = int(metrics.get("directionalBatches", 0)) + 1
				break

func _dequeue_owner(owner_id: String) -> void:
	for resource_id in queues_by_resource.keys().duplicate():
		var queue: Dictionary = queues_by_resource.get(resource_id, {})
		queue.erase(owner_id)
		if queue.is_empty():
			queues_by_resource.erase(resource_id)
		else:
			queues_by_resource[resource_id] = queue

func _waiting_result(group_id: String, request: Dictionary, blockers: Array, reason: String, interval: Dictionary) -> Dictionary:
	var owner_id := String(request.get("ownerId", ""))
	var wait_age := now - float(request.get("waitStartedAt", now))
	metrics["maxWaitSeconds"] = maxf(float(metrics.get("maxWaitSeconds", 0.0)), wait_age)
	var result := {
		"ok": false,
		"status": "waiting",
		"reason": reason,
		"groupId": group_id,
		"scheduledStart": float(interval.get("start", now)),
		"scheduledEnd": float(interval.get("end", now)),
		"blockers": _blocker_owner_ids(blockers),
		"queueLength": queue_length(),
		"waitAge": wait_age
	}
	if cycle_resolution_by_owner.has(owner_id):
		result["cycleResolution"] = cycle_resolution_by_owner.get(owner_id)
		result["reason"] = "wait_cycle_retreat"
	return result

func _blocker_owner_ids(blockers: Array) -> Array:
	var result := []
	for blocker in blockers:
		if blocker == null:
			continue
		var owner_id := String(blocker.get("owner_id"))
		if owner_id != "" and not result.has(owner_id):
			result.append(owner_id)
	result.sort()
	return result

func _reservation_ids(reservations: Array) -> Array:
	var result := []
	for reservation in reservations:
		result.append(String(reservation.get("reservation_id")))
	return result

func _adopt_generation(owner_id: String, generation: int) -> void:
	if owner_id == "":
		return
	if owner_generations.has(owner_id) and int(owner_generations.get(owner_id)) != generation:
		release_owner_generation(owner_id, int(owner_generations.get(owner_id)), "owner_generation_replaced")
		metrics["leaksPrevented"] = int(metrics.get("leaksPrevented", 0)) + 1
	owner_generations[owner_id] = generation
	while owner_generations.size() > NpcConstantsScript.TRAFFIC_OWNER_GENERATION_CAPACITY:
		var keys := owner_generations.keys()
		keys.sort()
		owner_generations.erase(keys[0])

func _wait_started_for_owner(owner_id: String) -> float:
	var existing: Dictionary = owner_requests.get(owner_id, {})
	if existing.has("waitStartedAt"):
		return float(existing.get("waitStartedAt", now))
	return now

func _release_owner_groups_by_kind(owner_id: String, kind: String, except_group := "", reason := "released") -> int:
	var groups := {}
	for reservation_id in (reservations_by_owner.get(owner_id, []) as Array):
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null:
			continue
		var group_id := String(reservation.get("group_id"))
		var metadata = reservation.get("metadata")
		var reservation_kind := String(reservation.get("resource_kind"))
		if metadata is Dictionary and String((metadata as Dictionary).get("kind", "")) != "":
			reservation_kind = String((metadata as Dictionary).get("kind"))
		if group_id == except_group:
			continue
		if kind == "" or reservation_kind == kind or group_id.begins_with("%s:" % kind):
			groups[group_id] = true
	var count := 0
	for group_id in groups.keys():
		count += release_group(String(group_id), reason)
	return count

func _expire_old_reservations() -> void:
	for reservation_id in reservations_by_id.keys().duplicate():
		var reservation = reservations_by_id.get(reservation_id)
		if reservation == null:
			reservations_by_id.erase(reservation_id)
			continue
		if String(reservation.get("status")) == TrafficReservationScript.STATUS_GRANTED and bool(reservation.get("active_crossing")):
			continue
		if float(reservation.get("interval_end")) + NpcConstantsScript.TRAFFIC_RESERVATION_EXPIRE_GRACE_SECONDS < now:
			if _release_reservation(String(reservation_id), "expired"):
				metrics["expired"] = int(metrics.get("expired", 0)) + 1

func _update_wait_metrics() -> void:
	for request in owner_requests.values():
		if request is Dictionary:
			metrics["maxWaitSeconds"] = maxf(float(metrics.get("maxWaitSeconds", 0.0)), now - float((request as Dictionary).get("waitStartedAt", now)))

func _note_unresolved(reason: String) -> void:
	var unresolved: Dictionary = metrics.get("unresolvedReasons", {})
	unresolved[reason] = int(unresolved.get(reason, 0)) + 1
	metrics["unresolvedReasons"] = unresolved

func _merged_metadata(a, b) -> Dictionary:
	var result := {}
	if a is Dictionary:
		for key in (a as Dictionary).keys():
			result[key] = (a as Dictionary)[key]
	if b is Dictionary:
		for key in (b as Dictionary).keys():
			result[key] = (b as Dictionary)[key]
	return result

func _next_group_id(owner_id: String) -> String:
	sequence += 1
	return "traffic-group:%s:%d" % [owner_id, sequence]

func _record(kind: String, metadata := {}) -> void:
	trace.append({
		"t": now,
		"kind": kind,
		"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
	})
	while trace.size() > NpcConstantsScript.TRAFFIC_TRACE_CAPACITY:
		trace.remove_at(0)
