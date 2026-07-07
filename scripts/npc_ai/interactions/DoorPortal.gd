extends RefCounted
class_name DoorPortal

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var portal_id := ""
var group_id := ""
var building_id := ""
var side := -1
var orientation_axis := "z"
var crossing_axis := "z"
var leaf_nodes: Array[Node] = []
var leaf_cells: Array[Vector3i] = []
var leaf_ids: Array[String] = []
var state: StringName = NpcEnumsScript.DOOR_STATE_CLOSED
var locked := false
var jammed := false
var destroyed := false
var unloaded := false
var public_access := true
var policy_id := "private_home"
var state_revision := 0
var open_holds := {}
var queued_actors := {}
var active_crossing := {}
var threshold_bounds := AABB()
var sweep_bounds := AABB()
var clearance_bounds := AABB()
var approach_slots := {}
var trace: Array[Dictionary] = []

func add_leaf(door: Node) -> void:
	if door == null or not is_instance_valid(door):
		return
	if leaf_nodes.has(door):
		return
	leaf_nodes.append(door)
	var cell: Vector3i = door.get_meta("cell", Vector3i.ZERO)
	leaf_cells.append(cell)
	leaf_ids.append(String(door.name))
	if portal_id == "":
		portal_id = String(door.get_meta("door_portal_id", "door:%d,%d,%d" % [cell.x, cell.y, cell.z]))
	if group_id == "":
		group_id = String(door.get_meta("door_group_id", portal_id))
	if building_id == "":
		building_id = String(door.get_meta("door_building_id", ""))
	if side < 0:
		side = int(door.get_meta("door_side", -1))
	locked = locked or bool(door.get_meta("locked", false))
	jammed = jammed or bool(door.get_meta("jammed", false))
	destroyed = destroyed or bool(door.get_meta("destroyed", false))
	unloaded = unloaded or bool(door.get_meta("unloaded", false))
	if destroyed:
		state = NpcEnumsScript.DOOR_STATE_DESTROYED
	elif unloaded:
		state = NpcEnumsScript.DOOR_STATE_UNLOADED
	elif bool(door.get_meta("open", false)) and state != NpcEnumsScript.DOOR_STATE_DESTROYED:
		state = NpcEnumsScript.DOOR_STATE_OPEN
	public_access = public_access and bool(door.get_meta("door_public_access", true))
	policy_id = String(door.get_meta("door_policy", policy_id))
	_update_orientation_from_door(door)
	rebuild_geometry()

func rebuild_geometry() -> void:
	if leaf_nodes.is_empty():
		threshold_bounds = AABB()
		sweep_bounds = AABB()
		clearance_bounds = AABB()
		return
	var min_x := INF
	var min_y := INF
	var min_z := INF
	var max_x := -INF
	var max_y := -INF
	var max_z := -INF
	var valid_leaf_nodes: Array[Node] = []
	for door_value in leaf_nodes:
		if door_value == null or not is_instance_valid(door_value):
			continue
		var door := door_value as Node3D
		if door == null:
			continue
		valid_leaf_nodes.append(door)
		min_x = minf(min_x, door.global_position.x)
		min_y = minf(min_y, door.global_position.y)
		min_z = minf(min_z, door.global_position.z)
		max_x = maxf(max_x, door.global_position.x)
		max_y = maxf(max_y, door.global_position.y)
		max_z = maxf(max_z, door.global_position.z)
	leaf_nodes = valid_leaf_nodes
	if min_x == INF:
		return
	var cell := NpcConstantsScript.CELL_SIZE
	var height := cell * 2.25
	var center := Vector3((min_x + max_x) * 0.5, min_y + height * 0.45, (min_z + max_z) * 0.5)
	var leaf_span_x := maxf(cell, absf(max_x - min_x) + cell)
	var leaf_span_z := maxf(cell, absf(max_z - min_z) + cell)
	var threshold_size := Vector3(leaf_span_x, height, cell * 0.72)
	var clearance_size := Vector3(leaf_span_x + cell * 0.25, height, cell * 2.35)
	var sweep_size := Vector3(leaf_span_x + cell * 0.35, height, cell * 1.45)
	if crossing_axis == "x":
		threshold_size = Vector3(cell * 0.72, height, leaf_span_z)
		clearance_size = Vector3(cell * 2.35, height, leaf_span_z + cell * 0.25)
		sweep_size = Vector3(cell * 1.45, height, leaf_span_z + cell * 0.35)
	threshold_bounds = AABB(center - threshold_size * 0.5, threshold_size)
	clearance_bounds = AABB(center - clearance_size * 0.5, clearance_size)
	sweep_bounds = AABB(center - sweep_size * 0.5, sweep_size)
	_build_slots(center, cell)

func occupied_actors(actors: Array, volume := "clearance") -> Array[String]:
	var bounds := clearance_bounds
	if volume == "threshold":
		bounds = threshold_bounds
	elif volume == "sweep":
		bounds = sweep_bounds
	var result: Array[String] = []
	for actor_value in actors:
		var actor := actor_value as Node3D
		if actor == null or not is_instance_valid(actor):
			continue
		if _bounds_contains_capsule_center(bounds, actor.global_position, NpcConstantsScript.DEFAULT_NPC_RADIUS):
			result.append(actor_id_for_node(actor))
	result.sort()
	return result

