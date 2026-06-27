extends RefCounted
class_name SmartObjectRegistration

var object_id := ""
var kind := ""
var node: Node = null
var metadata := {}
var slots := {}
var reservations := {}
var depleted := false
var revision := 0

static func make(object_id_value: String, kind_value: String, node_value: Node = null, metadata_value := {}):
	var registration = load("res://scripts/npc_ai/interactions/SmartObjectRegistration.gd").new()
	registration.object_id = object_id_value
	registration.kind = kind_value
	registration.node = node_value
	registration.metadata = metadata_value.duplicate(true) if metadata_value is Dictionary else {}
	registration.slots = registration.metadata.get("slots", {}).duplicate(true) if registration.metadata.get("slots", {}) is Dictionary else {}
	registration.depleted = bool(registration.metadata.get("depleted", false))
	return registration

func to_summary() -> Dictionary:
	return {
		"objectId": object_id,
		"kind": kind,
		"nodeName": String(node.name) if node != null and is_instance_valid(node) else "",
		"metadata": metadata.duplicate(true),
		"slots": slots.duplicate(true),
		"reservations": reservations.duplicate(true),
		"depleted": depleted,
		"revision": revision
	}
