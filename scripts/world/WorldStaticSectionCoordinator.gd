extends RefCounted
class_name WorldStaticSectionCoordinator

## World-lifetime, serialized coordinator for immutable static-section inputs.
##
## Producer jobs submit source-part replacements/removals and immutable
## prepared instance segments. One ledger combines each change with every
## previously committed contributor in the world, so independent producers
## cannot overwrite each other's content in an overlapping section.
##
## This is an integration boundary, not a second world authority. Callers must
## provide a fresh canonical (sourceId, sourcePartId) revision map and exact
## section census
## on every advance. The census must come from authoritative producer discovery;
## the ledger's known contributors alone do not prove completeness.
##
## Renderer support is layer-manifest instance batches. Section slots resolve to
## independent render-demand owners; source-chunk keys describe immutable
## capture coverage and do not pin gameplay chunks after sealing. Producer
## revisions and exact contributor census still require authoritative discovery
## on every advance; this coordinator does not infer completeness from its ledger.

const LedgerScript = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SourceRoster = preload("res://scripts/world/StaticSectionSourceRoster.gd")
const CandidateAssembler = preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const GeometryOwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const GeometryOwnerSectionSlice := preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")

const MAX_VISIBLE_SECTION_DEMAND_SCAN_PER_ADVANCE := 32
const MAX_SUPPORT_TERRAIN_REVISION_CAPTURES_PER_FRAME := 2
const VISIBLE_SECTION_DEMAND_RETRY_FRAMES := 30
const MAX_SOURCE_INVALIDATION_SECTIONS := 64
const MAX_PENDING_SOURCE_ACKNOWLEDGEMENTS_PER_ADVANCE := 1
const MAX_PENDING_SOURCE_RELEASES_PER_ADVANCE := 1
const MAX_PENDING_SOURCE_RELEASE_SCAN_PER_ADVANCE := 32
const MAX_PENDING_GEOMETRY_OWNER_COMPLETION_REQUESTS := 2048
const MAX_GEOMETRY_OWNER_COMPLETION_ATTEMPTS_PER_ADVANCE := 8
const MAX_GEOMETRY_OWNER_COMPLETION_CURSOR_WORK_PER_ADVANCE := 32
const MAX_GEOMETRY_OWNER_COMPLETION_BUDGET_USEC_PER_ADVANCE := 4000
const SOURCE_ACK_RETRY_BASE_FRAMES := 2
const SOURCE_ACK_RETRY_MAX_FRAMES := 120
const MAX_TRANSLUCENT_POV_RESORT_SCAN_PER_REFRESH := 16
const MAX_SOURCE_ACK_STATUS_SAMPLES := 8

var _ledger = LedgerScript.new()
var _source_roster = SourceRoster.new()
var _world_id := ""
var _boundary_queue: Array[Dictionary] = []
var _active_boundary: Dictionary = {}
var _generation := 0
var _committed_candidates: Dictionary = {}
var _installed_receipts: Dictionary = {}
var _replay_queue: Array[Vector3i] = []
var _replay_set: Dictionary = {}
var _active_replay: Dictionary = {}
var _census_digest_by_boundary: Dictionary = {}
var _production_candidates_by_section: Dictionary = {}
var _production_candidate_jobs: Dictionary = {}
var _production_install_cursor := 0
var _section_compile_dispatcher: RefCounted
var _section_compile_jobs: Dictionary = {}
var _section_compile_order: Array[Vector3i] = []
var _section_compile_accepting := true
var _section_compile_completed_count := 0
var _production_candidate_receipts: Dictionary = {}
var _geometry_owner_dependency_revision_by_source: Dictionary = {}
var _geometry_owner_visible_membership_revision_by_source: Dictionary = {}
var _geometry_owner_completion_reset_count_by_key: Dictionary = {}
var _geometry_owner_completion_active_key := ""
var _geometry_owner_completion_sessions: Dictionary = {}
var _geometry_owner_completion_session_key_by_source: Dictionary = {}
var _geometry_owner_completion_requests: Dictionary = {}
var _geometry_owner_completion_request_queue: Array[String] = []
var _geometry_owner_completion_request_key_by_source: Dictionary = {}
var _geometry_owner_receipt_scope_serial := 0
var _geometry_owner_receipt_scope_token := 0
var _geometry_owner_receipt_scope_owner: WeakRef
var _geometry_owner_receipt_scope_generation := -1
var _geometry_owner_receipt_scope_cache: Dictionary = {}
var _geometry_owner_receipt_scope_liveness_checks := 0
var _geometry_owner_receipt_scope_cache_hits := 0
var _pending_source_acknowledgements: Dictionary = {}
var _pending_source_acknowledgement_cursor := Vector3i.ZERO
var _has_pending_source_acknowledgement_cursor := false
var _last_source_acknowledgement_deferrals := {}
var _source_install_acknowledgements_by_section: Dictionary = {}
var _source_install_acknowledgement_counts := {
	"pending":0, "failed":0, "acknowledged":0, "stale":0}
var _pending_source_releases: Dictionary = {}
var _pending_source_release_order: Array[Dictionary] = []
var _pending_source_release_queue_index: Dictionary = {}
var _pending_source_release_free_slots: Array[int] = []
var _pending_source_release_cursor := 0
var _pending_frame_presentations: Dictionary = {}
var _frame_presentation_callback_counts := {"registered":0, "accepted":0,
	"cancelledNoOp":0, "staleNoOp":0}
var _production_candidate_generation := 0
var _visible_sections_by_source_id: Dictionary = {}
var _visible_section_keys_by_source_id: Dictionary = {}
var _dirty_source_sections: Dictionary = {}
var _visible_section_demands: Dictionary = {}
var _visible_section_demand_queue: Array[Dictionary] = []
var _visible_section_demand_head := 0
var _visible_section_demand_tail := 0
var _visible_section_demand_count := 0
var _visible_section_demand_queue_token := 0
var _visible_section_demand_attempts := 0
var _ordinary_geometry_owner_support_demands: Dictionary = {}
var _geometry_owner_lease_claims: Dictionary = {}
var _geometry_completion_providers: Dictionary = {}
var _visible_section_recompile_quota := 2
var _visible_section_demand_wake_rounds := 0
var _translucent_camera_position := Vector3.ZERO
var _has_translucent_camera_snapshot := false
var _translucent_visible_sections: Array[Vector3i] = []
var _translucent_visible_section_set: Dictionary = {}
var _translucent_visible_scan_cursor := 0
var _replay_pov_waiting_revision_by_section: Dictionary = {}
var _replay_reassembly_required_by_section: Dictionary = {}


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_world_identity")
	if _world_id == world_id:
		return {"status":"ready", "worldId":_world_id}
	if not _world_id.is_empty() or not _boundary_queue.is_empty() \
			or not _active_boundary.is_empty() or not _committed_candidates.is_empty():
		return _failed("world_static_section_coordinator_already_bound")
	_world_id = world_id
	return {"status":"ready", "worldId":_world_id}


func world_identity() -> String:
	return _world_id


## RenderingServer callbacks target this world-lifetime coordinator, never the
## short-lived install session. The map strongly retains each session until its
## global frame-boundary callback is accepted or safely discarded as a tombstone.
func register_pending_frame_presentation(session: RefCounted, token: String) -> Dictionary:
	if not is_instance_valid(session) or token.is_empty() \
			or String(session.get("state")) != "awaiting_frame" \
			or String(session.get("_presentation_token")) != token:
		return _failed("invalid_section_frame_callback_registration")
	if _pending_frame_presentations.has(token):
		var existing: Dictionary = _pending_frame_presentations[token]
		if existing.get("session") == session:
			return {"status":"queued", "token":token, "alreadyRegistered":true}
		return _failed("duplicate_section_frame_callback_token")
	_pending_frame_presentations[token] = {"session":session, "cancelled":false,
		"callbackReceived":false}
	_frame_presentation_callback_counts["registered"] += 1
	RenderingServer.request_frame_drawn_callback(
		Callable(self, "_on_section_frame_drawn").bind(token))
	return {"status":"queued", "token":token}


func cancel_pending_frame_presentation(session: RefCounted, token: String) -> Dictionary:
	if token.is_empty() or not _pending_frame_presentations.has(token):
		return {"status":"already_drained", "token":token}
	var record: Dictionary = _pending_frame_presentations[token]
	if record.get("session") != session:
		return _failed("section_frame_callback_owner_mismatch")
	if bool(record.get("callbackReceived", false)):
		_pending_frame_presentations.erase(token)
		return {"status":"already_drained", "token":token}
	record["cancelled"] = true
	return {"status":"tombstoned", "token":token}


func complete_pending_frame_presentation(session: RefCounted, token: String) -> Dictionary:
	if token.is_empty() or not _pending_frame_presentations.has(token):
		return {"status":"already_drained", "token":token}
	var record: Dictionary = _pending_frame_presentations[token]
	if record.get("session") != session or bool(record.get("cancelled", false)) \
			or not bool(record.get("callbackReceived", false)):
		return _failed("section_frame_presentation_completion_mismatch")
	_pending_frame_presentations.erase(token)
	return {"status":"completed", "token":token}


func frame_presentation_callback_diagnostics() -> Dictionary:
	var pending_callback_count := 0
	for record_value: Variant in _pending_frame_presentations.values():
		if record_value is Dictionary and not bool(record_value.get("callbackReceived", false)):
			pending_callback_count += 1
	return {"pendingCallbackCount":pending_callback_count,
		"awaitingPresentationCount":_pending_frame_presentations.size(),
		"registeredCallbackCount":int(_frame_presentation_callback_counts.get("registered", 0)),
		"acceptedCallbackCount":int(_frame_presentation_callback_counts.get("accepted", 0)),
		"cancelledCallbackCount":int(_frame_presentation_callback_counts.get("cancelledNoOp", 0)),
		"staleCallbackCount":int(_frame_presentation_callback_counts.get("staleNoOp", 0))}


## Cancel every install lane while its exact backend is still callable. A first
## installation has no committed candidate or frame callback yet; those maps
## therefore cannot serve as the inventory of execution owners.
func _cancel_install_sessions_before_owner_retirement(owner_cell: Variant = null,
		chunk_instance_id := 0) -> Dictionary:
	var failures: Array[Dictionary] = []
	var cancelled_count := 0
	for section_value: Variant in _production_candidate_jobs.keys():
		if not section_value is Vector3i: continue
		var section_key: Vector3i = section_value
		if owner_cell != null and SectionGrid.chunk_key_for_section(section_key) != owner_cell:
			continue
		var job: Dictionary = _production_candidate_jobs[section_key]
		var session: Variant = job.get("session")
		if session is RefCounted and chunk_instance_id > 0 \
				and int(session.get("_chunk_id")) != chunk_instance_id:
			continue
		var generation := int(job.get("candidate", {}).get("generation", 0))
		var result := _cancel_pending_production_candidate(section_key)
		if result.get("status") != "cancelled":
			failures.append({"lane":"production", "sectionKey":section_key, "result":result})
			continue
		cancelled_count += 1
		_reconcile_visible_section_candidate_outcome(section_key, generation, {
			"status":"cancelled", "reason":"section_install_owner_retired",
			"requiresReassembly":true, "retryable":true})
	var replay_session: Variant = _active_replay.get("installSession")
	if _install_session_matches_owner(replay_session, owner_cell, chunk_instance_id):
		var replay_key: Variant = _active_replay.get("sectionKey")
		var replay_result := _cancel_active_replay("render_owner_retirement")
		if replay_result.get("status") != "cancelled":
			failures.append({"lane":"replay", "result":replay_result})
		else:
			cancelled_count += 1
			if owner_cell != null and replay_key is Vector3i: _queue_replay(replay_key)
	var boundary_session: Variant = _active_boundary.get("installSession")
	if _install_session_matches_owner(boundary_session, owner_cell, chunk_instance_id):
		var boundary_result: Dictionary = boundary_session.cancel()
		if boundary_result.get("status") != "cancelled":
			_active_boundary["stage"] = "rollback_failed"
			_active_boundary["rollbackFailure"] = boundary_result
			failures.append({"lane":"boundary", "result":boundary_result})
		else:
			cancelled_count += 1
			_active_boundary["installSession"] = null
			_active_boundary.erase("stage")
			_active_boundary.erase("rollbackFailure")
			# Local owner recreation retries the same complete boundary. A global
			# teardown cancels its ledger transaction instead of leaving it active.
			if owner_cell == null: _unsupported_active("world_teardown")
	return {"status":"ready" if failures.is_empty() else "rollback_failed",
		"ownerMustBeRetained":not failures.is_empty(),
		"cancelledInstallSessionCount":cancelled_count, "failures":failures}


func _install_session_matches_owner(session: Variant, owner_cell: Variant,
		chunk_instance_id: int) -> bool:
	return session is RefCounted and is_instance_valid(session) \
		and session.has_method("cancel") \
		and (owner_cell == null or session.get("_owner_cell") == owner_cell) \
		and (chunk_instance_id <= 0 or int(session.get("_chunk_id")) == chunk_instance_id)


func drain_pending_frame_presentations() -> Dictionary:
	var install_drain := _cancel_install_sessions_before_owner_retirement()
	if install_drain.get("status") != "ready":
		return {"status":"rollback_failed", "drained":false,
			"ownerMustBeRetained":true, "installDrain":install_drain}
	var rolled_back := 0
	var rollback_failures: Array[String] = []
	for token_value: Variant in _pending_frame_presentations.keys():
		var token := String(token_value)
		var record: Dictionary = _pending_frame_presentations[token]
		var session: Variant = record.get("session")
		if not bool(record.get("cancelled", false)) and session is RefCounted \
				and is_instance_valid(session) and String(session.get("state")) == "awaiting_frame":
			var rollback: Dictionary = session.rollback_presentation(token)
			if rollback.get("status") != "cancelled":
				rollback_failures.append(token + ":" + String(rollback.get("reason", "rollback_failed")))
				continue
			rolled_back += 1
		if bool(record.get("callbackReceived", false)):
			# The callback has already been consumed, so there is no future server
			# event to wait for. A still-awaiting session was rolled back above;
			# installed/cancelled sessions can now release this token record.
			_pending_frame_presentations.erase(token)
			continue
		# Keep the coordinator callback target alive and the canceled session in
		# the token map until RenderingServer delivers the already-queued callback.
		record["cancelled"] = true
	if not rollback_failures.is_empty():
		return {"status":"rollback_failed", "drained":false,
			"ownerMustBeRetained":true, "rolledBackCount":rolled_back,
			"pendingCallbackCount":_pending_frame_presentations.size(),
			"rollbackFailures":rollback_failures}
	# The caller retains this coordinator while awaiting. Its token records also
	# strongly retain sessions until RenderingServer delivers every queued global
	# frame callback. Do not destroy backend owners while a callback can still
	# target this dispatcher.
	var main_loop := Engine.get_main_loop() as SceneTree
	if main_loop == null and not _pending_frame_presentations.is_empty():
		return {"status":"callback_dispatcher_unavailable", "drained":false,
			"ownerMustBeRetained":true, "rolledBackCount":rolled_back,
			"pendingCallbackCount":_pending_frame_presentations.size(),
			"rollbackFailures":[]}
	while not _pending_frame_presentations.is_empty():
		await main_loop.process_frame
	return {"status":"drained", "drained":true,
		"rolledBackCount":rolled_back, "pendingCallbackCount":0,
		"rollbackFailures":[]}


func _on_section_frame_drawn(token: String) -> void:
	if not _pending_frame_presentations.has(token):
		_frame_presentation_callback_counts["staleNoOp"] += 1
		return
	var record: Dictionary = _pending_frame_presentations[token]
	var session: Variant = record.get("session")
	if bool(record.get("cancelled", false)):
		_frame_presentation_callback_counts["cancelledNoOp"] += 1
		_pending_frame_presentations.erase(token)
	elif session is RefCounted and is_instance_valid(session) \
			and session.has_method("accept_frame_drawn_callback") \
			and bool(session.call("accept_frame_drawn_callback", token)):
		_frame_presentation_callback_counts["accepted"] += 1
		record["callbackReceived"] = true
	else:
		_frame_presentation_callback_counts["staleNoOp"] += 1
		_pending_frame_presentations.erase(token)


func configure_source_roster(required_provider_ids: Array[String]) -> Dictionary:
	if _world_id.is_empty():
		return _failed("world_static_section_coordinator_unconfigured")
	return _source_roster.bind_world(_world_id, required_provider_ids)


func register_source_provider(provider_id: String, authority_owner: Object,
		capture_method: String) -> Dictionary:
	var registered: Dictionary = _source_roster.register_provider(provider_id,
		authority_owner, capture_method)
	if registered.get("status") == "ready":
		if authority_owner.has_method("bind_geometry_completion_owner"):
			authority_owner.call("bind_geometry_completion_owner", self)
			_geometry_completion_providers[provider_id] = weakref(authority_owner)
		_wake_visible_section_demands()
	return registered


func unregister_source_provider(provider_id: String, authority_owner: Object) -> Dictionary:
	var unregistered: Dictionary = _source_roster.unregister_provider(provider_id, authority_owner)
	if unregistered.get("status") == "ready":
		_geometry_completion_providers.erase(provider_id)
		_wake_visible_section_demands()
	return unregistered


## Track a native terrain section that has entered the current mesh-block view.
## The queue stores demand identity and priority only; each attempt recaptures the
## full provider census before any whole-section candidate can be admitted.
func request_visible_section_demand(section_key: Vector3i, terrain_revision: int,
		camera_distance_squared: float) -> Dictionary:
	if terrain_revision <= 0 or not is_finite(camera_distance_squared) \
			or camera_distance_squared < 0.0:
		return _failed("invalid_visible_section_demand_identity")
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	var revision := str(terrain_revision)
	if state.is_empty():
		var has_installed_candidate := _production_candidates_by_section.has(section_key)
		state = {"terrainRevision":revision,
			"priority":0.0 if has_installed_candidate else camera_distance_squared,
			"stage":"waiting", "attempts":0,
			"nextAttemptFrame":Engine.get_process_frames(), "queued":false}
		if has_installed_candidate:
			state["urgentRecompile"] = true
		if _dirty_source_sections.has(section_key):
			state["sourceInvalidation"] = _dirty_source_sections[section_key].duplicate(true)
		_visible_section_demands[section_key] = state
		_enqueue_visible_section_demand(section_key, state)
	else:
		state["priority"] = camera_distance_squared
		if String(state.get("terrainRevision", "")) != revision:
			var revision_cancel := _cancel_pending_production_candidate(section_key)
			if revision_cancel.get("status") == "rollback_failed":
				state["stage"] = "rollback_failed"
				state["lastInstallStatus"] = "rollback_failed"
				state["lastInstallReason"] = String(revision_cancel.get("reason", ""))
				_visible_section_demands[section_key] = state
				return revision_cancel
			_pending_source_acknowledgements.erase(section_key)
			_erase_source_install_acknowledgement(section_key)
			state["terrainRevision"] = revision
			if _production_candidates_by_section.has(section_key):
				# A replacement for installed world content is latency-sensitive:
				# keep the old receipt live, but let its revision catch up before
				# spending the bounded capture lane on first-time distant sections.
				state["urgentRecompile"] = true
				state["priority"] = 0.0
			state["stage"] = "waiting"
			state["attempts"] = 0
			state["lastReason"] = ""
			state.erase("blockedReason")
			state.erase("continuationHint")
			state.erase("admissionGeneration")
			state["nextAttemptFrame"] = Engine.get_process_frames()
			state.erase("candidateGeneration")
			state.erase("installedGeneration")
			state.erase("installedReceipt")
			if not bool(state.get("queued", false)):
				_enqueue_visible_section_demand(section_key, state)
	_visible_section_demands[section_key] = state
	if _replay_reassembly_required_by_section.has(section_key):
		_promote_replay_reassembly_to_visible_demand(section_key)
		state = _visible_section_demands.get(section_key, state)
	_track_translucent_visible_section(section_key)
	return {"status":"queued" if state.get("stage") == "waiting" else "tracked",
		"sectionKey":section_key, "stage":String(state.get("stage", "waiting")),
		"terrainRevision":revision}


## A support lease admits the canonical geometry-owner section through the
## same complete provider census/candidate/native install lifecycle. Its exact
## terrain source revision remains a String and is never treated as a VoxelTools
## mesh-block serial.
func request_support_section_candidate(view_owner: String, snapshot: Dictionary,
		terrain_source_revision: String, camera_distance_squared: float) -> Dictionary:
	if view_owner.is_empty() or not snapshot.is_read_only() \
			or String(snapshot.get("schema", "")) != "visible-support-section-snapshot/v1" \
			or String(snapshot.get("worldId", "")) != _world_id \
			or not snapshot.get("supportSectionKey") is Vector3i \
			or terrain_source_revision.is_empty() \
			or not is_finite(camera_distance_squared) or camera_distance_squared < 0.0:
		return _failed("invalid_support_section_candidate_demand")
	var section_key: Vector3i = snapshot.supportSectionKey
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	var demands: Dictionary = state.get("supportDemands", {})
	var previous: Dictionary = demands.get(view_owner, {})
	var demand_identity := "%d:%d:%s:%s:%s" % [int(snapshot.requestId),
		int(snapshot.viewRevision), String(snapshot.sourceIndexRevision),
		String(snapshot.get("snapshotDigest", "")), terrain_source_revision]
	if not previous.is_empty() and String(previous.get("identity", "")) == demand_identity:
		previous["priority"] = camera_distance_squared
		demands[view_owner] = previous
		state["supportDemands"] = demands
		_visible_section_demands[section_key] = state
		return {"status":"tracked", "sectionKey":section_key,
			"identity":demand_identity, "stage":String(state.get("stage", "waiting"))}
	if not state.is_empty() and (state.has("candidateGeneration") \
			or _production_candidate_jobs.has(section_key)):
		var cancelled := _cancel_pending_production_candidate(section_key)
		if cancelled.get("status") == "rollback_failed":
			return cancelled
		state.erase("candidateGeneration")
	# Multiple active views may lease the same render section. Replacing one
	# view's certificate must not silently drop the other views' references.
	demands[view_owner] = {"identity":demand_identity,
		"snapshot":snapshot, "terrainSourceRevision":terrain_source_revision,
		"priority":camera_distance_squared}
	state["supportDemands"] = demands
	state["priority"] = minf(float(state.get("priority", INF)), camera_distance_squared)
	state["stage"] = "waiting"
	state["attempts"] = 0
	state["nextAttemptFrame"] = Engine.get_process_frames()
	state.erase("blockedReason")
	state.erase("continuationHint")
	state.erase("admissionGeneration")
	state.erase("installedGeneration")
	state.erase("installedReceipt")
	state.erase("lastReason")
	state.erase("urgentRecompile")
	if not bool(state.get("queued", false)):
		_enqueue_visible_section_demand(section_key, state)
	_visible_section_demands[section_key] = state
	return {"status":"queued", "sectionKey":section_key,
		"identity":demand_identity, "terrainSourceRevision":terrain_source_revision}


func release_support_section_demand(view_owner: String, section_key: Vector3i) -> Dictionary:
	if view_owner.is_empty() or not _visible_section_demands.has(section_key):
		return {"status":"idle", "sectionKey":section_key}
	var state: Dictionary = _visible_section_demands[section_key]
	var demands: Dictionary = state.get("supportDemands", {})
	if not demands.has(view_owner):
		return {"status":"idle", "sectionKey":section_key}
	var retained_demand: Dictionary = demands[view_owner]
	demands.erase(view_owner)
	state["supportDemands"] = demands
	if not demands.is_empty():
		_visible_section_demands[section_key] = state
		return {"status":"retained", "sectionKey":section_key,
			"remainingSupportDemandCount":demands.size()}
	if state.has("terrainRevision"):
		_visible_section_demands[section_key] = state
		return {"status":"retained_by_terrain_demand", "sectionKey":section_key}
	var cancelled := _cancel_pending_production_candidate(section_key)
	if cancelled.get("status") == "rollback_failed":
		demands[view_owner] = retained_demand
		state["supportDemands"] = demands
		_visible_section_demands[section_key] = state
		return cancelled
	_visible_section_demands.erase(section_key)
	_source_roster.release_section_capture_demand(section_key)
	_untrack_translucent_visible_section(section_key)
	return {"status":"released", "sectionKey":section_key}


func support_demand_section_keys(view_owner: String) -> Dictionary:
	var result: Dictionary = {}
	for section_value: Variant in _visible_section_demands:
		if section_value is Vector3i \
				and _visible_section_demands[section_value].get("supportDemands", {}).has(view_owner):
			result[section_value] = true
	return result


## Keep a static geometry owner's section resident while an installed,
## demanded section contains its validated support rows. Ownership may use a
## static center or a compound attachment anchor. This uses the supportDemands reference
## set and never adds gameplay chunk simulation demand.
func reconcile_ordinary_geometry_support_owner_demands() -> Dictionary:
	var reconciliation_started := Time.get_ticks_usec()
	var required: Dictionary = {}
	var pending_release_owners: Dictionary = {}
	var snapshot_scopes: Array[Dictionary] = []
	for reference: WeakRef in _geometry_completion_providers.values():
		var provider: Variant = reference.get_ref()
		if not is_instance_valid(provider) or not provider.has_method("begin_owner_expectation_snapshot"):
			continue
		if not provider.has_method("end_owner_expectation_snapshot"):
			_end_geometry_expectation_snapshots(snapshot_scopes)
			return {"status":"pending", "reason":"owner_expectation_snapshot_end_missing", "retryable":true}
		var scope: Dictionary = provider.begin_owner_expectation_snapshot(self)
		if scope.get("status") != "ready":
			_end_geometry_expectation_snapshots(snapshot_scopes)
			return {"status":"pending", "reason":"owner_expectation_snapshot_scope_unavailable",
				"retryable":true}
		snapshot_scopes.append({"provider":provider, "token":int(scope.token)})
	# First fetch still invokes each registered authority's currentness checks.
	# No values escape this call, and no install/release occurs during collection.
	var geometry_expectations: Dictionary = {}
	var prior_expectations: Dictionary = {}
	var section_expectations: Dictionary = {}
	var presentation_expectations: Dictionary = {}
	var lookup_diagnostics := {"geometryFetches":0, "geometryHits":0,
		"priorFetches":0, "priorHits":0, "presentationFetches":0,
		"presentationHits":0, "authorityLookupUsec":0,
		"presentationLookupSamples":[], "sectionSliceLookupSamples":[]}
	# Derived indexes live only for this synchronous reconciliation. Retain the
	# original claims; indexing must not replace their owner/revision authority.
	var claims_by_support: Dictionary = {}
	var presentation_claims_by_support: Dictionary = {}
	var waiting_owner_sections: Dictionary = {}
	for lease_id: String in _geometry_owner_lease_claims:
		var claim: Dictionary = _geometry_owner_lease_claims[lease_id]
		var support_key: Variant = claim.get("supportSectionKey")
		if not claims_by_support.has(support_key): claims_by_support[support_key] = {}
		claims_by_support[support_key][lease_id] = claim
		if claim.has("presentationRoster"):
			if not presentation_claims_by_support.has(support_key):
				presentation_claims_by_support[support_key] = {}
			var source_key: Variant = claim.get("sourceId")
			if not presentation_claims_by_support[support_key].has(source_key):
				presentation_claims_by_support[support_key][source_key] = {}
			presentation_claims_by_support[support_key][source_key][lease_id] = claim
	for support_section_value: Variant in _visible_section_demands:
		if not support_section_value is Vector3i:
			continue
		var support_section: Vector3i = support_section_value
		var support_state: Dictionary = _visible_section_demands.get(support_section, {})
		if not _has_independent_geometry_demand(support_state): continue
		var candidate: Dictionary = _production_candidates_by_section.get(support_section, {})
		var receipt: Dictionary = _production_candidate_receipts.get(support_section, {})
		if support_state.is_empty() or candidate.is_empty() or receipt.is_empty() \
				or not installed_section_receipt_is_current(support_section, receipt):
			# Keep the last exact owner leases during replacement/backpressure. The
			# originating demand, not another generated lease, owns their lifetime.
			_merge_retained_support_claims(required, support_section,
				claims_by_support.get(support_section, {}), _ordinary_geometry_owner_support_demands)
			continue
		var snapshot: Dictionary = candidate.get("candidate", {}).get("snapshot", {})
		var completion_rows: Array = snapshot.get("manifest", []).duplicate()
		# Empty replacement sections have no geometry manifest; their exact
		# admitted removals still own the previous geometry-owner lease closure.
		completion_rows.append_array(candidate.get("removalSourceIdentities", {}).values())
		for manifest_value: Variant in completion_rows:
			if not manifest_value is Dictionary:
				continue
			var manifest_row: Dictionary = manifest_value
			var source_id := String(manifest_row.get("sourceId", ""))
			var part_id := String(manifest_row.get("sourcePartId", ""))
			var revision := String(manifest_row.get("sourceRevision", ""))
			var expectation_key := var_to_str([source_id, part_id, revision])
			if not presentation_expectations.has(expectation_key):
				var lookup_started := Time.get_ticks_usec()
				var presentation_result := _registered_presentation_owner_expectation(
					source_id, part_id, revision)
				var lookup_elapsed := Time.get_ticks_usec() - lookup_started
				presentation_expectations[expectation_key] = presentation_result
				lookup_diagnostics.authorityLookupUsec += lookup_elapsed
				lookup_diagnostics.presentationFetches += 1
				var lookup_samples: Array = lookup_diagnostics.presentationLookupSamples
				if lookup_samples.size() < 16:
					lookup_samples.append({"sourceId":source_id.substr(0, 160),
						"partId":part_id.substr(0, 96), "section":support_section,
						"elapsedUsec":lookup_elapsed,
						"status":"ready" if not presentation_result.is_empty() else "unavailable"})
			else:
				lookup_diagnostics.presentationHits += 1
			var presentation_roster: Dictionary = presentation_expectations[expectation_key]
			var support_bounds := _section_world_bounds(support_section)
			if presentation_roster.is_empty():
				# An unavailable replacement source cannot release the old source's
				# residency while this exact independent support demand still exists.
				var retained_presentations: Dictionary = presentation_claims_by_support.get(
					support_section, {}).get(source_id, {})
				for lease_id: String in retained_presentations:
					var claim: Dictionary = retained_presentations[lease_id]
					var retained_owner: Vector3i = _ordinary_geometry_owner_support_demands[lease_id]
					if not required.has(retained_owner): required[retained_owner] = {}
					required[retained_owner][lease_id] = claim
				waiting_owner_sections[support_section] = true
			for member: Dictionary in presentation_roster.get("members", []) + presentation_roster.get("priorMembers", []):
				if not member.sweptWorldBounds.intersects(support_bounds): continue
				var member_owner: Vector3i = SectionGrid.key_for_world_position(member.neutralParentToWorld.origin)
				if member_owner == support_section: continue
				var lease_id := "presentation-owner:%s:%s:%s:%s:%s" % [_section_identity(support_section),
					source_id, String(presentation_roster.sourceRevision), String(member.presentationMemberId), _section_identity(member_owner)]
				if not required.has(member_owner): required[member_owner] = {}
				required[member_owner][lease_id] = {"supportSectionKey":support_section,
					"sourceId":source_id, "sourceRevision":presentation_roster.sourceRevision,
					"memberId":member.presentationMemberId, "presentationRoster":presentation_roster}
			var section_expectation_key := var_to_str([expectation_key, support_section])
			if not section_expectations.has(section_expectation_key):
				var section_lookup_started := Time.get_ticks_usec()
				var section_expectation_value := _registered_geometry_owner_section_expectation(
					source_id, part_id, revision, support_section)
				var section_lookup_elapsed := Time.get_ticks_usec() - section_lookup_started
				section_expectations[section_expectation_key] = section_expectation_value
				lookup_diagnostics.authorityLookupUsec += section_lookup_elapsed
				var section_samples: Array = lookup_diagnostics.sectionSliceLookupSamples
				if section_samples.size() < 16:
					var section_expectation_detail: Dictionary = section_expectation_value.get("expectation", {})
					section_samples.append({"sourceId":source_id.substr(0, 160),
						"section":support_section, "elapsedUsec":section_lookup_elapsed,
						"status":String(section_expectation_detail.get("status", "legacy")),
						"reason":String(section_expectation_detail.get("reason", ""))})
			var section_expectation: Dictionary = section_expectations[section_expectation_key]
			if section_expectation.get("mode") == "section_slice":
				var slice_result: Dictionary = section_expectation.get("expectation", {})
				var owner_slice: Dictionary = slice_result.get("slice", {})
				var parent_roster: Dictionary = slice_result.get("parentRoster", {})
				var prior_slices: Variant = slice_result.get("priorSlices", null)
				var slice_valid := _section_owner_slice_is_current(slice_result, parent_roster,
					owner_slice, prior_slices, source_id, part_id, support_section)
				if not slice_valid:
					# A scoped provider is authoritative. Never widen an unavailable
					# slice back to its complete parent roster.
					_merge_retained_support_claims(required, support_section,
						claims_by_support.get(support_section, {}), _ordinary_geometry_owner_support_demands)
					if slice_result.get("status") != "ready":
						waiting_owner_sections[support_section] = true
			else:
				if not geometry_expectations.has(expectation_key):
					var lookup_started := Time.get_ticks_usec()
					geometry_expectations[expectation_key] = _registered_geometry_owner_expectation(
						source_id, part_id, revision)
					lookup_diagnostics.authorityLookupUsec += Time.get_ticks_usec() - lookup_started
					lookup_diagnostics.geometryFetches += 1
				else:
					lookup_diagnostics.geometryHits += 1
				var full_roster: Dictionary = geometry_expectations[expectation_key]
				if not full_roster.is_empty():
					var current_owners := GeometryOwnerCompletion.owner_sections(full_roster)
					if not prior_expectations.has(expectation_key):
						var lookup_started := Time.get_ticks_usec()
						prior_expectations[expectation_key] = _registered_geometry_owner_prior_expectations(full_roster)
						lookup_diagnostics.authorityLookupUsec += Time.get_ticks_usec() - lookup_started
						lookup_diagnostics.priorFetches += 1
					else:
						lookup_diagnostics.priorHits += 1
					for previous: Dictionary in prior_expectations[expectation_key]:
						for old_owner: Vector3i in GeometryOwnerCompletion.owner_sections(previous):
							if old_owner == support_section or old_owner in current_owners: continue
							var old_lease_id := "building-owner-removal:%s:%s:%s:%s" % [
								_section_identity(support_section), source_id, full_roster.digest, _section_identity(old_owner)]
							if not required.has(old_owner): required[old_owner] = {}
							required[old_owner][old_lease_id] = {"supportSectionKey":support_section,
								"sourceId":source_id, "sourceRevision":full_roster.sourceRevision,
								"memberId":"departed:" + _section_identity(old_owner),
								"geometryRemoval":full_roster.sourcePartId}
					for member: Dictionary in full_roster.members:
						var member_owner: Vector3i = member.geometryOwnerSection
						if member_owner == support_section: continue
						var member_key := GeometryOwnerCompletion.member_key(member)
						var lease_id := "building-owner-roster:%s:%s:%s:%s" % [
							_section_identity(support_section), source_id, full_roster.digest, member_key]
						if not required.has(member_owner): required[member_owner] = {}
						required[member_owner][lease_id] = {"supportSectionKey":support_section,
							"sourceId":source_id, "sourceRevision":member.sourceRevision,
							"memberId":member_key, "geometryMember":member}
			for support_value: Variant in manifest_row.get("supportRanges", []):
				if not support_value is Dictionary:
					continue
				var support: Dictionary = support_value
				var exact_claim := _exact_support_range_owner_claim(support, support_section, source_id)
				if exact_claim.is_empty(): continue
				var owner_section: Vector3i = exact_claim.ownerSection
				var lease_id := String(exact_claim.leaseId)
				var by_owner: Dictionary = required.get(owner_section, {})
				by_owner[lease_id] = exact_claim.claim
				required[owner_section] = by_owner
	# End before release or native proof/admission work can mutate ownership.
	if not _end_geometry_expectation_snapshots(snapshot_scopes):
		return {"status":"pending", "reason":"owner_expectation_snapshot_release_failed", "retryable":true}
	var released := 0
	for lease_id_value: Variant in _ordinary_geometry_owner_support_demands:
		var lease_id := String(lease_id_value)
		var owner_section: Vector3i = _ordinary_geometry_owner_support_demands[lease_id]
		if required.get(owner_section, {}).has(lease_id):
			continue
		var outcome := release_support_section_demand(lease_id, owner_section)
		if outcome.get("status") in ["released", "retained_by_terrain_demand", "retained", "idle"]:
			released += 1
			_ordinary_geometry_owner_support_demands.erase(lease_id)
			_geometry_owner_lease_claims.erase(lease_id)
		else:
			# Rollback/backpressure must retain both retry intent and residency.
			pending_release_owners[owner_section] = true
	var owner_cells: Dictionary = {}
	var owner_sections: Dictionary = {}
	for pending_owner: Vector3i in pending_release_owners:
		owner_sections[pending_owner] = true
		owner_cells[SectionGrid.chunk_key_for_section(pending_owner)] = true
	var retained := 0
	# All release operations above are finished before proof reuse begins. This
	# loop does not yield or install/retire native packets. Require exact roster
	# equality, including prior members, and discard every result on return.
	var presentation_proofs: Dictionary = {}
	for owner_value: Variant in required:
		var owner_section: Vector3i = owner_value
		var leases: Dictionary = required[owner_section]
		var geometry_proofs := _installed_static_geometry_proofs(owner_section)
		var owner_geometry_ready := true
		for lease: Dictionary in leases.values():
			var support: Dictionary = lease.get("geometryMember", lease.get("supportRange", {}))
			var proof: Dictionary = geometry_proofs.get(_static_geometry_proof_key(support), {})
			var matches: bool = support == proof if lease.has("geometryMember") else _static_geometry_support_matches_proof(support, proof)
			if lease.has("presentationRoster"):
				var roster: Dictionary = lease.presentationRoster
				var proof_key := var_to_str([roster.worldId, roster.sourceId,
					roster.sourcePartId, roster.sourceRevision, owner_section])
				var retained_proof: Dictionary = presentation_proofs.get(proof_key, {})
				if retained_proof.is_empty() or retained_proof.roster != roster:
					retained_proof = {"roster":roster,
						"ready":_presentation_owner_section_is_current(owner_section, roster)}
					presentation_proofs[proof_key] = retained_proof
				matches = bool(retained_proof.ready)
			if lease.has("geometryRemoval"):
				matches = _geometry_owner_departure_is_installed(owner_section, String(lease.sourceId),
					String(lease.geometryRemoval), String(lease.sourceRevision))
			if not matches:
				owner_geometry_ready = false
				waiting_owner_sections[owner_section] = true
		var state: Dictionary = _visible_section_demands.get(owner_section, {})
		if state.is_empty():
			state = {"priority":0.0, "stage":"waiting", "attempts":0,
				"nextAttemptFrame":Engine.get_process_frames(), "queued":false}
		var demands: Dictionary = state.get("supportDemands", {})
		var added_demand := false
		for lease_id_value: Variant in leases:
			var lease_id := String(lease_id_value)
			if not demands.has(lease_id):
				demands[lease_id] = {"kind":"ordinary_geometry_support",
					"identity":lease_id,
					"sourceSectionKey":leases[lease_id].supportSectionKey,
					"sourceId":leases[lease_id].sourceId,
					"sourceRevision":leases[lease_id].sourceRevision,
					"memberId":leases[lease_id].memberId,
					"terrainSourceRevision":""}
				added_demand = true
			_ordinary_geometry_owner_support_demands[lease_id] = owner_section
			_geometry_owner_lease_claims[lease_id] = leases[lease_id]
			retained += 1
		state["supportDemands"] = demands
		state["terrainDemandWithdrawn"] = not state.has("terrainRevision")
		if added_demand:
			var existing_receipt: Dictionary = _production_candidate_receipts.get(
				owner_section, {})
			if not existing_receipt.is_empty() \
					and installed_section_receipt_is_current(owner_section, existing_receipt) \
					and owner_geometry_ready:
				state["stage"] = "installed"
				state["installedGeneration"] = int(existing_receipt.get("generation", 0))
				state["queued"] = false
			else:
				state["priority"] = 0.0
				state["stage"] = "waiting"
				state["nextAttemptFrame"] = Engine.get_process_frames()
				state.erase("blockedReason")
				state.erase("continuationHint")
				if not bool(state.get("queued", false)):
					_enqueue_visible_section_demand(owner_section, state)
		_visible_section_demands[owner_section] = state
		owner_sections[owner_section] = true
		owner_cells[SectionGrid.chunk_key_for_section(owner_section)] = true
	return {"status":"ready" if waiting_owner_sections.is_empty() and pending_release_owners.is_empty() else "pending",
		"ownerCells":owner_cells, "waitingOwnerSections":waiting_owner_sections,
		"pendingReleaseOwnerCount":pending_release_owners.size(),
		"ownerSections":owner_sections, "retainedDemandCount":retained,
		"releasedDemandCount":released,
		"reconciliationDiagnostics":{"lookups":lookup_diagnostics,
			"elapsedUsec":Time.get_ticks_usec() - reconciliation_started}}


