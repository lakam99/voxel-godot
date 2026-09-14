extends RefCounted
class_name BuildingNavigationTileProducer

## Worker-confined, resumable producer of immutable source navigation tiles.
## No scene, NavigationServer, live acknowledgement or route authority belongs
## here. The owner retires this whole value graph on its existing owned worker.
const Clearance = preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const STEP := Clearance.BUILDING_SUPPORT_NAV_SAMPLE_STEP
const CELL := Clearance.CELL
const TILE := CELL * Clearance.NAV_TILE_CELL_SIZE
const MAX_OUTPUT_SELECTION := 8

var _clearance: Clearance
var _manifest: Dictionary = {}
var _furniture: Dictionary = {}
var _solids: Array = []
var _producer_keys: Array = []
var _producer_supports := {}
var _producers_by_output := {}
var _domain: Dictionary = {}
var _base_tiles := {}
var _first_occurrence := {}
var _unresolved: Array[String] = []
var _snapshots := {}
var _producer_done := {}
var _samples := {}
var _samples_by_tile := {}
var _completed := {}
var _requests: Array[String] = []
var _requested := {}
var _active_tile := ""
var _active_record := {}
var _active_producers: Array = []
var _producer_index := 0
var _job := {}
var _job_key := ""
var _job_rank := 0
var _merge_supports: Array = []
var _merge_index := 0
var _merge_cells: Array = []
var _merge_cell_index := 0
var _polygon_supports: Array = []
var _polygon_support_index := 0
var _polygon_cells: Array = []
var _polygon_cell_index := 0
var _footprint := PackedVector2Array()
var _phase := "uninitialized"
var _reason := ""
var _cancelled := false
var _sample_count := 0
var _surface_count := 0
var _blocked_count := 0
var _rejected_footprints := 0
var _preparation_usec := 0

func begin(manifest: Dictionary, furniture: Dictionary, continuation: Callable, solids: Array = []) -> Dictionary:
	if _phase != "uninitialized": return {"status":"failed","reason":"navigation_producer_already_initialized"}
	var started := Time.get_ticks_usec()
	# Runtime descriptions already own recursively frozen values. Mutable
	# direct/offline inputs get private copies; never freeze a caller's graph.
	_manifest = manifest if _sealed(manifest) else manifest.duplicate(true)
	_furniture = furniture if _sealed(furniture) else furniture.duplicate(true)
	_solids = solids if _sealed(solids) else solids.duplicate(true)
	for value in [_manifest,_furniture,_solids]:
		if not _freeze(value,continuation):
			cancel()
			return status()
	_clearance = Clearance.new()
	_clearance._load_source_navigation_manifests(_manifest,[_furniture])
	_producer_keys = _clearance.cached_building_supports_by_tile.keys()
	_producer_keys.sort()
	var output_keys := {}
	for tile_key: String in _producer_keys:
		if not _continue(continuation,"publication_navigation_index"):
			cancel(); return status()
		var supports: Array = _clearance.building_supports_for_tile(tile_key)
		if not _freeze(supports,continuation): cancel(); return status()
		_producer_supports[tile_key] = supports
		var tile := _clearance._parse_tile_key(tile_key)
		# Each center lies inside its original producer tile. Its sample box
		# extends STEP/2 beyond the center, so only adjacent output tiles can
		# receive a piece. Preserve original producer order and global supports.
		for z in range(tile.y-1,tile.y+2):
			for x in range(tile.x-1,tile.x+2):
				var output := "%d,%d" % [x,z]
				output_keys[output] = true
				if not _producers_by_output.has(output): _producers_by_output[output] = []
				_producers_by_output[output].append(tile_key)
	if not _index_direct_records(output_keys,continuation): cancel(); return status()
	var keys: Array = output_keys.keys()
	keys.sort()
	_domain = {"status":"complete","tileKeys":keys,"producerTileKeys":_producer_keys,
		"scope":"source_navigation_output"}
	for value in [_producer_supports,_producers_by_output,_base_tiles,_domain,_unresolved]:
		if not _freeze(value,continuation): cancel(); return status()
	_phase = "idle"
	_preparation_usec += Time.get_ticks_usec()-started
	return status()

func domain() -> Dictionary:
	return _domain

