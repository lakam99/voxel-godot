extends RefCounted

const SmartObjectServiceScript := preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
const NpcGoalSelectorScript := preload("res://scripts/npc_ai/behavior/NpcGoalSelector.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcProfileRulesScript := preload("res://scripts/NpcProfileRules.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const NpcSemanticGoalPlannerScript := preload("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
const CELL := 1.35

var runner = null
var transient_nodes: Array[Node] = []

class FakeForageWorld:
	extends RefCounted
	const WATER_LEVEL := -100.0

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class FakeAutonomyRelease:
	extends RefCounted
	var releases: Array[Dictionary] = []

	func release_smart_object(object_id: String, object_node: Node, _actor: Node, actor_id: String, reason := "released", metadata := {}):
		releases.append({
			"objectId": object_id,
			"objectNode": object_node,
			"actorId": actor_id,
			"reason": reason,
			"reservationId": String(metadata.get("reservationId", ""))
		})
		return null

class FakeUtilityAnchorSystem:
	extends RefCounted
	var service

	func _init(service_value) -> void:
		service = service_value

	func smart_object_service():
		return service

	func performance_monitor():
		return null

class FakeUtilityAnchorWorld:
	extends RefCounted
	var approach_calls := 0
	var standability_calls := 0
	var reject_all_standability := false
	var no_approach := false
	var approach_offset := Vector2i(0, 1)

	func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
		var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
		var radius := float(entry.get("townRadius", 18)) * CELL
		return Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL).length() <= radius

	func approach_cells_for_target(_entry: Dictionary, position: Vector3, _outside_only := false) -> Array[Vector2i]:
		approach_calls += 1
		if no_approach:
			return []
		return [Vector2i(roundi(position.x / CELL), roundi(position.z / CELL)) + approach_offset]

	func cell_position(cell: Vector2i) -> Vector3:
		return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func point_inside_work_area(_entry: Dictionary, _position: Vector3) -> bool:
		return true

	func point_allowed(entry: Dictionary, position: Vector3, allow_outside := false, _moving_home := false) -> bool:
		return allow_outside or point_inside_town(entry, position)

	func cell_is_standable_goal(_entry: Dictionary, _cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		standability_calls += 1
		return not reject_all_standability

class FakeUtilityMain:
	extends RefCounted
	const WATER_LEVEL := -100.0

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	return [
		case("npc_interaction_resource_reserved_single_user", "day", "test_resource_reserved_single_user"),
		case("npc_interaction_reservation_lifecycle_diagnostics", "day", "test_reservation_lifecycle_diagnostics"),
		case("npc_interaction_reservation_route_heartbeat_identity", "day", "test_reservation_route_heartbeat_identity"),
		case("npc_interaction_reservation_deadline_rejects_heartbeat", "day", "test_reservation_deadline_rejects_heartbeat"),
		case("npc_interaction_preferred_slot_is_capacity_authority", "day", "test_preferred_slot_is_capacity_authority"),
		case("npc_interaction_reregistration_preserves_live_slot", "day", "test_reregistration_preserves_live_slot"),
		case("npc_interaction_resource_removed_during_approach", "day", "test_resource_removed_during_approach"),
		case("npc_interaction_player_harvests_before_npc_replans", "day", "test_player_harvests_before_npc_replans"),
		case("npc_interaction_workstation_capacity", "day", "test_workstation_capacity"),
		case("npc_interaction_deposit_through_real_door", "day", "test_deposit_through_real_door"),
		case("npc_interaction_no_harvest_through_wall", "day", "test_no_harvest_through_wall"),
		case("npc_interaction_no_use_from_wrong_vertical_layer", "day", "test_no_use_from_wrong_vertical_layer"),
		case("npc_interaction_player_npc_same_availability", "day", "test_player_npc_same_availability"),
		case("npc_interaction_access_policy_shared", "day", "test_access_policy_shared"),
		case("npc_interaction_idempotent_effect", "day", "test_idempotent_effect"),
		case("npc_interaction_forager_harvest_carry_eat", "day", "test_forager_harvest_carry_eat"),
		case("npc_interaction_forager_catalog_accepts_biome_food", "day", "test_forager_catalog_accepts_biome_food"),
		case("npc_interaction_forager_work_area_is_static_target_boundary", "day", "test_forager_work_area_is_static_target_boundary"),
		case("npc_interaction_stale_registered_resource_ignored", "day", "test_stale_registered_resource_ignored"),
		case("npc_interaction_queue_free_resource_query_no_script_error", "day", "test_queue_free_resource_query_no_script_error"),
		case("npc_interaction_stale_resource_unindexed", "day", "test_stale_resource_unindexed"),
		case("npc_interaction_stale_resource_reservation_released", "day", "test_stale_resource_reservation_released"),
		case("npc_interaction_stream_unbind_is_not_depletion", "day", "test_stream_unbind_is_not_depletion"),
		case("npc_interaction_stream_rebind_restores_availability", "day", "test_stream_rebind_restores_availability"),
		case("npc_interaction_true_depletion_survives_rebind", "day", "test_true_depletion_survives_rebind"),
		case("npc_interaction_freed_job_target_release_clears_state", "day", "test_freed_job_target_release_clears_state"),
		case("npc_interaction_query_cache_invalidates_on_resource_removal", "day", "test_query_cache_invalidates_on_resource_removal"),
		case("npc_interaction_utility_anchor_index_matches_deterministic_scan", "day", "test_utility_anchor_index_matches_deterministic_scan"),
		case("npc_interaction_utility_anchor_inside_town_survives_outside_crowding", "day", "test_utility_anchor_inside_town_survives_outside_crowding"),
		case("npc_interaction_utility_anchor_limit_uses_legacy_3d_distance", "day", "test_utility_anchor_limit_uses_legacy_3d_distance"),
		case("npc_interaction_utility_anchor_moving_origin_bypasses_cache", "day", "test_utility_anchor_moving_origin_bypasses_cache"),
		case("npc_interaction_utility_query_cache_separates_actor_origins", "day", "test_utility_query_cache_separates_actor_origins"),
		case("npc_interaction_utility_query_cache_has_hard_origin_cap", "day", "test_utility_query_cache_has_hard_origin_cap"),
		case("npc_interaction_utility_query_cache_tracks_reserve_release", "day", "test_utility_query_cache_tracks_reserve_release"),
		case("npc_interaction_utility_query_scope_fingerprint_is_stateless", "day", "test_utility_query_scope_fingerprint_is_stateless"),
		case("npc_interaction_utility_anchor_index_tracks_block_lifecycle", "day", "test_utility_anchor_index_tracks_block_lifecycle"),
		case("npc_interaction_utility_anchor_selection_has_no_global_or_route_scan", "day", "test_utility_anchor_selection_has_no_global_or_route_scan"),
		case("npc_interaction_trader_fallback_incremental_parity_and_bound", "day", "test_trader_fallback_incremental_parity_and_bound"),
		case("npc_interaction_trader_fallback_scoped_invalidation", "day", "test_trader_fallback_scoped_invalidation"),
		case("npc_interaction_trader_fallback_matching_mutations_invalidate", "day", "test_trader_fallback_matching_mutations_invalidate"),
		case("npc_interaction_trader_fallback_identity_invalidation", "day", "test_trader_fallback_identity_invalidation"),
		case("npc_interaction_trader_fallback_exhaustion_liveness", "day", "test_trader_fallback_exhaustion_liveness"),
		case("npc_interaction_forager_query_after_harvest_no_crash", "day", "test_forager_query_after_harvest_no_crash"),
		case("npc_interaction_forager_live_candidate_only", "day", "test_forager_live_candidate_only"),
		case("npc_interaction_forager_reachable_approach_slot", "day", "test_forager_reachable_approach_slot"),
		case("npc_interaction_forager_no_wall_bump_on_morning_exit", "day", "test_forager_no_wall_bump_on_morning_exit"),
		case("npc_interaction_forager_target_gone_reselects", "day", "test_forager_target_gone_reselects"),
		case("npc_interaction_forager_route_blocked_marks_target_unreachable", "day", "test_forager_route_blocked_marks_target_unreachable"),
		case("npc_interaction_forager_unreachable_key_sanitizes_npc_id", "day", "test_forager_unreachable_key_sanitizes_npc_id"),
		case("npc_interaction_forager_harvest_requires_reservation_and_arrival", "day", "test_forager_harvest_requires_reservation_and_arrival"),
		case("npc_interaction_niko_full_forage_cycle_morning", "day", "test_niko_full_forage_cycle_morning"),
		case("npc_interaction_wood_worker_gather_deliver", "day", "test_wood_worker_gather_deliver"),
		case("npc_interaction_stone_worker_gather_deliver", "day", "test_stone_worker_gather_deliver"),
		case("npc_interaction_trader_day_stall_night_home", "day", "test_trader_day_stall_night_home"),
		case("npc_interaction_guard_reachable_ranged_intercept", "night", "test_guard_reachable_ranged_intercept"),
		case("npc_interaction_guard_reachable_melee_intercept", "night", "test_guard_reachable_melee_intercept"),
		case("npc_interaction_guard_no_attack_through_wall", "night", "test_guard_no_attack_through_wall"),
		case("npc_interaction_scripted_world_action", "day", "test_scripted_world_action"),
		case("npc_interaction_cancel_releases_slot", "day", "test_cancel_releases_slot"),
		case("npc_interaction_day_night_object_policy", "night", "test_day_night_object_policy")
	]

func case(id: String, mode: String, method: String) -> Dictionary:
	return {
		"id": id,
		"suite": "interaction",
		"timeModes": [mode],
		"callable": Callable(self, method)
	}

func test_resource_reserved_single_user(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("berries-1", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var first = reserve(service, object_id, prop, make_actor("npc-a", Vector3(1.4, 0.0, 0.0)), "npc-a")
	var second = reserve(service, object_id, prop, make_actor("npc-b", Vector3(-1.4, 0.0, 0.0)), "npc-b")
	var passed: bool = succeeded(first) and failed_reason(second, "capacity_busy")
	return outcome(passed, "first=%s second=%s" % [summary(first), summary(second)], ["single_capacity_owner", "second_user_busy"], state(service))

func test_reservation_lifecycle_diagnostics(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("reservation-diagnostics", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var owner := make_actor("diagnostic-owner", Vector3(CELL * 1.05, 0.0, 0.0))
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, "diagnostic-owner", {
		"action": "harvest_resource",
		"actorKind": "npc",
		"routeRequestId": "route-request-42",
		"routeGeneration": 7,
		"goalKey": "forage|outbound|reservation-diagnostics"
	})
	request.object_node = prop
	request.actor_node = owner
	request.actor_kind = "npc"
	var reserved = service.request_interaction(request)
	var contender = reserve(service, object_id, prop, make_actor("diagnostic-contender", Vector3(-CELL * 1.05, 0.0, 0.0)), "diagnostic-contender")
	var active_debug: Dictionary = service.reservation_debug(object_id, "diagnostic-owner")
	var active_rows: Array = active_debug.get("reservations", []) if active_debug.get("reservations", []) is Array else []
	var active: Dictionary = active_rows[0] if not active_rows.is_empty() and active_rows[0] is Dictionary else {}
	var busy_rows: Array = contender.metrics.get("ownerReservations", []) if contender != null and contender.metrics.get("ownerReservations", []) is Array else []
	var released = release(service, object_id, prop, owner, "diagnostic-owner", reserved)
	var released_debug: Dictionary = service.reservation_debug(object_id, "diagnostic-owner")
	var last_release: Dictionary = released_debug.get("lastRelease", {}) if released_debug.get("lastRelease", {}) is Dictionary else {}
	var passed := succeeded(reserved) \
		and failed_reason(contender, "capacity_busy") \
		and active_rows.size() == 1 \
		and busy_rows.size() == 1 \
		and String(active.get("routeRequestId", "")) == "route-request-42" \
		and int(active.get("routeGeneration", 0)) == 7 \
		and active.has("createdPhysicsFrame") \
		and active.has("ageFrames") \
		and succeeded(released) \
		and (released_debug.get("reservations", []) as Array).is_empty() \
		and String(last_release.get("releaseReason", "")) == "cancel"
	return outcome(passed, "active=%s busy=%s release=%s" % [JSON.stringify(active_debug), summary(contender), JSON.stringify(released_debug)], ["reservation_owner_age_visible", "capacity_busy_names_owner_reservation", "release_reason_retained"], state(service))

func test_reservation_route_heartbeat_identity(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("reservation-heartbeat", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var owner := make_actor("heartbeat-owner", Vector3(CELL * 1.05, 0.0, 0.0))
	var reserved = reserve(service, object_id, prop, owner, "heartbeat-owner")
	var reservation_id := String(reserved.metrics.get("reservationId", ""))
	var first: Dictionary = service.heartbeat_reservation(object_id, reservation_id, "heartbeat-owner", {
		"slotId": String(reserved.metrics.get("slotId", "")),
		"routeRequestId": "heartbeat-owner:v2:4:1",
		"routeGeneration": 4,
		"goalKey": "forage|outbound|%s" % object_id
	})
	var stale: Dictionary = service.heartbeat_reservation(object_id, reservation_id, "heartbeat-owner", {
		"slotId": String(reserved.metrics.get("slotId", "")),
		"routeRequestId": "heartbeat-owner:v2:3:9",
		"routeGeneration": 3,
		"goalKey": "forage|outbound|%s" % object_id
	})
	var replacement: Dictionary = service.heartbeat_reservation(object_id, reservation_id, "heartbeat-owner", {
		"slotId": String(reserved.metrics.get("slotId", "")),
		"routeRequestId": "heartbeat-owner:v2:5:2",
		"routeGeneration": 5,
		"goalKey": "forage|outbound|%s" % object_id
	})
	var debug: Dictionary = service.reservation_debug(object_id, "heartbeat-owner")
	var rows: Array = debug.get("reservations", []) if debug.get("reservations", []) is Array else []
	var active: Dictionary = rows[0] if not rows.is_empty() and rows[0] is Dictionary else {}
	var passed := succeeded(reserved) \
		and bool(first.get("ok", false)) \
		and not bool(stale.get("ok", true)) \
		and String(stale.get("reason", "")) == "stale_route_generation" \
		and bool(replacement.get("ok", false)) \
		and String(active.get("routeRequestId", "")) == "heartbeat-owner:v2:5:2" \
		and int(active.get("routeGeneration", 0)) == 5
	return outcome(passed, "first=%s stale=%s replacement=%s active=%s" % [JSON.stringify(first), JSON.stringify(stale), JSON.stringify(replacement), JSON.stringify(active)], ["heartbeat_binds_route_identity", "older_generation_rejected", "newer_generation_rebinds"], state(service))

func test_reservation_deadline_rejects_heartbeat(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("reservation-deadline", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var owner := make_actor("deadline-owner", Vector3(CELL * 1.05, 0.0, 0.0))
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, "deadline-owner", {
		"action": "harvest_resource",
		"actorKind": "npc",
		"maxReservationAgeSeconds": 45.0
	})
	request.object_node = prop
	request.actor_node = owner
	request.actor_kind = "npc"
	var reserved = service.request_interaction(request)
	var reservation_id := String(reserved.metrics.get("reservationId", ""))
	var registration = service.registrations.get(object_id)
	var reservation: Dictionary = registration.reservations.get(reservation_id, {})
	reservation["deadlinePhysicsFrame"] = Engine.get_physics_frames()
	registration.reservations[reservation_id] = reservation
	var heartbeat: Dictionary = service.heartbeat_reservation(object_id, reservation_id, "deadline-owner", {
		"slotId": String(reserved.metrics.get("slotId", "")),
		"routeRequestId": "deadline-owner:v2:1:1",
		"routeGeneration": 1,
		"goalKey": "forage|outbound|%s" % object_id
	})
	var debug: Dictionary = service.reservation_debug(object_id, "deadline-owner")
	var available: Dictionary = service.object_available(object_id, "other-forager")
	var last_release: Dictionary = debug.get("lastRelease", {}) if debug.get("lastRelease", {}) is Dictionary else {}
	var passed := succeeded(reserved) \
		and not bool(heartbeat.get("ok", true)) \
		and String(heartbeat.get("reason", "")) == "reservation_deadline" \
		and (debug.get("reservations", []) as Array).is_empty() \
		and String(last_release.get("releaseReason", "")) == "reservation_deadline" \
		and bool(available.get("ok", false))
	return outcome(passed, "heartbeat=%s debug=%s available=%s" % [JSON.stringify(heartbeat), JSON.stringify(debug), JSON.stringify(available)], ["absolute_deadline_beats_heartbeat", "deadline_releases_slot", "deadline_restores_availability"], state(service))

func test_preferred_slot_is_capacity_authority(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("preferred-slot", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop, { "slots": two_test_slots(Vector3.ZERO, Vector3(CELL, 0.0, 0.0)) })
	var actor := make_actor("preferred-owner", Vector3(CELL, 0.0, 0.0))
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, "preferred-owner", {
		"action": "harvest_resource",
		"actorKind": "npc",
		"preferredSlotId": "slot:1"
	})
	request.object_node = prop
	request.actor_node = actor
	request.actor_kind = "npc"
	var reserved = service.request_interaction(request)
	var passed := succeeded(reserved) and String(reserved.metrics.get("slotId", "")) == "slot:1"
	return outcome(passed, summary(reserved), ["preferred_slot_selected_exactly", "smart_object_remains_capacity_authority"], state(service))

func test_reregistration_preserves_live_slot(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("reregister-slot", "berryBush", "berries", 2, Vector3.ZERO)
	var original_position := Vector3(CELL, 0.0, 0.0)
	var object_id: String = service.register_resource(prop, { "slots": two_test_slots(Vector3.ZERO, original_position) })
	var actor := make_actor("reregister-owner", original_position)
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, "reregister-owner", {
		"action": "harvest_resource",
		"actorKind": "npc",
		"preferredSlotId": "slot:1"
	})
	request.object_node = prop
	request.actor_node = actor
	request.actor_kind = "npc"
	var reserved = service.request_interaction(request)
	service.register_resource(prop, { "slots": two_test_slots(Vector3(CELL * 3.0, 0.0, 0.0), Vector3(CELL * 4.0, 0.0, 0.0)) })
	var debug: Dictionary = service.reservation_debug(object_id, "reregister-owner")
	var rows: Array = debug.get("reservations", []) if debug.get("reservations", []) is Array else []
	var active: Dictionary = rows[0] if not rows.is_empty() and rows[0] is Dictionary else {}
	var current_position := summary_vector(active.get("approachPosition", []))
	var passed := succeeded(reserved) \
		and String(active.get("slotId", "")) == "slot:1" \
		and current_position.is_equal_approx(original_position) \
		and not bool(active.get("slotGeometryChanged", true))
	return outcome(passed, "reserved=%s active=%s" % [summary(reserved), JSON.stringify(active)], ["live_slot_not_moved_on_reregistration", "live_reservation_not_orphaned"], state(service))

func two_test_slots(first_position: Vector3, second_position: Vector3) -> Dictionary:
	return {
		"slot:0": { "slotId": "slot:0", "position": first_position, "capacity": 1, "occupants": [] },
		"slot:1": { "slotId": "slot:1", "position": second_position, "capacity": 1, "occupants": [] }
	}

func summary_vector(value) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.INF

func test_resource_removed_during_approach(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("berries-removed", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("npc-a", Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "npc-a")
	service.notify_object_removed(object_id, prop)
	var completed = complete(service, object_id, prop, actor, "npc-a", first)
	var reason := String(completed.reason)
	var passed: bool = succeeded(first) and reason == "resource_depleted"
	return outcome(passed, "complete=%s" % summary(completed), ["removed_invalidates_reservation", "explicit_removal_is_resource_depleted"], state(service))

func test_player_harvests_before_npc_replans(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("berries-player", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var player := make_actor("player", Vector3(1.4, 0.0, 0.0))
	var player_result = harvest(service, object_id, prop, player, "player", "player")
	var npc_result = reserve(service, object_id, prop, make_actor("npc-a", Vector3(-1.4, 0.0, 0.0)), "npc-a")
	var passed: bool = succeeded(player_result) and bool(player_result.metrics.get("effectApplied", false)) and failed_reason(npc_result, "resource_depleted")
	return outcome(passed, "player=%s npc=%s" % [summary(player_result), summary(npc_result)], ["player_effect_once", "npc_target_depleted"], state(service))

func test_workstation_capacity(_mode: String) -> Dictionary:
	var service = make_service()
	var station := make_block("workbench", Vector3.ZERO)
	var object_id: String = service.register_workstation(station, { "capacity": 1 })
	var first = reserve(service, object_id, station, make_actor("npc-a", Vector3(0.0, 0.0, 1.4)), "npc-a", "use_workbench")
	var second = reserve(service, object_id, station, make_actor("npc-b", Vector3(0.0, 0.0, -1.4)), "npc-b", "use_workbench")
	return outcome(succeeded(first) and failed_reason(second, "capacity_busy"), "first=%s second=%s" % [summary(first), summary(second)], ["workstation_capacity_one"], state(service))

func test_deposit_through_real_door(_mode: String) -> Dictionary:
	var service = make_service()
	var actor := make_actor("npc-a", Vector3(0.0, 0.0, 1.2))
	var closed_id: String = service.register_anchor("deposit:closed", "storage", Vector3.ZERO, {
		"blockers": [AABB(Vector3(-0.4, -0.2, 0.45), Vector3(0.8, 1.8, 0.25))]
	})
	var closed = use_object(service, closed_id, null, actor, "npc-a", "deposit_inventory", "deposit-closed")
	var open_id: String = service.register_anchor("deposit:open", "storage", Vector3.ZERO, {})
	var open = use_object(service, open_id, null, actor, "npc-a", "deposit_inventory", "deposit-open")
	return outcome(failed_reason(closed, "line_of_sight_blocked") and succeeded(open), "closed=%s open=%s" % [summary(closed), summary(open)], ["closed_door_blocks_deposit", "open_door_allows_deposit"], state(service))

func test_no_harvest_through_wall(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("wall-berries", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop, {
		"blockers": [AABB(Vector3(0.45, -0.2, -0.4), Vector3(0.25, 1.8, 0.8))]
	})
	var actor := make_actor("npc-a", Vector3(1.3, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "npc-a")
	var completed = complete(service, object_id, prop, actor, "npc-a", first)
	return outcome(failed_reason(completed, "line_of_sight_blocked"), "complete=%s" % summary(completed), ["wall_blocks_resource_effect"], state(service))

func test_no_use_from_wrong_vertical_layer(_mode: String) -> Dictionary:
	var service = make_service()
	var station := make_block("furnace", Vector3.ZERO)
	var object_id: String = service.register_workstation(station)
	var actor := make_actor("npc-a", Vector3(0.0, 3.4, 1.2))
	var first = reserve(service, object_id, station, actor, "npc-a", "use_furnace")
	var completed = use_object(service, object_id, station, actor, "npc-a", "use_furnace", "wrong-floor", first)
	return outcome(succeeded(first) and failed_reason(completed, "wrong_vertical_layer"), "complete=%s" % summary(completed), ["wrong_floor_rejected"], state(service))

func test_player_npc_same_availability(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("shared-berries", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var player := make_actor("player", Vector3(1.4, 0.0, 0.0))
	var npc := make_actor("npc-a", Vector3(-1.4, 0.0, 0.0))
	var player_reserve = reserve(service, object_id, prop, player, "player", "harvest_resource", "player")
	var npc_busy = reserve(service, object_id, prop, npc, "npc-a")
	release(service, object_id, prop, player, "player", player_reserve, "player")
	var npc_after = reserve(service, object_id, prop, npc, "npc-a")
	return outcome(succeeded(player_reserve) and failed_reason(npc_busy, "capacity_busy") and succeeded(npc_after), "busy=%s after=%s" % [summary(npc_busy), summary(npc_after)], ["player_npc_share_availability"], state(service))

func test_access_policy_shared(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("policy-berries", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop, { "allowedActorKinds": ["npc"] })
	var player_result = reserve(service, object_id, prop, make_actor("player", Vector3(1.4, 0.0, 0.0)), "player", "harvest_resource", "player")
	var npc_result = reserve(service, object_id, prop, make_actor("npc-a", Vector3(-1.4, 0.0, 0.0)), "npc-a", "harvest_resource", "npc")
	return outcome(failed_reason(player_result, "access_denied") and succeeded(npc_result), "player=%s npc=%s" % [summary(player_result), summary(npc_result)], ["shared_access_policy"], state(service))

func test_idempotent_effect(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("idem-berries", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("npc-a", Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "npc-a")
	var once = complete(service, object_id, prop, actor, "npc-a", first, "idem-request")
	var twice = complete(service, object_id, prop, actor, "npc-a", first, "idem-request")
	return outcome(succeeded(once) and succeeded(twice) and bool(once.metrics.get("effectApplied", false)) and not bool(twice.metrics.get("effectApplied", true)), "once=%s twice=%s" % [summary(once), summary(twice)], ["effect_once", "idempotent_replay_no_effect"], state(service))

func test_forager_harvest_carry_eat(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("forager-berries", "berryBush", "berries", 3, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("forager", Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "forager")
	var completed = complete(service, object_id, prop, actor, "forager", first)
	var hunger := 42.0
	if succeeded(completed):
		hunger = minf(100.0, hunger + 24.0)
	var passed: bool = succeeded(completed) and String(completed.metrics.get("drop", "")) == "berries" and int(completed.metrics.get("amount", 0)) == 3 and hunger > 42.0
	return outcome(passed, "complete=%s hunger=%.1f" % [summary(completed), hunger], ["forager_harvests_berries", "forager_can_eat_carried_food"], state(service))

func test_forager_catalog_accepts_biome_food(_mode: String) -> Dictionary:
	var service = make_service()
	var resources := [
		make_prop("forager-berries", "berryBush", "berries", 1, Vector3(12.0, 0.0, 0.0)),
		make_prop("forager-aloe", "aloePatch", "aloe", 1, Vector3(13.35, 0.0, 0.0)),
		make_prop("forager-mirecap", "mushroomCluster", "mirecap", 1, Vector3(14.7, 0.0, 0.0)),
		make_prop("forager-frost-herb", "frostHerbPatch", "frostHerb", 1, Vector3(16.05, 0.0, 0.0))
	]
	for resource in resources:
		service.register_resource(resource)
	var npc_system := track_transient_node(NpcSystemScript.new()) as NpcSystem
	var entry := make_query_entry()
	var options: Dictionary = npc_system.resource_query_options_for_job(entry, "forage")
	options["cacheFrames"] = 0
	var queried: Array[Node3D] = service.query_resource_nodes(entry, ["forage_source"], options)
	var queried_drops: Array[String] = []
	for node in queried:
		queried_drops.append(String(node.get_meta("drop", "")))
	queried_drops.sort()
	var expected := npc_system.forage_food_item_ids()
	var consumed: Dictionary = npc_system.consume_forage_food({ "personalInventory": { "aloe": 1 } }, "aloe")
	var passed := expected == ["aloe", "berries", "frostHerb", "mirecap"] \
		and queried_drops == expected \
		and bool(consumed.get("ok", false)) \
		and String(consumed.get("itemId", "")) == "aloe" \
		and int(consumed.get("food", 0)) == 6
	return outcome(passed, "expected=%s queried=%s consumed=%s" % [JSON.stringify(expected), JSON.stringify(queried_drops), JSON.stringify(consumed)], ["forager_queries_catalog_forage_food", "savanna_aloe_is_forage_target", "forager_consumes_catalog_food"], state(service))

func test_forager_work_area_is_static_target_boundary(_mode: String) -> Dictionary:
	var npc_system := track_transient_node(NpcSystemScript.new()) as NpcSystem
	if runner is Node:
		(runner as Node).add_child(npc_system)
	npc_system.main = FakeForageWorld.new()
	var entry := make_query_entry()
	entry["homePosition"] = Vector3(-CELL * 4.0, 0.0, 0.0)
	entry["porchPosition"] = entry["homePosition"]
	var prop := make_prop("forager-work-area", "aloePatch", "aloe", 1, Vector3(CELL * 27.0, 0.0, 0.0))
	npc_system.add_child(prop)
	var in_work_area := npc_system.point_inside_work_area(entry, prop.global_position)
	var outside_town := not npc_system.point_inside_town_footprint(entry, prop.global_position, 3)
	var valid := npc_system.is_valid_forage_node(prop, entry)
	var passed := in_work_area and outside_town and valid
	return outcome(
		passed,
		"inWorkArea=%s outsideTown=%s valid=%s" % [str(in_work_area), str(outside_town), str(valid)],
		["forager_work_area_is_single_static_target_boundary", "home_distance_does_not_reject_live_forage", "collision_route_remains_separate_authority"],
		{ "inWorkArea": in_work_area, "outsideTown": outside_town, "valid": valid }
	)

func test_stale_registered_resource_ignored(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("stale-ignored", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var before: Array[Node3D] = query_forage_nodes(service)
	prop.free()
	var after: Array[Node3D] = query_forage_nodes(service)
	var availability: Dictionary = service.object_available(object_id, "forager")
	var passed: bool = before.size() == 1 and after.is_empty() and String(availability.get("reason", "")) == "target_gone"
	return outcome(passed, "before=%d after=%d availability=%s" % [before.size(), after.size(), JSON.stringify(availability)], ["stale_resource_skipped", "temporary_absence_is_target_gone_not_depleted", "query_continues_after_stale_node"], state(service))

func test_queue_free_resource_query_no_script_error(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("freed-query", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	service.register_resource(prop)
	prop.free()
	var first: Array[Node3D] = query_forage_nodes(service)
	var second: Array[Node3D] = query_forage_nodes(service)
	var passed: bool = first.is_empty() and second.is_empty()
	return outcome(passed, "first=%d second=%d" % [first.size(), second.size()], ["freed_node_query_no_result", "repeat_query_no_script_error"], state(service))

func test_stale_resource_unindexed(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("stale-unindexed", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var indexed_before: bool = index_contains(service.get("available_index_by_kind"), "forage_source", object_id)
	prop.free()
	query_forage_nodes(service)
	var indexed_after: bool = index_contains(service.get("available_index_by_kind"), "forage_source", object_id)
	var depleted_indexed: bool = index_contains(service.get("depleted_index_by_kind"), "forage_source", object_id)
	var passed: bool = indexed_before and not indexed_after and not depleted_indexed
	return outcome(passed, "indexedBefore=%s indexedAfter=%s depletedIndexed=%s" % [str(indexed_before), str(indexed_after), str(depleted_indexed)], ["stale_removed_from_available_index", "stale_removed_from_depleted_index"], state(service))

func test_stale_resource_reservation_released(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("stale-reservation", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("forager", Vector3(12.0, 0.0, 1.4))
	var first = reserve(service, object_id, prop, actor, "forager")
	var before: int = int(service.owner_reservation_count("forager"))
	prop.free()
	query_forage_nodes(service)
	var after: int = int(service.owner_reservation_count("forager"))
	var passed: bool = succeeded(first) and before == 1 and after == 0
	return outcome(passed, "reserve=%s before=%d after=%d" % [summary(first), before, after], ["stale_resource_releases_owner_reservation"], state(service))

func test_stream_unbind_is_not_depletion(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := attach_to_runner(make_prop("stream-unbind", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0)))
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("generic-forager", Vector3(12.0, 0.0, CELL))
	var reserved = reserve(service, object_id, prop, actor, "generic-forager")
	if prop.get_parent() != null:
		prop.get_parent().remove_child(prop)
	var debug: Dictionary = service.reservation_debug(object_id, "generic-forager")
	var availability: Dictionary = service.object_available(object_id, "generic-forager")
	var available_indexed := index_contains(service.get("available_index_by_kind"), "forage_source", object_id)
	var depleted_indexed := index_contains(service.get("depleted_index_by_kind"), "forage_source", object_id)
	var passed := succeeded(reserved) \
		and not bool(debug.get("depleted", true)) \
		and (debug.get("reservations", []) as Array).is_empty() \
		and String(availability.get("reason", "")) == "target_gone" \
		and not available_indexed \
		and not depleted_indexed
	return outcome(passed, "reserved=%s debug=%s availability=%s availableIndexed=%s depletedIndexed=%s" % [summary(reserved), JSON.stringify(debug), JSON.stringify(availability), str(available_indexed), str(depleted_indexed)], ["stream_unbind_releases_reservation", "stream_unbind_is_not_depletion", "unbound_resource_is_not_queryable"], state(service))

func test_stream_rebind_restores_availability(_mode: String) -> Dictionary:
	var service = make_service()
	var original := attach_to_runner(make_prop("stream-rebind", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0)))
	var object_id: String = service.register_resource(original)
	if original.get_parent() != null:
		original.get_parent().remove_child(original)
	var replacement := attach_to_runner(make_prop("stream-rebind", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0)))
	var rebound_id: String = service.register_resource(replacement)
	var availability: Dictionary = service.object_available(object_id, "generic-forager")
	var queried: Array[Node3D] = service.query_resource_nodes(make_query_entry(), ["forage_source"], {
		"drops": ["aloe"],
		"limit": 8,
		"cacheFrames": 0
	})
	var debug: Dictionary = service.reservation_debug(object_id, "generic-forager")
	var passed := rebound_id == object_id \
		and bool(availability.get("ok", false)) \
		and not bool(debug.get("depleted", true)) \
		and queried.size() == 1 \
		and queried[0] == replacement
	return outcome(passed, "objectId=%s reboundId=%s availability=%s debug=%s queried=%d" % [object_id, rebound_id, JSON.stringify(availability), JSON.stringify(debug), queried.size()], ["stable_resource_id_rebound", "stream_rebind_restores_availability", "rebound_resource_returns_to_forage_index"], state(service))

func test_true_depletion_survives_rebind(_mode: String) -> Dictionary:
	var service = make_service()
	var original := attach_to_runner(make_prop("depleted-rebind", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0)))
	var object_id: String = service.register_resource(original)
	var actor := make_actor("player", Vector3(12.0, 0.0, CELL))
	var harvested = harvest(service, object_id, original, actor, "player", "player")
	if original.get_parent() != null:
		original.get_parent().remove_child(original)
	var replacement := attach_to_runner(make_prop("depleted-rebind", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0)))
	service.register_resource(replacement)
	var availability: Dictionary = service.object_available(object_id, "generic-forager")
	var queried: Array[Node3D] = service.query_resource_nodes(make_query_entry(), ["forage_source"], {
		"drops": ["aloe"],
		"limit": 8,
		"cacheFrames": 0
	})
	var passed := succeeded(harvested) \
		and String(availability.get("reason", "")) == "resource_depleted" \
		and queried.is_empty()
	return outcome(passed, "harvested=%s availability=%s queried=%d" % [summary(harvested), JSON.stringify(availability), queried.size()], ["true_depletion_is_durable_in_service", "depleted_rebind_cannot_duplicate_reward", "depleted_resource_stays_out_of_forage_index"], state(service))

func test_freed_job_target_release_clears_state(_mode: String) -> Dictionary:
	var npc_system := track_transient_node(NpcSystemScript.new()) as NpcSystem
	var autonomy := FakeAutonomyRelease.new()
	npc_system.autonomy_system = autonomy
	var target := make_prop("freed-job-target", "aloePatch", "aloe", 1, Vector3(12.0, 0.0, 0.0))
	var entry := {
		"id": "generic-forager",
		"jobTargetNode": target,
		"jobObjectId": "prop:freed-job-target",
		"jobReservationId": "reservation:freed-job-target",
		"jobApproachSlotId": "slot:0",
		"forageReservationStartedPhysicsFrame": 1,
		"forageReservationElapsedSeconds": 2.0
	}
	target.free()
	npc_system.release_job_reservation(entry, "target_streamed_out")
	var cleared := String(entry.get("jobObjectId", "")) == "" \
		and String(entry.get("jobReservationId", "")) == "" \
		and String(entry.get("jobApproachSlotId", "")) == "" \
		and not entry.has("forageReservationStartedPhysicsFrame") \
		and not entry.has("forageReservationElapsedSeconds")
	var passed := cleared and autonomy.releases.size() == 1 and autonomy.releases[0].get("objectNode") == null
	return outcome(passed, "cleared=%s releases=%s" % [str(cleared), JSON.stringify(autonomy.releases)], ["freed_target_never_type_checked", "release_uses_stable_object_id_without_live_node", "job_reservation_state_cleared"], {"entry": entry.duplicate(true), "releases": autonomy.releases.duplicate(true)})

func test_query_cache_invalidates_on_resource_removal(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("cache-removal", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var before: Array[Node3D] = query_forage_nodes(service)
	var cache_before: Dictionary = service.get("query_cache").duplicate(true)
	service.notify_object_removed(object_id, "test_removed")
	var cache_after_remove: Dictionary = service.get("query_cache").duplicate(true)
	var after: Array[Node3D] = query_forage_nodes(service)
	var passed: bool = before.size() == 1 and cache_before.size() > 0 and cache_after_remove.is_empty() and after.is_empty()
	return outcome(passed, "before=%d cacheBefore=%d cacheAfterRemove=%d after=%d" % [before.size(), cache_before.size(), cache_after_remove.size(), after.size()], ["query_cache_populated", "query_cache_invalidated_on_removal", "removed_resource_not_returned"], state(service))

func test_utility_anchor_index_matches_deterministic_scan(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), null, world, null)
	var body := attach_to_runner(make_actor("utility-query-actor", Vector3.ZERO))
	var entry := {
		"id": "utility-query-actor",
		"job": "trade",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 8,
		"porchPosition": Vector3.ZERO
	}
	var blocks: Array[Node3D] = [
		attach_to_runner(make_block("traderStall", Vector3(-CELL * 2.0, 0.0, 0.0))),
		attach_to_runner(make_block("chest", Vector3(CELL * 2.0, 0.0, 0.0))),
		attach_to_runner(make_block("workbench", Vector3(CELL * 3.0, 0.0, 0.0))),
		attach_to_runner(make_block("furnace", Vector3(CELL * 4.0, 0.0, 0.0))),
		attach_to_runner(make_block("bed", Vector3(CELL * 5.0, 0.0, 0.0))),
		attach_to_runner(make_block("campfire", Vector3(CELL * 6.0, 0.0, 0.0))),
		attach_to_runner(make_block("anvil", Vector3(CELL * 7.0, 0.0, 0.0))),
		attach_to_runner(make_block("chest", Vector3(CELL * 10.0, 0.0, 0.0)))
	]
	for index in range(blocks.size() - 1, -1, -1):
		service.register_workstation(blocks[index])
	var actual: Array[Vector3] = [Vector3.ZERO]
	planner.add_utility_anchor_candidates(actual, entry)
	var expected: Array[Vector3] = [Vector3.ZERO]
	expected.append_array(legacy_utility_anchor_candidates(blocks, entry, world, body.global_position))
	var debug: Dictionary = entry.get("lastUtilityAnchorDebug", {})
	var passed := actual == expected \
		and actual.size() == 8 \
		and actual[1].x < actual[2].x \
		and int(debug.get("indexedReturned", -1)) == 7 \
		and int(debug.get("acceptedUtilityNodes", -1)) == 7 \
		and int(debug.get("appendedApproachCandidates", -1)) == 7 \
		and int(debug.get("totalCandidatesAfter", -1)) == 8
	return outcome(passed, "actual=%s expected=%s debug=%s" % [JSON.stringify(actual), JSON.stringify(expected), JSON.stringify(debug)], ["indexed_candidates_match_legacy_town_and_approach_semantics", "distance_then_stable_object_id_order", "all_utility_kinds_share_authoritative_index"], state(service))

func test_utility_anchor_inside_town_survives_outside_crowding(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), null, world, null)
	var entry := {
		"id": "crowding-trader",
		"job": "trade",
		"townCenter": Vector2i.ZERO,
		"townRadius": 4,
		"porchPosition": Vector3.ZERO
	}
	var outside_count := 0
	for x in range(-20, 21):
		for z in range(-20, 21):
			if outside_count >= 70:
				break
			var radius := Vector2(float(x), float(z)).length()
			if radius <= 5.0 or radius > 20.0:
				continue
			var block := attach_to_runner(make_block("chest", Vector3(float(x) * CELL, 0.0, float(z) * CELL)))
			service.register_workstation(block)
			outside_count += 1
		if outside_count >= 70:
			break
	var inside_nodes: Array[Node3D] = [
		attach_to_runner(make_block("traderStall", Vector3(-CELL, 0.0, 0.0))),
		attach_to_runner(make_block("workbench", Vector3(CELL, 0.0, 0.0))),
		attach_to_runner(make_block("bed", Vector3(0.0, 0.0, CELL)))
	]
	for node in inside_nodes:
		service.register_workstation(node)
	var actual: Array[Vector3] = []
	planner.add_utility_anchor_candidates(actual, entry)
	var debug: Dictionary = entry.get("lastUtilityAnchorDebug", {})
	var passed := outside_count == 70 \
		and actual.size() == 3 \
		and int(debug.get("indexedReturned", -1)) == 3 \
		and int(debug.get("acceptedUtilityNodes", -1)) == 3 \
		and int(debug.get("appendedApproachCandidates", -1)) == 3 \
		and int(debug.get("totalCandidatesAfter", -1)) == 3
	return outcome(passed, "outside=%d actual=%s debug=%s" % [outside_count, JSON.stringify(actual), JSON.stringify(debug)], ["inside_town_filter_applies_before_query_limit", "outside_town_utilities_cannot_crowd_valid_anchors", "spatial_query_remains_bounded"], state(service))

func test_utility_anchor_limit_uses_legacy_3d_distance(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), null, world, null)
	var entry := {
		"id": "multilevel-trader",
		"job": "trade",
		"townCenter": Vector2i.ZERO,
		"townRadius": 20,
		"porchPosition": Vector3.ZERO
	}
	for index in range(70):
		var high_block := attach_to_runner(make_block("workbench", Vector3(0.0, CELL * float(100 + index), 0.0)))
		service.register_workstation(high_block)
	var ground_nearest := attach_to_runner(make_block("traderStall", Vector3(CELL * 10.0, 0.0, 0.0)))
	service.register_workstation(ground_nearest)
	var actual: Array[Vector3] = []
	planner.add_utility_anchor_candidates(actual, entry)
	var expected_first := world.cell_position(Vector2i(10, 1))
	var debug: Dictionary = entry.get("lastUtilityAnchorDebug", {})
	var passed := not actual.is_empty() \
		and actual[0].is_equal_approx(expected_first) \
		and int(debug.get("indexedReturned", -1)) == 64 \
		and int(debug.get("acceptedUtilityNodes", -1)) == 64
	return outcome(passed, "first=%s expected=%s debug=%s" % [str(actual[0] if not actual.is_empty() else Vector3.INF), str(expected_first), JSON.stringify(debug)], ["service_applies_3d_distance_before_limit", "vertical_decoys_do_not_crowd_legacy_nearest", "stable_id_tie_break_remains_deterministic"], state(service))

func test_utility_anchor_moving_origin_bypasses_cache(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), null, world, null)
	var station := attach_to_runner(make_block("workbench", Vector3(CELL * 3.0, 0.0, 0.0)))
	service.register_workstation(station)
	var body := attach_to_runner(make_actor("moving-trader", Vector3.ZERO))
	var entry := { "id": "moving-trader", "job": "trade", "body": body, "townCenter": Vector2i.ZERO, "townRadius": 20, "porchPosition": Vector3.ZERO }
	var fallback_options := {
		"limit": 64,
		"outsideTown": false,
		"insideTownOnly": true,
		"workAreaOnly": true,
		"collectAllSpatialMatches": true,
		"distanceMode": "3d",
		"bypassCache": true
	}
	var seeded_key: String = service.query_cache_key(entry, ["trader_stall", "workstation", "storage", "bed"], fallback_options, body.global_position)
	var cache: Dictionary = service.get("query_cache")
	cache[seeded_key] = {
		"revision": int(service.get("revision_counter")),
		"frame": Engine.get_process_frames(),
		"objectIds": [],
		"sentinel": "must_remain_untouched"
	}
	var nonempty_queries := 0
	for index in range(24):
		body.position = Vector3(float(index) * 0.05, 0.0, 0.0)
		var candidates: Array[Vector3] = []
		planner.add_utility_anchor_candidates(candidates, entry)
		if not candidates.is_empty():
			nonempty_queries += 1
	var seeded_after: Dictionary = cache.get(seeded_key, {})
	var passed := nonempty_queries == 24 \
		and cache.size() == 1 \
		and String(seeded_after.get("sentinel", "")) == "must_remain_untouched" \
		and (seeded_after.get("objectIds", []) as Array).is_empty()
	return outcome(passed, "queries=%d cache=%d seeded=%s" % [nonempty_queries, cache.size(), JSON.stringify(seeded_after)], ["matching_stale_cache_entry_is_ignored", "moving_fallback_queries_remain_exact", "fallback_explicitly_bypasses_shared_cache", "repeated_origins_leave_cache_unchanged"], state(service))

func test_utility_query_cache_separates_actor_origins(_mode: String) -> Dictionary:
	var service = make_service()
	var left := attach_to_runner(make_block("workbench", Vector3(-CELL * 2.0, 0.0, 0.0)))
	var right := attach_to_runner(make_block("workbench", Vector3(CELL * 2.0, 0.0, 0.0)))
	service.register_workstation(left)
	service.register_workstation(right)
	var options := { "limit": 1, "outsideTown": false, "insideTownOnly": true, "workAreaOnly": true, "collectAllSpatialMatches": true, "cacheFrames": 60 }
	var left_entry := { "id": "left-npc", "townCenter": Vector2i.ZERO, "townRadius": 8, "porchPosition": Vector3(-CELL * 4.0, 0.0, 0.0) }
	var right_entry := { "id": "right-npc", "townCenter": Vector2i.ZERO, "townRadius": 8, "porchPosition": Vector3(CELL * 4.0, 0.0, 0.0) }
	var left_result: Array[Node3D] = service.query_resource_nodes(left_entry, ["workstation"], options)
	var right_result: Array[Node3D] = service.query_resource_nodes(right_entry, ["workstation"], options)
	var cache: Dictionary = service.get("query_cache")
	var passed := left_result == [left] and right_result == [right] and cache.size() == 2
	return outcome(passed, "left=%s right=%s cache=%d" % [node_names(left_result), node_names(right_result), cache.size()], ["query_cache_key_includes_actor_origin", "limited_results_are_sorted_per_caller", "same_town_npcs_do_not_share_ordered_cache"], state(service))

func test_utility_query_cache_has_hard_origin_cap(_mode: String) -> Dictionary:
	var service = make_service()
	var station := attach_to_runner(make_block("workbench", Vector3.ZERO))
	service.register_workstation(station)
	var options := { "limit": 1, "outsideTown": false, "workAreaOnly": false, "chunkRadius": 1, "cacheFrames": 60 }
	var first_entry := { "id": "cache-cap-actor", "townCenter": Vector2i.ZERO, "townRadius": 8, "porchPosition": Vector3.ZERO }
	var first_key: String = service.query_cache_key(first_entry, ["workstation"], options, Vector3.ZERO)
	var last_key := ""
	var returned := 0
	for index in range(140):
		var origin := Vector3(float(index) * 0.001, 0.0, 0.0)
		var entry := { "id": "cache-cap-actor", "townCenter": Vector2i.ZERO, "townRadius": 8, "porchPosition": origin }
		var queried: Array[Node3D] = service.query_resource_nodes(entry, ["workstation"], options)
		if queried == [station]:
			returned += 1
		last_key = service.query_cache_key(entry, ["workstation"], options, origin)
	var cache: Dictionary = service.get("query_cache")
	var counters: Dictionary = service.stats().get("counters", {})
	var passed := returned == 140 \
		and cache.size() == 128 \
		and not cache.has(first_key) \
		and cache.has(last_key) \
		and int(counters.get("indexed_query_cache_evictions", 0)) == 12
	return outcome(passed, "returned=%d cache=%d first=%s last=%s evictions=%d" % [returned, cache.size(), str(cache.has(first_key)), str(cache.has(last_key)), int(counters.get("indexed_query_cache_evictions", 0))], ["origin_aware_cache_has_hard_cap", "oldest_origin_is_evicted", "latest_origin_is_retained", "eviction_count_is_deterministic"], state(service))

func test_utility_query_cache_tracks_reserve_release(_mode: String) -> Dictionary:
	var service = make_service()
	var station := attach_to_runner(make_block("workbench", Vector3.ZERO))
	var object_id: String = service.register_workstation(station, { "capacity": 1 })
	var entry := { "id": "availability-observer", "townCenter": Vector2i.ZERO, "townRadius": 8, "porchPosition": Vector3.ZERO }
	var options := { "limit": 8, "outsideTown": false, "insideTownOnly": true, "workAreaOnly": true, "collectAllSpatialMatches": true, "cacheFrames": 60 }
	var scope_before: Dictionary = service.query_scope_revision(entry, ["workstation"], options, Vector3.ZERO)
	var before: Array[Node3D] = service.query_resource_nodes(entry, ["workstation"], options)
	var holder := make_actor("reservation-holder", Vector3(0.0, 0.0, CELL))
	var reserved = reserve(service, object_id, station, holder, "reservation-holder", "use_workbench")
	var scope_after_reserve: Dictionary = service.query_scope_revision(entry, ["workstation"], options, Vector3.ZERO)
	var cache_after_reserve: Dictionary = service.get("query_cache").duplicate(true)
	var busy: Array[Node3D] = service.query_resource_nodes(entry, ["workstation"], options)
	var released = release(service, object_id, station, holder, "reservation-holder", reserved)
	var scope_after_release: Dictionary = service.query_scope_revision(entry, ["workstation"], options, Vector3.ZERO)
	var cache_after_release: Dictionary = service.get("query_cache").duplicate(true)
	var available: Array[Node3D] = service.query_resource_nodes(entry, ["workstation"], options)
	var passed: bool = before == [station] \
		and succeeded(reserved) \
		and scope_after_reserve.get("semanticFingerprint") != scope_before.get("semanticFingerprint") \
		and cache_after_reserve.is_empty() \
		and busy.is_empty() \
		and succeeded(released) \
		and scope_after_release.get("semanticFingerprint") != scope_after_reserve.get("semanticFingerprint") \
		and cache_after_release.is_empty() \
		and available == [station]
	return outcome(passed, "before=%d reserved=%s cacheReserve=%d busy=%d released=%s cacheRelease=%d available=%d fingerprints=%s/%s/%s" % [before.size(), summary(reserved), cache_after_reserve.size(), busy.size(), summary(released), cache_after_release.size(), available.size(), str(scope_before.get("semanticFingerprint")), str(scope_after_reserve.get("semanticFingerprint")), str(scope_after_release.get("semanticFingerprint"))], ["reserve_invalidates_availability_query_cache", "reserve_changes_semantic_query_fingerprint", "busy_utility_is_not_returned", "release_invalidates_cache_and_restores_utility", "release_changes_semantic_query_fingerprint"], state(service))

func test_utility_query_scope_fingerprint_is_stateless(_mode: String) -> Dictionary:
	var service = make_service()
	var entry := {"id":"fingerprint-observer", "townCenter":Vector2i.ZERO, "townRadius":8, "porchPosition":Vector3.ZERO}
	var options := {"limit":64, "outsideTown":false, "insideTownOnly":true, "workAreaOnly":true, "collectAllSpatialMatches":true, "distanceMode":"3d", "bypassCache":true}
	var before: Dictionary = service.query_scope_revision(entry, ["workstation"], options, Vector3.ZERO)
	for index in range(540):
		service.register_anchor("irrelevant-tree:%d" % index, "tree_source", Vector3(float(index % 8) * CELL, 0.0, float((index / 8) % 8) * CELL), {})
	var after: Dictionary = service.query_scope_revision(entry, ["workstation"], options, Vector3.ZERO)
	var passed: bool = before == after and service.get("query_cache").size() <= 128 and before.size() == 3
	return outcome(passed, "before=%s after=%s cache=%d" % [JSON.stringify(before), JSON.stringify(after), service.get("query_cache").size()], ["semantic_query_fingerprint_is_stateless", "irrelevant_kind_churn_does_not_change_fingerprint", "service_memory_remains_bounded"], state(service))

func test_utility_anchor_index_tracks_block_lifecycle(_mode: String) -> Dictionary:
	var autonomy = NpcAutonomySystemScript.new()
	transient_nodes.append(autonomy)
	var block := attach_to_runner(make_block("traderStall", Vector3(CELL * 2.0, 0.0, 0.0)))
	var cell: Vector3i = block.get_meta("cell")
	var entry := {
		"id": "trader-lifecycle",
		"job": "trade",
		"townCenter": Vector2i.ZERO,
		"townRadius": 8,
		"porchPosition": Vector3.ZERO
	}
	var options := { "limit": 8, "outsideTown": false, "workAreaOnly": true, "cacheFrames": 60 }
	autonomy.notify_block_created(cell, "traderStall", block)
	var created: Array[Node3D] = autonomy.smart_objects.query_resource_nodes(entry, ["trader_stall"], options)
	var cache_after_create: Dictionary = autonomy.smart_objects.get("query_cache").duplicate(true)
	autonomy.notify_block_removed(cell, "traderStall", block)
	var cache_after_remove: Dictionary = autonomy.smart_objects.get("query_cache").duplicate(true)
	var removed: Array[Node3D] = autonomy.smart_objects.query_resource_nodes(entry, ["trader_stall"], options)
	var replacement := attach_to_runner(make_block("traderStall", Vector3(CELL * 2.0, 0.0, 0.0)))
	autonomy.notify_block_created(cell, "traderStall", replacement)
	var recreated: Array[Node3D] = autonomy.smart_objects.query_resource_nodes(entry, ["trader_stall"], options)
	var recreated_debug: Dictionary = autonomy.smart_objects.reservation_debug("block:%d,%d,%d:traderStall" % [cell.x, cell.y, cell.z], "")
	var passed := created == [block] \
		and not cache_after_create.is_empty() \
		and cache_after_remove.is_empty() \
		and removed.is_empty() \
		and recreated == [replacement] \
		and not bool(recreated_debug.get("depleted", true))
	return outcome(passed, "created=%d cacheCreated=%d cacheRemoved=%d removed=%d recreated=%d debug=%s" % [created.size(), cache_after_create.size(), cache_after_remove.size(), removed.size(), recreated.size(), JSON.stringify(recreated_debug)], ["block_create_registers_indexed_utility", "block_remove_invalidates_query_cache", "removed_utility_is_not_selected", "same_cell_type_recreation_reactivates_utility"], state(autonomy.smart_objects))

func test_utility_anchor_selection_has_no_global_or_route_scan(_mode: String) -> Dictionary:
	var source := FileAccess.get_file_as_string("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
	var start := source.find("func add_utility_anchor_candidates")
	var finish := source.find("\nfunc ", start + 1)
	var method_source := source.substr(start, finish - start) if start >= 0 and finish > start else ""
	var uses_authoritative_index := method_source.contains("smart_object_service()") and method_source.contains("query_resource_nodes")
	var has_bounded_inside_query := method_source.contains("\"insideTownOnly\": true") and method_source.contains("\"collectAllSpatialMatches\": true")
	var has_legacy_ordering_and_cache_policy := method_source.contains("\"distanceMode\": \"3d\"") and method_source.contains("\"bypassCache\": true")
	var scans_global_blocks := method_source.contains("main.get(\"blocks\")") or method_source.contains("blocks.values()")
	var invokes_route_authority := method_source.contains("route_cost") \
		or method_source.contains("route_authority") \
		or method_source.contains("choose_best_reachable_position") \
		or method_source.contains("planner.")
	var passed := uses_authoritative_index and has_bounded_inside_query and has_legacy_ordering_and_cache_policy and not scans_global_blocks and not invokes_route_authority
	return outcome(passed, "indexed=%s boundedInside=%s exactPolicy=%s globalScan=%s routeAuthority=%s" % [str(uses_authoritative_index), str(has_bounded_inside_query), str(has_legacy_ordering_and_cache_policy), str(scans_global_blocks), str(invokes_route_authority)], ["no_global_block_dictionary_scan", "existing_smart_object_authority_reused", "inside_town_matches_collected_before_limit", "three_dimensional_ordering_precedes_limit", "moving_fallback_bypasses_cache", "target_collection_does_not_invoke_route_authority"], {})

func test_trader_fallback_incremental_parity_and_bound(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	world.approach_offset = Vector2i.ZERO
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), FakeUtilityMain.new(), world, RefCounted.new())
	var body := attach_to_runner(make_actor("incremental-trader", Vector3(CELL * 5.0, 0.0, 0.0)))
	var entry := {"id":"incremental-trader", "job":"trade", "body":body, "townCenter":Vector2i.ZERO, "townRadius":20, "porchPosition":Vector3(-CELL * 8.0, 0.0, 0.0), "guardPosition":Vector3(-CELL * 7.0, 0.0, 0.0)}
	for index in range(12):
		var block := attach_to_runner(make_block("workbench", Vector3(CELL * float(12 - index), float(index % 3) * CELL, CELL * float((index % 2) * 2))))
		service.register_workstation(block)
	var synchronous_candidates: Array[Vector3] = planner.town_anchor_candidates(entry)
	var expected: Vector3 = planner.choose_best_reachable_position(entry, synchronous_candidates, false, false, CELL * 0.85, 16)
	world.approach_calls = 0
	world.standability_calls = 0
	var final_result: Dictionary = {}
	var bounded_each_call := true
	var pending_had_no_target := true
	var bounded_state := true
	for _iteration in range(80):
		var before := world.approach_calls + world.standability_calls
		final_result = planner.advance_trader_fallback_target(entry, "incremental-request")
		var delta_checks := world.approach_calls + world.standability_calls - before
		bounded_each_call = bounded_each_call and delta_checks <= 1
		if String(final_result.get("status", "")) == "pending":
			pending_had_no_target = pending_had_no_target and not final_result.has("target")
			var selector_state: Dictionary = entry.get("_traderFallbackSelection", {})
			var descriptors: Array = selector_state.get("utilityDescriptors", []) if selector_state.get("utilityDescriptors", []) is Array else []
			bounded_state = bounded_state and descriptors.size() <= 64
			for descriptor_value in descriptors:
				if descriptor_value is Dictionary:
					for value in (descriptor_value as Dictionary).values():
						bounded_state = bounded_state and not (value is Node)
		if String(final_result.get("status", "")) != "pending":
			break
	var actual: Vector3 = final_result.get("target", Vector3.INF)
	var passed := String(final_result.get("status", "")) == "ready" and actual.is_equal_approx(expected) \
		and bounded_each_call and pending_had_no_target and bounded_state \
		and world.approach_calls <= 8 and world.standability_calls <= 16 \
		and not entry.has("_traderFallbackSelection") and not entry.has("traderFallbackSelectionPending")
	return outcome(passed, "expected=%s actual=%s result=%s approach=%d standability=%d bounded=%s" % [str(expected), str(actual), JSON.stringify(final_result), world.approach_calls, world.standability_calls, str(bounded_each_call)], ["incremental_result_matches_synchronous_nearest_valid_3d_order", "one_expensive_check_per_call", "pending_never_invents_target", "selector_state_is_bounded_and_node_free", "ready_cleans_selector_state"], state(service))

func test_trader_fallback_scoped_invalidation(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	world.approach_offset = Vector2i.ZERO
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), FakeUtilityMain.new(), world, RefCounted.new())
	var body := attach_to_runner(make_actor("scoped-trader", Vector3.ZERO))
	var entry := {"id":"scoped-trader", "job":"trade", "body":body, "townCenter":Vector2i.ZERO, "townRadius":12, "porchPosition":Vector3(CELL * 9.0, 0.0, 0.0)}
	for index in range(8):
		service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * float(index + 3), 0.0, CELL))))
	var options: Dictionary = planner.utility_anchor_query_options()
	var scope_before: Dictionary = service.query_scope_revision(entry, ["trader_stall", "workstation", "storage", "bed"], options, body.global_position)
	service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * 1000.0, 0.0, 0.0))))
	var scope_after_far: Dictionary = service.query_scope_revision(entry, ["trader_stall", "workstation", "storage", "bed"], options, body.global_position)
	var first: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_resource(attach_to_runner(make_prop("irrelevant-tree", "tree", "logs", 1, Vector3(CELL * 2.0, 0.0, 0.0))))
	var after_tree: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_resource(attach_to_runner(make_prop("irrelevant-forage", "berryBush", "berries", 1, Vector3(CELL * 2.0, 0.0, CELL))))
	var after_forage: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_resource(attach_to_runner(make_prop("irrelevant-rock", "rock", "stones", 1, Vector3(CELL * 2.0, 0.0, CELL * 2.0))))
	var after_rock: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_workstation(attach_to_runner(make_block("decorativeUtility", Vector3(CELL * 2.0, 0.0, CELL * 3.0))))
	var after_unsupported_block: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * 40.0, 0.0, 0.0))))
	var after_outside: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	service.register_workstation(attach_to_runner(make_block("traderStall", Vector3(CELL, 0.0, 0.0))))
	var invalidated: Dictionary = planner.advance_trader_fallback_target(entry, "scoped-request")
	var final_result: Dictionary = {}
	for _iteration in range(40):
		final_result = planner.advance_trader_fallback_target(entry, "scoped-request")
		if String(final_result.get("status", "")) != "pending":
			break
	var passed := scope_before == scope_after_far \
		and String(first.get("status", "")) == "pending" \
		and String(after_tree.get("status", "")) == "pending" \
		and String(after_forage.get("status", "")) == "pending" \
		and String(after_rock.get("status", "")) == "pending" \
		and String(after_unsupported_block.get("status", "")) == "pending" \
		and String(after_outside.get("status", "")) == "pending" \
		and String(invalidated.get("status", "")) == "invalidated" and String(invalidated.get("reason", "")) == "source_changed" \
		and not invalidated.has("target") and String(final_result.get("status", "")) == "ready"
	return outcome(passed, "scopeBefore=%s scopeAfterFar=%s first=%s irrelevant=%s/%s/%s/%s/%s invalidated=%s final=%s" % [JSON.stringify(scope_before), JSON.stringify(scope_after_far), JSON.stringify(first), JSON.stringify(after_tree), JSON.stringify(after_forage), JSON.stringify(after_rock), JSON.stringify(after_unsupported_block), JSON.stringify(after_outside), JSON.stringify(invalidated), JSON.stringify(final_result)], ["outside_query_scope_mutation_does_not_restart", "same_scope_tree_forage_rock_mutations_do_not_restart", "unsupported_block_type_does_not_restart", "out_of_town_utility_does_not_restart", "inside_query_scope_matching_utility_invalidates", "invalidated_result_has_no_stale_target", "same_request_can_restart_and_complete"], state(service))

func test_trader_fallback_matching_mutations_invalidate(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), FakeUtilityMain.new(), world, RefCounted.new())
	var body := attach_to_runner(make_actor("mutation-trader", Vector3.ZERO))
	var entry := {"id":"mutation-trader", "job":"trade", "body":body, "townCenter":Vector2i.ZERO, "townRadius":20, "porchPosition":Vector3(CELL * 12.0, 0.0, 0.0)}
	for index in range(8):
		service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * float(index + 3), 0.0, CELL))))
	var mutable_station := attach_to_runner(make_block("workbench", Vector3(CELL * 2.0, 0.0, 0.0)))
	var mutable_id: String = service.register_workstation(mutable_station, {"capacity":1})
	var holder := attach_to_runner(make_actor("mutation-holder", Vector3(CELL * 2.0, 0.0, CELL)))
	var statuses := {}
	statuses["reserveStart"] = planner.advance_trader_fallback_target(entry, "mutation-reserve")
	var reserved = reserve(service, mutable_id, mutable_station, holder, "mutation-holder", "use_workbench")
	statuses["reserve"] = planner.advance_trader_fallback_target(entry, "mutation-reserve")
	statuses["releaseStart"] = planner.advance_trader_fallback_target(entry, "mutation-release")
	var released = release(service, mutable_id, mutable_station, holder, "mutation-holder", reserved)
	statuses["release"] = planner.advance_trader_fallback_target(entry, "mutation-release")
	var deplete_station := attach_to_runner(make_block("workbench", Vector3(CELL * 2.0, 0.0, CELL * 2.0)))
	var deplete_id: String = service.register_workstation(deplete_station, {"singleUse":true})
	var deplete_actor := attach_to_runner(make_actor("mutation-depleter", Vector3(CELL * 2.0, 0.0, CELL * 3.05)))
	statuses["depleteStart"] = planner.advance_trader_fallback_target(entry, "mutation-deplete")
	var depleted = use_object(service, deplete_id, deplete_station, deplete_actor, "mutation-depleter", "use_workbench", "mutation-deplete-effect")
	statuses["deplete"] = planner.advance_trader_fallback_target(entry, "mutation-deplete")
	statuses["removeStart"] = planner.advance_trader_fallback_target(entry, "mutation-remove")
	service.notify_object_removed(mutable_id, "mutation_removed")
	statuses["remove"] = planner.advance_trader_fallback_target(entry, "mutation-remove")
	statuses["recreateStart"] = planner.advance_trader_fallback_target(entry, "mutation-recreate")
	var replacement := attach_to_runner(make_block("workbench", Vector3(CELL * 2.0, 0.0, 0.0)))
	service.register_workstation(replacement, {"capacity":1})
	statuses["recreate"] = planner.advance_trader_fallback_target(entry, "mutation-recreate")
	statuses["relocateStart"] = planner.advance_trader_fallback_target(entry, "mutation-relocate")
	replacement.position = Vector3(CELL * 4.0, 0.0, CELL * 2.0)
	service.register_workstation(replacement, {"capacity":1})
	statuses["relocate"] = planner.advance_trader_fallback_target(entry, "mutation-relocate")
	var passed: bool = succeeded(reserved) and succeeded(released) and succeeded(depleted)
	for key in ["reserveStart", "releaseStart", "depleteStart", "removeStart", "recreateStart", "relocateStart"]:
		passed = passed and String((statuses.get(key, {}) as Dictionary).get("status", "")) == "pending"
	for key in ["reserve", "release", "deplete", "remove", "recreate", "relocate"]:
		var result: Dictionary = statuses.get(key, {})
		passed = passed and String(result.get("status", "")) == "invalidated" and String(result.get("reason", "")) == "source_changed" and not result.has("target")
	return outcome(passed, "statuses=%s reserved=%s released=%s depleted=%s" % [JSON.stringify(statuses), summary(reserved), summary(released), summary(depleted)], ["matching_reserve_invalidates_in_progress_selector", "matching_release_invalidates_in_progress_selector", "matching_depletion_invalidates_in_progress_selector", "matching_remove_invalidates_in_progress_selector", "matching_recreate_invalidates_in_progress_selector", "matching_relocation_invalidates_in_progress_selector"], state(service))

func test_trader_fallback_identity_invalidation(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), FakeUtilityMain.new(), world, RefCounted.new())
	var body := attach_to_runner(make_actor("identity-trader", Vector3.ZERO))
	var entry := {"id":"identity-trader", "job":"trade", "body":body, "townCenter":Vector2i.ZERO, "townRadius":12, "porchPosition":Vector3.ZERO, "guardPosition":Vector3(CELL * 2.0, 0.0, 0.0), "townKey":"town-a", "homeStableId":"home-a", "homeKey":1, "homeCell":Vector2i(1, 1), "porchCell":Vector2i(1, 2)}
	service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * 3.0, 0.0, 0.0))))
	planner.advance_trader_fallback_target(entry, "identity-a")
	entry["townRadius"] = 13
	var town_changed: Dictionary = planner.advance_trader_fallback_target(entry, "identity-a")
	planner.advance_trader_fallback_target(entry, "identity-a")
	var request_changed: Dictionary = planner.advance_trader_fallback_target(entry, "identity-b")
	planner.advance_trader_fallback_target(entry, "identity-b")
	body.position.x += 0.25
	var actor_changed: Dictionary = planner.advance_trader_fallback_target(entry, "identity-b")
	var anchor_results: Array[Dictionary] = []
	planner.advance_trader_fallback_target(entry, "identity-anchor-porch")
	entry["porchPosition"] = Vector3(CELL, 0.0, 0.0)
	anchor_results.append(planner.advance_trader_fallback_target(entry, "identity-anchor-porch"))
	planner.advance_trader_fallback_target(entry, "identity-anchor-guard")
	entry["guardPosition"] = Vector3(CELL * 3.0, 0.0, 0.0)
	anchor_results.append(planner.advance_trader_fallback_target(entry, "identity-anchor-guard"))
	var assignment_results: Array[Dictionary] = []
	var assignment_mutations := [
		{"key":"townKey", "value":"town-b"},
		{"key":"homeStableId", "value":"home-b"},
		{"key":"homeKey", "value":2},
		{"key":"homeCell", "value":Vector2i(2, 1)},
		{"key":"porchCell", "value":Vector2i(2, 2)}
	]
	for index in range(assignment_mutations.size()):
		var request_id := "identity-assignment-%d" % index
		planner.advance_trader_fallback_target(entry, request_id)
		var mutation: Dictionary = assignment_mutations[index]
		entry[String(mutation.get("key", ""))] = mutation.get("value")
		assignment_results.append(planner.advance_trader_fallback_target(entry, request_id))
	var passed := String(town_changed.get("reason", "")) == "town_changed" and not town_changed.has("target") \
		and String(request_changed.get("reason", "")) == "request_changed" and not request_changed.has("target") \
		and String(actor_changed.get("reason", "")) == "actor_changed" and not actor_changed.has("target") \
		and not entry.has("_traderFallbackSelection")
	for result in anchor_results:
		passed = passed and String(result.get("status", "")) == "invalidated" and String(result.get("reason", "")) == "anchor_changed" and not result.has("target")
	for result in assignment_results:
		passed = passed and String(result.get("status", "")) == "invalidated" and String(result.get("reason", "")) == "assignment_changed" and not result.has("target")
	return outcome(passed, "town=%s request=%s actor=%s anchors=%s assignments=%s" % [JSON.stringify(town_changed), JSON.stringify(request_changed), JSON.stringify(actor_changed), JSON.stringify(anchor_results), JSON.stringify(assignment_results)], ["town_change_invalidates", "request_change_invalidates", "actor_origin_change_invalidates", "porch_and_guard_anchor_changes_invalidate", "stable_town_and_home_assignment_changes_invalidate", "all_invalidations_clear_state_without_target"], state(service))