func _end_geometry_expectation_snapshots(scopes: Array[Dictionary]) -> bool:
	var released := true
	for scope: Dictionary in scopes:
		var provider: Variant = scope.provider
		if not is_instance_valid(provider):
			released = false
			continue
		var outcome: Dictionary = provider.end_owner_expectation_snapshot(self, int(scope.token))
		released = outcome.get("status") == "released" and released
	return released


static func _static_geometry_proof_key(value: Dictionary) -> String:
	return var_to_str([String(value.get("sourceId", "")),
		String(value.get("sourcePartId", value.get("sourceId", ""))),
		String(value.get("sourceRevision", "")), String(value.get("sourceSegmentId", "")),
		int(value.get("sourceInstance", -1))])


static func _section_world_bounds(section: Vector3i) -> AABB:
	return AABB(SectionGrid.origin_for_key(section), Vector3.ONE * SectionGrid.SECTION_SIZE_METERS)


static func _section_owner_slice_is_current(result: Dictionary, parent_roster: Dictionary,
		owner_slice: Dictionary, prior_slices: Variant, source_id: String, part_id: String,
		section: Vector3i) -> bool:
	if result.get("status") != "ready" or not GeometryOwnerSectionSlice.validate_cached_slice_for_parent(
			parent_roster, owner_slice) or owner_slice.get("ownerSection") != section \
			or not prior_slices is Array or not prior_slices.is_read_only():
		return false
	if not _section_slice_remote_owner_sections(owner_slice, section).is_empty(): return false
	for prior_slice_value: Variant in prior_slices:
		if not prior_slice_value is Dictionary or not prior_slice_value.is_read_only() \
				or prior_slice_value.get("schema") != GeometryOwnerSectionSlice.SCHEMA \
				or prior_slice_value.get("ownerSection") != section \
				or prior_slice_value.get("sourceId") != source_id \
				or prior_slice_value.get("sourcePartId") != part_id:
			return false
	return true


static func _section_slice_remote_owner_sections(owner_slice: Dictionary,
		section: Vector3i) -> Dictionary:
	var owners: Dictionary = {}
	if owner_slice.get("ownerSection") != section:
		owners["invalid"] = true
		return owners
	for member: Dictionary in owner_slice.get("members", []):
		var owner_value: Variant = member.get("geometryOwnerSection", null)
		if not owner_value is Vector3i or owner_value != section:
			owners["invalid"] = true
			return owners
	return owners


static func _exact_support_range_owner_claim(support: Dictionary,
		support_section: Vector3i, source_id: String) -> Dictionary:
	var owner_value: Variant = support.get("geometryOwnerSection", null)
	var member_id := String(support.get("memberId", ""))
	var source_revision := String(support.get("sourceRevision", ""))
	var segment_id := String(support.get("sourceSegmentId", ""))
	if String(support.get("ownershipPolicy", "")) not in [
			"ordinary_center_geometry_owner/aabb_support_sections_v1",
			"citadel_center_geometry_owner/aabb_support_sections_v1",
			"compound_anchor_geometry_owner/swept_support_sections_v1"] \
			or support.get("supportSectionKey", null) != support_section \
			or not owner_value is Vector3i or owner_value == support_section \
			or source_id.is_empty() or member_id.is_empty() \
			or source_revision.is_empty() or segment_id.is_empty():
		return {}
	var lease_id := "ordinary-render-support:%s:%s:%s:%s" % [
		_section_identity(support_section), source_id, member_id, source_revision]
	return {"ownerSection":owner_value, "leaseId":lease_id,
		"claim":{"supportSectionKey":support_section,
			"sourceId":source_id, "sourceRevision":source_revision,
			"memberId":member_id, "sourceSegmentId":segment_id,
			"supportRange":support}}


static func _merge_retained_support_claims(required: Dictionary, support_section: Vector3i,
		claims: Dictionary, owner_by_lease: Dictionary) -> void:
	for lease_id: String in claims:
		if not owner_by_lease.has(lease_id) \
				or claims[lease_id].get("supportSectionKey") != support_section: continue
		var owner_section: Vector3i = owner_by_lease[lease_id]
		if not required.has(owner_section): required[owner_section] = {}
		required[owner_section][lease_id] = claims[lease_id]


func _presentation_owner_section_is_current(section: Vector3i, roster: Dictionary) -> bool:
	if roster.get("worldId") != _world_id or not roster.get("members") is Array:
		return false
	var source_id := String(roster.get("sourceId", ""))
	var part_id := String(roster.get("sourcePartId", ""))
	var revision := String(roster.get("sourceRevision", ""))
	if source_id.is_empty() or part_id.is_empty() or revision.is_empty(): return false
	var receipt: Dictionary = _production_candidate_receipts.get(section, {})
	if not installed_section_receipt_is_current(section, receipt): return false
	var identity := SourceRoster._source_part_identity_key(source_id, part_id)
	if receipt.get("sourceRevisions", {}).get(identity) != revision \
			and receipt.get("removalRevisions", {}).get(identity) != revision:
		return false
	var contract = preload("res://scripts/world/StaticSectionPresentationMembers.gd")
	var expected: Dictionary = {}
	for member: Variant in roster.members:
		if contract.validate(member, source_id, part_id, revision).get("status") != "ready":
			return false
		if SectionGrid.key_for_world_position(member.neutralParentToWorld.origin) != section:
			continue
		var member_id := String(member.presentationMemberId)
		if expected.has(member_id): return false
		expected[member_id] = member
	var actual: Dictionary = {}
	for member: Variant in _production_candidates_by_section.get(section, {}).get(
			"candidate", {}).get("snapshot", {}).get("presentationMembers", []):
		if member.get("sourceId") != source_id or member.get("sourcePartId") != part_id:
			continue
		var member_id := String(member.get("presentationMemberId", ""))
		if member_id.is_empty() or actual.has(member_id): return false
		actual[member_id] = member
	return actual == expected


func _installed_static_geometry_proofs(section: Vector3i) -> Dictionary:
	var receipt: Dictionary = _production_candidate_receipts.get(section, {})
	if receipt.is_empty() or not installed_section_receipt_is_current(section, receipt):
		return {}
	var candidate: Dictionary = _production_candidates_by_section.get(section, {})
	var proofs: Dictionary = {}
	for member: Dictionary in candidate.get("candidate", {}).get("snapshot", {}).get("manifest", []):
		for range_value: Dictionary in member.get("geometrySourceRanges", []):
			if range_value.get("sourceId") != member.get("sourceId") \
					or range_value.get("sourcePartId") != member.get("sourcePartId") \
					or range_value.get("sourceRevision") != member.get("sourceRevision") \
					or range_value.get("geometryOwnerSection") != section:
				return {}
			var key := _static_geometry_proof_key(range_value)
			if proofs.has(key):
				return {}
			proofs[key] = range_value
	return proofs


static func _has_independent_geometry_demand(state: Dictionary) -> bool:
	if state.has("terrainRevision"): return true
	for demand: Dictionary in state.get("supportDemands", {}).values():
		if demand.get("kind") != "ordinary_geometry_support": return true
	return false


func _registered_presentation_owner_expectation(source_id: String, part_id: String, revision: String) -> Dictionary:
	var result: Dictionary = {}
	var contract = preload("res://scripts/world/StaticSectionPresentationMembers.gd")
	for reference: WeakRef in _geometry_completion_providers.values():
		var provider: Object = reference.get_ref()
		if not is_instance_valid(provider) or not provider.has_method("presentation_owner_expectation"): continue
		var roster: Dictionary = provider.call("presentation_owner_expectation", source_id, part_id, revision)
		if roster.is_empty(): continue
		if not result.is_empty() or not roster.is_read_only() or roster.get("worldId") != _world_id \
				or roster.get("sourceId") != source_id or roster.get("sourcePartId") != part_id \
				or roster.get("sourceRevision") != revision: return {}
		for member: Variant in roster.get("members", []):
			if contract.validate(member, source_id, part_id, revision).get("status") != "ready": return {}
		for member: Variant in roster.get("priorMembers", []):
			if not member is Dictionary or contract.validate(member, source_id, part_id,
					String(member.get("sourceRevision", ""))).get("status") != "ready": return {}
		result = roster
	return result

func _registered_geometry_owner_expectation(source_id: String, part_id: String, revision: String) -> Dictionary:
	var result: Dictionary = {}
	for reference: WeakRef in _geometry_completion_providers.values():
		var provider: Object = reference.get_ref()
		if not is_instance_valid(provider) or not provider.has_method("geometry_owner_expectation"): continue
		var roster: Dictionary = provider.call("geometry_owner_expectation", source_id, part_id, revision)
		if roster.is_empty(): continue
		if not result.is_empty() or not GeometryOwnerCompletion.validate(roster) \
				or roster.worldId != _world_id or roster.sourceId != source_id \
				or roster.sourcePartId != part_id or roster.sourceRevision != revision: return {}
		result = roster
	return result


func _registered_geometry_owner_section_expectation(source_id: String, part_id: String,
		revision: String, section_key: Vector3i) -> Dictionary:
	var result: Dictionary = {}
	for provider_id_value: Variant in _geometry_completion_providers:
		var provider_id := String(provider_id_value)
		var reference: WeakRef = _geometry_completion_providers[provider_id_value]
		var provider: Object = reference.get_ref()
		if not is_instance_valid(provider) or not provider.has_method("geometry_owner_section_expectation"):
			continue
		var expectation: Dictionary = provider.call("geometry_owner_section_expectation",
			source_id, part_id, revision, section_key)
		if expectation.is_empty():
			# The registered blueprint provider owns these static building sources.
			# Once it advertises the scoped API, unavailable means pending, never a
			# reason to fall back to its full source roster.
			if provider_id == "blueprint_buildings":
				return {"mode":"section_slice", "expectation":{"status":"pending"}}
			continue
		if not result.is_empty(): return {"mode":"section_slice", "expectation":{}}
		result = expectation
	if not result.is_empty():
		return {"mode":"section_slice", "expectation":result}
	return {"mode":"legacy_roster", "expectation":{}}


