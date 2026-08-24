extends Node
class_name NpcAutonomySystem

const NpcAgentContextScript := preload("res://scripts/npc_ai/NpcAgentContext.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcBrainSchedulerScript := preload("res://scripts/npc_ai/NpcBrainScheduler.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcTelemetryServiceScript := preload("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
const DoorPortalServiceScript := preload("res://scripts/npc_ai/interactions/DoorPortalService.gd")
const SmartObjectServiceScript := preload("res://scripts/npc_ai/interactions/SmartObjectService.gd")
const DoorTraversalExecutorScript := preload("res://scripts/npc_ai/interactions/DoorTraversalExecutor.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const BottleneckClassifierScript := preload("res://scripts/npc_ai/traffic/BottleneckClassifier.gd")
const SafeIntervalPlannerScript := preload("res://scripts/npc_ai/traffic/SafeIntervalPlanner.gd")
const WaitForGraphScript := preload("res://scripts/npc_ai/traffic/WaitForGraph.gd")
const TrafficPriorityPolicyScript := preload("res://scripts/npc_ai/traffic/TrafficPriorityPolicy.gd")
const TrafficReservationServiceScript := preload("res://scripts/npc_ai/traffic/TrafficReservationService.gd")
const GuardRosterServiceScript := preload("res://scripts/npc_ai/behavior/GuardRosterService.gd")
const NpcScheduleServiceScript := preload("res://scripts/npc_ai/behavior/NpcScheduleService.gd")
const NpcPerceptionServiceScript := preload("res://scripts/npc_ai/behavior/NpcPerceptionService.gd")
const NpcGoalSelectorScript := preload("res://scripts/npc_ai/behavior/NpcGoalSelector.gd")
const NpcActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
const NpcTaskPlannerScript := preload("res://scripts/npc_ai/behavior/NpcTaskPlanner.gd")
const NpcRecoveryPolicyScript := preload("res://scripts/npc_ai/behavior/NpcRecoveryPolicy.gd")
const NpcPlanExecutorScript := preload("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd")
const NpcSimulationLodServiceScript := preload("res://scripts/npc_ai/lifecycle/NpcSimulationLodService.gd")
const NpcRouteAuthorityV2Script := preload("res://scripts/npc_ai/routing/NpcRouteAuthorityV2.gd")

const NAV_CHANGE_EVENTS_PER_PHYSICS_TICK := 1
const NAV_CHANGE_OBJECT_IDS_PER_PHYSICS_TICK := 2

var npc_system: Node
var main: Node
var architecture_version := NpcConstantsScript.ARCHITECTURE_VERSION
var movement_stack := NpcConstantsScript.NPC_MOVEMENT_STACK
var contexts_by_instance_id := {}
var contexts_by_stable_id := {}
var blackboards_by_stable_id := {}
var scheduler
var telemetry
var change_bus
var navigation_backend_config
var navigation_world
var navmesh_world
var building_navigation_manifests: Dictionary = {}
var navigation_collision_manifests: Dictionary = {}
var crowd_velocity_service
var door_portals
var smart_objects
var door_traversal
var bottleneck_classifier
var safe_interval_planner
var wait_for_graph
var traffic_priority_policy
var traffic_reservations
var external_traffic_advanced_since_policy := false
var guard_roster
var schedule_service
var perception_service
var goal_selector
var action_library
var task_planner
var recovery_policy
var plan_executor
var simulation_lod
var route_authority_v2

func _init() -> void:
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()
	navigation_backend_config = NavigationBackendConfigScript.from_environment()
	navigation_world = NavigationWorldServiceScript.new()
	navigation_world.setup(null, change_bus)
	navmesh_world = NavmeshWorldServiceScript.new()
	navmesh_world.setup(navigation_backend_config)
	door_portals = DoorPortalServiceScript.new()
	smart_objects = SmartObjectServiceScript.new()
	door_traversal = DoorTraversalExecutorScript.new()
	bottleneck_classifier = BottleneckClassifierScript.new()
	safe_interval_planner = SafeIntervalPlannerScript.new()
	wait_for_graph = WaitForGraphScript.new()
	traffic_priority_policy = TrafficPriorityPolicyScript.new()
	traffic_reservations = TrafficReservationServiceScript.new()
	traffic_reservations.setup(bottleneck_classifier, safe_interval_planner, wait_for_graph, traffic_priority_policy)
	simulation_lod = NpcSimulationLodServiceScript.new()
	simulation_lod.setup(self, npc_system, main)
	route_authority_v2 = NpcRouteAuthorityV2Script.new()
	route_authority_v2.setup(npc_system, main)
	setup_behavior_services()

func setup(system_node: Node, main_node: Node) -> void:
	npc_system = system_node
	main = main_node
	navigation_backend_config = NavigationBackendConfigScript.from_environment()
	navigation_world.setup(main, change_bus)
	if navmesh_world == null:
		navmesh_world = NavmeshWorldServiceScript.new()
	navmesh_world.setup(navigation_backend_config)
	door_portals.setup(main, self)
	smart_objects.setup(self, door_portals)
	bottleneck_classifier = BottleneckClassifierScript.new()
	safe_interval_planner = SafeIntervalPlannerScript.new()
	wait_for_graph = WaitForGraphScript.new()
	traffic_priority_policy = TrafficPriorityPolicyScript.new()
	traffic_reservations = TrafficReservationServiceScript.new()
	traffic_reservations.setup(bottleneck_classifier, safe_interval_planner, wait_for_graph, traffic_priority_policy)
	door_traversal.setup(door_portals, traffic_reservations, bottleneck_classifier, traffic_priority_policy, wait_for_graph)
	simulation_lod = NpcSimulationLodServiceScript.new()
	simulation_lod.setup(self, npc_system, main)
	route_authority_v2 = NpcRouteAuthorityV2Script.new()
	route_authority_v2.setup(npc_system, main)
	setup_behavior_services()
	telemetry.record_event("_system", &"architecture", "setup", &"none", {
		"architectureVersion": architecture_version,
		"movementStack": movement_stack,
		"navigationBackend": navigation_backend_config.to_summary()
	})

func _physics_process(delta: float) -> void:
	if route_authority_v2 != null:
		route_authority_v2.begin_frame()
	if crowd_velocity_service != null:
		var crowd_entries: Array = npc_system.get("npcs") if npc_system != null and npc_system.get("npcs") is Array else []
		crowd_velocity_service.begin_physics_frame(crowd_entries)
	process_navigation_changes(NAV_CHANGE_EVENTS_PER_PHYSICS_TICK, NAV_CHANGE_OBJECT_IDS_PER_PHYSICS_TICK)
	build_navigation_tiles(NpcConstantsScript.NAV_BUILD_MAX_JOBS_PER_TICK)
	process_navmesh_dirty_regions(1)
	advance_traffic(delta)
	service_active_route_work(delta)
	if crowd_velocity_service != null:
		crowd_velocity_service.end_physics_frame()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_clear_navmesh_world()

func clear() -> void:
	if crowd_velocity_service != null:
		crowd_velocity_service.clear()
	contexts_by_instance_id.clear()
	contexts_by_stable_id.clear()
	blackboards_by_stable_id.clear()
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()
	navigation_backend_config = NavigationBackendConfigScript.from_environment()
	navigation_world = NavigationWorldServiceScript.new()
	navigation_world.setup(main, change_bus)
	_clear_navmesh_world()
	# Route delegates retain the shared navmesh service across a world reset.  Keep
	# that service's identity stable: replacing it here lets those delegates publish
	# into an orphaned NavigationServer map that the active autonomy system can no
	# longer release.
	if navmesh_world == null:
		navmesh_world = NavmeshWorldServiceScript.new()
	navmesh_world.setup(navigation_backend_config)
	door_portals = DoorPortalServiceScript.new()
	door_portals.setup(main, self)
	smart_objects = SmartObjectServiceScript.new()
	smart_objects.setup(self, door_portals)
	door_traversal = DoorTraversalExecutorScript.new()
	bottleneck_classifier = BottleneckClassifierScript.new()
	safe_interval_planner = SafeIntervalPlannerScript.new()
	wait_for_graph = WaitForGraphScript.new()
	traffic_priority_policy = TrafficPriorityPolicyScript.new()
	traffic_reservations = TrafficReservationServiceScript.new()
	traffic_reservations.setup(bottleneck_classifier, safe_interval_planner, wait_for_graph, traffic_priority_policy)
	door_traversal.setup(door_portals, traffic_reservations, bottleneck_classifier, traffic_priority_policy, wait_for_graph)
	simulation_lod = NpcSimulationLodServiceScript.new()
	simulation_lod.setup(self, npc_system, main)
	route_authority_v2 = NpcRouteAuthorityV2Script.new()
	route_authority_v2.setup(npc_system, main)
	setup_behavior_services()

func shutdown_for_process_exit() -> void:
	# clear() deliberately reconstructs services for an in-session world reset.
	# Process exit has the opposite contract: release the navigation map and all
	# service references without allocating a fresh routing graph.
	contexts_by_instance_id.clear()
	contexts_by_stable_id.clear()
	blackboards_by_stable_id.clear()
	if crowd_velocity_service != null:
		crowd_velocity_service.clear()
	_clear_navmesh_world()
	route_authority_v2 = null
	plan_executor = null
	crowd_velocity_service = null
	recovery_policy = null
	task_planner = null
	action_library = null
	goal_selector = null
	perception_service = null
	schedule_service = null
	guard_roster = null
	simulation_lod = null
	traffic_reservations = null
	traffic_priority_policy = null
	wait_for_graph = null
	safe_interval_planner = null
	bottleneck_classifier = null
	door_traversal = null
	smart_objects = null
	door_portals = null
	navmesh_world = null
	navigation_world = null
	navigation_backend_config = null
	change_bus = null
	telemetry = null
	scheduler = null
	npc_system = null
	main = null

func _clear_navmesh_world() -> void:
	if navmesh_world != null:
		navmesh_world.clear()

func setup_behavior_services() -> void:
	var CrowdVelocityServiceScript := preload("res://scripts/npc_ai/movement/NpcCrowdVelocityService.gd")
	crowd_velocity_service = CrowdVelocityServiceScript.new()
	crowd_velocity_service.setup(npc_system, main)
	guard_roster = GuardRosterServiceScript.new()
	schedule_service = NpcScheduleServiceScript.new()
	schedule_service.setup(guard_roster)
	perception_service = NpcPerceptionServiceScript.new()
	perception_service.setup(self, npc_system)
	goal_selector = NpcGoalSelectorScript.new()
	action_library = NpcActionLibraryScript.new()
	task_planner = NpcTaskPlannerScript.new()
	task_planner.setup(action_library, self if _navmesh_backend_active() else navigation_world)
	recovery_policy = NpcRecoveryPolicyScript.new()
	plan_executor = NpcPlanExecutorScript.new()
	plan_executor.setup(self, npc_system, main, {
		"schedule": schedule_service,
		"guardRoster": guard_roster,
		"perception": perception_service,
		"goalSelector": goal_selector,
		"taskPlanner": task_planner,
		"recovery": recovery_policy,
		"crowdVelocity": crowd_velocity_service
	})

func closest_walkable(position: Vector3, max_distance := INF) -> Dictionary:
	if navmesh_world != null and navmesh_world.has_method("closest_walkable"):
		return navmesh_world.closest_walkable(position, max_distance)
	return { "found": false, "reason": "missing_navmesh_world", "position": position, "maxDistance": max_distance }

func world_cell(position: Vector3) -> Vector2i:
	var generated_world = generated_navigation_adapter()
	if generated_world != null and generated_world.has_method("world_cell"):
		return generated_world.world_cell(position)
	return Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))

