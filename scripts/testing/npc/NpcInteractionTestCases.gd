extends RefCounted

const SmartObjectServiceScript := preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
const NpcGoalSelectorScript := preload("res://scripts/npc_ai/behavior/NpcGoalSelector.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcProfileRulesScript := preload("res://scripts/NpcProfileRules.gd")

var runner = null
var transient_nodes: Array[Node] = []

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	return [
		case("npc_interaction_resource_reserved_single_user", "day", "test_resource_reserved_single_user"),
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
		case("npc_interaction_stale_registered_resource_ignored", "day", "test_stale_registered_resource_ignored"),
		case("npc_interaction_queue_free_resource_query_no_script_error", "day", "test_queue_free_resource_query_no_script_error"),
		case("npc_interaction_stale_resource_unindexed", "day", "test_stale_resource_unindexed"),
		case("npc_interaction_stale_resource_reservation_released", "day", "test_stale_resource_reservation_released"),
		case("npc_interaction_query_cache_invalidates_on_resource_removal", "day", "test_query_cache_invalidates_on_resource_removal"),
		case("npc_interaction_forager_query_after_harvest_no_crash", "day", "test_forager_query_after_harvest_no_crash"),
		case("npc_interaction_wood_worker_gather_deliver", "day", "test_wood_worker_gather_deliver"),
		case("npc_interaction_stone_worker_gather_deliver", "day", "test_stone_worker_gather_deliver"),
		case("npc_interaction_trader_day_stall_night_home", "day", "test_trader_day_stall_night_home"),
		case("npc_interaction_guard_reachable_ranged_intercept", "night", "test_guard_reachable_ranged_intercept"),
		case("npc_interaction_guard_reachable_melee_intercept", "night", "test_guard_reachable_melee_intercept"),
		case("npc_interaction_guard_no_attack_through_wall", "night", "test_guard_no_attack_through_wall"),
		case("npc_interaction_tutorial_scripted_action_migrated", "day", "test_tutorial_scripted_action_migrated"),
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

func test_resource_removed_during_approach(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("berries-removed", "berryBush", "berries", 2, Vector3.ZERO)
	var object_id: String = service.register_resource(prop)
	var actor := make_actor("npc-a", Vector3(1.4, 0.0, 0.0))
	var first = reserve(service, object_id, prop, actor, "npc-a")
	service.notify_object_removed(object_id, prop)
	var completed = complete(service, object_id, prop, actor, "npc-a", first)
	var reason := String(completed.reason)
	var passed: bool = succeeded(first) and reason in ["resource_depleted", "target_gone"]
	return outcome(passed, "complete=%s" % summary(completed), ["removed_invalidates_reservation", "bounded_replan_reason"], state(service))

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

func test_stale_registered_resource_ignored(_mode: String) -> Dictionary:
	var service = make_service()
	var prop := make_prop("stale-ignored", "berryBush", "berries", 2, Vector3(12.0, 0.0, 0.0))
	var object_id: String = service.register_resource(prop)
	var before: Array[Node3D] = query_forage_nodes(service)
	prop.free()
	var after: Array[Node3D] = query_forage_nodes(service)
	var availability: Dictionary = service.object_available(object_id, "forager")
	var passed: bool = before.size() == 1 and after.is_empty() and String(availability.get("reason", "")) in ["target_gone", "resource_depleted"]
	return outcome(passed, "before=%d after=%d availability=%s" % [before.size(), after.size(), JSON.stringify(availability)], ["stale_resource_skipped", "query_continues_after_stale_node"], state(service))

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

func test_tutorial_scripted_action_migrated(_mode: String) -> Dictionary:
	var library := NpcActionLibraryScript.new()
	var action := library.definition("complete_tutorial_world_action")
	var service = make_service()
	var object_id: String = service.register_anchor("tutorial:repair", "tutorial_action", Vector3.ZERO, { "action": "complete_tutorial_world_action" })
	var result = use_object(service, object_id, null, make_actor("tutorial-npc", Vector3(0.0, 0.0, 1.0)), "tutorial-npc", "complete_tutorial_world_action", "tutorial-action")
	var passed: bool = String(action.get("execution", "")) == "smart_object" and succeeded(result)
	return outcome(passed, "action=%s result=%s" % [JSON.stringify(action), summary(result)], ["tutorial_action_uses_smart_object"], state(service))

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
