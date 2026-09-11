extends SceneTree

const TutorialSystemScript := preload("res://scripts/TutorialSystem.gd")
const MainCoreScript := preload("res://scripts/MainCore.gd")
const TitleMenuScript := preload("res://scripts/TitleMenu.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")

class SyntheticTileWorld extends RefCounted:
	var stale_snapshot := false
	func navmesh_tile_source_key_for_tile(_key: String) -> String: return "current-source"
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		return {"tileKey":key,"sourceKey":"stale-source" if stale_snapshot else "current-source","sourceRevision":1,
			"surfaces":[{"cell":Vector3i.ZERO,"worldPosition":Vector3.ZERO}]}

class SyntheticTileDelegate extends RefCounted:
	var navmesh_world

class FakeStructureSystem:
	extends RefCounted
	var update_calls := 0
	var publication_calls := 0

	func update_around(_center: Vector2i) -> void:
		update_calls += 1

	func request_town_manifest_publication(_town: Dictionary, _requirements: Dictionary, _max_ops: int, _budget_ms: float) -> Dictionary:
		publication_calls += 1
		return {
			"ok": false,
			"status": "failed",
			"reason": "required_town_manifest_generation_failed",
			"manifest": {},
			"pending": [],
			"metrics": {"failureReasons": ["missing required homeKey 3"]}
		}

class FakeNpcSystem:
	extends RefCounted
	var npcs: Array = []
	var autonomy_system = null

class FakeMain:
	extends Node
	var startup_loading_active := true
	var runtime_loading_active := false
	var town_region_cache := {}
	var structure_system = FakeStructureSystem.new()
	var npc_system = null
	var blocks := {}
	var player = null

	func town_region(_rx: int, _rz: int) -> Dictionary:
		return {
			"regionX": 1,
			"regionZ": 0,
			"centerX": 280,
			"centerZ": 0,
			"radius": 30,
			"level": 16.0
		}

	func unlock_crafting_group(_group_id: String, _reason := "") -> bool:
		return true

var report_path := ""
var results: Array[Dictionary] = []
var failure_signal_reason := ""
var completion_signal_count := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_STARTUP_READINESS_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/tutorial-town/startup-loading-readiness-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	test_scenario_requirements_are_semantic()
	test_regional_demand_contract()
	test_missing_manifest_doors_are_structured_failure()
	test_missing_npc_registration_is_structured_failure()
	test_continue_restore_defers_world_setup()
	test_gameplay_physics_gate_rejects_enabled_npc()
	test_loading_completion_requires_all_readiness_domains()
	await test_startup_requires_revision_matched_navigation()
	await test_forced_manifest_failure_keeps_gameplay_disabled_and_visible()
	finish()

func test_regional_demand_contract() -> void:
	const Regions := preload("res://scripts/world/WorldStreamingCoordinator.gd")
	var regions := Regions.new()
	regions.configure("contract-seed")
	var bounds := Regions.playable_bounds(Vector3(-0.25,0.0,-0.25))
	var keys := Regions.chunks_for_bounds(bounds)
	add_result("regional_64m_negative_grid_coverage",keys.has(Vector2i(-2,-2)) and keys.has(Vector2i(1,1)) and keys.size() == 16,{"bounds":bounds,"chunks":keys})
	var first := regions.request_region(bounds,0,"player")
	var second := regions.request_region(bounds,1,"actor")
	var held := regions.retained_gameplay_chunks()
	regions.release_region(first)
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_overlapping_owner_retains_demand",first > 0 and second > 0 and regions.retained_gameplay_chunks() == held,{"count":held.size()})
	var state := regions.region_readiness(bounds)
	add_result("regional_missing_owner_cannot_report_ready",state.status == "pending" and state.missing.size() == 3,state)
	regions.release_region(second)
	add_result("regional_release_hysteresis",not regions.retained_gameplay_chunks().is_empty(),{})
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_release_drains",regions.retained_gameplay_chunks().is_empty(),{})
	regions.configure("next-seed")
	var next := regions.request_region(bounds,0,"new player")
	regions.release_region(first)
	regions.advance(Time.get_ticks_msec()+Regions.RELEASE_HYSTERESIS_MS+1)
	add_result("regional_stale_release_cannot_touch_new_world",next > second and not regions.retained_gameplay_chunks().is_empty(),{})
	var before := regions.retained_gameplay_chunks()
	var rejected := regions.request_region(Rect2i(Vector2i(10000,10000),Vector2i(512,512)),0,"oversized resident request")
	add_result("regional_capacity_rejects_without_dropping_demand",rejected == 0 and regions.last_rejection == "region_resident_capacity" and before == regions.retained_gameplay_chunks(),{})
	const TerrainRuntime := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
	var runtime := TerrainRuntime.new()
	var chunk := Vector2i(-1,0)
	# Synthetic bookkeeping only: no claim that this dictionary is terrain proof.
	runtime.retained_gameplay_chunks[chunk] = true
	runtime.desired_gameplay_chunks[chunk] = true
	runtime.published_gameplay_chunks[chunk] = {"synthetic":true}
	runtime.release_gameplay_chunk(chunk)
	add_result("regional_terrain_release_respects_retained_owner",runtime.published_gameplay_chunks.has(chunk),{})
	runtime.retained_gameplay_chunks.clear()
	runtime.release_gameplay_chunk(chunk)
	add_result("regional_terrain_release_invalidates_publication",not runtime.desired_gameplay_chunks.has(chunk) and not runtime.published_gameplay_chunks.has(chunk),{})
	runtime.free()