func approach_cells_for_target(entry: Dictionary, target_position: Vector3, allow_outside := true) -> Array[Vector2i]:
	var generated_world = generated_navigation_adapter()
	if generated_world != null and generated_world.has_method("approach_cells_for_target"):
		return generated_world.approach_cells_for_target(entry, target_position, allow_outside)
	return []

func cell_position(cell: Vector2i) -> Vector3:
	var generated_world = generated_navigation_adapter()
	if generated_world != null and generated_world.has_method("cell_position"):
		return generated_world.cell_position(cell)
	var y := 0.0
	if main != null and main.has_method("surface_y_at_cell"):
		y = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y))) + 0.04
	return Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, y, float(cell.y) * NpcConstantsScript.CELL_SIZE)

func cell_is_standable_goal(entry: Dictionary, cell: Vector2i, allow_outside := false, moving_home := false) -> bool:
	var generated_world = generated_navigation_adapter()
	if generated_world != null and generated_world.has_method("cell_is_standable_goal"):
		return bool(generated_world.cell_is_standable_goal(entry, cell, allow_outside, moving_home))
	return false

func forbidden_private_door_portal_ids_for_entry(entry: Dictionary) -> Array[String]:
	var generated_world = generated_navigation_adapter()
	if generated_world != null and generated_world.has_method("forbidden_private_door_portal_ids_for_entry"):
		return generated_world.forbidden_private_door_portal_ids_for_entry(entry)
	return []

func generated_navigation_adapter():
	if npc_system == null:
		return null
	var pathing = npc_system.get("pathing")
	if pathing == null:
		return null
	if pathing.has_method("ensure_ready"):
		pathing.ensure_ready()
	return pathing.get("navigation_world")

func plan_source_navigation_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if npc_system == null:
		return {
			"ok": false,
			"status": "pending",
			"classification": "pending_nav_data",
			"reason": "missing_npc_system"
		}
	var pathing = npc_system.get("pathing")
	if pathing == null or not pathing.has_method("plan_source_navigation_route"):
		return {
			"ok": false,
			"status": "pending",
			"classification": "pending_nav_data",
			"reason": "missing_source_navigation_pathing"
		}
	return pathing.plan_source_navigation_route(entry, intent)

func begin_update_frame() -> void:
	if plan_executor != null and plan_executor.has_method("begin_update_frame"):
		plan_executor.begin_update_frame()

func register_npc(body: Node, profile: Dictionary, entry: Dictionary):
	if body == null:
		return null
	var context = NpcAgentContextScript.from_profile(body, profile)
	var blackboard = NpcBlackboardScript.new()
	contexts_by_instance_id[body.get_instance_id()] = context
	contexts_by_stable_id[context.stable_id] = context
	blackboards_by_stable_id[context.stable_id] = blackboard
	scheduler.register_agent(context.stable_id)
	entry["agentContext"] = context
	entry["blackboard"] = blackboard
	if guard_roster != null:
		guard_roster.assign_duty_from_entry(context, entry)
	body.set_meta("npc_stable_id", context.stable_id)
	body.set_meta("npc_guard_duty", String(context.guard_duty_kind))
	if simulation_lod != null:
		simulation_lod.register_actor(entry)
	if route_authority_v2 != null:
		route_authority_v2.register_actor(entry)
	telemetry.record_event(context.stable_id, &"registration", "registered", &"none", {
		"canFight": context.can_fight,
		"guardDuty": String(context.guard_duty_kind)
	})
	return context

func update_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
	if plan_executor == null:
		return
	if simulation_lod != null and simulation_lod.should_hold_active_movement(entry):
		record_motion_skipped(entry, "topology_hold")
		return
	if bool(entry.get("abstractSimulated", false)) or String(entry.get("simulationLod", "")) == NpcSimulationLodServiceScript.STATE_ABSTRACT:
		if simulation_lod != null:
			simulation_lod.advance_abstract(entry, delta)
		record_motion_skipped(entry, "abstract")
		return
	if not bool(entry.get("npc_lod_brain_due", true)):
		record_brain_budget_skipped(entry, "lod_brain_not_due")
		return
	record_brain_update(entry)
	plan_executor.update_npc(entry, delta, night_factor)

func advance_npc_motion(entry: Dictionary, delta: float, night_factor: float) -> Dictionary:
	if plan_executor == null:
		return record_motion_skipped(entry, "missing_plan_executor")
	if simulation_lod != null and simulation_lod.should_hold_active_movement(entry):
		return record_motion_skipped(entry, "topology_hold")
	if bool(entry.get("abstractSimulated", false)) or String(entry.get("simulationLod", "")) == NpcSimulationLodServiceScript.STATE_ABSTRACT:
		return record_motion_skipped(entry, "abstract")
	var result: Dictionary = plan_executor.advance_motion_npc(entry, delta, night_factor)
	if bool(result.get("advanced", false)):
		record_motion_update(entry, result)
	else:
		record_motion_skipped(entry, String(result.get("reason", "no_motion_intent")))
	return result


func physics_route_service_owns_motion(entry: Dictionary) -> bool:
	return plan_executor != null and plan_executor.has_method("physics_route_service_owns_motion") and bool(plan_executor.physics_route_service_owns_motion(entry))


func service_active_route_work(delta: float) -> void:
	if plan_executor == null or npc_system == null:
		return
	var entries = npc_system.get("npcs")
	if not (entries is Array):
		return
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		if not physics_route_service_owns_motion(entry):
			continue
		if simulation_lod != null and simulation_lod.should_hold_active_movement(entry):
			record_motion_skipped(entry, "topology_hold")
			continue
		if bool(entry.get("abstractSimulated", false)) or String(entry.get("simulationLod", "")) == NpcSimulationLodServiceScript.STATE_ABSTRACT:
			record_motion_skipped(entry, "abstract")
			continue
		var result: Dictionary = plan_executor.advance_physics_route_service(entry, delta)
		if bool(result.get("advanced", false)):
			record_motion_update(entry, result)
		else:
			record_motion_skipped(entry, String(result.get("reason", "route_service_not_advanced")))


func select_urgent_brain_entries(entries: Array, maximum_count: int) -> Array:
	var selected: Array = []
	if maximum_count <= 0 or entries.is_empty():
		return selected
	var entries_by_stable_id := {}
	var eligible_ids: Array[String] = []
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var stable_id := String(entry.get("id", ""))
		var body := entry.get("body") as Node
		if body != null and is_instance_valid(body) and body.has_meta("npc_stable_id"):
			stable_id = String(body.get_meta("npc_stable_id"))
		if stable_id == "" or entries_by_stable_id.has(stable_id):
			continue
		if not scheduler.registered_ids.has(stable_id):
			scheduler.register_agent(stable_id)
		entries_by_stable_id[stable_id] = entry
		eligible_ids.append(stable_id)
	var selected_ids: Array[String] = scheduler.next_eligible_slice(eligible_ids, maximum_count)
	for stable_id in selected_ids:
		if entries_by_stable_id.has(stable_id):
			selected.append(entries_by_stable_id[stable_id])
	if selected.size() >= maximum_count:
		return selected
	eligible_ids.sort()
	for stable_id in eligible_ids:
		if selected.size() >= maximum_count:
			break
		var entry: Dictionary = entries_by_stable_id[stable_id]
		if not selected.has(entry):
			selected.append(entry)
	return selected

func record_brain_update(entry: Dictionary) -> void:
	var tick := Engine.get_physics_frames()
	entry["npc_brain_updates"] = int(entry.get("npc_brain_updates", 0)) + 1
	entry["npc_last_brain_tick"] = tick
	entry["npc_brain_budget_skipped"] = int(entry.get("npc_brain_budget_skipped", 0))
	entry["npc_brain_budget_skip_streak"] = 0
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_brain_updates", int(entry.get("npc_brain_updates", 0)))
		body.set_meta("npc_last_brain_tick", tick)
		body.set_meta("npc_brain_budget_skip_streak", 0)
	telemetry.increment(&"npc_brain_updates")

