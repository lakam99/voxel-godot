extends RefCounted

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const DoorPortalServiceScript := preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const DoorTraversalExecutorScript := preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")

const CELL := 1.35

var runner = null

class FakeAutonomyForDoorHold:
	var door_portals = null

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_door_idempotent_open", "test_idempotent_open"],
		["npc_door_idempotent_close", "test_idempotent_close"],
		["npc_door_single_open_cross_close", "test_single_open_cross_close"],
		["npc_door_double_coordinated_portal", "test_double_coordinated_portal"],
		["npc_door_metadata_portal_overrides_stale_action_id", "test_metadata_portal_overrides_stale_action_id"],
		["npc_door_player_npc_shared_authority", "test_player_npc_shared_authority"],
		["npc_door_threshold_occupied_no_close", "test_threshold_occupied_no_close"],
		["npc_door_sweep_occupied_no_close", "test_sweep_occupied_no_close"],
		["npc_door_clearance_volume_occupied_no_close", "test_clearance_volume_occupied_no_close"],
		["npc_door_crossing_releases_after_sweep_clearance", "test_crossing_releases_after_sweep_clearance"],
		["npc_door_arrived_route_still_holds_threshold_actor", "test_arrived_route_still_holds_threshold_actor"],
		["npc_door_obstructed_closing_reopens", "test_obstructed_closing_reopens"],
		["npc_door_queue_inherits_opening", "test_queue_inherits_opening"],
		["npc_door_opposing_direction_ordered", "test_opposing_direction_ordered"],
		["npc_door_locked_authorized", "test_locked_authorized"],
		["npc_door_locked_unauthorized_alternate", "test_locked_unauthorized_alternate"],
		["npc_door_jammed_failure_or_alternate", "test_jammed_failure_or_alternate"],
		["npc_door_destroyed_topology_update", "test_destroyed_topology_update"],
		["npc_door_no_timeout_safety_override", "test_no_timeout_safety_override"],
		["npc_door_cancelled_actor_releases_hold", "test_cancelled_actor_releases_hold"],
		["npc_door_night_civilian_enters_home", "test_night_civilian_enters_home"],
		["npc_door_night_guard_exits_for_duty", "test_night_guard_exits_for_duty"],
		["npc_door_night_player_blocks_threshold_no_close", "test_night_player_blocks_threshold_no_close"],
		["npc_door_day_worker_exit_and_return", "test_day_worker_exit_and_return"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": String(spec[0]),
			"suite": "door",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_idempotent_open(_mode: String) -> Dictionary:
	var setup := door_setup()
	var first = setup.service.request_door_state(setup.door, true, null, "", {})
	var second = setup.service.request_door_state(setup.door, true, null, "", {})
	var stats: Dictionary = setup.service.stats()
	var passed: bool = succeeded(first) and succeeded(second) and bool(setup.door.get_meta("open", false)) and int(stats.get("transitionCounts", {}).get("open", 0)) == 1
	return outcome(passed, "first=%s second=%s stats=%s" % [summary(first), summary(second), JSON.stringify(stats)], ["open_idempotent", "single_open_transition"], { "stats": stats, "first": result_summary(first), "second": result_summary(second) })

func test_idempotent_close(_mode: String) -> Dictionary:
	var setup := door_setup()
	setup.service.request_door_state(setup.door, true, null, "", {})
	var first = setup.service.request_door_state(setup.door, false, null, "", {})
	var second = setup.service.request_door_state(setup.door, false, null, "", {})
	var stats: Dictionary = setup.service.stats()
	var passed: bool = succeeded(first) and succeeded(second) and not bool(setup.door.get_meta("open", true)) and int(stats.get("transitionCounts", {}).get("close", 0)) == 1
	return outcome(passed, "first=%s second=%s stats=%s" % [summary(first), summary(second), JSON.stringify(stats)], ["close_idempotent", "single_close_transition"], { "stats": stats, "first": result_summary(first), "second": result_summary(second) })

func test_single_open_cross_close(_mode: String) -> Dictionary:
	var setup := door_setup()
	var actor := make_actor("npc-a", Vector3(0.0, 0.0, -CELL * 2.4))
	var open = setup.service.request_door_state(setup.door, true, actor, "npc", { "actors": [actor] })
	setup.service.release_actor(setup.portalId, actor_id(actor), true)
	set_actor_position(actor, Vector3(0.0, 0.0, CELL * 2.8))
	var processed: Dictionary = setup.service.process(0.5, [actor])
	var passed: bool = succeeded(open) and int(processed.get("closed", 0)) == 1 and not bool(setup.door.get_meta("open", true))
	return outcome(passed, "open=%s processed=%s" % [summary(open), JSON.stringify(processed)], ["open_cross_release", "policy_close_after_clear"], { "processed": processed, "doorOpen": setup.door.get_meta("open") })

func test_double_coordinated_portal(_mode: String) -> Dictionary:
	var setup := door_setup({ "double": true })
	var open = setup.service.request_door_state(setup.door, true, null, "", {})
	var portal = setup.service.portal_for_door(setup.door)
	var same_portal: bool = setup.service.portal_for_door(setup.secondDoor) == portal
	var both_open: bool = bool(setup.door.get_meta("open", false)) and bool(setup.secondDoor.get_meta("open", false))
	var both_clear: bool = primary_collider(setup.door).disabled and primary_collider(setup.secondDoor).disabled
	var passed: bool = succeeded(open) and same_portal and both_open and both_clear and portal.leaf_nodes.size() == 2
	return outcome(passed, "portal=%s open=%s" % [JSON.stringify(portal.to_summary()), summary(open)], ["logical_double_portal", "coordinated_leaves"], { "portal": portal.to_summary(), "bothOpen": both_open, "bothClear": both_clear })

func test_metadata_portal_overrides_stale_action_id(_mode: String) -> Dictionary:
	var setup := door_setup({ "double": true })
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(setup.service)
	var actor := make_actor("npc-a", Vector3.ZERO)
	var entry := { "id": actor_id(actor), "routeGoalCell": Vector2i(0, 1) }
	var stale_action := { "cell": Vector2i(0, 1), "portalId": "door:%s" % String(setup.door.name) }
	var crossing: Dictionary = executor.request_crossing(setup.door, actor, entry, stale_action)
	var portal = setup.service.portal_for_door(setup.door)
	var both_open: bool = bool(setup.door.get_meta("open", false)) and bool(setup.secondDoor.get_meta("open", false))
	var both_clear: bool = primary_collider(setup.door).disabled and primary_collider(setup.secondDoor).disabled
	var passed: bool = bool(crossing.get("ok", false)) \
		and String(crossing.get("portalId", "")) == setup.portalId \
		and String(entry.get("activeDoorPortalId", "")) == setup.portalId \
		and portal != null \
		and portal.leaf_nodes.size() == 2 \
		and both_open \
		and both_clear
	return outcome(
		passed,
		"crossing=%s entryPortal=%s expected=%s leaves=%d" % [JSON.stringify(crossing), String(entry.get("activeDoorPortalId", "")), setup.portalId, portal.leaf_nodes.size() if portal != null else 0],
		["door_service_prefers_authoritative_portal_metadata", "stale_leaf_action_opens_all_grouped_leaves"],
		{ "crossing": crossing, "entryPortal": String(entry.get("activeDoorPortalId", "")), "expectedPortal": setup.portalId, "bothOpen": both_open, "bothClear": both_clear }
	)

func test_player_npc_shared_authority(_mode: String) -> Dictionary:
	var setup := door_setup()
	var player := make_actor("player", Vector3(0.0, 0.0, -CELL * 2.0))
	var npc := make_actor("npc-a", Vector3(0.0, 0.0, -CELL * 1.8))
	var player_open = setup.service.request_door_state(setup.door, true, player, "player", { "actors": [player, npc] })
	var npc_hold = setup.service.hold_open(setup.door, npc, "npc", { "actors": [player, npc] })
	setup.service.release_actor(setup.portalId, actor_id(player), false)
	setup.service.release_actor(setup.portalId, actor_id(npc), true)
	player.global_position.z = CELL * 2.4
	npc.global_position.z = CELL * 2.6
	var processed: Dictionary = setup.service.process(0.5, [player, npc])
	var stats: Dictionary = setup.service.stats()
	var passed: bool = succeeded(player_open) and succeeded(npc_hold) and int(stats.get("portalCount", 0)) == 1 and int(processed.get("closed", 0)) == 1
	return outcome(passed, "player=%s npc=%s processed=%s" % [summary(player_open), summary(npc_hold), JSON.stringify(processed)], ["shared_authority", "single_portal"], { "stats": stats, "processed": processed })

func test_threshold_occupied_no_close(_mode: String) -> Dictionary:
	return close_blocked_case("threshold", Vector3.ZERO, "threshold_occupied")

func test_sweep_occupied_no_close(_mode: String) -> Dictionary:
	return close_blocked_case("sweep", Vector3(0.0, 0.0, CELL * 0.95), "sweep_occupied")

func test_clearance_volume_occupied_no_close(_mode: String) -> Dictionary:
	return close_blocked_case("clearance", Vector3(0.0, 0.0, CELL * 1.35), "clearance_occupied")

func test_crossing_releases_after_sweep_clearance(_mode: String) -> Dictionary:
	var setup := door_setup()
	var npc_system = NpcSystemScript.new()
	var fake_autonomy := FakeAutonomyForDoorHold.new()
	fake_autonomy.door_portals = setup.service
	npc_system.set("autonomy_system", fake_autonomy)
	var actor := make_actor("npc-cleared-sweep", Vector3(0.0, 0.0, CELL * 1.08))
	var entry := {
		"id": actor_id(actor),
		"body": actor,
		"activeDoorDirection": "z+"
	}
	var still_needs_hold := npc_system.active_door_crossing_still_needs_hold(entry, setup.portalId)
	setup.service.request_door_state(setup.door, true, actor, "npc", { "actors": [actor] })
	setup.service.schedule_close_for_portal(setup.portalId, 0.0)
	var processed: Dictionary = setup.service.process(0.5, [actor])
	var passed: bool = not still_needs_hold and int(processed.get("blocked", 0)) == 1 and bool(setup.door.get_meta("open", false))
	npc_system.free()
	return outcome(
		passed,
		"stillNeedsHold=%s processed=%s" % [str(still_needs_hold), JSON.stringify(processed)],
		["traffic_hold_releases_after_sweep_clearance", "clearance_still_blocks_close"],
		{ "stillNeedsHold": still_needs_hold, "processed": processed, "doorOpen": setup.door.get_meta("open") }
	)

func test_arrived_route_still_holds_threshold_actor(_mode: String) -> Dictionary:
	var setup := door_setup()
	var npc_system = NpcSystemScript.new()
	var fake_autonomy := FakeAutonomyForDoorHold.new()
	fake_autonomy.door_portals = setup.service
	npc_system.set("autonomy_system", fake_autonomy)
	var actor := make_actor("npc-threshold-arrived", Vector3.ZERO)
	var entry := {
		"id": actor_id(actor),
		"body": actor,
		"activeDoorDirection": "z+",
		"activeDoorPortalId": setup.portalId,
		"routeStatus": "arrived",
		"pathWaypoints": [],
		"routeActions": {}
	}
	var still_needs_hold := npc_system.route_still_needs_active_door(entry, setup.portalId)
	npc_system.free()
	return outcome(
		still_needs_hold,
		"stillNeedsHold=%s portal=%s" % [str(still_needs_hold), setup.portalId],
		["arrived_route_does_not_release_threshold_actor", "portal_ownership_kept_until_clearance"],
		{ "stillNeedsHold": still_needs_hold, "entry": entry }
	)

func test_obstructed_closing_reopens(_mode: String) -> Dictionary:
	var setup := door_setup()
	setup.service.request_door_state(setup.door, true, null, "", {})
	var portal = setup.service.portal_for_door(setup.door)
	portal.state = NpcEnumsScript.DOOR_STATE_CLOSING
	var actor := make_actor("npc-blocker", Vector3.ZERO)
	var close = setup.service.request_door_state(setup.door, false, null, "", { "actors": [actor] })
	var passed: bool = failed_with(close, "threshold_occupied") and portal.state == NpcEnumsScript.DOOR_STATE_OPEN and bool(setup.door.get_meta("open", false))
	return outcome(passed, "close=%s portal=%s" % [summary(close), JSON.stringify(portal.to_summary())], ["obstructed_close_fails", "closing_reopens"], { "result": result_summary(close), "portal": portal.to_summary() })

func test_queue_inherits_opening(_mode: String) -> Dictionary:
	var setup := door_setup()
	var portal = setup.service.portal_for_door(setup.door)
	var first := make_actor("npc-a", Vector3(0.0, 0.0, -CELL))
	var queued := make_actor("npc-b", Vector3(0.0, 0.0, -CELL * 1.2))
	setup.service.request_door_state(setup.door, true, first, "npc", { "actors": [first, queued] })
	portal.queue(actor_id(queued), "z+")
	setup.service.release_actor(setup.portalId, actor_id(first), false)
	setup.service.schedule_close_for_portal(setup.portalId, 0.0)
	set_actor_position(first, Vector3(0.0, 0.0, CELL * 2.6))
	set_actor_position(queued, Vector3(0.0, 0.0, -CELL * 2.6))
	var processed: Dictionary = setup.service.process(0.1, [first, queued])
	var passed: bool = int(processed.get("blocked", 0)) == 1 and bool(setup.door.get_meta("open", false)) and portal.queued_actors.has(actor_id(queued))
	return outcome(passed, "processed=%s portal=%s" % [JSON.stringify(processed), JSON.stringify(portal.to_summary())], ["queued_actor_prevents_close", "opening_inherited"], { "processed": processed, "portal": portal.to_summary() })

func test_opposing_direction_ordered(_mode: String) -> Dictionary:
	var setup := door_setup()
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(setup.service)
	var a := make_actor("npc-a", Vector3(0.0, 0.0, -CELL))
	var b := make_actor("npc-b", Vector3(0.0, 0.0, CELL))
	var entry_a := { "id": "npc-a", "routeGoalCell": Vector2i(0, 2) }
	var entry_b := { "id": "npc-b", "routeGoalCell": Vector2i(0, -2) }
	var action := { "cell": Vector2i(0, 0), "portalId": setup.portalId }
	var first: Dictionary = executor.request_crossing(setup.door, a, entry_a, action)
	var second: Dictionary = executor.request_crossing(setup.door, b, entry_b, action)
	var portal = setup.service.portal_for_door(setup.door)
	var passed: bool = bool(first.get("ok", false)) and not bool(second.get("ok", true)) and String(second.get("reason", "")) == "door_reserved" and portal.queued_actors.has("npc-b")
	return outcome(passed, "first=%s second=%s portal=%s" % [JSON.stringify(first), JSON.stringify(second), JSON.stringify(portal.to_summary())], ["active_crossing_granted", "opposing_waits"], { "first": first, "second": second, "portal": portal.to_summary() })

func test_locked_authorized(_mode: String) -> Dictionary:
	var setup := door_setup({ "locked": true })
	var result = setup.service.request_door_state(setup.door, true, null, "owner", { "authorized": true })
	var passed: bool = succeeded(result) and bool(setup.door.get_meta("open", false))
	return outcome(passed, "result=%s" % summary(result), ["locked_authorized_opens"], { "result": result_summary(result) })

func test_locked_unauthorized_alternate(_mode: String) -> Dictionary:
	var setup := door_setup({ "locked": true })
	var result = setup.service.request_door_state(setup.door, true, null, "npc", {})
	var passed: bool = failed_with(result, "locked_unauthorized") and not bool(setup.door.get_meta("open", false))
	return outcome(passed, "result=%s" % summary(result), ["locked_unauthorized_denied", "route_must_alternate"], { "result": result_summary(result) })

func test_jammed_failure_or_alternate(_mode: String) -> Dictionary:
	var setup := door_setup({ "jammed": true })
	var result = setup.service.request_door_state(setup.door, true, null, "npc", {})
	var passed: bool = failed_with(result, "jammed") and not bool(setup.door.get_meta("open", false))
	return outcome(passed, "result=%s" % summary(result), ["jammed_fails", "alternate_required"], { "result": result_summary(result) })

func test_destroyed_topology_update(_mode: String) -> Dictionary:
	var setup := door_setup()
	var request = InteractionRequestScript.make(NpcEnumsScript.DOOR_COMMAND_DESTROY, setup.portalId, "admin", { "authorized": true })
	request.object_node = setup.door
	request.actor_kind = "admin"
	var result = setup.service.request_interaction(request)
	var portal = setup.service.portal_for_door(setup.door)
	var passed: bool = succeeded(result) and portal.destroyed and portal.state == NpcEnumsScript.DOOR_STATE_DESTROYED and bool(setup.door.get_meta("destroyed", false)) and primary_collider(setup.door).disabled
	return outcome(passed, "result=%s portal=%s" % [summary(result), JSON.stringify(portal.to_summary())], ["destroy_command_terminal", "collider_cleared", "topology_state_changed"], { "result": result_summary(result), "portal": portal.to_summary() })

func test_no_timeout_safety_override(_mode: String) -> Dictionary:
	var setup := door_setup()
	var actor := make_actor("player", Vector3(0.0, 0.0, CELL * 1.35))
	setup.service.request_door_state(setup.door, true, null, "", {})
	setup.service.schedule_close_for_portal(setup.portalId, 0.0)
	var last := {}
	for _i in range(24):
		last = setup.service.process(1.0, [actor])
	var passed: bool = bool(setup.door.get_meta("open", false)) and int(last.get("blocked", 0)) == 1
	return outcome(passed, "last=%s" % JSON.stringify(last), ["elapsed_time_cannot_close", "clearance_blocks_forever"], { "last": last, "doorOpen": setup.door.get_meta("open") })

func test_cancelled_actor_releases_hold(_mode: String) -> Dictionary:
	var setup := door_setup()
	var actor := make_actor("npc-a", Vector3(0.0, 0.0, -CELL))
	setup.service.request_door_state(setup.door, true, actor, "npc", { "actors": [actor] })
	setup.service.release_actor(setup.portalId, actor_id(actor), true)
	set_actor_position(actor, Vector3(0.0, 0.0, CELL * 2.4))
	var processed: Dictionary = setup.service.process(0.5, [actor])
	var passed: bool = int(processed.get("closed", 0)) == 1 and not bool(setup.door.get_meta("open", true))
	return outcome(passed, "processed=%s" % JSON.stringify(processed), ["cancel_releases_hold", "close_after_cancel"], { "processed": processed })

func test_night_civilian_enters_home(mode: String) -> Dictionary:
	var setup := door_setup({ "buildingId": "home-a" })
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(setup.service)
	var civilian := make_actor("civilian", Vector3(0.0, 0.0, -CELL * 1.4))
	var entry := { "id": "civilian", "routeGoalCell": Vector2i(0, 1), "scheduleState": "night", "homeCell": Vector2i(0, 1) }
	var result: Dictionary = executor.request_crossing(setup.door, civilian, entry, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
	set_actor_position(civilian, Vector3(0.0, 0.0, CELL * 2.2))
	executor.release_actor("civilian", true)
	var processed: Dictionary = setup.service.process(0.5, [civilian])
	var passed: bool = bool(result.get("ok", false)) and int(processed.get("closed", 0)) == 1 and String(entry.get("activeDoorPortalId", "")) == setup.portalId
	return outcome(passed, "mode=%s result=%s processed=%s" % [mode, JSON.stringify(result), JSON.stringify(processed)], ["night_civilian_uses_portal", "home_entry_releases"], { "result": result, "processed": processed, "entry": entry })

func test_night_guard_exits_for_duty(mode: String) -> Dictionary:
	var setup := door_setup({ "buildingId": "home-a" })
	var executor = DoorTraversalExecutorScript.new()
	executor.setup(setup.service)
	var guard := make_actor("guard", Vector3(0.0, 0.0, CELL * 1.4))
	var entry := { "id": "guard", "routeGoalCell": Vector2i(0, -2), "scheduleState": "night", "guardDuty": "night_guard" }
	var result: Dictionary = executor.request_crossing(setup.door, guard, entry, { "cell": Vector2i(0, 0), "portalId": setup.portalId })
	set_actor_position(guard, Vector3(0.0, 0.0, -CELL * 2.2))
	executor.release_actor("guard", true)
	var processed: Dictionary = setup.service.process(0.5, [guard])
	var passed: bool = bool(result.get("ok", false)) and int(processed.get("closed", 0)) == 1 and String(entry.get("activeDoorPortalId", "")) == setup.portalId
	return outcome(passed, "mode=%s result=%s processed=%s" % [mode, JSON.stringify(result), JSON.stringify(processed)], ["night_guard_uses_portal", "duty_exit_releases"], { "result": result, "processed": processed, "entry": entry })

func test_night_player_blocks_threshold_no_close(_mode: String) -> Dictionary:
	var setup := door_setup()
	var player := make_actor("player", Vector3.ZERO)
	setup.service.request_door_state(setup.door, true, null, "", {})
	setup.service.schedule_close_for_portal(setup.portalId, 0.0)
	var processed: Dictionary = setup.service.process(1.0, [player])
	var passed: bool = int(processed.get("blocked", 0)) == 1 and bool(setup.door.get_meta("open", false))
	return outcome(passed, "processed=%s" % JSON.stringify(processed), ["player_threshold_blocks_close"], { "processed": processed })

func test_day_worker_exit_and_return(_mode: String) -> Dictionary:
	var setup := door_setup()
	var worker := make_actor("worker", Vector3(0.0, 0.0, CELL * 1.5))
	var exit_open = setup.service.request_door_state(setup.door, true, worker, "npc", { "actors": [worker] })
	setup.service.release_actor(setup.portalId, actor_id(worker), true)
	set_actor_position(worker, Vector3(0.0, 0.0, -CELL * 2.3))
	var exit_close: Dictionary = setup.service.process(0.5, [worker])
	var return_open = setup.service.request_door_state(setup.door, true, worker, "npc", { "actors": [worker] })
	setup.service.release_actor(setup.portalId, actor_id(worker), true)
	set_actor_position(worker, Vector3(0.0, 0.0, CELL * 2.3))
	var return_close: Dictionary = setup.service.process(0.5, [worker])
	var passed: bool = succeeded(exit_open) and succeeded(return_open) and int(exit_close.get("closed", 0)) == 1 and int(return_close.get("closed", 0)) == 1
	return outcome(passed, "exit=%s return=%s" % [JSON.stringify(exit_close), JSON.stringify(return_close)], ["day_worker_exit", "day_worker_return"], { "exitClose": exit_close, "returnClose": return_close })

func close_blocked_case(volume: String, actor_position: Vector3, expected_reason: String) -> Dictionary:
	var setup := door_setup()
	setup.service.request_door_state(setup.door, true, null, "", {})
	var actor := make_actor("%s-actor" % volume, actor_position)
	var result = setup.service.request_door_state(setup.door, false, null, "", { "actors": [actor] })
	var passed: bool = failed_with(result, expected_reason) and bool(setup.door.get_meta("open", false))
	return outcome(passed, "volume=%s result=%s" % [volume, summary(result)], ["%s_blocks_close" % volume], { "result": result_summary(result), "doorOpen": setup.door.get_meta("open") })

func door_setup(options := {}) -> Dictionary:
	var service = DoorPortalServiceScript.new()
	service.setup(null, null)
	var side := int(options.get("side", 0))
	var primary_cell := Vector3i(0, 0, 0)
	var group_id := "door-group:%d,%d,%d:%d" % [primary_cell.x, primary_cell.y, primary_cell.z, side]
	var portal_id := "door:%s" % group_id
	var door := make_door(primary_cell, false, side, portal_id, group_id, options)
	service.register_door(door)
	var second_door = null
	if bool(options.get("double", false)):
		var second_cell := Vector3i(1, 0, 0) if side == 0 or side == 2 else Vector3i(0, 0, 1)
		second_door = make_door(second_cell, true, side, portal_id, group_id, options)
		service.register_door(second_door)
	return {
		"service": service,
		"door": door,
		"secondDoor": second_door,
		"portalId": portal_id
	}

func make_door(cell: Vector3i, secondary: bool, side: int, portal_id: String, group_id: String, options := {}) -> StaticBody3D:
	var door := StaticBody3D.new()
	door.name = "Door_%d_%d_%d_%d" % [cell.x, cell.y, cell.z, 1 if secondary else 0]
	if runner is Node:
		runner.add_child(door)
	door.global_position = Vector3(float(cell.x) * CELL, 0.0, float(cell.z) * CELL)
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("cell", cell)
	door.set_meta("open", bool(options.get("open", false)))
	door.set_meta("closed_rotation", 0.0)
	door.set_meta("secondary", secondary)
	door.set_meta("door_leaf_index", 1 if secondary else 0)
	door.set_meta("door_side", side)
	door.set_meta("door_group_id", group_id)
	door.set_meta("door_portal_id", portal_id)
	door.set_meta("door_building_id", String(options.get("buildingId", "")))
	door.set_meta("door_public_access", bool(options.get("publicAccess", true)))
	door.set_meta("door_policy", String(options.get("policy", "private_home")))
	door.set_meta("locked", bool(options.get("locked", false)))
	door.set_meta("jammed", bool(options.get("jammed", false)))
	door.set_meta("destroyed", bool(options.get("destroyed", false)))
	door.set_meta("unloaded", bool(options.get("unloaded", false)))
	door.set_meta("open_swing", (1.0 if secondary else -1.0) * PI * 0.5)
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16)
	collider.shape = shape
	door.add_child(collider)
	var pivot := Node3D.new()
	pivot.name = "DoorPivot"
	door.add_child(pivot)
	return door

func make_actor(id: String, position: Vector3) -> Node3D:
	var actor := CharacterBody3D.new()
	actor.name = id
	if runner is Node:
		runner.add_child(actor)
	set_actor_position(actor, position)
	actor.set_meta("npc_stable_id", id)
	return actor

func set_actor_position(actor: Node3D, position: Vector3) -> void:
	actor.position = position
	actor.global_position = position

func primary_collider(door: Node) -> CollisionShape3D:
	for child in door.get_children():
		if child is CollisionShape3D:
			return child
	return null

func actor_id(actor: Node) -> String:
	if actor == null:
		return ""
	if actor.has_meta("npc_stable_id"):
		return String(actor.get_meta("npc_stable_id"))
	return "%s:%d" % [actor.name, actor.get_instance_id()]

func succeeded(result) -> bool:
	return result != null and String(result.get("status")) == "succeeded"

func failed_with(result, reason: String) -> bool:
	return result != null and String(result.get("status")) == "failed" and String(result.get("reason")) == reason

func summary(result) -> String:
	return JSON.stringify(result_summary(result))

func result_summary(result) -> Dictionary:
	if result == null:
		return {}
	return result.to_summary() if result.has_method("to_summary") else {}

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
