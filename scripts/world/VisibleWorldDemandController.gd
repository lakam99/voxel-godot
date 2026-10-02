extends RefCounted
class_name VisibleWorldDemandController

## Keeps visual evidence tied to the retained request that owns it. The
## controller schedules existing publishers; it never creates a representation.
const ReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const TerrainManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const StructureManifestScript := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
const ViewPriorityScript := preload("res://scripts/world/GeneratedContentViewPriority.gd")
const REFRESH_DISTANCE_CELLS := 24.0
const PENDING_REBASE_DISTANCE_CELLS := 24.0
const TERRAIN_BLOCKS_PER_STEP := 6
const CHUNK_SOURCE_STEPS_PER_STEP := 1

var _owners: Dictionary = {}
var _next_demand_revision := 0


func clear() -> void:
	_owners.clear()


func release(owner: String) -> void:
	_owners.erase(owner)


func has_owner(owner: String) -> bool:
	return _owners.has(owner)


func adopt(owner: String, request_id: int, seed: String, world_revision: String,
		ledger: Object, view_revision: int, center: Vector2, radius_cells: float,
		view_bounds: Rect2i, near_bounds: Rect2i) -> void:
	if owner.is_empty() or request_id <= 0 or not is_instance_valid(ledger) or view_revision <= 0:
		return
	_next_demand_revision += 1
	_owners[owner] = {"current": {"ledger": ledger, "requestId": request_id,
		"seed": seed, "worldRevision": world_revision, "viewRevision": view_revision,
		"demandRevision": _next_demand_revision,
		"center": center, "radius": radius_cells, "bounds": view_bounds,
		"nearBounds": near_bounds}, "pending": {}}


