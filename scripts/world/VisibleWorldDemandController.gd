extends RefCounted
class_name VisibleWorldDemandController

## Keeps visual evidence tied to the retained request that owns it. The
## controller schedules existing publishers; it never creates a representation.
const ReadinessScript := preload("res://scripts/world/VisibleWorldReadiness.gd")
const TerrainManifestScript := preload("res://scripts/world/VoxelTerrainVisualManifest.gd")
const StructureManifestScript := preload("res://scripts/world/GeneratedStructureVisualManifest.gd")
const SupportLeaseBridgeScript := preload("res://scripts/world/VisibleSectionSupportLeaseBridge.gd")
## Begin the next all-direction source view before the old 24-cell rebase.
## This only schedules existing owners; it does not enlarge the rendered view.
const REFRESH_DISTANCE_CELLS := 12.0
const PENDING_REBASE_DISTANCE_CELLS := 24.0
const TERRAIN_BLOCKS_PER_STEP := 24
const MAX_CHUNK_SOURCE_ATOMS_PER_STEP := 4
const SOURCE_DEADLINE_RESERVE_USEC := 1000
const MAX_CHUNK_SOURCES_PER_VIEW := 256
const MAX_MISSING_CHUNK_DIAGNOSTICS := 8
const MAX_STALE_TERRAIN_REVISITS_PER_STEP := 8
const SUPERSEDED_RETENTION_USEC := 3000000
const STRUCTURE_PREFETCH_SHIFT_CELLS := 24.0
const STRUCTURE_PREFETCH_MAX_KEYS := 64
const STRUCTURE_PREFETCH_SLICE_USEC := 750
const STRUCTURE_PREFETCH_DEADLINE_RESERVE_USEC := 150

var _owners: Dictionary = {}
var _next_demand_revision := 0
var _support_lease_bridge = SupportLeaseBridgeScript.new()


func clear() -> void:
	_owners.clear()
	_support_lease_bridge.clear()


func release(owner: String) -> void:
	_owners.erase(owner)
	_support_lease_bridge.release_view(owner)


func has_owner(owner: String) -> bool:
	return _owners.has(owner)


## Queries each exact terrain section from the active view manifests. Every
## support slot owns an independent certificate and replacement lifecycle.
func refresh_support_owner_demands(owner: String, main: Object, world_id: String) -> Dictionary:
	if not _owners.has(owner) or not is_instance_valid(main) or world_id.is_empty():
		return {"status":"pending", "reason":"support_view_or_world_unavailable",
			"retryable":true, "ownerCells":{}}
	var provider: Object = main.get("ecology_static_section_provider") as Object
	if not is_instance_valid(provider):
		return {"status":"pending", "reason":"ecology_support_index_unavailable",
			"retryable":true, "ownerCells":_support_lease_bridge.owner_demand_cells(owner)}
	var state: Dictionary = _owners[owner]
	var failures: Array[String] = []
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	if view.is_empty() or not view.has("terrain"):
		failures.append("visible_terrain_manifest_unavailable")
	else:
		var terrain_manifest: Object = view.terrain as Object
		if not is_instance_valid(terrain_manifest) or not terrain_manifest.has_method("required_section_keys"):
			failures.append("terrain_manifest_section_set_unavailable")
		else:
			var required: Dictionary = terrain_manifest.call("required_section_keys")
			if required.get("status") != "ready":
				failures.append(String(required.get("reason", "terrain_section_set_pending")))
			else:
				required = required.duplicate()
				required["viewOwner"] = owner
				required["worldId"] = world_id
				required["demandRevision"] = int(view.get("demandRevision", 0))
				var refreshed: Dictionary = _support_lease_bridge.reconcile_view(owner,
					required, provider)
				if refreshed.get("status") != "ready":
					failures.append(String(refreshed.get("reason", "support_index_pending")))
	var owner_cells: Dictionary = _support_lease_bridge.owner_demand_cells(owner)
	var snapshots: Dictionary = _support_lease_bridge.required_section_snapshots(owner)
	return {"status":"pending" if not failures.is_empty() else "ready",
		"reason":failures[0] if not failures.is_empty() else "",
		"retryable":not failures.is_empty(), "ownerCells":owner_cells,
		"snapshots":snapshots}


