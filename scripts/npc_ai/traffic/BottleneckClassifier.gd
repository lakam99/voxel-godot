extends RefCounted
class_name BottleneckClassifier

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

func classify_portal(portal) -> Dictionary:
	if portal == null:
		return {}
	var portal_id := String(portal.get("portal_id"))
	if portal_id == "":
		return {}
	var axis := String(portal.get("crossing_axis"))
	var base := "portal:%s" % portal_id
	var directions := ["x+", "x-"] if axis == "x" else ["z+", "z-"]
	return {
		"id": base,
		"kind": "door_threshold",
		"capacity": 1,
		"portalId": portal_id,
		"crossingAxis": axis,
		"thresholdResourceId": "%s:threshold" % base,
		"edgeResources": {
			directions[0]: "%s:edge:%s" % [base, directions[0]],
			directions[1]: "%s:edge:%s" % [base, directions[1]]
		},
		"oppositeDirections": {
			directions[0]: directions[1],
			directions[1]: directions[0]
		},
		"stagingSlots": portal.get("approach_slots"),
		"bounds": {
			"threshold": _aabb_summary(portal.get("threshold_bounds")),
			"clearance": _aabb_summary(portal.get("clearance_bounds"))
		}
	}

func classify_span(resource_id: String, metadata := {}) -> Dictionary:
	var kind := String(metadata.get("kind", metadata.get("bottleneckKind", "corridor")))
	var capacity := maxi(1, int(metadata.get("capacity", 1)))
	if metadata.has("lateralClearance") and float(metadata.get("lateralClearance", 99.0)) <= NpcConstantsScript.DEFAULT_NPC_RADIUS * 2.2:
		capacity = 1
	if kind == "bridge" or kind == "stair" or kind == "stairs" or kind == "interaction_slot":
		capacity = maxi(1, int(metadata.get("capacity", capacity)))
	return {
		"id": resource_id,
		"kind": kind,
		"capacity": capacity,
		"resourceId": "span:%s" % resource_id,
		"edgeResourceId": "span:%s:edge" % resource_id,
		"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
	}

func classify_interaction_slot(slot_id: String, metadata := {}) -> Dictionary:
	var data := metadata.duplicate(true) if metadata is Dictionary else {}
	data["kind"] = "interaction_slot"
	data["capacity"] = maxi(1, int(data.get("capacity", 1)))
	return classify_span("interaction:%s" % slot_id, data)

func movement_resources(from_node: String, to_node: String, metadata := {}) -> Array[Dictionary]:
	var capacity := maxi(1, int(metadata.get("capacity", 1)))
	var node_resource := "node:%s" % to_node
	var edge_resource := "edge:%s>%s" % [from_node, to_node]
	var opposite_resource := "edge:%s>%s" % [to_node, from_node]
	return [
		{
			"resourceId": node_resource,
			"resourceKind": "node",
			"capacity": capacity,
			"direction": direction_for_nodes(from_node, to_node),
			"fromNode": from_node,
			"toNode": to_node
		},
		{
			"resourceId": edge_resource,
			"resourceKind": "directed_edge",
			"capacity": 1,
			"direction": direction_for_nodes(from_node, to_node),
			"fromNode": from_node,
			"toNode": to_node,
			"metadata": { "oppositeResourceId": opposite_resource }
		}
	]

func portal_resources(portal, direction: String) -> Array[Dictionary]:
	var classification := classify_portal(portal)
	if classification.is_empty():
		return []
	var edge_resources: Dictionary = classification.get("edgeResources", {})
	var opposite_directions: Dictionary = classification.get("oppositeDirections", {})
	var edge_id := String(edge_resources.get(direction, ""))
	if edge_id == "":
		direction = String(edge_resources.keys()[0]) if not edge_resources.is_empty() else "unknown"
		edge_id = String(edge_resources.get(direction, ""))
	var opposite_direction := String(opposite_directions.get(direction, ""))
	var opposite_id := String(edge_resources.get(opposite_direction, ""))
	return [
		{
			"resourceId": String(classification.get("thresholdResourceId", "")),
			"resourceKind": "portal",
			"capacity": 1,
			"direction": direction,
			"metadata": { "portalId": String(classification.get("portalId", "")), "kind": "threshold" }
		},
		{
			"resourceId": edge_id,
			"resourceKind": "directed_edge",
			"capacity": 1,
			"direction": direction,
			"fromNode": "%s:%s:from" % [classification.get("id", ""), direction],
			"toNode": "%s:%s:to" % [classification.get("id", ""), direction],
			"metadata": { "oppositeResourceId": opposite_id, "portalId": String(classification.get("portalId", "")), "kind": "edge" }
		}
	]

func stage_position_for_portal(portal, actor_id: String, direction: String, current_position := Vector3.ZERO) -> Vector3:
	if portal == null:
		return current_position
	var slots: Dictionary = portal.get("approach_slots")
	var center: Vector3 = portal.get("threshold_bounds").position + portal.get("threshold_bounds").size * 0.5
	var slot_key := "negative"
	if direction == "x-" or direction == "z-":
		slot_key = "positive"
	if direction == "unknown":
		if String(portal.get("crossing_axis")) == "x":
			slot_key = "negative" if current_position.x <= center.x else "positive"
		else:
			slot_key = "negative" if current_position.z <= center.z else "positive"
	var base: Vector3 = slots.get(slot_key, current_position)
	var lateral := Vector3.RIGHT
	if String(portal.get("crossing_axis")) == "x":
		lateral = Vector3.FORWARD
	var sign := 1.0 if stable_hash(actor_id) % 2 == 0 else -1.0
	var offset := lateral * sign * NpcConstantsScript.CELL_SIZE * 0.58
	var staged := base + offset
	staged.y = current_position.y
	if staged.distance_to(center) < NpcConstantsScript.CELL_SIZE * 0.90:
		var away := staged - center
		away.y = 0.0
		if away.length_squared() > 0.0001:
			staged = center + away.normalized() * NpcConstantsScript.CELL_SIZE * 0.95
			staged.y = current_position.y
	return staged

func direction_for_nodes(from_node: String, to_node: String) -> String:
	if from_node == "" or to_node == "":
		return "unknown"
	return "%s>%s" % [from_node, to_node]

func stable_hash(value: String) -> int:
	var result := 2166136261
	for i in range(value.length()):
		result = int((result ^ value.unicode_at(i)) * 16777619) & 0x7fffffff
	return result

func _aabb_summary(bounds: AABB) -> Dictionary:
	return {
		"position": [bounds.position.x, bounds.position.y, bounds.position.z],
		"size": [bounds.size.x, bounds.size.y, bounds.size.z]
	}
