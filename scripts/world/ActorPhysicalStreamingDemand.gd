extends RefCounted
class_name ActorPhysicalStreamingDemand

## Composes per-body physical streaming facts into the exact occupied gameplay-
## chunk union. The bodies remain the authority; this only removes duplicate
## retained consumers when several physical actors occupy the same chunk.
static func aggregate(rows: Array) -> Dictionary:
	var groups_by_chunk := {}
	var body_ids := {}
	for row_value in rows:
		if not (row_value is Dictionary):
			continue
		var row: Dictionary = row_value
		var chunk_value = row.get("chunk")
		var body_instance_id := int(row.get("bodyInstanceId", 0))
		if not (chunk_value is Vector2i) or body_instance_id <= 0 or body_ids.has(body_instance_id):
			continue
		body_ids[body_instance_id] = true
		var chunk: Vector2i = chunk_value
		if not groups_by_chunk.has(chunk):
			groups_by_chunk[chunk] = {
				"owner": owner_for_chunk(chunk),
				"chunk": chunk,
				"actorIds": [],
				"bodyInstanceIds": []
			}
		var group: Dictionary = groups_by_chunk[chunk]
		var actor_id := String(row.get("actorId", "")).strip_edges()
		if actor_id == "":
			actor_id = "instance:%d" % body_instance_id
		if not group.actorIds.has(actor_id):
			group.actorIds.append(actor_id)
		group.bodyInstanceIds.append(body_instance_id)
	var chunks: Array[Vector2i] = []
	for chunk_value in groups_by_chunk:
		chunks.append(chunk_value)
	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x
	)
	var groups: Array[Dictionary] = []
	for chunk in chunks:
		var group: Dictionary = groups_by_chunk[chunk]
		group.actorIds.sort()
		group.bodyInstanceIds.sort()
		groups.append(group)
	return {
		"actorCount": body_ids.size(),
		"ownerCount": groups.size(),
		"groups": groups
	}


static func owner_for_chunk(chunk: Vector2i) -> String:
	return "actor_chunk:%d,%d" % [chunk.x, chunk.y]