func promote_support_section(owner: String, section_key: Vector3i,
		snapshot_digest: String) -> bool:
	return _support_lease_bridge.promote_section(owner, section_key, snapshot_digest)


func pending_support_section_snapshots(owner: String) -> Dictionary:
	return _support_lease_bridge.required_section_snapshots(owner).get("pending", {})


func active_support_section_keys(owner: String) -> Dictionary:
	return _support_lease_bridge.active_section_keys(owner)


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
		chunk_size: int, _view_intent: Dictionary = {},
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
	var superseded: Dictionary = state.get("superseded", {})
	var underground_visuals_required := bool(main.call(
		"visible_world_underground_visuals_required")) \
		if main.has_method("visible_world_underground_visuals_required") else false
	if not current.is_empty() and (int(current.requestId) != request_id \
			or String(current.seed) != seed or String(current.worldRevision) != world_revision):
		current = {}
	if not pending.is_empty() and (int(pending.requestId) != request_id \
			or String(pending.seed) != seed or String(pending.worldRevision) != world_revision):
		pending = {}
	if not superseded.is_empty() and (int(superseded.get("requestId", 0)) != request_id \
			or String(superseded.get("seed", "")) != seed \
			or String(superseded.get("worldRevision", "")) != world_revision):
		superseded = {}
	# The adopted startup ledger proves nearby playability, but it has no
	# controller-owned horizon publishers. Build the full-view replacement before
	# first control, then retain that accepted view during ordinary movement.
	var current_covers := current.has("terrain") \
		and bool(current.get("undergroundVisualsRequired", false)) \
			== underground_visuals_required \
		and _covers(current, center, near_bounds, REFRESH_DISTANCE_CELLS)
	var pending_covers := _pending_covers(pending, center, near_bounds,
		underground_visuals_required)
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
		var previous_views: Array[Dictionary] = []
		for old_view: Dictionary in [pending, current]:
			if not old_view.is_empty() and is_instance_valid(old_view.get("ledger")) \
					and bool(old_view.get("undergroundVisualsRequired", false)) \
						== underground_visuals_required \
				and not previous_ledgers.has(old_view.ledger):
				previous_ledgers.append(old_view.ledger)
				previous_views.append(old_view)
		var manifest = TerrainManifestScript.new()
		var terrain_start: Dictionary = manifest.begin(runtime, ledger, request_id, seed,
			world_revision, int(admitted.viewRevision), bounds, prepared_near,
			center_cells, radius_cells, previous_ledgers)
		if terrain_start.get("status") != "ready": return terrain_start
		var keys := _ranked_chunk_keys(bounds, center_world, cell_scale,
			chunk_size, radius_cells)
		if keys.size() > MAX_CHUNK_SOURCES_PER_VIEW:
			return {"status": "failed", "reason": "visual_chunk_source_capacity",
				"chunkSourceCount": keys.size(), "limit": MAX_CHUNK_SOURCES_PER_VIEW}
		# Keep one superseded producer footprint briefly across a fast rebase.
		# Only the new view publishes receipts and controls readiness.
		if not pending.is_empty() and pending.has("chunkKeys"):
			superseded = {"requestId": request_id, "seed": seed,
				"worldRevision": world_revision, "chunkKeys": pending.chunkKeys,
				"expiresUsec": Time.get_ticks_usec() + SUPERSEDED_RETENTION_USEC}
		pending = {"ledger": ledger, "terrain": manifest, "terrainState": terrain_start,
			"mainId": main.get_instance_id(),
			# Retain only the two immediately superseded ledgers while their
			# complete interior sources can be checked against this demand.
			"overlapLedgers": previous_ledgers,
			"overlapViews": previous_views,
			"requestId": request_id, "seed": seed, "worldRevision": world_revision,
			"demandRevision": _next_demand_revision,
			"viewRevision": int(admitted.viewRevision), "center": center,
			"undergroundVisualsRequired": underground_visuals_required,
			"centerWorld": center_world,
			"radius": radius_cells, "bounds": bounds, "nearBounds": prepared_near,
			"cellScale": cell_scale,
			"chunkKeys": keys,
			"propCursor": 0, "structureCursor": 0,
			"propJobs": {}, "propBudgetStreak": 0,
			"structureJobs": {}, "structureBudgetStreak": 0,
			"nextChunkKind": "prop",
			"propSources": {}, "structureSources": {}, "structureProofs": {},
			"structureTransfers": {}, "lastProp": {}, "lastStructure": {},
			"structureStartAudit": {"transferUnavailable": 0,
				"freshCaptureBegun": 0, "lastFreshCaptureStatus": "",
				"lastFreshCaptureReason": "", "structureAtomsAttempted": 0,
				"lastStructureKey": "", "lastPath": "",
				"lastJobWasValid": false, "lastTransferStatus": "",
				"lastTransferReason": ""},
			"missingChunkSources": {},
			"dirtyChunkKeys": []}
	state.current = current
	state.pending = pending
	state.superseded = superseded
	_owners[owner] = state
	return {"status": "ready" if pending.is_empty() else "pending",
		"reason": "" if pending.is_empty() else "visual_demand_preparing",
		"requestId": request_id,
		"visualDemandRevision": int(pending.get("demandRevision",
			current.get("demandRevision", 0))),
		"viewRevision": int(pending.get("viewRevision", current.get("viewRevision", 0)))}


