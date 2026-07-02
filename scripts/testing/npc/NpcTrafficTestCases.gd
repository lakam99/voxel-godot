extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const TrafficReservationServiceScript := preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")
const BottleneckClassifierScript := preload("res://scripts/npc_ai/traffic/BottleneckClassifier.gd")
const SafeIntervalPlannerScript := preload("res://scripts/npc_ai/traffic/SafeIntervalPlanner.gd")
const WaitForGraphScript := preload("res://scripts/npc_ai/traffic/WaitForGraph.gd")
const TrafficPriorityPolicyScript := preload("res://scripts/npc_ai/traffic/TrafficPriorityPolicy.gd")
const DoorPortalServiceScript := preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const DoorTraversalExecutorScript := preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")

const CELL := 1.35

var runner = null

class FakeMotionSystem:
	extends Node3D
	var motion_calls := 0
	var npc_reservation_waits := 0

	func apply_npc_route_motion(entry: Dictionary, previous: Vector3, candidate: Vector3, _physics_delta: float) -> Dictionary:
		motion_calls += 1
		var body := entry.get("body") as CharacterBody3D
		if body != null:
			body.position = candidate
			body.global_position = candidate
		return {
			"position": candidate,
			"moved": Vector2(candidate.x - previous.x, candidate.z - previous.z).length(),
			"blocked": false,
			"reason": ""
		}

