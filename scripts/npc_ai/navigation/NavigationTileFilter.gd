extends RefCounted

## Pure publication kernel. No class_name, scene owner, renderer or route authority.
## Input graph must be owned, recursively value-only and sealed BEFORE dispatch.
const Constants = preload("res://scripts/npc_ai/NpcConstants.gd")
const Enums = preload("res://scripts/npc_ai/NpcEnums.gd")
const Clearance = preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const CELL := Constants.CELL_SIZE
const INVALID_CELL := Vector2i(999999, 999999)
const INFLATION := Constants.DEFAULT_NPC_RADIUS + Constants.DEFAULT_PERSONAL_SPACE_MARGIN
const INDEX_MARGIN := 2

func compile(input: Dictionary, header: Dictionary, continuation: Callable) -> Dictionary:
	# Admission, not this worker, must reject a mutable/object-bearing input.
	# Never silently accept a missing field as an empty authoritative tile.
	if not input.is_read_only() or not header.is_read_only(): return _invalid()
	for field: String in ["terrainCells", "staticCollision", "buildingTiles", "doorPortals", "doorLinks"]:
		if not input.get(field) is Array or not input[field].is_read_only(): return _invalid()
	if not input.get("waterLevel") is float or not is_finite(input.waterLevel): return _invalid()
	if input.terrainCells.size() != Constants.NAV_TILE_CELL_SIZE * Constants.NAV_TILE_CELL_SIZE: return _invalid()
	var started := Time.get_ticks_usec()
	var extent := _query_extent(input, continuation)
	if not extent.get("ready", false): return _cancelled()
	var index := _collision_index(input.staticCollision, extent.bounds, continuation)
	if not index.get("ready", false): return _cancelled()
	var index_usec := Time.get_ticks_usec() - started
	var clearance := Clearance.new() # Worker-local; only its pure records predicate is called.
	var surfaces: Array[Dictionary] = []
	var building_surfaces: Array[Dictionary] = []
	var crossing_links: Array[Dictionary] = []
	var diagnostics: Dictionary = input.get("diagnostics", {}).duplicate(true)
	var terrain_started := Time.get_ticks_usec()
	for fact: Dictionary in input.terrainCells:
		if not _continue(continuation, "navigation_filter_terrain_cell"): return _cancelled()
		var surface := _terrain_surface(fact, input.waterLevel, index.byCell, diagnostics)
		if surface.is_empty(): continue
		var position: Vector3 = surface.worldPosition
		var center := Vector2(position.x, position.z)
		var rejected := false
		for tile: Dictionary in input.buildingTiles:
			if not _continue(continuation, "navigation_filter_terrain_manifest"): return _cancelled()
			# Deliberately retain the existing SEGMENT predicate for terrain vs
			# building manifests. Do not switch this call to full_rectangle=true.
			var blocker: Dictionary = clearance._building_support_navigation_blocker_from_records(
				tile.collisionRecords, {"sourcePartId":"terrain"}, position.y,
				center-Vector2.ONE*CELL*0.5, center+Vector2.ONE*CELL*0.5)
			if not blocker.is_empty():
				_record_rejection(diagnostics, "terrain", _cell_key(fact.cell), "building_manifest_clearance", blocker)
				rejected = true
				break
		if not rejected: surfaces.append(surface)
	var terrain_usec := Time.get_ticks_usec() - terrain_started
	var building_started := Time.get_ticks_usec()
	var live_records := {}
	for tile: Dictionary in input.buildingTiles:
		if not _continue(continuation, "navigation_filter_building_tile"): return _cancelled()
		if not diagnostics.is_empty():
			diagnostics.rawBuildingSurfaceCount += tile.surfaces.size()
			diagnostics.sourceBindings.append(tile.binding)
		for surface: Dictionary in tile.surfaces:
			if not _continue(continuation, "navigation_filter_building_surface"): return _cancelled()
			var position: Vector3 = surface.worldPosition
			var cell := Vector2i(roundi(position.x/CELL), roundi(position.z/CELL))
			if not live_records.has(cell): live_records[cell] = _transition_collision_records(index.byCell, cell, cell)
			var center := Vector2(position.x, position.z)
			var half := Vector2(surface.size.x, surface.size.z)*0.5
			# Full rectangle and default support-owner exclusion are unchanged.
			# Building filtering does NOT skip invalid-node records: only terrain
			# static_collision_blocker did that in the captured implementation.
			var blocker: Dictionary = clearance._building_support_navigation_blocker_from_records(
				live_records[cell], surface, position.y, center-half, center+half,
				Clearance.BUILDING_SUPPORT_NAV_CLEARANCE, [], true)
			if blocker.is_empty(): building_surfaces.append(surface)
			else: _record_rejection(diagnostics, "building", String(surface.id), "live_collision_clearance", blocker, String(surface.get("sourcePartId", "")))
		# Preserve all authored crossing facts, order and duplicates. The existing
		# descriptor/service validates links against accepted surfaces later.
		crossing_links.append_array(tile.crossingLinks)
	var building_usec := Time.get_ticks_usec() - building_started
	if not _continue(continuation, "navigation_filter_complete"): return _cancelled()
	var snapshot := header.duplicate(false)
	snapshot["publicationStatus"] = "ready"
	snapshot["surfaces"] = surfaces
	snapshot["semanticRegions"] = []
	snapshot["buildingSurfaces"] = building_surfaces
	snapshot["crossingLinks"] = crossing_links
	# Main has already captured ordinary doors in sorted-cell order and appended
	# exact registered building leaves. No owner reads or ID dedup on this worker.
	snapshot["doorPortals"] = input.doorPortals
	snapshot["doorLinks"] = input.doorLinks
	if not diagnostics.is_empty():
		diagnostics.acceptedTerrainSurfaceCount = surfaces.size()
		diagnostics.acceptedBuildingSurfaceCount = building_surfaces.size()
	return {"ready":true, "snapshot":snapshot, "diagnostics":diagnostics,
		"profile":{"collisionIndexUsec":index_usec, "terrainFilterUsec":terrain_usec,
			"buildingFilterUsec":building_usec, "filterUsec":Time.get_ticks_usec()-started}}

