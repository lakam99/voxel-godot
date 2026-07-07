extends RefCounted
class_name NavigationChangeBus

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var monotonic_revision := 0
var max_pending_tiles := NpcConstantsScript.CHANGE_BUS_MAX_PENDING_TILES
var pending_by_tile := {}
var dropped_events := 0

static func tile_key_for_cell(cell) -> String:
	var x := 0
	var z := 0
	if cell is Vector3i:
		x = (cell as Vector3i).x
		z = (cell as Vector3i).z
	elif cell is Vector2i:
		x = (cell as Vector2i).x
		z = (cell as Vector2i).y
	return "%d,%d" % [floori(float(x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)), floori(float(z) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))]

static func tile_key_for_chunk(chunk_key: Vector2i) -> String:
	return "%d,%d" % [chunk_key.x, chunk_key.y]

static func tile_key_for_world_position(position: Vector3) -> String:
	var cell := Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))
	return tile_key_for_cell(cell)

static func tile_keys_for_bounds(bounds: AABB) -> Array[String]:
	var result: Array[String] = []
	if bounds.size == Vector3.ZERO:
		return result
	var min_cell_x := floori(bounds.position.x / NpcConstantsScript.CELL_SIZE)
	var min_cell_z := floori(bounds.position.z / NpcConstantsScript.CELL_SIZE)
	var max_cell_x := floori((bounds.position.x + bounds.size.x - 0.001) / NpcConstantsScript.CELL_SIZE)
	var max_cell_z := floori((bounds.position.z + bounds.size.z - 0.001) / NpcConstantsScript.CELL_SIZE)
	for z in range(min_cell_z, max_cell_z + 1):
		for x in range(min_cell_x, max_cell_x + 1):
			var tile_key := tile_key_for_cell(Vector2i(x, z))
			if not result.has(tile_key):
				result.append(tile_key)
	result.sort()
	return result

func emit_change(kind: StringName, object_id: String, bounds: AABB, tile_keys: Array, source_revision := 0) -> int:
	monotonic_revision += 1
	var normalized_tiles := _normalized_tile_keys(tile_keys)
	if normalized_tiles.is_empty():
		normalized_tiles = tile_keys_for_bounds(bounds)
	if normalized_tiles.is_empty():
		normalized_tiles.append("0,0")
	for tile_key in normalized_tiles:
		if not pending_by_tile.has(tile_key) and pending_by_tile.size() >= max_pending_tiles:
			dropped_events += 1
			continue
		var event: Dictionary = pending_by_tile.get(tile_key, {
			"tileKey": tile_key,
			"revision": monotonic_revision,
			"changeKinds": [],
			"objectIds": [],
			"bounds": bounds,
			"sourceRevisions": [],
			"coalescedCount": 0
		})
		event["revision"] = monotonic_revision
		event["coalescedCount"] = int(event.get("coalescedCount", 0)) + 1
		if not (event["changeKinds"] as Array).has(String(kind)):
			(event["changeKinds"] as Array).append(String(kind))
		if object_id != "" and not (event["objectIds"] as Array).has(object_id):
			(event["objectIds"] as Array).append(object_id)
		if source_revision > 0 and not (event["sourceRevisions"] as Array).has(source_revision):
			(event["sourceRevisions"] as Array).append(source_revision)
		if event.has("bounds") and event["bounds"] is AABB:
			event["bounds"] = (event["bounds"] as AABB).merge(bounds)
		pending_by_tile[tile_key] = event
	return monotonic_revision

func flush_frame(max_events := -1, max_object_ids := -1) -> Array[Dictionary]:
	var keys := pending_by_tile.keys()
	keys.sort()
	var events: Array[Dictionary] = []
	var limit := keys.size()
	if max_events > 0:
		limit = mini(limit, max_events)
	for index in range(limit):
		var key = keys[index]
		var event: Dictionary = pending_by_tile[key]
		if max_object_ids > 0 and event.get("objectIds", []) is Array and (event.get("objectIds", []) as Array).size() > max_object_ids:
			var object_ids: Array = event.get("objectIds", [])
			var batch_ids := []
			var remaining_ids := []
			for object_index in range(object_ids.size()):
				if object_index < max_object_ids:
					batch_ids.append(object_ids[object_index])
				else:
					remaining_ids.append(object_ids[object_index])
			event["objectIds"] = remaining_ids
			event["coalescedCount"] = remaining_ids.size()
			pending_by_tile[key] = event
			event = event.duplicate(false)
			event["objectIds"] = batch_ids
			event["coalescedCount"] = batch_ids.size()
		else:
			pending_by_tile.erase(key)
		(event["changeKinds"] as Array).sort()
		(event["objectIds"] as Array).sort()
		events.append(event)
	return events

func pending_count() -> int:
	return pending_by_tile.size()

func stats() -> Dictionary:
	return {
		"revision": monotonic_revision,
		"pendingTiles": pending_by_tile.size(),
		"maxPendingTiles": max_pending_tiles,
		"droppedEvents": dropped_events
	}

func _normalized_tile_keys(tile_keys: Array) -> Array[String]:
	var result: Array[String] = []
	for tile_key in tile_keys:
		var value := String(tile_key)
		if value != "" and not result.has(value):
			result.append(value)
	result.sort()
	return result