func record_brain_budget_skipped(entry: Dictionary, reason := "budget") -> void:
	var count := int(entry.get("npc_brain_budget_skipped", 0)) + 1
	entry["npc_brain_budget_skipped"] = count
	var streak := int(entry.get("npc_brain_budget_skip_streak", 0)) + 1
	entry["npc_brain_budget_skip_streak"] = streak
	entry["npc_brain_skipped_reason"] = reason
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_brain_budget_skipped", count)
		body.set_meta("npc_brain_budget_skip_streak", streak)
		body.set_meta("npc_brain_skipped_reason", reason)
	telemetry.increment(&"npc_brain_budget_skipped")

func record_motion_update(entry: Dictionary, result := {}) -> Dictionary:
	var tick := Engine.get_physics_frames()
	entry["npc_motion_updates"] = int(entry.get("npc_motion_updates", 0)) + 1
	entry["npc_last_motion_tick"] = tick
	entry["npc_motion_skipped_reason"] = ""
	entry["npc_motion_budget_skipped"] = 0
	var intent_kind := String(result.get("intentKind", ""))
	if intent_kind == "" and String(entry.get("routeStatus", "")) in ["moving", "waiting", "pending"]:
		intent_kind = "route"
	if intent_kind == "scripted":
		entry["npc_scripted_order_motion_ticks"] = int(entry.get("npc_scripted_order_motion_ticks", 0)) + 1
	if intent_kind in ["route", "home", "guard", "job", "idle"]:
		entry["npc_active_route_motion_ticks"] = int(entry.get("npc_active_route_motion_ticks", 0)) + 1
	if intent_kind == "door" or String(entry.get("activeDoorPortalId", "")) != "" or String(result.get("classification", "")) == "door_state":
		entry["npc_door_action_motion_ticks"] = int(entry.get("npc_door_action_motion_ticks", 0)) + 1
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_motion_updates", int(entry.get("npc_motion_updates", 0)))
		body.set_meta("npc_last_motion_tick", tick)
		body.set_meta("npc_motion_skipped_reason", "")
		body.set_meta("npc_motion_budget_skipped", 0)
		body.set_meta("npc_active_route_motion_ticks", int(entry.get("npc_active_route_motion_ticks", 0)))
		body.set_meta("npc_scripted_order_motion_ticks", int(entry.get("npc_scripted_order_motion_ticks", 0)))
		body.set_meta("npc_door_action_motion_ticks", int(entry.get("npc_door_action_motion_ticks", 0)))
	telemetry.increment(&"npc_motion_updates")
	if intent_kind == "scripted":
		telemetry.increment(&"npc_scripted_order_motion_ticks")
	if intent_kind in ["route", "home", "guard", "job", "idle"]:
		telemetry.increment(&"npc_active_route_motion_ticks")
	if intent_kind == "door" or String(entry.get("activeDoorPortalId", "")) != "" or String(result.get("classification", "")) == "door_state":
		telemetry.increment(&"npc_door_action_motion_ticks")
	return result

func record_motion_skipped(entry: Dictionary, reason := "no_motion_intent") -> Dictionary:
	entry["npc_motion_skipped_reason"] = reason
	entry["npc_motion_skipped"] = int(entry.get("npc_motion_skipped", 0)) + 1
	var budget_skipped := reason in ["motion_budget", "frame_time_budget"]
	var budget_count := int(entry.get("npc_motion_budget_skipped", 0)) + 1 if budget_skipped else 0
	entry["npc_motion_budget_skipped"] = budget_count
	if reason == "physics_route_service":
		entry["npc_motion_handoff_skipped"] = int(entry.get("npc_motion_handoff_skipped", 0)) + 1
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_motion_skipped_reason", reason)
		body.set_meta("npc_motion_skipped", int(entry.get("npc_motion_skipped", 0)))
		body.set_meta("npc_motion_budget_skipped", budget_count)
	return { "advanced": false, "reason": reason }

func update_simulation_lod(entry: Dictionary, delta: float, observer_position := Vector3.INF, context := {}) -> Dictionary:
	if simulation_lod == null:
		return { "state": "active", "brainDue": true, "reason": "missing_lod_service" }
	var previous_lod := String(entry.get("simulationLod", "active"))
	var result: Dictionary = simulation_lod.update_actor(entry, delta, observer_position, context)
	entry["npc_lod_brain_due"] = bool(result.get("brainDue", true))
	var current_lod := String(entry.get("simulationLod", previous_lod))
	if previous_lod != current_lod:
		if current_lod == NpcSimulationLodServiceScript.STATE_ABSTRACT:
			telemetry.observe_lod_transition("demotion")
		elif current_lod == NpcSimulationLodServiceScript.STATE_ACTIVE:
			telemetry.observe_lod_transition("promotion")
	return result

func inject_schedule_snapshot(snapshot: Dictionary) -> void:
	if schedule_service != null:
		schedule_service.inject_snapshot(snapshot)

func clear_injected_schedule_snapshot() -> void:
	if schedule_service != null:
		schedule_service.clear_injected_snapshot()

func is_inside_home_interior(entry: Dictionary, position: Vector3) -> bool:
	if perception_service == null:
		return false
	return perception_service.is_inside_home_interior(entry, position)

func home_interior_status(entry: Dictionary, position: Vector3) -> Dictionary:
	if perception_service == null:
		return { "strictInside": false, "reason": "missing_perception_service" }
	return perception_service.home_interior_status(entry, position)

func release_action_owned_state(entry: Dictionary, reason := "released") -> void:
	var protected_crossing := npc_protected_door_crossing(entry)
	if protected_crossing.is_empty():
		release_npc_traffic_reservations(entry, reason)
	elif traffic_reservations != null and traffic_reservations.has_method("release_owner_except_group"):
		traffic_reservations.release_owner_except_group(
			String(entry.get("id", "")),
			String(protected_crossing.get("groupId", "")),
			reason
		)
	var body := entry.get("body") as Node
	if protected_crossing.is_empty():
		release_npc_door_hold(body if body != null else String(entry.get("id", "")), true)
	if smart_objects != null and smart_objects.has_method("release_owner"):
		smart_objects.release_owner(String(entry.get("id", "")), reason)

func cancel_active_route_request(entry: Dictionary, reason := "order_replaced") -> Dictionary:
	return supersede_semantic_routes(entry, reason)


func supersede_semantic_routes(entry: Dictionary, reason := "order_replaced", preserved_semantic := "") -> Dictionary:
	if plan_executor == null or not plan_executor.has_method("supersede_semantic_routes"):
		return {"ok": false, "cancelled": false, "reason": "missing_plan_executor"}
	return plan_executor.supersede_semantic_routes(entry, reason, preserved_semantic)


func prepare_scripted_route_order(entry: Dictionary, order_kind: String, reason := "scripted_order") -> Dictionary:
	if plan_executor == null or not plan_executor.has_method("prepare_scripted_route_order"):
		return {"ok": false, "prepared": false, "reason": "missing_plan_executor"}
	return plan_executor.prepare_scripted_route_order(entry, order_kind, reason)


func cleanup_actor_ownership(entry_or_id, reason := "cleanup") -> Dictionary:
	if simulation_lod == null:
		return {}
	return simulation_lod.cleanup_actor_ownership(entry_or_id, reason)

func unregister_npc(body: Node) -> void:
	if body == null:
		return
	var instance_id := body.get_instance_id()
	var context = contexts_by_instance_id.get(instance_id)
	if context == null:
		return
	if simulation_lod != null:
		simulation_lod.unregister_actor(context.stable_id, "actor_unregistered")
	contexts_by_instance_id.erase(instance_id)
	contexts_by_stable_id.erase(context.stable_id)
	blackboards_by_stable_id.erase(context.stable_id)
	scheduler.unregister_agent(context.stable_id)
	telemetry.record_event(context.stable_id, &"registration", "unregistered")

func record_motion(entry: Dictionary, motor_state) -> void:
	if motor_state == null:
		return
	var body := entry.get("body") as Node
	var context = context_for_body(body)
	var stable_id := String(entry.get("id", "npc"))
	if context != null:
		stable_id = String(context.get("stable_id"))
	var displacement: Vector3 = motor_state.get("displacement")
	var requested: Vector3 = motor_state.get("requested_velocity")
	var applied: Vector3 = motor_state.get("applied_velocity")
	var blocked_contact_category := String(motor_state.get("blocked_contact_category"))
	var blocked := bool(motor_state.get("blocked"))
	telemetry.increment(&"motor_frames")
	if blocked:
		telemetry.increment(&"motor_blocked_contacts")
		telemetry.increment(&"motor_blocked_ticks")
	if blocked_contact_category != "":
		telemetry.increment(&"motor_contacts")
	telemetry.record_event(stable_id, &"motor", "motion", &"none", {
		"requestedVelocity": [requested.x, requested.y, requested.z],
		"appliedVelocity": [applied.x, applied.y, applied.z],
		"displacement": [displacement.x, displacement.y, displacement.z],
		"blocked": blocked,
		"blockedContact": blocked_contact_category
	})

func context_for_body(body: Node):
	return contexts_by_instance_id.get(body.get_instance_id()) if body != null else null

func blackboard_for_id(stable_id: String):
	return blackboards_by_stable_id.get(stable_id)

func notify_block_created(cell: Vector3i, block_type: String, block: Node = null) -> void:
	var object_id := "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, block_type]
	if smart_objects != null and block != null and block_type in ["chest", "traderStall", "bed", "workbench", "furnace", "campfire", "anvil"]:
		smart_objects.register_workstation(block, {
			"blockType": block_type,
			"objectId": object_id
		})
	var bounds := _bounds_for_cell(cell)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, object_id, bounds, [NavigationChangeBusScript.tile_key_for_cell(cell)])
	telemetry.increment(&"change_block_created")

func notify_block_removed(cell: Vector3i, block_type: String, block: Node = null) -> void:
	var object_id := "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, block_type]
	if smart_objects != null:
		smart_objects.notify_object_removed(object_id, block)
	var bounds := _bounds_for_cell(cell)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED, object_id, bounds, [NavigationChangeBusScript.tile_key_for_cell(cell)])
	telemetry.increment(&"change_block_removed")

