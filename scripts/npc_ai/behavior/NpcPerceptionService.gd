extends RefCounted
class_name NpcPerceptionService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var autonomy_system = null
var npc_system = null

func setup(autonomy, system_node) -> void:
	autonomy_system = autonomy
	npc_system = system_node

func snapshot(entry: Dictionary, schedule: Dictionary) -> Dictionary:
	var body := entry.get("body") as Node3D
	var position: Vector3 = body.global_position if body != null else entry.get("homePosition", Vector3.ZERO)
	var active_threat = null
	if body != null and npc_system != null and npc_system.has_method("nearest_hostile") and bool(entry.get("canFight", false)):
		var prefer_clear_shot := false
		if npc_system.has_method("npc_weapon_is_ranged"):
			prefer_clear_shot = bool(npc_system.call("npc_weapon_is_ranged", String(entry.get("weaponId", ""))))
		active_threat = npc_system.call("nearest_hostile", position, 42.0, body, prefer_clear_shot)
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var current_cell := Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))
	var inside_home := is_inside_home_interior(entry, position)
	var on_porch := current_cell == porch_cell or position.distance_to(entry.get("porchPosition", position)) <= NpcConstantsScript.CELL_SIZE * 0.78
	var threshold := on_porch and not inside_home
	var route_status := String(entry.get("routeStatus", ""))
	var route_reason := String(entry.get("routeReason", ""))
	var scripted_order_kind := String(body.get_meta("npc_scripted_order_kind", "")) if body != null else ""
	var scripted_order_state := String(body.get_meta("npc_scripted_order_state", "")) if body != null else ""
	var scripted_order_hold := bool(body.get_meta("npc_scripted_hold_on_arrival", false)) if body != null else false
	if scripted_order_kind == "" or not (scripted_order_state in ["PENDING", "ACTIVE", "ARRIVED"]):
		var entry_order_value = entry.get("scriptedOrder", {})
		if entry_order_value is Dictionary:
			var entry_order: Dictionary = entry_order_value
			var entry_order_state := String(entry_order.get("state", ""))
			if entry_order_state in ["PENDING", "ACTIVE", "ARRIVED"]:
				scripted_order_kind = String(entry_order.get("kind", scripted_order_kind))
				scripted_order_state = entry_order_state
				scripted_order_hold = bool(entry_order.get("holdOnArrival", scripted_order_hold))
	var held_arrived_go_home := scripted_order_kind == "go_home" and scripted_order_state == "ARRIVED" and scripted_order_hold
	var active_scripted_order := body != null and (
		body.has_meta("npc_scripted_target")
		or scripted_order_state in ["PENDING", "ACTIVE"]
		or held_arrived_go_home
	)
	return {
		"position": position,
		"insideHome": inside_home,
		"onPorch": on_porch,
		"onThreshold": threshold,
		"scriptedOrder": active_scripted_order and scripted_order_kind != "go_home",
		"scriptedHomeOrder": active_scripted_order and scripted_order_kind == "go_home",
		"scriptedOrderKind": scripted_order_kind,
		"scriptedOrderState": scripted_order_state,
		"scriptedAllowOutside": body != null and bool(body.get_meta("npc_scripted_allow_outside", true)),
		"heldByScript": _held_by_script(entry, body),
		"activeThreat": active_threat != null and is_instance_valid(active_threat),
		"threat": active_threat,
		"homeBlocked": route_status in ["partial", "blocked", "unreachable"] and route_reason != "" and not inside_home,
		"routeStatus": route_status,
		"routeReason": route_reason,
		"scheduleState": schedule.get("scheduleState", &"day")
	}

func is_inside_home_interior(entry: Dictionary, position: Vector3) -> bool:
	var strict_cell_inside := _strict_cell_inside_home(entry, position)
	if not strict_cell_inside:
		return false
	if autonomy_system == null or autonomy_system.get("navigation_world") == null:
		return strict_cell_inside
	var world = autonomy_system.get("navigation_world")
	if world.get("semantic_service") == null:
		return strict_cell_inside
	var regions: Array = world.get("semantic_service").regions_at_position(position, &"home_interior")
	var npc_id := String(entry.get("id", ""))
	for region in regions:
		var metadata: Dictionary = region.get("metadata", {})
		if String(metadata.get("npcId", "")) == npc_id or String(metadata.get("npcId", "")) == "":
			return bool(metadata.get("inside", true))
	return strict_cell_inside

func compliance(entry: Dictionary, perception: Dictionary, schedule: Dictionary) -> Dictionary:
	var state := String(schedule.get("scheduleState", "day"))
	if bool(schedule.get("activeGuardDuty", false)) and state in ["dusk", "night"]:
		return {
			"ok": not bool(perception.get("insideHome", false)),
			"reason": "assigned_guard_outside" if not bool(perception.get("insideHome", false)) else "assigned_guard_inside",
			"state": state
		}
	if bool(schedule.get("mustBeInside", false)):
		if bool(perception.get("insideHome", false)):
			return { "ok": true, "reason": "inside_assigned_home", "state": state }
		if bool(perception.get("onThreshold", false)):
			return { "ok": false, "reason": "threshold_not_inside", "state": state }
		if bool(perception.get("onPorch", false)):
			return { "ok": false, "reason": "porch_not_inside", "state": state }
		return { "ok": false, "reason": "outside_home", "state": state }
	return { "ok": true, "reason": "day_or_explicit_exception", "state": state }

func _held_by_script(entry: Dictionary, body: Node3D) -> bool:
	if body == null:
		return false
	if npc_system != null and npc_system.has_method("npc_is_held_by_intro_or_dialogue"):
		return bool(npc_system.call("npc_is_held_by_intro_or_dialogue", entry, body))
	if bool(body.get_meta("npc_dialogue_focused", false)):
		return true
	return bool(entry.get("holdIntroDoor", false))

func _fallback_inside_home(entry: Dictionary, position: Vector3) -> bool:
	var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
	var current_cell := Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))
	return current_cell == home_cell and position.distance_to(entry.get("homePosition", position)) <= NpcConstantsScript.CELL_SIZE * 0.82

func _strict_cell_inside_home(entry: Dictionary, position: Vector3) -> bool:
	var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
	var porch_cell: Vector2i = entry.get("porchCell", home_cell)
	var min_cell: Vector2i = entry.get("interiorMinCell", home_cell)
	var max_cell: Vector2i = entry.get("interiorMaxCell", home_cell)
	var current_cell := Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))
	if current_cell == porch_cell:
		return false
	return current_cell.x >= mini(min_cell.x, max_cell.x) \
		and current_cell.x <= maxi(min_cell.x, max_cell.x) \
		and current_cell.y >= mini(min_cell.y, max_cell.y) \
		and current_cell.y <= maxi(min_cell.y, max_cell.y)
