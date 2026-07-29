extends RefCounted
class_name DoorController

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const InteractionResultScript := preload("res://scripts/npc_ai/contracts/InteractionResult.gd")
const DoorAccessPolicyScript := preload("res://scripts/npc_ai/interactions/DoorAccessPolicy.gd")

var portal = null
var access_policy = DoorAccessPolicyScript.new()
var state_changed_callback := Callable()
var transition_counts := {
	"open": 0,
	"close": 0
}

func setup(portal_value, callback := Callable()) -> void:
	portal = portal_value
	state_changed_callback = callback
	apply_current_state("setup")

func apply_current_state(reason := "sync") -> void:
	_apply_leaf_state(_leaf_clear_for_state(), reason)

func request_interaction(interaction_request, actors: Array = []):
	if portal == null:
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing")
	var command: StringName = interaction_request.get("command")
	match command:
		NpcEnumsScript.DOOR_COMMAND_OPEN:
			return request_open(interaction_request)
		NpcEnumsScript.DOOR_COMMAND_CLOSE:
			return request_close(interaction_request, actors)
		NpcEnumsScript.DOOR_COMMAND_HOLD:
			return request_hold(interaction_request)
		NpcEnumsScript.DOOR_COMMAND_RELEASE:
			return request_release(interaction_request)
		NpcEnumsScript.DOOR_COMMAND_CANCEL:
			return request_release(interaction_request)
		NpcEnumsScript.DOOR_COMMAND_LOCK:
			return request_lock(interaction_request, true)
		NpcEnumsScript.DOOR_COMMAND_UNLOCK:
			return request_lock(interaction_request, false)
		NpcEnumsScript.DOOR_COMMAND_DESTROY:
			return request_destroy(interaction_request)
		NpcEnumsScript.DOOR_COMMAND_MARK_JAMMED:
			return request_jammed(interaction_request, true)
		NpcEnumsScript.DOOR_COMMAND_REPAIR:
			return request_repair(interaction_request)
		_:
			return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"unknown_command")

func request_open(request):
	var access := access_policy.evaluate(portal, request, NpcEnumsScript.DOOR_COMMAND_OPEN)
	if not bool(access.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(access.get("reason", "denied"))))
	var actor_id := String(request.get("actor_id"))
	if portal.state == NpcEnumsScript.DOOR_STATE_OPEN:
		return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"already_open", { "idempotent": true, "state": String(portal.state) })
	_set_state(NpcEnumsScript.DOOR_STATE_OPEN, "open_request")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"opened", { "transition": "open", "state": String(portal.state) })

func request_close(request, actors: Array = []):
	var access := access_policy.evaluate(portal, request, NpcEnumsScript.DOOR_COMMAND_CLOSE)
	if not bool(access.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(access.get("reason", "denied"))))
	var close_check: Dictionary = portal.can_close(actors)
	if not bool(close_check.get("ok", false)):
		if portal.state == NpcEnumsScript.DOOR_STATE_CLOSING:
			_set_state(NpcEnumsScript.DOOR_STATE_OPEN, "obstructed_reopen")
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(close_check.get("reason", "occupied"))), {
			"obstructed": true,
			"actors": close_check.get("actors", []),
			"state": String(portal.state)
		})
	if portal.state == NpcEnumsScript.DOOR_STATE_CLOSED:
		return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"already_closed", { "idempotent": true, "state": String(portal.state) })
	_set_state(NpcEnumsScript.DOOR_STATE_CLOSED, "close_request")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"closed", { "transition": "close", "state": String(portal.state) })

func request_hold(request):
	var access := access_policy.evaluate(portal, request, NpcEnumsScript.DOOR_COMMAND_HOLD)
	if not bool(access.get("ok", false)):
		return _result(NpcEnumsScript.INTERACTION_STATUS_FAILED, StringName(String(access.get("reason", "denied"))))
	var actor_id := String(request.get("actor_id"))
	portal.hold(actor_id)
	if portal.state != NpcEnumsScript.DOOR_STATE_OPEN:
		_set_state(NpcEnumsScript.DOOR_STATE_OPEN, "hold_open")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"held", { "actorId": actor_id, "state": String(portal.state) })

func request_release(request):
	var actor_id := String(request.get("actor_id"))
	portal.release(actor_id)
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"released", { "actorId": actor_id, "state": String(portal.state) })

func request_lock(request, locked: bool):
	portal.locked = locked
	for leaf in portal.leaf_nodes:
		if leaf != null and is_instance_valid(leaf):
			leaf.set_meta("locked", locked)
	portal.state_revision += 1
	_emit_state_changed("lock" if locked else "unlock")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"locked" if locked else &"unlocked", { "locked": locked })