func ensure(main: Object, runtime: Object, owner: String, request_id: int,
		seed: String, world_revision: String, center_world: Vector3,
		near_bounds: Rect2i, radius_cells: float, cell_scale: float,
		chunk_size: int, view_intent: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(runtime) or owner.is_empty() \
			or request_id <= 0 or seed.is_empty() or world_revision.is_empty() \
			or not center_world.is_finite() or not is_finite(radius_cells) or radius_cells <= 0.0 \
			or cell_scale <= 0.0 or chunk_size <= 0 or not near_bounds.has_area():
		return {"status": "failed", "reason": "invalid_visual_request_demand"}
	var center_cells := center_world / cell_scale
	var center := Vector2(center_cells.x, center_cells.z)
	var state: Dictionary = _owners.get(owner, {"current": {}, "pending": {}})
	var current: Dictionary = state.get("current", {})
	var pending: Dictionary = state.get("pending", {})
	if not current.is_empty() and (int(current.requestId) != request_id \
			or String(current.seed) != seed or String(current.worldRevision) != world_revision):
		current = {}
	if not pending.is_empty() and (int(pending.requestId) != request_id \
			or String(pending.seed) != seed or String(pending.worldRevision) != world_revision):
		pending = {}
	# The adopted startup ledger proves nearby playability, but it has no
	# controller-owned horizon publishers. Build a replacement request while
	# retaining that already accepted foreground representation.
	var current_covers := current.has("terrain") \
		and _covers(current, center, near_bounds, REFRESH_DISTANCE_CELLS)
	var pending_covers := _covers(pending, center, near_bounds, PENDING_REBASE_DISTANCE_CELLS)
	if not current_covers and not pending_covers:
		var radius_int := ceili(radius_cells)
		var bounds := Rect2i(Vector2i(floori(center.x) - radius_int,
			floori(center.y) - radius_int), Vector2i.ONE * (2 * radius_int + 1))
		if not bounds.encloses(near_bounds):
			return {"status": "failed", "reason": "visual_near_region_outside_view"}
		# A modest buffer lets the foreground move through several cells before
		# its next request revision, while staying inside the existing view.
		var prepared_near := near_bounds.grow(chunk_size / 2).intersection(bounds)
		var ledger = ReadinessScript.new()
		_next_demand_revision += 1
		var admitted: Dictionary = ledger.begin_view(request_id, seed, world_revision,
			bounds, prepared_near, center, radius_cells)
		if admitted.get("status") != "ready": return admitted
		var manifest = TerrainManifestScript.new()
		var terrain_start: Dictionary = manifest.begin(runtime, ledger, request_id, seed,
			world_revision, int(admitted.viewRevision), bounds, prepared_near,
			center_cells, radius_cells)
		if terrain_start.get("status") != "ready": return terrain_start
		var keys := _ranked_chunk_keys(bounds, center_world, cell_scale,
			chunk_size, view_intent)
		pending = {"ledger": ledger, "terrain": manifest, "terrainState": terrain_start,
			"requestId": request_id, "seed": seed, "worldRevision": world_revision,
			"demandRevision": _next_demand_revision,
			"viewRevision": int(admitted.viewRevision), "center": center,
			"centerWorld": center_world,
			"radius": radius_cells, "bounds": bounds, "nearBounds": prepared_near,
			"chunkKeys": keys,
			"propCursor": 0, "structureCursor": 0,
			"propSources": {}, "structureSources": {}, "lastProp": {}, "lastStructure": {}}
	state.current = current
	state.pending = pending
	_owners[owner] = state
	return {"status": "ready" if pending.is_empty() else "pending",
		"reason": "" if pending.is_empty() else "visual_demand_preparing",
		"requestId": request_id,
		"visualDemandRevision": int(pending.get("demandRevision",
			current.get("demandRevision", 0))),
		"viewRevision": int(pending.get("viewRevision", current.get("viewRevision", 0)))}


func advance(main: Object, runtime: Object, structure_system: Object, owner: String,
		chunk_size: int) -> Dictionary:
	if not _owners.has(owner): return {"status": "pending", "reason": "visual_request_not_started"}
	var state: Dictionary = _owners[owner]
	var pending: Dictionary = state.get("pending", {})
	var advancing_pending := not pending.is_empty()
	if pending.is_empty():
		pending = state.get("current", {})
		if pending.is_empty() or not pending.has("terrain") \
				or bool(pending.get("publicationComplete", false)):
			return {"status": "ready", "reason": ""}
	if not is_instance_valid(main) or not is_instance_valid(runtime) \
			or not is_instance_valid(structure_system):
		return {"status": "pending", "reason": "visual_publisher_unavailable"}
	if String(runtime.call("visible_mesh_world_revision")) != String(pending.worldRevision):
		if advancing_pending: state.pending = {}
		else: state.current = {}
		_owners[owner] = state
		return {"status": "pending", "reason": "visual_world_revision_changed", "retryable": true}
	var terrain: Dictionary = pending.terrain.advance(TERRAIN_BLOCKS_PER_STEP)
	pending.terrainState = terrain
	if String(terrain.get("reason", "")).contains("revision_changed"):
		if advancing_pending: state.pending = {}
		else: state.current = {}
		_owners[owner] = state
		return {"status": "pending", "reason": "visual_terrain_source_revision_changed",
			"retryable": true}
	var keys: Array[Vector2i] = pending.chunkKeys
	if not keys.is_empty():
		for _step in CHUNK_SOURCE_STEPS_PER_STEP:
			var prop_key: Vector2i = keys[int(pending.propCursor)]
			pending.propCursor = (int(pending.propCursor) + 1) % keys.size()
			var prop: Dictionary = main.call("publish_chunk_prop_visual_readiness",
				pending.ledger, int(pending.viewRevision), pending.nearBounds,
				prop_key, pending.centerWorld)
			pending.lastProp = prop
			if bool(prop.get("manifestSubmitted", false)):
				pending.propSources[prop_key] = true
			var structure_key: Vector2i = keys[int(pending.structureCursor)]
			pending.structureCursor = (int(pending.structureCursor) + 1) % keys.size()
			var source_bounds := Rect2i(structure_key * chunk_size,
				Vector2i.ONE * chunk_size)
			var structure: Dictionary = StructureManifestScript.submit(main,
				structure_system, pending.ledger, int(pending.requestId),
				int(pending.viewRevision), source_bounds, source_bounds, false,
				pending.nearBounds)
			pending.lastStructure = structure
			if structure.get("status") == "ready":
				pending.structureSources[structure_key] = true
	var unscanned := maxi(0, keys.size() - pending.propSources.size()) \
		+ maxi(0, keys.size() - pending.structureSources.size())
	var terrain_pending := int(terrain.get("pendingBlocks", 0))
	pending.publicationComplete = terrain.get("status") == "ready" \
		and pending.propSources.size() == keys.size() \
		and pending.structureSources.size() == keys.size()
	pending.ledger.record_queue_diagnostics(mini(ReadinessScript.MAX_SOURCES,
		unscanned + terrain_pending), 0.0)
	var near_result: Dictionary = pending.ledger.region_readiness(
		int(pending.requestId), String(pending.seed), String(pending.worldRevision),
		int(pending.viewRevision), pending.nearBounds)
	# The old acknowledged view stays available until the replacement has
	# complete near evidence. Far coverage is still checked on the new ledger.
	if advancing_pending and near_result.get("status") == "ready":
		state.current = pending
		state.pending = {}
	elif advancing_pending:
		state.pending = pending
	else:
		state.current = pending
	_owners[owner] = state
	return {"status": String(near_result.get("status", "pending")),
		"reason": String(near_result.get("reason", "visual_representation_pending")),
		"requestId": int(pending.requestId), "viewRevision": int(pending.viewRevision),
		"visualDemandRevision": int(pending.demandRevision),
		"queueDepth": unscanned + terrain_pending,
		"expectedChunkSources": keys.size(),
		"propSourcesComplete": pending.propSources.size(),
		"structureSourcesComplete": pending.structureSources.size(),
		"terrain": terrain,
		"prop": pending.lastProp, "structures": pending.lastStructure}


func region_readiness(owner: String, request_id: int, seed: String,
		world_revision: String, bounds: Rect2i, observer_center: Vector2) -> Dictionary:
	if not _owners.has(owner):
		return {"status": "pending", "reason": "visual_request_not_started",
			"requestId": request_id, "bounds": bounds}
	var state: Dictionary = _owners[owner]
	for view: Dictionary in [state.get("pending", {}), state.get("current", {})]:
		if view.is_empty() or int(view.get("requestId", 0)) != request_id \
				or String(view.get("seed", "")) != seed \
				or String(view.get("worldRevision", "")) != world_revision:
			continue
		if not view.bounds.encloses(bounds) or not view.nearBounds.encloses(bounds):
			continue
		var lag: float = observer_center.distance_to(view.center) if owner == "player" else 0.0
		var ledger: Object = view.ledger
		var result: Dictionary = ledger.region_readiness(request_id, seed,
			world_revision, int(view.viewRevision), bounds)
		result["visualCoverageLagCells"] = minf(1000000.0, lag)
		result["visualViewCenterCells"] = view.center
		result["visualRequestOwner"] = owner
		result["visualDemandRevision"] = int(view.demandRevision)
		if result.get("status") == "ready" or view == state.get("current", {}):
			return result
	return {"status": "pending", "reason": "visual_request_region_refresh_pending",
		"requestId": request_id, "bounds": bounds, "visualRequestOwner": owner}


func full_view_readiness(owner: String, request_id: int, seed: String,
		world_revision: String) -> Dictionary:
	if not _owners.has(owner):
		return {"status": "pending", "reason": "visual_request_not_started",
			"requestId": request_id}
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	if view.is_empty() or int(view.get("requestId", 0)) != request_id \
			or String(view.get("seed", "")) != seed \
			or String(view.get("worldRevision", "")) != world_revision:
		return {"status": "pending", "reason": "visual_request_revision_changed",
			"requestId": request_id}
	var ledger: Object = view.ledger
	var result: Dictionary = ledger.region_readiness(request_id, seed,
		world_revision, int(view.viewRevision), view.bounds)
	result["visualDemandRevision"] = int(view.demandRevision)
	result["visualRequestOwner"] = owner
	return result


static func _covers(view: Dictionary, center: Vector2, near_bounds: Rect2i,
		maximum_lag: float) -> bool:
	return not view.is_empty() and view.get("bounds", Rect2i()) is Rect2i \
		and view.bounds.encloses(near_bounds) and view.nearBounds.encloses(near_bounds) \
		and center.distance_to(view.center) < maximum_lag


static func _ranked_chunk_keys(bounds: Rect2i, center_world: Vector3,
		cell_scale: float, chunk_size: int, view_intent: Dictionary) -> Array[Vector2i]:
	var groups := {}
	var keys_by_id := {}
	for z in range(floori(float(bounds.position.y) / float(chunk_size)),
			floori(float(bounds.end.y - 1) / float(chunk_size)) + 1):
		for x in range(floori(float(bounds.position.x) / float(chunk_size)),
				floori(float(bounds.end.x - 1) / float(chunk_size)) + 1):
			var key := Vector2i(x, z)
			var id := "%d,%d" % [x, z]
			var low := Vector3(float(x * chunk_size) * cell_scale, 0.0,
				float(z * chunk_size) * cell_scale)
			groups[id] = {"bounds": AABB(low, Vector3(float(chunk_size) * cell_scale,
				1.0, float(chunk_size) * cell_scale)), "doorPartIds": []}
			keys_by_id[id] = key
	var intent := view_intent.duplicate(true)
	intent["origin"] = center_world
	intent["predictedOrigin"] = center_world
	var ranked: Array[Dictionary] = ViewPriorityScript.ranked_groups(groups,
		ViewPriorityScript.normalize(intent))
	var result: Array[Vector2i] = []
	for row: Dictionary in ranked:
		result.append(keys_by_id[String(row.id)])
	return result
