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

func _init() -> void:
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()
	navigation_world = NavigationWorldServiceScript.new()
	navigation_world.setup(null, change_bus)
	door_portals = DoorPortalServiceScript.new()
	smart_objects = SmartObjectServiceScript.new()
	door_traversal = DoorTraversalExecutorScript.new()

func setup(system_node: Node, main_node: Node) -> void:
	npc_system = system_node
	main = main_node
	navigation_world.setup(main, change_bus)
	door_portals.setup(main, self)
	smart_objects.setup(self, door_portals)
	door_traversal.setup(door_portals)
	telemetry.record_event("_system", &"architecture", "setup", &"none", {
		"architectureVersion": architecture_version,
		"locomotionMode": locomotion_mode
	})

func _physics_process(_delta: float) -> void:
	process_navigation_changes()
	navigation_world.build_next_tiles(NpcConstantsScript.NAV_BUILD_MAX_JOBS_PER_TICK, NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC)

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
	door_traversal.setup(door_portals)

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
	body.set_meta("npc_stable_id", context.stable_id)
	body.set_meta("npc_guard_duty", String(context.guard_duty_kind))
	telemetry.record_event(context.stable_id, &"registration", "legacy_registered", &"none", {
		"canFight": context.can_fight,
		"guardDuty": String(context.guard_duty_kind)
	})
	return context

func unregister_legacy_npc(body: Node) -> void:
	if body == null:
		return
	var instance_id := body.get_instance_id()
	var context = contexts_by_instance_id.get(instance_id)
	if context == null:
		return
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
	telemetry.increment(&"motor_frames")
	if bool(motor_state.get("blocked")):
		telemetry.increment(&"motor_blocked_contacts")
	telemetry.record_event(stable_id, &"motor", "motion", &"none", {
		"requestedVelocity": [requested.x, requested.y, requested.z],
		"appliedVelocity": [applied.x, applied.y, applied.z],
		"displacement": [displacement.x, displacement.y, displacement.z],
		"blocked": bool(motor_state.get("blocked")),
		"blockedContact": String(motor_state.get("blocked_contact_category"))
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
	_emit_prop_change(NpcEnumsScript.CHANGE_KIND_PROP_REMOVED, prop_id, prop)

func notify_chunk_loaded(chunk_key: Vector2i) -> void:
	var object_id := "chunk:%d,%d" % [chunk_key.x, chunk_key.y]
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, object_id, _bounds_for_chunk(chunk_key), [NavigationChangeBusScript.tile_key_for_chunk(chunk_key)])
	telemetry.increment(&"change_chunk_loaded")

func notify_chunk_unloaded(chunk_key: Vector2i) -> void:
	var object_id := "chunk:%d,%d" % [chunk_key.x, chunk_key.y]
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, object_id, _bounds_for_chunk(chunk_key), [NavigationChangeBusScript.tile_key_for_chunk(chunk_key)])
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

func request_npc_door_traversal(door: Node, actor: Node, entry: Dictionary = {}, action: Dictionary = {}) -> Dictionary:
	if door_traversal == null:
		return { "ok": false, "status": "failed", "reason": "missing_door_traversal" }
	var result: Dictionary = door_traversal.request_crossing(door, actor, entry, action)
	if bool(result.get("ok", false)):
		telemetry.increment(&"door_traversal_granted")
	else:
		telemetry.increment(&"door_traversal_waiting")
	return result

func release_npc_door_hold(actor_or_id, schedule_close := true) -> void:
	if door_traversal != null:
		door_traversal.release_actor(actor_or_id, schedule_close)

func process_door_policies(delta: float, actors: Array = []) -> Dictionary:
	if door_portals == null:
		return { "closed": 0, "blocked": 0, "scheduled": 0 }
	return door_portals.process(delta, actors)

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
	return navigation_world.request_tile(snapshot, priority, profile) if navigation_world != null else {}

func build_navigation_tiles(max_jobs := 1) -> Array:
	return navigation_world.build_next_tiles(max_jobs, NpcConstantsScript.NAV_BUILD_HARD_SLICE_USEC) if navigation_world != null else []

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
		"doorTraversal": door_traversal.stats() if door_traversal != null else {}
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
