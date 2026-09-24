extends RefCounted
class_name NativePrivateMainLoadStage

## Main-loading candidate only. No terrain, collision, query, or save publisher
## is installed until a later atomic authority cutover owns those boundaries.
const SourceRequest = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const LoadTransaction = preload("res://scripts/terrain/NativeTerrainLoadTransaction.gd")
const LegacyConverter = preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")

var _main
var _save: Dictionary = {}
var _converter
var _transaction
var _backend
var _receipt: Dictionary = {}
var _source_descriptor: Dictionary = {}
var _source_seed := ""
var _state := "new"
var _failure := ""
var _last_release_usec := 0

func start(main, save_snapshot: Dictionary = {}) -> Dictionary:
	if _state != "new": return _failed("private_stage_already_started")
	_main = main
	_save = save_snapshot
	if not _save.is_empty() and _save.get("terrainVolume", {}) is Dictionary \
			and (_save.get("terrainVolume", {}) as Dictionary).is_empty() \
			and _save.get("terrain", []) is Array \
			and not (_save.get("terrain", []) as Array).is_empty():
		_converter = LegacyConverter.new()
		var begun: Dictionary = _converter.setup(_main, _save)
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
	_backend = _transaction.take_backend()
	if _backend == null: return _failed("private_backend_transfer_failed")
	_receipt = committed.duplicate(true)
	_save = {}
	_state = "ready"
	return {"status":"ready", "receipt":_receipt.duplicate(true)}

func stop() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "ready":
		var release_started := Time.get_ticks_usec()
		_backend = null
		_transaction = null
		_last_release_usec = Time.get_ticks_usec() - release_started
		_receipt = {}
		_main = null
		_state = "drained"
		return {"status":"ready", "drained":true, "releaseUsec":_last_release_usec}
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
		"backendRetained":_backend != null, "saveRetained":not _save.is_empty(),
		"lastReleaseUsec":_last_release_usec}

func current_source_valid() -> bool:
	if _main == null or not is_instance_valid(_main): return false
	if String(_main.get("seed_text")) != _source_seed: return false
	var current: Dictionary = SourceRequest.from_main(_main)
	if current.get("status") != "ready" or current.get("request") != _source_descriptor:
		return false
	if not _save.is_empty() and (int(_save.get("version", -1)) != 2 \
			or String(_save.get("seed", "")) != _source_seed):
		return false
	return true

func _begin_import() -> Dictionary:
	var built: Dictionary = SourceRequest.from_main(_main) if _save.is_empty() \
		else SourceRequest.from_main_with_v2_save_snapshot(_main, _save)
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
