extends SceneTree
## Static/source contract for production loading semantics. It does not prove a
## live renderer receipt or headed gameplay; those require separate acceptance.

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var output := OS.get_environment("CITADEL_STARTUP_DEADLINE_OUTPUT")
	if output.is_empty():
		quit(2)
		return
	var main_source := FileAccess.get_file_as_string("res://scripts/MainCore.gd")
	var discovery_source := FileAccess.get_file_as_string("res://scripts/MainDiscoveryFlow.gd")
	var terrain_source := FileAccess.get_file_as_string("res://scripts/terrain/VoxelTerrainRuntime.gd")
	var boot_source := _function_body(main_source, "func _run_deferred_startup_boot()")
	var gates := {
		"startup_physics_gate_readiness": _function_body(main_source, "func startup_physics_gate_readiness()"),
		"wait_for_final_voxel_view_distance": _function_body(main_source, "func wait_for_final_voxel_view_distance()"),
		"wait_for_initial_terrain_mesh_coverage": _function_body(main_source, "func wait_for_initial_terrain_mesh_coverage("),
		"bootstrap_initial_chunks_staged": _function_body(main_source, "func bootstrap_initial_chunks_staged("),
		"wait_for_initial_terrain_presentation": _function_body(main_source, "func wait_for_initial_terrain_presentation()"),
		"wait_for_initial_region_readiness": _function_body(main_source, "func wait_for_initial_region_readiness()"),
		"wait_for_initial_region_physical_readiness": _function_body(main_source, "func wait_for_initial_region_physical_readiness()"),
		"wait_for_initial_voxel_collision_publication": _function_body(main_source, "func wait_for_initial_voxel_collision_publication("),
		"wait_for_initial_player_collision_publication": _function_body(main_source, "func wait_for_initial_player_collision_publication()"),
		"drain_initial_navigation_changes_staged": _function_body(main_source, "func drain_initial_navigation_changes_staged()"),
		"prime_initial_navigation_snapshot_staged": _function_body(main_source, "func prime_initial_navigation_snapshot_staged()"),
		"prime_initial_navigation_tiles_staged": _function_body(main_source, "func prime_initial_navigation_tiles_staged("),
		"wait_for_initial_navigation_map_readiness": _function_body(main_source, "func wait_for_initial_navigation_map_readiness()"),
		"wait_for_initial_visible_world_readiness": _function_body(main_source, "func wait_for_initial_visible_world_readiness()"),
		"prepare_streaming_destination_staged": _function_body(main_source, "func prepare_streaming_destination_staged("),
		"run_runtime_world_load_staged": _function_body(main_source, "func run_runtime_world_load_staged("),
		"retire_generated_scenes_before_world_reset": _function_body(main_source, "func retire_generated_scenes_before_world_reset()"),
		"wait_for_spawn_presentation": _function_body(terrain_source, "func wait_for_spawn_presentation("),
		"wait_for_seed_reset_task_drain": _function_body(terrain_source, "func wait_for_seed_reset_task_drain("),
		"relocation_presentation_callers": _function_body(discovery_source, "func teleport_to(value: String)")
	}
	var no_wall_clock_terminal := true
	var all_wait_for_next_progress := true
	for gate_name: String in gates:
		var body: String = gates[gate_name]
		no_wall_clock_terminal = no_wall_clock_terminal and not body.is_empty() \
			and not body.to_lower().contains("timeout")
		if gate_name not in ["startup_physics_gate_readiness", "wait_for_initial_terrain_presentation", "relocation_presentation_callers"]:
			all_wait_for_next_progress = all_wait_for_next_progress \
				and body.contains("startup_loading_yield")
	var presentation_checks_cancel_and_draw: bool = gates["wait_for_spawn_presentation"].contains("while true:") \
		and gates["wait_for_spawn_presentation"].contains("not is_instance_valid(main)") \
		and gates["wait_for_spawn_presentation"].contains("shutdown_requested") \
		and gates["wait_for_spawn_presentation"].contains("frame_post_draw")
	var visible_world_wait_cancels_and_reports_progress: bool = gates["wait_for_initial_visible_world_readiness"].contains("if shutdown_requested") \
		and gates["wait_for_initial_visible_world_readiness"].contains("full_view_readiness(\"player\"") \
		and gates["wait_for_initial_visible_world_readiness"].contains("candidateCount") \
		and gates["wait_for_initial_visible_world_readiness"].contains("representedCount") \
		and gates["wait_for_initial_visible_world_readiness"].contains("pendingCount") \
		and gates["wait_for_initial_visible_world_readiness"].contains("startup_loading_yield")
	var relocation_cancels_superseded_demand: bool = gates["prepare_streaming_destination_staged"].contains("seed_text != expected_seed") \
		and gates["prepare_streaming_destination_staged"].contains("streaming_requests.get(owner,0)) != request_id")
	var authoritative_failure_paths_remain: bool = gates["wait_for_initial_region_readiness"].contains('state.status == "failed"') \
		and gates["wait_for_initial_voxel_collision_publication"].contains("secondary_viewer_admission_failure") \
		and gates["wait_for_initial_navigation_map_readiness"].contains('reason in ["navmesh_backend_disabled"')
	var bounded_diagnostics_remain: bool = _function_body(main_source, "func wait_for_startup_loading_complete(").contains("var deadline") \
		and main_source.contains("VOXEL_SHUTDOWN_TASK_DRAIN_TIMEOUT_SECONDS") \
		and not gates["wait_for_seed_reset_task_drain"].contains("TIMEOUT")
	var runtime_save_drain_is_retryable: bool = gates["run_runtime_world_load_staged"].contains("while save_system != null and save_system.has_async_save_pending()") \
		and gates["run_runtime_world_load_staged"].contains("save_system.poll_async_save(false)") \
		and gates["run_runtime_world_load_staged"].contains("startup_loading_yield(\"Waiting for pending save\"") \
		and gates["run_runtime_world_load_staged"].contains("if shutdown_requested") \
		and not gates["run_runtime_world_load_staged"].contains("30000") \
		and not gates["run_runtime_world_load_staged"].contains("timed_out")
	var world_reset_drain_is_retryable: bool = gates["retire_generated_scenes_before_world_reset"].contains("while true:") \
		and gates["retire_generated_scenes_before_world_reset"].contains("while not publication.world_reset_ready()") \
		and gates["retire_generated_scenes_before_world_reset"].contains("startup_loading_yield(\"Clearing previous navigation\"") \
		and gates["retire_generated_scenes_before_world_reset"].contains("startup_loading_yield(\"Clearing previous landmarks\"") \
		and gates["retire_generated_scenes_before_world_reset"].contains("finish_publication_reset()") \
		and gates["retire_generated_scenes_before_world_reset"].contains("drain_section_presentations_before_teardown()") \
		and not gates["retire_generated_scenes_before_world_reset"].contains("30000")
	var reset_is_shared_by_new_game_and_continue: bool = gates["run_runtime_world_load_staged"].contains("retire_generated_scenes_before_world_reset()") \
		and _function_body(main_source, "func run_new_game_staged(").contains("retire_generated_scenes_before_world_reset()")
	var checks := {
		"production_gates_have_no_elapsed_time_failure": no_wall_clock_terminal,
		"pending_gates_continue_reporting_progress": all_wait_for_next_progress,
		"visible_spawn_gate_keeps_progress_and_cancellation": visible_world_wait_cancels_and_reports_progress,
		"boot_keeps_exact_prerequisite_order": boot_source.find("startup_physics_gate_readiness()") < boot_source.find("wait_for_initial_terrain_presentation()") \
			and boot_source.find("wait_for_initial_region_readiness()") < boot_source.find("wait_for_initial_visible_world_readiness()") \
			and boot_source.find("spawn_player_after_visible_world_ready(visible_result)") > boot_source.find("wait_for_initial_visible_world_readiness()"),
		"presentation_requires_stable_draw_and_cancels": presentation_checks_cancel_and_draw,
		"destination_request_supersession_cancels_stale_wait": relocation_cancels_superseded_demand,
		"authoritative_nonretryable_failures_remain_terminal": authoritative_failure_paths_remain,
		"runner_and_shutdown_bounds_remain_separate": bounded_diagnostics_remain,
		"runtime_load_save_drain_remains_pending_with_progress": runtime_save_drain_is_retryable,
		"new_game_and_continue_reset_drains_remain_pending": world_reset_drain_is_retryable and reset_is_shared_by_new_game_and_continue
	}
	var passed := not checks.values().has(false)
	var report := {
		"schema": "production_readiness_no_timeout_source_contract/v1",
		"passed": passed,
		"checks": checks,
		"productionGateNames": gates.keys(),
		"evidenceLevel": "static_source_contract",
		"doesNotProve": "No live startup, native section receipt, rendered frame, or gameplay behavior is exercised.",
		"sourceSha256": {
			"main": FileAccess.get_sha256("res://scripts/MainCore.gd"),
			"discovery": FileAccess.get_sha256("res://scripts/MainDiscoveryFlow.gd"),
			"terrain": FileAccess.get_sha256("res://scripts/terrain/VoxelTerrainRuntime.gd")
		}
	}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PRODUCTION READINESS NO TIMEOUT SOURCE CONTRACT ", passed)
	quit(0 if passed else 1)

func _function_body(source: String, signature: String) -> String:
	var start := source.find(signature)
	if start < 0:
		return ""
	var end := source.find("\nfunc ", start + signature.length())
	return source.substr(start, end - start if end >= 0 else source.length() - start)
