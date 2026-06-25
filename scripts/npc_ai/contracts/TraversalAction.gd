extends RefCounted
class_name TraversalAction

var action_id := ""
var kind: StringName = &"none"
var from_span_key := ""
var to_span_key := ""
var portal_id := ""
var required_state: StringName = &""
var cost := 0.0
var metadata := {}

static func make(kind_value: StringName, from_value: String, to_value: String, portal_value := "", cost_value := 0.0):
	var action = load("res://scripts/npc_ai/contracts/TraversalAction.gd").new()
	action.kind = kind_value
	action.from_span_key = from_value
	action.to_span_key = to_value
	action.portal_id = portal_value
	action.action_id = "%s:%s:%s" % [String(kind_value), from_value, to_value]
	action.cost = cost_value
	if kind_value == &"door":
		action.required_state = &"open"
	return action

func to_summary() -> Dictionary:
	return {
		"actionId": action_id,
		"kind": String(kind),
		"from": from_span_key,
		"to": to_span_key,
		"portalId": portal_id,
		"requiredState": String(required_state),
		"cost": cost,
		"metadata": metadata.duplicate(true)
	}
