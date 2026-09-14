extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcTestAssertionsScript := preload("res://scripts/testing/npc/NpcTestAssertions.gd")
const NpcTelemetryServiceScript := preload("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
const RouteCasesScript := preload("res://scripts/testing/npc/NpcRouteTestCases.gd")
const RepairCasesScript := preload("res://scripts/testing/npc/NpcRepairTestCases.gd")
const TrafficReservationServiceScript := preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")
const BottleneckClassifierScript := preload("res://scripts/npc_ai/traffic/BottleneckClassifier.gd")
const SafeIntervalPlannerScript := preload("res://scripts/npc_ai/traffic/SafeIntervalPlanner.gd")
const WaitForGraphScript := preload("res://scripts/npc_ai/traffic/WaitForGraph.gd")
const TrafficPriorityPolicyScript := preload("res://scripts/npc_ai/traffic/TrafficPriorityPolicy.gd")
const DoorPortalServiceScript := preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const DoorTraversalExecutorScript := preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")
const NpcSimulationLodServiceScript := preload("res://scripts/npc_ai/lifecycle/NpcSimulationLodService.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const NpcSafePlacementServiceScript := preload("res://scripts/npc_ai/NpcSafePlacementService.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")

const CELL := NpcConstantsScript.CELL_SIZE
const REPAIR_ROUTE_ID := "repair:test"

var runner = null
var transient_nodes: Array[Node] = []
var route_helper = null
var repair_helper = null

class FakeMain:
	extends Node
	var player: Node3D

	func _init() -> void:
		player = Node3D.new()
		player.name = "Player"
		add_child(player)

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class FakeNpcSystem:
	extends Node
	var main
	var placement_service

	func _init() -> void:
		main = FakeMain.new()
		add_child(main)
		placement_service = NpcSafePlacementServiceScript.new()
		placement_service.setup(self, main)

	func safe_place_npc(body: Node3D, position: Vector3, profile = null, reason := "spawn") -> Dictionary:
		return placement_service.place_spawn(body as CharacterBody3D, position, profile, reason)

	func cleanup_npc_route_state(_actor_id: String, entry := {}, reason := "cleanup") -> Dictionary:
		var entry_dict: Dictionary = entry if entry is Dictionary else {}
		var released := 0
		for key in ["pathWaypoints", "routeCells", "routeActions", "activeTrafficStepGroup", "activeDoorPortalId", "activeDoorTrafficGroupId", "jobReservationId", "jobApproachSlotId"]:
			if entry_dict.has(key):
				entry_dict.erase(key)
				released += 1
		return { "actorId": _actor_id, "reason": reason, "routeState": released, "avoidance": 0 }

	func npc_avoidance_registration_count() -> int:
		return 0

class FakeAutonomy:
	var requested_tiles := []

	func request_navigation_tile(snapshot: Dictionary, priority := 0, _profile = null) -> Dictionary:
		var tile_key := String(snapshot.get("tileKey", ""))
		requested_tiles.append({ "tileKey": tile_key, "priority": priority })
		return { "status": "PENDING", "reason": "requested", "tileKey": tile_key }

	func release_npc_traffic_reservations(_entry_or_id, _reason := "released") -> int:
		return 0

	func release_npc_door_hold(_actor_or_id, _schedule_close := true) -> void:
		pass

class OpenWorld:
	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

func setup(owner) -> void:
	runner = owner
	route_helper = RouteCasesScript.new()
	route_helper.setup(owner)
	repair_helper = RepairCasesScript.new()
	repair_helper.setup(owner)

func cases() -> Array[Dictionary]:
	var specs := [
		["npc_soak_32_agents_day_10_seeds", "test_soak_32_agents_day_10_seeds", ["day"]],
		["npc_soak_32_agents_night_10_seeds", "test_soak_32_agents_night_10_seeds", ["night"]],
		["npc_soak_32_agents_dusk_transition_10_seeds", "test_soak_32_agents_dusk_transition_10_seeds", ["transition"]],
		["npc_soak_64_agents_stress", "test_soak_64_agents_stress", ["day", "night"]],
		["npc_soak_dynamic_blocks_day_night", "test_soak_dynamic_blocks_day_night", ["day", "night"]],
		["npc_soak_door_traffic_day_night", "test_soak_door_traffic_day_night", ["day", "night"]],
		["npc_soak_streaming_promote_demote", "test_soak_streaming_promote_demote", ["day", "night"]],
		["npc_soak_save_load_cycles", "test_soak_save_load_cycles", ["day", "night"]],
		["npc_soak_spawn_remove_ownership_cleanup", "test_soak_spawn_remove_ownership_cleanup", ["day", "night"]],
		["npc_fuzz_route_repair_matches_oracle", "test_fuzz_route_repair_matches_oracle", ["day", "night"]],
		["npc_fuzz_no_penetration_random_obstacles", "test_fuzz_no_penetration_random_obstacles", ["day", "night"]],
		["npc_fuzz_terminal_outcomes_random_goals", "test_fuzz_terminal_outcomes_random_goals", ["day", "night"]],
		["npc_fuzz_door_state_machine_safety", "test_fuzz_door_state_machine_safety", ["day", "night"]],
		["npc_fuzz_traffic_no_conflicting_intervals", "test_fuzz_traffic_no_conflicting_intervals", ["day", "night"]],
		["npc_fuzz_schedule_compliance", "test_fuzz_schedule_compliance", ["day", "night", "transition"]]
	]
	var result: Array[Dictionary] = []
	for spec in specs:
		result.append({
			"id": String(spec[0]),
			"suite": "soak",
			"timeModes": spec[2],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_soak_32_agents_day_10_seeds(_mode: String) -> Dictionary:
	return agent_soak_case("day", NpcConstantsScript.NPC_SOAK_AGENT_COUNT, NpcConstantsScript.NPC_SOAK_SEED_COUNT, false)

func test_soak_32_agents_night_10_seeds(_mode: String) -> Dictionary:
	return agent_soak_case("night", NpcConstantsScript.NPC_SOAK_AGENT_COUNT, NpcConstantsScript.NPC_SOAK_SEED_COUNT, false)

func test_soak_32_agents_dusk_transition_10_seeds(_mode: String) -> Dictionary:
	return agent_soak_case("dusk_transition", NpcConstantsScript.NPC_SOAK_AGENT_COUNT, NpcConstantsScript.NPC_SOAK_SEED_COUNT, true)

func test_soak_64_agents_stress(mode: String) -> Dictionary:
	return agent_soak_case("stress_%s" % mode, NpcConstantsScript.NPC_SOAK_STRESS_AGENT_COUNT, 3, true)

func test_soak_dynamic_blocks_day_night(mode: String) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(NpcConstantsScript.NPC_SOAK_SEED_COUNT):
		var started := Time.get_ticks_usec()
		var setup: Dictionary = repair_helper.call("repair_setup", { "goalKind": "work" if mode == "day" else "home" })
		var response: Dictionary = repair_helper.call("block_mid", setup, true)
		var oracle: Dictionary = setup.repair.fresh_oracle(REPAIR_ROUTE_ID)
		var cost: float = float(repair_helper.call("route_cost", response))
		var oracle_cost: float = float(oracle.get("cost", -1.0))
		var ok: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and absf(cost - oracle_cost) <= 0.001 and bool(response.get("metrics", {}).get("safeStopRequired", false))
		if not ok:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "status": String(response.get("status")), "cost": cost, "oracleCost": oracle_cost, "durationUsec": Time.get_ticks_usec() - started })
	var passed: bool = failures.is_empty()
	record_case_metrics("npc_soak_dynamic_blocks_day_night", rows)
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["dynamic_block_repaired", "repair_matches_oracle", "safe_stop_metric"], { "failures": failures, "performance": rows })

func test_soak_door_traffic_day_night(mode: String) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(NpcConstantsScript.NPC_SOAK_SEED_COUNT):
		var traffic = traffic_service()
		var max_queue := 0
		var initial_results := {}
		for actor_index in range(18):
			var owner_id := "door-%02d-%02d" % [seed_index, actor_index]
			var resource := "town-door-%02d" % (actor_index % 3)
			var result: Dictionary = traffic.request_span(owner_id, resource, traffic_request({
				"duration": 0.28,
				"priorityClass": "night_home" if mode == "night" else "work",
				"ownerGeneration": seed_index + 1,
				"metadata": { "kind": "door", "capacity": 1 }
			}))
			initial_results[owner_id] = { "result": result, "resource": resource }
			max_queue = maxi(max_queue, int(traffic.stats().get("queueLength", 0)))
		for actor_index in range(18):
			var drain_owner_id := "door-%02d-%02d" % [seed_index, actor_index]
			var record: Dictionary = initial_results.get(drain_owner_id, {})
			var drain_resource := String(record.get("resource", "town-door-00"))
			var result: Dictionary = record.get("result", {})
			var attempts := 0
			if not bool(result.get("ok", false)):
				while not bool(result.get("ok", false)) and attempts < 4:
					attempts += 1
					traffic.advance(retry_delay(traffic, drain_owner_id, result))
					result = traffic.request_span(drain_owner_id, drain_resource, traffic_request({
						"duration": 0.28,
						"priorityClass": "night_home" if mode == "night" else "work",
						"ownerGeneration": seed_index + 1,
						"metadata": { "kind": "door", "capacity": 1 }
					}))
			if bool(result.get("ok", false)):
				traffic.release_owner(drain_owner_id, "soak_terminal")
			traffic.advance(0.02)
		var stats: Dictionary = traffic.stats()
		var ok: bool = int(stats.get("activeReservations", -1)) == 0 and int(stats.get("queueLength", -1)) == 0 and max_queue > 0
		if not ok:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "maxQueue": max_queue, "stats": stats })
	var passed: bool = failures.is_empty()
	record_case_metrics("npc_soak_door_traffic_day_night", rows)
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["door_queue_observed", "reservations_zero", "queue_settled"], { "failures": failures, "performance": rows })

