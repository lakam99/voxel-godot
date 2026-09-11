extends RefCounted
class_name BuildingNavigationTilePreparation

## Pure worker preparation from the same manifests used by source clearance.
## No scene scan, NavigationServer resource or route authority lives here.
const Clearance = preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const STEP := Clearance.BUILDING_SUPPORT_NAV_SAMPLE_STEP
const CELL := Clearance.CELL
const TILE := CELL * Clearance.NAV_TILE_CELL_SIZE

static func compile(manifest: Dictionary, furniture: Dictionary, continuation: Callable, solids: Array = []) -> Dictionary:
	var started := Time.get_ticks_usec()
	var clearance := Clearance.new()
	clearance._load_source_navigation_manifests(manifest,[furniture])
	var keys := clearance.cached_building_supports_by_tile.keys()
	keys.sort()
	var samples := {}
	var snapshots := {}
	var blocked_count := 0
	for tile_key: String in keys:
		if not _continue(continuation,"publication_navigation_tile"): return {}
		snapshots[tile_key] = clearance._layout_source_tile_snapshot(tile_key)
		var job := clearance._new_tile_support_navigation_sample_job(clearance.building_supports_for_tile(tile_key),
			snapshots[tile_key],tile_key)
		while not job.get("done",false):
			if not _continue(continuation,"publication_navigation_sample"): return {}
			clearance._advance_tile_support_navigation_sample_job(job)
		if job.has("reason"): return {"ready":false,"reason":job.reason}
		for support_id: String in job.resultsBySupport:
			if not samples.has(support_id): samples[support_id] = {}
			var result: Dictionary = job.resultsBySupport[support_id]
			for cell: Vector2i in result.navigableCells:
				# The sampling grid is global. Boundary consumers reference one
				# sample rather than independently inventing another height.
				samples[support_id][cell] = result.navigableCells[cell]
			blocked_count += result.blockedByCell.size()
	var tiles := {}
	for fact in solids + furniture.get("staticCollision",[]):
		if not _continue(continuation,"publication_navigation_occupancy"): return {}
		var collision := clearance._manifest_static_collision_record(fact,"generated_structure")
		if collision.is_empty(): continue
		for tile_key: String in fact.get("tileKeys",[]):
			_tile(tiles,tile_key).collisionRecords.append(collision)
	var sample_count := 0
	var surface_count := 0
	var rejected_footprints := 0
	var support_ids := samples.keys()
	support_ids.sort()
	for support_id: String in support_ids:
		var support: Dictionary = clearance.cached_building_support_by_id[support_id]
		var footprint := PackedVector2Array()
		for point: Vector3 in support.polygon: footprint.append(Vector2(point.x,point.z))
		var cells: Array = samples[support_id].keys()
		cells.sort_custom(func(a: Vector2i,b: Vector2i): return a.x<b.x if a.y==b.y else a.y<b.y)
		for cell: Vector2i in cells:
			if not _continue(continuation,"publication_navigation_polygon"): return {}
			# Derive both sides from integer grid coordinates. Adding STEP to an
			# already rounded world Vector2 produces different shared boundaries
			# several kilometres from origin, preventing exact rectangle unions.
			var minimum := _sample_boundary(cell)
			var maximum := _sample_boundary(cell+Vector2i.ONE)
			var box := _rectangle(minimum,maximum)
			var clipped := Geometry2D.intersect_polygons(box,footprint)
			for polygon: PackedVector2Array in clipped:
				var low := _tile_for(minimum)
				var high := _tile_for(maximum-Vector2.ONE*0.000001)
				for z in range(low.y,high.y+1):
					for x in range(low.x,high.x+1):
						var tile_key := "%d,%d" % [x,z]
						var lower := _tile_boundary(Vector2i(x,z))
						var upper := _tile_boundary(Vector2i(x+1,z+1))
						for piece: PackedVector2Array in Geometry2D.intersect_polygons(polygon,_rectangle(lower,upper)):
							if piece.size()<3: continue
							var vertices: Array[Vector3] = []
							for point: Vector2 in piece:
								var position := Vector3(point.x,0,point.y)
								position.y = clearance._support_surface_y(support,position)+0.04
								vertices.append(position)
							# Godot's horizontal navigation polygons use clockwise XZ.
							if not Geometry2D.is_polygon_clockwise(piece): vertices.reverse()
							var record := _tile(tiles,tile_key)
							var id := "%s:cell:%d,%d:tile:%s" % [support_id,cell.x,cell.y,tile_key]
							var bounds := AABB(vertices[0],Vector3.ZERO)
							for point: Vector3 in vertices: bounds = bounds.expand(point)
							if not snapshots.has(tile_key): snapshots[tile_key] = clearance._layout_source_tile_snapshot(tile_key)
							if not clearance._building_support_navigation_blocker_for_footprint(snapshots[tile_key],support,bounds.position.y,
								Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.end.x,bounds.end.z),Clearance.BUILDING_SUPPORT_NAV_CLEARANCE,[],true).is_empty():
								rejected_footprints+=1
								continue
							record.surfaces.append({"id":id,"polygon":vertices,"sourcePartId":support.sourcePartId,
								"supportId":support_id,"geometryGroupId":support.sourceBlueprintId,"worldPosition":bounds.get_center(),"center":bounds.get_center(),
								"size":bounds.size,"floorNormal":support.floorNormal,"walkable":true})
							surface_count+=1
			sample_count+=1
	var unresolved: Array[String] = []
	for door: Dictionary in manifest.get("doors",[]):
		var tile_key := String(door.get("ownerTileKey",""))
		if tile_key.is_empty():
			var cell := _tile_for(Vector2(door.position.x,door.position.z))
			tile_key = "%d,%d" % [cell.x,cell.y]
		_tile(tiles,tile_key).doors.append(door)
		if not door.get("sourcePortalReady",false):
			_tile(tiles,tile_key).unresolvedCrossings.append(String(door.id))
			unresolved.append(String(door.id))
	for family: String in ["verticalLinks","supportSeamLinks","interiorPassageLinks"]:
		for fact: Dictionary in manifest.get(family,[]):
			if not _continue(continuation,"publication_navigation_crossing"): return {}
			var owner := String(fact.get("ownerTileKey",""))
			var record := _tile(tiles,owner)
			record.requiredCrossingIds.append(String(fact.id))
			if family=="verticalLinks" and not fact.get("endpointCertification",{}).get("resolved",false):
				record.unresolvedCrossings.append(String(fact.id))
				unresolved.append(String(fact.id))
				continue
			var crossing := fact.duplicate(true)
			# Retain declared start/end geometry and source ownership, never a
			# guessed door portal or a synthetic bridge between unrelated floors.
			crossing["kind"] = {"verticalLinks":"stair_ramp","supportSeamLinks":"support_seam","interiorPassageLinks":"interior_passage"}[family]
			record.crossingLinks.append(crossing)
	return {"ready":true,"tiles":tiles,"sampleCount":sample_count,"surfaceCount":surface_count,
		"blockedSampleCount":blocked_count,"rejectedFootprintCount":rejected_footprints,"unresolvedCrossingIds":unresolved,"preparationUsec":Time.get_ticks_usec()-started}

static func _tile(tiles: Dictionary,key: String) -> Dictionary:
	if not tiles.has(key): tiles[key] = {"surfaces":[],"crossingLinks":[],"requiredCrossingIds":[],"unresolvedCrossings":[],"collisionRecords":[],"doors":[]}
	return tiles[key]

static func _rectangle(low: Vector2,high: Vector2) -> PackedVector2Array:
	return PackedVector2Array([low,Vector2(low.x,high.y),high,Vector2(high.x,low.y)])

static func _sample_boundary(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x)*STEP,float(cell.y)*STEP)

static func _tile_boundary(tile: Vector2i) -> Vector2:
	return Vector2(float(tile.x)*TILE-CELL*0.5,float(tile.y)*TILE-CELL*0.5)

static func _tile_for(position: Vector2) -> Vector2i:
	return Vector2i(floori((position.x+CELL*0.5)/TILE),floori((position.y+CELL*0.5)/TILE))

static func _continue(callback: Callable,stage: String) -> bool:
	return not callback.is_valid() or callback.call(stage)==true