func test_startup_requires_revision_matched_navigation() -> void:
	# Synthetic source, real NavigationServer install/sync and production startup
	# consumer. Proves the receipt gate, not generated topology or NPC movement.
	var main = MainCoreScript.new()
	var world := SyntheticTileWorld.new()
	var delegate := SyntheticTileDelegate.new()
	delegate.navmesh_world = NavmeshWorldServiceScript.new()
	var ready: Dictionary = main.publish_startup_navmesh_tile(world,delegate,"0,0")
	for frame in 60:
		if ready.get("status") != "pending": break
		await physics_frame
		ready=main.publish_startup_navmesh_tile(world,delegate,"0,0")
	add_result("startup_navigation_requires_installed_revision",ready.get("ok",false) and ready.get("receipt",{}).get("status")=="ready",ready)
	world.stale_snapshot=true
	var stale: Dictionary = main.publish_startup_navmesh_tile(world,delegate,"0,0")
	add_result("startup_navigation_rejects_stale_registered_source",not stale.get("ok",true),stale)
	delegate.navmesh_world.clear()
	main.free()

func test_scenario_requirements_are_semantic() -> void:
	var tutorial = TutorialSystemScript.new()
	var requirements: Dictionary = tutorial.tutorial_scenario_requirements()
	add_result(
		"tutorial_scenario_derives_semantic_home_requirements",
		bool(requirements.get("ok", false)) \
			and requirements.get("requiredHomeKeys", []) == [0, 1, 2, 3] \
			and int((requirements.get("actorHomeAssignments", {}) as Dictionary).get("mira", -1)) == 3,
		requirements
	)
	tutorial.free()

func test_missing_manifest_doors_are_structured_failure() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	root.add_child(fake_main)
	fake_main.add_child(tutorial)
	tutorial.main = fake_main
	var manifest := {"doorPortalIds": ["door:required-home"]}
	var result: Dictionary = tutorial.tutorial_manifest_door_readiness(manifest)
	var metrics: Dictionary = result.get("metrics", {})
	add_result(
		"missing_manifest_door_block_and_portal_fail_structurally",
		String(result.get("status", "")) == "failed" \
			and String(result.get("reason", "")) == "required_town_doors_not_registered" \
			and metrics.get("missingDoorBlocks", []) == ["door:required-home"] \
			and metrics.get("missingDoorPortals", []) == ["door:required-home"],
		result
	)
	fake_main.free()

func test_missing_npc_registration_is_structured_failure() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	var fake_npcs := FakeNpcSystem.new()
	var bodies: Array[Node3D] = []
	for npc_id in ["rowan", "niko", "sera", "toma", "lyra"]:
		var body := Node3D.new()
		bodies.append(body)
		fake_npcs.npcs.append({"id": npc_id, "body": body})
	fake_main.npc_system = fake_npcs
	tutorial.main = fake_main
	var result: Dictionary = tutorial.tutorial_npc_registration_readiness({})
	add_result(
		"missing_required_npc_registration_fails_before_gameplay",
		String(result.get("status", "")) == "failed" \
			and String(result.get("reason", "")) == "required_tutorial_npcs_not_registered" \
			and (result.get("metrics", {}) as Dictionary).get("missingNpcIds", []) == ["mira"],
		result
	)
	for body in bodies:
		body.free()
	tutorial.free()
	fake_main.free()

