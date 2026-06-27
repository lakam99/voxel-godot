extends RefCounted

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const GuardRosterServiceScript := preload("res://scripts/npc_ai/behavior/GuardRosterService.gd")
const NpcScheduleServiceScript := preload("res://scripts/npc_ai/behavior/NpcScheduleService.gd")
const NpcGoalSelectorScript := preload("res://scripts/npc_ai/behavior/NpcGoalSelector.gd")
const NpcActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
const NpcTaskPlannerScript := preload("res://scripts/npc_ai/behavior/NpcTaskPlanner.gd")
const NpcRecoveryPolicyScript := preload("res://scripts/npc_ai/behavior/NpcRecoveryPolicy.gd")
const NpcPlanExecutorScript := preload("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd")
const NpcPerceptionServiceScript := preload("res://scripts/npc_ai/behavior/NpcPerceptionService.gd")

var runner = null
var roster
var schedule
var selector
var planner
var recovery

class FakeAutonomy:
	extends Node
	var traffic_releases := 0
	var door_releases := 0

	func release_npc_traffic_reservations(_entry, _reason := "released") -> int:
		traffic_releases += 1
		return 1

	func release_npc_door_hold(_actor_or_id, _schedule_close := true) -> void:
		door_releases += 1

class FakeNpcSystem:
	extends Node
	var chosen_anchor := Vector3(2.7, 0.0, 0.0)

	func update_npc_needs(_entry: Dictionary, _delta: float, _night_factor: float) -> void:
		pass

	func npc_is_held_by_intro_or_dialogue(_entry: Dictionary, _body: Node3D) -> bool:
		return false

	func choose_day_target(_entry: Dictionary) -> Vector3:
		return chosen_anchor

	func move_npc(entry: Dictionary, target: Vector3, max_distance: float, _moving_home := false, _allow_outside := false, _physics_delta := 0.0166667) -> float:
		var body := entry.get("body") as Node3D
		if body == null:
			return 0.0
		var previous := body.global_position
		if bool(entry.get("blockMovement", false)):
			return 0.0
		body.global_position = previous.move_toward(target, max_distance)
		return body.global_position.distance_to(previous)

	func home_route_target(entry: Dictionary) -> Vector3:
		return entry.get("homePosition", Vector3.ZERO)

	func settle_home_if_reached(entry: Dictionary) -> void:
		var body := entry.get("body") as Node3D
		if body != null and body.global_position.distance_to(entry.get("homePosition", body.global_position)) <= 0.35:
			entry["insideHome"] = true
			body.set_meta("npc_inside_home", true)

	func update_day_job(entry: Dictionary, _delta: float) -> bool:
		entry["jobTarget"] = Vector3(5.4, 0.0, 0.0)
		return true

	func update_fighter_target(entry: Dictionary, _body: Node3D, target_hostile: Node3D, _weapon_id: String) -> Vector3:
		entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
		return Vector3(4.05, 0.0, 0.0)

	func update_scripted_npc(entry: Dictionary, body: Node3D, _delta: float) -> void:
		body.set_meta("npc_scripted_arrived", true)
		entry["scriptedUpdated"] = true

	func face_hostile_if_needed(_body: Node3D, _target_hostile: Node3D) -> void:
		pass

func setup(owner) -> void:
	runner = owner
	roster = GuardRosterServiceScript.new()
	schedule = NpcScheduleServiceScript.new()
	schedule.setup(roster)
	selector = NpcGoalSelectorScript.new()
	var library = NpcActionLibraryScript.new()
	planner = NpcTaskPlannerScript.new()
	planner.setup(library)
	recovery = NpcRecoveryPolicyScript.new()