func notify_terrain_edited(cell: Vector2i, old_height: float, new_height: float) -> void:
	var min_y := minf(old_height, new_height) - NpcConstantsScript.CELL_SIZE
	var max_y := maxf(old_height, new_height) + NpcConstantsScript.CELL_SIZE
	var origin := Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE - NpcConstantsScript.CELL_SIZE * 0.5, min_y, float(cell.y) * NpcConstantsScript.CELL_SIZE - NpcConstantsScript.CELL_SIZE * 0.5)
	var bounds := AABB(origin, Vector3(NpcConstantsScript.CELL_SIZE, max_y - min_y, NpcConstantsScript.CELL_SIZE))
	var object_id := "terrain:%d,%d" % [cell.x, cell.y]
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT, object_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds))
	telemetry.increment(&"change_terrain_edit")

func notify_terrain_cells_edited(cells: Array) -> int:
	var bounds_by_tile := {}
	var cell_size := NpcConstantsScript.CELL_SIZE
	for value in cells:
		if not (value is Vector2i):
			continue
		var cell: Vector2i = value
		var tile_key := NavigationChangeBusScript.tile_key_for_cell(cell)
		var origin := Vector3(float(cell.x) * cell_size - cell_size * 0.5, -128.0, float(cell.y) * cell_size - cell_size * 0.5)
		var bounds := AABB(origin, Vector3(cell_size, 256.0, cell_size))
		if bounds_by_tile.has(tile_key) and bounds_by_tile[tile_key] is AABB:
			bounds_by_tile[tile_key] = (bounds_by_tile[tile_key] as AABB).merge(bounds)
		else:
			bounds_by_tile[tile_key] = bounds
	for tile_key_value in bounds_by_tile.keys():
		var tile_key := String(tile_key_value)
		change_bus.emit_change(
			NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT,
			"terrain_tile:%s" % tile_key,
			bounds_by_tile[tile_key],
			[tile_key]
		)
		telemetry.increment(&"change_terrain_edit")
	return bounds_by_tile.size()

func notify_prop_created(prop_id: String, prop: Node = null) -> void:
	if smart_objects != null and prop != null:
		smart_objects.register_resource(prop, { "propId": prop_id })
	_emit_prop_change(NpcEnumsScript.CHANGE_KIND_PROP_CREATED, prop_id, prop)

func notify_prop_removed(prop_id: String, prop: Node = null) -> void:
	if smart_objects != null:
		smart_objects.notify_object_removed("prop:%s" % prop_id, prop)
	_emit_prop_change(NpcEnumsScript.CHANGE_KIND_PROP_REMOVED, prop_id, prop)

func notify_chunk_loaded(chunk_key: Vector2i) -> void:
	var object_id := "chunk:%d,%d" % [chunk_key.x, chunk_key.y]
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, object_id, _bounds_for_chunk(chunk_key), [NavigationChangeBusScript.tile_key_for_chunk(chunk_key)])
	telemetry.increment(&"change_chunk_loaded")

func notify_chunk_unloaded(chunk_key: Vector2i) -> void:
	var object_id := "chunk:%d,%d" % [chunk_key.x, chunk_key.y]
	var tile_key := NavigationChangeBusScript.tile_key_for_chunk(chunk_key)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, object_id, _bounds_for_chunk(chunk_key), [tile_key])
	if simulation_lod != null and npc_system != null:
		var entries = npc_system.get("npcs")
		if entries is Array:
			simulation_lod.handle_tile_unloaded(tile_key, entries)
	telemetry.increment(&"change_chunk_unloaded")

func notify_door_state_changed(door: Node, open: bool) -> void:
	var tile_key := "0,0"
	var object_id := "door"
	var bounds := AABB()
	if door != null:
		object_id = "door:%s" % String(door.name)
		if door.has_meta("cell"):
			var cell: Vector3i = door.get_meta("cell")
			tile_key = NavigationChangeBusScript.tile_key_for_cell(cell)
			bounds = _bounds_for_cell(cell)
		elif door is Node3D:
			tile_key = NavigationChangeBusScript.tile_key_for_world_position((door as Node3D).global_position)
			bounds = AABB((door as Node3D).global_position - Vector3.ONE * 0.5, Vector3.ONE)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_DOOR_STATE, object_id, bounds, [tile_key])
	telemetry.record_event("_system", &"door", "state_changed", NpcEnumsScript.DOOR_STATE_OPEN if open else NpcEnumsScript.DOOR_STATE_CLOSED, { "open": open })

func notify_door_registered(door: Node) -> Dictionary:
	var portal_id := register_door(door)
	if portal_id == "":
		return {"ok": false, "reason": "door_registration_failed"}
	var tile_key := "0,0"
	var object_id := "door"
	var bounds := AABB()
	if door != null:
		object_id = "door:%s" % String(door.name)
		if door.has_meta("cell"):
			var cell: Vector3i = door.get_meta("cell")
			tile_key = NavigationChangeBusScript.tile_key_for_cell(cell)
			bounds = _bounds_for_cell(cell)
		elif door is Node3D:
			var position := (door as Node3D).global_position
			tile_key = NavigationChangeBusScript.tile_key_for_world_position(position)
			bounds = AABB(position - Vector3.ONE * 0.5, Vector3.ONE)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_DOOR_REGISTERED, object_id, bounds, [tile_key])
	telemetry.increment(&"change_door_registered")
	return {"ok": true, "portalId": portal_id}

func unregister_door_portal(portal_id: String) -> Dictionary:
	if door_portals == null or not door_portals.has_method("unregister_portal"):
		return {"ok": false, "reason": "missing_door_portal_authority"}
	if not bool(door_portals.unregister_portal(portal_id)):
		return {"ok": false, "reason": "missing_door_portal", "portalId": portal_id}
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA, "door:%s" % portal_id, AABB(), [])
	telemetry.increment(&"change_door_unregistered")
	return {"ok": true, "portalId": portal_id}

func register_door(door: Node, metadata := {}) -> String:
	if smart_objects == null:
		return ""
	var portal_id: String = smart_objects.register_door(door, metadata)
	if portal_id != "":
		_publish_door_portal_to_navmesh(door)
		telemetry.record_event("_system", &"door", "registered", &"none", {
			"portalId": portal_id
		})
	return portal_id

func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
	if smart_objects == null:
		return null
	var result = smart_objects.request_door_state(door, desired_open, actor, actor_kind, metadata)
	if result != null:
		telemetry.record_event("_system", &"door", "state_request", StringName(String(result.reason)), {
			"desiredOpen": desired_open,
			"actorKind": actor_kind,
			"status": String(result.status),
			"metrics": result.metrics.duplicate(true) if result.metrics is Dictionary else {}
		})
	return result