func has_any_occupancy(actors: Array) -> bool:
	return not occupied_actors(actors, "threshold").is_empty() or not occupied_actors(actors, "sweep").is_empty() or not occupied_actors(actors, "clearance").is_empty()

func hold(actor_id: String) -> void:
	if actor_id == "":
		return
	open_holds[actor_id] = true
	queued_actors.erase(actor_id)
	_record("hold", { "actorId": actor_id })

func release(actor_id: String) -> void:
	if actor_id == "":
		return
	open_holds.erase(actor_id)
	queued_actors.erase(actor_id)
	if String(active_crossing.get("actorId", "")) == actor_id:
		active_crossing.clear()
	_record("release", { "actorId": actor_id })

func queue(actor_id: String, direction: String) -> void:
	if actor_id == "":
		return
	queued_actors[actor_id] = {
		"direction": direction,
		"age": 0.0
	}
	_record("queue", { "actorId": actor_id, "direction": direction })

func can_close(actors: Array) -> Dictionary:
	if destroyed or unloaded:
		return { "ok": false, "reason": "unavailable" }
	if not open_holds.is_empty():
		return { "ok": false, "reason": "active_hold", "actors": open_holds.keys() }
	if not queued_actors.is_empty():
		return { "ok": false, "reason": "queued_actor", "actors": queued_actors.keys() }
	var threshold := occupied_actors(actors, "threshold")
	if not threshold.is_empty():
		return { "ok": false, "reason": "threshold_occupied", "actors": threshold }
	var sweep := occupied_actors(actors, "sweep")
	if not sweep.is_empty():
		return { "ok": false, "reason": "sweep_occupied", "actors": sweep }
	var clearance := occupied_actors(actors, "clearance")
	if not clearance.is_empty():
		return { "ok": false, "reason": "clearance_occupied", "actors": clearance }
	return { "ok": true, "reason": "clear" }

func advance(delta: float) -> void:
	for actor_id in queued_actors.keys().duplicate():
		var entry: Dictionary = queued_actors[actor_id]
		entry["age"] = float(entry.get("age", 0.0)) + delta
		if float(entry.get("age", 0.0)) > NpcConstantsScript.DOOR_QUEUE_INHERITANCE_SECONDS:
			queued_actors.erase(actor_id)
		else:
			queued_actors[actor_id] = entry

func actor_id_for_node(node: Node) -> String:
	if node == null:
		return ""
	if node.has_meta("npc_stable_id"):
		return String(node.get_meta("npc_stable_id"))
	if node.has_meta("npc_id"):
		return String(node.get_meta("npc_id"))
	return "%s:%d" % [node.name, node.get_instance_id()]

func to_summary() -> Dictionary:
	return {
		"portalId": portal_id,
		"groupId": group_id,
		"buildingId": building_id,
		"side": side,
		"orientationAxis": orientation_axis,
		"crossingAxis": crossing_axis,
		"leafCount": leaf_nodes.size(),
		"leafCells": _cell_summaries(),
		"state": String(state),
		"locked": locked,
		"jammed": jammed,
		"destroyed": destroyed,
		"unloaded": unloaded,
		"publicAccess": public_access,
		"policyId": policy_id,
		"stateRevision": state_revision,
		"holds": open_holds.keys(),
		"queue": queued_actors.keys(),
		"threshold": _aabb_summary(threshold_bounds),
		"sweep": _aabb_summary(sweep_bounds),
		"clearance": _aabb_summary(clearance_bounds)
	}

func _update_orientation_from_door(door: Node) -> void:
	if side == 1 or side == 3:
		orientation_axis = "z"
		crossing_axis = "x"
	elif side == 0 or side == 2:
		orientation_axis = "x"
		crossing_axis = "z"
	else:
		var default_facing := 0.0
		if door is Node3D:
			default_facing = (door as Node3D).rotation.y
		var facing := float(door.get_meta("closed_rotation", default_facing))
		if absf(sin(facing)) > absf(cos(facing)):
			orientation_axis = "z"
			crossing_axis = "x"
		else:
			orientation_axis = "x"
			crossing_axis = "z"

func _build_slots(center: Vector3, cell: float) -> void:
	var offset := Vector3(0.0, 0.0, cell * 1.15)
	if crossing_axis == "x":
		offset = Vector3(cell * 1.15, 0.0, 0.0)
	approach_slots = {
		"negative": center - offset,
		"positive": center + offset,
		"threshold": center
	}

func _bounds_contains_capsule_center(bounds: AABB, position: Vector3, radius: float) -> bool:
	if bounds.size == Vector3.ZERO:
		return false
	var expanded := bounds.grow(radius)
	expanded.position.y -= NpcConstantsScript.CELL_SIZE
	expanded.size.y += NpcConstantsScript.CELL_SIZE
	return expanded.has_point(position)

func _record(kind: String, metadata := {}) -> void:
	trace.append({
		"kind": kind,
		"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
	})
	while trace.size() > NpcConstantsScript.DOOR_TRACE_CAPACITY:
		trace.remove_at(0)

func _cell_summaries() -> Array:
	var result := []
	for cell in leaf_cells:
		result.append([cell.x, cell.y, cell.z])
	return result

func _aabb_summary(bounds: AABB) -> Dictionary:
	return {
		"position": [bounds.position.x, bounds.position.y, bounds.position.z],
		"size": [bounds.size.x, bounds.size.y, bounds.size.z]
	}