func cases() -> Array[Dictionary]:
	return [
		case("npc_behavior_day_worker_reachable_job", "day", "test_day_worker_reachable_job"),
		case("npc_behavior_day_forager_goal_plan_shape", "day", "test_day_forager_goal_plan_shape"),
		case("npc_behavior_day_guard_patrol", "day", "test_day_guard_patrol"),
		case("npc_behavior_day_idle_semantic_anchor", "day", "test_day_idle_semantic_anchor"),
		case("npc_behavior_dusk_civilian_returns_before_night", "transition", "test_dusk_civilian_returns_before_night"),
		case("npc_behavior_dusk_guard_reports_to_duty", "transition", "test_dusk_guard_reports_to_duty"),
		case("npc_behavior_night_assigned_guard_outside", "night", "test_night_assigned_guard_outside"),
		case("npc_behavior_night_off_duty_guard_inside", "night", "test_night_off_duty_guard_inside"),
		case("npc_behavior_night_fighter_non_guard_inside", "night", "test_night_fighter_non_guard_inside"),
		case("npc_behavior_night_worker_inside", "night", "test_night_worker_inside"),
		case("npc_behavior_night_forager_inside", "night", "test_night_forager_inside"),
		case("npc_behavior_night_trader_inside", "night", "test_night_trader_inside"),
		case("npc_behavior_night_porch_not_inside", "night", "test_night_porch_not_inside"),
		case("npc_behavior_night_threshold_not_inside", "night", "test_night_threshold_not_inside"),
		case("npc_behavior_night_blocked_home_explicit_failure_no_teleport", "night", "test_night_blocked_home_explicit_failure_no_teleport"),
		case("npc_behavior_threat_exception_explicit", "night", "test_threat_exception_explicit"),
		case("npc_behavior_executor_decays_guard_cooldown", "night", "test_executor_decays_guard_cooldown"),
		case("npc_behavior_post_threat_schedule_restored", "night", "test_post_threat_schedule_restored"),
		case("npc_behavior_goal_hysteresis_no_thrashing", "day", "test_goal_hysteresis_no_thrashing"),
		case("npc_behavior_action_interrupt_releases_resources", "day", "test_action_interrupt_releases_resources"),
		case("npc_behavior_scripted_order_priority_and_cancel", "day", "test_scripted_order_priority_and_cancel"),
		case("npc_behavior_unreachable_goal_terminal", "day", "test_unreachable_goal_terminal"),
		case("npc_behavior_all_generated_town_npcs_have_interior_home", "day", "test_all_generated_town_npcs_have_interior_home"),
		case("npc_behavior_no_raw_random_world_goal", "day", "test_no_raw_random_world_goal")
	]

func case(id: String, mode: String, method: String) -> Dictionary:
	return {
		"id": id,
		"suite": "behavior",
		"timeModes": [mode],
		"callable": Callable(self, method)
	}

