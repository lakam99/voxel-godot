extends RefCounted
class_name RouteStep

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var from_span_key := ""
var to_span_key := ""
var cell := Vector3i.ZERO
var world_position := Vector3.ZERO
var traversal_kind: StringName = NpcEnumsScript.TRAVERSAL_KIND_WALK
var cost := 0.0
var portal_id := ""
var action_id := ""
var reservation_required := false
var bottleneck := false
var semantic_region_ids: Array[String] = []
var cost_breakdown := {}
var metadata := {}

static func make(from_value: String, to_value: String, position: Vector3, cell_value: Vector3i, kind_value: StringName, cost_value := 0.0):
	var step = load("res://scripts/npc_ai/contracts/RouteStep.gd").new()
	step.from_span_key = from_value
	step.to_span_key = to_value
	step.world_position = position
	step.cell = cell_value
	step.traversal_kind = kind_value
	step.cost = cost_value
	step.reservation_required = kind_value in [NpcEnumsScript.TRAVERSAL_KIND_DOOR, NpcEnumsScript.TRAVERSAL_KIND_SPECIAL]
	step.bottleneck = step.reservation_required
	return step

func to_summary() -> Dictionary:
	return {
		"from": from_span_key,
		"to": to_span_key,
		"cell": [cell.x, cell.y, cell.z],
		"worldPosition": [world_position.x, world_position.y, world_position.z],
		"kind": String(traversal_kind),
		"cost": cost,
		"portalId": portal_id,
		"actionId": action_id,
		"reservationRequired": reservation_required,
		"bottleneck": bottleneck,
		"semanticRegionIds": semantic_region_ids.duplicate(),
		"costBreakdown": cost_breakdown.duplicate(true),
		"metadata": metadata.duplicate(true)
	}
