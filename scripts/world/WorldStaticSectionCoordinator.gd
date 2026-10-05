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
## provide a fresh source-revision map and an exact section->sourcePartId census
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

const MAX_VISIBLE_SECTION_DEMAND_SCAN_PER_ADVANCE := 32
const VISIBLE_SECTION_DEMAND_RETRY_FRAMES := 30
const MAX_SOURCE_INVALIDATION_SECTIONS := 64

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
var _production_candidate_receipts: Dictionary = {}
var _production_candidate_generation := 0
var _visible_sections_by_source_id: Dictionary = {}
var _dirty_source_sections: Dictionary = {}
var _visible_section_demands: Dictionary = {}
var _visible_section_demand_queue: Array[Dictionary] = []
var _visible_section_demand_head := 0
var _visible_section_demand_tail := 0
var _visible_section_demand_count := 0
var _visible_section_demand_queue_token := 0
var _visible_section_demand_attempts := 0
var _visible_section_recompile_quota := 2
var _visible_section_demand_wake_rounds := 0


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


func configure_source_roster(required_provider_ids: Array[String]) -> Dictionary:
	if _world_id.is_empty():
		return _failed("world_static_section_coordinator_unconfigured")
	return _source_roster.bind_world(_world_id, required_provider_ids)


func register_source_provider(provider_id: String, authority_owner: Object,
		capture_method: String) -> Dictionary:
	var registered: Dictionary = _source_roster.register_provider(provider_id,
		authority_owner, capture_method)
	if registered.get("status") == "ready":
		_wake_visible_section_demands()
	return registered


func unregister_source_provider(provider_id: String, authority_owner: Object) -> Dictionary:
	var unregistered: Dictionary = _source_roster.unregister_provider(provider_id, authority_owner)
	if unregistered.get("status") == "ready":
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
			_cancel_pending_production_candidate(section_key)
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
			state["nextAttemptFrame"] = Engine.get_process_frames()
			state.erase("candidateGeneration")
			state.erase("installedGeneration")
			state.erase("installedReceipt")
			if not bool(state.get("queued", false)):
				_enqueue_visible_section_demand(section_key, state)
		_visible_section_demands[section_key] = state
	return {"status":"queued" if state.get("stage") == "waiting" else "tracked",
		"sectionKey":section_key, "stage":String(state.get("stage", "waiting")),
		"terrainRevision":revision}


## Rebuild a demanded section after an authoritative contributor changes. The
## old accepted candidate and renderer receipt remain owned until a replacement
## receives a current native install acknowledgement.
func invalidate_visible_section_source(section_key: Vector3i, provider_id: String,
		source_id: String, source_revision: String) -> Dictionary:
	if provider_id.strip_edges().is_empty() or source_id.strip_edges().is_empty() \
			or source_revision.strip_edges().is_empty():
		return _failed("invalid_visible_section_source_invalidation")
	var state: Dictionary = _visible_section_demands.get(section_key, {})
	var dirty_sources: Dictionary = _dirty_source_sections.get(section_key, {})
	dirty_sources[source_id] = {"providerId":provider_id,
		"sourceRevision":source_revision, "requestedFrame":Engine.get_process_frames()}
	_dirty_source_sections[section_key] = dirty_sources
	_cancel_stale_replay_for_section(section_key)
	if state.is_empty():
		return {"status":"deferred", "reason":"section_not_currently_demanded",
			"retryable":true, "dirtyRetained":true,
			"sectionKey":section_key, "providerId":provider_id, "sourceId":source_id}
	var previous_generation := int(state.get("installedGeneration", 0))
	_cancel_pending_production_candidate(section_key)
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
	for source_id: String in _section_candidate_source_revisions(previous):
		var sections: Dictionary = _visible_sections_by_source_id.get(source_id, {})
		sections.erase(section_key)
		if sections.is_empty():
			_visible_sections_by_source_id.erase(source_id)
		else:
			_visible_sections_by_source_id[source_id] = sections
	var replacement_source_revisions := _section_candidate_source_revisions(replacement)
	for source_id: String in replacement_source_revisions:
		var sections: Dictionary = _visible_sections_by_source_id.get(source_id, {})
		sections[section_key] = String(replacement_source_revisions[source_id])
		_visible_sections_by_source_id[source_id] = sections


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
	_visible_section_demands.erase(section_key)
	_cancel_pending_production_candidate(section_key)
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
	return {"status":"advanced" if updated > 0 else "idle", "updatedCount":updated,
		"pendingDemandCount":_visible_section_demands.size()}


