extends RefCounted
class_name NativePrivateMainLoadStage

## Main-loading candidate only. No terrain, collision, query, or save publisher
## is installed until a later atomic authority cutover owns those boundaries.
const SourceRequest = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const LoadTransaction = preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const LegacyConverter = preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")
const RuntimeOwner = preload("res://scripts/terrain/NativeTerrainRuntimeOwner.gd")

var _main
var _save: Dictionary = {}
var _converter
var _transaction
var _backend
var _receipt: Dictionary = {}
var _transferred_owner: WeakRef
var _transfer_identity: Dictionary = {}
var _adopted_owner_id := 0
var _adopted_owner_generation := 0
var _failed_owner_bound := false
var _source_descriptor: Dictionary = {}
var _source_seed := ""
var _state := "new"
var _failure := ""
var _last_release_usec := 0
var _last_backend_release_usec := 0
var _last_transaction_release_usec := 0
var _last_retirement_request_usec := 0
var _max_retirement_poll_usec := 0
var _retirement_polls := 0

func start(main, save_snapshot: Dictionary = {}) -> Dictionary:
	if _state != "new": return _failed("private_stage_already_started")
	_main = main
	_save = save_snapshot
	if not _save.is_empty() and _save.get("terrainVolume", {}) is Dictionary \
			and (_save.get("terrainVolume", {}) as Dictionary).is_empty() \
			and _save.get("terrain", []) is Array \
			and not (_save.get("terrain", []) as Array).is_empty():
		_converter = LegacyConverter.new()
		var begun: Dictionary = _converter.setup(_main, _save, true)
		if begun.get("status") != "ready": return _failed(String(begun.get("reason", "legacy_conversion_failed")))
		_state = "converting"
		return {"status":"pending", "reason":"legacy_v2_conversion_pending"}
	return _begin_import()

func advance() -> Dictionary:
	if _state == "ready": return {"status":"ready", "receipt":_receipt.duplicate(true)}
	if _state == "converting":
		var converted: Dictionary = _converter.advance()
		if converted.get("status") == "pending": return converted
		if converted.get("status") != "ready":
			return _failed(String(converted.get("reason", "legacy_conversion_failed")))
		var resolved: Dictionary = _converter.resolved_save()
		if resolved.get("status") != "ready":
			return _failed(String(resolved.get("reason", "legacy_conversion_export_failed")))
		_save = resolved.save
		_converter = null
		return _begin_import()
	if _state != "importing" or _transaction == null:
		return {"status":"failed", "reason":_failure if not _failure.is_empty() else "private_stage_not_importing"}
	var result: Dictionary = _transaction.advance()
	if result.get("reason") != "candidate_requires_explicit_commit":
		if result.get("status") == "failed":
			_failure = String(result.get("reason", "private_import_failed"))
			_state = "failed"
		return result
	var identity: Dictionary = _transaction.candidate_source_identity()
	if identity.is_empty(): return _failed("private_candidate_identity_missing")
	if not current_source_valid(): return _failed("private_source_changed_during_import")
	var committed: Dictionary = _transaction.commit(identity)
	if committed.get("status") != "ready": return _failed(String(committed.get("reason", "private_commit_failed")))
	# Retain a non-consuming backend alias for private retirement diagnostics.
	# The transaction keeps its single-use transfer and immutable save lease.
	var borrowed: Dictionary = _borrow_committed_backend(committed)
	if borrowed.get("status") != "ready":
		# Commit already happened. Keep the transaction and receipt so stop() can
		# take and retire the real backend even if non-consuming borrow failed.
		_receipt = committed.duplicate(true)
		_save = {}
		_failure = String(borrowed.get("reason", "private_committed_backend_missing"))
		_state = "committed_borrow_failed"
		return {"status":"failed", "reason":_failure, "ownerMustBeRetained":true}
	_backend = borrowed.backend
	_receipt = committed.duplicate(true)
	_save = {}
	_state = "ready"
	return {"status":"ready", "receipt":_receipt.duplicate(true)}

func _borrow_committed_backend(committed: Dictionary) -> Dictionary:
	return _transaction.borrow_committed_backend(committed)