func test_soak_streaming_promote_demote(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var rows := []
	var failures := []
	for i in range(12):
		var entry := make_lod_entry("lod-%02d" % i, Vector3(float(i), 0.0, 0.0))
		var demote: Dictionary = setup.service.update_actor(entry, 0.2, Vector3(180.0 + float(i), 0.0, 0.0), { "transitEdge": open_edge() })
		var promote: Dictionary = setup.service.update_actor(entry, 0.2, Vector3.ZERO, { "promotionPosition": Vector3(float(i), 0.0, 1.0), "topologyLoaded": true })
		var ok: bool = String(demote.get("state", "")) == "abstract" and String(promote.get("state", "")) == "active" and not bool(entry.get("abstractSimulated", true))
		if not ok:
			failures.append(entry.get("id"))
		rows.append({ "id": entry.get("id"), "demote": demote, "promote": promote })
	var stats: Dictionary = setup.service.stats()
	var passed: bool = failures.is_empty() and int(stats.get("active", 0)) >= 0
	record_case_metrics("npc_soak_streaming_promote_demote", rows)
	return outcome(passed, "failures=%s stats=%s" % [JSON.stringify(failures), JSON.stringify(stats)], ["demote_safe", "promote_safe", "lod_stats_present"], { "failures": failures, "stats": stats, "rows": rows })

func test_soak_save_load_cycles(mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_lod_entry("save-cycle", Vector3(3.0, 0.0, 5.0))
	entry["personalInventory"] = { "berries": 4, "logs": 2 }
	entry["hunger"] = 63.0
	setup.service.start_abstract_transit(entry, open_edge())
	var snapshots := []
	var transient_found: bool = false
	for i in range(8):
		var fact: Dictionary = setup.service.durable_snapshot(entry)
		transient_found = transient_found or setup.service.snapshot_has_transient_state(fact)
		var restored := make_lod_entry("save-cycle", Vector3.ZERO)
		setup.service.apply_durable_snapshot(restored, fact, { "timeOfDay": 0.75 if mode == "night" else 0.25 })
		entry = restored
		snapshots.append(JSON.stringify(fact))
	var deterministic: bool = true
	for i in range(1, snapshots.size()):
		deterministic = deterministic and snapshots[i] == snapshots[0]
	var passed: bool = deterministic and not transient_found
	return outcome(passed, "deterministic=%s transient=%s" % [str(deterministic), str(transient_found)], ["durable_round_trip_repeatable", "no_transient_saved", "load_migration_stable"], { "snapshot": snapshots[0] if not snapshots.is_empty() else "", "cycles": snapshots.size() })

func test_soak_spawn_remove_ownership_cleanup(_mode: String) -> Dictionary:
	var fake := FakeNpcSystem.new()
	transient_nodes.append(fake)
	var autonomy := NpcAutonomySystemScript.new()
	if runner is Node:
		runner.add_child(autonomy)
	autonomy.setup(fake, fake.main)
	var leaks := []
	for i in range(10):
		var entry := make_lod_entry("cleanup-%02d" % i, Vector3.ZERO)
		var body := entry.get("body") as CharacterBody3D
		var object_id := autonomy.register_smart_anchor("cleanup:bench:%02d" % i, "workstation", Vector3.ZERO, { "capacity": 1 })
		autonomy.reserve_smart_object(object_id, null, body, String(entry.get("id")), "use_workstation")
		autonomy.request_npc_traffic_step(entry, Vector3.ZERO, Vector3(CELL, 0.0, 0.0), OpenWorld.new(), { "physicsDelta": 0.2 })
		var cleanup: Dictionary = autonomy.cleanup_actor_ownership(entry, "phase12_soak")
		var stats: Dictionary = autonomy.stats()
		var smart_stats: Dictionary = stats.get("smartObjects", {})
		var traffic_stats: Dictionary = stats.get("traffic", {})
		if int(smart_stats.get("reservations", 0)) != 0 or int(traffic_stats.get("activeReservations", 0)) != 0:
			leaks.append({ "id": entry.get("id"), "cleanup": cleanup, "stats": stats })
	if runner is Node:
		autonomy.queue_free()
	var passed: bool = leaks.is_empty()
	return outcome(passed, "leaks=%s" % JSON.stringify(leaks), ["smart_leaks_zero", "traffic_leaks_zero", "cleanup_releases_all_paths"], { "leaks": leaks })

func test_fuzz_route_repair_matches_oracle(_mode: String) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(24):
		var setup: Dictionary = repair_helper.call("repair_setup", { "goalKind": "guard" if seed_index % 3 == 0 else "move" })
		var response: Dictionary = repair_helper.call("block_mid", setup, true)
		var oracle: Dictionary = setup.repair.fresh_oracle(REPAIR_ROUTE_ID)
		var repair_cost: float = float(repair_helper.call("route_cost", response))
		var oracle_cost: float = float(oracle.get("cost", -1.0))
		var ok: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and absf(repair_cost - oracle_cost) <= 0.001
		if not ok:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "repairCost": repair_cost, "oracleCost": oracle_cost, "status": String(response.get("status")) })
	var passed: bool = failures.is_empty()
	record_case_metrics("npc_fuzz_route_repair_matches_oracle", rows)
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["repair_oracle_cost_equal", "recorded_replay_seeds"], { "failures": failures, "replay": rows })

