extends RefCounted
class_name RouteCorridor

var steps: Array = []
var waypoints: Array[Vector3] = []
var actions: Array = []
var dependencies := {
	"tiles": [],
	"edges": [],
	"portals": [],
	"semantics": []
}
var total_cost := 0.0
var smoothed := false
var smoothing_rejected := false
var arrival_contract := ""

func add_dependency(kind: String, value: String) -> void:
	if value == "":
		return
	if not dependencies.has(kind):
		dependencies[kind] = []
	var values: Array = dependencies[kind]
	if not values.has(value):
		values.append(value)
		values.sort()

func add_step(step) -> void:
	if step == null:
		return
	steps.append(step)
	waypoints.append(step.get("world_position"))
	total_cost += float(step.get("cost"))
	if String(step.get("portal_id")) != "":
		add_dependency("portals", String(step.get("portal_id")))
	for semantic_id in step.get("semantic_region_ids"):
		add_dependency("semantics", String(semantic_id))

func add_action(action) -> void:
	if action != null:
		actions.append(action)

func mandatory_action_count() -> int:
	return actions.size()

func cells_2d() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for step in steps:
		var cell: Vector3i = step.get("cell")
		result.append(Vector2i(cell.x, cell.z))
	return result

func actions_by_cell() -> Dictionary:
	var result := {}
	for step in steps:
		if String(step.get("action_id")) == "":
			continue
		var cell: Vector3i = step.get("cell")
		result["%d,%d" % [cell.x, cell.z]] = {
			"kind": String(step.get("traversal_kind")),
			"cell": Vector2i(cell.x, cell.z),
			"actionId": String(step.get("action_id")),
			"portalId": String(step.get("portal_id")),
			"door": step.get("metadata").get("door")
		}
	return result

func to_summary() -> Dictionary:
	var step_summaries: Array = []
	for step in steps:
		step_summaries.append(step.to_summary())
	var action_summaries: Array = []
	for action in actions:
		action_summaries.append(action.to_summary())
	return {
		"stepCount": steps.size(),
		"waypointCount": waypoints.size(),
		"actionCount": actions.size(),
		"totalCost": total_cost,
		"smoothed": smoothed,
		"smoothingRejected": smoothing_rejected,
		"arrivalContract": arrival_contract,
		"dependencies": dependencies.duplicate(true),
		"steps": step_summaries,
		"actions": action_summaries
	}
