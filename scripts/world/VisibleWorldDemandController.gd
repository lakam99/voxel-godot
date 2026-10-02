extends RefCounted
class_name VisibleWorldDemandController

## Keeps visual evidence tied to the retained request that owns it. The
## controller schedules existing publishers; it never creates a representation.
const ReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const TerrainManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const StructureManifestScript := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
const ViewPriorityScript := preload("res://scripts/world/GeneratedContentViewPriority.gd")
## Begin the next all-direction source view before the old 24-cell rebase.
## This only schedules existing owners; it does not enlarge the rendered view.
const REFRESH_DISTANCE_CELLS := 12.0
const PENDING_REBASE_DISTANCE_CELLS := 24.0
const TERRAIN_BLOCKS_PER_STEP := 12
const CHUNK_SOURCE_STEPS_PER_STEP := 1
const MAX_CHUNK_SOURCES_PER_VIEW := 256
const MAX_MISSING_CHUNK_DIAGNOSTICS := 8
const MAX_STALE_TERRAIN_REVISITS_PER_STEP := 8

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
		chunk_size: int, view_intent: Dictionary = {},
		near_margin_cells := -1) -> Dictionary:
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
	# controller-owned horizon publishers. Build the full-view replacement before
	# first control, then retain that accepted view during ordinary movement.
	var current_covers := current.has("terrain") \
		and _covers(current, center, near_bounds, REFRESH_DISTANCE_CELLS)
	var pending_covers := _covers(pending, center, near_bounds, PENDING_REBASE_DISTANCE_CELLS)
	if not current_covers and not pending_covers:
		var radius_int := ceili(radius_cells)
		var bounds := Rect2i(Vector2i(floori(center.x) - radius_int,
			floori(center.y) - radius_int), Vector2i.ONE * (2 * radius_int + 1))
		if not bounds.encloses(near_bounds):
			return {"status": "failed", "reason": "visual_near_region_outside_view"}
		# Gameplay prepares a small moving buffer. Loading can request the exact
		# stationary foreground so optional adjacent underground scans do not
		# become first-control dependencies.
		var margin := chunk_size / 2 if near_margin_cells < 0 else maxi(0, near_margin_cells)
		var prepared_near := near_bounds.grow(margin).intersection(bounds)
		var ledger = ReadinessScript.new()
		_next_demand_revision += 1
		var admitted: Dictionary = ledger.begin_view(request_id, seed, world_revision,
			bounds, prepared_near, center, radius_cells)
		if admitted.get("status") != "ready": return admitted
		var previous_ledgers: Array = []
		for old_view: Dictionary in [pending, current]:
			if not old_view.is_empty() and is_instance_valid(old_view.get("ledger")) \
					and not previous_ledgers.has(old_view.ledger):
				previous_ledgers.append(old_view.ledger)
		var manifest = TerrainManifestScript.new()
		var terrain_start: Dictionary = manifest.begin(runtime, ledger, request_id, seed,
			world_revision, int(admitted.viewRevision), bounds, prepared_near,
			center_cells, radius_cells, previous_ledgers)
		if terrain_start.get("status") != "ready": return terrain_start
		var keys := _ranked_chunk_keys(bounds, center_world, cell_scale,
			chunk_size, view_intent)
		if keys.size() > MAX_CHUNK_SOURCES_PER_VIEW:
			return {"status": "failed", "reason": "visual_chunk_source_capacity",
				"chunkSourceCount": keys.size(), "limit": MAX_CHUNK_SOURCES_PER_VIEW}
		pending = {"ledger": ledger, "terrain": manifest, "terrainState": terrain_start,
			# Retain only the two immediately superseded ledgers while their
			# complete interior sources can be checked against this demand.
			"overlapLedgers": previous_ledgers,
			"requestId": request_id, "seed": seed, "worldRevision": world_revision,
			"demandRevision": _next_demand_revision,
			"viewRevision": int(admitted.viewRevision), "center": center,
			"centerWorld": center_world,
			"radius": radius_cells, "bounds": bounds, "nearBounds": prepared_near,
			"chunkKeys": keys,
			"propCursor": 0, "structureCursor": 0,
			"propSources": {}, "structureSources": {}, "lastProp": {}, "lastStructure": {},
			"missingChunkSources": {},
			"dirtyChunkKeys": []}
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
	var coverage_advance_usec := 0
	var prop_advance_usec := 0
	var structure_advance_usec := 0
	if pending.is_empty():
		pending = state.get("current", {})
		var terrain_changed: bool = pending.has("terrain") \
			and pending.terrain.has_method("needs_advance") \
			and bool(pending.terrain.call("needs_advance"))
		if pending.is_empty() or not pending.has("terrain"):
			return {"status": "pending", "reason": "visual_full_view_source_not_started"}
		if bool(pending.get("publicationComplete", false)) and not terrain_changed:
			if is_instance_valid(main) and is_instance_valid(runtime) \
					and is_instance_valid(structure_system) \
					and runtime.has_method("visible_mesh_world_revision") \
					and String(runtime.call("visible_mesh_world_revision")) == String(pending.worldRevision):
				if not (pending.get("dirtyChunkKeys", []) as Array).is_empty():
					return _refresh_current_chunk(main, state, pending, owner)
				var coverage_started_usec := Time.get_ticks_usec()
				var confirmed: Dictionary = _full_view_result(pending)
				coverage_advance_usec += maxi(0, Time.get_ticks_usec() - coverage_started_usec)
				if confirmed.get("status") == "ready":
					return {"status": "ready", "reason": "", "requestId": int(pending.requestId),
						"viewRevision": int(pending.viewRevision),
						"visualDemandRevision": int(pending.demandRevision),
						"exactReceiptValidation": true,
						"coverageAdvanceUsec": coverage_advance_usec,
						"coverageGeometryUsec": confirmed.get("coverageGeometryUsec", 0),
						"receiptValidationUsec": confirmed.get("receiptValidationUsec", 0),
						"receiptValidationByKindUsec": confirmed.get("receiptValidationByKindUsec", {})}
				_request_stale_terrain_revisits(pending, confirmed)
			# A removed owner, changed tree tier, or missing source must be retried
			# through the same bounded publisher, never acknowledged from a flag.
	if not is_instance_valid(main) or not is_instance_valid(runtime) \
			or not runtime.has_method("visible_mesh_world_revision") \
			or not is_instance_valid(structure_system):
		return {"status": "pending", "reason": "visual_publisher_unavailable"}
	if String(runtime.call("visible_mesh_world_revision")) != String(pending.worldRevision):
		if advancing_pending: state.pending = {}
		else: state.current = {}
		_owners[owner] = state
		return {"status": "pending", "reason": "visual_world_revision_changed", "retryable": true}
	var terrain_started_usec := Time.get_ticks_usec()
	var terrain: Dictionary = pending.terrain.advance(TERRAIN_BLOCKS_PER_STEP)
	var terrain_advance_usec := maxi(0, Time.get_ticks_usec() - terrain_started_usec)
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
			var prop_started_usec := Time.get_ticks_usec()
			var prop: Dictionary = main.call("publish_chunk_prop_visual_readiness",
				pending.ledger, int(pending.viewRevision), pending.nearBounds,
				prop_key, pending.centerWorld)
			prop_advance_usec += maxi(0, Time.get_ticks_usec() - prop_started_usec)
			pending.lastProp = prop
			if bool(prop.get("manifestSubmitted", false)):
				pending.propSources[prop_key] = true
			if String(prop.get("reason", "")) in ["chunk_prop_source_missing", "chunk_prop_source_not_live"]:
				pending.missingChunkSources[prop_key] = true
			else:
				pending.missingChunkSources.erase(prop_key)
			var structure_key: Vector2i = keys[int(pending.structureCursor)]
			pending.structureCursor = (int(pending.structureCursor) + 1) % keys.size()
			var source_bounds := Rect2i(structure_key * chunk_size,
				Vector2i.ONE * chunk_size)
			var structure_started_usec := Time.get_ticks_usec()
			var structure: Dictionary = StructureManifestScript.submit(main,
				structure_system, pending.ledger, int(pending.requestId),
				int(pending.viewRevision), source_bounds, source_bounds, false,
				pending.nearBounds)
			structure_advance_usec += maxi(0, Time.get_ticks_usec() - structure_started_usec)
			pending.lastStructure = structure
			if structure.get("status") == "ready":
				pending.structureSources[structure_key] = true
	var unscanned := maxi(0, keys.size() - pending.propSources.size()) \
		+ maxi(0, keys.size() - pending.structureSources.size())
	var terrain_pending := int(terrain.get("pendingBlocks", 0))
	pending.publicationComplete = terrain.get("status") == "ready" \
		and pending.propSources.size() == keys.size() \
		and pending.structureSources.size() == keys.size()
	if bool(pending.publicationComplete):
		pending.overlapLedgers = []
	pending.ledger.record_queue_diagnostics(mini(ReadinessScript.MAX_SOURCES,
		unscanned + terrain_pending), 0.0)
	var coverage_started_usec := Time.get_ticks_usec()
	var full_result: Dictionary = _full_view_result(pending) \
		if bool(pending.publicationComplete) else {"status": "pending",
			"reason": "visual_source_publication_pending"}
	if bool(pending.publicationComplete):
		coverage_advance_usec += maxi(0, Time.get_ticks_usec() - coverage_started_usec)
	var stale_revisits := 0
	if full_result.get("status") == "pending":
		stale_revisits = _request_stale_terrain_revisits(pending, full_result)
	# Keep the previous accepted all-direction view until this replacement's
	# complete view and live owner receipts validate, including its far sources.
	if advancing_pending and full_result.get("status") == "ready":
		state.current = pending
		state.pending = {}
	elif advancing_pending:
		state.pending = pending
	else:
		state.current = pending
	_owners[owner] = state
	var missing_keys: Array[Vector2i] = _bounded_missing_chunk_keys(pending)
	var pending_keys: Array[Vector2i] = _bounded_pending_chunk_keys(pending)
	return {"status": String(full_result.get("status", "pending")),
		"reason": String(full_result.get("reason", "visual_representation_pending")),
		"requestId": int(pending.requestId), "viewRevision": int(pending.viewRevision),
		"visualDemandRevision": int(pending.demandRevision),
		"queueDepth": unscanned + terrain_pending,
		"expectedChunkSources": keys.size(),
		"propSourcesComplete": pending.propSources.size(),
		"structureSourcesComplete": pending.structureSources.size(),
		"missingChunkSourceCount": (pending.get("missingChunkSources", {}) as Dictionary).size(),
		"missingChunkSourceKeys": missing_keys,
		"pendingChunkSourceCount": maxi(0, keys.size() - pending.propSources.size()),
		"pendingChunkSourceKeys": pending_keys,
		"staleTerrainRevisitsQueued": stale_revisits,
		"terrainAdvanceUsec": terrain_advance_usec,
		"propAdvanceUsec": prop_advance_usec,
		"structureAdvanceUsec": structure_advance_usec,
		"coverageAdvanceUsec": coverage_advance_usec,
		"coverageGeometryUsec": full_result.get("coverageGeometryUsec", 0),
		"receiptValidationUsec": full_result.get("receiptValidationUsec", 0),
		"receiptValidationByKindUsec": full_result.get("receiptValidationByKindUsec", {}),
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
	# The adopted startup ledger is a retention source while this controller
	# builds the full all-direction view. It has no controller-owned terrain and
	# chunk source set, so it cannot be the final startup gate by itself.
	if not view.has("terrain") or not view.has("chunkKeys"):
		return {"status": "pending", "reason": "visual_full_view_source_not_started",
			"requestId": request_id, "visualDemandRevision": int(view.demandRevision)}
	var ledger: Object = view.ledger
	var result: Dictionary = ledger.region_readiness(request_id, seed,
		world_revision, int(view.viewRevision), view.bounds)
	# The ledger cannot enumerate candidates from a chunk publisher that has
	# not submitted its manifest yet. A ready receipt count is therefore only
	# complete after every required chunk source has been scanned.
	if result.get("status") == "ready" and view.has("chunkKeys") \
			and not bool(view.get("publicationComplete", false)):
		result["status"] = "pending"
		result["reason"] = "visual_source_publication_pending"
		result["pendingChunkSourceCount"] = maxi(0,
			(view.chunkKeys as Array).size() - (view.get("propSources", {}) as Dictionary).size()) \
			+ maxi(0, (view.chunkKeys as Array).size() \
				- (view.get("structureSources", {}) as Dictionary).size())
	result["visualDemandRevision"] = int(view.demandRevision)
	result["visualRequestOwner"] = owner
	return result


func ranked_chunk_keys(owner: String) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _owners.has(owner): return result
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty():
		view = state.get("current", {})
	if view.is_empty() or not view.has("chunkKeys"):
		return result
	if bool(view.get("publicationComplete", false)):
		var dirty: Dictionary = {}
		for key_value in view.get("dirtyChunkKeys", []):
			if key_value is Vector2i: dirty[key_value] = true
		for key: Vector2i in view.chunkKeys:
			if dirty.has(key): result.append(key)
		return result
	for key: Vector2i in view.chunkKeys:
		result.append(key)
	return result


## Retention covers both the accepted view and its replacement. Work ranking
## above may become empty after publication, but its installed visual sources
## must stay alive until neither view references their chunk.
func retained_chunk_keys(owner: String) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _owners.has(owner): return result
	var state: Dictionary = _owners[owner]
	var seen: Dictionary = {}
	for view_value in [state.get("current", {}), state.get("pending", {})]:
		if not view_value is Dictionary: continue
		var view: Dictionary = view_value
		for key_value in view.get("chunkKeys", []):
			if not key_value is Vector2i or seen.has(key_value): continue
			seen[key_value] = true
			result.append(key_value)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	return result


func missing_chunk_source_keys(owner: String, limit := MAX_MISSING_CHUNK_DIAGNOSTICS) -> Array[Vector2i]:
	if not _owners.has(owner): return []
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	return _bounded_missing_chunk_keys(view, limit)


func pending_chunk_source_keys(owner: String, limit := MAX_MISSING_CHUNK_DIAGNOSTICS) -> Array[Vector2i]:
	if not _owners.has(owner): return []
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	return _bounded_pending_chunk_keys(view, limit)


func mark_chunk_dirty(owner: String, chunk_key: Vector2i) -> void:
	if not _owners.has(owner): return
	var state: Dictionary = _owners[owner]
	for view_name: String in ["current", "pending"]:
		var view: Dictionary = state.get(view_name, {})
		if view.is_empty() or not (view.get("chunkKeys", []) as Array).has(chunk_key):
			continue
		var dirty: Array = view.get("dirtyChunkKeys", [])
		if not dirty.has(chunk_key): dirty.append(chunk_key)
		view.dirtyChunkKeys = dirty
		state[view_name] = view
	_owners[owner] = state


func handoff_published_tree(owner: String, chunk_key: Vector2i,
		body: StaticBody3D) -> Dictionary:
	if not _owners.has(owner) or not is_instance_valid(body):
		return {"status": "pending", "reason": "visual_tree_view_not_active"}
	var candidate_id := String(body.get_meta("prop_id", ""))
	if candidate_id.is_empty():
		return {"status": "pending", "reason": "visual_tree_candidate_id_missing"}
	var state: Dictionary = _owners[owner]
	var accepted := 0
	for view_name: String in ["current", "pending"]:
		var view: Dictionary = state.get(view_name, {})
		var ledger: Object = view.get("ledger") as Object
		if view.is_empty() or not is_instance_valid(ledger) \
				or not ledger.has_method("handoff_published_tree_receipt"):
			continue
		var source_id := "chunk-props:%s:%d,%d:trees_foliage" % [
			String(view.get("seed", "")), chunk_key.x, chunk_key.y]
		var handoff: Dictionary = ledger.call("handoff_published_tree_receipt",
			source_id, candidate_id, body)
		if handoff.get("status") == "ready": accepted += 1
	mark_chunk_dirty(owner, chunk_key)
	return {"status": "ready" if accepted > 0 else "pending",
		"acceptedViews": accepted}


func _refresh_current_chunk(main: Object, state: Dictionary,
		current: Dictionary, owner: String) -> Dictionary:
	if not is_instance_valid(main):
		return {"status": "pending", "reason": "visual_publisher_unavailable"}
	var dirty: Array = current.get("dirtyChunkKeys", [])
	var chunk_key: Vector2i = dirty.pop_front()
	var refresh: Dictionary = main.call("publish_chunk_prop_visual_readiness",
		current.ledger, int(current.viewRevision), current.nearBounds,
		chunk_key, current.centerWorld)
	if refresh.get("status") != "ready" or not bool(refresh.get("manifestSubmitted", false)):
		dirty.append(chunk_key)
	current.dirtyChunkKeys = dirty
	state.current = current
	_owners[owner] = state
	var confirmed: Dictionary = _full_view_result(current) if dirty.is_empty() \
		else {"status": "pending", "reason": "visual_receipt_refresh_pending"}
	return {"status": String(confirmed.get("status", "pending")),
		"reason": String(confirmed.get("reason", "visual_receipt_refresh_pending")),
		"queueDepth": dirty.size(), "refreshedChunk": chunk_key,
		"prop": refresh}


func pending_representation_diagnostics(owner: String, request_id: int,
		seed: String, world_revision: String, limit := 8) -> Array[Dictionary]:
	if not _owners.has(owner): return []
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	if view.is_empty() or int(view.get("requestId", 0)) != request_id \
			or String(view.get("seed", "")) != seed \
			or String(view.get("worldRevision", "")) != world_revision:
		return []
	return (view.ledger as Object).call("pending_candidate_diagnostics", request_id,
		seed, world_revision, int(view.viewRevision), view.bounds, limit)


static func _covers(view: Dictionary, center: Vector2, near_bounds: Rect2i,
		maximum_lag: float) -> bool:
	return not view.is_empty() and view.get("bounds", Rect2i()) is Rect2i \
		and view.bounds.encloses(near_bounds) and view.nearBounds.encloses(near_bounds) \
		and center.distance_to(view.center) < maximum_lag


static func _full_view_result(view: Dictionary) -> Dictionary:
	var ledger: Object = view.get("ledger")
	if not is_instance_valid(ledger):
		return {"status": "pending", "reason": "visual_ledger_owner_missing"}
	return ledger.region_readiness(int(view.requestId), String(view.seed),
		String(view.worldRevision), int(view.viewRevision), view.bounds)


static func _request_stale_terrain_revisits(view: Dictionary, result: Dictionary) -> int:
	var terrain: Object = view.get("terrain")
	var ledger: Object = view.get("ledger")
	if not is_instance_valid(terrain) or not terrain.has_method("revisit_candidate") \
			or not is_instance_valid(ledger) \
			or not ledger.has_method("pending_candidate_diagnostics"):
		return 0
	var by_kind: Dictionary = result.get("byKind", {})
	var terrain_counts: Dictionary = by_kind.get("terrain", {})
	if int(terrain_counts.get("pending", 0)) <= 0: return 0
	var rows: Array = ledger.pending_candidate_diagnostics(int(view.requestId),
		String(view.seed), String(view.worldRevision), int(view.viewRevision),
		view.bounds, MAX_STALE_TERRAIN_REVISITS_PER_STEP)
	var admitted := 0
	for row_value in rows:
		if not row_value is Dictionary: continue
		var row: Dictionary = row_value
		if String(row.get("kind", "")) != "terrain": continue
		if bool(terrain.call("revisit_candidate", String(row.get("sourceId", "")),
				String(row.get("candidateId", "")))):
			admitted += 1
	return admitted


static func _bounded_missing_chunk_keys(view: Dictionary,
		limit := MAX_MISSING_CHUNK_DIAGNOSTICS) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if view.is_empty() or limit <= 0: return result
	var missing: Dictionary = view.get("missingChunkSources", {})
	for key_value in missing.keys():
		if key_value is Vector2i:
			result.append(key_value)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	if result.size() > limit: result.resize(limit)
	return result


static func _bounded_pending_chunk_keys(view: Dictionary,
		limit := MAX_MISSING_CHUNK_DIAGNOSTICS) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if view.is_empty() or limit <= 0: return result
	var complete: Dictionary = view.get("propSources", {})
	for key_value in view.get("chunkKeys", []):
		if key_value is Vector2i and not complete.has(key_value):
			result.append(key_value)
			if result.size() >= limit: break
	return result


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
	if not intent.get("predictedOrigin") is Vector3:
		intent["predictedOrigin"] = center_world
	var ranked: Array[Dictionary] = ViewPriorityScript.ranked_groups(groups,
		ViewPriorityScript.normalize(intent))
	var result: Array[Vector2i] = []
	for row: Dictionary in ranked:
		result.append(keys_by_id[String(row.id)])
	return result
