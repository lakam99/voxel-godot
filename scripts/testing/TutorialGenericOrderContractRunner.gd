extends SceneTree

const NpcSystemScript := preload("res://scripts/NpcSystem.gd")

class FakeAutonomy:
	extends RefCounted
	var cancel_calls := 0
	var release_calls := 0
	var last_cancel_reason := ""
	var last_release_reason := ""

	func cancel_active_route_request(_entry: Dictionary, reason := "order_replaced") -> Dictionary:
		cancel_calls += 1
		last_cancel_reason = reason
		return {"ok": true, "cancelled": true, "requestId": "route-contract", "reason": reason}

	func release_action_owned_state(_entry: Dictionary, reason := "released") -> void:
		release_calls += 1
		last_release_reason = reason

var report_path := ""
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TUTORIAL_GENERIC_ORDER_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/tutorial-generic-order-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	test_wait_replaced_by_go_home_cleans_owned_state()
	test_cancel_order_cleans_non_tutorial_actor_state()
	test_dialogue_pause_is_generic()
	test_tutorial_scenario_and_acknowledgement_use_generic_orders()
	test_source_has_no_tutorial_movement_privileges()
	finish()

func make_system_and_entry(actor_id: String, tutorial := false) -> Dictionary:
	var system = NpcSystemScript.new()
	root.add_child(system)
	var autonomy := FakeAutonomy.new()
	system.autonomy_system = autonomy
	var body := CharacterBody3D.new()
	system.add_child(body)
	var entry := {
		"id": actor_id,
		"body": body,
		"homePosition": Vector3(10.0, 0.0, 4.0),
		"homeCell": Vector2i(7, 3),
		"jobObjectId": "",
		"jobReservationId": "",
		"jobApproachSlotId": "",
		"scriptedOrderSerial": 0,
		"tutorial": tutorial,
		"npcWalkSpeed": 2.6,
		"npcSprintSpeed": 4.4
	}
	system.npcs.append(entry)
	return {"system": system, "autonomy": autonomy, "body": body, "entry": entry}

func seed_owned_route_state(entry: Dictionary) -> void:
	entry["routeLease"] = {"leaseId": "lease-contract"}
	entry["routeLeaseId"] = "lease-contract"
	entry["routineRouteV2RequestId"] = "route-contract"
	entry["routineRouteV2Key"] = "old-route"
	entry["pathWaypoints"] = [Vector3.ONE]
	entry["routeCells"] = [Vector2i.ONE]
	entry["routeActions"] = {0: {"kind": "door"}}
	entry["activeDoorPortalId"] = "door:contract"
	entry["activeDoorActorId"] = String(entry.get("id", ""))
	entry["activeDoorTrafficGroupId"] = "traffic:contract"
	entry["activeTrafficStepGroup"] = "traffic:contract"

func test_wait_replaced_by_go_home_cleans_owned_state() -> void:
	var fixture := make_system_and_entry("mira", true)
	var system = fixture.system
	var autonomy: FakeAutonomy = fixture.autonomy
	var entry: Dictionary = fixture.entry
	var wait_result: Dictionary = system.order_wait("mira", "tutorial_knock_pending")
	seed_owned_route_state(entry)
	autonomy.cancel_calls = 0
	autonomy.release_calls = 0
	var home_result: Dictionary = system.order_go_home("mira", "tutorial_knock_complete")
	var cleanup: Dictionary = home_result.get("replacementCleanup", {}) if home_result.get("replacementCleanup", {}) is Dictionary else {}
	var route_cancel: Dictionary = cleanup.get("routeCancellation", {}) if cleanup.get("routeCancellation", {}) is Dictionary else {}
	var passed := String(wait_result.get("kind", "")) == "wait" \
		and String(home_result.get("kind", "")) == "go_home" \
		and String(home_result.get("state", "")) == "PENDING" \
		and String(home_result.get("reason", "")) == "tutorial_knock_complete" \
		and String(home_result.get("submissionReason", "")) == "tutorial_knock_complete" \
		and autonomy.cancel_calls == 1 \
		and autonomy.release_calls == 1 \
		and bool(route_cancel.get("cancelled", false)) \
		and not entry.has("routeLease") \
		and not entry.has("routineRouteV2RequestId") \
		and not entry.has("activeDoorPortalId") \
		and String((entry.get("activeMotionGoal", {}) as Dictionary).get("goalKind", "")) == "home"
	add_result("generic_wait_to_go_home_replacement_cancels_route_door_and_traffic_state", passed, {
		"wait": wait_result,
		"home": home_result,
		"cancelCalls": autonomy.cancel_calls,
		"releaseCalls": autonomy.release_calls
	})
	system.free()

