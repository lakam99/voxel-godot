extends RefCounted
class_name NativeTerrainLoadTransaction

## Stages a save-v2 native backend without making it authoritative early.
## start() snapshots only the small source descriptor; callers must keep the
## supplied terrainVolume value stable until commit or acknowledged drain.
## advance() admits at most `max_records_per_advance` cells (never above the
## C++ adapter's 256-record append contract) or polls one async lifecycle step.
## A ready candidate remains private until commit(candidate_source_identity()),
## after which take_backend() transfers the one authoritative native owner.

const DEFAULT_RECORDS_PER_ADVANCE := 256
const MAX_RECORDS_PER_ADVANCE := 256
const MAX_TOTAL_RECORDS := 65536
const MAX_CELLS_PER_SECTION := 4096
const SOURCE_SCHEMA := "n3-native-world-backend-initialize/v1"
const SAVE_SOURCE_SCHEMA := "n3-native-world-backend-initialize-from-save-v2/v1"

var _backend
var _backend_factory: Callable
var _input_request: Dictionary = {}
var _input_owner
var _snapshot_lease
var _sections: Array
var _volume_revision := -1
var _generation := -1
var _section_index := 0
var _cell_index := 0
var _records_admitted := 0
var _max_records_per_advance := DEFAULT_RECORDS_PER_ADVANCE
var _state := "new"
var _failure := ""
var _candidate_source_identity: Dictionary = {}
var _last_advance_records := 0
var _advance_count := 0
var _max_advance_usec := 0
var _cancel_sent := false
var _cancel_failure := ""

## `request` is a NativeWorldSourceRequest envelope. The large terrainVolume
## subtree is deliberately not deep-copied here. Its owner must hold an
## immutable save snapshot until this transaction is committed or drained.
func start(request: Dictionary, max_records_per_advance: int = DEFAULT_RECORDS_PER_ADVANCE,
		snapshot_owner = null) -> Dictionary:
	if _state != "new": return _failed("transaction_already_started")
	if not request is Dictionary or request.is_empty(): return _failed("load_transaction_inputs_missing")
	if max_records_per_advance <= 0 or max_records_per_advance > MAX_RECORDS_PER_ADVANCE:
		return _failed("record_admission_budget_out_of_range")
	var schema := String(request.get("schema", ""))
	if schema != SOURCE_SCHEMA and schema != SAVE_SOURCE_SCHEMA:
		return _failed("native_source_request_schema_invalid")
	var seed := String(request.get("seedText", ""))
	if seed.is_empty(): return _failed("native_source_seed_missing")
	var volume_value = request.get("terrainVolume", null)
	var volume: Dictionary
	if volume_value == null:
		volume = {"schemaVersion": 1, "sectionSize": 16, "revision": 0, "sections": []}
	elif volume_value is Dictionary:
		volume = volume_value
	else:
		return _failed("terrain_volume_snapshot_invalid")
	if int(volume.get("schemaVersion", -1)) != 1 or int(volume.get("sectionSize", -1)) != 16:
		return _failed("terrain_volume_snapshot_invalid")
	if not volume.get("revision", null) is int or int(volume.revision) < 0 \
			or int(volume.revision) > 9007199254740992:
		return _failed("terrain_volume_revision_invalid")
	var sections_value = volume.get("sections", null)
	if not sections_value is Array or sections_value.size() > MAX_TOTAL_RECORDS:
		return _failed("terrain_volume_sections_invalid")
	if schema == SAVE_SOURCE_SCHEMA and String(request.get("saveSeedText", "")) != seed:
		return _failed("save_seed_mismatch")
	if schema == SAVE_SOURCE_SCHEMA:
		if not snapshot_owner is Object or not snapshot_owner.has_method("is_valid_for") \
				or not snapshot_owner.is_valid_for(volume):
			return _failed("save_snapshot_lease_required")
	elif request.has("terrainVolume"):
		return _failed("save_volume_requires_snapshot_lease")

	# Strip the potentially huge save before copying the immutable native source
	# descriptor and finalized town policy.
	var native_request: Dictionary = request.duplicate(false)
	native_request.erase("terrainVolume")
	native_request["schema"] = SOURCE_SCHEMA
	native_request["saveSeedText"] = seed
	native_request = native_request.duplicate(true)
	var import_identity := {"domain": "terrainVolume", "schemaVersion": 1,
		"sectionSize": 16, "revision": int(volume.revision)}
	_backend = _create_backend()
	if _backend == null: return _failed("native_backend_unavailable")
	# Keep the caller's canonical save envelope alive while the native importer
	# consumes its section arrays. Assignment retains the Variant owner; unlike
	# duplicate(true), it does not recursively copy the save payload.
	_input_request = request
	_input_owner = snapshot_owner if snapshot_owner != null else request
	_snapshot_lease = snapshot_owner if schema == SAVE_SOURCE_SCHEMA else null
	var begun: Dictionary = _backend.begin_staged_save_v2_initialization(native_request, import_identity)
	if begun.get("status") != "pending":
		_backend = null
		_input_request = {}
		_input_owner = null
		if _snapshot_lease != null: _snapshot_lease.release_after_drain()
		_snapshot_lease = null
		return _failed(String(begun.get("reason", "native_staged_initialization_failed")))
	_generation = int(begun.get("generation", -1))
	if _generation <= 0:
		# The backend claimed an owner but omitted its generation. Retain it and
		# report failure rather than risking destruction of an undrained import.
		_failure = "native_import_generation_missing"
		_state = "ownership_error"
		return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
	_sections = sections_value
	_volume_revision = int(volume.revision)
	_max_records_per_advance = max_records_per_advance
	_state = "accepting"
	if _sections.is_empty(): _state = "finalize_start_pending"
	return {"status": "pending", "reason": "accepting_bounded_records",
		"generation": _generation, "maxRecordsPerAdvance": _max_records_per_advance,
		"transactionId": get_instance_id(), "candidateVisible": false}

