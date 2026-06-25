extends RefCounted
class_name NavEdgeData

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var from_key := ""
var to_key := ""
var traversal_kind: StringName = NpcEnumsScript.TRAVERSAL_KIND_WALK
var cost := 1.0
var bidirectional := true
var portal_id := ""
var action_id := ""
var required_capabilities: Array[StringName] = []
var metadata := {}

static func make(from_value: String, to_value: String, kind_value: StringName, cost_value := 1.0):
	var edge = load("res://scripts/npc_ai/contracts/NavEdgeData.gd").new()
	edge.from_key = from_value
	edge.to_key = to_value
	edge.traversal_kind = kind_value
	edge.cost = cost_value
	return edge

func key_string() -> String:
	return "%s->%s:%s" % [from_key, to_key, String(traversal_kind)]

func to_summary() -> Dictionary:
	return {
		"from": from_key,
		"to": to_key,
		"kind": String(traversal_kind),
		"cost": cost,
		"bidirectional": bidirectional,
		"portalId": portal_id,
		"actionId": action_id,
		"requiredCapabilities": required_capabilities.duplicate(),
		"metadata": metadata.duplicate()
	}
