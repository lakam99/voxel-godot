extends Node
class_name NpcAutonomySystem

const NpcAgentContextScript := preload("res://scripts/npc_ai/NpcAgentContext.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcBrainSchedulerScript := preload("res://scripts/npc_ai/NpcBrainScheduler.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
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

var npc_system: Node
var main: Node
var architecture_version := NpcConstantsScript.ARCHITECTURE_VERSION
var locomotion_mode := NpcConstantsScript.LEGACY_LOCOMOTION_MODE
var contexts_by_instance_id := {}
var contexts_by_stable_id := {}
var blackboards_by_stable_id := {}
var scheduler
var telemetry
var change_bus
var navigation_world
var door_portals
var smart_objects
var door_traversal
var bottleneck_classifier
var safe_interval_planner
var wait_for_graph
var traffic_priority_policy
var traffic_reservations
var guard_roster
var schedule_service
var perception_service
var goal_selector
var action_library
var task_planner
var recovery_policy
var plan_executor
var simulation_lod

func _init() -> void:
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()
	navigation_world = NavigationWorldServiceScript.new()
	navigation_world.setup(null, change_bus)
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
	setup_behavior_services()

func setup(system_node: Node, main_node: Node) -> void:
	npc_system = system_node
	main = main_node
	navigation_world.setup(main, change_bus)
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
	setup_behavior_services()
	telemetry.record_event("_system", &"architecture", "setup", &"none", {
		"architectureVersion": architecture_version,
		"locomotionMode": locomotion_mode
	})

func _physics_process(_delta: float) -> void:
	process_navigation_changes()
	build_navigation_tiles(NpcConstantsScript.NAV_BUILD_MAX_JOBS_PER_TICK)

func clear() -> void:
	contexts_by_instance_id.clear()
	contexts_by_stable_id.clear()
	blackboards_by_stable_id.clear()
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()
	navigation_world = NavigationWorldServiceScript.new()
	navigation_world.setup(main, change_bus)
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
	setup_behavior_services()

func setup_behavior_services() -> void:
	guard_roster = GuardRosterServiceScript.new()
	schedule_service = NpcScheduleServiceScript.new()
	schedule_service.setup(guard_roster)
	perception_service = NpcPerceptionServiceScript.new()
	perception_service.setup(self, npc_system)
	goal_selector = NpcGoalSelectorScript.new()
	action_library = NpcActionLibraryScript.new()
	task_planner = NpcTaskPlannerScript.new()
	task_planner.setup(action_library)
	recovery_policy = NpcRecoveryPolicyScript.new()
	plan_executor = NpcPlanExecutorScript.new()
	plan_executor.setup(self, npc_system, main, {
		"schedule": schedule_service,
		"guardRoster": guard_roster,
		"perception": perception_service,
		"goalSelector": goal_selector,
		"taskPlanner": task_planner,
		"recovery": recovery_policy
	})

func register_legacy_npc(body: Node, profile: Dictionary, legacy_entry: Dictionary):
	if body == null:
		return null
	var context = NpcAgentContextScript.from_legacy_profile(body, profile)
	var blackboard = NpcBlackboardScript.new()
	contexts_by_instance_id[body.get_instance_id()] = context
	contexts_by_stable_id[context.stable_id] = context
	blackboards_by_stable_id[context.stable_id] = blackboard
	scheduler.register_agent(context.stable_id)
	legacy_entry["agentContext"] = context
	legacy_entry["blackboard"] = blackboard
	if guard_roster != null:
		guard_roster.migrate_legacy_duty(context, legacy_entry)
	body.set_meta("npc_stable_id", context.stable_id)
	body.set_meta("npc_guard_duty", String(context.guard_duty_kind))
	if simulation_lod != null:
		simulation_lod.register_actor(legacy_entry)
	telemetry.record_event(context.stable_id, &"registration", "legacy_registered", &"none", {
		"canFight": context.can_fight,
		"guardDuty": String(context.guard_duty_kind)
	})
	return context

func update_legacy_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
	if plan_executor == null:
		return
	if simulation_lod != null and simulation_lod.should_hold_active_movement(entry):
		return
	if bool(entry.get("abstractSimulated", false)) or String(entry.get("simulationLod", "")) == NpcSimulationLodServiceScript.STATE_ABSTRACT:
		if simulation_lod != null:
			simulation_lod.advance_abstract(entry, delta)
		return
	if not bool(entry.get("npc_lod_brain_due", true)):
		return
	plan_executor.update_legacy_npc(entry, delta, night_factor)

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

func release_action_owned_state(entry: Dictionary, reason := "released") -> void:
	release_npc_traffic_reservations(entry, reason)
	var body := entry.get("body") as Node
	release_npc_door_hold(body if body != null else String(entry.get("id", "")), true)
	if smart_objects != null and smart_objects.has_method("release_owner"):
		smart_objects.release_owner(String(entry.get("id", "")), reason)

func cleanup_actor_ownership(entry_or_id, reason := "cleanup") -> Dictionary:
	if simulation_lod == null:
		return {}
	return simulation_lod.cleanup_actor_ownership(entry_or_id, reason)

func unregister_legacy_npc(body: Node) -> void:
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
	telemetry.record_event(context.stable_id, &"registration", "legacy_unregistered")

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

func notify_prop_created(prop_id: String, prop: Node = null) -> void:
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

func notify_door_registered(door: Node) -> void:
	register_door(door)
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

func register_door(door: Node, metadata := {}) -> String:
	if smart_objects == null:
		return ""
	var portal_id: String = smart_objects.register_door(door, metadata)
	if portal_id != "":
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

func request_door_toggle(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
	if smart_objects == null:
		return null
	var result = smart_objects.request_door_toggle(door, actor, actor_kind, metadata)
	if result != null:
		telemetry.record_event("_system", &"door", "toggle_request", StringName(String(result.reason)), {
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

func release_npc_door_hold(actor_or_id, schedule_close := true) -> void:
	if door_traversal != null:
		door_traversal.release_actor(actor_or_id, schedule_close)

func advance_traffic(delta: float) -> void:
	if traffic_reservations != null:
		traffic_reservations.advance(delta)

func request_npc_traffic_step(entry: Dictionary, previous: Vector3, candidate: Vector3, world, intent := {}) -> Dictionary:
	if traffic_reservations == null or world == null:
		return { "ok": true, "status": "granted", "reason": "missing_traffic_optional" }
	var owner_id := String(entry.get("id", "npc"))
	var from_cell: Vector2i = world.world_cell(previous)
	var to_cell: Vector2i = world.world_cell(candidate)
	if from_cell == to_cell:
		return { "ok": true, "status": "granted", "reason": "same_cell" }
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
	notify_door_state_changed(door, open)
	telemetry.record_event("_system", &"door", "revision", NpcEnumsScript.DOOR_STATE_OPEN if open else NpcEnumsScript.DOOR_STATE_CLOSED, {
		"reason": reason,
		"revision": revision
	})

func notify_structure_metadata_changed(structure_id: String, bounds: AABB, metadata := {}) -> void:
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA, "structure:%s" % structure_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds))
	telemetry.record_event("_system", &"semantic", "structure_metadata", &"none", metadata)

func notify_semantic_changed(semantic_id: String, bounds: AABB, metadata := {}) -> void:
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED, "semantic:%s" % semantic_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds))
	telemetry.record_event("_system", &"semantic", "changed", &"none", metadata)