## Transfer the actual committed transaction once. The receiver must pass this
## exact transaction and receipt to NativeTerrainRuntimeOwner's adoption API;
## it then owns take_backend() and every subsequent stop/drain obligation.
func take_committed_transaction() -> Dictionary:
	if _state != "ready" or _transaction == null or _backend == null:
		return {"status":"failed", "reason":"private_committed_transfer_unavailable"}
	if not current_source_valid():
		return {"status":"failed", "reason":"private_source_changed_before_transfer",
			"ownerMustBeRetained":true}
	var transaction_state: Dictionary = _transaction.snapshot()
	if transaction_state.get("state") != "committed" \
			or transaction_state.get("snapshotLeaseValid") != true \
			or int(transaction_state.get("generation", 0)) != int(_receipt.get("generation", -1)) \
			or int(transaction_state.get("backendInstanceId", 0)) != _backend.get_instance_id() \
			or transaction_state.get("sourceIdentity") != _receipt.get("sourceIdentity") \
			or int(_receipt.get("backendInstanceId", 0)) != _backend.get_instance_id():
		return {"status":"failed", "reason":"private_committed_transfer_receipt_mismatch",
			"ownerMustBeRetained":true}
	var transferred = _transaction
	var receipt := _receipt.duplicate(true)
	_transfer_identity = {"transactionId":transferred.get_instance_id(),
		"backendInstanceId":int(transaction_state.get("backendInstanceId", 0)),
		"generation":int(receipt.get("generation", 0)),
		"sourceIdentity":receipt.get("sourceIdentity", {}).duplicate(true)}
	_transaction = null
	_backend = null
	_receipt = {}
	_save = {}
	_main = null
	_source_descriptor = {}
	_source_seed = ""
	_state = "transferred"
	return {"status":"ready", "transaction":transferred, "receipt":receipt,
		"transactionId":transferred.get_instance_id(),
		"backendInstanceId":int(transaction_state.get("backendInstanceId", 0))}

