extends SceneTree

const PlaytestSearchLoadingControllerScript := preload("res://scripts/testing/PlaytestSearchLoadingController.gd")

class FakeHud extends Node:
	var overlay_visible := false
	var messages: Array[String] = []

	func show_loading_overlay(message := "Loading") -> void:
		overlay_visible = true
		messages.append(String(message))

	func set_loading_message(message: String) -> void:
		messages.append(message)

	func hide_loading_overlay() -> void:
		overlay_visible = false

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var hud := FakeHud.new()
	root.add_child(hud)
	var controller = PlaytestSearchLoadingControllerScript.new()
	root.add_child(controller)
	await process_frame
	var shown := bool(controller.begin(hud, "Searching generated forests", "Candidate 1/8"))
	await create_timer(0.42).timeout
	controller.set_detail("Candidate 1/8 — streaming 90/180")
	await create_timer(0.42).timeout
	controller.set_detail("Candidate 1/8 — searching trees 120/420")
	await create_timer(0.42).timeout
	var summary: Dictionary = controller.finish()
	await process_frame
	var distinct_messages := {}
	for message in hud.messages:
		distinct_messages[message] = true
	var passed := shown \
		and int(summary.get("returnedFrames", 0)) >= 3 \
		and int(summary.get("messageUpdates", 0)) >= 3 \
		and distinct_messages.size() >= 4 \
		and not hud.overlay_visible
	print(JSON.stringify({
		"runnerId": "playtest_search_loading_controller_contract",
		"evidenceLevel": "contract",
		"passed": passed,
		"shown": shown,
		"returnedFrames": int(summary.get("returnedFrames", 0)),
		"messageUpdates": int(summary.get("messageUpdates", 0)),
		"distinctMessages": distinct_messages.size(),
		"hiddenAfterSearch": not hud.overlay_visible
	}))
	quit(0 if passed else 1)