func advance(main: Object, runtime: Object, structure_system: Object, owner: String,
		chunk_size: int, deadline_usec: int = 0) -> Dictionary:
	if not _owners.has(owner): return {"status": "pending", "reason": "visual_request_not_started"}
	var state: Dictionary = _owners[owner]
	var pending: Dictionary = state.get("pending", {})
	var accepted: Dictionary = state.get("current", {})
	var prefetch: Dictionary = {}
	if not accepted.is_empty() and bool(accepted.get("publicationComplete", false)) \
			and is_instance_valid(runtime) and is_instance_valid(structure_system) \
			and runtime.has_method("visible_mesh_world_revision") \
			and String(runtime.call("visible_mesh_world_revision")) == String(accepted.worldRevision):
		prefetch = _advance_structure_prefetch(structure_system, state, accepted,
			owner, chunk_size, deadline_usec)
		_owners[owner] = state
	var advancing_pending := not pending.is_empty()
	var coverage_advance_usec := 0
	var prop_advance_usec := 0
	var prop_phase_usec: Dictionary = {}
	var structure_advance_usec := 0
	var source_atoms_attempted := 0
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
						"receiptValidationByKindUsec": confirmed.get("receiptValidationByKindUsec", {}),
						"structurePrefetch": prefetch}
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
		var maximum_atoms := 2 if deadline_usec <= 0 else MAX_CHUNK_SOURCE_ATOMS_PER_STEP
		for _step in maximum_atoms:
			if deadline_usec > 0 \
					and Time.get_ticks_usec() + SOURCE_DEADLINE_RESERVE_USEC >= deadline_usec:
				break
			var kind := String(pending.get("nextChunkKind", "prop"))
			pending.nextChunkKind = "structure" if kind == "prop" else "prop"
			source_atoms_attempted += 1
			if kind == "prop":
				pending.propCursor = _next_prop_cursor(main, keys,
					int(pending.propCursor), pending)
				var prop_key: Vector2i = keys[int(pending.propCursor)]
				var prop_started_usec := Time.get_ticks_usec()
				var prop_jobs: Dictionary = pending.get("propJobs", {})
				var prop: Dictionary = main.call("publish_chunk_prop_visual_readiness",
					pending.ledger, int(pending.viewRevision), pending.nearBounds,
					prop_key, pending.centerWorld, prop_jobs.get(prop_key))
				var capture_job: Object = prop.get("captureJob") as Object
				if is_instance_valid(capture_job):
					prop_jobs[prop_key] = capture_job
				else:
					prop_jobs.erase(prop_key)
				prop.erase("captureJob")
				prop_advance_usec += maxi(0, Time.get_ticks_usec() - prop_started_usec)
				prop_phase_usec = prop.get("propPhaseUsec", {}) as Dictionary
				pending.lastProp = prop
				if bool(prop.get("manifestSubmitted", false)):
					pending.propSources[prop_key] = true
				if String(prop.get("reason", "")) in ["chunk_prop_source_missing", "chunk_prop_source_not_live"]:
					pending.missingChunkSources[prop_key] = true
				else:
					pending.missingChunkSources.erase(prop_key)
				var prop_budget_pending: bool = String(prop.get("reason", "")) == \
					"chunk_prop_bounded_capture_budget"
				if prop_budget_pending and int(pending.get("propBudgetStreak", 0)) < 2:
					pending.propBudgetStreak = int(pending.get("propBudgetStreak", 0)) + 1
				else:
					pending.propCursor = (int(pending.propCursor) + 1) % keys.size()
					pending.propBudgetStreak = 0
			else:
				var structure_key: Vector2i = keys[int(pending.structureCursor)]
				var source_bounds := Rect2i(structure_key * chunk_size,
					Vector2i.ONE * chunk_size)
				var structure_started_usec := Time.get_ticks_usec()
				var structure_jobs: Dictionary = pending.get("structureJobs", {})
				var job: Object = structure_jobs.get(structure_key)
				var structure: Dictionary = {}
				var start_audit: Dictionary = pending.get("structureStartAudit", {})
				start_audit["structureAtomsAttempted"] = int(
					start_audit.get("structureAtomsAttempted", 0)) + 1
				start_audit["lastStructureKey"] = str(structure_key)
				start_audit["lastJobWasValid"] = is_instance_valid(job)
				if not is_instance_valid(job):
					var start_result: Dictionary = _start_structure_source_atom(main,
						state, pending, structure_system, structure_key, source_bounds,
						start_audit)
					structure = start_result.get("result", {})
					job = start_result.get("job") as Object
					start_audit = start_result.get("audit", start_audit)
					if structure.get("status") == "ready":
						pending.structureSources[structure_key] = true
						(pending.get("structureProofs", {}) as Dictionary)[structure_key] = \
							structure.get("producerCertificate", {})
					if is_instance_valid(job): structure_jobs[structure_key] = job
				if is_instance_valid(job):
					structure = job.call("advance", 128, 3000)
					if (job.get("_bounded") as Dictionary).is_empty() \
							or structure.get("status") == "ready":
						structure_jobs.erase(structure_key)
				elif structure.get("reason") == "visual_overlap_transfer_budget":
					pass
				else:
					start_audit["lastPath"] = "continue_capture"
				pending.structureJobs = structure_jobs
				pending.structureStartAudit = start_audit
				structure_advance_usec += maxi(0, Time.get_ticks_usec() - structure_started_usec)
				pending.lastStructure = structure
				if String(structure.get("reason", "")) in [
						"ordinary_visual_capture_source_changed",
						"ordinary_visual_capture_owner_changed",
						"generated_structure_bounded_owner_changed",
						"generated_structure_source_revision_changed"]:
					var prefetch_state: Dictionary = state.get("structurePrefetch", {})
					(prefetch_state.get("jobs", {}) as Dictionary).erase(structure_key)
					(prefetch_state.get("ready", {}) as Dictionary).erase(structure_key)
					state.structurePrefetch = prefetch_state
				if structure.get("status") == "ready":
					pending.structureSources[structure_key] = true
					if structure.has("producerCertificate"):
						(pending.get("structureProofs", {}) as Dictionary)[structure_key] = \
							structure.producerCertificate
				var budget_pending: bool = String(structure.get("reason", "")) in [
					"ordinary_visual_capture_budget", "generated_structure_candidate_budget",
					"generated_structure_bounded_budget", "visual_overlap_transfer_budget"]
				if budget_pending and int(pending.get("structureBudgetStreak", 0)) < 2:
					pending.structureBudgetStreak = int(pending.get("structureBudgetStreak", 0)) + 1
				else:
					pending.structureCursor = (int(pending.structureCursor) + 1) % keys.size()
					pending.structureBudgetStreak = 0
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
		state.superseded = {}
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
		"propPhaseUsec": prop_phase_usec,
		"structureAdvanceUsec": structure_advance_usec,
		"sourceAtomsAttempted": source_atoms_attempted,
		"structurePhaseUsec": (pending.lastStructure as Dictionary).get("phaseUsec", {}),
		"coverageAdvanceUsec": coverage_advance_usec,
		"coverageGeometryUsec": full_result.get("coverageGeometryUsec", 0),
		"receiptValidationUsec": full_result.get("receiptValidationUsec", 0),
		"receiptValidationByKindUsec": full_result.get("receiptValidationByKindUsec", {}),
		"terrain": terrain,
		"prop": pending.lastProp, "structures": pending.lastStructure,
		"structureStartAudit": pending.get("structureStartAudit", {}).duplicate(true),
		"structurePrefetch": prefetch}