func request_player_door_use(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
	if smart_objects == null:
		return null
	var result = smart_objects.request_player_door_use(door, actor, actor_kind, metadata)
	if result != null:
		telemetry.record_event("_system", &"door", "player_use_request", StringName(String(result.reason)), {
			"actorKind": actor_kind,
			"status": String(result.status),
			"metrics": result.metrics.duplicate(true) if result.metrics is Dictionary else {}
		})
	return result

func register_smart_resource(prop: Node, metadata := {}) -> String:
	return smart_objects.register_resource(prop, metadata) if smart_objects != null else ""

func register_smart_workstation(block: Node, metadata := {}) -> String:
	return smart_objects.register_workstation(block, metadata) if smart_objects != null else ""

func register_smart_anchor(object_id: String, kind: String, position: Vector3, metadata := {}) -> String:
	return smart_objects.register_anchor(object_id, kind, position, metadata) if smart_objects != null else ""

func reserve_smart_object(object_id: String, object_node: Node, actor: Node, actor_id: String, action: String, metadata := {}):
	if smart_objects == null:
		return null
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RESERVE, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = String(metadata.get("actorKind", "npc"))
	request.metadata["action"] = action
	return smart_objects.request_interaction(request)

func heartbeat_smart_object_reservation(object_id: String, reservation_id: String, actor_id: String, route_metadata := {}) -> Dictionary:
	if smart_objects == null or not smart_objects.has_method("heartbeat_reservation"):
		return { "ok": false, "status": "failed", "reason": "missing_smart_object_service" }
	return smart_objects.heartbeat_reservation(object_id, reservation_id, actor_id, route_metadata)

func complete_smart_object(object_id: String, object_node: Node, actor: Node, actor_id: String, action: String, metadata := {}):
	if smart_objects == null:
		return null
	var command := StringName(String(metadata.get("command", SmartObjectServiceScript.COMMAND_COMPLETE)))
	var request = InteractionRequestScript.make(command, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = String(metadata.get("actorKind", "npc"))
	request.metadata["action"] = action
	if String(metadata.get("request_id", "")) != "":
		request.request_id = String(metadata.get("request_id", ""))
	elif String(request.request_id) == "":
		request.request_id = "%s:%s:%s:%s" % [String(command), object_id, actor_id, action]
	return smart_objects.request_interaction(request)

func release_smart_object(object_id: String, object_node: Node, actor: Node, actor_id: String, reason := "released", metadata := {}):
	if smart_objects == null:
		return null
	var request = InteractionRequestScript.make(SmartObjectServiceScript.COMMAND_RELEASE, object_id, actor_id, metadata)
	request.object_node = object_node
	request.actor_node = actor
	request.actor_kind = String(metadata.get("actorKind", "npc"))
	request.metadata["reason"] = reason
	return smart_objects.request_interaction(request)

func request_npc_door_traversal(door: Node, actor: Node, entry: Dictionary = {}, action: Dictionary = {}) -> Dictionary:
	if door_traversal == null:
		return { "ok": false, "status": "failed", "reason": "missing_door_traversal" }
	var result: Dictionary = door_traversal.request_crossing(door, actor, entry, action)
	if bool(result.get("ok", false)):
		telemetry.increment(&"door_traversal_granted")
		telemetry.observe_door_event("hold")
	else:
		telemetry.increment(&"door_traversal_waiting")
		telemetry.increment(&"reservation_waits")
	return result

func release_npc_door_hold(actor_or_id, schedule_close := true, release_evidence: Dictionary = {}) -> void:
	if door_traversal != null:
		door_traversal.release_actor(actor_or_id, schedule_close, release_evidence)

func cancel_npc_door_crossing(actor_or_id) -> void:
	if door_traversal != null and door_traversal.has_method("cancel_actor"):
		door_traversal.cancel_actor(actor_or_id)

func bind_npc_door_crossing_successor(entry: Dictionary, request_id: String, generation: int, lease_id: String) -> Dictionary:
	if door_traversal == null or not door_traversal.has_method("bind_successor_route"):
		return {"ok": false, "reason": "missing_door_traversal"}
	return door_traversal.bind_successor_route(entry, request_id, generation, lease_id)

func npc_door_crossing_transaction(entry: Dictionary) -> Dictionary:
	if door_traversal == null or not door_traversal.has_method("active_crossing_for_entry"):
		return {}
	return door_traversal.active_crossing_for_entry(entry)

func npc_protected_door_crossing(entry: Dictionary) -> Dictionary:
	if door_traversal == null or not door_traversal.has_method("protected_crossing_for_entry"):
		return {}
	return door_traversal.protected_crossing_for_entry(entry)

func npc_completed_door_crossing(entry: Dictionary) -> Dictionary:
	if door_traversal == null or not door_traversal.has_method("completed_crossing_for_entry"):
		return {}
	return door_traversal.completed_crossing_for_entry(entry)

func advance_traffic(delta: float, mark_external := true) -> void:
	if traffic_reservations != null:
		traffic_reservations.advance(delta)
	if mark_external:
		external_traffic_advanced_since_policy = true

func consume_external_traffic_advance() -> bool:
	if external_traffic_advanced_since_policy:
		external_traffic_advanced_since_policy = false
		return true
	return false

func request_npc_traffic_step(entry: Dictionary, previous: Vector3, candidate: Vector3, world, intent := {}) -> Dictionary:
	if traffic_reservations == null or world == null:
		return { "ok": true, "status": "granted", "reason": "missing_traffic_optional" }
	var owner_id := String(entry.get("id", "npc"))
	var from_cell: Vector2i = world.world_cell(previous)
	var to_cell: Vector2i = world.world_cell(candidate)
	if from_cell == to_cell:
		return { "ok": true, "status": "granted", "reason": "same_cell" }
	if not movement_step_requires_traffic_reservation(entry, from_cell, to_cell, world, intent):
		var active_group := String(entry.get("activeTrafficStepGroup", ""))
		if active_group != "" and traffic_reservations.has_method("release_group"):
			traffic_reservations.release_group(active_group, "open_space_step")
		entry.erase("activeTrafficStepGroup")
		entry.erase("trafficWaitReason")
		return { "ok": true, "status": "granted", "reason": "open_space_step" }
	var generation := int(entry.get("trafficOwnerGeneration", 0))
	if generation <= 0:
		generation = int(entry.get("routeGeneration", entry.get("cancellation_generation", 1)))
		if generation <= 0:
			generation = 1
		entry["trafficOwnerGeneration"] = generation
	var priority_class: String = traffic_priority_policy.priority_class_for(entry, intent) if traffic_priority_policy != null else "idle"
	var result: Dictionary = traffic_reservations.request_movement_step(owner_id, world.cell_key(from_cell), world.cell_key(to_cell), {
		"ownerGeneration": generation,
		"actionGeneration": int(entry.get("trafficActionGeneration", entry.get("actionGeneration", 0))),
		"priority": int(intent.get("priority", entry.get("routePriority", 0))),
		"priorityClass": priority_class,
		"earliestStart": float(intent.get("trafficEarliestStart", traffic_reservations.get("now"))),
		"duration": maxf(float(intent.get("physicsDelta", 1.0 / 60.0)), NpcConstantsScript.TRAFFIC_MOVEMENT_STEP_SECONDS),
		"metadata": { "kind": "movement", "fromCell": [from_cell.x, from_cell.y], "toCell": [to_cell.x, to_cell.y] }
	})
	if bool(result.get("ok", false)):
		entry["activeTrafficStepGroup"] = String(result.get("groupId", ""))
	else:
		entry["trafficWaitReason"] = String(result.get("reason", "traffic_wait"))
		telemetry.increment(&"reservation_waits")
		if String(result.get("reason", "")) == "capacity_conflict":
			telemetry.increment(&"reservation_denials")
	telemetry.observe_traffic_stats(traffic_reservations.stats())
	return result

func request_npc_navigation_transition(entry: Dictionary, action: Dictionary, intent := {}) -> Dictionary:
	if traffic_reservations == null:
		return {"ok": false, "status": "failed", "reason": "missing_traffic_authority"}
	if not navigation_transition_action_is_current(action):
		return {"ok": false, "status": "failed", "reason": "navigation_transition_topology_changed"}
	var owner_id := String(entry.get("id", ""))
	var link_id := String(action.get("linkId", ""))
	if owner_id.is_empty() or link_id.is_empty():
		return {"ok": false, "status": "failed", "reason": "invalid_navigation_transition"}
	var generation := int(entry.get("trafficOwnerGeneration", entry.get("routeGeneration", entry.get("cancellation_generation", 1))))
	if generation <= 0:
		generation = 1
		entry["trafficOwnerGeneration"] = generation
	var priority_class: String = traffic_priority_policy.priority_class_for(entry, intent) if traffic_priority_policy != null else "idle"
	var group_id := "navigation-transition:%s:%s:%d" % [link_id, owner_id, generation]
	var result: Dictionary = traffic_reservations.request_span(owner_id, link_id, {
		"groupId": group_id,
		"ownerGeneration": generation,
		"actionGeneration": int(entry.get("trafficActionGeneration", entry.get("actionGeneration", 0))),
		"priority": int(intent.get("priority", entry.get("routePriority", 0))),
		"priorityClass": priority_class,
		"duration": NpcConstantsScript.TRAFFIC_PORTAL_CROSSING_SECONDS,
		"direction": String(action.get("direction", "unknown")),
		"activeCrossing": true,
		"metadata": {
			"kind": "surface_transition",
			"capacity": maxi(1, int(action.get("capacity", 1))),
			"linkId": link_id,
			"seamCorridorId": String(action.get("seamCorridorId", "")),
			"linkRid": int(action.get("linkRid", 0)),
			"snapshotRevision": String(action.get("snapshotRevision", "")),
			"certifiedCorridorWidth": float(action.get("certifiedCorridorWidth", 0.0))
		}
	})
	result["linkId"] = link_id
	result["groupId"] = String(result.get("groupId", group_id))
	telemetry.observe_traffic_stats(traffic_reservations.stats())
	return result

func navigation_transition_action_is_current(action: Dictionary) -> bool:
	return navmesh_world != null \
		and navmesh_world.has_method("navigation_link_action_is_current") \
		and bool(navmesh_world.call("navigation_link_action_is_current", action))

func revalidate_navigation_transition_action(action: Dictionary, existing_certificate: Dictionary) -> Dictionary:
	var navigation_adapter = generated_navigation_adapter()
	if navigation_adapter == null or not navigation_adapter.has_method("cached_static_tile_snapshot") or not navigation_adapter.has_method("validate_surface_transition_action"):
		return {"ok": false, "reason": "navigation_transition_validation_authority_unavailable"}
	if not navigation_adapter.has_method("surface_transition_certificate_matches_action") \
		or not bool(navigation_adapter.call("surface_transition_certificate_matches_action", action, existing_certificate)):
		return {"ok": false, "reason": "navigation_transition_certificate_action_mismatch"}
	var snapshot: Dictionary = navigation_adapter.cached_static_tile_snapshot(true, true)
	var current_revision := int(snapshot.get("staticSnapshotRevision", -1))
	var current_door_revision := int(snapshot.get("doorStateRevision", -1))
	if current_revision >= 0 \
		and current_revision == int(existing_certificate.get("staticSnapshotRevision", -2)) \
		and current_door_revision >= 0 \
		and current_door_revision == int(existing_certificate.get("doorStateRevision", -2)):
		return {"ok": true, "reason": "", "certificate": existing_certificate, "revalidated": false, "staticSnapshotRevision": current_revision, "doorStateRevision": current_door_revision}
	var certificate: Dictionary = navigation_adapter.validate_surface_transition_action(snapshot, action)
	return {
		"ok": bool(certificate.get("ok", false)),
		"reason": String(certificate.get("reason", "navigation_transition_corridor_changed")),
		"certificate": certificate,
		"revalidated": true,
		"staticSnapshotRevision": current_revision,
		"doorStateRevision": current_door_revision
	}

func navigation_transition_infrastructure_readiness() -> Dictionary:
	var navigation_adapter = generated_navigation_adapter()
	var validator_ready: bool = navigation_adapter != null \
		and navigation_adapter.has_method("cached_static_tile_snapshot") \
		and navigation_adapter.has_method("validate_surface_transition_action") \
		and navigation_adapter.has_method("surface_transition_certificate_matches_action")
	return {
		"validatorReady": validator_ready,
		"trafficReady": traffic_reservations != null,
		"validatorRevision": String(navigation_adapter.call("revision")) if validator_ready and navigation_adapter.has_method("revision") else ""
	}

func release_npc_navigation_transition(entry: Dictionary, reason := "navigation_transition_cleared") -> int:
	if traffic_reservations == null:
		return 0
	var active: Dictionary = entry.get("activeNavigationTransition", {}) if entry.get("activeNavigationTransition", {}) is Dictionary else {}
	var pending: Dictionary = entry.get("pendingNavigationTransition", {}) if entry.get("pendingNavigationTransition", {}) is Dictionary else {}
	var group_id := String(active.get("groupId", pending.get("groupId", "")))
	var released: int = int(traffic_reservations.release_group(group_id, reason)) if not group_id.is_empty() else 0
	entry.erase("activeNavigationTransition")
	entry.erase("pendingNavigationTransition")
	return released

func movement_step_requires_traffic_reservation(entry: Dictionary, from_cell: Vector2i, to_cell: Vector2i, world, intent := {}) -> bool:
	if bool(intent.get("requiresTrafficReservation", false)):
		return true
	if String(entry.get("activeDoorPortalId", "")) != "" or String(entry.get("activeDoorTrafficGroupId", "")) != "":
		return true
	var route_kind := String(intent.get("kind", ""))
	if route_kind in ["door", "portal"]:
		return true
	if world == null or not world.has_method("door_at"):
		return false
	var snapshot: Dictionary = {}
	if world.has_method("cached_validation_snapshot"):
		snapshot = world.cached_validation_snapshot(entry, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	elif world.has_method("build_snapshot"):
		snapshot = world.build_snapshot(entry, bool(intent.get("allowOutside", false)), bool(intent.get("movingHome", false)))
	if snapshot.is_empty():
		return false
	return world.door_at(snapshot, from_cell) != null or world.door_at(snapshot, to_cell) != null

func release_npc_traffic_reservations(entry_or_id, reason := "released") -> int:
	if traffic_reservations == null:
		return 0
	var owner_id := ""
	if entry_or_id is Dictionary:
		owner_id = String((entry_or_id as Dictionary).get("id", ""))
	else:
		owner_id = String(entry_or_id)
	if owner_id == "":
		return 0
	return traffic_reservations.release_owner(owner_id, reason)

func release_npc_traffic_generation(entry: Dictionary, reason := "generation_replaced") -> int:
	if traffic_reservations == null:
		return 0
	var owner_id := String(entry.get("id", ""))
	if owner_id == "":
		return 0
	var generation := int(entry.get("trafficOwnerGeneration", 0))
	if generation <= 0:
		return 0
	return traffic_reservations.release_owner_generation(owner_id, generation, reason)

func process_door_policies(delta: float, actors: Array = []) -> Dictionary:
	if door_portals == null:
		return { "closed": 0, "blocked": 0, "scheduled": 0 }
	var result: Dictionary = door_portals.process(delta, actors)
	if int(result.get("closed", 0)) > 0:
		telemetry.observe_door_event("close")
	if int(result.get("blocked", 0)) > 0:
		telemetry.observe_door_event("obstruction_reverse")
	return result

func emit_door_state_revision(door: Node, open: bool, reason: String, revision: int) -> void:
	if door != null and is_instance_valid(door):
		door.set_meta("door_state_revision", revision)
	_publish_door_portal_to_navmesh(door, { "open": open, "stateRevision": revision, "reason": reason })
	notify_door_state_changed(door, open)
	telemetry.record_event("_system", &"door", "revision", NpcEnumsScript.DOOR_STATE_OPEN if open else NpcEnumsScript.DOOR_STATE_CLOSED, {
		"reason": reason,
		"revision": revision
	})

func notify_structure_metadata_changed(structure_id: String, bounds: AABB, metadata := {}) -> void:
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA, "structure:%s" % structure_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds))
	telemetry.record_event("_system", &"semantic", "structure_metadata", &"none", metadata)


func register_building_navigation_manifest(manifest: Dictionary) -> Dictionary:
	var building_id := String(manifest.get("buildingId", manifest.get("sourceBlueprintId", "")))
	if building_id == "":
		return { "ok": false, "reason": "missing_building_id" }
	var snapshot: Dictionary = manifest.duplicate(true)
	building_navigation_manifests[building_id] = snapshot
	var bounds: AABB = snapshot.get("bounds", AABB()) if snapshot.get("bounds", AABB()) is AABB else AABB()
	notify_structure_metadata_changed(building_id, bounds, {
		"source": "building_part_navigation_manifest",
		"supportCount": int(snapshot.get("supportCount", 0)),
		"verticalLinkCount": int(snapshot.get("verticalLinkCount", 0))
	})
	return {
		"ok": true,
		"buildingId": building_id,
		"supportCount": int(snapshot.get("supportCount", 0)),
		"verticalLinkCount": int(snapshot.get("verticalLinkCount", 0))
	}


func unregister_building_navigation_manifest(building_id: String) -> Dictionary:
	if building_id == "" or not building_navigation_manifests.has(building_id):
		return { "ok": false, "reason": "missing_building_manifest" }
	var manifest: Dictionary = building_navigation_manifests.get(building_id, {}) as Dictionary
	building_navigation_manifests.erase(building_id)
	var bounds: AABB = manifest.get("bounds", AABB()) if manifest.get("bounds", AABB()) is AABB else AABB()
	notify_structure_metadata_changed(building_id, bounds, { "source": "building_part_navigation_manifest", "removed": true })
	return { "ok": true, "buildingId": building_id }


func building_navigation_manifest_snapshot() -> Array[Dictionary]:
	var ids: Array = building_navigation_manifests.keys()
	ids.sort()
	var manifests: Array[Dictionary] = []
	for id_value in ids:
		var manifest: Dictionary = building_navigation_manifests.get(id_value, {}) as Dictionary
		if not manifest.is_empty():
			manifests.append(manifest.duplicate(true))
	return manifests


func prove_building_door_topology(building_manifest: Dictionary, residence_manifest: Dictionary) -> Dictionary:
	var navigation_adapter = generated_navigation_adapter()
	if navmesh_world == null or navigation_adapter == null:
		return {"ready": false, "reason": "navigation_topology_authority_unavailable"}
	if navmesh_world.has_method("sync_navigation_map_if_dirty"):
		navmesh_world.sync_navigation_map_if_dirty()
	var map_readiness: Dictionary = navmesh_world.navigation_map_readiness() if navmesh_world.has_method("navigation_map_readiness") else {}
	if not bool(map_readiness.get("ready", false)) or int(map_readiness.get("iterationId", 0)) <= 0:
		return {"ready": false, "retryable": true, "classification": "pending_nav_data", "reason": "navigation_map_iteration_pending", "mapReadiness": map_readiness}
	var doors_by_part_id := {}
	for door_value in building_manifest.get("doors", []) as Array:
		if door_value is Dictionary:
			doors_by_part_id[String((door_value as Dictionary).get("sourcePartId", ""))] = door_value
	var installed_door_links: Dictionary = (navmesh_world.debug_snapshot() as Dictionary).get("doorLinks", {}) as Dictionary
	var proofs: Array[Dictionary] = []
	var all_ready := true
	var any_retryable_pending := false
	var any_static_failure := false
	for citizen_value in residence_manifest.get("citizens", []) as Array:
		if not (citizen_value is Dictionary):
			continue
		var citizen: Dictionary = citizen_value
		var door_part_id := String(citizen.get("doorPartId", ""))
		var source_door: Dictionary = doors_by_part_id.get(door_part_id, {}) as Dictionary
		var portal_id := String(source_door.get("id", citizen.get("doorPortalId", "")))
		var owner_tile_key := String(source_door.get("ownerTileKey", ""))
		var descriptor_link := {}
		if not owner_tile_key.is_empty() and navigation_adapter.has_method("build_navmesh_tile_snapshot"):
			var tile_snapshot: Dictionary = navigation_adapter.build_navmesh_tile_snapshot(owner_tile_key)
			for link_value in tile_snapshot.get("doorLinks", []) as Array:
				if link_value is Dictionary and String((link_value as Dictionary).get("portalId", "")) == portal_id:
					descriptor_link = link_value
					break
		var source_links: Array[Dictionary] = []
		for link_value in installed_door_links.get(portal_id, []) as Array:
			if link_value is Dictionary and bool((link_value as Dictionary).get("sourceDoor", false)):
				source_links.append(link_value)
		var installed_link: Dictionary = source_links[0] if source_links.size() == 1 else {}
		var start: Vector3 = installed_link.get("startPosition", Vector3.INF) as Vector3
		var end: Vector3 = installed_link.get("endPosition", Vector3.INF) as Vector3
		var home: Vector3 = citizen.get("homePosition", Vector3.INF) as Vector3
		var porch: Vector3 = citizen.get("porchPosition", Vector3.INF) as Vector3
		var enabled_query: Dictionary = navmesh_world.call("_query_path_points", home, porch, {"queryApi": "query_path"}) as Dictionary if home.is_finite() and porch.is_finite() else {}
		var enabled_path: Array[Vector3] = []
		for point_value in enabled_query.get("path", []) as Array:
			if point_value is Vector3:
				enabled_path.append(point_value as Vector3)
		var disabled_path: Array = navmesh_world.diagnostic_query_path_without_door_links(home, porch, [portal_id], {"queryApi": "query_path"}) if home.is_finite() and porch.is_finite() and navmesh_world.has_method("diagnostic_query_path_without_door_links") else []
		var enabled_actions: Dictionary = navmesh_world.diagnostic_door_actions_for_path(enabled_path, {}) if navmesh_world.has_method("diagnostic_door_actions_for_path") else {}
		var enabled_endpoint: Vector3 = enabled_path.back() as Vector3 if not enabled_path.is_empty() and enabled_path.back() is Vector3 else Vector3.INF
		var disabled_endpoint: Vector3 = disabled_path.back() as Vector3 if not disabled_path.is_empty() and disabled_path.back() is Vector3 else Vector3.INF
		var start_owner: Dictionary = navmesh_world.call("_closest_walkable_from_server", start, 0.48) as Dictionary if start.is_finite() else {}
		var end_owner: Dictionary = navmesh_world.call("_closest_walkable_from_server", end, 0.48) as Dictionary if end.is_finite() else {}
		var home_owner: Dictionary = navmesh_world.call("_closest_walkable_from_server", home, 0.48) as Dictionary if home.is_finite() else {}
		var porch_owner: Dictionary = navmesh_world.call("_closest_walkable_from_server", porch, 0.48) as Dictionary if porch.is_finite() else {}
		var residence_link_ids: Array[String] = []
		var residence_part_prefix := "castle_%s__" % String(citizen.get("residenceId", ""))
		for link_collection_key in ["verticalLinks", "interiorPassageLinks"]:
			for link_value in building_manifest.get(link_collection_key, []) as Array:
				if not (link_value is Dictionary):
					continue
				var link: Dictionary = link_value
				if String(link.get("id", "")).contains(residence_part_prefix):
					residence_link_ids.append(String(link.get("id", "")))
		residence_link_ids.sort()
		var home_to_door_query: Dictionary = navmesh_world.call("_query_path_points", home, start, {"queryApi": "query_path"}) as Dictionary if home.is_finite() and start.is_finite() else {}
		var home_to_door_path: Array = home_to_door_query.get("path", []) as Array if home_to_door_query.get("path", []) is Array else []
		var home_to_door_without_links: Array = navmesh_world.diagnostic_query_path_without_navigation_links(home, start, residence_link_ids, {"queryApi": "query_path"}) if home.is_finite() and start.is_finite() and not residence_link_ids.is_empty() and navmesh_world.has_method("diagnostic_query_path_without_navigation_links") else []
		var support_match := String(descriptor_link.get("startSupportId", "")) == String(source_door.get("interiorSupportId", "")) and String(descriptor_link.get("endSupportId", "")) == String(source_door.get("exteriorSupportId", "")) and String(installed_link.get("startSupportId", "")) == String(source_door.get("interiorSupportId", "")) and String(installed_link.get("endSupportId", "")) == String(source_door.get("exteriorSupportId", ""))
		var porch_server_position: Vector3 = porch_owner.get("position", Vector3.INF) as Vector3
		var enabled_crosses := enabled_endpoint.is_finite() and porch_server_position.is_finite() and enabled_endpoint.distance_to(porch_server_position) <= NpcConstantsScript.CORRIDOR_ARRIVAL_STOP_RADIUS
		var disabled_crosses := disabled_endpoint.is_finite() and porch_server_position.is_finite() and disabled_endpoint.distance_to(porch_server_position) <= NpcConstantsScript.CORRIDOR_ARRIVAL_STOP_RADIUS
		var home_endpoint: Vector3 = home_to_door_path.back() as Vector3 if not home_to_door_path.is_empty() and home_to_door_path.back() is Vector3 else Vector3.INF
		var home_without_links_endpoint: Vector3 = home_to_door_without_links.back() as Vector3 if not home_to_door_without_links.is_empty() and home_to_door_without_links.back() is Vector3 else Vector3.INF
		var home_reaches_door := home_endpoint.is_finite() and home_endpoint.distance_to(start) <= 0.001
		var home_requires_declared_links := not home_without_links_endpoint.is_finite() or home_without_links_endpoint.distance_to(start) > 0.001
		var requires_declared_transition := home.is_finite() and start.is_finite() and absf(home.y - start.y) > NpcConstantsScript.DEFAULT_NPC_STEP_UP
		var exact_portal_action := false
		for action_value in enabled_actions.values():
			if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == portal_id:
				exact_portal_action = true
				break
		var installed_dirty_serial := int(installed_link.get("installedDirtySerial", -1))
		var installed_iteration_id := int(installed_link.get("installedIterationId", -1))
		var published_after_install := installed_dirty_serial >= 0 and int(map_readiness.get("syncedSerial", -1)) >= installed_dirty_serial and (not bool(map_readiness.get("hasIterationApi", false)) or int(map_readiness.get("iterationId", -1)) > installed_iteration_id)
		var passed := bool(source_door.get("sourcePortalReady", false)) and not descriptor_link.is_empty() and source_links.size() == 1 and support_match and published_after_install and bool(home_owner.get("found", false)) and bool(start_owner.get("found", false)) and bool(end_owner.get("found", false)) and bool(porch_owner.get("found", false)) and home_reaches_door and (not requires_declared_transition or (not residence_link_ids.is_empty() and home_requires_declared_links)) and enabled_crosses and exact_portal_action and not disabled_crosses
		var pending_reasons: Array[String] = []
		var static_failure_reasons: Array[String] = []
		if not published_after_install:
			pending_reasons.append("navigation_map_iteration_after_link_install_pending")
		if not bool(source_door.get("sourcePortalReady", false)):
			static_failure_reasons.append("source_portal_not_ready")
		if descriptor_link.is_empty():
			static_failure_reasons.append("descriptor_link_missing")
		if source_links.size() != 1:
			static_failure_reasons.append("installed_source_link_cardinality_invalid")
		if not support_match:
			static_failure_reasons.append("support_provenance_mismatch")
		if not bool(home_owner.get("found", false)) or not bool(start_owner.get("found", false)) or not bool(end_owner.get("found", false)) or not bool(porch_owner.get("found", false)):
			static_failure_reasons.append("server_endpoint_owner_missing")
		if not home_reaches_door:
			static_failure_reasons.append("home_does_not_reach_door")
		if requires_declared_transition and (residence_link_ids.is_empty() or not home_requires_declared_links):
			static_failure_reasons.append("declared_home_transition_invalid")
		if not enabled_crosses:
			static_failure_reasons.append("enabled_door_does_not_cross")
		if not exact_portal_action:
			static_failure_reasons.append("exact_portal_action_missing")
		if disabled_crosses:
			static_failure_reasons.append("disabled_door_still_crosses")
		any_retryable_pending = any_retryable_pending or (not pending_reasons.is_empty() and static_failure_reasons.is_empty())
		any_static_failure = any_static_failure or not static_failure_reasons.is_empty()
		proofs.append({
			"actorId": String(citizen.get("id", "")),
			"residenceId": String(citizen.get("residenceId", "")),
			"portalId": portal_id,
			"passed": passed,
			"sourceDoor": source_door.duplicate(true),
			"descriptorLink": descriptor_link.duplicate(true),
			"installedLinks": source_links.duplicate(true),
			"supportProvenanceMatch": support_match,
			"sourcePortalReady": bool(source_door.get("sourcePortalReady", false)),
			"publishedAfterInstall": published_after_install,
			"homeSupportId": String(citizen.get("homeSupportId", "")),
			"residenceNavigationLinkIds": residence_link_ids,
			"homeServerOwner": home_owner,
			"porchServerOwner": porch_owner,
			"porchPosition": porch,
			"porchServerPosition": porch_server_position,
			"homeToDoorPath": home_to_door_path.duplicate(),
			"homeToDoorWithoutResidenceLinks": home_to_door_without_links.duplicate(),
			"homeReachesDoor": home_reaches_door,
			"homeRequiresDeclaredLinks": home_requires_declared_links,
			"requiresDeclaredTransition": requires_declared_transition,
			"serverStartOwner": start_owner,
			"serverEndOwner": end_owner,
			"enabledPath": enabled_path.duplicate(),
			"enabledEndpoint": enabled_endpoint,
			"enabledEndpointDistance": enabled_endpoint.distance_to(porch_server_position) if enabled_endpoint.is_finite() and porch_server_position.is_finite() else INF,
			"enabledCrosses": enabled_crosses,
			"enabledDoorActions": enabled_actions.duplicate(true),
			"exactPortalAction": exact_portal_action,
			"disabledPath": disabled_path.duplicate(),
			"disabledEndpoint": disabled_endpoint,
			"disabledEndpointDistance": disabled_endpoint.distance_to(porch_server_position) if disabled_endpoint.is_finite() and porch_server_position.is_finite() else INF,
			"disabledCrosses": disabled_crosses,
			"pendingReasons": pending_reasons,
			"staticFailureReasons": static_failure_reasons
		})
		all_ready = all_ready and passed
	var ready := all_ready and not proofs.is_empty()
	var retryable := not ready and not any_static_failure and any_retryable_pending
	return {
		"ready": ready,
		"retryable": retryable,
		"classification": "ready" if ready else "pending_nav_data" if retryable else "invalid_topology",
		"reason": "" if ready else "building_door_topology_publication_pending" if retryable else "building_door_topology_invalid",
		"mapReadiness": map_readiness,
		"proofs": proofs
	}


func register_navigation_collision_manifest(manifest: Dictionary) -> Dictionary:
	var manifest_id := String(manifest.get("manifestId", ""))
	if manifest_id == "":
		return { "ok": false, "reason": "missing_navigation_collision_manifest_id" }
	var snapshot: Dictionary = manifest.duplicate(true)
	navigation_collision_manifests[manifest_id] = snapshot
	var bounds: AABB = snapshot.get("bounds", AABB()) if snapshot.get("bounds", AABB()) is AABB else AABB()
	notify_structure_metadata_changed(manifest_id, bounds, {
		"source": "navigation_collision_manifest",
		"sourceKind": String(snapshot.get("sourceKind", "")),
		"staticCollisionCount": int(snapshot.get("staticCollisionCount", 0))
	})
	return {
		"ok": true,
		"manifestId": manifest_id,
		"staticCollisionCount": int(snapshot.get("staticCollisionCount", 0))
	}


func unregister_navigation_collision_manifest(manifest_id: String) -> Dictionary:
	if manifest_id == "" or not navigation_collision_manifests.has(manifest_id):
		return { "ok": false, "reason": "missing_navigation_collision_manifest" }
	var manifest: Dictionary = navigation_collision_manifests.get(manifest_id, {}) as Dictionary
	navigation_collision_manifests.erase(manifest_id)
	var bounds: AABB = manifest.get("bounds", AABB()) if manifest.get("bounds", AABB()) is AABB else AABB()
	notify_structure_metadata_changed(manifest_id, bounds, { "source": "navigation_collision_manifest", "removed": true })
	return { "ok": true, "manifestId": manifest_id }


func navigation_collision_manifest_snapshot() -> Array[Dictionary]:
	var ids: Array = navigation_collision_manifests.keys()
	ids.sort()
	var manifests: Array[Dictionary] = []
	for id_value in ids:
		var manifest: Dictionary = navigation_collision_manifests.get(id_value, {}) as Dictionary
		if not manifest.is_empty():
			manifests.append(manifest.duplicate(true))
	return manifests

func notify_semantic_changed(semantic_id: String, bounds: AABB, metadata := {}) -> void:
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED, "semantic:%s" % semantic_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds))
	telemetry.record_event("_system", &"semantic", "changed", &"none", metadata)

