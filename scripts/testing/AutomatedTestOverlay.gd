extends CanvasLayer

## Test-only autoload. It stays inert for normal launches and reads status
## emitted by tools/lib/headed-test-evidence.mjs for headed test runs.

const ENABLED_ENV := "VOXEL_AUTOMATED_TEST"
const NAME_ENV := "VOXEL_AUTOMATED_TEST_NAME"
const RUN_ID_ENV := "VOXEL_AUTOMATED_TEST_RUN_ID"
const STATUS_ENV := "VOXEL_AUTOMATED_TEST_STATUS"
const CAPTURE_MODE_ENV := "VOXEL_AUTOMATED_TEST_CAPTURE_MODE"
const SOURCE_IDENTITY_ENV := "VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY"
const SOURCE_IDENTITY_SHA256_ENV := "VOXEL_AUTOMATED_TEST_SOURCE_IDENTITY_SHA256"
const CAPTURE_DIR_ENV := "VOXEL_AUTOMATED_TEST_CAPTURE_DIR"
const VIEWPORT_CAPTURE_REQUEST_ENV := "VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_REQUEST"
const VIEWPORT_CAPTURE_RECEIPT_ENV := "VOXEL_AUTOMATED_TEST_VIEWPORT_CAPTURE_RECEIPT"
const STATUS_SCHEMA := "voxel-automated-test-status/v1"
const VIEWPORT_REQUEST_SCHEMA := "voxel-automated-test-viewport-capture-request/v1"
const VIEWPORT_RECEIPT_SCHEMA := "voxel-automated-test-viewport-capture-receipt/v1"
const VIEWPORT_CAPTURE_MODE := "godot_viewport"
const REFRESH_SECONDS := 0.25

var _status_path := ""
var _runner_id := ""
var _run_id := ""
var _capture_mode := ""
var _source_identity_json := ""
var _source_identity_sha256 := ""
var _capture_directory_path := ""
var _capture_request_path := ""
var _capture_receipt_path := ""
var _status := {}
var _refresh_elapsed := REFRESH_SECONDS
var _label: Label
var _capture_in_flight := false
var _last_capture_request_id := ""


func _ready() -> void:
	if OS.get_environment(ENABLED_ENV) != "1":
		set_process(false)
		return
	_runner_id = OS.get_environment(NAME_ENV).strip_edges()
	_run_id = OS.get_environment(RUN_ID_ENV).strip_edges()
	_status_path = OS.get_environment(STATUS_ENV).strip_edges()
	_capture_mode = OS.get_environment(CAPTURE_MODE_ENV).strip_edges()
	_source_identity_json = OS.get_environment(SOURCE_IDENTITY_ENV).strip_edges()
	_source_identity_sha256 = OS.get_environment(SOURCE_IDENTITY_SHA256_ENV).strip_edges()
	_capture_directory_path = OS.get_environment(CAPTURE_DIR_ENV).strip_edges()
	_capture_request_path = OS.get_environment(VIEWPORT_CAPTURE_REQUEST_ENV).strip_edges()
	_capture_receipt_path = OS.get_environment(VIEWPORT_CAPTURE_RECEIPT_ENV).strip_edges()
	layer = 120
	_create_overlay()
	_refresh_status()
	_update_display()


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed >= REFRESH_SECONDS:
		_refresh_elapsed = 0.0
		_refresh_status()
	_update_display()
	_service_viewport_capture()


func _create_overlay() -> void:
	var panel := PanelContainer.new()
	panel.name = "AutomatedTestPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12.0, 12.0)
	panel.custom_minimum_size = Vector2(580.0, 0.0)
	panel.z_index = 4096
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.045, 0.065, 0.94)
	style.border_color = Color(0.95, 0.47, 0.16, 1.0)
	style.set_border_width_all(3)
	style.set_content_margin_all(10.0)
	panel.add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.name = "AutomatedTestStatus"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", 16)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_label)
	add_child(panel)


