extends RefCounted

## Read-only, bounded checkpoint evidence. This never advances a publisher or
## asks the readiness ledger to revalidate receipts during a screenshot frame.
const MAX_VIEW_ROWS := 40
const MAX_RING_ROWS := 8
const CONTENT_KINDS := ["trees_foliage", "props", "wildlife"]


static func capture(main: Object, owner := "player", cell_scale := 1.35,
        chunk_size := 28, visible_distance := 96.0,
        preparation_distance := 112.0) -> Dictionary:
    if not is_instance_valid(main): return {"status": "main_unavailable"}
    var controller := main.get("visible_world_demand_controller") as Object
    if not is_instance_valid(controller): return {"status": "controller_unavailable"}
    var owners_value: Variant = controller.get("_owners")
    if not owners_value is Dictionary: return {"status": "owners_unavailable"}
    var owner_state: Dictionary = owners_value.get(owner, {})
    var physical_value: Variant = main.get("chunks")
    var pending_value: Variant = main.get("pending_chunk_prop_spawns")
    var horizon := main.get("horizon_ecology_source") as Object
    var player := main.get("player") as Node3D
    var physical: Dictionary = physical_value if physical_value is Dictionary else {}
    var pending: Dictionary = pending_value if pending_value is Dictionary else {}
    var result := {"status": "sampled", "owner": owner, "views": {}, "ring": {}}
    for role in ["current", "pending"]:
        var view: Dictionary = owner_state.get(role, {})
        if view.is_empty(): continue
        result.views[role] = _view_snapshot(view, main, physical, pending, horizon,
            chunk_size)
    result.ring = _ring_snapshot(physical, pending, player, cell_scale, chunk_size,
        visible_distance, preparation_distance)
    return result


static func _view_snapshot(view: Dictionary, main: Object, physical: Dictionary,
        pending: Dictionary, horizon: Object, chunk_size: int) -> Dictionary:
    var keys: Array = view.get("chunkKeys", [])
    var submitted: Dictionary = view.get("propSources", {})
    var jobs: Dictionary = view.get("propJobs", {})
    var missing: Dictionary = view.get("missingChunkSources", {})
    var last: Dictionary = view.get("lastProp", {})
    var ledger := view.get("ledger") as Object
    var ledger_value: Variant = ledger.get("_sources") if is_instance_valid(ledger) else {}
    var ledger_sources: Dictionary = ledger_value if ledger_value is Dictionary else {}
    var rows: Array[Dictionary] = []
    for index in mini(keys.size(), MAX_VIEW_ROWS):
        var key_value: Variant = keys[index]
        if not key_value is Vector2i: continue
        var key: Vector2i = key_value
        rows.append(_source_row(key, view, main, physical, pending, horizon,
            submitted, jobs, missing, last, ledger_sources, chunk_size))
    return {"demandRevision": int(view.get("demandRevision", 0)),
        "viewRevision": int(view.get("viewRevision", 0)),
        "expected": keys.size(), "reportedManifestSubmitted": submitted.size(),
        "rows": rows, "rowsTruncated": maxi(0, keys.size() - rows.size())}