func test_cancel_order_cleans_non_tutorial_actor_state() -> void:
	var fixture := make_system_and_entry("ordinary-worker", false)
	var system = fixture.system
	var autonomy: FakeAutonomy = fixture.autonomy
	var body: Node = fixture.body
	var entry: Dictionary = fixture.entry
	system.order_go_to("ordinary-worker", Vector3(8.0, 0.0, 8.0), "ordinary_work_order")
	seed_owned_route_state(entry)
	autonomy.cancel_calls = 0
	autonomy.release_calls = 0
	var cancelled: Dictionary = system.cancel_order("ordinary-worker", "ordinary_order_cancelled")
	var passed := String(cancelled.get("state", "")) == "CANCELLED" \
		and String(body.get_meta("npc_scripted_order_state", "")) == "CANCELLED" \
		and autonomy.cancel_calls == 1 \
		and autonomy.release_calls == 1 \
		and not entry.has("routeLease") \
		and not entry.has("routineRouteV2RequestId") \
		and not entry.has("activeDoorPortalId") \
		and String(entry.get("activeGoalKind", "")) == "idle"
	add_result("non_tutorial_cancel_order_uses_the_same_ownership_cleanup", passed, {
		"cancelled": cancelled,
		"cancelCalls": autonomy.cancel_calls,
		"releaseCalls": autonomy.release_calls
	})
	system.free()

func test_dialogue_pause_is_generic() -> void:
	var fixture := make_system_and_entry("dialogue-worker", false)
	var system = fixture.system
	var body: Node3D = fixture.body
	var entry: Dictionary = fixture.entry
	body.set_meta("npc_dialogue_focused", true)
	body.set_meta("npc_dialogue_face_position", Vector3(2.0, 0.0, 2.0))
	var focused: bool = bool(system.npc_movement_is_paused(entry, body))
	body.set_meta("npc_dialogue_focused", false)
	var released: bool = not bool(system.npc_movement_is_paused(entry, body))
	add_result("dialogue_focus_pauses_and_releases_an_ordinary_npc", focused and released, {
		"focused": focused,
		"released": released
	})
	system.free()

func test_tutorial_scenario_and_acknowledgement_use_generic_orders() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd")
	var scenario_wait := source.find('"initialOrder": {') >= 0 \
		and source.find('"kind": "wait"') >= 0 \
		and source.find('"reason": "tutorial_knock_pending"') >= 0
	var acknowledgement_home := source.find('order_go_home(actor, "tutorial_knock_complete")') >= 0
	add_result("tutorial_knock_choreography_is_wait_then_one_generic_go_home_call", scenario_wait and acknowledgement_home, {
		"scenarioWait": scenario_wait,
		"acknowledgementHome": acknowledgement_home
	})

func test_source_has_no_tutorial_movement_privileges() -> void:
	var sources := "\n".join([
		FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd"),
		FileAccess.get_file_as_string("res://scripts/TutorialRescueSystem.gd"),
		FileAccess.get_file_as_string("res://scripts/NpcSystem.gd"),
		FileAccess.get_file_as_string("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd"),
		FileAccess.get_file_as_string("res://scripts/npc_ai/behavior/NpcPerceptionService.gd")
	])
	var forbidden := [
		"release_intro_hold_and_order_home",
		"holdIntroDoor",
		"npc_hold_intro_door",
		"clear_intro_hold_for_entry",
		"npc_is_held_by_intro_or_dialogue",
		"release_intro_elder_home_order",
		"npc_force_hold",
		"npc_rescue_stranded"
	]
	var found: Array[String] = []
	for symbol in forbidden:
		if sources.find(symbol) >= 0:
			found.append(symbol)
	add_result("production_source_has_no_tutorial_movement_hold_privileges", found.is_empty(), {"found": found})

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failures := results.filter(func(result): return not bool(result.get("passed", false)))
	var report := {
		"schemaVersion": 1,
		"runnerId": "tutorial_generic_order_contract",
		"testId": "vox_75_tutorial_generic_order_contract",
		"finished": true,
		"passed": failures.is_empty(),
		"evidenceLevel": "contract",
		"scope": "Generic scripted-order submission, replacement cleanup, dialogue pause, and static tutorial choreography. No live gameplay behavior is exercised.",
		"resultCount": results.size(),
		"failureCount": failures.size(),
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
	quit(0 if bool(report.passed) else 1)