func _start_structure_source_atom(main: Object, state: Dictionary, pending: Dictionary,
		structure_system: Object, key: Vector2i, bounds: Rect2i,
		audit: Dictionary) -> Dictionary:
	audit["lastPath"] = "overlap_check"
	var result: Dictionary = _transfer_structure_overlap(state, pending,
		structure_system, key, bounds)
	audit["lastTransferStatus"] = String(result.get("status", ""))
	audit["lastTransferReason"] = String(result.get("reason", ""))
	var job: Object = null
	if result.get("status") != "ready" \
			and result.get("reason") != "visual_overlap_transfer_budget":
		audit["lastPath"] = "fresh_capture"
		if String(result.get("reason", "")) == "visual_overlap_source_not_transferable":
			audit["transferUnavailable"] = int(audit.get("transferUnavailable", 0)) + 1
		var prefetched: Object = _prefetched_structure_capture(state,
			structure_system, pending, key, bounds)
		var begun: Dictionary = StructureManifestScript.begin_bounded(main,
			structure_system, pending.ledger, int(pending.requestId),
			int(pending.viewRevision), bounds, bounds, false,
			pending.nearBounds, prefetched)
		audit["freshCaptureBegun"] = int(audit.get("freshCaptureBegun", 0)) + 1
		audit["lastFreshCaptureStatus"] = String(begun.get("status", ""))
		audit["lastFreshCaptureReason"] = String(begun.get("reason", ""))
		job = begun.get("job") as Object
		result = begun
	return {"result": result, "job": job, "audit": audit}