func test_fuzz_no_penetration_random_obstacles(_mode: String) -> Dictionary:
	var failures := []
	var rows := []
	for seed_index in range(20):
		var obstacles: Array = generated_obstacle_field("penetration:%d" % seed_index, 18, 16, 9)
		var lane := find_safe_lane(obstacles, 9)
		var path := [Vector2(-7.0, float(lane)), Vector2(0.0, float(lane)), Vector2(7.0, float(lane))]
		var clear: bool = path_clear_of_obstacles(path, obstacles, 0.42)
		if not clear:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "lane": lane, "obstacles": obstacles.size(), "clear": clear })
	var passed: bool = failures.is_empty()
	record_case_metrics("npc_fuzz_no_penetration_random_obstacles", rows)
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["capsule_sweep_clear", "random_obstacle_replay_recorded"], { "failures": failures, "replay": rows })

func test_fuzz_terminal_outcomes_random_goals(_mode: String) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(18):
		var reachable: bool = seed_index % 2 == 0
		var surfaces := []
		for x in range(4):
			if reachable or x < 2:
				surfaces.append(route_helper.nav_surface(Vector3i(x, 0, 0), { "semanticRegionIds": ["road"] }))
		var service = route_helper.route_service_from_surfaces({ "0,0": surfaces })
		var goal_key: String = route_helper.route_span_key(Vector3i(3, 0, 0))
		var result = route_helper.route_plan(service, route_helper.route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": goal_key })
		var expected_status: StringName = NpcEnumsScript.ROUTE_STATUS_COMPLETE if reachable else NpcEnumsScript.ROUTE_STATUS_UNREACHABLE
		var ok: bool = result.get("status") == expected_status and result.call("is_terminal")
		if not ok:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "reachable": reachable, "status": String(result.get("status")), "reason": String(result.get("reason")) })
	var passed: bool = failures.is_empty()
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["reachable_complete", "unreachable_terminal", "no_unbounded_trying"], { "failures": failures, "replay": rows })

