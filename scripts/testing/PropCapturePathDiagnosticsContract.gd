extends SceneTree

const MainScript := preload("res://scripts/MainPlaytestTools.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := MainScript.new()
	main.call("_record_prop_capture_path", "physical_bounded", "begin",
		"budget", "children", 120)
	main.call("_record_prop_capture_path", "physical_bounded", "continue",
		"complete", "complete", 220)
	for index in 260:
		main.call("_record_prop_capture_path", "physical_surface_handoff_sync",
			"capture", "ready", "complete", index)
	var paths: Dictionary = (main.get("prop_capture_path_diagnostics") as Dictionary).get("paths", {})
	var bounded: Dictionary = paths.get("physical_bounded", {})
	var surface: Dictionary = paths.get("physical_surface_handoff_sync", {})
	var passed := int(bounded.get("calls", 0)) == 2 \
		and int((bounded.get("events", {}) as Dictionary).get("begin", 0)) == 1 \
		and int((bounded.get("events", {}) as Dictionary).get("continue", 0)) == 1 \
		and int((bounded.get("events", {}) as Dictionary).get("budget", 0)) == 1 \
		and int((bounded.get("events", {}) as Dictionary).get("complete", 0)) == 1 \
		and int((bounded.get("stages", {}) as Dictionary).get("children", 0)) == 1 \
		and int(bounded.get("totalUsec", 0)) == 340 \
		and int(surface.get("calls", 0)) == 260 \
		and (surface.get("samplesUsec", []) as Array).size() == 256 \
		and int(surface.get("samplesDropped", 0)) == 4
	print(JSON.stringify({"schema": "prop-capture-path-diagnostics-contract/v1",
		"passed": passed, "boundedCalls": bounded.get("calls", 0),
		"surfaceCalls": surface.get("calls", 0),
		"surfaceSamplesDropped": surface.get("samplesDropped", 0)}))
	main.free()
	quit(0 if passed else 1)