func _prefetched_structure_capture(state: Dictionary, structure_system: Object,
		view: Dictionary, key: Vector2i, bounds: Rect2i) -> Object:
	var prefetch: Dictionary = state.get("structurePrefetch", {})
	if int(prefetch.get("requestId", 0)) != int(view.requestId) \
			or String(prefetch.get("seed", "")) != String(view.seed) \
			or String(prefetch.get("worldRevision", "")) != String(view.worldRevision) \
			or int(prefetch.get("structureId", 0)) != structure_system.get_instance_id():
		return null
	var jobs: Dictionary = prefetch.get("jobs", {})
	var capture := jobs.get(key) as Object
	if not is_instance_valid(capture) or not capture.has_method("eligible_for") \
			or not bool(capture.call("eligible_for", structure_system, bounds)):
		jobs.erase(key)
		(prefetch.get("ready", {}) as Dictionary).erase(key)
		return null
	return capture


func _transfer_structure_overlap(state: Dictionary, view: Dictionary,
		structure_system: Object, key: Vector2i, bounds: Rect2i) -> Dictionary:
	var source_id := "generated-structure-blocks:%s" % str(bounds)
	var transfers: Dictionary = view.get("structureTransfers", {})
	var existing: Dictionary = transfers.get(key, {})
	var previous_views: Array = view.get("overlapViews", [])
	var has_previous_proof := not existing.is_empty()
	if not has_previous_proof:
		for old_view_value in previous_views:
			if old_view_value is Dictionary \
					and (old_view_value as Dictionary).get("structureProofs", {}).has(key):
				has_previous_proof = true
				break
	if not has_previous_proof:
		return {"status": "unavailable", "reason": "visual_overlap_source_not_transferable"}
	var current_certificate: Dictionary = StructureManifestScript.producer_certificate(
		structure_system, bounds)
	if current_certificate.is_empty():
		return {"status": "pending", "reason": "generated_structure_producer_certificate_pending",
			"retryable": true}
	if not existing.is_empty() and JSON.stringify(existing.get("certificate", {})) \
			!= JSON.stringify(current_certificate):
		var in_progress_ledger := existing.get("ledger") as Object
		if is_instance_valid(in_progress_ledger) and in_progress_ledger.has_method("abort_overlap_transfer"):
			in_progress_ledger.call("abort_overlap_transfer", source_id)
		transfers.erase(key)
		view.structureTransfers = transfers
		existing.clear()
	for old_view_value in previous_views:
		if not old_view_value is Dictionary: continue
		var old_view: Dictionary = old_view_value
		var old_proofs: Dictionary = old_view.get("structureProofs", {})
		var old_certificate: Dictionary = old_proofs.get(key, {})
		if old_certificate.is_empty() or JSON.stringify(old_certificate) \
				!= JSON.stringify(current_certificate):
			continue
		var old_ledger := old_view.get("ledger") as Object
		if not is_instance_valid(old_ledger) or not old_ledger.has_method("complete_source_descriptor"):
			continue
		var descriptor: Dictionary = old_ledger.call("complete_source_descriptor", source_id)
		if descriptor.is_empty() or String(descriptor.get("kind", "")) != "structures":
			continue
		var source_identity := String(descriptor.get("identity", ""))
		var old_main_id := int(old_view.get("mainId", 0))
		if old_main_id <= 0 or source_identity != "generated-structure-blocks:%d:%d:%s" % [
				old_main_id, structure_system.get_instance_id(), str(bounds)]:
			continue
		var result: Dictionary = view.ledger.call("transfer_complete_overlap_source",
			old_ledger, source_id, source_identity, String(descriptor.get("revision", "")),
			int(view.viewRevision), 64, structure_system)
		if result.get("status") == "ready":
			transfers.erase(key)
			view.structureTransfers = transfers
			result["producerCertificate"] = current_certificate
			result["candidateCount"] = int(descriptor.get("candidateCount", 0))
			result["sourceRevision"] = String(descriptor.get("revision", ""))
			return result
		if String(result.get("reason", "")) == "visual_overlap_transfer_budget":
			transfers[key] = {"ledger": old_ledger, "sourceId": source_id,
				"certificate": current_certificate}
			view.structureTransfers = transfers
			return result
		old_ledger.call("abort_overlap_transfer", source_id)
		if not existing.is_empty() and existing.get("ledger") == old_ledger:
			transfers.erase(key)
	view.structureTransfers = transfers
	return {"status": "unavailable", "reason": "visual_overlap_source_not_transferable"}


