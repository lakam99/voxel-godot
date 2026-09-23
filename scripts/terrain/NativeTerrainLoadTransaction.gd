extends RefCounted
class_name NativeTerrainLoadTransaction

## Loading-only native source lifetime. This service does not create a
## VoxelTerrain, publisher, query facade, or gameplay readiness signal.
const PageAdmission = preload("res://scripts/world/NativeShapingPageAdmission.gd")

var _backend
var _pages
var _admission
var _state := "new"
var _failure := ""
var _source_identity := {}
var _page := Vector2i.ZERO
var _cancel_requested := false
var _max_advance_usec := 0
var _advance_count := 0
var _page_adapter_override

func start(request: Dictionary, admission, page: Vector2i) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"transaction_already_started"}
	if request.is_empty() or admission == null:
		return _fail("load_transaction_inputs_missing")
	_admission = admission
	_page = page
	_backend = ClassDB.instantiate("NativeWorldBackend")
	if _backend == null: return _fail("native_backend_unavailable")
	var initialized: Dictionary = _backend.initialize_from_save_v2(request.duplicate(true))
	if initialized.get("status") != "ready":
		return _fail(String(initialized.get("reason", "native_initialize_failed")))
	_source_identity = initialized.get("sourceIdentity", {}).duplicate(true)
	_pages = PageAdmission.new()
	var bound: Dictionary = _pages.setup(_backend, _admission)
	if bound.get("status") != "ready":
		return _fail(String(bound.get("reason", "native_shaping_bridge_failed")))
	_state = "pending"
	return {"status":"pending", "transactionId":get_instance_id(),
		"sourceIdentity":_source_identity.duplicate(true), "page":_page}

## Bind an already initialized native backend and its production shaping
## admission. This overload is useful to loading coordinators that initialize
## the backend as part of their retained transaction.
func start_backend(backend, admission, page: Vector2i) -> Dictionary:
	if _state != "new": return {"status":"failed", "reason":"transaction_already_started"}
	if backend == null or admission == null:
		return _fail("load_transaction_inputs_missing")
	var status: Dictionary = backend.status()
	if status.get("status") != "ready": return _fail("native_backend_not_ready")
	_backend = backend
	_admission = admission
	_page = page
	_source_identity = status.get("sourceIdentity", {}).duplicate(true)
	_pages = PageAdmission.new()
	var bound: Dictionary = _pages.setup(_backend, _admission)
	if bound.get("status") != "ready":
		return _fail(String(bound.get("reason", "native_shaping_bridge_failed")))
	_state = "pending"
	return {"status":"pending", "transactionId":get_instance_id(),
		"sourceIdentity":_source_identity.duplicate(true), "page":_page}

func _set_page_adapter_for_test(adapter) -> bool:
	if _state != "pending" or adapter == null: return false
	_page_adapter_override = adapter
	return true

func advance() -> Dictionary:
	var started := Time.get_ticks_usec()
	_advance_count += 1
	if _state == "draining":
		_release()
		_record_advance(started)
		return {"status":"ready", "cancelled":true, "drained":true}
	if _state == "ready":
		_record_advance(started)
		return {"status":"ready", "transactionId":get_instance_id()}
	if _state != "pending":
		_record_advance(started)
		return {"status":"failed", "reason":_failure if not _failure.is_empty() else "transaction_not_pending"}
	if _cancel_requested:
		_state = "draining"
		_release()
		_record_advance(started)
		return {"status":"ready", "cancelled":true, "drained":true}
	var site: Dictionary = _admission.advance()
	if not String(site.get("failure", "")).is_empty():
		var result := _fail(String(site.failure))
		_record_advance(started)
		return result
	var page_owner = _page_adapter_override if _page_adapter_override != null else _pages
	var admitted: Dictionary = page_owner.request_page(_page)
	if admitted.get("status") == "ready":
		var pinned: Dictionary = _backend.pin_effective_page(_page)
		if pinned.get("status") == "ready":
			_state = "ready"
			_record_advance(started)
			return {"status":"ready", "transactionId":get_instance_id(),
				"sourceIdentity":_source_identity.duplicate(true), "page":_page,
				"pagePinIdentity":pinned.page.status().get("pinIdentity", {})}
		admitted = pinned
	if admitted.get("status") == "failed":
		var failed := _fail(String(admitted.get("reason", "native_page_admission_failed")))
		_record_advance(started)
		return failed
	_record_advance(started)
	return {"status":"pending", "reason":String(admitted.get("reason", "native_page_pending")),
		"transactionId":get_instance_id(), "page":_page,
		"progress":{"advances":_advance_count, "maxAdvanceUsec":_max_advance_usec}}

func cancel() -> Dictionary:
	if _state == "drained": return {"status":"ready", "drained":true}
	if _state == "new":
		_state = "drained"
		return {"status":"ready", "drained":true}
	if _state == "ready": return {"status":"failed", "reason":"transaction_already_ready"}
	# Admission.advance() may enqueue shared Citadel source work. Until this
	# transaction uses consumer leases and observes their retirement ack, it is
	# safe to release only before the first advance could issue page demand.
	if _advance_count > 0:
		return {"status":"failed", "reason":"active_source_cancellation_unsupported",
			"drained":false, "state":_state}
	_cancel_requested = true
	_state = "draining"
	return advance()

func stop() -> Dictionary:
	if _state == "pending" or _state == "draining": return cancel()
	if _state == "new" or _state == "ready" or _state == "failed":
		_release()
		return {"status":"ready", "drained":true}
	if _state == "drained": return {"status":"ready", "drained":true}
	return {"status":"failed", "reason":"transaction_stop_state_invalid"}

func snapshot() -> Dictionary:
	return {"state":_state, "transactionId":get_instance_id(),
		"sourceIdentity":_source_identity.duplicate(true), "page":_page,
		"advanceCount":_advance_count, "maxAdvanceUsec":_max_advance_usec,
		"backendInstanceId":_backend.get_instance_id() if _backend != null else 0,
		"cancelRequested":_cancel_requested, "failure":_failure}

func _record_advance(started: int) -> void:
	_max_advance_usec = maxi(_max_advance_usec, Time.get_ticks_usec() - started)

func _fail(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	_release()
	return {"status":"failed", "reason":reason}

func _release() -> void:
	_pages = null
	_page_adapter_override = null
	_backend = null
	_admission = null
	_state = "drained"