func _refresh_status() -> void:
	if _status_path.is_empty() or not FileAccess.file_exists(_status_path):
		return
	var file := FileAccess.open(_status_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or parsed.get("schema") != STATUS_SCHEMA:
		return
	if parsed.get("runId") != _run_id or parsed.get("runnerId") != _runner_id:
		return
	if _capture_mode == VIEWPORT_CAPTURE_MODE \
			and parsed.get("sourceIdentitySha256") != _source_identity_sha256:
		return
	_status = parsed


func _service_viewport_capture() -> void:
	if _capture_mode != VIEWPORT_CAPTURE_MODE or _capture_in_flight \
			or _capture_request_path.is_empty() or _capture_receipt_path.is_empty() \
			or not FileAccess.file_exists(_capture_request_path) \
			or FileAccess.file_exists(_capture_receipt_path):
		return
	var file := FileAccess.open(_capture_request_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or parsed.get("schema") != VIEWPORT_REQUEST_SCHEMA:
		return
	var request: Dictionary = parsed
	var capture_id := String(request.get("captureId", ""))
	if capture_id.is_empty() or capture_id == _last_capture_request_id:
		return
	var request_state := _validate_viewport_capture_request(request)
	if request_state == "wait":
		return
	_last_capture_request_id = capture_id
	_capture_in_flight = true
	call_deferred("_capture_viewport_request", request.duplicate(true), request_state)


func _validate_viewport_capture_request(request: Dictionary) -> String:
	if request.get("captureType") != "godot-rendered-viewport":
		return "capture_type_mismatch"
	if request.get("runId") != _run_id or request.get("watchdogRunId") != _run_id \
			or request.get("runnerId") != _runner_id:
		return "run_or_runner_identity_mismatch"
	if request.get("sourceIdentityJson") != _source_identity_json \
			or request.get("sourceIdentitySha256") != _source_identity_sha256:
		return "source_identity_or_hash_mismatch"
	if request.get("receiptPath") != _capture_receipt_path:
		return "receipt_path_mismatch"
	var capture_path := String(request.get("capturePath", ""))
	var normalized_root := _capture_directory_path.replace("\\", "/").trim_suffix("/")
	var normalized_capture := capture_path.replace("\\", "/").simplify_path()
	if _capture_directory_path.is_empty() or not normalized_capture.begins_with(normalized_root + "/"):
		return "capture_path_outside_run_directory"
	if _status.is_empty() or int(_status.get("sequence", 0)) < int(request.get("statusSequence", -1)):
		return "wait"
	if _status.get("sequence") != request.get("statusSequence") \
			or _status.get("phase") != request.get("phase") \
			or _status.get("phaseKind") != request.get("phaseKind") \
			or _status.get("sourceIdentitySha256") != _source_identity_sha256:
		return "phase_status_mismatch"
	return ""


func _viewport_capture_request_is_current(request: Dictionary) -> bool:
	if not FileAccess.file_exists(_capture_request_path):
		return false
	var file := FileAccess.open(_capture_request_path, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed is Dictionary \
		and parsed.get("schema") == VIEWPORT_REQUEST_SCHEMA \
		and parsed.get("captureId") == request.get("captureId") \
		and parsed.get("sourceIdentitySha256") == _source_identity_sha256


func _capture_viewport_request(request: Dictionary, initial_error: String) -> void:
	var error_message := initial_error
	if error_message.is_empty():
		_update_display()
		await RenderingServer.frame_post_draw
		if not _viewport_capture_request_is_current(request):
			_capture_in_flight = false
			return
		_refresh_status()
		error_message = _validate_viewport_capture_request(request)
		if error_message == "wait":
			error_message = "phase_status_changed_before_viewport_capture"
	if error_message.is_empty():
		_update_display()
		await RenderingServer.frame_post_draw
		if not _viewport_capture_request_is_current(request):
			_capture_in_flight = false
			return
		_refresh_status()
		error_message = _validate_viewport_capture_request(request)
		if error_message == "wait":
			error_message = "phase_status_changed_during_viewport_capture"
	var receipt := _viewport_receipt_base(request)
	var viewport_image: Image
	if error_message.is_empty():
		var texture := get_viewport().get_texture()
		if texture == null:
			error_message = "main_viewport_texture_unavailable"
		else:
			viewport_image = texture.get_image()
			if viewport_image == null or viewport_image.is_empty():
				error_message = "main_viewport_image_unavailable"
	if error_message.is_empty():
		var save_error := viewport_image.save_png(String(request.get("capturePath", "")))
		if save_error != OK:
			error_message = "Image.save_png failed: error=%d" % save_error
	if error_message.is_empty():
		var screenshot_bytes := FileAccess.get_file_as_bytes(String(request.get("capturePath", "")))
		if screenshot_bytes.size() <= 24:
			error_message = "saved viewport PNG is empty or truncated"
		else:
			receipt["captured"] = true
			receipt["width"] = viewport_image.get_width()
			receipt["height"] = viewport_image.get_height()
			receipt["screenshotBytes"] = screenshot_bytes.size()
			receipt["capturedAtUnixMilliseconds"] = int(Time.get_unix_time_from_system() * 1000.0)
	if not error_message.is_empty():
		receipt["captured"] = false
		receipt["reason"] = error_message
	_write_viewport_capture_receipt(receipt)
	_capture_in_flight = false


func _viewport_receipt_base(request: Dictionary) -> Dictionary:
	return {"schema":VIEWPORT_RECEIPT_SCHEMA, "captureType":"godot-rendered-viewport",
		"captureId":request.get("captureId", ""), "runnerId":request.get("runnerId", ""),
		"runId":request.get("runId", ""), "watchdogRunId":request.get("watchdogRunId", ""),
		"statusSequence":request.get("statusSequence", -1),
		"phase":request.get("phase", ""), "phaseKind":request.get("phaseKind", ""),
		"captureName":request.get("captureName", ""),
		"sourceIdentityJson":request.get("sourceIdentityJson", ""),
		"sourceIdentitySha256":request.get("sourceIdentitySha256", ""),
		"capturePath":request.get("capturePath", ""), "receiptPath":request.get("receiptPath", ""),
		"captured":false}


func _write_viewport_capture_receipt(receipt: Dictionary) -> void:
	var temporary_path := _capture_receipt_path + ".tmp"
	if FileAccess.file_exists(temporary_path):
		DirAccess.remove_absolute(temporary_path)
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write viewport capture receipt: " + temporary_path)
		return
	file.store_string(JSON.stringify(receipt, "\t"))
	file.close()
	var error := DirAccess.rename_absolute(temporary_path, _capture_receipt_path)
	if error != OK:
		var fallback := FileAccess.open(_capture_receipt_path, FileAccess.WRITE)
		if fallback == null:
			push_error("Could not publish viewport capture receipt: error=%d" % error)
			return
		fallback.store_string(JSON.stringify(receipt, "\t"))
		fallback.close()


func _update_display() -> void:
	if _label == null:
		return
	if _status.is_empty():
		_label.text = "AUTOMATED TEST\n%s\nRun: %s\nPhase: waiting for test status\nElapsed: --:--" % [_runner_id, _run_id]
		DisplayServer.window_set_title("AUTOMATED TEST | %s | %s | waiting for test status" % [_runner_id, _run_id])
		return
	var phase := str(_status.get("phase", "starting"))
	var phase_kind := str(_status.get("phaseKind", "harness"))
	var elapsed_ms := maxi(0, int(Time.get_unix_time_from_system() * 1000.0) - int(_status.get("startedAtUnixMs", 0)))
	var elapsed := _format_elapsed(elapsed_ms)
	var detail := str(_status.get("detail", ""))
	_label.text = "AUTOMATED TEST  |  %s\nRun: %s\nPhase: %s (%s)%s\nElapsed: %s" % [
		_runner_id, _run_id, phase, phase_kind,
		("\n" + detail) if not detail.is_empty() else "", elapsed
	]
	DisplayServer.window_set_title("AUTOMATED TEST | %s | %s | %s | %s" % [_runner_id, _run_id, phase, elapsed])


func _format_elapsed(milliseconds: int) -> String:
	var seconds := int(milliseconds / 1000)
	return "%02d:%02d:%02d" % [int(seconds / 3600), int((seconds / 60) % 60), int(seconds % 60)]