func register_semantic_region(kind: StringName, region_id: String, bounds: AABB, metadata := {}) -> int:
	if navigation_world == null or region_id == "":
		return 0
	if smart_objects != null and String(kind) in ["guard_post", "work_anchor"]:
		var anchor_metadata := metadata.duplicate(true) if metadata is Dictionary else {}
		anchor_metadata["bounds"] = bounds
		smart_objects.register_anchor("semantic:%s" % region_id, String(kind), bounds.position + bounds.size * 0.5, anchor_metadata)
	var revision: int = navigation_world.register_semantic_region(kind, region_id, bounds, metadata)
	if navmesh_world != null and navigation_backend_config != null and navigation_backend_config.use_navmesh():
		navmesh_world.register_semantic_descriptor(String(kind), region_id, bounds, metadata)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED, "semantic:%s" % region_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds), revision)
	telemetry.record_event("_system", &"semantic", "registered", kind, {
		"regionId": region_id,
		"revision": revision
	})
	return revision

func process_navigation_changes(max_events := -1, max_object_ids := -1) -> Array:
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var bus_start: int = monitor.begin_section("nav_change_bus_process") if monitor != null else Time.get_ticks_usec()
	var events: Array = navigation_world.process_change_bus(max_events, max_object_ids) if navigation_world != null else []
	if monitor != null:
		var object_id_count := 0
		for event_value in events:
			if event_value is Dictionary and (event_value as Dictionary).get("objectIds", []) is Array:
				object_id_count += ((event_value as Dictionary).get("objectIds", []) as Array).size()
		monitor.increment_counter("nav_change_events_processed", events.size())
		monitor.increment_counter("nav_change_object_ids_processed", object_id_count)
		monitor.end_section("nav_change_bus_process", bus_start)
	if navmesh_world != null and navigation_backend_config != null and navigation_backend_config.use_navmesh() and not events.is_empty():
		var navmesh_start: int = monitor.begin_section("navmesh_event_apply") if monitor != null else Time.get_ticks_usec()
		navmesh_world.apply_navigation_events(events)
		if monitor != null:
			monitor.end_section("navmesh_event_apply", navmesh_start)
	if npc_system != null and npc_system.has_method("process_navigation_route_changes") and not events.is_empty():
		var route_start: int = monitor.begin_section("route_event_apply") if monitor != null else Time.get_ticks_usec()
		npc_system.call("process_navigation_route_changes", events)
		if monitor != null:
			monitor.end_section("route_event_apply", route_start)
	return events