func test_fuzz_door_state_machine_safety(_mode: String) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(10):
		var setup := door_setup(seed_index)
		var actor_a_id := "door-a-%02d" % seed_index
		var actor_b_id := "door-b-%02d" % seed_index
		var actor_a := make_actor(actor_a_id, Vector3(0.0, 0.0, -CELL * 1.4))
		var actor_b := make_actor(actor_b_id, Vector3(0.0, 0.0, CELL * 1.4))
		var entry_a := { "id": actor_a_id, "routeGoalCell": Vector2i(0, 2), "trafficOwnerGeneration": seed_index + 1, "routePriority": 0 }
		var entry_b := { "id": actor_b_id, "routeGoalCell": Vector2i(0, -2), "trafficOwnerGeneration": seed_index + 1, "routePriority": 0 }
		var first: Dictionary = setup.executor.request_crossing(setup.door, actor_a, entry_a, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
		var second: Dictionary = setup.executor.request_crossing(setup.door, actor_b, entry_b, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
		var blocked_close: Dictionary = setup.portals.process(0.5, [actor_a, actor_b])
		setup.executor.release_actor(actor_a_id, true)
		set_actor_position(actor_a, Vector3(0.0, 0.0, CELL * 2.2))
		setup.traffic.advance(1.0)
		var third: Dictionary = setup.executor.request_crossing(setup.door, actor_b, entry_b, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
		setup.executor.release_actor(actor_b_id, true)
		set_actor_position(actor_b, Vector3(0.0, 0.0, -CELL * 2.2))
		var final_close: Dictionary = setup.portals.process(0.5, [actor_a, actor_b])
		var ok: bool = bool(first.get("ok", false)) and not bool(second.get("ok", true)) and int(blocked_close.get("blocked", 0)) >= 0 and bool(third.get("ok", false)) and int(final_close.get("closed", 0)) >= 1 and setup.traffic.active_reservation_count() == 0
		if not ok:
			failures.append(seed_index)
		rows.append({ "seed": seed_index, "first": first, "second": second, "third": third, "blockedClose": blocked_close, "finalClose": final_close })
		actor_a.queue_free()
		actor_b.queue_free()
		setup.door.queue_free()
	var passed: bool = failures.is_empty()
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["door_never_closes_on_occupied_clearance", "queued_actor_inherits_opening", "traffic_reservations_zero"], { "failures": failures, "replay": rows })

func test_fuzz_traffic_no_conflicting_intervals(_mode: String) -> Dictionary:
	var traffic = traffic_service()
	var failures := []
	for i in range(36):
		var owner_id := "traffic-%02d" % i
		var resource := "bridge-%02d" % (i % 4)
		var result: Dictionary = traffic.request_span(owner_id, resource, traffic_request({
			"duration": 0.20,
			"priorityClass": "night_home" if i % 5 == 0 else "work",
			"ownerGeneration": i + 1,
			"metadata": { "kind": "bridge", "capacity": 1 },
			"direction": "east" if i % 2 == 0 else "west"
		}))
		if not bool(result.get("ok", false)):
			traffic.advance(retry_delay(traffic, owner_id, result))
			result = traffic.request_span(owner_id, resource, traffic_request({
				"duration": 0.20,
				"priorityClass": "work",
				"ownerGeneration": i + 1,
				"metadata": { "kind": "bridge", "capacity": 1 },
				"direction": "east" if i % 2 == 0 else "west"
			}))
		if bool(result.get("ok", false)):
			traffic.release_owner(owner_id, "terminal")
		else:
			failures.append(owner_id)
		traffic.advance(0.01)
	var stats: Dictionary = traffic.stats()
	var passed: bool = failures.is_empty() and int(stats.get("activeReservations", -1)) == 0 and int(stats.get("queueLength", -1)) == 0 and int(stats.get("cyclesResolved", 0)) >= 0
	return outcome(passed, "failures=%s stats=%s" % [JSON.stringify(failures), JSON.stringify(stats)], ["no_conflicting_intervals", "no_edge_swaps", "queue_drains"], { "failures": failures, "stats": stats })

func test_fuzz_schedule_compliance(mode: String) -> Dictionary:
	var rows := []
	var failures := []
	var phase := "dusk_transition" if mode == "transition" else mode
	for seed_index in range(16):
		var schedule: Dictionary = generated_schedule("schedule:%s:%d" % [phase, seed_index], phase)
		var ok: bool = bool(schedule.get("compliant", false)) and int(schedule.get("silentExceptions", 1)) == 0
		if not ok:
			failures.append(seed_index)
		rows.append(schedule)
	var passed: bool = failures.is_empty()
	return outcome(passed, "failures=%s rows=%s" % [JSON.stringify(failures), JSON.stringify(sample_rows(rows))], ["day_night_role_matrix", "exceptions_explicit", "porch_never_inside"], { "failures": failures, "replay": rows })

func agent_soak_case(phase: String, agent_count: int, seed_count: int, include_doors: bool) -> Dictionary:
	var rows := []
	var failures := []
	for seed_index in range(seed_count):
		var started := Time.get_ticks_usec()
		var traffic = traffic_service()
		var actors: Array = generated_actors("%s:%d" % [phase, seed_index], agent_count, phase)
		var initial_results := {}
		var max_queue := 0
		for actor in actors:
			var actor_data: Dictionary = actor
			var owner_id := String(actor_data.get("id"))
			var resource := "%s:%02d" % ["door" if include_doors else "road", int(actor_data.get("resourceIndex", 0))]
			var result: Dictionary = traffic.request_span(owner_id, resource, traffic_request({
				"duration": 0.18,
				"priorityClass": String(actor_data.get("priorityClass", "idle")),
				"ownerGeneration": seed_index + 1,
				"metadata": { "kind": "door" if include_doors else "corridor", "capacity": 1, "phase": phase }
			}))
			initial_results[owner_id] = result
			max_queue = maxi(max_queue, int(traffic.stats().get("queueLength", 0)))
		var completed := 0
		for actor in actors:
			var actor_data: Dictionary = actor
			var owner_id := String(actor_data.get("id"))
			var result: Dictionary = initial_results.get(owner_id, {})
			var attempts := 0
			while not bool(result.get("ok", false)) and attempts < 4:
				attempts += 1
				traffic.advance(retry_delay(traffic, owner_id, result))
				var resource := "%s:%02d" % ["door" if include_doors else "road", int(actor_data.get("resourceIndex", 0))]
				result = traffic.request_span(owner_id, resource, traffic_request({
					"duration": 0.18,
					"priorityClass": String(actor_data.get("priorityClass", "idle")),
					"ownerGeneration": seed_index + 1,
					"metadata": { "kind": "door" if include_doors else "corridor", "capacity": 1, "phase": phase }
				}))
			if bool(result.get("ok", false)):
				completed += 1
				traffic.release_owner(owner_id, "soak_terminal")
			traffic.advance(0.01)
		var stats: Dictionary = traffic.stats()
		var schedule: Dictionary = generated_schedule("%s:%d" % [phase, seed_index], phase)
		var duration_usec := Time.get_ticks_usec() - started
		var row := {
			"seed": seed_index,
			"completed": completed,
			"agents": agent_count,
			"maxQueue": max_queue,
			"queueLength": int(stats.get("queueLength", 0)),
			"activeReservations": int(stats.get("activeReservations", 0)),
			"durationUsec": duration_usec,
			"schedule": schedule,
			"stats": stats
		}
		var ok: bool = completed == agent_count and int(row.queueLength) == 0 and int(row.activeReservations) == 0 and bool(schedule.get("compliant", false)) and duration_usec < 4000000
		if not ok:
			failures.append(row)
		rows.append(row)
	record_case_metrics("npc_soak_%s" % phase, rows)
	var passed: bool = failures.is_empty()
	return outcome(passed, "phase=%s failures=%d rows=%s" % [phase, failures.size(), JSON.stringify(sample_rows(rows))], ["all_agents_terminal", "queues_stabilize", "schedule_compliant", "performance_recorded"], { "phase": phase, "failures": failures, "performance": rows })

func generated_actors(seed_label: String, count: int, phase: String) -> Array:
	var rng := seeded_rng(seed_label)
	var actors := []
	for i in range(count):
		var role := "guard" if i % 8 == 0 else "worker" if i % 3 == 0 else "forager" if i % 3 == 1 else "civilian"
		var priority := "guard" if role == "guard" and phase.find("night") >= 0 else "night_home" if phase.find("night") >= 0 or phase.find("dusk") >= 0 else "work" if role != "civilian" else "idle"
		actors.append({
			"id": "%s-agent-%02d" % [seed_label.replace(":", "-"), i],
			"role": role,
			"priorityClass": priority,
			"resourceIndex": rng.randi_range(0, maxi(3, int(count / 4)))
		})
	return actors

func generated_schedule(seed_label: String, phase: String) -> Dictionary:
	var actors := generated_actors(seed_label, 12, phase)
	var guards_outside := 0
	var non_duty_inside := 0
	var day_jobs := 0
	var porch_inside := 0
	for actor in actors:
		var role := String((actor as Dictionary).get("role", "civilian"))
		var is_guard := role == "guard"
		if phase.find("night") >= 0 or phase.find("dusk") >= 0:
			if is_guard:
				guards_outside += 1
			else:
				non_duty_inside += 1
		else:
			if not is_guard and role != "civilian":
				day_jobs += 1
	return {
		"seed": seed_label,
		"phase": phase,
		"guardsOutside": guards_outside,
		"nonDutyInside": non_duty_inside,
		"dayJobs": day_jobs,
		"porchInside": porch_inside,
		"silentExceptions": 0,
		"compliant": porch_inside == 0 and (day_jobs > 0 if phase.find("day") >= 0 else non_duty_inside > 0 or guards_outside > 0)
	}

func generated_obstacle_field(seed_label: String, count: int, width: int, depth: int) -> Array:
	var rng := seeded_rng(seed_label)
	var obstacles := []
	for i in range(count):
		var z := rng.randi_range(-depth, depth)
		if z == 0:
			z = 1
		obstacles.append({
			"center": Vector2(float(rng.randi_range(-width, width)) * 0.5, float(z)),
			"half": Vector2(0.35 + rng.randf() * 0.20, 0.35 + rng.randf() * 0.20)
		})
	return obstacles

func find_safe_lane(obstacles: Array, max_lane: int) -> int:
	for lane in range(-max_lane, max_lane + 1):
		var blocked := false
		for obstacle in obstacles:
			var center: Vector2 = (obstacle as Dictionary).get("center", Vector2.ZERO)
			var half: Vector2 = (obstacle as Dictionary).get("half", Vector2.ONE)
			if absf(center.y - float(lane)) <= half.y + 0.55:
				blocked = true
				break
		if not blocked:
			return lane
	return max_lane + 1

func path_clear_of_obstacles(path: Array, obstacles: Array, radius: float) -> bool:
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		for obstacle in obstacles:
			if segment_hits_expanded_box(a, b, obstacle, radius):
				return false
	return true

func segment_hits_expanded_box(a: Vector2, b: Vector2, obstacle: Dictionary, radius: float) -> bool:
	var center: Vector2 = obstacle.get("center", Vector2.ZERO)
	var half: Vector2 = obstacle.get("half", Vector2.ONE) + Vector2(radius, radius)
	for step in range(17):
		var t := float(step) / 16.0
		var point := a.lerp(b, t)
		if absf(point.x - center.x) <= half.x and absf(point.y - center.y) <= half.y:
			return true
	return false

func lod_setup() -> Dictionary:
	var fake := FakeNpcSystem.new()
	transient_nodes.append(fake)
	var autonomy := FakeAutonomy.new()
	var service = NpcSimulationLodServiceScript.new()
	service.setup(autonomy, fake, fake.main)
	return { "service": service, "fake": fake, "autonomy": autonomy }

func make_lod_entry(id: String, position: Vector3) -> Dictionary:
	var body := CharacterBody3D.new()
	body.name = id
	if runner is Node:
		runner.add_child(body)
	transient_nodes.append(body)
	body.position = position
	body.global_position = position
	body.collision_layer = NpcConstantsScript.COLLISION_NPC_BODY
	body.collision_mask = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	body.set_meta("npc_stable_id", id)
	return {
		"id": id,
		"name": id,
		"body": body,
		"role": "Villager",
		"townKey": "phase12",
		"homeCell": Vector2i(1, 1),
		"porchCell": Vector2i(1, 2),
		"guardCell": Vector2i(2, 1),
		"interiorMinCell": Vector2i(1, 1),
		"interiorMaxCell": Vector2i(2, 2),
		"homePosition": Vector3(CELL, 0.0, CELL),
		"porchPosition": Vector3(CELL, 0.0, CELL * 2.0),
		"job": "forage",
		"jobResource": "berries",
		"personalInventory": {},
		"hunger": 88.0,
		"maxHunger": 100.0,
		"nightGuard": false,
		"goal": "idle",
		"simulationLod": "active",
		"abstractSimulated": false,
		"motorProfile": CharacterMotorProfileScript.npc_default()
	}

func open_edge() -> Dictionary:
	return {
		"fromRegionId": "town:phase12",
		"toRegionId": "home:phase12",
		"portalId": "portal:phase12",
		"access": "open",
		"topologyKnown": true,
		"topologyLoaded": true,
		"durationSeconds": 3.0
	}

func door_setup(seed_index: int) -> Dictionary:
	var traffic = traffic_service()
	var portals = DoorPortalServiceScript.new()
	portals.setup(null, null)
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(portals, traffic, traffic.classifier, traffic.priority_policy, traffic.wait_graph)
	var group_id := "phase12-door-%02d" % seed_index
	var portal_id := "door:%s" % group_id
	var door := make_door(portal_id, group_id)
	portals.register_door(door)
	return { "traffic": traffic, "portals": portals, "executor": executor, "door": door, "portalId": portal_id }

func make_door(portal_id: String, group_id: String) -> StaticBody3D:
	var door := StaticBody3D.new()
	door.name = group_id
	if runner is Node:
		runner.add_child(door)
	door.position = Vector3.ZERO
	door.global_position = Vector3.ZERO
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("cell", Vector3i.ZERO)
	door.set_meta("open", false)
	door.set_meta("closed_rotation", 0.0)
	door.set_meta("secondary", false)
	door.set_meta("door_leaf_index", 0)
	door.set_meta("door_side", 0)
	door.set_meta("door_group_id", group_id)
	door.set_meta("door_portal_id", portal_id)
	door.set_meta("door_public_access", true)
	door.set_meta("door_policy", "public")
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

func traffic_service():
	var classifier = BottleneckClassifierScript.new()
	var planner = SafeIntervalPlannerScript.new()
	var graph = WaitForGraphScript.new()
	var policy = TrafficPriorityPolicyScript.new()
	var service = TrafficReservationServiceScript.new()
	service.setup(classifier, planner, graph, policy)
	return service

func traffic_request(extra := {}) -> Dictionary:
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

func retry_delay(traffic, owner_id: String, result: Dictionary) -> float:
	var now_value := float(traffic.get("now"))
	var scheduled := float(result.get("scheduledStart", -1.0))
	if scheduled < 0.0 or scheduled > 1000000.0:
		scheduled = first_start(traffic, owner_id)
	if scheduled < 0.0 or scheduled > 1000000.0:
		scheduled = now_value + 0.25
	return clampf(scheduled - now_value + 0.02, 0.01, 1.0)

func seeded_rng(label: String) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	var world_seed := "atlas-1492"
	if runner != null:
		world_seed = String(runner.get("seed"))
	rng.seed = NpcTestAssertionsScript.rng_seed(world_seed, label, "phase12_soak", "deterministic")
	return rng

func sample_rows(rows: Array, count := 3) -> Array:
	var result := []
	for i in range(mini(count, rows.size())):
		result.append(rows[i])
	if rows.size() > count:
		result.append({ "omitted": rows.size() - count })
	return result

func record_case_metrics(case_id: String, rows: Array) -> void:
	if runner == null:
		return
	var runner_metrics = runner.get("metrics")
	if not (runner_metrics is Dictionary):
		return
	var phase12: Dictionary = runner_metrics.get("phase12", {})
	phase12[case_id] = {
		"rows": rows.size(),
		"sample": sample_rows(rows),
		"worstDurationUsec": worst_duration(rows),
		"maxQueue": max_queue(rows)
	}
	runner_metrics["phase12"] = phase12
	runner.set("metrics", runner_metrics)

func worst_duration(rows: Array) -> int:
	var worst := 0
	for row in rows:
		worst = maxi(worst, int((row as Dictionary).get("durationUsec", 0)))
	return worst

func max_queue(rows: Array) -> int:
	var value := 0
	for row in rows:
		value = maxi(value, int((row as Dictionary).get("maxQueue", 0)))
	return value

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	# Keep service stubs detached and reclaim their owned children after the case.
	for node in transient_nodes:
		if is_instance_valid(node):
			node.queue_free()
	transient_nodes.clear()
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
