extends Node
class_name PlaytestSearchLoadingController

var hud
var base_message := "Searching generated world"
var detail := ""
var active := false
var elapsed := 0.0
var returned_frames := 0
var message_updates := 0
var last_text := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

func begin(target_hud, message: String, initial_detail := "") -> bool:
	hud = target_hud
	if hud == null or not hud.has_method("show_loading_overlay"):
		return false
	base_message = message
	detail = initial_detail
	elapsed = 0.0
	returned_frames = 0
	message_updates = 0
	active = true
	set_process(true)
	hud.call("show_loading_overlay", compose_text())
	return true

func set_detail(value: String) -> void:
	detail = value
	refresh_text()

func finish() -> Dictionary:
	var summary := snapshot()
	active = false
	set_process(false)
	if hud != null and is_instance_valid(hud) and hud.has_method("hide_loading_overlay"):
		hud.call("hide_loading_overlay")
	hud = null
	return summary

func snapshot() -> Dictionary:
	return {
		"active": active,
		"returnedFrames": returned_frames,
		"messageUpdates": message_updates,
		"elapsedSeconds": elapsed,
		"lastText": last_text
	}

func _process(delta: float) -> void:
	if not active:
		return
	if hud == null or not is_instance_valid(hud):
		active = false
		set_process(false)
		return
	elapsed += delta
	returned_frames += 1
	refresh_text()

func refresh_text() -> void:
	if not active or hud == null or not is_instance_valid(hud) or not hud.has_method("set_loading_message"):
		return
	var text := compose_text()
	if text == last_text:
		return
	last_text = text
	message_updates += 1
	hud.call("set_loading_message", text)

func compose_text() -> String:
	var dot_count := 1 + (floori(elapsed * 3.0) % 3)
	var dots := ".".repeat(dot_count)
	if detail == "":
		return "%s%s" % [base_message, dots]
	return "%s%s\n%s" % [base_message, dots, detail]