func request(tile_key: String) -> Dictionary:
	if _cancelled or _phase in ["uninitialized","failed"]: return status()
	if _completed.has(tile_key): return take(tile_key)
	if not _requested.has(tile_key):
		_requested[tile_key] = true
		_requests.append(tile_key)
	return {"status":"pending","reason":"navigation_tile_uncompiled","tileKey":tile_key}

func request_all() -> Dictionary:
	if _domain.is_empty(): return status()
	for key: String in _domain.tileKeys: request(key)
	return status()

## Only waiting outputs change order. An active output keeps its original
## dependency/apron job and must be covered by the same selected receipt set.
func prioritize_waiting(tile_order: Array[String]) -> Dictionary:
	if _cancelled or _phase in ["uninitialized","failed"]: return status()
	var failure := _selection_failure(tile_order)
	if not failure.is_empty(): return {"status":"failed","reason":failure}
	var waiting: Array[String] = []
	for key: String in tile_order:
		if key != _active_tile and _requested.has(key): waiting.append(key)
	for key: String in _requests:
		if not tile_order.has(key): waiting.append(key)
	_requests = waiting
	return status()

func _selection_failure(selection: Array[String]) -> String:
	if selection.is_empty() or selection.size()>MAX_OUTPUT_SELECTION: return "invalid_navigation_output_selection"
	var seen := {}
	for key: String in selection:
		if seen.has(key) or (not _requested.has(key) and not _completed.has(key)):
			return "invalid_navigation_output_selection"
		seen[key] = true
	if not _active_tile.is_empty() and not seen.has(_active_tile): return "navigation_active_output_not_selected"
	return ""

func advance(budget_usec := 4000, continuation: Callable = Callable(), eligible_outputs: Array[String] = []) -> Dictionary:
	if _cancelled or _phase in ["uninitialized","failed"]: return status()
	var eligible: Array[String] = []
	if not eligible_outputs.is_empty():
		var failure := _selection_failure(eligible_outputs)
		if not failure.is_empty(): return {"status":"failed","reason":failure}
		eligible = eligible_outputs.duplicate()
	var started := Time.get_ticks_usec()
	var deadline := started+budget_usec if budget_usec>0 else 0
	while not _cancelled and (_phase != "idle" or not _requests.is_empty()):
		if deadline>0 and Time.get_ticks_usec()>=deadline: break
		# Eligibility belongs to this call, not retained producer state. Stop at
		# the output boundary even if this kernel has time to start an old tail.
		if _phase=="idle" and not eligible.is_empty() and not eligible.has(_requests[0]): break
		if not _continue(continuation,_stage()):
			cancel(); break
		# A direct/offline continuation may change waiting demand. Recheck at
		# the call boundary before touching the queue; runtime callbacks only
		# check cancellation, but eligibility must hold for both public paths.
		if _cancelled: break
		if _phase=="idle" and (_requests.is_empty() or (not eligible.is_empty() and not eligible.has(_requests[0]))): break
		_step(deadline)
		if _phase == "failed": break
	_preparation_usec += Time.get_ticks_usec()-started
	return status()

## Repeatable borrowed receipt: arrays/facts are frozen before exposure. The
## producer retains the artifact for later demand and complete ordered export.
func take(tile_key: String) -> Dictionary:
	if _cancelled or _phase in ["uninitialized","failed"]: return status()
	if _completed.has(tile_key): return _completed[tile_key]
	return {"status":"pending","reason":"navigation_tile_uncompiled","tileKey":tile_key}

func status() -> Dictionary:
	return {"status":"cancelled" if _cancelled else ("failed" if _phase in ["uninitialized","failed"] else "ready"),
		"reason":_reason,"phase":_phase,"activeTileKey":_active_tile,
		"pendingRequestCount":_requested.size(),"completedTileCount":_completed.size(),
		"compiledProducerCount":_producer_done.size(),"producerCount":_producer_keys.size(),
		"sampleCount":_sample_count,"surfaceCount":_surface_count,"blockedSampleCount":_blocked_count,
		"rejectedFootprintCount":_rejected_footprints,"preparationUsec":_preparation_usec}

func cancel() -> void:
	_cancelled = true
	_reason = "navigation_producer_cancelled"
	# Keep heavy references until the owner retires the whole producer through
	# its established off-thread lifetime protocol.
	_requests.clear()
	_requested.clear()