## A previously initialized backend bypasses the staged candidate/commit
## boundary, so it is intentionally not accepted by this service.
func start_backend(_backend_value, _unused = null, _unused_page: Vector2i = Vector2i.ZERO) -> Dictionary:
	return _failed("preinitialized_backend_unsupported")

func advance() -> Dictionary:
	var started := Time.get_ticks_usec()
	_advance_count += 1
	_last_advance_records = 0
	var result: Dictionary
	match _state:
		"accepting":
			if not _snapshot_lease_is_valid():
				_request_failure("save_snapshot_lease_revoked_during_admission")
				result = _pending_cleanup()
			else:
				result = _admit_bounded_records()
		"finalize_start_pending":
			if not _snapshot_lease_is_valid():
				_request_failure("save_snapshot_lease_revoked_before_finalization")
				result = _pending_cleanup()
			else:
				var finalizing: Dictionary = _backend.start_staged_save_v2_finalization(_generation)
				if finalizing.get("status") == "pending":
					_state = "finalizing"
					result = {"status": "pending", "reason": "worker_finalizing_candidate",
						"generation": _generation, "recordsAdmitted": _records_admitted}
				else:
					_request_failure(String(finalizing.get("reason", "native_finalization_start_failed")))
					result = _pending_cleanup()
		"finalizing":
			if not _snapshot_lease_is_valid():
				_request_failure("save_snapshot_lease_revoked_during_finalization")
				result = _pending_cleanup()
			else:
				result = _poll_finalization()
		"cancelling", "draining":
			result = _advance_cleanup()
		"candidate_ready":
			result = {"status": "pending", "reason": "candidate_requires_explicit_commit",
				"generation": _generation, "candidateVisible": false,
				"candidateSourceIdentity": _candidate_source_identity.duplicate(true)}
		"committed":
			result = {"status": "ready", "reason": "committed_backend_waiting_for_transfer",
				"generation": _generation, "candidateVisible": true,
				"backendInstanceId": _backend.get_instance_id() if _backend != null else 0}
		"transferred":
			result = {"status": "ready", "reason": "backend_transferred", "transferred": true}
		"failed", "drained":
			result = {"status": "failed", "reason": _failure if not _failure.is_empty() else "transaction_not_active",
				"drained": _state == "drained"}
		"ownership_error":
			result = {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
		_:
			result = {"status": "failed", "reason": "transaction_not_active"}
	_record_advance(started)
	return result

func candidate_source_identity() -> Dictionary:
	if _state != "candidate_ready": return {}
	return _candidate_source_identity.duplicate(true)

## Commit is explicit and source-identity checked. A mismatch is rejected
## locally, leaving the private candidate available for a correct owner check
## or cancellation; no native one-shot state is consumed by a bad identity.
func commit(expected_source_identity: Dictionary) -> Dictionary:
	if _state != "candidate_ready":
		return {"status": "failed", "reason": "candidate_not_ready"}
	if not _snapshot_lease_is_valid():
		_request_failure("save_snapshot_lease_revoked_before_commit")
		return {"status": "pending", "reason": _failure,
			"candidateVisible": false, "ownerMustBeRetained": true}
	if expected_source_identity != _candidate_source_identity:
		return {"status": "failed", "reason": "candidate_source_identity_mismatch",
			"candidateVisible": false, "ownerRetained": true}
	var committed: Dictionary = _backend.commit_staged_save_v2_initialization(
		_generation, expected_source_identity.duplicate(true))
	if committed.get("status") != "ready" or committed.get("committed") != true:
		_request_failure(String(committed.get("reason", "native_candidate_commit_failed")))
		return {"status": "pending", "reason": _failure, "ownerMustBeRetained": true}
	var checked: Dictionary = _backend.status()
	if checked.get("status") != "ready" or checked.get("sourceIdentity") != _candidate_source_identity:
		_failure = "committed_backend_identity_mismatch"
		_state = "ownership_error"
		return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
	_state = "committed"
	_sections = []
	return {"status": "ready", "committed": true, "generation": _generation,
		"candidateVisible": true, "sourceIdentity": _candidate_source_identity.duplicate(true),
		"backendInstanceId": _backend.get_instance_id()}

## Transfer is available only after native identity-checked commit. The returned
## RefCounted backend now becomes the new runtime owner's responsibility.
func take_backend():
	if _state != "committed" or _backend == null:
		return null
	var transferred = _backend
	_backend = null
	_input_request = {}
	_input_owner = null
	if _snapshot_lease != null: _snapshot_lease.release_after_drain()
	_snapshot_lease = null
	_state = "transferred"
	return transferred

func cancel() -> Dictionary:
	if _state == "drained": return {"status": "ready", "drained": true}
	if _state == "new":
		_state = "drained"
		return {"status": "ready", "drained": true}
	if _state == "failed": return {"status": "failed", "reason": _failure, "drained": true}
	if _state == "committed" or _state == "transferred":
		return {"status": "failed", "reason": "transaction_already_committed"}
	if _state == "ownership_error":
		return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
	_state = "cancelling"
	if _failure.is_empty(): _failure = "cancelled"
	return {"status": "pending", "reason": "cancel_requested_owner_retained",
		"generation": _generation, "ownerMustBeRetained": true}

func stop() -> Dictionary:
	return cancel()

func snapshot() -> Dictionary:
	return {"state": _state, "transactionId": get_instance_id(),
		"generation": _generation, "sectionIndex": _section_index,
		"cellIndex": _cell_index, "recordsAdmitted": _records_admitted,
		"lastAdvanceRecords": _last_advance_records,
		"maxRecordsPerAdvance": _max_records_per_advance,
		"advanceCount": _advance_count, "maxAdvanceUsec": _max_advance_usec,
		"backendInstanceId": _backend.get_instance_id() if _backend != null else 0,
		"inputSnapshotRetained": _input_owner != null,
		"ownerMustBeRetained": _backend != null,
		"candidateVisible": _state == "committed" or _state == "transferred",
		"sourceIdentity": _candidate_source_identity.duplicate(true),
		"failure": _failure,
		"snapshotLeaseValid": _snapshot_lease_is_valid()}

func _admit_bounded_records() -> Dictionary:
	if _sections == null or _section_index < 0 or _section_index > _sections.size():
		_request_failure("terrain_volume_input_owner_changed")
		return _pending_cleanup()
	if _section_index >= _sections.size():
		_state = "finalize_start_pending"
		return {"status": "pending", "reason": "save_input_admitted",
			"recordsAdmitted": _records_admitted, "generation": _generation}
	var section_value = _sections[_section_index]
	if not section_value is Dictionary:
		_request_failure("terrain_volume_section_invalid")
		return _pending_cleanup()
	var section: Dictionary = section_value
	var cells_value = section.get("cells", null)
	if not cells_value is Array or cells_value.is_empty() or cells_value.size() > MAX_CELLS_PER_SECTION:
		_request_failure("terrain_volume_section_cell_count_invalid")
		return _pending_cleanup()
	var cells: Array = cells_value
	if _cell_index < 0 or _cell_index >= cells.size():
		_request_failure("terrain_volume_input_cursor_invalid")
		return _pending_cleanup()
	var take_count := mini(_max_records_per_advance, cells.size() - _cell_index)
	if take_count <= 0 or _records_admitted > MAX_TOTAL_RECORDS - take_count:
		_request_failure("terrain_volume_record_capacity_exceeded")
		return _pending_cleanup()
	# Array.slice copies only this bounded chunk. Native parsing/copying completes
	# synchronously in append_terrain_volume_v2_import before the next frame.
	var chunk: Dictionary = section.duplicate(false)
	chunk["cells"] = cells.slice(_cell_index, _cell_index + take_count)
	var appended: Dictionary = _backend.append_terrain_volume_v2_import([chunk], _generation)
	if appended.get("status") != "pending" or appended.has("terminalStatus"):
		_request_failure(String(appended.get("failure", appended.get("reason", "native_save_append_failed"))))
		return _pending_cleanup()
	_cell_index += take_count
	_records_admitted += take_count
	_last_advance_records = take_count
	if _cell_index >= cells.size():
		_section_index += 1
		_cell_index = 0
	if _records_admitted > MAX_TOTAL_RECORDS:
		_request_failure("terrain_volume_record_capacity_exceeded")
		return _pending_cleanup()
	return {"status": "pending", "reason": "accepting_bounded_records",
		"generation": _generation, "appendedRecords": take_count,
		"recordsAdmitted": _records_admitted, "sectionsAdmitted": _section_index,
		"maxRecordsPerAdvance": _max_records_per_advance}

func _poll_finalization() -> Dictionary:
	var status: Dictionary = _backend.staged_save_v2_initialization_status(_generation)
	if status.get("reason") == "stale_import_generation":
		_state = "ownership_error"
		_failure = "staged_import_generation_lost"
		return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
	if status.get("status") == "ready" and status.get("candidateVisible") == true:
		_candidate_source_identity = status.get("candidateSourceIdentity", {}).duplicate(true)
		if _candidate_source_identity.get("algorithm") != "sha256" \
				or String(_candidate_source_identity.get("hex", "")).length() != 64:
			_request_failure("candidate_source_identity_invalid")
			return _pending_cleanup()
		_state = "candidate_ready"
		return {"status": "pending", "reason": "candidate_requires_explicit_commit",
			"generation": _generation, "candidateVisible": false,
			"candidateSourceIdentity": _candidate_source_identity.duplicate(true),
			"recordsAdmitted": _records_admitted}
	if status.get("status") == "failed":
		_request_failure(String(status.get("failure", status.get("reason", "native_save_finalization_failed"))))
		return _pending_cleanup()
	return {"status": "pending", "reason": String(status.get("reason", "worker_finalizing_candidate")),
		"generation": _generation, "workerFinished": status.get("workerFinished", false),
		"candidateVisible": false, "recordsAdmitted": _records_admitted}

func _request_failure(reason: String) -> void:
	if _failure.is_empty() or _failure == "cancelled": _failure = reason
	_state = "cancelling"

func _pending_cleanup() -> Dictionary:
	return {"status": "pending", "reason": "native_load_cleanup_pending",
		"failure": _failure, "generation": _generation, "ownerMustBeRetained": true}

func _advance_cleanup() -> Dictionary:
	if _backend == null or _generation <= 0:
		_state = "ownership_error"
		return {"status": "failed", "reason": "native_cleanup_owner_missing", "ownerMustBeRetained": true}
	if not _cancel_sent:
		var cancelled: Dictionary = _backend.cancel_staged_save_v2_initialization(_generation)
		if cancelled.get("reason") == "stale_import_generation":
			_state = "ownership_error"
			_failure = "staged_import_generation_lost"
			return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
		if cancelled.get("status") == "failed":
			_cancel_failure = String(cancelled.get("reason", "native_cancel_failed"))
		_cancel_sent = true
		_state = "draining"
	var drained: Dictionary = _backend.drain_staged_save_v2_initialization(_generation)
	if drained.get("reason") == "stale_import_generation":
		_state = "ownership_error"
		_failure = "staged_import_generation_lost"
		return {"status": "failed", "reason": _failure, "ownerMustBeRetained": true}
	if drained.get("cleanupComplete") == true:
		_sections = []
		_input_request = {}
		_input_owner = null
		if _snapshot_lease != null: _snapshot_lease.release_after_drain()
		_snapshot_lease = null
		_backend = null
		_state = "drained" if _failure == "cancelled" else "failed"
		return {"status": "ready" if _failure == "cancelled" else "failed",
			"reason": "cancelled_and_drained" if _failure == "cancelled" else _failure,
			"cancelled": _failure == "cancelled", "drained": true,
			"cleanupComplete": true, "generation": _generation}
	if drained.get("status") == "failed":
		_failure = "native_drain_terminal_failed:" + String(drained.get("reason", "unknown"))
		_state = "ownership_error"
		return {"status": "failed", "reason": _failure,
			"cancelFailure": _cancel_failure, "ownerMustBeRetained": true,
			"drained": false, "workerJoined": drained.get("workerJoined", false)}
	return {"status": "pending", "reason": String(drained.get("reason", "bounded_cleanup_in_progress")),
		"failure": _failure, "cancelFailure": _cancel_failure,
		"generation": _generation, "ownerMustBeRetained": true,
		"workerJoined": drained.get("workerJoined", false)}

func _snapshot_lease_is_valid() -> bool:
	if _snapshot_lease == null: return true
	return _snapshot_lease.is_valid_for(_input_request.get("terrainVolume", {}))

func _create_backend():
	if _backend_factory.is_valid(): return _backend_factory.call()
	return ClassDB.instantiate("NativeWorldBackend")

func _record_advance(started: int) -> void:
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)

func _failed(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status": "failed", "reason": reason}
