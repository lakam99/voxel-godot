extends "res://scripts/MainRuntimeTools.gd"

const TreePublicationQueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const TreeRuntimeRequestBuilderScript := preload("res://scripts/environment/TreeRuntimeRequestBuilder.gd")
const TreeRequestAdmissionScript := preload("res://scripts/environment/TreeRequestAdmission.gd")
const RockRecipeBuilderScript := preload("res://scripts/environment/RockRecipeBuilder.gd")
const ChunkPropVisualManifestScript := preload("res://scripts/world/ChunkPropVisualManifest.gd")
const HorizonChunkPropManifestCacheScript := preload("res://scripts/world/HorizonChunkPropManifestCache.gd")
const PhysicalChunkPropManifestCacheScript := preload("res://scripts/world/PhysicalChunkPropManifestCache.gd")
const DetailBatchVisualReceiptPublisherScript := preload("res://scripts/world/DetailBatchVisualReceiptPublisher.gd")
const EcologySourceValueLedgerScript := preload("res://scripts/world/EcologySourceValueLedger.gd")
const EcologyProducerDomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const EcologyProducerCatalogContextScript := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
const EcologyDetailSourceValueBuilderScript := preload("res://scripts/world/EcologyDetailSourceValueBuilder.gd")
const ActiveBiomeEnvironmentSnapshotScript := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const ActiveVisualAssetSnapshotScript := preload("res://scripts/visual/ActiveVisualAssetSnapshot.gd")
const ActiveRemovedPropsSnapshotScript := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const EcologyMeshFingerprintScript := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const EcologyMaterialDigestScript := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const EcologyStaticMaterialFingerprintScript := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")

# Emitted only after the production rock body, visual and collider are published.
signal rock_published(body: StaticBody3D, collider: CollisionShape3D)

const VOLUME_CUBE_CORNER_OFFSETS := [
    Vector3i(0, 0, 0),
    Vector3i(1, 0, 0),
    Vector3i(1, 0, 1),
    Vector3i(0, 0, 1),
    Vector3i(0, 1, 0),
    Vector3i(1, 1, 0),
    Vector3i(1, 1, 1),
    Vector3i(0, 1, 1)
]
const VOLUME_TETRAHEDRA := [
    [0, 5, 1, 6],
    [0, 1, 2, 6],
    [0, 2, 3, 6],
    [0, 3, 7, 6],
    [0, 7, 4, 6],
    [0, 4, 5, 6]
]
const VOLUME_TETRAHEDRON_EDGES := [
    [0, 1],
    [0, 2],
    [0, 3],
    [1, 2],
    [1, 3],
    [2, 3]
]
const UNDERGROUND_VOLUME_MESH_STEP_CELLS := 16
const UNDERGROUND_VOLUME_COARSE_STEP_CELLS := 16
const UNDERGROUND_VOLUME_EXTERIOR_LOD_STEP_CELLS := 8
const UNDERGROUND_VOLUME_FINE_FOCUS_STEP_CELLS := 2
const UNDERGROUND_VOLUME_FOCUS_STEP_CELLS := 12
const UNDERGROUND_VOLUME_DEBUG_STEP_CELLS := 16
const UNDERGROUND_VOLUME_FOCUS_RADIUS_CELLS := 9
const UNDERGROUND_VOLUME_DEBUG_RADIUS_CELLS := 84
const UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS := 6
const UNDERGROUND_VOLUME_SURFACE_EXPOSURE_VERTICAL_STEP_CELLS := 2
const UNDERGROUND_VOLUME_Y_PADDING := CELL * 0.85
const MAX_RETAINED_ECOLOGY_SNAPSHOT_ARTIFACT_LEASES := 16
const MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_SESSIONS := 128
const MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES := 67108864

var full_exterior_indices_cache := PackedInt32Array()
var underground_focus_cache_cell := Vector3i(999999, 999999, 999999)
var underground_focus_cache_revision := -1
var underground_focus_cache_seed := ""
var underground_focus_cache_debug := false
var underground_focus_cache_result := false
var underground_chunk_exposure_cache := {}
var tree_publication_queue = null
var tree_runtime_request_builder = null
var ecology_producer_domain = EcologyProducerDomainScript.new()
var ecology_producer_catalog_context = EcologyProducerCatalogContextScript.new()
var ecology_world_epoch := 1
var ecology_current_catalog_artifact_id := ""
var ecology_current_catalog_content_digest := ""
var ecology_current_catalog_signature := ""
var ecology_current_catalog_scope_key := ""
var ecology_current_catalog_lease_token := ""
var ecology_current_owner_publications: Dictionary = {}
var ecology_snapshot_catalog_leases: Dictionary = {}
var ecology_snapshot_catalog_lease_order: Array[String] = []
var ecology_source_publication_admission_sequence := 0
## Mutable source-pass cursors live only on Main. They are never frozen or
## returned to the section adapter; adapter-owned leases bound their lifetime.
var _ecology_source_capture_sessions: Dictionary = {}
var _ecology_source_capture_phase_stats: Dictionary = {}
var _ecology_source_capture_last_call_timings: Dictionary = {}
var _ecology_source_capture_session_stats: Dictionary = {
    "created":0, "resumed":0, "cancelled":0, "stale":0,
    "completed":0, "failed":0, "reset":0,
    "completedPassCacheHits":0, "completedPassCacheEvictions":0,
    "retainedPassHits":0, "retainedPassEvictions":0,
    "retainedPayloadBudgetRejects":0, "retiredPayloadEstimateBytes":0,
    "retirementBackpressure":0}
var horizon_chunk_prop_manifest_cache = HorizonChunkPropManifestCacheScript.new()
var physical_chunk_prop_manifest_cache = PhysicalChunkPropManifestCacheScript.new()
var prop_capture_path_diagnostics: Dictionary = {}


func _record_ecology_source_capture_phase(phase: String, elapsed_usec: int) -> void:
    if phase.is_empty(): return
    var phases: Dictionary = _ecology_source_capture_phase_stats
    var row: Dictionary = phases.get(phase, {"calls":0, "totalUsec":0,
        "lastUsec":0, "maxUsec":0})
    var elapsed := maxi(0, elapsed_usec)
    row["calls"] = int(row.get("calls", 0)) + 1
    row["totalUsec"] = int(row.get("totalUsec", 0)) + elapsed
    row["lastUsec"] = elapsed
    row["maxUsec"] = maxi(int(row.get("maxUsec", 0)), elapsed)
    phases[phase] = row
    _ecology_source_capture_phase_stats = phases
    _ecology_source_capture_last_call_timings[phase] = elapsed


func ecology_source_capture_diagnostics_snapshot() -> Dictionary:
    var phases: Dictionary = _ecology_source_capture_phase_stats.duplicate(true)
    var session_phases: Dictionary = {}
    var session_progress: Array[Dictionary] = []
    var session_keys: Array = _ecology_source_capture_sessions.keys()
    session_keys.sort()
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if not session_value is Dictionary: continue
        var session: Dictionary = session_value
        var state_value: Variant = session.get("state", null)
        var phase := String(state_value.get("phase", "unknown")) \
            if state_value is Dictionary else "unknown"
        session_phases[phase] = int(session_phases.get(phase, 0)) + 1
    for identity_value: Variant in session_keys:
        var session_lookup_value: Variant = _ecology_source_capture_sessions.get(identity_value, null)
        if not session_lookup_value is Dictionary:
            continue
        var session: Dictionary = session_lookup_value
        var state_value: Variant = session.get("state", null)
        if not state_value is Dictionary:
            continue
        var state: Dictionary = state_value
        var progress := _ecology_source_pass_progress(state)
        progress["sourceChunkKey"] = Vector2i(int(state.get("cx", 0)),
            int(state.get("cz", 0)))
        progress["sliceCount"] = int(session.get("sliceCount", 0))
        progress["progressRevision"] = int(session.get("progressRevision", 0))
        progress["completedPassCached"] = bool(session.get("completedPassCached", false))
        progress["retainedIdle"] = bool(session.get("retainedIdle", false))
        progress["retirementPending"] = bool(session.get("retirementPending", false))
        progress["requestedFamilyCount"] = (state.get(
            "requestedSourceFamilies", []) as Array).size()
        progress["publishedFamilyCount"] = (session.get(
            "publishedSourceFamilies", []) as Array).size()
        progress["estimatedValueBytes"] = \
            _ecology_source_capture_value_graph_estimate_bytes(session)
        progress["identityPrefix"] = String(identity_value).substr(0, 12)
        session_progress.append(progress)
        if session_progress.size() >= 16:
            break
    return {"schema":"ecology-source-capture-diagnostics/v1",
        "sessionCount":_ecology_source_capture_sessions.size(),
        "completedPassCacheCount":_completed_ecology_source_capture_pass_count(),
        "retainedIdlePassCount":_retained_ecology_source_capture_idle_count(),
        "retainedIdleEstimatedBytes":_retained_ecology_source_capture_estimated_bytes(),
        "retainedIdleEstimatedBytesLimit":MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES,
        "retirementPendingCount":_ecology_source_capture_retirement_pending_count(),
        "retirementPendingEstimatedBytes":_ecology_source_capture_retirement_pending_estimated_bytes(),
        "sessionsByPhase":session_phases,
        "sessionProgressSample":session_progress,
        "sessionLifecycle":_ecology_source_capture_session_stats.duplicate(true),
        "phaseTimings":phases,
        "sourcePublication":ecology_producer_catalog_context.
            source_publication_diagnostics_snapshot()}


func ecology_source_capture_last_timing_snapshot() -> Dictionary:
    return _ecology_source_capture_last_call_timings.duplicate(true)


func _ecology_source_capture_session_matches(session: Dictionary,
        cache_identity: String, world_id: String, world_seed: String,
        source_chunk_key: Vector2i,
        removed_digest: String, catalog_artifact: Dictionary,
        catalog_lease_token: String) -> bool:
    # The map key is the producer domain's SHA-256 cache identity over the full
    # validated sourceInputs, policy, catalog artifact, and scoped removals.
    var state_value: Variant = session.get("state", null)
    if not state_value is Dictionary: return false
    var subscribers: Variant = session.get("subscriberLeaseTokens", null)
    if not subscribers is Array or catalog_lease_token.is_empty():
        return false
    var subscriber_lease := resolve_ecology_catalog_artifact(catalog_lease_token,
        world_id, ecology_world_epoch)
    if String(subscriber_lease.get("status", "")) != "ready" \
            or String(subscriber_lease.get("artifactId", "")) != String(
                catalog_artifact.get("artifactId", "")):
        return false
    var session_lease_token := String(session.get("sessionLeaseToken", ""))
    var session_lease := resolve_ecology_catalog_artifact(session_lease_token,
        world_id, ecology_world_epoch) if not session_lease_token.is_empty() else {}
    if String(session_lease.get("status", "")) != "ready" \
            or String(session_lease.get("artifactId", "")) != String(
                catalog_artifact.get("artifactId", "")):
        return false
    var state: Dictionary = state_value
    return String(session.get("cacheIdentity", "")) == cache_identity \
        and String(session.get("worldId", "")) == world_id \
        and int(session.get("worldEpoch", -1)) == ecology_world_epoch \
        and String(session.get("worldSeed", "")) == world_seed \
        and Vector2i(session.get("sourceChunkKey", Vector2i.ZERO)) == source_chunk_key \
        and not String(session.get("sourceDomainRevision", "")).is_empty() \
        and String(state.get("cacheIdentity", "")) == cache_identity \
        and String(state.get("sourceDomainRevision", "")) == String( \
            session.get("sourceDomainRevision", "")) \
        and String(state.get("sourceWorldId", "")) == world_id \
        and String(state.get("sourceWorldSeed", "")) == world_seed \
        and Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0))) == source_chunk_key \
        and String(session.get("removedSourceProjectionDigest", "")) == removed_digest \
        and String(session.get("catalogArtifactId", "")) == String(
            catalog_artifact.get("artifactId", "")) \
        and not bool(session.get("terminalFailure", false)) \
        and int(session.get("worldEpoch", -1)) == ecology_world_epoch \
        and String(session.get("sessionLeaseToken", "")).begins_with("ecology-artifact-lease:")


func _new_ecology_source_capture_session(cache_identity: String,
        world_id: String, world_seed: String, source_chunk_key: Vector2i,
        source_revision: String,
        removed_digest: String, catalog_artifact: Dictionary,
        state: Dictionary, owner_lease_token: String) -> Dictionary:
    if owner_lease_token.is_empty():
        return {}
    var owner_lease := resolve_ecology_catalog_artifact(owner_lease_token,
        world_id, ecology_world_epoch)
    if String(owner_lease.get("status", "")) != "ready" \
            or String(owner_lease.get("artifactId", "")) != String(
                catalog_artifact.get("artifactId", "")):
        return {}
    var session_lease := acquire_ecology_catalog_artifact_lease(
        String(catalog_artifact.get("artifactId", "")), "source_capture_session",
        cache_identity, world_id, ecology_world_epoch)
    if String(session_lease.get("status", "")) != "ready":
        return {}
    var session := {"cacheIdentity":cache_identity, "worldId":world_id,
        "worldEpoch":ecology_world_epoch, "worldSeed":world_seed,
        "sourceChunkKey":source_chunk_key,
        "sourceDomainRevision":source_revision,
        "removedSourceProjectionDigest":removed_digest,
        "catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
        "sessionLeaseToken":String(session_lease.get("leaseToken", "")),
        "subscriberLeaseTokens":[owner_lease_token] if not owner_lease_token.is_empty() else [],
        "startedUsec":Time.get_ticks_usec(), "lastAccessUsec":Time.get_ticks_usec(),
        "completedPassCached":false, "retainedIdle":false, "sliceCount":0,
        "state":state}
    _ecology_source_capture_sessions[cache_identity] = session
    _ecology_source_capture_session_stats["created"] = int(
        _ecology_source_capture_session_stats.get("created", 0)) + 1
    return session


func _seal_ecology_source_capture_snapshot(payload: Dictionary,
        catalog_artifact: Dictionary) -> Dictionary:
    return EcologyProducerDomainScript.seal_source_domain_snapshot(payload,
        catalog_artifact)


func _drop_ecology_source_capture_session(cache_identity: String,
        reason: String) -> bool:
    if cache_identity.is_empty() or not _ecology_source_capture_sessions.has(cache_identity):
        return false
    var session_value: Variant = _ecology_source_capture_sessions.get(cache_identity, null)
    if session_value is Dictionary:
        if reason == "failed":
            session_value["terminalFailure"] = true
        if not _queue_ecology_source_capture_values_for_retirement(session_value):
            session_value["retirementPending"] = true
            _ecology_source_capture_sessions[cache_identity] = session_value
            _ecology_source_capture_session_stats["retirementBackpressure"] = int(
                _ecology_source_capture_session_stats.get("retirementBackpressure", 0)) + 1
            return false
        var session_token := String(session_value.get("sessionLeaseToken", ""))
        if not session_token.is_empty():
            release_ecology_catalog_artifact_lease(session_token)
    _ecology_source_capture_sessions.erase(cache_identity)
    if reason == "completed":
        _ecology_source_capture_session_stats["completed"] = int(
            _ecology_source_capture_session_stats.get("completed", 0)) + 1
    elif reason == "failed":
        _ecology_source_capture_session_stats["failed"] = int(
            _ecology_source_capture_session_stats.get("failed", 0)) + 1
    elif reason == "stale":
        _ecology_source_capture_session_stats["stale"] = int(
            _ecology_source_capture_session_stats.get("stale", 0)) + 1
    elif reason == "completed_cache_eviction":
        _ecology_source_capture_session_stats["cacheEvicted"] = int(
            _ecology_source_capture_session_stats.get("cacheEvicted", 0)) + 1
    else:
        _ecology_source_capture_session_stats["cancelled"] = int(
            _ecology_source_capture_session_stats.get("cancelled", 0)) + 1
    return true


func _make_room_for_ecology_source_capture_session() -> bool:
    if _ecology_source_capture_sessions.size() < MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_SESSIONS:
        return true
    var candidates: Array[String] = []
    for identity_value: Variant in _ecology_source_capture_sessions:
        var identity := String(identity_value)
        var session_value: Variant = _ecology_source_capture_sessions.get(identity, null)
        if session_value is Dictionary and (bool(session_value.get(
                "completedPassCached", false)) or bool(session_value.get(
                "retainedIdle", false)) or bool(session_value.get(
                "retirementPending", false))) \
                and (session_value.get("subscriberLeaseTokens", []) as Array).is_empty():
            candidates.append(identity)
    candidates.sort_custom(func(a: String, b: String) -> bool:
        var a_session: Dictionary = _ecology_source_capture_sessions.get(a, {})
        var b_session: Dictionary = _ecology_source_capture_sessions.get(b, {})
        var a_time := int(a_session.get("lastAccessUsec", 0))
        var b_time := int(b_session.get("lastAccessUsec", 0))
        return a_time < b_time if a_time != b_time else a < b)
    for identity: String in candidates:
        var candidate_value: Variant = _ecology_source_capture_sessions.get(identity, {})
        var was_completed_pass: bool = candidate_value is Dictionary \
            and bool(candidate_value.get("completedPassCached", false))
        if _drop_ecology_source_capture_session(identity, "completed_cache_eviction"):
            var eviction_key: String = "completedPassCacheEvictions" \
                if was_completed_pass else "retainedPassEvictions"
            _ecology_source_capture_session_stats[eviction_key] = int(
                _ecology_source_capture_session_stats.get(eviction_key, 0)) + 1
            if _ecology_source_capture_sessions.size() \
                    < MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_SESSIONS:
                return true
    return _ecology_source_capture_sessions.size() \
        < MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_SESSIONS


func _queue_ecology_source_capture_values_for_retirement(session: Dictionary) -> bool:
    var state_value: Variant = session.get("state", null)
    if not state_value is Dictionary:
        return true
    var state: Dictionary = state_value
    var source_rows_value: Variant = state.get("sourceRows", [])
    var actor_intents_value: Variant = state.get("actorIntents", [])
    var source_rows: Array = source_rows_value if source_rows_value is Array else []
    var actor_intents: Array = actor_intents_value if actor_intents_value is Array else []
    var underground_candidates_value: Variant = state.get("undergroundCandidates", [])
    var underground_candidates: Array = underground_candidates_value \
        if underground_candidates_value is Array else []
    var detail_batches_value: Variant = state.get("detailBatches", {})
    var detail_batches: Dictionary = detail_batches_value \
        if detail_batches_value is Dictionary else {}
    var detail_rows_value: Variant = state.get("detailSourceRows", [])
    var detail_rows: Array = detail_rows_value if detail_rows_value is Array else []
    var detail_keys_value: Variant = state.get("detailBatchKeys", [])
    var detail_keys: Array = detail_keys_value if detail_keys_value is Array else []
    var active_attempt_value: Variant = state.get("detailActiveAttempt", {})
    var active_attempt: Dictionary = active_attempt_value \
        if active_attempt_value is Dictionary else {}
    var floor_scan_value: Variant = state.get("undergroundVolumeFloorScan", {})
    var floor_scan: Dictionary = floor_scan_value \
        if floor_scan_value is Dictionary else {}
    if source_rows.is_empty() and actor_intents.is_empty() \
            and underground_candidates.is_empty() and detail_batches.is_empty() \
            and detail_rows.is_empty() and active_attempt.is_empty() \
            and floor_scan.is_empty():
        return true
    var queue_value: Variant = get("tree_publication_queue")
    if not is_instance_valid(queue_value) or not queue_value.has_method(
            "_queue_tree_value_retirement"):
        return false
    # Generated rows are value-only dictionaries/arrays. No other owner retains
    # these private arrays; published family bundles seal independent copies.
    # The queue's worker drops the exact aliases after a later advance, once this
    # call has returned and the source session no longer owns them.
    var value_root := {"schema":"ecology-source-capture-values/v2",
        "sourceRows":source_rows, "actorIntents":actor_intents,
        "undergroundCandidates":underground_candidates,
        "detailBatches":detail_batches, "detailSourceRows":detail_rows,
        "detailBatchKeys":detail_keys, "detailActiveAttempt":active_attempt,
        "undergroundVolumeFloorScan":floor_scan}
    value_root.make_read_only()
    var roots: Array[Dictionary] = [value_root]
    var keepalives: Array[RefCounted] = []
    for keepalive_key: String in ["rng", "undergroundRng", "detailRng",
            "ecologySourceLedger"]:
        var keepalive_value: Variant = state.get(keepalive_key, null)
        if keepalive_value is RefCounted:
            keepalives.append(keepalive_value)
    var payload_estimate := _ecology_source_capture_value_graph_estimate_bytes(session)
    var queued: Variant = queue_value.call("_queue_tree_value_retirement",
        roots, keepalives)
    if bool(queued):
        _ecology_source_capture_session_stats["retiredPayloadEstimateBytes"] = int(
            _ecology_source_capture_session_stats.get("retiredPayloadEstimateBytes", 0)) \
            + payload_estimate
    return bool(queued)


func _completed_ecology_source_capture_pass_count() -> int:
    var count := 0
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if session_value is Dictionary and bool(session_value.get(
                "completedPassCached", false)):
            count += 1
    return count


func _retained_ecology_source_capture_idle_count() -> int:
    var count := 0
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if session_value is Dictionary and bool(session_value.get("retainedIdle", false)):
            count += 1
    return count


func _ecology_source_capture_retirement_pending_count() -> int:
    var count := 0
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if session_value is Dictionary and bool(session_value.get("retirementPending", false)):
            count += 1
    return count


func _ecology_source_capture_value_graph_estimate_bytes(session: Dictionary) -> int:
    var state_value: Variant = session.get("state", null)
    if not state_value is Dictionary:
        return 0
    var state: Dictionary = state_value
    var rows_value: Variant = state.get("sourceRows", [])
    var intents_value: Variant = state.get("actorIntents", [])
    if not rows_value is Array or not intents_value is Array:
        return MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES + 1
    var rows: Array = rows_value
    var intents: Array = intents_value
    # Structural allowance bounds non-geometry dictionaries and values. Mesh
    # CPU sizes come from admitted resource fingerprints; this is cache
    # accounting, not an exact serialized-size claim.
    var estimate := rows.size() * 2048 + intents.size() * 1024
    var capture_state_value: Variant = session.get("state", null)
    if capture_state_value is Dictionary:
        var capture_state: Dictionary = capture_state_value
        var candidates_value: Variant = capture_state.get("undergroundCandidates", [])
        if candidates_value is Array:
            estimate += candidates_value.size() * 512
        var detail_rows_value: Variant = capture_state.get("detailSourceRows", [])
        if detail_rows_value is Array:
            estimate += detail_rows_value.size() * 2048
        var detail_keys_value: Variant = capture_state.get("detailBatchKeys", [])
        if detail_keys_value is Array:
            estimate += detail_keys_value.size() * 64
        var detail_batches_value: Variant = capture_state.get("detailBatches", {})
        if detail_batches_value is Dictionary:
            for transforms_value: Variant in detail_batches_value.values():
                if transforms_value is Array:
                    estimate += transforms_value.size() * 64
        var active_attempt_value: Variant = capture_state.get("detailActiveAttempt", {})
        if active_attempt_value is Dictionary:
            estimate += active_attempt_value.size() * 128
        var floor_scan_value: Variant = capture_state.get("undergroundVolumeFloorScan", {})
        if floor_scan_value is Dictionary:
            estimate += floor_scan_value.size() * 128
    for row_value: Variant in rows:
        if not row_value is Dictionary:
            return MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES + 1
        var row: Dictionary = row_value
        var members_value: Variant = row.get("renderMembers", null)
        if members_value is Array:
            for member_value: Variant in members_value:
                if not member_value is Dictionary:
                    return MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES + 1
                estimate += maxi(0, int(member_value.get("meshCpuArrayBytes", 0)))
        else:
            estimate += maxi(0, int(row.get("meshCpuArrayBytes", 0)))
    return estimate


func _retained_ecology_source_capture_estimated_bytes() -> int:
    var total := 0
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if session_value is Dictionary and bool(session_value.get("retainedIdle", false)):
            total += _ecology_source_capture_value_graph_estimate_bytes(session_value)
    return total


func _ecology_source_capture_retirement_pending_estimated_bytes() -> int:
    var total := 0
    for session_value: Variant in _ecology_source_capture_sessions.values():
        if session_value is Dictionary and bool(session_value.get("retirementPending", false)):
            total += _ecology_source_capture_value_graph_estimate_bytes(session_value)
    return total


func _make_room_for_ecology_source_capture_payload(cache_identity: String,
        incoming_estimate: int) -> bool:
    if incoming_estimate < 0 \
            or incoming_estimate > MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES:
        return false
    var total := _retained_ecology_source_capture_estimated_bytes()
    var current_value: Variant = _ecology_source_capture_sessions.get(cache_identity, null)
    if current_value is Dictionary and bool(current_value.get("retainedIdle", false)):
        total = maxi(0, total - _ecology_source_capture_value_graph_estimate_bytes(
            current_value))
    if total + incoming_estimate <= MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES:
        return true
    var candidates: Array[String] = []
    for identity_value: Variant in _ecology_source_capture_sessions:
        var identity := String(identity_value)
        if identity == cache_identity:
            continue
        var session_value: Variant = _ecology_source_capture_sessions.get(identity, null)
        if session_value is Dictionary and bool(session_value.get("retainedIdle", false)) \
                and (session_value.get("subscriberLeaseTokens", []) as Array).is_empty():
            candidates.append(identity)
    candidates.sort_custom(func(a: String, b: String) -> bool:
        var a_session: Dictionary = _ecology_source_capture_sessions.get(a, {})
        var b_session: Dictionary = _ecology_source_capture_sessions.get(b, {})
        var a_time := int(a_session.get("lastAccessUsec", 0))
        var b_time := int(b_session.get("lastAccessUsec", 0))
        return a_time < b_time if a_time != b_time else a < b)
    for identity: String in candidates:
        var candidate: Dictionary = _ecology_source_capture_sessions.get(identity, {})
        var estimate := _ecology_source_capture_value_graph_estimate_bytes(candidate)
        if _drop_ecology_source_capture_session(identity, "completed_cache_eviction"):
            total = maxi(0, total - estimate)
            if total + incoming_estimate <= MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES:
                return true
    return total + incoming_estimate <= MAX_RETAINED_ECOLOGY_SOURCE_CAPTURE_ESTIMATED_BYTES


func _retain_completed_ecology_source_capture_pass(cache_identity: String,
        session: Dictionary) -> bool:
    if cache_identity.is_empty() or not _ecology_source_capture_sessions.has(cache_identity):
        return false
    var state_value: Variant = session.get("state", null)
    if not state_value is Dictionary:
        return false
    var state: Dictionary = state_value
    var completed_categories: Array = state.get("completedSourceCategories", [])
    for family: String in EcologyProducerDomainScript.REQUIRED_CATEGORIES:
        if family not in completed_categories:
            return false
    var requested_families: Array = state.get("requestedSourceFamilies", [])
    var published_families: Array = session.get("publishedSourceFamilies", [])
    for family_value: Variant in requested_families:
        if String(family_value) not in published_families:
            return false
    var estimated_bytes := _ecology_source_capture_value_graph_estimate_bytes(session)
    if not _make_room_for_ecology_source_capture_payload(cache_identity,
            estimated_bytes):
        _ecology_source_capture_session_stats["retainedPayloadBudgetRejects"] = int(
            _ecology_source_capture_session_stats.get("retainedPayloadBudgetRejects", 0)) + 1
        return false
    session["completedPassCached"] = true
    session["retainedIdle"] = true
    session["retirementPending"] = false
    session["lastAccessUsec"] = Time.get_ticks_usec()
    # Published family bundles own independent sealed rows. Once every admitted
    # receipt exists, no queue consumer needs this session's lease token list.
    session["subscriberLeaseTokens"] = []
    _ecology_source_capture_sessions[cache_identity] = session
    _ecology_source_capture_session_stats["completed"] = int(
        _ecology_source_capture_session_stats.get("completed", 0)) + 1
    return true


func _retain_idle_ecology_source_capture_pass(cache_identity: String,
        session: Dictionary) -> bool:
    if cache_identity.is_empty() or not _ecology_source_capture_sessions.has(cache_identity):
        return false
    if not (session.get("subscriberLeaseTokens", []) as Array).is_empty():
        return false
    var estimated_bytes := _ecology_source_capture_value_graph_estimate_bytes(session)
    if not _make_room_for_ecology_source_capture_payload(cache_identity,
            estimated_bytes):
        _ecology_source_capture_session_stats["retainedPayloadBudgetRejects"] = int(
            _ecology_source_capture_session_stats.get("retainedPayloadBudgetRejects", 0)) + 1
        return false
    session["retainedIdle"] = true
    session["retirementPending"] = false
    session["lastAccessUsec"] = Time.get_ticks_usec()
    _ecology_source_capture_sessions[cache_identity] = session
    return true


func reset_ecology_source_capture_sessions() -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_source_session_reset_requires_main_thread"}
    var removed_count := 0
    var pending_count := 0
    for identity_value: Variant in _ecology_source_capture_sessions.keys():
        if _drop_ecology_source_capture_session(String(identity_value), "reset"):
            removed_count += 1
        else:
            pending_count += 1
    _ecology_source_capture_session_stats["reset"] = int(
        _ecology_source_capture_session_stats.get("reset", 0)) + removed_count
    if pending_count > 0:
        return {"status":"pending", "reason":"ecology_source_session_retirement_backpressure",
            "removedSessionCount":removed_count, "pendingSessionCount":pending_count,
            "retryable":true}
    return {"status":"ready", "removedSessionCount":removed_count}


func _record_prop_capture_path(path: String, entry: String, outcome: String,
        stage: String, elapsed_usec: int) -> void:
    # Diagnostic-only, bounded per-path samples. The sprint fixture resets this
    # before movement; no path selection or readiness decision reads it.
    var paths: Dictionary = prop_capture_path_diagnostics.get("paths", {})
    var row: Dictionary = paths.get(path, {"calls": 0, "totalUsec": 0,
        "maxUsec": 0, "events": {}, "stages": {}, "samplesUsec": [],
        "samplesDropped": 0})
    row.calls = int(row.calls) + 1
    row.totalUsec = int(row.totalUsec) + maxi(0, elapsed_usec)
    row.maxUsec = maxi(int(row.maxUsec), elapsed_usec)
    var events: Dictionary = row.events
    for event: String in [entry, outcome]:
        if not event.is_empty(): events[event] = int(events.get(event, 0)) + 1
    var stages: Dictionary = row.stages
    if not stage.is_empty(): stages[stage] = int(stages.get(stage, 0)) + 1
    var samples: Array = row.samplesUsec
    if samples.size() < 256: samples.append(maxi(0, elapsed_usec))
    else: row.samplesDropped = int(row.samplesDropped) + 1
    paths[path] = row
    prop_capture_path_diagnostics.paths = paths

func generated_volume_exposure_cache_metadata(start_x: int, start_z: int) -> Dictionary:
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var revision := int(world_generation_system.call("terrain_volume_revision")) if world_generation_system != null and world_generation_system.has_method("terrain_volume_revision") else 0
    return {
        "chunk": chunk_key,
        "revision": revision,
        "seed": seed_text
    }

func cached_generated_surface_volume_exposure(start_x: int, start_z: int) -> Dictionary:
    var metadata := generated_volume_exposure_cache_metadata(start_x, start_z)
    var chunk_key: Vector2i = metadata.get("chunk", Vector2i.ZERO)
    if underground_chunk_exposure_cache.has(chunk_key):
        var cached_value = underground_chunk_exposure_cache[chunk_key]
        if cached_value is Dictionary:
            var cached: Dictionary = cached_value
            if int(cached.get("revision", -1)) == int(metadata.get("revision", -1)) and String(cached.get("seed", "")) == String(metadata.get("seed", "")):
                return {
                    "known": true,
                    "result": bool(cached.get("result", false))
                }
    return {
        "known": false,
        "result": false
    }

func cache_generated_surface_volume_exposure(start_x: int, start_z: int, result: bool) -> void:
    var metadata := generated_volume_exposure_cache_metadata(start_x, start_z)
    var chunk_key: Vector2i = metadata.get("chunk", Vector2i.ZERO)
    underground_chunk_exposure_cache[chunk_key] = {
        "revision": int(metadata.get("revision", 0)),
        "seed": String(metadata.get("seed", "")),
        "result": result
    }

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var monitor = runtime_perf_monitor
    var volume_scan_start: int = monitor.begin_section("chunk_volume_boundary_scan") if monitor != null else Time.get_ticks_usec()
    var has_excavation := chunk_has_excavation_overlap(start_x, start_z)
    var has_volume_edits := chunk_has_terrain_volume_edits(start_x, start_z)
    var generated_volume_required := chunk_needs_generated_underground_volume_mesh(start_x, start_z)
    var full_generated_volume_required := generated_volume_required and not has_volume_edits
    var local_volume_required := has_excavation or has_volume_edits
    var volume_required := local_volume_required or full_generated_volume_required
    if monitor != null:
        monitor.end_section("chunk_volume_boundary_scan", volume_scan_start)
    if not volume_required:
        var exterior_start_fast: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
        var exterior_mesh := build_two_sided_exterior_array_mesh(start_x, start_z)
        if monitor != null:
            monitor.end_section("chunk_exterior_surface_mesh", exterior_start_fast)
        return exterior_mesh
    var mesh := ArrayMesh.new()
    var exterior_start: int = monitor.begin_section("chunk_exterior_surface_mesh") if monitor != null else Time.get_ticks_usec()
    var volume_context := {}
    var exterior_arrays := empty_terrain_surface_arrays() if (full_generated_volume_required and not local_volume_required) or has_volume_edits else build_natural_exterior_arrays(start_x, start_z)
    if monitor != null:
        monitor.end_section("chunk_exterior_surface_mesh", exterior_start)
    var bounds := chunk_volume_y_bounds(start_x, start_z) if full_generated_volume_required or has_volume_edits else excavation_volume_y_bounds_for_chunk(start_x, start_z)
    var min_y := int(bounds.get("minY", floori((MIN_HEIGHT - CELL * 4.0) / CELL))) - 1
    var max_y := int(bounds.get("maxY", ceili((MAX_HEIGHT + CELL * 2.0) / CELL))) + 1
    var volume_arrays := {}
    var volume_start: int = monitor.begin_section("chunk_volume_mesh") if monitor != null else Time.get_ticks_usec()
    if full_generated_volume_required or has_volume_edits:
        volume_arrays = build_volume_iso_arrays(start_x, start_z, min_y, max_y, volume_context)
    else:
        volume_arrays = build_excavation_volume_iso_arrays(start_x, start_z, min_y, max_y, volume_context)
    if monitor != null:
        monitor.increment_counter("chunk_volume_columns", int(volume_arrays.get("columns", 0)))
        monitor.increment_counter("chunk_volume_cubes", int(volume_arrays.get("cubes", 0)))
        monitor.increment_counter("chunk_volume_faces", int(volume_arrays.get("faces", 0)))
        monitor.end_section("chunk_volume_mesh", volume_start)
    var combine_start: int = monitor.begin_section("chunk_combine_surface_arrays") if monitor != null else Time.get_ticks_usec()
    var exterior_vertices: PackedVector3Array = exterior_arrays.get("vertices", PackedVector3Array())
    var combined_arrays := volume_arrays if exterior_vertices.is_empty() else combine_terrain_surface_arrays(exterior_arrays, volume_arrays)
    if monitor != null:
        monitor.end_section("chunk_combine_surface_arrays", combine_start)
    add_terrain_array_surface(mesh, combined_arrays, terrain_material)
    mesh.set_meta("chunk_volume_faces", int(volume_arrays.get("faces", 0)))
    mesh.set_meta("chunk_volume_vertices", (volume_arrays.get("vertices", PackedVector3Array()) as PackedVector3Array).size())
    return mesh

func build_chunk_fluid_mesh(cx: int, cz: int) -> Mesh:
    var mesh := ArrayMesh.new()
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return mesh
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var has_excavation := chunk_has_excavation_overlap(start_x, start_z)
    var has_volume_edits := chunk_has_terrain_volume_edits(start_x, start_z)
    var generated_volume_required := chunk_needs_generated_underground_volume_mesh(start_x, start_z)
    var full_generated_volume_required := generated_volume_required and not has_volume_edits
    if not has_excavation and not full_generated_volume_required:
        return mesh
    var bounds := chunk_volume_y_bounds(start_x, start_z) if full_generated_volume_required else excavation_volume_y_bounds_for_chunk(start_x, start_z)
    var min_y := int(bounds.get("minY", floori((MIN_HEIGHT - CELL * 4.0) / CELL))) - 1
    var max_y := int(bounds.get("maxY", ceili((MAX_HEIGHT + CELL * 2.0) / CELL))) + 1
    var sample_cache := {}
    var volume_context := {}
    var step_cells := 1 if bool(get("force_underground_volume_fine_focus")) else maxi(2, mini(4, underground_volume_mesh_step_for_chunk(start_x, start_z)))
    var water_arrays := empty_terrain_surface_arrays()
    var lava_arrays := empty_terrain_surface_arrays()
    var water_faces := 0
    var lava_faces := 0
    for z in range(start_z, start_z + CHUNK_SIZE, step_cells):
        for x in range(start_x, start_x + CHUNK_SIZE, step_cells):
            for y in range(min_y, max_y + 1, step_cells):
                var cell := Vector3i(x, y, z)
                var sample := volume_cell_center_sample(cell, sample_cache, volume_context)
                var fluid_id := String(sample.get("fluid", ""))
                if fluid_id == "" or bool(sample.get("solid", false)):
                    continue
                if fluid_id == "lava":
                    lava_faces += append_fluid_cell_faces(lava_arrays, cell, step_cells, start_x, start_z, sample_cache, volume_context, fluid_id)
                else:
                    water_faces += append_fluid_cell_faces(water_arrays, cell, step_cells, start_x, start_z, sample_cache, volume_context, fluid_id)
    add_terrain_array_surface(mesh, water_arrays, materials.get("water", terrain_material) as Material)
    add_terrain_array_surface(mesh, lava_arrays, materials.get("lava", terrain_material) as Material)
    mesh.set_meta("chunk_fluid_faces", water_faces + lava_faces)
    mesh.set_meta("chunk_water_faces", water_faces)
    mesh.set_meta("chunk_lava_faces", lava_faces)
    var monitor = runtime_perf_monitor
    if monitor != null:
        monitor.increment_counter("chunk_fluid_faces", water_faces + lava_faces)
        monitor.increment_counter("chunk_water_faces", water_faces)
        monitor.increment_counter("chunk_lava_faces", lava_faces)
    return mesh

func append_fluid_cell_faces(
    arrays: Dictionary,
    cell: Vector3i,
    step_cells: int,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context: Dictionary,
    fluid_id: String
) -> int:
    var directions := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    var face_count := 0
    for direction: Vector3i in directions:
        var neighbor_cell := cell + direction * step_cells
        var neighbor_sample := volume_cell_center_sample(neighbor_cell, sample_cache, volume_context)
        if String(neighbor_sample.get("fluid", "")) == fluid_id and not bool(neighbor_sample.get("solid", false)):
            continue
        append_fluid_boundary_face(arrays, cell, direction, step_cells, origin_x, origin_z, fluid_id)
        face_count += 1
    return face_count

func append_fluid_boundary_face(
    arrays: Dictionary,
    cell: Vector3i,
    direction: Vector3i,
    step_cells: int,
    origin_x: int,
    origin_z: int,
    fluid_id: String
) -> void:
    var corners := fluid_boundary_face_corners(cell, direction, step_cells)
    var normal := Vector3(float(direction.x), float(direction.y), float(direction.z)).normalized()
    var color := fluid_vertex_color(fluid_id, corners[0], normal)
    var vertices: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = arrays.get("normals", PackedVector3Array())
    var colors: PackedColorArray = arrays.get("colors", PackedColorArray())
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[1], corners[2], normal, color, origin_x, origin_z)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[2], corners[3], normal, color, origin_x, origin_z)
    arrays["vertices"] = vertices
    arrays["normals"] = normals
    arrays["colors"] = colors

func fluid_boundary_face_corners(cell: Vector3i, direction: Vector3i, step_cells: int) -> Array[Vector3]:
    var step := maxi(1, step_cells)
    var x0 := float(cell.x) * CELL
    var x1 := float(cell.x + step) * CELL
    var y0 := float(cell.y) * CELL
    var y1 := float(cell.y + step) * CELL
    var z0 := float(cell.z) * CELL
    var z1 := float(cell.z + step) * CELL
    if direction == Vector3i(1, 0, 0):
        return [Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)]
    if direction == Vector3i(-1, 0, 0):
        return [Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1)]
    if direction == Vector3i(0, 1, 0):
        return [Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1)]
    if direction == Vector3i(0, -1, 0):
        return [Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0)]
    if direction == Vector3i(0, 0, 1):
        return [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)]
    return [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)]

func fluid_vertex_color(fluid_id: String, world: Vector3, normal: Vector3) -> Color:
    var shade := 0.88 + noise01(ridge_noise, world_to_cell(world.x) + 917, world_to_cell(world.z) - 613) * 0.10
    if normal.y < -0.35:
        shade *= 0.72
    elif absf(normal.y) < 0.35:
        shade *= 0.84
    if fluid_id == "lava":
        return Color(1.0, 0.34, 0.08, 0.92) * shade
    return Color(0.22, 0.58, 0.68, 0.62) * shade

func empty_terrain_surface_arrays() -> Dictionary:
    return {
        "vertices": PackedVector3Array(),
        "normals": PackedVector3Array(),
        "colors": PackedColorArray(),
        "indices": PackedInt32Array()
    }

func align_down_to_step(value: int, step: int) -> int:
    if step <= 1:
        return value
    return floori(float(value) / float(step)) * step

func align_up_to_step(value: int, step: int) -> int:
    if step <= 1:
        return value
    return ceili(float(value) / float(step)) * step

func chunk_compatible_volume_step(preferred_step: int) -> int:
    var preferred := maxi(1, preferred_step)
    for candidate in [preferred, 14, 7, 4, 2, 1]:
        var step := int(candidate)
        if step > 0 and step <= CHUNK_SIZE and CHUNK_SIZE % step == 0:
            return step
    return 1

func underground_volume_mesh_step_for_chunk(_start_x: int, _start_z: int) -> int:
    if chunk_has_terrain_volume_edits(_start_x, _start_z):
        return 1
    if chunk_has_town_surface_volume_edge(_start_x, _start_z):
        return chunk_compatible_volume_step(4)
    var preferred_step := 8
    if chunk_has_underground_focus_overlap(_start_x, _start_z):
        if bool(get("force_underground_volume_fine_focus")):
            preferred_step = UNDERGROUND_VOLUME_FINE_FOCUS_STEP_CELLS
        elif force_underground_volume_debug:
            preferred_step = UNDERGROUND_VOLUME_DEBUG_STEP_CELLS
        else:
            preferred_step = UNDERGROUND_VOLUME_FOCUS_STEP_CELLS
    return chunk_compatible_volume_step(preferred_step)

func underground_volume_focus_radius_cells() -> int:
    if bool(get("force_underground_volume_fine_focus")):
        return CHUNK_SIZE * 3
    if force_underground_volume_debug:
        return UNDERGROUND_VOLUME_DEBUG_RADIUS_CELLS
    return UNDERGROUND_VOLUME_FOCUS_RADIUS_CELLS

func build_natural_exterior_array_mesh(start_x: int, start_z: int) -> Mesh:
    var monitor = runtime_perf_monitor
    var border_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(border_size * border_size)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var plain_context := exterior_surface_context_is_plain(surface_context)
    var use_volume_surface_fast_path: bool = (
        plain_context
        and world_generation_system != null
        and world_generation_system.has_method("surface_y_for_cell")
    )
    var height_start: int = monitor.begin_section("chunk_exterior_height_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * border_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            if use_volume_surface_fast_path:
                surface_cache[row_index + vx + 1] = float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
            else:
                surface_cache[row_index + vx + 1] = natural_exterior_surface_y_cell(cell_x, cell_z) if plain_context else exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
    if monitor != null:
        monitor.end_section("chunk_exterior_height_grid", height_start)

    var grid_size := CHUNK_SIZE + 1
    var vertex_count := grid_size * grid_size
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    colors.resize(vertex_count)
    var vertex_start: int = monitor.begin_section("chunk_exterior_vertex_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(grid_size):
        var vertex_row := vz * grid_size
        var border_row := (vz + 1) * border_size
        for vx in range(grid_size):
            var vertex_index := vertex_row + vx
            var border_index := border_row + vx + 1
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            vertices[vertex_index] = Vector3(float(vx) * CELL, float(surface_cache[border_index]), float(vz) * CELL)
            normals[vertex_index] = exterior_surface_normal_grid(surface_cache, border_index, border_size)
            var color: Color = natural_exterior_surface_color_for_cell(cell_x, cell_z, float(surface_cache[border_index])) if plain_context else exterior_surface_color_for_cell_from_context(cell_x, cell_z, float(surface_cache[border_index]), surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    if monitor != null:
        monitor.end_section("chunk_exterior_vertex_grid", vertex_start)

    var index_start: int = monitor.begin_section("chunk_exterior_index_grid") if monitor != null else Time.get_ticks_usec()
    var indices := full_exterior_indices()
    if monitor != null:
        monitor.end_section("chunk_exterior_index_grid", index_start)

    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var commit_start: int = monitor.begin_section("chunk_mesh_commit") if monitor != null else Time.get_ticks_usec()
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, terrain_material)
    if monitor != null:
        monitor.end_section("chunk_mesh_commit", commit_start)
    return mesh

func build_two_sided_exterior_array_mesh(start_x: int, start_z: int) -> Mesh:
    var arrays := build_natural_exterior_arrays(start_x, start_z)
    var vertices: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = arrays.get("normals", PackedVector3Array())
    var colors: PackedColorArray = arrays.get("colors", PackedColorArray())
    var indices: PackedInt32Array = arrays.get("indices", PackedInt32Array())
    streaming_append_reversed_indexed_surface(vertices, normals, colors, indices)
    arrays["vertices"] = vertices
    arrays["normals"] = normals
    arrays["colors"] = colors
    arrays["indices"] = indices
    var mesh := ArrayMesh.new()
    add_terrain_array_surface(mesh, arrays, terrain_material)
    mesh.set_meta("terrainMeshingBackend", "two_sided_exterior")
    mesh.set_meta("terrainVisualUndersideClosed", true)
    return mesh

func build_natural_exterior_arrays(start_x: int, start_z: int) -> Dictionary:
    var monitor = runtime_perf_monitor
    var border_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(border_size * border_size)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var plain_context := exterior_surface_context_is_plain(surface_context)
    var use_volume_surface_fast_path: bool = (
        plain_context
        and world_generation_system != null
        and world_generation_system.has_method("surface_y_for_cell")
    )
    var height_start: int = monitor.begin_section("chunk_exterior_height_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * border_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            if use_volume_surface_fast_path:
                surface_cache[row_index + vx + 1] = float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
            else:
                surface_cache[row_index + vx + 1] = natural_exterior_surface_y_cell(cell_x, cell_z) if plain_context else exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
    if monitor != null:
        monitor.end_section("chunk_exterior_height_grid", height_start)

    var grid_size := CHUNK_SIZE + 1
    var vertex_count := grid_size * grid_size
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    colors.resize(vertex_count)
    var vertex_start: int = monitor.begin_section("chunk_exterior_vertex_grid") if monitor != null else Time.get_ticks_usec()
    for vz in range(grid_size):
        var vertex_row := vz * grid_size
        var border_row := (vz + 1) * border_size
        for vx in range(grid_size):
            var vertex_index := vertex_row + vx
            var border_index := border_row + vx + 1
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            vertices[vertex_index] = Vector3(float(vx) * CELL, float(surface_cache[border_index]), float(vz) * CELL)
            normals[vertex_index] = exterior_surface_normal_grid(surface_cache, border_index, border_size)
            var color: Color = natural_exterior_surface_color_for_cell(cell_x, cell_z, float(surface_cache[border_index])) if plain_context else exterior_surface_color_for_cell_from_context(cell_x, cell_z, float(surface_cache[border_index]), surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    if monitor != null:
        monitor.end_section("chunk_exterior_vertex_grid", vertex_start)

    var indices := PackedInt32Array()
    var index_start: int = monitor.begin_section("chunk_exterior_index_grid") if monitor != null else Time.get_ticks_usec()
    indices = exterior_indices_for_surface(
        start_x,
        start_z,
        surface_cache,
        border_size,
        active_volume_excavation_brushes(),
        edited_volume_boundary_cells_for_chunk(start_x, start_z, -999999, 999999)
    )
    if monitor != null:
        monitor.end_section("chunk_exterior_index_grid", index_start)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func build_natural_exterior_arrays_lod(start_x: int, start_z: int, step_cells: int) -> Dictionary:
    var step := maxi(1, step_cells)
    var local_xs: Array[int] = []
    var local_zs: Array[int] = []
    var local_x := 0
    while local_x < CHUNK_SIZE:
        local_xs.append(local_x)
        local_x += step
    if local_xs.is_empty() or local_xs[local_xs.size() - 1] != CHUNK_SIZE:
        local_xs.append(CHUNK_SIZE)
    var local_z := 0
    while local_z < CHUNK_SIZE:
        local_zs.append(local_z)
        local_z += step
    if local_zs.is_empty() or local_zs[local_zs.size() - 1] != CHUNK_SIZE:
        local_zs.append(CHUNK_SIZE)
    var surface_context := exterior_surface_chunk_context(start_x, start_z)
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var vertex_count := local_xs.size() * local_zs.size()
    vertices.resize(vertex_count)
    normals.resize(vertex_count)
    colors.resize(vertex_count)
    for z_index in range(local_zs.size()):
        var vz: int = local_zs[z_index]
        for x_index in range(local_xs.size()):
            var vx: int = local_xs[x_index]
            var vertex_index := z_index * local_xs.size() + x_index
            var cell_x := start_x + vx
            var cell_z := start_z + vz
            var surface_y := exterior_surface_y_cell_from_context(cell_x, cell_z, surface_context)
            vertices[vertex_index] = Vector3(float(vx) * CELL, surface_y, float(vz) * CELL)
            normals[vertex_index] = exterior_surface_normal_lod(cell_x, cell_z, surface_context, step)
            var color: Color = exterior_surface_color_for_cell_from_context(cell_x, cell_z, surface_y, surface_context)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            colors[vertex_index] = color * shade
    var indices := PackedInt32Array()
    for z_index in range(local_zs.size() - 1):
        var row := z_index * local_xs.size()
        var next_row := (z_index + 1) * local_xs.size()
        for x_index in range(local_xs.size() - 1):
            var i00 := row + x_index
            var i10 := i00 + 1
            var i01 := next_row + x_index
            var i11 := i01 + 1
            indices.append(i00)
            indices.append(i01)
            indices.append(i10)
            indices.append(i10)
            indices.append(i01)
            indices.append(i11)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func exterior_surface_normal_lod(cell_x: int, cell_z: int, context: Dictionary, step_cells: int) -> Vector3:
    var step := maxi(1, step_cells)
    var left := exterior_surface_y_cell_from_context(cell_x - step, cell_z, context)
    var right := exterior_surface_y_cell_from_context(cell_x + step, cell_z, context)
    var back := exterior_surface_y_cell_from_context(cell_x, cell_z - step, context)
    var forward := exterior_surface_y_cell_from_context(cell_x, cell_z + step, context)
    return Vector3(left - right, CELL * float(step) * 2.0, back - forward).normalized()

func build_volume_iso_arrays(start_x: int, start_z: int, min_y: int, max_y: int, volume_context: Dictionary) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var sample_cache := {}
    var volume_columns := 0
    var volume_cubes := 0
    var iso_triangles := 0
    var step_cells := underground_volume_mesh_step_for_chunk(start_x, start_z)
    for z in range(start_z, start_z + CHUNK_SIZE, step_cells):
        for x in range(start_x, start_x + CHUNK_SIZE, step_cells):
            if not volume_block_may_touch_underground_boundary(x, z, step_cells, min_y, max_y, sample_cache, volume_context):
                continue
            var fine_result := append_volume_iso_block_arrays(
                vertices,
                normals,
                colors,
                x,
                z,
                step_cells,
                start_x,
                start_z,
                min_y,
                max_y,
                volume_context,
                sample_cache
            )
            volume_columns += int(fine_result.get("columns", 0))
            volume_cubes += int(fine_result.get("cubes", 0))
            iso_triangles += int(fine_result.get("faces", 0))
    var boundary_faces := append_excavation_boundary_arrays(vertices, normals, colors, start_x, start_z, min_y, max_y, volume_context)
    iso_triangles += boundary_faces
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "columns": volume_columns,
        "cubes": volume_cubes,
        "faces": iso_triangles
    }

func build_excavation_volume_iso_arrays(start_x: int, start_z: int, min_y: int, max_y: int, volume_context: Dictionary) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var boundary_faces := append_excavation_boundary_arrays(vertices, normals, colors, start_x, start_z, min_y, max_y, volume_context)
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "columns": 0,
        "cubes": 0,
        "faces": boundary_faces
    }

func append_excavation_boundary_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    start_x: int,
    start_z: int,
    min_y: int,
    max_y: int,
    volume_context: Dictionary
) -> int:
    var brushes := active_volume_excavation_brushes()
    var iso_triangles := 0
    var iso_sample_cache := {}
    var chunk_min_x := start_x - 1
    var chunk_max_x := start_x + CHUNK_SIZE + 1
    var chunk_min_z := start_z - 1
    var chunk_max_z := start_z + CHUNK_SIZE + 1
    var visited := {}
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        var center_cell := Vector3i(world_to_cell(center.x), world_to_cell(center.y), world_to_cell(center.z))
        var cell_radius := ceili(radius / CELL) + 2
        for z in range(center_cell.z - cell_radius, center_cell.z + cell_radius + 1):
            if z < chunk_min_z or z > chunk_max_z:
                continue
            for x in range(center_cell.x - cell_radius, center_cell.x + cell_radius + 1):
                if x < chunk_min_x or x > chunk_max_x:
                    continue
                for y in range(maxi(min_y, center_cell.y - cell_radius), mini(max_y, center_cell.y + cell_radius) + 1):
                    var cell := Vector3i(x, y, z)
                    if visited.has(cell):
                        continue
                    var cube_center := Vector3((float(x) + 0.5) * CELL, (float(y) + 0.5) * CELL, (float(z) + 0.5) * CELL)
                    if center.distance_to(cube_center) > radius + CELL * 1.65:
                        continue
                    visited[cell] = true
                    var before_vertices := vertices.size()
                    extract_volume_iso_cube_arrays(
                        vertices,
                        normals,
                        colors,
                        cell,
                        start_x,
                        start_z,
                        iso_sample_cache,
                        volume_context,
                        1
                    )
                    iso_triangles += int((vertices.size() - before_vertices) / 3)
    for edited_cell in edited_volume_boundary_cells_for_chunk(start_x, start_z, min_y, max_y):
        for dz in range(-1, 2):
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    var edited_cube_cell := edited_cell + Vector3i(dx, dy, dz)
                    if edited_cube_cell.x < chunk_min_x or edited_cube_cell.x > chunk_max_x:
                        continue
                    if edited_cube_cell.z < chunk_min_z or edited_cube_cell.z > chunk_max_z:
                        continue
                    if edited_cube_cell.y < min_y or edited_cube_cell.y > max_y:
                        continue
                    if visited.has(edited_cube_cell):
                        continue
                    visited[edited_cube_cell] = true
                    var edited_before_vertices := vertices.size()
                    extract_volume_iso_cube_arrays(
                        vertices,
                        normals,
                        colors,
                        edited_cube_cell,
                        start_x,
                        start_z,
                        iso_sample_cache,
                        volume_context,
                        1
                    )
                    iso_triangles += int((vertices.size() - edited_before_vertices) / 3)
    return iso_triangles

func append_volume_iso_block_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    x: int,
    z: int,
    step_cells: int,
    start_x: int,
    start_z: int,
    min_y: int,
    max_y: int,
    volume_context: Dictionary,
    sample_cache: Dictionary
) -> Dictionary:
    var cell_min_y := align_down_to_step(min_y, step_cells)
    var cell_max_y := align_up_to_step(max_y, step_cells)
    if cell_max_y <= cell_min_y:
        return {
            "columns": 0,
            "cubes": 0,
            "faces": 0
        }
    var volume_cubes := 0
    var iso_triangles := 0
    for y in range(cell_min_y, cell_max_y, step_cells):
        volume_cubes += 1
        var before_vertices := vertices.size()
        extract_volume_iso_cube_arrays(
            vertices,
            normals,
            colors,
            Vector3i(x, y, z),
            start_x,
            start_z,
            sample_cache,
            volume_context,
            step_cells
        )
        iso_triangles += int((vertices.size() - before_vertices) / 3)
    return {
        "columns": 1,
        "cubes": volume_cubes,
        "faces": iso_triangles
    }

func volume_block_may_touch_underground_boundary(cell_x: int, cell_z: int, step_cells: int, min_y: int, max_y: int, sample_cache: Dictionary, volume_context := {}) -> bool:
    var step := maxi(1, step_cells)
    for y in range(min_y, max_y, step):
        if volume_cube_has_density_boundary(Vector3i(cell_x, y, cell_z), step, sample_cache, volume_context):
            return true
    return false

func volume_cube_has_density_boundary(origin_cell: Vector3i, step_cells: int, sample_cache: Dictionary, volume_context := {}) -> bool:
    var solid_count := 0
    var surface_ys := PackedFloat32Array()
    var densities := PackedFloat32Array()
    var world_positions: Array[Vector3] = []
    surface_ys.resize(8)
    densities.resize(8)
    world_positions.resize(8)
    for index in range(8):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        var grid_cell := origin_cell + offset * step_cells
        var sample := volume_grid_sample_numeric(grid_cell, sample_cache, volume_context)
        var density := sample.x
        densities[index] = density
        surface_ys[index] = sample.z
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        if density > 0.0:
            solid_count += 1
    if solid_count <= 0 or solid_count >= 8:
        return false
    for index in range(8):
        if densities[index] <= 0.0 and world_positions[index].y < surface_ys[index] - CELL * 0.35:
            return true
    return false

func combine_terrain_surface_arrays(exterior_arrays: Dictionary, volume_arrays: Dictionary) -> Dictionary:
    var exterior_vertices: PackedVector3Array = exterior_arrays.get("vertices", PackedVector3Array())
    var exterior_normals: PackedVector3Array = exterior_arrays.get("normals", PackedVector3Array())
    var exterior_colors: PackedColorArray = exterior_arrays.get("colors", PackedColorArray())
    var exterior_indices: PackedInt32Array = exterior_arrays.get("indices", PackedInt32Array())
    var vertices := PackedVector3Array(exterior_vertices)
    var normals := PackedVector3Array(exterior_normals)
    var colors := PackedColorArray(exterior_colors)
    var indices := PackedInt32Array(exterior_indices)
    if indices.is_empty() and not exterior_vertices.is_empty():
        indices.resize(exterior_vertices.size())
        for i in range(exterior_vertices.size()):
            indices[i] = i
    if volume_arrays.is_empty():
        return {
            "vertices": vertices,
            "normals": normals,
            "colors": colors,
            "indices": indices
        }
    var volume_vertices: PackedVector3Array = volume_arrays.get("vertices", PackedVector3Array())
    if volume_vertices.is_empty():
        return {
            "vertices": vertices,
            "normals": normals,
            "colors": colors,
            "indices": indices
        }
    var volume_normals: PackedVector3Array = volume_arrays.get("normals", PackedVector3Array())
    var volume_colors: PackedColorArray = volume_arrays.get("colors", PackedColorArray())
    var volume_offset := vertices.size()
    vertices.append_array(volume_vertices)
    if volume_normals.size() == volume_vertices.size():
        normals.append_array(volume_normals)
    else:
        for i in range(volume_vertices.size()):
            normals.append(Vector3.UP)
    if volume_colors.size() == volume_vertices.size():
        colors.append_array(volume_colors)
    else:
        for i in range(volume_vertices.size()):
            colors.append(Color(0.36, 0.38, 0.35))
    var volume_indices: PackedInt32Array = volume_arrays.get("indices", PackedInt32Array())
    if volume_indices.is_empty():
        for i in range(volume_vertices.size()):
            indices.append(volume_offset + i)
    else:
        for index in volume_indices:
            indices.append(volume_offset + int(index))
    return {
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices
    }

func full_exterior_indices() -> PackedInt32Array:
    if not full_exterior_indices_cache.is_empty():
        return PackedInt32Array(full_exterior_indices_cache)
    var grid_size := CHUNK_SIZE + 1
    full_exterior_indices_cache.resize(CHUNK_SIZE * CHUNK_SIZE * 6)
    var write_index := 0
    for z in range(CHUNK_SIZE):
        var row := z * grid_size
        var next_row := (z + 1) * grid_size
        for x in range(CHUNK_SIZE):
            var i00 := row + x
            var i10 := i00 + 1
            var i01 := next_row + x
            var i11 := i01 + 1
            full_exterior_indices_cache[write_index] = i00
            full_exterior_indices_cache[write_index + 1] = i01
            full_exterior_indices_cache[write_index + 2] = i10
            full_exterior_indices_cache[write_index + 3] = i10
            full_exterior_indices_cache[write_index + 4] = i01
            full_exterior_indices_cache[write_index + 5] = i11
            write_index += 6
    return PackedInt32Array(full_exterior_indices_cache)

func exterior_indices_for_surface(start_x: int, start_z: int, surface_cache: PackedFloat32Array, border_size: int, brushes: Array, edited_cells: Array[Vector3i] = []) -> PackedInt32Array:
    if brushes.is_empty() and edited_cells.is_empty():
        return full_exterior_indices()
    var grid_size := CHUNK_SIZE + 1
    var indices := PackedInt32Array()
    for z in range(CHUNK_SIZE):
        var row := z * grid_size
        var next_row := (z + 1) * grid_size
        for x in range(CHUNK_SIZE):
            if exterior_surface_quad_cut_by_excavation(start_x, start_z, x, z, surface_cache, border_size, brushes, edited_cells):
                continue
            var i00 := row + x
            var i10 := i00 + 1
            var i01 := next_row + x
            var i11 := i01 + 1
            indices.append(i00)
            indices.append(i01)
            indices.append(i10)
            indices.append(i10)
            indices.append(i01)
            indices.append(i11)
    return indices

func exterior_surface_quad_cut_by_excavation(start_x: int, start_z: int, local_x: int, local_z: int, surface_cache: PackedFloat32Array, border_size: int, brushes: Array, edited_cells: Array[Vector3i] = []) -> bool:
    var cell_x := start_x + local_x
    var cell_z := start_z + local_z
    var center_x := (float(cell_x) + 0.5) * CELL
    var center_z := (float(cell_z) + 0.5) * CELL
    var surface_y := exterior_surface_quad_average_y(surface_cache, local_x, local_z, border_size)
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var brush_center: Vector3 = brush.get("center", Vector3.ZERO)
        var brush_radius := float(brush.get("radius", 0.0))
        if brush_radius <= 0.0:
            continue
        var horizontal_distance := Vector2(brush_center.x - center_x, brush_center.z - center_z).length()
        if horizontal_distance > brush_radius + CELL * 0.35:
            continue
        if absf(brush_center.y - surface_y) > brush_radius + CELL * 0.95:
            continue
        return true
    if exterior_surface_quad_has_surface_deformation(center_x, center_z, surface_y):
        return false
    if exterior_surface_quad_has_volume_surface_projection_edit(start_x, start_z, local_x, local_z):
        return false
    for edited_cell in edited_cells:
        var edit_center_x := (float(edited_cell.x) + 0.5) * CELL
        var edit_center_z := (float(edited_cell.z) + 0.5) * CELL
        if Vector2(edit_center_x - center_x, edit_center_z - center_z).length() > CELL * 1.85:
            continue
        var edit_center_y := (float(edited_cell.y) + 0.5) * CELL
        if absf(edit_center_y - surface_y) > CELL * 2.75:
            continue
        return true
    return false

func exterior_surface_quad_has_volume_surface_projection_edit(start_x: int, start_z: int, local_x: int, local_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_column_has_surface_projection_affecting_edits"):
        return false
    for dz in range(2):
        for dx in range(2):
            var column_cell := Vector3i(start_x + local_x + dx, 0, start_z + local_z + dz)
            if bool(world_generation_system.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell)):
                return true
    return false

func exterior_surface_quad_has_surface_deformation(center_x: float, center_z: float, surface_y: float) -> bool:
    if world_generation_system == null:
        return false
    var brush_values = world_generation_system.get("excavation_brushes")
    if not (brush_values is Array):
        return false
    for brush_value in brush_values:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        if not excavation_brush_is_surface_deformation(brush):
            continue
        var brush_center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("deformRadius", brush.get("radius", 0.0)))
        if radius <= 0.0:
            continue
        if Vector2(brush_center.x - center_x, brush_center.z - center_z).length() > radius + CELL * 0.35:
            continue
        if absf(float(brush.get("surfaceY", brush_center.y)) - surface_y) > radius + CELL:
            continue
        return true
    return false

func exterior_surface_quad_average_y(surface_cache: PackedFloat32Array, local_x: int, local_z: int, border_size: int) -> float:
    var i00 := (local_z + 1) * border_size + local_x + 1
    var i10 := i00 + 1
    var i01 := i00 + border_size
    var i11 := i01 + 1
    return (float(surface_cache[i00]) + float(surface_cache[i10]) + float(surface_cache[i01]) + float(surface_cache[i11])) * 0.25

func append_density_boundary_faces_for_cell(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    cell: Vector3i,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context: Dictionary
) -> int:
    var air_sample := volume_cell_center_sample(cell, sample_cache, volume_context)
    if not volume_sample_is_subtracted_air(air_sample):
        return 0
    var face_count := 0
    var directions := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for direction in directions:
        var neighbor_cell: Vector3i = cell + direction
        var solid_sample := volume_cell_center_sample(neighbor_cell, sample_cache, volume_context)
        if float(solid_sample.get("density", 0.0)) < 0.0:
            continue
        append_density_boundary_face(vertices, normals, colors, cell, direction, origin_x, origin_z, air_sample, solid_sample, volume_context)
        face_count += 1
    return face_count

func volume_cell_center_sample(cell: Vector3i, sample_cache: Dictionary, volume_context: Dictionary) -> Dictionary:
    if sample_cache.has(cell):
        return sample_cache[cell]
    var position := Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)
    var sample := volume_sample_from_context(position, cell, volume_context) if not volume_context.is_empty() else volume_sample_world(position)
    sample_cache[cell] = sample
    return sample

func volume_sample_is_subtracted_air(sample: Dictionary) -> bool:
    if float(sample.get("density", 0.0)) >= 0.0:
        return false
    if String(sample.get("biome", "")) == "underground_air":
        return true
    var position: Vector3 = sample.get("position", Vector3.ZERO)
    var surface_y := float(sample.get("surfaceY", position.y))
    return position.y < surface_y - CELL * 0.20

func append_density_boundary_face(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    cell: Vector3i,
    direction: Vector3i,
    origin_x: int,
    origin_z: int,
    air_sample: Dictionary,
    solid_sample: Dictionary,
    volume_context: Dictionary
) -> void:
    var corners := density_boundary_face_corners(cell, direction)
    var normal := Vector3(-float(direction.x), -float(direction.y), -float(direction.z)).normalized()
    var color := volume_boundary_face_color(corners[0], air_sample, solid_sample, normal, volume_context)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[1], corners[2], normal, color, origin_x, origin_z)
    append_density_boundary_triangle(vertices, normals, colors, corners[0], corners[2], corners[3], normal, color, origin_x, origin_z)

func density_boundary_face_corners(cell: Vector3i, direction: Vector3i) -> Array[Vector3]:
    var x0 := float(cell.x) * CELL
    var x1 := float(cell.x + 1) * CELL
    var y0 := float(cell.y) * CELL
    var y1 := float(cell.y + 1) * CELL
    var z0 := float(cell.z) * CELL
    var z1 := float(cell.z + 1) * CELL
    if direction == Vector3i(1, 0, 0):
        return [Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1)]
    if direction == Vector3i(-1, 0, 0):
        return [Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0)]
    if direction == Vector3i(0, 1, 0):
        return [Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0)]
    if direction == Vector3i(0, -1, 0):
        return [Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1)]
    if direction == Vector3i(0, 0, 1):
        return [Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)]
    return [Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)]

func append_density_boundary_triangle(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a_world: Vector3,
    b_world: Vector3,
    c_world: Vector3,
    normal: Vector3,
    color: Color,
    origin_x: int,
    origin_z: int
) -> void:
    var a_local := Vector3(a_world.x - float(origin_x) * CELL, a_world.y, a_world.z - float(origin_z) * CELL)
    var b_local := Vector3(b_world.x - float(origin_x) * CELL, b_world.y, b_world.z - float(origin_z) * CELL)
    var c_local := Vector3(c_world.x - float(origin_x) * CELL, c_world.y, c_world.z - float(origin_z) * CELL)
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if cross.normalized().dot(normal) < 0.0:
        var swap := b_local
        b_local = c_local
        c_local = swap
    vertices.append(a_local)
    vertices.append(b_local)
    vertices.append(c_local)
    normals.append(normal)
    normals.append(normal)
    normals.append(normal)
    colors.append(color)
    colors.append(color)
    colors.append(color)

func volume_boundary_face_color(world: Vector3, air_sample: Dictionary, solid_sample: Dictionary, normal: Vector3, volume_context: Dictionary) -> Color:
    var shade := volume_iso_shade(world)
    if String(air_sample.get("biome", "")) == "underground_air":
        shade *= underground_wall_visual_shade(world)
        var underground_material := String(solid_sample.get("material", "stone"))
        var underground_biome := String(solid_sample.get("biome", "underground"))
        return volume_material_surface_color(underground_material, underground_biome, normal, shade, true)
    var solid_cell: Vector3i = solid_sample.get("cell", Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z)))
    var surface_y := float(solid_sample.get("surfaceY", volume_context_surface_y_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(Vector3i(solid_cell.x, 0, solid_cell.z))))
    var density := float(solid_sample.get("density", surface_y - world.y))
    var biome := volume_context_surface_biome_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(Vector3i(solid_cell.x, 0, solid_cell.z))
    var material_id := volume_material_from_components(world, solid_cell, density, surface_y, biome)
    return volume_material_surface_color(material_id, biome, normal, shade, false)

func volume_material_surface_color(material_id: String, biome: String, normal: Vector3, shade: float, underground: bool) -> Color:
    if underground:
        if normal.y < -0.35:
            return Color(0.045, 0.047, 0.045) * shade
        if normal.y > 0.35:
            return Color(0.120, 0.125, 0.112) * shade
        if material_id == "copperOre":
            return Color(0.34, 0.20, 0.13) * shade
        if material_id == "ironOre":
            return Color(0.30, 0.30, 0.27) * shade
        if material_id == "bedrock":
            return Color(0.070, 0.075, 0.075) * shade
        if material_id == "deepStone":
            return Color(0.130, 0.145, 0.140) * shade
        if material_id == "sand":
            return Color(0.135, 0.120, 0.085) * shade
        if material_id == "dirt":
            return Color(0.100, 0.080, 0.060) * shade
        return Color(0.125, 0.135, 0.125) * shade
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
        return BIOME_COLORS.get(biome, BIOME_COLORS["plains"]) * shade
    match material_id:
        "sand":
            return Color(0.76, 0.67, 0.42) * shade
        "mud":
            return Color(0.28, 0.39, 0.22) * shade
        "snow":
            return Color(0.77, 0.82, 0.82) * shade
        "dirt":
            return Color(0.43, 0.27, 0.15) * shade
        "bedrock":
            return Color(0.10, 0.11, 0.11) * shade
        "deepStone":
            return Color(0.22, 0.23, 0.21) * shade
        "copperOre":
            return Color(0.48, 0.30, 0.20) * shade
        "ironOre":
            return Color(0.38, 0.35, 0.31) * shade
        _:
            return Color(0.34, 0.35, 0.31) * shade

func add_terrain_array_surface(mesh: ArrayMesh, surface_data: Dictionary, material: Material = null) -> void:
    var vertices: PackedVector3Array = surface_data.get("vertices", PackedVector3Array())
    if vertices.is_empty():
        return
    var monitor = runtime_perf_monitor
    var pack_start: int = monitor.begin_section("chunk_surface_array_pack") if monitor != null else Time.get_ticks_usec()
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = surface_data.get("normals", PackedVector3Array())
    arrays[Mesh.ARRAY_COLOR] = surface_data.get("colors", PackedColorArray())
    var indices: PackedInt32Array = surface_data.get("indices", PackedInt32Array())
    if not indices.is_empty():
        arrays[Mesh.ARRAY_INDEX] = indices
    if monitor != null:
        monitor.end_section("chunk_surface_array_pack", pack_start)
    var commit_start: int = monitor.begin_section("chunk_mesh_commit") if monitor != null else Time.get_ticks_usec()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(mesh.get_surface_count() - 1, material if material != null else terrain_material)
    if monitor != null:
        monitor.end_section("chunk_mesh_commit", commit_start)

func add_natural_exterior_surface(st: SurfaceTool, start_x: int, start_z: int) -> void:
    var grid_size := CHUNK_SIZE + 3
    var surface_cache := PackedFloat32Array()
    surface_cache.resize(grid_size * grid_size)
    var color_cache: Array[Color] = []
    color_cache.resize(grid_size * grid_size)
    var normal_cache: Array[Vector3] = []
    normal_cache.resize(grid_size * grid_size)
    for vz in range(-1, CHUNK_SIZE + 2):
        var row_index := (vz + 1) * grid_size
        for vx in range(-1, CHUNK_SIZE + 2):
            var cell_x: int = start_x + vx
            var cell_z: int = start_z + vz
            var cache_index := row_index + vx + 1
            surface_cache[cache_index] = exterior_surface_y_cell(cell_x, cell_z)
            if vx < 0 or vx > CHUNK_SIZE or vz < 0 or vz > CHUNK_SIZE:
                continue
            var color: Color = exterior_surface_color_for_cell(cell_x, cell_z)
            var shade := 0.88 + noise01(ridge_noise, cell_x + 400, cell_z - 200) * 0.18
            color_cache[cache_index] = color * shade
    for vz in range(CHUNK_SIZE + 1):
        var row_index := (vz + 1) * grid_size
        for vx in range(CHUNK_SIZE + 1):
            var cache_index := row_index + vx + 1
            normal_cache[cache_index] = exterior_surface_normal_grid(surface_cache, cache_index, grid_size)
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            var gx: int = start_x + x
            var gz: int = start_z + z
            var p00 := exterior_surface_vertex_grid(surface_cache, x, z, grid_size)
            var p10 := exterior_surface_vertex_grid(surface_cache, x + 1, z, grid_size)
            var p01 := exterior_surface_vertex_grid(surface_cache, x, z + 1, grid_size)
            var p11 := exterior_surface_vertex_grid(surface_cache, x + 1, z + 1, grid_size)
            add_exterior_surface_triangle_grid(st, p00, p01, p10, color_cache, normal_cache, x, z, x, z + 1, x + 1, z, grid_size)
            add_exterior_surface_triangle_grid(st, p10, p01, p11, color_cache, normal_cache, x + 1, z, x, z + 1, x + 1, z + 1, grid_size)

func exterior_surface_vertex_grid(surface_cache: PackedFloat32Array, vx: int, vz: int, grid_size: int) -> Vector3:
    var cache_index := (vz + 1) * grid_size + vx + 1
    return Vector3(float(vx) * CELL, float(surface_cache[cache_index]), float(vz) * CELL)

func exterior_surface_normal_grid(surface_cache: PackedFloat32Array, cache_index: int, grid_size: int) -> Vector3:
    var left := float(surface_cache[cache_index - 1])
    var right := float(surface_cache[cache_index + 1])
    var back := float(surface_cache[cache_index - grid_size])
    var forward := float(surface_cache[cache_index + grid_size])
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func add_exterior_surface_vertex_grid(st: SurfaceTool, point: Vector3, color_cache: Array[Color], normal_cache: Array[Vector3], vx: int, vz: int, grid_size: int) -> void:
    var cache_index := (vz + 1) * grid_size + vx + 1
    st.set_normal(normal_cache[cache_index])
    st.set_color(color_cache[cache_index])
    st.add_vertex(point)

func add_exterior_surface_triangle_grid(
    st: SurfaceTool,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    color_cache: Array[Color],
    normal_cache: Array[Vector3],
    cell_ax: int,
    cell_az: int,
    cell_bx: int,
    cell_bz: int,
    cell_cx: int,
    cell_cz: int,
    grid_size: int
) -> void:
    add_exterior_surface_vertex_grid(st, a, color_cache, normal_cache, cell_ax, cell_az, grid_size)
    add_exterior_surface_vertex_grid(st, b, color_cache, normal_cache, cell_bx, cell_bz, grid_size)
    add_exterior_surface_vertex_grid(st, c, color_cache, normal_cache, cell_cx, cell_cz, grid_size)

func exterior_surface_vertex_cached(surface_cache: Dictionary, cell_x: int, cell_z: int, origin_cell_x: int, origin_cell_z: int) -> Vector3:
    var key := Vector2i(cell_x, cell_z)
    var y := float(surface_cache[key]) if surface_cache.has(key) else exterior_surface_y_cell(cell_x, cell_z)
    return Vector3((cell_x - origin_cell_x) * CELL, y, (cell_z - origin_cell_z) * CELL)

func add_exterior_surface_vertex(st: SurfaceTool, point: Vector3, color_cache: Dictionary, normal_cache: Dictionary, cell_x: int, cell_z: int) -> void:
    var key := Vector2i(cell_x, cell_z)
    st.set_normal(normal_cache.get(key, Vector3.UP))
    st.set_color(color_cache.get(key, BIOME_COLORS["plains"]))
    st.add_vertex(point)

func add_exterior_surface_triangle(
    st: SurfaceTool,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    color_cache: Dictionary,
    normal_cache: Dictionary,
    cell_a: Vector2i,
    cell_b: Vector2i,
    cell_c: Vector2i
) -> void:
    add_exterior_surface_vertex(st, a, color_cache, normal_cache, cell_a.x, cell_a.y)
    add_exterior_surface_vertex(st, b, color_cache, normal_cache, cell_b.x, cell_b.y)
    add_exterior_surface_vertex(st, c, color_cache, normal_cache, cell_c.x, cell_c.y)

func exterior_surface_y_cell(cell_x: int, cell_z: int) -> float:
    var edit_key := Vector2i(cell_x, cell_z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if world_generation_system != null:
        return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    return 0.0

func exterior_surface_chunk_context(start_x: int, start_z: int) -> Dictionary:
    var context := {
        "towns": [],
        "hasSurfaceDeformation": world_generation_system != null and world_generation_system.has_method("has_surface_deformation") and bool(world_generation_system.call("has_surface_deformation"))
    }
    if world_generation_system == null or not world_generation_system.has_method("town_slope_apron_cells"):
        return context
    var min_x := start_x - 1
    var max_x := start_x + CHUNK_SIZE + 1
    var min_z := start_z - 1
    var max_z := start_z + CHUNK_SIZE + 1
    var region_min_x := floori(float(min_x) / float(TOWN_REGION_CELLS)) - 1
    var region_max_x := floori(float(max_x) / float(TOWN_REGION_CELLS)) + 1
    var region_min_z := floori(float(min_z) / float(TOWN_REGION_CELLS)) - 1
    var region_max_z := floori(float(max_z) / float(TOWN_REGION_CELLS)) + 1
    var towns: Array[Dictionary] = []
    for rz in range(region_min_z, region_max_z + 1):
        for rx in range(region_min_x, region_max_x + 1):
            var town: Dictionary = town_region(rx, rz)
            if town.is_empty():
                continue
            var center_x := float(town.get("centerX", 0))
            var center_z := float(town.get("centerZ", 0))
            var radius := float(town.get("radius", TOWN_RADIUS_CELLS))
            var apron := float(world_generation_system.call("town_slope_apron_cells", town))
            var influence_radius := radius + apron
            var nearest_x := clampf(center_x, float(min_x), float(max_x))
            var nearest_z := clampf(center_z, float(min_z), float(max_z))
            var distance := Vector2(center_x - nearest_x, center_z - nearest_z).length()
            if distance > influence_radius + 1.0:
                continue
            towns.append({
                "centerX": center_x,
                "centerZ": center_z,
                "radius": radius,
                "apron": apron,
                "level": float(town.get("level", float(WATER_LEVEL) + 3.0))
            })
    context["towns"] = towns
    return context

func exterior_surface_context_is_plain(context: Dictionary) -> bool:
    if not volume_edit_markers.is_empty():
        return false
    if bool(context.get("hasSurfaceDeformation", false)):
        return false
    var towns_value = context.get("towns", [])
    return (towns_value is Array and (towns_value as Array).is_empty()) or not (towns_value is Array)

func exterior_surface_y_cell_from_context(cell_x: int, cell_z: int, context: Dictionary) -> float:
    var edit_key := Vector2i(cell_x, cell_z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if bool(context.get("hasSurfaceDeformation", false)) and world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    var towns_value = context.get("towns", [])
    var towns: Array = towns_value if towns_value is Array else []
    var best_town := {}
    var best_distance := INF
    for town_value in towns:
        if not (town_value is Dictionary):
            continue
        var town: Dictionary = town_value
        var center_x := float(town.get("centerX", 0.0))
        var center_z := float(town.get("centerZ", 0.0))
        var distance := Vector2(float(cell_x) - center_x, float(cell_z) - center_z).length()
        var max_distance := float(town.get("radius", TOWN_RADIUS_CELLS)) + float(town.get("apron", 18.0))
        if distance <= max_distance and distance < best_distance:
            best_town = town
            best_distance = distance
    if best_town.is_empty():
        return natural_exterior_surface_y_cell(cell_x, cell_z)
    var radius := float(best_town.get("radius", TOWN_RADIUS_CELLS))
    var level := float(best_town.get("level", float(WATER_LEVEL) + 3.0))
    if best_distance <= radius:
        return level
    var apron := float(best_town.get("apron", 18.0))
    var delta := Vector2(float(cell_x) - float(best_town.get("centerX", 0.0)), float(cell_z) - float(best_town.get("centerZ", 0.0)))
    var natural := natural_exterior_surface_y_cell(cell_x, cell_z)
    if delta.length() > 0.001:
        var direction := delta.normalized()
        var sample_distance := radius + apron
        var sample_x := int(round(float(best_town.get("centerX", 0.0)) + direction.x * sample_distance))
        var sample_z := int(round(float(best_town.get("centerZ", 0.0)) + direction.y * sample_distance))
        natural = natural_exterior_surface_y_cell(sample_x, sample_z)
    var blend := clampf((best_distance - radius) / maxf(1.0, apron), 0.0, 1.0)
    var eased := blend * blend * (3.0 - 2.0 * blend)
    return lerp(level, natural, eased)

func natural_exterior_surface_y_cell(cell_x: int, cell_z: int) -> float:
    if world_generation_system != null:
        if world_generation_system.has_method("surface_y_for_cell"):
            return float(world_generation_system.surface_y_for_cell(Vector3i(cell_x, 0, cell_z)))
    return 0.0

func exterior_surface_color_for_cell(cell_x: int, cell_z: int) -> Color:
    if world_generation_system != null:
        return world_generation_system.surface_color_for_cell3(Vector3i(cell_x, 0, cell_z))
    return BIOME_COLORS.get(surface_biome_at_cell(Vector3i(cell_x, 0, cell_z)), BIOME_COLORS["plains"])

func exterior_surface_color_for_cell_from_context(cell_x: int, cell_z: int, surface_y: float, context: Dictionary) -> Color:
    if exterior_surface_context_contains_town_cell(cell_x, cell_z, context):
        return Color(0.43, 0.53, 0.32)
    return natural_exterior_surface_color_for_cell(cell_x, cell_z, surface_y)

func natural_exterior_surface_color_for_cell(cell_x: int, cell_z: int, surface_y: float) -> Color:
    var moisture: float = noise01(moisture_noise, cell_x - 1200, cell_z + 800)
    var temp: float = clampf(0.42 + noise01(temp_noise, cell_x + 1500, cell_z - 900) * 0.46 - abs(cell_z) / 1300.0 - maxf(0.0, surface_y - 38.0) / 180.0, 0.0, 1.0)
    if surface_y < float(WATER_LEVEL) + 1.7:
        return Color(0.76, 0.67, 0.42)
    if surface_y > 78.0:
        return Color(0.77, 0.82, 0.82)
    if surface_y > 56.0:
        return Color(0.34, 0.35, 0.31)
    if surface_y > 42.0 and moisture < 0.5:
        return Color(0.34, 0.35, 0.31)
    if moisture > 0.78 and surface_y < float(WATER_LEVEL) + 6.0:
        return Color(0.28, 0.39, 0.22)
    if temp > 0.68 and moisture < 0.32:
        return Color(0.76, 0.67, 0.42)
    if temp > 0.61 and moisture < 0.48:
        return Color(0.55, 0.58, 0.29)
    if moisture > 0.64:
        return Color(0.34, 0.53, 0.29)
    return Color(0.43, 0.62, 0.32)

func exterior_surface_context_contains_town_cell(cell_x: int, cell_z: int, context: Dictionary) -> bool:
    var towns_value = context.get("towns", [])
    var towns: Array = towns_value if towns_value is Array else []
    for town_value in towns:
        if not (town_value is Dictionary):
            continue
        var town: Dictionary = town_value
        var center_x := float(town.get("centerX", 0.0))
        var center_z := float(town.get("centerZ", 0.0))
        var radius := float(town.get("radius", TOWN_RADIUS_CELLS))
        if Vector2(float(cell_x) - center_x, float(cell_z) - center_z).length() <= radius:
            return true
    return false

func exterior_surface_normal_cached(surface_cache: Dictionary, cell_x: int, cell_z: int) -> Vector3:
    var left := exterior_surface_y_from_cache(surface_cache, cell_x - 1, cell_z)
    var right := exterior_surface_y_from_cache(surface_cache, cell_x + 1, cell_z)
    var back := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z - 1)
    var forward := exterior_surface_y_from_cache(surface_cache, cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func exterior_surface_normal_for_cell(cell_x: int, cell_z: int) -> Vector3:
    var left := natural_exterior_surface_y_cell(cell_x - 1, cell_z)
    var right := natural_exterior_surface_y_cell(cell_x + 1, cell_z)
    var back := natural_exterior_surface_y_cell(cell_x, cell_z - 1)
    var forward := natural_exterior_surface_y_cell(cell_x, cell_z + 1)
    return Vector3(left - right, CELL * 2.0, back - forward).normalized()

func chunk_has_town_surface_volume_edge(start_x: int, start_z: int) -> bool:
    var context := exterior_surface_chunk_context(start_x, start_z)
    var towns_value = context.get("towns", [])
    if not (towns_value is Array) or (towns_value as Array).is_empty():
        return false
    var step := 4
    var edge_threshold := CELL * 0.65
    var slope_threshold := CELL * 1.25
    var offsets: Array[Vector2i] = [Vector2i(step, 0), Vector2i(0, step)]
    for local_z in range(-step, CHUNK_SIZE + step + 1, step):
        for local_x in range(-step, CHUNK_SIZE + step + 1, step):
            var cell_x := start_x + local_x
            var cell_z := start_z + local_z
            var in_town := exterior_surface_context_contains_town_cell(cell_x, cell_z, context)
            var surface_y := exterior_surface_y_cell_from_context(cell_x, cell_z, context)
            for offset in offsets:
                var neighbor_x := cell_x + offset.x
                var neighbor_z := cell_z + offset.y
                var neighbor_in_town := exterior_surface_context_contains_town_cell(neighbor_x, neighbor_z, context)
                var neighbor_y := exterior_surface_y_cell_from_context(neighbor_x, neighbor_z, context)
                var delta_y := absf(surface_y - neighbor_y)
                if in_town != neighbor_in_town and delta_y >= edge_threshold:
                    return true
                if (in_town or neighbor_in_town) and delta_y >= slope_threshold:
                    return true
    return false

func project_chunk_surface_normals(mesh: Mesh, cx: int, cz: int) -> Mesh:
    if mesh == null or not (mesh is ArrayMesh):
        return mesh
    var array_mesh := mesh as ArrayMesh
    if array_mesh.get_surface_count() <= 0:
        return mesh
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var projected_surfaces: Array = []
    var surface_materials: Array = []
    var changed_any := false
    for surface_index in range(array_mesh.get_surface_count()):
        var arrays := array_mesh.surface_get_arrays(surface_index)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
        var changed_surface := false
        if not vertices.is_empty() and normals.size() == vertices.size():
            for vertex_index in range(vertices.size()):
                var normal := normals[vertex_index]
                if normal.y <= 0.20:
                    continue
                var vertex := vertices[vertex_index]
                var cell_x := roundi((float(start_x) * CELL + vertex.x) / CELL)
                var cell_z := roundi((float(start_z) * CELL + vertex.z) / CELL)
                var surface_y := natural_exterior_surface_y_cell(cell_x, cell_z)
                if absf(vertex.y - surface_y) > CELL * 2.25:
                    continue
                var projected_normal := exterior_surface_normal_for_cell(cell_x, cell_z)
                if projected_normal.length_squared() <= 0.0001:
                    continue
                normals[vertex_index] = projected_normal
                changed_surface = true
            if changed_surface:
                arrays[Mesh.ARRAY_NORMAL] = normals
                changed_any = true
        projected_surfaces.append(arrays)
        surface_materials.append(array_mesh.surface_get_material(surface_index))
    if not changed_any:
        return mesh
    var projected_mesh := ArrayMesh.new()
    for surface_index in range(projected_surfaces.size()):
        projected_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, projected_surfaces[surface_index])
        var material = surface_materials[surface_index]
        if material is Material:
            projected_mesh.surface_set_material(surface_index, material as Material)
    for meta_name in mesh.get_meta_list():
        projected_mesh.set_meta(String(meta_name), mesh.get_meta(String(meta_name)))
    projected_mesh.set_meta("terrainSurfaceNormalsProjected", true)
    return projected_mesh

func exterior_surface_y_from_cache(surface_cache: Dictionary, cell_x: int, cell_z: int) -> float:
    var key := Vector2i(cell_x, cell_z)
    return float(surface_cache[key]) if surface_cache.has(key) else exterior_surface_y_cell(cell_x, cell_z)

func chunk_needs_generated_underground_volume_mesh(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    if chunk_has_terrain_volume_edits(start_x, start_z):
        return true
    var focus_is_underground := player != null and position_is_near_underground_air_focus(player.global_position)
    if focus_is_underground and chunk_has_underground_focus_overlap(start_x, start_z):
        return true
    if chunk_has_town_surface_volume_edge(start_x, start_z):
        return true
    if has_method("should_use_cached_generated_volume_exposure_only") and bool(call("should_use_cached_generated_volume_exposure_only")):
        var cached_value = cached_generated_surface_volume_exposure(start_x, start_z)
        if cached_value is Dictionary:
            var cached: Dictionary = cached_value
            if bool(cached.get("known", false)):
                return bool(cached.get("result", false))
        if has_method("queue_generated_volume_exposure_scan_for_region"):
            call("queue_generated_volume_exposure_scan_for_region", start_x, start_z)
        return false
    if has_method("should_defer_generated_volume_exposure_scan") and bool(call("should_defer_generated_volume_exposure_scan")):
        if has_method("note_deferred_generated_volume_exposure_scan"):
            call("note_deferred_generated_volume_exposure_scan")
        return false
    if chunk_has_generated_surface_volume_exposure(start_x, start_z):
        return true
    if adjacent_chunk_requires_generated_underground_volume_mesh(start_x, start_z, focus_is_underground):
        return true
    return false

func adjacent_chunk_requires_generated_underground_volume_mesh(start_x: int, start_z: int, focus_is_underground: bool) -> bool:
    var offsets: Array[Vector2i] = [
        Vector2i(1, 0),
        Vector2i(-1, 0),
        Vector2i(0, 1),
        Vector2i(0, -1)
    ]
    for offset: Vector2i in offsets:
        var neighbor_start_x: int = start_x + offset.x * CHUNK_SIZE
        var neighbor_start_z: int = start_z + offset.y * CHUNK_SIZE
        if chunk_has_terrain_volume_edits(neighbor_start_x, neighbor_start_z):
            return true
        if focus_is_underground and chunk_has_underground_focus_overlap(neighbor_start_x, neighbor_start_z):
            return true
        if chunk_has_town_surface_volume_edge(neighbor_start_x, neighbor_start_z):
            return true
        if chunk_has_generated_surface_volume_exposure(neighbor_start_x, neighbor_start_z):
            return true
    return false

func chunk_has_terrain_volume_edits(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_chunk_has_edits"):
        return false
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    return bool(world_generation_system.call("terrain_volume_chunk_has_edits", chunk_key, CHUNK_SIZE))

func edited_volume_boundary_cells_for_chunk(start_x: int, start_z: int, min_y: int, max_y: int) -> Array[Vector3i]:
    if world_generation_system == null or not world_generation_system.has_method("terrain_volume_edited_mesh_cells_for_chunk"):
        return []
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var cells_value = world_generation_system.call("terrain_volume_edited_mesh_cells_for_chunk", chunk_key, CHUNK_SIZE)
    if not (cells_value is Array):
        return []
    var cells: Array[Vector3i] = []
    for value in cells_value:
        if not (value is Vector3i):
            continue
        var cell: Vector3i = value
        if cell.y < min_y - 2 or cell.y > max_y + 2:
            continue
        cells.append(cell)
    return cells

func underground_air_column_reaches_open_surface(cell_x: int, air_y: int, cell_z: int, surface_cell_y: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    for y in range(air_y + 1, surface_cell_y + 2):
        var sample_position := Vector3(float(cell_x) * CELL, float(y) * CELL, float(cell_z) * CELL)
        var sample: Dictionary = world_generation_system.call("sample_world", sample_position)
        if bool(sample.get("solid", false)):
            return false
    return true

func chunk_has_generated_surface_volume_exposure(start_x: int, start_z: int) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return false
    var cached_value = cached_generated_surface_volume_exposure(start_x, start_z)
    if cached_value is Dictionary:
        var cached: Dictionary = cached_value
        if bool(cached.get("known", false)):
            return bool(cached.get("result", false))
    var step := maxi(4, int(UNDERGROUND_VOLUME_EXTERIOR_LOD_STEP_CELLS))
    var vertical_step := maxi(1, int(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_VERTICAL_STEP_CELLS))
    var max_depth_cells := mini(
        generated_volume_scan_depth_for_chunk(start_x, start_z, step),
        int(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS)
    )
    var result := false
    var sample_cache := {}
    for z in range(start_z - step, start_z + CHUNK_SIZE + step + 1, step):
        for x in range(start_x - step, start_x + CHUNK_SIZE + step + 1, step):
            var surface_y := chunk_reference_surface_y_for_volume_scan(x, z)
            var surface_cell_y := floori(surface_y / CELL)
            for depth in range(1, max_depth_cells + 1, vertical_step):
                var y := surface_cell_y - depth
                var numeric_sample := volume_grid_sample_numeric(Vector3i(x, y, z), sample_cache)
                if numeric_sample.x < 0.0 and numeric_sample.y <= 0.0:
                    if underground_air_column_reaches_open_surface(x, y, z, surface_cell_y):
                        result = true
                        break
            if result:
                break
        if result:
            break
    cache_generated_surface_volume_exposure(start_x, start_z, result)
    return result

func generated_volume_scan_depth_for_chunk(start_x: int, start_z: int, step_cells: int) -> int:
    var bottom_y := int(world_generation_system.call("world_bottom_cell_y")) if world_generation_system != null and world_generation_system.has_method("world_bottom_cell_y") else floori((MIN_HEIGHT - CELL * 64.0) / CELL)
    var max_surface_cell_y := floori(MAX_HEIGHT / CELL)
    var step := maxi(1, int(step_cells))
    for z in range(start_z - step, start_z + CHUNK_SIZE + step + 1, step):
        for x in range(start_x - step, start_x + CHUNK_SIZE + step + 1, step):
            var surface_cell_y := floori(chunk_reference_surface_y_for_volume_scan(x, z) / CELL)
            max_surface_cell_y = maxi(max_surface_cell_y, surface_cell_y)
    return maxi(1, max_surface_cell_y - bottom_y - 1)

func chunk_reference_surface_y_for_volume_scan(cell_x: int, cell_z: int) -> float:
    if world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
    return chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))

func chunk_has_underground_focus_overlap(start_x: int, start_z: int) -> bool:
    if player == null:
        return false
    var focus := player.global_position
    if not position_is_near_underground_air_focus(focus):
        return false
    var radius := float(maxi(underground_volume_focus_radius_cells(), UNDERGROUND_VOLUME_FOCUS_STEP_CELLS)) * CELL
    var min_x := float(start_x) * CELL - radius
    var max_x := float(start_x + CHUNK_SIZE) * CELL + radius
    var min_z := float(start_z) * CELL - radius
    var max_z := float(start_z + CHUNK_SIZE) * CELL + radius
    return focus.x >= min_x and focus.x <= max_x and focus.z >= min_z and focus.z <= max_z

func position_is_near_underground_air_focus(position: Vector3) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_world"):
        return force_underground_volume_debug
    var focus_cell := Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z))
    var revision := int(world_generation_system.call("terrain_volume_revision")) if world_generation_system.has_method("terrain_volume_revision") else 0
    var seed_key := seed_text
    var cache_matches := focus_cell == underground_focus_cache_cell
    cache_matches = cache_matches and revision == underground_focus_cache_revision
    cache_matches = cache_matches and seed_key == underground_focus_cache_seed
    cache_matches = cache_matches and force_underground_volume_debug == underground_focus_cache_debug
    if cache_matches:
        return underground_focus_cache_result
    if force_underground_volume_debug:
        return remember_underground_focus_result(focus_cell, revision, seed_key, true)
    var surface_y := chunk_bound_surface_y_at_cell(Vector3i(focus_cell.x, 0, focus_cell.z))
    if position.y >= surface_y - CELL * 0.35:
        return remember_underground_focus_result(focus_cell, revision, seed_key, false)
    var offsets: Array[Vector3i] = [
        Vector3i.ZERO,
        Vector3i(0, -1, 0),
        Vector3i(0, 1, 0),
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for offset: Vector3i in offsets:
        var sample_cell: Vector3i = focus_cell + offset
        if world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
            var numeric_sample: Vector3 = world_generation_system.call("volume_numeric_sample_at_grid_cell", sample_cell)
            if numeric_sample.x < 0.0 and numeric_sample.y <= 0.0:
                return remember_underground_focus_result(focus_cell, revision, seed_key, true)
            continue
        var sample_position := Vector3(float(sample_cell.x) * CELL, float(sample_cell.y) * CELL, float(sample_cell.z) * CELL)
        var sample: Dictionary = world_generation_system.call("sample_world", sample_position)
        if String(sample.get("biome", "")) == "underground_air" and not bool(sample.get("solid", false)):
            return remember_underground_focus_result(focus_cell, revision, seed_key, true)
    return remember_underground_focus_result(focus_cell, revision, seed_key, false)

func remember_underground_focus_result(cell: Vector3i, revision: int, seed_key: String, result: bool) -> bool:
    underground_focus_cache_cell = cell
    underground_focus_cache_revision = revision
    underground_focus_cache_seed = seed_key
    underground_focus_cache_debug = force_underground_volume_debug
    underground_focus_cache_result = result
    return result

func chunk_has_excavation_overlap(start_x: int, start_z: int) -> bool:
    var brushes := active_volume_excavation_brushes()
    if brushes.is_empty():
        return false
    var min_x := float(start_x) * CELL - CELL
    var max_x := float(start_x + CHUNK_SIZE) * CELL + CELL
    var min_z := float(start_z) * CELL - CELL
    var max_z := float(start_z + CHUNK_SIZE) * CELL + CELL
    for brush_value in brushes:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        if center.x + radius < min_x or center.x - radius > max_x:
            continue
        if center.z + radius < min_z or center.z - radius > max_z:
            continue
        return true
    return false

func excavation_volume_y_bounds_for_chunk(start_x: int, start_z: int) -> Dictionary:
    var min_y := 999999
    var max_y := -999999
    var found := false
    var chunk_min_x := float(start_x) * CELL - CELL
    var chunk_max_x := float(start_x + CHUNK_SIZE) * CELL + CELL
    var chunk_min_z := float(start_z) * CELL - CELL
    var chunk_max_z := float(start_z + CHUNK_SIZE) * CELL + CELL
    for brush_value in active_volume_excavation_brushes():
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        var center: Vector3 = brush.get("center", Vector3.ZERO)
        var radius := float(brush.get("radius", 0.0))
        if radius <= 0.0:
            continue
        if center.x + radius < chunk_min_x or center.x - radius > chunk_max_x:
            continue
        if center.z + radius < chunk_min_z or center.z - radius > chunk_max_z:
            continue
        var center_y := world_to_cell(center.y)
        var radius_cells := ceili(radius / CELL) + 3
        min_y = mini(min_y, center_y - radius_cells)
        max_y = maxi(max_y, center_y + radius_cells)
        found = true
    if not found:
        return {
            "minY": 0,
            "maxY": 0
        }
    return {
        "minY": min_y,
        "maxY": max_y
    }

func chunk_volume_y_bounds(start_x: int, start_z: int) -> Dictionary:
    if player != null and chunk_has_underground_focus_overlap(start_x, start_z):
        var radius_world := float(underground_volume_focus_radius_cells() + 3) * CELL
        return {
            "minY": floori((player.global_position.y - radius_world) / CELL),
            "maxY": ceili((player.global_position.y + radius_world) / CELL)
        }
    if world_generation_system != null and world_generation_system.has_method("terrain_meshing_y_bounds_for_chunk"):
        var authoritative_bounds_value = world_generation_system.call(
            "terrain_meshing_y_bounds_for_chunk",
            start_x,
            start_z,
            CHUNK_SIZE,
            UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS + 4,
            2,
            2
        )
        if authoritative_bounds_value is Dictionary:
            return authoritative_bounds_value
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var edited_bounds := {}
    if world_generation_system != null and world_generation_system.has_method("terrain_volume_chunk_edited_y_bounds"):
        edited_bounds = world_generation_system.call("terrain_volume_chunk_edited_y_bounds", chunk_key, CHUNK_SIZE)
    var min_height := INF
    var max_height := -INF
    for z in range(start_z - 2, start_z + CHUNK_SIZE + 3):
        for x in range(start_x - 2, start_x + CHUNK_SIZE + 3):
            var h := chunk_bound_surface_y_at_cell(Vector3i(x, 0, z))
            min_height = minf(min_height, h)
            max_height = maxf(max_height, h)
    if min_height == INF:
        min_height = MIN_HEIGHT
        max_height = MAX_HEIGHT
    var fallback_depth_cells := 64
    var bottom_world := float(world_generation_system.call("world_bottom_cell_y")) * CELL if world_generation_system != null and world_generation_system.has_method("world_bottom_cell_y") else min_height - float(fallback_depth_cells) * CELL
    var shallow_surface_depth := float(UNDERGROUND_VOLUME_SURFACE_EXPOSURE_DEPTH_CELLS + 4) * CELL
    var min_bound: float = maxf(bottom_world, min_height - shallow_surface_depth)
    var max_bound: float = max_height + CELL * 2.0
    if bool(edited_bounds.get("found", false)):
        min_bound = maxf(bottom_world, float(int(edited_bounds.get("minY", floori(bottom_world / CELL))) - 3) * CELL)
        max_bound = maxf(max_bound, float(int(edited_bounds.get("maxY", ceili(max_height / CELL))) + 3) * CELL)
    return {
        "minY": floori(min_bound / CELL),
        "maxY": ceili(max_bound / CELL)
    }

func column_volume_y_bounds(cell_x: int, cell_z: int, chunk_min_y: int, chunk_max_y: int) -> Dictionary:
    var surface := chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    var min_bound := float(chunk_min_y) * CELL
    var max_bound := surface + CELL * 2.0
    return {
        "minY": clampi(floori(min_bound / CELL), chunk_min_y, chunk_max_y),
        "maxY": clampi(ceili(max_bound / CELL), chunk_min_y, chunk_max_y)
    }

func mesh_block_volume_y_bounds(cell_x: int, cell_z: int, step_cells: int, chunk_min_y: int, chunk_max_y: int) -> Dictionary:
    var min_bound := chunk_max_y
    var max_bound := chunk_min_y
    var found := false
    var step := maxi(1, step_cells)
    for dz in range(step):
        for dx in range(step):
            var bounds := column_volume_y_bounds(cell_x + dx, cell_z + dz, chunk_min_y, chunk_max_y)
            var bound_min := int(bounds.get("minY", chunk_min_y))
            var bound_max := int(bounds.get("maxY", chunk_min_y))
            if bound_max <= bound_min:
                continue
            min_bound = mini(min_bound, bound_min)
            max_bound = maxi(max_bound, bound_max)
            found = true
    if not found:
        return {
            "minY": chunk_min_y,
            "maxY": chunk_min_y
        }
    return {
        "minY": min_bound,
        "maxY": max_bound
    }

func chunk_bound_surface_y_at_cell(cell: Vector3i) -> float:
    if world_generation_system != null:
        return world_generation_system.surface_y_for_cell(cell)
    return surface_y_at_cell(cell)

func volume_grid_sample(grid_cell: Vector3i, sample_cache: Dictionary, volume_context := {}) -> Dictionary:
    if sample_cache.has(grid_cell):
        return sample_cache[grid_cell]
    var position := Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
    var sample := {}
    if not volume_context.is_empty():
        sample = volume_sample_from_context(position, grid_cell, volume_context)
    elif world_generation_system != null and world_generation_system.has_method("sample_world"):
        sample = world_generation_system.call("sample_world", position)
    elif world_generation_system != null and world_generation_system.has_method("sample_cell"):
        sample = world_generation_system.call("sample_cell", grid_cell)
        sample["position"] = position
    else:
        var surface_y := surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))
        var density := surface_y - position.y
        sample = {
            "cell": grid_cell,
            "position": position,
            "solid": density >= 0.0,
            "biome": surface_biome_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z)),
            "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z)),
            "density": density
        }
    sample_cache[grid_cell] = sample
    return sample

func volume_grid_sample_numeric(grid_cell: Vector3i, sample_cache: Dictionary, volume_context := {}) -> Vector3:
    if sample_cache.has(grid_cell):
        var cached = sample_cache[grid_cell]
        if cached is Vector3:
            return cached
    if world_generation_system != null and world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
        var fast_result: Vector3 = world_generation_system.call("volume_numeric_sample_at_grid_cell", grid_cell)
        sample_cache[grid_cell] = fast_result
        return fast_result
    var position := Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
    var surface_y := 0.0
    var generated_air_value := INF
    var density := 0.0
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        var sample: Dictionary = world_generation_system.call("sample_world", position)
        density = float(sample.get("density", 0.0))
        generated_air_value = 0.0 if String(sample.get("biome", "")) == "underground_air" and not bool(sample.get("solid", true)) else INF
        surface_y = float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))))
    else:
        surface_y = surface_y_at_cell(Vector3i(grid_cell.x, 0, grid_cell.z))
        density = surface_y - position.y
    var result := Vector3(density, generated_air_value, surface_y)
    sample_cache[grid_cell] = result
    return result

func native_terrain_numeric_sample_at_grid_cell(grid_cell: Vector3i) -> Vector3:
    if world_generation_system != null and world_generation_system.has_method("volume_numeric_sample_at_grid_cell"):
        return world_generation_system.call("volume_numeric_sample_at_grid_cell", grid_cell)
    return volume_grid_sample_numeric(grid_cell, {})

func extract_volume_iso_cube_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    base_cell: Vector3i,
    origin_x: int,
    origin_z: int,
    sample_cache: Dictionary,
    volume_context := {},
    step_cells := 1
) -> void:
    var local_positions: Array[Vector3] = []
    var world_positions: Array[Vector3] = []
    var densities := PackedFloat32Array()
    var generated_air_values := PackedFloat32Array()
    var surface_ys := PackedFloat32Array()
    var solids: Array[bool] = []
    local_positions.resize(8)
    world_positions.resize(8)
    densities.resize(8)
    generated_air_values.resize(8)
    surface_ys.resize(8)
    solids.resize(8)
    var solid_count := 0
    for index in range(VOLUME_CUBE_CORNER_OFFSETS.size()):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        offset = Vector3i(offset.x * step_cells, offset.y * step_cells, offset.z * step_cells)
        var grid_cell: Vector3i = base_cell + offset
        var sample := volume_grid_sample_numeric(grid_cell, sample_cache, volume_context)
        var density := sample.x
        var solid := density > 0.0
        if solid:
            solid_count += 1
        local_positions[index] = Vector3(float(grid_cell.x - origin_x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z - origin_z) * CELL)
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        densities[index] = density
        generated_air_values[index] = sample.y
        surface_ys[index] = sample.z
        solids[index] = solid
    if solid_count == 0 or solid_count == local_positions.size():
        return
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 5, 1, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 1, 2, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 2, 3, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 3, 7, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 7, 4, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)
    extract_volume_iso_tetrahedron_indices_numeric(vertices, normals, colors, 0, 4, 5, 6, local_positions, world_positions, densities, generated_air_values, surface_ys, solids, volume_context)

func extract_volume_iso_tetrahedron_indices_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    i0: int,
    i1: int,
    i2: int,
    i3: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array,
    surface_ys: PackedFloat32Array,
    solids: Array[bool],
    volume_context := {}
) -> void:
    var solid0 := -1
    var solid1 := -1
    var solid2 := -1
    var air0 := -1
    var air1 := -1
    var air2 := -1
    var solid_count := 0
    var air_count := 0
    if bool(solids[i0]):
        solid0 = i0
        solid_count += 1
    else:
        air0 = i0
        air_count += 1
    if bool(solids[i1]):
        if solid_count == 0:
            solid0 = i1
        elif solid_count == 1:
            solid1 = i1
        else:
            solid2 = i1
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i1
        elif air_count == 1:
            air1 = i1
        else:
            air2 = i1
        air_count += 1
    if bool(solids[i2]):
        if solid_count == 0:
            solid0 = i2
        elif solid_count == 1:
            solid1 = i2
        else:
            solid2 = i2
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i2
        elif air_count == 1:
            air1 = i2
        else:
            air2 = i2
        air_count += 1
    if bool(solids[i3]):
        if solid_count == 0:
            solid0 = i3
        elif solid_count == 1:
            solid1 = i3
        else:
            solid2 = i3
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i3
        elif air_count == 1:
            air1 = i3
        else:
            air2 = i3
        air_count += 1
    if solid_count == 0 or air_count == 0:
        return
    if not volume_air_indices_need_iso_surface_numeric(air0, air1, air2, air_count, generated_air_values, surface_ys, world_positions):
        return
    if solid_count == 1:
        var desired := average_world_positions_fast(air0, air1, air2, air_count, world_positions) - world_positions[solid0]
        add_volume_iso_triangle_edges_numeric(
            vertices,
            normals,
            colors,
            solid0,
            air0,
            solid0,
            air1,
            solid0,
            air2,
            local_positions,
            world_positions,
            densities,
            generated_air_values,
            desired,
            volume_context
        )
    elif solid_count == 3:
        var desired := world_positions[air0] - average_world_positions_fast(solid0, solid1, solid2, solid_count, world_positions)
        add_volume_iso_triangle_edges_numeric(
            vertices,
            normals,
            colors,
            solid0,
            air0,
            solid1,
            air0,
            solid2,
            air0,
            local_positions,
            world_positions,
            densities,
            generated_air_values,
            desired,
            volume_context
        )
    elif solid_count == 2 and air_count == 2:
        var desired := average_world_positions_fast(air0, air1, -1, air_count, world_positions) - average_world_positions_fast(solid0, solid1, -1, solid_count, world_positions)
        add_volume_iso_triangle_edges_numeric(vertices, normals, colors, solid0, air0, solid1, air0, solid1, air1, local_positions, world_positions, densities, generated_air_values, desired, volume_context)
        add_volume_iso_triangle_edges_numeric(vertices, normals, colors, solid0, air0, solid1, air1, solid0, air1, local_positions, world_positions, densities, generated_air_values, desired, volume_context)

func volume_air_indices_need_iso_surface_numeric(
    air0: int,
    air1: int,
    air2: int,
    air_count: int,
    generated_air_values: PackedFloat32Array,
    surface_ys: PackedFloat32Array,
    world_positions: Array[Vector3]
) -> bool:
    if air_count >= 1 and volume_air_index_needs_iso_surface_numeric(air0, generated_air_values, surface_ys, world_positions):
        return true
    if air_count >= 2 and volume_air_index_needs_iso_surface_numeric(air1, generated_air_values, surface_ys, world_positions):
        return true
    if air_count >= 3 and volume_air_index_needs_iso_surface_numeric(air2, generated_air_values, surface_ys, world_positions):
        return true
    return false

func volume_air_index_needs_iso_surface_numeric(index: int, generated_air_values: PackedFloat32Array, surface_ys: PackedFloat32Array, world_positions: Array[Vector3]) -> bool:
    if index < 0:
        return false
    if float(generated_air_values[index]) <= 0.0:
        return true
    return world_positions[index].y < float(surface_ys[index]) - CELL * 0.35

func interpolate_volume_iso_edge_numeric(
    solid_index: int,
    air_index: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array
) -> Array:
    var da := float(densities[solid_index])
    var db := float(densities[air_index])
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    return [
        local_positions[solid_index].lerp(local_positions[air_index], t),
        world_positions[solid_index].lerp(world_positions[air_index], t),
        float(generated_air_values[air_index])
    ]

func add_volume_iso_triangle_edges_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    solid_a: int,
    air_a: int,
    solid_b: int,
    air_b: int,
    solid_c: int,
    air_c: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    generated_air_values: PackedFloat32Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var da := float(densities[solid_a])
    var db := float(densities[air_a])
    var ta := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        ta = clampf(da / denominator, 0.0, 1.0)
    da = float(densities[solid_b])
    db = float(densities[air_b])
    var tb := 0.5
    denominator = da - db
    if absf(denominator) > 0.0001:
        tb = clampf(da / denominator, 0.0, 1.0)
    da = float(densities[solid_c])
    db = float(densities[air_c])
    var tc := 0.5
    denominator = da - db
    if absf(denominator) > 0.0001:
        tc = clampf(da / denominator, 0.0, 1.0)
    add_volume_iso_triangle_values_numeric(
        vertices,
        normals,
        colors,
        local_positions[solid_a].lerp(local_positions[air_a], ta),
        world_positions[solid_a].lerp(world_positions[air_a], ta),
        float(generated_air_values[air_a]),
        local_positions[solid_b].lerp(local_positions[air_b], tb),
        world_positions[solid_b].lerp(world_positions[air_b], tb),
        float(generated_air_values[air_b]),
        local_positions[solid_c].lerp(local_positions[air_c], tc),
        world_positions[solid_c].lerp(world_positions[air_c], tc),
        float(generated_air_values[air_c]),
        desired_normal,
        volume_context
    )

func add_volume_iso_triangle_values_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a_local: Vector3,
    a_world: Vector3,
    a_air_value: float,
    b_local: Vector3,
    b_world: Vector3,
    b_air_value: float,
    c_local: Vector3,
    c_world: Vector3,
    c_air_value: float,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap_local := b_local
        var swap_world := b_world
        var swap_air_value := b_air_value
        b_local = c_local
        b_world = c_world
        b_air_value = c_air_value
        c_local = swap_local
        c_world = swap_world
        c_air_value = swap_air_value
        cross = -cross
    var normal := cross.normalized()
    var face_world := (a_world + b_world + c_world) / 3.0
    var face_air_value := minf(a_air_value, minf(b_air_value, c_air_value))
    var face_color := volume_iso_vertex_color_numeric(face_world, face_air_value, normal, volume_context)
    vertices.append(a_local)
    normals.append(normal)
    colors.append(face_color)
    vertices.append(b_local)
    normals.append(normal)
    colors.append(face_color)
    vertices.append(c_local)
    normals.append(normal)
    colors.append(face_color)

func add_volume_iso_triangle_oriented_arrays_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a: Array,
    b: Array,
    c: Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap := b
        b = c
        c = swap
        cross = -cross
    var normal := cross.normalized()
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, a, normal, volume_context)
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, b, normal, volume_context)
    append_volume_iso_vertex_arrays_numeric(vertices, normals, colors, c, normal, volume_context)

func append_volume_iso_vertex_arrays_numeric(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    point: Array,
    normal: Vector3,
    volume_context := {}
) -> void:
    var world: Vector3 = point[1]
    var air_value := float(point[2])
    vertices.append(point[0])
    normals.append(normal)
    colors.append(volume_iso_vertex_color_numeric(world, air_value, normal, volume_context))

func volume_iso_vertex_color_numeric(world: Vector3, air_value: float, normal: Vector3, volume_context := {}) -> Color:
    var shade := volume_iso_shade(world)
    if air_value <= 0.0:
        shade *= underground_wall_visual_shade(world)
        if normal.y < -0.35:
            return Color(0.055, 0.060, 0.060) * shade
        if normal.y > 0.35:
            return Color(0.150, 0.158, 0.142) * shade
        return Color(0.170, 0.182, 0.170) * shade
    var cell := Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z))
    var surface_y := volume_context_surface_y_at_cell(cell.x, cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(Vector3i(cell.x, 0, cell.z))
    var biome := volume_context_surface_biome_at_cell(cell.x, cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(Vector3i(cell.x, 0, cell.z))
    var density := surface_y - world.y
    var material_id := volume_material_from_components(world, cell, density, surface_y, biome)
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
        return BIOME_COLORS.get(biome, BIOME_COLORS["plains"]) * shade
    match material_id:
        "sand":
            return Color(0.62, 0.57, 0.42) * shade
        "mud":
            return Color(0.30, 0.35, 0.25) * shade
        "snow":
            return Color(0.77, 0.82, 0.82) * shade
        "dirt":
            return Color(0.32, 0.27, 0.18) * shade
        "copperOre":
            return Color(0.48, 0.30, 0.20) * shade
        "ironOre":
            return Color(0.40, 0.39, 0.36) * shade
        _:
            return Color(0.36, 0.38, 0.35) * shade

func extract_volume_iso_tetrahedron_indices(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    i0: int,
    i1: int,
    i2: int,
    i3: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid0 := -1
    var solid1 := -1
    var solid2 := -1
    var air0 := -1
    var air1 := -1
    var air2 := -1
    var solid_count := 0
    var air_count := 0
    if bool(solids[i0]):
        solid0 = i0
        solid_count += 1
    else:
        air0 = i0
        air_count += 1
    if bool(solids[i1]):
        if solid_count == 0:
            solid0 = i1
        elif solid_count == 1:
            solid1 = i1
        else:
            solid2 = i1
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i1
        elif air_count == 1:
            air1 = i1
        else:
            air2 = i1
        air_count += 1
    if bool(solids[i2]):
        if solid_count == 0:
            solid0 = i2
        elif solid_count == 1:
            solid1 = i2
        else:
            solid2 = i2
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i2
        elif air_count == 1:
            air1 = i2
        else:
            air2 = i2
        air_count += 1
    if bool(solids[i3]):
        if solid_count == 0:
            solid0 = i3
        elif solid_count == 1:
            solid1 = i3
        else:
            solid2 = i3
        solid_count += 1
    else:
        if air_count == 0:
            air0 = i3
        elif air_count == 1:
            air1 = i3
        else:
            air2 = i3
        air_count += 1
    if solid_count == 0 or air_count == 0:
        return
    if not volume_air_indices_need_iso_surface_fast(air0, air1, air2, air_count, samples, world_positions):
        return
    if solid_count == 1:
        var desired := average_world_positions_fast(air0, air1, air2, air_count, world_positions) - world_positions[solid0]
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid0, air1, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid0, air2, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_count == 3:
        var desired := world_positions[air0] - average_world_positions_fast(solid0, solid1, solid2, solid_count, world_positions)
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid1, air0, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid2, air0, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_count == 2 and air_count == 2:
        var desired := average_world_positions_fast(air0, air1, -1, air_count, world_positions) - average_world_positions_fast(solid0, solid1, -1, solid_count, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid0, air0, local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid1, air0, local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid1, air1, local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid0, air1, local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p11, p01, desired, volume_context)

func volume_air_indices_need_iso_surface_fast(air0: int, air1: int, air2: int, air_count: int, samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    if air_count >= 1 and volume_air_index_needs_iso_surface(air0, samples, world_positions):
        return true
    if air_count >= 2 and volume_air_index_needs_iso_surface(air1, samples, world_positions):
        return true
    if air_count >= 3 and volume_air_index_needs_iso_surface(air2, samples, world_positions):
        return true
    return false

func volume_air_index_needs_iso_surface(index: int, samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    if index < 0:
        return false
    var sample: Dictionary = samples[index]
    if String(sample.get("biome", "")) == "underground_air":
        return true
    var world := world_positions[index]
    var surface_y := float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
    return world.y < surface_y - CELL * 0.35

func average_world_positions_fast(i0: int, i1: int, i2: int, count: int, world_positions: Array[Vector3]) -> Vector3:
    var total := Vector3.ZERO
    if count >= 1 and i0 >= 0:
        total += world_positions[i0]
    if count >= 2 and i1 >= 0:
        total += world_positions[i1]
    if count >= 3 and i2 >= 0:
        total += world_positions[i2]
    return total / maxf(1.0, float(count))

func extract_volume_iso_tetrahedron_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    tet: Array,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid_indices: Array[int] = []
    var air_indices: Array[int] = []
    for index_value in tet:
        var index := int(index_value)
        if bool(solids[index]):
            solid_indices.append(index)
        else:
            air_indices.append(index)
    if solid_indices.is_empty() or air_indices.is_empty():
        return
    if not volume_air_indices_need_iso_surface(air_indices, samples, world_positions):
        return
    if solid_indices.size() == 1:
        var solid_index := solid_indices[0]
        var desired := average_world_positions(air_indices, world_positions) - world_positions[solid_index]
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid_index, air_indices[0], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[1], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[2], local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 3:
        var air_index := air_indices[0]
        var desired := world_positions[air_index] - average_world_positions(solid_indices, world_positions)
        add_volume_iso_triangle_oriented_arrays(
            vertices,
            normals,
            colors,
            interpolate_volume_iso_edge_fast(solid_indices[0], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[1], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[2], air_index, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 2 and air_indices.size() == 2:
        var desired := average_world_positions(air_indices, world_positions) - average_world_positions(solid_indices, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[0], local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[0], local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[1], local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[1], local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_arrays(vertices, normals, colors, p00, p11, p01, desired, volume_context)

func add_volume_iso_triangle_oriented_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    a: Array,
    b: Array,
    c: Array,
    desired_normal: Vector3,
    volume_context := {}
) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap := b
        b = c
        c = swap
        cross = -cross
    var normal := cross.normalized()
    append_volume_iso_vertex_arrays(vertices, normals, colors, a, normal, volume_context)
    append_volume_iso_vertex_arrays(vertices, normals, colors, b, normal, volume_context)
    append_volume_iso_vertex_arrays(vertices, normals, colors, c, normal, volume_context)

func append_volume_iso_vertex_arrays(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    point: Array,
    normal: Vector3,
    volume_context := {}
) -> void:
    var world: Vector3 = point[1]
    var solid_sample: Dictionary = point[2]
    var air_sample: Dictionary = point[3]
    vertices.append(point[0])
    normals.append(normal)
    colors.append(volume_iso_vertex_color_fast(world, solid_sample, air_sample, normal, volume_context))

func extract_volume_iso_cube(st: SurfaceTool, base_cell: Vector3i, origin_x: int, origin_z: int, sample_cache: Dictionary, volume_context := {}, step_cells := 1) -> void:
    var local_positions: Array[Vector3] = []
    var world_positions: Array[Vector3] = []
    var samples: Array[Dictionary] = []
    var densities := PackedFloat32Array()
    var solids: Array[bool] = []
    local_positions.resize(8)
    world_positions.resize(8)
    samples.resize(8)
    densities.resize(8)
    solids.resize(8)
    var solid_count := 0
    for index in range(VOLUME_CUBE_CORNER_OFFSETS.size()):
        var offset: Vector3i = VOLUME_CUBE_CORNER_OFFSETS[index]
        offset = Vector3i(offset.x * step_cells, offset.y * step_cells, offset.z * step_cells)
        var grid_cell: Vector3i = base_cell + offset
        var sample := volume_grid_sample(grid_cell, sample_cache, volume_context)
        var density := float(sample.get("density", 0.0))
        var solid := density > 0.0
        if solid:
            solid_count += 1
        local_positions[index] = Vector3(float(grid_cell.x - origin_x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z - origin_z) * CELL)
        world_positions[index] = Vector3(float(grid_cell.x) * CELL, float(grid_cell.y) * CELL, float(grid_cell.z) * CELL)
        samples[index] = sample
        densities[index] = density
        solids[index] = solid
    if solid_count == 0 or solid_count == local_positions.size():
        return
    for tet in VOLUME_TETRAHEDRA:
        extract_volume_iso_tetrahedron_fast(st, tet, local_positions, world_positions, densities, solids, samples, volume_context)

func extract_volume_iso_tetrahedron_fast(
    st: SurfaceTool,
    tet: Array,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    solids: Array[bool],
    samples: Array[Dictionary],
    volume_context := {}
) -> void:
    var solid_indices: Array[int] = []
    var air_indices: Array[int] = []
    for index_value in tet:
        var index := int(index_value)
        if bool(solids[index]):
            solid_indices.append(index)
        else:
            air_indices.append(index)
    if solid_indices.is_empty() or air_indices.is_empty():
        return
    if not volume_air_indices_need_iso_surface(air_indices, samples, world_positions):
        return
    if solid_indices.size() == 1:
        var solid_index := solid_indices[0]
        var desired := average_world_positions(air_indices, world_positions) - world_positions[solid_index]
        add_volume_iso_triangle_oriented_fast(
            st,
            interpolate_volume_iso_edge_fast(solid_index, air_indices[0], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[1], local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_index, air_indices[2], local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 3:
        var air_index := air_indices[0]
        var desired := world_positions[air_index] - average_world_positions(solid_indices, world_positions)
        add_volume_iso_triangle_oriented_fast(
            st,
            interpolate_volume_iso_edge_fast(solid_indices[0], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[1], air_index, local_positions, world_positions, densities, samples),
            interpolate_volume_iso_edge_fast(solid_indices[2], air_index, local_positions, world_positions, densities, samples),
            desired,
            volume_context
        )
    elif solid_indices.size() == 2 and air_indices.size() == 2:
        var desired := average_world_positions(air_indices, world_positions) - average_world_positions(solid_indices, world_positions)
        var p00 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[0], local_positions, world_positions, densities, samples)
        var p10 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[0], local_positions, world_positions, densities, samples)
        var p11 := interpolate_volume_iso_edge_fast(solid_indices[1], air_indices[1], local_positions, world_positions, densities, samples)
        var p01 := interpolate_volume_iso_edge_fast(solid_indices[0], air_indices[1], local_positions, world_positions, densities, samples)
        add_volume_iso_triangle_oriented_fast(st, p00, p10, p11, desired, volume_context)
        add_volume_iso_triangle_oriented_fast(st, p00, p11, p01, desired, volume_context)

func volume_air_indices_need_iso_surface(air_indices: Array[int], samples: Array[Dictionary], world_positions: Array[Vector3]) -> bool:
    for index in air_indices:
        var sample: Dictionary = samples[index]
        if String(sample.get("biome", "")) == "underground_air":
            return true
        var world := world_positions[index]
        var surface_y := float(sample.get("surfaceY", chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
        if world.y < surface_y - CELL * 0.35:
            return true
    return false

func average_world_positions(indices: Array[int], world_positions: Array[Vector3]) -> Vector3:
    var total := Vector3.ZERO
    for index in indices:
        total += world_positions[index]
    return total / maxf(1.0, float(indices.size()))

func interpolate_volume_iso_edge_fast(
    solid_index: int,
    air_index: int,
    local_positions: Array[Vector3],
    world_positions: Array[Vector3],
    densities: PackedFloat32Array,
    samples: Array[Dictionary]
) -> Array:
    var da := float(densities[solid_index])
    var db := float(densities[air_index])
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    return [
        local_positions[solid_index].lerp(local_positions[air_index], t),
        world_positions[solid_index].lerp(world_positions[air_index], t),
        samples[solid_index],
        samples[air_index]
    ]

func add_volume_iso_triangle_oriented_fast(st: SurfaceTool, a: Array, b: Array, c: Array, desired_normal: Vector3, volume_context := {}) -> void:
    var a_local: Vector3 = a[0]
    var b_local: Vector3 = b[0]
    var c_local: Vector3 = c[0]
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap := b
        b = c
        c = swap
        cross = -cross
    var normal := cross.normalized()
    add_volume_iso_vertex_fast(st, a, normal, volume_context)
    add_volume_iso_vertex_fast(st, b, normal, volume_context)
    add_volume_iso_vertex_fast(st, c, normal, volume_context)

func add_volume_iso_vertex_fast(st: SurfaceTool, point: Array, normal: Vector3, volume_context := {}) -> void:
    var world: Vector3 = point[1]
    var solid_sample: Dictionary = point[2]
    var air_sample: Dictionary = point[3]
    st.set_normal(normal)
    st.set_color(volume_iso_vertex_color_fast(world, solid_sample, air_sample, normal, volume_context))
    st.add_vertex(point[0])

func volume_iso_vertex_color_fast(world: Vector3, solid_sample: Dictionary, air_sample: Dictionary, normal: Vector3, volume_context := {}) -> Color:
    var shade := volume_iso_shade(world)
    var air_biome_is_underground := String(air_sample.get("biome", "")) == "underground_air"
    if air_biome_is_underground:
        shade *= underground_wall_visual_shade(world)
        if normal.y < -0.35:
            return Color(0.055, 0.060, 0.060) * shade
        if normal.y > 0.35:
            return Color(0.150, 0.158, 0.142) * shade
        return Color(0.170, 0.182, 0.170) * shade
    var solid_cell: Vector3i = solid_sample.get("cell", Vector3i(world_to_cell(world.x), world_to_cell(world.y), world_to_cell(world.z)))
    var surface_cell := Vector3i(solid_cell.x, 0, solid_cell.z)
    var solid_surface_y := float(solid_sample.get("surfaceY", volume_context_surface_y_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(surface_cell)))
    var solid_density := float(solid_sample.get("density", solid_surface_y - world.y))
    var biome := String(solid_sample.get("biome", ""))
    if biome == "":
        biome = volume_context_surface_biome_at_cell(solid_cell.x, solid_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(surface_cell)
    var material_id := String(solid_sample.get("material", ""))
    if material_id == "":
        material_id = volume_material_from_components(world, solid_cell, solid_density, solid_surface_y, biome)
    if material_id == "air":
        var inside_sample := volume_sample_world(world - normal * CELL * 0.18, volume_context)
        var inside_cell: Vector3i = inside_sample.get("cell", solid_cell)
        var inside_surface_cell := Vector3i(inside_cell.x, 0, inside_cell.z)
        var inside_surface_y := float(inside_sample.get("surfaceY", volume_context_surface_y_at_cell(inside_cell.x, inside_cell.z, volume_context) if not volume_context.is_empty() else chunk_bound_surface_y_at_cell(inside_surface_cell)))
        var inside_density := float(inside_sample.get("density", inside_surface_y - world.y))
        biome = String(inside_sample.get("biome", ""))
        if biome == "":
            biome = volume_context_surface_biome_at_cell(inside_cell.x, inside_cell.z, volume_context) if not volume_context.is_empty() else surface_biome_at_cell(inside_surface_cell)
        material_id = String(inside_sample.get("material", ""))
        if material_id == "":
            material_id = volume_material_from_components(world, inside_cell, inside_density, inside_surface_y, biome)
    if normal.y > 0.42 and material_id in ["grass", "mud", "snow"]:
        return BIOME_COLORS.get(biome, BIOME_COLORS["plains"]) * shade
    match material_id:
        "sand":
            return Color(0.62, 0.57, 0.42) * shade
        "mud":
            return Color(0.30, 0.35, 0.25) * shade
        "snow":
            return Color(0.77, 0.82, 0.82) * shade
        "dirt":
            return Color(0.32, 0.27, 0.18) * shade
        "copperOre":
            return Color(0.48, 0.30, 0.20) * shade
        "ironOre":
            return Color(0.40, 0.39, 0.36) * shade
        _:
            return Color(0.36, 0.38, 0.35) * shade

func volume_iso_shade(world: Vector3) -> float:
    var key := Vector3i(roundi(world.x * 9.0), roundi(world.y * 9.0), roundi(world.z * 9.0))
    return 0.88 + float(absi(hash(key)) % 100000) / 100000.0 * 0.16

func underground_wall_visual_shade(world: Vector3) -> float:
    if ridge_noise == null:
        return 1.0
    var broad := ridge_noise.get_noise_3d(world.x * 5.5 + 4100.0, world.y * 7.0 - 2300.0, world.z * 5.5 + 1700.0)
    var fine := ridge_noise.get_noise_3d(world.x * 13.0 - 7200.0, world.y * 11.0 + 3300.0, world.z * 13.0 - 5100.0)
    return clampf(0.96 + broad * 0.08 + fine * 0.035, 0.82, 1.12)

func extract_volume_iso_tetrahedron(st: SurfaceTool, tetra: Array) -> void:
    var solid_corners := []
    var air_corners := []
    for corner in tetra:
        if bool(corner.get("solid", false)):
            solid_corners.append(corner)
        else:
            air_corners.append(corner)
    if solid_corners.is_empty() or air_corners.is_empty():
        return
    if not volume_air_corners_need_iso_surface(air_corners):
        return
    if solid_corners.size() == 1:
        var solid: Dictionary = solid_corners[0]
        var desired := average_corner_world(air_corners) - (solid.get("world", Vector3.ZERO) as Vector3)
        add_volume_iso_triangle_oriented(
            st,
            interpolate_volume_iso_edge(solid, air_corners[0]),
            interpolate_volume_iso_edge(solid, air_corners[1]),
            interpolate_volume_iso_edge(solid, air_corners[2]),
            desired
        )
    elif solid_corners.size() == 3:
        var air: Dictionary = air_corners[0]
        var desired := (air.get("world", Vector3.ZERO) as Vector3) - average_corner_world(solid_corners)
        add_volume_iso_triangle_oriented(
            st,
            interpolate_volume_iso_edge(solid_corners[0], air),
            interpolate_volume_iso_edge(solid_corners[1], air),
            interpolate_volume_iso_edge(solid_corners[2], air),
            desired
        )
    elif solid_corners.size() == 2 and air_corners.size() == 2:
        var desired := average_corner_world(air_corners) - average_corner_world(solid_corners)
        var p00 := interpolate_volume_iso_edge(solid_corners[0], air_corners[0])
        var p10 := interpolate_volume_iso_edge(solid_corners[1], air_corners[0])
        var p11 := interpolate_volume_iso_edge(solid_corners[1], air_corners[1])
        var p01 := interpolate_volume_iso_edge(solid_corners[0], air_corners[1])
        add_volume_iso_triangle_oriented(st, p00, p10, p11, desired)
        add_volume_iso_triangle_oriented(st, p00, p11, p01, desired)

func average_corner_world(corners: Array) -> Vector3:
    var total := Vector3.ZERO
    for corner in corners:
        total += corner.get("world", Vector3.ZERO)
    return total / maxf(1.0, float(corners.size()))

func volume_air_corners_need_iso_surface(air_corners: Array) -> bool:
    for corner in air_corners:
        var sample: Dictionary = corner.get("sample", {})
        if String(sample.get("biome", "")) == "underground_air":
            return true
        var world: Vector3 = corner.get("world", Vector3.ZERO)
        var surface_y := chunk_bound_surface_y_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))
        if world.y < surface_y - CELL * 0.35:
            return true
    return false

func interpolate_volume_iso_edge(a: Dictionary, b: Dictionary) -> Dictionary:
    var da := float(a.get("density", 0.0))
    var db := float(b.get("density", 0.0))
    var t := 0.5
    var denominator := da - db
    if absf(denominator) > 0.0001:
        t = clampf(da / denominator, 0.0, 1.0)
    var local: Vector3 = (a.get("local", Vector3.ZERO) as Vector3).lerp(b.get("local", Vector3.ZERO) as Vector3, t)
    var world: Vector3 = (a.get("world", Vector3.ZERO) as Vector3).lerp(b.get("world", Vector3.ZERO) as Vector3, t)
    var a_sample: Dictionary = a.get("sample", {})
    var b_sample: Dictionary = b.get("sample", {})
    var solid_sample := a_sample if bool(a.get("solid", false)) else b_sample
    var air_sample := b_sample if bool(a.get("solid", false)) else a_sample
    return {
        "local": local,
        "world": world,
        "solidSample": solid_sample,
        "airSample": air_sample
    }

func add_volume_iso_triangle_oriented(st: SurfaceTool, a: Dictionary, b: Dictionary, c: Dictionary, desired_normal: Vector3) -> void:
    var a_local: Vector3 = a.get("local", Vector3.ZERO)
    var b_local: Vector3 = b.get("local", Vector3.ZERO)
    var c_local: Vector3 = c.get("local", Vector3.ZERO)
    var cross := (b_local - a_local).cross(c_local - a_local)
    if cross.length_squared() <= 0.000001:
        return
    if desired_normal.length_squared() <= 0.0001:
        desired_normal = cross.normalized()
    else:
        desired_normal = desired_normal.normalized()
    if cross.normalized().dot(desired_normal) < 0.0:
        var swap := b
        b = c
        c = swap
        cross = -cross
    var normal := cross.normalized()
    add_volume_iso_vertex(st, a, normal)
    add_volume_iso_vertex(st, b, normal)
    add_volume_iso_vertex(st, c, normal)

func add_volume_iso_vertex(st: SurfaceTool, point: Dictionary, normal: Vector3) -> void:
    st.set_normal(normal)
    st.set_color(volume_iso_vertex_color(point, normal))
    st.add_vertex(point.get("local", Vector3.ZERO))

func active_volume_excavation_brushes() -> Array:
    if world_generation_system == null:
        return []
    if world_generation_system.get("terrain_volume_service") != null:
        return []
    var brush_values = world_generation_system.get("excavation_brushes")
    if not (brush_values is Array):
        return []
    var result := []
    for brush_value in brush_values:
        if not (brush_value is Dictionary):
            continue
        var brush: Dictionary = brush_value
        if excavation_brush_is_surface_deformation(brush):
            continue
        result.append(brush)
    return result

func excavation_brush_is_surface_deformation(brush: Dictionary) -> bool:
    var mode := String(brush.get("mode", ""))
    if mode == "surface_deform":
        return true
    if mode == "volume":
        return false
    if brush.has("surfaceTargetY") or brush.has("deformRadius"):
        return true
    if world_generation_system != null and world_generation_system.has_method("brush_is_surface_deformation"):
        return bool(world_generation_system.call("brush_is_surface_deformation", brush))
    return false

func volume_sample_from_context(position: Vector3, sample_cell: Vector3i, volume_context: Dictionary) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        return world_generation_system.call("sample_world", position)
    var surface_y := volume_context_surface_y_at_cell(sample_cell.x, sample_cell.z, volume_context)
    var density := surface_y - position.y
    return {
        "cell": sample_cell,
        "position": position,
        "solid": density >= 0.0,
        "density": density,
        "surface": absf(density) <= CELL * 0.75,
        "biome": surface_biome_at_cell(Vector3i(sample_cell.x, 0, sample_cell.z)),
        "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(sample_cell.x, 0, sample_cell.z)),
        "surfaceY": surface_y
    }

func volume_context_surface_y_at_cell(cell_x: int, cell_z: int, volume_context: Dictionary) -> float:
    var cache_value = volume_context.get("surfaceY", null)
    if not (cache_value is Dictionary):
        cache_value = {}
        volume_context["surfaceY"] = cache_value
    var cache: Dictionary = cache_value
    var key := Vector2i(cell_x, cell_z)
    if cache.has(key):
        return float(cache[key])
    var value := chunk_bound_surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    cache[key] = value
    return value

func volume_context_surface_biome_at_cell(cell_x: int, cell_z: int, volume_context: Dictionary) -> String:
    var cache_value = volume_context.get("surfaceBiome", null)
    if not (cache_value is Dictionary):
        cache_value = {}
        volume_context["surfaceBiome"] = cache_value
    var cache: Dictionary = cache_value
    var key := Vector2i(cell_x, cell_z)
    if cache.has(key):
        return String(cache[key])
    var biome := surface_biome_at_cell(Vector3i(cell_x, 0, cell_z))
    cache[key] = biome
    return biome

func volume_material_from_components(position: Vector3, sample_cell: Vector3i, density: float, surface_y: float, biome: String) -> String:
    if density < 0.0:
        return "air"
    var depth := maxf(0.0, surface_y - position.y)
    if depth <= CELL * 1.20:
        return volume_top_material_for_biome(biome)
    if depth <= CELL * 4.65:
        return volume_subsoil_material_for_biome(biome)
    var deep_ore := volume_ore_material_at(sample_cell, depth)
    return deep_ore if deep_ore != "" else "stone"

func volume_top_material_for_biome(biome: String) -> String:
    if biome == "beach" or biome == "desert":
        return "sand"
    if biome == "swamp":
        return "mud"
    if biome == "snow":
        return "snow"
    if biome == "alpine" or biome == "tundra":
        return "stone"
    return "grass"

func volume_subsoil_material_for_biome(biome: String) -> String:
    if biome == "beach" or biome == "desert":
        return "sand"
    if biome == "swamp":
        return "mud"
    if biome == "snow":
        return "snow"
    return "dirt"

func volume_ore_material_at(sample_cell: Vector3i, depth: float) -> String:
    var depth_cells := depth / maxf(0.001, CELL)
    var copper_noise := hash01("subsurface-copper:%s:%d,%d,%d" % [
        String(seed_text),
        int(sample_cell.x / 3),
        int(sample_cell.y / 3),
        int(sample_cell.z / 3)
    ])
    if depth_cells >= 8.0 and copper_noise > 0.985:
        return "copperOre"
    var iron_noise := hash01("subsurface-iron:%s:%d,%d,%d" % [
        String(seed_text),
        int(sample_cell.x / 4),
        int(sample_cell.y / 4),
        int(sample_cell.z / 4)
    ])
    if depth_cells >= 15.0 and iron_noise > 0.992:
        return "ironOre"
    return ""

func volume_density_at_world(position: Vector3) -> float:
    if world_generation_system != null and world_generation_system.has_method("density_at"):
        return float(world_generation_system.call("density_at", position))
    return surface_y_at_position(position) - position.y

func volume_sample_world(position: Vector3, volume_context := {}) -> Dictionary:
    if not volume_context.is_empty():
        var cell := Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z))
        return volume_sample_from_context(position, cell, volume_context)
    if world_generation_system != null and world_generation_system.has_method("sample_world"):
        return world_generation_system.call("sample_world", position)
    var density := volume_density_at_world(position)
    return {
        "cell": Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z)),
        "position": position,
        "solid": density >= 0.0,
        "biome": surface_biome_at_cell(Vector3i(world_to_cell(position.x), 0, world_to_cell(position.z))),
        "material": "air" if density < 0.0 else surface_material_at_cell(Vector3i(world_to_cell(position.x), 0, world_to_cell(position.z))),
        "density": density
    }

func volume_iso_vertex_color(point: Dictionary, normal: Vector3) -> Color:
    var solid_sample: Dictionary = point.get("solidSample", {})
    var air_sample: Dictionary = point.get("airSample", {})
    var world: Vector3 = point.get("world", Vector3.ZERO)
    var material_id := String(solid_sample.get("material", "stone"))
    if material_id == "air":
        var inside_sample := volume_sample_world(world - normal * CELL * 0.18)
        material_id = String(inside_sample.get("material", "stone"))
        solid_sample = inside_sample
    var air_biome := String(air_sample.get("biome", ""))
    var biome := String(solid_sample.get("biome", surface_biome_at_cell(Vector3i(world_to_cell(world.x), 0, world_to_cell(world.z)))))
    var shade := volume_iso_shade(world)
    if air_biome == "underground_air":
        shade *= underground_wall_visual_shade(world)
        return volume_material_surface_color(material_id, biome, normal, shade, true)
    return volume_material_surface_color(material_id, biome, normal, shade, false)

func spawn_chunk_props(chunk: Node3D, cx: int, cz: int) -> void:
    var state := begin_chunk_prop_spawn_state(chunk, cx, cz)
    while not process_chunk_prop_spawn_state(state, 28, 999999):
        if state.get("naturalPropAdmission", {}).get("status", "ready") != "ready":
            # Synchronous callers must yield pending/failed admission to the
            # same retry queue, retaining the untouched RNG and attempt state.
            pending_chunk_prop_spawns[Vector2i(cx, cz)] = state
            return

func begin_chunk_prop_spawn_state(chunk: Node3D, cx: int, cz: int) -> Dictionary:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:props:%d,%d" % [seed_text, cx, cz])
    var underground_rng := RandomNumberGenerator.new()
    underground_rng.seed = hash_string("%s:underground-props:%d,%d" % [seed_text, cx, cz])
    var detail_rng := RandomNumberGenerator.new()
    detail_rng.seed = hash_string("%s:details:%d,%d" % [seed_text, cx, cz])
    var source_ledger = EcologySourceValueLedgerScript.new()
    var terrain_revision := -1
    if world_generation_system != null and world_generation_system.has_method("terrain_volume_chunk_revision"):
        terrain_revision = int(world_generation_system.call("terrain_volume_chunk_revision",
            Vector2i(cx, cz), CHUNK_SIZE))
    source_ledger.configure(seed_text, Vector2i(cx, cz),
        _ecology_chunk_source_revision(Vector2i(cx, cz)),
        int(removed_props_revision), terrain_revision)
    if chunk != null and is_instance_valid(chunk):
        chunk.remove_meta("static_ecology_source_value_snapshot")
        chunk.set_meta("static_ecology_source_value_ledger", source_ledger)
    return {
        "chunk": chunk,
        "cx": cx,
        "cz": cz,
        "startX": cx * CHUNK_SIZE,
        "startZ": cz * CHUNK_SIZE,
        "rng": rng,
        "undergroundRng": underground_rng,
        "propIndex": 0,
        "undergroundIndex": 0,
        "undergroundCandidates": [],
        "undergroundScanColumn": 0,
        "undergroundScanY": 0,
        "undergroundScanColumnStarted": false,
        "undergroundScanComplete": false,
        "phase": "props",
        "detailRng": detail_rng,
        "detailIndex": 0,
        "detailAttempts": -1,
        "detailActiveAttempt": {},
        "detailBatches": {},
        "detailBatchKeys": [],
        "detailBatchIndex": 0,
        "detailBatchRoot": null,
        "detailSourceRowsAppendedToPass": false,
        "ecologySourceLedger": source_ledger
    }

func _record_ecology_source_value(chunk: Node, candidate: Dictionary) -> bool:
    if chunk == null or not is_instance_valid(chunk):
        return false
    var ledger = chunk.get_meta("static_ecology_source_value_ledger", null)
    if ledger == null or not ledger.has_method("record_candidate"):
        return false
    var prop_id := String(candidate.get("propId", ""))
    if not prop_id.is_empty() and removed_props.has(prop_id):
        var source_id := String(candidate.get("sourceId", ""))
        return bool(ledger.call("record_tombstone", source_id, "removed_props"))
    return bool(ledger.call("record_candidate", candidate))


## Called by prop creators with the meshes/materials they have just built. The
## creator passes each member as it is made; this helper never inspects a Node
## subtree and never asks the RNG for another value.
func ecology_render_member(member_id: String, mesh: Mesh, local_transform: Transform3D,
        material_key: String, render_layer: String, material: Material = null,
        fingerprint_cache: Dictionary = {}) -> Dictionary:
    if member_id.is_empty() or not is_instance_valid(mesh) or not local_transform.is_finite():
        return {"status":"pending", "reason":"realized_prop_mesh_unavailable",
            "memberId":member_id}
    var fingerprint: Dictionary = _ecology_cached_resource_fingerprint(
        mesh, fingerprint_cache, "mesh")
    if fingerprint.get("status") != "ready":
        return {"status":"pending", "reason":String(fingerprint.get("reason", "mesh_fingerprint_pending")),
            "memberId":member_id}
    var captured_layer := render_layer
    var pending_reason := ""
    var material_digest := String(_ecology_cached_resource_fingerprint(
        material, fingerprint_cache, "material").get("contentDigest", "")) \
        if is_instance_valid(material) else ""
    if material_digest.is_empty():
        pending_reason = "prop_material_content_digest_unavailable"
    if material is BaseMaterial3D:
        match material.transparency:
            BaseMaterial3D.TRANSPARENCY_DISABLED:
                captured_layer = "opaque"
            BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
                captured_layer = "cutout"
            _:
                captured_layer = "translucent"
                pending_reason = "translucent_prop_layer_sort_unavailable"
    elif material is ShaderMaterial:
        var shader := (material as ShaderMaterial).shader
        if shader != null and not shader.code.is_empty() \
                and not shader.code.contains("ALPHA") \
                and not shader.code.contains("discard") \
                and not shader.code.contains("blend_"):
            captured_layer = "opaque"
        else:
            captured_layer = ""
            pending_reason = "shader_prop_render_semantics_unsupported"
    else:
        captured_layer = ""
        pending_reason = "unsupported_material_render_semantics"
    var result := {"status":"ready" if pending_reason.is_empty() else "pending",
        "reason":pending_reason, "memberId":member_id,
        "meshContentDigest":String(fingerprint.contentDigest),
        "meshSchema":String(fingerprint.schema), "meshCpuArrayBytes":int(fingerprint.cpuArrayBytes),
        "meshBounds":mesh.get_aabb(), "transform":local_transform,
        "localBounds":local_transform * mesh.get_aabb(),
        "materialKey":material_key, "materialClass":material.get_class() if is_instance_valid(material) else "missing",
        "materialContentDigest":material_digest, "renderLayer":captured_layer,
        "_meshResource":mesh, "_materialResource":material}
    return result


func _record_realized_ecology_prop(parent: Node, body: StaticBody3D,
        source_kind: String, members: Array, pending_reason := "") -> bool:
    if parent == null or not is_instance_valid(parent) or not is_instance_valid(body):
        return false
    var context_value: Variant = parent.get_meta("ecology_capture_context", {})
    if not context_value is Dictionary or context_value.is_empty():
        return false
    var context: Dictionary = context_value
    var category := String(context.get("category", ""))
    var chunk_key := Vector2i(int(context.get("chunkX", 0)), int(context.get("chunkZ", 0)))
    var prop_id := String(body.get_meta("prop_id", ""))
    if prop_id.is_empty() or category.is_empty():
        return false
    var source_id := "%s:%s:%s" % [seed_text, category, prop_id]
    var source_revision := _ecology_chunk_source_revision(chunk_key)
    var scan_revision := String(context.get("scanRevision", ""))
    var provenance := {"producer":String(context.get("producer", "")),
        "chunk":chunk_key, "sourceRevision":source_revision,
        "terrainRevision":int(context.get("terrainRevision", -1)),
        "attemptIndex":int(context.get("attemptIndex", -1)),
        "sourceCell":context.get("sourceCell", Vector3i.ZERO),
        "scanRevision":scan_revision, "creatorOutputComplete":true}
    var ready_members: Array[Dictionary] = []
    var pending_members: Array[Dictionary] = []
    var resource_bindings: Dictionary = parent.get_meta("static_ecology_render_resource_bindings", {}) \
        if parent.has_meta("static_ecology_render_resource_bindings") else {}
    resource_bindings = resource_bindings.duplicate(false)
    for member_value: Variant in members:
        if member_value is Dictionary and member_value.get("status") == "ready":
            var member: Dictionary = member_value.duplicate(true)
            var mesh_resource: Variant = member.get("_meshResource", null)
            var material_resource: Variant = member.get("_materialResource", null)
            if mesh_resource is Mesh and material_resource is Material:
                var binding := {
                    "mesh":mesh_resource, "material":material_resource,
                    "meshContentDigest":String(member.get("meshContentDigest", "")),
                    "materialContentDigest":String(member.get("materialContentDigest", "")),
                    "materialKey":String(member.get("materialKey", "")),
                    "renderLayer":String(member.get("renderLayer", ""))}
                binding.make_read_only()
                resource_bindings[source_id + "|" + String(member.get("memberId", ""))] = binding
            else:
                member["status"] = "pending"
                member["reason"] = "realized_prop_resource_binding_missing"
            member.erase("_meshResource")
            member.erase("_materialResource")
            if member.get("status") == "ready":
                ready_members.append(member)
            else:
                pending_members.append(member)
        elif member_value is Dictionary:
            pending_members.append(member_value)
    resource_bindings.make_read_only()
    parent.set_meta("static_ecology_render_resource_bindings", resource_bindings)
    var candidate := {"sourceId":source_id, "propId":prop_id,
        "kind":"realized_static_prop", "category":category,
        "sourceKind":source_kind, "chunk":chunk_key,
        "transform":body.transform, "renderMembers":ready_members,
        "renderStatus":"ready" if pending_reason.is_empty() and ready_members.size() == members.size() \
            else "pending",
        "missingMembers":pending_members,
        "pendingReason":pending_reason, "provenance":provenance}
    var producer_value: Variant = body.get_meta("static_ecology_source_recipe", {})
    if producer_value is Dictionary and not producer_value.is_empty():
        candidate["producerValue"] = producer_value.duplicate(true)
    if members.is_empty() or ready_members.size() != members.size():
        candidate["pendingReason"] = pending_reason if not pending_reason.is_empty() \
            else "realized_prop_member_recipe_missing"
    var bounds := AABB()
    var have_bounds := false
    var world_bounds := AABB()
    var have_world_bounds := false
    for member in ready_members:
        # ecology_render_member has already transformed the raw mesh AABB into
        # body-local space. Keep this union body-local for the source value.
        var member_bounds: AABB = member.localBounds
        bounds = member_bounds if not have_bounds else bounds.merge(member_bounds)
        have_bounds = true
        var raw_mesh_bounds: Variant = member.get("meshBounds", null)
        var member_transform: Variant = member.get("transform", null)
        if not raw_mesh_bounds is AABB or not member_transform is Transform3D:
            return false
        var expected_local_bounds: AABB = (member_transform as Transform3D) \
            * (raw_mesh_bounds as AABB)
        if not expected_local_bounds.is_equal_approx(member_bounds):
            return false
        var member_world_transform := body.global_transform * (member_transform as Transform3D)
        var member_world_bounds: AABB = member_world_transform * (raw_mesh_bounds as AABB)
        world_bounds = member_world_bounds if not have_world_bounds \
            else world_bounds.merge(member_world_bounds)
        have_world_bounds = true
    candidate["localBounds"] = bounds if have_bounds else AABB(body.position, Vector3.ZERO)
    body.set_meta("static_ecology_source_id", source_id)
    if have_bounds and have_world_bounds:
        body.set_meta("static_ecology_source_bounds", world_bounds)
        var recorded := _record_ecology_source_value(parent, candidate)
        if recorded:
            var section_coordinator: Variant = get("world_static_section_coordinator")
            if section_coordinator != null \
                    and section_coordinator.has_method("invalidate_visible_static_source"):
                section_coordinator.call("invalidate_visible_static_source",
                    "ecology_and_static_props", source_id, source_revision, world_bounds)
        return recorded
    return _record_ecology_source_value(parent, candidate)


func _mark_ecology_category_complete(state: Dictionary, category: String,
        producer: String, scan_revision := "") -> bool:
    var ledger: Variant = state.get("ecologySourceLedger", null)
    if ledger == null or not ledger.has_method("mark_category_complete"):
        return false
    var key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    var terrain_revision := -1
    if ledger != null:
        terrain_revision = int(ledger.get("terrain_revision"))
    return bool(ledger.call("mark_category_complete", category, {
        "producer":producer, "chunk":key,
        "sourceRevision":_ecology_chunk_source_revision(key),
        "terrainRevision":terrain_revision, "scanRevision":scan_revision,
        "producerComplete":true}))


func _ecology_capture_context(state: Dictionary, producer: String, category: String,
        attempt_index: int, source_cell: Vector3i, scan_revision := "") -> Dictionary:
    var key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    var terrain_revision := -1
    var ledger: Variant = state.get("ecologySourceLedger")
    if ledger != null:
        terrain_revision = int(ledger.get("terrain_revision"))
    return {"producer":producer, "category":category, "chunkX":key.x, "chunkZ":key.y,
        "terrainRevision":terrain_revision, "attemptIndex":attempt_index,
        "sourceCell":source_cell, "scanRevision":scan_revision}


func _underground_prop_scan_revision(state: Dictionary) -> String:
    if not bool(state.get("undergroundScanComplete", false)) or world_generation_system == null:
        return ""
    var service_scan: Variant = state.get("undergroundVolumeFloorScan", {})
    if service_scan is Dictionary and not str(service_scan.get("revision", "")).is_empty():
        return str(service_scan.revision)
    if not world_generation_system.has_method("sample_cell"):
        return ""
    var key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    var candidates: Array = state.get("undergroundCandidates", []) \
        if state.get("undergroundCandidates", []) is Array else []
    var rows: Array = []
    for cell_value: Variant in candidates:
        if cell_value is Vector3i:
            var cell: Vector3i = cell_value
            rows.append([cell.x, cell.y, cell.z])
    var source := _ecology_chunk_source_revision(key)
    return "sample-cell-scan:%s:%s" % [source, JSON.stringify(rows).sha256_text()]

func _finalize_ecology_source_values(state: Dictionary) -> void:
    var ledger = state.get("ecologySourceLedger")
    if ledger == null or not ledger.has_method("snapshot"):
        return
    var removed: Dictionary = removed_props if removed_props is Dictionary else {}
    if ledger.has_method("apply_removed_props"):
        ledger.call("apply_removed_props", removed, int(removed_props_revision))
    var snapshot: Dictionary = ledger.call("snapshot")
    var key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    snapshot["status"] = "ready" if String(snapshot.get("sourceRevision", "")) == \
        _ecology_chunk_source_revision(key) else "stale"
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk != null and is_instance_valid(chunk):
        snapshot["producerOwnerInstanceId"] = chunk.get_instance_id()
        chunk.remove_meta("static_ecology_source_value_ledger")
        chunk.set_meta("static_ecology_source_value_snapshot", snapshot.duplicate(true))


## Seal a value copy of the completed surface families without sealing the
## producer ledger; underground discovery continues in the same deterministic
## state and will replace this snapshot only when its scan is complete.
func _publish_surface_ecology_source_values(state: Dictionary) -> void:
    var ledger = state.get("ecologySourceLedger")
    if ledger == null or not ledger.has_method("snapshot"):
        return
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    if chunk == null or not is_instance_valid(chunk):
        return
    var existing_value: Variant = chunk.get_meta("static_ecology_source_value_snapshot", {})
    if existing_value is Dictionary \
            and String(existing_value.get("contentScope", "")) == "surface_pending_underground" \
            and String(existing_value.get("sourceRevision", "")) == _ecology_chunk_source_revision(
                Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))) \
            and int(existing_value.get("removedPropsRevision", -1)) == int(removed_props_revision):
        return
    var snapshot: Dictionary = ledger.call("snapshot", false, "surface_pending_underground")
    var key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    snapshot["status"] = "ready" if String(snapshot.get("sourceRevision", "")) == \
        _ecology_chunk_source_revision(key) else "stale"
    snapshot["producerOwnerInstanceId"] = chunk.get_instance_id()
    chunk.set_meta("static_ecology_source_value_snapshot", snapshot.duplicate(true))

func _ecology_chunk_source_revision(key: Vector2i) -> String:
    # Physical ecology source identity follows its chunk producer owner and
    # content snapshot, not terrain edits. Terrain provenance is retained in
    # the snapshot and the section candidate carries terrain's own revision.
    return "ecology-v2:%s:%d,%d:static-props-v1" % [seed_text, key.x, key.y]


## The canonical nonresident producer entry point. Until every deterministic
## producer has a value-only pass and every support policy is enforced, this
## returns a sealed production dependency failure; it never treats a missing
## resident chunk or source snapshot as an authoritative empty domain.
func capture_ecology_source_domain(world_id: String, source_chunk_key: Vector2i,
        world_seed: String, source_inputs: Dictionary,
        removed_props_snapshot: Dictionary, catalog_lease_token := "",
        family_request: Dictionary = {}) -> Dictionary:
    _ecology_source_capture_last_call_timings.clear()
    var started_usec := Time.get_ticks_usec()
    var result: Dictionary = _capture_ecology_source_domain_impl(world_id,
        source_chunk_key, world_seed, source_inputs, removed_props_snapshot,
        catalog_lease_token, family_request)
    _record_ecology_source_capture_phase("capture_call",
        Time.get_ticks_usec() - started_usec)
    if String(result.get("status", "")) == "pending" and not result.is_read_only():
        var response := result.duplicate(false)
        if not response.has("captureDisposition"):
            response["captureDisposition"] = "dependency_blocked"
        response["captureTimings"] = ecology_source_capture_last_timing_snapshot()
        return response
    return result


## Recipe-local reuse only: each caller builds one synchronous candidate from
## resources that it just created or already owns. Hold a strong reference in
## the cache and key by instance ID so recycled IDs cannot reuse an old digest.
## Cross-call reuse would need the registry's revision/currentness lease.
func _ecology_cached_resource_fingerprint(resource: Resource,
        fingerprint_cache: Dictionary, kind: String) -> Dictionary:
    if not is_instance_valid(resource):
        return {"status":"failed", "reason":"resource_unavailable"}
    var cache: Dictionary = fingerprint_cache.get(kind, {}) \
        if fingerprint_cache.get(kind, {}) is Dictionary else {}
    var stats: Dictionary = fingerprint_cache.get("stats", {}) \
        if fingerprint_cache.get("stats", {}) is Dictionary else {}
    var instance_id := resource.get_instance_id()
    var cached_value: Variant = cache.get(instance_id, null)
    if cached_value is Dictionary and cached_value.get("resource", null) == resource:
        if kind == "mesh":
            stats["meshHits"] = int(stats.get("meshHits", 0)) + 1
        else:
            stats["materialHits"] = int(stats.get("materialHits", 0)) + 1
        fingerprint_cache["stats"] = stats
        return (cached_value.get("fingerprint", {}) as Dictionary).duplicate(false)
    var fingerprint: Dictionary
    if kind == "mesh":
        fingerprint = EcologyMeshFingerprintScript.inspect(resource as Mesh)
        stats["meshMisses"] = int(stats.get("meshMisses", 0)) + 1
    else:
        fingerprint = EcologyStaticMaterialFingerprintScript.inspect(resource as Material)
        stats["materialMisses"] = int(stats.get("materialMisses", 0)) + 1
    cache[instance_id] = {"resource":resource, "fingerprint":fingerprint.duplicate(false)}
    fingerprint_cache[kind] = cache
    fingerprint_cache["stats"] = stats
    return fingerprint


func _trace_ecology_fingerprint_cache(family: String, prop_id: String,
        fingerprint_cache: Dictionary) -> void:
    if OS.get_environment("VOXEL_ECOLOGY_SOURCE_TRACE") != "1":
        return
    var stats: Dictionary = fingerprint_cache.get("stats", {}) \
        if fingerprint_cache.get("stats", {}) is Dictionary else {}
    print("ECOLOGY_RECIPE_FINGERPRINT_CACHE family=%s prop=%s mesh=%d/%d material=%d/%d" % [
        family, prop_id, int(stats.get("meshHits", 0)), int(stats.get("meshMisses", 0)),
        int(stats.get("materialHits", 0)), int(stats.get("materialMisses", 0))])


func _capture_ecology_source_domain_impl(world_id: String, source_chunk_key: Vector2i,
        world_seed: String, source_inputs: Dictionary,
        removed_props_snapshot: Dictionary, catalog_lease_token := "",
        family_request: Dictionary = {}) -> Dictionary:
    var local_validation_started_usec := Time.get_ticks_usec()
    var artifact_result := _resolve_ecology_source_artifact(source_inputs,
        catalog_lease_token)
    _record_ecology_source_capture_phase("lease_resolution",
        Time.get_ticks_usec() - local_validation_started_usec)
    if String(artifact_result.get("status", "")) != "ready":
        var artifact_status := String(artifact_result.get("status", "pending"))
        if artifact_status in ["failed", "stale"]:
            var artifact_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
                source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
                catalog_lease_token, "failed")
            if String(artifact_retirement.get("status", "")) != "ready":
                return artifact_retirement
        return {"status":"pending" if artifact_status == "stale" else artifact_status,
            "reason":String(artifact_result.get("reason",
                "ecology_catalog_artifact_pending")), "sourceChunkKey":source_chunk_key,
            "retryable":artifact_status in ["pending", "stale"]}
    var catalog_artifact: Dictionary = artifact_result.artifact
    var live_scope := _active_ecology_catalog_artifact(world_id, world_seed)
    if String(live_scope.get("status", "")) != "ready":
        if String(live_scope.get("status", "pending")) in ["failed", "stale"]:
            var live_scope_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
                source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
                catalog_lease_token, "failed")
            if String(live_scope_retirement.get("status", "")) != "ready":
                return live_scope_retirement
        return live_scope
    if String(live_scope.get("artifactId", "")) != String(catalog_artifact.get("artifactId", "")):
        return _stale_ecology_source_domain(world_id, source_chunk_key, source_inputs,
            removed_props_snapshot, "ecology_source_catalog_artifact_stale",
            String(source_inputs.get("catalogArtifactId", "")),
            String(live_scope.get("artifactId", "")), catalog_artifact,
            catalog_lease_token)
    var admitted_inputs := source_inputs
    local_validation_started_usec = Time.get_ticks_usec()
    source_inputs = _ecology_source_capture_inputs(world_id, source_chunk_key,
        world_seed, source_inputs, catalog_artifact)
    _record_ecology_source_capture_phase("local_input_capture",
        Time.get_ticks_usec() - local_validation_started_usec)
    if String(source_inputs.get("_captureStatus", "")) != "":
        var capture_status := String(source_inputs.get("_captureStatus", "pending"))
        var capture_reason := String(source_inputs.get("_captureReason",
            "ecology_source_local_inputs_pending"))
        if capture_status == "failed":
            var local_input_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
                source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
                catalog_lease_token, "failed")
            if String(local_input_retirement.get("status", "")) != "ready":
                return local_input_retirement
            return _failed_ecology_source_domain(world_id, source_chunk_key,
                world_seed, source_inputs, capture_reason,
                [String(source_inputs.get("_captureStage", "source_inputs"))])
        return {"status":"pending", "reason":capture_reason,
            "stage":String(source_inputs.get("_captureStage", "source_inputs")),
            "sourceChunkKey":source_chunk_key, "retryable":true}
    if admitted_inputs.get("schema", "") == "ecology-source-domain-inputs/v2" \
            and admitted_inputs != source_inputs:
        return _stale_ecology_source_domain(world_id, source_chunk_key, admitted_inputs,
            removed_props_snapshot, "ecology_source_catalog_inputs_stale",
            EcologyProducerDomainScript.digest_value(admitted_inputs),
            EcologyProducerDomainScript.digest_value(source_inputs), catalog_artifact,
            catalog_lease_token)
    var support_policy := EcologyProducerDomainScript.support_policy(source_inputs,
        catalog_artifact)
    if not EcologyProducerDomainScript.validate_support_policy_certificate(support_policy):
        var policy_status := String(support_policy.get("certificateStatus", "pending"))
        if policy_status == "failed":
            var policy_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
                source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
                catalog_lease_token, "failed")
            if String(policy_retirement.get("status", "")) != "ready":
                return policy_retirement
        return {"status":"pending", "reason":String(support_policy.get(
            "runtimePolicyReason", "ecology_support_policy_catalog_dependency_pending")),
            "schema":"ecology-source-domain-snapshot/v1", "worldId":world_id,
            "worldSeed":world_seed, "sourceChunkKey":source_chunk_key,
            "sourceInputs":source_inputs.duplicate(true),
            "influencePolicyRevision":String(support_policy.get("revision", "")),
            "influencePolicyDigest":String(support_policy.get("digest", "")),
            "unsupportedCategories":["family_support_policy"],
            "retryable":true}
    var authority_validation_started_usec := Time.get_ticks_usec()
    var current_world_id := ""
    if world_static_section_coordinator != null \
            and world_static_section_coordinator.has_method("world_identity"):
        current_world_id = String(world_static_section_coordinator.call("world_identity"))
    if world_id.is_empty() or world_id != current_world_id:
        var world_identity_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
            source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
            catalog_lease_token, "failed")
        if String(world_identity_retirement.get("status", "")) != "ready":
            return world_identity_retirement
        return _failed_ecology_source_domain(world_id, source_chunk_key, world_seed,
            source_inputs, "ecology_source_world_identity_unavailable_or_stale",
            ["world_identity"])
    if world_seed.is_empty() or world_seed != seed_text:
        var seed_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
            source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
            catalog_lease_token, "failed")
        if String(seed_retirement.get("status", "")) != "ready":
            return seed_retirement
        return _failed_ecology_source_domain(world_id, source_chunk_key, world_seed,
            source_inputs, "ecology_source_seed_identity_stale", ["seed_identity"])
    var terrain_revision := String(source_inputs.get("terrainVolumeChunkRevision", ""))
    var structure_revision := String(source_inputs.get("structureAdmissionRevision", ""))
    var structure_status := String(source_inputs.get("structureAdmissionStatus", "pending"))
    if terrain_revision.is_empty():
        return {"status":"pending", "reason":"ecology_terrain_source_revision_pending",
            "sourceChunkKey":source_chunk_key, "stage":"terrain_source_revision",
            "retryable":true}
    if structure_status == "pending" or structure_revision.is_empty():
        return {"status":"pending", "reason":"ecology_structure_admission_pending",
            "sourceChunkKey":source_chunk_key, "stage":"structure_admission",
            "retryable":true}
    if structure_status != "ready":
        var structure_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
            source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
            catalog_lease_token, "failed")
        if String(structure_retirement.get("status", "")) != "ready":
            return structure_retirement
        return _failed_ecology_source_domain(world_id, source_chunk_key, world_seed,
            source_inputs, "ecology_structure_admission_failed", ["structure_admission"])
    var current_terrain_revision := ""
    if world_generation_system != null \
            and world_generation_system.has_method("terrain_volume_chunk_revision"):
        current_terrain_revision = str(world_generation_system.call(
            "terrain_volume_chunk_revision", source_chunk_key, CHUNK_SIZE))
    if current_terrain_revision.is_empty():
        return {"status":"pending", "reason":"ecology_terrain_source_revision_unavailable",
            "sourceChunkKey":source_chunk_key, "retryable":true}
    if current_terrain_revision != terrain_revision:
        return _stale_ecology_source_domain(world_id, source_chunk_key, source_inputs,
            removed_props_snapshot, "ecology_terrain_source_revision_stale",
            terrain_revision, current_terrain_revision, catalog_artifact,
            catalog_lease_token)
    var source_bounds := Rect2i(source_chunk_key * CHUNK_SIZE,
        Vector2i.ONE * CHUNK_SIZE)
    var structure_dependencies: Variant = source_inputs.get("structureDependencies", null)
    if not structure_dependencies is Dictionary:
        return {"status":"pending", "reason":"ecology_structure_dependency_snapshot_unavailable",
            "sourceChunkKey":source_chunk_key, "retryable":true}
    var removal_projection := _removed_props_projection_for_source_chunk(
        source_chunk_key, removed_props_snapshot)
    if removal_projection.get("status") != "ready":
        var removal_retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id,
            source_chunk_key, String(source_inputs.get("catalogArtifactId", "")),
            catalog_lease_token, "failed")
        if String(removal_retirement.get("status", "")) != "ready":
            return removal_retirement
        return _failed_ecology_source_domain(world_id, source_chunk_key, world_seed,
            source_inputs, String(removal_projection.get("reason",
                "ecology_removed_props_projection_unavailable")), ["removed_props_projection"])
    var removed_ids: Array = removal_projection.get("removedIds", [])
    var removed_digest := EcologyProducerDomainScript.digest_value(removed_ids)
    var requested_family_request := family_request
    if requested_family_request.is_empty():
        requested_family_request = EcologyProducerDomainScript.build_source_family_request(
            EcologyProducerDomainScript.REQUIRED_CATEGORIES, world_id, world_seed,
            source_chunk_key, source_inputs, removed_digest, catalog_artifact,
            catalog_lease_token)
    if String(requested_family_request.get("status", "")) != "ready" \
            or not EcologyProducerDomainScript.validate_source_family_request(
                requested_family_request, world_id, world_seed, source_chunk_key,
                source_inputs, removed_digest, catalog_artifact, catalog_lease_token):
        return {"status":String(requested_family_request.get("status", "pending")),
            "reason":String(requested_family_request.get("reason",
                "ecology_source_family_request_invalid")),
            "sourceChunkKey":source_chunk_key, "retryable":true,
            "familyRequest":requested_family_request}
    var requested_families: Array = requested_family_request.get("requestedFamilies", [])
    _record_ecology_source_capture_phase("local_authority_validation",
        Time.get_ticks_usec() - authority_validation_started_usec)
    var cache_lookup_started_usec := Time.get_ticks_usec()
    var cache_identity := EcologyProducerDomainScript.snapshot_cache_identity(world_id,
        source_chunk_key, source_inputs, removed_digest, catalog_artifact)
    if cache_identity.is_empty():
        return {"status":"pending", "reason":"ecology_source_cache_identity_pending",
            "sourceChunkKey":source_chunk_key, "retryable":true}
    var existing_publication := ecology_producer_catalog_context.acquire_source_publication_for_request( \
            String(catalog_artifact.get("artifactId", "")),
            String(requested_family_request.get("sourceDomainRevision", "")),
            String(requested_family_request.get("requestDigest", "")),
            "adapter_capture", cache_identity, world_id, ecology_world_epoch)
    if String(existing_publication.get("status", "")) == "ready":
        var existing_view: Dictionary = existing_publication.view
        var existing_payload: Dictionary = existing_view.payload
        return _ecology_source_publication_capture_result(existing_publication,
            existing_payload)
    var cached := ecology_producer_domain.completed_snapshot_for(world_id,
        source_chunk_key, source_inputs, removed_digest, catalog_artifact,
        requested_families)
    _record_ecology_source_capture_phase("cache_lookup",
        Time.get_ticks_usec() - cache_lookup_started_usec)
    if cached.get("status") == "ready":
        var cached_snapshot: Dictionary = cached.get("snapshot", {})
        return _admit_ecology_source_snapshot(cached_snapshot, catalog_artifact,
            cache_identity, requested_family_request)
    var source_domain_revision := ""
    var session_value: Variant = _ecology_source_capture_sessions.get(cache_identity, null)
    var state: Dictionary = {}
    if session_value is Dictionary \
            and _ecology_source_capture_session_matches(session_value, cache_identity, world_id,
                world_seed, source_chunk_key, removed_digest,
                catalog_artifact, catalog_lease_token):
        var state_value: Variant = session_value.get("state", null)
        if state_value is Dictionary:
            state = state_value
            source_domain_revision = String(session_value.get("sourceDomainRevision", ""))
            var was_retained_pass: bool = bool(session_value.get(
                "completedPassCached", false)) or bool(session_value.get(
                "retainedIdle", false))
            session_value["lastAccessUsec"] = Time.get_ticks_usec()
            session_value["retainedIdle"] = false
            if bool(session_value.get("completedPassCached", false)):
                _ecology_source_capture_session_stats["completedPassCacheHits"] = int(
                    _ecology_source_capture_session_stats.get("completedPassCacheHits", 0)) + 1
            elif was_retained_pass:
                _ecology_source_capture_session_stats["retainedPassHits"] = int(
                    _ecology_source_capture_session_stats.get("retainedPassHits", 0)) + 1
            _ecology_source_capture_session_stats["resumed"] = int(
                _ecology_source_capture_session_stats.get("resumed", 0)) + 1
            _retain_ecology_source_capture_subscriber(session_value,
                catalog_lease_token)
    else:
        if session_value is Dictionary:
            if not _drop_ecology_source_capture_session(cache_identity, "stale"):
                return {"status":"pending",
                    "reason":"ecology_source_capture_retirement_backpressure",
                    "sourceChunkKey":source_chunk_key, "retryable":true}
        if not _make_room_for_ecology_source_capture_session():
            return {"status":"pending",
                "reason":"ecology_source_capture_session_capacity",
                "sourceChunkKey":source_chunk_key, "retryable":true}
        state = begin_chunk_prop_spawn_state(null, source_chunk_key.x, source_chunk_key.y)
        state["sourceCaptureMode"] = true
        state["sourceWorldId"] = world_id
        state["sourceWorldSeed"] = world_seed
        state["sourceInputs"] = source_inputs.duplicate(true)
        # The leased artifact owns this recursively frozen value. Source-pass
        # code only reads it; retaining the alias avoids per-slice catalogue copies.
        state["catalogInputs"] = catalog_artifact.get("catalogInputs", {})
        state["animatedAssetOwnerReceipt"] = _ecology_catalog_owner_receipt(
            catalog_artifact, "animated_assets")
        state["visualAssetOwnerReceipt"] = _ecology_catalog_owner_receipt(
            catalog_artifact, "visual_assets")
        source_domain_revision = EcologyProducerDomainScript.source_domain_revision(
            world_id, world_seed, source_chunk_key, source_inputs, removed_digest,
            catalog_artifact)
        if source_domain_revision.is_empty():
            return {"status":"pending", "reason":"ecology_source_revision_pending",
                "sourceChunkKey":source_chunk_key, "retryable":true}
        var policy := EcologyProducerDomainScript.support_policy(source_inputs,
            catalog_artifact)
        state["sourceDomainRevision"] = source_domain_revision
        state["influencePolicyRevision"] = String(policy.get("revision", ""))
        state["influencePolicyDigest"] = String(policy.get("digest", ""))
        state["supportPolicy"] = policy
        state["removedSourceProjectionDigest"] = removed_digest
        state["removedSourceIds"] = removed_ids.duplicate()
        state["cacheIdentity"] = cache_identity
        state["sourceRows"] = []
        state["actorIntents"] = []
        state["sourceFamilyFailures"] = {}
        state["completedSourceCategories"] = []
        state["requestedSourceFamilies"] = []
        state["structureAdmissionStatus"] = structure_status
        session_value = _new_ecology_source_capture_session(cache_identity,
            world_id, world_seed, source_chunk_key, source_domain_revision,
            removed_digest, catalog_artifact, state, catalog_lease_token)
        if session_value.is_empty():
            return {"status":"pending", "reason":"ecology_source_capture_session_unavailable",
                "cacheIdentity":cache_identity, "sourceChunkKey":source_chunk_key,
                "retryable":true}
    if state.is_empty():
        return {"status":"pending", "reason":"ecology_source_capture_session_unavailable",
            "cacheIdentity":cache_identity, "sourceChunkKey":source_chunk_key,
            "retryable":true}
    state["sourceFamilyScoped"] = true
    # The capture session is the single deterministic source pass for this
    # chunk/revision. Keep the admitted family union monotonic for diagnostics
    # and completion accounting, while the active request slice controls which
    # resumable family cursor may advance in this call.
    var requested_family_union: Array[String] = \
        _merge_ecology_source_capture_family_union(state, requested_families)
    state["activeCaptureFamilies"] = requested_families.duplicate()
    if "details" in requested_families \
            and "details" not in state.get("completedSourceCategories", []) \
            and int(state.get("propIndex", 0)) >= 28 \
            and String(state.get("phase", "")) == "underground_props":
        state["phase"] = "details"
    var start_usec := Time.get_ticks_usec()
    var previous_progress: Dictionary = session_value.get("lastProgress",
        _ecology_source_pass_progress(state))
    process_chunk_prop_spawn_state(state, 8, 8, 2.5, start_usec)
    _record_ecology_source_capture_phase("useful_generation",
        Time.get_ticks_usec() - start_usec)
    var retain_started_usec := Time.get_ticks_usec()
    var current_progress := _ecology_source_pass_progress(state)
    var made_progress := current_progress != previous_progress
    session_value["state"] = state
    session_value["sliceCount"] = int(session_value.get("sliceCount", 0)) + 1
    var progress_revision := int(session_value.get("progressRevision", 0))
    if made_progress:
        progress_revision += 1
    session_value["progressRevision"] = progress_revision
    session_value["lastProgress"] = current_progress
    session_value["lastAdvancedUsec"] = Time.get_ticks_usec()
    _ecology_source_capture_sessions[cache_identity] = session_value
    _record_ecology_source_capture_phase("session_retention",
        Time.get_ticks_usec() - retain_started_usec)
    if not String(state.get("sourceCaptureFailure", "")).is_empty():
        var failed_seal_started_usec := Time.get_ticks_usec()
        var failed_snapshot := EcologyProducerDomainScript.seal_source_domain_snapshot({
            "worldId":world_id, "worldSeed":world_seed,
            "sourceChunkKey":source_chunk_key,
            "sourceInputs":source_inputs.duplicate(true),
            "sourceRows":state.get("sourceRows", []),
            "categoriesComplete":state.get("completedSourceCategories", []),
            "producerComplete":false, "producerStatus":"failed",
            "failureReason":String(state.sourceCaptureFailure),
            "failureDetails":state.get("sourceCaptureFailureDetails", {}),
            "unsupportedCategories":[String(state.sourceCaptureFailure)],
            "removedSourceProjectionDigest":removed_digest,
            "removedSourceIds":state.get("removedSourceIds", removed_ids),
            "cacheIdentity":cache_identity,
            "captureProgress":_ecology_source_pass_progress(state)
        }, catalog_artifact)
        _record_ecology_source_capture_phase("final_sealing",
            Time.get_ticks_usec() - failed_seal_started_usec)
        if not _drop_ecology_source_capture_session(cache_identity, "failed"):
            return {"status":"pending",
                "reason":"ecology_source_session_retirement_backpressure",
                "cacheIdentity":cache_identity, "sourceChunkKey":source_chunk_key,
                "retryable":true, "terminalFailure":true}
        return failed_snapshot
    var completed_categories: Array = state.get("completedSourceCategories", [])
    var requested_categories_complete := true
    for family_value: Variant in requested_families:
        if String(family_value) not in completed_categories:
            requested_categories_complete = false
            break
    if not requested_categories_complete:
        var capture_disposition := _ecology_source_capture_disposition(state)
        var blocked_reason := String(state.get("sourceCaptureBlockedReason", ""))
        return {"status":"pending", "reason":"ecology_source_chunk_pass_pending",
            "schema":"ecology-source-domain-snapshot/v1",
            "worldId":world_id, "worldSeed":world_seed,
            "sourceChunkKey":source_chunk_key,
            "sourceRevision":source_domain_revision,
            "cacheIdentity":cache_identity,
            "captureProgress":current_progress,
            "captureDisposition":capture_disposition,
            "captureCursorAdvanced":made_progress,
            "captureProgressRevision":progress_revision,
            "cursorRevision":progress_revision,
            "blockedReason":blocked_reason}
    var policy := EcologyProducerDomainScript.support_policy(source_inputs,
        catalog_artifact)
    var failure_reason := ""
    var unsupported: Array = []
    for family_value: Variant in requested_families:
        var family := String(family_value)
        var family_failures: Dictionary = state.get("sourceFamilyFailures", {})
        var family_failure_value: Variant = family_failures.get(family, null)
        if family_failure_value is Dictionary:
            failure_reason = String(family_failure_value.get("reason",
                "ecology_source_family_producer_failed"))
            unsupported.append(family)
        var family_policy := EcologyProducerDomainScript.family_support_policy(
            source_inputs, catalog_artifact, family)
        if String(family_policy.get("status", "")) != "ready":
            failure_reason = "ecology_requested_family_support_bounds_unproven"
            unsupported.append(family)
    var bounded_family_row_failures: Array[String] = []
    for row_value: Variant in state.get("sourceRows", []):
        if not row_value is Dictionary:
            bounded_family_row_failures.append("invalid_source_row")
            continue
        var row: Dictionary = row_value
        var family := String(row.get("producerFamily", ""))
        if family not in requested_families:
            continue
        var family_policy: Variant = policy.get("families", {}).get(family, null)
        if not family_policy is Dictionary \
                or String(family_policy.get("status", "")) != "bounded":
            continue
        var proof: Variant = row.get("supportProof", null)
        if not proof is Dictionary or String(proof.get("status", "")) != "ready":
            bounded_family_row_failures.append(String(row.get("sourceId", "unknown_source")))
    if not bounded_family_row_failures.is_empty():
        if failure_reason.is_empty():
            failure_reason = "ecology_source_member_exceeds_certified_support_bound"
        unsupported.append_array(bounded_family_row_failures)
    if not failure_reason.is_empty():
        var failed_seal_started_usec := Time.get_ticks_usec()
        var failed_snapshot := _seal_ecology_source_capture_snapshot({
            "worldId":world_id, "worldSeed":world_seed,
            "sourceChunkKey":source_chunk_key,
            "sourceInputs":source_inputs.duplicate(true),
            "sourceRows":state.get("sourceRows", []),
            "actorIntents":state.get("actorIntents", []),
            "categoriesComplete":completed_categories,
            "producerComplete":false, "producerStatus":"failed",
            "failureReason":failure_reason,
            "unsupportedCategories":unsupported,
            "removedSourceProjectionDigest":removed_digest,
            "removedSourceIds":state.get("removedSourceIds", removed_ids),
            "cacheIdentity":cache_identity,
            "captureProgress":_ecology_source_pass_progress(state)
        }, catalog_artifact)
        _record_ecology_source_capture_phase("final_sealing",
            Time.get_ticks_usec() - failed_seal_started_usec)
        if not _drop_ecology_source_capture_session(cache_identity, "failed"):
            return {"status":"pending",
                "reason":"ecology_source_session_retirement_backpressure",
                "cacheIdentity":cache_identity, "sourceChunkKey":source_chunk_key,
                "retryable":true, "terminalFailure":true}
        return failed_snapshot
    var source_publication_key := "%s|%s|%s" % [
        String(catalog_artifact.get("artifactId", "")), source_domain_revision,
        String(requested_family_request.get("requestDigest", ""))]
    ecology_source_publication_admission_sequence += 1
    var durable_catalog_hold := acquire_ecology_catalog_artifact_lease(
        String(catalog_artifact.get("artifactId", "")), "source_publication_factory",
        "%s|seal:%d" % [source_publication_key,
            ecology_source_publication_admission_sequence], world_id, ecology_world_epoch)
    if String(durable_catalog_hold.get("status", "")) != "ready":
        return {"status":"pending", "reason":String(durable_catalog_hold.get(
            "reason", "ecology_source_publication_catalog_hold_pending")),
            "sourceChunkKey":source_chunk_key, "retryable":true}
    var publication := _produce_and_admit_ecology_source_publication({
        "worldId":world_id, "worldSeed":world_seed,
        "sourceChunkKey":source_chunk_key,
        "sourceInputs":source_inputs,
        "sourceRows":state.get("sourceRows", []),
        "actorIntentSnapshot":state.get("actorIntents", []),
        "categoriesComplete":completed_categories,
        "completedFamilies":completed_categories,
        "familyRequest":requested_family_request,
        "removedSourceProjectionDigest":removed_digest,
        "removedSourceIds":state.get("removedSourceIds", removed_ids)
    }, String(durable_catalog_hold.get("leaseToken", "")),
        "adapter_capture", cache_identity)
    _record_ecology_source_capture_phase("final_sealing",
        int(publication.get("producerSealUsec", 0)))
    if String(publication.get("status", "")) == "ready":
        var retention_started_usec := Time.get_ticks_usec()
        var snapshot: Dictionary = publication.view.payload
        var published_families: Array = session_value.get(
            "publishedSourceFamilies", [])
        for family_value: Variant in requested_families:
            var published_family := String(family_value)
            if published_family not in published_families:
                published_families.append(published_family)
        published_families.sort()
        session_value["publishedSourceFamilies"] = published_families
        # Keep the private shared pass alive when some families are deferred so
        # sibling family jobs can seal their own receipts from this same pass.
        # The session is retired only after its producer pass and all currently
        # admitted family receipts are complete.
        var all_source_families_complete := true
        for family: String in EcologyProducerDomainScript.REQUIRED_CATEGORIES:
            if family not in completed_categories:
                all_source_families_complete = false
                break
        var all_admitted_family_receipts_complete := true
        for family_value: Variant in state.get("requestedSourceFamilies", []):
            if String(family_value) not in published_families:
                all_admitted_family_receipts_complete = false
                break
        if all_source_families_complete and all_admitted_family_receipts_complete:
            ecology_producer_domain.clear_pending_capture_progress(cache_identity)
            _retain_completed_ecology_source_capture_pass(cache_identity,
                session_value)
        else:
            session_value["lastFamilyBundle"] = snapshot
            _ecology_source_capture_sessions[cache_identity] = session_value
        _record_ecology_source_capture_phase("accepted_result_retention",
            int(publication.get("producerStoreUsec", 0))
            + Time.get_ticks_usec() - retention_started_usec)
        return _ecology_source_publication_capture_result(publication, snapshot)
    _record_ecology_source_capture_phase("accepted_result_retention",
        int(publication.get("producerStoreUsec", 0)))
    if String(publication.get("status", "")) == "pending":
        var pending_snapshot: Variant = publication.get("snapshot", null)
        if pending_snapshot is Dictionary:
            return pending_snapshot
        return {"status":"pending", "reason":String(publication.get("reason",
            "ecology_source_publication_pending")),
            "sourceChunkKey":source_chunk_key, "retryable":true}
    if not _drop_ecology_source_capture_session(cache_identity, "failed"):
        return {"status":"pending",
            "reason":"ecology_source_session_retirement_backpressure",
            "cacheIdentity":cache_identity, "sourceChunkKey":source_chunk_key,
            "retryable":true, "terminalFailure":true}
    return {"status":String(publication.get("status", "failed")),
        "reason":String(publication.get("reason", "ecology_source_publication_failed")),
        "sourceChunkKey":source_chunk_key}


func _retain_ecology_source_capture_subscriber(session: Dictionary,
        owner_lease_token: String) -> void:
    if owner_lease_token.is_empty():
        return
    var tokens: Array = session.get("subscriberLeaseTokens", [])
    if owner_lease_token not in tokens:
        tokens.append(owner_lease_token)
    session["subscriberLeaseTokens"] = tokens


func _merge_ecology_source_capture_family_union(state: Dictionary,
        requested_families: Array) -> Array[String]:
    var requested_family_union: Array[String] = []
    for existing_family_value: Variant in state.get("requestedSourceFamilies", []):
        var existing_family := String(existing_family_value)
        if not existing_family.is_empty() and existing_family not in requested_family_union:
            requested_family_union.append(existing_family)
    for requested_family_value: Variant in requested_families:
        var requested_family := String(requested_family_value)
        if not requested_family.is_empty() and requested_family not in requested_family_union:
            requested_family_union.append(requested_family)
    requested_family_union.sort()
    state["requestedSourceFamilies"] = requested_family_union
    return requested_family_union


func cancel_ecology_source_domain_capture(cache_identity: String,
        owner_lease_token := "") -> Dictionary:
    # Queue retirement already retains this exact admission key. Cancellation
    # must not recapture catalogs or delete a reusable completed snapshot.
    var session_value: Variant = _ecology_source_capture_sessions.get(cache_identity, null)
    if session_value is Dictionary and not owner_lease_token.is_empty():
        var tokens: Array = session_value.get("subscriberLeaseTokens", [])
        tokens.erase(owner_lease_token)
        session_value["subscriberLeaseTokens"] = tokens
        if not tokens.is_empty():
            _ecology_source_capture_sessions[cache_identity] = session_value
            return {"status":"detached", "cacheIdentity":cache_identity,
                "remainingSubscribers":tokens.size(), "sessionReleased":false}
        var state_value: Variant = session_value.get("state", null)
        if state_value is Dictionary:
            var state: Dictionary = state_value
            var has_reusable_progress := bool(session_value.get(
                "completedPassCached", false)) \
                or not (state.get("completedSourceCategories", []) as Array).is_empty() \
                or int(session_value.get("sliceCount", 0)) > 1
            has_reusable_progress = has_reusable_progress \
                and not bool(session_value.get("terminalFailure", false))
            if has_reusable_progress:
                if _retain_idle_ecology_source_capture_pass(cache_identity,
                        session_value):
                    return {"status":"retained", "cacheIdentity":cache_identity,
                        "remainingSubscribers":0, "sessionReleased":false,
                        "completedPassCached":bool(session_value.get(
                            "completedPassCached", false))}
    var dropped := _drop_ecology_source_capture_session(cache_identity, "cancelled")
    if dropped:
        ecology_producer_domain.clear_pending_capture_progress(cache_identity)
        return {"status":"cancelled", "cacheIdentity":cache_identity,
            "sessionReleased":true, "remainingSubscribers":0}
    return {"status":"pending", "reason":"ecology_source_capture_retirement_backpressure",
        "cacheIdentity":cache_identity, "sessionReleased":false,
        "remainingSubscribers":0, "retryable":true}


func invalidate_ecology_source_capture_chunk(world_id: String,
        source_chunk_key: Vector2i) -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_source_session_invalidation_requires_main_thread"}
    var removed := 0
    var pending := 0
    for identity_value: Variant in _ecology_source_capture_sessions.keys():
        var identity := String(identity_value)
        var session: Variant = _ecology_source_capture_sessions.get(identity, null)
        if session is Dictionary and String(session.get("worldId", "")) == world_id \
                and Vector2i(session.get("sourceChunkKey", Vector2i.ZERO)) == source_chunk_key:
            if _drop_ecology_source_capture_session(identity, "stale"):
                removed += 1
            else:
                pending += 1
    if pending > 0:
        return {"status":"pending", "reason":"ecology_source_session_retirement_backpressure",
            "removedSessionCount":removed, "pendingSessionCount":pending,
            "worldId":world_id, "sourceChunkKey":source_chunk_key, "retryable":true}
    ecology_producer_domain.invalidate_source_chunk(world_id, source_chunk_key)
    return {"status":"ready", "removedSessionCount":removed}


func _drop_ecology_source_capture_sessions_for_source(world_id: String,
        source_chunk_key: Vector2i, catalog_artifact_id: String,
        catalog_lease_token: String, reason: String) -> Dictionary:
    var removed := 0
    var pending := 0
    for identity_value: Variant in _ecology_source_capture_sessions.keys():
        var identity := String(identity_value)
        var session: Variant = _ecology_source_capture_sessions.get(identity, null)
        if not session is Dictionary \
                or String(session.get("worldId", "")) != world_id \
                or Vector2i(session.get("sourceChunkKey", Vector2i.ZERO)) != source_chunk_key:
            continue
        if not catalog_artifact_id.is_empty() \
                and String(session.get("catalogArtifactId", "")) != catalog_artifact_id:
            continue
        if _drop_ecology_source_capture_session(identity, reason):
            removed += 1
        else:
            pending += 1
    if pending > 0:
        return {"status":"pending", "reason":"ecology_source_session_retirement_backpressure",
            "removedSessionCount":removed, "pendingSessionCount":pending,
            "worldId":world_id, "sourceChunkKey":source_chunk_key, "retryable":true}
    return {"status":"ready", "removedSessionCount":removed,
        "pendingSessionCount":0}


func _stale_ecology_source_domain(world_id: String, source_chunk_key: Vector2i,
        source_inputs: Dictionary, removed_snapshot: Dictionary, reason: String,
        captured_revision: String, current_revision: String,
        catalog_artifact: Dictionary = {}, catalog_lease_token: String = "") -> Dictionary:
    # The private mutable session belongs to its original revision. Retire its
    # cursor; the source queue must obtain new inputs from the authority.
    var retirement: Dictionary = _drop_ecology_source_capture_sessions_for_source(world_id, source_chunk_key,
        String(source_inputs.get("catalogArtifactId", "")), catalog_lease_token, "stale")
    if String(retirement.get("status", "")) != "ready":
        retirement["requiresRecapture"] = true
        retirement["capturedRevision"] = captured_revision
        retirement["currentRevision"] = current_revision
        retirement["stage"] = "source_capture_retirement"
        return retirement
    var projection := _removed_props_projection_for_source_chunk(source_chunk_key,
        removed_snapshot)
    if projection.get("status") == "ready":
        var removed_digest := EcologyProducerDomainScript.digest_value(
            projection.get("removedIds", []))
        var obsolete_identity := EcologyProducerDomainScript.snapshot_cache_identity(
            world_id, source_chunk_key, source_inputs, removed_digest, catalog_artifact)
        if _ecology_source_capture_sessions.has(obsolete_identity) \
                and not _drop_ecology_source_capture_session(obsolete_identity, "stale"):
            return {"status":"pending",
                "reason":"ecology_source_session_retirement_backpressure",
                "cacheIdentity":obsolete_identity, "worldId":world_id,
                "sourceChunkKey":source_chunk_key, "retryable":true,
                "requiresRecapture":true, "stage":"source_capture_retirement"}
        ecology_producer_domain.clear_pending_capture_progress(obsolete_identity)
    return {"status":"pending", "reason":reason, "retryable":true,
        "requiresRecapture":true, "worldId":world_id,
        "sourceChunkKey":source_chunk_key,
        "capturedRevision":captured_revision, "currentRevision":current_revision,
        "stage":"source_capture_revision"}


## The section adapter asks Main for the same immutable producer/catalog inputs
## used by source capture, then supplies those values to the inverse census.
## This keeps profile and imported-asset eligibility owned by the live registries.
func ecology_source_support_policy_inputs(world_id: String, source_chunk_key: Vector2i,
        world_seed: String, source_inputs: Dictionary) -> Dictionary:
    var active := _active_ecology_catalog_artifact(world_id, world_seed)
    if String(active.get("status", "")) != "ready":
        return active
    var canonical_inputs := _ecology_source_capture_inputs(world_id, source_chunk_key,
        world_seed, source_inputs, active.artifact)
    if String(canonical_inputs.get("_captureStatus", "")) != "":
        var capture_status := String(canonical_inputs.get("_captureStatus", "pending"))
        return {"status":capture_status,
            "reason":String(canonical_inputs.get("_captureReason",
                "ecology_source_local_inputs_pending")),
            "stage":String(canonical_inputs.get("_captureStage", "source_inputs")),
            "worldId":world_id, "sourceChunkKey":source_chunk_key,
            "retryable":capture_status == "pending"}
    var policy := EcologyProducerDomainScript.support_policy(canonical_inputs,
        active.artifact)
    var immutable_inputs: Dictionary = EcologyProducerDomainScript.freeze_value(
        canonical_inputs)
    var immutable_policy: Dictionary = EcologyProducerDomainScript.freeze_value(policy)
    var result := {"status":"ready" if String(policy.get("certificateStatus", "")) == "ready" else "pending",
        "reason":String(policy.get("runtimePolicyStatus", "pending")),
        "policyStatus":String(policy.get("status", "pending")),
        "schema":"ecology-source-support-policy-inputs/v2",
        "worldId":world_id, "worldSeed":world_seed,
        "sourceChunkKey":source_chunk_key,
        "sourceInputs":immutable_inputs,
        "supportPolicy":immutable_policy,
        "catalogArtifact":active.artifact,
        "catalogArtifactId":String(active.artifactId),
        "catalogContentDigest":String(active.catalogContentDigest),
        "worldEpoch":ecology_world_epoch,
        "influencePolicyRevision":String(policy.get("revision", "")),
        "influencePolicyDigest":String(policy.get("digest", ""))}
    if String(policy.get("certificateStatus", "")) != "ready":
        result["reason"] = String(policy.get("runtimePolicyReason",
            "ecology_support_policy_pending"))
    return result


func begin_ecology_source_catalog_context_scope() -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
    var world_id := _ecology_current_world_id()
    if world_id.is_empty() or seed_text.is_empty() or ecology_world_epoch <= 0:
        return {"status":"failed", "reason":"ecology_catalog_context_world_identity_unavailable"}
    # A synchronous census/service batch may open nested scopes while validating
    # each source record. Reuse the already-owned artifact inside that batch;
    # fresh semantic capture happens only at the outermost scope boundary.
    var active_context := ecology_producer_catalog_context.context_for(world_id,
        seed_text)
    if ecology_producer_catalog_context.scope_depth() > 0:
        if String(active_context.get("status", "")) != "ready":
            return active_context
        var active_artifact_id := String(active_context.get("artifactId", ""))
        var live_active := ecology_producer_catalog_context.resolve_active_scope_artifact(
            active_artifact_id, world_id, ecology_world_epoch)
        if String(live_active.get("status", "")) != "ready":
            return live_active
        return ecology_producer_catalog_context.begin_artifact_scope(
            active_artifact_id, world_id, ecology_world_epoch)
    var publication_state := _read_ecology_owner_publications(world_id, seed_text)
    if String(publication_state.get("status", "")) != "ready":
        return publication_state
    var publication_signature := _ecology_catalog_publication_signature(
        world_id, seed_text, publication_state)
    if publication_signature.is_empty():
        return {"status":"pending", "reason":"ecology_catalog_publication_identity_invalid",
            "retryable":true}
    if publication_signature != ecology_current_catalog_signature:
        var catalog_inputs := _build_ecology_source_catalog_inputs(world_id,
            seed_text, publication_state)
        if String(catalog_inputs.get("_status", "ready")) != "ready":
            var compose_status := String(catalog_inputs.get("_status", "pending"))
            return {"status":compose_status,
                "reason":String(catalog_inputs.get("_reason",
                    "ecology_catalog_composition_pending")),
                "retryable":compose_status == "pending",
                "detail":catalog_inputs}
        catalog_inputs.erase("_status")
        catalog_inputs.erase("_reason")
        var owner_identity := _ecology_catalog_owner_identity(world_id,
            seed_text, publication_state)
        var interned := ecology_producer_catalog_context.intern_fresh(world_id,
            seed_text, ecology_world_epoch, owner_identity, catalog_inputs)
        if String(interned.get("status", "")) != "ready":
            return interned
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("ecology_catalog_artifact_seals")
            if bool(interned.get("deduplicated", false)):
                runtime_perf_monitor.increment_counter("ecology_catalog_artifact_deduplications")
        var new_artifact_id := String(interned.get("artifactId", ""))
        var current_lease := ecology_producer_catalog_context.acquire_lease(
            new_artifact_id, "current_publication", str(get_instance_id()),
            world_id, ecology_world_epoch)
        if String(current_lease.get("status", "")) != "ready":
            return current_lease
        var prior_lease := ecology_current_catalog_lease_token
        ecology_current_catalog_artifact_id = new_artifact_id
        ecology_current_catalog_content_digest = String(interned.get(
            "catalogContentDigest", ""))
        ecology_current_catalog_signature = publication_signature
        ecology_current_catalog_scope_key = _ecology_catalog_scope_key(world_id,
            seed_text, publication_state)
        ecology_current_catalog_lease_token = String(current_lease.get("leaseToken", ""))
        ecology_current_owner_publications = {
            "biome":publication_state.get("biome", {}),
            "visual":publication_state.get("visual", {}),
            "animated":publication_state.get("animated", {})}
        if not prior_lease.is_empty():
            ecology_producer_catalog_context.release_lease(prior_lease)
    else:
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("ecology_catalog_publication_reuses")
        var current_artifact := ecology_producer_catalog_context.resolve_leased_artifact(
            ecology_current_catalog_lease_token, world_id, ecology_world_epoch)
        if String(current_artifact.get("status", "")) != "ready":
            return current_artifact
    return ecology_producer_catalog_context.begin_artifact_scope(
        ecology_current_catalog_artifact_id, world_id, ecology_world_epoch)


func end_ecology_source_catalog_context_scope(scope_token: Dictionary) -> Dictionary:
    return ecology_producer_catalog_context.end_scope(scope_token)


func acquire_ecology_catalog_artifact_lease(artifact_id: String, owner_kind: String,
        owner_key: String, expected_world_id: String, expected_world_epoch: int) -> Dictionary:
    if expected_world_epoch != ecology_world_epoch \
            or expected_world_id != _ecology_current_world_id():
        return {"status":"failed", "reason":"ecology_catalog_artifact_owner_epoch_stale"}
    return ecology_producer_catalog_context.acquire_lease(artifact_id, owner_kind,
        owner_key, expected_world_id, expected_world_epoch)


func resolve_ecology_catalog_artifact(lease_token: String, expected_world_id: String,
        expected_world_epoch: int) -> Dictionary:
    if expected_world_epoch != ecology_world_epoch \
            or expected_world_id != _ecology_current_world_id():
        return {"status":"failed", "reason":"ecology_catalog_artifact_owner_epoch_stale"}
    var resolved := ecology_producer_catalog_context.resolve_leased_artifact(
        lease_token, expected_world_id, expected_world_epoch)
    if String(resolved.get("status", "")) != "ready":
        return resolved
    resolved["catalogArtifactId"] = String(resolved.get("artifactId", ""))
    return resolved


func release_ecology_catalog_artifact_lease(lease_token: String) -> Dictionary:
    return ecology_producer_catalog_context.release_lease(lease_token)


func _produce_and_admit_ecology_source_publication(fields: Dictionary,
        catalog_hold_token: String, owner_kind: String,
        owner_key: String) -> Dictionary:
    var world_id := String(fields.get("worldId", ""))
    var world_seed := String(fields.get("worldSeed", ""))
    var source_inputs: Variant = fields.get("sourceInputs", null)
    var world_epoch := int(source_inputs.get("worldEpoch", -1)) \
        if source_inputs is Dictionary else -1
    if not Thread.is_main_thread() or world_id != _ecology_current_world_id() \
            or world_epoch != ecology_world_epoch or world_seed != seed_text:
        release_ecology_catalog_artifact_lease(catalog_hold_token)
        return {"status":"failed", "reason":"ecology_source_publication_main_owner_stale"}
    var lease_result := resolve_ecology_catalog_artifact(catalog_hold_token,
        world_id, world_epoch)
    if String(lease_result.get("status", "")) != "ready":
        release_ecology_catalog_artifact_lease(catalog_hold_token)
        return lease_result
    var catalog_artifact: Dictionary = lease_result.get("artifact", {})
    if String(source_inputs.get("catalogArtifactId", "")) != String(
            catalog_artifact.get("artifactId", "")) \
            or String(source_inputs.get("catalogContentDigest", "")) != String(
                catalog_artifact.get("catalogContentDigest", "")):
        release_ecology_catalog_artifact_lease(catalog_hold_token)
        return {"status":"pending", "reason":"ecology_source_publication_catalog_stale",
            "retryable":true}
    var owner_receipt := {"schema":"ecology-source-publication-owner/v1",
        "mainInstanceId":get_instance_id(), "worldId":world_id,
        "worldEpoch":world_epoch,
        "catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
        "catalogContentDigest":String(catalog_artifact.get("catalogContentDigest", ""))}
    var publication := ecology_producer_catalog_context._publish_producer_family_bundle(
        fields, catalog_hold_token, owner_kind, owner_key, owner_receipt)
    if String(publication.get("status", "")) != "ready" \
            or not bool(publication.get("catalogLeaseAdopted", false)):
        release_ecology_catalog_artifact_lease(catalog_hold_token)
    else:
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("ecology_source_publication_admissions")
    return publication


func admit_ecology_source_publication(snapshot: Dictionary,
        catalog_lease_token: String, owner_kind: String,
        owner_key: String) -> Dictionary:
    var world_id := String(snapshot.get("worldId", ""))
    var world_epoch := int(snapshot.get("worldEpoch", -1))
    if world_epoch != ecology_world_epoch or world_id != _ecology_current_world_id():
        return {"status":"failed", "reason":"ecology_source_publication_main_owner_stale"}
    var lease_result := resolve_ecology_catalog_artifact(catalog_lease_token,
        world_id, world_epoch)
    if String(lease_result.get("status", "")) != "ready":
        return lease_result
    var catalog_artifact: Dictionary = lease_result.get("artifact", {})
    var publication_key := "%s|%s|%s" % [
        String(catalog_artifact.get("artifactId", "")),
        String(snapshot.get("sourceRevision", "")),
        String(snapshot.get("familyRequestDigest", ""))]
    ecology_source_publication_admission_sequence += 1
    var publication_catalog_hold := acquire_ecology_catalog_artifact_lease(
        String(catalog_artifact.get("artifactId", "")), "source_publication",
        "%s|admission:%d" % [publication_key,
            ecology_source_publication_admission_sequence], world_id, world_epoch)
    if String(publication_catalog_hold.get("status", "")) != "ready":
        return publication_catalog_hold
    var owner_receipt := {"schema":"ecology-source-publication-owner/v1",
        "mainInstanceId":get_instance_id(), "worldId":world_id,
        "worldEpoch":world_epoch,
        "catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
        "catalogContentDigest":String(catalog_artifact.get("catalogContentDigest", ""))}
    var admitted := ecology_producer_catalog_context.publish_source_bundle(snapshot,
        String(publication_catalog_hold.get("leaseToken", "")),
        owner_kind, owner_key, owner_receipt)
    if String(admitted.get("status", "")) != "ready":
        release_ecology_catalog_artifact_lease(String(
            publication_catalog_hold.get("leaseToken", "")))
        return admitted
    if not bool(admitted.get("catalogLeaseAdopted", false)):
        release_ecology_catalog_artifact_lease(String(
            publication_catalog_hold.get("leaseToken", "")))
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("ecology_source_publication_admissions")
    return admitted


func acquire_ecology_source_publication(publication_id: String,
        owner_kind: String, owner_key: String) -> Dictionary:
    var acquired := ecology_producer_catalog_context.acquire_source_publication_lease(
        publication_id, owner_kind, owner_key, _ecology_current_world_id(),
        ecology_world_epoch)
    if String(acquired.get("status", "")) != "ready":
        return acquired
    var resolved := resolve_ecology_source_publication(
        String(acquired.get("leaseToken", "")), _ecology_current_world_id(),
        ecology_world_epoch)
    if String(resolved.get("status", "")) != "ready":
        release_ecology_source_publication(String(acquired.get("leaseToken", "")))
        return resolved
    acquired["view"] = resolved.view
    return acquired


func resolve_ecology_source_publication(lease_token: String,
        expected_world_id: String, expected_world_epoch: int) -> Dictionary:
    if expected_world_epoch != ecology_world_epoch \
            or expected_world_id != _ecology_current_world_id():
        return {"status":"failed", "reason":"ecology_source_publication_main_owner_stale"}
    var resolved := ecology_producer_catalog_context.resolve_source_publication(
        lease_token, expected_world_id, expected_world_epoch)
    if String(resolved.get("status", "")) != "ready":
        return resolved
    var view: Dictionary = resolved.get("view", {})
    var receipt: Dictionary = view.get("ownerReceipt", {})
    if int(receipt.get("mainInstanceId", 0)) != get_instance_id() \
            or String(receipt.get("catalogArtifactId", "")) != String(
                view.get("catalogArtifactId", "")) \
            or (not ecology_current_catalog_artifact_id.is_empty() \
                and ecology_current_catalog_artifact_id != String(
                    view.get("catalogArtifactId", ""))):
        return {"status":"failed", "reason":"ecology_source_publication_owner_receipt_stale"}
    return resolved


func prepare_ecology_source_publication_section_band_slices(
        publication_view: Dictionary, lease_token: String,
        section_keys: Array) -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_band_slice_requires_main_thread"}
    var resolved := resolve_ecology_source_publication(lease_token,
        String(publication_view.get("worldId", "")),
        int(publication_view.get("worldEpoch", -1)))
    if String(resolved.get("status", "")) != "ready" \
            or not is_same(resolved.get("view", null), publication_view):
        return {"status":"failed", "reason":"ecology_band_slice_view_not_admitted"}
    return ecology_producer_catalog_context.prepare_source_publication_section_band_slices(
        lease_token, String(publication_view.get("worldId", "")),
        int(publication_view.get("worldEpoch", -1)), section_keys)


func resolve_ecology_source_publication_section_band_slice(
        publication_view: Dictionary, lease_token: String,
        section_key: Vector3i, exact_slice: Dictionary) -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_band_slice_requires_main_thread"}
    var resolved := resolve_ecology_source_publication(lease_token,
        String(publication_view.get("worldId", "")),
        int(publication_view.get("worldEpoch", -1)))
    if String(resolved.get("status", "")) != "ready" \
            or not is_same(resolved.get("view", null), publication_view):
        return {"status":"failed", "reason":"ecology_band_slice_view_not_admitted"}
    return ecology_producer_catalog_context.resolve_source_publication_section_band_slice(
        lease_token, String(publication_view.get("worldId", "")),
        int(publication_view.get("worldEpoch", -1)), publication_view,
        section_key, exact_slice)


func ecology_source_publication_is_current(lease_token: String,
        expected_world_id: String, expected_world_epoch: int,
        expected_owner_receipt: Dictionary, expected_source_revision: String,
        expected_removed_projection_digest: String) -> Dictionary:
    if expected_world_epoch != ecology_world_epoch \
            or expected_world_id != _ecology_current_world_id():
        return {"status":"failed", "reason":"ecology_source_publication_main_owner_stale"}
    if not ecology_current_catalog_artifact_id.is_empty() \
            and ecology_current_catalog_artifact_id != String(
                expected_owner_receipt.get("catalogArtifactId", "")):
        return {"status":"failed", "reason":"ecology_source_publication_catalog_owner_stale"}
    return ecology_producer_catalog_context.source_publication_is_current(
        lease_token, expected_world_id, expected_world_epoch,
        expected_owner_receipt, expected_source_revision,
        expected_removed_projection_digest)


func ecology_source_publication_local_is_current(view: Dictionary,
        lease_token: String) -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_source_publication_currentness_requires_main_thread"}
    var resolved := resolve_ecology_source_publication(lease_token,
        String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
    if String(resolved.get("status", "")) != "ready" \
            or not is_same(resolved.get("view", null), view):
        return {"status":"failed", "reason":"ecology_source_publication_view_not_admitted"}
    var payload: Dictionary = view.get("payload", {})
    var owner_check := ecology_source_publication_is_current(lease_token,
        String(view.get("worldId", "")), int(view.get("worldEpoch", -1)),
        view.get("ownerReceipt", {}), String(view.get("sourceDomainRevision", "")),
        String(payload.get("removedSourceProjectionDigest", "")))
    if String(owner_check.get("status", "")) != "ready":
        return owner_check
    var scope := begin_ecology_source_catalog_context_scope()
    if String(scope.get("status", "")) != "ready":
        return scope
    var current := _ecology_source_domain_is_current_in_scope(payload, scope,
        "", view)
    var ended := end_ecology_source_catalog_context_scope(scope)
    if String(ended.get("status", "")) != "ready":
        return ended
    return current


func ecology_source_publication_record_is_current(view: Dictionary,
        lease_token: String, record: Dictionary) -> Dictionary:
    var resolved := resolve_ecology_source_publication(lease_token,
        String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
    if String(resolved.get("status", "")) != "ready" \
            or not is_same(resolved.get("view", null), view):
        return {"status":"failed", "reason":"ecology_source_publication_view_not_admitted"}
    var family := String(record.get("producerFamily", ""))
    var source_id := String(record.get("sourceId", ""))
    var source_part_id := String(record.get("sourcePartId", ""))
    var member_key := EcologyProducerDomainScript.source_publication_member_key(
        family, source_id, source_part_id)
    var member_index: Dictionary = view.get("memberIndex", {})
    if not member_index.has(member_key):
        return {"status":"failed", "reason":"ecology_source_publication_member_absent"}
    var row_index := int(member_index[member_key])
    var payload: Dictionary = view.get("payload", {})
    var rows: Array = payload.get("sourceRows", [])
    if row_index < 0 or row_index >= rows.size() or not is_same(rows[row_index], record):
        return {"status":"failed", "reason":"ecology_source_publication_member_alias_mismatch"}
    var owner_check := ecology_source_publication_is_current(lease_token,
        String(view.get("worldId", "")), int(view.get("worldEpoch", -1)),
        view.get("ownerReceipt", {}), String(view.get("sourceDomainRevision", "")),
        String(payload.get("removedSourceProjectionDigest", "")))
    if String(owner_check.get("status", "")) != "ready":
        return owner_check
    var digests: Array = view.get("memberDigestsByIndex", [])
    return {"status":"ready", "publicationId":String(view.get("publicationId", "")),
        "family":family, "sourceId":source_id, "sourcePartId":source_part_id,
        "rowIndex":row_index,
        "memberDigest":String(digests[row_index]) if row_index < digests.size() else ""}


func release_ecology_source_publication(lease_token: String) -> Dictionary:
    return ecology_producer_catalog_context.release_source_publication_lease(lease_token)


func _ecology_source_publication_capture_result(publication: Dictionary,
        snapshot: Dictionary) -> Dictionary:
    var view: Dictionary = publication.get("view", {})
    return {"status":"ready", "snapshot":snapshot,
        "sourcePublicationId":String(publication.get("publicationId", "")),
        "sourcePublicationLeaseToken":String(publication.get("leaseToken", "")),
        "sourcePublicationView":view,
        "deduplicated":bool(publication.get("deduplicated", false))}


func _admit_ecology_source_snapshot(snapshot: Dictionary,
        catalog_artifact: Dictionary, cache_identity: String,
        family_request: Dictionary) -> Dictionary:
    var publication_key := "%s|%s|%s" % [
        String(catalog_artifact.get("artifactId", "")),
        String(family_request.get("sourceDomainRevision", "")),
        String(family_request.get("requestDigest", ""))]
    var durable_hold := acquire_ecology_catalog_artifact_lease(
        String(catalog_artifact.get("artifactId", "")), "source_publication",
        publication_key, String(snapshot.get("worldId", "")), ecology_world_epoch)
    if String(durable_hold.get("status", "")) != "ready":
        return durable_hold
    var result := admit_ecology_source_publication(snapshot,
        String(durable_hold.get("leaseToken", "")), "adapter_capture", cache_identity)
    release_ecology_catalog_artifact_lease(String(
        durable_hold.get("leaseToken", "")))
    if String(result.get("status", "")) != "ready":
        return result
    return _ecology_source_publication_capture_result(result,
        result.view.payload)


func _read_ecology_owner_publications(world_id: String, world_seed: String) -> Dictionary:
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("ecology_catalog_owner_publication_reads")
    if not is_instance_valid(biome_environment_catalog) \
            or not biome_environment_catalog.has_method("published_catalog_snapshot"):
        return {"status":"pending", "reason":"ecology_biome_publication_unavailable",
            "retryable":true}
    var biome_publication: Dictionary = biome_environment_catalog.call(
        "published_catalog_snapshot")
    var validation := _validate_ecology_owner_publication(biome_publication,
        "biome_environment")
    if String(validation.get("status", "")) != "ready":
        return validation
    if not is_instance_valid(visual_asset_registry) \
            or not visual_asset_registry.has_method("published_catalog_snapshot"):
        return {"status":"pending", "reason":"ecology_visual_publication_unavailable",
            "retryable":true}
    var visual_publication: Dictionary = visual_asset_registry.call(
        "published_catalog_snapshot", biome_publication)
    validation = _validate_ecology_owner_publication(visual_publication,
        "visual_assets")
    if String(validation.get("status", "")) != "ready":
        return validation
    if not is_instance_valid(animated_asset_registry) \
            or not animated_asset_registry.has_method("published_catalog_snapshot"):
        return {"status":"pending", "reason":"ecology_animated_publication_unavailable",
            "retryable":true}
    var animated_publication: Dictionary = animated_asset_registry.call(
        "published_catalog_snapshot")
    validation = _validate_ecology_owner_publication(animated_publication,
        "animated_assets")
    if String(validation.get("status", "")) != "ready":
        return validation
    return {"status":"ready", "worldId":world_id, "worldSeed":world_seed,
        "biome":biome_publication, "visual":visual_publication,
        "animated":animated_publication,
        "detailProducerInputs":_ecology_detail_producer_inputs()}


func _validate_ecology_owner_publication(publication: Dictionary,
        expected_owner_kind: String) -> Dictionary:
    var payload: Variant = publication.get("payload", null)
    var owner_receipt: Variant = publication.get("ownerReceipt", null)
    if String(publication.get("schema", "")) != "producer-catalog-owner-publication/v1" \
            or String(publication.get("ownerKind", "")) != expected_owner_kind \
            or String(publication.get("status", "")) != "ready" \
            or String(publication.get("contentDigest", "")).length() != 64 \
            or not publication.is_read_only() \
            or not payload is Dictionary or not payload.is_read_only() \
            or not owner_receipt is Dictionary or not owner_receipt.is_read_only():
        return {"status":"pending", "reason":"ecology_owner_publication_unsealed:%s" % expected_owner_kind,
            "ownerKind":expected_owner_kind, "retryable":true}
    return {"status":"ready"}


func _ecology_detail_producer_inputs() -> Dictionary:
    var detail_density := clampf(float(visual_quality.get("decorativeDensity", 0.74)),
        0.0, 1.0)
    var detail_attempt_cap := maxi(0, int(visual_quality.get("decorativeDetailCap", 72)))
    return {"schema":"ecology-detail-producer-inputs/v1",
        "density":detail_density, "attemptCap":detail_attempt_cap,
        "attempts":maxi(8, int(round(float(detail_attempt_cap) * detail_density))),
        "detailRecipeRevision":"detail-transform-recipes/v1"}


func _ecology_catalog_publication_signature(world_id: String, world_seed: String,
        publication_state: Dictionary) -> String:
    var owner_rows: Array = []
    var same_publications := not ecology_current_owner_publications.is_empty()
    for owner_kind: String in ["biome", "visual", "animated"]:
        var publication: Dictionary = publication_state.get(owner_kind, {})
        var prior_publication: Dictionary = ecology_current_owner_publications.get(owner_kind, {})
        if prior_publication.is_empty() or not is_same(publication, prior_publication):
            same_publications = false
        var owner_receipt: Dictionary = publication.get("ownerReceipt", {})
        var owner_instance_id: Variant = owner_receipt.get("ownerInstanceId",
            owner_receipt.get("owner_id", null))
        var publication_revision: Variant = owner_receipt.get("publicationRevision",
            owner_receipt.get("revision", null))
        if not (owner_instance_id is int) or not (publication_revision is int):
            return ""
        owner_rows.append([String(publication.get("ownerKind", "")),
            String(publication.get("contentDigest", "")),
            int(owner_instance_id), int(publication_revision)])
    var scope_key := _ecology_catalog_scope_key(world_id, world_seed, publication_state)
    if same_publications and scope_key == ecology_current_catalog_scope_key \
            and not ecology_current_catalog_signature.is_empty():
        return ecology_current_catalog_signature
    return EcologyProducerDomainScript.digest_value([
        "ecology-main-catalog-publication/v3", scope_key, owner_rows])


func _ecology_catalog_scope_key(world_id: String, world_seed: String,
        publication_state: Dictionary) -> String:
    var detail_inputs: Dictionary = publication_state.get("detailProducerInputs", {})
    var detail_digest := EcologyProducerDomainScript.digest_value(detail_inputs)
    var coordinator_id: int = world_static_section_coordinator.get_instance_id() \
        if is_instance_valid(world_static_section_coordinator) else 0
    var world_generation_id: int = world_generation_system.get_instance_id() \
        if is_instance_valid(world_generation_system) else 0
    return EcologyProducerDomainScript.digest_value([
        "ecology-main-catalog-scope/v1", world_id, world_seed,
        ecology_world_epoch, get_instance_id(), coordinator_id,
        world_generation_id, detail_digest])


func _active_ecology_catalog_artifact(world_id: String, world_seed: String) -> Dictionary:
    var current_world_id := _ecology_current_world_id()
    if world_id.is_empty() or world_id != current_world_id or world_seed != seed_text:
        return {"status":"failed", "reason":"ecology_catalog_context_world_identity_stale"}
    var context := ecology_producer_catalog_context.context_for(world_id, world_seed)
    if String(context.get("status", "")) != "ready":
        return {"status":"pending", "reason":"ecology_catalog_context_scope_required"}
    var artifact_id := String(context.get("artifactId", ""))
    return ecology_producer_catalog_context.resolve_active_scope_artifact(artifact_id,
        world_id, ecology_world_epoch)


func _ecology_current_world_id() -> String:
    if world_static_section_coordinator != null \
            and world_static_section_coordinator.has_method("world_identity"):
        return String(world_static_section_coordinator.call("world_identity"))
    return ""


func _ecology_catalog_owner_identity(world_id: String, world_seed: String,
        publication_state: Dictionary) -> Dictionary:
    var coordinator_id: int = world_static_section_coordinator.get_instance_id() \
        if is_instance_valid(world_static_section_coordinator) else 0
    var world_generation_id: int = world_generation_system.get_instance_id() \
        if is_instance_valid(world_generation_system) else 0
    var publications: Array = []
    for owner_kind: String in ["biome", "visual", "animated"]:
        var publication: Dictionary = publication_state.get(owner_kind, {})
        publications.append({"ownerKind":String(publication.get("ownerKind", "")),
            "contentDigest":String(publication.get("contentDigest", "")),
            "ownerReceipt":publication.get("ownerReceipt", {})})
    return {"worldId":world_id, "worldSeed":world_seed,
        "mainInstanceId":get_instance_id(),
        "worldCoordinatorInstanceId":coordinator_id,
        "worldGenerationInstanceId":world_generation_id,
        "worldEpoch":ecology_world_epoch,
        "ownerPublications":publications}


func _ecology_registry_owner_identity(owner: Variant, revision_property: String) -> Dictionary:
    if not is_instance_valid(owner): return {}
    var receipt: Dictionary = owner.call("generation_receipt") \
        if owner.has_method("generation_receipt") else {}
    return {"ownerInstanceId":owner.get_instance_id(),
        "generationRevision":int(owner.get(revision_property)),
        "generationReceipt":receipt}


func _retain_ecology_snapshot_artifact(snapshot: Dictionary,
        catalog_artifact: Dictionary, cache_identity: String) -> Dictionary:
    var existing_token := String(ecology_snapshot_catalog_leases.get(cache_identity, ""))
    if not existing_token.is_empty():
        ecology_snapshot_catalog_lease_order.erase(cache_identity)
        ecology_snapshot_catalog_lease_order.append(cache_identity)
        return {"status":"ready", "leaseToken":existing_token, "reused":true}
    var source_inputs: Variant = snapshot.get("sourceInputs", null)
    if not source_inputs is Dictionary or cache_identity.is_empty():
        return {"status":"failed", "reason":"ecology_snapshot_lease_identity_missing"}
    var result := acquire_ecology_catalog_artifact_lease(
        String(catalog_artifact.get("artifactId", "")), "source_snapshot",
        "snapshot:%s" % cache_identity, String(snapshot.get("worldId", "")),
        int(source_inputs.get("worldEpoch", -1)))
    if String(result.get("status", "")) != "ready": return result
    ecology_snapshot_catalog_leases[cache_identity] = String(result.get("leaseToken", ""))
    ecology_snapshot_catalog_lease_order.append(cache_identity)
    while ecology_snapshot_catalog_lease_order.size() \
            > MAX_RETAINED_ECOLOGY_SNAPSHOT_ARTIFACT_LEASES:
        var retired_identity: String = ecology_snapshot_catalog_lease_order.pop_front()
        var retired_token := String(ecology_snapshot_catalog_leases.get(retired_identity, ""))
        ecology_snapshot_catalog_leases.erase(retired_identity)
        release_ecology_catalog_artifact_lease(retired_token)
    return result


func advance_ecology_world_epoch_after_reset() -> Dictionary:
    if not Thread.is_main_thread():
        return {"status":"failed", "reason":"ecology_world_epoch_reset_requires_main_thread"}
    var sessions_reset := reset_ecology_source_capture_sessions()
    if String(sessions_reset.get("status", "")) != "ready":
        return sessions_reset
    var old_world_id := _ecology_current_world_id()
    var prior_current_lease := ecology_current_catalog_lease_token
    if is_instance_valid(tree_publication_queue) and tree_publication_queue.has_method(
            "reset_ecology_source_compilers"):
        var queue_reset_value: Variant = tree_publication_queue.call(
            "reset_ecology_source_compilers")
        if not queue_reset_value is Dictionary:
            return {"status":"failed", "reason":"ecology_source_queue_reset_result_invalid"}
        var queue_reset: Dictionary = queue_reset_value
        if String(queue_reset.get("status", "")) != "ready":
            # Preserve the current catalog authority and epoch until the queue
            # has retired every compiler/cache lease. The loading caller retries.
            return queue_reset
    ecology_current_catalog_artifact_id = ""
    ecology_current_catalog_content_digest = ""
    ecology_current_catalog_signature = ""
    ecology_current_catalog_scope_key = ""
    ecology_current_catalog_lease_token = ""
    ecology_current_owner_publications = {}
    ecology_world_epoch += 1
    if ecology_world_epoch <= 0: ecology_world_epoch = 1
    var reset := ecology_producer_catalog_context.reset_world(old_world_id,
        ecology_world_epoch)
    if not prior_current_lease.is_empty():
        ecology_producer_catalog_context.release_lease(prior_current_lease)
    ecology_snapshot_catalog_leases.clear()
    ecology_snapshot_catalog_lease_order.clear()
    ecology_producer_domain.clear_all_snapshots()
    return {"status":String(reset.get("status", "ready")),
        "worldEpoch":ecology_world_epoch, "revokedLeaseCount":int(
            reset.get("revokedLeaseCount", 0))}


func _ecology_source_capture_inputs(world_id: String, source_chunk_key: Vector2i,
        world_seed: String, source_inputs: Dictionary,
        catalog_artifact: Dictionary = {}) -> Dictionary:
    if not catalog_artifact.is_empty():
        var catalog_policy: Variant = catalog_artifact.get("supportPolicy", null)
        if not catalog_policy is Dictionary:
            return {}
        var artifact_source := {"schema":"ecology-source-domain-inputs/v2",
            "worldId":world_id, "worldSeed":world_seed,
            "catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
            "catalogContentDigest":String(catalog_artifact.get("catalogContentDigest", "")),
            "worldEpoch":ecology_world_epoch,
            "influencePolicyRevision":String(catalog_policy.get("revision", "")),
            "influencePolicyDigest":String(catalog_policy.get("digest", ""))}
        var policy := EcologyProducerDomainScript.support_policy(artifact_source,
            catalog_artifact)
        if String(policy.get("status", "")) != "ready":
            return {"_captureStatus":"pending", "_captureStage":"support_policy",
                "_captureReason":String(policy.get("runtimePolicyReason",
                    "ecology_source_support_policy_pending"))}
        var terrain_revision := ""
        if world_generation_system != null and world_generation_system.has_method(
                "terrain_volume_chunk_revision"):
            terrain_revision = str(world_generation_system.call(
                "terrain_volume_chunk_revision", source_chunk_key, CHUNK_SIZE))
        if terrain_revision.is_empty():
            return {"_captureStatus":"pending", "_captureStage":"terrain_revision",
                "_captureReason":"ecology_terrain_source_revision_unavailable"}
        var tree_envelope: Dictionary = catalog_artifact.get("catalogInputs", {}).get(
            "treeProducerEnvelope", {})
        var max_trunk_radius := float(tree_envelope.get("maxTrunkRadiusMeters", NAN))
        var max_canopy_radius := float(tree_envelope.get("maxCanopyRadiusMeters", NAN))
        if String(tree_envelope.get("status", "")) != "ready" \
                or not is_finite(max_trunk_radius) or max_trunk_radius <= 0.0 \
                or not is_finite(max_canopy_radius) or max_canopy_radius <= 0.0:
            return {"_captureStatus":"failed", "_captureStage":"tree_support_margin",
                "_captureReason":"ecology_tree_request_envelope_invalid"}
        var profiles: Array = catalog_artifact.catalogInputs.get(
            "biomeProfileSnapshot", {}).get("profiles", [])
        var max_exclusion := 0.0
        for profile_value: Variant in profiles:
            if not profile_value is Dictionary:
                return {"_captureStatus":"failed", "_captureStage":"natural_prop_margin",
                    "_captureReason":"ecology_profile_row_invalid"}
            var exclusion := _ecology_profile_number(profile_value,
                "natural_prop_exclusion_margin")
            if not is_finite(exclusion) or exclusion < 0.0:
                return {"_captureStatus":"failed", "_captureStage":"natural_prop_margin",
                    "_captureReason":"ecology_natural_prop_exclusion_margin_invalid"}
            max_exclusion = maxf(max_exclusion, exclusion)
        var natural_margin_cells := ceili((max_trunk_radius + max_exclusion) / CELL)
        var structure_margin_cells := ceili((max_canopy_radius + max_exclusion) / CELL)
        var source_bounds := Rect2i(source_chunk_key * CHUNK_SIZE,
            Vector2i.ONE * CHUNK_SIZE)
        if structure_system == null or not structure_system.has_method(
                "capture_ecology_structure_dependencies"):
            return {"_captureStatus":"pending", "_captureStage":"structure_dependencies",
                "_captureReason":"ecology_structure_dependency_api_unavailable"}
        var structure_dependencies: Dictionary = structure_system.call(
            "capture_ecology_structure_dependencies", source_bounds,
            natural_margin_cells, structure_margin_cells)
        var structure_status := String(structure_dependencies.get("status", "pending"))
        var structure_digest := String(structure_dependencies.get("contentDigest", ""))
        if structure_status != "ready" or structure_digest.length() != 64:
            return {"_captureStatus":structure_status if structure_status == "failed" else "pending",
                "_captureStage":"structure_dependencies",
                "_captureReason":String(structure_dependencies.get("reason",
                    "ecology_structure_dependency_snapshot_incomplete")),
                "structureDependencies":structure_dependencies,
                "structureDependencyContentDigest":structure_digest,
                "structureDependencyStatus":structure_status}
        return {"schema":"ecology-source-domain-inputs/v2",
            "worldId":world_id, "worldSeed":world_seed,
            "sourceChunkKey":source_chunk_key,
            "catalogArtifactId":String(catalog_artifact.artifactId),
            "catalogContentDigest":String(catalog_artifact.catalogContentDigest),
            "worldEpoch":ecology_world_epoch,
            "influencePolicyRevision":String(policy.revision),
            "influencePolicyDigest":String(policy.digest),
            "terrainVolumeChunkRevision":terrain_revision,
            "structureAdmissionRevision":structure_digest,
            "structureAdmissionStatus":structure_status,
            "structureDependencyStatus":structure_status,
            "structureDependencyContentDigest":structure_digest,
            "structureDependencies":structure_dependencies,
            "naturalMarginCells":natural_margin_cells,
            "structureMarginCells":structure_margin_cells}
    return {}


func _ecology_profile_number(profile: Dictionary, field: String) -> float:
    var encoded: Variant = profile.get(field, null)
    if encoded is not Dictionary: return NAN
    var value: Variant = encoded.get("value", null)
    return float(value) if value is float or value is int else NAN


func _resolve_ecology_source_artifact(source_inputs: Dictionary,
        catalog_lease_token: String) -> Dictionary:
    var world_id := String(source_inputs.get("worldId", _ecology_current_world_id()))
    var world_seed := String(source_inputs.get("worldSeed", seed_text))
    var artifact_id := String(source_inputs.get("catalogArtifactId", ""))
    if artifact_id.is_empty():
        var active := _active_ecology_catalog_artifact(world_id, world_seed)
        if String(active.get("status", "")) != "ready": return active
        artifact_id = String(active.artifactId)
    if not catalog_lease_token.is_empty():
        return resolve_ecology_catalog_artifact(catalog_lease_token, world_id,
            ecology_world_epoch)
    var active_context := ecology_producer_catalog_context.context_for(world_id, world_seed)
    if String(active_context.get("status", "")) == "ready" \
            and String(active_context.get("artifactId", "")) == artifact_id:
        return _active_ecology_catalog_artifact(world_id, world_seed)
    return {"status":"failed", "reason":"ecology_catalog_artifact_lease_required"}


func _build_ecology_source_catalog_inputs(world_id: String, world_seed: String,
        publication_state: Dictionary) -> Dictionary:
    var started_usec := Time.get_ticks_usec()
    var biome_publication: Dictionary = publication_state.get("biome", {})
    var visual_publication: Dictionary = publication_state.get("visual", {})
    var animated_publication: Dictionary = publication_state.get("animated", {})
    var biome_payload: Variant = biome_publication.get("payload", null)
    var visual_payload: Variant = visual_publication.get("payload", null)
    var animated_payload: Variant = animated_publication.get("payload", null)
    if not biome_payload is Dictionary or not visual_payload is Dictionary \
            or not animated_payload is Dictionary:
        return {"_status":"pending", "_reason":"ecology_catalog_owner_payload_missing"}
    var profile_rows: Variant = biome_payload.get("profiles", null)
    var asset_rows: Variant = visual_payload.get("assets", null)
    var family_rows: Variant = visual_payload.get("families", null)
    var static_descriptors: Variant = visual_payload.get("staticDescriptors", null)
    var rock_envelope: Variant = visual_payload.get("rockSupportEnvelope", null)
    var animated_assets: Variant = animated_payload.get("assets", null)
    var animated_descriptors: Variant = animated_payload.get("descriptors", null)
    if not profile_rows is Array or profile_rows.is_empty() \
            or not asset_rows is Array or not family_rows is Array \
            or not static_descriptors is Array or not rock_envelope is Dictionary \
            or not animated_assets is Array or not animated_descriptors is Array:
        return {"_status":"pending", "_reason":"ecology_catalog_owner_payload_incomplete"}
    var detail_inputs := _ecology_detail_producer_inputs()
    var profile_snapshot := {"schemaVersion":int(biome_payload.get("schemaVersion", -1)),
        "fallbackId":String(biome_payload.get("fallbackId", "")),
        "contentIdentity":String(biome_publication.get("contentDigest", "")),
        "profiles":profile_rows}
    if int(profile_snapshot.schemaVersion) != 1 \
            or String(profile_snapshot.fallbackId) != "default" \
            or String(profile_snapshot.contentIdentity).length() != 64:
        return {"_status":"failed", "_reason":"ecology_biome_publication_payload_invalid"}
    var inputs: Dictionary = {"worldId":world_id, "worldSeed":world_seed,
        "detailProducerInputs":detail_inputs,
        "biomeProfileSnapshotStatus":"ready",
        "biomeProfileSnapshot":profile_snapshot}
    var tree_request_envelope := EcologyProducerDomainScript.derive_tree_request_envelope(
        profile_snapshot)
    var tree_support_envelope := EcologyProducerDomainScript.derive_tree_grammar_support_envelope(
        profile_snapshot)
    var static_recipe_envelope := EcologyProducerDomainScript.derive_static_recipe_profile_envelope(
        profile_snapshot)
    if String(tree_request_envelope.get("status", "")) != "ready" \
            or String(tree_support_envelope.get("status", "")) != "ready" \
            or String(static_recipe_envelope.get("status", "")) != "ready":
        return {"_status":"pending", "_reason":"ecology_catalog_profile_envelope_pending",
            "treeRequestReason":String(tree_request_envelope.get("reason", "")),
            "treeSupportReason":String(tree_support_envelope.get("reason", "")),
            "staticRecipeReason":String(static_recipe_envelope.get("reason", "")),
            "treeRequestEnvelope":tree_request_envelope,
            "treeSupportEnvelope":tree_support_envelope,
            "staticRecipeEnvelope":static_recipe_envelope}
    var normalized_rock: Dictionary = rock_envelope
    if String(normalized_rock.get("status", "")) != "ready" \
            or String(normalized_rock.get("profileCatalogRevision", "")) \
                != String(profile_snapshot.contentIdentity):
        return {"_status":"pending", "_reason":"ecology_rock_support_publication_stale"}
    inputs["treeProducerEnvelopeStatus"] = "ready"
    inputs["treeProducerEnvelope"] = tree_request_envelope
    inputs["treeGrammarEnvelopeStatus"] = "ready"
    inputs["treeGrammarEnvelope"] = tree_support_envelope
    inputs["treeGrammarEnvelopeDigest"] = String(tree_support_envelope.get("digest", ""))
    inputs["rockSupportEnvelopeStatus"] = "ready"
    inputs["rockSupportEnvelope"] = normalized_rock
    inputs["staticRecipeEnvelopeStatus"] = "ready"
    inputs["staticRecipeEnvelope"] = static_recipe_envelope
    var visual_catalog := {"schema":"visual-owner-payload/v1",
        "contentIdentity":String(visual_publication.get("contentDigest", "")),
        "assets":asset_rows, "families":family_rows,
        "disabledIds":visual_payload.get("disabledIds", []),
        "sceneCache":visual_payload.get("sceneCache", []),
        "staticDescriptors":static_descriptors,
        "rockSupportEnvelope":normalized_rock}
    var definition_by_id: Dictionary = {}
    for asset_value: Variant in animated_assets:
        if not asset_value is Dictionary:
            return {"_status":"failed", "_reason":"ecology_animated_asset_row_invalid"}
        var asset_id := String(asset_value.get("id", ""))
        var definition: Variant = asset_value.get("definition", null)
        if asset_id.is_empty() or not definition is Dictionary \
                or definition_by_id.has(asset_id):
            return {"_status":"failed", "_reason":"ecology_animated_asset_identity_invalid"}
        definition_by_id[asset_id] = definition
    var animated_rows: Array[Dictionary] = []
    var animated_status := "ready"
    var animated_reason := ""
    var seen_animated_ids: Dictionary = {}
    for descriptor_value: Variant in animated_descriptors:
        if not descriptor_value is Dictionary:
            return {"_status":"failed", "_reason":"ecology_animated_descriptor_row_invalid"}
        var descriptor: Dictionary = descriptor_value
        var asset_id := String(descriptor.get("assetId", ""))
        var semantic_schema := String(descriptor.get("semanticSceneStateSchema", ""))
        var semantic_digest := String(descriptor.get("semanticSceneStateDigest", ""))
        var descriptor_status := String(descriptor.get("descriptorStatus", "failed"))
        if asset_id.is_empty() or seen_animated_ids.has(asset_id) \
                or not definition_by_id.has(asset_id):
            return {"_status":"failed", "_reason":"ecology_animated_descriptor_identity_invalid"}
        seen_animated_ids[asset_id] = true
        if semantic_schema != "animated-scene-semantic-state/v1" \
                or semantic_digest.length() != 64:
            animated_status = "failed"
            animated_reason = "animated_asset_semantic_scene_proof_unavailable:%s" % asset_id
        if descriptor_status != "ready" and descriptor_status != "failed":
            animated_status = "failed"
            animated_reason = String(descriptor.get("descriptorReason",
                "animated_asset_descriptor_not_ready:%s" % asset_id))
        animated_rows.append({"assetId":asset_id,
            "definition":definition_by_id[asset_id],
            "descriptorStatus":descriptor_status,
            "descriptorReason":String(descriptor.get("descriptorReason", "")),
            "semanticSceneStateSchema":semantic_schema,
            "semanticSceneStateDigest":semantic_digest,
            "rootNodeType":String(descriptor.get("rootNodeType", "")),
            "animationPlayerPresent":bool(descriptor.get("animationPlayerPresent", false)),
            "animationPlayerPath":String(descriptor.get("animationPlayerPath", "")),
            "availableClips":descriptor.get("availableClips", []),
            "expectedClip":String(descriptor.get("expectedClip", "")),
            "expectedClipAvailable":bool(descriptor.get("expectedClipAvailable", false)),
            "dependencyPaths":descriptor.get("dependencyPaths", [])})
    if seen_animated_ids.size() != definition_by_id.size():
        return {"_status":"failed", "_reason":"ecology_animated_descriptor_set_incomplete"}
    var animated_catalog := {"presentationStatus":animated_status,
        "presentationReason":animated_reason, "assets":animated_rows}
    inputs["visualCatalog"] = visual_catalog
    inputs["visualCatalogContentIdentity"] = String(visual_publication.get("contentDigest", ""))
    inputs["animatedCatalog"] = animated_catalog
    inputs["animatedCatalogContentIdentity"] = String(animated_publication.get("contentDigest", ""))
    inputs["producerCatalogRevision"] = EcologyProducerDomainScript.digest_value([
        "ecology-unified-source-pass/v2",
        String(biome_publication.get("contentDigest", "")),
        String(visual_publication.get("contentDigest", "")),
        String(animated_publication.get("contentDigest", "")),
        EcologyProducerDomainScript.digest_value(detail_inputs),
        String(tree_support_envelope.get("digest", "")),
        String(normalized_rock.get("digest", ""))])
    inputs["catalogInputSchema"] = "ecology-producer-catalog-inputs/v2"
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("ecology_catalog_inputs_total", started_usec)
        runtime_perf_monitor.increment_counter("ecology_catalog_input_compositions")
        runtime_perf_monitor.increment_counter("ecology_catalog_publication_compositions")
    return inputs


func _unique_ecology_string_values(values: Array[String]) -> Array[String]:
    var unique_values: Array[String] = []
    var prior := ""
    for value: String in values:
        if value == prior:
            continue
        unique_values.append(value)
        prior = value
    return unique_values


func _bounded_animated_descriptor_diagnostic(diagnostic: Dictionary) -> Dictionary:
    var bounded := {}
    for field: String in ["stage", "reason", "assetPath", "sceneStatePath",
            "nodePath", "nodeType", "propertyName", "propertyVariantType",
            "propertyClass", "animationLibraryKey"]:
        var value: Variant = diagnostic.get(field, null)
        if value is String or value is int or value is bool:
            bounded[field] = value
    return bounded


func _ecology_catalog_owner_receipt(catalog_artifact: Dictionary,
        expected_owner_kind: String) -> Dictionary:
    var owner_identity: Variant = catalog_artifact.get("ownerIdentity", null)
    if not owner_identity is Dictionary:
        return {}
    var publications: Variant = owner_identity.get("ownerPublications", null)
    if not publications is Array:
        return {}
    for publication_value: Variant in publications:
        if not publication_value is Dictionary \
                or String(publication_value.get("ownerKind", "")) != expected_owner_kind:
            continue
        var current_publication: Dictionary = {}
        var cached_publication: Dictionary = {}
        if expected_owner_kind == "animated_assets" \
                and is_instance_valid(animated_asset_registry) \
                and animated_asset_registry.has_method("published_catalog_snapshot"):
            current_publication = animated_asset_registry.call("published_catalog_snapshot")
            cached_publication = ecology_current_owner_publications.get("animated", {})
        elif expected_owner_kind == "visual_assets" \
                and is_instance_valid(visual_asset_registry) \
                and visual_asset_registry.has_method("published_catalog_snapshot"):
            var biome_publication: Dictionary = ecology_current_owner_publications.get(
                "biome", {})
            current_publication = visual_asset_registry.call(
                "published_catalog_snapshot", biome_publication)
            cached_publication = ecology_current_owner_publications.get("visual", {})
        else:
            return {}
        if not is_same(current_publication, cached_publication) \
                or String(current_publication.get("contentDigest", "")) \
                    != String(publication_value.get("contentDigest", "")) \
                or current_publication.get("ownerReceipt", {}) \
                    != publication_value.get("ownerReceipt", {}):
            return {}
        var receipt: Variant = current_publication.get("ownerReceipt", null)
        return receipt if receipt is Dictionary else {}
    return {}


func _ecology_source_pass_progress(state: Dictionary) -> Dictionary:
    var active_attempt_value: Variant = state.get("detailActiveAttempt", {})
    var active_attempt: Dictionary = active_attempt_value \
        if active_attempt_value is Dictionary else {}
    var floor_scan_value: Variant = state.get("undergroundVolumeFloorScan", {})
    var floor_scan: Dictionary = floor_scan_value if floor_scan_value is Dictionary else {}
    var detail_batch_keys_value: Variant = state.get("detailBatchKeys", [])
    var detail_batch_count: int = detail_batch_keys_value.size() \
        if detail_batch_keys_value is Array else 0
    var actor_intents_value: Variant = state.get("actorIntents", [])
    var actor_intent_count: int = actor_intents_value.size() \
        if actor_intents_value is Array else 0
    return {"phase":String(state.get("phase", "")),
        "surfaceAttempt":int(state.get("propIndex", 0)),
        "detailAttempt":int(state.get("detailIndex", 0)),
        "detailAttempts":int(state.get("detailAttempts", 0)),
        "detailAttemptPhase":String(active_attempt.get("phase", "")),
        "detailVariationIndex":int(active_attempt.get("variationIndex", 0)),
        "detailBatchIndex":int(state.get("detailBatchIndex", 0)),
        "detailBatchCount":detail_batch_count,
        "detailSourceRowCount":int((state.get("detailSourceRows", []) as Array).size()),
        "detailBatchesPresent":not (state.get("detailBatches", {}) as Dictionary).is_empty(),
        "detailActiveAttempt":active_attempt.duplicate(true),
        "undergroundColumn":int(state.get("undergroundScanColumn", 0)),
        "undergroundScanY":int(state.get("undergroundScanY", floor_scan.get("scanY", 0))),
        "undergroundColumnStarted":bool(state.get("undergroundScanColumnStarted", false)),
        "undergroundScanComplete":bool(state.get("undergroundScanComplete", false)),
        "undergroundCellsScanned":int(state.get("undergroundScanCellsProcessed", 0)),
        "undergroundScanRestarts":int(state.get("undergroundScanRestartCount", 0)),
        "undergroundCandidateCount":int((state.get("undergroundCandidates", []) as Array).size()),
        "undergroundAttempt":int(state.get("undergroundIndex", 0)),
        "undergroundLastAttempt":state.get("undergroundLastAttempt", {}),
        "sourceCount":int((state.get("sourceRows", []) as Array).size()),
        "naturalPropAdmission":state.get("naturalPropAdmission", {}),
        "sourceCaptureBlockedReason":String(state.get("sourceCaptureBlockedReason", "")),
        "sourceCaptureBlockedFamily":String(state.get("sourceCaptureBlockedFamily", "")),
        "sourceCaptureBlockedCategory":String(state.get("sourceCaptureBlockedCategory", "")),
        "sourceCaptureBlockedProducer":String(state.get("sourceCaptureBlockedProducer", "")),
        "sourceFamilyScoped":bool(state.get("sourceFamilyScoped", false)),
        "requestedSourceFamilies":(state.get("requestedSourceFamilies", []) as Array).duplicate(),
        "detailRngPresent":state.get("detailRng", null) is RandomNumberGenerator,
        "actorIntentCount":actor_intent_count,
        "completedCategories":(state.get("completedSourceCategories", []) as Array).duplicate()}


func _ecology_source_capture_disposition(state: Dictionary) -> String:
    # A source slice is productive work even when a time budget expires before
    # the public cursor changes. Yield only on an explicit external dependency.
    var admission_value: Variant = state.get("naturalPropAdmission", {})
    if admission_value is Dictionary \
            and String(admission_value.get("status", "ready")) != "ready":
        return "dependency_blocked"
    if not String(state.get("sourceCaptureBlockedReason", "")).is_empty():
        return "dependency_blocked"
    return "progress"


func _failed_ecology_source_domain(world_id: String, source_chunk_key: Vector2i,
        world_seed: String, source_inputs: Dictionary, reason: String,
        unsupported_categories: Array) -> Dictionary:
    return EcologyProducerDomainScript.seal_source_domain_snapshot({
        "worldId":world_id,
        "worldSeed":world_seed,
        "sourceChunkKey":source_chunk_key,
        "sourceInputs":source_inputs.duplicate(true),
        "sourceRows":[],
        "categoriesComplete":[],
        "producerComplete":false,
        "producerStatus":"failed",
        "failureReason":reason,
        "unsupportedCategories":unsupported_categories,
        "removedSourceProjectionDigest":EcologyProducerDomainScript.digest_value([]),
    })


func _removed_props_projection_for_source_chunk(source_chunk_key: Vector2i,
        removed_props_snapshot: Dictionary) -> Dictionary:
    if not bool(removed_props_snapshot.get("ok", false)) \
            or String(removed_props_snapshot.get("scope", "world")) == "requested_ids" \
            or not removed_props_snapshot.get("ids", null) is Array:
        return {"status":"failed", "reason":"ecology_removed_props_world_snapshot_required"}
    var removed_ids: Array[String] = []
    for id_value: Variant in removed_props_snapshot.get("ids", []):
        if not id_value is String:
            return {"status":"failed", "reason":"ecology_removed_props_id_invalid"}
        var prop_id := String(id_value)
        var prop_cell: Variant = _source_prop_id_cell(prop_id)
        if not prop_cell is Vector2i:
            return {"status":"failed", "reason":"ecology_removed_props_id_has_no_source_chunk", "propId":prop_id}
        var owner_key := Vector2i(floori(float(prop_cell.x) / float(CHUNK_SIZE)),
            floori(float(prop_cell.y) / float(CHUNK_SIZE)))
        if owner_key == source_chunk_key:
            removed_ids.append(prop_id)
    removed_ids.sort()
    return {"status":"ready", "removedIds":removed_ids,
        "digest":EcologyProducerDomainScript.digest_value(removed_ids)}


func _source_prop_id_cell(prop_id: String) -> Variant:
    var segments := prop_id.split(":", false)
    for segment_value: Variant in segments:
        var segment := String(segment_value)
        if not segment.contains(","):
            continue
        var coordinates := segment.split(",", false)
        if coordinates.size() == 2 and String(coordinates[0]).is_valid_int() \
                and String(coordinates[1]).is_valid_int():
            return Vector2i(int(coordinates[0]), int(coordinates[1]))
        if coordinates.size() >= 3 and String(coordinates[0]).is_valid_int() \
                and String(coordinates[2]).is_valid_int():
            return Vector2i(int(coordinates[0]), int(coordinates[2]))
    return null


## Currentness handshake for values-only tree/prop compilation. A record is
## admissible only when its immutable source context matches this running
## world's current terrain, structure-admission, removals and support policy.
func ecology_source_record_is_current(record: Dictionary,
        enclosing_provenance: Dictionary) -> Dictionary:
    var scope := begin_ecology_source_catalog_context_scope()
    if String(scope.get("status", "")) != "ready": return scope
    var current := _ecology_source_record_is_current_in_scope(record,
        enclosing_provenance, scope)
    var ended := end_ecology_source_catalog_context_scope(scope)
    if String(ended.get("status", "")) != "ready": return ended
    return current


func _ecology_source_record_is_current_in_scope(record: Dictionary,
        enclosing_provenance: Dictionary, scope: Dictionary) -> Dictionary:
    var source_chunk_key: Variant = record.get("sourceChunkKey",
        enclosing_provenance.get("sourceChunkKey", null))
    if not source_chunk_key is Vector2i:
        return {"status":"failed", "reason":"ecology_source_record_chunk_key_invalid"}
    var world_id := String(enclosing_provenance.get("worldId", ""))
    var current_world_id := ""
    if world_static_section_coordinator != null \
            and world_static_section_coordinator.has_method("world_identity"):
        current_world_id = String(world_static_section_coordinator.call("world_identity"))
    if world_id.is_empty() or world_id != current_world_id \
            or String(enclosing_provenance.get("worldSeed", "")) != seed_text:
        return {"status":"failed", "reason":"ecology_source_record_world_stale"}
    var source_inputs: Variant = enclosing_provenance.get("sourceInputs", null)
    if not source_inputs is Dictionary:
        return {"status":"pending", "reason":"ecology_source_record_inputs_pending"}
    var key: Vector2i = source_chunk_key
    var active := _active_ecology_catalog_artifact(world_id, seed_text)
    if String(active.get("status", "")) != "ready": return active
    if String(scope.get("artifactId", "")) != String(enclosing_provenance.get(
            "catalogArtifactId", "")) \
            or String(scope.get("catalogContentDigest", "")) != String(
                enclosing_provenance.get("catalogContentDigest", "")):
        return {"status":"failed", "reason":"ecology_source_record_catalog_stale"}
    var canonical_source_inputs := _ecology_source_capture_inputs(world_id, key,
        seed_text, source_inputs, active.artifact)
    if canonical_source_inputs != source_inputs:
        return {"status":"failed", "reason":"ecology_source_record_producer_inputs_stale"}
    var expected_terrain := ""
    if world_generation_system != null \
            and world_generation_system.has_method("terrain_volume_chunk_revision"):
        expected_terrain = str(world_generation_system.call("terrain_volume_chunk_revision",
            key, CHUNK_SIZE))
    if expected_terrain.is_empty():
        return {"status":"pending", "reason":"ecology_source_record_terrain_revision_pending"}
    var bounds := Rect2i(key * CHUNK_SIZE, Vector2i.ONE * CHUNK_SIZE)
    var structure_dependencies: Variant = source_inputs.get("structureDependencies", null)
    if not structure_dependencies is Dictionary:
        return {"status":"pending", "reason":"ecology_source_record_structure_revision_pending"}
    if String(source_inputs.get("terrainVolumeChunkRevision", "")) != expected_terrain \
            or String(source_inputs.get("structureAdmissionStatus", "")) != "ready":
        return {"status":"failed", "reason":"ecology_source_record_authority_revision_stale"}
    var removed_snapshot := ActiveRemovedPropsSnapshotScript.capture(self)
    if not bool(removed_snapshot.get("ok", false)):
        return {"status":"pending", "reason":"ecology_source_record_removal_snapshot_pending"}
    var removal_projection := _removed_props_projection_for_source_chunk(key, removed_snapshot)
    if removal_projection.get("status") != "ready":
        return {"status":"failed", "reason":"ecology_source_record_removal_projection_failed"}
    var removal_digest := String(removal_projection.get("digest", ""))
    var policy := EcologyProducerDomainScript.support_policy(canonical_source_inputs,
        active.artifact)
    var source_domain_revision := EcologyProducerDomainScript.source_domain_revision(world_id,
        seed_text, key, canonical_source_inputs, removal_digest, active.artifact)
    for field: String in ["influencePolicyRevision", "influencePolicyDigest"]:
        if String(enclosing_provenance.get(field, "")) != String(policy.get(
                "revision" if field == "influencePolicyRevision" else "digest", "")):
            return {"status":"failed", "reason":"ecology_source_record_policy_stale"}
    if String(enclosing_provenance.get("removedSourceProjectionDigest", "")) != removal_digest:
        return {"status":"failed", "reason":"ecology_source_record_removals_stale"}
    if String(enclosing_provenance.get("sourceDomainRevision", "")) != source_domain_revision \
            or String(record.get("sourceRevision", "")) != source_domain_revision \
            or String(record.get("producerRevision", "")) != source_domain_revision:
        return {"status":"failed", "reason":"ecology_source_record_revision_stale"}
    var record_id := String(record.get("sourceId", ""))
    if record_id.is_empty() or String(record.get("propId", "")) in removal_projection.get("removedIds", []):
        return {"status":"failed", "reason":"ecology_source_record_removed_or_unidentified"}
    var cache_identity := EcologyProducerDomainScript.snapshot_cache_identity(world_id,
        key, canonical_source_inputs, removal_digest, active.artifact)
    var captured := false
    var captured_row: Dictionary = {}
    var session_value: Variant = _ecology_source_capture_sessions.get(cache_identity, null)
    if session_value is Dictionary \
            and String(session_value.get("worldId", "")) == world_id \
            and int(session_value.get("worldEpoch", -1)) == ecology_world_epoch \
            and String(session_value.get("worldSeed", "")) == seed_text \
            and String(session_value.get("catalogArtifactId", "")) == String(
                active.artifact.get("artifactId", "")) \
            and String(session_value.get("sourceDomainRevision", "")) == source_domain_revision:
        var lease_token := String(session_value.get("sessionLeaseToken", ""))
        var lease_check: Dictionary = resolve_ecology_catalog_artifact(lease_token,
            world_id, ecology_world_epoch) if not lease_token.is_empty() else {}
        var session_state: Variant = session_value.get("state", null)
        if String(lease_check.get("status", "")) == "ready" \
                and session_state is Dictionary:
            for row_value: Variant in session_state.get("sourceRows", []):
                if row_value is Dictionary and String(row_value.get("sourceId", "")) == record_id \
                        and String(row_value.get("sourceRevision", "")) == source_domain_revision:
                    captured = true
                    captured_row = row_value
                    break
    if not captured:
        var cached_domain := ecology_producer_domain.completed_snapshot_for(world_id, key,
            canonical_source_inputs, removal_digest, active.artifact,
            [String(record.get("producerFamily", ""))], true)
        if cached_domain.get("status") == "ready":
            var snapshot: Dictionary = cached_domain.get("snapshot", {})
            for row_value: Variant in snapshot.get("sourceRows", []):
                if row_value is Dictionary and String(row_value.get("sourceId", "")) == record_id \
                        and String(row_value.get("sourceRevision", "")) == source_domain_revision:
                    captured = true
                    captured_row = row_value
                    break
    if not captured:
        return {"status":"pending", "reason":"ecology_source_record_not_in_current_pass",
            "cacheIdentity":cache_identity}
    if String(captured_row.get("assetId", "")) != "":
        if String(record.get("assetRevision", "")) != String(captured_row.get("assetRevision", "")) \
                or String(record.get("assetRevision", "")).is_empty():
            return {"status":"failed", "reason":"ecology_static_asset_source_revision_mismatch"}
        var descriptor_currentness := _ecology_static_asset_row_is_current(captured_row)
        if String(descriptor_currentness.get("status", "")) != "ready":
            return descriptor_currentness
    return {"status":"ready", "sourceDomainRevision":source_domain_revision,
        "sourceChunkKey":key, "sourceId":record_id}


## Row-free currentness check for complete-empty family results. It validates
## the same current catalog, terrain, structure and removal authorities as the
## record handshake without inventing a source/member identity.
func ecology_source_domain_is_current(snapshot: Dictionary,
        owner_lease_token := "", publication_view: Dictionary = {}) -> Dictionary:
    var scope := begin_ecology_source_catalog_context_scope()
    if String(scope.get("status", "")) != "ready":
        return scope
    var current := _ecology_source_domain_is_current_in_scope(snapshot, scope,
        owner_lease_token, publication_view)
    var ended := end_ecology_source_catalog_context_scope(scope)
    if String(ended.get("status", "")) != "ready":
        return ended
    return current


func ecology_source_domain_family_result(snapshot: Dictionary, family: String,
        owner_lease_token := "") -> Dictionary:
    var currentness := ecology_source_domain_is_current(snapshot, owner_lease_token)
    if String(currentness.get("status", "")) != "ready":
        return currentness
    var lease_token := owner_lease_token if not owner_lease_token.is_empty() \
        else String(snapshot.get("catalogLeaseToken", ""))
    var resolved := resolve_ecology_catalog_artifact(lease_token,
        String(snapshot.get("worldId", "")), int(snapshot.get("worldEpoch", -1)))
    if String(resolved.get("status", "")) != "ready":
        return resolved
    return EcologyProducerDomainScript.source_family_result(snapshot, family,
        resolved.get("artifact", {}))


func _ecology_source_domain_is_current_in_scope(snapshot: Dictionary,
        scope: Dictionary, owner_lease_token := "",
        publication_view: Dictionary = {}) -> Dictionary:
    var world_id := String(snapshot.get("worldId", ""))
    var world_seed := String(snapshot.get("worldSeed", ""))
    var source_key_value: Variant = snapshot.get("sourceChunkKey", null)
    if not source_key_value is Vector2i:
        return {"status":"failed", "reason":"ecology_source_domain_chunk_key_invalid"}
    var current_world_id := ""
    if world_static_section_coordinator != null \
            and world_static_section_coordinator.has_method("world_identity"):
        current_world_id = String(world_static_section_coordinator.call("world_identity"))
    if world_id.is_empty() or world_id != current_world_id \
            or world_seed.is_empty() or world_seed != seed_text \
            or int(snapshot.get("worldEpoch", -1)) != ecology_world_epoch:
        return {"status":"failed", "reason":"ecology_source_domain_world_stale"}
    var source_inputs_value: Variant = snapshot.get("sourceInputs", null)
    if not source_inputs_value is Dictionary:
        return {"status":"failed", "reason":"ecology_source_domain_inputs_missing"}
    var source_inputs: Dictionary = source_inputs_value
    var source_key: Vector2i = source_key_value
    var active := _active_ecology_catalog_artifact(world_id, world_seed)
    if String(active.get("status", "")) != "ready":
        return active
    var artifact: Dictionary = active.get("artifact", {})
    if String(scope.get("artifactId", "")) != String(snapshot.get("catalogArtifactId", "")) \
            or String(scope.get("catalogContentDigest", "")) != String(
                snapshot.get("catalogContentDigest", "")) \
            or String(artifact.get("artifactId", "")) != String(snapshot.get("catalogArtifactId", "")):
        return {"status":"failed", "reason":"ecology_source_domain_catalog_stale"}
    if not publication_view.is_empty():
        if not is_same(publication_view.get("payload", null), snapshot) \
                or String(publication_view.get("sourceDomainRevision", "")) \
                    != String(snapshot.get("sourceRevision", "")) \
                or String(publication_view.get("catalogArtifactId", "")) \
                    != String(artifact.get("artifactId", "")):
            return {"status":"failed", "reason":"ecology_source_domain_publication_alias_stale"}
    else:
        var lease_token := owner_lease_token if not owner_lease_token.is_empty() \
            else String(snapshot.get("catalogLeaseToken", ""))
        var lease_check := resolve_ecology_catalog_artifact(lease_token,
            world_id, ecology_world_epoch) if not lease_token.is_empty() else {}
        if String(lease_check.get("status", "")) != "ready" \
                or String(lease_check.get("artifactId", "")) != String(snapshot.get("catalogArtifactId", "")):
            return {"status":"failed", "reason":"ecology_source_domain_catalog_lease_stale"}
        if not EcologyProducerDomainScript.validate_source_domain_family_bundle(snapshot,
                world_id, source_key, artifact, snapshot.get("requestedFamilies", [])):
            return {"status":"failed", "reason":"ecology_source_domain_family_bundle_invalid"}
    var canonical_inputs := _ecology_source_capture_inputs(world_id, source_key,
        world_seed, source_inputs, artifact)
    if canonical_inputs != source_inputs:
        return {"status":"failed", "reason":"ecology_source_domain_inputs_stale"}
    var terrain_revision := ""
    if world_generation_system != null \
            and world_generation_system.has_method("terrain_volume_chunk_revision"):
        terrain_revision = str(world_generation_system.call(
            "terrain_volume_chunk_revision", source_key, CHUNK_SIZE))
    if terrain_revision.is_empty():
        return {"status":"pending", "reason":"ecology_source_domain_terrain_pending"}
    if terrain_revision != String(snapshot.get("terrainVolumeChunkRevision", "")):
        return {"status":"failed", "reason":"ecology_source_domain_terrain_stale"}
    var removed_snapshot := ActiveRemovedPropsSnapshotScript.capture(self)
    if not bool(removed_snapshot.get("ok", false)):
        return {"status":"pending", "reason":"ecology_source_domain_removal_snapshot_pending"}
    var projection := _removed_props_projection_for_source_chunk(source_key, removed_snapshot)
    if String(projection.get("status", "")) != "ready":
        return {"status":"failed", "reason":"ecology_source_domain_removal_projection_failed"}
    var removal_digest := String(projection.get("digest", ""))
    if removal_digest != String(snapshot.get("removedSourceProjectionDigest", "")):
        return {"status":"failed", "reason":"ecology_source_domain_removals_stale"}
    var expected_revision := EcologyProducerDomainScript.source_domain_revision(
        world_id, world_seed, source_key, canonical_inputs, removal_digest, artifact)
    if expected_revision.is_empty() or expected_revision != String(snapshot.get("sourceRevision", "")):
        return {"status":"failed", "reason":"ecology_source_domain_revision_stale"}
    return {"status":"ready", "sourceDomainRevision":expected_revision,
        "sourceChunkKey":source_key, "familyCoverageDigest":String(
            snapshot.get("familyCoverageDigest", ""))}


func _ecology_static_asset_row_is_current(row: Dictionary) -> Dictionary:
    if not is_instance_valid(visual_asset_registry) \
            or not visual_asset_registry.has_method("describe_static_asset_without_instantiation") \
            or not visual_asset_registry.has_method("static_asset_descriptor_is_current"):
        return {"status":"pending", "reason":"ecology_static_asset_descriptor_unavailable"}
    var asset_id := String(row.get("assetId", ""))
    if asset_id.is_empty():
        return {"status":"failed", "reason":"ecology_static_asset_id_missing"}
    var descriptor: Dictionary = visual_asset_registry.call(
        "describe_static_asset_without_instantiation", asset_id)
    if String(descriptor.get("status", "")) != "ready":
        return {"status":"pending", "reason":String(descriptor.get("reason",
            "ecology_static_asset_descriptor_pending")), "assetId":asset_id}
    if not bool(visual_asset_registry.call("static_asset_descriptor_is_current", descriptor)):
        return {"status":"failed", "reason":"ecology_static_asset_descriptor_stale",
            "assetId":asset_id}
    var expected_identity: Variant = row.get("assetDescriptorIdentity", null)
    if not expected_identity is Dictionary:
        return {"status":"failed", "reason":"ecology_static_asset_descriptor_identity_missing"}
    var receipt: Variant = descriptor.get("registryReceipt", {})
    var current_identity := {
        "catalogContentDigest":String(descriptor.get("catalogContentDigest", "")),
        "sceneContentDigest":String(descriptor.get("sceneContentDigest", "")),
        "registryRevision":String(receipt.get("revision", "")) if receipt is Dictionary else ""
    }
    if current_identity != expected_identity:
        return {"status":"failed", "reason":"ecology_static_asset_descriptor_content_changed",
            "assetId":asset_id}
    return {"status":"ready", "assetId":asset_id,
        "assetRevision":String(row.get("assetRevision", ""))}

func process_chunk_prop_spawn_state(
    state: Dictionary,
    prop_attempt_budget: int,
    detail_attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return true
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var phase := String(state.get("phase", "props"))
    if phase in ["props", "details", "detail_batches"] and structure_system != null:
        var bounds := Rect2i(Vector2i(
            int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE)),
            int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))), Vector2i.ONE * CHUNK_SIZE)
        var admission: Dictionary = structure_system.citadel_terrain_admission.request_bounds(bounds)
        state["naturalPropAdmission"] = admission
        if admission.get("status") != "ready":
            if source_capture and admission.get("status") == "failed":
                state["sourceCaptureFailure"] = String(admission.get("reason",
                    "ecology_structure_admission_failed"))
                return true
            # No random draws, attempt increments, terrain sampling or detail
            # publication until the source owner has decided this footprint.
            return false
    if phase == "props":
        var rng := state.get("rng") as RandomNumberGenerator
        if rng == null:
            return true
        var processed := 0
        var prop_index := int(state.get("propIndex", 0))
        while prop_index < 28 and processed < maxi(1, prop_attempt_budget):
            if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                break
            var prop_attempt_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
            spawn_chunk_prop_attempt(state, prop_index, rng)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_surface_prop_attempt", prop_attempt_start)
            prop_index += 1
            processed += 1
        state["propIndex"] = prop_index
        if prop_index < 28:
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        state["phase"] = "details"
        if source_capture:
            var surface_categories: Array = state.get("completedSourceCategories", [])
            for family: String in ["trees", "surface_rocks", "ore", "forage"]:
                if family not in surface_categories:
                    surface_categories.append(family)
            state["completedSourceCategories"] = surface_categories
            state["surfaceSourcePassComplete"] = true
            if bool(state.get("sourceFamilyScoped", false)):
                return false
    if String(state.get("phase", "")) == "details":
        var requested_families: Array = state.get("activeCaptureFamilies", [])
        if source_capture and bool(state.get("sourceFamilyScoped", false)) \
                and "details" not in requested_families:
            state["phase"] = "underground_props"
        else:
            if not process_chunk_detail_spawn_state(state, detail_attempt_budget, time_budget_ms, start_usec):
                return false
            if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                return false
            if source_capture and "details" not in state.get("completedSourceCategories", []):
                var detail_categories: Array = state.get("completedSourceCategories", [])
                detail_categories.append("details")
                state["completedSourceCategories"] = detail_categories
            state["phase"] = "underground_props"
            if source_capture and bool(state.get("sourceFamilyScoped", false)):
                return false
    if String(state.get("phase", "")) == "detail_batches":
        var requested_families: Array = state.get("activeCaptureFamilies", [])
        if source_capture and bool(state.get("sourceFamilyScoped", false)) \
                and "details" not in requested_families:
            state["phase"] = "underground_props"
        else:
            if not process_chunk_detail_batch_spawn_state(state, time_budget_ms, start_usec):
                return false
            if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                return false
            if source_capture and "details" not in state.get("completedSourceCategories", []):
                var detail_categories: Array = state.get("completedSourceCategories", [])
                detail_categories.append("details")
                state["completedSourceCategories"] = detail_categories
            state["phase"] = "underground_props"
            if source_capture and bool(state.get("sourceFamilyScoped", false)):
                return false
    if String(state.get("phase", "")) == "underground_props" \
            and not bool(state.get("surfaceStaticCategoriesEvaluated", false)):
        if source_capture:
            var complete_categories: Array = state.get("completedSourceCategories", [])
            for category: String in ["trees", "surface_rocks", "ore", "forage"]:
                if category not in complete_categories:
                    complete_categories.append(category)
            state["completedSourceCategories"] = complete_categories
        else:
            _mark_ecology_category_complete(state, "surface_rocks", "surface_spawn")
            _mark_ecology_category_complete(state, "ore", "surface_spawn")
            _mark_ecology_category_complete(state, "forage", "surface_spawn")
        state["surfaceStaticCategoriesEvaluated"] = true
    if String(state.get("phase", "")) == "underground_props":
        if source_capture:
            state["surfaceSourcePassComplete"] = true
        elif not bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)):
            # Surface props and decorative batches are now fully decided by
            # their existing RNG streams. Deep-floor scanning can continue
            # without withholding this surface source from horizon demand.
            chunk.set_meta("chunk_surface_candidate_scan_complete", true)
            chunk.set_meta("chunk_surface_candidate_source_revision", "%s:%d:%d:surface" % [
                seed_text, int(get("seed_hash")), chunk.get_instance_id()
            ])
        if not source_capture:
            _publish_surface_ecology_source_values(state)
        if not source_capture and bool(chunk.get_meta("horizon_visual_only", false)):
            _finalize_ecology_source_values(state)
            return true
        var requested_families: Array = state.get("activeCaptureFamilies", [])
        if source_capture and bool(state.get("sourceFamilyScoped", false)) \
                and "underground_props" not in requested_families:
            return true
        if not process_underground_chunk_prop_spawn_state(state, prop_attempt_budget, time_budget_ms, start_usec):
            return false
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        var scan_revision := _underground_prop_scan_revision(state)
        if not scan_revision.is_empty():
            if source_capture:
                var completed_categories: Array = state.get("completedSourceCategories", [])
                if "underground_props" not in completed_categories:
                    completed_categories.append("underground_props")
                state["completedSourceCategories"] = completed_categories
                state["sourcePassComplete"] = true
                state["sourceScanRevision"] = scan_revision
            else:
                _mark_ecology_category_complete(state, "underground_props",
                    "underground_exposed_floor_scan", scan_revision)
    var completed_chunk := valid_node3d_from_variant(state.get("chunk"))
    if not source_capture and completed_chunk != null:
        completed_chunk.set_meta("chunk_prop_candidate_scan_complete", true)
        completed_chunk.set_meta("chunk_prop_candidate_source_revision", "%s:%d:%d" % [
            seed_text, int(get("seed_hash")), completed_chunk.get_instance_id()
        ])
    if source_capture:
        state["sourcePassComplete"] = true
    else:
        _finalize_ecology_source_values(state)
    return true


## Read-only view of the real chunk prop publisher. Empty manifests are
## available only after the existing seeded spawn state has completed.
func chunk_prop_visual_source_scan_complete(chunk_key: Vector2i,
        near_bounds: Rect2i) -> bool:
    var chunk := chunks.get(chunk_key) as Node3D
    if visible_world_underground_visuals_required():
        return is_instance_valid(chunk) and bool(chunk.get_meta(
            "chunk_prop_candidate_scan_complete", false))
    var horizon_chunk := horizon_ecology_source.source_for(chunk_key) as Node3D
    if is_instance_valid(horizon_chunk) and bool(horizon_chunk.get_meta(
            "chunk_surface_candidate_scan_complete", false)):
        return true
    return is_instance_valid(chunk) and bool(chunk.get_meta(
        "chunk_surface_candidate_scan_complete", false))


func visible_world_underground_visuals_required() -> bool:
    if player == null or not is_instance_valid(player): return false
    var cell := Vector3i(world_to_cell(player.global_position.x), 0,
        world_to_cell(player.global_position.z))
    var surface_y := chunk_bound_surface_y_at_cell(cell)
    return ChunkPropVisualManifestScript.underground_visuals_required(
        player.global_position.y, surface_y, CELL)


func visible_chunk_prop_manifest(chunk_key: Vector2i, surface_only := false,
        capture_job: Object = null) -> Dictionary:
    var chunk := chunks.get(chunk_key) as Node3D
    var horizon_chunk := horizon_ecology_source.source_for(chunk_key) as Node3D
    var physical_handoff_manifest: Dictionary = {}
    var physical_handoff_job: Object = null
    if surface_only and horizon_chunk != null:
        # Keep the old far visual until the physical producer has completed
        # its surface scan and its live visual receipt can replace it.
        if chunk == null or not is_instance_valid(chunk) \
                or not bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)):
            chunk = horizon_chunk
        else:
            var physical_manifest := _bounded_physical_chunk_prop_manifest(
                chunk, chunk_key, true, capture_job)
            if physical_manifest.get("status") == "ready":
                physical_handoff_manifest = physical_manifest
            else:
                physical_handoff_job = physical_manifest.get("captureJob") as Object
                chunk = horizon_chunk
    elif not surface_only and horizon_chunk != null and chunk != null \
            and is_instance_valid(chunk) and bool(chunk.get_meta("chunk_prop_candidate_scan_complete", false)):
        # The far visual stays installed while the near producer catches up.
        var near_manifest := _bounded_physical_chunk_prop_manifest(
            chunk, chunk_key, false, capture_job)
        return near_manifest
    if chunk == null or not is_instance_valid(chunk):
        return {"status": "pending", "reason": "chunk_prop_source_missing", "chunk": chunk_key}
    var complete := bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)) if surface_only \
        else bool(chunk.get_meta("chunk_prop_candidate_scan_complete", false))
    var source_revision := String(chunk.get_meta("chunk_surface_candidate_source_revision", "")) if surface_only \
        else String(chunk.get_meta("chunk_prop_candidate_source_revision", ""))
    if not physical_handoff_manifest.is_empty(): return physical_handoff_manifest
    if not bool(chunk.get_meta("horizon_visual_only", false)):
        return _bounded_physical_chunk_prop_manifest(chunk, chunk_key, surface_only, capture_job)
    var cache_started_usec := Time.get_ticks_usec()
    var cached_manifest: Dictionary = horizon_chunk_prop_manifest_cache.capture_or_refresh(
        self, chunk, chunk_key, seed_text, source_revision, complete, CELL,
        CHUNK_SIZE, surface_only
    )
    _record_prop_capture_path("horizon_cache" if bool(chunk.get_meta("horizon_visual_only", false))
        else "static_fallback", "capture",
        "hit" if bool(cached_manifest.get("candidateSnapshotCacheHit", false))
        else String(cached_manifest.get("status", "")), "complete",
        Time.get_ticks_usec() - cache_started_usec)
    if is_instance_valid(physical_handoff_job):
        cached_manifest["captureJob"] = physical_handoff_job
    return cached_manifest


func _bounded_physical_chunk_prop_manifest(chunk: Node3D, chunk_key: Vector2i,
        surface_only: bool, capture_job: Object = null) -> Dictionary:
    var source_revision := String(chunk.get_meta("chunk_surface_candidate_source_revision", "")) \
        if surface_only else String(chunk.get_meta("chunk_prop_candidate_source_revision", ""))
    var complete := bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)) \
        if surface_only else bool(chunk.get_meta("chunk_prop_candidate_scan_complete", false))
    if complete and not is_instance_valid(capture_job):
        var cache_started_usec := Time.get_ticks_usec()
        var cached: Dictionary = physical_chunk_prop_manifest_cache.recall(self,
            chunk, chunk_key, seed_text, source_revision, surface_only, CELL)
        if bool(cached.get("scanComplete", false)):
            _record_prop_capture_path("physical_cache", "recall", "hit",
                "complete", Time.get_ticks_usec() - cache_started_usec)
            return cached
    var job := capture_job
    var entry := "continue" if is_instance_valid(job) else "begin"
    var started_usec := Time.get_ticks_usec()
    if not is_instance_valid(job):
        var begun: Dictionary = ChunkPropVisualManifestScript.begin_capture(self,
            chunk, chunk_key, seed_text, source_revision, complete, CELL, surface_only)
        job = begun.get("job") as Object
        if not is_instance_valid(job):
            _record_prop_capture_path("physical_bounded", entry,
                "source_pending" if begun.get("status") == "pending" else "failed",
                "begin", Time.get_ticks_usec() - started_usec)
            return begun
    var captured: Dictionary = job.call("advance", 128, 3000)
    if String(captured.get("reason", "")) == "chunk_prop_bounded_capture_budget":
        captured["captureJob"] = job
    var outcome := "complete" if bool(captured.get("scanComplete", false)) else \
        ("budget" if String(captured.get("reason", "")) == "chunk_prop_bounded_capture_budget" else \
        ("restart" if String(captured.get("reason", "")) == "chunk_prop_bounded_source_changed" else \
        String(captured.get("status", ""))))
    _record_prop_capture_path("physical_bounded", entry, outcome,
        String(captured.get("stage", "complete" if outcome == "complete" else "unknown")),
        Time.get_ticks_usec() - started_usec)
    if bool(captured.get("scanComplete", false)):
        physical_chunk_prop_manifest_cache.remember(self, chunk, chunk_key,
            seed_text, source_revision, surface_only, CELL, captured)
    return captured


func publish_chunk_prop_visual_readiness(readiness: Object, view_revision: int,
        near_bounds: Rect2i, chunk_key: Vector2i,
        observer_position: Vector3 = Vector3.INF,
        capture_job: Object = null) -> Dictionary:
    var phase_started_usec := Time.get_ticks_usec()
    if horizon_ecology_source.source_for(chunk_key) != null:
        horizon_ecology_source.refresh_ordinary_visual_ranges(self, chunk_key)
    var range_refresh_usec := maxi(0, Time.get_ticks_usec() - phase_started_usec)
    phase_started_usec = Time.get_ticks_usec()
    var manifest := visible_chunk_prop_manifest(chunk_key,
        not visible_world_underground_visuals_required(), capture_job)
    var capture_usec := maxi(0, Time.get_ticks_usec() - phase_started_usec)
    if manifest.get("status") == "failed" or not bool(manifest.get("scanComplete", false)):
        manifest["propPhaseUsec"] = {"rangeRefresh": range_refresh_usec,
            "capture": capture_usec, "submit": 0}
        return manifest
    var visual_observer := observer_position if observer_position.is_finite() else player.global_position
    phase_started_usec = Time.get_ticks_usec()
    var submitted: Dictionary = ChunkPropVisualManifestScript.submit(manifest, readiness, view_revision,
        near_bounds, visual_observer)
    submitted["propPhaseUsec"] = {"rangeRefresh": range_refresh_usec,
        "capture": capture_usec,
        "submit": maxi(0, Time.get_ticks_usec() - phase_started_usec)}
    submitted["propCandidateCount"] = int(manifest.get("candidateCount", 0))
    submitted["propSurfaceOnly"] = bool(manifest.get("surfaceOnly", false))
    if is_instance_valid(manifest.get("captureJob") as Object):
        submitted["captureJob"] = manifest.captureJob
    if submitted.get("status") == "ready":
        var physical_chunk := chunks.get(chunk_key) as Node3D
        if is_instance_valid(physical_chunk) \
                and int(manifest.get("chunkInstanceId", 0)) == physical_chunk.get_instance_id() \
                and horizon_ecology_source.source_for(chunk_key) != null:
            horizon_ecology_source.retire(chunk_key)
    if manifest.has("candidateSnapshotCacheHit"):
        submitted["candidateSnapshotCacheHit"] = manifest.candidateSnapshotCacheHit
        submitted["candidateSnapshotValidationUsec"] = manifest.get("candidateSnapshotValidationUsec", 0)
        submitted["candidateSnapshotRefreshUsec"] = manifest.get("candidateSnapshotRefreshUsec", 0)
        submitted["candidateSnapshotCaptureUsec"] = manifest.get("candidateSnapshotCaptureUsec", 0)
    return submitted

func chunk_prop_spawn_budget_elapsed(start_usec: int, time_budget_ms: float) -> bool:
    if time_budget_ms <= 0.0:
        return false
    return float(Time.get_ticks_usec() - start_usec) / 1000.0 >= time_budget_ms

func spawn_chunk_prop_attempt(state: Dictionary, i: int, rng: RandomNumberGenerator) -> void:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var x := start_x + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
    var z := start_z + 2 + rng.randi_range(0, CHUNK_SIZE - 4)
    var prop_id := "%s:%d,%d:%d" % [seed_text, x, z, i]
    if removed_props.has(prop_id):
        if source_capture:
            var tombstones: Array = state.get("removedSourceIds", [])
            if prop_id not in tombstones:
                tombstones.append(prop_id)
            state["removedSourceIds"] = tombstones
        return
    var block_check_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_block_check") if runtime_perf_monitor != null else Time.get_ticks_usec()
    if natural_props_blocked_at_cell(x, z):
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_block_check", block_check_start)
        return
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("chunk_surface_prop_block_check", block_check_start)
    var sample_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_sample") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var surface_sample := surface_volume_spawn_sample_at_cell(x, z)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("chunk_surface_prop_sample", sample_start)
    if surface_sample.is_empty() or not bool(surface_sample.get("found", false)):
        return
    var h := float(surface_sample.get("height", 0.0))
    if h < WATER_LEVEL + 1.0 or h > 92.0:
        return
    var biome := String(surface_sample.get("biome", "plains"))
    if biome == "town":
        return
    var rock_roll := rock_chance(biome, h)
    var tree_roll := tree_chance(biome) if h <= 70.0 else 0.0
    var forage_roll := forage_chance(biome)
    var wildlife_roll := wildlife_chance(biome, h)
    var prop_roll := rng.randf()
    var local_position := Vector3((x - start_x) * CELL, h, (z - start_z) * CELL)
    if prop_roll < rock_roll:
        var ore := ore_for_cell(biome, h, rng)
        if source_capture:
            if ore != "":
                for descriptor_value: Variant in make_ore_cluster(null, prop_id,
                        local_position, ore, rng, 2):
                    if descriptor_value is Dictionary:
                        _append_ecology_source_value(state, descriptor_value, "ore", "ore",
                            Vector3i(x, roundi(h / CELL), z), biome)
            else:
                var rock_value := build_rock_source_value(prop_id, local_position, biome,
                    rng, state.get("visualAssetOwnerReceipt", {}), true)
                _append_ecology_source_value(state, rock_value, "surface_rocks",
                    "surface_rocks", Vector3i(x, roundi(h / CELL), z), biome)
            return
        var rock_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_rock") if runtime_perf_monitor != null else Time.get_ticks_usec()
        if ore != "":
            chunk.set_meta("ecology_capture_context", _ecology_capture_context(
                state, "surface_spawn", "ore", i, Vector3i(x, roundi(h / CELL), z)))
            make_ore_cluster(chunk, prop_id, local_position, ore, rng, 2)
        else:
            chunk.set_meta("ecology_capture_context", _ecology_capture_context(
                state, "surface_spawn", "surface_rocks", i, Vector3i(x, roundi(h / CELL), z)))
            make_rock(chunk, prop_id, local_position, rng)
        chunk.remove_meta("ecology_capture_context")
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_rock", rock_start)
    elif prop_roll < rock_roll + tree_roll:
        if source_capture:
            var tree_value := build_tree_source_value(prop_id, local_position, biome, rng,
                Vector2i(x, z), state.get("supportPolicy", {}))
            if not tree_value.is_empty():
                _append_ecology_source_value(state, tree_value, "trees", "trees",
                    Vector3i(x, roundi(h / CELL), z), biome)
            else:
                _set_ecology_source_family_failure(state, "trees",
                    "tree_source_recipe_unavailable")
            return
        var tree_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_tree") if runtime_perf_monitor != null else Time.get_ticks_usec()
        make_tree(chunk, prop_id, local_position, biome, rng, Vector2i(x, z))
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_tree", tree_start)
    elif prop_roll < rock_roll + tree_roll + forage_roll:
        if source_capture:
            var forage_value: Variant = call("build_forage_source_value", prop_id,
                local_position, biome, rng)
            _append_ecology_source_value(state, forage_value, "forage", "forage",
                Vector3i(x, roundi(h / CELL), z), biome)
            return
        var forage_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_forage") if runtime_perf_monitor != null else Time.get_ticks_usec()
        chunk.set_meta("ecology_capture_context", _ecology_capture_context(
            state, "surface_spawn", "forage", i, Vector3i(x, roundi(h / CELL), z)))
        make_forage(chunk, prop_id, local_position, biome, rng)
        chunk.remove_meta("ecology_capture_context")
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_forage", forage_start)
    elif prop_roll < rock_roll + tree_roll + forage_roll + wildlife_roll:
        if source_capture:
            var actor_intent: Variant = call("build_wildlife_actor_intent",
                prop_id, local_position, biome, rng,
                state.get("animatedAssetOwnerReceipt", {}))
            if actor_intent.get("status", "") != "ready":
                if String(state.get("sourceCaptureFailure", "")).is_empty():
                    var failure_details: Dictionary = actor_intent.get(
                        "failureDetails", {})
                    failure_details["sourceChunkKey"] = Vector2i(
                        int(state.get("cx", 0)), int(state.get("cz", 0)))
                    failure_details["attemptIndex"] = i
                    failure_details["sourceCell"] = Vector3i(x, roundi(h / CELL), z)
                    failure_details["biome"] = biome
                    failure_details["propId"] = prop_id
                    state["sourceCaptureFailure"] = String(actor_intent.get("reason",
                        "wildlife_actor_intent_capture_failed"))
                    state["sourceCaptureFailureDetails"] = failure_details
            else:
                var actor_intents: Array = state.get("actorIntents", [])
                actor_intents.append(actor_intent)
                state["actorIntents"] = actor_intents
            return
        var wildlife_start: int = runtime_perf_monitor.begin_section("chunk_surface_prop_make_wildlife") if runtime_perf_monitor != null else Time.get_ticks_usec()
        make_wildlife(chunk, prop_id, local_position, biome, rng)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_surface_prop_make_wildlife", wildlife_start)


func _append_ecology_source_value(state: Dictionary, source_value: Dictionary,
        family: String, category: String, source_cell: Vector3i,
        biome := "") -> bool:
    var source_status := String(source_value.get("status", "ready"))
    if source_status == "pending":
        state["sourceCaptureBlockedReason"] = String(source_value.get("reason",
            "ecology_source_value_pending"))
        state["sourceCaptureBlockedFamily"] = String(source_value.get("family", family))
        state["sourceCaptureBlockedCategory"] = category
        state["sourceCaptureBlockedProducer"] = String(source_value.get("schema",
            source_value.get("sourceKind", source_value.get("sourceId", ""))))
        return false
    if source_value.is_empty() or source_status != "ready":
        _set_ecology_source_family_failure(state, family,
            String(source_value.get("reason", "ecology_source_value_unavailable")))
        return false
    var candidate_value: Variant = source_value.get("candidate", null)
    var row: Dictionary
    if candidate_value is Dictionary and not candidate_value.is_empty():
        row = candidate_value.duplicate(true)
    else:
        row = source_value.duplicate(true)
    if row.is_empty():
        _set_ecology_source_family_failure(state, family,
            String(source_value.get("failureReason", "ecology_source_candidate_missing")))
        return false
    var source_chunk_key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    var prop_id := String(source_value.get("propId", row.get("propId", "")))
    var source_id := String(row.get("sourceId", ""))
    if source_id.is_empty():
        source_id = "%s:%s:%s" % [seed_text, category, prop_id]
    if prop_id.is_empty() or removed_props.has(prop_id):
        var tombstones: Array = state.get("removedSourceIds", [])
        if not prop_id.is_empty() and prop_id not in tombstones:
            tombstones.append(prop_id)
        state["removedSourceIds"] = tombstones
        return false
    _bind_ecology_source_row(state, row, family, category)
    row["sourceId"] = source_id
    row["propId"] = prop_id
    if family == "trees":
        var runtime_spec: Variant = row.get("runtimeSpec", null)
        var envelope: Variant = state.get("catalogInputs", {}).get("treeProducerEnvelope", null)
        if not runtime_spec is Dictionary or not envelope is Dictionary \
                or String(envelope.get("status", "")) != "ready":
            _set_ecology_source_family_failure(state, family,
                "tree_request_envelope_unavailable")
            return false
        for pair: Array in [["visualHeight", "maxVisualHeightMeters"],
                ["trunkRadius", "maxTrunkRadiusMeters"],
                ["canopyRadius", "maxCanopyRadiusMeters"]]:
            var actual := float(runtime_spec.get(pair[0], NAN))
            var maximum := float(envelope.get(pair[1], NAN))
            if not is_finite(actual) or not is_finite(maximum) or actual > maximum + 0.0001:
                _set_ecology_source_family_failure(state, family,
                    "tree_request_exceeds_catalog_envelope")
                return false
        row["treeRequestEnvelopeDigest"] = String(envelope.get("digest", ""))
    if row.get("renderMembers", null) is Array:
        var member_rows: Array = row.get("renderMembers", [])
        for member_value: Variant in member_rows:
            if not member_value is Dictionary:
                _set_ecology_source_family_failure(state, family,
                    "ecology_source_member_invalid")
                return false
            var member: Dictionary = member_value
            if String(member.get("contentIdentityStatus", "ready")) == "pending":
                state["sourceCaptureBlockedReason"] = String(member.get(
                    "contentIdentityReason", "ecology_source_member_content_pending"))
                return false
            if not _valid_ecology_content_digest(String(member.get(
                    "meshContentDigest", ""))) \
                    or not _valid_ecology_content_digest(String(member.get(
                    "materialContentDigest", ""))):
                _set_ecology_source_family_failure(state, family,
                    "ecology_source_member_content_digest_unavailable")
                return false
            var source_part_id := String(member.get("sourcePartId", member.get("memberId", "")))
            if source_part_id.is_empty():
                _set_ecology_source_family_failure(state, family,
                    "ecology_source_member_part_id_missing")
                return false
            member["sourceId"] = source_id
            member["sourcePartId"] = source_part_id
        row["renderMembers"] = member_rows
    elif family != "trees":
        var source_part_id := String(row.get("sourcePartId", "render"))
        if source_part_id.is_empty():
            _set_ecology_source_family_failure(state, family,
                "ecology_source_member_part_id_missing")
            return false
        row["sourcePartId"] = source_part_id
    if source_value.has("supportProof"):
        row["supportProof"] = source_value.get("supportProof", {}).duplicate(true) \
            if source_value.get("supportProof", {}) is Dictionary else source_value.get("supportProof")
    row["sourceCell"] = source_cell
    if not biome.is_empty():
        row["biome"] = biome
    var transform_value: Variant = row.get("transform", Transform3D.IDENTITY)
    var local_position: Variant = source_value.get("position",
        transform_value.origin if transform_value is Transform3D else Vector3.ZERO)
    if local_position is Vector3:
        row["sourceOrigin"] = Vector3(
            float(int(state.get("startX", 0))) * CELL + local_position.x,
            local_position.y,
            float(int(state.get("startZ", 0))) * CELL + local_position.z)
    _prove_ecology_source_row_bounds(state, row, family)
    var rows: Array = state.get("sourceRows", [])
    rows.append(row)
    state["sourceRows"] = rows
    return true


func _set_ecology_source_family_failure(state: Dictionary, family: String,
        reason: String) -> void:
    var failures: Dictionary = state.get("sourceFamilyFailures", {})
    if not failures.has(family):
        failures[family] = {"reason":reason}
    state["sourceFamilyFailures"] = failures


func _bind_ecology_source_row(state: Dictionary, row: Dictionary,
        family: String, category: String) -> void:
    var source_inputs: Dictionary = state.get("sourceInputs", {})
    var source_chunk_key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
    var domain_revision := String(state.get("sourceDomainRevision", ""))
    row["schema"] = String(row.get("schema", "ecology.static_source_value.v1"))
    row["sourceChunkKey"] = source_chunk_key
    row["producerFamily"] = family
    row["category"] = category
    row["sourceRevision"] = domain_revision
    row["producerRevision"] = domain_revision
    row["sourceDomainRevision"] = domain_revision
    row["catalogArtifactId"] = String(source_inputs.get("catalogArtifactId", ""))
    row["catalogContentDigest"] = String(source_inputs.get("catalogContentDigest", ""))
    row["worldEpoch"] = int(source_inputs.get("worldEpoch", 0))
    row["terrainVolumeChunkRevision"] = String(source_inputs.get(
        "terrainVolumeChunkRevision", ""))
    row["structureAdmissionRevision"] = String(source_inputs.get(
        "structureAdmissionRevision", ""))
    row["structureAdmissionStatus"] = String(source_inputs.get(
        "structureAdmissionStatus", "pending"))
    row["removedSourceProjectionDigest"] = String(state.get(
        "removedSourceProjectionDigest", ""))
    row["influencePolicyRevision"] = String(state.get("influencePolicyRevision", ""))
    row["influencePolicyDigest"] = String(state.get("influencePolicyDigest", ""))


func _valid_ecology_content_digest(value: String) -> bool:
    return value.length() == 64 and value.is_valid_hex_number(false)


func _prove_ecology_source_row_bounds(state: Dictionary, row: Dictionary,
        family: String) -> void:
    var chunk_origin := Vector3(float(int(state.get("startX", 0))) * CELL, 0.0,
        float(int(state.get("startZ", 0))) * CELL)
    var chunk_to_world := Transform3D(Basis.IDENTITY, chunk_origin)
    var source_origin: Variant = row.get("sourceOrigin", chunk_origin)
    if not source_origin is Vector3:
        source_origin = chunk_origin
    var local_bounds: Variant = row.get("localBounds", null)
    var actual_world_bounds := AABB()
    var has_bounds := false
    if family == "trees" and local_bounds is AABB:
        var transform_value: Variant = row.get("transform", Transform3D.IDENTITY)
        if not transform_value is Transform3D:
            row["supportProof"] = {"status":"pending", "reason":"tree_source_transform_unavailable",
                "family":family}
            return
        if not (local_bounds as AABB).position.is_finite() \
                or not (local_bounds as AABB).size.is_finite() \
                or (local_bounds as AABB).size.x < 0.0 \
                or (local_bounds as AABB).size.y < 0.0 \
                or (local_bounds as AABB).size.z < 0.0:
            row["supportProof"] = {"status":"pending",
                "reason":"tree_nominal_source_bounds_invalid", "family":family}
            return
        var tree_world_transform: Transform3D = chunk_to_world * (transform_value as Transform3D)
        var tree_source_origin: Vector3 = source_origin as Vector3
        if not tree_world_transform.origin.is_equal_approx(tree_source_origin):
            row["supportProof"] = {"status":"pending",
                "reason":"tree_source_origin_transform_mismatch", "family":family}
            return
        var support_policy_value: Variant = state.get("supportPolicy", {})
        if not support_policy_value is Dictionary:
            row["supportProof"] = {"status":"pending",
                "reason":"tree_source_support_policy_unavailable", "family":family}
            return
        var support_families: Variant = support_policy_value.get("families", null)
        var tree_family_policy: Variant = support_families.get("trees", null) \
            if support_families is Dictionary else null
        if not tree_family_policy is Dictionary \
                or String(tree_family_policy.get("status", "")) != "bounded":
            row["supportProof"] = {"status":"pending",
                "reason":"tree_source_support_envelope_unavailable", "family":family}
            return
        var horizontal_support := float(tree_family_policy.get(
            "maxHorizontalSupportMeters", -1.0))
        var vertical_support := float(tree_family_policy.get(
            "maxVerticalSupportMeters", -1.0))
        var envelope_digest := String(tree_family_policy.get("envelopeDigest", ""))
        var envelope_revision := String(tree_family_policy.get("envelopeRevision", ""))
        if not is_finite(horizontal_support) or not is_finite(vertical_support) \
                or horizontal_support <= 0.0 or vertical_support <= 0.0 \
                or not _valid_ecology_content_digest(envelope_digest) \
                or envelope_revision != EcologyProducerDomainScript.TREE_SUPPORT_ENVELOPE_REVISION:
            row["supportProof"] = {"status":"pending",
                "reason":"tree_source_support_envelope_invalid", "family":family}
            return
        var horizontal_extent: Vector3 = Vector3(horizontal_support, 0.0, horizontal_support)
        var vertical_extent: Vector3 = Vector3(0.0, vertical_support, 0.0)
        actual_world_bounds = AABB(tree_source_origin - horizontal_extent - vertical_extent,
            Vector3(horizontal_support * 2.0, vertical_support * 2.0,
                horizontal_support * 2.0))
        has_bounds = true
    elif family == "details" and local_bounds is AABB:
        var raw_mesh_bounds: Variant = row.get("meshBounds", null)
        var detail_transform: Variant = row.get("transform", null)
        if not raw_mesh_bounds is AABB or not detail_transform is Transform3D:
            row["supportProof"] = {"status":"pending", "reason":"detail_raw_geometry_bounds_unavailable",
                "family":family}
            return
        var declared_local_bounds: AABB = (detail_transform as Transform3D) \
            * (raw_mesh_bounds as AABB)
        if not declared_local_bounds.is_equal_approx(local_bounds):
            row["supportProof"] = {"status":"pending",
                "reason":"detail_forward_bounds_declaration_mismatch", "family":family}
            return
        actual_world_bounds = chunk_to_world * (detail_transform as Transform3D) \
            * (raw_mesh_bounds as AABB)
        has_bounds = true
    elif row.get("renderMembers", null) is Array:
        var body_transform := Transform3D.IDENTITY
        var row_transform: Variant = row.get("transform", null)
        if row_transform is Transform3D:
            body_transform = row_transform
        else:
            var position: Variant = row.get("position", Vector3.ZERO)
            var rotation: Variant = row.get("bodyRotation", Vector3.ZERO)
            if position is Vector3 and rotation is Vector3:
                body_transform = Transform3D(Basis.from_euler(rotation), position)
        var missing_member_bounds := false
        for member_value: Variant in row.get("renderMembers", []):
            if not member_value is Dictionary:
                missing_member_bounds = true
                break
            var raw_mesh_bounds: Variant = member_value.get("meshBounds", null)
            var member_transform: Variant = member_value.get("transform", Transform3D.IDENTITY)
            var declared_member_bounds: Variant = member_value.get("localBounds", null)
            if not raw_mesh_bounds is AABB or not member_transform is Transform3D \
                    or not declared_member_bounds is AABB:
                missing_member_bounds = true
                break
            var expected_member_bounds: AABB = (member_transform as Transform3D) \
                * (raw_mesh_bounds as AABB)
            if not expected_member_bounds.is_equal_approx(declared_member_bounds):
                missing_member_bounds = true
                break
            var complete_transform := chunk_to_world * body_transform \
                * (member_transform as Transform3D)
            var member_bounds: AABB = complete_transform * (raw_mesh_bounds as AABB)
            actual_world_bounds = member_bounds if not has_bounds else actual_world_bounds.merge(member_bounds)
            has_bounds = true
        if missing_member_bounds:
            row["supportProof"] = {"status":"pending",
                "reason":"static_member_raw_geometry_bounds_unavailable", "family":family}
            return
    elif local_bounds is AABB:
        var body_transform := Transform3D.IDENTITY
        var row_transform: Variant = row.get("transform", null)
        if row_transform is Transform3D:
            body_transform = row_transform
        else:
            var position: Variant = row.get("position", Vector3.ZERO)
            var rotation: Variant = row.get("bodyRotation", Vector3.ZERO)
            if position is Vector3 and rotation is Vector3:
                body_transform = Transform3D(Basis.from_euler(rotation), position)
        actual_world_bounds = chunk_to_world * body_transform * local_bounds
        has_bounds = true
    if not has_bounds:
        row["supportProof"] = {"status":"pending", "reason":"source_geometry_bounds_unavailable",
            "family":family}
        return
    var proof := EcologyProducerDomainScript.validate_source_bounds(family,
        source_origin, actual_world_bounds, state.get("supportPolicy", {}))
    proof["worldBounds"] = actual_world_bounds
    proof["sourceOrigin"] = source_origin
    proof["influencePolicyRevision"] = String(state.get("influencePolicyRevision", ""))
    proof["influencePolicyDigest"] = String(state.get("influencePolicyDigest", ""))
    row["supportProof"] = proof

func process_underground_chunk_prop_spawn_state(
    state: Dictionary,
    attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return true
    if state.get("undergroundCandidates", null) == null:
        state["undergroundCandidates"] = []
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    if bool(state.get("undergroundScanComplete", false)) and int(state.get("undergroundIndex", 0)) == 0 \
            and world_generation_system != null \
            and (world_generation_system.has_method("exposed_underground_floor_scan_source_revision") \
                or world_generation_system.has_method("terrain_volume_chunk_revision")):
        var completed_scan: Dictionary = state.get("undergroundVolumeFloorScan", {}) \
            if state.get("undergroundVolumeFloorScan", {}) is Dictionary else {}
        var completed_revision := str(completed_scan.get("revision", ""))
        var current_revision := ""
        var scan_chunk_key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
        if world_generation_system.has_method("exposed_underground_floor_scan_source_revision"):
            current_revision = str(world_generation_system.call(
                "exposed_underground_floor_scan_source_revision", scan_chunk_key, CHUNK_SIZE))
        elif world_generation_system.has_method("terrain_volume_chunk_revision"):
            current_revision = str(world_generation_system.call(
                "terrain_volume_chunk_revision", scan_chunk_key, CHUNK_SIZE))
        if not completed_revision.is_empty() and completed_revision != current_revision:
            # Revalidate the completed scan before its first RNG draw. Once
            # publication starts, that source/order is pinned for this chunk.
            state["undergroundScanComplete"] = false
    if not bool(state.get("undergroundScanComplete", false)):
        var scan_budget := maxi(8, maxi(1, attempt_budget) * 8)
        var scan_start: int = runtime_perf_monitor.begin_section("chunk_underground_prop_scan") if runtime_perf_monitor != null else Time.get_ticks_usec()
        if not scan_underground_prop_candidates(state, scan_budget, time_budget_ms, start_usec):
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_underground_prop_scan", scan_start)
            return false
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_underground_prop_scan", scan_start)
        if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    if candidates.is_empty():
        return true
    var rng := state.get("undergroundRng") as RandomNumberGenerator
    if rng == null:
        return true
    var processed := 0
    var index := int(state.get("undergroundIndex", 0))
    while index < candidates.size() and processed < maxi(1, attempt_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var cell_value = candidates[index]
        if cell_value is Vector3i:
            var underground_attempt_start: int = runtime_perf_monitor.begin_section("chunk_underground_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var rng_state_before: int = rng.state
            var source_rows_before: Array = (state.get("sourceRows", []) as Array).duplicate(false)
            var removed_ids_before: Array = (state.get("removedSourceIds", []) as Array).duplicate(false)
            state["sourceCaptureBlockedReason"] = ""
            state["undergroundAttemptBranch"] = "unclassified"
            if source_capture and OS.get_environment("VOXEL_ECOLOGY_SOURCE_TRACE") == "1":
                print("ECOLOGY_UNDERGROUND_CANDIDATE start chunk=(%d,%d) index=%d/%d cell=%s sourceCount=%d" % [
                    int(state.get("cx", 0)), int(state.get("cz", 0)), index,
                    candidates.size(), str(cell_value),
                    (state.get("sourceRows", []) as Array).size()])
            spawn_underground_prop_attempt(state, cell_value, rng)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_underground_prop_attempt", underground_attempt_start)
            var blocked_reason := String(state.get("sourceCaptureBlockedReason", ""))
            if source_capture and not blocked_reason.is_empty():
                rng.state = rng_state_before
                state["sourceRows"] = source_rows_before
                state["removedSourceIds"] = removed_ids_before
                state["undergroundLastAttempt"] = {"index":index,
                    "cell":cell_value, "status":"pending", "reason":blocked_reason,
                    "branch":String(state.get("undergroundAttemptBranch", "unclassified")),
                    "elapsedUsec":Time.get_ticks_usec() - underground_attempt_start}
                if OS.get_environment("VOXEL_ECOLOGY_SOURCE_TRACE") == "1":
                    print("ECOLOGY_UNDERGROUND_CANDIDATE pending chunk=(%d,%d) index=%d cell=%s branch=%s reason=%s elapsedUsec=%d" % [
                        int(state.get("cx", 0)), int(state.get("cz", 0)), index,
                        str(cell_value), String(state.get("undergroundAttemptBranch", "unclassified")),
                        blocked_reason, Time.get_ticks_usec() - underground_attempt_start])
                return false
            state["undergroundLastAttempt"] = {"index":index,
                "cell":cell_value, "status":"ready",
                "branch":String(state.get("undergroundAttemptBranch", "unclassified")),
                "elapsedUsec":Time.get_ticks_usec() - underground_attempt_start}
            if source_capture and OS.get_environment("VOXEL_ECOLOGY_SOURCE_TRACE") == "1":
                print("ECOLOGY_UNDERGROUND_CANDIDATE ready chunk=(%d,%d) index=%d cell=%s branch=%s elapsedUsec=%d" % [
                    int(state.get("cx", 0)), int(state.get("cz", 0)), index,
                    str(cell_value), String(state.get("undergroundAttemptBranch", "unclassified")),
                    Time.get_ticks_usec() - underground_attempt_start])
        index += 1
        processed += 1
    state["undergroundIndex"] = index
    return index >= candidates.size()

func underground_prop_candidate_cells(cx: int, cz: int) -> Array[Vector3i]:
    var scan_state := {
        "cx": cx,
        "cz": cz,
        "startX": cx * CHUNK_SIZE,
        "startZ": cz * CHUNK_SIZE,
        "undergroundCandidates": [],
        "undergroundScanColumn": 0,
        "undergroundScanY": 0,
        "undergroundScanColumnStarted": false,
        "undergroundScanComplete": false
    }
    while not scan_underground_prop_candidates(scan_state, CHUNK_SIZE * CHUNK_SIZE * 96, -1.0, 0):
        pass
    var candidates: Array = scan_state.get("undergroundCandidates", []) if scan_state.get("undergroundCandidates", []) is Array else []
    var result: Array[Vector3i] = []
    for cell_value in candidates:
        if cell_value is Vector3i:
            result.append(cell_value)
    return result

func scan_underground_prop_candidates(
    state: Dictionary,
    sample_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    if world_generation_system != null and world_generation_system.has_method("advance_exposed_underground_floor_scan"):
        return scan_underground_prop_candidates_from_volume_service(state, sample_budget, time_budget_ms, budget_start_usec)
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        state["undergroundScanComplete"] = true
        return true
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    var max_candidates := 36
    if candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
        state["undergroundCandidates"] = candidates
        return true
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var total_columns := CHUNK_SIZE * CHUNK_SIZE
    var column_index := int(state.get("undergroundScanColumn", 0))
    var y := int(state.get("undergroundScanY", 0))
    var column_started := bool(state.get("undergroundScanColumnStarted", false))
    var bottom_y := int(world_generation_system.call("world_bottom_cell_y")) if world_generation_system.has_method("world_bottom_cell_y") else floori((MIN_HEIGHT - CELL * 4.0) / CELL)
    var processed := 0
    var found_count_before := candidates.size()
    while column_index < total_columns and candidates.size() < max_candidates and processed < maxi(1, sample_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var lx := column_index % CHUNK_SIZE
        var lz := floori(float(column_index) / float(CHUNK_SIZE))
        var cell_x := start_x + lx
        var cell_z := start_z + lz
        if not column_started:
            var surface_y := chunk_reference_surface_y_for_volume_scan(cell_x, cell_z)
            y = floori(surface_y / CELL) + 1
            column_started = true
        var finished_column := false
        while y > bottom_y and processed < maxi(1, sample_budget):
            if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
                break
            var air_cell := Vector3i(cell_x, y, cell_z)
            processed += 1
            if underground_air_floor_cell_is_valid(air_cell):
                var floor_cell := air_cell + Vector3i(0, -1, 0)
                var roll := hash01("underground-prop-candidate:%d,%d,%d" % [floor_cell.x, floor_cell.y, floor_cell.z])
                if roll <= 0.18:
                    candidates.append(floor_cell)
                finished_column = true
                break
            y -= 1
        if finished_column or y <= bottom_y:
            column_index += 1
            y = 0
            column_started = false
        else:
            break
    state["undergroundCandidates"] = candidates
    state["undergroundScanColumn"] = column_index
    state["undergroundScanY"] = y
    state["undergroundScanColumnStarted"] = column_started
    if column_index >= total_columns or candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
    if runtime_perf_monitor != null and processed > 0:
        runtime_perf_monitor.increment_counter("underground_prop_cells_scanned", processed)
        var found_delta := candidates.size() - found_count_before
        if found_delta > 0:
            runtime_perf_monitor.increment_counter("underground_prop_candidates_found", found_delta)
    return bool(state.get("undergroundScanComplete", false))

func scan_underground_prop_candidates_from_volume_service(
    state: Dictionary,
    sample_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var candidates: Array = state.get("undergroundCandidates", []) if state.get("undergroundCandidates", []) is Array else []
    var max_candidates := 36
    if candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
        state["undergroundCandidates"] = candidates
        return true
    var scan_state: Dictionary = state.get("undergroundVolumeFloorScan", {}) if state.get("undergroundVolumeFloorScan", {}) is Dictionary else {}
    if scan_state.is_empty():
        var chunk_key := Vector2i(int(state.get("cx", 0)), int(state.get("cz", 0)))
        if world_generation_system.has_method("begin_exposed_underground_floor_scan"):
            scan_state = world_generation_system.call("begin_exposed_underground_floor_scan", chunk_key, CHUNK_SIZE)
        else:
            state["undergroundScanComplete"] = true
            state["undergroundCandidates"] = candidates
            return true
    var result: Dictionary = world_generation_system.call(
        "advance_exposed_underground_floor_scan",
        scan_state,
        maxi(1, int(sample_budget)),
        time_budget_ms,
        budget_start_usec
    )
    scan_state = result.get("state", scan_state) if result.get("state", scan_state) is Dictionary else scan_state
    state["undergroundVolumeFloorScan"] = scan_state
    state["undergroundScanLastSliceCells"] = int(result.get("processed", 0))
    state["undergroundScanCellsProcessed"] = int(
        state.get("undergroundScanCellsProcessed", 0)) \
        + int(result.get("processed", 0))
    state["undergroundScanColumn"] = int(scan_state.get("columnIndex", 0))
    state["undergroundScanY"] = int(scan_state.get("scanY", 0))
    if bool(result.get("restarted", false)):
        # The volume owner discarded its old scan cursor after a source
        # revision change. Its prior cells are no longer one complete source;
        # no underground RNG draws have happened before scan completion.
        candidates.clear()
        state["undergroundIndex"] = 0
        state["undergroundScanRestartCount"] = int(
            state.get("undergroundScanRestartCount", 0)) + 1
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("underground_prop_scan_restarts")
    var found_count_before := candidates.size()
    var new_candidates: Array = result.get("newCandidates", []) if result.get("newCandidates", []) is Array else []
    var seen_cells := {}
    for candidate_value in candidates:
        if candidate_value is Vector3i:
            seen_cells[candidate_value] = true
    for cell_value in new_candidates:
        if candidates.size() >= max_candidates:
            break
        if not (cell_value is Vector3i):
            continue
        var floor_cell: Vector3i = cell_value
        if seen_cells.has(floor_cell):
            continue
        var roll := hash01("underground-prop-candidate:%d,%d,%d" % [floor_cell.x, floor_cell.y, floor_cell.z])
        if roll <= 0.18:
            candidates.append(floor_cell)
            seen_cells[floor_cell] = true
    state["undergroundCandidates"] = candidates
    if bool(result.get("complete", false)) or candidates.size() >= max_candidates:
        state["undergroundScanComplete"] = true
    if runtime_perf_monitor != null:
        var processed := int(result.get("processed", 0))
        if processed > 0:
            runtime_perf_monitor.increment_counter("underground_prop_cells_scanned", processed)
            runtime_perf_monitor.increment_counter("underground_prop_volume_service_scans")
            var found_delta := candidates.size() - found_count_before
            if found_delta > 0:
                runtime_perf_monitor.increment_counter("underground_prop_candidates_found", found_delta)
    return bool(state.get("undergroundScanComplete", false))

func underground_air_floor_cell_is_valid(air_cell: Vector3i) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        return false
    var air_sample: Dictionary = world_generation_system.call("sample_cell", air_cell)
    if bool(air_sample.get("solid", true)):
        return false
    if String(air_sample.get("biome", "")) != "underground_air":
        return false
    if String(air_sample.get("fluid", "")) != "":
        return false
    var head_sample: Dictionary = world_generation_system.call("sample_cell", air_cell + Vector3i(0, 1, 0))
    if bool(head_sample.get("solid", false)):
        return false
    return underground_prop_cell_is_valid(air_cell + Vector3i(0, -1, 0))

func underground_prop_cell_is_valid(solid_cell: Vector3i) -> bool:
    if world_generation_system == null or not world_generation_system.has_method("sample_cell"):
        return false
    var air_cell := solid_cell + Vector3i(0, 1, 0)
    var air_sample: Dictionary = world_generation_system.call("sample_cell", air_cell)
    if bool(air_sample.get("solid", true)):
        return false
    if String(air_sample.get("biome", "")) != "underground_air":
        return false
    if String(air_sample.get("fluid", "")) != "":
        return false
    var solid_sample: Dictionary = world_generation_system.call("sample_cell", solid_cell)
    var material := String(solid_sample.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        return false
    return true

func spawn_underground_prop_attempt(state: Dictionary, solid_cell: Vector3i, rng: RandomNumberGenerator) -> void:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var prop_id := "%s:underground:%d,%d,%d" % [seed_text, solid_cell.x, solid_cell.y, solid_cell.z]
    if removed_props.has(prop_id):
        if source_capture:
            var tombstones: Array = state.get("removedSourceIds", [])
            if prop_id not in tombstones:
                tombstones.append(prop_id)
            state["removedSourceIds"] = tombstones
        return
    var solid_sample: Dictionary = world_generation_system.call("sample_cell", solid_cell) if world_generation_system != null and world_generation_system.has_method("sample_cell") else {}
    var material := String(solid_sample.get("material", "stone"))
    var air_cell := solid_cell + Vector3i(0, 1, 0)
    var local_position := Vector3((float(solid_cell.x - start_x) + 0.5) * CELL, float(air_cell.y) * CELL + CELL * 0.04, (float(solid_cell.z - start_z) + 0.5) * CELL)
    var roll := rng.randf()
    var scan_state: Variant = state.get("undergroundVolumeFloorScan", {})
    var scan_revision := str(scan_state.get("revision", "")) if scan_state is Dictionary else ""
    if scan_revision.is_empty():
        scan_revision = _underground_prop_scan_revision(state)
    if material in ["copperOre", "ironOre"]:
        state["undergroundAttemptBranch"] = "ore_material"
        if source_capture:
            _capture_underground_ore_values(state, prop_id, local_position, material, rng,
                solid_cell)
            return
        chunk.set_meta("ecology_capture_context", _ecology_capture_context(state,
            "underground_exposed_floor_scan", "underground_props", int(state.get("undergroundIndex", -1)),
            solid_cell, scan_revision))
        make_ore_cluster(chunk, prop_id, local_position, material, rng, 1)
        chunk.remove_meta("ecology_capture_context")
        return
    if roll < 0.12 and material in ["stone", "deepStone", "bedrock"]:
        state["undergroundAttemptBranch"] = "ore_roll"
        var ore := "ironOre" if solid_cell.y < -22 and rng.randf() < 0.38 else "copperOre"
        if source_capture:
            _capture_underground_ore_values(state, prop_id, local_position, ore, rng,
                solid_cell)
            return
        chunk.set_meta("ecology_capture_context", _ecology_capture_context(state,
            "underground_exposed_floor_scan", "underground_props", int(state.get("undergroundIndex", -1)),
            solid_cell, scan_revision))
        make_ore_cluster(chunk, prop_id, local_position, ore, rng, 1)
        chunk.remove_meta("ecology_capture_context")
    elif roll < 0.36:
        state["undergroundAttemptBranch"] = "rock"
        if source_capture:
            var rock_value := build_rock_source_value(prop_id, local_position,
                "underground", rng, state.get("visualAssetOwnerReceipt", {}), true)
            _append_ecology_source_value(state, rock_value, "underground_props",
                "underground_props", solid_cell)
            return
        chunk.set_meta("ecology_capture_context", _ecology_capture_context(state,
            "underground_exposed_floor_scan", "underground_props", int(state.get("undergroundIndex", -1)),
            solid_cell, scan_revision))
        make_rock(chunk, prop_id, local_position, rng)
        chunk.remove_meta("ecology_capture_context")
    elif roll < 0.48:
        state["undergroundAttemptBranch"] = "forage"
        if source_capture:
            var forage_value: Variant = call("build_forage_source_value", prop_id,
                local_position, "swamp", rng)
            _append_ecology_source_value(state, forage_value, "underground_props",
                "underground_props", solid_cell)
            return
        chunk.set_meta("ecology_capture_context", _ecology_capture_context(state,
            "underground_exposed_floor_scan", "underground_props", int(state.get("undergroundIndex", -1)),
            solid_cell, scan_revision))
        make_forage(chunk, prop_id, local_position, "swamp", rng)
        chunk.remove_meta("ecology_capture_context")


func _capture_underground_ore_values(state: Dictionary, prop_id: String,
        position: Vector3, ore_type: String, rng: RandomNumberGenerator,
        source_cell: Vector3i) -> void:
    var descriptors := make_ore_cluster(null, prop_id, position, ore_type, rng, 1)
    for descriptor_value: Variant in descriptors:
        if descriptor_value is Dictionary:
            _append_ecology_source_value(state, descriptor_value,
                "underground_props", "underground_props", source_cell)

func process_chunk_detail_spawn_state(
    state: Dictionary,
    detail_attempt_budget: int,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return true
    var density: float = clampf(float(visual_quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
    if density <= 0.01:
        return true
    if int(state.get("detailAttempts", -1)) < 0:
        state["detailAttempts"] = maxi(8, int(round(float(visual_quality.get("decorativeDetailCap", 72)) * density)))
    var rng := state.get("detailRng") as RandomNumberGenerator
    if rng == null:
        return true
    var batches: Dictionary = state.get("detailBatches", {}) if state.get("detailBatches", {}) is Dictionary else {}
    var attempts := int(state.get("detailAttempts", 0))
    var detail_index := int(state.get("detailIndex", 0))
    var processed := 0
    var active_attempt: Dictionary = state.get("detailActiveAttempt", {}) if state.get("detailActiveAttempt", {}) is Dictionary else {}
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    while detail_index < attempts and processed < maxi(1, detail_attempt_budget):
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            break
        var detail_attempt_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_attempt") if runtime_perf_monitor != null else Time.get_ticks_usec()
        if active_attempt.is_empty():
            active_attempt = begin_chunk_detail_attempt(state, rng)
        var attempt_complete := advance_chunk_detail_attempt(
            state,
            active_attempt,
            rng,
            batches,
            time_budget_ms,
            start_usec
        )
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("chunk_detail_prop_attempt", detail_attempt_start)
        if not attempt_complete:
            state["detailIndex"] = detail_index
            state["detailActiveAttempt"] = active_attempt
            state["detailBatches"] = batches
            return false
        detail_index += 1
        processed += 1
        active_attempt = {}
    state["detailIndex"] = detail_index
    state["detailActiveAttempt"] = active_attempt
    state["detailBatches"] = batches
    if detail_index < attempts:
        return false
    state["phase"] = "detail_batches"
    state["detailBatchKeys"] = batches.keys()
    state["detailBatchIndex"] = 0
    if chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
        return false
    return process_chunk_detail_batch_spawn_state(state, time_budget_ms, start_usec)

func process_chunk_detail_batch_spawn_state(state: Dictionary, time_budget_ms := -1.0, budget_start_usec := 0) -> bool:
    var chunk := valid_node3d_from_variant(state.get("chunk"))
    var source_capture := bool(state.get("sourceCaptureMode", false))
    if not source_capture and (chunk == null or not is_instance_valid(chunk)):
        return true
    var batches: Dictionary = state.get("detailBatches", {}) if state.get("detailBatches", {}) is Dictionary else {}
    if batches.is_empty():
        if source_capture:
            state["detailSourceRows"] = []
        else:
            chunk.set_meta("visual_detail_expected_batches", [])
        return true
    var keys: Array = state.get("detailBatchKeys", []) if state.get("detailBatchKeys", []) is Array else []
    if keys.is_empty():
        keys = batches.keys()
        state["detailBatchKeys"] = keys
    var root := valid_node3d_from_variant(state.get("detailBatchRoot"))
    if not source_capture and (root == null or not is_instance_valid(root)):
        root = Node3D.new()
        root.name = "DecorBatches"
        root.set_meta("kind", "decor")
        chunk.add_child(root)
        state["detailBatchRoot"] = root
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    var batch_index := int(state.get("detailBatchIndex", 0))
    var expected_batches: Array = state.get("visualDetailBatchRecords", [])
    var processed := 0
    while batch_index < keys.size():
        if processed > 0 and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            state["detailBatchIndex"] = batch_index
            return false
        var detail_type_variant = keys[batch_index]
        var transforms: Array = batches.get(detail_type_variant, [])
        if not transforms.is_empty():
            var batch_start: int = runtime_perf_monitor.begin_section("chunk_detail_batch_spawn") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var detail_source_inputs: Dictionary = state.get("catalogInputs", {}) \
                if source_capture else state.get("sourceInputs", {})
            if source_capture:
                detail_source_inputs = detail_source_inputs.duplicate(true)
                detail_source_inputs.merge(state.get("sourceInputs", {}), true)
            var detail_rows := _build_chunk_detail_source_values(int(state.get("cx", 0)),
                int(state.get("cz", 0)), String(detail_type_variant), transforms,
                detail_source_inputs)
            if String(detail_rows.get("status", "")) != "ready":
                state["sourceCaptureFailure"] = String(detail_rows.get("reason",
                    "detail_source_values_unavailable"))
                return true
            if source_capture:
                var all_rows: Array = state.get("detailSourceRows", [])
                for row_value: Variant in detail_rows.get("rows", []):
                    if row_value is Dictionary:
                        var row: Dictionary = row_value.duplicate(true)
                        if not _valid_ecology_content_digest(String(row.get(
                                "meshContentDigest", ""))) \
                                or not _valid_ecology_content_digest(String(row.get(
                                "materialContentDigest", ""))):
                            state["sourceCaptureFailure"] = \
                                "detail_render_resource_digest_unavailable"
                            return true
                        _bind_ecology_source_row(state, row, "details", "details")
                        var detail_transform: Variant = row.get("transform", null)
                        if detail_transform is Transform3D:
                            row["sourceOrigin"] = Vector3(
                                float(int(state.get("startX", 0))) * CELL,
                                0.0,
                                float(int(state.get("startZ", 0))) * CELL) \
                                + (detail_transform as Transform3D).origin
                        _prove_ecology_source_row_bounds(state, row, "details")
                        all_rows.append(row)
                state["detailSourceRows"] = all_rows
            else:
                record_chunk_detail_source_values(chunk, int(state.get("cx", 0)),
                    int(state.get("cz", 0)), String(detail_type_variant), transforms,
                    state.get("sourceInputs", {}))
                spawn_detail_batch(root, String(detail_type_variant), transforms)
                var published_batch := root.get_child(root.get_child_count() - 1) as MultiMeshInstance3D
                expected_batches.append({"detailType": String(detail_type_variant),
                    "batchInstanceId": published_batch.get_instance_id(),
                    "instanceCount": published_batch.multimesh.instance_count})
                state["visualDetailBatchRecords"] = expected_batches
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_batch_spawn", batch_start)
        batch_index += 1
        processed += 1
    state["detailBatchIndex"] = batch_index
    if source_capture:
        # The caller may yield after this function reports completion but before
        # it advances the phase. Keep the producer handoff idempotent across
        # that boundary so retained source sessions never publish details twice.
        if not bool(state.get("detailSourceRowsAppendedToPass", false)):
            var detail_rows: Array = state.get("detailSourceRows", [])
            var pass_rows: Array = state.get("sourceRows", [])
            pass_rows.append_array(detail_rows)
            state["sourceRows"] = pass_rows
            state["detailSourceRowsAppendedToPass"] = true
    else:
        chunk.set_meta("visual_detail_expected_batches", expected_batches.duplicate(true))
    return true

func record_chunk_detail_source_values(chunk: Node3D, cx: int, cz: int,
        detail_type: String, transforms: Array, source_inputs: Dictionary = {}) -> void:
    if chunk == null or not is_instance_valid(chunk) or detail_type.is_empty():
        return
    var built := _build_chunk_detail_source_values(cx, cz, detail_type,
        transforms, source_inputs)
    if String(built.get("status", "")) != "ready":
        return
    for candidate_value: Variant in built.get("rows", []):
        if candidate_value is Dictionary:
            _record_ecology_source_value(chunk, candidate_value)


func _build_chunk_detail_source_values(cx: int, cz: int, detail_type: String,
        transforms: Array, source_inputs: Dictionary = {}) -> Dictionary:
    var inputs := _detail_source_value_inputs(cx, cz, source_inputs)
    return EcologyDetailSourceValueBuilderScript.build_rows(inputs,
        {detail_type: transforms}, _detail_source_value_resolvers())


func _detail_source_value_inputs(cx: int, cz: int, producer_inputs: Dictionary = {}) -> Dictionary:
    var world_id := ""
    if world_static_section_coordinator != null \
            and world_static_section_coordinator.has_method("world_identity"):
        world_id = String(world_static_section_coordinator.call("world_identity"))
    if producer_inputs.has("worldId"):
        world_id = String(producer_inputs.worldId)
    var structure_revision := String(producer_inputs.get("structureAdmissionRevision", ""))
    var terrain_revision := String(producer_inputs.get("terrainVolumeChunkRevision", ""))
    var admission_status := String(producer_inputs.get("structureAdmissionStatus", "ready"))
    var chunk_bounds := Rect2i(Vector2i(cx * CHUNK_SIZE, cz * CHUNK_SIZE),
        Vector2i.ONE * CHUNK_SIZE)
    var compact_source_inputs := String(producer_inputs.get("schema", "")) \
        == "ecology-source-domain-inputs/v2"
    if not compact_source_inputs and structure_revision.is_empty() and structure_system != null \
            and structure_system.has_method("region_dependency_revision"):
        structure_revision = String(structure_system.call("region_dependency_revision", chunk_bounds))
    if terrain_revision.is_empty() and world_generation_system != null \
            and world_generation_system.has_method("terrain_volume_chunk_revision"):
        terrain_revision = str(world_generation_system.call("terrain_volume_chunk_revision",
            Vector2i(cx, cz), CHUNK_SIZE))
    var density := clampf(float(visual_quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
    var attempts := maxi(8, int(round(float(visual_quality.get("decorativeDetailCap", 72)) * density)))
    if compact_source_inputs and (terrain_revision.is_empty() \
            or String(producer_inputs.get("structureDependencyStatus", "")) != "ready" \
            or structure_revision.length() != 64):
        admission_status = "pending"
    var chunk_key := Vector2i(cx, cz)
    var detail_revision := EcologyProducerDomainScript.digest_value({
        "detailsSeed":hash_string("%s:details:%d,%d" % [seed_text, cx, cz]),
        "attempts":attempts, "density":density,
        "terrainRevision":terrain_revision, "structureRevision":structure_revision,
        "admissionStatus":admission_status})
    return {
        "worldId": world_id,
        "worldSeed": seed_text,
        "sourceChunkKey": "%d,%d" % [cx, cz],
        "chunkX": cx,
        "chunkZ": cz,
        "chunkOrigin": Vector3(float(cx * CHUNK_SIZE) * CELL, 0.0,
            float(cz * CHUNK_SIZE) * CELL),
        "revisions": {
            "terrain": terrain_revision,
            "structure": structure_revision,
            "details": detail_revision
        },
        "attempts":attempts,
        "generationStatus": "complete",
        "batchesComplete": true,
    }


func _detail_source_value_resolvers() -> Dictionary:
    return {
        "mesh": Callable(self, "detail_mesh"),
        "meshSurface": Callable(self, "detail_mesh_surface"),
        "materialKey": Callable(self, "_detail_source_material_key"),
        "material": Callable(self, "_detail_source_material"),
        "meshContentDigest": Callable(self, "_detail_source_mesh_content_digest"),
        "materialContentDigest": Callable(self, "_detail_source_material_content_digest"),
        "renderLayer": Callable(self, "_detail_source_render_layer"),
        "instanceColor": Callable(self, "detail_instance_color"),
        "instancePhase": Callable(self, "detail_instance_phase"),
        "visibilityRangeEnd": Callable(self, "detail_visibility_range")
    }


func _detail_source_mesh_content_digest(mesh: Mesh) -> String:
    var fingerprint: Dictionary = EcologyMeshFingerprintScript.inspect(mesh)
    return String(fingerprint.get("contentDigest", "")) \
        if String(fingerprint.get("status", "")) == "ready" else ""


func _detail_source_material_content_digest(material: Material) -> String:
    return EcologyMaterialDigestScript._material_digest(material) \
        if is_instance_valid(material) else ""


func _detail_source_material_key(detail_type: String, surface_index: int) -> String:
    return detail_surface_material_key(detail_type, surface_index) if surface_index >= 0 \
        else String(detail_type_material_key(detail_type))


func _detail_source_material(detail_type: String, surface_index: int) -> Material:
    return detail_surface_material(detail_type, surface_index) if surface_index >= 0 \
        else detail_material(detail_type)


func _detail_source_render_layer(material: Material, _detail_type: String,
        _surface_index: int) -> String:
    return detail_surface_render_layer(material)

func begin_chunk_detail_attempt(state: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    return {
        "phase": "block_check",
        "x": start_x + 1 + rng.randi_range(0, CHUNK_SIZE - 2),
        "z": start_z + 1 + rng.randi_range(0, CHUNK_SIZE - 2),
        "variationCenterHeight": 0.0,
        "variationIndex": 0,
        "variationMaxDelta": 0.0
    }

func advance_chunk_detail_attempt(
    state: Dictionary,
    attempt: Dictionary,
    rng: RandomNumberGenerator,
    batches: Dictionary,
    time_budget_ms := -1.0,
    budget_start_usec := 0
) -> bool:
    var start_x := int(state.get("startX", int(state.get("cx", 0)) * CHUNK_SIZE))
    var start_z := int(state.get("startZ", int(state.get("cz", 0)) * CHUNK_SIZE))
    var x := int(attempt.get("x", start_x))
    var z := int(attempt.get("z", start_z))
    var start_usec := budget_start_usec if budget_start_usec > 0 else Time.get_ticks_usec()
    while true:
        var phase := String(attempt.get("phase", "block_check"))
        if phase != "block_check" and chunk_prop_spawn_budget_elapsed(start_usec, time_budget_ms):
            return false
        if phase == "block_check":
            var block_check_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_block_check") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var blocked := natural_props_blocked_at_cell(x, z)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_prop_block_check", block_check_start)
            if blocked:
                return true
            attempt["phase"] = "surface_sample"
            continue
        if phase == "surface_sample":
            var sample_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_sample") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var surface_sample := surface_volume_spawn_sample_at_cell(x, z)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_prop_sample", sample_start)
            if surface_sample.is_empty() or not bool(surface_sample.get("found", false)):
                return true
            var h := float(surface_sample.get("height", 0.0))
            if h < WATER_LEVEL - 0.1 or h > 104.0:
                return true
            var biome := String(surface_sample.get("biome", "plains"))
            if biome == "town":
                return true
            attempt["height"] = h
            attempt["biome"] = biome
            attempt["phase"] = "variation_center"
            continue
        if phase == "variation_center":
            var center_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_variation") if runtime_perf_monitor != null else Time.get_ticks_usec()
            attempt["variationCenterHeight"] = surface_y_at_cell(Vector3i(x, 0, z))
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_prop_variation", center_start)
            attempt["phase"] = "variation_cells"
            continue
        if phase == "variation_cells":
            var variation_index := int(attempt.get("variationIndex", 0))
            if variation_index >= 9:
                if float(attempt.get("variationMaxDelta", 0.0)) > CELL * 1.35:
                    return true
                attempt["phase"] = "append"
                continue
            var dx := variation_index % 3 - 1
            var dz := floori(float(variation_index) / 3.0) - 1
            var variation_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_variation") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var sample_height: float = surface_y_at_cell(Vector3i(x + dx, 0, z + dz))
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_prop_variation", variation_start)
            attempt["variationMaxDelta"] = maxf(
                float(attempt.get("variationMaxDelta", 0.0)),
                abs(sample_height - float(attempt.get("variationCenterHeight", 0.0)))
            )
            attempt["variationIndex"] = variation_index + 1
            continue
        if phase == "append":
            var append_start: int = runtime_perf_monitor.begin_section("chunk_detail_prop_append") if runtime_perf_monitor != null else Time.get_ticks_usec()
            var local_position := Vector3(
                (x - start_x) * CELL + rng.randf_range(-0.42, 0.42),
                float(attempt.get("height", 0.0)),
                (z - start_z) * CELL + rng.randf_range(-0.42, 0.42)
            )
            add_detail_for_biome(batches, local_position, String(attempt.get("biome", "plains")), float(attempt.get("height", 0.0)), rng)
            if runtime_perf_monitor != null:
                runtime_perf_monitor.end_section("chunk_detail_prop_append", append_start)
            return true
        return true
    return true

func spawn_chunk_detail_attempt(state: Dictionary, _index: int, rng: RandomNumberGenerator, batches: Dictionary) -> void:
    var attempt := begin_chunk_detail_attempt(state, rng)
    while not advance_chunk_detail_attempt(state, attempt, rng, batches):
        pass

func spawn_chunk_detail_batches_from_transforms(chunk: Node3D, batches: Dictionary) -> void:
    if batches.is_empty():
        chunk.set_meta("visual_detail_expected_batches", [])
        return
    var root := Node3D.new()
    root.name = "DecorBatches"
    root.set_meta("kind", "decor")
    chunk.add_child(root)
    var expected_batches: Array = []
    for detail_type_variant in batches.keys():
        var detail_type := String(detail_type_variant)
        var transforms: Array = batches[detail_type_variant]
        if transforms.is_empty():
            continue
        spawn_detail_batch(root, detail_type, transforms)
        var published_batch := root.get_child(root.get_child_count() - 1) as MultiMeshInstance3D
        expected_batches.append({"detailType": detail_type,
            "batchInstanceId": published_batch.get_instance_id(),
            "instanceCount": published_batch.multimesh.instance_count})
    chunk.set_meta("visual_detail_expected_batches", expected_batches)

func spawn_chunk_detail_batches(chunk: Node3D, cx: int, cz: int) -> void:
    var density: float = clampf(float(visual_quality.get("decorativeDensity", 0.74)), 0.0, 1.0)
    if density <= 0.01:
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:details:%d,%d" % [seed_text, cx, cz])
    var start_x: int = cx * CHUNK_SIZE
    var start_z: int = cz * CHUNK_SIZE
    var attempts: int = maxi(8, int(round(float(visual_quality.get("decorativeDetailCap", 72)) * density)))
    var batches := {}
    var attempt_state := {
        "startX": start_x,
        "startZ": start_z
    }
    for i in range(attempts):
        spawn_chunk_detail_attempt(attempt_state, i, rng, batches)
    spawn_chunk_detail_batches_from_transforms(chunk, batches)

func natural_props_blocked_at_cell(x: int, z: int) -> bool:
    if structure_system != null and structure_system.has_method("blocks_natural_prop_at_cell"):
        return bool(structure_system.call("blocks_natural_prop_at_cell", x, z))
    return false

func surface_volume_spawn_sample_at_cell(cell_x: int, cell_z: int) -> Dictionary:
    var column_cell := Vector3i(cell_x, 0, cell_z)
    var fallback_height := surface_y_at_cell(column_cell)
    var fallback_biome := surface_biome_at_cell(column_cell)
    if world_generation_system == null or not world_generation_system.has_method("surface_projection_for_cell"):
        return {
            "found": true,
            "height": fallback_height,
            "biome": fallback_biome,
            "material": world_material_at_cell(Vector3i(cell_x, floori(fallback_height / CELL), cell_z)) if has_method("world_material_at_cell") else "",
            "authority": "height_compat"
        }
    if world_generation_system.has_method("terrain_volume_column_has_surface_projection_affecting_edits") \
        and not bool(world_generation_system.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell)):
        # Unedited does not imply an intact surface: generated cave mouths can
        # remove the root/support location. Surface ecology must not float over
        # that air or grow down into it from the old heightfield projection.
        var footprint_center := Vector3(float(cell_x) * CELL, fallback_height, float(cell_z) * CELL)
        if world_generation_system.generated_cave_near_surface_footprint(footprint_center, 1.5):
            for offset in [Vector2.ZERO, Vector2(1.5, 0), Vector2(-1.5, 0), Vector2(0, 1.5), Vector2(0, -1.5)]:
                var root_position := footprint_center + Vector3(offset.x, 0, offset.y)
                var reference_y := float(world_generation_system.terrain_reference_surface_y_at(root_position))
                var surface_y := float(world_generation_system.terrain_deformed_surface_y_at(root_position))
                # Check carving at each support point, independently of ordinary
                # hillside variation; a tree's base must not overhang a void.
                root_position.y = surface_y - 0.2
                if float(world_generation_system.density_from_components(root_position, surface_y, reference_y)) < 0.0:
                    return {"found": false, "height": fallback_height, "biome": fallback_biome, "authority": "generated_volume"}
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("surface_prop_generated_surface_fast_queries")
        return {
            "found": true,
            "height": fallback_height,
            "biome": fallback_biome,
            "material": surface_material_at_cell(column_cell) if has_method("surface_material_at_cell") else "",
            "solidCell": Vector3i(cell_x, floori(fallback_height / CELL), cell_z),
            "airCell": Vector3i(cell_x, floori(fallback_height / CELL) + 1, cell_z),
            "authority": "generated_surface_fast"
        }
    var start_cell := Vector3i(cell_x, floori(fallback_height / CELL), cell_z)
    var projection_start: int = runtime_perf_monitor.begin_section("surface_prop_volume_projection") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var projection: Dictionary = world_generation_system.call("surface_projection_for_cell", start_cell, 24, 96)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("surface_prop_volume_projection", projection_start)
    if projection.is_empty() or not bool(projection.get("found", false)):
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    var solid_state: Dictionary = projection.get("solidState", {}) if projection.get("solidState", {}) is Dictionary else {}
    var air_state: Dictionary = projection.get("airState", {}) if projection.get("airState", {}) is Dictionary else {}
    var material := String(solid_state.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    if String(air_state.get("fluid", "")) != "":
        return {
            "found": false,
            "height": fallback_height,
            "biome": fallback_biome,
            "authority": "terrain_volume_projection"
        }
    var air_cell: Vector3i = projection.get("airCell", start_cell + Vector3i(0, 1, 0))
    var biome := String(solid_state.get("biome", fallback_biome))
    if biome == "" or biome == "underground" or biome == "deep_underground":
        biome = fallback_biome
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("surface_prop_volume_projection_queries")
    return {
        "found": true,
        "height": float(air_cell.y) * CELL,
        "biome": biome,
        "material": material,
        "solidCell": projection.get("solidCell", start_cell),
        "airCell": air_cell,
        "authority": "terrain_volume_projection"
    }

func add_detail_for_biome(batches: Dictionary, local_position: Vector3, biome: String, height: float, rng: RandomNumberGenerator) -> void:
    var roll := rng.randf()
    var choice: Dictionary = biome_environment_catalog.detail_choice(biome, height, WATER_LEVEL, roll) if biome_environment_catalog != null else {}
    var detail_type := String(choice.get("type", ""))
    if detail_type == "":
        return
    if detail_type == "flower":
        append_flower_detail(batches, local_position, rng)
        return
    append_detail_transform(
        batches,
        detail_type,
        local_position + Vector3(0.0, float(choice.get("yOffset", 0.0)), 0.0),
        rng.randf() * TAU,
        Vector3.ONE * rng.randf_range(float(choice.get("scaleMin", 1.0)), float(choice.get("scaleMax", 1.0)))
    )

func append_flower_detail(batches: Dictionary, local_position: Vector3, rng: RandomNumberGenerator) -> void:
    var yaw := rng.randf() * TAU
    var scale := rng.randf_range(0.82, 1.18)
    var offset := Vector3(cos(yaw + PI * 0.5), 0.0, sin(yaw + PI * 0.5)) * 0.08
    append_detail_transform(batches, "flowerStem", local_position + Vector3(0.0, 0.15, 0.0) - offset, yaw, Vector3.ONE * scale)
    append_detail_transform(batches, "flowerBloom", local_position + Vector3(0.0, 0.15, 0.0) + offset, yaw + PI * 0.62, Vector3.ONE * scale)

func append_detail_transform(batches: Dictionary, detail_type: String, origin: Vector3, yaw: float, scale: Vector3) -> void:
    if not batches.has(detail_type):
        batches[detail_type] = []
    var basis := Basis(Vector3.UP, yaw).scaled(scale)
    batches[detail_type].append(Transform3D(basis, origin))

func spawn_detail_batch(parent: Node3D, detail_type: String, transforms: Array) -> void:
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_colors = true
    multimesh.use_custom_data = true
    multimesh.mesh = detail_mesh(detail_type)
    multimesh.instance_count = transforms.size()
    for i in range(transforms.size()):
        var transform: Transform3D = transforms[i]
        multimesh.set_instance_transform(i, transform)
        multimesh.set_instance_color(i, detail_instance_color(detail_type, transform, i))
        multimesh.set_instance_custom_data(i, Color(detail_instance_phase(detail_type, transform, i), 0.0, 0.0, 1.0))
    var instance := MultiMeshInstance3D.new()
    instance.name = "Detail_%s_%d" % [detail_type, transforms.size()]
    instance.multimesh = multimesh
    var override_material := detail_material(detail_type)
    if override_material != null:
        instance.material_override = override_material
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = detail_visibility_range(detail_type)
    instance.visibility_range_end_margin = 12.0
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    instance.extra_cull_margin = 0.16 if override_material is ShaderMaterial else 0.0
    instance.set_meta("kind", "decor")
    instance.set_meta("detail_type", detail_type)
    instance.set_meta("detail_visibility_end", instance.visibility_range_end)
    parent.add_child(instance)
    var visual_publisher = DetailBatchVisualReceiptPublisherScript.new()
    visual_publisher.configure(instance, detail_type)
    instance.set_meta("visual_detail_receipt_publisher", visual_publisher)

func detail_material(detail_type: String) -> Material:
    match detail_type:
        "flowerStem", "flowerBloom":
            return null
        "grass":
            return materials["detailGrass"]
        "reed":
            return materials["detailReed"]
        "pebble":
            return materials["detailPebble"]
        "snowClump":
            return materials["detailSnow"]
        "scrub":
            return materials["detailScrub"]
        "leafLitter":
            return materials["detailLeaf"]
    return materials["detailGrass"]

func detail_type_material_key(detail_type: String) -> String:
    match detail_type:
        "flowerStem", "flowerBloom", "grass":
            return "detailGrass"
        "reed":
            return "detailReed"
        "pebble":
            return "detailPebble"
        "snowClump":
            return "detailSnow"
        "scrub":
            return "detailScrub"
        "leafLitter":
            return "detailLeaf"
    return "detailGrass"

func detail_surface_material_key(detail_type: String, surface_index: int) -> String:
    var source_mesh := detail_mesh(detail_type)
    if not source_mesh is ArrayMesh or surface_index < 0 \
            or surface_index >= source_mesh.get_surface_count():
        return ""
    var surface_material := source_mesh.surface_get_material(surface_index)
    if not surface_material is Material:
        return ""
    for key_value: Variant in materials:
        var key := String(key_value)
        if materials[key_value] == surface_material:
            return key
    return ""

func detail_surface_material(detail_type: String, surface_index: int) -> Material:
    var source_mesh := detail_mesh(detail_type)
    if not source_mesh is ArrayMesh or surface_index < 0 \
            or surface_index >= source_mesh.get_surface_count():
        return null
    var surface_material := source_mesh.surface_get_material(surface_index)
    return surface_material as Material if surface_material is Material else null

func detail_surface_render_layer(material: Material) -> String:
    if material is ShaderMaterial:
        var shader := (material as ShaderMaterial).shader
        if shader == null or shader.code.is_empty() or shader.code.contains("ALPHA") \
                or shader.code.contains("discard") or shader.code.contains("blend_"):
            return ""
        if shader.resource_path != "res://resources/visual/detail_material.gdshader":
            return ""
        return "opaque"
    if material is BaseMaterial3D:
        var base := material as BaseMaterial3D
        if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
                and base.albedo_color.a >= 0.999:
            return "opaque"
        if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
            return "alpha_scissor"
    return ""

func detail_mesh_surface(detail_type: String, surface_index: int) -> Mesh:
    var cache_key := "__surface__:%s:%d" % [detail_type, surface_index]
    if detail_meshes.has(cache_key):
        return detail_meshes[cache_key] as Mesh
    var source_mesh := detail_mesh(detail_type)
    if not source_mesh is ArrayMesh or surface_index < 0 \
            or surface_index >= source_mesh.get_surface_count():
        return null
    var arrays := source_mesh.surface_get_arrays(surface_index)
    if arrays.is_empty():
        return null
    var surface_mesh := ArrayMesh.new()
    surface_mesh.add_surface_from_arrays(source_mesh.surface_get_primitive_type(surface_index), arrays)
    var surface_material := source_mesh.surface_get_material(surface_index)
    if surface_material is Material:
        surface_mesh.surface_set_material(0, surface_material)
    detail_meshes[cache_key] = surface_mesh
    return surface_mesh

func detail_mesh(detail_type: String) -> Mesh:
    if detail_meshes.has(detail_type):
        return detail_meshes[detail_type]
    var mesh: Mesh
    match detail_type:
        "grass":
            mesh = make_grass_cluster_mesh()
        "flowerStem":
            mesh = make_flower_cluster_mesh(0)
        "flowerBloom":
            mesh = make_flower_cluster_mesh(1)
        "reed":
            mesh = make_reed_cluster_mesh()
        "pebble":
            mesh = make_pebble_cluster_mesh()
        "snowClump":
            mesh = make_snow_clump_mesh()
        "scrub":
            mesh = make_scrub_cluster_mesh()
        "leafLitter":
            mesh = make_leaf_litter_mesh()
        _:
            mesh = make_grass_cluster_mesh()
    detail_meshes[detail_type] = mesh
    return mesh

func detail_visibility_range(detail_type: String) -> float:
    match detail_type:
        "reed", "scrub":
            return 82.0
        "grass", "flowerStem", "flowerBloom":
            return 64.0
        "pebble", "snowClump", "leafLitter":
            return 58.0
    return 64.0

func detail_instance_phase(detail_type: String, transform: Transform3D, index: int) -> float:
    return detail_hash_unit(detail_type, transform.origin, index, 19.71)

func detail_instance_color(detail_type: String, transform: Transform3D, index: int) -> Color:
    var warm := detail_hash_unit(detail_type, transform.origin, index, 3.17)
    var cool := detail_hash_unit(detail_type, transform.origin, index, 9.91)
    var light := detail_hash_unit(detail_type, transform.origin, index, 14.43)
    match detail_type:
        "pebble":
            return Color(0.88 + warm * 0.20, 0.90 + cool * 0.16, 0.86 + light * 0.18, 1.0)
        "snowClump":
            return Color(0.95 + warm * 0.10, 0.98 + cool * 0.08, 1.0 + light * 0.06, 1.0)
        "leafLitter":
            return Color(0.92 + warm * 0.18, 0.82 + cool * 0.14, 0.70 + light * 0.12, 1.0)
        "flowerBloom":
            return Color(1.02 + warm * 0.16, 0.92 + cool * 0.12, 0.86 + light * 0.16, 1.0)
        "reed", "scrub":
            return Color(0.86 + warm * 0.18, 0.94 + cool * 0.16, 0.78 + light * 0.16, 1.0)
    return Color(0.86 + warm * 0.18, 0.96 + cool * 0.18, 0.82 + light * 0.14, 1.0)

func detail_hash_unit(detail_type: String, origin: Vector3, index: int, salt: float) -> float:
    var type_seed := float(abs(hash_string(detail_type)) % 997)
    var value := sin(origin.x * 12.9898 + origin.z * 78.233 + origin.y * 5.913 + float(index) * 37.719 + type_seed + salt) * 43758.5453
    return fposmod(value, 1.0)

func make_grass_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailGrass"])
    var blade_data := [
        [Vector3(-0.09, -0.19, -0.05), 0.38, 0.055, 0.10, 0.0],
        [Vector3(0.06, -0.19, 0.02), 0.46, 0.048, -0.08, 1.18],
        [Vector3(0.0, -0.19, -0.10), 0.34, 0.045, 0.06, 2.35],
        [Vector3(0.12, -0.19, -0.04), 0.31, 0.038, -0.04, 3.30],
        [Vector3(-0.02, -0.19, 0.10), 0.42, 0.050, 0.11, 4.28],
        [Vector3(-0.13, -0.19, 0.05), 0.30, 0.040, -0.05, 5.36],
    ]
    for row in blade_data:
        add_detail_blade(st, row[0], float(row[1]), float(row[2]), float(row[4]), float(row[3]))
    return commit_detail_surface(st)

func make_reed_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailReed"])
    var reeds := [
        [Vector3(-0.06, -0.36, -0.03), 0.86, 0.032, 0.08, 0.15],
        [Vector3(0.04, -0.36, 0.02), 0.78, 0.026, -0.05, 1.50],
        [Vector3(0.10, -0.36, -0.04), 0.66, 0.024, 0.04, 2.60],
        [Vector3(-0.12, -0.36, 0.05), 0.72, 0.024, -0.08, 3.85],
    ]
    for row in reeds:
        add_detail_stem(st, row[0], float(row[1]), float(row[2]), float(row[4]), float(row[3]))
    add_detail_blade(st, Vector3(0.0, -0.36, 0.08), 0.58, 0.035, 4.8, 0.13)
    return commit_detail_surface(st)

func make_scrub_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailScrub"])
    add_detail_blade(st, Vector3(-0.11, -0.17, -0.03), 0.36, 0.055, 0.2, 0.13)
    add_detail_blade(st, Vector3(0.08, -0.17, 0.01), 0.32, 0.048, 1.2, -0.10)
    add_detail_blade(st, Vector3(0.00, -0.17, 0.09), 0.30, 0.046, 2.5, 0.08)
    add_detail_blade(st, Vector3(0.13, -0.17, -0.08), 0.24, 0.040, 3.7, -0.05)
    add_detail_blade(st, Vector3(-0.06, -0.17, 0.04), 0.28, 0.044, 4.7, 0.12)
    return commit_detail_surface(st)

func make_flower_cluster_mesh(variant: int) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var stem_st := begin_detail_surface(materials["detailGrass"])
    add_detail_stem(stem_st, Vector3(0.0, -0.15, 0.0), 0.31 + float(variant) * 0.03, 0.018, 0.0, 0.018)
    add_detail_blade(stem_st, Vector3(-0.015, -0.08, 0.0), 0.13, 0.032, 2.0 + float(variant) * 0.4, 0.04)
    add_detail_blade(stem_st, Vector3(0.012, -0.07, 0.0), 0.12, 0.030, 4.6 + float(variant) * 0.3, -0.04)
    commit_detail_surface(stem_st, mesh)

    var bloom_st := begin_detail_surface(materials["detailFlower"])
    var center := Vector3(0.0, 0.17 + float(variant) * 0.03, 0.0)
    var petals := 5 + variant
    for i in range(petals):
        var angle := float(i) / float(petals) * TAU
        var petal_center := center + Vector3(cos(angle), 0.0, sin(angle)) * 0.025
        add_vertical_diamond(bloom_st, petal_center, 0.075, 0.042, angle)
    return commit_detail_surface(bloom_st, mesh)

func make_pebble_cluster_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailPebble"])
    add_detail_octahedron(st, Vector3(-0.08, 0.0, -0.03), Vector3(0.11, 0.06, 0.08))
    add_detail_octahedron(st, Vector3(0.06, -0.005, 0.04), Vector3(0.085, 0.045, 0.065))
    add_detail_octahedron(st, Vector3(0.15, -0.01, -0.03), Vector3(0.055, 0.035, 0.045))
    return commit_detail_surface(st)

func make_snow_clump_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailSnow"])
    add_detail_octahedron(st, Vector3(-0.07, 0.0, -0.03), Vector3(0.16, 0.055, 0.11))
    add_detail_octahedron(st, Vector3(0.08, -0.005, 0.02), Vector3(0.13, 0.045, 0.10))
    add_detail_octahedron(st, Vector3(0.0, 0.01, 0.10), Vector3(0.09, 0.04, 0.07))
    return commit_detail_surface(st)

func make_leaf_litter_mesh() -> ArrayMesh:
    var st := begin_detail_surface(materials["detailLeaf"])
    add_horizontal_diamond(st, Vector3(-0.08, -0.008, -0.04), 0.22, 0.075, 0.3)
    add_horizontal_diamond(st, Vector3(0.08, -0.006, 0.03), 0.18, 0.065, 1.6)
    add_horizontal_diamond(st, Vector3(0.00, -0.004, 0.10), 0.16, 0.055, 2.7)
    add_horizontal_diamond(st, Vector3(0.13, -0.007, -0.09), 0.14, 0.050, 4.1)
    return commit_detail_surface(st)

func begin_detail_surface(material: Material) -> SurfaceTool:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    st.set_material(material)
    return st

func commit_detail_surface(st: SurfaceTool, mesh: ArrayMesh = null) -> ArrayMesh:
    st.generate_normals()
    return st.commit(mesh)

func add_detail_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, wind_a: float, wind_b: float, wind_c: float) -> void:
    st.set_uv2(Vector2(wind_a, 0.0))
    st.add_vertex(a)
    st.set_uv2(Vector2(wind_b, 0.0))
    st.add_vertex(b)
    st.set_uv2(Vector2(wind_c, 0.0))
    st.add_vertex(c)

func add_detail_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, wind_bottom: float, wind_top: float) -> void:
    add_detail_triangle(st, a, b, c, wind_bottom, wind_top, wind_bottom)
    add_detail_triangle(st, c, b, d, wind_bottom, wind_top, wind_top)

func add_detail_blade(st: SurfaceTool, base: Vector3, height: float, width: float, yaw: float, lean: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width
    var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
    var tip := base + Vector3(0.0, height, 0.0) + forward * lean
    add_detail_triangle(st, base - right, tip, base + right, 0.0, 1.0, 0.0)

func add_detail_stem(st: SurfaceTool, base: Vector3, height: float, width: float, yaw: float, lean: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width
    var forward := Vector3(-sin(yaw), 0.0, cos(yaw))
    var top := base + Vector3(0.0, height, 0.0) + forward * lean
    add_detail_quad(st, base - right, top - right * 0.45, base + right, top + right * 0.45, 0.0, 1.0)

func add_horizontal_diamond(st: SurfaceTool, center: Vector3, length: float, width: float, yaw: float) -> void:
    var forward := Vector3(cos(yaw), 0.0, sin(yaw)) * length * 0.5
    var right := Vector3(-sin(yaw), 0.0, cos(yaw)) * width * 0.5
    add_detail_triangle(st, center - forward, center + right, center + forward, 0.0, 0.0, 0.0)
    add_detail_triangle(st, center - forward, center + forward, center - right, 0.0, 0.0, 0.0)

func add_vertical_diamond(st: SurfaceTool, center: Vector3, height: float, width: float, yaw: float) -> void:
    var right := Vector3(cos(yaw), 0.0, sin(yaw)) * width * 0.5
    var top := center + Vector3(0.0, height * 0.5, 0.0)
    var bottom := center - Vector3(0.0, height * 0.5, 0.0)
    add_detail_triangle(st, bottom, center + right, top, 0.35, 0.65, 1.0)
    add_detail_triangle(st, bottom, top, center - right, 0.35, 1.0, 0.65)

func add_detail_octahedron(st: SurfaceTool, center: Vector3, radius: Vector3) -> void:
    var top := center + Vector3(0.0, radius.y, 0.0)
    var bottom := center - Vector3(0.0, radius.y, 0.0)
    var east := center + Vector3(radius.x, 0.0, 0.0)
    var west := center - Vector3(radius.x, 0.0, 0.0)
    var north := center - Vector3(0.0, 0.0, radius.z)
    var south := center + Vector3(0.0, 0.0, radius.z)
    add_detail_triangle(st, top, north, east, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, east, south, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, south, west, 0.0, 0.0, 0.0)
    add_detail_triangle(st, top, west, north, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, east, north, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, south, east, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, west, south, 0.0, 0.0, 0.0)
    add_detail_triangle(st, bottom, north, west, 0.0, 0.0, 0.0)

func tree_visual_spec(biome: String, rng: RandomNumberGenerator) -> Dictionary:
    # Preserve the historic prop-RNG draw sequence while the actual natural-tree
    # dimensions now come from TreeRuntimeRequestBuilder. Other props share this
    # chunk RNG, so retiring these legacy fallback values outright would reorder
    # world generation even though they are no longer visual authority.
    var spec := {
        "rotation": rng.randf() * TAU,
        "height": 3.0 + rng.randf() * 2.2,
        "clumps": []
    }
    if biome == "taiga" or biome == "snow" or biome == "tundra":
        spec["height"] = float(spec["height"]) + 1.6
    var height := float(spec["height"])
    var clumps := 3 if biome == "taiga" or biome == "snow" or biome == "tundra" else 5
    for c in range(clumps):
        var radius := 0.82 + rng.randf() * 0.35
        var angle := rng.randf() * TAU
        var spread := 0.0 if c == 0 else 0.42 + rng.randf() * 0.55
        var y := height + 0.3 + rng.randf() * 0.65
        var scale := Vector3(
            1.2 + rng.randf() * 0.4,
            0.68 + rng.randf() * 0.22,
            1.2 + rng.randf() * 0.4
        )
        spec["clumps"].append({
            "radius": radius,
            "position": Vector3(cos(angle) * spread, y, sin(angle) * spread),
            "scale": scale
        })
    return spec

func tree_runtime_spec_for_prop(
    biome: String,
    prop_id: String,
    fallback_height: float,
    world_cell: Vector2i
) -> Dictionary:
    var catalog = biome_environment_catalog
    # Production setup owns this catalog directly. A few isolated contract
    # fixtures construct Main without the normal setup sequence but inject a
    # ready registry; using only its already-built catalog keeps those fixtures
    # on the same pure request builder without reviving asset selection.
    if catalog == null and visual_asset_registry != null:
        catalog = visual_asset_registry.environment_catalog
    if catalog == null or not catalog.has_method("profile_for_biome"):
        return {}
    var profile := catalog.profile_for_biome(biome) as BiomeEnvironmentProfile
    if profile == null:
        return {}
    if tree_runtime_request_builder == null:
        tree_runtime_request_builder = TreeRuntimeRequestBuilderScript.new()
    var catalog_snapshot := ActiveBiomeEnvironmentSnapshotScript.capture(catalog)
    return tree_runtime_request_builder.build(profile, biome, prop_id, fallback_height,
        world_cell, seed_text, catalog_snapshot)

func add_tree_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> void:
    if add_generated_tree_visual(body, prop_id, biome, spec):
        return
    add_fallback_tree_visual(body, spec)

func add_generated_tree_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> bool:
    var runtime_spec: Dictionary = spec.get("runtime_spec", {}) if spec.get("runtime_spec", {}) is Dictionary else {}
    if TreeRuntimeRequestBuilderScript.is_procedural_request(runtime_spec):
        var queue = ensure_tree_publication_queue()
        if queue != null:
            if player != null and is_instance_valid(player) and queue.has_method("set_viewer"):
                queue.set_viewer(player)
            var request := runtime_spec.duplicate(true)
            request["treeId"] = request.get("treeId", prop_id)
            request["biome"] = request.get("biome", biome)
            request["worldSeed"] = request.get("worldSeed", seed_text)
            request["presentation"] = request.get("presentation", "runtime")
            request["treeWorldPosition"] = body.global_position
            # The queue owns only presentation.  Supplying the current viewer
            # distance lets it complete local canopies first without changing
            # deterministic prop selection, IDs, collision, or save state.
            request["publicationPriority"] = body.global_position.distance_squared_to(player.global_position) if player != null and is_instance_valid(player) else INF
            if bool(queue.enqueue(body, request)):
                body.set_meta("visual_source", "procedural_tree_recipe_pending")
                body.set_meta("visual_asset_id", "procedural:%s" % String(runtime_spec.get("speciesGrammar", "tree")))
                body.set_meta("tree_visual_state", "queued")
                return true
    return false

func add_fallback_tree_visual(body: StaticBody3D, spec: Dictionary) -> void:
    var height := float(spec.get("height", 4.0))
    var trunk_radius := maxf(0.12, float(spec.get("trunk_radius", 0.36)))
    var canopy_radius := maxf(1.2, float(spec.get("canopy_radius", 1.8)))
    var legacy_height := maxf(0.1, float(spec.get("legacy_height", height)))
    var height_ratio := height / legacy_height
    var canopy_ratio := canopy_radius / 1.8
    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = trunk_radius * 0.62
    trunk_mesh.bottom_radius = trunk_radius
    trunk_mesh.height = height
    trunk_mesh.radial_segments = 7
    var trunk := MeshInstance3D.new()
    trunk.name = "PrimitiveTreeTrunk"
    trunk.mesh = trunk_mesh
    trunk.material_override = materials["trunk"]
    trunk.position.y = height * 0.5
    trunk.set_meta("visual_source", "primitive_fallback")
    body.add_child(trunk)

    for leaf_spec in spec.get("clumps", []):
        var leaf_mesh := SphereMesh.new()
        leaf_mesh.radius = float(leaf_spec.get("radius", 0.95)) * canopy_ratio
        leaf_mesh.height = leaf_mesh.radius * 1.25
        var leaf := MeshInstance3D.new()
        leaf.name = "PrimitiveTreeLeaf"
        leaf.mesh = leaf_mesh
        leaf.material_override = materials["leaf"]
        var authored_position: Vector3 = leaf_spec.get("position", Vector3(0.0, legacy_height + 0.5, 0.0))
        leaf.position = Vector3(
            authored_position.x * canopy_ratio,
            height * 0.72 + (authored_position.y - legacy_height) * minf(height_ratio, 2.2),
            authored_position.z * canopy_ratio
        )
        leaf.scale = leaf_spec.get("scale", Vector3.ONE)
        leaf.set_meta("visual_source", "primitive_fallback")
        body.add_child(leaf)
    body.set_meta("visual_source", "primitive_fallback")
    body.set_meta("visual_asset_id", "")

func make_tree(
    parent: Node,
    prop_id: String,
    position: Vector3,
    biome: String,
    rng: RandomNumberGenerator,
    world_cell := Vector2i(2147483647, 2147483647)
):
    var source_value := build_tree_source_value(prop_id, position, biome, rng, world_cell)
    if source_value.is_empty():
        return null
    if parent == null or not is_instance_valid(parent):
        return source_value
    var candidate: Dictionary = source_value.get("candidate", {})
    _record_ecology_source_value(parent, candidate)
    var spec: Dictionary = source_value.get("treeSpec", {})
    var runtime_spec: Dictionary = source_value.get("runtimeSpec", {})
    return _publish_tree_body(parent, prop_id, position, biome, spec, runtime_spec)


## Captures the deterministic tree request before presentation. This is shared
## by resident chunk projection and node-free source-domain enumeration; it
## consumes the same legacy compatibility draws exactly once.
func build_tree_source_value(
    prop_id: String,
    position: Vector3,
    biome: String,
    rng: RandomNumberGenerator,
    world_cell := Vector2i(2147483647, 2147483647),
    runtime_support_policy: Dictionary = {}
) -> Dictionary:
    var spec := tree_visual_spec(biome, rng)
    var legacy_height := float(spec.get("height", 4.0))
    var runtime_spec := {}
    runtime_spec = tree_runtime_spec_for_prop(biome, prop_id, legacy_height, world_cell)
    if not runtime_spec.is_empty():
        spec["legacy_height"] = legacy_height
        spec["runtime_spec"] = runtime_spec
        spec["height"] = float(runtime_spec.get("visualHeight", legacy_height))
        spec["trunk_radius"] = float(runtime_spec.get("trunkRadius", 0.36))
        spec["canopy_radius"] = float(runtime_spec.get("canopyRadius", 1.8))
    var trunk_radius := maxf(0.12, float(spec.get("trunk_radius", 0.36)))
    var canopy_radius := maxf(trunk_radius, float(spec.get("canopy_radius", 1.8)))
    var exclusion_margin := float(runtime_spec.get("exclusionMargin", 0.0))
    if world_cell.x != 2147483647 and natural_tree_blocked_at_cell(
        world_cell.x,
        world_cell.y,
        trunk_radius + exclusion_margin,
        canopy_radius + exclusion_margin
    ):
        return {}
    var candidate := {}
    if not runtime_spec.is_empty():
        var height := float(spec.get("height", legacy_height))
        canopy_radius = maxf(0.1, float(spec.get("canopy_radius", 1.8)))
        var architecture := String(runtime_spec.get("architecture", "broadleaf"))
        var tree_transform := Transform3D(Basis(Vector3.UP, float(spec.get("rotation", 0.0))), position)
        candidate = {
            "sourceId": "%s:tree:%s" % [seed_text, prop_id],
            "propId": prop_id,
            "visualId": "procedural-tree:%s" % prop_id,
            "recipeVersion": 2,
            "kind": "trees_foliage",
            "renderLayers": ["opaque_branches", "alpha_scissor_foliage"],
            "materials": ["procedural_tree_bark:%s:%s" % [architecture, biome],
                "procedural_tree_foliage:%s:%s" % [architecture, biome]],
            "meshSource": "procedural_tree_recipe:v2",
            "runtimeSpec": runtime_spec.duplicate(true),
            "legacySpec": spec.duplicate(true),
            "transform": tree_transform,
            "localBounds": AABB(Vector3(-canopy_radius, 0.0, -canopy_radius),
                Vector3(canopy_radius * 2.0, height, canopy_radius * 2.0))
        }
    var support_proof := {"status": "failed", "reason": "tree_candidate_missing"}
    if not candidate.is_empty():
        var local_bounds: AABB = candidate.localBounds
        support_proof = EcologyProducerDomainScript.validate_source_bounds("trees", position,
            AABB(position + local_bounds.position, local_bounds.size),
            runtime_support_policy)
    return {
        "status": String(support_proof.get("status", "pending")) if not candidate.is_empty() else "failed",
        "reason": String(support_proof.get("reason", "")) if not candidate.is_empty() else "tree_runtime_source_request_unavailable",
        "failureReason": "tree_runtime_source_request_unavailable" if candidate.is_empty() else "",
        "supportProof": support_proof,
        "family": "trees",
        "propId": prop_id,
        "position": position,
        "biome": biome,
        "worldCell": world_cell,
        "treeSpec": spec.duplicate(true),
        "runtimeSpec": runtime_spec.duplicate(true),
        "candidate": candidate,
    }

## Publishes an already generated request without ecology/RNG or natural-prop
## exclusion sampling. Position and yaw are explicitly parent-local; dimensions
## are world units, so the parent must be rigid and upright. Only the copied
## request's placement is rebound to world space, never its recipe identity.
## The owner supplies a stable durable prop_id, prevents duplicate publication,
## and retains/retries deferred requests. Harvest remains the removed_props
## writer; neither rejection nor deferral records a durable removal.
func make_tree_from_runtime_request(
    parent: Node3D,
    prop_id: String,
    position: Vector3,
    biome: String,
    runtime_request: Dictionary,
    rotation_y: float
) -> Dictionary:
    if parent == null or not is_instance_valid(parent) or not parent.is_inside_tree():
        return {"status": "deferred", "reason": "parent_not_ready", "body": null}
    if prop_id.is_empty() or not position.is_finite() or not is_finite(rotation_y):
        return {"status": "rejected", "reason": "invalid_placement", "body": null}
    if removed_props.has(prop_id):
        return {"status": "skipped", "reason": "removed_prop", "body": null}
    var parent_basis := parent.global_basis
    if not parent_basis.is_equal_approx(parent_basis.orthonormalized()) or not parent_basis.y.is_equal_approx(Vector3.UP) or not is_equal_approx(parent_basis.determinant(), 1.0):
        return {"status": "rejected", "reason": "parent_not_rigid_upright", "body": null}
    if not TreeRuntimeRequestBuilderScript.is_procedural_request(runtime_request):
        return {"status": "rejected", "reason": "invalid_runtime_request", "body": null}
    var active_catalog = biome_environment_catalog
    if active_catalog == null or not is_instance_valid(active_catalog):
        return {"status": "rejected", "reason": "tree_admission_catalog_unavailable", "body": null}
    var current_profile_snapshot := ActiveBiomeEnvironmentSnapshotScript.capture(active_catalog)
    var admission := TreeRequestAdmissionScript.validate_request(runtime_request,
        current_profile_snapshot)
    if String(admission.get("status", "")) != "ready":
        return {"status": "rejected", "reason": String(admission.get("reason", "tree_admission_rejected")), "body": null}
    # Reject unsupported dimensions rather than silently clamp an authored tree.
    for key in ["visualHeight", "trunkRadius", "canopyRadius", "collisionHeight"]:
        var value: Variant = runtime_request.get(key)
        if not (value is float or value is int) or not is_finite(float(value)):
            return {"status": "rejected", "reason": "invalid_dimensions", "body": null}
    var height := float(runtime_request["visualHeight"])
    var trunk_radius := float(runtime_request["trunkRadius"])
    var canopy_radius := float(runtime_request["canopyRadius"])
    var collision_height := float(runtime_request["collisionHeight"])
    if height < 1.0 or trunk_radius < 0.12 or canopy_radius < trunk_radius or collision_height < 1.0 or collision_height > height:
        return {"status": "rejected", "reason": "unsupported_dimensions", "body": null}
    var world_position := parent.to_global(position)
    if player != null and is_instance_valid(player) and _player_position_overlaps_tree_dimensions(player.global_position, world_position, height, trunk_radius):
        return {"status": "deferred", "reason": "player_overlap", "body": null}
    var runtime_spec := runtime_request.duplicate(true)
    runtime_spec["worldPosition"] = world_position
    runtime_spec["worldRotationY"] = parent_basis.get_euler().y + rotation_y
    var spec := {
        "rotation": rotation_y,
        "height": height,
        "trunk_radius": trunk_radius,
        "canopy_radius": canopy_radius,
        "runtime_spec": runtime_spec
    }
    var body = _publish_tree_body(parent, prop_id, position, biome, spec, runtime_spec, false)
    return {"status": "published", "reason": "visual_queued", "body": body}

func _publish_tree_body(
    parent: Node,
    prop_id: String,
    position: Vector3,
    biome: String,
    spec: Dictionary,
    runtime_spec: Dictionary,
    resolve_player_overlap := true
):
    var legacy_height := float(spec.get("legacy_height", spec.get("height", 4.0)))
    var trunk_radius := maxf(0.12, float(spec.get("trunk_radius", 0.36)))
    var canopy_radius := maxf(trunk_radius, float(spec.get("canopy_radius", 1.8)))
    var body := StaticBody3D.new()
    body.name = "Tree"
    body.position = position
    body.rotation.y = float(spec.get("rotation", 0.0))
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "logs")
    body.set_meta("material", "tree")
    body.set_meta("drop_count", 3)
    body.set_meta("visual_biome", biome)
    body.set_meta("tree_family", String(runtime_spec.get("family", "primitive_fallback")))
    body.set_meta("tree_growth_class", String(runtime_spec.get("growthClass", "standard")))
    body.set_meta("tree_architecture", String(runtime_spec.get("architecture", "legacy")))
    body.set_meta("tree_age_band", String(runtime_spec.get("ageBand", "standard")))
    body.set_meta("tree_age_years", float(runtime_spec.get("ageYears", 0.0)))
    body.set_meta("tree_age_range_min", float(runtime_spec.get("ageRangeMin", 0.0)))
    body.set_meta("tree_age_range_max", float(runtime_spec.get("ageRangeMax", 0.0)))
    body.set_meta("tree_local_maturity", float(runtime_spec.get("localMaturity", 0.5)))
    body.set_meta("tree_genetic_seed", int(runtime_spec.get("geneticSeed", 0)))
    body.set_meta("tree_canopy_radius", canopy_radius)
    body.set_meta("tree_trunk_radius", trunk_radius)
    body.set_meta("tree_visual_height", float(spec.get("height", legacy_height)))
    body.set_meta("tree_collision_height", float(runtime_spec.get("collisionHeight", spec.get("height", legacy_height))))
    body.set_meta("tree_old_growth", bool(runtime_spec.get("oldGrowth", false)))
    var horizon_only := bool(parent.get_meta("horizon_visual_only", false))
    if not horizon_only:
        body.add_to_group("generated_tree_trunks")

    var height := float(spec.get("height", 4.0))
    # Branches and foliage are deliberately non-colliding. The recipe supplies
    # one bounded interaction trunk rather than a collider that reaches through
    # the complete crown.
    var collision_height := clampf(float(runtime_spec.get("collisionHeight", height)), 1.0, height)
    if not horizon_only:
        var trunk_shape := CylinderShape3D.new()
        trunk_shape.radius = trunk_radius
        trunk_shape.height = collision_height
        var collider := CollisionShape3D.new()
        collider.shape = trunk_shape
        collider.position.y = collision_height * 0.5
        body.add_child(collider)

    parent.add_child(body)
    # The visual queue ranks publication by distance from the live viewer.  The
    # collision body must therefore be in the scene tree before its visual is
    # enqueued; using global_position before this point asks Godot for an
    # invalid transform during ordinary chunk prop creation.
    add_tree_visual(body, prop_id, biome, spec)
    var tree_source_bounds := AABB(Vector3(-canopy_radius, 0.0, -canopy_radius),
        Vector3(canopy_radius * 2.0, float(spec.get("height", legacy_height)), canopy_radius * 2.0))
    body.set_meta("static_ecology_source_id", "%s:tree:%s" % [seed_text, prop_id])
    body.set_meta("static_ecology_source_bounds", body.global_transform * tree_source_bounds)
    if resolve_player_overlap and not horizon_only:
        resolve_player_tree_publication_overlap(body)
    if not horizon_only and npc_system and npc_system.has_method("notify_navigation_prop_created"):
        npc_system.notify_navigation_prop_created(prop_id, body)
    return body

func resolve_player_tree_publication_overlap(tree: Node3D) -> bool:
    if player == null or not is_instance_valid(player):
        return false
    if not player_position_overlaps_generated_tree(player.global_position, tree):
        return false
    var center := tree.global_position
    var delta := Vector2(player.global_position.x - center.x, player.global_position.z - center.z)
    var base_angle := delta.angle() if delta.length_squared() > 0.0001 else float(posmod(String(tree.get_meta("prop_id", tree.name)).hash(), 360)) * PI / 180.0
    var trunk_radius := maxf(0.12, float(tree.get_meta("tree_trunk_radius", 0.36)))
    for radius_extra in [1.05, 2.40, 4.20]:
        var radius := trunk_radius + float(radius_extra)
        for index in range(24):
            var angle := base_angle + TAU * float(index) / 24.0
            var candidate_xz := Vector2(center.x, center.z) + Vector2(cos(angle), sin(angle)) * radius
            var candidate_cell := Vector3i(world_to_cell(candidate_xz.x), 0, world_to_cell(candidate_xz.y))
            var candidate := Vector3(candidate_xz.x, surface_y_at_cell(candidate_cell) + 0.15, candidate_xz.y)
            if player_tree_relocation_candidate_is_clear(candidate):
                player.global_position = candidate
                player.velocity = Vector3.ZERO
                return true
    return false

func player_tree_relocation_candidate_is_clear(candidate: Vector3) -> bool:
    if player == null or not is_instance_valid(player):
        return false
    var scene_tree := player.get_tree()
    if scene_tree != null:
        for node in scene_tree.get_nodes_in_group("generated_tree_trunks"):
            if node is Node3D and is_instance_valid(node) and player_position_overlaps_generated_tree(candidate, node as Node3D):
                return false
    var candidate_cell := Vector3i(world_to_cell(candidate.x), world_to_cell(candidate.y), world_to_cell(candidate.z))
    for dy in range(0, 3):
        if blocks.has(candidate_cell + Vector3i(0, dy, 0)):
            return false
    return true

func ensure_tree_publication_queue():
    if tree_publication_queue != null and is_instance_valid(tree_publication_queue):
        if player != null and is_instance_valid(player) and tree_publication_queue.has_method("set_viewer"):
            tree_publication_queue.set_viewer(player)
        _enable_section_owned_tree_publication_if_available()
        return tree_publication_queue
    tree_publication_queue = TreePublicationQueueScript.new()
    tree_publication_queue.name = "TreePublicationQueue"
    add_child(tree_publication_queue)
    tree_publication_queue.tree_visual_published.connect(_on_visible_world_tree_visual_published)
    tree_publication_queue.tree_section_values_prepared.connect(
        _on_visible_world_tree_section_values_prepared)
    if player != null and is_instance_valid(player) and tree_publication_queue.has_method("set_viewer"):
        tree_publication_queue.set_viewer(player)
    _enable_section_owned_tree_publication_if_available()
    return tree_publication_queue

func _enable_section_owned_tree_publication_if_available() -> void:
    var coordinator: Variant = get("world_static_section_coordinator")
    if is_instance_valid(tree_publication_queue) \
            and tree_publication_queue.has_method("set_section_owned_publication_enabled") \
            and coordinator != null and is_instance_valid(coordinator):
        if tree_publication_queue.call("bind_presentation_coordinator", coordinator):
            tree_publication_queue.call("set_section_owned_publication_enabled", true)

func tree_publication_proof(body: Variant, include_installed := true) -> Dictionary:
    var queue: Variant = get("tree_publication_queue")
    if not is_instance_valid(queue) or not queue.has_method("tree_publication_proof"):
        return {"status":"failed", "reason":"tree_publication_authority_missing"}
    return queue.call("tree_publication_proof", body, include_installed)

## Main-thread source capture; installation is deliberately not a prerequisite.
## Durable removal and the queue's current recipe incarnation remain authority.
func capture_tree_section_source(body: Variant) -> Dictionary:
    if not is_instance_valid(body) or not body is StaticBody3D:
        return {"status":"pending", "reason":"tree_source_owner_unavailable"}
    var prop_id := String(body.get_meta("prop_id", ""))
    if prop_id.is_empty() or removed_props.has(prop_id):
        return {"status":"pending", "reason":"tree_source_removed"}
    var queue: Variant = get("tree_publication_queue")
    if not is_instance_valid(queue) or not queue.has_method("capture_section_source"):
        return {"status":"pending", "reason":"tree_source_authority_unavailable"}
    return queue.call("capture_section_source", body, seed_text)

func tree_source_is_durably_removed(prop_id: String) -> bool:
    return not prop_id.is_empty() and removed_props.has(prop_id)

func invalidate_tree_section_source(body: Variant) -> void:
    if is_instance_valid(body) and body is StaticBody3D:
        _invalidate_visible_world_tree_source(body)

func _on_visible_world_tree_visual_published(body: StaticBody3D, _recipe: Dictionary) -> void:
    if body == null or not is_instance_valid(body): return
    visible_world_demand_controller.handoff_published_tree("player",
        world_to_chunk(body.global_position.x, body.global_position.z), body)
    _invalidate_visible_world_tree_source(body)

func _on_visible_world_tree_section_values_prepared(body: StaticBody3D) -> void:
    if body == null or not is_instance_valid(body): return
    _invalidate_visible_world_tree_source(body)

func _invalidate_visible_world_tree_source(body: StaticBody3D) -> void:
    var finite_reference: Variant = body.get_meta("building_tree_source_owner") if body.has_meta("building_tree_source_owner") else null
    var finite_owner: Variant = finite_reference.get_ref() if finite_reference is WeakRef else null
    if is_instance_valid(finite_owner) and finite_owner.has_method("tree_section_source_identity"):
        var identity: Dictionary = finite_owner.call("tree_section_source_identity", body)
        if identity.get("status") == "ready":
            var coordinator: Variant = get("world_static_section_coordinator")
            if is_instance_valid(coordinator):
                coordinator.call("invalidate_visible_static_source", "blueprint_buildings",
                    String(identity.sourceId), "tree-change:%s:%s" % [removed_props_revision,
                        int(body.get_meta("tree_section_recipe_input_expected_generation", 0))], identity.bounds)
            return
    var source_id := str(body.get_meta("static_ecology_source_id", ""))
    var source_revision := str(body.get_meta("tree_recipe_signature", ""))
    var source_bounds: Variant = body.get_meta("static_ecology_source_bounds", AABB())
    if not source_id.is_empty() and not source_revision.is_empty() and source_bounds is AABB:
        var section_coordinator: Variant = get("world_static_section_coordinator")
        if section_coordinator != null \
                and section_coordinator.has_method("invalidate_visible_static_source"):
            section_coordinator.call("invalidate_visible_static_source",
                "ecology_and_static_props", source_id, source_revision, source_bounds)

func player_position_overlaps_generated_tree(position: Vector3, tree: Node3D) -> bool:
    if tree == null or not is_instance_valid(tree):
        return false
    var center := tree.global_position
    var height := maxf(0.5, float(tree.get_meta("tree_visual_height", 4.0)))
    return _player_position_overlaps_tree_dimensions(position, center, height, float(tree.get_meta("tree_trunk_radius", 0.36)))

func _player_position_overlaps_tree_dimensions(position: Vector3, center: Vector3, height: float, trunk_radius: float) -> bool:
    if position.y < center.y - 0.5 or position.y > center.y + height + 0.5:
        return false
    var horizontal_delta := Vector2(position.x - center.x, position.z - center.z)
    return horizontal_delta.length() < maxf(0.12, trunk_radius) + 0.80

func natural_tree_blocked_at_cell(
    x: int,
    z: int,
    natural_exclusion_margin_world: float,
    structure_footprint_margin_world: float
) -> bool:
    if structure_system == null:
        return false
    var natural_margin_cells := ceili(maxf(0.0, natural_exclusion_margin_world) / CELL)
    var structure_margin_cells := ceili(maxf(0.0, structure_footprint_margin_world) / CELL)
    if structure_system.has_method("blocks_natural_prop_with_separate_margins_at_cell"):
        return bool(structure_system.call(
            "blocks_natural_prop_with_separate_margins_at_cell",
            x,
            z,
            natural_margin_cells,
            structure_margin_cells
        ))
    if structure_system.has_method("blocks_natural_prop_with_margin_at_cell"):
        return bool(structure_system.call("blocks_natural_prop_with_margin_at_cell", x, z, structure_margin_cells))
    return natural_props_blocked_at_cell(x, z)

func rock_visual_spec(rng: RandomNumberGenerator) -> Dictionary:
    return RockRecipeBuilderScript.build_visual_spec(rng)

func add_rock_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> void:
    if add_generated_rock_visual(body, prop_id, biome, spec):
        return
    add_fallback_rock_visual(body, spec)

func add_generated_rock_visual(body: StaticBody3D, prop_id: String, biome: String, spec: Dictionary) -> bool:
    if visual_asset_registry == null or not visual_asset_registry.is_ready():
        return false
    var asset_id: String = visual_asset_registry.select_rock_asset_id(biome, prop_id)
    var visual: Node3D = visual_asset_registry.instantiate_asset(asset_id)
    if visual == null:
        return false
    var radius := float(spec.get("radius", 0.8))
    var height_factor := float(spec.get("height_factor", 1.0))
    var old_scale: Vector3 = spec.get("scale", Vector3.ONE)
    var asset_size: Vector3 = visual_asset_registry.asset_size(asset_id)
    var sx := (radius * 2.0 * old_scale.x) / maxf(0.1, asset_size.x)
    var sy := (radius * height_factor * old_scale.y) / maxf(0.1, asset_size.z)
    var sz := (radius * 2.0 * old_scale.z) / maxf(0.1, asset_size.y)
    var profile_scale: float = visual_asset_registry.rock_scale_for_biome(biome)
    visual.name = "GeneratedRockVisual"
    visual.position = Vector3.ZERO
    visual.rotation = Vector3.ZERO
    visual.scale = Vector3(sx, sy, sz) * profile_scale
    visual.set_meta("visual_source", "generated_asset")
    visual.set_meta("visual_asset_id", asset_id)
    body.add_child(visual)
    body.set_meta("visual_source", "generated_asset")
    body.set_meta("visual_asset_id", asset_id)
    var manifest_value: Variant = visual.get_meta("static_render_member_values", [])
    var render_members: Array[Dictionary] = []
    var pending_reason := ""
    if not manifest_value is Array or manifest_value.is_empty():
        pending_reason = "generated_rock_asset_render_manifest_empty"
    else:
        for member_value: Variant in manifest_value:
            if not member_value is Dictionary \
                    or String(member_value.get("status", "")) != "ready":
                pending_reason = String(member_value.get("reason",
                    "generated_rock_asset_render_member_pending")) \
                    if member_value is Dictionary else "generated_rock_asset_render_member_invalid"
                continue
            var member: Dictionary = member_value
            var member_transform: Transform3D = visual.transform * member.get("transform",
                Transform3D.IDENTITY)
            var captured_member := ecology_render_member(
                String(member.get("memberId", "")), member.get("mesh") as Mesh,
                member_transform, String(member.get("materialKey", "")),
                String(member.get("renderLayer", "")), member.get("material") as Material)
            if captured_member.get("status") != "ready":
                pending_reason = String(captured_member.get("reason",
                    "generated_rock_asset_render_member_unrenderable"))
            render_members.append(captured_member)
    body.set_meta("ecology_render_members", render_members)
    if not pending_reason.is_empty():
        body.set_meta("ecology_render_capture_pending", pending_reason)
    else:
        body.remove_meta("ecology_render_capture_pending")
    return true

func add_fallback_rock_visual(body: StaticBody3D, spec: Dictionary) -> void:
    var radius := float(spec.get("radius", 0.8))
    var rock_mesh := SphereMesh.new()
    rock_mesh.radius = radius
    rock_mesh.height = radius * float(spec.get("height_factor", 1.0))
    var rock := MeshInstance3D.new()
    rock.name = "PrimitiveRockVisual"
    rock.mesh = rock_mesh
    rock.material_override = materials["rock"]
    rock.position.y = radius * 0.42
    rock.scale = spec.get("scale", Vector3.ONE)
    rock.set_meta("visual_source", "primitive_fallback")
    body.add_child(rock)
    body.set_meta("visual_source", "primitive_fallback")
    body.set_meta("visual_asset_id", "")
    var transform := Transform3D(Basis.IDENTITY.scaled(rock.scale), rock.position)
    body.set_meta("ecology_render_members", [ecology_render_member(
        "rock_visual", rock_mesh, transform, "rock", "opaque", materials["rock"])])

func prop_biome_for_position(parent: Node, position: Vector3) -> String:
    var world_position := position
    var parent_node := parent as Node3D
    if parent_node:
        world_position = parent_node.global_transform * position
    return surface_biome_at_cell(Vector3i(world_to_cell(world_position.x), world_to_cell(world_position.y), world_to_cell(world_position.z)))

func build_rock_source_value(prop_id: String, position: Vector3, biome: String,
        rng: RandomNumberGenerator, visual_owner_receipt: Dictionary = {},
        require_publication := false) -> Dictionary:
    var spec := rock_visual_spec(rng)
    var radius := float(spec.get("radius", 0.8))
    var shape_scale: Vector3 = spec.get("scale", Vector3.ONE)
    var source_id := "%s:rock:%s" % [seed_text, prop_id]
    var asset_id := ""
    var descriptor_identity := ""
    var descriptor: Dictionary = {}
    var render_members: Array[Dictionary] = []
    var local_bounds := AABB()
    var has_bounds := false
    var source_visual := "primitive_fallback"
    var profile_scale := 1.0
    if is_instance_valid(visual_asset_registry) \
            and visual_asset_registry.has_method("is_ready") \
            and bool(visual_asset_registry.call("is_ready")):
        var asset_size := Vector3.ZERO
        if not visual_owner_receipt.is_empty():
            if not visual_asset_registry.has_method("rock_source_descriptor_for_publication"):
                return {"status":"pending", "reason":"rock_publication_resolver_unavailable",
                    "sourceId":source_id, "propId":prop_id, "retryable":true}
            var published_source: Dictionary = visual_asset_registry.call(
                "rock_source_descriptor_for_publication", visual_owner_receipt,
                biome, prop_id)
            if String(published_source.get("status", "")) != "ready":
                return {"status":String(published_source.get("status", "pending")),
                    "reason":String(published_source.get("reason",
                        "rock_publication_descriptor_pending")),
                    "sourceId":source_id, "propId":prop_id,
                    "retryable":String(published_source.get("status", "")) == "pending"}
            asset_id = String(published_source.get("assetId", ""))
            descriptor = published_source.get("descriptor", {})
            asset_size = published_source.get("assetSize", Vector3.ZERO)
            profile_scale = float(published_source.get("profileScale", 0.0))
            descriptor_identity = String(published_source.get(
                "assetDescriptorDigest", ""))
            if String(published_source.get("sourceVisualContentDigest", "")) \
                    != String(ecology_current_owner_publications.get("visual", {}).get(
                        "contentDigest", "")) \
                    or String(published_source.get("sourceBiomeContentDigest", "")) \
                    != String(ecology_current_owner_publications.get("biome", {}).get(
                        "contentDigest", "")):
                return {"status":"pending", "reason":"rock_publication_dependency_stale",
                    "sourceId":source_id, "propId":prop_id, "retryable":true}
        else:
            if require_publication:
                return {"status":"pending", "reason":"rock_owner_publication_receipt_missing",
                    "sourceId":source_id, "propId":prop_id, "retryable":true}
            asset_id = str(visual_asset_registry.call("select_rock_asset_id", biome, prop_id))
            var disabled_assets: Variant = visual_asset_registry.get("disabled_asset_ids")
            if not asset_id.is_empty() and disabled_assets is Dictionary \
                    and disabled_assets.has(asset_id):
                asset_id = ""
            if asset_id.is_empty():
                return {"status":"failed", "reason":"rock_selected_asset_missing",
                    "sourceId":source_id, "propId":prop_id}
            if not visual_asset_registry.has_method("describe_static_asset_without_instantiation"):
                return {"status":"failed", "reason":"rock_static_scene_descriptor_unavailable",
                    "sourceId":source_id, "propId":prop_id}
            descriptor = visual_asset_registry.call(
                "describe_static_asset_without_instantiation", asset_id)
            if descriptor.get("status", "") != "ready" \
                    or not visual_asset_registry.has_method("static_asset_descriptor_is_current") \
                    or not bool(visual_asset_registry.call(
                        "static_asset_descriptor_is_current", descriptor)):
                return {"status":"failed", "reason":str(descriptor.get("reason",
                    "rock_static_scene_descriptor_pending_or_stale")),
                    "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
            asset_size = visual_asset_registry.call("asset_size", asset_id)
            profile_scale = float(visual_asset_registry.call("rock_scale_for_biome", biome))
            descriptor_identity = String(descriptor.get("assetDescriptorDigest", ""))
        if asset_id.is_empty() or not descriptor is Dictionary:
            return {"status":"failed", "reason":"rock_published_descriptor_invalid",
                "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
        if asset_size.x <= 0.0 or asset_size.y <= 0.0 or asset_size.z <= 0.0:
            return {"status":"failed", "reason":"rock_asset_size_invalid",
                "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
        var visual_scale := Vector3(
            (radius * 2.0 * shape_scale.x) / maxf(0.1, asset_size.x),
            (radius * float(spec.get("height_factor", 1.0)) * shape_scale.y) \
                / maxf(0.1, asset_size.z),
            (radius * 2.0 * shape_scale.z) / maxf(0.1, asset_size.y)) * profile_scale
        var root_transform := Transform3D(Basis.IDENTITY.scaled(visual_scale), Vector3.ZERO)
        for member_value: Variant in descriptor.get("renderMembers", []):
            if not member_value is Dictionary:
                return {"status":"failed", "reason":"rock_asset_member_invalid",
                    "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
            var descriptor_member: Dictionary = member_value
            var source_transform: Variant = descriptor_member.get("transform", null)
            var mesh_bounds: Variant = descriptor_member.get("meshBounds", null)
            if not source_transform is Transform3D or not mesh_bounds is AABB:
                return {"status":"failed", "reason":"rock_asset_member_geometry_unproven",
                    "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
            var member_transform: Transform3D = root_transform * (source_transform as Transform3D)
            var member_bounds: AABB = member_transform * (mesh_bounds as AABB)
            local_bounds = member_bounds if not has_bounds else local_bounds.merge(member_bounds)
            has_bounds = true
            render_members.append({
                "memberId":str(descriptor_member.get("memberId", "")),
                "meshSource":"visual_asset:%s:%s:%d" % [asset_id,
                    str(descriptor_member.get("nodePath", "")),
                    int(descriptor_member.get("meshSurfaceIndex", -1))],
                "meshResourcePath":str(descriptor_member.get("meshResourcePath", "")),
                "meshContentDigest":str(descriptor_member.get("meshContentDigest", "")),
                "meshBounds":mesh_bounds,
                "materialKey":str(descriptor_member.get("materialKey", "")),
                "materialResourcePath":str(descriptor_member.get("materialResourcePath", "")),
                "materialContentDigest":str(descriptor_member.get("materialContentDigest", "")),
                "renderLayer":str(descriptor_member.get("renderLayer", "")),
                "surfaceIndex":int(descriptor_member.get("meshSurfaceIndex", -1)),
                "transform":member_transform,
                "localBounds":member_bounds})
        source_visual = "generated_asset"
    else:
        var fallback_mesh := SphereMesh.new()
        fallback_mesh.radius = radius
        fallback_mesh.height = radius * float(spec.get("height_factor", 1.0))
        var fallback_transform := Transform3D(Basis.IDENTITY.scaled(shape_scale),
            Vector3(0.0, radius * 0.42, 0.0))
        var fallback_member := ecology_render_member("rock_visual", fallback_mesh,
            fallback_transform, "rock", "opaque", materials.get("rock", null))
        if fallback_member.get("status", "") != "ready":
            return {"status":"failed", "reason":str(fallback_member.get("reason",
                "rock_fallback_member_unrenderable")), "sourceId":source_id, "propId":prop_id}
        local_bounds = fallback_member.localBounds
        has_bounds = true
        render_members.append({
            "memberId":"rock_visual", "meshSource":"primitive_rock_fallback:v1",
            "primitive":"sphere", "radius":radius,
            "height":fallback_mesh.height, "radialSegments":fallback_mesh.radial_segments,
            "rings":fallback_mesh.rings,
            "meshContentDigest":str(fallback_member.meshContentDigest),
            "meshBounds":fallback_member.meshBounds,
            "materialKey":"rock",
            "materialContentDigest":str(fallback_member.materialContentDigest),
            "renderLayer":"opaque", "transform":fallback_transform,
            "localBounds":local_bounds})
    if not has_bounds:
        return {"status":"failed", "reason":"rock_render_member_manifest_empty",
            "sourceId":source_id, "propId":prop_id, "assetId":asset_id}
    var asset_revision := EcologyProducerDomainScript.digest_value({
        "assetId":asset_id, "catalogContentDigest":str(descriptor.get(
            "catalogContentDigest", "")),
        "sceneContentDigest":str(descriptor.get("sceneContentDigest", "")),
        "assetDescriptorDigest":descriptor_identity,
        "members":render_members, "visualScale":profile_scale})
    return {
        "status": "ready",
        "family": "surface_rocks",
        "sourceId": source_id,
        "propId": prop_id,
        "kind": "surface_rock_recipe",
        "biome": biome,
        "position": position,
        "bodyRotation": Vector3(0.0, float(spec.get("rotation", 0.0)), 0.0),
        "recipeVersion": 1,
        "recipe": spec.duplicate(true),
        "assetId":asset_id, "assetRevision":asset_revision,
        "assetDescriptorIdentity":{
            "catalogContentDigest":str(descriptor.get("catalogContentDigest", "")),
            "sceneContentDigest":str(descriptor.get("sceneContentDigest", "")),
            "registryRevision":str(descriptor.get("registryReceipt", {}).get("revision", "")) \
                if descriptor.get("registryReceipt", {}) is Dictionary else "",
        },
        "sourceVisual":source_visual,
        "renderMembers":render_members, "localBounds":local_bounds,
    }


func make_rock(parent: Node, prop_id: String, position: Vector3, rng: RandomNumberGenerator,
        prebuilt_source_value: Dictionary = {}, biome_override := ""):
    var biome := biome_override
    if biome.is_empty():
        if parent == null:
            return {"status": "pending", "reason": "node_free_rock_capture_requires_authoritative_biome"}
        biome = prop_biome_for_position(parent, position)
    var source_value := prebuilt_source_value
    if source_value.is_empty():
        source_value = build_rock_source_value(prop_id, position, biome, rng)
    if parent == null or not is_instance_valid(parent):
        return source_value
    var horizon_only := bool(parent.get_meta("horizon_visual_only", false))
    var setup_started: int = runtime_perf_monitor.begin_section("rock_setup") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var spec: Dictionary = source_value.get("recipe", {})
    var body := StaticBody3D.new()
    body.name = "Rock"
    body.position = position
    body.rotation.y = float(spec.get("rotation", 0.0))
    body.set_meta("kind", "prop")
    body.set_meta("prop_id", prop_id)
    body.set_meta("drop", "stones")
    body.set_meta("material", "rock")
    body.set_meta("drop_count", 4)
    body.set_meta("visual_biome", biome)
    body.set_meta("static_ecology_source_recipe", source_value.duplicate(true))
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_setup", setup_started)

    var radius := float(spec.get("radius", 0.8))
    var visual_started: int = runtime_perf_monitor.begin_section("rock_visual") if runtime_perf_monitor != null else Time.get_ticks_usec()
    add_rock_visual(body, prop_id, biome, spec)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_visual", visual_started)

    var collision_started: int = runtime_perf_monitor.begin_section("rock_collision") if runtime_perf_monitor != null else Time.get_ticks_usec()
    var collider: CollisionShape3D
    if not horizon_only:
        var shape := SphereShape3D.new()
        shape.radius = radius * 1.05
        collider = CollisionShape3D.new()
        collider.shape = shape
        collider.position.y = radius * 0.42
        body.add_child(collider)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_collision", collision_started)
    var tree_started: int = runtime_perf_monitor.begin_section("rock_tree_attach") if runtime_perf_monitor != null else Time.get_ticks_usec()
    parent.add_child(body)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.end_section("rock_tree_attach", tree_started)
    if not horizon_only and npc_system and npc_system.has_method("notify_navigation_prop_created"):
        var navigation_started: int = runtime_perf_monitor.begin_section("rock_navigation_notify") if runtime_perf_monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_prop_created(prop_id, body)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.end_section("rock_navigation_notify", navigation_started)
    if not horizon_only:
        rock_published.emit(body, collider)
    var capture_members: Array = body.get_meta("ecology_render_members", []) \
        if body.get_meta("ecology_render_members", []) is Array else []
    _record_realized_ecology_prop(parent, body, "rock", capture_members,
        String(body.get_meta("ecology_render_capture_pending", "")))
    return body

func make_ore_cluster(parent: Node, prop_id: String, position: Vector3, ore_type: String, rng: RandomNumberGenerator, count: int = 3) -> Array:
    var outputs := []
    var cluster_count: int = clampi(count, 1, 4)
    for i in range(cluster_count):
        var child_id := prop_id if i == 0 else "%s:cluster%d" % [prop_id, i]
        if removed_props.has(child_id):
            continue
        var angle: float = rng.randf() * TAU + float(i) * TAU / float(cluster_count)
        var spacing: float = 0.0 if i == 0 else CELL * (0.60 + rng.randf() * 0.42)
        var offset := Vector3(cos(angle) * spacing, rng.randf() * 0.08, sin(angle) * spacing)
        var descriptor: Dictionary = call("build_ore_source_value", child_id,
            position + offset, ore_type, rng)
        descriptor["clusterSize"] = cluster_count
        if parent == null or not is_instance_valid(parent):
            outputs.append(descriptor)
            continue
        var node: Node = call("make_ore_from_source_value", parent, descriptor)
        if node:
            node.set_meta("cluster_size", cluster_count)
            outputs.append(node)
    return outputs
