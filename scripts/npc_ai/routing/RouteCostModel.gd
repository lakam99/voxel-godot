extends RefCounted
class_name RouteCostModel

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

const ROAD_PENALTY := 0.0
const TERRAIN_PENALTY := 0.24
const HAZARD_PENALTY_CIVILIAN := 8.0
const HAZARD_PENALTY_GUARD := 2.0
const DOOR_ACTION_COST := 1.35
const BOTTLENECK_COST := 0.18
const GUARD_POST_NON_GUARD_PENALTY := 0.5
const GUARD_POST_GUARD_PENALTY := 0.0

func edge_cost(edge_record: Dictionary, request, profile = null) -> Dictionary:
	var edge = edge_record.get("edge")
	var to_span = edge_record.get("to")
	var base := float(edge_record.get("baseCost", 1.0))
	if edge != null:
		base = float(edge.get("cost"))
	var semantic_penalty := semantic_penalty(to_span, request)
	var hazard_penalty := hazard_penalty(to_span, request)
	var door_cost := DOOR_ACTION_COST if edge != null and edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_DOOR else 0.0
	var bottleneck := bool(edge_record.get("bottleneck", false)) or door_cost > 0.0
	var bottleneck_cost := BOTTLENECK_COST if bottleneck else 0.0
	var total := maxf(0.0, base) + semantic_penalty + hazard_penalty + door_cost + bottleneck_cost
	return {
		"base": maxf(0.0, base),
		"semanticPenalty": semantic_penalty,
		"hazardPenalty": hazard_penalty,
		"doorCost": door_cost,
		"bottleneckCost": bottleneck_cost,
		"total": total
	}

func semantic_penalty(span, request) -> float:
	var ids: Array = span.get("semantic_region_ids") if span != null else []
	var preferences: Dictionary = request.get("semantic_preferences") if request != null else {}
	var avoidances: Dictionary = request.get("semantic_avoidances") if request != null else {}
	var penalty := TERRAIN_PENALTY
	for semantic_id in ids:
		var value := String(semantic_id)
		if value.begins_with("road") or value == "road":
			penalty = minf(penalty, ROAD_PENALTY)
		if value.begins_with("guard") or value == "guard_post":
			penalty += GUARD_POST_GUARD_PENALTY if String(request.get("goal_kind")) == "guard" else GUARD_POST_NON_GUARD_PENALTY
		for key in preferences.keys():
			if value.begins_with(String(key)):
				penalty = minf(penalty, maxf(0.0, float(preferences[key])))
		for key in avoidances.keys():
			if value.begins_with(String(key)):
				penalty += maxf(0.0, float(avoidances[key]))
	return maxf(0.0, penalty)

func hazard_penalty(span, request) -> float:
	if span == null:
		return 0.0
	var ids: Array = span.get("semantic_region_ids")
	var flags: Dictionary = span.get("flags")
	var hazardous := bool(flags.get("hazard", false))
	for semantic_id in ids:
		var value := String(semantic_id)
		hazardous = hazardous or value.begins_with("hazard")
	if not hazardous:
		return 0.0
	return HAZARD_PENALTY_GUARD if String(request.get("goal_kind")) == "guard" else HAZARD_PENALTY_CIVILIAN

func path_cost_breakdown(edge_breakdowns: Array) -> Dictionary:
	var result := {
		"base": 0.0,
		"semanticPenalty": 0.0,
		"hazardPenalty": 0.0,
		"doorCost": 0.0,
		"bottleneckCost": 0.0,
		"total": 0.0
	}
	for breakdown in edge_breakdowns:
		for key in result.keys():
			result[key] = float(result[key]) + float((breakdown as Dictionary).get(key, 0.0))
	return result