class FakeMain:
	extends Node

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class OpenWorld:
	func point_allowed(_entry: Dictionary, _candidate: Vector3, _allow_outside := false, _moving_home := false) -> bool:
		return true

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

	func terrain_allows_step(_previous_cell: Vector2i, _candidate_cell: Vector2i, _moving_home := false) -> Dictionary:
		return { "ok": true, "height": 0.0 }

	func build_snapshot(_entry: Dictionary, _allow_outside := false, _moving_home := false) -> Dictionary:
		return {}

	func static_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

	func dynamic_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_traffic_two_actor_one_door_swap", "test_two_actor_one_door_swap"],
		["npc_traffic_node_and_edge_conflict", "test_node_and_edge_conflict"],
		["npc_traffic_no_adjacent_edge_swap", "test_no_adjacent_edge_swap"],
		["npc_traffic_bridge_direction_batch", "test_bridge_direction_batch"],
		["npc_traffic_stair_single_capacity", "test_stair_single_capacity"],
		["npc_traffic_interaction_slot_capacity", "test_interaction_slot_capacity"],
		["npc_traffic_four_actor_cycle_resolved", "test_four_actor_cycle_resolved"],
		["npc_traffic_priority_emergency_over_wander", "test_priority_emergency_over_wander"],
		["npc_traffic_priority_night_home_over_idle", "test_priority_night_home_over_idle"],
		["npc_traffic_active_crossing_not_preempted", "test_active_crossing_not_preempted"],
		["npc_traffic_wait_age_prevents_starvation", "test_wait_age_prevents_starvation"],
		["npc_traffic_priority_inheritance_chain", "test_priority_inheritance_chain"],
		["npc_traffic_pullout_retreat_physical", "test_pullout_retreat_physical"],
		["npc_traffic_cancel_releases_reservation", "test_cancel_releases_reservation"],
		["npc_traffic_destroyed_portal_releases_reservation", "test_destroyed_portal_releases_reservation"],
		["npc_traffic_no_permanent_deadlock_soak", "test_no_permanent_deadlock_soak"],
		["npc_traffic_day_work_wave", "test_day_work_wave"],
		["npc_traffic_dusk_return_home_wave", "test_dusk_return_home_wave"],
		["npc_traffic_night_guard_outbound_civilians_inbound", "test_night_guard_outbound_civilians_inbound"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": String(spec[0]),
			"suite": "traffic",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_two_actor_one_door_swap(_mode: String) -> Dictionary:
	var setup := door_setup()
	var a := make_actor("npc-a", Vector3(0.0, 0.0, -CELL * 1.4))
	var b := make_actor("npc-b", Vector3(0.0, 0.0, CELL * 1.4))
	var entry_a := { "id": "npc-a", "routeGoalCell": Vector2i(0, 2), "trafficOwnerGeneration": 1, "routePriority": 0 }
	var entry_b := { "id": "npc-b", "routeGoalCell": Vector2i(0, -2), "trafficOwnerGeneration": 1, "routePriority": 0 }
	var action := { "cell": Vector2i(0, 0), "portalId": setup.portalId }
	var first: Dictionary = setup.executor.request_crossing(setup.door, a, entry_a, action)
	var second: Dictionary = setup.executor.request_crossing(setup.door, b, entry_b, action)
	setup.executor.release_actor("npc-a", false)
	setup.traffic.advance(1.0)
	var third: Dictionary = setup.executor.request_crossing(setup.door, b, entry_b, action)
	setup.executor.release_actor("npc-b", true)
	set_actor_position(a, Vector3(0.0, 0.0, CELL * 2.2))
	set_actor_position(b, Vector3(0.0, 0.0, -CELL * 2.2))
	var closed: Dictionary = setup.portals.process(0.5, [a, b])
	var passed: bool = bool(first.get("ok", false)) and not bool(second.get("ok", true)) and second.has("stagePosition") and bool(third.get("ok", false)) and setup.traffic.active_reservation_count() == 0 and int(closed.get("closed", 0)) == 1
	return outcome(passed, "first=%s second=%s third=%s traffic=%s close=%s" % [JSON.stringify(first), JSON.stringify(second), JSON.stringify(third), JSON.stringify(setup.traffic.stats()), JSON.stringify(closed)], ["first_crosses", "opposite_waits_at_stage", "second_crosses_after_release", "reservations_return_zero", "door_closes_after_final"], { "traffic": setup.traffic.stats(), "second": second, "closed": closed })

func test_node_and_edge_conflict(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var a: Dictionary = traffic.request_movement_step("npc-a", "0,0", "1,0", request({ "ownerGeneration": 1 }))
	var b: Dictionary = traffic.request_movement_step("npc-b", "2,0", "1,0", request({ "ownerGeneration": 1 }))
	var passed: bool = bool(a.get("ok", false)) and not bool(b.get("ok", true)) and (b.get("blockers", []) as Array).has("npc-a")
	return outcome(passed, "a=%s b=%s" % [JSON.stringify(a), JSON.stringify(b)], ["node_conflict_blocks_second", "blocker_reported"], { "a": a, "b": b, "stats": traffic.stats() })

func test_no_adjacent_edge_swap(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var a: Dictionary = traffic.request_movement_step("npc-a", "A", "B", request({ "ownerGeneration": 1 }))
	var b: Dictionary = traffic.request_movement_step("npc-b", "B", "A", request({ "ownerGeneration": 1 }))
	var passed: bool = bool(a.get("ok", false)) and not bool(b.get("ok", true)) and (b.get("blockers", []) as Array).has("npc-a")
	return outcome(passed, "a=%s b=%s" % [JSON.stringify(a), JSON.stringify(b)], ["opposite_edge_blocks", "adjacent_swap_prevented"], { "a": a, "b": b, "stats": traffic.stats() })

func test_bridge_direction_batch(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var a: Dictionary = traffic.request_span("npc-a", "bridge-main", request({ "direction": "east", "metadata": { "kind": "bridge", "capacity": 1 } }))
	var b: Dictionary = traffic.request_span("npc-b", "bridge-main", request({ "direction": "east", "metadata": { "kind": "bridge", "capacity": 1 } }))
	var c: Dictionary = traffic.request_span("npc-c", "bridge-main", request({ "direction": "west", "metadata": { "kind": "bridge", "capacity": 1 } }))
	var passed: bool = bool(a.get("ok", false)) and not bool(b.get("ok", true)) and not bool(c.get("ok", true)) and float(b.get("scheduledStart", 99.0)) <= float(c.get("scheduledStart", 0.0)) and int(traffic.stats().get("directionalBatches", 0)) >= 1
	return outcome(passed, "a=%s b=%s c=%s stats=%s" % [JSON.stringify(a), JSON.stringify(b), JSON.stringify(c), JSON.stringify(traffic.stats())], ["bridge_single_capacity", "same_direction_batches_before_later_opposite"], { "b": b, "c": c, "stats": traffic.stats() })

func test_stair_single_capacity(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var a: Dictionary = traffic.request_span("npc-a", "stair-north", request({ "metadata": { "kind": "stair", "capacity": 1 } }))
	var b: Dictionary = traffic.request_span("npc-b", "stair-north", request({ "metadata": { "kind": "stair", "capacity": 1 } }))
	var passed: bool = bool(a.get("ok", false)) and not bool(b.get("ok", true)) and float(b.get("scheduledStart", 0.0)) > 0.0
	return outcome(passed, "a=%s b=%s" % [JSON.stringify(a), JSON.stringify(b)], ["stair_one_capacity", "stair_second_waits"], { "a": a, "b": b, "stats": traffic.stats() })

func test_interaction_slot_capacity(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var a: Dictionary = traffic.request_interaction_slot("npc-a", "forge", request({ "metadata": { "capacity": 2 } }))
	var b: Dictionary = traffic.request_interaction_slot("npc-b", "forge", request({ "metadata": { "capacity": 2 } }))
	var c: Dictionary = traffic.request_interaction_slot("npc-c", "forge", request({ "metadata": { "capacity": 2 } }))
	var passed: bool = bool(a.get("ok", false)) and bool(b.get("ok", false)) and not bool(c.get("ok", true)) and float(c.get("scheduledStart", 0.0)) > 0.0
	return outcome(passed, "a=%s b=%s c=%s" % [JSON.stringify(a), JSON.stringify(b), JSON.stringify(c)], ["slot_capacity_two", "third_waits"], { "a": a, "b": b, "c": c, "stats": traffic.stats() })

func test_four_actor_cycle_resolved(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	for id in ["npc-a", "npc-b", "npc-c", "npc-d"]:
		traffic.owner_requests[id] = request({ "ownerId": id, "priorityClass": "idle", "waitStartedAt": 0.0 })
	traffic.wait_graph.set_wait("npc-a", ["npc-b"], "cycle")
	traffic.wait_graph.set_wait("npc-b", ["npc-c"], "cycle")
	traffic.wait_graph.set_wait("npc-c", ["npc-d"], "cycle")
	traffic.wait_graph.set_wait("npc-d", ["npc-a"], "cycle")
	var resolved: Array = traffic.resolve_wait_cycles()
	var stats: Dictionary = traffic.stats()
	var passed: bool = resolved.size() == 1 and int(stats.get("cyclesResolved", 0)) == 1 and int(stats.get("cyclesDetected", 0)) >= 1 and not traffic.cycle_resolution_by_owner.is_empty()
	return outcome(passed, "resolved=%s stats=%s" % [JSON.stringify(resolved), JSON.stringify(stats)], ["cycle_detected", "cycle_resolved", "deterministic_yielder_marked"], { "resolved": resolved, "stats": stats, "cycleResolution": traffic.cycle_resolution_by_owner.duplicate(true) })

func test_priority_emergency_over_wander(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	traffic.request_span("active", "clinic-door", request({ "duration": 2.0, "priorityClass": "idle" }))
	var wander: Dictionary = traffic.request_span("wanderer", "clinic-door", request({ "priorityClass": "wander", "waitStartedAt": 0.0 }))
	var emergency: Dictionary = traffic.request_span("medic", "clinic-door", request({ "priorityClass": "emergency", "waitStartedAt": 0.2 }))
	var wander_start: float = first_start(traffic, "wanderer")
	var medic_start: float = first_start(traffic, "medic")
	var passed: bool = not bool(wander.get("ok", true)) and not bool(emergency.get("ok", true)) and medic_start < wander_start and int(traffic.stats().get("starvationPreventions", 0)) >= 1
	return outcome(passed, "wander %.2f medic %.2f stats=%s" % [wander_start, medic_start, JSON.stringify(traffic.stats())], ["emergency_reorders_pending_wander", "lower_pending_shifted"], { "wander": wander, "emergency": emergency, "wanderStart": wander_start, "medicStart": medic_start, "stats": traffic.stats() })

func test_priority_night_home_over_idle(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	traffic.request_span("active", "home-door", request({ "duration": 2.0, "priorityClass": "idle" }))
	var idle: Dictionary = traffic.request_span("idle-npc", "home-door", request({ "priorityClass": "idle", "waitStartedAt": 0.0 }))
	var home: Dictionary = traffic.request_span("returning", "home-door", request({ "priorityClass": "night_home", "waitStartedAt": 0.2 }))
	var passed: bool = first_start(traffic, "returning") < first_start(traffic, "idle-npc") and not bool(idle.get("ok", true)) and not bool(home.get("ok", true))
	return outcome(passed, "idle %.2f home %.2f" % [first_start(traffic, "idle-npc"), first_start(traffic, "returning")], ["night_home_reorders_idle", "stable_pending_shift"], { "idle": idle, "home": home, "stats": traffic.stats() })

func test_active_crossing_not_preempted(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var active: Dictionary = traffic.request_span("active", "gate", request({ "duration": 2.0, "priorityClass": "wander", "activeCrossing": true }))
	var emergency: Dictionary = traffic.request_span("emergency", "gate", request({ "priorityClass": "emergency" }))
	var passed: bool = bool(active.get("ok", false)) and not bool(emergency.get("ok", true)) and float(emergency.get("scheduledStart", 0.0)) >= 2.0
	return outcome(passed, "active=%s emergency=%s" % [JSON.stringify(active), JSON.stringify(emergency)], ["active_crossing_continuity", "active_not_preempted"], { "active": active, "emergency": emergency, "stats": traffic.stats() })

func test_wait_age_prevents_starvation(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	traffic.request_span("active", "well", request({ "duration": 5.0, "priorityClass": "idle" }))
	var old_waiter: Dictionary = traffic.request_span("old-wanderer", "well", request({ "priorityClass": "wander", "waitStartedAt": 0.0 }))
	traffic.advance(4.0)
	var new_idle: Dictionary = traffic.request_span("new-idle", "well", request({ "priorityClass": "idle", "waitStartedAt": 4.0 }))
	var passed: bool = not bool(old_waiter.get("ok", true)) and not bool(new_idle.get("ok", true)) and first_start(traffic, "old-wanderer") <= first_start(traffic, "new-idle") and float(traffic.stats().get("maxWaitSeconds", 0.0)) >= 4.0
	return outcome(passed, "old %.2f new %.2f stats=%s" % [first_start(traffic, "old-wanderer"), first_start(traffic, "new-idle"), JSON.stringify(traffic.stats())], ["wait_age_preserves_old_waiter", "max_wait_counter"], { "old": old_waiter, "new": new_idle, "stats": traffic.stats() })

func test_priority_inheritance_chain(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	traffic.owner_requests["npc-a"] = request({ "ownerId": "npc-a", "priorityClass": "emergency", "waitStartedAt": 0.0 })
	traffic.owner_requests["npc-b"] = request({ "ownerId": "npc-b", "priorityClass": "idle", "waitStartedAt": 0.0 })
	traffic.owner_requests["npc-c"] = request({ "ownerId": "npc-c", "priorityClass": "wander", "waitStartedAt": 0.0 })
	traffic.wait_graph.set_wait("npc-a", ["npc-b"], "blocked")
	traffic.wait_graph.set_wait("npc-b", ["npc-c"], "blocked")
	var inherited_b: int = traffic.priority_policy.inherited_priority_for("npc-b", traffic.wait_graph, traffic.owner_requests, traffic.now)
	var inherited_c: int = traffic.priority_policy.inherited_priority_for("npc-c", traffic.wait_graph, traffic.owner_requests, traffic.now)
	var emergency_priority: int = traffic.priority_policy.effective_priority(traffic.owner_requests["npc-a"], traffic.now)
	var passed: bool = inherited_b >= emergency_priority and inherited_c >= emergency_priority
	return outcome(passed, "inherit b=%d c=%d emergency=%d" % [inherited_b, inherited_c, emergency_priority], ["direct_priority_inheritance", "transitive_priority_inheritance"], { "inheritedB": inherited_b, "inheritedC": inherited_c, "emergency": emergency_priority, "graph": traffic.wait_graph.to_summary() })

func test_pullout_retreat_physical(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3(0.0, 0.0, 0.0))
	var blocker := make_actor("npc-b", Vector3(0.20, 0.0, 0.0))
	var fake_system := FakeMotionSystem.new()
	if runner is Node:
		runner.add_child(fake_system)
	var locomotion = NpcRouteMovementControllerScript.new()
	locomotion.setup(fake_system, FakeMain.new())
	var result: Dictionary = locomotion.try_dynamic_yield_retreat({ "id": "npc-a" }, body.global_position, { "reason": "yielding", "candidate": Vector3(0.5, 0.0, 0.0), "blocker": blocker }, { "physicsDelta": 1.0 / 60.0, "allowOutside": true }, CELL * 0.35, OpenWorld.new(), [body, blocker], 0)
	var text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var passed: bool = String(result.get("reason", "")) == "yielding_retreat" and int(fake_system.get("motion_calls")) == 1 and text.find("global_position =") < 0
	return outcome(passed, "result=%s calls=%d globalWrite=%d" % [JSON.stringify(result), int(fake_system.get("motion_calls")), text.find("global_position =")], ["retreat_uses_motion_adapter", "no_locomotion_transform_write"], { "result": result, "motionCalls": int(fake_system.get("motion_calls")) })

func test_cancel_releases_reservation(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var first: Dictionary = traffic.request_span("npc-a", "woodshop", request({ "duration": 1.0 }))
	var released: int = traffic.cancel_owner("npc-a")
	var passed: bool = bool(first.get("ok", false)) and released > 0 and traffic.active_reservation_count() == 0
	return outcome(passed, "released=%d stats=%s" % [released, JSON.stringify(traffic.stats())], ["cancel_releases", "active_zero"], { "first": first, "released": released, "stats": traffic.stats() })

func test_destroyed_portal_releases_reservation(_mode: String) -> Dictionary:
	var setup := door_setup()
	var actor := make_actor("npc-a", Vector3(0.0, 0.0, -CELL))
	var entry := { "id": "npc-a", "routeGoalCell": Vector2i(0, 2), "trafficOwnerGeneration": 1 }
	var first: Dictionary = setup.executor.request_crossing(setup.door, actor, entry, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
	var released: int = setup.traffic.destroy_portal(setup.portalId)
	var passed: bool = bool(first.get("ok", false)) and released > 0 and setup.traffic.active_reservation_count() == 0
	return outcome(passed, "first=%s released=%d stats=%s" % [JSON.stringify(first), released, JSON.stringify(setup.traffic.stats())], ["portal_destroy_releases", "no_portal_leak"], { "first": first, "released": released, "stats": setup.traffic.stats() })

func test_no_permanent_deadlock_soak(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var completed: int = 0
	var actors := ["npc-a", "npc-b", "npc-c", "npc-d", "npc-e", "npc-f"]
	for round_index in range(8):
		for actor_id in actors:
			var result: Dictionary = traffic.request_span(actor_id, "market-arch", request({ "ownerGeneration": round_index + 1, "priorityClass": "work" if round_index % 2 == 0 else "night_home" }))
			if not bool(result.get("ok", false)):
				traffic.advance(maxf(0.01, float(result.get("scheduledStart", traffic.now)) - traffic.now + 0.02))
				result = traffic.request_span(actor_id, "market-arch", request({ "ownerGeneration": round_index + 1, "priorityClass": "work" }))
			if bool(result.get("ok", false)):
				completed += 1
				traffic.release_owner(actor_id, "terminal_goal")
			traffic.advance(0.03)
	var passed: bool = completed == actors.size() * 8 and traffic.active_reservation_count() == 0 and int(traffic.stats().get("queueLength", 0)) == 0
	return outcome(passed, "completed=%d stats=%s" % [completed, JSON.stringify(traffic.stats())], ["all_actors_terminal", "no_permanent_deadlock", "reservation_zero_after_soak"], { "completed": completed, "stats": traffic.stats() })

func test_day_work_wave(mode: String) -> Dictionary:
	var result := run_wave("day-work", ["work", "work", "forage", "idle"], mode)
	var passed: bool = bool(result.get("allReached", false)) and int(result.get("maxQueue", 0)) >= 1 and int(result.get("activeReservations", -1)) == 0
	return outcome(passed, "mode=%s wave=%s" % [mode, JSON.stringify(result)], ["day_work_wave_terminal", "queue_observed", "reservations_zero"], result)

func test_dusk_return_home_wave(mode: String) -> Dictionary:
	var result := run_wave("dusk-home", ["night_home", "night_home", "idle", "wander"], mode)
	var passed: bool = bool(result.get("allReached", false)) and int(result.get("maxQueue", 0)) >= 1 and int(result.get("activeReservations", -1)) == 0
	return outcome(passed, "mode=%s wave=%s" % [mode, JSON.stringify(result)], ["dusk_home_wave_terminal", "night_home_priority_present", "reservations_zero"], result)

func test_night_guard_outbound_civilians_inbound(mode: String) -> Dictionary:
	var result := run_wave("night-guard", ["guard", "night_home", "night_home", "idle", "guard"], mode)
	var passed: bool = bool(result.get("allReached", false)) and int(result.get("maxQueue", 0)) >= 1 and int(result.get("activeReservations", -1)) == 0
	return outcome(passed, "mode=%s wave=%s" % [mode, JSON.stringify(result)], ["night_guard_civilian_wave_terminal", "mixed_priorities_ordered", "reservations_zero"], result)

func run_wave(resource_id: String, classes: Array, mode: String) -> Dictionary:
	var traffic = traffic_service()
	var reached := 0
	var max_queue := 0
	var initial_results: Dictionary = {}
	for i in range(classes.size()):
		var actor_id := "wave-%02d" % i
		var result: Dictionary = traffic.request_span(actor_id, resource_id, request({ "priorityClass": String(classes[i]), "ownerGeneration": 1, "metadata": { "kind": "corridor", "capacity": 1, "mode": mode } }))
		initial_results[actor_id] = result
		max_queue = maxi(max_queue, int(traffic.stats().get("queueLength", 0)))
	for i in range(classes.size()):
		var actor_id := "wave-%02d" % i
		var result: Dictionary = initial_results.get(actor_id, {})
		if bool(result.get("ok", false)):
			reached += 1
			traffic.release_owner(actor_id, "terminal_goal")
			traffic.advance(0.03)
			continue
		traffic.advance(maxf(0.01, first_start(traffic, actor_id) - traffic.now + 0.02))
		result = traffic.request_span(actor_id, resource_id, request({ "priorityClass": String(classes[i]), "ownerGeneration": 1, "metadata": { "kind": "corridor", "capacity": 1, "mode": mode } }))
		if bool(result.get("ok", false)):
			reached += 1
			traffic.release_owner(actor_id, "terminal_goal")
		traffic.advance(0.03)
	return {
		"allReached": reached == classes.size(),
		"reached": reached,
		"actors": classes.size(),
		"maxQueue": max_queue,
		"activeReservations": traffic.active_reservation_count(),
		"stats": traffic.stats()
	}

func traffic_service():
	var classifier = BottleneckClassifierScript.new()
	var planner = SafeIntervalPlannerScript.new()
	var graph = WaitForGraphScript.new()
	var policy = TrafficPriorityPolicyScript.new()
	var service = TrafficReservationServiceScript.new()
	service.setup(classifier, planner, graph, policy)
	return service

func request(extra := {}) -> Dictionary:
	var result := {
		"ownerGeneration": 1,
		"actionGeneration": 0,
		"priority": 0,
		"priorityClass": "idle",
		"earliestStart": 0.0,
		"duration": NpcConstantsScript.TRAFFIC_DEFAULT_INTERVAL_SECONDS,
		"direction": "forward",
		"waitStartedAt": 0.0,
		"metadata": {}
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result

func first_start(traffic, owner_id: String) -> float:
	var summaries: Array = traffic.owner_group_summaries(owner_id)
	var result := INF
	for summary in summaries:
		result = minf(result, float((summary as Dictionary).get("start", INF)))
	return result

func door_setup(options := {}) -> Dictionary:
	var traffic = traffic_service()
	var portals = DoorPortalServiceScript.new()
	portals.setup(null, null)
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(portals, traffic, traffic.classifier, traffic.priority_policy, traffic.wait_graph)
	var primary_cell := Vector3i(0, 0, 0)
	var group_id := "traffic-door:%d,%d,%d" % [primary_cell.x, primary_cell.y, primary_cell.z]
	var portal_id := "door:%s" % group_id
	var door := make_door(primary_cell, portal_id, group_id, options)
	portals.register_door(door)
	return {
		"traffic": traffic,
		"portals": portals,
		"executor": executor,
		"door": door,
		"portalId": portal_id
	}

func make_door(cell: Vector3i, portal_id: String, group_id: String, options := {}) -> StaticBody3D:
	var door := StaticBody3D.new()
	door.name = "TrafficDoor_%d_%d_%d" % [cell.x, cell.y, cell.z]
	if runner is Node:
		runner.add_child(door)
	door.global_position = Vector3(float(cell.x) * CELL, 0.0, float(cell.z) * CELL)
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("cell", cell)
	door.set_meta("open", bool(options.get("open", false)))
	door.set_meta("closed_rotation", 0.0)
	door.set_meta("secondary", false)
	door.set_meta("door_leaf_index", 0)
	door.set_meta("door_side", int(options.get("side", 0)))
	door.set_meta("door_group_id", group_id)
	door.set_meta("door_portal_id", portal_id)
	door.set_meta("door_building_id", String(options.get("buildingId", "")))
	door.set_meta("door_public_access", true)
	door.set_meta("door_policy", "private_home")
	door.set_meta("locked", false)
	door.set_meta("jammed", false)
	door.set_meta("destroyed", false)
	door.set_meta("unloaded", false)
	door.set_meta("open_swing", -PI * 0.5)
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16)
	collider.shape = shape
	door.add_child(collider)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	door.add_child(pivot)
	return door

func make_actor(id: String, position: Vector3) -> CharacterBody3D:
	var actor := CharacterBody3D.new()
	actor.name = id
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.34
	shape.height = 1.62
	collider.shape = shape
	collider.position.y = 0.81
	actor.add_child(collider)
	if runner is Node:
		runner.add_child(actor)
	set_actor_position(actor, position)
	actor.set_meta("npc_stable_id", id)
	return actor

func set_actor_position(actor: Node3D, position: Vector3) -> void:
	actor.position = position
	actor.global_position = position

func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
