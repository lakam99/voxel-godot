extends RefCounted

## One resumable capture owned by GeneratedWorldNavigationAdapter. It publishes
## no geometry. Live objects stay here; only copied value facts reach a worker.
const SIZE := 16
const CELL := 1.35
const INVALID_CELL := Vector2i(999999, 999999)
var tile_key := ""
var source_key := ""
var seed_text := ""
var snapshot := {"blocked":{}, "doors":{}, "paths":{}, "propClearance":{}, "staticCollision":[]}
var terrain: Array[Dictionary] = []
var heights := {}
var projections := {}
var source_sites: Array[String] = []
var status := "pending"
var reason := "navigation_capture_pending"
var profile := {"liveUsec":0, "terrainUsec":0, "maxStepUsec":0, "steps":0,"unitSteps":0,
	"sliceCount":0,"lastSliceUsec":0,"maxSliceUsec":0,"lastSliceUnits":0,
	"phaseLifetimeUsec":{},"lastSlicePhaseUsec":{},"maxSlicePhaseUsec":{},
	"blockInventoryCount":0, "blockCandidateCount":0, "blockCandidateVisits":0,
	"blockColliderReads":0,
	"collisionInventoryCount":0, "collisionCandidateCount":0,
	"collisionIndexCellsVisited":0, "collisionIndexedOccurrenceVisits":0,
	"collisionCandidateVisits":0, "collisionOverlayVisits":0}
var _main_id := 0
var _static_revision := 0
var _semantic_revision := 0
var _door_revision := 0
var _generator: WeakRef
var _volume: WeakRef
var _volume_revision := -1
var _profiles: Array = []
var _tile := Vector2i.ZERO
var _extent := Rect2i()
var _sources: Array = []
var _source_index := 0
var _surface_index := 0
var _phase := "extent"
var _cursor := 0
var _block_keys: Array = []
var _refresh_blocks := false
var _overlay: Array = []
var _records: Array = []
var _last_frame := -1

func advanced_this_process_frame() -> bool:
	return _last_frame == Engine.get_process_frames()

func diagnostic_snapshot() -> Dictionary:
	var surface_count := 0
	if _source_index < _sources.size():
		var source_value = _sources[_source_index]
		if source_value is Dictionary:
			surface_count = (source_value as Dictionary).get("tile",{}).get("surfaces",[]).size()
	return {"tileKey":tile_key,"sourceKey":source_key,"status":status,"phase":_phase,
		"cursor":_cursor,"processFrame":Engine.get_process_frames(),"lastAdvancedFrame":_last_frame,
		"sourceCount":_sources.size(),"sourceIndex":_source_index,"surfaceIndex":_surface_index,
		"currentSourceSurfaceCount":surface_count,"extent":_extent,"recordCount":_records.size(),
		"overlayCount":_overlay.size(),"blockKeyCount":_block_keys.size(),"terrainCount":terrain.size(),
		"heightCount":heights.size(),"profile":profile.duplicate(true)}


## Cheap scheduling identity for the capture that already owns this immutable
## source. This never proves physical acceptance; the publication service still
## performs its fresh live-source proof immediately before installation.
func retained_source(owner, expected_tile_key: String) -> Dictionary:
	if tile_key != expected_tile_key or status not in ["pending", "ready"] \
			or not current_from_entry_source(owner,source_key):
		return {}
	return {"sourceKey":source_key,"sources":_sources}

func begin(owner, key: String, source: String, seed_value: String, sources: Array) -> void:
	tile_key = key
	source_key = source
	seed_text = seed_value
	_tile = owner._parse_tile_key(key)
	_extent = Rect2i(_tile*SIZE-Vector2i.ONE, Vector2i.ONE*(SIZE+2))
	_main_id = owner.main.get_instance_id()
	_static_revision = owner.static_snapshot_revision
	_semantic_revision = owner.semantic_revision
	_door_revision = owner.door_state_revision
	var generator = owner.main.get("world_generation_system")
	if is_instance_valid(generator):
		_generator = weakref(generator)
		_profiles = generator.generated_site_profiles
		var volume = generator.terrain_volume_service
		if is_instance_valid(volume):
			_volume = weakref(volume)
			_volume_revision = volume.revision
	_sources = sources.duplicate()
	for entry: Dictionary in _sources: source_sites.append(String(entry.binding.siteId))
	var blocks: Dictionary = owner.main.get("blocks")
	_block_keys = owner.navigation_capture_block_keys(key)
	profile.blockInventoryCount = blocks.size()
	profile.blockCandidateCount = _block_keys.size()
	_refresh_blocks = not blocks.is_empty()

func current(owner) -> bool:
	return _identity_current(owner) and owner.navmesh_tile_source_key_for_tile(tile_key) == source_key

## Only the adapter's same-call fresh source proof may supply this entry key.
## No proof/key is stored: independent calls, slice exit and final sealing still
## query live sources through current(). Cheap identity checks always repeat.
func current_from_entry_source(owner, entry_source_key: String) -> bool:
	return entry_source_key == source_key and _identity_current(owner)