func test_trader_fallback_exhaustion_liveness(_mode: String) -> Dictionary:
	var service = make_service()
	var world := FakeUtilityAnchorWorld.new()
	world.no_approach = true
	world.reject_all_standability = true
	var planner = NpcSemanticGoalPlannerScript.new()
	planner.setup(FakeUtilityAnchorSystem.new(service), FakeUtilityMain.new(), world, RefCounted.new())
	var body := attach_to_runner(make_actor("exhausted-trader", Vector3.ZERO))
	var entry := {"id":"exhausted-trader", "job":"trade", "body":body, "townCenter":Vector2i.ZERO, "townRadius":200, "porchPosition":Vector3(CELL * 20.0, 0.0, 0.0)}
	for index in range(64):
		service.register_workstation(attach_to_runner(make_block("workbench", Vector3(CELL * float(index + 1), 0.0, CELL * 2.0))))
	var result: Dictionary = {}
	var bounded_each_call := true
	var calls := 0
	for iteration in range(80):
		var before := world.approach_calls + world.standability_calls
		result = planner.advance_trader_fallback_target(entry, "exhaustion-request")
		calls = iteration + 1
		bounded_each_call = bounded_each_call and world.approach_calls + world.standability_calls - before <= 1
		if String(result.get("status", "")) != "pending":
			break
	var debug: Dictionary = entry.get("lastTraderFallbackSelectionDebug", {})
	var passed := String(result.get("status", "")) == "exhausted" and calls <= 80 and bounded_each_call \
		and world.approach_calls == 64 and world.standability_calls <= 16 \
		and int(debug.get("approachChecks", -1)) == 64 and int(debug.get("standabilityChecks", -1)) == world.standability_calls \
		and not entry.has("_traderFallbackSelection") and not entry.has("traderFallbackSelectionPending")
	return outcome(passed, "result=%s calls=%d approach=%d standability=%d debug=%s" % [JSON.stringify(result), calls, world.approach_calls, world.standability_calls, JSON.stringify(debug)], ["adversarial_selection_terminates_within_80_admissions", "approach_scan_is_bounded_at_64", "validation_is_bounded_at_16", "exhaustion_cleans_state"], state(service))