func _advance_structure_prefetch(structure_system: Object, state: Dictionary,
		current: Dictionary, owner: String, chunk_size: int,
		deadline_usec: int) -> Dictionary:
	if owner != "player" or deadline_usec <= 0 \
			or Time.get_ticks_usec() + STRUCTURE_PREFETCH_SLICE_USEC \
				+ STRUCTURE_PREFETCH_DEADLINE_RESERVE_USEC >= deadline_usec \
			or not structure_system.has_method("begin_region_ordinary_visual_source_capture"):
		return {"status": "deferred"}
	var prefetch: Dictionary = state.get("structurePrefetch", {})
	if int(prefetch.get("currentDemandRevision", 0)) != int(current.demandRevision) \
			or int(prefetch.get("requestId", 0)) != int(current.requestId) \
			or String(prefetch.get("seed", "")) != String(current.seed) \
			or String(prefetch.get("worldRevision", "")) != String(current.worldRevision) \
			or int(prefetch.get("structureId", 0)) != structure_system.get_instance_id():
		var cell_scale := float(current.get("cellScale", 0.0))
		if cell_scale <= 0.0: return {"status": "deferred"}
		var center: Vector2 = current.center
		var radius := float(current.radius) + STRUCTURE_PREFETCH_SHIFT_CELLS
		var extent := ceili(radius)
		var bounds := Rect2i(Vector2i(floori(center.x) - extent,
			floori(center.y) - extent), Vector2i.ONE * (2 * extent + 1))
		var current_keys: Dictionary = {}
		for key: Vector2i in current.chunkKeys: current_keys[key] = true
		var keys: Array[Vector2i] = []
		for key: Vector2i in _ranked_chunk_keys(bounds, current.centerWorld,
				cell_scale, chunk_size, radius):
			if not current_keys.has(key): keys.append(key)
			if keys.size() >= STRUCTURE_PREFETCH_MAX_KEYS: break
		prefetch = {"requestId": int(current.requestId), "seed": String(current.seed),
			"worldRevision": String(current.worldRevision),
			"structureId": structure_system.get_instance_id(),
			"currentDemandRevision": int(current.demandRevision),
			"keys": keys, "cursor": 0, "jobs": {}, "ready": {}}
		state.structurePrefetch = prefetch
	var keys: Array[Vector2i] = prefetch.get("keys", [])
	if keys.is_empty(): return {"status": "empty", "ready": 0, "expected": 0}
	var jobs: Dictionary = prefetch.jobs
	var ready: Dictionary = prefetch.ready
	for offset in keys.size():
		var index := (int(prefetch.cursor) + offset) % keys.size()
		var key: Vector2i = keys[index]
		if ready.has(key): continue
		var bounds := Rect2i(key * chunk_size, Vector2i.ONE * chunk_size)
		var capture := jobs.get(key) as Object
		if not is_instance_valid(capture) or not capture.has_method("eligible_for") \
				or not bool(capture.call("eligible_for", structure_system, bounds)):
			capture = structure_system.call("begin_region_ordinary_visual_source_capture", bounds)
			jobs[key] = capture
		if not is_instance_valid(capture) or not capture.has_method("advance"):
			jobs.erase(key)
			prefetch.cursor = (index + 1) % keys.size()
			break
		var result: Dictionary = capture.call("advance", 512, STRUCTURE_PREFETCH_SLICE_USEC)
		if result.get("status") == "described":
			ready[key] = true
			prefetch.cursor = (index + 1) % keys.size()
		elif result.get("reason") == "ordinary_visual_capture_budget":
			prefetch.cursor = index
		else:
			jobs.erase(key)
			prefetch.cursor = (index + 1) % keys.size()
		state.structurePrefetch = prefetch
		return {"status": String(result.get("status", "pending")),
			"reason": String(result.get("reason", "")), "key": key,
			"ready": ready.size(), "expected": keys.size(),
			"sliceUsec": int(result.get("sliceUsec", 0))}
	return {"status": "ready", "ready": ready.size(), "expected": keys.size()}