func full_result() -> Dictionary:
	if _cancelled: return {}
	if _phase == "failed": return {"ready":false,"reason":_reason}
	if _domain.is_empty() or _producer_done.size()!=_producer_keys.size(): return {"ready":false,"reason":"navigation_tiles_pending"}
	for key: String in _domain.tileKeys:
		if not _completed.has(key): return {"ready":false,"reason":"navigation_tiles_pending"}
	var keys: Array = _first_occurrence.keys()
	keys.sort_custom(func(a: String,b: String): return _before(_first_occurrence[a],_first_occurrence[b]))
	var tiles := {}
	for key: String in keys: tiles[key] = _completed[key].tile
	# Preserve every legacy field and dictionary insertion order. The larger
	# conservative domain is only a scheduling proof, not extra output tiles.
	return {"ready":true,"tiles":tiles,"sampleCount":_sample_count,"surfaceCount":_surface_count,
		"blockedSampleCount":_blocked_count,"rejectedFootprintCount":_rejected_footprints,
		"unresolvedCrossingIds":_unresolved,"preparationUsec":_preparation_usec}

func _index_direct_records(output_keys: Dictionary, continuation: Callable) -> bool:
	var facts: Array = _solids + _furniture.get("staticCollision",[])
	for index in range(facts.size()):
		if not _continue(continuation,"publication_navigation_occupancy"): return false
		var fact: Dictionary = facts[index]
		var collision: Dictionary = _clearance._manifest_static_collision_record(fact,"generated_structure")
		if collision.is_empty(): continue
		var keys: Array = fact.get("tileKeys",[])
		for key_index in range(keys.size()):
			var key := String(keys[key_index])
			output_keys[key] = true
			_tile(_base_tiles,key).collisionRecords.append(collision)
			_note_occurrence(key,[0,index,key_index])
	var doors: Array = _manifest.get("doors",[])
	for index in range(doors.size()):
		var door: Dictionary = doors[index]
		var key := String(door.get("ownerTileKey",""))
		if key.is_empty():
			var tile := _tile_for(Vector2(door.position.x,door.position.z))
			key = "%d,%d" % [tile.x,tile.y]
		output_keys[key] = true
		var record := _tile(_base_tiles,key)
		record.doors.append(door)
		_note_occurrence(key,[2,index])
		if not door.get("sourcePortalReady",false):
			record.unresolvedCrossings.append(String(door.id))
			_unresolved.append(String(door.id))
	var families: Array[String] = ["verticalLinks","supportSeamLinks","interiorPassageLinks"]
	for family_index in range(families.size()):
		var family := families[family_index]
		var crossings: Array = _manifest.get(family,[])
		for index in range(crossings.size()):
			if not _continue(continuation,"publication_navigation_crossing"): return false
			var fact: Dictionary = crossings[index]
			var key := String(fact.get("ownerTileKey",""))
			output_keys[key] = true
			var record := _tile(_base_tiles,key)
			_note_occurrence(key,[3,family_index,index])
			record.requiredCrossingIds.append(String(fact.id))
			if family=="verticalLinks" and not fact.get("endpointCertification",{}).get("resolved",false):
				record.unresolvedCrossings.append(String(fact.id))
				_unresolved.append(String(fact.id))
				continue
			var crossing := fact.duplicate(true)
			crossing["kind"] = {"verticalLinks":"stair_ramp","supportSeamLinks":"support_seam","interiorPassageLinks":"interior_passage"}[family]
			record.crossingLinks.append(crossing)
	return true

func _stage() -> String:
	if _phase == "sample": return "publication_navigation_sample"
	if _phase == "polygon": return "publication_navigation_polygon"
	return "publication_navigation_tile"