func _identity_current(owner) -> bool:
	if not is_instance_valid(owner.main) or owner.main.get_instance_id() != _main_id \
			or (owner.main is Node and owner.main.is_queued_for_deletion()) \
			or String(owner.main.get("seed_text")) != seed_text:
		return false
	# Tile epochs are the publication identity. Global counters also advance for
	# explicitly local changes in other tiles; rejecting those counters would
	# restart an unrelated cursor even though its retained facts remain current.
	# Unscoped changes discard the cursor at the adapter cache boundary, while
	# local static/semantic/door/chunk changes alter this recomposed tile key.
	if owner._navmesh_tile_source_key_from_building_sources(tile_key,{"status":"ready","sources":_sources}) != source_key:
		return false
	var generator = _generator.get_ref() if _generator != null else null
	if owner.main.get("world_generation_system") != generator: return false
	if _generator != null:
		if not is_instance_valid(generator) or not is_same(_profiles, generator.generated_site_profiles): return false
		var volume = _volume.get_ref() if _volume != null else null
		if generator.terrain_volume_service != volume: return false
		if _volume != null and (not is_instance_valid(volume) or volume.revision != _volume_revision): return false
	return true

func advance(owner, budget_usec: int, entry_source_key: String = "") -> Dictionary:
	var started := Time.get_ticks_usec()
	var entry_current: bool = current(owner) if entry_source_key.is_empty() else current_from_entry_source(owner,entry_source_key)
	if not entry_current:
		return {"status":"stale", "reason":"navigation_source_changed_during_capture"}
	var frame := Engine.get_process_frames()
	if _last_frame == frame: return {"status":status,"reason":reason,"phase":_phase}
	_last_frame = frame
	var deadline := started + maxi(1, budget_usec)
	var units := 0
	var slice_phases: Dictionary = {}
	while status == "pending" and units < 4096 and Time.get_ticks_usec() < deadline:
		var unit_started := Time.get_ticks_usec()
		var unit_phase := _phase
		var was_terrain := unit_phase == "terrain"
		_step(owner)
		var unit_usec := Time.get_ticks_usec()-unit_started
		profile["terrainUsec" if was_terrain else "liveUsec"] += unit_usec
		profile.maxStepUsec=maxi(int(profile.maxStepUsec),unit_usec)
		profile.phaseLifetimeUsec[unit_phase]=int(profile.phaseLifetimeUsec.get(unit_phase,0))+unit_usec
		slice_phases[unit_phase]=int(slice_phases.get(unit_phase,0))+unit_usec
		units += 1
	profile.steps += 1
	profile.unitSteps += units
	profile.sliceCount += 1
	profile.lastSliceUsec = Time.get_ticks_usec()-started
	profile.maxSliceUsec = maxi(int(profile.maxSliceUsec),int(profile.lastSliceUsec))
	profile.lastSliceUnits = units
	profile.lastSlicePhaseUsec = slice_phases
	for phase: String in slice_phases:
		profile.maxSlicePhaseUsec[phase]=maxi(int(profile.maxSlicePhaseUsec.get(phase,0)),int(slice_phases[phase]))
	# The caller supplied a fresh physical source key at this slice's entry.
	# No mutation-capable callback or await occurs inside the value capture loop,
	# so repeat only the cheap lifecycle/revision identity here. The final seal
	# still calls current(), which performs authoritative physical validation.
	var exit_current: bool = current(owner) if entry_source_key.is_empty() \
		else current_from_entry_source(owner,entry_source_key)
	if not exit_current: return {"status":"stale", "reason":"navigation_source_changed_during_capture"}
	return {"status":status, "reason":reason, "phase":_phase}

func detach_live_records() -> void:
	for field: String in ["blocked","doors","paths","propClearance"]: snapshot[field] = {}
	_records = []
	_overlay = []
	_block_keys = []

func _next_phase(value: String) -> void:
	_phase = value
	_cursor = 0

