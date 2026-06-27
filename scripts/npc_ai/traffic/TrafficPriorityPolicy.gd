extends RefCounted
class_name TrafficPriorityPolicy

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CLASS_PRIORITY := {
	"emergency": 900,
	"combat": 760,
	"night_home": 640,
	"guard": 560,
	"work": 420,
	"forage": 380,
	"idle": 120,
	"wander": 60
}

func priority_class_for(entry: Dictionary, intent := {}) -> String:
	if bool(intent.get("emergency", false)) or bool(entry.get("emergency", false)):
		return "emergency"
	if bool(intent.get("combat", false)) or String(entry.get("goal", "")) == "fight":
		return "combat"
	if String(entry.get("scheduleState", "")) == "night" and (bool(intent.get("movingHome", false)) or entry.has("homeCell")):
		return "night_home"
	if String(entry.get("guardDuty", "")) != "":
		return "guard"
	var kind := String(intent.get("kind", entry.get("goal", "")))
	if kind in ["work", "job", "wood", "stone"]:
		return "work"
	if kind == "forage" or String(entry.get("job", "")) == "forage":
		return "forage"
	if kind == "wander":
		return "wander"
	return "idle"

func base_priority(priority_class: String, explicit_priority := 0) -> int:
	return int(explicit_priority) + int(CLASS_PRIORITY.get(priority_class, CLASS_PRIORITY.get("idle")))

func effective_priority(data, now: float, inherited_priority := -INF) -> int:
	var priority_class := "idle"
	var explicit_priority := 0
	var wait_started := now
	var active_crossing := false
	if data is Dictionary:
		priority_class = String((data as Dictionary).get("priorityClass", priority_class))
		explicit_priority = int((data as Dictionary).get("priority", explicit_priority))
		wait_started = float((data as Dictionary).get("waitStartedAt", now))
		active_crossing = bool((data as Dictionary).get("activeCrossing", false))
	else:
		priority_class = String(data.get("priority_class"))
		explicit_priority = int(data.get("priority"))
		wait_started = float(data.get("wait_started_at"))
		active_crossing = bool(data.get("active_crossing"))
	var wait_age := maxf(0.0, now - wait_started)
	var aged := int(floor(wait_age / NpcConstantsScript.TRAFFIC_WAIT_AGING_SECONDS)) * NpcConstantsScript.TRAFFIC_WAIT_AGING_BONUS
	var continuity := NpcConstantsScript.TRAFFIC_ACTIVE_CROSSING_BONUS if active_crossing else 0
	return max(base_priority(priority_class, explicit_priority) + aged + continuity, int(inherited_priority))

func compare(a, b, now: float, inherited_a := -INF, inherited_b := -INF) -> int:
	var a_priority := effective_priority(a, now, inherited_a)
	var b_priority := effective_priority(b, now, inherited_b)
	if a_priority != b_priority:
		return 1 if a_priority > b_priority else -1
	var a_wait := _wait_age(a, now)
	var b_wait := _wait_age(b, now)
	if not is_equal_approx(a_wait, b_wait):
		return 1 if a_wait > b_wait else -1
	var a_id := _owner_id(a)
	var b_id := _owner_id(b)
	if a_id == b_id:
		return 0
	return 1 if a_id < b_id else -1

func beats_request(a: Dictionary, b, now: float, inherited_a := -INF, inherited_b := -INF) -> bool:
	return compare(a, b, now, inherited_a, inherited_b) > 0

func pick_cycle_yielder(cycle: Array, owner_requests: Dictionary, now: float) -> String:
	var yielder := ""
	var yielder_priority := INF
	var yielder_wait := INF
	for owner in cycle:
		var owner_id := String(owner)
		var data = owner_requests.get(owner_id, { "ownerId": owner_id, "priorityClass": "idle", "waitStartedAt": now })
		var priority := effective_priority(data, now)
		var wait := _wait_age(data, now)
		if yielder == "" or priority < yielder_priority or (priority == yielder_priority and wait < yielder_wait) or (priority == yielder_priority and is_equal_approx(wait, yielder_wait) and owner_id > yielder):
			yielder = owner_id
			yielder_priority = priority
			yielder_wait = wait
	return yielder

func inherited_priority_for(owner_id: String, wait_graph, owner_requests: Dictionary, now: float) -> int:
	if wait_graph == null:
		return -INF
	return int(_inherited_priority_recursive(owner_id, wait_graph, owner_requests, now, {}))

func _wait_age(data, now: float) -> float:
	if data is Dictionary:
		return maxf(0.0, now - float((data as Dictionary).get("waitStartedAt", now)))
	return maxf(0.0, now - float(data.get("wait_started_at")))

func _owner_id(data) -> String:
	if data is Dictionary:
		return String((data as Dictionary).get("ownerId", ""))
	return String(data.get("owner_id"))

func _inherited_priority_recursive(owner_id: String, wait_graph, owner_requests: Dictionary, now: float, visited: Dictionary) -> int:
	if visited.has(owner_id):
		return -INF
	visited[owner_id] = true
	var inherited := -INF
	for waiter in wait_graph.waiters_for(owner_id):
		var waiter_id := String(waiter)
		var data = owner_requests.get(waiter_id, {})
		if data is Dictionary:
			inherited = max(inherited, effective_priority(data, now))
		inherited = max(inherited, _inherited_priority_recursive(waiter_id, wait_graph, owner_requests, now, visited.duplicate()))
	return int(inherited)