func test_continue_restore_defers_world_setup() -> void:
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	tutorial.setup(fake_main)
	tutorial.restore({
		"started": true,
		"interacted": [],
		"completedSteps": [],
		"lastMessage": "saved tutorial",
		"startCell": [267, -10],
		"introRepair": {}
	})
	add_result(
		"continue_restore_defers_generation_and_spawn_to_readiness_gate",
		bool(tutorial.restore_world_setup_pending) \
			and fake_main.structure_system.update_calls == 0 \
			and tutorial.npc_count() == 0,
		{
			"restorePending": tutorial.restore_world_setup_pending,
			"structureUpdateCalls": fake_main.structure_system.update_calls,
			"npcCount": tutorial.npc_count()
		}
	)
	tutorial.free()
	fake_main.free()

func test_gameplay_physics_gate_rejects_enabled_npc() -> void:
	var main = MainCoreScript.new()
	main.set_process(false)
	main.set_process_unhandled_input(false)
	main.set_physics_process(false)
	var player_body := CharacterBody3D.new()
	player_body.set_physics_process(false)
	main.player = player_body
	var npc_body := CharacterBody3D.new()
	npc_body.set_physics_process(true)
	var fake_npcs := FakeNpcSystem.new()
	fake_npcs.npcs = [{"id": "early_npc", "body": npc_body}]
	main.npc_system = fake_npcs
	var failed_result: Dictionary = main.startup_physics_gate_readiness()
	npc_body.set_physics_process(false)
	var ready_result: Dictionary = main.startup_physics_gate_readiness()
	add_result(
		"gameplay_physics_gate_rejects_enabled_registered_npc",
		String(failed_result.get("status", "")) == "failed" \
			and String(failed_result.get("reason", "")) == "gameplay_physics_enabled_before_readiness" \
			and (failed_result.get("metrics", {}) as Dictionary).get("enabledNpcIds", []) == ["early_npc"] \
			and String(ready_result.get("status", "")) == "ready",
		{"failed": failed_result, "ready": ready_result}
	)
	player_body.free()
	npc_body.free()
	main.free()

func test_loading_completion_requires_all_readiness_domains() -> void:
	var main_source := FileAccess.get_file_as_string("res://scripts/MainCore.gd")
	var tutorial_source := FileAccess.get_file_as_string("res://scripts/TutorialSystem.gd")
	var completion_index := main_source.find("startup_loading_completed.emit()")
	var tutorial_ready_index := main_source.find("if not startup_result_is_ready(tutorial_result):")
	var gameplay_ready_index := main_source.find("if not startup_result_is_ready(physics_gate_result):")
	var loading_release_index := main_source.find("startup_loading_active = false", gameplay_ready_index)
	var presentation_index := main_source.find("await wait_for_initial_terrain_presentation()", gameplay_ready_index)
	var new_game_start := main_source.find("func start_new_game")
	var new_game_tutorial_ready := main_source.find("if not startup_result_is_ready(tutorial_result):", new_game_start)
	var new_game_release := main_source.find("runtime_loading_active = false", new_game_start)
	var new_game_presentation := main_source.find("await wait_for_initial_terrain_presentation()", new_game_start)
	var tutorial_domains_present := tutorial_source.find("ensure_town_manifest_ready_staged") >= 0 \
		and tutorial_source.find("tutorial_manifest_door_readiness") >= 0 \
		and tutorial_source.find("tutorial_npc_registration_readiness") >= 0 \
		and tutorial_source.find("claim_town_population") >= 0 \
		and tutorial_source.find("submit_initial_actor_orders") >= 0
	var passed := completion_index >= 0 \
		and tutorial_ready_index >= 0 and tutorial_ready_index < completion_index \
		and gameplay_ready_index >= 0 and gameplay_ready_index < completion_index \
		and loading_release_index > gameplay_ready_index and loading_release_index < completion_index \
		and presentation_index > gameplay_ready_index and presentation_index < loading_release_index \
		and new_game_tutorial_ready > new_game_start \
		and new_game_release > new_game_tutorial_ready \
		and new_game_presentation > new_game_start and new_game_presentation < new_game_release \
		and tutorial_domains_present
	add_result("loading_completion_is_guarded_by_manifest_door_registration_order_and_physics_readiness", passed, {
		"completionIndex": completion_index,
		"tutorialReadyIndex": tutorial_ready_index,
		"gameplayReadyIndex": gameplay_ready_index,
		"loadingReleaseIndex": loading_release_index,
		"newGameTutorialReadyIndex": new_game_tutorial_ready,
		"newGameReleaseIndex": new_game_release,
		"tutorialDomainsPresent": tutorial_domains_present
	})