func test_forager_query_after_harvest_no_crash(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("harvest-query", "berryBush", "berries", 3, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var before: Array[Node3D] = query_forage_nodes(service)
	var actor := make_actor("forager", Vector3(12.0, 0.0, 1.4))
	var harvested = harvest(service, object_id, prop, actor, "forager", "npc")
	var after: Array[Node3D] = query_forage_nodes(service)
	var passed: bool = before.size() == 1 and succeeded(harvested) and after.is_empty()
	return outcome(passed, "harvest=%s before=%d after=%d" % [summary(harvested), before.size(), after.size()], ["forager_query_before_harvest", "harvest_depletes_resource", "forager_query_after_harvest_empty_no_crash"], state(service))

func test_forager_live_candidate_only(_mode: String) -> Dictionary:
	var service = make_service()
	var live := make_prop("forager-live", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var stale := make_prop("forager-stale", "berryBush", "berries", 2, Vector3(13.35, 0.0, 0.0))
	service.register_resource(live)
	var stale_id: String = service.register_resource(stale)
	stale.free()
	var queried: Array[Node3D] = query_forage_nodes(service)
	var stale_available: Dictionary = service.object_available(stale_id, "forager")
	var passed: bool = queried.size() == 1 and queried[0] == live and String(stale_available.get("reason", "")) == "target_gone"
	return outcome(passed, "queried=%d stale=%s" % [queried.size(), JSON.stringify(stale_available)], ["forager_query_returns_only_live_candidate", "temporarily_absent_candidate_is_target_gone"], state(service))

func test_forager_reachable_approach_slot(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("forager-slot", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("forager", Vector3(CELL * 1.05, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "forager")
	var completed = complete(service, object_id, prop, actor, "forager", first)
	var slot_id: String = String(first.metrics.get("slotId", "")) if succeeded(first) else ""
	var approach_position = first.metrics.get("approachPosition", null) if succeeded(first) else null
	var passed: bool = succeeded(first) and slot_id != "" and approach_position != null and succeeded(completed)
	return outcome(passed, "reserve=%s complete=%s" % [summary(first), summary(completed)], ["forager_reserves_registered_approach_slot", "forager_harvests_from_reachable_slot"], state(service))

func test_forager_no_wall_bump_on_morning_exit(_mode: String) -> Dictionary:
	var service = make_service()
	var blocked := make_prop("forager-wall-blocked", "berryBush", "berries", 2, Vector3.ZERO)
	var blocked_id: String = service.register_resource(blocked, {
		"blockers": [AABB(Vector3(0.45, -0.2, -0.4), Vector3(0.25, 1.8, 0.8))]
	})
	var actor := make_actor("niko", Vector3(1.3, 0.0, 0.0))
	var first = reserve(service, blocked_id, blocked, actor, "niko")
	var blocked_result = complete(service, blocked_id, blocked, actor, "niko", first)
	var released = release(service, blocked_id, blocked, actor, "niko", first)
	var alternate := make_prop("forager-wall-clear", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	service.register_resource(alternate)
	var queried: Array[Node3D] = query_forage_nodes(service)
	var passed: bool = succeeded(first) and failed_reason(blocked_result, "line_of_sight_blocked") and succeeded(released) and queried.has(alternate)
	return outcome(passed, "blocked=%s release=%s queried=%d" % [summary(blocked_result), summary(released), queried.size()], ["wall_contact_blocks_forage_effect", "blocked_reservation_released_before_reselect"], state(service))

func test_forager_target_gone_reselects(_mode: String) -> Dictionary:
	var service = make_service()
	var removed := make_prop("forager-gone", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var alternate := make_prop("forager-reselect", "berryBush", "berries", 2, Vector3(13.35, 0.0, 0.0))
	var removed_id: String = service.register_resource(removed)
	service.register_resource(alternate)
	var actor := make_actor("forager", Vector3(12.0, 0.0, CELL * 1.05))
	var first = reserve(service, removed_id, removed, actor, "forager")
	service.notify_object_removed(removed_id, removed)
	var completed = complete(service, removed_id, removed, actor, "forager", first)
	var queried: Array[Node3D] = query_forage_nodes(service)
	var passed: bool = succeeded(first) and failed_reason(completed, "resource_depleted") and queried.size() == 1 and queried[0] == alternate
	return outcome(passed, "complete=%s queried=%d" % [summary(completed), queried.size()], ["target_gone_is_terminal_for_old_resource", "forager_reselects_live_alternate"], state(service))

func test_forager_route_blocked_marks_target_unreachable(_mode: String) -> Dictionary:
	var service = make_service()
	var blocked := make_prop("forager-unreachable", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var alternate := make_prop("forager-reachable-after-unreachable", "berryBush", "berries", 2, Vector3(13.35, 0.0, 0.0))
	service.register_resource(blocked)
	service.register_resource(alternate)
	blocked.set_meta("npc_unreachable_forager", true)
	var queried: Array[Node3D] = service.query_resource_nodes(make_query_entry(), ["forage_source"], {
		"drops": ["berries"],
		"limit": 8,
		"cacheFrames": 0,
		"unreachableMetaKey": "npc_unreachable_forager"
	})
	var passed: bool = queried.size() == 1 and queried[0] == alternate
	return outcome(passed, "queried=%d" % queried.size(), ["route_blocked_target_retry_suppressed", "reachable_alternate_remains_queryable"], state(service))

func test_forager_unreachable_key_sanitizes_npc_id(_mode: String) -> Dictionary:
	var service = make_service()
	var blocked := make_prop("forager-unsafe-id-blocked", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var alternate := make_prop("forager-unsafe-id-alternate", "berryBush", "berries", 2, Vector3(13.35, 0.0, 0.0))
	service.register_resource(blocked)
	service.register_resource(alternate)
	var npc_system := track_transient_node(NpcSystemScript.new()) as NpcSystem
	var entry := make_query_entry()
	entry["id"] = "forager_0,0:home:2"
	var key := npc_system.forager_unreachable_meta_key(entry)
	blocked.set_meta(key, true)
	var options: Dictionary = npc_system.resource_query_options_for_job(entry, "forage")
	options["cacheFrames"] = 0
	var queried: Array[Node3D] = service.query_resource_nodes(entry, ["forage_source"], options)
	var safe_key := key.find(":") < 0 and key.find(",") < 0
	var passed: bool = safe_key and bool(blocked.get_meta(key, false)) and queried.size() == 1 and queried[0] == alternate
	return outcome(passed, "key=%s queried=%d" % [key, queried.size()], ["unsafe_npc_id_produces_valid_meta_key", "unsafe_id_unreachable_target_suppressed"], state(service))

func test_forager_harvest_requires_reservation_and_arrival(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("forager-authority", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("forager", Vector3(CELL * 1.05, 0.0, 0.0))
	var missing_reservation = complete_with_metadata(service, object_id, prop, actor, "forager", {
		"action": "harvest_resource",
		"actorKind": "npc",
		"requireReservation": true
	})
	actor.position = Vector3(CELL * 4.0, 0.0, 0.0)
	var first = reserve(service, object_id, prop, actor, "forager")
	var far_complete = complete(service, object_id, prop, actor, "forager", first)
	actor.position = Vector3(CELL * 1.05, 0.0, 0.0)
	var arrived_complete = complete(service, object_id, prop, actor, "forager", first)
	var passed: bool = failed_reason(missing_reservation, "missing_reservation") and succeeded(first) and failed_reason(far_complete, "outside_action_reach") and succeeded(arrived_complete)
	return outcome(passed, "missing=%s far=%s arrived=%s" % [summary(missing_reservation), summary(far_complete), summary(arrived_complete)], ["harvest_requires_reservation", "harvest_requires_physical_arrival", "arrival_applies_effect"], state(service))

func test_niko_full_forage_cycle_morning(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("niko-morning-berries", "berryBush", "berries", 3, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var queried: Array[Node3D] = query_forage_nodes(service)
	var niko := make_actor("niko", Vector3(12.0 + CELL * 1.05, 0.0, 0.0))
	var first = reserve(service, object_id, prop, niko, "niko")
	var completed = complete(service, object_id, prop, niko, "niko", first)
	var after: Array[Node3D] = query_forage_nodes(service)
	var carried: int = int(completed.metrics.get("amount", 0)) if succeeded(completed) else 0
	var hunger: float = 38.0
	if carried > 0:
		hunger = minf(100.0, hunger + 24.0)
	var passed: bool = queried.size() == 1 and succeeded(first) and succeeded(completed) and carried == 3 and hunger > 38.0 and after.is_empty()
	return outcome(passed, "queried=%d reserve=%s complete=%s hunger=%.1f after=%d" % [queried.size(), summary(first), summary(completed), hunger, after.size()], ["niko_selects_live_forage_source", "niko_reserves_arrives_harvests", "niko_consumes_or_carries_food"], state(service))

func test_wood_worker_gather_deliver(_mode: String) -> Dictionary:
	return worker_gather_deliver("tree-logs", "tree", "logs", "wood")

func test_stone_worker_gather_deliver(_mode: String) -> Dictionary:
	return worker_gather_deliver("rock-stones", "rock", "stones", "stone")

func test_trader_day_stall_night_home(_mode: String) -> Dictionary:
	var selector := NpcGoalSelectorScript.new()
	var blackboard := NpcBlackboardScript.new()
	var entry := { "id": "trader", "role": "Trader", "job": NpcProfileRulesScript.job_for_role("Trader", false), "hasHome": true }
	var day_goal: Dictionary = selector.select_goal(null, blackboard, entry, {}, { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_DAY, "mustBeInside": false, "activeGuardDuty": false })
	var night_goal: Dictionary = selector.select_goal(null, blackboard, entry, {}, { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT, "mustBeInside": true, "activeGuardDuty": false })
	var library := NpcActionLibraryScript.new()
	var stall_action := library.definition("use_trader_stall")
	var passed: bool = String(entry.get("job", "")) == "trade" and day_goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_WORK and night_goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and String(stall_action.get("execution", "")) == "smart_object"
	return outcome(passed, "job=%s day=%s night=%s stall=%s" % [String(entry.get("job", "")), String(day_goal.get("goalKind")), String(night_goal.get("goalKind")), JSON.stringify(stall_action)], ["trader_day_stall_work", "trader_night_home"], { "day": day_goal, "night": night_goal })

func test_guard_reachable_ranged_intercept(_mode: String) -> Dictionary:
	var service = make_service()
	var object_id: String = service.register_anchor("guard:ranged", "guard_post", Vector3(4.05, 0.0, 0.0), { "capacity": 1, "action": "occupy_guard_post" })
	var actor := make_actor("guard-ranged", Vector3(4.05, 0.0, 1.0))
	var result = use_object(service, object_id, null, actor, "guard-ranged", "occupy_guard_post", "ranged-guard")
	var library := NpcActionLibraryScript.new()
	var intercept := library.definition("choose_intercept")
	return outcome(succeeded(result) and String(intercept.get("execution", "")) == "target_select", "result=%s" % summary(result), ["ranged_guard_uses_reachable_slot", "intercept_is_target_selection"], state(service))

func test_guard_reachable_melee_intercept(_mode: String) -> Dictionary:
	var service = make_service()
	var object_id: String = service.register_anchor("guard:melee", "guard_post", Vector3(1.35, 0.0, 0.0), { "capacity": 1, "action": "occupy_guard_post" })
	var actor := make_actor("guard-melee", Vector3(1.35, 0.0, 0.8))
	var result = use_object(service, object_id, null, actor, "guard-melee", "occupy_guard_post", "melee-guard")
	return outcome(succeeded(result), "result=%s" % summary(result), ["melee_guard_uses_reachable_slot"], state(service))

func test_guard_no_attack_through_wall(_mode: String) -> Dictionary:
	var service = make_service()
	var object_id: String = service.register_anchor("guard:blocked", "guard_post", Vector3.ZERO, {
		"blockers": [AABB(Vector3(0.45, -0.2, -0.4), Vector3(0.25, 1.8, 0.8))]
	})
	var actor := make_actor("guard", Vector3(1.3, 0.0, 0.0))
	var result = use_object(service, object_id, null, actor, "guard", "occupy_guard_post", "blocked-guard")
	return outcome(failed_reason(result, "line_of_sight_blocked"), "result=%s" % summary(result), ["guard_wall_occlusion_blocks_effect"], state(service))

func test_scripted_world_action(_mode: String) -> Dictionary:
	var library := NpcActionLibraryScript.new()
	var action := library.definition("complete_scripted_world_action")
	var service = make_service()
	var object_id: String = service.register_anchor("scripted:world", "scripted_action", Vector3.ZERO, { "action": "complete_scripted_world_action" })
	var result = use_object(service, object_id, null, make_actor("scripted-npc", Vector3(0.0, 0.0, 1.0)), "scripted-npc", "complete_scripted_world_action", "scripted-action")
	var passed: bool = String(action.get("execution", "")) == "smart_object" and succeeded(result)
	return outcome(passed, "action=%s result=%s" % [JSON.stringify(action), summary(result)], ["scripted_action_uses_smart_object"], state(service))

func test_cancel_releases_slot(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("cancel-berries", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("npc-a", Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "npc-a")
	var cancelled = release(service, object_id, prop, actor, "npc-a", first)
	var second = reserve(service, object_id, prop, make_actor("npc-b", Vector3(-1.4, 0.0, 0.0)), "npc-b")
	return outcome(succeeded(first) and succeeded(cancelled) and succeeded(second), "cancel=%s second=%s" % [summary(cancelled), summary(second)], ["cancel_releases_capacity"], state(service))

func test_day_night_object_policy(_mode: String) -> Dictionary:
	var service = make_service()
	var object_id: String = service.register_anchor("stall:policy", "trader_stall", Vector3.ZERO, { "allowedScheduleStates": ["day"] })
	var actor := make_actor("trader", Vector3(0.0, 0.0, 1.0))
	var night = use_object(service, object_id, null, actor, "trader", "use_trader_stall", "night-stall", {}, { "scheduleState": "night" })
	var day = use_object(service, object_id, null, actor, "trader", "use_trader_stall", "day-stall", {}, { "scheduleState": "day" })
	return outcome(failed_reason(night, "schedule_policy_closed") and succeeded(day), "night=%s day=%s" % [summary(night), summary(day)], ["night_policy_closes_stall", "day_policy_opens_stall"], state(service))

func worker_gather_deliver(prop_id: String, material: String, drop: String, worker_id: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop(prop_id, material, drop, 4, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor(worker_id, Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, worker_id)
	var gathered = complete(service, object_id, prop, actor, worker_id, first)
	var deposit_id: String = service.register_anchor("deposit:%s" % worker_id, "storage", Vector3(1.4, 0.0, 0.0), {})
	var delivered = use_object(service, deposit_id, null, actor, worker_id, "deposit_inventory", "deposit-%s" % worker_id)
	var passed: bool = succeeded(gathered) and String(gathered.metrics.get("drop", "")) == drop and succeeded(delivered)
	return outcome(passed, "gather=%s deposit=%s" % [summary(gathered), summary(delivered)], ["worker_gather_effect", "worker_deliver_effect"], state(service))

func legacy_utility_anchor_candidates(blocks: Array[Node3D], entry: Dictionary, world, origin: Vector3) -> Array[Vector3]:
	var utility_types := ["traderStall", "workbench", "furnace", "chest", "bed", "campfire", "anvil"]
	var utility_nodes: Array[Node3D] = []
	for node in blocks:
		if node == null or not is_instance_valid(node):
			continue
		if not (String(node.get_meta("block_type", "")) in utility_types):
			continue
		if not world.point_inside_town(entry, node.global_position):
			continue
		utility_nodes.append(node)
	utility_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var a_distance := a.global_position.distance_squared_to(origin)
		var b_distance := b.global_position.distance_squared_to(origin)
		if is_equal_approx(a_distance, b_distance):
			return stable_test_node_id(a) < stable_test_node_id(b)
		return a_distance < b_distance
	)
	var result: Array[Vector3] = []
	for node in utility_nodes:
		for cell in world.approach_cells_for_target(entry, node.global_position, false):
			var position: Vector3 = world.cell_position(cell)
			if world.point_inside_town(entry, position):
				result.append(position)
				break
		if result.size() >= 8:
			break
	return result

func stable_test_node_id(node: Node) -> String:
	if node.has_meta("cell"):
		var cell = node.get_meta("cell")
		if cell is Vector3i:
			return "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, String(node.get_meta("block_type", node.name))]
	return String(node.name)

func make_service():
	var service = SmartObjectServiceScript.new()
	service.setup(null, null)
	return service

func make_actor(id: String, position: Vector3) -> Node3D:
	var actor := Node3D.new()
	actor.name = id
	actor.position = position
	actor.set_meta("npc_stable_id", id)
	return track_transient_node(actor)

func make_prop(prop_id: String, material: String, drop: String, count: int, position: Vector3) -> Node3D:
	var prop := Node3D.new()
	prop.name = "Prop_%s" % prop_id
	prop.position = position
	prop.set_meta("kind", "prop")
	prop.set_meta("prop_id", prop_id)
	prop.set_meta("material", material)
	prop.set_meta("drop", drop)
	prop.set_meta("drop_count", count)
	return track_transient_node(prop)

func query_forage_nodes(service) -> Array[Node3D]:
	return service.query_resource_nodes(make_query_entry(), ["forage_source"], {
		"drops": ["berries"],
		"limit": 8,
		"cacheFrames": 60
	})

func node_names(nodes: Array[Node3D]) -> String:
	var names: Array[String] = []
	for node in nodes:
		names.append(String(node.name) if node != null else "<null>")
	return JSON.stringify(names)

func make_query_entry() -> Dictionary:
	return {
		"id": "forager",
		"job": "forage",
		"townCenter": Vector2i.ZERO,
		"townRadius": 4,
		"porchPosition": Vector3.ZERO
	}

func index_contains(index_value, kind: String, object_id: String) -> bool:
	if not (index_value is Dictionary):
		return false
	var index: Dictionary = index_value
	var bucket: Dictionary = index.get(kind, {})
	return bucket.has(object_id)

func make_block(block_type: String, position: Vector3) -> Node3D:
	var block := Node3D.new()
	block.name = "Block_%s" % block_type
	block.position = position
	block.set_meta("kind", "block")
	block.set_meta("block_type", block_type)
	block.set_meta("cell", Vector3i(roundi(position.x / 1.35), roundi(position.y / 1.35), roundi(position.z / 1.35)))
	return track_transient_node(block)

func track_transient_node(node: Node3D) -> Node3D:
	transient_nodes.append(node)
	return node

func attach_to_runner(node: Node3D) -> Node3D:
	if runner is Node:
		(runner as Node).add_child(node)
	return node

func cleanup_transient_nodes() -> void:
	for node in transient_nodes:
		if node != null and is_instance_valid(node):
			node.free()
	transient_nodes.clear()

func reserve(service, object_id: String, object_node: Node, actor: Node, actor_id: String, action := "harvest_resource", actor_kind := "npc"):
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, actor_id, {
		"action": action,
		"actorKind": actor_kind
	})
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = actor_kind
	return service.request_interaction(request)

func release(service, object_id: String, object_node: Node, actor: Node, actor_id: String, prior_result, actor_kind := "npc"):
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_CANCEL, object_id, actor_id, {
		"reservationId": String(prior_result.metrics.get("reservationId", "")),
		"actorKind": actor_kind
	})
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = actor_kind
	return service.request_interaction(request)

func complete(service, object_id: String, object_node: Node, actor: Node, actor_id: String, prior_result, request_id := ""):
	var metadata := {
		"reservationId": String(prior_result.metrics.get("reservationId", "")),
		"actorKind": "npc",
		"action": "harvest_resource",
		"requireReservation": true
	}
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_COMPLETE, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = "npc"
	if request_id != "":
		request.request_id = request_id
	return service.request_interaction(request)

func complete_with_metadata(service, object_id: String, object_node: Node, actor: Node, actor_id: String, metadata: Dictionary):
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_COMPLETE, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = String(metadata.get("actorKind", "npc"))
	return service.request_interaction(request)

func harvest(service, object_id: String, object_node: Node, actor: Node, actor_id: String, actor_kind := "player"):
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_HARVEST, object_id, actor_id, {
		"actorKind": actor_kind,
		"action": "harvest_resource",
		"requireReservation": false
	})
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = actor_kind
	return service.request_interaction(request)

func use_object(service, object_id: String, object_node: Node, actor: Node, actor_id: String, action: String, request_id: String, prior_result = {}, extra_metadata := {}):
	var metadata := extra_metadata.duplicate(true) if extra_metadata is Dictionary else {}
	metadata["actorKind"] = "npc"
	metadata["action"] = action
	metadata["requireReservation"] = false if prior_result is Dictionary and prior_result.is_empty() else true
	if prior_result != null and prior_result is Object and prior_result.get("metrics") is Dictionary:
		metadata["reservationId"] = String(prior_result.metrics.get("reservationId", ""))
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_COMPLETE, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = "npc"
	request.request_id = request_id
	return service.request_interaction(request)

func succeeded(result) -> bool:
	return result != null and String(result.status) == String(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED)

func failed_reason(result, reason: String) -> bool:
	return result != null and String(result.status) == String(NpcEnumsScript.INTERACTION_STATUS_FAILED) and String(result.reason) == reason

func summary(result) -> String:
	if result == null:
		return "{}"
	return JSON.stringify(result.to_summary())

func state(service) -> Dictionary:
	return { "smartObjects": service.stats() }

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	var result: Dictionary = runner.outcome(passed, details, assertions, key_state) if runner != null else {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
	cleanup_transient_nodes()
	return result