static func _source_row(key: Vector2i, view: Dictionary, main: Object,
        physical: Dictionary, pending: Dictionary, horizon: Object,
        submitted: Dictionary, jobs: Dictionary, missing: Dictionary,
        last: Dictionary, ledger_sources: Dictionary, chunk_size: int) -> Dictionary:
    var chunk := physical.get(key) as Node3D
    var physical_live := is_instance_valid(chunk) and chunk.is_inside_tree() \
        and not chunk.is_queued_for_deletion()
    var state_value: Variant = pending.get(key)
    var state: Dictionary = state_value if state_value is Dictionary else {}
    var state_owner := state.get("chunk") as Node3D
    var producer_owned := physical_live and is_instance_valid(state_owner) \
        and is_same(chunk, state_owner)
    var horizon_root: Node3D = horizon.call("source_for", key) as Node3D \
        if is_instance_valid(horizon) and horizon.has_method("source_for") else null
    var horizon_live := is_instance_valid(horizon_root) \
        and horizon_root.is_inside_tree() and not horizon_root.is_queued_for_deletion()
    var horizon_states: Dictionary = horizon.get("states") if is_instance_valid(horizon) else {}
    var near_bounds: Rect2i = view.get("nearBounds", Rect2i())
    var near := Rect2i(key * chunk_size, Vector2i.ONE * chunk_size).intersects(near_bounds)
    # Main's far handoff keeps the horizon owner while the physical surface
    # producer is incomplete. Keep both owners' markers in the row below.
    var use_horizon := not near and horizon_live and (not physical_live \
        or not bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)))
    var source: Node3D = horizon_root if use_horizon else chunk if physical_live else null
    var manifest_source_owner := "horizon" if use_horizon else \
        "physical" if physical_live else "missing"
    var underground_required := bool(main.call(
        "visible_world_underground_visuals_required")) \
        if main.has_method("visible_world_underground_visuals_required") else near
    var scan_key := "chunk_prop_candidate_scan_complete" if underground_required \
        else "chunk_surface_candidate_scan_complete"
    var source_ready := is_instance_valid(source) and bool(source.get_meta(scan_key, false))
    var underground_scan: Dictionary = state.get("undergroundVolumeFloorScan", {}) \
        if state.get("undergroundVolumeFloorScan", {}) is Dictionary else {}
    var underground_chunk_size := int(underground_scan.get("chunkSize", chunk_size))
    var ledger_kinds := 0
    var ledger_complete := 0
    var ledger_candidates := 0
    var seed := String(main.get("seed_text"))
    var source_prefix := "chunk-props:%s:%d,%d:" % [seed, key.x, key.y]
    for kind in CONTENT_KINDS:
        var declared: Dictionary = ledger_sources.get(source_prefix + kind, {})
        if declared.is_empty(): continue
        ledger_kinds += 1
        if bool(declared.get("complete", false)): ledger_complete += 1
        var candidates: Dictionary = declared.get("candidates", {})
        ledger_candidates += candidates.size()
    var exact_reason := String(last.get("reason", "")) \
        if last.get("chunk") == key else ""
    var stage := "manifest_submitted" if submitted.has(key) else \
        "source_missing" if not is_instance_valid(source) else \
        "producer_scan_incomplete" if not source_ready else \
        "capture_in_progress" if jobs.has(key) else "awaiting_manifest_submission"
    return {"key": [key.x, key.y], "near": near,
        "undergroundVisualsRequired": underground_required,
        "manifestSourceOwner": manifest_source_owner,
        "physicalOwnerLive": physical_live, "physicalOwnerId": chunk.get_instance_id() \
            if physical_live else 0,
        "physicalProducerPending": producer_owned,
        "physicalPhase": String(state.get("phase", "")) if producer_owned else "",
        "physicalPropIndex": int(state.get("propIndex", -1)) if producer_owned else -1,
        "physicalDetailIndex": int(state.get("detailIndex", -1)) if producer_owned else -1,
        "physicalUndergroundScanComplete": bool(state.get("undergroundScanComplete", false)) \
            if producer_owned else false,
        "physicalUndergroundScanCellsProcessed": int(
            state.get("undergroundScanCellsProcessed", 0)) if producer_owned else 0,
        "physicalUndergroundScanLastSliceCells": int(
            state.get("undergroundScanLastSliceCells", 0)) if producer_owned else 0,
        "physicalUndergroundScanColumn": int(underground_scan.get("columnIndex",
            state.get("undergroundScanColumn", 0))) if producer_owned else 0,
        "physicalUndergroundScanY": int(underground_scan.get("scanY",
            state.get("undergroundScanY", 0))) if producer_owned else 0,
        "physicalUndergroundScanColumnsTotal": underground_chunk_size * underground_chunk_size \
            if producer_owned else 0,
        "physicalUndergroundCandidateCount": (state.get("undergroundCandidates", []) as Array).size() \
            if producer_owned and state.get("undergroundCandidates", []) is Array else 0,
        "physicalUndergroundScanRestarts": int(state.get("undergroundScanRestartCount", 0)) \
            if producer_owned else 0,
        "physicalSurfaceScanComplete": physical_live and bool(chunk.get_meta(
            "chunk_surface_candidate_scan_complete", false)),
        "physicalFullScanComplete": physical_live and bool(chunk.get_meta(
            "chunk_prop_candidate_scan_complete", false)),
        "horizonRootLive": horizon_live,
        "horizonProducerPending": horizon_live and horizon_states.has(key),
        "horizonSurfaceScanComplete": horizon_live and bool(horizon_root.get_meta(
            "chunk_surface_candidate_scan_complete", false)),
        "requiredSourceScanComplete": source_ready,
        "captureJobPending": jobs.has(key), "manifestSubmitted": submitted.has(key),
        "ledgerSourceKindsDeclared": ledger_kinds,
        "ledgerSourceKindsComplete": ledger_complete,
        "ledgerCandidateCount": ledger_candidates,
        "controllerMissingSource": missing.has(key), "diagnosticStage": stage,
        "lastAttemptReason": exact_reason}


