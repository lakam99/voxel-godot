extends Resource
class_name NpcTaskCatalogResource

@export var action_definitions: Array[Dictionary] = []
@export var goal_sequences: Array[Dictionary] = []

func actions_by_id() -> Dictionary:
	var result := {}
	for action_value in action_definitions:
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = (action_value as Dictionary).duplicate(true)
		var action_id := String(action.get("actionId", ""))
		if action_id == "":
			continue
		result[action_id] = action
	return result

func sequences_for_goal(goal_kind: StringName, context := {}) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for sequence_value in goal_sequences:
		if not (sequence_value is Dictionary):
			continue
		var sequence: Dictionary = sequence_value
		if String(sequence.get("goalKind", "")) != String(goal_kind):
			continue
		if _context_matches(sequence.get("context", {}), context):
			matches.append(sequence.duplicate(true))
	matches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_context: Dictionary = a.get("context", {}) if a.get("context", {}) is Dictionary else {}
		var b_context: Dictionary = b.get("context", {}) if b.get("context", {}) is Dictionary else {}
		if a_context.size() == b_context.size():
			return String(a.get("sequenceId", "")) < String(b.get("sequenceId", ""))
		return a_context.size() > b_context.size()
	)
	return matches

func validate_catalog() -> Dictionary:
	var actions := actions_by_id()
	var missing_fields: Array[String] = []
	for action_id in actions.keys():
		var action: Dictionary = actions[action_id]
		for field in ["actionId", "targetKind", "reservationRequired", "routeRequired", "timeoutSeconds", "failurePolicy", "successEffect"]:
			if not action.has(field):
				missing_fields.append("%s:%s" % [String(action_id), String(field)])
	var missing_actions: Array[String] = []
	for sequence_value in goal_sequences:
		if not (sequence_value is Dictionary):
			continue
		var sequence: Dictionary = sequence_value
		for action_id_value in sequence.get("actionIds", []):
			var action_id := String(action_id_value)
			if not actions.has(action_id):
				missing_actions.append("%s:%s" % [String(sequence.get("sequenceId", "")), action_id])
	return {
		"ok": missing_fields.is_empty() and missing_actions.is_empty() and not actions.is_empty() and not goal_sequences.is_empty(),
		"actionCount": actions.size(),
		"sequenceCount": goal_sequences.size(),
		"missingFields": missing_fields,
		"missingActions": missing_actions
	}

func _context_matches(required_value, context_value) -> bool:
	if not (required_value is Dictionary):
		return true
	var required: Dictionary = required_value
	var context: Dictionary = context_value if context_value is Dictionary else {}
	for key in required.keys():
		if not context.has(key):
			return false
		var expected = required[key]
		var actual = context[key]
		if typeof(expected) != typeof(actual):
			if String(expected) != String(actual):
				return false
		elif expected != actual:
			return false
	return true