func _terrain_surface(fact: Dictionary, water_level: float, index: Dictionary, diagnostics: Dictionary) -> Dictionary:
	var cell: Vector2i = fact.cell
	var id := _cell_key(cell)
	if float(fact.height) < water_level + 0.45:
		_record_rejection(diagnostics, "terrain", id, "below_water_clearance")
		return {}
	var door: Dictionary = fact.door
	if not door.is_empty():
		if door.locked or door.jammed or door.destroyed or door.unloaded:
			_record_rejection(diagnostics, "terrain", id, "door_flags", door.evidence)
			return {}
		if String(door.state) in [String(Enums.DOOR_STATE_LOCKED), String(Enums.DOOR_STATE_JAMMED), String(Enums.DOOR_STATE_DESTROYED), String(Enums.DOOR_STATE_UNLOADED)]:
			var evidence: Dictionary = door.evidence.duplicate(false)
			evidence["state"] = door.state
			_record_rejection(diagnostics, "terrain", id, "door_state", evidence)
			return {}
	# Existing static_blocker bypasses the cell registry when a door is present.
	if door.is_empty() and fact.staticBlocked:
		_record_rejection(diagnostics, "terrain", id, "static_cell_blocker", fact.staticEvidence)
		return {}
	var position := Vector3(float(cell.x)*CELL, float(fact.height)+0.04, float(cell.y)*CELL)
	if door.is_empty():
		for record: Dictionary in _transition_collision_records(index, cell, cell):
			if not record.terrainNodeValid: continue
			if String(record.get("blockType", "")) == "prop" and record.get("cell", INVALID_CELL) != cell: continue
			if _point_inside_collision_record(position, record):
				_record_rejection(diagnostics, "terrain", id, "static_collision", record)
				return {}
	if fact.propBlocked:
		_record_rejection(diagnostics, "terrain", id, "prop_clearance", fact.propEvidence)
		return {}
	# Use the unquantized captured height for the checks above. Only emission
	# quantizes, and terrain-v-building clearance consumes this quantized surface.
	var span_y := floori(position.y/CELL)
	position.y = float(span_y)*CELL + 0.04
	var tags: Array[String] = ["terrain"]
	var semantic_ids: Array[String] = []
	if not door.is_empty(): tags.append("door")
	if fact.path: tags.append("path")
	return {"cell":Vector3i(cell.x, span_y, cell.y), "spanIndex":0,
		"worldPosition":position, "floorNormal":Vector3.UP, "headroom":3.0,
		"lateralClearance":1.0, "blocked":false,
		"semanticRegionIds":semantic_ids, "traversalTags":tags}

func _query_extent(input: Dictionary, continuation: Callable) -> Dictionary:
	var bounds := Rect2i(input.terrainCells[0].cell-Vector2i.ONE,Vector2i.ONE*3)
	for fact: Dictionary in input.terrainCells:
		bounds = bounds.merge(Rect2i(fact.cell-Vector2i.ONE,Vector2i.ONE*3))
	for tile: Dictionary in input.buildingTiles:
		for surface: Dictionary in tile.surfaces:
			if not _continue(continuation,"navigation_filter_query_extent"): return _cancelled()
			var point: Vector3 = surface.worldPosition
			var cell := Vector2i(roundi(point.x/CELL),roundi(point.z/CELL))
			bounds = bounds.merge(Rect2i(cell-Vector2i.ONE,Vector2i.ONE*3))
	return {"ready":true,"bounds":bounds}

