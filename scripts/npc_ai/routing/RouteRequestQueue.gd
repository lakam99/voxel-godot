extends RefCounted
class_name RouteRequestQueue

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const RouteResultScript := preload("res://scripts/npc_ai/contracts/RouteResult.gd")

var pending_by_id := {}
var sequence := 0
var cancelled_generations := {}
var completed_results := {}
var cancelled_order: Array[String] = []
var completed_order: Array[String] = []

func clear() -> void:
	pending_by_id.clear()
	cancelled_generations.clear()
	completed_results.clear()
	cancelled_order.clear()
	completed_order.clear()
	sequence = 0

func submit(request) -> String:
	if request == null:
		return ""
	sequence += 1
	var request_id := String(request.get("request_id"))
	if request_id == "":
		request_id = "route:%06d" % sequence
		request.set("request_id", request_id)
	pending_by_id[request_id] = {
		"request": request,
		"sequence": sequence,
		"priority": int(request.get("priority_class"))
	}
	_enforce_pending_capacity()
	return request_id

func replace(owner_id: String, request) -> String:
	for request_id in pending_by_id.keys():
		var queued: Dictionary = pending_by_id[request_id]
		var queued_request = queued.get("request")
		if queued_request != null and String(queued_request.get("owner_npc_id")) == owner_id:
			cancel(request_id)
	return submit(request)

func cancel(request_id: String) -> void:
	if pending_by_id.has(request_id):
		var request = (pending_by_id[request_id] as Dictionary).get("request")
		if request != null:
			_remember_cancelled_generation(request_id, int(request.get("cancellation_generation")))
		pending_by_id.erase(request_id)
		var result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_CANCELLED)
		result.request_id = request_id
		_remember_completed(request_id, result)

func process_budget(planner, max_expansions := 128) -> Array:
	var output: Array = []
	var remaining := max_expansions
	while remaining > 0 and not pending_by_id.is_empty():
		var request_id := _next_request_id()
		var queued: Dictionary = pending_by_id.get(request_id, {})
		var request = queued.get("request")
		if request == null:
			pending_by_id.erase(request_id)
			continue
		var before := int(planner.stats().get("lastExpansions", 0)) if planner != null and planner.has_method("stats") else 0
		var result = planner.plan_route(request, remaining)
		var after := int(planner.stats().get("lastExpansions", before)) if planner != null and planner.has_method("stats") else before
		remaining -= maxi(1, after - before)
		if result == null:
			break
		if result.call("is_terminal"):
			pending_by_id.erase(request_id)
			_remember_completed(request_id, result)
		output.append(result)
		if not result.call("is_terminal"):
			break
	return output

func stats() -> Dictionary:
	return {
		"pending": pending_by_id.size(),
		"cancelled": cancelled_generations.size(),
		"completed": completed_results.size(),
		"pendingCapacity": NpcConstantsScript.ROUTE_REQUEST_QUEUE_CAPACITY,
		"completedCapacity": NpcConstantsScript.ROUTE_COMPLETED_RESULT_CAPACITY,
		"sequence": sequence
	}

func _next_request_id() -> String:
	var best_id := ""
	var best_priority := -2147483648
	var best_sequence := 2147483647
	for request_id in pending_by_id.keys():
		var queued: Dictionary = pending_by_id[request_id]
		var priority := int(queued.get("priority", 0))
		var order := int(queued.get("sequence", 0))
		if priority > best_priority or (priority == best_priority and order < best_sequence):
			best_id = String(request_id)
			best_priority = priority
			best_sequence = order
	return best_id

func _enforce_pending_capacity() -> void:
	var capacity := maxi(1, NpcConstantsScript.ROUTE_REQUEST_QUEUE_CAPACITY)
	while pending_by_id.size() > capacity:
		var request_id := _lowest_priority_newest_request_id()
		if request_id == "":
			return
		var request = (pending_by_id.get(request_id, {}) as Dictionary).get("request")
		if request != null:
			_remember_cancelled_generation(request_id, int(request.get("cancellation_generation")))
		pending_by_id.erase(request_id)
		var result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_QUEUE_CAPACITY)
		result.request_id = request_id
		_remember_completed(request_id, result)

func _lowest_priority_newest_request_id() -> String:
	var worst_id := ""
	var worst_priority := 2147483647
	var worst_sequence := -1
	for request_id in pending_by_id.keys():
		var queued: Dictionary = pending_by_id[request_id]
		var priority := int(queued.get("priority", 0))
		var order := int(queued.get("sequence", 0))
		if priority < worst_priority or (priority == worst_priority and order > worst_sequence):
			worst_id = String(request_id)
			worst_priority = priority
			worst_sequence = order
	return worst_id

func _remember_cancelled_generation(request_id: String, generation: int) -> void:
	cancelled_generations[request_id] = generation
	cancelled_order.erase(request_id)
	cancelled_order.append(request_id)
	var capacity := maxi(1, NpcConstantsScript.ROUTE_COMPLETED_RESULT_CAPACITY)
	while cancelled_order.size() > capacity:
		var evicted := String(cancelled_order.pop_front())
		cancelled_generations.erase(evicted)

func _remember_completed(request_id: String, result) -> void:
	completed_results[request_id] = result
	completed_order.erase(request_id)
	completed_order.append(request_id)
	var capacity := maxi(1, NpcConstantsScript.ROUTE_COMPLETED_RESULT_CAPACITY)
	while completed_order.size() > capacity:
		var evicted := String(completed_order.pop_front())
		completed_results.erase(evicted)