func test_forced_manifest_failure_keeps_gameplay_disabled_and_visible() -> void:
	failure_signal_reason = ""
	completion_signal_count = 0
	var tutorial = TutorialSystemScript.new()
	var fake_main := FakeMain.new()
	root.add_child(fake_main)
	fake_main.add_child(tutorial)
	tutorial.main = fake_main
	tutorial.town = fake_main.town_region(1, 0)
	var failure: Dictionary = await tutorial.ensure_town_manifest_ready_staged(tutorial.tutorial_scenario_requirements())
	var main = MainCoreScript.new()
	var player_body := CharacterBody3D.new()
	player_body.set_physics_process(true)
	main.player = player_body
	var fake_npcs := FakeNpcSystem.new()
	var npc_body := CharacterBody3D.new()
	npc_body.set_physics_process(true)
	fake_npcs.npcs = [{"id": "contract_npc", "body": npc_body}]
	main.npc_system = fake_npcs
	main.startup_loading_active = true
	main.runtime_loading_active = true
	main.set_process(true)
	main.set_process_unhandled_input(true)
	main.set_physics_process(true)
	main.startup_loading_failed.connect(Callable(self, "_on_failure_signal"))
	main.startup_loading_completed.connect(Callable(self, "_on_completion_signal"))

	var menu = TitleMenuScript.new()
	menu.status_label = Label.new()
	menu.loading_overlay = Control.new()
	menu.loading_overlay.visible = true
	menu.new_game_button = Button.new()
	menu.new_game_button.disabled = true
	menu.continue_button = Button.new()
	menu.quit_button = Button.new()
	menu.quit_button.disabled = true
	menu.launching = true
	main.startup_loading_failed.connect(Callable(menu, "_on_game_loading_failed"))

	var previous_save_override := OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE")
	OS.set_environment("VOXEL_SAVE_PATH_OVERRIDE", "user://vox73_missing_manifest_contract_save.json")
	var reason: String = main.apply_startup_loading_failure_state(failure)
	if previous_save_override == "":
		OS.unset_environment("VOXEL_SAVE_PATH_OVERRIDE")
	else:
		OS.set_environment("VOXEL_SAVE_PATH_OVERRIDE", previous_save_override)

	var passed: bool = reason == "required_town_manifest_generation_failed" \
		and fake_main.structure_system.publication_calls == 1 \
		and String(failure.get("status", "")) == "failed" \
		and failure_signal_reason == reason \
		and completion_signal_count == 0 \
		and not main.startup_loading_active \
		and not main.runtime_loading_active \
		and not main.is_processing() \
		and not main.is_processing_unhandled_input() \
		and not main.is_physics_processing() \
		and not player_body.is_physics_processing() \
		and not npc_body.is_physics_processing() \
		and String(main.startup_loading_failure_result.get("status", "")) == "failed" \
		and menu.status_label.text == reason \
		and not menu.loading_overlay.visible \
		and not menu.new_game_button.disabled \
		and not menu.quit_button.disabled
	add_result("forced_missing_manifest_is_visible_and_cannot_enable_gameplay", passed, {
		"reason": reason,
		"manifestPublicationCalls": fake_main.structure_system.publication_calls,
		"manifestFailure": failure,
		"failureSignalReason": failure_signal_reason,
		"completionSignalCount": completion_signal_count,
		"startupActive": main.startup_loading_active,
		"runtimeLoadingActive": main.runtime_loading_active,
		"mainProcess": main.is_processing(),
		"mainPhysics": main.is_physics_processing(),
		"playerPhysics": player_body.is_physics_processing(),
		"npcPhysics": npc_body.is_physics_processing(),
		"visibleMessage": menu.status_label.text,
		"failureResult": main.startup_loading_failure_result
	})

	menu.status_label.free()
	menu.loading_overlay.free()
	menu.new_game_button.free()
	menu.continue_button.free()
	menu.quit_button.free()
	menu.free()
	fake_main.free()
	player_body.free()
	npc_body.free()
	main.free()

func _on_failure_signal(reason: String) -> void:
	failure_signal_reason = reason

func _on_completion_signal() -> void:
	completion_signal_count += 1

func add_result(name: String, passed: bool, details) -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": TownRuntimeManifestScript.canonical_data(details)
	})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func finish() -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"runnerId": "startup_loading_readiness_contract",
		"testId": "vox_73_startup_loading_readiness_contract",
		"finished": true,
		"passed": failure_count == 0,
		"evidenceLevel": "contract",
		"scope": "Synthetic contract coverage for tutorial startup requirements, missing door/NPC failure, deferred Continue setup, disabled gameplay on failure, and visible menu presentation. No live gameplay acceptance is claimed.",
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify({
		"runnerId": report.runnerId,
		"passed": report.passed,
		"resultCount": report.resultCount,
		"failureCount": report.failureCount
	}, "  "))
	quit(0 if failure_count == 0 else 1)