## Admit at most a small number of visible demands. Selection examines a bounded
## queue window, prioritizes nearby first-time sections, and grants at most two
## nearer recompiles before giving an initial section its turn. Pending providers
## stay queued with delayed retries instead of rescanning every section each frame.
func advance_visible_section_candidate_demands(max_attempts := 1,
		urgent_only := false) -> Dictionary:
	if max_attempts < 1 or max_attempts > 4:
		return _failed("invalid_visible_section_candidate_attempt_budget")
	var results: Array[Dictionary] = []
	for _attempt_index in range(max_attempts):
		var selected: Dictionary = _take_next_visible_section_demand(urgent_only)
		if selected.get("status") != "ready":
			break
		var section_key: Vector3i = selected.sectionKey
		var state: Dictionary = selected.state
		_production_candidate_generation += 1
		var admission: Dictionary = assemble_and_submit_complete_section_candidate(
			section_key, _production_candidate_generation)
		state["attempts"] = int(state.get("attempts", 0)) + 1
		state["lastReason"] = String(admission.get("reason", ""))
		state["lastStatus"] = String(admission.get("status", "failed"))
		state["lastAdmissionDetails"] = _visible_section_admission_details(admission)
		if admission.get("status") == "queued":
			state["stage"] = "candidate_queued"
			state["candidateGeneration"] = _production_candidate_generation
			state.erase("blockedReason")
		else:
			var retryable: bool = admission.get("status") == "pending" \
				or bool(admission.get("retryable", false))
			state["stage"] = "waiting" if retryable else "blocked"
			if retryable:
				state.erase("blockedReason")
			else:
				state["blockedReason"] = String(admission.get("reason", admission.get("status", "failed")))
			state["nextAttemptFrame"] = Engine.get_process_frames() \
				+ VISIBLE_SECTION_DEMAND_RETRY_FRAMES
			if retryable:
				_enqueue_visible_section_demand(section_key, state)
		_visible_section_demands[section_key] = state
		results.append({"sectionKey":section_key, "terrainRevision":state.terrainRevision,
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
		if _production_candidates_by_section.has(section_key):
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
			"snapshotRemovedPropsRevision",
			"currentRemovedPropsRevision", "snapshotSourceRevision", "currentSourceRevision",
			"requestedSection", "ownedSection"]:
		if admission.has(key):
			result[key] = admission[key]
	if admission.has("providerReason"):
		result["providerReason"] = String(admission.get("providerReason", ""))
	var provider_details: Variant = admission.get("providerDetails", {})
	if provider_details is Dictionary:
		for key in ["chunk", "sourceId", "sourcePartId", "cell", "blockType",
				"missingCategories", "categoryEvidence",
				"snapshotRemovedPropsRevision", "currentRemovedPropsRevision",
				"snapshotSourceRevision", "currentSourceRevision",
				"snapshotValidationStatus", "snapshotValidationReason"]:
			if provider_details.has(key):
				result[key] = provider_details[key]
	var validation_value: Variant = admission.get("snapshotValidation", null)
	if validation_value is Dictionary:
		result["snapshotValidationStatus"] = String(validation_value.get("status", ""))
		result["snapshotValidationReason"] = String(validation_value.get("reason", ""))
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


func _cancel_pending_production_candidate(section_key: Vector3i) -> void:
	var job: Dictionary = _production_candidate_jobs.get(section_key, {})
	if job.is_empty():
		return
	var session = job.get("session")
	if session is RefCounted and session.has_method("cancel"):
		session.cancel()
	_production_candidate_jobs.erase(section_key)


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
		candidate_generation: int) -> Dictionary:
	if candidate_generation <= 0:
		return _failed("invalid_complete_section_candidate_generation")
	var phase_usec := {}
	var phase_started_usec := Time.get_ticks_usec()
	var census: Dictionary = capture_authoritative_source_census([section_key])
	phase_usec["census"] = Time.get_ticks_usec() - phase_started_usec
	var census_provider_times: Variant = census.get("providerPhaseUsec", {})
	if census_provider_times is Dictionary:
		for provider_id_value: Variant in census_provider_times:
			phase_usec["census_provider_" + String(provider_id_value)] = int(
				census_provider_times[provider_id_value])
	if census.get("status") != "complete":
		return _with_candidate_phase_timings(census, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	var captured: Dictionary = _source_roster.capture_section_contributions(
		census, section_key)
	phase_usec["contributions"] = Time.get_ticks_usec() - phase_started_usec
	if captured.get("status") != "complete":
		return _with_candidate_phase_timings(captured, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	var assembled: Dictionary = CandidateAssembler.assemble(census, section_key,
		captured.get("contributions", []), candidate_generation)
	phase_usec["assembly"] = Time.get_ticks_usec() - phase_started_usec
	if assembled.get("status") != "ready":
		return _with_candidate_phase_timings(assembled, phase_usec)
	phase_started_usec = Time.get_ticks_usec()
	var admitted: Dictionary = submit_complete_section_candidate(assembled.candidate)
	phase_usec["submit_and_revalidate"] = Time.get_ticks_usec() - phase_started_usec
	if admitted.get("status") != "queued":
		return _with_candidate_phase_timings(admitted, phase_usec)
	return _with_candidate_phase_timings({"status":"queued", "sectionKey":section_key,
		"generation":candidate_generation, "censusDigest":String(census.censusDigest),
		"contentManifestDigest":String(assembled.contentManifestDigest),
		"providerCount":int(assembled.providerCount),
		"sourceCount":int(assembled.sourceCount), "inputCount":int(assembled.inputCount)},
		phase_usec)


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
	var section_key: Vector3i = section_value
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
			session.cancel()
	_production_candidate_jobs[section_key] = {"candidate":candidate,
		"session":null, "stage":"queued"}
	return {"status":"queued", "sectionKey":section_key,
		"generation":int(generation_value),
		"replacedPendingGeneration":int(existing.get("candidate", {}).get("generation", 0))}


## Revalidates the full provider census before each staging/upload/commit step.
## A stale candidate is aborted while the old native slot remains visible.
func advance_complete_section_candidate(section_key: Vector3i,
		max_upload_units := 1) -> Dictionary:
	if max_upload_units < 1 or max_upload_units > 64:
		return _failed("invalid_complete_section_upload_budget")
	var job: Dictionary = _production_candidate_jobs.get(section_key, {})
	if job.is_empty():
		return {"status":"idle", "sectionKey":section_key}
	var candidate: Dictionary = job.get("candidate", {})
	var census: Dictionary = _source_roster.capture_sections([section_key])
	if census.get("status") != "complete" \
			or String(census.get("censusDigest", "")) != String(candidate.get("censusDigest", "")):
		var stale_session = job.get("session")
		if stale_session is RefCounted and stale_session.has_method("cancel"):
			stale_session.cancel()
		_production_candidate_jobs.erase(section_key)
		var stale_result := {"status":"pending", "stage":"source_census",
			"reason":String(census.get("reason", "complete_section_candidate_census_changed")),
			"retryable":true, "sectionKey":section_key,
			"requiresReassembly":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), stale_result)
		return stale_result
	var session = job.get("session")
	if session == null:
		var started: Dictionary = PacketOwner.begin_static_section_install(candidate,
			candidate.get("materialBindings", {}), candidate.get("meshBindings", {}))
		if started.get("status") == "pending":
			var owner_pending := {"status":"pending_owner", "reason":String(started.get("reason", "")),
				"sectionKey":section_key, "retryable":true}
			_reconcile_visible_section_candidate_outcome(section_key,
				int(candidate.get("generation", 0)), owner_pending)
			return owner_pending
		if started.get("status") != "ready":
			_production_candidate_jobs.erase(section_key)
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
	var step: Dictionary = session.advance(max_upload_units)
	if step.get("status") == "pending":
		job["stage"] = String(step.get("stage", "installing"))
		_production_candidate_jobs[section_key] = job
		var install_pending := {"status":"pending", "stage":String(job.stage),
			"reason":String(step.get("reason", "")), "sectionKey":section_key,
			"generation":int(candidate.get("generation", 0)), "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), install_pending)
		return install_pending
	if step.get("status") == "failed" and String(step.get("reason", "")) == "section_install_owner_replaced":
		job["session"] = null
		job["stage"] = "owner_replaced"
		_production_candidate_jobs[section_key] = job
		var owner_replaced := {"status":"pending_owner", "reason":String(step.reason),
			"sectionKey":section_key, "retryable":true}
		_reconcile_visible_section_candidate_outcome(section_key,
			int(candidate.get("generation", 0)), owner_replaced)
		return owner_replaced
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
			stale_owner_session.cancel()
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
	_replace_section_source_index(section_key, previous_candidate, candidate)
	_production_candidates_by_section[section_key] = candidate
	_production_candidate_receipts[section_key] = receipt
	_dirty_source_sections.erase(section_key)
	_production_candidate_jobs.erase(section_key)
	var acknowledgement_receipt: Dictionary = receipt.duplicate(true)
	acknowledgement_receipt.make_read_only()
	var provider_acknowledgements: Dictionary = _source_roster.acknowledge_section_install(
		section_key, candidate.get("providerCoverage", []), acknowledgement_receipt)
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
	var section_keys: Array[Vector3i] = []
	for section_value: Variant in _production_candidate_jobs:
		if section_value is Vector3i:
			section_keys.append(Vector3i(section_value))
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var results: Array[Dictionary] = []
	for index in range(mini(max_sections, section_keys.size())):
		results.append(advance_complete_section_candidate(section_keys[index], max_upload_units))
	results.make_read_only()
	return {"status":"advanced" if not results.is_empty() else "idle",
		"sectionCount":results.size(), "results":results}


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
	for part_id_value: Variant in removal_revisions:
		var part_id := String(part_id_value)
		if part_id.is_empty() or not removal_revisions[part_id_value] is String \
				or current_source_revisions.has(part_id):
			return _failed("invalid_or_current_roster_removal_revision:" + part_id)
		current_source_revisions[part_id] = String(removal_revisions[part_id_value])
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
			or not _production_candidate_jobs.is_empty() \
			or not _visible_section_demands.is_empty():
		return _failed("world_reset_has_pending_section_work")
	_world_id = world_id
	_ledger = LedgerScript.new()
	_source_roster = SourceRoster.new()
	_generation = 0
	_production_candidate_generation = 0
	_committed_candidates.clear()
	_installed_receipts.clear()
	_production_candidates_by_section.clear()
	_production_candidate_jobs.clear()
	_production_candidate_receipts.clear()
	_visible_sections_by_source_id.clear()
	_dirty_source_sections.clear()
	_visible_section_demands.clear()
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
		var session = _active_boundary.get("installSession")
		if session is RefCounted and session.has_method("cancel"):
			session.cancel()
		_ledger.abort_boundary(boundary_id)
		_active_boundary.clear()
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
## - current_source_revisions: sourcePartId -> current revision, including the
##   boundary's removal tombstone revisions until that boundary is accepted;
## - expected_contributors_by_section: sectionKey -> exact sorted or unsorted
##   Array[String] of all current sourcePartIds expected in that section.
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
				replacement, material_bindings, mesh_bindings)
			if started.get("status") == "pending":
				return {"status":"pending_owner", "reason":started.get("reason", ""),
					"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
			if started.get("status") != "ready":
				if String(started.get("reason", "")) == "section_residency_dependency_not_pinned":
					return _unsupported_active(String(started.reason))
				return _abort_active(String(started.get("reason", "section_install_begin_failed")))
			_active_boundary.installSession = started.session
			session = started.session
		var step: Dictionary = session.advance(max_upload_units)
		if step.get("status") == "pending":
			return {"status":"pending", "stage":String(step.get("stage", "section_install")),
				"reason":String(step.get("reason", "")), "boundaryId":boundary_id,
				"sectionKey":section_key, "retryable":true}
		if step.get("status") != "installed":
			var reason := String(step.get("reason", "section_install_failed"))
			if reason == "section_install_owner_replaced":
				_active_boundary.installSession = null
				return {"status":"pending_owner", "reason":reason,
					"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
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
	var queued := 0
	for section_value: Variant in _committed_candidates:
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) != owner_cell:
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
		var job: Dictionary = _production_candidate_jobs.get(section_key, {})
		var session = job.get("session")
		if session is RefCounted and session.has_method("cancel"):
			session.cancel()
		_production_candidate_jobs.erase(section_key)
		_production_candidate_receipts.erase(section_key)
		queued += 1
	return queued


func notify_stream_chunk_loaded(owner_cell: Vector2i) -> int:
	var queued := 0
	for section_value: Variant in _committed_candidates:
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) == owner_cell \
				and not _dirty_source_sections.has(section_key):
			_queue_replay(section_key)
			queued += 1
	for section_value: Variant in _production_candidates_by_section:
		if not section_value is Vector3i:
			continue
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) != owner_cell \
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
		var session = _active_replay.get("installSession")
		if session is RefCounted and session.has_method("cancel"):
			session.cancel()
		_active_replay.clear()
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
		return _advance_replay_session(current_source_revisions,
			expected_contributors_by_section, material_bindings, mesh_bindings,
			max_upload_units)
	while not _replay_queue.is_empty():
		var section_key: Vector3i = _replay_queue.pop_front()
		_replay_set.erase(section_key)
		if _dirty_source_sections.has(section_key):
			continue
		if not _committed_candidates.has(section_key):
			continue
		var candidate: Dictionary = _committed_candidates[section_key]
		var check := _validate_candidate_census([candidate],
			expected_contributors_by_section, current_source_revisions)
		if check.get("status") != "ready":
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
		or not _active_replay.is_empty() or not _replay_queue.is_empty()


