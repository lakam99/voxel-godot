extends RefCounted

const NpcSimulationLodServiceScript := preload("res://scripts/npc_ai/lifecycle/NpcSimulationLodService.gd")
const AbstractNpcTransitScript := preload("res://scripts/npc_ai/lifecycle/AbstractNpcTransit.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const NpcSafePlacementServiceScript := preload("res://scripts/npc_ai/NpcSafePlacementService.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35

var runner = null

class FakeMain:
	extends Node
	var player: Node3D

	func _init() -> void:
		player = Node3D.new()
		player.name = "Player"

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class FakeNpcSystem:
	extends Node
	var main
	var placement_service
	var cleanup_calls := 0
	var last_cleanup := {}

	func _init() -> void:
		main = FakeMain.new()
		placement_service = NpcSafePlacementServiceScript.new()
		placement_service.setup(self, main)

	func safe_place_npc(body: Node3D, position: Vector3, profile = null, reason := "spawn") -> Dictionary:
		return placement_service.place_spawn(body as CharacterBody3D, position, profile, reason)

	func cleanup_npc_route_state(actor_id: String, entry := {}, reason := "cleanup") -> Dictionary:
		cleanup_calls += 1
		var entry_dict: Dictionary = entry if entry is Dictionary else {}
		var released := 0
		for key in ["pathWaypoints", "routeCells", "routeActions", "activeTrafficStepGroup", "activeDoorPortalId", "activeDoorTrafficGroupId", "jobReservationId", "jobApproachSlotId"]:
			if entry_dict.has(key):
				entry_dict.erase(key)
				released += 1
		last_cleanup = { "actorId": actor_id, "reason": reason, "routeState": released, "avoidance": 1 }
		return last_cleanup.duplicate(true)

	func npc_avoidance_registration_count() -> int:
		return 0

class OpenWorld:
	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var specs := [
		["npc_stream_active_to_abstract_safe", "test_active_to_abstract_safe"],
		["npc_stream_abstract_to_active_safe_span", "test_abstract_to_active_safe_span"],
		["npc_stream_no_promote_in_door_threshold", "test_no_promote_in_door_threshold"],
		["npc_stream_no_demote_during_crossing", "test_no_demote_during_crossing"],
		["npc_stream_active_forage_lifecycle_stays_physical", "test_active_forage_lifecycle_stays_physical"],
		["npc_stream_route_across_chunk_boundary", "test_route_across_chunk_boundary"],
		["npc_stream_prefetch_before_boundary", "test_prefetch_before_boundary"],
		["npc_stream_unloaded_goal_pending_not_teleport", "test_unloaded_goal_pending_not_teleport"],
		["npc_stream_topology_hold_releases_when_ready", "test_topology_hold_releases_when_ready"],
		["npc_stream_abstract_respects_locked_portal", "test_abstract_respects_locked_portal"],
		["npc_stream_lod_hysteresis_no_thrashing", "test_lod_hysteresis_no_thrashing"],
		["npc_stream_actor_removal_releases_all_ownership", "test_actor_removal_releases_all_ownership"],
		["npc_save_old_snapshot_defaults", "test_save_old_snapshot_defaults"],
		["npc_save_round_trip_durable_state", "test_save_round_trip_durable_state"],
		["npc_save_no_transient_route_or_reservation", "test_save_no_transient_route_or_reservation"],
		["npc_save_invalid_position_safe_migration", "test_save_invalid_position_safe_migration"],
		["npc_save_night_schedule_reconstructs", "test_save_night_schedule_reconstructs"],
		["npc_save_guard_duty_reconstructs", "test_save_guard_duty_reconstructs"],
		["npc_save_door_durable_state_reconstructs", "test_save_door_durable_state_reconstructs"],
		["npc_save_deterministic_round_trip", "test_save_deterministic_round_trip"],
		["npc_save_world_signature_unchanged", "test_save_world_signature_unchanged"]
	]
	var result: Array[Dictionary] = []
	for spec in specs:
		result.append({
			"id": String(spec[0]),
			"suite": "streaming_save",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_active_to_abstract_safe(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-safe", Vector3.ZERO)
	entry["routeCells"] = [Vector2i(0, 0), Vector2i(1, 0)]
	entry["activeTrafficStepGroup"] = ""
	var result: Dictionary = setup.service.update_actor(entry, 0.1, Vector3(180.0, 0.0, 0.0), { "transitEdge": open_edge() })
	var body := entry.get("body") as CharacterBody3D
	var passed: bool = String(result.get("state", "")) == "abstract" and bool(entry.get("abstractSimulated", false)) and not body.visible and body.collision_layer == 0 and not entry.has("routeCells")
	return outcome(passed, "result=%s" % JSON.stringify(result), ["distant_actor_demotes", "physical_body_disabled", "route_transients_cleared"], { "result": result, "entry": entry_summary(entry), "bodyVisible": body.visible, "collisionLayer": body.collision_layer })

func test_abstract_to_active_safe_span(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-promote", Vector3.ZERO)
	setup.service.demote_actor(entry, "test", { "transitEdge": open_edge() })
	var result: Dictionary = setup.service.update_actor(entry, 0.1, Vector3.ZERO, { "promotionPosition": Vector3(1.0, 0.0, 1.0), "topologyLoaded": true })
	var body := entry.get("body") as CharacterBody3D
	var passed: bool = bool(result.get("state", "") == "active") and not bool(entry.get("abstractSimulated", true)) and body.visible and body.get_meta("npc_safe_placement_reason", "") == "promotion" and body.position.distance_to(Vector3(1.0, 0.0, 1.0)) <= 0.001
	return outcome(passed, "result=%s position=%s" % [JSON.stringify(result), str(body.position)], ["abstract_promotes_only_via_safe_placement", "body_reenabled", "same_body_reused"], { "result": result, "position": vec3(body.position), "metaReason": body.get_meta("npc_safe_placement_reason", "") })

func test_no_promote_in_door_threshold(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-door-promote", Vector3.ZERO)
	setup.service.demote_actor(entry, "test", { "transitEdge": open_edge() })
	entry["inDoorThreshold"] = true
	var result: Dictionary = setup.service.update_actor(entry, 0.1, Vector3.ZERO, { "promotionPosition": Vector3.ZERO, "topologyLoaded": true })
	var passed: bool = String(result.get("state", "")) == "abstract" and String(result.get("reason", "")) == "door_threshold"
	return outcome(passed, "result=%s" % JSON.stringify(result), ["door_threshold_blocks_promotion"], { "result": result, "entry": entry_summary(entry) })

func test_no_demote_during_crossing(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-crossing", Vector3.ZERO)
	entry["activeDoorPortalId"] = "door:front"
	entry["activeDoorTrafficGroupId"] = "portal:front:stream-crossing:1"
	var result: Dictionary = setup.service.update_actor(entry, 0.1, Vector3(200.0, 0.0, 0.0))
	var passed: bool = String(result.get("state", "")) == "active" and String(result.get("reason", "")) == "in_door_threshold" and not bool(entry.get("abstractSimulated", false))
	return outcome(passed, "result=%s" % JSON.stringify(result), ["active_crossing_blocks_demote", "actor_remains_physical"], { "result": result, "entry": entry_summary(entry) })

func test_active_forage_lifecycle_stays_physical(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-active-forager", Vector3.ZERO)
	entry["activeGoalKind"] = "forage"
	entry["activeMotionGoal"] = { "goalKind": "forage", "reason": "role_forager_food_loop" }
	entry["jobPhase"] = "searching"
	entry["routineRouteV2RequestId"] = "stream-active-forager:v2:1:1"
	var result: Dictionary = setup.service.update_actor(entry, 0.1, Vector3(200.0, 0.0, 0.0), { "transitEdge": open_edge() })
	var body := entry.get("body") as CharacterBody3D
	var passed: bool = String(result.get("state", "")) == "active" \
		and String(entry.get("simulationLod", "")) == "active" \
		and not bool(entry.get("abstractSimulated", true)) \
		and body != null and body.visible
	return outcome(
		passed,
		"result=%s" % JSON.stringify(result),
		["active_forage_lifecycle_blocks_distance_demotion", "collision_backed_forage_route_remains_physical"],
		{ "result": result, "entry": entry_summary(entry) }
	)

func test_route_across_chunk_boundary(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-boundary", Vector3.ZERO)
	entry["routeCells"] = [Vector2i(14, 0), Vector2i(15, 0), Vector2i(16, 0), Vector2i(17, 0)]
	var result: Dictionary = setup.service.prefetch_for_entry(entry)
	var requested: Array = result.get("requested", [])
	var tile_keys := []
	for item in requested:
		tile_keys.append(String((item as Dictionary).get("tileKey", "")))
	var passed: bool = tile_keys.has("0,0") and tile_keys.has("1,0")
	return outcome(passed, "prefetch=%s" % JSON.stringify(result), ["route_boundary_detected", "both_boundary_tiles_requested"], { "result": result, "requests": setup.autonomy.requested_tiles })

func test_prefetch_before_boundary(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-prefetch", Vector3.ZERO)
	entry["routeCells"] = [Vector2i(13, 4)]
	var result: Dictionary = setup.service.prefetch_for_entry(entry, 3)
	var passed: bool = not (result.get("requested", []) as Array).is_empty() and String(((result.get("requested", []) as Array)[0] as Dictionary).get("tileKey", "")) == "0,0"
	return outcome(passed, "prefetch=%s" % JSON.stringify(result), ["near_boundary_prefetch_requested"], { "result": result, "requests": setup.autonomy.requested_tiles })

func test_unloaded_goal_pending_not_teleport(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-unloaded", Vector3(2.0, 0.0, 2.0))
	entry["routeGoalCell"] = Vector2i(18, 2)
	var before: Vector3 = (entry.get("body") as CharacterBody3D).position
	var result: Dictionary = setup.service.handle_tile_unloaded("1,0", [entry])
	var after: Vector3 = (entry.get("body") as CharacterBody3D).position
	var passed: bool = bool(entry.get("movementHeldForTopology", false)) and String(entry.get("routeStatus", "")) == "PENDING" and before.distance_to(after) <= 0.001
	return outcome(passed, "result=%s before=%s after=%s" % [JSON.stringify(result), str(before), str(after)], ["unloaded_goal_sets_pending", "body_not_teleported"], { "result": result, "position": vec3(after), "entry": entry_summary(entry) })

func test_topology_hold_releases_when_ready(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-topology-ready", Vector3(2.0, 0.0, 2.0))
	entry["routeGoalCell"] = Vector2i(18, 2)
	setup.service.handle_tile_unloaded("1,0", [entry])
	var held_before: bool = setup.service.should_hold_active_movement(entry)
	setup.autonomy.navigation_world.ready_tiles["1,0"] = true
	var held_after: bool = setup.service.should_hold_active_movement(entry)
	var passed: bool = held_before and not held_after and not bool(entry.get("movementHeldForTopology", false)) and bool(entry.get("routeForceReplan", false)) and String(entry.get("routeStatus", "")) == "waiting" and String(entry.get("routeReason", "")) == "topology_ready"
	return outcome(passed, "held %s->%s entry=%s stats=%s" % [str(held_before), str(held_after), JSON.stringify(entry_summary(entry)), JSON.stringify(setup.service.stats())], ["hold_persists_until_tile_ready", "ready_tile_releases_hold", "route_replan_forced"], { "entry": entry_summary(entry), "stats": setup.service.stats() })

func test_abstract_respects_locked_portal(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("stream-locked", Vector3.ZERO)
	var result: Dictionary = setup.service.start_abstract_transit(entry, {
		"fromRegionId": "town:a",
		"toRegionId": "home:a",
		"portalId": "door:locked",
		"access": "locked",
		"durationSeconds": 4.0
	})
	var passed: bool = not bool(result.get("ok", true)) and String(result.get("reason", "")) == "locked_portal" and not entry.has("abstractTransit")
	return outcome(passed, "result=%s" % JSON.stringify(result), ["locked_portal_blocks_abstract_travel"], { "result": result })

func test_lod_hysteresis_no_thrashing(_mode: String) -> Dictionary:
	var service := NpcSimulationLodServiceScript.new()
	var states := [
		service.classify_distance(51.0, "active"),
		service.classify_distance(53.0, "active"),
		service.classify_distance(95.0, "nearby"),
		service.classify_distance(97.0, "abstract"),
		service.classify_distance(41.0, "abstract")
	]
	var passed: bool = states == ["active", "nearby", "nearby", "abstract", "active"]
	return outcome(passed, "states=%s" % JSON.stringify(states), ["active_exit_hysteresis", "nearby_exit_hysteresis", "abstract_enter_hysteresis"], { "states": states })

func test_actor_removal_releases_all_ownership(_mode: String) -> Dictionary:
	var fake := FakeNpcSystem.new()
	var autonomy := NpcAutonomySystemScript.new()
	if runner is Node:
		runner.add_child(autonomy)
	autonomy.setup(fake, fake.main)
	var entry := make_entry("stream-cleanup", Vector3.ZERO)
	entry["pathWaypoints"] = [Vector3.ONE]
	entry["routeCells"] = [Vector2i(0, 0)]
	entry["activeTrafficStepGroup"] = "movement:stream-cleanup:1:0,0>1,0"
	var body := entry.get("body") as CharacterBody3D
	var object_id: String = autonomy.register_smart_anchor("cleanup:bench", "workstation", Vector3.ZERO, { "capacity": 1 })
	var smart_result = autonomy.reserve_smart_object(object_id, null, body, "stream-cleanup", "use_workstation")
	var traffic_result: Dictionary = autonomy.request_npc_traffic_step(entry, Vector3.ZERO, Vector3(CELL, 0.0, 0.0), OpenWorld.new(), { "physicsDelta": 0.2 })
	var cleanup: Dictionary = autonomy.cleanup_actor_ownership(entry, "actor_removed")
	var smart = autonomy.get("smart_objects")
	var traffic = autonomy.get("traffic_reservations")
	var stats := {
		"smartReservations": smart.owner_reservation_count("stream-cleanup") if smart != null else -1,
		"trafficActive": traffic.active_reservation_count() if traffic != null else -1,
		"cleanup": cleanup
	}
	var passed: bool = int(stats.get("smartReservations", -1)) == 0 and int(stats.get("trafficActive", -1)) == 0 and not entry.has("routeCells") and not entry.has("activeTrafficStepGroup") and int((cleanup.get("released", {}) as Dictionary).get("routeState", 0)) > 0
	if runner is Node:
		autonomy.queue_free()
	return outcome(passed, "smart=%s traffic=%s cleanup=%s" % [str(smart_result), JSON.stringify(traffic_result), JSON.stringify(cleanup)], ["smart_object_released", "traffic_released", "route_state_cleared", "leak_counters_zero"], stats)

func test_save_old_snapshot_defaults(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-old", Vector3.ZERO)
	entry["role"] = "Fighter"
	entry["canFight"] = true
	var fact := { "id": "save-old", "role": "Fighter", "job": "guard", "hunger": 44.0 }
	var result: Dictionary = setup.service.apply_durable_snapshot(entry, fact, { "timeOfDay": 0.75 })
	var passed: bool = bool(result.get("migrated", false)) and not bool(entry.get("nightGuard", true)) and String(entry.get("restoredScheduleIntent", "")) == "return_home" and String(entry.get("interiorRegionId", "")).begins_with("home:")
	return outcome(passed, "result=%s entry=%s" % [JSON.stringify(result), JSON.stringify(entry_summary(entry))], ["old_snapshot_migrates", "fighter_not_implicit_guard", "home_interior_defaulted", "night_non_duty_returns_home"], { "result": result, "entry": entry_summary(entry) })

func test_save_round_trip_durable_state(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-round", Vector3(3.0, 0.0, 4.0))
	entry["personalInventory"] = { "berries": 3, "logs": 1 }
	entry["hunger"] = 55.0
	entry["weaponId"] = "trainingBow"
	entry["carriedResource"] = "logs"
	setup.service.start_abstract_transit(entry, open_edge())
	var fact: Dictionary = setup.service.durable_snapshot(entry)
	var restored := make_entry("save-round", Vector3.ZERO)
	var result: Dictionary = setup.service.apply_durable_snapshot(restored, fact, { "timeOfDay": 0.25 })
	var passed: bool = bool(result.get("ok", false)) and restored.get("personalInventory", {}) == entry.get("personalInventory", {}) and String(restored.get("weaponId", "")) == "trainingBow" and restored.has("abstractTransit")
	return outcome(passed, "fact=%s result=%s" % [JSON.stringify(fact), JSON.stringify(result)], ["durable_inventory_round_trips", "equipment_round_trips", "abstract_transit_round_trips"], { "fact": fact, "restored": entry_summary(restored) })

func test_save_no_transient_route_or_reservation(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-transient", Vector3.ZERO)
	entry["routeCells"] = [Vector2i(1, 2)]
	entry["routeActions"] = { "1,2": { "kind": "door" } }
	entry["activeTrafficStepGroup"] = "movement:save-transient"
	entry["jobReservationId"] = "reserved"
	entry["debugTrace"] = ["no-save"]
	var fact: Dictionary = setup.service.durable_snapshot(entry)
	var passed: bool = not setup.service.snapshot_has_transient_state(fact)
	return outcome(passed, "fact=%s" % JSON.stringify(fact), ["transient_route_absent", "reservation_absent", "debug_trace_absent"], { "fact": fact })

func test_save_invalid_position_safe_migration(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-invalid", Vector3(8.0, 0.0, 8.0))
	entry["homePosition"] = Vector3(2.0, 0.0, 2.0)
	var fact := { "id": "save-invalid", "schemaVersion": 1, "position": [9999.0, 0.0, 9999.0], "positionValid": false }
	var result: Dictionary = setup.service.apply_durable_snapshot(entry, fact, { "timeOfDay": 0.25 })
	var body := entry.get("body") as CharacterBody3D
	var passed: bool = bool(result.get("migrated", false)) and (entry.get("saveMigrationLog", []) as Array).has("invalid_position_safe_migration") and body.position.distance_to(Vector3(2.0, 0.0, 2.0)) <= 0.001 and body.get_meta("npc_safe_placement_reason", "") == "load_restore"
	return outcome(passed, "result=%s pos=%s" % [JSON.stringify(result), str(body.position)], ["invalid_position_logged", "safe_placement_used", "nearest_semantic_home_span"], { "result": result, "position": vec3(body.position), "migrationLog": entry.get("saveMigrationLog", []) })

func test_save_night_schedule_reconstructs(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-night", Vector3.ZERO)
	var result: Dictionary = setup.service.apply_durable_snapshot(entry, { "id": "save-night", "schemaVersion": 2, "nightGuard": false }, { "timeOfDay": 0.75 })
	var passed: bool = String(entry.get("restoredScheduleIntent", "")) == "return_home"
	return outcome(passed, "result=%s intent=%s" % [JSON.stringify(result), String(entry.get("restoredScheduleIntent", ""))], ["night_non_guard_reconstructs_home_intent"], { "result": result, "entry": entry_summary(entry) })

func test_save_guard_duty_reconstructs(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-guard", Vector3.ZERO)
	var result: Dictionary = setup.service.apply_durable_snapshot(entry, { "id": "save-guard", "schemaVersion": 2, "nightGuard": true, "guardDuty": "night_guard" }, { "timeOfDay": 0.75 })
	var passed: bool = bool(entry.get("nightGuard", false)) and String(entry.get("restoredScheduleIntent", "")) == "guard_duty"
	return outcome(passed, "result=%s intent=%s" % [JSON.stringify(result), String(entry.get("restoredScheduleIntent", ""))], ["night_guard_reconstructs_duty_intent"], { "result": result, "entry": entry_summary(entry) })

func test_save_door_durable_state_reconstructs(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-door", Vector3.ZERO)
	var door_state := { "door:home": { "locked": true, "destroyed": false, "revision": 7 } }
	var fact := { "id": "save-door", "schemaVersion": 2, "doorDurableState": door_state }
	var result: Dictionary = setup.service.apply_durable_snapshot(entry, fact, { "timeOfDay": 0.25 })
	var passed: bool = bool(result.get("ok", false)) and entry.get("doorDurableState", {}) == door_state
	return outcome(passed, "result=%s door=%s" % [JSON.stringify(result), JSON.stringify(entry.get("doorDurableState", {}))], ["door_lock_state_reconstructed", "door_state_is_durable_not_token"], { "result": result, "doorDurableState": entry.get("doorDurableState", {}) })

func test_save_deterministic_round_trip(_mode: String) -> Dictionary:
	var setup := lod_setup()
	var entry := make_entry("save-deterministic", Vector3(5.0, 0.0, 6.0))
	entry["personalInventory"] = { "berries": 2 }
	entry["hunger"] = 77.0
	var first: Dictionary = setup.service.durable_snapshot(entry)
	var restored := make_entry("save-deterministic", Vector3.ZERO)
	setup.service.apply_durable_snapshot(restored, first, { "timeOfDay": 0.25 })
	var second: Dictionary = setup.service.durable_snapshot(restored)
	var passed: bool = JSON.stringify(first) == JSON.stringify(second)
	return outcome(passed, "first=%s second=%s" % [JSON.stringify(first), JSON.stringify(second)], ["same_input_same_durable_snapshot"], { "first": first, "second": second })

func test_save_world_signature_unchanged(_mode: String) -> Dictionary:
	var baseline := read_text("res://artifacts/baselines/world-signature/atlas-1492.json")
	var latest := read_text("res://artifacts/world-signature/latest/atlas-1492.json")
	var latest_available := latest.strip_edges() != ""
	var passed: bool = baseline.strip_edges() != "" and latest_available and baseline == latest
	return outcome(passed, "baselineBytes=%d latestBytes=%d" % [baseline.length(), latest.length()], ["tracked_baseline_present", "generated_latest_present", "world_signature_stable"], { "baselineBytes": baseline.length(), "latestBytes": latest.length(), "latestAvailable": latest_available })

func lod_setup() -> Dictionary:
	var fake := FakeNpcSystem.new()
	var autonomy := FakeAutonomy.new()
	var service = NpcSimulationLodServiceScript.new()
	service.setup(autonomy, fake, fake.main)
	autonomy.service = service
	return { "service": service, "fake": fake, "autonomy": autonomy }

class FakeNavigationWorld:
	var ready_tiles := {}

	func is_tile_traversable(tile_key: String) -> bool:
		return bool(ready_tiles.get(tile_key, false))

class FakeAutonomy:
	var service = null
	var requested_tiles := []
	var navigation_world = FakeNavigationWorld.new()

	func request_navigation_tile(snapshot: Dictionary, priority := 0, _profile = null) -> Dictionary:
		var tile_key := String(snapshot.get("tileKey", ""))
		requested_tiles.append({ "tileKey": tile_key, "priority": priority })
		return { "status": "PENDING", "reason": "requested", "tileKey": tile_key }

	func release_npc_traffic_reservations(_entry_or_id, _reason := "released") -> int:
		return 0

	func release_npc_door_hold(_actor_or_id, _schedule_close := true) -> void:
		pass


func make_entry(id: String, position: Vector3) -> Dictionary:
	var body := CharacterBody3D.new()
	body.name = id
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
		"townKey": "test-town",
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
		"jobRuns": 0,
		"goal": "idle",
		"simulationLod": "active",
		"abstractSimulated": false,
		"motorProfile": CharacterMotorProfileScript.npc_default()
	}

func open_edge() -> Dictionary:
	return {
		"fromRegionId": "town:test",
		"toRegionId": "home:test",
		"portalId": "portal:test",
		"access": "open",
		"topologyKnown": true,
		"topologyLoaded": true,
		"durationSeconds": 3.0
	}

func entry_summary(entry: Dictionary) -> Dictionary:
	return {
		"id": String(entry.get("id", "")),
		"simulationLod": String(entry.get("simulationLod", "")),
		"abstractSimulated": bool(entry.get("abstractSimulated", false)),
		"routeStatus": String(entry.get("routeStatus", "")),
		"routeReason": String(entry.get("routeReason", "")),
		"nightGuard": bool(entry.get("nightGuard", false)),
		"scheduleIntent": String(entry.get("restoredScheduleIntent", "")),
		"interiorRegionId": String(entry.get("interiorRegionId", "")),
		"hasTransit": entry.has("abstractTransit") and entry.get("abstractTransit") != null
	}

func vec3(position: Vector3) -> Array:
	return [position.x, position.y, position.z]

func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