func _step(deadline: int) -> void:
	match _phase:
		"idle":
			_active_tile = _requests.pop_front()
			_active_producers = _producers_by_output.get(_active_tile,[])
			_producer_index = 0
			_phase = "dependencies"
		"dependencies":
			if _producer_index >= _active_producers.size():
				_begin_polygons(); return
			_job_key = _active_producers[_producer_index]
			_producer_index += 1
			if _producer_done.has(_job_key): return
			_job_rank = _producer_keys.find(_job_key)
			_job = _clearance._new_tile_support_navigation_sample_job(_producer_supports[_job_key],_snapshot(_job_key),_job_key)
			_phase = "sample"
		"sample":
			_clearance._advance_tile_support_navigation_sample_job(_job,deadline)
			if not _job.get("done",false): return
			if _job.has("reason"):
				_phase = "failed"; _reason = String(_job.reason); return
			_merge_supports = _job.resultsBySupport.keys()
			_merge_index = 0
			_merge_cells = []
			_merge_cell_index = 0
			_phase = "merge_samples"
		"merge_samples": _merge_sample()
		"polygon": _advance_polygon()

func _merge_sample() -> void:
	if _merge_index >= _merge_supports.size():
		_producer_done[_job_key] = true
		_job = {}
		_merge_supports = []
		_merge_cells = []
		_phase = "dependencies"
		return
	var support_id := String(_merge_supports[_merge_index])
	var result: Dictionary = _job.resultsBySupport[support_id]
	if _merge_cells.is_empty() and _merge_cell_index==0:
		_merge_cells = result.navigableCells.keys()
		_blocked_count += result.blockedByCell.size()
	if _merge_cell_index >= _merge_cells.size():
		_merge_index += 1
		_merge_cells = []
		_merge_cell_index = 0
		return
	var cell: Vector2i = _merge_cells[_merge_cell_index]
	_merge_cell_index += 1
	if not _samples.has(support_id): _samples[support_id] = {}
	if not _samples[support_id].has(cell): _sample_count += 1
	# Legacy polygon generation uses the sample union, then evaluates heights
	# from the support at every polygon vertex. Retain last-producer values too.
	var previous: Dictionary = _samples[support_id].get(cell,{})
	if previous.is_empty() or int(previous.producerRank)<=_job_rank:
		_samples[support_id][cell] = {"producerRank":_job_rank,"position":result.navigableCells[cell]}
	var low := _tile_for(_sample_boundary(cell))
	var high := _tile_for(_sample_boundary(cell+Vector2i.ONE)-Vector2.ONE*0.000001)
	for z in range(low.y,high.y+1):
		for x in range(low.x,high.x+1):
			var key := "%d,%d" % [x,z]
			if not _producers_by_output.has(key) or not _producers_by_output[key].has(_job_key):
				_phase = "failed"; _reason = "navigation_apron_domain_mismatch"; return
			if not _samples_by_tile.has(key): _samples_by_tile[key] = {}
			if not _samples_by_tile[key].has(support_id): _samples_by_tile[key][support_id] = {}
			_samples_by_tile[key][support_id][cell] = true

func _begin_polygons() -> void:
	_active_record = _new_tile()
	if _base_tiles.has(_active_tile):
		# Append only to worker-owned arrays; share the already frozen facts.
		for field: String in _active_record: _active_record[field].append_array(_base_tiles[_active_tile][field])
	_polygon_supports = _samples_by_tile.get(_active_tile,{}).keys()
	_polygon_supports.sort()
	_polygon_support_index = 0
	_polygon_cells = []
	_polygon_cell_index = 0
	_phase = "polygon"