func status() -> Dictionary:
	return {"status":"busy" if has_pending_work() else "idle", "worldId":_world_id,
		"queuedBoundaries":_boundary_queue.size(),
		"activeBoundaryId":String(_active_boundary.get("boundaryId", "")),
		"queuedReplaySections":_replay_queue.size(),
		"activeReplaySection":_active_replay.get("sectionKey"),
		"committedSourcePartIds":_ledger.committed_source_part_ids(),
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
		var stale_replay_session = _active_replay.get("installSession")
		if stale_replay_session is RefCounted and stale_replay_session.has_method("cancel"):
			stale_replay_session.cancel()
		_active_replay.clear()
		return {"status":"deferred_dirty", "reason":"section_has_dirty_source",
			"sectionKey":section_key, "retryable":true}
	var current_check := _validate_candidate_census([candidate],
		expected_contributors_by_section, current_source_revisions)
	if current_check.get("status") != "ready":
		_active_replay.clear()
		return {"status":"failed", "reason":current_check.get("reason", "stale_section_replay_source"),
			"sectionKey":section_key}
	var session = _active_replay.get("installSession")
	if session == null:
		var started: Dictionary = PacketOwner.begin_static_section_install(
			candidate, material_bindings, mesh_bindings)
		if started.get("status") == "pending":
			return {"status":"pending_owner", "sectionKey":section_key,
				"reason":started.get("reason", ""), "retryable":true}
		if started.get("status") != "ready":
			_active_replay.clear()
			if String(started.get("reason", "")) == "section_residency_dependency_not_pinned":
				_queue_replay(section_key)
				return {"status":"unsupported", "reason":String(started.reason),
					"sectionKey":section_key, "retryable":true}
			return _failed(String(started.get("reason", "section_replay_begin_failed")))
		_active_replay.installSession = started.session
		session = started.session
	var step: Dictionary = session.advance(max_upload_units)
	if step.get("status") == "pending":
		return {"status":"pending", "sectionKey":section_key,
			"stage":step.get("stage", "section_replay"),
			"reason":step.get("reason", ""), "retryable":true}
	if step.get("status") != "installed":
		var reason := String(step.get("reason", "section_replay_failed"))
		if reason == "section_install_owner_replaced":
			_active_replay.installSession = null
			return {"status":"pending_owner", "sectionKey":section_key,
				"reason":reason, "retryable":true}
		_active_replay.clear()
		return _failed(reason)
	var receipt: Dictionary = step.get("receipt", {})
	if not _receipt_is_live(candidate, receipt):
		_active_replay.installSession = null
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
			var part_id := String(contributor.get("sourcePartId", ""))
			var revision := String(contributor.get("sourceRevision", ""))
			if part_id.is_empty() or revision.is_empty() or actual_seen.has(part_id):
				return _failed("invalid_or_duplicate_candidate_contributor")
			actual_seen[part_id] = true
			actual_ids.append(part_id)
			if not current_source_revisions.has(part_id) \
					or String(current_source_revisions[part_id]) != revision:
				return _failed("section_candidate_contributor_revision_stale:" + part_id)
		actual_ids.sort()
		if actual_ids != expected_ids:
			return _failed("section_candidate_contributor_census_mismatch:" + str(section_key))
	return {"status":"ready"}


func _changed_revision_snapshot(request: Dictionary,
		current_source_revisions: Dictionary) -> Dictionary:
	var expected: Dictionary = {}
	for declaration_value: Variant in request.declarations:
		var declaration: Dictionary = declaration_value
		var part_id := String(declaration.get("sourcePartId", ""))
		var revision := String(declaration.get("sourceRevision", ""))
		if part_id.is_empty() or not current_source_revisions.has(part_id) \
				or String(current_source_revisions[part_id]) != revision:
			return _failed("stale_source_revision:" + part_id)
		expected[part_id] = revision
	for removal_value: Variant in request.removals:
		var removal: Dictionary = removal_value
		var part_id := String(removal.get("sourcePartId", ""))
		var revision := String(removal.get("sourceRevision", ""))
		if part_id.is_empty() or not current_source_revisions.has(part_id) \
				or String(current_source_revisions[part_id]) != revision:
			return _failed("stale_removal_revision:" + part_id)
		expected[part_id] = revision
	expected.make_read_only()
	return {"status":"ready", "revisions":expected}


func _receipt_is_live(candidate: Dictionary, receipt: Dictionary) -> bool:
	if receipt.is_empty() or not receipt.is_read_only() \
			or receipt.get("status") != "installed" \
			or String(receipt.get("worldId", "")) != String(candidate.get("worldId", "")) \
			or receipt.get("sectionKey") != candidate.get("sectionKey") \
			or int(receipt.get("generation", 0)) != int(candidate.get("generation", 0)) \
			or String(receipt.get("contentManifestDigest", "")) != String(candidate.get("contentManifestDigest", "")):
		return false
	var section_key: Vector3i = candidate.sectionKey
	var owner_cell := SectionGrid.chunk_key_for_section(section_key)
	if receipt.get("ownerCell") != owner_cell:
		return false
	var current: Dictionary = PacketOwner.resolve_existing_static_section_backend(owner_cell)
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
	var source_revision := "%s:%d" % [_world_id, generation]
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


func installed_section_receipt_is_current(section_key: Vector3i,
		receipt: Dictionary) -> bool:
	var candidate: Dictionary = _production_candidates_by_section.get(section_key, {})
	var current_receipt: Dictionary = _production_candidate_receipts.get(section_key, {})
	return not candidate.is_empty() and not current_receipt.is_empty() \
		and int(current_receipt.get("generation", 0)) == int(receipt.get("generation", -1)) \
		and String(current_receipt.get("contentManifestDigest", "")) \
			== String(receipt.get("contentManifestDigest", "")) \
		and _receipt_is_live(candidate, current_receipt)


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
		_replay_set.erase(section_key)
		_replay_queue.erase(section_key)
	_active_boundary.clear()
	return {"status":"committed", "boundaryId":boundary_id,
		"worldId":_world_id, "changedSourceParts":accepted.changedSourceParts,
		"sectionKeys":section_keys,
		"sourcePartCount":accepted.sourcePartCount}


func _unsupported_active(reason: String) -> Dictionary:
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	var session = _active_boundary.get("installSession")
	if session is RefCounted and session.has_method("cancel"):
		session.cancel()
	if not boundary_id.is_empty():
		_ledger.abort_boundary(boundary_id)
	_active_boundary.clear()
	return {"status":"unsupported", "reason":reason,
		"boundaryId":boundary_id, "retryable":false, "requiresResubmit":true}


func _abort_active(reason: String) -> Dictionary:
	if _active_boundary.is_empty():
		return _failed(reason)
	var boundary_id := String(_active_boundary.get("boundaryId", ""))
	var session = _active_boundary.get("installSession")
	if session is RefCounted and session.has_method("cancel"):
		session.cancel()
	if not boundary_id.is_empty():
		_ledger.abort_boundary(boundary_id)
	_active_boundary.clear()
	return {"status":"failed", "reason":reason, "boundaryId":boundary_id}


func _queue_replay(section_key: Vector3i) -> void:
	if _dirty_source_sections.has(section_key) or _replay_set.has(section_key) \
			or not _committed_candidates.has(section_key):
		return
	_replay_set[section_key] = true
	_replay_queue.append(section_key)


func _cancel_stale_replay_for_section(section_key: Vector3i) -> void:
	if not _active_replay.is_empty() and _active_replay.get("sectionKey") == section_key:
		var session = _active_replay.get("installSession")
		if session is RefCounted and session.has_method("cancel"):
			session.cancel()
		_active_replay.clear()
	if _replay_set.has(section_key):
		_replay_set.erase(section_key)
		_replay_queue.erase(section_key)


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