func _registered_geometry_owner_prior_expectations(roster: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for reference: WeakRef in _geometry_completion_providers.values():
		var provider: Object = reference.get_ref()
		if not is_instance_valid(provider) or not provider.has_method("geometry_owner_prior_expectations"): continue
		var values: Array = provider.call("geometry_owner_prior_expectations", roster.sourceId,
			roster.sourcePartId, roster.sourceRevision)
		for value: Variant in values:
			if value is Dictionary and GeometryOwnerCompletion.validate(value) \
					and value.worldId == roster.worldId and value.sourceId == roster.sourceId \
					and value.sourcePartId == roster.sourcePartId: result.append(value)
	return result


func _geometry_owner_departure_is_installed(section: Vector3i, source_id: String, part_id: String, revision: String) -> bool:
	var receipt: Dictionary = _production_candidate_receipts.get(section, {})
	if not installed_section_receipt_is_current(section, receipt): return false
	var identity := SourceRoster._source_part_identity_key(source_id, part_id)
	if receipt.get("sourceRevisions", {}).get(identity) != revision \
			and receipt.get("removalRevisions", {}).get(identity) != revision: return false
	for member: Dictionary in _production_candidates_by_section.get(section, {}).get("candidate", {}).get("snapshot", {}).get("manifest", []):
		if member.get("sourceId") == source_id and member.get("sourcePartId") == part_id \
				and not member.get("geometrySourceRanges", []).is_empty(): return false
	return true


## Full producer expectation versus actual current native geometry. Provider ACK
## is deliberately not a prerequisite: it is the consumer of this proof.
func validate_geometry_owner_completion(roster: Dictionary, prior_rosters: Array = []) -> Dictionary:
	if not GeometryOwnerCompletion.validate(roster) or roster.worldId != _world_id:
		return {"status":"pending", "reason":"geometry_owner_roster_world_or_digest_invalid"}
	var source_id: String = roster.sourceId
	var part_id: String = roster.sourcePartId
	var expected_owners := GeometryOwnerCompletion.owner_sections(roster)
	var required: Dictionary = {}
	for section: Vector3i in expected_owners: required[section] = true
	for previous: Variant in prior_rosters:
		if not previous is Dictionary or not GeometryOwnerCompletion.validate(previous) \
				or previous.worldId != _world_id or previous.sourceId != source_id \
				or previous.sourcePartId != part_id:
			return {"status":"pending", "reason":"geometry_owner_prior_roster_invalid"}
		for section: Vector3i in GeometryOwnerCompletion.owner_sections(previous): required[section] = true
	# Include every already installed geometry owner for this part. Support-only
	# rows are not geometry and do not expand the completion closure.
	for section: Vector3i in _visible_sections_by_source_id.get(source_id, {}):
		var candidate: Dictionary = _production_candidates_by_section.get(section, {})
		for entry: Dictionary in candidate.get("candidate", {}).get("snapshot", {}).get("manifest", []):
			if entry.get("sourceId") == source_id and entry.get("sourcePartId") == part_id \
					and not entry.get("geometrySourceRanges", []).is_empty():
				required[section] = true
	var installed: Array[Dictionary] = []
	var receipts: Array[Dictionary] = []
	var identity_key := SourceRoster._source_part_identity_key(source_id, part_id)
	for section: Vector3i in required:
		var receipt: Dictionary = _production_candidate_receipts.get(section, {})
		if not installed_section_receipt_is_current(section, receipt):
			return {"status":"pending", "reason":"geometry_owner_native_receipt_missing_or_stale",
				"sectionKey":section, "retryable":true}
		var source_revision := String(receipt.get("sourceRevisions", {}).get(identity_key, ""))
		var removal_revision := String(receipt.get("removalRevisions", {}).get(identity_key, ""))
		if source_revision != roster.sourceRevision and removal_revision != roster.sourceRevision:
			return {"status":"pending", "reason":"geometry_owner_current_revision_claim_missing",
				"sectionKey":section, "retryable":true}
		var candidate: Dictionary = _production_candidates_by_section.get(section, {})
		var section_member_count := 0
		for entry: Dictionary in candidate.get("candidate", {}).get("snapshot", {}).get("manifest", []):
			if entry.get("sourceId") != source_id or entry.get("sourcePartId") != part_id: continue
			for member: Dictionary in entry.get("geometrySourceRanges", []):
				if member.get("geometryOwnerSection") != section:
					return {"status":"pending", "reason":"geometry_owner_installed_section_mismatch"}
				installed.append(member)
				section_member_count += 1
		if section not in expected_owners and section_member_count != 0:
			return {"status":"pending", "reason":"geometry_owner_departed_owner_still_has_geometry"}
		receipts.append(receipt)
	var result := GeometryOwnerCompletion.compare_installed_members(roster, installed)
	if result.get("status") != "ready": return result
	# Guard the native owner incarnations again after collecting the whole union.
	for receipt: Dictionary in receipts:
		if not installed_section_receipt_is_current(receipt.sectionKey, receipt):
			return {"status":"pending", "reason":"geometry_owner_native_receipt_changed_during_proof"}
	result["ownerSections"] = expected_owners
	result["receiptCount"] = receipts.size()
	return result


func _geometry_owner_prior_identity_tokens(prior_rosters: Array) -> Array[String]:
	var tokens: Array[String] = []
	for prior: Dictionary in prior_rosters:
		tokens.append(var_to_str([prior.get("worldId", ""),
			prior.get("sourceId", ""), prior.get("sourcePartId", ""),
			prior.get("sourceRevision", ""), prior.get("sourceIncarnation", ""),
			prior.get("digest", "")]))
	tokens.make_read_only()
	return tokens


func _geometry_owner_completion_key(roster: Dictionary,
		prior_rosters: Array) -> String:
	return var_to_str([roster.get("worldId", ""), roster.get("sourceId", ""),
		roster.get("sourcePartId", ""), roster.get("sourceRevision", ""),
		roster.get("sourceIncarnation", ""), roster.get("digest", ""),
		_geometry_owner_prior_identity_tokens(prior_rosters)])


func _geometry_owner_completion_cached_receipts_are_current(
		session: Dictionary) -> bool:
	if String(session.get("stage", "")) != "complete":
		return false
	for section_value: Variant in session.get("requiredSectionKeys", []):
		if not section_value is Vector3i:
			return false
		var section: Vector3i = section_value
		var token: Dictionary = session.get("sectionTokens", {}).get(section, {})
		if token.is_empty() \
				or not is_same(_production_candidates_by_section.get(section, {}),
					token.get("candidate")) \
				or not is_same(_production_candidate_receipts.get(section, {}),
					token.get("receipt")):
			return false
		# The provider performs authoritative native receipt liveness checks before
		# using a ready completion token. This cache check only invalidates changed
		# candidate/receipt identities and publication epochs; re-walking every
		# backend slot here would put a synchronous O(section-count) sweep back on
		# every ready proof poll.
	return true


func _geometry_owner_first_stale_section(session: Dictionary) -> Variant:
	for section_value: Variant in session.get("requiredSectionKeys", []):
		if not section_value is Vector3i:
			return section_value
		var section: Vector3i = section_value
		var token: Dictionary = session.get("sectionTokens", {}).get(section, {})
		if token.is_empty() \
				or not is_same(_production_candidates_by_section.get(section, {}),
					token.get("candidate")) \
				or not is_same(_production_candidate_receipts.get(section, {}),
					token.get("receipt")):
			return section
	return null


## Admit an exact producer-sealed owner proof for background preparation. This
## records immutable input identity only; it does not advance cursors or make an
## ACK/retirement decision. The provider must revalidate its owner and receipt
## authority before using a ready result.
func request_geometry_owner_completion(roster: Dictionary,
		prior_rosters: Array = []) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not _geometry_owner_roster_session_input_valid(roster, prior_rosters):
		return {"status":"pending", "reason":"geometry_owner_roster_or_prior_invalid",
			"retryable":true, "workItems":0,
			"elapsedUsec":Time.get_ticks_usec() - started}
	var session_key := _geometry_owner_completion_key(roster, prior_rosters)
	var source_id := String(roster.get("sourceId", ""))
	var prior_identities := _geometry_owner_prior_identity_tokens(prior_rosters)
	var session: Dictionary = _geometry_owner_completion_sessions.get(session_key, {})
	if not session.is_empty():
		if session.get("priorIdentities") == prior_identities \
				and not _geometry_owner_prior_roster_objects_match(
					session.get("priorRosters", []), prior_rosters):
			return {"status":"pending",
				"reason":"geometry_owner_prior_roster_object_replaced_same_identity",
				"retryable":false, "workItems":prior_rosters.size(),
				"totalWorkItems":prior_rosters.size(),
				"elapsedUsec":Time.get_ticks_usec() - started}
		if not is_same(session.get("roster"), roster):
			session = {}
		elif String(session.get("stage", "")) == "complete":
			var cached_receipts_current := \
				_geometry_owner_completion_cached_receipts_are_current(session)
			if cached_receipts_current:
				var ready: Dictionary = session.get("result", {}).duplicate(false)
				ready["schedulerCached"] = true
				ready["workItems"] = 0
				ready["totalWorkItems"] = 0
				ready["cursorWorkItems"] = 0
				ready["identityWorkItems"] = 0
				ready["elapsedUsec"] = Time.get_ticks_usec() - started
				return ready
			if not cached_receipts_current:
				var stale_section: Variant = _geometry_owner_first_stale_section(session)
				if stale_section is Vector3i:
					_invalidate_geometry_owner_section_observation(session, stale_section)
	if session_key.is_empty():
		return {"status":"pending", "reason":"geometry_owner_completion_identity_invalid",
			"retryable":false, "workItems":0,
			"elapsedUsec":Time.get_ticks_usec() - started}
	var prior_snapshot: Array = prior_rosters.duplicate(false)
	prior_snapshot.make_read_only()
	var prior_request: Dictionary = _geometry_owner_completion_requests.get(session_key, {})
	if not prior_request.is_empty() \
			and prior_request.get("priorIdentities") == prior_identities \
			and not _geometry_owner_prior_roster_objects_match(
				prior_request.get("priorRosters", []), prior_rosters):
		return {"status":"pending",
			"reason":"geometry_owner_prior_roster_object_replaced_same_identity",
			"retryable":false, "workItems":prior_rosters.size(),
			"totalWorkItems":prior_rosters.size(),
			"elapsedUsec":Time.get_ticks_usec() - started}
	var previous_request_key := String(
		_geometry_owner_completion_request_key_by_source.get(source_id, ""))
	if not previous_request_key.is_empty() and previous_request_key != session_key:
		_geometry_owner_completion_requests.erase(previous_request_key)
	if _geometry_owner_completion_requests.has(session_key):
		var retained: Dictionary = _geometry_owner_completion_requests[session_key]
		if not is_same(retained.get("roster"), roster):
			retained["roster"] = roster
			retained["priorRosters"] = prior_snapshot
			retained["priorIdentities"] = prior_identities
			_geometry_owner_completion_requests[session_key] = retained
	else:
		if _geometry_owner_completion_requests.size() >= \
				MAX_PENDING_GEOMETRY_OWNER_COMPLETION_REQUESTS:
			return {"status":"pending", "reason":"geometry_owner_completion_queue_full",
				"retryable":true, "workItems":0,
				"elapsedUsec":Time.get_ticks_usec() - started}
		_geometry_owner_completion_requests[session_key] = {
			"sourceId":source_id, "roster":roster,
			"priorRosters":prior_snapshot, "priorIdentities":prior_identities}
		_geometry_owner_completion_request_queue.append(session_key)
	_geometry_owner_completion_request_key_by_source[source_id] = session_key
	return {"status":"pending", "reason":"geometry_owner_completion_queued",
		"retryable":true, "workItems":0, "totalWorkItems":0,
		"sessionKey":session_key,
		"queueDepth":_geometry_owner_completion_requests.size(),
		"elapsedUsec":Time.get_ticks_usec() - started}


## Fairly advances retained proof requests from the regular coordinator turn.
## max_work_items caps cursor units; immutable prior identity headers are checked
## on every worker call and are separately reported. Each worker call remains
## individually capped by advance_geometry_owner_completion's 1ms maximum.
func advance_pending_geometry_owner_completions(max_owner_attempts: int,
		max_work_items: int, budget_usec: int) -> Dictionary:
	if max_owner_attempts < 1 \
			or max_owner_attempts > MAX_GEOMETRY_OWNER_COMPLETION_ATTEMPTS_PER_ADVANCE \
			or max_work_items < 1 \
			or max_work_items > MAX_GEOMETRY_OWNER_COMPLETION_CURSOR_WORK_PER_ADVANCE \
			or budget_usec < 1 \
			or budget_usec > MAX_GEOMETRY_OWNER_COMPLETION_BUDGET_USEC_PER_ADVANCE:
		return {"status":"failed", "reason":"invalid_geometry_owner_scheduler_budget",
			"attemptCount":0, "cursorWorkItems":0,
			"identityWorkItems":0, "elapsedUsec":0}
	var started := Time.get_ticks_usec()
	var attempts := 0
	var cursor_work := 0
	var identity_work := 0
	# Visit each request that was queued at entry at most once. Requeued work
	# waits for the next coordinator turn, preserving round-robin fairness even
	# when one owner is the only pending source or is waiting on a receipt.
	var attempt_limit := mini(max_owner_attempts,
		_geometry_owner_completion_request_queue.size())
	var outcomes: Array[Dictionary] = []
	while attempts < attempt_limit and cursor_work < max_work_items \
			and not _geometry_owner_completion_request_queue.is_empty() \
			and Time.get_ticks_usec() - started < budget_usec:
		var request_key: String = _geometry_owner_completion_request_queue.pop_front()
		var request: Dictionary = _geometry_owner_completion_requests.get(request_key, {})
		if request.is_empty():
			continue
		var source_id := String(request.get("sourceId", ""))
		if String(_geometry_owner_completion_request_key_by_source.get(source_id, "")) \
				!= request_key:
			_geometry_owner_completion_requests.erase(request_key)
			continue
		var remaining_usec := maxi(1, budget_usec - (Time.get_ticks_usec() - started))
		var allowed_cursor_work := mini(8, max_work_items - cursor_work)
		var outcome := advance_geometry_owner_completion(
			request.get("roster", {}), request.get("priorRosters", []),
			allowed_cursor_work, mini(1000, remaining_usec))
		attempts += 1
		cursor_work += int(outcome.get("cursorWorkItems", 0))
		identity_work += int(outcome.get("identityWorkItems", 0))
		var row := {"sessionKey":request_key, "sourceId":source_id,
			"status":String(outcome.get("status", "pending")),
			"reason":String(outcome.get("reason", "")),
			"stage":String(outcome.get("stage", "")),
			"cursor":int(outcome.get("cursor", 0)),
			"total":int(outcome.get("total", 0)),
			"cursorWorkItems":int(outcome.get("cursorWorkItems", 0)),
			"identityWorkItems":int(outcome.get("identityWorkItems", 0)),
			"elapsedUsec":int(outcome.get("elapsedUsec", 0))}
		row.make_read_only()
		outcomes.append(row)
		if outcome.get("status") == "ready" or not bool(outcome.get("retryable", true)):
			_geometry_owner_completion_requests.erase(request_key)
			if String(_geometry_owner_completion_request_key_by_source.get(source_id, "")) \
					== request_key:
				_geometry_owner_completion_request_key_by_source.erase(source_id)
		elif _geometry_owner_completion_requests.has(request_key):
			_geometry_owner_completion_request_queue.append(request_key)
	outcomes.make_read_only()
	return {"status":"advanced" if attempts > 0 else "idle",
		"attemptCount":attempts, "cursorWorkItems":cursor_work,
		"identityWorkItems":identity_work,
		"pendingRequestCount":_geometry_owner_completion_requests.size(),
		"elapsedUsec":Time.get_ticks_usec() - started,
		"outcomes":outcomes}


## Incremental version of the full owner proof. It walks immutable producer
## members and installed section manifests across calls. Candidate/receipt
## replacement invalidates only that section's captured proof; every required
## section is fenced by exact candidate and receipt identity before readiness.
func advance_geometry_owner_completion(roster: Dictionary,
		prior_rosters: Array = [], max_work_items := 2,
		budget_usec := 250) -> Dictionary:
	var started := Time.get_ticks_usec()
	_geometry_owner_completion_active_key = ""
	if max_work_items < 1 or max_work_items > 8 or budget_usec < 1 \
			or budget_usec > 1000 or prior_rosters.size() > 64:
		return {"status":"failed", "reason":"invalid_geometry_owner_completion_slice"}
	if not _geometry_owner_roster_session_input_valid(roster, prior_rosters):
		return {"status":"pending", "reason":"geometry_owner_roster_or_prior_invalid",
			"retryable":true, "workItems":0,
			"elapsedUsec":Time.get_ticks_usec() - started}
	# Citadel commonly constructs a fresh mutable Array for this bounded roster
	# set on every retry. Bind the continuation to immutable producer identities,
	# not the transient wrapper's object identity.
	var prior_identities := _geometry_owner_prior_identity_tokens(prior_rosters)
	var session_key := _geometry_owner_completion_key(roster, prior_rosters)
	var source_id := String(roster.get("sourceId", ""))
	var previous_session_key := String(_geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var owner_input_changed := false
	if not previous_session_key.is_empty() and previous_session_key != session_key:
		_geometry_owner_completion_sessions.erase(previous_session_key)
		owner_input_changed = true
	_geometry_owner_completion_session_key_by_source[source_id] = session_key
	var visible_section_snapshot: Array = _visible_section_keys_by_source_id.get(source_id, [])
	if not _visible_section_keys_by_source_id.has(source_id):
		visible_section_snapshot = []
		visible_section_snapshot.make_read_only()
	if not visible_section_snapshot.is_read_only():
		return {"status":"pending", "reason":"geometry_owner_visible_section_index_unsealed",
			"retryable":true, "workItems":0,
			"elapsedUsec":Time.get_ticks_usec() - started}
	var session: Dictionary = _geometry_owner_completion_sessions.get(session_key, {})
	var dependency_revision := int(_geometry_owner_dependency_revision_by_source.get(source_id, 0))
	var membership_revision := int(_geometry_owner_visible_membership_revision_by_source.get(source_id, 0))
	if not session.is_empty() and session.get("priorIdentities") == prior_identities \
			and not _geometry_owner_prior_roster_objects_match(
				session.get("priorRosters", []), prior_rosters):
		return {"status":"pending",
			"reason":"geometry_owner_prior_roster_object_replaced_same_identity",
			"retryable":false, "workItems":prior_rosters.size(),
			"totalWorkItems":prior_rosters.size(),
			"identityWorkItems":prior_rosters.size(), "cursorWorkItems":0,
			"elapsedUsec":Time.get_ticks_usec() - started,
			"closureResetCount":int(session.get("closureResetCount", 0))}
	if not session.is_empty() and (not is_same(session.get("roster"), roster) \
			or session.get("priorIdentities") != prior_identities):
		_geometry_owner_completion_sessions.erase(session_key)
		session = {}
		owner_input_changed = true
	if session.is_empty():
		# Admission trusts the producer's existing sealed digest as an opaque
		# identity token. Recomputing it uses Godot's whole-Variant serializer and
		# cannot be sliced without changing the public digest semantics. The
		# producer seal is the trust boundary; each member is validated below as
		# it is consumed, and reuse requires this exact roster object and digest.
		if not GeometryOwnerCompletion.incremental_header_is_valid(roster, _world_id):
			return {"status":"pending", "reason":"geometry_owner_roster_header_invalid",
				"retryable":false, "workItems":0,
				"elapsedUsec":Time.get_ticks_usec() - started}
		var reset_count := int(_geometry_owner_completion_reset_count_by_key.get(session_key, 0))
		if owner_input_changed:
			reset_count += 1
			_geometry_owner_completion_reset_count_by_key[session_key] = reset_count
		var frozen_prior := prior_rosters.duplicate(false)
		frozen_prior.make_read_only()
		session = {"roster":roster, "priorRosters":frozen_prior,
			"priorIdentities":prior_identities, "priorDigests":prior_identities,
			"dependencyRevision":dependency_revision,
			"membershipRevision":membership_revision,
			"stage":"expected_members", "memberCursor":0, "priorCursor":0,
			"rosterValidationPreviousMemberKey":"",
			"rosterValidationRowsProcessed":0,
			"priorValidationPreviousMemberKey":"", "priorValidationRowsProcessed":0,
			"digestUnitsProcessed":0, "rosterDigestAdmissionPending":true,
		"visibleCursor":0, "sectionCursor":0, "manifestCursor":0,
		"memberRangeCursor":0,
		"compareSectionCursor":0, "compareMemberCursor":0,
		"expectedMembers":{}, "installedMembers":{},
		"expectedMemberKeys":[], "expectedMemberKeysBySection":{},
		"installedMemberKeysBySection":{}, "sectionScanned":{},
		"sectionCompared":{}, "finalReceiptValidated":{},
			"finalReceiptCursor":0,
			"requiredSections":{}, "requiredSectionKeys":[],
			"ownerRequiredSections":{}, "ownerRequiredSectionKeys":[],
			"ownerClosureCursor":0, "sectionTokens":{},
			"sectionReceipts":{},
			"visibleSections":visible_section_snapshot,
			"workItems":0, "maxElapsedUsec":0, "resetCount":reset_count,
			"ownerInputResetCount":reset_count, "closureResetCount":0,
			"lastResetReason":"owner_input_changed" if owner_input_changed else "initial"}
		_geometry_owner_completion_sessions[session_key] = session
	else:
		# Publication changes are reconciled per section when a candidate is
		# accepted. Keep the current global counters for diagnostics only; they
		# must not restart unrelated section manifest/receipt proof work.
		session.dependencyRevision = dependency_revision
		session.membershipRevision = membership_revision
	# Each of at most 64 prior identity/header checks is included in workItems.
	# max_work_items controls cursor work after this small fixed admission bound.
	var prior_identity_units := prior_rosters.size()
	var used := prior_identity_units
	session.digestUnitsProcessed = int(session.get("digestUnitsProcessed", 0)) + prior_identity_units
	session.lastCallIdentityWorkItems = prior_identity_units
	var completed_sections := 0
	_geometry_owner_completion_active_key = session_key
	while used < prior_identity_units + max_work_items and Time.get_ticks_usec() - started < budget_usec:
		if bool(session.get("rosterDigestAdmissionPending", false)):
			# One producer-sealed digest identity is admitted as an opaque token.
			# Re-serializing the roster here would violate both the slice bound and
			# the established digest format; producer sealing remains authoritative.
			session.rosterDigestAdmissionPending = false
			session.digestUnitsProcessed = int(session.digestUnitsProcessed) + 1
			session.lastCallIdentityWorkItems = int(session.lastCallIdentityWorkItems) + 1
			used += 1
			continue
		match String(session.get("stage", "")):
			"expected_members":
				var members: Array = roster.members
				var cursor := int(session.memberCursor)
				if cursor >= members.size():
					session.stage = "prior_sections"
					continue
				var row: Variant = members[cursor]
				if not row is Dictionary or not GeometryOwnerCompletion.valid_member(row) \
						or row.get("sourceId") != roster.get("sourceId") \
						or row.get("sourcePartId") != roster.get("sourcePartId") \
						or row.get("sourceRevision") != roster.get("sourceRevision"):
					return _geometry_owner_completion_pending("geometry_owner_roster_member_invalid",
						used, completed_sections, started, false)
				var member_key := GeometryOwnerCompletion.member_key(row)
				if member_key.is_empty() or member_key <= String(session.rosterValidationPreviousMemberKey):
					return _geometry_owner_completion_pending("geometry_owner_roster_member_order_or_duplicate",
						used, completed_sections, started, false)
				session.rosterValidationPreviousMemberKey = member_key
				session.expectedMembers[member_key] = row
				session.expectedMemberKeys.append(member_key)
				var expected_keys_by_section: Dictionary = session.get(
					"expectedMemberKeysBySection", {})
				var section_member_keys: Array = expected_keys_by_section.get(
					row.geometryOwnerSection, [])
				section_member_keys.append(member_key)
				expected_keys_by_section[row.geometryOwnerSection] = section_member_keys
				session.expectedMemberKeysBySection = expected_keys_by_section
				_add_geometry_owner_section_requirement(session, row.geometryOwnerSection)
				session.memberCursor = cursor + 1
				session.rosterValidationRowsProcessed = int(session.rosterValidationRowsProcessed) + 1
				used += 1
			"prior_sections":
				var prior_index := int(session.priorCursor)
				var captured_prior_rosters: Array = session.get("priorRosters", [])
				if prior_index >= captured_prior_rosters.size():
					session.stage = "visible_sections"
					continue
				var prior: Dictionary = captured_prior_rosters[prior_index]
				var prior_members: Array = prior.members
				var prior_cursor := int(session.get("priorMemberCursor", 0))
				if prior_cursor >= prior_members.size():
					session.priorCursor = prior_index + 1
					session.priorMemberCursor = 0
					session.priorValidationPreviousMemberKey = ""
					used += 1
					continue
				var prior_row: Variant = prior_members[prior_cursor]
				if not prior_row is Dictionary or not GeometryOwnerCompletion.valid_member(prior_row) \
						or prior_row.get("sourceId") != roster.get("sourceId") \
						or prior_row.get("sourcePartId") != roster.get("sourcePartId") \
						or prior_row.get("sourceRevision") != prior.get("sourceRevision"):
					return _geometry_owner_completion_pending("geometry_owner_prior_member_invalid",
						used, completed_sections, started, false)
				var prior_member_key := GeometryOwnerCompletion.member_key(prior_row)
				if prior_member_key.is_empty() or prior_member_key <= String(session.priorValidationPreviousMemberKey):
					return _geometry_owner_completion_pending("geometry_owner_prior_member_order_or_duplicate",
						used, completed_sections, started, false)
				session.priorValidationPreviousMemberKey = prior_member_key
				_add_geometry_owner_section_requirement(session, prior_row.geometryOwnerSection)
				session.priorMemberCursor = prior_cursor + 1
				session.priorValidationRowsProcessed = int(session.priorValidationRowsProcessed) + 1
				used += 1
			"visible_sections":
				var visible: Array = session.visibleSections
				var visible_cursor := int(session.visibleCursor)
				if visible_cursor >= visible.size():
					session.stage = "section_manifests"
					continue
				var section_value: Variant = visible[visible_cursor]
				if section_value is Vector3i:
					_add_geometry_owner_required_section(session, section_value)
				session.visibleCursor = visible_cursor + 1
				used += 1
			"owner_closure":
				var owner_sections: Array = session.get("ownerRequiredSectionKeys", [])
				var owner_cursor := int(session.get("ownerClosureCursor", 0))
				if owner_cursor >= owner_sections.size():
					session.stage = "visible_sections"
					continue
				_add_geometry_owner_required_section(session, owner_sections[owner_cursor])
				session.ownerClosureCursor = owner_cursor + 1
				used += 1
			"section_manifests":
				var keys: Array = session.requiredSectionKeys
				var section_cursor := int(session.sectionCursor)
				if section_cursor >= keys.size():
					session.stage = "compare_members"
					continue
				var section: Vector3i = keys[section_cursor]
				if bool(session.get("sectionScanned", {}).get(section, false)):
					session.sectionCursor = section_cursor + 1
					used += 1
					continue
				var token: Dictionary = session.sectionTokens.get(section, {})
				if token.is_empty():
					var candidate: Dictionary = _production_candidates_by_section.get(section, {})
					var receipt: Dictionary = _production_candidate_receipts.get(section, {})
					if candidate.is_empty() or receipt.is_empty():
						return _geometry_owner_completion_pending("geometry_owner_native_receipt_missing_or_stale",
							used, completed_sections, started, true, section)
					token = {"candidate":candidate, "receipt":receipt}
					session.sectionTokens[section] = token
					session.sectionReceipts[section] = receipt
					used += 1
					continue
				if not bool(token.get("receiptValidated", false)):
					if not installed_section_receipt_is_current(section, token.receipt):
						_invalidate_geometry_owner_section_observation(session, section)
						return _geometry_owner_completion_pending("geometry_owner_native_receipt_missing_or_stale",
							used, completed_sections, started, true, section)
					token.receiptValidated = true
					session.sectionTokens[section] = token
					used += 1
					continue
				var current_receipt: Dictionary = token.receipt
				if not is_same(_production_candidates_by_section.get(section, {}),
						token.get("candidate")) \
						or not is_same(_production_candidate_receipts.get(section, {}),
							token.get("receipt")):
					_invalidate_geometry_owner_section_observation(session, section)
					continue
				var identity_key := SourceRoster._source_part_identity_key(
					String(roster.sourceId), String(roster.sourcePartId))
				if String(current_receipt.get("sourceRevisions", {}).get(identity_key, "")) \
						!= String(roster.sourceRevision) \
						and String(current_receipt.get("removalRevisions", {}).get(identity_key, "")) \
						!= String(roster.sourceRevision):
					return _geometry_owner_completion_pending("geometry_owner_current_revision_claim_missing",
						used, completed_sections, started, true, section)
				var manifest: Array = token.candidate.get("candidate", {}).get("snapshot", {}).get("manifest", [])
				var manifest_cursor := int(session.manifestCursor)
				if manifest_cursor >= manifest.size():
					var scanned: Dictionary = session.get("sectionScanned", {})
					scanned[section] = true
					session.sectionScanned = scanned
					session.sectionCursor = section_cursor + 1
					session.manifestCursor = 0
					completed_sections += 1
					used += 1
					continue
				var entry: Variant = manifest[manifest_cursor]
				if entry is Dictionary and entry.get("sourceId") == roster.sourceId \
						and entry.get("sourcePartId") == roster.sourcePartId:
					var ranges: Array = entry.get("geometrySourceRanges", [])
					var range_cursor := int(session.memberRangeCursor)
					if range_cursor < ranges.size():
						var member_value: Variant = ranges[range_cursor]
						if not member_value is Dictionary:
							return _geometry_owner_completion_pending("geometry_owner_installed_member_invalid",
								used, completed_sections, started, false, section)
						if member_value.get("geometryOwnerSection") != section:
							return _geometry_owner_completion_pending("geometry_owner_installed_section_mismatch",
								used, completed_sections, started, false, section)
						var key := GeometryOwnerCompletion.member_key(member_value)
						if session.installedMembers.has(key):
							return _geometry_owner_completion_pending("geometry_owner_duplicate_installed_member",
								used, completed_sections, started, false, section)
						session.installedMembers[key] = member_value
						var section_member_keys: Dictionary = session.get(
							"installedMemberKeysBySection", {})
						var member_keys: Array = section_member_keys.get(section, [])
						member_keys.append(key)
						section_member_keys[section] = member_keys
						session.installedMemberKeysBySection = section_member_keys
						session.memberRangeCursor = range_cursor + 1
						used += 1
						continue
					session.memberRangeCursor = 0
				session.manifestCursor = manifest_cursor + 1
				used += 1
				continue
			"compare_members":
				var sections: Array = session.requiredSectionKeys
				var compare_section_cursor := int(session.get("compareSectionCursor", 0))
				if compare_section_cursor >= sections.size():
					session.stage = "final_receipts"
					continue
				var compare_section: Vector3i = sections[compare_section_cursor]
				if bool(session.get("sectionCompared", {}).get(compare_section, false)):
					session.compareSectionCursor = compare_section_cursor + 1
					used += 1
					continue
				var expected_by_section: Dictionary = session.get(
					"expectedMemberKeysBySection", {})
				var expected_keys: Array = expected_by_section.get(compare_section, [])
				var compare_cursor := int(session.get("compareMemberCursor", 0))
				if compare_cursor >= expected_keys.size():
					var installed_by_section: Dictionary = session.get(
						"installedMemberKeysBySection", {})
					if installed_by_section.get(compare_section, []).size() != expected_keys.size():
						return _geometry_owner_completion_pending("geometry_owner_installed_member_count_mismatch",
							used, completed_sections, started, true, compare_section)
					var compared: Dictionary = session.get("sectionCompared", {})
					compared[compare_section] = true
					session.sectionCompared = compared
					session.compareSectionCursor = compare_section_cursor + 1
					session.compareMemberCursor = 0
					used += 1
					continue
				var key := String(expected_keys[compare_cursor])
				if not session.installedMembers.has(key) \
						or session.installedMembers[key] != session.expectedMembers[key]:
					return _geometry_owner_completion_pending("geometry_owner_installed_member_mismatch",
						used, completed_sections, started, true, compare_section)
				session.compareMemberCursor = compare_cursor + 1
				used += 1
			"final_receipts":
				var sections: Array = session.requiredSectionKeys
				var receipt_cursor := int(session.finalReceiptCursor)
				if receipt_cursor < sections.size() and bool(
						session.get("finalReceiptValidated", {}).get(
							sections[receipt_cursor], false)):
					session.finalReceiptCursor = receipt_cursor + 1
					used += 1
					continue
				if receipt_cursor >= sections.size():
					session.requiredSectionKeys.make_read_only()
					session.sectionReceipts.make_read_only()
					var result := {"status":"ready", "memberCount":session.expectedMembers.size(),
						"ownerSections":session.requiredSectionKeys,
						"receiptsBySection":session.sectionReceipts,
						"receiptCount":session.sectionTokens.size(), "sessionKey":session_key,
						"dependencyRevision":session.dependencyRevision,
						"membershipRevision":session.membershipRevision}
					session.result = result
					session.stage = "complete"
					session.workItems = int(session.get("workItems", 0)) + used
					session.maxElapsedUsec = maxi(int(session.get("maxElapsedUsec", 0)),
						Time.get_ticks_usec() - started)
					var completed_result := _geometry_owner_completion_result(result, session, used,
						completed_sections, started)
					return completed_result
				var final_section: Vector3i = sections[receipt_cursor]
				var final_token: Dictionary = session.sectionTokens.get(final_section, {})
				if final_token.is_empty() \
						or not is_same(_production_candidates_by_section.get(final_section, {}), final_token.get("candidate")) \
						or not is_same(_production_candidate_receipts.get(final_section, {}), final_token.get("receipt")) \
						or not installed_section_receipt_is_current(final_section, final_token.get("receipt", {})):
					_invalidate_geometry_owner_section_observation(session, final_section)
					continue
				var validated_receipts: Dictionary = session.get("finalReceiptValidated", {})
				validated_receipts[final_section] = true
				session.finalReceiptValidated = validated_receipts
				session.finalReceiptCursor = receipt_cursor + 1
				used += 1
			"complete":
				if not _geometry_owner_completion_cached_receipts_are_current(session):
					var stale_section: Variant = _geometry_owner_first_stale_section(session)
					if stale_section is Vector3i:
						_invalidate_geometry_owner_section_observation(session, stale_section)
						continue
					return _geometry_owner_completion_pending(
						"geometry_owner_completed_section_identity_invalid",
						used, completed_sections, started, false)
				return _geometry_owner_completion_result(session.result, session, used,
					completed_sections, started)
			_:
				return _geometry_owner_completion_pending("geometry_owner_completion_session_invalid",
					used, completed_sections, started, false)
	session.workItems = int(session.get("workItems", 0)) + used
	session.maxElapsedUsec = maxi(int(session.get("maxElapsedUsec", 0)),
		Time.get_ticks_usec() - started)
	return _geometry_owner_completion_pending("geometry_owner_completion_slice_pending",
		used, completed_sections, started, true)


func _geometry_owner_roster_session_input_valid(roster: Dictionary,
		prior_rosters: Array) -> bool:
	# A fresh caller-owned prior Array is allowed, but every entry must be a
	# producer-sealed immutable roster. This scan is bounded to 64 headers; member
	# validation remains cursor-based in the session below.
	if not GeometryOwnerCompletion.incremental_header_is_valid(roster, _world_id) \
			or prior_rosters.size() > 64:
		return false
	for prior_value: Variant in prior_rosters:
		if not prior_value is Dictionary \
				or not GeometryOwnerCompletion.incremental_header_is_valid(prior_value, _world_id) \
				or prior_value.get("sourceId") != roster.get("sourceId") \
				or prior_value.get("sourcePartId") != roster.get("sourcePartId"):
			return false
	return true


func _geometry_owner_prior_roster_objects_match(captured: Array,
		current: Array) -> bool:
	if captured.size() != current.size(): return false
	for index in range(captured.size()):
		if not is_same(captured[index], current[index]): return false
	return true


func _add_geometry_owner_required_section(session: Dictionary, section: Vector3i) -> void:
	var required_sections: Dictionary = session.get("requiredSections", {})
	var required_keys: Array = session.get("requiredSectionKeys", [])
	if required_sections.has(section): return
	if required_sections.is_read_only(): required_sections = required_sections.duplicate()
	if required_keys.is_read_only(): required_keys = required_keys.duplicate()
	required_sections[section] = true
	required_keys.append(section)
	session.requiredSections = required_sections
	session.requiredSectionKeys = required_keys


func _add_geometry_owner_section_requirement(session: Dictionary, section: Vector3i) -> void:
	if not session.ownerRequiredSections.has(section):
		var owner_sections: Dictionary = session.get("ownerRequiredSections", {})
		var owner_keys: Array = session.get("ownerRequiredSectionKeys", [])
		if owner_sections.is_read_only(): owner_sections = owner_sections.duplicate()
		if owner_keys.is_read_only(): owner_keys = owner_keys.duplicate()
		owner_sections[section] = true
		owner_keys.append(section)
		session.ownerRequiredSections = owner_sections
		session.ownerRequiredSectionKeys = owner_keys
	_add_geometry_owner_required_section(session, section)


func _invalidate_geometry_owner_section_observation(session: Dictionary,
		section: Vector3i) -> void:
	# A replacement receipt invalidates only the manifest slice captured from
	# this section. Other section tokens and their completed cursors remain valid.
	_add_geometry_owner_required_section(session, section)
	var tokens: Dictionary = session.get("sectionTokens", {})
	var receipts: Dictionary = session.get("sectionReceipts", {})
	var scanned: Dictionary = session.get("sectionScanned", {})
	var compared: Dictionary = session.get("sectionCompared", {})
	var final_receipts: Dictionary = session.get("finalReceiptValidated", {})
	if tokens.is_read_only(): tokens = tokens.duplicate()
	if receipts.is_read_only(): receipts = receipts.duplicate()
	if scanned.is_read_only(): scanned = scanned.duplicate()
	if compared.is_read_only(): compared = compared.duplicate()
	if final_receipts.is_read_only(): final_receipts = final_receipts.duplicate()
	tokens.erase(section)
	receipts.erase(section)
	scanned.erase(section)
	compared.erase(section)
	final_receipts.erase(section)
	session.sectionTokens = tokens
	session.sectionReceipts = receipts
	session.sectionScanned = scanned
	session.sectionCompared = compared
	session.finalReceiptValidated = final_receipts
	var installed_by_section: Dictionary = session.get("installedMemberKeysBySection", {})
	var installed_member_keys: Array = installed_by_section.get(section, [])
	for key_value: Variant in installed_member_keys:
		session.installedMembers.erase(String(key_value))
	installed_by_section.erase(section)
	session.installedMemberKeysBySection = installed_by_section
	var index := int(session.get("requiredSectionKeys", []).find(section))
	if index < 0: return
	var stage := String(session.get("stage", ""))
	if stage in ["compare_members", "final_receipts", "complete"]:
		session.stage = "section_manifests"
		session.sectionCursor = mini(int(session.get("sectionCursor", 0)), index)
		session.manifestCursor = 0
		session.memberRangeCursor = 0
		session.compareSectionCursor = mini(
			int(session.get("compareSectionCursor", 0)), index)
		session.compareMemberCursor = 0
		session.finalReceiptCursor = mini(int(session.get("finalReceiptCursor", 0)), index)
	elif stage == "section_manifests" and index <= int(session.get("sectionCursor", 0)):
		# The current section may already have partially consumed its old manifest.
		# Rewind that slice too, or the replacement candidate would resume at an
		# offset from the previous receipt and silently omit its leading members.
		session.sectionCursor = index
		session.manifestCursor = 0
		session.memberRangeCursor = 0
		session.compareSectionCursor = mini(
			int(session.get("compareSectionCursor", 0)), index)
		session.compareMemberCursor = 0
	session.erase("result")


func _notify_geometry_owner_candidate_changed(section_key: Vector3i,
		previous: Dictionary, replacement: Dictionary) -> void:
	var affected_sources: Dictionary = {}
	for source_id: String in _section_candidate_source_revisions(previous):
		affected_sources[source_id] = true
	for source_id: String in _section_candidate_source_revisions(replacement):
		affected_sources[source_id] = true
	for source_id: String in affected_sources:
		var session_key := String(
			_geometry_owner_completion_session_key_by_source.get(source_id, ""))
		if session_key.is_empty(): continue
		var session: Dictionary = _geometry_owner_completion_sessions.get(session_key, {})
		if session.is_empty(): continue
		_add_geometry_owner_required_section(session, section_key)
		_invalidate_geometry_owner_section_observation(session, section_key)
		session.dependencyRevision = int(
			_geometry_owner_dependency_revision_by_source.get(source_id, 0))
		session.membershipRevision = int(
			_geometry_owner_visible_membership_revision_by_source.get(source_id, 0))


func _advance_geometry_owner_dependency_revision_for_candidate(candidate: Dictionary) -> void:
	var prepared: Variant = candidate.get("candidate", {})
	var snapshot: Variant = prepared.get("snapshot", {}) if prepared is Dictionary else {}
	var manifest: Variant = snapshot.get("manifest", []) if snapshot is Dictionary else []
	if not manifest is Array: return
	var seen: Dictionary = {}
	for row_value: Variant in manifest:
		if not row_value is Dictionary: continue
		var source_id := String(row_value.get("sourceId", ""))
		if source_id.is_empty() or seen.has(source_id): continue
		seen[source_id] = true
		_geometry_owner_dependency_revision_by_source[source_id] = \
			int(_geometry_owner_dependency_revision_by_source.get(source_id, 0)) + 1


func _advance_geometry_owner_visible_membership_revision(source_id: String) -> void:
	_geometry_owner_visible_membership_revision_by_source[source_id] = \
		int(_geometry_owner_visible_membership_revision_by_source.get(source_id, 0)) + 1


func _geometry_owner_completion_pending(reason: String, used: int,
		completed_sections: int, started: int, retryable: bool,
		section: Variant = null) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":retryable,
		"workItems":used, "totalWorkItems":used,
		"identityWorkItems":0, "cursorWorkItems":0,
		"completedSections":completed_sections,
		"elapsedUsec":Time.get_ticks_usec() - started,
		"stage":"unavailable", "cursor":0, "total":0, "cumulativeWork":0,
		"resetCount":0, "ownerInputResetCount":0, "resetReason":"",
		"closureResetCount":0, "validationRowsProcessed":0, "digestUnitsProcessed":0}
	var session: Dictionary = _geometry_owner_completion_sessions.get(
		_geometry_owner_completion_active_key, {})
	if not session.is_empty():
		result.identityWorkItems = int(session.get("lastCallIdentityWorkItems", 0))
		result.cursorWorkItems = maxi(0, used - int(result.identityWorkItems))
		var stage := String(session.get("stage", "unknown"))
		result.stage = stage
		match stage:
			"expected_members":
				result.cursor = int(session.get("memberCursor", 0))
				result.total = session.get("roster", {}).get("members", []).size()
			"prior_sections":
				var prior_cursor := int(session.get("priorCursor", 0))
				var prior_values: Array = session.get("priorRosters", [])
				if prior_cursor < prior_values.size():
					result.cursor = int(session.get("priorMemberCursor", 0))
					result.total = prior_values[prior_cursor].get("members", []).size()
				else:
					result.cursor = prior_cursor
					result.total = prior_values.size()
			"visible_sections":
				result.cursor = int(session.get("visibleCursor", 0))
				result.total = session.get("visibleSections", []).size()
			"owner_closure":
				result.cursor = int(session.get("ownerClosureCursor", 0))
				result.total = session.get("ownerRequiredSectionKeys", []).size()
			"section_manifests":
				var section_cursor := int(session.get("sectionCursor", 0))
				var section_values: Array = session.get("requiredSectionKeys", [])
				if section_cursor < section_values.size():
					var section_key: Vector3i = section_values[section_cursor]
					var section_token: Dictionary = session.get("sectionTokens", {}).get(section_key, {})
					var section_manifest: Array = section_token.get("candidate", {}).get(
						"candidate", {}).get("snapshot", {}).get("manifest", [])
					result.cursor = int(session.get("manifestCursor", 0))
					result.total = section_manifest.size()
				else:
					result.cursor = section_cursor
					result.total = section_values.size()
			"compare_members":
				result.cursor = int(session.get("compareSectionCursor", 0))
				result.total = session.get("requiredSectionKeys", []).size()
			"final_receipts":
				result.cursor = int(session.get("finalReceiptCursor", 0))
				result.total = session.get("requiredSectionKeys", []).size()
		result.cumulativeWork = int(session.get("workItems", 0)) + used
		result.resetCount = int(session.get("resetCount", 0))
		result.ownerInputResetCount = int(session.get("ownerInputResetCount", 0))
		result.resetReason = String(session.get("lastResetReason", ""))
		result.closureResetCount = int(session.get("closureResetCount", 0))
		result.validationRowsProcessed = int(session.get("rosterValidationRowsProcessed", 0)) \
			+ int(session.get("priorValidationRowsProcessed", 0))
		result.digestUnitsProcessed = int(session.get("digestUnitsProcessed", 0))
	if section is Vector3i: result.sectionKey = section
	return result


func _geometry_owner_completion_result(result: Dictionary, session: Dictionary,
		used: int, completed_sections: int, started: int) -> Dictionary:
	var output := result.duplicate(false)
	output["workItems"] = used
	output["totalWorkItems"] = used
	output["identityWorkItems"] = int(session.get("lastCallIdentityWorkItems", 0))
	output["cursorWorkItems"] = maxi(0, used - int(output["identityWorkItems"]))
	output["completedSections"] = completed_sections
	output["elapsedUsec"] = Time.get_ticks_usec() - started
	output["stage"] = String(session.get("stage", "unknown"))
	output["cursor"] = int(session.get("finalReceiptCursor", 0))
	output["total"] = int(session.get("requiredSectionKeys", []).size())
	output["cumulativeWork"] = int(session.get("workItems", 0))
	output["resetCount"] = int(session.get("resetCount", 0))
	output["ownerInputResetCount"] = int(session.get("ownerInputResetCount", 0))
	output["resetReason"] = String(session.get("lastResetReason", ""))
	output["closureResetCount"] = int(session.get("closureResetCount", 0))
	output["validationRowsProcessed"] = int(session.get("rosterValidationRowsProcessed", 0)) \
		+ int(session.get("priorValidationRowsProcessed", 0))
	output["digestUnitsProcessed"] = int(session.get("digestUnitsProcessed", 0))
	output["sessionTotalWorkItems"] = int(session.get("workItems", 0))
	output["sessionMaxElapsedUsec"] = maxi(int(session.get("maxElapsedUsec", 0)),
		Time.get_ticks_usec() - started)
	return output


func _geometry_owner_completion_session_status(session: Dictionary) -> Dictionary:
	var stage := String(session.get("stage", "unknown"))
	var cursor := 0
	var total := 0
	match stage:
		"expected_members":
			cursor = int(session.get("memberCursor", 0))
			total = session.get("roster", {}).get("members", []).size()
		"prior_sections":
			var prior_cursor := int(session.get("priorCursor", 0))
			var prior_values: Array = session.get("priorRosters", [])
			if prior_cursor < prior_values.size():
				cursor = int(session.get("priorMemberCursor", 0))
				total = prior_values[prior_cursor].get("members", []).size()
			else:
				cursor = prior_cursor
				total = prior_values.size()
		"visible_sections":
			cursor = int(session.get("visibleCursor", 0))
			total = session.get("visibleSections", []).size()
		"owner_closure":
			cursor = int(session.get("ownerClosureCursor", 0))
			total = session.get("ownerRequiredSectionKeys", []).size()
		"section_manifests":
			var section_cursor := int(session.get("sectionCursor", 0))
			var section_values: Array = session.get("requiredSectionKeys", [])
			if section_cursor < section_values.size():
				var section_key: Vector3i = section_values[section_cursor]
				var section_token: Dictionary = session.get("sectionTokens", {}).get(section_key, {})
				var section_manifest: Array = section_token.get("candidate", {}).get(
					"candidate", {}).get("snapshot", {}).get("manifest", [])
				cursor = int(session.get("manifestCursor", 0))
				total = section_manifest.size()
			else:
				cursor = section_cursor
				total = section_values.size()
		"compare_members":
			cursor = int(session.get("compareSectionCursor", 0))
			total = session.get("requiredSectionKeys", []).size()
		"final_receipts":
			cursor = int(session.get("finalReceiptCursor", 0))
			total = session.get("requiredSectionKeys", []).size()
	return {"sourceId":String(session.get("roster", {}).get("sourceId", "")),
		"stage":stage, "cursor":cursor, "total":total,
		"cumulativeWork":int(session.get("workItems", 0)),
		"digestUnitsProcessed":int(session.get("digestUnitsProcessed", 0)),
		"resetCount":int(session.get("resetCount", 0)),
		"ownerInputResetCount":int(session.get("ownerInputResetCount", 0)),
		"closureResetCount":int(session.get("closureResetCount", 0)),
		"resetReason":String(session.get("lastResetReason", "")),
		"dependencyRevision":int(session.get("dependencyRevision", -1)),
		"membershipRevision":int(session.get("membershipRevision", -1))}


func _geometry_owner_completion_sessions_status() -> Dictionary:
	var active_count := 0
	var sample: Array[Dictionary] = []
	for session_value: Variant in _geometry_owner_completion_sessions.values():
		if not session_value is Dictionary or String(session_value.get("stage", "")) == "complete":
			continue
		active_count += 1
		if sample.size() < 4:
			sample.append(_geometry_owner_completion_session_status(session_value))
	sample.make_read_only()
	return {"total":_geometry_owner_completion_sessions.size(),
		"active":active_count, "sampleLimit":4, "sample":sample}


## Receipt liveness is shared across many source-part completions during one
## synchronous provider ACK. Reuse only within that explicit no-yield scope;
## the installed candidate and immutable receipt identities must still match.
func begin_geometry_owner_receipt_validation_scope(owner: Object) -> Dictionary:
	if not is_instance_valid(owner) or _geometry_owner_receipt_scope_token != 0:
		return {"status":"failed", "reason":"geometry_owner_receipt_scope_busy"}
	_geometry_owner_receipt_scope_serial += 1
	_geometry_owner_receipt_scope_token = _geometry_owner_receipt_scope_serial
	_geometry_owner_receipt_scope_owner = weakref(owner)
	_geometry_owner_receipt_scope_generation = _generation
	_geometry_owner_receipt_scope_cache.clear()
	_geometry_owner_receipt_scope_liveness_checks = 0
	_geometry_owner_receipt_scope_cache_hits = 0
	return {"status":"ready", "token":_geometry_owner_receipt_scope_token}


func end_geometry_owner_receipt_validation_scope(owner: Object, token: int) -> Dictionary:
	if token == 0 or token != _geometry_owner_receipt_scope_token \
			or _geometry_owner_receipt_scope_owner == null \
			or _geometry_owner_receipt_scope_owner.get_ref() != owner:
		return {"status":"failed", "reason":"geometry_owner_receipt_scope_mismatch"}
	_geometry_owner_receipt_scope_token = 0
	_geometry_owner_receipt_scope_owner = null
	_geometry_owner_receipt_scope_generation = -1
	var result := {"status":"released",
		"livenessChecks":_geometry_owner_receipt_scope_liveness_checks,
		"cacheHits":_geometry_owner_receipt_scope_cache_hits}
	_geometry_owner_receipt_scope_cache.clear()
	return result


static func _static_geometry_support_matches_proof(support: Dictionary, proof: Dictionary) -> bool:
	return not proof.is_empty() and _static_geometry_proof_key(support) == _static_geometry_proof_key(proof) \
		and proof.get("geometryOwnerSection") == support.get("geometryOwnerSection") \
		and String(proof.get("meshContentDigest", "")) == String(support.get("meshContentDigest", "")) \
		and proof.get("worldBounds") is AABB and support.get("worldBounds") is AABB \
		and (proof.worldBounds as AABB).is_equal_approx(support.worldBounds)


static func _section_identity(section_key: Vector3i) -> String:
	return "%d,%d,%d" % [section_key.x, section_key.y, section_key.z]


func support_section_demand_matches(view_owner: String, snapshot: Dictionary) -> bool:
	if view_owner.is_empty() or not snapshot.get("supportSectionKey") is Vector3i:
		return false
	var state: Dictionary = _visible_section_demands.get(snapshot.supportSectionKey, {})
	var demand: Dictionary = state.get("supportDemands", {}).get(view_owner, {})
	var prior: Dictionary = demand.get("snapshot", {})
	return not bool(demand.get("needsTerrainRevisionRefresh", false)) \
		and not prior.is_empty() \
		and int(prior.get("requestId", 0)) == int(snapshot.get("requestId", -1)) \
		and int(prior.get("viewRevision", 0)) == int(snapshot.get("viewRevision", -1)) \
		and String(prior.get("snapshotDigest", "")) == String(snapshot.get("snapshotDigest", ""))


func support_section_receipt_matches(snapshot: Dictionary) -> Dictionary:
	if not snapshot.is_read_only() or snapshot.get("supportSectionKey") is not Vector3i \
			or not snapshot.get("coverageCertificate") is Dictionary:
		return {"status":"pending", "reason":"invalid_support_snapshot", "retryable":true}
	var section_key: Vector3i = snapshot.supportSectionKey
	var certificate: Dictionary = snapshot.coverageCertificate
	var source_index_revision := int(snapshot.get("sourceIndexRevision", -1))
	var coverage_digest := String(snapshot.get("coverageDigest", ""))
	if source_index_revision < 0 or coverage_digest.length() != 64 \
			or String(certificate.get("coverageDigest", "")) != coverage_digest \
			or int(certificate.get("sourceIndexRevision", -1)) != source_index_revision \
			or certificate.get("sectionKey", null) != section_key \
			or String(certificate.get("worldId", "")) != _world_id \
			or not support_section_demand_matches(String(snapshot.get("viewOwner", "")), snapshot):
		return {"status":"pending", "reason":"support_snapshot_identity_not_current",
			"retryable":true, "sectionKey":section_key}
	var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	if not _production_candidates_by_section.has(section_key) or receipt.is_empty() \
			or not installed_section_receipt_is_current(section_key, receipt):
		return {"status":"pending", "reason":"support_section_native_receipt_not_current",
			"retryable":true, "sectionKey":section_key}
	if not _receipt_covers_support_identity(receipt, section_key,
			source_index_revision, coverage_digest):
		return {"status":"pending", "reason":"installed_candidate_support_identity_stale",
			"retryable":true, "sectionKey":section_key,
			"sourceIndexRevision":source_index_revision,
			"coverageDigest":coverage_digest}
	return {"status":"ready", "sectionKey":section_key,
		"sourceIndexRevision":source_index_revision,
		"coverageDigest":coverage_digest,
		"snapshotDigest":String(snapshot.snapshotDigest),
		"receipt":receipt.duplicate(true)}


## Presentation completion is independent of geometry cardinality. Its evidence
## is the same current native transaction receipt and immutable installed snapshot.
func validate_presentation_owner_completion(world_id: String, source_id: String,
		part_id: String, revision: String, expected_members: Array, prior_members: Array = []) -> Dictionary:
	if world_id != _world_id or source_id.is_empty() or part_id.is_empty() or revision.is_empty():
		return {"status":"pending", "reason":"presentation_completion_identity_invalid"}
	var contract = preload("res://scripts/world/StaticSectionPresentationMembers.gd")
	if expected_members.size() > contract.MAX_MEMBERS or prior_members.size() > contract.MAX_MEMBERS:
		return {"status":"pending", "reason":"presentation_completion_roster_capacity"}
	var expected_by_section: Dictionary = {}
	var required: Dictionary = {}
	var seen: Dictionary = {}
	for member: Variant in expected_members:
		if contract.validate(member, source_id, part_id, revision).get("status") != "ready":
			return {"status":"pending", "reason":"presentation_completion_roster_invalid"}
		var key := String(member.presentationMemberId)
		var member_key := "member:" + key
		var attachment_key := "attachment:" + String(member.attachmentKey)
		if seen.has(member_key) or seen.has(attachment_key): return {"status":"pending", "reason":"presentation_completion_member_duplicate"}
		seen[member_key] = true
		seen[attachment_key] = true
		if not contract.valid_grid_position(member.neutralParentToWorld.origin, SectionGrid.SECTION_SIZE_METERS):
			return {"status":"pending", "reason":"presentation_completion_anchor_invalid"}
		var section: Vector3i = SectionGrid.key_for_world_position(member.neutralParentToWorld.origin)
		if not expected_by_section.has(section): expected_by_section[section] = {}
		expected_by_section[section][key] = member
		required[section] = true
	for member: Variant in prior_members:
		if not member is Dictionary or contract.validate(member, source_id, part_id,
				String(member.get("sourceRevision", ""))).get("status") != "ready":
			return {"status":"pending", "reason":"presentation_completion_prior_roster_invalid"}
		if not contract.valid_grid_position(member.neutralParentToWorld.origin, SectionGrid.SECTION_SIZE_METERS):
			return {"status":"pending", "reason":"presentation_completion_prior_anchor_invalid"}
		required[SectionGrid.key_for_world_position(member.neutralParentToWorld.origin)] = true
	# Include installed owners even if a provider lost its historical view.
	for section: Vector3i in _visible_sections_by_source_id.get(source_id, {}):
		for member: Dictionary in _production_candidates_by_section.get(section, {}).get("candidate", {}).get("snapshot", {}).get("presentationMembers", []):
			if member.get("sourceId") == source_id and member.get("sourcePartId") == part_id:
				required[section] = true
	var identity := SourceRoster._source_part_identity_key(source_id, part_id)
	for section: Vector3i in required:
		var receipt: Dictionary = _production_candidate_receipts.get(section, {})
		if not installed_section_receipt_is_current(section, receipt):
			return {"status":"pending", "reason":"presentation_completion_native_receipt_stale", "sectionKey":section}
		if receipt.get("sourceRevisions", {}).get(identity) != revision \
				and receipt.get("removalRevisions", {}).get(identity) != revision:
			return {"status":"pending", "reason":"presentation_completion_current_claim_missing", "sectionKey":section}
		var actual: Dictionary = {}
		for member: Dictionary in _production_candidates_by_section.get(section, {}).get("candidate", {}).get("snapshot", {}).get("presentationMembers", []):
			if member.get("sourceId") != source_id or member.get("sourcePartId") != part_id: continue
			var key := String(member.get("presentationMemberId", ""))
			if actual.has(key): return {"status":"pending", "reason":"presentation_completion_installed_duplicate"}
			actual[key] = member
		if actual != expected_by_section.get(section, {}):
			return {"status":"pending", "reason":"presentation_completion_installed_roster_mismatch", "sectionKey":section}
	return {"status":"ready", "sourceId":source_id, "sourceRevision":revision,
		"presentationMemberCount":expected_members.size(), "requiredSectionCount":required.size()}

func installed_section_contains_source(section_key: Vector3i, source_id: String,
		source_revision: String) -> bool:
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	if candidate.is_empty() or receipt.is_empty() \
			or not installed_section_receipt_is_current(section_key, receipt):
		return false
	return String(_section_candidate_source_revisions(candidate).get(source_id, "")) \
		== source_revision


func installed_section_contains_member(section_key: Vector3i,
		lease: Dictionary) -> bool:
	if not _support_lease_is_well_formed(lease, section_key, "compiled"):
		return false
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	if candidate.is_empty() or receipt.is_empty() \
			or not installed_section_receipt_is_current(section_key, receipt):
		return false
	var prepared: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = prepared.get("snapshot", {})
	var manifest: Variant = snapshot.get("manifest", [])
	if not manifest is Array:
		return false
	var source_id := String(lease.get("sourceId", ""))
	var source_revision := String(lease.get("sourceRevision", ""))
	var member_id := String(lease.get("memberId", ""))
	for source_value: Variant in manifest:
		if not source_value is Dictionary or String(source_value.get("sourceId", "")) != source_id \
				or String(source_value.get("sourceRevision", "")) != source_revision:
			continue
		for support_value: Variant in source_value.get("supportRanges", []):
			if support_value is Dictionary and _support_range_matches_lease(
					support_value, lease, section_key):
				return true
	return false


func installed_section_member_absent(section_key: Vector3i,
		lease: Dictionary) -> bool:
	if not _support_lease_is_well_formed(lease, section_key, "tombstoned"):
		return false
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	if candidate.is_empty() or receipt.is_empty() \
			or not installed_section_receipt_is_current(section_key, receipt):
		return false
	var prepared: Dictionary = candidate.get("candidate", {})
	var snapshot: Dictionary = prepared.get("snapshot", {})
	var manifest: Variant = snapshot.get("manifest", [])
	if not manifest is Array:
		return false
	var source_id := String(lease.get("sourceId", ""))
	var source_revision := String(lease.get("sourceRevision", ""))
	var member_id := String(lease.get("memberId", ""))
	var segment := "ecology-static:%s:%s" % [member_id, source_revision]
	for source_value: Variant in manifest:
		if not source_value is Dictionary or String(source_value.get("sourceId", "")) != source_id:
			continue
		for support_value: Variant in source_value.get("supportRanges", []):
			if support_value is Dictionary \
					and String(support_value.get("memberId", "")) == member_id \
					and String(support_value.get("sourceRevision", "")) == source_revision \
					and support_value.get("geometryOwnerSection") == section_key:
				return false
		for instance_value: Variant in source_value.get("instances", []):
			if instance_value is Dictionary and instance_value.get("sectionKey") == section_key \
					and String(instance_value.get("sourceSegmentId", "")) == segment:
				return false
	return true


func _receipt_covers_support_identity(receipt: Dictionary, section_key: Vector3i,
		source_index_revision: int, coverage_digest: String) -> bool:
	var identities: Variant = receipt.get("supportCoverageIdentities", null)
	if not identities is Array:
		return false
	for identity_value: Variant in identities:
		if identity_value is Dictionary \
				and String(identity_value.get("schema", "")) \
					== "ecology-support-coverage-identity/v1" \
				and String(identity_value.get("providerId", "")) \
					== "ecology_and_static_props" \
				and identity_value.get("sectionKey", null) == section_key \
				and int(identity_value.get("sourceIndexRevision", -1)) == source_index_revision \
				and String(identity_value.get("coverageDigest", "")) == coverage_digest:
			return true
	return false


func _support_lease_is_well_formed(lease: Dictionary, owner_section: Vector3i,
		expected_state: String) -> bool:
	var artifact_generation := int(lease.get("recipeArtifactGeneration", 0))
	var kind := String(lease.get("kind", ""))
	var envelope_digest := String(lease.get("certifiedEnvelopeDigest", ""))
	var artifact_proof_valid := artifact_generation > 0 \
		or (kind in ["static_prop", "surface_detail"] and envelope_digest.length() == 64)
	return lease.is_read_only() \
		and String(lease.get("schema", "")) == "ecology-support-owner-lease/v1" \
		and String(lease.get("state", "")) == expected_state \
		and String(lease.get("sourceId", "")) != "" \
		and String(lease.get("sourceRevision", "")) != "" \
		and String(lease.get("memberId", "")) != "" \
		and String(lease.get("sourceDomainRevision", "")) != "" \
		and String(lease.get("producerSnapshotRevision", "")) != "" \
		and artifact_proof_valid \
		and String(lease.get("supportLeaseToken", "")) != "" \
		and String(lease.get("coverageDigest", "")).length() == 64 \
		and int(lease.get("sourceIndexRevision", -1)) >= 0 \
		and lease.get("ownerSectionKey", null) == owner_section \
		and String(lease.get("certifiedEnvelopeDigest", "")).length() == 64


func _support_range_matches_lease(support_range: Dictionary, lease: Dictionary,
		owner_section: Vector3i) -> bool:
	return String(support_range.get("sourceId", "")) == String(lease.get("sourceId", "")) \
		and String(support_range.get("sourceRevision", "")) == String(lease.get("sourceRevision", "")) \
		and String(support_range.get("memberId", "")) == String(lease.get("memberId", "")) \
		and support_range.get("geometryOwnerSection", null) == owner_section \
		and String(support_range.get("sourceDomainRevision", "")) \
			== String(lease.get("sourceDomainRevision", "")) \
		and String(support_range.get("producerSnapshotRevision", "")) \
			== String(lease.get("producerSnapshotRevision", "")) \
		and int(support_range.get("artifactGeneration", 0)) \
			== int(lease.get("recipeArtifactGeneration", 0)) \
		and String(support_range.get("certifiedEnvelopeDigest", "")) \
			== String(lease.get("certifiedEnvelopeDigest", "")) \
		and String(support_range.get("influencePolicyRevision", "")) \
			== String(lease.get("influencePolicyRevision", "")) \
		and String(support_range.get("influencePolicyDigest", "")) \
			== String(lease.get("influencePolicyDigest", ""))


## Rebuild a demanded section after an authoritative contributor changes. The
## old accepted candidate and renderer receipt remain owned until a replacement
## receives a current native install acknowledgement.
func invalidate_visible_section_source(section_key: Vector3i, provider_id: String,
		source_id: String, source_revision: String) -> Dictionary:
	if provider_id.strip_edges().is_empty() or source_id.strip_edges().is_empty() \
			or source_revision.strip_edges().is_empty():
		return _failed("invalid_visible_section_source_invalidation")
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	_pending_source_acknowledgements.erase(section_key)
	_erase_source_install_acknowledgement(section_key)
	var dirty_sources: Dictionary = _dirty_source_sections.get(section_key, {})
	dirty_sources[source_id] = {"providerId":provider_id,
		"sourceRevision":source_revision, "requestedFrame":Engine.get_process_frames()}
	_dirty_source_sections[section_key] = dirty_sources
	var replay_cancel := _cancel_stale_replay_for_section(section_key)
	if replay_cancel.get("status") == "rollback_failed":
		return replay_cancel
	if state.is_empty():
		return {"status":"deferred", "reason":"section_not_currently_demanded",
			"retryable":true, "dirtyRetained":true,
			"sectionKey":section_key, "providerId":provider_id, "sourceId":source_id}
	var previous_generation := int(state.get("installedGeneration", 0))
	var invalidation_cancel := _cancel_pending_production_candidate(section_key)
	if invalidation_cancel.get("status") == "rollback_failed":
		return invalidation_cancel
	state["stage"] = "waiting"
	state["attempts"] = 0
	state["lastReason"] = "authoritative_source_revision_changed"
	state["lastInstallStatus"] = "pending"
	state["lastInstallReason"] = "authoritative_source_revision_changed"
	state["nextAttemptFrame"] = Engine.get_process_frames()
	state["sourceInvalidation"] = {"providerId":provider_id, "sourceId":source_id,
		"sourceRevision":source_revision, "requestedFrame":Engine.get_process_frames()}
	if _production_candidates_by_section.has(section_key):
		# Source invalidations and terrain-revision requests are two entry points
		# to the same replacement lifecycle. Keep the installed representation
		# visible, but give its replacement the same urgent queue priority.
		state["urgentRecompile"] = true
		state["priority"] = 0.0
	state.erase("candidateGeneration")
	state.erase("blockedReason")
	state.erase("continuationHint")
	if not bool(state.get("queued", false)):
		_enqueue_visible_section_demand(section_key, state)
	_visible_section_demands[section_key] = state
	return {"status":"queued", "sectionKey":section_key,
		"providerId":provider_id, "sourceId":source_id,
		"sourceRevision":source_revision,
		"previousInstalledGeneration":previous_generation,
		"previousRepresentationRetained":_production_candidates_by_section.has(section_key)}


## Resolve changed/removed sources from installed complete manifests, and include
## sections intersecting current bounds for additions or moves. This searches
## the bounded source index, not resident gameplay chunks.
func invalidate_visible_static_source(provider_id: String, source_id: String,
		source_revision: String, current_world_bounds: AABB = AABB()) -> Dictionary:
	if provider_id.strip_edges().is_empty() or source_id.strip_edges().is_empty() \
			or source_revision.strip_edges().is_empty():
		return _failed("invalid_visible_static_source_invalidation")
	var affected: Dictionary = {}
	var installed_sections: Variant = _visible_sections_by_source_id.get(source_id, {})
	if installed_sections is Dictionary:
		for section_value: Variant in installed_sections:
			if section_value is Vector3i:
				affected[Vector3i(section_value)] = true
	if _valid_source_invalidation_bounds(current_world_bounds):
		for section_key: Vector3i in SectionGrid.keys_intersecting_bounds(current_world_bounds):
			affected[section_key] = true
	if affected.is_empty():
		return {"status":"pending", "reason":"source_affected_sections_unknown",
			"retryable":true, "providerId":provider_id, "sourceId":source_id}
	if affected.size() > MAX_SOURCE_INVALIDATION_SECTIONS:
		return _failed("source_invalidation_section_budget_exceeded")
	var section_keys: Array[Vector3i] = []
	for section_value: Variant in affected:
		section_keys.append(Vector3i(section_value))
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var results: Array[Dictionary] = []
	var queued_count := 0
	var deferred := 0
	for section_key: Vector3i in section_keys:
		var invalidation := invalidate_visible_section_source(section_key, provider_id,
			source_id, source_revision)
		results.append(invalidation)
		if invalidation.get("status") == "queued":
			queued_count += 1
		elif invalidation.get("status") == "deferred":
			deferred += 1
	results.make_read_only()
	return {"status":"queued" if queued_count > 0 else "deferred",
		"providerId":provider_id, "sourceId":source_id,
		"sourceRevision":source_revision, "affectedSectionKeys":section_keys,
		"queuedCount":queued_count, "deferredCount":deferred, "results":results}


static func _valid_source_invalidation_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


func _replace_section_source_index(section_key: Vector3i, previous: Dictionary,
		replacement: Dictionary) -> void:
	var previous_sources := _section_candidate_source_revisions(previous)
	var replacement_source_revisions := _section_candidate_source_revisions(replacement)
	var all_sources: Dictionary = {}
	for source_id: String in previous_sources: all_sources[source_id] = true
	for source_id: String in replacement_source_revisions: all_sources[source_id] = true
	for source_id: String in all_sources:
		var had_section := previous_sources.has(source_id)
		var has_section := replacement_source_revisions.has(source_id)
		if had_section and has_section:
			var same_membership_sections: Dictionary = _visible_sections_by_source_id.get(source_id, {})
			same_membership_sections[section_key] = String(replacement_source_revisions[source_id])
			_visible_sections_by_source_id[source_id] = same_membership_sections
			continue
		if not had_section and not has_section: continue
		var sections: Dictionary = _visible_sections_by_source_id.get(source_id, {})
		var section_keys: Array = _visible_section_keys_by_source_id.get(source_id, []).duplicate()
		if has_section:
			sections[section_key] = String(replacement_source_revisions[source_id])
			if not section_keys.has(section_key): section_keys.append(section_key)
		else:
			sections.erase(section_key)
			section_keys.erase(section_key)
		if sections.is_empty():
			_visible_sections_by_source_id.erase(source_id)
			_visible_section_keys_by_source_id.erase(source_id)
		else:
			_visible_sections_by_source_id[source_id] = sections
			section_keys.make_read_only()
			_visible_section_keys_by_source_id[source_id] = section_keys
		_advance_geometry_owner_visible_membership_revision(source_id)
	for source_id: String in replacement_source_revisions:
		var sections: Dictionary = _visible_sections_by_source_id.get(source_id, {})
		var section_keys: Array = _visible_section_keys_by_source_id.get(source_id, []).duplicate()
		if not sections.has(section_key): section_keys.append(section_key)
		sections[section_key] = String(replacement_source_revisions[source_id])
		_visible_sections_by_source_id[source_id] = sections
		section_keys.make_read_only()
		_visible_section_keys_by_source_id[source_id] = section_keys


## Resolve source identity from the accepted render manifest, which carries
## sourceId/sourceRevision. sourceRevisions on the candidate is keyed by
## sourcePartId and is a different identity boundary.
static func _section_candidate_source_revisions(candidate: Dictionary) -> Dictionary:
	var prepared_value: Variant = candidate.get("candidate", {})
	if not prepared_value is Dictionary:
		return {}
	var snapshot_value: Variant = prepared_value.get("snapshot", {})
	if not snapshot_value is Dictionary:
		return {}
	var manifest_value: Variant = snapshot_value.get("manifest", [])
	if not manifest_value is Array:
		return {}
	var result: Dictionary = {}
	for manifest_value_row: Variant in manifest_value:
		if not manifest_value_row is Dictionary:
			continue
		var source_id := String(manifest_value_row.get("sourceId", ""))
		var source_revision := String(manifest_value_row.get("sourceRevision", ""))
		if not source_id.is_empty() and not source_revision.is_empty():
			result[source_id] = source_revision
	return result


## Remove only queued/staged candidate work for an exited native mesh block.
## Accepted render slots remain under their current owner and are not retired here.
func withdraw_visible_section_demand(section_key: Vector3i) -> Dictionary:
	if not _visible_section_demands.has(section_key):
		return {"status":"idle", "sectionKey":section_key}
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	if not state.get("supportDemands", {}).is_empty():
		# A section that leaves the terrain mesh-block view can still own static
		# geometry required by another visible support section. Retire only the
		# ordinary VoxelTools demand and keep the candidate/replay slot alive.
		state["terrainDemandWithdrawn"] = true
		state.erase("terrainRevision")
		_visible_section_demands[section_key] = state
		_untrack_translucent_visible_section(section_key)
		return {"status":"retained_by_support_lease", "sectionKey":section_key,
			"supportDemandCount":state.get("supportDemands", {}).size()}
	var cancel_result := _cancel_pending_production_candidate(section_key)
	if cancel_result.get("status") == "rollback_failed":
		return cancel_result
	_visible_section_demands.erase(section_key)
	_source_roster.release_section_capture_demand(section_key)
	_untrack_translucent_visible_section(section_key)
	return {"status":"withdrawn", "sectionKey":section_key,
		"installedRepresentationRetained":_production_candidates_by_section.has(section_key)}


## Wake one currently demanded section after one of its exact producer proofs
## becomes current. This only removes that demand's retry delay; the next attempt
## still captures and validates the full authoritative source census.
func wake_visible_section_demand(section_key: Vector3i, reason: String,
		wake_token: String) -> Dictionary:
	if reason.strip_edges().is_empty() or wake_token.strip_edges().is_empty():
		return _failed("invalid_visible_section_demand_wake_reason")
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	if state.is_empty():
		return {"status":"ignored", "reason":"section_not_demanded",
			"sectionKey":section_key}
	if String(state.get("lastWakeToken", "")) == wake_token:
		return {"status":"duplicate", "sectionKey":section_key,
			"queued":bool(state.get("queued", false))}
	if state.get("stage") != "waiting":
		return {"status":"ignored", "reason":"section_demand_not_waiting",
			"sectionKey":section_key, "stage":String(state.get("stage", ""))}
	if bool(state.get("eventWake", false)):
		return {"status":"duplicate", "sectionKey":section_key,
			"queued":bool(state.get("queued", false))}
	state["nextAttemptFrame"] = Engine.get_process_frames()
	state["eventWake"] = true
	state["lastWakeReason"] = reason
	state["lastWakeToken"] = wake_token
	if not bool(state.get("queued", false)):
		_enqueue_visible_section_demand(section_key, state)
	_visible_section_demands[section_key] = state
	return {"status":"woken", "sectionKey":section_key,
		"reason":reason, "queueToken":int(state.get("queueToken", -1))}


## Refresh queued priorities from the live camera with a fixed work cap. This
## rotates only current pending demands and never enumerates the full resident
## terrain mesh-block dictionary.
func refresh_visible_section_demand_priorities(camera_position: Vector3,
		max_updates := 16) -> Dictionary:
	if not camera_position.is_finite() or max_updates < 1 or max_updates > 64:
		return _failed("invalid_visible_section_priority_refresh")
	_translucent_camera_position = camera_position
	_has_translucent_camera_snapshot = true
	var pov_resorts_queued := _queue_translucent_pov_resorts(
		MAX_TRANSLUCENT_POV_RESORT_SCAN_PER_REFRESH)
	var updated := 0
	var refresh_count := mini(max_updates, _visible_section_demand_count)
	for _index in range(refresh_count):
		var popped: Dictionary = _pop_visible_section_demand()
		if popped.get("status") != "ready":
			break
		var section_key: Vector3i = popped.sectionKey
		var state: Dictionary = _visible_section_demands.get(section_key, {})
		if state.is_empty() or not bool(state.get("queued", false)) \
				or int(state.get("queueToken", -1)) != int(popped.get("queueToken", -2)):
			continue
		state["queued"] = false
		if state.get("stage") == "waiting":
			var center := SectionGrid.origin_for_key(section_key) \
				+ Vector3.ONE * (SectionGrid.SECTION_SIZE_METERS * 0.5)
			state["priority"] = camera_position.distance_squared_to(center)
			updated += 1
			_enqueue_visible_section_demand(section_key, state)
		else:
			_visible_section_demands[section_key] = state
	return {"status":"advanced" if updated > 0 or pov_resorts_queued > 0 else "idle",
		"updatedCount":updated, "povResortsQueued":pov_resorts_queued,
		"pendingDemandCount":_visible_section_demands.size()}


func _track_translucent_visible_section(section_key: Vector3i) -> void:
	if _translucent_visible_section_set.has(section_key):
		return
	_translucent_visible_section_set[section_key] = true
	_translucent_visible_sections.append(section_key)


func _untrack_translucent_visible_section(section_key: Vector3i) -> void:
	if not _translucent_visible_section_set.erase(section_key):
		return
	var index := _translucent_visible_sections.find(section_key)
	if index < 0:
		return
	_translucent_visible_sections.remove_at(index)
	if _translucent_visible_sections.is_empty():
		_translucent_visible_scan_cursor = 0
	else:
		if index < _translucent_visible_scan_cursor:
			_translucent_visible_scan_cursor -= 1
		_translucent_visible_scan_cursor = posmod(_translucent_visible_scan_cursor,
			_translucent_visible_sections.size())


## Camera-relative transparency changes become normal replacement demand. The
## old accepted candidate/root stays installed while providers recompile the
## same section against the new POV and the native session accepts its receipt.
## Scan at most a fixed number of visible resident sections per camera refresh.
func _queue_translucent_pov_resorts(max_scans: int) -> int:
	if not _has_translucent_camera_snapshot or max_scans < 1 \
			or _translucent_visible_sections.is_empty():
		return 0
	var queued := 0
	var scan_count := mini(max_scans, _translucent_visible_sections.size())
	for _index in range(scan_count):
		if _translucent_visible_sections.is_empty():
			break
		_translucent_visible_scan_cursor = posmod(_translucent_visible_scan_cursor,
			_translucent_visible_sections.size())
		var section_key := _translucent_visible_sections[_translucent_visible_scan_cursor]
		_translucent_visible_scan_cursor = posmod(_translucent_visible_scan_cursor + 1,
			_translucent_visible_sections.size())
		var state: Dictionary = _visible_section_demands.get(section_key, {})
		if state.is_empty() or String(state.get("stage", "")) != "installed":
			continue
		var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
		var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
		var installed_pov := _candidate_translucent_pov_revision(candidate)
		if installed_pov <= 0 or receipt.is_empty() \
				or not _receipt_backend_matches_candidate(candidate, receipt) \
				or not _section_receipt_source_revision_matches_candidate(candidate, receipt):
			continue
		var current_pov := current_translucent_pov_snapshot(section_key)
		if current_pov.get("status") != "ready" \
				or int(current_pov.get("revision", -1)) == installed_pov:
			continue
		var terrain_revision := int(state.get("terrainRevision", 0))
		if terrain_revision <= 0:
			continue
		state.erase("candidateGeneration")
		state.erase("pendingCandidateStage")
		state.erase("blockedReason")
		state["stage"] = "waiting"
		state["urgentRecompile"] = true
		state["priority"] = 0.0
		state["attempts"] = 0
		state["nextAttemptFrame"] = Engine.get_process_frames()
		state["lastWakeReason"] = "translucent_camera_pov_changed"
		state["lastWakeToken"] = "%d" % int(current_pov.get("revision", -1))
		if not bool(state.get("queued", false)):
			_enqueue_visible_section_demand(section_key, state)
		_visible_section_demands[section_key] = state
		queued += 1
	return queued


## Supplies the active camera snapshot and Minecraft-style section-relative
## translucent-sort identity. The class changes only when the camera crosses a
## render-section boundary relative to this section, so small camera movement
## does not repeatedly invalidate staged installs. Producers sort their
## canonical face groups against cameraPosition; install sessions compare the
## class revision before upload/commit and request a replacement when it changes.
func current_translucent_pov_snapshot(section_key: Vector3i) -> Dictionary:
	if not _has_translucent_camera_snapshot or _world_id.is_empty():
		return {"status":"pending", "reason":"translucent_camera_snapshot_unavailable",
			"retryable":true, "sectionKey":section_key}
	var camera_section := SectionGrid.key_for_world_position(_translucent_camera_position)
	var pov_class := Vector3i(
		clampi(camera_section.x - section_key.x, -1, 1),
		clampi(camera_section.y - section_key.y, -1, 1),
		clampi(camera_section.z - section_key.z, -1, 1))
	# Stable POV identity (1..27), rather than a frame counter, mirrors
	# Minecraft's TranslucencyPointOfView and cannot starve work while the player
	# moves within the same relative section class.
	var pov_revision := pov_class.x + 1 + (pov_class.y + 1) * 3 \
		+ (pov_class.z + 1) * 9 + 1
	return {"status":"ready", "sectionKey":section_key,
		"cameraPosition":_translucent_camera_position,
		"povClass":pov_class, "revision":pov_revision}


## Admit at most a small number of visible demands. Selection examines a bounded
## queue window, prioritizes nearby first-time sections, and grants at most two
## nearer recompiles before giving an initial section its turn. Pending providers
## stay queued with delayed retries instead of rescanning every section each frame.
func advance_visible_section_candidate_demands(max_attempts := 1,
		urgent_only := false, phase_observer: Callable = Callable()) -> Dictionary:
	if max_attempts < 1 or max_attempts > 4:
		return _failed("invalid_visible_section_candidate_attempt_budget")
	var results: Array[Dictionary] = []
	for _attempt_index in range(max_attempts):
		_emit_admission_phase(phase_observer, "demand_selection", {
			"attemptIndex":_attempt_index})
		var selected: Dictionary = _take_next_visible_section_demand(urgent_only)
		if selected.get("status") != "ready":
			_emit_admission_phase(phase_observer, "demand_selection_complete", {
				"attemptIndex":_attempt_index, "status":String(selected.get("status", ""))})
			break
		var section_key: Vector3i = selected.sectionKey
		var state: Dictionary = selected.state
		_emit_admission_phase(phase_observer, "candidate_assembly", {
			"attemptIndex":_attempt_index, "sectionKey":section_key})
		var candidate_generation := int(state.get("admissionGeneration", 0))
		if candidate_generation <= 0:
			_production_candidate_generation += 1
			candidate_generation = _production_candidate_generation
		var admission: Dictionary = assemble_and_submit_complete_section_candidate(
			section_key, candidate_generation, phase_observer)
		state["attempts"] = int(state.get("attempts", 0)) + 1
		state["lastReason"] = String(admission.get("reason", ""))
		state["lastStatus"] = String(admission.get("status", "failed"))
		state["lastAdmissionDetails"] = _visible_section_admission_details(admission)
		if admission.get("status") == "queued":
			state["stage"] = "candidate_queued"
			state["candidateGeneration"] = candidate_generation
			state.erase("admissionGeneration")
			state.erase("blockedReason")
			state.erase("continuationHint")
		else:
			var retryable: bool = admission.get("status") == "pending" \
				or bool(admission.get("retryable", false))
			state["stage"] = "waiting" if retryable else "blocked"
			if retryable:
				state["admissionGeneration"] = candidate_generation
				state.erase("blockedReason")
			else:
				state.erase("admissionGeneration")
				state["blockedReason"] = String(admission.get("reason", admission.get("status", "failed")))
			var continuation_value: Variant = admission.get("continuationHint", null)
			var has_continuation: bool = continuation_value is Dictionary \
				and continuation_value.is_read_only() \
				and String(continuation_value.get("schema", "")) \
					== "static-section-provider-continuation/v1"
			if retryable and has_continuation:
				state["continuationHint"] = continuation_value
				state["nextAttemptFrame"] = Engine.get_process_frames() + 1
			else:
				state.erase("continuationHint")
				state["nextAttemptFrame"] = Engine.get_process_frames() \
					+ VISIBLE_SECTION_DEMAND_RETRY_FRAMES
			if retryable:
				_enqueue_visible_section_demand(section_key, state)
		_visible_section_demands[section_key] = state
		results.append({"sectionKey":section_key,
			"terrainRevision":String(state.get("terrainRevision", "")),
			"terrainSourceRevision":String(state.get("supportDemands", {}).values()[0].get(
				"terrainSourceRevision", "")) if not state.get("supportDemands", {}).is_empty() else "",
			"stage":String(state.stage), "admission":admission})
	_visible_section_demand_attempts += results.size()
	results.make_read_only()
	return {"status":"advanced" if not results.is_empty() else "idle",
		"attemptCount":results.size(), "totalAttempts":_visible_section_demand_attempts,
		"pendingDemandCount":_visible_section_demands.size(), "results":results}


func has_urgent_visible_section_recompile() -> bool:
	if _visible_section_demand_count <= 0 or _visible_section_demand_queue.is_empty():
		return false
	var queued: Dictionary = _visible_section_demand_queue[_visible_section_demand_head]
	var section_key: Vector3i = queued.get("sectionKey", Vector3i.ZERO)
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	return not state.is_empty() and state.get("stage") == "waiting" \
		and bool(state.get("queued", false)) \
		and bool(state.get("urgentRecompile", false)) \
		and int(state.get("nextAttemptFrame", 0)) <= Engine.get_process_frames() \
		and int(state.get("queueToken", -1)) == int(queued.get("queueToken", -2)) \
		and _production_candidates_by_section.has(section_key)


func _take_next_visible_section_demand(urgent_only := false) -> Dictionary:
	if _visible_section_demand_count <= 0:
		return {"status":"idle"}
	var current_frame := Engine.get_process_frames()
	var wake_allows_retry := _visible_section_demand_wake_rounds > 0
	var initial_candidates: Array[Dictionary] = []
	var recompile_candidates: Array[Dictionary] = []
	var scan_count := mini(MAX_VISIBLE_SECTION_DEMAND_SCAN_PER_ADVANCE,
		_visible_section_demand_count)
	for _scan_index in range(scan_count):
		var popped: Dictionary = _pop_visible_section_demand()
		if popped.get("status") != "ready":
			break
		var section_key: Vector3i = popped.sectionKey
		var state: Dictionary = _visible_section_demands.get(section_key, {})
		if state.is_empty() or not bool(state.get("queued", false)) \
				or int(state.get("queueToken", -1)) != int(popped.get("queueToken", -2)):
			continue
		state["queued"] = false
		_visible_section_demands[section_key] = state
		if state.get("stage") != "waiting":
			continue
		var event_wake := bool(state.get("eventWake", false))
		if not event_wake and not wake_allows_retry \
				and int(state.get("nextAttemptFrame", 0)) > current_frame:
			_enqueue_visible_section_demand(section_key, state)
			continue
		if event_wake:
			state.erase("eventWake")
			_visible_section_demands[section_key] = state
		var row := {"sectionKey":section_key, "state":state,
			"priority":float(state.get("priority", INF))}
		var continuation_value: Variant = state.get("continuationHint", null)
		var has_continuation: bool = continuation_value is Dictionary \
			and not (continuation_value as Dictionary).is_empty()
		if _production_candidates_by_section.has(section_key) \
				or has_continuation:
			recompile_candidates.append(row)
		else:
			initial_candidates.append(row)
	if wake_allows_retry:
		_visible_section_demand_wake_rounds = maxi(0, _visible_section_demand_wake_rounds - 1)
	var selected: Dictionary = {}
	var initial: Dictionary = _closest_visible_demand(initial_candidates)
	var recompile: Dictionary = _closest_visible_demand(recompile_candidates)
	var urgent_recompiles: Array[Dictionary] = []
	for row: Dictionary in recompile_candidates:
		if bool(row.state.get("urgentRecompile", false)):
			urgent_recompiles.append(row)
	var urgent_recompile: Dictionary = _closest_visible_demand(urgent_recompiles)
	if urgent_only:
		selected = urgent_recompile
	elif not urgent_recompile.is_empty():
		selected = urgent_recompile
		_visible_section_recompile_quota = maxi(0, _visible_section_recompile_quota - 1)
	elif not recompile.is_empty() and (initial.is_empty() \
			or float(recompile.priority) < float(initial.priority) \
			and _visible_section_recompile_quota > 0):
		selected = recompile
		_visible_section_recompile_quota = maxi(0, _visible_section_recompile_quota - 1)
	elif not initial.is_empty():
		selected = initial
		_visible_section_recompile_quota = 2
	elif not recompile.is_empty():
		selected = recompile
		_visible_section_recompile_quota = maxi(0, _visible_section_recompile_quota - 1)
	for row: Dictionary in initial_candidates + recompile_candidates:
		if row.get("sectionKey") != selected.get("sectionKey"):
			_enqueue_visible_section_demand(row.sectionKey, row.state)
	if selected.is_empty():
		return {"status":"idle"}
	return {"status":"ready", "sectionKey":selected.sectionKey, "state":selected.state}


func _closest_visible_demand(rows: Array[Dictionary]) -> Dictionary:
	var selected: Dictionary = {}
	for row: Dictionary in rows:
		if selected.is_empty() or float(row.priority) < float(selected.priority):
			selected = row
	return selected


static func _visible_section_admission_details(admission: Dictionary) -> Dictionary:
	var result := {}
	for key in ["providerId", "chunk", "sourceId", "sourcePartId", "cell", "blockType",
			"missingCategories", "categoryEvidence",
			"supportPolicyDiagnostic", "captureProgress", "producerStatus",
			"sourceChunkKey",
			"snapshotRemovedPropsRevision",
			"currentRemovedPropsRevision", "snapshotSourceRevision", "currentSourceRevision",
			"requestedSection", "ownedSection", "phaseUsec", "providerPhaseUsec",
			"contributionProviderPhaseUsec"]:
		if admission.has(key):
			result[key] = admission[key]
	if admission.has("providerReason"):
		result["providerReason"] = String(admission.get("providerReason", ""))
	var provider_details: Variant = admission.get("providerDetails", {})
	if provider_details is Dictionary:
		for key in ["chunk", "sourceId", "sourcePartId", "cell", "blockType",
				"missingCategories", "categoryEvidence",
				"family", "materialClass", "meshFingerprintStatus",
				"meshContentDigest", "declaredMeshContentDigest",
				"materialContentDigest", "declaredMaterialContentDigest",
				"meshDigestLength",
				"declaredMeshDigestLength", "meshDigestMatches",
				"materialDigestLength", "declaredMaterialDigestLength",
				"materialDigestMatches", "resourceDescriptorRevisionLength",
				"snapshotRemovedPropsRevision", "currentRemovedPropsRevision",
				"snapshotSourceRevision", "currentSourceRevision",
				"snapshotValidationStatus", "snapshotValidationReason"]:
			if provider_details.has(key):
				result[key] = provider_details[key]
	var validation_value: Variant = admission.get("snapshotValidation", null)
	if validation_value is Dictionary:
		result["snapshotValidationStatus"] = String(validation_value.get("status", ""))
		result["snapshotValidationReason"] = String(validation_value.get("reason", ""))
	var continuation_value: Variant = admission.get("continuationHint", null)
	if continuation_value is Dictionary and continuation_value.is_read_only():
		result["continuationStage"] = String(continuation_value.get("stage", ""))
		result["continuationCursor"] = int(continuation_value.get("cursor", -1))
	return result


func _enqueue_visible_section_demand(section_key: Vector3i, state: Dictionary) -> void:
	if bool(state.get("queued", false)):
		return
	if _visible_section_demand_queue.is_empty():
		_visible_section_demand_queue.resize(32)
	elif _visible_section_demand_count >= _visible_section_demand_queue.size():
		var expanded: Array[Dictionary] = []
		expanded.resize(_visible_section_demand_queue.size() * 2)
		for index in range(_visible_section_demand_count):
			expanded[index] = _visible_section_demand_queue[
				(_visible_section_demand_head + index) % _visible_section_demand_queue.size()]
		_visible_section_demand_queue = expanded
		_visible_section_demand_head = 0
		_visible_section_demand_tail = _visible_section_demand_count
	_visible_section_demand_queue_token += 1
	var queue_token := _visible_section_demand_queue_token
	var queued_row := {"sectionKey":section_key, "queueToken":queue_token}
	if bool(state.get("urgentRecompile", false)):
		_visible_section_demand_head = posmod(_visible_section_demand_head - 1,
			_visible_section_demand_queue.size())
		_visible_section_demand_queue[_visible_section_demand_head] = queued_row
		if _visible_section_demand_count == 0:
			_visible_section_demand_tail = (_visible_section_demand_head + 1) \
				% _visible_section_demand_queue.size()
	else:
		_visible_section_demand_queue[_visible_section_demand_tail] = queued_row
		_visible_section_demand_tail = (_visible_section_demand_tail + 1) \
			% _visible_section_demand_queue.size()
	_visible_section_demand_count += 1
	state["queued"] = true
	state["queueToken"] = queue_token
	_visible_section_demands[section_key] = state


func _pop_visible_section_demand() -> Dictionary:
	if _visible_section_demand_count <= 0:
		return {"status":"idle"}
	var queued: Dictionary = _visible_section_demand_queue[_visible_section_demand_head]
	var section_key: Vector3i = queued.get("sectionKey", Vector3i.ZERO)
	_visible_section_demand_queue[_visible_section_demand_head] = {}
	_visible_section_demand_head = (_visible_section_demand_head + 1) \
		% _visible_section_demand_queue.size()
	_visible_section_demand_count -= 1
	return {"status":"ready", "sectionKey":section_key,
		"queueToken":int(queued.get("queueToken", -1))}


func _cancel_pending_production_candidate(section_key: Vector3i) -> Dictionary:
	_cancel_section_compile(section_key)
	var job: Dictionary = _production_candidate_jobs.get(section_key, {})
	if job.is_empty():
		return {"status":"cancelled", "sectionKey":section_key}
	var session = job.get("session")
	if session is RefCounted and session.has_method("cancel"):
		var cancelled: Dictionary = session.cancel()
		if cancelled.get("status") != "cancelled":
			job["stage"] = "rollback_failed"
			job["rollbackFailure"] = cancelled.duplicate(true)
			_production_candidate_jobs[section_key] = job
			return {"status":"rollback_failed", "reason":"section_candidate_cancel_rollback_failed",
				"sectionKey":section_key,
				"generation":int(job.get("candidate", {}).get("generation", 0)),
				"rollback":cancelled, "retryable":true}
	_production_candidate_jobs.erase(section_key)
	return {"status":"cancelled", "sectionKey":section_key}


func _wake_visible_section_demands() -> void:
	if _visible_section_demand_count > 0:
		_visible_section_demand_wake_rounds = maxi(
			_visible_section_demand_wake_rounds,
			ceili(float(_visible_section_demand_count) \
				/ float(MAX_VISIBLE_SECTION_DEMAND_SCAN_PER_ADVANCE)))


func capture_authoritative_source_census(section_keys: Array) -> Dictionary:
	return _source_roster.capture_sections(section_keys)


## Production composition entry point. It captures the exact required-provider
## census, requests each provider's sealed geometry, performs one shared
## cross-domain assembly, and queues only a complete candidate. Missing terrain
## layers or static domains therefore keep the existing renderer slot intact.
func assemble_and_submit_complete_section_candidate(section_key: Vector3i,
		candidate_generation: int, phase_observer: Callable = Callable()) -> Dictionary:
	if candidate_generation <= 0:
		return _failed("invalid_complete_section_candidate_generation")
	# Explicit admission callers and the visible-demand scheduler share this
	# monotonic world counter. The native dispatcher retains each section's high
	# water mark after cancellation, so remember direct generations before any
	# later demand allocates its replacement.
	_production_candidate_generation = maxi(_production_candidate_generation,
		candidate_generation)
	var phase_usec := {}
	var phase_started_usec := Time.get_ticks_usec()
	_emit_admission_phase(phase_observer, "provider_census", {"sectionKey":section_key})
	var census: Dictionary = _source_roster.capture_sections([section_key], phase_observer)
	phase_usec["census"] = Time.get_ticks_usec() - phase_started_usec
	var census_provider_times: Variant = census.get("providerPhaseUsec", {})
	if census_provider_times is Dictionary:
		for provider_id_value: Variant in census_provider_times:
			phase_usec["census_provider_" + String(provider_id_value)] = int(
				census_provider_times[provider_id_value])
	if census.get("status") != "complete":
		return _with_candidate_phase_timings(census, phase_usec)
	var support_revision_check := _current_support_terrain_revision_matches(section_key, census)
	if support_revision_check.get("status") != "ready":
		return _with_candidate_phase_timings(support_revision_check, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	_emit_admission_phase(phase_observer, "contributor_capture", {"sectionKey":section_key})
	var captured: Dictionary = _source_roster.capture_section_contributions(
		census, section_key, candidate_generation, phase_observer)
	phase_usec["contributions"] = Time.get_ticks_usec() - phase_started_usec
	var contribution_provider_times: Variant = captured.get("providerPhaseUsec", {})
	if contribution_provider_times is Dictionary:
		for provider_id_value: Variant in contribution_provider_times:
			phase_usec["contribution_provider_" + String(provider_id_value)] = int(
				contribution_provider_times[provider_id_value])
	if captured.get("status") != "complete":
		return _with_candidate_phase_timings(captured, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	_emit_admission_phase(phase_observer, "candidate_preparation", {"sectionKey":section_key})
	var prepared: Dictionary = CandidateAssembler.prepare_compile(census, section_key,
		captured.get("contributions", []), candidate_generation)
	phase_usec["prepare_compile"] = Time.get_ticks_usec() - phase_started_usec
	if prepared.get("status") != "ready":
		return _with_candidate_phase_timings(prepared, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	_emit_admission_phase(phase_observer, "native_compile_admission", {"sectionKey":section_key})
	var admitted := _submit_section_compile(census, section_key,
		candidate_generation, prepared)
	phase_usec["native_compile_admission"] = Time.get_ticks_usec() - phase_started_usec
	if admitted.get("status") != "queued":
		return _with_candidate_phase_timings(admitted, phase_usec)
	return _with_candidate_phase_timings({"status":"queued", "sectionKey":section_key,
		"generation":candidate_generation, "censusDigest":String(census.censusDigest),
		"stage":"native_compile", "compileTicket":admitted.get("ticket", 0),
		"preparedPayloadDigest":String(prepared.get("inputDigest", ""))},
		phase_usec)


static func _emit_admission_phase(observer: Callable, phase: String,
		details: Dictionary) -> void:
	if observer.is_valid():
		observer.call(phase, details)


func _submit_section_compile(census: Dictionary, section_key: Vector3i,
		generation: int, prepared: Dictionary) -> Dictionary:
	if not _section_compile_accepting:
		return _failed("section_compile_dispatcher_shutting_down")
	if _section_compile_dispatcher == null:
		if not ClassDB.class_exists("NativeSectionCompileDispatcher"):
			return _failed("native_section_compile_dispatcher_unavailable")
		_section_compile_dispatcher = ClassDB.instantiate("NativeSectionCompileDispatcher") as RefCounted
	if _section_compile_dispatcher == null:
		return _failed("native_section_compile_dispatcher_instantiation_failed")
	# Admission can wake a worker immediately. Supply the live camera first.
	_section_compile_dispatcher.call("set_compile_camera", _translucent_camera_position,
		Engine.get_process_frames())
	var previous: Dictionary = _section_compile_jobs.get(section_key, {})
	var previous_generation := int(previous.get("generation", 0))
	if previous_generation >= generation:
		return {"status":"failed", "reason":"stale_section_compile_generation",
			"sectionKey":section_key, "requestedGeneration":generation,
			"pendingCompileGeneration":previous_generation,
			"pendingCompileTicket":int(previous.get("ticket", 0)),
			"pendingCompileIdentity":previous.get("identity", {}),
			"pendingCompileRetryable":true}
	if not previous.is_empty():
		_cancel_section_compile(section_key)
	var identity := {"worldId":_world_id, "worldEpoch":_world_id,
		"sectionKey":section_key, "generation":generation,
		"providerRevisionDigest":String(census.get("censusDigest", "")),
		"sourceIndexRevision":0,
		# The census digest binds the complete per-provider coverage/revision vector;
		# this pipeline has no independent global source-index revision counter.
		"coverageDigest":String(census.get("censusDigest", "")),
		"preparedPayloadDigest":String(prepared.get("inputDigest", ""))}
	identity.make_read_only()
	var admission: Dictionary = _section_compile_dispatcher.call(
		"submit_section_compile", prepared.get("nativePreparation", {}), identity)
	if admission.get("status") == "backpressure":
		return {"status":"pending", "reason":"native_section_compile_backpressure",
			"retryable":true, "sectionKey":section_key}
	if admission.get("status") != "queued":
		return admission
	_section_compile_jobs[section_key] = {"ticket":int(admission.get("ticket", 0)),
		"generation":generation, "identity":identity,
		"preparation":prepared.get("preparation", {}), "census":census}
	_section_compile_order.append(section_key)
	return admission


func _cancel_section_compile(section_key: Vector3i) -> void:
	var job: Dictionary = _section_compile_jobs.get(section_key, {})
	if job.is_empty(): return
	if _section_compile_dispatcher != null:
		var identity: Dictionary = job.get("identity", {})
		_section_compile_dispatcher.call("cancel_section_compile",
			String(identity.get("worldId", "")), String(identity.get("worldEpoch", "")), section_key,
			int(job.get("generation", 0)))
		_section_compile_dispatcher.call("release_section_compile", int(job.get("ticket", 0)))
	_section_compile_jobs.erase(section_key)
	_section_compile_order.erase(section_key)


func _advance_section_compiles(max_results: int) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if _section_compile_dispatcher == null: return results
	_section_compile_dispatcher.call("set_compile_camera", _translucent_camera_position,
		Engine.get_process_frames())
	var scans := mini(_section_compile_order.size(), maxi(8, max_results))
	for _scan in range(scans):
		if results.size() >= max_results: break
		var key: Vector3i = _section_compile_order.pop_front()
		var job: Dictionary = _section_compile_jobs.get(key, {})
		if job.is_empty(): continue
		var ticket := int(job.get("ticket", 0))
		var polled: Dictionary = _section_compile_dispatcher.call("poll_section_compile", ticket)
		if String(polled.get("status", "")) in ["pending", "queued", "running"]:
			_section_compile_order.append(key)
			continue
		var generation := int(job.get("generation", 0))
		var outcome: Dictionary
		var compile_phase_usec: Dictionary = {}
		var census_provider_phase_usec: Dictionary = {}
		if polled.get("status") != "ready":
			outcome = {"status":"failed", "reason":String(polled.get("reason",
				"native_section_compile_failed")), "retryable":false}
			_section_compile_dispatcher.call("release_section_compile", ticket)
		else:
			var compiled: Dictionary = _section_compile_dispatcher.call(
				"take_section_compile_result", ticket)
			var census_started_usec := Time.get_ticks_usec()
			var census := capture_authoritative_source_census([key])
			compile_phase_usec["resultCensus"] = Time.get_ticks_usec() - census_started_usec
			var census_provider_times: Variant = census.get("providerPhaseUsec", {})
			if census_provider_times is Dictionary:
				census_provider_phase_usec = census_provider_times.duplicate(false)
			if compiled.get("identity", {}) != job.get("identity", {}) \
					or compiled.get("status") != "ready" \
					or int(compiled.get("ticket", 0)) != ticket:
				outcome = _failed("native_section_compile_result_identity_mismatch")
			elif census.get("status") != "complete" \
					or census.get("censusDigest") != job.census.get("censusDigest"):
				outcome = {"status":"cancelled", "reason":"native_section_compile_census_stale",
					"requiresReassembly":true, "retryable":true}
			else:
				var finalize_started_usec := Time.get_ticks_usec()
				var finalized: Dictionary = CandidateAssembler.finalize_compile(
					job.preparation, compiled)
				compile_phase_usec["finalizeCompile"] = Time.get_ticks_usec() - finalize_started_usec
				if finalized.get("status") == "ready":
					var compile_receipt := {"status":"compiled", "ticket":ticket,
						"identity":job.identity, "groupCount":compiled.get("groups", {}).size()}
					compile_receipt.make_read_only()
					var compiled_candidate: Dictionary = finalized.candidate.duplicate(false)
					compiled_candidate["nativeCompileReceipt"] = compile_receipt
					compiled_candidate.make_read_only()
					var submit_started_usec := Time.get_ticks_usec()
					outcome = submit_complete_section_candidate(compiled_candidate)
					compile_phase_usec["candidateSubmit"] = Time.get_ticks_usec() - submit_started_usec
					if outcome.get("status") == "queued":
						_section_compile_completed_count += 1
					elif outcome.get("status") == "pending":
						outcome["requiresReassembly"] = true
				else:
					outcome = finalized
		if not compile_phase_usec.is_empty():
			outcome["phaseUsec"] = compile_phase_usec
			outcome["censusProviderPhaseUsec"] = census_provider_phase_usec
		_section_compile_jobs.erase(key)
		outcome["sectionKey"] = key
		outcome["generation"] = generation
		outcome["stage"] = "native_compile"
		_reconcile_visible_section_candidate_outcome(key, generation, outcome)
		results.append(outcome)
	return results


func drain_section_compiles() -> Dictionary:
	_section_compile_accepting = false
	var result: Dictionary = {"status":"drained", "pendingJobCount":0}
	if _section_compile_dispatcher != null:
		result = _section_compile_dispatcher.call("drain_section_compiles")
	_section_compile_jobs.clear()
	_section_compile_order.clear()
	return result


func _current_support_terrain_revision_matches(section_key: Vector3i,
		census: Dictionary) -> Dictionary:
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	var demands: Dictionary = state.get("supportDemands", {})
	if demands.is_empty(): return {"status":"ready"}
	var has_terrain_revision_demand := false
	for demand_value: Variant in demands.values():
		if demand_value is Dictionary \
				and String(demand_value.get("kind", "")) != "ordinary_geometry_support":
			has_terrain_revision_demand = true
			break
	if not has_terrain_revision_demand:
		return {"status":"ready"}
	var source_revisions: Variant = census.get("sourceRevisions", {})
	var source_providers: Variant = census.get("sourceProviderIds", {})
	if not source_revisions is Dictionary or not source_providers is Dictionary:
		return {"status":"pending", "reason":"support_terrain_census_identity_missing",
			"retryable":true, "sectionKey":section_key}
	var actual_terrain_revisions: Array[String] = []
	for source_id_value: Variant in source_providers:
		if String(source_providers[source_id_value]) == "terrain":
			var revision := String(source_revisions.get(source_id_value, ""))
			if not revision.is_empty(): actual_terrain_revisions.append(revision)
	if actual_terrain_revisions.size() != 1:
		return {"status":"pending", "reason":"support_terrain_section_revision_unavailable",
			"retryable":true, "sectionKey":section_key,
			"terrainRevisionCount":actual_terrain_revisions.size()}
	for view_owner_value: Variant in demands:
		var demand: Dictionary = demands[view_owner_value]
		if String(demand.get("kind", "")) == "ordinary_geometry_support":
			continue
		var expected := String(demand.get("terrainSourceRevision", ""))
		if expected.is_empty() or expected != actual_terrain_revisions[0]:
			demand["needsTerrainRevisionRefresh"] = true
			demands[view_owner_value] = demand
			state["supportDemands"] = demands
			_visible_section_demands[section_key] = state
			return {"status":"pending", "reason":"support_terrain_section_revision_changed",
				"retryable":true, "sectionKey":section_key,
				"expectedTerrainSourceRevision":expected,
				"actualTerrainSourceRevision":actual_terrain_revisions[0]}
	return {"status":"ready"}


func _with_candidate_phase_timings(result: Dictionary, phase_usec: Dictionary) -> Dictionary:
	var timed := result.duplicate(false)
	var frozen_phases := phase_usec.duplicate(false)
	frozen_phases.make_read_only()
	timed["phaseUsec"] = frozen_phases
	return timed


## Admit one complete cross-domain section snapshot. This path does not merge
## per-source ledger deltas: every install is the result of one whole-section
## candidate assembled from the current provider census and one shared pass.
func submit_complete_section_candidate(candidate: Dictionary) -> Dictionary:
	if _world_id.is_empty() or not candidate.is_read_only() \
			or String(candidate.get("schema", "")) != CandidateAssembler.SCHEMA \
			or String(candidate.get("worldId", "")) != _world_id:
		return _failed("invalid_complete_section_candidate")
	var section_value: Variant = candidate.get("sectionKey", null)
	var generation_value: Variant = candidate.get("generation", null)
	var envelope_value: Variant = candidate.get("candidate", null)
	var digest := String(candidate.get("contentManifestDigest", ""))
	if not section_value is Vector3i or not generation_value is int \
			or generation_value <= 0 or not envelope_value is Dictionary \
			or not envelope_value.is_read_only() or digest.length() != 64 \
			or String(envelope_value.get("contentManifestDigest", "")) != digest \
			or envelope_value.get("sectionKey") != section_value \
			or int(envelope_value.get("generation", 0)) != generation_value:
		return _failed("inconsistent_complete_section_candidate_identity")
	var census: Dictionary = _source_roster.capture_sections([section_value])
	if census.get("status") != "complete":
		return {"status":"pending", "reason":String(census.get("reason", "section_census_pending")),
			"retryable":true, "sectionKey":section_value}
	if String(census.get("censusDigest", "")) != String(candidate.get("censusDigest", "")):
		return {"status":"pending", "reason":"complete_section_candidate_census_stale",
			"retryable":true, "sectionKey":section_value}
	if not _candidate_removal_identities_match_census(candidate, census, section_value):
		return _failed("complete_section_candidate_removal_identity_mismatch")
	var section_key: Vector3i = section_value
	if _pending_source_releases.has(section_key):
		return {"status":"pending", "reason":"section_source_release_pending",
			"retryable":true, "sectionKey":section_key}
	var latest_candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	if not latest_candidate.is_empty() \
			and int(latest_candidate.get("generation", 0)) >= int(generation_value):
		return _failed("stale_complete_section_candidate_generation")
	var existing: Dictionary = _production_candidate_jobs.get(section_key, {})
	if not existing.is_empty():
		var existing_candidate: Dictionary = existing.get("candidate", {})
		if int(existing_candidate.get("generation", 0)) >= int(generation_value):
			return _failed("stale_complete_section_candidate_generation")
		var session = existing.get("session")
		if session is RefCounted and session.has_method("cancel"):
			var cancelled: Dictionary = session.cancel()
			if cancelled.get("status") != "cancelled":
				existing["stage"] = "rollback_failed"
				existing["rollbackFailure"] = cancelled.duplicate(true)
				_production_candidate_jobs[section_key] = existing
				return {"status":"rollback_failed",
					"reason":"replaced_candidate_rollback_failed",
					"sectionKey":section_key,
					"generation":int(existing_candidate.get("generation", 0)),
					"rollback":cancelled, "retryable":true}
	_production_candidate_jobs[section_key] = {"candidate":candidate,
		"session":null, "stage":"queued"}
	return {"status":"queued", "sectionKey":section_key,
		"generation":int(generation_value),
		"replacedPendingGeneration":int(existing.get("candidate", {}).get("generation", 0))}


func _candidate_removal_identities_match_census(candidate: Dictionary,
		census: Dictionary, section: Vector3i) -> bool:
	var removal_revisions: Variant = candidate.get("removalRevisions", {})
	if not removal_revisions is Dictionary \
			or (not removal_revisions.is_empty() and not removal_revisions.is_read_only()): return false
	var expected: Dictionary = {}
	for row: Dictionary in census.get("removalsBySection", {}).get(section, []):
		var identity := SourceRoster._source_part_identity_key(String(row.sourceId), String(row.sourcePartId))
		expected[identity] = {"sourceId":String(row.sourceId), "sourcePartId":String(row.sourcePartId),
			"sourceRevision":String(row.sourceRevision)}
	var supplied: Variant = candidate.get("removalSourceIdentities", {})
	if not supplied is Dictionary or supplied != expected: return false
	if not expected.is_empty() and not supplied.is_read_only(): return false
	for identity: String in supplied:
		if not supplied[identity] is Dictionary or not supplied[identity].is_read_only() \
				or candidate.get("removalRevisions", {}).get(identity) != supplied[identity].sourceRevision:
			return false
	return candidate.get("removalRevisions", {}).size() == expected.size()


## Full authority check at admission and visibility/retirement boundaries.
func _validate_production_candidate_census(section_key: Vector3i, job: Dictionary) -> Dictionary:
	var candidate: Dictionary = job.get("candidate", {})
	var census: Dictionary = _source_roster.capture_sections([section_key])
	if census.get("status") != "complete" \
			or String(census.get("censusDigest", "")) != String(candidate.get("censusDigest", "")):
		var stale_session = job.get("session")
		if stale_session is RefCounted and stale_session.has_method("cancel"):
			var stale_cancel: Dictionary = stale_session.cancel()
			if stale_cancel.get("status") != "cancelled":
				job["stage"] = "rollback_failed"
				job["rollbackFailure"] = stale_cancel.duplicate(true)
				_production_candidate_jobs[section_key] = job
				return {"status":"rollback_failed", "stage":"rollback",
					"reason":"stale_candidate_rollback_failed",
					"sectionKey":section_key,
					"generation":int(candidate.get("generation", 0)),
					"rollback":stale_cancel, "retryable":true}
		_production_candidate_jobs.erase(section_key)
		if _candidate_has_section_attachments(candidate):
			return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
				String(census.get("reason", "complete_section_candidate_census_changed")))
		var stale_result := {"status":"pending", "stage":"source_census",
			"reason":String(census.get("reason", "complete_section_candidate_census_changed")),
			"providerId":String(census.get("providerId", "")),
			"providerReason":String(census.get("providerReason", "")),
			"retryable":true, "sectionKey":section_key,
			"requiresReassembly":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), stale_result)
		return stale_result
	return {"status":"ready"}


func advance_complete_section_candidate(section_key: Vector3i,
		max_upload_units := 1) -> Dictionary:
	if max_upload_units < 1 or max_upload_units > 64:
		return _failed("invalid_complete_section_upload_budget")
	if _pending_source_releases.has(section_key):
		return {"status":"pending", "reason":"section_source_release_pending",
			"retryable":true, "sectionKey":section_key}
	var job: Dictionary = _production_candidate_jobs.get(section_key, {})
	if job.is_empty(): return {"status":"idle", "sectionKey":section_key}
	var candidate: Dictionary = job.get("candidate", {})
	var session = job.get("session")
	# Hidden preparation cannot publish or retire the old packet. Explicit source
	# invalidation still cancels this exact job; Session keeps its owner, attachment
	# and POV guards. Unknown states conservatively retain the full census check.
	var session_state := String(session.get("state")) if session != null else ""
	var census_validated_before_step := false
	if session_state not in ["append", "upload", "awaiting_frame"]:
		var admission_check := _validate_production_candidate_census(section_key, job)
		if admission_check.get("status") != "ready": return admission_check
		census_validated_before_step = true
	if session == null:
		var started: Dictionary = PacketOwner.begin_static_section_install(candidate,
			candidate.get("materialBindings", {}), candidate.get("meshBindings", {}), self)
		if started.get("status") == "pending":
			var owner_pending := {"status":"pending_owner", "reason":String(started.get("reason", "")),
				"sectionKey":section_key, "retryable":true}
			_reconcile_visible_section_candidate_outcome(section_key,
				int(candidate.get("generation", 0)), owner_pending)
			return owner_pending
		if started.get("status") != "ready":
			_production_candidate_jobs.erase(section_key)
			if bool(started.get("requiresAuthoritativeReassembly", false)):
				return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
					String(started.get("reason", "section_attachment_binding_stale")))
			var begin_failure := _failed("complete_section_candidate_install_begin_failed:" +
				String(started.get("reason", "unknown")))
			if bool(started.get("retryable", false)):
				begin_failure["retryable"] = true
			_reconcile_visible_section_candidate_outcome(section_key,
				int(candidate.get("generation", 0)), begin_failure)
			return begin_failure
		job["session"] = started.session
		job["stage"] = "installing"
		_production_candidate_jobs[section_key] = job
		session = started.session
	var pov_snapshot := current_translucent_pov_snapshot(section_key)
	var candidate_pov_revision := _candidate_translucent_pov_revision(candidate)
	var awaiting_frame_session: Variant = job.get("session")
	var candidate_awaiting_frame := awaiting_frame_session is RefCounted \
		and String(awaiting_frame_session.get("state")) == "awaiting_frame"
	if candidate_pov_revision > 0 and pov_snapshot.get("status") != "ready" \
			and not candidate_awaiting_frame:
		var pending_pov := {"status":"pending", "stage":"translucent_pov",
			"reason":String(pov_snapshot.get("reason",
				"translucent_camera_snapshot_unavailable")),
			"sectionKey":section_key,
			"generation":int(candidate.get("generation", 0)), "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), pending_pov)
		return pending_pov
	var current_pov_revision := int(pov_snapshot.get("revision", -1)) \
		if pov_snapshot.get("status") == "ready" else -1
	var step: Dictionary = session.advance(max_upload_units, current_pov_revision)
	if step.get("status") == "pending_presentation":
		job["stage"] = "awaiting_frame"
		job["presentationToken"] = String(step.get("presentationToken", ""))
		_production_candidate_jobs[section_key] = job
		if not bool(step.get("frameDrawn", false)):
			var frame_pending := {"status":"pending", "stage":"awaiting_frame",
				"reason":"section_candidate_waiting_for_frame_drawn_callback",
				"sectionKey":section_key,
				"generation":int(candidate.get("generation", 0)), "retryable":true}
			_reconcile_visible_section_candidate_outcome(section_key,
				int(candidate.get("generation", 0)), frame_pending)
			return frame_pending
		# A mutation may have happened after publication but before the actual
		# frame callback. Revalidate before finalization can retire prior roots.
		if not census_validated_before_step:
			var frame_check := _validate_production_candidate_census(section_key, job)
			if frame_check.get("status") != "ready": return frame_check
		step = session.finalize_presentation(String(step.get("presentationToken", "")))
	if step.get("status") == "pending":
		job["stage"] = String(step.get("stage", "installing"))
		_production_candidate_jobs[section_key] = job
		var install_pending := {"status":"pending", "stage":String(job.stage),
			"reason":String(step.get("reason", "")), "sectionKey":section_key,
			"generation":int(candidate.get("generation", 0)), "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), install_pending)
		return install_pending
	if step.get("status") == "rollback_failed":
		job["stage"] = "rollback_failed"
		job["rollbackFailure"] = step.duplicate(true)
		_production_candidate_jobs[section_key] = job
		var rollback_pending := {"status":"rollback_failed", "stage":"rollback",
			"reason":String(step.get("reason", "section_presentation_rollback_failed")),
			"sectionKey":section_key,
			"generation":int(candidate.get("generation", 0)),
			"rollback":step.get("rollback", {}), "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), rollback_pending)
		return rollback_pending
	if step.get("status") == "failed" and String(step.get("reason", "")) == "section_install_owner_replaced":
		if step.get("rollback", {}).get("status") != "cancelled":
			job["stage"] = "rollback_failed"
			job["rollbackFailure"] = step.duplicate(true)
			_production_candidate_jobs[section_key] = job
			return {"status":"rollback_failed", "stage":"rollback",
				"reason":"owner_replaced_without_rollback_acknowledgement",
				"sectionKey":section_key, "generation":int(candidate.get("generation", 0)),
				"rollback":step.get("rollback", {}), "retryable":true}
		job["session"] = null
		job["stage"] = "owner_replaced"
		_production_candidate_jobs[section_key] = job
		var owner_replaced := {"status":"pending_owner", "reason":String(step.reason),
			"sectionKey":section_key, "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), owner_replaced)
		return owner_replaced
	if step.get("status") == "failed" \
			and bool(step.get("requiresAuthoritativeReassembly", false)):
		# A source body/pivot is a live binding, unlike immutable geometry. A
		# replacement incarnation must be captured again even when its mesh bytes
		# happen to match. The session emits this only after abort/rollback succeeds.
		_production_candidate_jobs.erase(section_key)
		return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
			String(step.get("reason", "section_attachment_binding_stale")))
	if step.get("status") == "failed" \
			and String(step.get("reason", "")) == "section_translucent_pov_revision_stale":
		# The section slot still owns its previous installed visual. Discard this
		# camera-sorted candidate and reassemble from the provider's canonical
		# unsorted groups for the current POV class rather than blocking the demand.
		_production_candidate_jobs.erase(section_key)
		var pov_stale := {"status":"failed", "reason":String(step.reason),
			"sectionKey":section_key, "retryable":true,
			"requiresReassembly":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), pov_stale)
		return pov_stale
	if step.get("status") != "installed":
		_production_candidate_jobs.erase(section_key)
		var install_failure := _failed("complete_section_candidate_install_failed:" +
			String(step.get("reason", step.get("status", "unknown"))))
		install_failure["nativeStep"] = step.duplicate(true)
		if bool(step.get("retryable", false)):
			install_failure["retryable"] = true
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), install_failure)
		return install_failure
	var receipt: Dictionary = step.get("receipt", {})
	if receipt.get("censusDigest") != candidate.get("censusDigest") \
			or String(receipt.get("contentManifestDigest", "")) != String(candidate.get("contentManifestDigest", "")) \
			or receipt.get("status") != "installed" \
			or int(receipt.get("generation", 0)) != int(candidate.get("generation", 0)):
		_production_candidate_jobs.erase(section_key)
		var receipt_failure := _failed("complete_section_candidate_receipt_identity_mismatch")
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), receipt_failure)
		return receipt_failure
	if not _receipt_is_live(candidate, receipt):
		var stale_owner_session = job.get("session")
		if stale_owner_session is RefCounted and stale_owner_session.has_method("cancel"):
			var stale_owner_cancel: Dictionary = stale_owner_session.cancel()
			if stale_owner_cancel.get("status") != "cancelled":
				job["stage"] = "rollback_failed"
				job["rollbackFailure"] = stale_owner_cancel.duplicate(true)
				_production_candidate_jobs[section_key] = job
				return {"status":"rollback_failed", "stage":"rollback",
					"reason":"installed_candidate_owner_change_cancel_failed",
					"sectionKey":section_key,
					"generation":int(candidate.get("generation", 0)),
					"rollback":stale_owner_cancel, "retryable":true}
		job["session"] = null
		job["stage"] = "owner_replaced"
		_production_candidate_jobs[section_key] = job
		var owner_changed := {"status":"pending_owner",
			"reason":"complete_section_candidate_receipt_owner_changed",
			"sectionKey":section_key, "generation":int(candidate.get("generation", 0)),
			"retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), owner_changed)
		return owner_changed
	var previous_candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	_advance_geometry_owner_dependency_revision_for_candidate(previous_candidate)
	_advance_geometry_owner_dependency_revision_for_candidate(candidate)
	_replace_section_source_index(section_key, previous_candidate, candidate)
	# A newer generation owns the slot now. Any acknowledgement retry queued for
	# the replaced receipt is stale and must never retire source visuals.
	_pending_source_acknowledgements.erase(section_key)
	_erase_source_install_acknowledgement(section_key)
	_production_candidates_by_section[section_key] = candidate
	_production_candidate_receipts[section_key] = receipt
	_notify_geometry_owner_candidate_changed(section_key, previous_candidate, candidate)
	# Keep the unload/replay index on the same immutable snapshot as the live
	# production slot; do not leave a previously committed envelope available.
	var installed_envelope: Variant = candidate.get("candidate", null)
	if installed_envelope is Dictionary:
		_committed_candidates[section_key] = installed_envelope
		_installed_receipts[section_key] = receipt
	_dirty_source_sections.erase(section_key)
	_production_candidate_jobs.erase(section_key)
	# A replacement assembled from the current provider census owns the section
	# only after its live receipt passed above. Until then, replay/reassembly keeps
	# the old installed representation visible and retryable.
	_replay_reassembly_required_by_section.erase(section_key)
	_replay_pov_waiting_revision_by_section.erase(section_key)
	_replay_set.erase(section_key)
	_replay_queue.erase(section_key)
	var acknowledgement_receipt: Dictionary = receipt.duplicate(true)
	acknowledgement_receipt.make_read_only()
	var acknowledgement_census := capture_authoritative_source_census([section_key])
	var provider_acknowledgements: Dictionary
	if acknowledgement_census.get("status") == "complete" \
			and String(acknowledgement_census.get("censusDigest", "")) \
			== String(candidate.get("censusDigest", "")):
		provider_acknowledgements = _source_roster.acknowledge_section_install(
			section_key, candidate.get("providerCoverage", []), acknowledgement_receipt,
			acknowledgement_census)
	else:
		provider_acknowledgements = {"status":"pending", "retryable":true,
			"reason":"source_acknowledgement_census_not_current",
			"censusStatus":String(acknowledgement_census.get("status", "failed")),
			"censusReason":String(acknowledgement_census.get("reason", ""))}
	_record_source_install_acknowledgement(section_key, candidate,
		candidate.get("providerCoverage", []), acknowledgement_receipt,
		provider_acknowledgements)
	var installed_result := {"status":"installed", "sectionKey":section_key,
		"generation":int(candidate.get("generation", 0)), "receipt":receipt,
		"sourceAcknowledgements":provider_acknowledgements}
	_reconcile_visible_section_candidate_outcome(section_key,
		int(candidate.get("generation", 0)), installed_result)
	return installed_result


## Keep visible demand state aligned with candidate ownership and the native
## install receipt. Reassembly retries return to the bounded priority queue;
## retained install sessions remain scheduled as candidate_pending jobs.
func _reconcile_visible_section_candidate_outcome(section_key: Vector3i,
		candidate_generation: int, outcome: Dictionary) -> void:
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	if state.is_empty() or int(state.get("candidateGeneration", 0)) != candidate_generation:
		return
	var status := String(outcome.get("status", "failed"))
	state["lastInstallStatus"] = status
	state["lastInstallReason"] = String(outcome.get("reason", ""))
	state["lastInstallStage"] = String(outcome.get("stage", ""))
	if status == "installed":
		var receipt: Dictionary = outcome.get("receipt", {})
		if String(receipt.get("status", "")) != "installed" \
				or int(receipt.get("generation", 0)) != candidate_generation:
			state["stage"] = "blocked"
			state["blockedReason"] = "installed_candidate_receipt_identity_mismatch"
			state["lastInstallStatus"] = "failed"
			state["lastInstallReason"] = String(state.blockedReason)
			state.erase("candidateGeneration")
			_visible_section_demands[section_key] = state
			return
		state["stage"] = "installed"
		state["installedGeneration"] = candidate_generation
		state.erase("blockedReason")
		state.erase("sourceInvalidation")
		state["installedReceipt"] = {
			"censusDigest":String(receipt.get("censusDigest", "")),
			"contentManifestDigest":String(receipt.get("contentManifestDigest", "")),
			"backendInstanceId":int(receipt.get("backendInstanceId", 0)),
			"chunkInstanceId":int(receipt.get("chunkInstanceId", 0)),
			"ownerCell":receipt.get("ownerCell", Vector2i.ZERO)}
		state.erase("urgentRecompile")
		state["queued"] = false
	elif bool(outcome.get("requiresReassembly", false)) \
			or (status in ["failed", "cancelled"] and bool(outcome.get("retryable", false))):
		state.erase("candidateGeneration")
		state.erase("blockedReason")
		state["stage"] = "waiting"
		state["nextAttemptFrame"] = Engine.get_process_frames() \
			+ VISIBLE_SECTION_DEMAND_RETRY_FRAMES
		if not bool(state.get("queued", false)):
			_enqueue_visible_section_demand(section_key, state)
	elif status in ["pending", "pending_owner"]:
		state["stage"] = "candidate_pending"
		state.erase("blockedReason")
		state["pendingCandidateStage"] = String(outcome.get("stage", status))
	elif status == "rollback_failed":
		state["stage"] = "rollback_failed"
		state["blockedReason"] = String(outcome.get("reason", status))
	elif status in ["failed", "cancelled"]:
		state["stage"] = "blocked"
		state["blockedReason"] = String(outcome.get("reason", status))
		state.erase("candidateGeneration")
	_visible_section_demands[section_key] = state


## Called from the normal runtime publication loop. It advances a bounded
## number of whole-section candidates; capture and assembly stay producer-side.
func advance_queued_complete_section_candidates(max_sections := 1,
		max_upload_units := 1) -> Dictionary:
	if max_sections < 1 or max_sections > 8:
		return _failed("invalid_complete_section_scheduler_budget")
	var phase_usec: Dictionary = {}
	var phase_started_usec := Time.get_ticks_usec()
	var compile_results := _advance_section_compiles(max_sections)
	phase_usec["compileAdvance"] = Time.get_ticks_usec() - phase_started_usec
	phase_started_usec = Time.get_ticks_usec()
	var geometry_owner_completion_advance := advance_pending_geometry_owner_completions(
		MAX_GEOMETRY_OWNER_COMPLETION_ATTEMPTS_PER_ADVANCE,
		MAX_GEOMETRY_OWNER_COMPLETION_CURSOR_WORK_PER_ADVANCE,
		MAX_GEOMETRY_OWNER_COMPLETION_BUDGET_USEC_PER_ADVANCE)
	phase_usec["geometryOwnerCompletionAdvance"] = Time.get_ticks_usec() - phase_started_usec
	phase_started_usec = Time.get_ticks_usec()
	var release_results := _advance_pending_source_releases(
		MAX_PENDING_SOURCE_RELEASES_PER_ADVANCE)
	phase_usec["sourceReleaseAdvance"] = Time.get_ticks_usec() - phase_started_usec
	phase_started_usec = Time.get_ticks_usec()
	var acknowledgement_results := _advance_pending_source_acknowledgements(
		MAX_PENDING_SOURCE_ACKNOWLEDGEMENTS_PER_ADVANCE)
	phase_usec["sourceAcknowledgementAdvance"] = Time.get_ticks_usec() - phase_started_usec
	var section_keys: Array[Vector3i] = []
	for section_value: Variant in _production_candidate_jobs:
		if section_value is Vector3i:
			section_keys.append(Vector3i(section_value))
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var results: Array[Dictionary] = []
	phase_started_usec = Time.get_ticks_usec()
	for index in range(mini(max_sections, section_keys.size())):
		# A pending upload or owner must not monopolize the first lexical slot.
		# Rotate complete candidates through the bounded installation budget.
		_production_install_cursor = posmod(_production_install_cursor, section_keys.size())
		var selected_key := section_keys[_production_install_cursor]
		_production_install_cursor += 1
		results.append(advance_complete_section_candidate(selected_key, max_upload_units))
	phase_usec["sectionCandidateAdvance"] = Time.get_ticks_usec() - phase_started_usec
	results.make_read_only()
	return {"status":"advanced" if not results.is_empty() \
		or not acknowledgement_results.is_empty() or not release_results.is_empty() \
		or not compile_results.is_empty() \
		or geometry_owner_completion_advance.get("attemptCount", 0) > 0 else "idle",
		"compileResults":compile_results, "pendingCompileCount":_section_compile_jobs.size(),
		"completedCompileCount":_section_compile_completed_count,
		"geometryOwnerCompletionAdvance":geometry_owner_completion_advance,
		"sectionCount":results.size(), "results":results,
		"releaseCount":release_results.size(), "releases":release_results,
		"pendingReleaseCount":_pending_source_releases.size(),
		"acknowledgementCount":acknowledgement_results.size(),
		"acknowledgements":acknowledgement_results,
		"acknowledgementDeferred":_last_source_acknowledgement_deferrals.duplicate(true),
		"pendingAcknowledgementCount":_pending_source_acknowledgements.size(),
		"phaseUsec":phase_usec}


func _advance_pending_source_acknowledgements(max_attempts: int) -> Array[Dictionary]:
	var section_keys: Array[Vector3i] = []
	for section_value: Variant in _pending_source_acknowledgements:
		if section_value is Vector3i:
			section_keys.append(Vector3i(section_value))
	section_keys = _ordered_pending_source_acknowledgement_keys(section_keys,
		_pending_source_acknowledgement_cursor,
		_has_pending_source_acknowledgement_cursor)
	_last_source_acknowledgement_deferrals = {
		"candidateJob":0, "pendingRelease":0, "notDue":0}
	var results: Array[Dictionary] = []
	var current_frame := Engine.get_process_frames()
	for section_key: Vector3i in section_keys:
		if results.size() >= max_attempts:
			break
		# A replacement may be visible for its first acknowledged frame while the
		# previous provider receipt is retained only for rollback. Defer retries of
		# that prior receipt until the replacement either finalizes or rolls back.
		if _production_candidate_jobs.has(section_key):
			_last_source_acknowledgement_deferrals.candidateJob += 1
			continue
		if _pending_source_releases.has(section_key):
			_last_source_acknowledgement_deferrals.pendingRelease += 1
			continue
		var pending: Dictionary = _pending_source_acknowledgements.get(section_key, {})
		if pending.is_empty():
			continue
		if int(pending.get("nextAttemptFrame", 0)) > current_frame:
			_last_source_acknowledgement_deferrals.notDue += 1
			continue
		_pending_source_acknowledgement_cursor = section_key
		_has_pending_source_acknowledgement_cursor = true
		var receipt: Dictionary = pending.get("receipt", {})
		var candidate: Dictionary = pending.get("candidate", {})
		if not installed_section_receipt_is_current(section_key, receipt) \
				or int(candidate.get("generation", 0)) \
				!= int(receipt.get("generation", -1)):
			_mark_source_install_acknowledgement(section_key, receipt,
				"stale", {"status":"stale_dropped",
					"reason":"source_acknowledgement_receipt_not_current"},
				int(pending.get("attempts", 0)), -1)
			_pending_source_acknowledgements.erase(section_key)
			results.append({"sectionKey":section_key, "status":"stale_dropped",
				"generation":int(receipt.get("generation", 0))})
			continue
		# A live native slot proves installation, not that its producer owners
		# still match. Revalidate even when semantic source geometry is unchanged.
		var census: Dictionary = _source_roster.capture_sections([section_key])
		if census.get("status") != "complete":
			var census_provider_phases: Dictionary = census.get("providerPhaseUsec", {})
			var census_retry_frame := current_frame + SOURCE_ACK_RETRY_BASE_FRAMES
			pending["nextAttemptFrame"] = census_retry_frame
			_pending_source_acknowledgements[section_key] = pending
			_mark_source_install_acknowledgement(section_key, receipt,
				"pending", {"status":"pending",
					"reason":"source_acknowledgement_census_pending",
					"censusStatus":census.get("status", "failed"),
					"censusReason":census.get("reason", "")},
				int(pending.get("attempts", 0)), census_retry_frame)
			results.append({"sectionKey":section_key, "status":"pending",
				"reason":"source_acknowledgement_census_pending", "retryable":true,
				"censusStatus":census.get("status", "failed"),
				"censusReason":census.get("reason", ""),
				"censusProviderPhaseUsec":census_provider_phases})
			continue
		if String(census.get("censusDigest", "")) != String(candidate.get("censusDigest", "")):
			_mark_source_install_acknowledgement(section_key, receipt,
				"stale", {"status":"stale_dropped",
					"reason":"source_acknowledgement_census_changed"},
				int(pending.get("attempts", 0)), -1)
			_pending_source_acknowledgements.erase(section_key)
			var reassembly := _defer_stale_replay_to_authoritative_reassembly(
				section_key, _candidate_translucent_pov_revision(candidate))
			results.append({"sectionKey":section_key, "status":"stale_dropped",
				"reason":"source_acknowledgement_census_changed",
				"generation":int(receipt.get("generation", 0)),
				"reassembly":reassembly})
			continue
		var retried: Dictionary = _source_roster.acknowledge_section_install(
			section_key, pending.get("providerCoverage", []), receipt, census)
		var census_provider_phases: Dictionary = census.get("providerPhaseUsec", {})
		var attempts := int(pending.get("attempts", 0)) + 1
		if retried.get("status") == "acknowledged":
			_mark_source_install_acknowledgement(section_key, receipt,
				"acknowledged", retried, attempts, -1)
			_pending_source_acknowledgements.erase(section_key)
			results.append({"sectionKey":section_key, "status":"acknowledged",
				"generation":int(receipt.get("generation", 0)),
				"attempt":attempts, "providerAcknowledgements":retried,
				"censusProviderPhaseUsec":census_provider_phases})
			continue
		var retry_exponent := mini(attempts - 1, 6)
		var retry_delay := 1 if String(retried.get("reason", "")) == \
			"citadel_section_ack_source_slice_pending" else mini(SOURCE_ACK_RETRY_MAX_FRAMES,
			SOURCE_ACK_RETRY_BASE_FRAMES << retry_exponent)
		var retry_frame := current_frame + retry_delay
		pending["attempts"] = attempts
		pending["nextAttemptFrame"] = retry_frame
		pending["lastResult"] = retried
		_pending_source_acknowledgements[section_key] = pending
		var unsettled_status := "pending" if retried.get("status") == "pending" else "failed"
		_mark_source_install_acknowledgement(section_key, receipt,
			unsettled_status, retried, attempts, retry_frame)
		results.append({"sectionKey":section_key, "status":unsettled_status,
			"generation":int(receipt.get("generation", 0)),
			"attempt":attempts, "nextAttemptFrame":int(pending.nextAttemptFrame),
			"providerAcknowledgements":retried,
			"censusProviderPhaseUsec":census_provider_phases})
	results.make_read_only()
	return results


static func _ordered_pending_source_acknowledgement_keys(
		section_keys: Array[Vector3i], cursor: Vector3i,
		has_cursor: bool) -> Array[Vector3i]:
	var ordered := section_keys.duplicate()
	ordered.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	if ordered.size() < 2 or not has_cursor:
		return ordered
	var start_index := 0
	for index in range(ordered.size()):
		var key: Vector3i = ordered[index]
		if key.x > cursor.x or (key.x == cursor.x and key.y > cursor.y) \
				or (key.x == cursor.x and key.y == cursor.y and key.z > cursor.z):
			start_index = index
			break
	var rotated: Array[Vector3i] = []
	for offset in range(ordered.size()):
		rotated.append(ordered[(start_index + offset) % ordered.size()])
	return rotated


func _record_source_install_acknowledgement(section_key: Vector3i,
		candidate: Dictionary, provider_coverage: Array, receipt: Dictionary,
		provider_result: Dictionary) -> void:
	var result_status := String(provider_result.get("status", "failed"))
	var retained_result: Dictionary = _source_acknowledgement_readonly_copy(provider_result)
	var next_attempt_frame := Engine.get_process_frames() + SOURCE_ACK_RETRY_BASE_FRAMES
	var settlement := {
		"status":result_status,
		"candidate":candidate,
		"providerCoverage":provider_coverage,
		"receipt":receipt,
		"attempts":0,
		"nextAttemptFrame":next_attempt_frame if result_status != "acknowledged" else -1,
		"lastResult":retained_result,
		"reason":String(retained_result.get("reason", ""))}
	_set_source_install_acknowledgement(section_key, settlement)
	if result_status == "acknowledged":
		_pending_source_acknowledgements.erase(section_key)
		return
	_pending_source_acknowledgements[section_key] = settlement.duplicate(false)


func _mark_source_install_acknowledgement(section_key: Vector3i,
		receipt: Dictionary, status_value: String, result: Dictionary,
		attempts: int, next_attempt_frame: int) -> void:
	var current_settlement: Dictionary = _source_install_acknowledgements_by_section.get(
		section_key, {})
	if current_settlement.is_empty() or not _source_ack_receipt_identity_matches(
		current_settlement.get("receipt", {}), receipt):
		return
	var settlement := current_settlement.duplicate(false)
	settlement["status"] = status_value
	settlement["attempts"] = attempts
	settlement["nextAttemptFrame"] = next_attempt_frame
	var retained_result: Dictionary = _source_acknowledgement_readonly_copy(result)
	settlement["lastResult"] = retained_result
	settlement["reason"] = String(retained_result.get("reason", ""))
	_set_source_install_acknowledgement(section_key, settlement)


static func _source_acknowledgement_readonly_copy(value: Variant) -> Dictionary:
	var copied: Dictionary = _copy_and_freeze_source_acknowledgement_value(value)
	return copied


static func _copy_and_freeze_source_acknowledgement_value(value: Variant) -> Variant:
	if value is Dictionary:
		var copied: Dictionary = {}
		for key_value: Variant in value:
			copied[key_value] = _copy_and_freeze_source_acknowledgement_value(
				value[key_value])
		copied.make_read_only()
		return copied
	if value is Array:
		var copied: Array = []
		for nested_value: Variant in value:
			copied.append(_copy_and_freeze_source_acknowledgement_value(nested_value))
		copied.make_read_only()
		return copied
	return value


func _set_source_install_acknowledgement(section_key: Vector3i,
		settlement: Dictionary) -> void:
	var previous: Dictionary = _source_install_acknowledgements_by_section.get(
		section_key, {})
	if not previous.is_empty():
		var previous_status := String(previous.get("status", "failed"))
		_source_install_acknowledgement_counts[previous_status] = maxi(0,
			int(_source_install_acknowledgement_counts.get(previous_status, 0)) - 1)
	_source_install_acknowledgements_by_section[section_key] = settlement
	var next_status := String(settlement.get("status", "failed"))
	_source_install_acknowledgement_counts[next_status] = int(
		_source_install_acknowledgement_counts.get(next_status, 0)) + 1


func _erase_source_install_acknowledgement(section_key: Vector3i) -> void:
	var previous: Dictionary = _source_install_acknowledgements_by_section.get(
		section_key, {})
	if previous.is_empty():
		return
	var previous_status := String(previous.get("status", "failed"))
	_source_install_acknowledgement_counts[previous_status] = maxi(0,
		int(_source_install_acknowledgement_counts.get(previous_status, 0)) - 1)
	_source_install_acknowledgements_by_section.erase(section_key)


static func _source_ack_receipt_identity_matches(a_value: Variant,
		b_value: Variant) -> bool:
	if not a_value is Dictionary or not b_value is Dictionary:
		return false
	var a: Dictionary = a_value
	var b: Dictionary = b_value
	for key: String in ["status", "worldId", "sectionKey", "generation",
			"censusDigest", "contentManifestDigest", "sourceRevision",
			"translucentPovRevision", "backendInstanceId", "chunkInstanceId", "ownerCell"]:
		if a.get(key) != b.get(key):
			return false
	return true


func _queue_source_install_release(section_key: Vector3i,
		candidate: Dictionary, receipt: Dictionary, release_result: Dictionary,
		owner_cell: Vector2i, chunk_instance_id: int) -> Dictionary:
	if release_result.get("status") == "acknowledged":
		_complete_source_install_release(section_key, receipt, candidate, false)
		return {"status":"acknowledged", "sectionKey":section_key,
			"generation":int(receipt.get("generation", 0)),
			"providerReleases":release_result}
	var pending: Dictionary = _pending_source_releases.get(section_key, {})
	if not pending.is_empty():
		if not _release_receipt_identity_matches(pending.get("receipt", {}), receipt):
			return {"status":"pending", "reason":"different_section_release_already_pending",
				"retryable":true, "sectionKey":section_key}
		pending["lastResult"] = release_result
		_pending_source_releases[section_key] = pending
		return {"status":"pending", "sectionKey":section_key,
			"generation":int(receipt.get("generation", 0)),
			"providerReleases":release_result}
	# One exact release record is retained per still-installed section receipt.
	# This map is bounded by the coordinator's retained section slots; attempts
	# are separately budgeted to one provider release per normal update.
	var next_attempt_frame := Engine.get_process_frames() + SOURCE_ACK_RETRY_BASE_FRAMES
	_pending_source_releases[section_key] = {
		"candidate":candidate, "providerCoverage":candidate.get("providerCoverage", []),
		"receipt":receipt, "ownerCell":owner_cell,
		"chunkInstanceId":chunk_instance_id, "reloadPending":false,
		"attempts":0, "nextAttemptFrame":next_attempt_frame,
		"lastResult":release_result}
	if not _pending_source_release_queue_index.has(section_key):
		var queue_index := -1
		if not _pending_source_release_free_slots.is_empty():
			queue_index = _pending_source_release_free_slots.pop_back()
		else:
			queue_index = _pending_source_release_order.size()
			_pending_source_release_order.append({})
		_pending_source_release_order[queue_index] = {"sectionKey":section_key}
		_pending_source_release_queue_index[section_key] = queue_index
	return {"status":"pending", "sectionKey":section_key,
		"generation":int(receipt.get("generation", 0)),
		"providerReleases":release_result,
		"nextAttemptFrame":next_attempt_frame}


func _advance_pending_source_releases(max_attempts: int) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var current_frame := Engine.get_process_frames()
	var scanned := 0
	while scanned < MAX_PENDING_SOURCE_RELEASE_SCAN_PER_ADVANCE \
			and results.size() < max_attempts \
			and not _pending_source_release_order.is_empty():
		if _pending_source_release_cursor >= _pending_source_release_order.size():
			_pending_source_release_cursor = 0
		var queue_row: Dictionary = _pending_source_release_order[
			_pending_source_release_cursor]
		_pending_source_release_cursor += 1
		scanned += 1
		var section_value: Variant = queue_row.get("sectionKey", null)
		if not section_value is Vector3i:
			continue
		var section_key := Vector3i(section_value)
		if not _pending_source_releases.has(section_key):
			continue
		if results.size() >= max_attempts:
			break
		var pending: Dictionary = _pending_source_releases.get(section_key, {})
		if pending.is_empty() or int(pending.get("nextAttemptFrame", 0)) > current_frame:
			continue
		var receipt: Dictionary = pending.get("receipt", {})
		var candidate: Dictionary = pending.get("candidate", {})
		if not _release_receipt_identity_matches(
			_production_candidate_receipts.get(section_key, {}), receipt):
			# Never release an unrelated/newer receipt. Keep the old token visible in
			# diagnostics and block replacement until its owning provider can settle.
			pending["lastResult"] = {"status":"failed",
				"reason":"pending_release_receipt_identity_changed"}
			pending["nextAttemptFrame"] = current_frame + SOURCE_ACK_RETRY_MAX_FRAMES
			_pending_source_releases[section_key] = pending
			results.append({"sectionKey":section_key, "status":"blocked",
				"reason":"pending_release_receipt_identity_changed",
				"generation":int(receipt.get("generation", 0))})
			continue
		var released: Dictionary = _source_roster.release_section_install(section_key,
			pending.get("providerCoverage", []), receipt)
		var attempts := int(pending.get("attempts", 0)) + 1
		if released.get("status") == "acknowledged":
			var reload_pending := bool(pending.get("reloadPending", false))
			_pending_source_releases.erase(section_key)
			_remove_source_release_queue_entry(section_key)
			_complete_source_install_release(section_key, receipt, candidate, reload_pending)
			results.append({"sectionKey":section_key, "status":"released",
				"generation":int(receipt.get("generation", 0)),
				"attempt":attempts, "reloadPending":reload_pending,
				"providerReleases":released})
			continue
		var retry_exponent := mini(attempts - 1, 6)
		var retry_delay := mini(SOURCE_ACK_RETRY_MAX_FRAMES,
			SOURCE_ACK_RETRY_BASE_FRAMES << retry_exponent)
		pending["attempts"] = attempts
		pending["nextAttemptFrame"] = current_frame + retry_delay
		pending["lastResult"] = released
		_pending_source_releases[section_key] = pending
		results.append({"sectionKey":section_key, "status":"pending",
			"generation":int(receipt.get("generation", 0)),
			"attempt":attempts, "nextAttemptFrame":int(pending.nextAttemptFrame),
			"providerReleases":released})
	if _pending_source_releases.is_empty():
		_pending_source_release_order.clear()
		_pending_source_release_queue_index.clear()
		_pending_source_release_free_slots.clear()
		_pending_source_release_cursor = 0
	results.make_read_only()
	return results


func _remove_source_release_queue_entry(section_key: Vector3i) -> void:
	var index_value: Variant = _pending_source_release_queue_index.get(section_key, null)
	if not index_value is int:
		return
	var queue_index := int(index_value)
	if queue_index < 0 or queue_index >= _pending_source_release_order.size():
		_pending_source_release_queue_index.erase(section_key)
		return
	var queue_row: Dictionary = _pending_source_release_order[queue_index]
	if queue_row.get("sectionKey") == section_key:
		_pending_source_release_order[queue_index] = {}
		_pending_source_release_free_slots.append(queue_index)
	_pending_source_release_queue_index.erase(section_key)


func _complete_source_install_release(section_key: Vector3i, receipt: Dictionary,
		candidate: Dictionary, queue_replay: bool) -> void:
	if not _release_receipt_identity_matches(
		_production_candidate_receipts.get(section_key, {}), receipt):
		return
	_installed_receipts.erase(section_key)
	_production_candidate_receipts.erase(section_key)
	_advance_geometry_owner_dependency_revision_for_candidate(candidate)
	_notify_geometry_owner_candidate_changed(section_key, candidate, {})
	_pending_source_acknowledgements.erase(section_key)
	_erase_source_install_acknowledgement(section_key)
	_untrack_translucent_visible_section(section_key)
	if queue_replay and not _dirty_source_sections.has(section_key) \
			and not _replay_reassembly_required_by_section.has(section_key) \
			and not _production_candidate_jobs.has(section_key):
		var current_candidate: Dictionary = _production_candidates_by_section.get(
			section_key, candidate)
		if not current_candidate.is_empty():
			_production_candidate_jobs[section_key] = {
				"candidate":current_candidate, "session":null,
				"stage":"unload_replay"}


static func _release_receipt_identity_matches(a_value: Variant, b_value: Variant) -> bool:
	if not a_value is Dictionary or not b_value is Dictionary:
		return false
	var a: Dictionary = a_value
	var b: Dictionary = b_value
	for key: String in ["worldId", "sectionKey", "generation", "contentManifestDigest",
			"ownerCell", "backendInstanceId", "chunkInstanceId"]:
		if a.get(key) != b.get(key):
			return false
	return true


## Production admission path: recapture the complete authority roster on every
## frame of a staged install, and abort the old boundary if provider owner,
## authority revision, or exact membership changes mid-install.
func advance_boundary_from_roster(section_keys: Array,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		max_upload_units := 1) -> Dictionary:
	if section_keys.size() != 1:
		return _failed("roster_boundary_requires_single_section_until_atomic_promotion")
	var census: Dictionary = _source_roster.capture_sections(section_keys)
	if census.get("status") != "complete":
		var active_boundary_id := String(_active_boundary.get("boundaryId", ""))
		if not active_boundary_id.is_empty() and _census_digest_by_boundary.has(active_boundary_id):
			var cancelled := cancel_boundary(active_boundary_id)
			return {"status":"failed", "stage":"source_census",
				"reason":String(census.get("reason", "source_census_unavailable")),
				"providerId":String(census.get("providerId", "")),
				"retryable":bool(census.get("retryable", false)),
				"boundaryId":active_boundary_id,
				"cancelled":cancelled.get("status") == "cancelled",
				"requiresResubmit":true}
		return {"status":String(census.get("status", "failed")),
			"stage":"source_census", "reason":String(census.get("reason", "source_census_unavailable")),
			"retryable":bool(census.get("retryable", false)),
			"providerId":String(census.get("providerId", ""))}
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	if boundary_id.is_empty() and not _boundary_queue.is_empty():
		boundary_id = String(_boundary_queue[0].get("boundaryId", ""))
	if boundary_id.is_empty():
		return {"status":"idle", "worldId":_world_id}
	var census_digest := String(census.get("censusDigest", ""))
	var previous_digest := String(_census_digest_by_boundary.get(boundary_id, ""))
	if not previous_digest.is_empty() and previous_digest != census_digest:
		cancel_boundary(boundary_id)
		_census_digest_by_boundary.erase(boundary_id)
		return {"status":"failed", "stage":"source_census",
			"reason":"authoritative_source_census_changed_during_boundary",
			"boundaryId":boundary_id, "retryable":false, "requiresResubmit":true}
	_census_digest_by_boundary[boundary_id] = census_digest
	var current_source_revisions: Dictionary = census.sourceRevisions.duplicate(false)
	var removal_revisions: Variant = census.get("removalRevisions", {})
	if not removal_revisions is Dictionary:
		return _failed("invalid_roster_removal_revision_map")
	for identity_key_value: Variant in removal_revisions:
		var identity_key := String(identity_key_value)
		if not _valid_source_part_identity_key(identity_key) \
				or not removal_revisions[identity_key_value] is String \
				or String(removal_revisions[identity_key_value]).is_empty() \
				or (current_source_revisions.has(identity_key) \
					and String(current_source_revisions[identity_key]) != String(removal_revisions[identity_key_value])):
			return _failed("invalid_or_current_roster_removal_revision:" + identity_key)
		current_source_revisions[identity_key] = String(removal_revisions[identity_key_value])
	current_source_revisions.make_read_only()
	var result: Dictionary = advance_boundary(
		current_source_revisions, census.expectedContributorsBySection,
		material_bindings, mesh_bindings, max_upload_units)
	result["censusDigest"] = census_digest
	if String(result.get("status", "")) in ["committed", "failed", "cancelled"]:
		_census_digest_by_boundary.erase(boundary_id)
	return result


## session and removed this coordinator's installed section slots from the old
## world. The coordinator cannot retire renderer resources on the caller's
## behalf. This is a world-lifetime boundary, not an in-place seed mutation.
func reset_for_world(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_world_identity")
	if not _active_boundary.is_empty() or not _boundary_queue.is_empty() \
			or not _active_replay.is_empty() or not _replay_queue.is_empty() \
			or not _section_compile_jobs.is_empty() \
			or not _pending_frame_presentations.is_empty() \
			or not _production_candidate_jobs.is_empty() \
			or not _installed_receipts.is_empty() \
			or not _production_candidate_receipts.is_empty() \
			or not _pending_source_acknowledgements.is_empty() \
			or not _pending_source_releases.is_empty() \
			or not _visible_section_demands.is_empty():
		return _failed("world_reset_has_pending_section_work")
	_world_id = world_id
	_ledger = LedgerScript.new()
	_source_roster = SourceRoster.new()
	_generation = 0
	_production_candidate_generation = 0
	if _section_compile_dispatcher != null:
		_section_compile_dispatcher.call("drain_section_compiles")
	_section_compile_dispatcher = null
	_section_compile_order.clear()
	_section_compile_accepting = true
	_section_compile_completed_count = 0
	_translucent_camera_position = Vector3.ZERO
	_has_translucent_camera_snapshot = false
	_committed_candidates.clear()
	_installed_receipts.clear()
	_production_candidates_by_section.clear()
	_production_candidate_jobs.clear()
	_production_install_cursor = 0
	_production_candidate_receipts.clear()
	_visible_section_keys_by_source_id.clear()
	_geometry_owner_completion_sessions.clear()
	_geometry_owner_completion_session_key_by_source.clear()
	_geometry_owner_completion_requests.clear()
	_geometry_owner_completion_request_queue.clear()
	_geometry_owner_completion_request_key_by_source.clear()
	_geometry_owner_dependency_revision_by_source.clear()
	_geometry_owner_visible_membership_revision_by_source.clear()
	_geometry_owner_completion_reset_count_by_key.clear()
	_pending_source_acknowledgements.clear()
	_pending_source_acknowledgement_cursor = Vector3i.ZERO
	_has_pending_source_acknowledgement_cursor = false
	_last_source_acknowledgement_deferrals.clear()
	_source_install_acknowledgements_by_section.clear()
	_source_install_acknowledgement_counts = {
		"pending":0, "failed":0, "acknowledged":0, "stale":0}
	_pending_source_releases.clear()
	_pending_source_release_order.clear()
	_pending_source_release_queue_index.clear()
	_pending_source_release_free_slots.clear()
	_pending_source_release_cursor = 0
	_translucent_visible_sections.clear()
	_translucent_visible_section_set.clear()
	_translucent_visible_scan_cursor = 0
	_replay_pov_waiting_revision_by_section.clear()
	_replay_reassembly_required_by_section.clear()
	_visible_sections_by_source_id.clear()
	_dirty_source_sections.clear()
	_visible_section_demands.clear()
	_ordinary_geometry_owner_support_demands.clear()
	_geometry_owner_lease_claims.clear()
	_geometry_completion_providers.clear()
	_visible_section_demand_queue.clear()
	_visible_section_demand_head = 0
	_visible_section_demand_tail = 0
	_visible_section_demand_count = 0
	_visible_section_demand_queue_token = 0
	_visible_section_demand_attempts = 0
	_visible_section_recompile_quota = 2
	_visible_section_demand_wake_rounds = 0
	_replay_set.clear()
	_census_digest_by_boundary.clear()
	return {"status":"ready", "worldId":_world_id}


## Queue one producer's immutable source delta. Declarations replace complete
## source-part contents; removals create tombstones for exact committed parts.
## Source IDs must already be globally unique within this world (for example,
## site-qualified for generated buildings).
func enqueue_boundary(boundary_id: String, declarations: Array, removals: Array) -> Dictionary:
	if _world_id.is_empty() or boundary_id.strip_edges().is_empty() \
			or not declarations.is_read_only() or not removals.is_read_only():
		return _failed("invalid_world_section_boundary")
	if _has_boundary_id(boundary_id):
		return _failed("duplicate_world_section_boundary_id")
	if declarations.is_empty() and removals.is_empty():
		return _failed("empty_world_section_boundary")
	var request := {"boundaryId":boundary_id, "declarations":declarations,
		"removals":removals, "segments":[], "phase":"queued"}
	_boundary_queue.append(request)
	return {"status":"queued", "boundaryId":boundary_id,
		"queueDepth":_boundary_queue.size() + (1 if not _active_boundary.is_empty() else 0)}


## Prepared data remains value-only while waiting behind another producer.
func submit_prepared_segment(boundary_id: String, segment: Dictionary) -> Dictionary:
	if not segment.is_read_only() or String(boundary_id).is_empty():
		return _failed("mutable_or_invalid_queued_segment")
	if not _active_boundary.is_empty() \
			and String(_active_boundary.get("boundaryId", "")) == boundary_id:
		if String(_active_boundary.get("phase", "")) != "collecting":
			return _failed("boundary_no_longer_accepts_segments")
		var admitted: Dictionary = _ledger.accept_prepared_segment(boundary_id, segment)
		return admitted
	for request: Dictionary in _boundary_queue:
		if String(request.boundaryId) == boundary_id:
			(request.segments as Array).append(segment)
			return {"status":"queued", "boundaryId":boundary_id,
				"acceptedSegmentId":String(segment.get("segmentId", ""))}
	return _failed("boundary_not_queued")


## Queued work can be removed at any time. Active work can be cancelled while
## it is collecting or staging; the native install session retains the prior
## slot until commit. A slot commit and ledger promotion occur in one call, so
## there is no externally cancellable half-promoted state.
func cancel_boundary(boundary_id: String) -> Dictionary:
	if String(_active_boundary.get("boundaryId", "")) == boundary_id:
		var cancelled := _cancel_active_boundary("explicit_cancel")
		if cancelled.get("status") != "cancelled":
			return cancelled
		_ledger.abort_boundary(boundary_id)
		_census_digest_by_boundary.erase(boundary_id)
		return {"status":"cancelled", "boundaryId":boundary_id}
	for index in range(_boundary_queue.size()):
		if String(_boundary_queue[index].get("boundaryId", "")) == boundary_id:
			_boundary_queue.remove_at(index)
			_census_digest_by_boundary.erase(boundary_id)
			return {"status":"cancelled", "boundaryId":boundary_id}
	return _failed("boundary_not_pending")


## Install all impacted section replacements for the active boundary. Maps must
## be fresh authoritative snapshots on every call:
## - current_source_revisions: canonical (sourceId, sourcePartId) -> current revision, including the
##   boundary's removal tombstone revisions until that boundary is accepted;
## - expected_contributors_by_section: sectionKey -> exact sorted or unsorted
##   Array[String] of canonical (sourceId, sourcePartId) contributor identities expected in that section.
## Resource maps bind the immutable compatibility keys to live Godot resources.
func advance_boundary(current_source_revisions: Dictionary,
		expected_contributors_by_section: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		max_upload_units := 1) -> Dictionary:
	if _world_id.is_empty():
		return _failed("world_static_section_coordinator_unconfigured")
	if max_upload_units < 1 or max_upload_units > 64:
		return _failed("invalid_section_upload_budget")
	if not _valid_revision_map(current_source_revisions) \
			or not _valid_census_map(expected_contributors_by_section) \
			or not material_bindings.is_read_only() or not mesh_bindings.is_read_only():
		return _failed("mutable_or_invalid_section_advance_inputs")
	if _active_boundary.is_empty():
		if _boundary_queue.is_empty():
			return {"status":"idle", "worldId":_world_id}
		var activation: Dictionary = _activate_next_boundary()
		if activation.get("status") != "ready":
			return activation
	var boundary_id := String(_active_boundary.boundaryId)
	if _active_boundary.phase == "collecting":
		var changed_revisions := _changed_revision_snapshot(
			_active_boundary, current_source_revisions)
		if changed_revisions.get("status") != "ready":
			return _abort_active(String(changed_revisions.get("reason", "stale_source_revision")))
		_generation += 1
		var prepared: Dictionary = _ledger.prepare_boundary(boundary_id,
			changed_revisions.revisions, _world_id, _generation)
		if prepared.get("status") != "prepared":
			if String(prepared.get("reason", "")) in ["boundary_incomplete", "boundary_candidate_already_prepared"]:
				return {"status":"pending", "stage":"prepared_segments",
					"reason":String(prepared.get("reason", "")), "boundaryId":boundary_id}
			return _abort_active(String(prepared.get("reason", "section_candidate_prepare_failed")))
		var census_check := _validate_candidate_census(prepared.replacements,
			expected_contributors_by_section, current_source_revisions)
		if census_check.get("status") != "ready":
			return _abort_active(String(census_check.get("reason", "section_source_census_mismatch")))
		if prepared.replacements.is_empty():
			return _abort_active("boundary_has_no_impacted_sections")
		_active_boundary["candidate"] = prepared
		_active_boundary["changedRevisions"] = changed_revisions.revisions
		_active_boundary["census"] = _copy_census_for_replacements(
			prepared.replacements, expected_contributors_by_section)
		_active_boundary["phase"] = "installing"
		_active_boundary["replacementIndex"] = 0
		_active_boundary["receipts"] = {}
		_active_boundary["installSession"] = null
		return {"status":"pending", "stage":"section_install",
			"boundaryId":boundary_id, "sectionCount":prepared.replacements.size(),
			"generation":prepared.generation}

	var candidate: Dictionary = _active_boundary.candidate
	var attachment_sections: Array[Vector3i] = []
	for replacement_value: Variant in candidate.get("replacements", []):
		if replacement_value is Dictionary and _candidate_has_section_attachments(replacement_value):
			attachment_sections.append(replacement_value.sectionKey)
	if not attachment_sections.is_empty():
		# The legacy ledger stores geometry only. Do not start installing any of
		# this boundary's replacements without current producer binding context.
		var abandoned := _unsupported_active("section_attachments_require_production_candidate")
		if abandoned.get("status") != "unsupported": return abandoned
		var recaptures: Array[Dictionary] = []
		for section_key: Vector3i in attachment_sections:
			recaptures.append(_defer_stale_replay_to_authoritative_reassembly(section_key, -1,
				"section_attachments_require_production_candidate"))
		return {"status":"pending", "stage":"authoritative_reassembly",
			"reason":"section_attachments_require_production_candidate",
			"requiresAuthoritativeReassembly":true, "requiresResubmit":true,
			"boundaryId":boundary_id, "sections":recaptures, "retryable":true}
	var live_check := _validate_candidate_census(candidate.replacements,
		expected_contributors_by_section, current_source_revisions)
	if live_check.get("status") != "ready":
		return _abort_active(String(live_check.get("reason", "stale_section_source_census")))
	var replacements: Array = candidate.replacements
	var replacement_index := int(_active_boundary.replacementIndex)
	if replacement_index < replacements.size():
		var replacement: Dictionary = replacements[replacement_index]
		var section_key: Vector3i = replacement.sectionKey
		var existing_receipt: Dictionary = _active_boundary.receipts.get(section_key, {})
		if not existing_receipt.is_empty() and _receipt_is_live(replacement, existing_receipt):
			_active_boundary.replacementIndex = replacement_index + 1
			return _promote_active_boundary(current_source_revisions,
				expected_contributors_by_section)
		var session = _active_boundary.get("installSession")
		if session == null:
			var started: Dictionary = PacketOwner.begin_static_section_install(
				replacement, material_bindings, mesh_bindings, self)
			if started.get("status") == "pending":
				return {"status":"pending_owner", "reason":started.get("reason", ""),
					"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
			if started.get("status") != "ready":
				if String(started.get("reason", "")) == "section_residency_dependency_not_pinned":
					return _unsupported_active(String(started.reason))
				return _abort_active(String(started.get("reason", "section_install_begin_failed")))
			_active_boundary.installSession = started.session
			session = started.session
		var pov_state := _current_translucent_pov_revision_for_candidate(
			replacement, section_key)
		if pov_state.get("status") != "ready":
			if String(session.get("state")) == "awaiting_frame":
				var unavailable_pov_step: Dictionary = session.advance(max_upload_units, -1)
				if unavailable_pov_step.get("status") == "rollback_failed":
					_active_boundary["stage"] = "rollback_failed"
					_active_boundary["rollbackFailure"] = unavailable_pov_step.duplicate(true)
					return {"status":"rollback_failed", "stage":"rollback",
						"boundaryId":boundary_id, "sectionKey":section_key,
						"reason":String(unavailable_pov_step.get("reason", "")),
						"rollback":unavailable_pov_step.get("rollback", {}),
						"retryable":true}
				if unavailable_pov_step.get("status") == "failed" \
						and String(unavailable_pov_step.get("reason", "")) \
							== "section_translucent_pov_revision_stale":
					var pov_abort := _abort_active("section_translucent_pov_revision_stale")
					pov_abort["requiresResubmit"] = true
					pov_abort["sectionKey"] = section_key
					return pov_abort
			return {"status":"pending", "stage":"translucent_pov",
				"reason":String(pov_state.get("reason", "translucent_camera_snapshot_unavailable")),
				"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
		var step: Dictionary = session.advance(max_upload_units,
			int(pov_state.get("revision", -1)))
		if step.get("status") == "pending_presentation":
			if not bool(step.get("frameDrawn", false)):
				return {"status":"pending", "stage":"awaiting_frame",
					"reason":"section_candidate_waiting_for_frame_drawn_callback",
					"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
			step = session.finalize_presentation(
				String(step.get("presentationToken", "")))
		if step.get("status") == "pending":
			return {"status":"pending", "stage":String(step.get("stage", "section_install")),
				"reason":String(step.get("reason", "")), "boundaryId":boundary_id,
				"sectionKey":section_key, "retryable":true}
		if step.get("status") != "installed":
			var reason := String(step.get("reason", "section_install_failed"))
			if reason == "section_install_owner_replaced":
				if step.get("rollback", {}).get("status") != "cancelled":
					_active_boundary["stage"] = "rollback_failed"
					_active_boundary["rollbackFailure"] = step.duplicate(true)
					return {"status":"rollback_failed", "stage":"rollback",
						"reason":"owner_replaced_without_rollback_acknowledgement",
						"boundaryId":boundary_id, "sectionKey":section_key,
						"rollback":step.get("rollback", {}), "retryable":true}
				_active_boundary.installSession = null
				return {"status":"pending_owner", "reason":reason,
					"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
			if reason == "section_translucent_pov_revision_stale":
				var stale_pov := _abort_active(reason)
				stale_pov["requiresResubmit"] = true
				stale_pov["sectionKey"] = section_key
				return stale_pov
			return _abort_active(reason)
		var receipt: Dictionary = step.get("receipt", {})
		if not _receipt_is_live(replacement, receipt):
			_active_boundary.installSession = null
			return {"status":"pending_owner", "reason":"section_receipt_owner_changed",
				"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
		_active_boundary.receipts[section_key] = receipt
		_active_boundary.installSession = null
		_active_boundary.replacementIndex = replacement_index + 1
		return _promote_active_boundary(current_source_revisions,
			expected_contributors_by_section)

	return _promote_active_boundary(current_source_revisions,
		expected_contributors_by_section)


## A stream-owner unload retires renderer receipts only. It never removes the
## corresponding contributors from the world ledger. Owner recreation queues
## explicit rebuilds, including empty compiled sections.
func notify_stream_chunk_unloaded(owner_cell: Vector2i, chunk_instance_id := 0) -> int:
	var install_drain := _cancel_install_sessions_before_owner_retirement(
		owner_cell, chunk_instance_id)
	if install_drain.get("status") != "ready": return 0
	var queued := 0
	for section_value: Variant in _section_compile_jobs.keys():
		if not section_value is Vector3i \
				or SectionGrid.chunk_key_for_section(section_value) != owner_cell:
			continue
		var generation := int(_section_compile_jobs[section_value].get("generation", 0))
		_cancel_section_compile(section_value)
		_reconcile_visible_section_candidate_outcome(section_value, generation, {
			"status":"cancelled", "reason":"section_compile_owner_unloaded",
			"requiresReassembly":true, "retryable":true})
		queued += 1
	for section_value: Variant in _committed_candidates:
		var section_key: Vector3i = section_value
		if _production_candidates_by_section.has(section_key) \
				or SectionGrid.chunk_key_for_section(section_key) != owner_cell:
			continue
		var receipt: Dictionary = _installed_receipts.get(section_key, {})
		if chunk_instance_id > 0 and int(receipt.get("chunkInstanceId", 0)) not in [0, chunk_instance_id]:
			continue
		_installed_receipts.erase(section_key)
		if not _dirty_source_sections.has(section_key):
			_queue_replay(section_key)
			queued += 1
	for section_value: Variant in _production_candidates_by_section:
		if not section_value is Vector3i:
			continue
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) != owner_cell:
			continue
		var production_receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
		if chunk_instance_id > 0 and not production_receipt.is_empty() \
				and int(production_receipt.get("chunkInstanceId", 0)) not in [0, chunk_instance_id]:
			continue
		_advance_geometry_owner_dependency_revision_for_candidate(
			_production_candidates_by_section.get(section_key, {}))
		_erase_source_install_acknowledgement(section_key)
		if _pending_source_releases.has(section_key):
			var pending_release: Dictionary = _pending_source_releases[section_key]
			pending_release["reloadPending"] = false
			_pending_source_releases[section_key] = pending_release
			queued += 1
			continue
		if production_receipt.is_empty():
			_pending_source_acknowledgements.erase(section_key)
			_untrack_translucent_visible_section(section_key)
		else:
			var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
			var provider_coverage: Array = candidate.get("providerCoverage", [])
			var receipt_for_release := production_receipt.duplicate(true)
			receipt_for_release.make_read_only()
			var release_result: Dictionary = _source_roster.release_section_install(
				section_key, provider_coverage, receipt_for_release) \
				if not provider_coverage.is_empty() else {"status":"acknowledged"}
			_queue_source_install_release(section_key, candidate,
				receipt_for_release, release_result, owner_cell, chunk_instance_id)
		queued += 1
	return queued


## Main may remove a native renderer owner only after stream invalidation has
## acknowledged every pending rollback and the stable dispatcher no longer
## retains a callback token for that exact owner identity.
func request_stream_chunk_owner_retirement(owner_cell: Vector2i,
		chunk_instance_id := 0) -> Dictionary:
	var install_drain := _cancel_install_sessions_before_owner_retirement(
		owner_cell, chunk_instance_id)
	if install_drain.get("status") != "ready":
		return {"status":"rollback_failed", "ownerMustBeRetained":true,
			"ownerCell":owner_cell, "chunkInstanceId":chunk_instance_id,
			"installDrain":install_drain}
	var queued := notify_stream_chunk_unloaded(owner_cell, chunk_instance_id)
	for token_value: Variant in _pending_frame_presentations:
		var record: Dictionary = _pending_frame_presentations[token_value]
		var session: Variant = record.get("session", null)
		if not session is RefCounted or not is_instance_valid(session) \
				or session.get("_owner_cell") != owner_cell:
			continue
		if chunk_instance_id > 0 and int(session.get("_chunk_id")) != chunk_instance_id:
			continue
		return {"status":"pending", "reason":"section_frame_callback_drain_pending",
			"ownerCell":owner_cell, "chunkInstanceId":chunk_instance_id,
			"presentationToken":String(token_value), "queuedWorkCount":queued,
			"retryable":true}
	return {"status":"ready", "ownerCell":owner_cell,
		"chunkInstanceId":chunk_instance_id, "queuedWorkCount":queued}


func notify_stream_chunk_loaded(owner_cell: Vector2i) -> int:
	var queued := 0
	for section_value: Variant in _committed_candidates:
		var section_key: Vector3i = section_value
		if not _production_candidates_by_section.has(section_key) \
				and SectionGrid.chunk_key_for_section(section_key) == owner_cell \
				and not _replay_reassembly_required_by_section.has(section_key) \
				and not _dirty_source_sections.has(section_key):
			_queue_replay(section_key)
			queued += 1
	for section_value: Variant in _production_candidates_by_section:
		if not section_value is Vector3i:
			continue
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) != owner_cell:
			continue
		var pending_release: Dictionary = _pending_source_releases.get(section_key, {})
		if not pending_release.is_empty():
			pending_release["reloadPending"] = true
			_pending_source_releases[section_key] = pending_release
			continue
		if _replay_reassembly_required_by_section.has(section_key) \
				or _dirty_source_sections.has(section_key) \
				or _production_candidate_receipts.has(section_key) \
				or _production_candidate_jobs.has(section_key):
			continue
		_production_candidate_jobs[section_key] = {
			"candidate":_production_candidates_by_section[section_key],
			"session":null, "stage":"unload_replay"}
		queued += 1
	return queued


func request_section_replay(section_key: Vector3i) -> bool:
	if _pending_source_releases.has(section_key):
		var pending_release: Dictionary = _pending_source_releases[section_key]
		pending_release["reloadPending"] = true
		_pending_source_releases[section_key] = pending_release
		return false
	if _replay_reassembly_required_by_section.has(section_key):
		return _promote_replay_reassembly_to_visible_demand(section_key)
	if _dirty_source_sections.has(section_key):
		return false
	if _production_candidates_by_section.has(section_key):
		if _production_candidate_receipts.has(section_key) \
				or _production_candidate_jobs.has(section_key):
			return false
		_production_candidate_jobs[section_key] = {
			"candidate":_production_candidates_by_section[section_key],
			"session":null, "stage":"requested_replay"}
		return true
	if not _committed_candidates.has(section_key):
		return false
	_queue_replay(section_key)
	return true


func cancel_section_replay(section_key: Vector3i) -> Dictionary:
	if not _committed_candidates.has(section_key):
		return _failed("section_replay_candidate_missing")
	if not _active_replay.is_empty() and _active_replay.get("sectionKey") == section_key:
		var cancelled := _cancel_active_replay("explicit_cancel")
		if cancelled.get("status") != "cancelled":
			return cancelled
	if _replay_set.has(section_key):
		_replay_set.erase(section_key)
		_replay_queue.erase(section_key)
	return {"status":"cancelled", "sectionKey":section_key}


## Reinstall one committed section after owner-chunk recreation. The caller must
## supply a fresh authoritative census/revision snapshot; a lost renderer slot
## is not a contributor removal. Explicit-empty snapshots are replayed too.
func advance_replay(current_source_revisions: Dictionary,
		expected_contributors_by_section: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		max_upload_units := 1) -> Dictionary:
	if not _active_boundary.is_empty():
		return {"status":"busy", "reason":"boundary_install_in_progress"}
	if not _active_replay.is_empty():
		var active_section: Vector3i = _active_replay.get("sectionKey", Vector3i.ZERO)
		if _replay_reassembly_required_by_section.has(active_section):
			var cancelled := _cancel_active_replay("authoritative_reassembly")
			if cancelled.get("status") != "cancelled":
				return cancelled
			var queued_reassembly := _promote_replay_reassembly_to_visible_demand(
				active_section)
			return {"status":"pending", "stage":"authoritative_reassembly",
				"sectionKey":active_section,
				"reason":"stale_replay_candidate_requires_provider_recapture",
				"reassemblyDemandQueued":queued_reassembly, "retryable":true}
		return _advance_replay_session(current_source_revisions,
			expected_contributors_by_section, material_bindings, mesh_bindings,
			max_upload_units)
	while not _replay_queue.is_empty():
		var section_key: Vector3i = _replay_queue.pop_front()
		_replay_set.erase(section_key)
		if _replay_reassembly_required_by_section.has(section_key):
			_promote_replay_reassembly_to_visible_demand(section_key)
			return {"status":"pending", "stage":"authoritative_reassembly",
				"sectionKey":section_key,
				"reason":"stale_replay_candidate_requires_provider_recapture",
				"retryable":true}
		if _dirty_source_sections.has(section_key):
			continue
		if not _committed_candidates.has(section_key):
			continue
		var candidate: Dictionary = _committed_candidates[section_key]
		if _replay_pov_waiting_revision_by_section.has(section_key):
			var blocked_revision := int(_replay_pov_waiting_revision_by_section[section_key])
			var current_pov := current_translucent_pov_snapshot(section_key)
			if current_pov.get("status") != "ready" \
					or int(current_pov.get("revision", -1)) == blocked_revision:
				_queue_replay(section_key)
				return {"status":"pending", "stage":"translucent_pov",
					"reason":"section_replay_waiting_for_translucent_pov_change",
					"sectionKey":section_key, "retryable":true}
			_replay_pov_waiting_revision_by_section.erase(section_key)
		var check := _validate_candidate_census([candidate],
			expected_contributors_by_section, current_source_revisions)
		if check.get("status") != "ready":
			if _candidate_has_section_attachments(candidate):
				return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
					String(check.get("reason", "stale_section_replay_census")))
			return {"status":"failed", "reason":check.get("reason", "stale_section_replay_census"),
				"sectionKey":section_key}
		var installed_receipt: Dictionary = _installed_receipts.get(section_key, {})
		if _receipt_is_live(candidate, installed_receipt):
			continue
		_active_replay = {"candidate":candidate, "sectionKey":section_key,
			"installSession":null}
		return _advance_replay_session(current_source_revisions,
			expected_contributors_by_section, material_bindings, mesh_bindings,
			max_upload_units)
	return {"status":"idle", "queuedSections":0}


func has_pending_work() -> bool:
	return not _active_boundary.is_empty() or not _boundary_queue.is_empty() \
		or not _section_compile_jobs.is_empty() \
		or not _active_replay.is_empty() or not _replay_queue.is_empty() \
		or not _pending_source_acknowledgements.is_empty() \
		or not _pending_source_releases.is_empty() \
		or not _production_candidate_jobs.is_empty() \
		or _pending_visible_section_demand_count() > 0


func _pending_visible_section_demand_count() -> int:
	var pending := 0
	for state_value: Variant in _visible_section_demands.values():
		if not state_value is Dictionary:
			continue
		var stage := String(state_value.get("stage", ""))
		if stage in ["waiting", "candidate_queued", "candidate_pending"]:
			pending += 1
	return pending


func _active_replay_reassembly_demand_count() -> int:
	var active := 0
	for section_key_value: Variant in _replay_reassembly_required_by_section.keys():
		if not section_key_value is Vector3i:
			continue
		var demand: Dictionary = _visible_section_demands.get(section_key_value, {})
		if String(demand.get("stage", "")) in ["waiting", "candidate_queued",
				"candidate_pending"]:
			active += 1
	return active


func _source_install_acknowledgement_statuses() -> Dictionary:
	var sample: Array[Dictionary] = []
	for section_value: Variant in _source_install_acknowledgements_by_section:
		if sample.size() >= MAX_SOURCE_ACK_STATUS_SAMPLES:
			break
		if not section_value is Vector3i:
			continue
		var settlement: Dictionary = _source_install_acknowledgements_by_section.get(
			section_value, {})
		var receipt: Dictionary = settlement.get("receipt", {})
		var section_key: Vector3i = section_value
		sample.append({"sectionKey":section_key,
			"status":String(settlement.get("status", "failed")),
			"generation":int(receipt.get("generation", 0)),
			"attempts":int(settlement.get("attempts", 0)),
			"nextAttemptFrame":int(settlement.get("nextAttemptFrame", -1)),
			"reason":String(settlement.get("reason", ""))})
	return {"total":_source_install_acknowledgements_by_section.size(),
		"counts":_source_install_acknowledgement_counts.duplicate(true),
		"sampleLimit":MAX_SOURCE_ACK_STATUS_SAMPLES, "sample":sample}


func status() -> Dictionary:
	var next_ack_frame := -1
	for pending_value: Variant in _pending_source_acknowledgements.values():
		if not pending_value is Dictionary:
			continue
		var retry_frame := int(pending_value.get("nextAttemptFrame", 0))
		if next_ack_frame < 0 or retry_frame < next_ack_frame:
			next_ack_frame = retry_frame
	var next_release_frame := -1
	for pending_value: Variant in _pending_source_releases.values():
		if not pending_value is Dictionary:
			continue
		var retry_frame := int(pending_value.get("nextAttemptFrame", 0))
		if next_release_frame < 0 or retry_frame < next_release_frame:
			next_release_frame = retry_frame
	var demand_stages := {"waiting":0, "candidate_queued":0,
		"candidate_pending":0, "installed":0, "blocked":0}
	for state_value: Variant in _visible_section_demands.values():
		if not state_value is Dictionary:
			continue
		var stage := String(state_value.get("stage", ""))
		if demand_stages.has(stage):
			demand_stages[stage] = int(demand_stages[stage]) + 1
	return {"status":"busy" if has_pending_work() else "idle", "worldId":_world_id,
		"queuedBoundaries":_boundary_queue.size(),
		"activeBoundaryId":String(_active_boundary.get("boundaryId", "")),
		"queuedReplaySections":_replay_queue.size(),
		"activeReplaySection":_active_replay.get("sectionKey"),
		"replayAwaitingAuthoritativeReassemblyCount":_replay_reassembly_required_by_section.size(),
		"activeReplayReassemblyDemandCount":_active_replay_reassembly_demand_count(),
		"productionCandidateJobCount":_production_candidate_jobs.size(),
		"sectionCompileJobCount":_section_compile_jobs.size(),
		"completedNativeSectionCompileCount":_section_compile_completed_count,
		"visibleSectionDemandCount":_visible_section_demands.size(),
		"pendingVisibleSectionDemandCount":_pending_visible_section_demand_count(),
		"queuedVisibleSectionDemandCount":_pending_visible_section_demand_count(),
		"physicalVisibleDemandQueueRows":_visible_section_demand_count,
		"visibleSectionDemandStages":demand_stages,
		"pendingSourceAcknowledgementCount":_pending_source_acknowledgements.size(),
		"sourceInstallAcknowledgementSummary":_source_install_acknowledgement_statuses(),
		"geometryOwnerCompletionSessions":_geometry_owner_completion_sessions_status(),
		"pendingGeometryOwnerCompletionRequests":_geometry_owner_completion_requests.size(),
		"nextSourceAcknowledgementFrame":next_ack_frame,
		"pendingSourceReleaseCount":_pending_source_releases.size(),
		"nextSourceReleaseFrame":next_release_frame,
		"committedSourcePartIds":_ledger.committed_source_part_ids(),
		"committedSourceParts":_ledger.committed_source_parts(),
		"committedSectionCount":_committed_candidates.size()}


func _activate_next_boundary() -> Dictionary:
	if _boundary_queue.is_empty():
		return {"status":"idle"}
	_active_boundary = _boundary_queue.pop_front()
	var boundary_id := String(_active_boundary.boundaryId)
	var begun: Dictionary = _ledger.begin_boundary(boundary_id,
		_active_boundary.declarations, _active_boundary.removals)
	if begun.get("status") != "ready":
		var reason := String(begun.get("reason", "section_boundary_rejected"))
		_active_boundary.clear()
		return _failed(reason)
	_active_boundary.phase = "collecting"
	for segment_value: Variant in _active_boundary.segments:
		var admitted: Dictionary = _ledger.accept_prepared_segment(boundary_id, segment_value)
		if admitted.get("status") != "accepted":
			return _abort_active(String(admitted.get("reason", "prepared_segment_rejected")))
	return {"status":"ready", "boundaryId":boundary_id}


func _advance_replay_session(current_source_revisions: Dictionary,
		expected_contributors_by_section: Dictionary,
		material_bindings: Dictionary, mesh_bindings: Dictionary,
		max_upload_units: int) -> Dictionary:
	if max_upload_units < 1 or max_upload_units > 64 or not _valid_revision_map(current_source_revisions) \
			or not _valid_census_map(expected_contributors_by_section):
		return _failed("invalid_section_replay_inputs")
	var candidate: Dictionary = _active_replay.candidate
	var section_key: Vector3i = _active_replay.sectionKey
	if _dirty_source_sections.has(section_key):
		var dirty_cancel := _cancel_active_replay("dirty_source")
		if dirty_cancel.get("status") != "cancelled":
			return dirty_cancel
		return {"status":"deferred_dirty", "reason":"section_has_dirty_source",
			"sectionKey":section_key, "retryable":true}
	var current_check := _validate_candidate_census([candidate],
		expected_contributors_by_section, current_source_revisions)
	if current_check.get("status") != "ready":
		var census_cancel := _cancel_active_replay("source_census_changed")
		if census_cancel.get("status") != "cancelled":
			return census_cancel
		if _candidate_has_section_attachments(candidate):
			return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
				String(current_check.get("reason", "stale_section_replay_source")))
		return {"status":"failed", "reason":current_check.get("reason", "stale_section_replay_source"),
			"sectionKey":section_key}
	if _replay_reassembly_required_by_section.has(section_key):
		var reassembly_cancel := _cancel_active_replay("authoritative_reassembly")
		if reassembly_cancel.get("status") != "cancelled":
			return reassembly_cancel
		_promote_replay_reassembly_to_visible_demand(section_key)
		return {"status":"pending", "stage":"authoritative_reassembly",
			"sectionKey":section_key,
			"reason":"stale_replay_candidate_requires_provider_recapture",
			"retryable":true}
	var session = _active_replay.get("installSession")
	if session == null:
		var started: Dictionary = PacketOwner.begin_static_section_install(
			candidate, material_bindings, mesh_bindings, self)
		if started.get("status") == "pending":
			return {"status":"pending_owner", "sectionKey":section_key,
				"reason":started.get("reason", ""), "retryable":true}
		if started.get("status") != "ready":
			_active_replay.clear()
			if bool(started.get("requiresAuthoritativeReassembly", false)):
				return _defer_stale_replay_to_authoritative_reassembly(section_key, -1,
					String(started.get("reason", "section_attachment_binding_stale")))
			if String(started.get("reason", "")) == "section_residency_dependency_not_pinned":
				_queue_replay(section_key)
				return {"status":"unsupported", "reason":String(started.reason),
					"sectionKey":section_key, "retryable":true}
			return _failed(String(started.get("reason", "section_replay_begin_failed")))
		_active_replay.installSession = started.session
		session = started.session
	var pov_state := _current_translucent_pov_revision_for_candidate(
		candidate, section_key)
	if pov_state.get("status") != "ready":
		if String(session.get("state")) == "awaiting_frame":
			var unavailable_pov_step: Dictionary = session.advance(max_upload_units, -1)
			if unavailable_pov_step.get("status") == "rollback_failed":
				_active_replay["stage"] = "rollback_failed"
				_active_replay["rollbackFailure"] = unavailable_pov_step.duplicate(true)
				return {"status":"rollback_failed", "stage":"rollback",
					"sectionKey":section_key,
					"reason":String(unavailable_pov_step.get("reason", "")),
					"rollback":unavailable_pov_step.get("rollback", {}),
					"retryable":true}
			if unavailable_pov_step.get("status") == "failed" \
					and String(unavailable_pov_step.get("reason", "")) \
						== "section_translucent_pov_revision_stale":
				var unavailable_pov_cancel := _cancel_active_replay("translucent_pov_unavailable")
				if unavailable_pov_cancel.get("status") != "cancelled":
					return unavailable_pov_cancel
				return _defer_stale_replay_to_authoritative_reassembly(section_key, -1)
		return {"status":"pending", "stage":"translucent_pov",
			"reason":String(pov_state.get("reason", "translucent_camera_snapshot_unavailable")),
			"sectionKey":section_key, "retryable":true}
	var step: Dictionary = session.advance(max_upload_units,
		int(pov_state.get("revision", -1)))
	if step.get("status") == "pending_presentation":
		if not bool(step.get("frameDrawn", false)):
			return {"status":"pending", "sectionKey":section_key,
				"stage":"awaiting_frame",
				"reason":"section_candidate_waiting_for_frame_drawn_callback",
				"retryable":true}
		step = session.finalize_presentation(
			String(step.get("presentationToken", "")))
	if step.get("status") == "pending":
		return {"status":"pending", "sectionKey":section_key,
			"stage":step.get("stage", "section_replay"),
			"reason":step.get("reason", ""), "retryable":true}
	if step.get("status") == "rollback_failed":
		_active_replay["stage"] = "rollback_failed"
		_active_replay["rollbackFailure"] = step.duplicate(true)
		return {"status":"rollback_failed", "stage":"rollback",
			"sectionKey":section_key, "reason":String(step.get("reason", "")),
			"rollback":step.get("rollback", {}), "retryable":true}
	if step.get("status") != "installed":
		var reason := String(step.get("reason", "section_replay_failed"))
		if bool(step.get("requiresAuthoritativeReassembly", false)):
			var attachment_cancel := _cancel_active_replay("stale_attachment_binding")
			if attachment_cancel.get("status") != "cancelled":
				return attachment_cancel
			return _defer_stale_replay_to_authoritative_reassembly(section_key, -1, reason)
		if reason == "section_install_owner_replaced":
			if step.get("rollback", {}).get("status") != "cancelled":
				_active_replay["stage"] = "rollback_failed"
				_active_replay["rollbackFailure"] = step.duplicate(true)
				return {"status":"rollback_failed", "stage":"rollback",
					"sectionKey":section_key,
					"reason":"owner_replaced_without_rollback_acknowledgement",
					"rollback":step.get("rollback", {}), "retryable":true}
			_active_replay.installSession = null
			return {"status":"pending_owner", "sectionKey":section_key,
				"reason":reason, "retryable":true}
		if reason == "section_translucent_pov_revision_stale":
			var pov_cancel := _cancel_active_replay("stale_translucent_pov")
			if pov_cancel.get("status") != "cancelled":
				return pov_cancel
			var stale_pov_snapshot := current_translucent_pov_snapshot(section_key)
			return _defer_stale_replay_to_authoritative_reassembly(section_key,
				int(stale_pov_snapshot.get("revision", -1)) \
				if stale_pov_snapshot.get("status") == "ready" else -1)
		var failure_cancel := _cancel_active_replay("replay_failed")
		if failure_cancel.get("status") != "cancelled":
			return failure_cancel
		return _failed(reason)
	var receipt: Dictionary = step.get("receipt", {})
	if not _receipt_is_live(candidate, receipt):
		_active_replay["stage"] = "owner_replaced"
		return {"status":"pending_owner", "sectionKey":section_key,
			"reason":"section_replay_receipt_owner_changed", "retryable":true}
	_installed_receipts[section_key] = receipt
	_active_replay.clear()
	return {"status":"replayed", "sectionKey":section_key,
		"generation":candidate.generation,
		"contentManifestDigest":candidate.contentManifestDigest,
		"receipt":receipt}


func _validate_candidate_census(replacements: Array,
		expected_contributors_by_section: Dictionary,
		current_source_revisions: Dictionary) -> Dictionary:
	if expected_contributors_by_section.size() != replacements.size():
		var candidate_keys: Array[String] = []
		for replacement_value: Variant in replacements:
			if replacement_value is Dictionary:
				candidate_keys.append(str(replacement_value.get("sectionKey", "invalid")))
		candidate_keys.sort()
		var census_keys: Array[String] = []
		for census_key: Variant in expected_contributors_by_section:
			census_keys.append(str(census_key))
		census_keys.sort()
		return _failed("section_source_census_key_set_mismatch:census=%s:candidates=%s" % [
			",".join(census_keys), ",".join(candidate_keys)])
	var used_keys: Dictionary = {}
	for replacement_value: Variant in replacements:
		if not replacement_value is Dictionary or not replacement_value.get("sectionKey") is Vector3i:
			return _failed("invalid_section_source_census_replacement")
		var replacement: Dictionary = replacement_value
		var section_key: Vector3i = replacement.sectionKey
		if used_keys.has(section_key) or not expected_contributors_by_section.has(section_key):
			return _failed("section_source_census_key_set_mismatch")
		used_keys[section_key] = true
		var expected_value: Variant = expected_contributors_by_section[section_key]
		if not expected_value is Array or not expected_value.is_read_only():
			return _failed("mutable_or_invalid_section_source_census")
		var expected_ids: Array[String] = []
		var expected_seen: Dictionary = {}
		for source_part_value: Variant in expected_value:
			if not source_part_value is String or String(source_part_value).is_empty() \
					or expected_seen.has(source_part_value):
				return _failed("invalid_or_duplicate_expected_section_contributor")
			expected_seen[source_part_value] = true
			expected_ids.append(String(source_part_value))
		expected_ids.sort()
		var snapshot_value: Variant = replacement.get("snapshot")
		if not snapshot_value is Dictionary or not snapshot_value.is_read_only():
			return _failed("section_candidate_snapshot_missing")
		var snapshot: Dictionary = snapshot_value
		var contributors: Variant = snapshot.get("manifest")
		if not contributors is Array or not contributors.is_read_only():
			return _failed("section_candidate_contributor_manifest_missing")
		var actual_ids: Array[String] = []
		var actual_seen: Dictionary = {}
		for contributor_value: Variant in contributors:
			if not contributor_value is Dictionary or not contributor_value.is_read_only():
				return _failed("mutable_or_invalid_section_contributor_manifest")
			var contributor: Dictionary = contributor_value
			var source_id := String(contributor.get("sourceId", ""))
			var part_id := String(contributor.get("sourcePartId", ""))
			var revision := String(contributor.get("sourceRevision", ""))
			var pair_key := _source_part_identity_key(source_id, part_id)
			if pair_key.is_empty() or revision.is_empty() or actual_seen.has(pair_key):
				return _failed("invalid_or_duplicate_candidate_contributor")
			actual_seen[pair_key] = true
			actual_ids.append(pair_key)
			if not current_source_revisions.has(pair_key) \
					or String(current_source_revisions[pair_key]) != revision:
				return _failed("section_candidate_contributor_revision_stale:" + pair_key)
		actual_ids.sort()
		if actual_ids != expected_ids:
			return _failed("section_candidate_contributor_census_mismatch:" + str(section_key))
	return {"status":"ready"}


func _changed_revision_snapshot(request: Dictionary,
		current_source_revisions: Dictionary) -> Dictionary:
	var expected: Dictionary = {}
	for declaration_value: Variant in request.declarations:
		var declaration: Dictionary = declaration_value
		var source_id := String(declaration.get("sourceId", ""))
		var part_id := String(declaration.get("sourcePartId", ""))
		var revision := String(declaration.get("sourceRevision", ""))
		var pair_key := _source_part_identity_key(source_id, part_id)
		if pair_key.is_empty() or not current_source_revisions.has(pair_key) \
				or String(current_source_revisions[pair_key]) != revision:
			return _failed("stale_source_revision:" + pair_key)
		expected[pair_key] = revision
	for removal_value: Variant in request.removals:
		var removal: Dictionary = removal_value
		var source_id := String(removal.get("sourceId", ""))
		var part_id := String(removal.get("sourcePartId", ""))
		var revision := String(removal.get("sourceRevision", ""))
		var pair_key := _source_part_identity_key(source_id, part_id)
		if pair_key.is_empty() or not current_source_revisions.has(pair_key) \
				or String(current_source_revisions[pair_key]) != revision:
			return _failed("stale_removal_revision:" + pair_key)
		expected[pair_key] = revision
	expected.make_read_only()
	return {"status":"ready", "revisions":expected}


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _valid_source_part_identity_key(identity_key: String) -> bool:
	if not identity_key.begins_with("section-part:"):
		return false
	var encoded := identity_key.trim_prefix("section-part:")
	if encoded.is_empty() or encoded.length() % 2 != 0:
		return false
	var decoded: Variant = bytes_to_var(encoded.hex_decode())
	return decoded is Array and decoded.size() == 2 \
		and decoded[0] is String and not String(decoded[0]).is_empty() \
		and decoded[1] is String and not String(decoded[1]).is_empty() \
		and _source_part_identity_key(String(decoded[0]), String(decoded[1])) == identity_key


func _receipt_is_live(candidate: Dictionary, receipt: Dictionary) -> bool:
	if receipt.is_empty() or not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or String(receipt.get("worldId", "")) != String(candidate.get("worldId", "")) \
			or receipt.get("sectionKey") != candidate.get("sectionKey") \
			or int(receipt.get("generation", 0)) != int(candidate.get("generation", 0)) \
			or String(receipt.get("contentManifestDigest", "")) != String(candidate.get("contentManifestDigest", "")):
		return false
	return _section_receipt_source_revision_is_current(candidate, receipt) \
		and _receipt_backend_matches_candidate(candidate, receipt)


func _receipt_backend_matches_candidate(candidate: Dictionary, receipt: Dictionary) -> bool:
	if receipt.is_empty() or not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or String(receipt.get("worldId", "")) != String(candidate.get("worldId", "")) \
			or receipt.get("sectionKey") != candidate.get("sectionKey") \
			or int(receipt.get("generation", 0)) != int(candidate.get("generation", 0)) \
			or String(receipt.get("contentManifestDigest", "")) != String(candidate.get("contentManifestDigest", "")):
		return false
	var section_value: Variant = candidate.get("sectionKey", null)
	if not section_value is Vector3i:
		return false
	var section_key := Vector3i(section_value)
	var owner_cell := SectionGrid.chunk_key_for_section(section_key)
	if receipt.get("ownerCell") != owner_cell:
		return false
	var current: Dictionary = _resolve_existing_static_section_backend(owner_cell)
	if current.get("status") != "ready":
		return false
	var backend: Node = current.backend as Node
	var chunk: Node3D = current.chunk as Node3D
	if not is_instance_valid(backend) or not is_instance_valid(chunk) \
			or backend.get_instance_id() != int(receipt.get("backendInstanceId", 0)) \
			or chunk.get_instance_id() != int(receipt.get("chunkInstanceId", 0)) \
			or backend.get_parent() != chunk:
		return false
	var source_id := InstallSession.slot_id(_world_id, section_key)
	var generation := int(candidate.generation)
	var source_revision := String(receipt.get("sourceRevision", ""))
	var digest := String(candidate.contentManifestDigest)
	if not backend.has_method("receipt_installed") \
			or not bool(backend.call("receipt_installed", source_id, generation, source_revision, digest)):
		return false
	var installed: Dictionary = backend.call("installed_snapshot", source_id)
	return installed.get("status") == "ready" \
		and installed.get("ownerCell") == owner_cell \
		and int(installed.get("generation", 0)) == generation \
		and String(installed.get("sourceRevision", "")) == source_revision \
		and String(installed.get("packetDigest", "")) == digest


func _resolve_existing_static_section_backend(owner_cell: Vector2i) -> Dictionary:
	return PacketOwner.resolve_existing_static_section_backend(owner_cell)


func installed_section_receipt_is_current(section_key: Vector3i,
		receipt: Dictionary) -> bool:
	if _geometry_owner_receipt_scope_token != 0 \
			and _geometry_owner_receipt_scope_generation == _generation \
			and _geometry_owner_receipt_scope_owner != null \
			and is_instance_valid(_geometry_owner_receipt_scope_owner.get_ref()):
		var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
		var current_receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
		var cached: Dictionary = _geometry_owner_receipt_scope_cache.get(section_key, {})
		if not cached.is_empty() and is_same(candidate, cached.get("candidate")) \
				and is_same(current_receipt, cached.get("receipt")) \
				and is_same(receipt, current_receipt):
			_geometry_owner_receipt_scope_cache_hits += 1
			return bool(cached.get("isCurrent", false))
		var current := _installed_section_receipt_is_current_uncached(
			section_key, receipt)
		_geometry_owner_receipt_scope_liveness_checks += 1
		_geometry_owner_receipt_scope_cache[section_key] = {
			"candidate":candidate, "receipt":current_receipt,
			"isCurrent":current}
		return current
	return _installed_section_receipt_is_current_uncached(section_key, receipt)


func _installed_section_receipt_is_current_uncached(section_key: Vector3i,
		receipt: Dictionary) -> bool:
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	var current_receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	if candidate.is_empty() or current_receipt.is_empty() or receipt.is_empty():
		return false
	for identity_key: String in ["worldId", "sectionKey", "generation",
			"censusDigest", "contentManifestDigest", "sourceRevision",
			"translucentPovRevision", "backendInstanceId", "chunkInstanceId", "ownerCell"]:
		if current_receipt.get(identity_key) != receipt.get(identity_key):
			return false
	return int(current_receipt.get("generation", 0)) == int(candidate.get("generation", -1)) \
		and _receipt_is_live(candidate, current_receipt)


## Positive acknowledgement proof for the current native installation receipt.
## This reads coordinator-owned settlement state only; it never invokes providers.
func source_install_acknowledgement_proof(section_key: Vector3i,
		receipt: Dictionary) -> Dictionary:
	if not installed_section_receipt_is_current(section_key, receipt):
		return {"status":"pending", "reason":"source_acknowledgement_receipt_not_current",
			"sectionKey":section_key}
	var settlement: Dictionary = _source_install_acknowledgements_by_section.get(
		section_key, {})
	if settlement.is_empty():
		return {"status":"pending", "reason":"source_acknowledgement_result_missing",
			"sectionKey":section_key, "generation":int(receipt.get("generation", 0))}
	if not _source_ack_receipt_identity_matches(settlement.get("receipt", {}), receipt):
		return {"status":"pending", "reason":"source_acknowledgement_receipt_identity_mismatch",
			"sectionKey":section_key, "generation":int(receipt.get("generation", 0))}
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	if int(candidate.get("generation", 0)) != int(receipt.get("generation", -1)) \
			or settlement.get("providerCoverage", []) != candidate.get("providerCoverage", []):
		return {"status":"pending", "reason":"source_acknowledgement_provider_coverage_changed",
			"sectionKey":section_key, "generation":int(receipt.get("generation", 0))}
	if String(settlement.get("status", "")) != "acknowledged" \
			or settlement.get("lastResult", {}).get("status") != "acknowledged":
		var last_result: Dictionary = settlement.get("lastResult", {})
		return {"status":String(settlement.get("status", "pending")),
			"reason":String(settlement.get("reason", "source_acknowledgement_not_settled")),
			"sectionKey":section_key, "generation":int(receipt.get("generation", 0)),
			"attempts":int(settlement.get("attempts", 0)),
			"nextAttemptFrame":int(settlement.get("nextAttemptFrame", -1)),
			"providerResultStatus":String(last_result.get("status", "failed")),
			"providerResultReason":String(last_result.get("reason", ""))}
	return {"status":"ready", "sectionKey":section_key,
		"generation":int(receipt.get("generation", 0)),
		"providerCoverageCount":int(settlement.get("providerCoverage", []).size()),
		"providerResultStatus":"acknowledged"}


## Exact startup diagnostic join. The caller supplies section keys from one
## compiled tree source; this method never scans unrelated sections or jobs.
func startup_source_install_diagnostics(source_id: String,
		section_keys: Array[Vector3i], expected_source_revision := "") -> Dictionary:
	var sections: Array[Dictionary] = []
	for section_key: Vector3i in section_keys:
		var job: Dictionary = _production_candidate_jobs.get(section_key, {})
		var installed: Dictionary = _production_candidates_by_section.get(section_key, {})
		var queued_candidate: Dictionary = job.get("candidate", {})
		var candidate: Dictionary = queued_candidate if not queued_candidate.is_empty() else installed
		var queued_source_revisions := _section_candidate_source_revisions(queued_candidate)
		var installed_source_revisions := _section_candidate_source_revisions(installed)
		var queued_source_present := queued_source_revisions.has(source_id)
		var installed_source_present := installed_source_revisions.has(source_id)
		var queued_source_revision := String(queued_source_revisions.get(source_id, ""))
		var installed_source_revision := String(installed_source_revisions.get(source_id, ""))
		var candidate_source_revision := queued_source_revision if not queued_candidate.is_empty() \
			else installed_source_revision
		var source_present := queued_source_present or installed_source_present
		var receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
		var receipt_installed_current := installed_source_present and not receipt.is_empty() \
			and installed_section_receipt_is_current(section_key, receipt)
		# The install receipt's sourceRevision identifies the native section
		# generation (world:generation[:pov]), while installed_source_revision is
		# the producer's content revision. They are separate revision domains;
		# join them through the current receipt's generation/manifest/owner identity.
		var receipt_source_revision := String(receipt.get("sourceRevision", ""))
		var receipt_joins_installed_candidate := receipt_installed_current \
			and int(receipt.get("generation", 0)) == int(installed.get("generation", -1)) \
			and String(receipt.get("contentManifestDigest", "")) \
				== String(installed.get("contentManifestDigest", ""))
		var queued_matches_installed := queued_candidate.is_empty() \
			or queued_source_revision == installed_source_revision
		var revision_matches := receipt_joins_installed_candidate \
			and queued_matches_installed
		if not expected_source_revision.is_empty():
			revision_matches = candidate_source_revision == expected_source_revision
		var expected_revision_matches_installed := expected_source_revision.is_empty() \
			or installed_source_revision == expected_source_revision
		var receipt_current := receipt_joins_installed_candidate \
			and (expected_source_revision.is_empty() \
				or installed_source_revision == expected_source_revision) \
			and queued_matches_installed
		var revision_mismatch_reason := ""
		if not expected_source_revision.is_empty() and not revision_matches:
			revision_mismatch_reason = "candidate_source_revision_mismatch"
		elif not queued_matches_installed:
			revision_mismatch_reason = "queued_candidate_source_revision_mismatch"
		elif not receipt_joins_installed_candidate:
			revision_mismatch_reason = "receipt_identity_does_not_join_installed_candidate"
		var pending_ack: Dictionary = _pending_source_acknowledgements.get(section_key, {})
		var pending_candidate: Dictionary = pending_ack.get("candidate", {})
		var pending_source := _section_candidate_source_revisions(pending_candidate).has(source_id)
		var pending_release: Dictionary = _pending_source_releases.get(section_key, {})
		var admitted := queued_source_present or installed_source_present
		sections.append({"sectionKey":section_key,
			"candidateJobStage":String(job.get("stage", "")),
			"sourcePresentInCandidate":source_present,
			"queuedSourceRevision":queued_source_revision,
			"installedSourceRevision":installed_source_revision,
			"admitted":admitted,
			"expectedSourceRevision":expected_source_revision,
			"candidateSourceRevision":candidate_source_revision,
			"queuedRevisionMatchesInstalled":queued_matches_installed,
			"expectedRevisionMatchesInstalled":expected_revision_matches_installed,
			"receiptSourceRevision":receipt_source_revision,
			"receiptJoinsInstalledCandidate":receipt_joins_installed_candidate,
			"sourceRevisionMatch":revision_matches,
			"sourceRevisionComparison":"expected_source_revision" \
				if not expected_source_revision.is_empty() else "receipt_to_installed_candidate",
			"sourceRevisionMismatchReason":revision_mismatch_reason,
			"candidateGeneration":int(candidate.get("generation", 0)),
			"receiptInstalledCurrent":receipt_installed_current,
			"receiptCurrent":receipt_current,
			"receiptGeneration":int(receipt.get("generation", 0)),
			"sourceAckPending":pending_source,
			"sourceAckResult":String(pending_ack.get("lastResult", {}).get("status", "")),
			"sourceReleasePending":not pending_release.is_empty(),
			"sourceReleaseResult":String(pending_release.get("lastResult", {}).get("status", "")),
			"sourceReleaseNextAttemptFrame":int(pending_release.get("nextAttemptFrame", -1))})
	return {"sourceId":source_id, "sections":sections,
		"querySectionCount":section_keys.size(), "exactSectionQuery":true,
		"status":"unresolved_no_compiled_sections" if section_keys.is_empty() else "queried"}


func _candidate_translucent_pov_revision(candidate: Dictionary) -> int:
	var envelope: Variant = candidate.get("candidate", candidate)
	if not envelope is Dictionary:
		return -1
	var snapshot: Variant = envelope.get("snapshot", null)
	if not snapshot is Dictionary:
		return -1
	var batches: Variant = snapshot.get("batches", null)
	if not batches is Dictionary:
		return -2
	var expected_revision := -1
	for batch_value: Variant in batches.values():
		if not batch_value is Dictionary \
				or String(batch_value.get("renderLayer", "")) != "translucent":
			continue
		var descriptor: Variant = batch_value.get("translucentSortDescriptor", null)
		if not descriptor is Dictionary:
			return -2
		var revision := int(descriptor.get("povRevision", -1))
		if revision <= 0 or (expected_revision > 0 and expected_revision != revision):
			return -2
		expected_revision = revision
	return expected_revision


func _current_translucent_pov_revision_for_candidate(candidate: Dictionary,
		section_key: Vector3i) -> Dictionary:
	var expected_revision := _candidate_translucent_pov_revision(candidate)
	if expected_revision == -2:
		return {"status":"failed", "reason":"candidate_translucent_pov_descriptor_invalid"}
	if expected_revision == -1:
		return {"status":"ready", "revision":-1}
	var snapshot := current_translucent_pov_snapshot(section_key)
	if snapshot.get("status") != "ready":
		return snapshot
	return {"status":"ready", "revision":int(snapshot.get("revision", -1)),
		"candidateRevision":expected_revision}


func _section_receipt_source_revision_is_current(candidate: Dictionary,
		receipt: Dictionary) -> bool:
	var section_value: Variant = candidate.get("sectionKey", null)
	var generation_value: Variant = candidate.get("generation", null)
	if not section_value is Vector3i or not generation_value is int:
		return false
	var expected_pov_revision := _candidate_translucent_pov_revision(candidate)
	if expected_pov_revision == -2:
		return false
	if not _section_receipt_source_revision_matches_candidate(candidate, receipt):
		return false
	if expected_pov_revision <= 0:
		return true
	var pov_snapshot := current_translucent_pov_snapshot(Vector3i(section_value))
	return pov_snapshot.get("status") == "ready" \
		and int(pov_snapshot.get("revision", -1)) == expected_pov_revision


func _section_receipt_source_revision_matches_candidate(candidate: Dictionary,
		receipt: Dictionary) -> bool:
	var section_value: Variant = candidate.get("sectionKey", null)
	var generation_value: Variant = candidate.get("generation", null)
	if not section_value is Vector3i or not generation_value is int:
		return false
	var expected_pov_revision := _candidate_translucent_pov_revision(candidate)
	if expected_pov_revision == -2:
		return false
	var receipt_pov_value: Variant = receipt.get("translucentPovRevision", null)
	var expected_source_revision := "%s:%d" % [String(candidate.get("worldId", "")),
		int(generation_value)]
	if expected_pov_revision > 0:
		if not receipt_pov_value is int or int(receipt_pov_value) != expected_pov_revision:
			return false
		expected_source_revision += ":pov:%d" % expected_pov_revision
	elif receipt_pov_value != null:
		return false
	return String(receipt.get("sourceRevision", "")) == expected_source_revision


func _promote_active_boundary(current_source_revisions: Dictionary,
		expected_contributors_by_section: Dictionary) -> Dictionary:
	var boundary_id := String(_active_boundary.boundaryId)
	var candidate: Dictionary = _active_boundary.candidate
	var replacements: Array = candidate.replacements
	var receipts: Array[Dictionary] = []
	var section_keys: Array[Vector3i] = []
	for replacement_value: Variant in replacements:
		if not replacement_value is Dictionary:
			return _abort_active("invalid_prepared_section_replacement")
		var replacement: Dictionary = replacement_value
		var section_key: Vector3i = replacement.sectionKey
		var receipt: Dictionary = _active_boundary.receipts.get(section_key, {})
		if not _receipt_is_live(replacement, receipt):
			_active_boundary.receipts.erase(section_key)
			_active_boundary.replacementIndex = replacements.find(replacement)
			return {"status":"pending_owner", "reason":"section_receipt_no_longer_live",
				"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
		receipts.append(receipt)
		section_keys.append(section_key)
	var changed_again := _changed_revision_snapshot(_active_boundary, current_source_revisions)
	if changed_again.get("status") != "ready":
		return _abort_active(String(changed_again.get("reason", "stale_source_revision_before_promotion")))
	var final_census := _validate_candidate_census(candidate.replacements,
		expected_contributors_by_section, current_source_revisions)
	if final_census.get("status") != "ready":
		return _abort_active(String(final_census.get("reason", "stale_section_source_census_before_promotion")))
	receipts.make_read_only()
	var accepted: Dictionary = _ledger.accept_installed_candidate(boundary_id,
		receipts, changed_again.revisions)
	if accepted.get("status") != "committed":
		return _abort_active(String(accepted.get("reason", "section_candidate_promotion_failed")))
	for replacement_value: Variant in replacements:
		var replacement: Dictionary = replacement_value
		var section_key: Vector3i = replacement.sectionKey
		_committed_candidates[section_key] = replacement
		_installed_receipts[section_key] = _active_boundary.receipts[section_key]
		_replay_pov_waiting_revision_by_section.erase(section_key)
		_replay_set.erase(section_key)
		_replay_queue.erase(section_key)
	_active_boundary.clear()
	return {"status":"committed", "boundaryId":boundary_id,
		"worldId":_world_id, "changedSourceParts":accepted.changedSourceParts,
		"sectionKeys":section_keys,
		"sourcePartCount":accepted.sourcePartCount}


func _unsupported_active(reason: String) -> Dictionary:
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	var cancelled := _cancel_active_boundary("unsupported:" + reason)
	if cancelled.get("status") != "cancelled":
		return cancelled
	if not boundary_id.is_empty():
		_ledger.abort_boundary(boundary_id)
	return {"status":"unsupported", "reason":reason,
		"boundaryId":boundary_id, "retryable":false, "requiresResubmit":true}


func _abort_active(reason: String) -> Dictionary:
	if _active_boundary.is_empty():
		return _failed(reason)
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	var cancelled := _cancel_active_boundary("abort:" + reason)
	if cancelled.get("status") != "cancelled":
		return cancelled
	if not boundary_id.is_empty():
		_ledger.abort_boundary(boundary_id)
	return {"status":"failed", "reason":reason, "boundaryId":boundary_id}


func _cancel_active_boundary(context: String) -> Dictionary:
	if _active_boundary.is_empty():
		return {"status":"cancelled"}
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	var session = _active_boundary.get("installSession")
	if session is RefCounted and session.has_method("cancel"):
		var cancelled: Dictionary = session.cancel()
		if cancelled.get("status") != "cancelled":
			_active_boundary["stage"] = "rollback_failed"
			_active_boundary["rollbackFailure"] = cancelled.duplicate(true)
			return {"status":"rollback_failed", "stage":"rollback",
				"reason":"active_section_boundary_rollback_failed",
				"context":context, "boundaryId":boundary_id,
				"rollback":cancelled, "retryable":true}
	_active_boundary.clear()
	return {"status":"cancelled", "boundaryId":boundary_id}


func _queue_replay(section_key: Vector3i) -> void:
	if _dirty_source_sections.has(section_key) or _replay_set.has(section_key) \
			or not _committed_candidates.has(section_key):
		return
	_replay_set[section_key] = true
	_replay_queue.append(section_key)


func _promote_replay_reassembly_to_visible_demand(section_key: Vector3i) -> bool:
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	if state.is_empty():
		return false
	state.erase("candidateGeneration")
	state.erase("pendingCandidateStage")
	state.erase("blockedReason")
	state.erase("continuationHint")
	state["stage"] = "waiting"
	state["urgentRecompile"] = true
	state["priority"] = 0.0
	state["attempts"] = 0
	state["nextAttemptFrame"] = Engine.get_process_frames()
	state["lastWakeReason"] = "stale_replay_requires_authoritative_reassembly"
	if not bool(state.get("queued", false)):
		_enqueue_visible_section_demand(section_key, state)
	_visible_section_demands[section_key] = state
	return true


func _candidate_has_section_attachments(candidate: Dictionary) -> bool:
	var envelope: Variant = candidate.get("candidate", candidate)
	if not envelope is Dictionary: return false
	var snapshot: Variant = envelope.get("snapshot", {})
	if not snapshot is Dictionary: return false
	var batches: Variant = snapshot.get("batches", {})
	if not batches is Dictionary: return false
	for batch_value: Variant in batches.values():
		if batch_value is Dictionary and not String(batch_value.get("attachmentKey", "")).is_empty():
			return true
	return false


func _defer_stale_replay_to_authoritative_reassembly(section_key: Vector3i,
		current_pov_revision: int, dependency_reason: String = "") -> Dictionary:
	_replay_pov_waiting_revision_by_section.erase(section_key)
	_replay_reassembly_required_by_section[section_key] = {
		"requiredAfterPovRevision":current_pov_revision,
		"requestedFrame":Engine.get_process_frames()}
	_replay_set.erase(section_key)
	_replay_queue.erase(section_key)
	var demand_queued := _promote_replay_reassembly_to_visible_demand(section_key)
	return {"status":"pending", "stage":"authoritative_reassembly",
		"reason":"stale_replay_candidate_requires_provider_recapture",
		"dependencyReason":dependency_reason,
		"sectionKey":section_key, "currentPovRevision":current_pov_revision,
		"requiresAuthoritativeReassembly":true,
		"reassemblyDemandQueued":demand_queued, "retryable":true}


func _cancel_stale_replay_for_section(section_key: Vector3i) -> Dictionary:
	if not _active_replay.is_empty() and _active_replay.get("sectionKey") == section_key:
		var cancelled := _cancel_active_replay("authoritative_source_invalidation")
		if cancelled.get("status") != "cancelled":
			return cancelled
	_replay_pov_waiting_revision_by_section.erase(section_key)
	if _replay_set.has(section_key):
		_replay_set.erase(section_key)
		_replay_queue.erase(section_key)
	return {"status":"cancelled", "sectionKey":section_key}


func _cancel_active_replay(context: String) -> Dictionary:
	if _active_replay.is_empty():
		return {"status":"cancelled"}
	var section_value: Variant = _active_replay.get("sectionKey", null)
	var session = _active_replay.get("installSession")
	if session is RefCounted and session.has_method("cancel"):
		var cancelled: Dictionary = session.cancel()
		if cancelled.get("status") != "cancelled":
			_active_replay["stage"] = "rollback_failed"
			_active_replay["rollbackFailure"] = cancelled.duplicate(true)
			return {"status":"rollback_failed", "stage":"rollback",
				"reason":"active_section_replay_rollback_failed",
				"context":context, "sectionKey":section_value,
				"rollback":cancelled, "retryable":true}
	_active_replay.clear()
	return {"status":"cancelled", "sectionKey":section_value}


func _valid_revision_map(value: Dictionary) -> bool:
	if not value.is_read_only():
		return false
	for key_value: Variant in value:
		if not key_value is String or String(key_value).is_empty() \
				or not value[key_value] is String or String(value[key_value]).is_empty():
			return false
	return true


func _valid_census_map(value: Dictionary) -> bool:
	if not value.is_read_only():
		return false
	for section_value: Variant in value:
		var contributors: Variant = value[section_value]
		if not section_value is Vector3i or not contributors is Array \
				or not contributors.is_read_only():
			return false
		for contributor_value: Variant in contributors:
			if not contributor_value is String or String(contributor_value).is_empty():
				return false
	return true


func _copy_census_for_replacements(replacements: Array,
		census: Dictionary) -> Dictionary:
	var copied: Dictionary = {}
	for replacement_value: Variant in replacements:
		var key: Vector3i = replacement_value.sectionKey
		copied[key] = census[key]
	copied.make_read_only()
	return copied


func _has_boundary_id(boundary_id: String) -> bool:
	if String(_active_boundary.get("boundaryId", "")) == boundary_id:
		return true
	for request: Dictionary in _boundary_queue:
		if String(request.get("boundaryId", "")) == boundary_id:
			return true
	return false


func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
