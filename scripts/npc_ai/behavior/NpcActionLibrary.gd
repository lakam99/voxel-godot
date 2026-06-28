extends RefCounted
class_name NpcActionLibrary

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const DEFAULT_CATALOG_PATH := "res://resources/npc_behavior/task_catalog.tres"

var definitions := {}
var catalog = null
var catalog_path := DEFAULT_CATALOG_PATH
var load_errors: Array[String] = []

func _init(path := DEFAULT_CATALOG_PATH) -> void:
	catalog_path = path
	load_catalog(catalog_path)

func definition(action_id: String) -> Dictionary:
	return definitions.get(action_id, {}).duplicate(true)

func sequence_for_goal(goal_kind: StringName, context := {}) -> Array:
	if catalog == null or not catalog.has_method("sequences_for_goal"):
		return []
	var sequences: Array = catalog.sequences_for_goal(goal_kind, context)
	if sequences.is_empty():
		sequences = catalog.sequences_for_goal(NpcEnumsScript.GOAL_KIND_IDLE, {})
	if sequences.is_empty():
		return []
	var sequence: Dictionary = sequences[0]
	var result := []
	for action_id_value in sequence.get("actionIds", []):
		result.append(_action(String(action_id_value)))
	return result

func sequence_metadata_for_goal(goal_kind: StringName, context := {}) -> Dictionary:
	if catalog == null or not catalog.has_method("sequences_for_goal"):
		return {}
	var sequences: Array = catalog.sequences_for_goal(goal_kind, context)
	if sequences.is_empty():
		sequences = catalog.sequences_for_goal(NpcEnumsScript.GOAL_KIND_IDLE, {})
	return sequences[0].duplicate(true) if not sequences.is_empty() else {}

func load_catalog(path: String) -> void:
	load_errors.clear()
	definitions.clear()
	if not ResourceLoader.exists(path):
		load_errors.append("missing_catalog:%s" % path)
		return
	var loaded = ResourceLoader.load(path)
	if loaded == null:
		load_errors.append("load_failed:%s" % path)
		return
	if not loaded.has_method("actions_by_id"):
		load_errors.append("invalid_catalog:%s" % path)
		return
	catalog = loaded
	definitions = catalog.actions_by_id()

func validate_catalog() -> Dictionary:
	if catalog == null or not catalog.has_method("validate_catalog"):
		return {
			"ok": false,
			"actionCount": definitions.size(),
			"sequenceCount": 0,
			"missingFields": [],
			"missingActions": [],
			"errors": load_errors.duplicate()
		}
	var result: Dictionary = catalog.validate_catalog()
	result["errors"] = load_errors.duplicate()
	result["catalogPath"] = catalog_path
	return result

func _action(action_id: String) -> Dictionary:
	return definition(action_id)
