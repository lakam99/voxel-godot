extends Node
class_name NpcAutonomySystem

const NpcAgentContextScript := preload("res://scripts/npc_ai/NpcAgentContext.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcBrainSchedulerScript := preload("res://scripts/npc_ai/NpcBrainScheduler.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NpcTelemetryServiceScript := preload("res://scripts/npc_ai/debug/NpcTelemetryService.gd")

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

func _init() -> void:
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()

func setup(system_node: Node, main_node: Node) -> void:
	npc_system = system_node
	main = main_node
	telemetry.record_event("_system", &"architecture", "setup", &"none", {
		"architectureVersion": architecture_version,
		"locomotionMode": locomotion_mode
	})

func clear() -> void:
	contexts_by_instance_id.clear()
	contexts_by_stable_id.clear()
	blackboards_by_stable_id.clear()
	scheduler = NpcBrainSchedulerScript.new()
	telemetry = NpcTelemetryServiceScript.new()
	change_bus = NavigationChangeBusScript.new()

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

func stats() -> Dictionary:
	return {
		"architectureVersion": architecture_version,
		"locomotionMode": locomotion_mode,
		"contexts": contexts_by_stable_id.size(),
		"scheduler": scheduler.stats(),
		"telemetry": telemetry.stats(),
		"changeBus": change_bus.stats()
	}

func _bounds_for_cell(cell: Vector3i) -> AABB:
	var size := Vector3.ONE * NpcConstantsScript.CELL_SIZE
	var origin := Vector3(float(cell.x), float(cell.y), float(cell.z)) * NpcConstantsScript.CELL_SIZE - size * 0.5
	return AABB(origin, size)

func _bounds_for_chunk(chunk_key: Vector2i) -> AABB:
	var span := float(NpcConstantsScript.NAV_TILE_CELL_SIZE) * NpcConstantsScript.CELL_SIZE
	var origin := Vector3(float(chunk_key.x) * span, -128.0, float(chunk_key.y) * span)
	return AABB(origin, Vector3(span, 256.0, span))
