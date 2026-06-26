extends RefCounted
class_name WaitForGraph

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var waiter_to_blockers := {}
var blocker_to_waiters := {}
var reasons_by_waiter := {}
var trace: Array[Dictionary] = []
var metrics := {
	"waiters": 0,
	"edges": 0,
	"cyclesDetected": 0,
	"cyclesResolved": 0,
	"unresolvedReasons": {}
}

func set_wait(waiter_id: String, blockers: Array, reason := "blocked") -> void:
	if waiter_id == "":
		return
	clear_waiter(waiter_id)
	var clean := []
	for blocker in blockers:
		var blocker_id := String(blocker)
		if blocker_id == "" or blocker_id == waiter_id or clean.has(blocker_id):
			continue
		clean.append(blocker_id)
	clean.sort()
	if clean.is_empty():
		return
	waiter_to_blockers[waiter_id] = clean
	reasons_by_waiter[waiter_id] = reason
	for blocker_id in clean:
		var waiters: Array = blocker_to_waiters.get(blocker_id, [])
		if not waiters.has(waiter_id):
			waiters.append(waiter_id)
			waiters.sort()
		blocker_to_waiters[blocker_id] = waiters
	_record("wait", { "waiter": waiter_id, "blockers": clean.duplicate(), "reason": reason })
	_refresh_counts()

func clear_waiter(waiter_id: String) -> void:
	if not waiter_to_blockers.has(waiter_id):
		reasons_by_waiter.erase(waiter_id)
		return
	var blockers: Array = waiter_to_blockers.get(waiter_id, [])
	for blocker_id in blockers:
		var waiters: Array = blocker_to_waiters.get(blocker_id, [])
		waiters.erase(waiter_id)
		if waiters.is_empty():
			blocker_to_waiters.erase(blocker_id)
		else:
			blocker_to_waiters[blocker_id] = waiters
	waiter_to_blockers.erase(waiter_id)
	reasons_by_waiter.erase(waiter_id)
	_refresh_counts()

func clear_actor(actor_id: String) -> void:
	clear_waiter(actor_id)
	for waiter_id in waiter_to_blockers.keys().duplicate():
		var blockers: Array = waiter_to_blockers.get(waiter_id, [])
		if blockers.has(actor_id):
			blockers.erase(actor_id)
			if blockers.is_empty():
				clear_waiter(waiter_id)
			else:
				waiter_to_blockers[waiter_id] = blockers
	for blocker_id in blocker_to_waiters.keys().duplicate():
		if blocker_id == actor_id:
			blocker_to_waiters.erase(blocker_id)
	_refresh_counts()

func blockers_for(waiter_id: String) -> Array:
	return (waiter_to_blockers.get(waiter_id, []) as Array).duplicate()

func waiters_for(blocker_id: String) -> Array:
	return (blocker_to_waiters.get(blocker_id, []) as Array).duplicate()

func detect_cycles() -> Array:
	var cycles := []
	var nodes := waiter_to_blockers.keys()
	nodes.sort()
	for node in nodes:
		_find_cycles_from(String(node), String(node), [], cycles)
	var unique := {}
	var result := []
	for cycle in cycles:
		var normalized := _normalize_cycle(cycle)
		var key := "|".join(normalized)
		if unique.has(key):
			continue
		unique[key] = true
		result.append(normalized)
	if not result.is_empty():
		metrics["cyclesDetected"] = int(metrics.get("cyclesDetected", 0)) + result.size()
		_record("cycles", { "cycles": result.duplicate(true) })
	return result

func mark_cycle_resolved(cycle: Array, reason := "retreat") -> void:
	metrics["cyclesResolved"] = int(metrics.get("cyclesResolved", 0)) + 1
	_record("cycle_resolved", { "cycle": cycle.duplicate(), "reason": reason })

func mark_unresolved(reason: String) -> void:
	var unresolved: Dictionary = metrics.get("unresolvedReasons", {})
	unresolved[reason] = int(unresolved.get(reason, 0)) + 1
	metrics["unresolvedReasons"] = unresolved
	_record("cycle_unresolved", { "reason": reason })

func stats() -> Dictionary:
	_refresh_counts()
	return metrics.duplicate(true)

func to_summary() -> Dictionary:
	return {
		"waiterToBlockers": waiter_to_blockers.duplicate(true),
		"blockerToWaiters": blocker_to_waiters.duplicate(true),
		"metrics": stats(),
		"traceSize": trace.size()
	}

func _find_cycles_from(start: String, current: String, path: Array, cycles: Array) -> void:
	if path.size() > NpcConstantsScript.TRAFFIC_WAIT_GRAPH_NODE_LIMIT:
		mark_unresolved("node_limit")
		return
	path.append(current)
	var blockers: Array = waiter_to_blockers.get(current, [])
	for blocker in blockers:
		var blocker_id := String(blocker)
		if blocker_id == start:
			var cycle := path.duplicate()
			cycle.append(start)
			cycles.append(cycle)
		elif not path.has(blocker_id) and waiter_to_blockers.has(blocker_id):
			_find_cycles_from(start, blocker_id, path.duplicate(), cycles)

func _normalize_cycle(cycle: Array) -> Array:
	var values := []
	for item in cycle:
		var value := String(item)
		if value != "" and not values.has(value):
			values.append(value)
	values.sort()
	return values

func _refresh_counts() -> void:
	var edge_count := 0
	for blockers in waiter_to_blockers.values():
		edge_count += (blockers as Array).size()
	metrics["waiters"] = waiter_to_blockers.size()
	metrics["edges"] = edge_count

func _record(kind: String, metadata := {}) -> void:
	trace.append({
		"kind": kind,
		"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
	})
	while trace.size() > NpcConstantsScript.TRAFFIC_TRACE_CAPACITY:
		trace.remove_at(0)