## If receiver setup failed before consuming the committed transaction, take
## back this exact still-private owner. Once adoption has started or completed,
## the stage must not reclaim or retire the receiver's backend.
func reclaim_unadopted_transaction(transaction: RefCounted,
		commit_receipt: Dictionary) -> Dictionary:
	if _state != "transferred" or _adopted_owner_id != 0 \
			or not transaction is LoadTransaction \
			or not transaction.has_method("snapshot") \
			or not transaction.has_method("borrow_committed_backend") \
			or transaction.get_instance_id() != int(_transfer_identity.get("transactionId", 0)):
		return {"status":"failed", "reason":"transferred_owner_reclaim_unavailable",
			"ownerMustBeRetained":true}
	var state: Dictionary = transaction.snapshot()
	if state.get("state") != "committed" or state.get("snapshotLeaseValid") != true \
			or int(state.get("generation", 0)) != int(_transfer_identity.get("generation", 0)) \
			or int(state.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or state.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or commit_receipt.get("status") != "ready" \
			or commit_receipt.get("committed") != true \
			or int(commit_receipt.get("generation", 0)) != int(_transfer_identity.get("generation", 0)) \
			or int(commit_receipt.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or commit_receipt.get("sourceIdentity") != _transfer_identity.get("sourceIdentity"):
		return {"status":"failed", "reason":"transferred_owner_reclaim_identity_mismatch",
			"ownerMustBeRetained":true}
	var borrowed: Dictionary = transaction.borrow_committed_backend(commit_receipt)
	if borrowed.get("status") != "ready":
		return {"status":"failed", "reason":"transferred_owner_reclaim_borrow_failed",
			"ownerMustBeRetained":true}
	_transaction = transaction
	_backend = borrowed.backend
	_receipt = commit_receipt.duplicate(true)
	_transfer_identity = {}
	_transferred_owner = null
	_state = "reclaimed"
	return {"status":"ready", "reclaimed":true, "drained":false,
		"ownerMustBeRetained":true}

## Join the receiving runtime owner while its exact backend is still active.
## A dictionary alone cannot attest to adoption; the live owner snapshot must
## match the committed backend, source and owner generation.
func bind_transferred_owner(owner: RefCounted, adoption_receipt: Dictionary) -> Dictionary:
	if _state != "transferred" or _adopted_owner_id != 0 \
			or not owner is RuntimeOwner \
			or not owner.has_method("snapshot"):
		return {"status":"failed", "reason":"transferred_owner_bind_unavailable"}
	var live: Dictionary = owner.snapshot()
	var owner_generation := int(adoption_receipt.get("ownerGeneration", 0))
	if adoption_receipt.get("status") != "ready" \
			or adoption_receipt.get("adoptedCommittedBackend") != true \
			or int(adoption_receipt.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or int(adoption_receipt.get("loadGeneration", 0)) != int(_transfer_identity.get("generation", 0)) \
			or adoption_receipt.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or owner_generation <= 0 or live.get("state") != "active" \
			or int(live.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or int(live.get("ownerGeneration", 0)) != owner_generation \
			or live.get("sourceIdentity") != _transfer_identity.get("sourceIdentity"):
		return {"status":"failed", "reason":"transferred_owner_adoption_mismatch",
			"ownerMustBeRetained":true}
	_transferred_owner = weakref(owner)
	_adopted_owner_id = owner.get_instance_id()
	_adopted_owner_generation = owner_generation
	return {"status":"ready", "stageReleased":true, "ownershipTransferred":true,
		"ownerInstanceId":_adopted_owner_id, "ownerGeneration":owner_generation}

## A receiver that consumed the transaction before activation failed owns the
## same backend until its bounded failure retirement completes. Bind the live
## failed owner before accepting any terminal acknowledgement.
func bind_failed_transferred_owner(owner: RefCounted,
		failure_receipt: Dictionary) -> Dictionary:
	if _state != "transferred" or _adopted_owner_id != 0 \
			or not owner is RuntimeOwner or not owner.has_method("snapshot"):
		return {"status":"failed", "reason":"failed_transferred_owner_bind_unavailable",
			"ownerMustBeRetained":true}
	var live: Dictionary = owner.snapshot()
	if failure_receipt.get("status") != "failed" \
			or failure_receipt.get("cleanupPending") != true \
			or failure_receipt.get("drained") != false \
			or int(failure_receipt.get("ownerInstanceId", 0)) != owner.get_instance_id() \
			or int(failure_receipt.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or int(failure_receipt.get("loadGeneration", 0)) != int(_transfer_identity.get("generation", 0)) \
			or failure_receipt.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or live.get("state") != "failed_transfer_retirement" \
			or int(live.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or int(live.get("loadGeneration", 0)) != int(_transfer_identity.get("generation", 0)) \
			or live.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or live.get("failure") != failure_receipt.get("reason"):
		return {"status":"failed", "reason":"failed_transferred_owner_identity_mismatch",
			"ownerMustBeRetained":true}
	_transferred_owner = weakref(owner)
	_adopted_owner_id = owner.get_instance_id()
	_failed_owner_bound = true
	return {"status":"ready", "stageReleased":true, "ownershipTransferred":true,
		"drained":false, "ownerInstanceId":_adopted_owner_id,
		"failedActivation":true}

func acknowledge_failed_transferred_owner_drain(owner: RefCounted,
		drain_receipt: Dictionary) -> Dictionary:
	if _state != "transferred" or not _failed_owner_bound \
			or owner == null or _transferred_owner == null \
			or _transferred_owner.get_ref() != owner \
			or owner.get_instance_id() != _adopted_owner_id:
		return {"status":"pending", "reason":"failed_transferred_owner_not_bound_or_changed",
			"drained":false, "ownerMustBeRetained":true}
	var live: Dictionary = owner.snapshot()
	var actual: Dictionary = live.get("asyncStopReceipt", {})
	if live.get("state") != "drained" or int(live.get("backendInstanceId", -1)) != 0 \
			or int(live.get("loadGeneration", 0)) != int(_transfer_identity.get("generation", 0)) \
			or live.get("failedTransferIdentity", {}).get("sourceIdentity") \
				!= _transfer_identity.get("sourceIdentity") \
			or int(live.get("failedTransferIdentity", {}).get("backendInstanceId", 0)) \
				!= int(_transfer_identity.get("backendInstanceId", 0)) \
			or actual != drain_receipt or actual.get("status") != "ready" \
			or actual.get("drained") != true or actual.get("failedTransferRetired") != true \
			or int(actual.get("ownerInstanceId", 0)) != _adopted_owner_id \
			or int(actual.get("backendInstanceId", 0)) != int(_transfer_identity.get("backendInstanceId", 0)) \
			or int(actual.get("loadGeneration", 0)) != int(_transfer_identity.get("generation", 0)) \
			or actual.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or actual.get("physicalBlocksUnloaded") != true \
			or actual.get("nativeWorkersDrained") != true \
			or actual.get("demandReleased") != true \
			or actual.get("leasesReleased") != true:
		return {"status":"pending", "reason":"failed_transferred_owner_drain_unverified",
			"drained":false, "ownerMustBeRetained":true}
	_transferred_owner = null
	_transfer_identity = {}
	_adopted_owner_id = 0
	_failed_owner_bound = false
	_state = "drained"
	return {"status":"ready", "drained":true, "ownershipTransferred":true,
		"failedActivation":true}

## The stage reports drained only after the exact adopted owner has completed
## its physical, worker, demand and lease retirement. Wrong or early receipts
## leave the transfer join pending so Main cannot mistake it for global drain.
func acknowledge_transferred_owner_drain(owner: RefCounted,
		drain_receipt: Dictionary) -> Dictionary:
	if _state != "transferred" or _adopted_owner_id == 0 or _failed_owner_bound \
			or owner == null or _transferred_owner == null \
			or _transferred_owner.get_ref() != owner \
			or owner.get_instance_id() != _adopted_owner_id:
		return {"status":"pending", "reason":"transferred_owner_not_bound_or_changed",
			"drained":false, "ownerMustBeRetained":true}
	var live: Dictionary = owner.snapshot()
	var actual: Dictionary = live.get("asyncStopReceipt", {})
	if live.get("state") != "drained" or int(live.get("backendInstanceId", -1)) != 0 \
			or int(live.get("ownerGeneration", 0)) != _adopted_owner_generation \
			or actual != drain_receipt or actual.get("status") != "ready" \
			or actual.get("drained") != true \
			or int(actual.get("ownerGeneration", 0)) != _adopted_owner_generation \
			or actual.get("sourceIdentity") != _transfer_identity.get("sourceIdentity") \
			or actual.get("physicalBlocksUnloaded") != true \
			or actual.get("nativeWorkersDrained") != true \
			or actual.get("demandReleased") != true \
			or actual.get("leasesReleased") != true:
		return {"status":"pending", "reason":"transferred_owner_drain_unverified",
			"drained":false, "ownerMustBeRetained":true}
	_transferred_owner = null
	_transfer_identity = {}
	_adopted_owner_id = 0
	_adopted_owner_generation = 0
	_state = "drained"
	return {"status":"ready", "drained":true, "ownershipTransferred":true}

func stop() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "transferred":
		return {"status":"pending", "reason":"transferred_owner_drain_external",
			"drained":false, "stageReleased":true,
			"ownershipTransferred":true, "ownerMustBeRetained":true}
	if _state == "stopping_retirement": return advance_stop()
	if _state in ["ready", "committed_borrow_failed", "reclaimed"]:
		_backend = _transaction.take_backend() if _transaction != null else null
		if _backend == null:
			return {"status":"failed", "reason":"private_retirement_backend_transfer_failed",
				"ownerMustBeRetained":true}
		var request_started := Time.get_ticks_usec()
		var started: Dictionary = _backend.start_private_staged_save_retirement(
			int(_receipt.get("generation", -1)))
		_last_retirement_request_usec = Time.get_ticks_usec() - request_started
		if started.get("status") != "pending":
			return {"status":"failed", "reason":String(started.get("reason", "private_retirement_start_failed")),
				"ownerMustBeRetained":true}
		_state = "stopping_retirement"
		return started
	if _converter != null:
		var requested: Dictionary = _converter.cancel()
		_state = "stopping_converter"
		if requested.get("status") == "ready": return _finish_drain()
		return requested
	if _transaction != null:
		if _transaction.snapshot().get("state") in ["committed", "transferred"]:
			return {"status":"failed", "reason":"private_committed_owner_missing",
				"ownerMustBeRetained":true}
		var requested: Dictionary = _transaction.cancel()
		_state = "stopping_import"
		if requested.get("drained", false): return _finish_drain()
		return requested
	return _finish_drain()

func advance_stop() -> Dictionary:
	if _state == "transferred":
		return stop()
	if _state == "stopping_retirement" and _backend != null:
		var poll_started := Time.get_ticks_usec()
		var retired: Dictionary = _backend.poll_private_staged_save_retirement()
		_max_retirement_poll_usec = maxi(_max_retirement_poll_usec,
			Time.get_ticks_usec() - poll_started)
		_retirement_polls += 1
		if retired.get("status") == "pending": return retired
		if retired.get("status") != "ready":
			return {"status":"failed", "reason":String(retired.get("reason", "private_retirement_poll_failed")),
				"ownerMustBeRetained":true}
		var release_started := Time.get_ticks_usec()
		_backend = null
		_last_backend_release_usec = Time.get_ticks_usec() - release_started
		var transaction_release_started := Time.get_ticks_usec()
		_transaction = null
		_last_transaction_release_usec = Time.get_ticks_usec() - transaction_release_started
		_last_release_usec = Time.get_ticks_usec() - release_started
		_receipt = {}
		_main = null
		_state = "drained"
		return {"status":"ready", "drained":true, "releaseUsec":_last_release_usec,
			"backendReleaseUsec":_last_backend_release_usec,
			"transactionReleaseUsec":_last_transaction_release_usec,
			"retirementRequestUsec":_last_retirement_request_usec,
			"maxRetirementPollUsec":_max_retirement_poll_usec,
			"retirementPolls":_retirement_polls}
	if _state == "stopping_converter" and _converter != null:
		var result: Dictionary = _converter.advance()
		if result.get("cancelled", false): return _finish_drain()
		return result
	if _state == "stopping_import" and _transaction != null:
		var result: Dictionary = _transaction.advance()
		if result.get("drained", false): return _finish_drain()
		return result
	return {"status":"ready", "drained":_state == "drained"}

func snapshot() -> Dictionary:
	return {"state":_state, "failure":_failure,
		"transaction":_transaction.snapshot() if _transaction != null else {},
		"backendRetained":_backend != null,
		"saveRetained":not _save.is_empty(),
		"transferIdentity":_transfer_identity.duplicate(true),
		"transferredOwnerBound":_adopted_owner_id != 0,
		"failedOwnerBound":_failed_owner_bound,
		"lastReleaseUsec":_last_release_usec,
		"lastBackendReleaseUsec":_last_backend_release_usec,
		"lastTransactionReleaseUsec":_last_transaction_release_usec,
		"lastRetirementRequestUsec":_last_retirement_request_usec,
		"maxRetirementPollUsec":_max_retirement_poll_usec,
		"retirementPolls":_retirement_polls}

func current_source_valid() -> bool:
	if _main == null or not is_instance_valid(_main): return false
	if String(_main.get("seed_text")) != _source_seed: return false
	var current: Dictionary = SourceRequest.from_finalized_main(_main)
	if current.get("status") != "ready" or current.get("request") != _source_descriptor:
		return false
	if not _save.is_empty() and (int(_save.get("version", -1)) != 2 \
			or String(_save.get("seed", "")) != _source_seed):
		return false
	return true

func _begin_import() -> Dictionary:
	var built: Dictionary = SourceRequest.from_finalized_main(_main) if _save.is_empty() \
		else SourceRequest.from_main_with_v2_save_snapshot(_main, _save, true)
	if built.get("status") != "ready": return _failed(String(built.get("reason", "private_source_request_failed")))
	var descriptor: Dictionary = built.request.duplicate(false)
	descriptor.erase("terrainVolume")
	descriptor.erase("saveSeedText")
	descriptor["schema"] = "n3-native-world-backend-initialize/v1"
	_source_descriptor = descriptor.duplicate(true)
	_source_seed = String(_main.get("seed_text"))
	_transaction = LoadTransaction.new()
	var begun: Dictionary = _transaction.start(built.request, 256, built.get("snapshotOwner"))
	if begun.get("status") != "pending": return _failed(String(begun.get("reason", "private_import_start_failed")))
	_state = "importing"
	return begun

func _finish_drain() -> Dictionary:
	_converter = null
	_transaction = null
	_backend = null
	_save = {}
	_main = null
	_source_descriptor = {}
	_source_seed = ""
	_state = "drained"
	return {"status":"ready", "drained":true}

func _failed(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status":"failed", "reason":reason,
		"ownerMustBeRetained":_converter != null or _transaction != null}