func register_semantic_region(kind: StringName, region_id: String, bounds: AABB, metadata := {}) -> int:
	if navigation_world == null or region_id == "":
		return 0
	var revision: int = navigation_world.register_semantic_region(kind, region_id, bounds, metadata)
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_SEMANTIC_CHANGED, "semantic:%s" % region_id, bounds, NavigationChangeBusScript.tile_keys_for_bounds(bounds), revision)
	telemetry.record_event("_system", &"semantic", "registered", kind, {
		"regionId": region_id,
		"revision": revision
	})
	return revision

func process_navigation_changes() -> Array:
	var events: Array = navigation_world.process_change_bus() if navigation_world != null else []
	if npc_system != null and npc_system.has_method("process_navigation_route_changes") and not events.is_empty():
		npc_system.call("process_navigation_route_changes", events)
	return events

func request_navigation_tile(snapshot: Dictionary, priority := 0, profile = null) -> Dictionary:
	var result: Dictionary = navigation_world.request_tile(snapshot, priority, profile) if navigation_world != null else {}
	if navigation_world != null:
		telemetry.observe_navigation_stats(navigation_world.stats())
	return result

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
	telemetry.record_duration(&"navigation_build_work", Time.get_ticks_usec() - started, NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC)
	telemetry.observe_navigation_stats(navigation_world.stats())
	return built

func stats() -> Dictionary:
	return {
		"architectureVersion": architecture_version,
		"locomotionMode": locomotion_mode,
		"contexts": contexts_by_stable_id.size(),
		"scheduler": scheduler.stats(),
		"telemetry": telemetry.stats(),
		"changeBus": change_bus.stats(),
		"navigationWorld": navigation_world.stats(),
		"smartObjects": smart_objects.stats() if smart_objects != null else {},
		"doorPortals": door_portals.stats() if door_portals != null else {},
		"doorTraversal": door_traversal.stats() if door_traversal != null else {},
		"traffic": traffic_reservations.stats() if traffic_reservations != null else {},
		"simulationLod": simulation_lod.stats() if simulation_lod != null else {},
		"guardRoster": guard_roster.summary() if guard_roster != null else {},
		"behavior": plan_executor.stats() if plan_executor != null else {}
	}

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
