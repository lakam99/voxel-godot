extends RefCounted
class_name NativeLoadPendingPages

var _backend
var _release_after := 0
var _calls := 0
var _held_page := Vector2i.ZERO
var _holding := false

func configure(backend, held_page: Vector2i, hold_count: int) -> void:
	_backend = backend
	_held_page = held_page
	_holding = true
	_release_after = hold_count

func setup(backend, _admission) -> Dictionary:
	if backend != null: _backend = backend
	return {"status":"ready"}

func request_page(page: Vector2i) -> Dictionary:
	_calls += 1
	if _holding and page == _held_page and _calls <= _release_after:
		return {"status":"pending", "reason":"fixture_page_pending"}
	var readiness: Dictionary = _backend.shaping_requests(page)
	if readiness.get("status") == "pending":
		var requests: Array = readiness.get("requests", [])
		var resolutions: Array = []
		for request in requests:
			resolutions.append({"region":request.region,
				"requestIdentity":request.requestIdentity,
				"workerSourceKey":request.workerSourceKey, "kind":"absent",
				"reasonCode":"fixture_absent"})
		var applied: Dictionary = _backend.apply_shaping_resolutions(resolutions)
		if applied.get("status") != "ready": return applied
	return _backend.shaping_requests(page)

func hold_for_calls(count: int) -> void:
	_release_after = maxi(_calls + count, _release_after)