func request_destroy(_request):
	portal.destroyed = true
	portal.state = NpcEnumsScript.DOOR_STATE_DESTROYED
	portal.state_revision += 1
	for leaf in portal.leaf_nodes:
		if leaf != null and is_instance_valid(leaf):
			leaf.set_meta("destroyed", true)
	_apply_leaf_state(true, "destroyed")
	_emit_state_changed("destroyed")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"destroyed", { "state": String(portal.state), "transition": "destroyed" })

func request_jammed(_request, jammed: bool):
	portal.jammed = jammed
	for leaf in portal.leaf_nodes:
		if leaf != null and is_instance_valid(leaf):
			leaf.set_meta("jammed", jammed)
	portal.state_revision += 1
	_emit_state_changed("jammed")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"jammed", { "jammed": jammed })

func request_repair(_request):
	portal.jammed = false
	portal.destroyed = false
	if portal.state == NpcEnumsScript.DOOR_STATE_DESTROYED:
		_set_state(NpcEnumsScript.DOOR_STATE_CLOSED, "repair")
	else:
		portal.state_revision += 1
		_emit_state_changed("repair")
	return _result(NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED, &"repaired", { "state": String(portal.state) })

func is_traversable() -> bool:
	if portal == null:
		return false
	return portal.state == NpcEnumsScript.DOOR_STATE_OPEN and not portal.destroyed and not portal.unloaded

func to_summary() -> Dictionary:
	return {
		"portal": portal.to_summary() if portal != null else {},
		"transitionCounts": transition_counts.duplicate()
	}

func _set_state(state_value: StringName, reason: String) -> void:
	if portal.state == state_value:
		_apply_leaf_state(state_value == NpcEnumsScript.DOOR_STATE_OPEN, reason)
		return
	portal.state = state_value
	portal.state_revision += 1
	if state_value == NpcEnumsScript.DOOR_STATE_OPEN:
		transition_counts["open"] = int(transition_counts.get("open", 0)) + 1
	elif state_value == NpcEnumsScript.DOOR_STATE_CLOSED:
		transition_counts["close"] = int(transition_counts.get("close", 0)) + 1
	_apply_leaf_state(state_value == NpcEnumsScript.DOOR_STATE_OPEN, reason)
	_emit_state_changed(reason)

func _leaf_clear_for_state() -> bool:
	if portal == null:
		return false
	return portal.state == NpcEnumsScript.DOOR_STATE_OPEN or portal.state == NpcEnumsScript.DOOR_STATE_DESTROYED

func _apply_leaf_state(open: bool, reason: String) -> void:
	if portal == null:
		return
	# A generated door leaf may be freed by world cleanup before its portal policy
	# receives the next close request. Rebuild through DoorPortal's ownership
	# contract first; never erase a freed object through a typed array.
	portal.rebuild_geometry()
	for leaf in portal.leaf_nodes:
		if leaf == null or not is_instance_valid(leaf):
			continue
		var door := leaf as Node3D
		if door == null:
			continue
		door.set_meta("open", open)
		door.set_meta("door_state", String(portal.state))
		door.set_meta("door_state_revision", portal.state_revision)
		door.set_meta("door_portal_id", portal.portal_id)
		door.rotation.y = float(door.get_meta("closed_rotation", door.rotation.y))
		var pivot := door.get_node_or_null("DoorPivot") as Node3D
		if pivot != null:
			# Most leaves swing, while a portcullis uses the same generic door
			# authority to lift its visual leaf.  Collision remains attached to the
			# single source door body and is disabled below in either open state.
			if not door.has_meta("door_pivot_closed_position"):
				door.set_meta("door_pivot_closed_position", pivot.position)
			var closed_pivot_position: Vector3 = door.get_meta("door_pivot_closed_position", Vector3.ZERO) as Vector3
			if String(door.get_meta("door_motion", "swing")) == "raise":
				pivot.rotation.y = 0.0
				pivot.position = closed_pivot_position + (door.get_meta("open_visual_offset", Vector3.ZERO) as Vector3 if open else Vector3.ZERO)
			else:
				pivot.position = closed_pivot_position
				pivot.rotation.y = float(door.get_meta("open_swing", PI * 0.5)) if open else 0.0
		for child in door.get_children():
			if child is CollisionShape3D:
				(child as CollisionShape3D).disabled = open
	portal.rebuild_geometry()
	portal.trace.append({ "kind": "apply_leaf_state", "reason": reason, "open": open })

func _emit_state_changed(reason: String) -> void:
	if state_changed_callback.is_valid():
		state_changed_callback.call(portal, reason)

func _result(status: StringName, reason: StringName, metrics := {}):
	var result = InteractionResultScript.make(status, reason)
	result.interaction_id = portal.portal_id if portal != null else ""
	result.metrics = metrics.duplicate(true) if metrics is Dictionary else {}
	return result
