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
## Current renderer support is opaque instance batches whose section residency
## dependencies all fit the canonical owner stream chunk. Cross-chunk candidates
## stay rejected by NativeStaticSectionInstallSession until an external owner
## can positively pin and validate every dependency chunk generation.

const LedgerScript = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const InstallSession = preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")

var _ledger = LedgerScript.new()
var _world_id := ""
var _boundary_queue: Array[Dictionary] = []
var _active_boundary: Dictionary = {}
var _generation := 0
var _committed_candidates: Dictionary = {}
var _installed_receipts: Dictionary = {}
var _replay_queue: Array[Vector3i] = []
var _replay_set: Dictionary = {}
var _active_replay: Dictionary = {}


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


## Rebind after the caller has cancelled/retired every install and replay
## session and removed this coordinator's installed section slots from the old
## world. The coordinator cannot retire renderer resources on the caller's
## behalf. This is a world-lifetime boundary, not an in-place seed mutation.
func reset_for_world(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_world_identity")
	if not _active_boundary.is_empty() or not _boundary_queue.is_empty() \
			or not _active_replay.is_empty() or not _replay_queue.is_empty():
		return _failed("world_reset_has_pending_section_work")
	_world_id = world_id
	_ledger = LedgerScript.new()
	_generation = 0
	_committed_candidates.clear()
	_installed_receipts.clear()
	_replay_set.clear()
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
		return {"status":"cancelled", "boundaryId":boundary_id}
	for index in range(_boundary_queue.size()):
		if String(_boundary_queue[index].get("boundaryId", "")) == boundary_id:
			_boundary_queue.remove_at(index)
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
		# First coordinator gate is deliberately single-slot. Installing several
		# section slots and then discovering a stale later source would require
		# restoring earlier slots. Do not claim group atomicity without that path.
		if prepared.replacements.size() != 1:
			return _unsupported_active("boundary_requires_exactly_one_impacted_section")
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
		_queue_replay(section_key)
		queued += 1
	return queued


func notify_stream_chunk_loaded(owner_cell: Vector2i) -> int:
	var queued := 0
	for section_value: Variant in _committed_candidates:
		var section_key: Vector3i = section_value
		if SectionGrid.chunk_key_for_section(section_key) == owner_cell:
			_queue_replay(section_key)
			queued += 1
	return queued


func request_section_replay(section_key: Vector3i) -> bool:
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
		return _failed("section_source_census_key_set_mismatch")
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
	var current: Dictionary = PacketOwner.resolve_existing_scene_backend(owner_cell)
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


func _promote_active_boundary(current_source_revisions: Dictionary,
		expected_contributors_by_section: Dictionary) -> Dictionary:
	var boundary_id := String(_active_boundary.boundaryId)
	var candidate: Dictionary = _active_boundary.candidate
	var replacement: Dictionary = candidate.replacements[0]
	var section_key: Vector3i = replacement.sectionKey
	var receipt: Dictionary = _active_boundary.receipts.get(section_key, {})
	if not _receipt_is_live(replacement, receipt):
		_active_boundary.receipts.erase(section_key)
		_active_boundary.replacementIndex = 0
		return {"status":"pending_owner", "reason":"section_receipt_no_longer_live",
			"boundaryId":boundary_id, "sectionKey":section_key, "retryable":true}
	var changed_again := _changed_revision_snapshot(_active_boundary, current_source_revisions)
	if changed_again.get("status") != "ready":
		return _abort_active(String(changed_again.get("reason", "stale_source_revision_before_promotion")))
	var final_census := _validate_candidate_census(candidate.replacements,
		expected_contributors_by_section, current_source_revisions)
	if final_census.get("status") != "ready":
		return _abort_active(String(final_census.get("reason", "stale_section_source_census_before_promotion")))
	var receipts: Array[Dictionary] = [receipt]
	receipts.make_read_only()
	var accepted: Dictionary = _ledger.accept_installed_candidate(boundary_id,
		receipts, changed_again.revisions)
	if accepted.get("status") != "committed":
		return _abort_active(String(accepted.get("reason", "section_candidate_promotion_failed")))
	_committed_candidates[section_key] = replacement
	_installed_receipts[section_key] = receipt
	_replay_set.erase(section_key)
	_replay_queue.erase(section_key)
	_active_boundary.clear()
	return {"status":"committed", "boundaryId":boundary_id,
		"worldId":_world_id, "changedSourceParts":accepted.changedSourceParts,
		"sectionKeys":accepted.impactedSectionKeys,
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
	if _replay_set.has(section_key) or not _committed_candidates.has(section_key):
		return
	_replay_set[section_key] = true
	_replay_queue.append(section_key)


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
