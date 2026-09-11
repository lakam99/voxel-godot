extends RefCounted
class_name NavigationPublicationQueue

## One owned compiler/upload slot. The existing route publication queue retains
## demand while this slot is busy; no second demand scheduler or topology owner.
const Worker = preload("res://scripts/npc_ai/navigation/NavigationPublicationWorker.gd")
var worker = Worker.new()
var _binding := {}
var _token := 0
var _descriptor
var _mesh: NavigationMesh
var _polygon := 0
var _state := "idle"
var _reason := ""
var _retired := {}
var _closing := false
var _last_frame := -1
var _worker_state := {}
var max_advance_usec := 0
var prepared_count := 0
var uploaded_count := 0

func request(source: Dictionary, binding: Dictionary) -> Dictionary:
	if _closing: return {"status":"failed","reason":"navigation_publication_closing"}
	if not _binding.is_empty():
		if _binding == binding: return {"status":_state,"reason":_reason}
		if _binding.siteId == binding.get("siteId") or _state == "failed":
			cancel()
		return {"status":"pending","reason":"navigation_publication_busy"}
	if not _retired.is_empty(): return {"status":"pending","reason":"navigation_retirement_pending"}
	var result: Dictionary = worker.dispatch(source,binding)
	if result.status != "queued": return {"status":"pending" if result.status=="busy" else "failed","reason":result.get("reason","")}
	_binding = binding.duplicate()
	_binding.make_read_only()
	_token = int(result.token)
	_state = "pending"
	_reason = "navigation_preparation_pending"
	return {"status":_state,"reason":_reason}

func advance(budget_usec := 4000) -> Dictionary:
	var frame := Engine.get_process_frames()
	if _last_frame == frame: return stats()
	_last_frame = frame
	var started := Time.get_ticks_usec()
	_worker_state = worker.poll()
	if not _retired.is_empty() and worker.retire_external_payload(_retired):
		_retired = {}
		_worker_state["shutdownComplete"] = false
	if _token > 0 and not String(_worker_state.get("completedStatus","")).is_empty():
		var taken: Dictionary = worker.take_result(_token,_binding)
		if taken.status == "consumed":
			var result: Dictionary = taken.result
			if result.get("ready",false):
				_descriptor = result.prepared.take(_binding)
				if _descriptor != null:
					prepared_count += 1
					_reason = "navigation_upload_pending"
				else:
					_state = "failed"; _reason = "navigation_binding_changed"
			else:
				_state = "failed"; _reason = String(result.get("reason","navigation_preparation_failed"))
			_token = 0
	if _descriptor != null and _state != "ready" and not _closing:
		var geometry: Dictionary = _descriptor.prepared_geometry()
		if geometry.is_empty():
			_state = "failed"; _reason = "navigation_preparation_changed"
		else:
			if _mesh == null:
				_mesh = NavigationMesh.new()
				_mesh.set_vertices(geometry.vertices)
				if _mesh.get_vertices() != geometry.vertices:
					_state = "failed"; _reason = "navigation_vertex_upload_mismatch"
			var count := 0
			while _state != "failed" and _polygon < geometry.polygons.size() and count < 128 and Time.get_ticks_usec()-started < budget_usec:
				_mesh.add_polygon(geometry.polygons[_polygon])
				if _mesh.get_polygon(_polygon) != geometry.polygons[_polygon]:
					_state = "failed"; _reason = "navigation_polygon_upload_mismatch"
					break
				_polygon += 1; count += 1
			if _state != "failed" and _polygon == geometry.polygons.size():
				_state = "ready"; _reason = "navigation_upload_complete"
				uploaded_count += 1
	max_advance_usec = maxi(max_advance_usec,Time.get_ticks_usec()-started)
	return stats()

func advanced_this_frame() -> bool:
	return _last_frame == Engine.get_process_frames()

func take_ready(binding: Dictionary) -> Dictionary:
	if _closing or binding != _binding or _state != "ready": return {}
	var result := {"descriptor":_descriptor,"mesh":_mesh,"binding":_binding}
	_descriptor = null; _mesh = null; _polygon = 0
	_binding = {}; _token = 0; _state = "idle"; _reason = ""
	return result

func retire(payload: Dictionary) -> void:
	if payload.is_empty(): return
	_retired[_retired.size()] = payload

func cancel() -> void:
	worker.reset()
	if _descriptor != null: retire({"descriptor":_descriptor})
	_descriptor = null; _mesh = null; _polygon = 0
	_binding = {}; _token = 0; _state = "idle"; _reason = ""

func request_shutdown() -> void:
	_closing = true
	cancel()
	worker.request_shutdown()

func stats() -> Dictionary:
	return {"status":_state,"reason":_reason,"binding":_binding,"worker":_worker_state,
		"busy":not _binding.is_empty() or not _retired.is_empty() or worker.has_pending_work(),
		"preparedCount":prepared_count,"uploadedCount":uploaded_count,"uploadPolygon":_polygon,
		"retiredBatchCount":_retired.size(),"maxAdvanceUsec":max_advance_usec,
		"shutdownComplete":_closing and _retired.is_empty() and not worker.has_pending_work() and bool(_worker_state.get("shutdownComplete",false))}

func finish_shutdown_for_owner_exit() -> void:
	# Normal gameplay reset/quit yields through advance(). Direct scene deletion
	# cannot yield; join the same owned cancellation/retirement protocol before
	# destroying its polling owner. Never abandon a live Thread in that path.
	request_shutdown()
	while true:
		_last_frame = -1
		if advance().shutdownComplete: return
		OS.delay_usec(250)