func _next_prop_cursor(main: Object, keys: Array[Vector2i], cursor: int,
		view: Dictionary) -> int:
	# A producer that has finished its required scan can be admitted now.
	# Leave unfinished producers in the rotation so missing owners still retry.
	var submitted: Dictionary = view.get("propSources", {})
	var jobs: Dictionary = view.get("propJobs", {})
	var first_unsubmitted := -1
	for offset in keys.size():
		var index := (cursor + offset) % keys.size()
		var key: Vector2i = keys[index]
		if submitted.has(key): continue
		if first_unsubmitted < 0: first_unsubmitted = index
		if jobs.has(key) or bool(main.call("chunk_prop_visual_source_scan_complete",
				key, view.nearBounds)):
			return index
	return first_unsubmitted if first_unsubmitted >= 0 else cursor


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
	var views: Array = [state.get("current", {}), state.get("pending", {})]
	var superseded: Dictionary = state.get("superseded", {})
	if not superseded.is_empty() \
			and Time.get_ticks_usec() < int(superseded.get("expiresUsec", 0)):
		views.append(superseded)
	for view_value in views:
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
	var prop_jobs: Dictionary = current.get("propJobs", {})
	var refresh: Dictionary = main.call("publish_chunk_prop_visual_readiness",
		current.ledger, int(current.viewRevision), current.nearBounds,
		chunk_key, current.centerWorld, prop_jobs.get(chunk_key))
	var capture_job: Object = refresh.get("captureJob") as Object
	if is_instance_valid(capture_job):
		prop_jobs[chunk_key] = capture_job
	else:
		prop_jobs.erase(chunk_key)
	refresh.erase("captureJob")
	current.propJobs = prop_jobs
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
		seed: String, world_revision: String, limit := 8,
		kind_filter := "", bounds_override := Rect2i()) -> Array[Dictionary]:
	if not _owners.has(owner): return []
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	if view.is_empty() or int(view.get("requestId", 0)) != request_id \
			or String(view.get("seed", "")) != seed \
			or String(view.get("worldRevision", "")) != world_revision:
		return []
	var bounds: Rect2i = view.bounds
	if bounds_override.has_area():
		if not view.bounds.encloses(bounds_override) \
				or not view.nearBounds.encloses(bounds_override):
			return []
		bounds = bounds_override
	return (view.ledger as Object).call("pending_candidate_diagnostics", request_id,
		seed, world_revision, int(view.viewRevision), bounds, limit, kind_filter)