static func _ring_snapshot(physical: Dictionary, pending: Dictionary, player: Node3D,
        cell_scale: float, chunk_size: int, visible_distance: float,
        preparation_distance: float) -> Dictionary:
    var result := {"visibleDistance": visible_distance,
        "preparationDistance": preparation_distance, "physicalOwners": 0,
        "surfaceComplete": 0, "fullComplete": 0, "producerPending": 0,
        "incompleteRows": [], "incompleteRowsTruncated": 0}
    if not is_instance_valid(player) or cell_scale <= 0.0 or chunk_size <= 0 \
            or preparation_distance <= visible_distance: return result
    var incomplete := 0
    for key_value in physical.keys():
        if not key_value is Vector2i: continue
        var key: Vector2i = key_value
        var chunk := physical.get(key) as Node3D
        if not is_instance_valid(chunk) or not chunk.is_inside_tree() \
                or chunk.is_queued_for_deletion(): continue
        var distance_squared := _chunk_distance_squared(key, player.global_position,
            cell_scale, chunk_size)
        if distance_squared <= visible_distance * visible_distance \
                or distance_squared > preparation_distance * preparation_distance: continue
        result.physicalOwners = int(result.physicalOwners) + 1
        var surface_complete := bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false))
        if surface_complete:
            result.surfaceComplete = int(result.surfaceComplete) + 1
        else:
            incomplete += 1
            if (result.incompleteRows as Array).size() < MAX_RING_ROWS:
                (result.incompleteRows as Array).append({"key": [key.x, key.y],
                    "distanceMeters": sqrt(distance_squared),
                    "producerPending": pending.has(key)})
        if bool(chunk.get_meta("chunk_prop_candidate_scan_complete", false)):
            result.fullComplete = int(result.fullComplete) + 1
        if pending.has(key): result.producerPending = int(result.producerPending) + 1
    result.incompleteRowsTruncated = maxi(0, incomplete - (result.incompleteRows as Array).size())
    return result


static func _chunk_distance_squared(key: Vector2i, position: Vector3,
        cell_scale: float, chunk_size: int) -> float:
    var side := cell_scale * float(chunk_size)
    var low := Vector2(float(key.x) * side, float(key.y) * side)
    var high := low + Vector2.ONE * side
    var closest := Vector2(clampf(position.x, low.x, high.x),
        clampf(position.z, low.y, high.y))
    return closest.distance_squared_to(Vector2(position.x, position.z))