func _step(owner) -> void:
	match _phase:
		"extent":
			if _source_index >= _sources.size():
				var candidates: Dictionary = owner.navigation_capture_static_collision_candidates(_extent)
				if candidates.get("status") != "ready":
					status = "failed"
					reason = String(candidates.get("reason", "navigation_collision_capture_candidates_failed"))
					return
				_records = candidates.get("records", []) as Array
				profile.collisionInventoryCount = int(candidates.get("inventoryCount", 0))
				profile.collisionCandidateCount = int(candidates.get("candidateCount", 0))
				profile.collisionIndexCellsVisited = int(candidates.get("indexCellsVisited", 0))
				profile.collisionIndexedOccurrenceVisits = int(candidates.get("indexedOccurrenceVisits", 0))
				_next_phase("cells")
				return
			var surfaces: Array = _sources[_source_index].tile.get("surfaces", [])
			if _surface_index >= surfaces.size(): _source_index += 1; _surface_index = 0; return
			var point: Vector3 = surfaces[_surface_index].worldPosition
			var cell := Vector2i(roundi(point.x/CELL), roundi(point.z/CELL))
			_extent = _extent.merge(Rect2i(cell-Vector2i.ONE, Vector2i.ONE*3))
			_surface_index += 1
		"cells":
			if _cursor >= (SIZE+2)*(SIZE+2): _next_phase("blocks"); return
			var cell := _halo_cell(_cursor)
			for pair: Array in [["blocked",owner.cached_blocked], ["doors",owner.cached_doors],
					["paths",owner.cached_paths], ["propClearance",owner.cached_prop_clearance]]:
				if _refresh_blocks and pair[0] != "propClearance" and owner.tile_key_for_cell(cell) == tile_key: continue
				if pair[1].has(cell): snapshot[pair[0]][cell] = pair[1][cell]
			_cursor += 1
		"blocks":
			if _cursor >= _block_keys.size(): _next_phase("collision"); return
			var block_key = _block_keys[_cursor]
			profile.blockCandidateVisits += 1
			var body = owner.main.blocks.get(block_key)
			_cursor += 1
			if not is_instance_valid(body) or not body is Node: return
			var cell: Vector2i = owner.block_world_cell(body)
			if cell == INVALID_CELL or owner.tile_key_for_cell(cell) != tile_key: return
			var kind := String(body.get_meta("block_type", ""))
			if kind == "door":
				snapshot.doors[cell] = body
				snapshot.blocked.erase(cell)
				profile.blockColliderReads += 1
				owner._collision_records_for_body(body,cell,kind,true)
			elif kind == "cobblestonePath":
				snapshot.paths[cell] = true
				snapshot.blocked.erase(cell)
			elif kind == "torch" or not owner._block_xz_blocks_npc_with_caches(cell,body,heights,projections): snapshot.blocked.erase(cell)
			else:
				snapshot.blocked[cell] = body
				profile.blockColliderReads += 1
				owner._append_collision_records(_overlay,body,cell,kind,false)
		"collision":
			_capture_record(owner)
		"terrain":
			if _cursor >= (SIZE+2)*(SIZE+2):
				status = "ready"; reason = "navigation_capture_complete"; return
			var cell := _halo_cell(_cursor)
			_cursor += 1
			if owner.tile_key_for_cell(cell) != tile_key: return
			var height: float = owner._height_for_cell_with_caches(cell, heights, projections)
			var door = owner.door_at(snapshot,cell)
			var door_fact := {}
			if door != null:
				door_fact = {"state":String(door.get_meta("door_state",owner.NpcEnumsScript.DOOR_STATE_CLOSED)),
					"locked":bool(door.get_meta("locked",false)), "jammed":bool(door.get_meta("jammed",false)),
					"destroyed":bool(door.get_meta("destroyed",false)), "unloaded":bool(door.get_meta("unloaded",false)),
					"evidence":owner._navmesh_node_evidence(door)}
			var blocker = owner.static_blocker(snapshot,cell)
			var prop = owner.prop_clearance_blocker(snapshot,cell)
			terrain.append({"cell":cell, "height":height, "door":door_fact,
				"staticBlocked":blocker != null, "staticEvidence":owner._navmesh_node_evidence(blocker),
				"propBlocked":prop != null, "propEvidence":owner._navmesh_node_evidence(prop),
				"path":owner.is_path_cell(snapshot,cell)})

func _halo_cell(index: int) -> Vector2i:
	return _tile*SIZE-Vector2i.ONE + Vector2i(index%(SIZE+2), floori(float(index)/(SIZE+2)))

func _capture_record(owner) -> void:
	if _cursor >= _records.size()+_overlay.size(): _next_phase("terrain"); return
	var original := _cursor < _records.size()
	var record: Dictionary = _records[_cursor] if original else _overlay[_cursor-_records.size()]
	_cursor += 1
	if original: profile.collisionCandidateVisits += 1
	else: profile.collisionOverlayVisits += 1
	var owner_cell: Vector2i = record.get("cell", INVALID_CELL)
	if original and _refresh_blocks and owner_cell != INVALID_CELL and owner.tile_key_for_cell(owner_cell) == tile_key: return
	var inflation := float(record.get("inflation",owner.TRANSITION_COLLISION_INFLATION))
	var low := Vector2i(floori((record.minX-inflation)/CELL)-2, floori((record.minZ-inflation)/CELL)-2)
	var high := Vector2i(floori((record.maxX+inflation)/CELL)+2, floori((record.maxZ+inflation)/CELL)+2)
	# Scan the authoritative inventory cooperatively, but copy/seal only records
	# that can enter a queried bucket. Original order and duplicate occurrences
	# survive; no ID deduplication or Y pruning changes first-rejection semantics.
	if Rect2i(low,high-low+Vector2i.ONE).intersects(_extent): snapshot.staticCollision.append(_fact(owner,record))

func _fact(owner, record: Dictionary) -> Dictionary:
	var fact: Dictionary = owner._navigation_rejection_record_values(record) if owner.navigation_rejection_diagnostics_enabled else record.duplicate(false)
	var node = record.get("node")
	fact.erase("node")
	fact.erase(owner.NAVIGATION_CAPTURE_ORDER_KEY)
	fact["terrainNodeValid"] = node == null or is_instance_valid(node)
	if fact.get("footprint") is Array: fact.footprint = fact.footprint.duplicate()
	return fact