func pending_navigation_change_count() -> int:
	var change_count := int(change_bus.pending_count()) if change_bus != null and change_bus.has_method("pending_count") else 0
	var replacement_count := int(npc_system.call("navigation_snapshot_replacement_pending_count")) if npc_system != null and npc_system.has_method("navigation_snapshot_replacement_pending_count") else 0
	return change_count + replacement_count

func process_navmesh_dirty_regions(max_jobs := 1) -> Array:
	if not _navmesh_backend_active():
		return []
	if navmesh_world == null or not navmesh_world.has_method("process_dirty_regions"):
		return []
	return navmesh_world.process_dirty_regions(max_jobs)


func request_navigation_tile(snapshot: Dictionary, priority := 0, profile = null) -> Dictionary:
	var result: Dictionary = navigation_world.request_tile(snapshot, priority, profile) if navigation_world != null else {}
	if navigation_backend_config != null and navigation_backend_config.use_navmesh():
		var tile_key := String(snapshot.get("tileKey", "")).strip_edges()
		if not tile_key.is_empty() and npc_system != null and npc_system.has_method("request_navigation_snapshot_replacement_priority"):
			result["navmeshPublication"] = npc_system.call("request_navigation_snapshot_replacement_priority", [tile_key], "navigation_tile_request")
	if navigation_world != null:
		telemetry.observe_navigation_stats(navigation_world.stats())
	return result