func pending_representation_diagnostic_snapshot(owner: String, request_id: int,
		seed: String, world_revision: String, limit := 8,
		kind_filter := "", bounds_override := Rect2i()) -> Dictionary:
	var empty_snapshot := {"rows": [], "sourcesInspected": 0,
		"candidatesInspected": 0, "truncated": false, "truncationReason": ""}
	if not _owners.has(owner):
		empty_snapshot["truncationReason"] = "visual_owner_missing"
		return empty_snapshot
	var state: Dictionary = _owners[owner]
	var view: Dictionary = state.get("pending", {})
	if view.is_empty(): view = state.get("current", {})
	if view.is_empty() or int(view.get("requestId", 0)) != request_id \
			or String(view.get("seed", "")) != seed \
			or String(view.get("worldRevision", "")) != world_revision:
		empty_snapshot["truncationReason"] = "visual_view_mismatch"
		return empty_snapshot
	var bounds: Rect2i = view.bounds
	if bounds_override.has_area():
		if not view.bounds.encloses(bounds_override) \
				or not view.nearBounds.encloses(bounds_override):
			empty_snapshot["truncationReason"] = "diagnostic_bounds_outside_view"
			return empty_snapshot
		bounds = bounds_override
	var ledger: Object = view.ledger as Object
	if ledger.has_method("pending_candidate_diagnostic_snapshot"):
		return ledger.call("pending_candidate_diagnostic_snapshot", request_id,
			seed, world_revision, int(view.viewRevision), bounds, limit, kind_filter)
	empty_snapshot["reason"] = "bounded_diagnostic_api_unavailable"
	return empty_snapshot


static func _covers(view: Dictionary, center: Vector2, near_bounds: Rect2i,
		maximum_lag: float) -> bool:
	return not view.is_empty() and view.get("bounds", Rect2i()) is Rect2i \
		and view.bounds.encloses(near_bounds) and view.nearBounds.encloses(near_bounds) \
		and center.distance_to(view.center) < maximum_lag


static func _pending_covers(view: Dictionary, center: Vector2,
		near_bounds: Rect2i, underground_visuals_required := false) -> bool:
	# A prepared view covers its full source bounds while publication catches up.
	# Its initial near priority band does not move with the player, and leaving
	# that band must not discard still-useful work from the same full view.
	return not view.is_empty() \
		and bool(view.get("undergroundVisualsRequired", false)) \
			== underground_visuals_required \
		and view.get("bounds", Rect2i()) is Rect2i \
		and view.bounds.encloses(near_bounds) \
		and center.distance_to(view.center) < PENDING_REBASE_DISTANCE_CELLS


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


## Scheduling-only order: nearest chunk edge in the complete circular view first.
## Camera direction never demotes a source behind or beside the player.
static func _ranked_chunk_keys(bounds: Rect2i, center_world: Vector3,
		cell_scale: float, chunk_size: int, radius_cells: float) -> Array[Vector2i]:
	var candidates: Array[Dictionary] = []
	if bounds.size.x <= 0 or bounds.size.y <= 0 or not is_finite(cell_scale) \
			or cell_scale <= 0.0 or chunk_size <= 0 or not is_finite(radius_cells) \
			or radius_cells <= 0.0 or not center_world.is_finite():
		return []
	var center_cells := Vector2(center_world.x / cell_scale,
		center_world.z / cell_scale)
	var radius_squared := radius_cells * radius_cells
	for z in range(floori(float(bounds.position.y) / float(chunk_size)),
			floori(float(bounds.end.y - 1) / float(chunk_size)) + 1):
		for x in range(floori(float(bounds.position.x) / float(chunk_size)),
				floori(float(bounds.end.x - 1) / float(chunk_size)) + 1):
			# A whole chunk strictly outside the circular visible view has no
			# candidates for this ledger. Keep every tangent/boundary chunk.
			var closest := Vector2(clampf(center_cells.x, float(x * chunk_size),
				float((x + 1) * chunk_size)), clampf(center_cells.y,
				float(z * chunk_size), float((z + 1) * chunk_size)))
			var distance_squared := center_cells.distance_squared_to(closest)
			if distance_squared > radius_squared:
				continue
			candidates.append({"key": Vector2i(x, z), "distanceSquared": distance_squared})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.distanceSquared), float(b.distanceSquared)):
			return float(a.distanceSquared) < float(b.distanceSquared)
		var left: Vector2i = a.key
		var right: Vector2i = b.key
		return left.x < right.x if left.x != right.x else left.y < right.y)
	var result: Array[Vector2i] = []
	for candidate: Dictionary in candidates:
		result.append(candidate.key)
	return result