func _collision_index(records: Array, query_bounds: Rect2i, continuation: Callable) -> Dictionary:
	var index := {}
	for record: Dictionary in records:
		if not _continue(continuation, "navigation_filter_collision_record"): return _cancelled()
		var inflation := float(record.get("inflation", INFLATION))
		var min_x := floori((float(record.get("minX", 0.0))-inflation)/CELL)-INDEX_MARGIN
		var max_x := floori((float(record.get("maxX", 0.0))+inflation)/CELL)+INDEX_MARGIN
		var min_z := floori((float(record.get("minZ", 0.0))-inflation)/CELL)-INDEX_MARGIN
		var max_z := floori((float(record.get("maxZ", 0.0))+inflation)/CELL)+INDEX_MARGIN
		# Only buckets any actual terrain/building query can read. Keep each
		# retained bucket's original record order, including duplicate IDs.
		min_x = maxi(min_x,query_bounds.position.x)
		max_x = mini(max_x,query_bounds.end.x-1)
		min_z = maxi(min_z,query_bounds.position.y)
		max_z = mini(max_z,query_bounds.end.y-1)
		for z in range(min_z, max_z+1):
			for x in range(min_x, max_x+1):
				if (x-min_x)%128 == 0 and not _continue(continuation, "navigation_filter_collision_index"): return _cancelled()
				var cell := Vector2i(x, z)
				if not index.has(cell): index[cell] = []
				(index[cell] as Array).append(record)
	return {"ready":true, "byCell":index}

func _transition_collision_records(index: Dictionary, from_cell: Vector2i, to_cell: Vector2i) -> Array:
	# Adapter semantics, NOT BuildingLayoutClearance's broader/larger query.
	# The +/-1 halo and first ID encountered in z/x/bucket order are significant.
	var result := []
	var seen := {}
	for z in range(mini(from_cell.y, to_cell.y)-1, maxi(from_cell.y, to_cell.y)+2):
		for x in range(mini(from_cell.x, to_cell.x)-1, maxi(from_cell.x, to_cell.x)+2):
			for record_value in index.get(Vector2i(x, z), []):
				if not record_value is Dictionary: continue
				var record: Dictionary = record_value
				var id := String(record.get("id", ""))
				if id == "" or seen.has(id): continue
				seen[id] = true
				result.append(record)
	return result

func _point_inside_collision_record(position: Vector3, record: Dictionary) -> bool:
	var inflation := float(record.get("inflation", INFLATION))
	# This original point predicate is XZ-only; adding Y clearance changes terrain.
	return position.x >= float(record.get("minX", 0.0))-inflation \
		and position.x <= float(record.get("maxX", 0.0))+inflation \
		and position.z >= float(record.get("minZ", 0.0))-inflation \
		and position.z <= float(record.get("maxZ", 0.0))+inflation

func _record_rejection(diagnostics: Dictionary, domain: String, source_id: String, reason: String, record: Dictionary = {}, source_part_id := "") -> void:
	if diagnostics.is_empty(): return
	var started := Time.get_ticks_usec()
	var record_id := String(record.get("id", ""))
	var group_key := reason+"|"+record_id
	var evidence: Dictionary = record.get("nodeEvidence", {})
	if record_id.is_empty() and not evidence.is_empty(): group_key += "|node:"+str(evidence.instanceId)
	if not diagnostics.blockers.has(group_key):
		var values := record.duplicate(false)
		values.erase("terrainNodeValid") # Capture-only field, not diagnostic geometry.
		diagnostics.blockers[group_key] = {"reason":reason, "record":values,
			"buildingSurfaceIdsByPart":{}, "terrainCells":[]}
	var group: Dictionary = diagnostics.blockers[group_key]
	if domain == "building":
		if not group.buildingSurfaceIdsByPart.has(source_part_id): group.buildingSurfaceIdsByPart[source_part_id] = []
		group.buildingSurfaceIdsByPart[source_part_id].append(source_id)
		diagnostics.rejectedBuildingSurfaceCount += 1
	else:
		group.terrainCells.append(source_id)
		diagnostics.rejectedTerrainCellCount += 1
		diagnostics.terrainRejectionReasons[reason] = int(diagnostics.terrainRejectionReasons.get(reason, 0))+1
	diagnostics.recordUsec += Time.get_ticks_usec()-started

static func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]

static func _continue(continuation: Callable, stage: String) -> bool:
	return not continuation.is_valid() or bool(continuation.call(stage))

static func _cancelled() -> Dictionary:
	return {"ready":false, "reason":"navigation_filter_cancelled"}

static func _invalid() -> Dictionary:
	return {"ready":false, "reason":"invalid_navigation_filter_input"}