func _publish_door_portal_to_navmesh(door: Node, extra := {}) -> void:
	if not _navmesh_backend_active() or navmesh_world == null or door_portals == null:
		return
	var portal = door_portals.portal_for_door(door) if door != null and door_portals.has_method("portal_for_door") else null
	if portal == null:
		return
	var summary: Dictionary = portal.to_summary() if portal.has_method("to_summary") else {}
	if extra is Dictionary:
		for key in (extra as Dictionary).keys():
			summary[key] = (extra as Dictionary)[key]
	if door != null and is_instance_valid(door):
		summary["door"] = door
	if navmesh_world.has_method("set_door_portal_state"):
		navmesh_world.set_door_portal_state(summary)

func _navmesh_backend_active() -> bool:
	return navmesh_world != null and navigation_backend_config != null and navigation_backend_config.use_navmesh()

func prefetch_for_entry(entry: Dictionary) -> Dictionary:
	return simulation_lod.prefetch_for_entry(entry) if simulation_lod != null else {}

func snapshot_lifecycle_fact(entry: Dictionary) -> Dictionary:
	return simulation_lod.durable_snapshot(entry) if simulation_lod != null else {}

func apply_lifecycle_fact(entry: Dictionary, fact, options := {}) -> Dictionary:
	return simulation_lod.apply_durable_snapshot(entry, fact, options) if simulation_lod != null else {}

func snapshot_has_transient_lifecycle_state(snapshot: Dictionary) -> bool:
	return simulation_lod.snapshot_has_transient_state(snapshot) if simulation_lod != null else false

func build_navigation_tiles(max_jobs := 1) -> Array:
	if navigation_world == null:
		return []
	var started := Time.get_ticks_usec()
	var built: Array = navigation_world.build_next_tiles(max_jobs, NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC)
	var duration_usec := Time.get_ticks_usec() - started
	telemetry.record_duration(&"navigation_build_work", duration_usec, NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC)
	if main != null and main.get("runtime_perf_monitor") != null:
		main.get("runtime_perf_monitor").observe_duration("navigation_tile_build", float(duration_usec) / 1000.0)
	telemetry.observe_navigation_stats(navigation_world.stats())
	return built

func navigation_backend_summary() -> Dictionary:
	var summary: Dictionary = navigation_backend_config.to_summary() if navigation_backend_config != null else NavigationBackendConfigScript.default_config().to_summary()
	if navmesh_world != null:
		summary["navmeshWorld"] = navmesh_world.stats()
	return summary

func stats() -> Dictionary:
	return {
		"architectureVersion": architecture_version,
		"movementStack": movement_stack,
		"navigationBackend": navigation_backend_summary(),
		"contexts": contexts_by_stable_id.size(),
		"scheduler": scheduler.stats(),
		"telemetry": telemetry.stats(),
		"changeBus": change_bus.stats(),
		"navigationWorld": navigation_world.stats(),
		"navmeshWorld": navmesh_world.stats() if navmesh_world != null else {},
		"smartObjects": smart_objects.stats() if smart_objects != null else {},
		"doorPortals": door_portals.stats() if door_portals != null else {},
		"doorTraversal": door_traversal.stats() if door_traversal != null else {},
		"traffic": traffic_reservations.stats() if traffic_reservations != null else {},
		"simulationLod": simulation_lod.stats() if simulation_lod != null else {},
		"routeAuthorityV2": route_authority_v2.stats() if route_authority_v2 != null else {},
		"guardRoster": guard_roster.summary() if guard_roster != null else {},
		"behavior": plan_executor.stats() if plan_executor != null else {}
	}

func route_authority_v2_debug_for_entry(entry: Dictionary) -> Dictionary:
	return route_authority_v2.debug_for_entry(entry) if route_authority_v2 != null else {}

func route_authority_v2_telemetry_for_entry(entry: Dictionary) -> Dictionary:
	return route_authority_v2.telemetry_for_entry(entry) if route_authority_v2 != null else {}

func route_authority_v2_debug_snapshot() -> Dictionary:
	return route_authority_v2.debug_snapshot() if route_authority_v2 != null else {}

func _bounds_for_cell(cell: Vector3i) -> AABB:
	var size := Vector3.ONE * NpcConstantsScript.CELL_SIZE
	var origin := Vector3(float(cell.x), float(cell.y), float(cell.z)) * NpcConstantsScript.CELL_SIZE - size * 0.5
	return AABB(origin, size)

func _bounds_for_chunk(chunk_key: Vector2i) -> AABB:
	var span := float(NpcConstantsScript.NAV_TILE_CELL_SIZE) * NpcConstantsScript.CELL_SIZE
	var origin := Vector3(float(chunk_key.x) * span, -128.0, float(chunk_key.y) * span)
	return AABB(origin, Vector3(span, 256.0, span))

func _emit_prop_change(kind: StringName, prop_id: String, prop: Node = null) -> void:
	var object_id := "prop:%s" % prop_id
	var bounds := AABB()
	if prop is Node3D:
		var position := (prop as Node3D).global_position
		bounds = AABB(position - Vector3.ONE * NpcConstantsScript.CELL_SIZE * 0.5, Vector3.ONE * NpcConstantsScript.CELL_SIZE)
	var tile_keys := NavigationChangeBusScript.tile_keys_for_bounds(bounds)
	change_bus.emit_change(kind, object_id, bounds, tile_keys)
	telemetry.increment(&"change_prop_removed" if kind == NpcEnumsScript.CHANGE_KIND_PROP_REMOVED else &"change_prop_created")
