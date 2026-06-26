extends RefCounted
class_name DoorAccessPolicy

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

func evaluate(portal, request, command: StringName) -> Dictionary:
	if portal == null:
		return { "ok": false, "reason": "missing" }
	if bool(portal.destroyed):
		return { "ok": false, "reason": "destroyed" }
	if bool(portal.unloaded):
		return { "ok": false, "reason": "unloaded" }
	if command in [NpcEnumsScript.DOOR_COMMAND_OPEN, NpcEnumsScript.DOOR_COMMAND_HOLD] and bool(portal.jammed):
		return { "ok": false, "reason": "jammed" }
	if command in [NpcEnumsScript.DOOR_COMMAND_OPEN, NpcEnumsScript.DOOR_COMMAND_HOLD] and bool(portal.locked):
		if not _request_authorized(request):
			return { "ok": false, "reason": "locked_unauthorized" }
	if command == NpcEnumsScript.DOOR_COMMAND_CLOSE and bool(portal.jammed):
		return { "ok": false, "reason": "jammed" }
	return { "ok": true, "reason": "allowed" }

func _request_authorized(request) -> bool:
	if request == null:
		return false
	var metadata: Dictionary = request.get("metadata")
	if bool(metadata.get("authorized", false)) or bool(metadata.get("useLocked", false)):
		return true
	var actor_kind := String(request.get("actor_kind"))
	return actor_kind in ["admin", "owner"]