func test_day_worker_reachable_job(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Carpenter", { "job": "wood" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_WORK and result.plan.get("actionIds", []).has("navigate_to_work")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["worker_goal_work", "worker_plan_navigates_to_work"], result)

func test_day_forager_goal_plan_shape(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Forager", { "job": "forage" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_FORAGE and actions == ["select_forage_target", "navigate_to_resource", "harvest_resource", "eat_if_hungry"]
	return outcome(passed, "actions=%s" % JSON.stringify(actions), ["forager_goal", "forager_symbolic_sequence"], result)

func test_day_guard_patrol(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and actions.has("patrol_guard_post")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(actions)], ["day_guard_goal", "patrol_action"], result)

func test_day_idle_semantic_anchor(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/npc_nav/NpcGoalPlanner.gd")
	var town_anchor_start := source.find("func town_anchor_candidates")
	var town_anchor_end := source.find("func job_anchor_candidates")
	var town_anchor_source := source.substr(town_anchor_start, town_anchor_end - town_anchor_start)
	var result := select_and_plan(entry("Trader", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_IDLE and actions.has("relocate_semantic_anchor") and town_anchor_source.find("add_deterministic_ring_candidates") < 0
	return outcome(passed, "idle actions=%s ringInIdle=%s" % [JSON.stringify(actions), str(town_anchor_source.find("add_deterministic_ring_candidates") >= 0)], ["idle_goal", "semantic_anchor_action", "no_ring_idle_candidates"], result)

func test_dusk_civilian_returns_before_night(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Villager", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_DUSK)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and result.plan.get("actionIds", []).has("navigate_home_approach")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["dusk_home_goal", "home_plan_started"], result)

func test_dusk_guard_reports_to_duty(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DUSK)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and result.schedule.get("activeGuardDuty") == true
	return outcome(passed, "goal=%s activeGuard=%s" % [String(result.goal.get("goalKind")), str(result.schedule.get("activeGuardDuty"))], ["dusk_guard_goal", "active_guard_duty"], result)

func test_night_assigned_guard_outside(_mode: String) -> Dictionary:
	var entry_data := entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true })
	var schedule_data := schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT)
	var compliance: Dictionary = { "insideHome": false, "onPorch": false, "onThreshold": false }
	var result := perception_compliance(entry_data, schedule_data, compliance)
	var passed: bool = bool(result.compliance.get("ok", false)) and String(result.compliance.get("reason", "")) == "assigned_guard_outside"
	return outcome(passed, JSON.stringify(result.compliance), ["assigned_guard_outside_ok"], result)

func test_night_off_duty_guard_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": false }), "off_duty_guard")

func test_night_fighter_non_guard_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Hunter", { "job": "", "canFight": true, "nightGuard": false }), "fighter_non_guard")

func test_night_worker_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Carpenter", { "job": "wood" }), "worker")

func test_night_forager_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Forager", { "job": "forage" }), "forager")

func test_night_trader_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Trader", { "job": "" }), "trader")

func test_night_porch_not_inside(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var result := perception_compliance(entry_data, schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT), { "insideHome": false, "onPorch": true, "onThreshold": false })
	var passed: bool = not bool(result.compliance.get("ok", true)) and String(result.compliance.get("reason", "")) == "porch_not_inside"
	return outcome(passed, JSON.stringify(result.compliance), ["porch_not_inside"], result)

func test_night_threshold_not_inside(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var result := perception_compliance(entry_data, schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT), { "insideHome": false, "onPorch": true, "onThreshold": true })
	var passed: bool = not bool(result.compliance.get("ok", true)) and String(result.compliance.get("reason", "")) == "threshold_not_inside"
	return outcome(passed, JSON.stringify(result.compliance), ["threshold_not_inside"], result)

func test_night_blocked_home_explicit_failure_no_teleport(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var terminal: Dictionary = recovery.mark_home_blocked(entry_data, "porch_not_inside")
	var passed: bool = bool(terminal.get("terminal", false)) and not bool(terminal.get("teleportUsed", true)) and body.global_position == before and not bool(entry_data.get("insideHome", true))
	return outcome(passed, "terminal=%s before=%s after=%s" % [JSON.stringify(terminal), str(before), str(body.global_position)], ["terminal_blocked_home", "no_teleport", "inside_false"], { "terminal": terminal })

func test_threat_exception_explicit(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Hunter", { "canFight": true, "nightGuard": false }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "activeThreat": true, "threat": Node3D.new() })
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and String(result.goal.get("exceptionReason", "")) == "explicit_active_threat_exception"
	return outcome(passed, "goal=%s reason=%s" % [String(result.goal.get("goalKind")), String(result.goal.get("reason"))], ["threat_exception_goal", "explicit_reason"], compact_result(result))

func test_executor_decays_guard_cooldown(_mode: String) -> Dictionary:
	var fake_autonomy := FakeAutonomy.new()
	var fake_npc := FakeNpcSystem.new()
	var perception := NpcPerceptionServiceScript.new()
	perception.setup(fake_autonomy, fake_npc)
	var executor := NpcPlanExecutorScript.new()
	executor.setup(fake_autonomy, fake_npc, null, {
		"schedule": schedule,
		"guardRoster": roster,
		"perception": perception,
		"goalSelector": selector,
		"taskPlanner": planner,
		"recovery": recovery
	})
	var entry_data := entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true })
	entry_data["blackboard"] = NpcBlackboardScript.new()
	entry_data["cooldown"] = 0.75
	executor.update_legacy_npc(entry_data, 0.25, 1.0)
	var cooldown_after := float(entry_data.get("cooldown", -1.0))
	var passed := absf(cooldown_after - 0.5) <= 0.001
	fake_autonomy.queue_free()
	fake_npc.queue_free()
	return outcome(passed, "cooldown %.2f -> %.2f" % [0.75, cooldown_after], ["executor_cooldown_decays"], { "cooldownAfter": cooldown_after })

func test_post_threat_schedule_restored(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Hunter", { "canFight": true, "nightGuard": false }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "activeThreat": false })
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and result.plan.get("actionIds", []).has("remain_inside")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["post_threat_home_goal", "home_plan_restored"], result)

func test_goal_hysteresis_no_thrashing(_mode: String) -> Dictionary:
	var entry_data := entry("Trader", { "job": "" })
	var blackboard = NpcBlackboardScript.new()
	var schedule_data := schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY)
	var perception := default_perception()
	var first: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var second: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var passed: bool = first.get("goalKind") == second.get("goalKind") and float(second.get("utilityBreakdown", {}).get("hysteresisMargin", 0.0)) > 0.0
	return outcome(passed, "first=%s second=%s" % [String(first.get("goalKind")), String(second.get("goalKind"))], ["stable_goal_reselection", "hysteresis_logged"], { "first": first, "second": second })

func test_action_interrupt_releases_resources(_mode: String) -> Dictionary:
	var fake_autonomy := FakeAutonomy.new()
	var executor := NpcPlanExecutorScript.new()
	executor.setup(fake_autonomy, FakeNpcSystem.new(), null, {
		"schedule": schedule,
		"guardRoster": roster,
		"perception": null,
		"goalSelector": selector,
		"taskPlanner": planner,
		"recovery": recovery
	})
	var entry_data := entry("Villager", {})
	entry_data["blackboard"] = NpcBlackboardScript.new()
	executor.call("_release_action_owned_state", entry_data, "test_interrupt")
	var passed: bool = fake_autonomy.traffic_releases == 1 and fake_autonomy.door_releases == 1 and entry_data.get("activeDoorTrafficGroupId", "") == ""
	fake_autonomy.queue_free()
	return outcome(passed, "traffic=%d door=%d" % [fake_autonomy.traffic_releases, fake_autonomy.door_releases], ["traffic_released", "door_hold_released"], { "traffic": fake_autonomy.traffic_releases, "door": fake_autonomy.door_releases })

func test_scripted_order_priority_and_cancel(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", {})
	var active: Dictionary = select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": true })
	var after_cancel: Dictionary = select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": false })
	var passed: bool = active.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_SCRIPTED and after_cancel.goal.get("goalKind") != NpcEnumsScript.GOAL_KIND_SCRIPTED
	return outcome(passed, "active=%s cancel=%s" % [String(active.goal.get("goalKind")), String(after_cancel.goal.get("goalKind"))], ["scripted_priority", "scripted_cancel_restores_selector"], { "active": active, "afterCancel": after_cancel })

func test_unreachable_goal_terminal(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", {})
	var terminal: Dictionary = recovery.mark_unreachable_goal(entry_data, "no_route")
	var passed: bool = bool(terminal.get("terminal", false)) and String(terminal.get("status", "")) == String(NpcEnumsScript.ROUTE_STATUS_UNREACHABLE)
	return outcome(passed, JSON.stringify(terminal), ["unreachable_terminal", "machine_reason"], { "terminal": terminal, "entryReason": entry_data.get("routeReason", "") })

func test_all_generated_town_npcs_have_interior_home(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var has_home_publish: bool = source.find("home_interior") >= 0 and source.find("publish_navigation_profile_semantics(entry)") >= 0
	var spawn_profile_home: bool = source.find("\"homeCell\": record.get(\"homeCell\"") >= 0 and source.find("\"porchCell\": porch_cell") >= 0
	var role_files := ["guard", "farmer", "carpenter", "forager", "mason", "trader", "civilian", "tutorial"]
	var missing := []
	for role_id in role_files:
		if not ResourceLoader.exists("res://resources/npc_roles/%s.tres" % role_id):
			missing.append(role_id)
	var passed: bool = has_home_publish and spawn_profile_home and missing.is_empty()
	return outcome(passed, "homePublish=%s spawnHome=%s missing=%s" % [str(has_home_publish), str(spawn_profile_home), JSON.stringify(missing)], ["home_semantics_published", "spawn_profile_home_cells", "role_resources_present"], { "missing": missing })

func test_no_raw_random_world_goal(_mode: String) -> Dictionary:
	var npc_source := read_text("res://scripts/NpcSystem.gd")
	var goal_source := read_text("res://scripts/npc_nav/NpcGoalPlanner.gd")
	var update_start := npc_source.find("func update_npc(entry")
	var update_end := npc_source.find("func update_npc_legacy_fallback")
	var update_source := npc_source.substr(update_start, update_end - update_start)
	var idle_start := goal_source.find("func town_anchor_candidates")
	var idle_end := goal_source.find("func job_anchor_candidates")
	var idle_source := goal_source.substr(idle_start, idle_end - idle_start)
	var delegates: bool = update_source.find("update_legacy_npc") >= 0 and update_source.find("update_wander_target") < 0
	var no_idle_ring: bool = idle_source.find("add_deterministic_ring_candidates") < 0
	var no_can_fight_guard: bool = read_text("res://scripts/NpcProfileRules.gd").find("if can_fight or role") < 0
	var passed: bool = delegates and no_idle_ring and no_can_fight_guard
	return outcome(passed, "delegates=%s noIdleRing=%s noCanFightGuard=%s" % [str(delegates), str(no_idle_ring), str(no_can_fight_guard)], ["executor_delegation", "idle_no_ring_candidates", "can_fight_not_guard_predicate"], {})

func expect_night_home_inside(entry_data: Dictionary, label: String) -> Dictionary:
	var result := select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "insideHome": true })
	var compliance: Dictionary = perception_compliance(entry_data, result.schedule, { "insideHome": true, "onPorch": false, "onThreshold": false }).compliance
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and bool(compliance.get("ok", false))
	return outcome(passed, "%s goal=%s compliance=%s" % [label, String(result.goal.get("goalKind")), JSON.stringify(compliance)], ["night_home_goal", "%s_inside_ok" % label], { "goal": result.goal, "plan": result.plan, "compliance": compliance })

func select_and_plan(entry_data: Dictionary, state: StringName, overrides := {}) -> Dictionary:
	var blackboard = NpcBlackboardScript.new()
	var schedule_data := schedule_for(entry_data, state)
	var perception := default_perception()
	for key in overrides.keys():
		perception[key] = overrides[key]
	var goal: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var plan: Dictionary = planner.plan(goal, null, entry_data, perception, schedule_data)
	return { "goal": goal, "plan": plan, "schedule": schedule_data, "perception": perception }

func schedule_for(entry_data: Dictionary, state: StringName) -> Dictionary:
	schedule.inject_snapshot({
		"timeOfDay": 0.75 if state == NpcEnumsScript.SCHEDULE_STATE_NIGHT else 0.25,
		"clockPhase": 0.0,
		"displayHour": 20.25 if state == NpcEnumsScript.SCHEDULE_STATE_NIGHT else 12.0,
		"scheduleState": state,
		"frozen": true
	})
	var snapshot: Dictionary = schedule.snapshot_for(null, entry_data, null)
	schedule.clear_injected_snapshot()
	return snapshot

func perception_compliance(entry_data: Dictionary, schedule_data: Dictionary, overrides := {}) -> Dictionary:
	var perception := default_perception()
	for key in overrides.keys():
		perception[key] = overrides[key]
	return { "perception": perception, "compliance": NpcPerceptionServiceScript.new().compliance(entry_data, perception, schedule_data) }

func default_perception() -> Dictionary:
	return {
		"insideHome": false,
		"onPorch": false,
		"onThreshold": false,
		"scriptedOrder": false,
		"activeThreat": false,
		"threat": null
	}

func entry(role: String, options := {}) -> Dictionary:
	var body := CharacterBody3D.new()
	body.name = "BehaviorNPC_%s" % role
	if runner != null:
		runner.add_child(body)
	var position: Vector3 = options.get("position", Vector3.ZERO)
	body.global_position = position
	var home_cell: Vector2i = options.get("homeCell", Vector2i.ZERO)
	var porch_cell: Vector2i = options.get("porchCell", Vector2i(1, 0))
	return {
		"body": body,
		"id": String(options.get("id", "npc_%s" % role.to_lower())),
		"role": role,
		"job": String(options.get("job", "")),
		"canFight": bool(options.get("canFight", false)),
		"nightGuard": bool(options.get("nightGuard", false)),
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"guardCell": options.get("guardCell", Vector2i(2, 0)),
		"homePosition": Vector3(float(home_cell.x) * 1.35, 0.0, float(home_cell.y) * 1.35),
		"porchPosition": Vector3(float(porch_cell.x) * 1.35, 0.0, float(porch_cell.y) * 1.35),
		"guardPosition": Vector3(2.7, 0.0, 0.0),
		"insideHome": false,
		"routeStatus": "idle",
		"routeReason": "",
		"personalInventory": {}
	}

func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func compact_result(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	if copy.has("perception") and copy["perception"] is Dictionary:
		copy["perception"]["threat"] = copy["perception"].get("threat") != null
	return copy

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	return runner.outcome(passed, details, assertions, key_state) if runner != null else {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