func _advance_polygon() -> void:
	if _polygon_support_index >= _polygon_supports.size():
		# Facts were sealed in bounded units as they were appended.
		for field: String in _active_record: _active_record[field].make_read_only()
		_active_record.make_read_only()
		var receipt := {"status":"ready","tileKey":_active_tile,
			"outputPresent":_first_occurrence.has(_active_tile),"tile":_active_record}
		receipt.make_read_only()
		_completed[_active_tile] = receipt
		_requested.erase(_active_tile)
		_active_tile = ""
		_active_record = {}
		_active_producers = []
		_polygon_supports = []
		_polygon_cells = []
		_phase = "idle"
		return
	var support_id := String(_polygon_supports[_polygon_support_index])
	var support: Dictionary = _clearance.cached_building_support_by_id[support_id]
	if _polygon_cells.is_empty() and _polygon_cell_index==0:
		_polygon_cells = _samples_by_tile[_active_tile][support_id].keys()
		_polygon_cells.sort_custom(func(a: Vector2i,b: Vector2i): return a.x<b.x if a.y==b.y else a.y<b.y)
		_footprint = PackedVector2Array()
		for point: Vector3 in support.polygon: _footprint.append(Vector2(point.x,point.z))
	if _polygon_cell_index >= _polygon_cells.size():
		_polygon_support_index += 1
		_polygon_cells = []
		_polygon_cell_index = 0
		return
	var cell: Vector2i = _polygon_cells[_polygon_cell_index]
	_polygon_cell_index += 1
	var minimum := _sample_boundary(cell)
	var maximum := _sample_boundary(cell+Vector2i.ONE)
	var clipped := Geometry2D.intersect_polygons(_rectangle(minimum,maximum),_footprint)
	var tile := _clearance._parse_tile_key(_active_tile)
	var lower := _tile_boundary(tile)
	var upper := _tile_boundary(tile+Vector2i.ONE)
	for polygon_index in range(clipped.size()):
		var pieces := Geometry2D.intersect_polygons(clipped[polygon_index],_rectangle(lower,upper))
		for piece_index in range(pieces.size()):
			var piece: PackedVector2Array = pieces[piece_index]
			if piece.size()<3: continue
			var vertices: Array[Vector3] = []
			for point: Vector2 in piece:
				var position := Vector3(point.x,0,point.y)
				position.y = _clearance._support_surface_y(support,position)+0.04
				vertices.append(position)
			if not Geometry2D.is_polygon_clockwise(piece): vertices.reverse()
			_note_occurrence(_active_tile,[1,support_id,cell.y,cell.x,polygon_index,tile.y,tile.x,piece_index])
			var id := "%s:cell:%d,%d:tile:%s" % [support_id,cell.x,cell.y,_active_tile]
			var bounds := AABB(vertices[0],Vector3.ZERO)
			for point: Vector3 in vertices: bounds = bounds.expand(point)
			if not _clearance._building_support_navigation_blocker_for_footprint(_snapshot(_active_tile),support,bounds.position.y,
				Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.end.x,bounds.end.z),Clearance.BUILDING_SUPPORT_NAV_CLEARANCE,[],true).is_empty():
				_rejected_footprints += 1
				continue
			var surface := {"id":id,"polygon":vertices,"sourcePartId":support.sourcePartId,
				"supportId":support_id,"geometryGroupId":support.sourceBlueprintId,"worldPosition":bounds.get_center(),"center":bounds.get_center(),
				"size":bounds.size,"floorNormal":support.floorNormal,"walkable":true}
			_freeze(surface,Callable())
			_active_record.surfaces.append(surface)
			_surface_count += 1

func _snapshot(key: String) -> Dictionary:
	if not _snapshots.has(key): _snapshots[key] = _clearance._layout_source_tile_snapshot(key)
	return _snapshots[key]

func _note_occurrence(key: String, order: Array) -> void:
	if not _first_occurrence.has(key) or _before(order,_first_occurrence[key]): _first_occurrence[key] = order

static func _before(a: Array,b: Array) -> bool:
	for index in range(mini(a.size(),b.size())):
		if a[index]!=b[index]: return a[index]<b[index]
	return a.size()<b.size()

static func _new_tile() -> Dictionary:
	return {"surfaces":[],"crossingLinks":[],"requiredCrossingIds":[],"unresolvedCrossings":[],"collisionRecords":[],"doors":[]}

static func _tile(tiles: Dictionary,key: String) -> Dictionary:
	if not tiles.has(key): tiles[key] = _new_tile()
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

static func _sealed(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key in value:
			if not _sealed(key) or not _sealed(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for item in value:
			if not _sealed(item): return false
	elif value is Object or value is Callable or value is Signal: return false
	return true

static func _freeze(value: Variant, continuation: Callable) -> bool:
	if value is Dictionary:
		if not _continue(continuation,"publication_navigation_freeze"): return false
		for key in value:
			if not _freeze(key,continuation) or not _freeze(value[key],continuation): return false
		if not value.is_read_only(): value.make_read_only()
	elif value is Array:
		if not _continue(continuation,"publication_navigation_freeze"): return false
		for item in value:
			if not _freeze(item,continuation): return false
		if not value.is_read_only(): value.make_read_only()
	elif value is Object or value is Callable or value is Signal: return false
	return true
