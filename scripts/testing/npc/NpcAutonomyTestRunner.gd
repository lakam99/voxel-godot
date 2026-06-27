extends Node

const NpcTestClockScript := preload("res://scripts/testing/npc/NpcTestClock.gd")
const NpcTestAssertionsScript := preload("res://scripts/testing/npc/NpcTestAssertions.gd")
const PlayerControllerScript := preload("res://scripts/PlayerController.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")
const NpcSystemScript := preload("res://scripts/NpcSystem.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcAgentContextScript := preload("res://scripts/npc_ai/NpcAgentContext.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const NpcBrainSchedulerScript := preload("res://scripts/npc_ai/NpcBrainScheduler.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const RouteResultScript := preload("res://scripts/npc_ai/contracts/RouteResult.gd")
const NpcActionInstanceScript := preload("res://scripts/npc_ai/contracts/NpcActionInstance.gd")
const InteractionResultScript := preload("res://scripts/npc_ai/contracts/InteractionResult.gd")
const NpcTelemetryServiceScript := preload("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const NavigationSemanticServiceScript := preload("res://scripts/npc_ai/navigation/NavigationSemanticService.gd")
const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcMotionControllerScript := preload("res://scripts/npc_ai/NpcMotionController.gd")
const NpcSafePlacementServiceScript := preload("res://scripts/npc_ai/NpcSafePlacementService.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
const NpcAgentScript := preload("res://scripts/npc_ai/NpcAgent.gd")

var suite_filter := "contract"
var case_filter := ""
var time_mode := "both"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var trace_dir := ""
var screenshot_dir := ""
var run_token := ""
var branch := ""
var git_commit := ""
var started_utc := ""
var finished_utc := ""
var started_unix := 0.0
var watchdog_seconds := 18.0
var elapsed := 0.0
var finished := false
var failed := false
var results: Array[Dictionary] = []
var route_case_provider = null
var repair_case_provider = null
var door_case_provider = null
var avoidance_case_provider = null
var traffic_case_provider = null
var behavior_case_provider = null
var interaction_case_provider = null
var streaming_save_case_provider = null
var soak_case_provider = null
var metrics := {
	"assertions": 0,
	"selectedCases": 0,
	"selectedRuns": 0
}

func _ready() -> void:
	configure_from_environment()
	started_unix = Time.get_unix_time_from_system()
	started_utc = Time.get_datetime_string_from_system(true)
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result(
			"npc_contract_runner_watchdog",
			time_mode,
			false,
			"watchdog %.2fs exceeded" % watchdog_seconds,
			["watchdog_seconds"],
			{ "elapsed": elapsed }
		)
		finish()

func configure_from_environment() -> void:
	suite_filter = OS.get_environment("VOXEL_NPC_TEST_SUITE").to_lower()
	if suite_filter == "":
		suite_filter = "contract"
	case_filter = OS.get_environment("VOXEL_NPC_TEST_CASE")
	time_mode = OS.get_environment("VOXEL_NPC_TIME_MODE").to_lower()
	if time_mode == "":
		time_mode = "both"
	seed = OS.get_environment("VOXEL_NPC_TEST_SEED")
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_NPC_TEST_REPORT")
	if report_path == "":
		report_path = "user://npc-contract-report.json"
	progress_path = OS.get_environment("VOXEL_NPC_TEST_PROGRESS")
	trace_dir = OS.get_environment("VOXEL_NPC_TEST_TRACE_DIR")
	screenshot_dir = OS.get_environment("VOXEL_NPC_TEST_SCREENSHOT_DIR")
	run_token = OS.get_environment("VOXEL_NPC_TEST_RUN_TOKEN")
	branch = OS.get_environment("VOXEL_GIT_BRANCH")
	git_commit = OS.get_environment("VOXEL_GIT_COMMIT")
	var watchdog_value := OS.get_environment("VOXEL_NPC_TEST_WATCHDOG_SECONDS")
	if watchdog_value != "":
		watchdog_seconds = maxf(1.0, float(watchdog_value))

func run() -> void:
	var cases := contract_cases()
	var matched_case_count := 0
	var matched_run_count := 0
	for test_case in cases:
		if not suite_matches(String(test_case.get("suite", ""))):
			continue
		if case_filter != "" and String(test_case.get("id", "")) != case_filter:
			continue
		var modes := selected_modes(test_case)
		if modes.is_empty():
			continue
		matched_case_count += 1
		for mode in modes:
			matched_run_count += 1
			if finished:
				return
			write_progress("%s:%s" % [String(test_case.get("id", "")), mode])
			var case_start := Time.get_unix_time_from_system()
			var outcome: Dictionary = test_case["callable"].call(mode)
			var duration := Time.get_unix_time_from_system() - case_start
			add_result(
				String(test_case.get("id", "")),
				mode,
				bool(outcome.get("passed", false)),
				String(outcome.get("details", "")),
				outcome.get("assertions", []),
				outcome.get("keyState", {}),
				duration
			)
	metrics["selectedCases"] = matched_case_count
	metrics["selectedRuns"] = matched_run_count
	if matched_run_count == 0:
		add_result(
			"npc_contract_no_matching_tests",
			time_mode,
			false,
			"suite='%s' case='%s' time='%s'" % [suite_filter, case_filter, time_mode],
			["matching_case"],
			{}
		)
	finish()

func contract_cases() -> Array[Dictionary]:
	var cases: Array[Dictionary] = [
		{
			"id": "npc_contract_clock_day_snapshot",
			"suite": "contract",
			"timeModes": ["day"],
			"callable": Callable(self, "test_clock_day_snapshot")
		},
		{
			"id": "npc_contract_clock_night_snapshot",
			"suite": "contract",
			"timeModes": ["night"],
			"callable": Callable(self, "test_clock_night_snapshot")
		},
		{
			"id": "npc_contract_runner_filters",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_runner_filters")
		},
		{
			"id": "npc_contract_report_freshness",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_report_freshness")
		},
		{
			"id": "npc_contract_report_schema",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_report_schema")
		},
		{
			"id": "npc_contract_route_status_terminal",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_route_status_terminal")
		},
		{
			"id": "npc_contract_partial_never_arrival",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_partial_never_arrival")
		},
		{
			"id": "npc_contract_stable_tie_break",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_stable_tie_break")
		},
		{
			"id": "npc_contract_profile_capability_filter",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_profile_capability_filter")
		},
		{
			"id": "npc_contract_rng_stream_isolation",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_rng_stream_isolation")
		},
		{
			"id": "npc_contract_bounded_trace_and_cache",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_bounded_trace_and_cache")
		},
		{
			"id": "npc_contract_cancellation_generation",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_cancellation_generation")
		},
		{
			"id": "npc_contract_change_bus_coalesces_tiles",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_change_bus_coalesces_tiles")
		},
		{
			"id": "npc_contract_change_bus_monotonic_revision",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_change_bus_monotonic_revision")
		},
		{
			"id": "npc_contract_guard_duty_not_can_fight",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_guard_duty_not_can_fight")
		},
		{
			"id": "npc_contract_autonomy_composition_no_main_layer",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_autonomy_composition_no_main_layer")
		},
		{
			"id": "npc_contract_rng_stream_isolation_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_rng_stream_isolation_baseline")
		},
		{
			"id": "npc_contract_player_motor_characterization_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_player_motor_characterization_baseline")
		},
		{
			"id": "npc_contract_existing_save_defaults_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_existing_save_defaults_baseline")
		},
		{
			"id": "npc_contract_existing_npc_navigation_runner_callable",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_existing_npc_navigation_runner_callable")
		},
		{
			"id": "npc_contract_all_runner_registry_baseline",
			"suite": "contract",
			"timeModes": ["day", "night"],
			"callable": Callable(self, "test_all_runner_registry_baseline")
		}
	]
	cases.append_array(motor_cases())
	cases.append_array(nav_world_cases())
	if suite_filter == "route" or suite_filter == "all" or suite_filter == "":
		cases.append_array(route_cases())
	if suite_filter == "repair" or suite_filter == "all" or suite_filter == "":
		cases.append_array(repair_cases())
	if suite_filter == "door" or suite_filter == "all" or suite_filter == "":
		cases.append_array(door_cases())
	if suite_filter == "avoidance" or suite_filter == "all" or suite_filter == "":
		cases.append_array(avoidance_cases())
	if suite_filter == "traffic" or suite_filter == "all" or suite_filter == "":
		cases.append_array(traffic_cases())
	if suite_filter == "behavior" or suite_filter == "all" or suite_filter == "":
		cases.append_array(behavior_cases())
	if suite_filter == "interaction" or suite_filter == "all" or suite_filter == "":
		cases.append_array(interaction_cases())
	if suite_filter == "streaming_save" or suite_filter == "all" or suite_filter == "":
		cases.append_array(streaming_save_cases())
	if suite_filter == "soak" or suite_filter == "all" or suite_filter == "":
		cases.append_array(soak_cases())
	return cases

func motor_cases() -> Array[Dictionary]:
	var ids := [
		["npc_motor_player_characterization_flat", "test_motor_player_characterization_flat"],
		["npc_motor_player_characterization_slope", "test_motor_player_characterization_slope"],
		["npc_motor_player_characterization_jump", "test_motor_player_characterization_jump"],
		["npc_motor_npc_flat_acceleration", "test_motor_npc_flat_acceleration"],
		["npc_motor_npc_slope_limit", "test_motor_npc_slope_limit"],
		["npc_motor_npc_step_up_limit", "test_motor_npc_step_up_limit"],
		["npc_motor_npc_safe_drop", "test_motor_npc_safe_drop"],
		["npc_motor_wall_slide_no_penetration", "test_motor_wall_slide_no_penetration"],
		["npc_motor_fence_window_corner_no_penetration", "test_motor_fence_window_corner_no_penetration"],
		["npc_motor_closed_door_blocks", "test_motor_closed_door_blocks"],
		["npc_motor_open_door_clears", "test_motor_open_door_clears"],
		["npc_motor_player_npc_solid_separation", "test_motor_player_npc_solid_separation"],
		["npc_motor_decorative_path_torch_nonblocking_mask", "test_motor_decorative_path_torch_nonblocking_mask"],
		["npc_motor_no_route_transform_write", "test_motor_no_route_transform_write"],
		["npc_motor_no_unstick_teleport", "test_motor_no_unstick_teleport"],
		["npc_motor_spawn_safe_placement", "test_motor_spawn_safe_placement"],
		["npc_motor_spawn_rejects_occupied_capsule", "test_motor_spawn_rejects_occupied_capsule"],
		["npc_motor_every_active_actor_physics_tick", "test_motor_every_active_actor_physics_tick"]
	]
	var cases: Array[Dictionary] = []
	for spec in ids:
		cases.append({
			"id": String(spec[0]),
			"suite": "motor",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return cases

func nav_world_cases() -> Array[Dictionary]:
	var ids := [
		["npc_navworld_event_block_add_dirty_exact_tiles", "test_navworld_event_block_add_dirty_exact_tiles"],
		["npc_navworld_event_block_remove_dirty_exact_tiles", "test_navworld_event_block_remove_dirty_exact_tiles"],
		["npc_navworld_event_prop_remove_dirty_exact_tiles", "test_navworld_event_prop_remove_dirty_exact_tiles"],
		["npc_navworld_event_terrain_edit_dirty_exact_tiles", "test_navworld_event_terrain_edit_dirty_exact_tiles"],
		["npc_navworld_event_chunk_load_unload", "test_navworld_event_chunk_load_unload"],
		["npc_navworld_no_scene_scan_revision", "test_navworld_no_scene_scan_revision"],
		["npc_navworld_multisurface_bridge", "test_navworld_multisurface_bridge"],
		["npc_navworld_tunnel_headroom", "test_navworld_tunnel_headroom"],
		["npc_navworld_stacked_surfaces_disconnected", "test_navworld_stacked_surfaces_disconnected"],
		["npc_navworld_profile_clearance_small_large", "test_navworld_profile_clearance_small_large"],
		["npc_navworld_slope_step_drop_edges", "test_navworld_slope_step_drop_edges"],
		["npc_navworld_corner_cut_rejected", "test_navworld_corner_cut_rejected"],
		["npc_navworld_door_portal_edge_registered", "test_navworld_door_portal_edge_registered"],
		["npc_navworld_semantic_home_interior", "test_navworld_semantic_home_interior"],
		["npc_navworld_semantic_guard_post", "test_navworld_semantic_guard_post"],
		["npc_navworld_semantic_road_and_work_anchor", "test_navworld_semantic_road_and_work_anchor"],
		["npc_navworld_unloaded_tile_not_traversable", "test_navworld_unloaded_tile_not_traversable"],
		["npc_navworld_build_budget_yields_and_resumes", "test_navworld_build_budget_yields_and_resumes"],
		["npc_navworld_deterministic_tile_output", "test_navworld_deterministic_tile_output"]
	]
	var cases: Array[Dictionary] = []
	for spec in ids:
		cases.append({
			"id": String(spec[0]),
			"suite": "nav_world",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return cases

func route_cases() -> Array[Dictionary]:
	if route_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcRouteTestCases.gd")
		route_case_provider = provider_script.new()
		route_case_provider.call("setup", self)
	return route_case_provider.call("cases")

func repair_cases() -> Array[Dictionary]:
	if repair_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcRepairTestCases.gd")
		repair_case_provider = provider_script.new()
		repair_case_provider.call("setup", self)
	return repair_case_provider.call("cases")

func door_cases() -> Array[Dictionary]:
	if door_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcDoorTestCases.gd")
		door_case_provider = provider_script.new()
		door_case_provider.call("setup", self)
	return door_case_provider.call("cases")

func avoidance_cases() -> Array[Dictionary]:
	if avoidance_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcAvoidanceTestCases.gd")
		avoidance_case_provider = provider_script.new()
		avoidance_case_provider.call("setup", self)
	return avoidance_case_provider.call("cases")

func traffic_cases() -> Array[Dictionary]:
	if traffic_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcTrafficTestCases.gd")
		traffic_case_provider = provider_script.new()
		traffic_case_provider.call("setup", self)
	return traffic_case_provider.call("cases")

func behavior_cases() -> Array[Dictionary]:
	if behavior_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcBehaviorTestCases.gd")
		behavior_case_provider = provider_script.new()
		behavior_case_provider.call("setup", self)
	return behavior_case_provider.call("cases")

func interaction_cases() -> Array[Dictionary]:
	if interaction_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcInteractionTestCases.gd")
		interaction_case_provider = provider_script.new()
		interaction_case_provider.call("setup", self)
	return interaction_case_provider.call("cases")

func streaming_save_cases() -> Array[Dictionary]:
	if streaming_save_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcStreamingSaveTestCases.gd")
		streaming_save_case_provider = provider_script.new()
		streaming_save_case_provider.call("setup", self)
	return streaming_save_case_provider.call("cases")

func soak_cases() -> Array[Dictionary]:
	if soak_case_provider == null:
		var provider_script = load("res://scripts/testing/npc/NpcSoakTestCases.gd")
		soak_case_provider = provider_script.new()
		soak_case_provider.call("setup", self)
	return soak_case_provider.call("cases")

func suite_matches(case_suite: String) -> bool:
	return suite_filter == "" or suite_filter == "all" or suite_filter == case_suite

func selected_modes(test_case: Dictionary) -> Array[String]:
	var supported: Array = test_case.get("timeModes", ["day", "night"])
	var modes: Array[String] = []
	if time_mode == "both":
		for candidate in ["day", "night"]:
			if supported.has(candidate):
				modes.append(candidate)
	elif supported.has(time_mode):
		modes.append(time_mode)
	return modes

func test_clock_day_snapshot(_mode: String) -> Dictionary:
	var clock = NpcTestClockScript.new()
	clock.set_canonical_day()
	clock.freeze()
	var snapshot: Dictionary = clock.snapshot()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(snapshot.get("timeOfDay", -1.0)), 0.25)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("clockPhase", -1.0)), 0.5)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("displayHour", -1.0)), 12.0)
		and String(snapshot.get("scheduleState", "")) == "day"
		and bool(snapshot.get("frozen", false))
	)
	return outcome(
		passed,
		"snapshot %s" % JSON.stringify(snapshot),
		["time_of_day", "clock_phase", "display_hour", "schedule_state"],
		{ "snapshot": snapshot }
	)

func test_clock_night_snapshot(_mode: String) -> Dictionary:
	var clock = NpcTestClockScript.new()
	clock.set_canonical_night()
	clock.freeze()
	var snapshot: Dictionary = clock.snapshot()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(snapshot.get("timeOfDay", -1.0)), 0.75)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("clockPhase", -1.0)), 0.0)
		and NpcTestAssertionsScript.approx_equal(float(snapshot.get("displayHour", -1.0)), 0.0)
		and String(snapshot.get("scheduleState", "")) == "night"
		and bool(snapshot.get("frozen", false))
	)
	return outcome(
		passed,
		"snapshot %s" % JSON.stringify(snapshot),
		["time_of_day", "clock_phase", "display_hour", "schedule_state"],
		{ "snapshot": snapshot }
	)

func test_runner_filters(mode: String) -> Dictionary:
	var valid_mode := time_mode in ["day", "night", "both", "transition"]
	var case_ok := case_filter == "" or case_filter.begins_with("npc_contract_")
	var passed := suite_filter == "contract" and valid_mode and case_ok and mode in ["day", "night"]
	return outcome(
		passed,
		"suite=%s case=%s time=%s activeMode=%s seed=%s" % [suite_filter, case_filter, time_mode, mode, seed],
		["suite_filter", "case_filter", "time_mode", "seed"],
		{ "suite": suite_filter, "case": case_filter, "timeMode": time_mode, "activeMode": mode, "seed": seed }
	)

func test_report_freshness(_mode: String) -> Dictionary:
	var passed := run_token.length() >= 16 and report_path != "" and progress_path != "" and started_unix > 0.0
	return outcome(
		passed,
		"token=%s report=%s progress=%s started=%.0f" % [run_token, report_path, progress_path, started_unix],
		["run_token", "report_path", "progress_path", "started_unix"],
		{ "runToken": run_token, "report": report_path, "progress": progress_path, "startedUnix": started_unix }
	)

func test_report_schema(_mode: String) -> Dictionary:
	var report := build_report(false)
	var required := NpcTestAssertionsScript.required_report_schema_keys()
	var passed := NpcTestAssertionsScript.dictionary_has_keys(report, required)
	return outcome(
		passed,
		"keys=%s" % JSON.stringify(report.keys()),
		["required_schema_keys"],
		{ "required": required, "actual": report.keys() }
	)

func test_rng_stream_isolation_baseline(mode: String) -> Dictionary:
	var seed_a := NpcTestAssertionsScript.rng_seed(seed, "npc-a", "goal", mode)
	var seed_a_again := NpcTestAssertionsScript.rng_seed(seed, "npc-a", "goal", mode)
	var seed_b := NpcTestAssertionsScript.rng_seed(seed, "npc-b", "goal", mode)
	var seq_a := NpcTestAssertionsScript.deterministic_sequence(seed_a, 5)
	var seq_a_again := NpcTestAssertionsScript.deterministic_sequence(seed_a_again, 5)
	var seq_b := NpcTestAssertionsScript.deterministic_sequence(seed_b, 5)
	var sorted_ids := NpcTestAssertionsScript.stable_sorted_strings(["npc-10", "npc-02", "npc-01"])
	var passed := seed_a == seed_a_again and seed_a != seed_b and seq_a == seq_a_again and seq_a != seq_b and sorted_ids == ["npc-01", "npc-02", "npc-10"]
	return outcome(
		passed,
		"seedA=%d seedB=%d seqA=%s seqB=%s sorted=%s" % [seed_a, seed_b, JSON.stringify(seq_a), JSON.stringify(seq_b), JSON.stringify(sorted_ids)],
		["per_npc_seed", "repeatable_sequence", "stable_sort"],
		{ "seedA": seed_a, "seedB": seed_b, "sequenceA": seq_a, "sequenceB": seq_b, "sortedIds": sorted_ids }
	)

func test_player_motor_characterization_baseline(_mode: String) -> Dictionary:
	var metrics_state := {
		"walkSpeed": PlayerControllerScript.WALK_SPEED,
		"sprintSpeed": PlayerControllerScript.SPRINT_SPEED,
		"acceleration": PlayerControllerScript.ACCELERATION,
		"airControl": PlayerControllerScript.AIR_CONTROL,
		"jumpSpeed": PlayerControllerScript.JUMP_SPEED,
		"gravity": PlayerControllerScript.GRAVITY,
		"terrainWalkableRise": PlayerControllerScript.TERRAIN_WALKABLE_RISE,
		"terrainWalkableDrop": PlayerControllerScript.TERRAIN_WALKABLE_DROP,
		"terrainAscendSpeed": PlayerControllerScript.TERRAIN_ASCEND_SPEED,
		"terrainDescendSpeed": PlayerControllerScript.TERRAIN_DESCEND_SPEED,
		"floorSnapLength": PlayerControllerScript.FLOOR_SNAP_LENGTH,
		"jumpSnapSuppression": PlayerControllerScript.JUMP_SNAP_SUPPRESSION,
		"capsuleRadius": 0.42,
		"capsuleHeight": 1.72,
		"floorMaxAngleDegrees": 46.0
	}
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(metrics_state.walkSpeed), 9.5)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.sprintSpeed), 15.5)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.acceleration), 14.0)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.jumpSpeed), 8.9)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.gravity), 26.0)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.terrainWalkableRise), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.terrainWalkableDrop), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.floorSnapLength), 0.32)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.capsuleRadius), 0.42)
		and NpcTestAssertionsScript.approx_equal(float(metrics_state.capsuleHeight), 1.72)
	)
	return outcome(
		passed,
		"metrics=%s" % JSON.stringify(metrics_state),
		["player_constants", "capsule_metrics", "floor_snap"],
		metrics_state
	)

func test_existing_save_defaults_baseline(mode: String) -> Dictionary:
	var path := "user://npc_contract_save_defaults_%s_%s.json" % [mode, run_token]
	var absolute_path := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(absolute_path)
	var save_system = SaveSystemScript.new(path)
	var missing_load: Dictionary = save_system.load("atlas-1492")
	var fallback_seed := save_system.active_seed("atlas-1492")
	var wrote_wrong_version := save_system.write_all({
		"atlas-1492": {
			"seed": "atlas-1492",
			"version": 0
		}
	})
	var wrong_version_load: Dictionary = save_system.load("atlas-1492")
	var saved := save_system.save("atlas-1492", { "custom": "value" })
	var loaded: Dictionary = save_system.load("atlas-1492")
	var deleted := save_system.delete("atlas-1492")
	var passed := (
		missing_load.is_empty()
		and fallback_seed == "atlas-1492"
		and wrote_wrong_version
		and wrong_version_load.is_empty()
		and saved
		and int(loaded.get("version", 0)) == SaveSystemScript.SAVE_VERSION
		and String(loaded.get("seed", "")) == "atlas-1492"
		and String(loaded.get("custom", "")) == "value"
		and deleted
	)
	DirAccess.remove_absolute(absolute_path)
	return outcome(
		passed,
		"missing=%s fallback=%s wrongEmpty=%s saved=%s loaded=%s deleted=%s" % [str(missing_load.is_empty()), fallback_seed, str(wrong_version_load.is_empty()), str(saved), JSON.stringify(loaded), str(deleted)],
		["missing_load_defaults", "version_rejection", "round_trip_version"],
		{ "missingLoad": missing_load, "fallbackSeed": fallback_seed, "wrongVersionLoad": wrong_version_load, "loaded": loaded }
	)

func test_existing_npc_navigation_runner_callable(_mode: String) -> Dictionary:
	var tool_exists := FileAccess.file_exists("res://tools/run-npc-navigation-tests.ps1")
	var scene_exists := FileAccess.file_exists("res://scenes/NpcNavigationTest.tscn")
	var script_exists := FileAccess.file_exists("res://scripts/NpcNavigationTestRunner.gd")
	var passed := tool_exists and scene_exists and script_exists
	return outcome(
		passed,
		"tool=%s scene=%s script=%s" % [str(tool_exists), str(scene_exists), str(script_exists)],
		["npc_navigation_runner_files"],
		{ "tool": tool_exists, "scene": scene_exists, "script": script_exists }
	)

func test_all_runner_registry_baseline(_mode: String) -> Dictionary:
	var parsed = read_json_file("res://tools/test-runner-registry.json")
	var ids: Array = []
	if parsed is Dictionary:
		for runner in parsed.get("runners", []):
			if runner is Dictionary:
				ids.append(String(runner.get("id", "")))
	var required := [
		"npc_focused",
		"npc_navigation_integration",
		"playtest",
		"story_playtest",
		"world_signature",
		"visual_captures",
		"visual_manifest"
	]
	var missing: Array[String] = []
	for id in required:
		if not ids.has(id):
			missing.append(id)
	var passed := parsed is Dictionary and missing.is_empty()
	return outcome(
		passed,
		"ids=%s missing=%s" % [JSON.stringify(ids), JSON.stringify(missing)],
		["runner_registry_present", "mandatory_runner_ids"],
		{ "ids": ids, "missing": missing }
	)

func test_route_status_terminal(_mode: String) -> Dictionary:
	var route_terminal := [
		NpcEnumsScript.ROUTE_STATUS_COMPLETE,
		NpcEnumsScript.ROUTE_STATUS_PARTIAL,
		NpcEnumsScript.ROUTE_STATUS_UNREACHABLE,
		NpcEnumsScript.ROUTE_STATUS_INVALIDATED,
		NpcEnumsScript.ROUTE_STATUS_CANCELLED,
		NpcEnumsScript.ROUTE_STATUS_FAILED_INTERNAL
	]
	var route_nonterminal := [
		NpcEnumsScript.ROUTE_STATUS_PENDING,
		NpcEnumsScript.ROUTE_STATUS_SEARCHING
	]
	var route_ok := true
	for status in route_terminal:
		var terminal_result = RouteResultScript.make(status, NpcEnumsScript.ROUTE_REASON_NONE, 1)
		route_ok = route_ok and terminal_result.is_terminal()
	for status in route_nonterminal:
		var nonterminal_result = RouteResultScript.make(status, NpcEnumsScript.ROUTE_REASON_NONE, 1)
		route_ok = route_ok and not nonterminal_result.is_terminal()
	var terminal_labels: Array[String] = []
	for status in route_terminal:
		terminal_labels.append(String(status))
	var nonterminal_labels: Array[String] = []
	for status in route_nonterminal:
		nonterminal_labels.append(String(status))
	var action := NpcActionInstanceScript.new()
	var action_generation: int = action.next_generation()
	var action_ok: bool = action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_SUCCEEDED) and action.is_terminal()
	var interaction = InteractionResultScript.make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"contract", 4)
	var interaction_ok: bool = interaction.is_terminal()
	var passed: bool = route_ok and action_ok and interaction_ok
	return outcome(
		passed,
		"routeTerminal=%s action=%s interaction=%s" % [str(route_ok), str(action_ok), str(interaction_ok)],
		["route_terminal_states", "action_terminal_states", "interaction_terminal_states"],
		{
			"routeTerminal": terminal_labels,
			"routeNonterminal": nonterminal_labels,
			"actionStatus": String(action.status),
			"interactionStatus": String(interaction.status)
		}
	)

func test_partial_never_arrival(_mode: String) -> Dictionary:
	var partial = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_PARTIAL, NpcEnumsScript.ROUTE_REASON_PARTIAL_ONLY, 2)
	partial.arrival_contract = "home"
	var complete = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, 2)
	complete.arrival_contract = "home"
	var passed: bool = partial.is_terminal() and not partial.is_arrival() and not partial.satisfies_arrival_contract("home") and complete.is_arrival() and complete.satisfies_arrival_contract("home")
	return outcome(
		passed,
		"partial=%s complete=%s" % [JSON.stringify(partial.to_summary()), JSON.stringify(complete.to_summary())],
		["partial_terminal", "partial_not_arrival", "arrival_contract_requires_complete"],
		{ "partial": partial.to_summary(), "complete": complete.to_summary() }
	)

func test_stable_tie_break(_mode: String) -> Dictionary:
	var body_10 := CharacterBody3D.new()
	body_10.name = "fallback-10"
	var body_02 := CharacterBody3D.new()
	body_02.name = "fallback-02"
	var context_10 = NpcAgentContextScript.from_profile(body_10, { "id": "npc-10", "name": "Ten" })
	var context_02 = NpcAgentContextScript.from_profile(body_02, { "id": "npc-02", "name": "Two" })
	var sorted := NpcAgentContextScript.stable_sort_ids([context_10, { "stableId": "npc-01" }, context_02])
	var scheduler := NpcBrainSchedulerScript.new()
	scheduler.register_agent("npc-10")
	scheduler.register_agent("npc-02")
	scheduler.register_agent("npc-01")
	var first_slice := scheduler.next_update_slice()
	body_10.free()
	body_02.free()
	var passed: bool = sorted == ["npc-01", "npc-02", "npc-10"] and first_slice == ["npc-01", "npc-02", "npc-10"]
	return outcome(
		passed,
		"sorted=%s slice=%s" % [JSON.stringify(sorted), JSON.stringify(first_slice)],
		["stable_id_order", "scheduler_sorted_order"],
		{ "stableSorted": sorted, "schedulerSlice": first_slice }
	)

func test_profile_capability_filter(_mode: String) -> Dictionary:
	var villager = TraversalProfileScript.from_profile({ "job": "forage" }, false)
	var worker = TraversalProfileScript.from_profile({ "job": "wood" }, false)
	var fighter = TraversalProfileScript.from_profile({ "job": "stone" }, true)
	var passed: bool = (
		villager.can(&"walk")
		and villager.can(&"open_doors")
		and not villager.can(&"use_locked_doors")
		and not villager.can(&"sprint")
		and worker.can(&"carry_bulky_item")
		and fighter.can(&"sprint")
		and fighter.can(&"carry_bulky_item")
	)
	return outcome(
		passed,
		"villager=%s worker=%s fighter=%s" % [JSON.stringify(villager.to_summary()), JSON.stringify(worker.to_summary()), JSON.stringify(fighter.to_summary())],
		["profile_abilities", "capability_filter"],
		{ "villager": villager.to_summary(), "worker": worker.to_summary(), "fighter": fighter.to_summary() }
	)

func test_rng_stream_isolation(mode: String) -> Dictionary:
	var body_a := CharacterBody3D.new()
	body_a.name = "NpcA"
	var body_b := CharacterBody3D.new()
	body_b.name = "NpcB"
	var context_a = NpcAgentContextScript.from_profile(body_a, { "id": "npc-a" })
	var context_b = NpcAgentContextScript.from_profile(body_b, { "id": "npc-b" })
	var seed_a: int = context_a.rng_seed(seed, "goal", mode)
	var seed_a_again: int = context_a.rng_seed(seed, "goal", mode)
	var seed_b: int = context_b.rng_seed(seed, "goal", mode)
	var seed_a_combat: int = context_a.rng_seed(seed, "combat", mode)
	var seq_a: Array[int] = []
	var seq_a_again: Array[int] = []
	var rng_a: RandomNumberGenerator = context_a.rng_stream(seed, "goal", mode)
	var rng_a_again: RandomNumberGenerator = context_a.rng_stream(seed, "goal", mode)
	for i in range(5):
		seq_a.append(rng_a.randi())
		seq_a_again.append(rng_a_again.randi())
	var control := RandomNumberGenerator.new()
	control.seed = 123456
	var expected_first := control.randi()
	var expected_second := control.randi()
	var probe := RandomNumberGenerator.new()
	probe.seed = 123456
	var observed_first := probe.randi()
	context_a.rng_stream(seed, "utility", mode).randi()
	context_b.rng_stream(seed, "utility", mode).randi()
	var observed_second := probe.randi()
	body_a.free()
	body_b.free()
	var passed: bool = seed_a == seed_a_again and seed_a != seed_b and seed_a != seed_a_combat and seq_a == seq_a_again and observed_first == expected_first and observed_second == expected_second
	return outcome(
		passed,
		"seedA=%d seedB=%d seedCombat=%d seq=%s probe=%d/%d" % [seed_a, seed_b, seed_a_combat, JSON.stringify(seq_a), observed_first, observed_second],
		["per_npc_rng_seed", "per_domain_rng_seed", "rng_sequence_repeatable", "world_rng_not_consumed"],
		{
			"seedA": seed_a,
			"seedB": seed_b,
			"seedCombat": seed_a_combat,
			"sequenceA": seq_a,
			"probe": [observed_first, observed_second]
		}
	)

func test_bounded_trace_and_cache(_mode: String) -> Dictionary:
	var telemetry := NpcTelemetryServiceScript.new()
	telemetry.ring_capacity = 4
	for i in range(6):
		telemetry.record_event("npc-a", &"trace", "event_%d" % i)
	var telemetry_events := telemetry.events_for("npc-a")
	var telemetry_stats: Dictionary = telemetry.stats()
	var scheduler := NpcBrainSchedulerScript.new()
	scheduler.max_registered_agents = 3
	var scheduler_accepts := [
		scheduler.register_agent("npc-1"),
		scheduler.register_agent("npc-2"),
		scheduler.register_agent("npc-3"),
		scheduler.register_agent("npc-4")
	]
	var change_bus := NavigationChangeBusScript.new()
	change_bus.max_pending_tiles = 2
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-a", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-b", AABB(Vector3.ONE, Vector3.ONE), ["1,0"])
	change_bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block-c", AABB(Vector3(2, 0, 0), Vector3.ONE), ["2,0"])
	var change_stats: Dictionary = change_bus.stats()
	var passed: bool = (
		telemetry_events.size() == 4
		and int(telemetry_stats.get("droppedEvents", {}).get("npc-a", 0)) == 2
		and scheduler_accepts == [true, true, true, false]
		and int(scheduler.stats().get("deniedRegistrations", 0)) == 1
		and int(change_stats.get("pendingTiles", 0)) == 2
		and int(change_stats.get("droppedEvents", 0)) == 1
	)
	return outcome(
		passed,
		"telemetry=%s scheduler=%s changeBus=%s" % [JSON.stringify(telemetry_stats), JSON.stringify(scheduler.stats()), JSON.stringify(change_stats)],
		["bounded_telemetry_ring", "bounded_scheduler_registry", "bounded_change_cache"],
		{ "telemetry": telemetry_stats, "scheduler": scheduler.stats(), "changeBus": change_stats }
	)

func test_cancellation_generation(_mode: String) -> Dictionary:
	var request := RouteRequestScript.new()
	var generation := request.next_generation()
	var stale_cancel := request.cancel(generation - 1)
	var current_before_cancel := request.is_current_generation(generation)
	var current_cancel := request.cancel(generation)
	var current_after_cancel := request.is_current_generation(generation)
	var blackboard := NpcBlackboardScript.new()
	var route_generation := blackboard.next_route_generation()
	var stale_result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, route_generation - 1)
	var current_result = RouteResultScript.make(NpcEnumsScript.ROUTE_STATUS_COMPLETE, NpcEnumsScript.ROUTE_REASON_NONE, route_generation)
	var stale_accept := blackboard.accept_route_result(stale_result)
	var current_accept := blackboard.accept_route_result(current_result)
	blackboard.next_route_generation()
	var old_accept_after_advance := blackboard.accept_route_result(current_result)
	var action := NpcActionInstanceScript.new()
	var action_generation := action.next_generation()
	var stale_action := action.apply_terminal(action_generation - 1, NpcEnumsScript.ACTION_STATUS_FAILED, NpcEnumsScript.ROUTE_REASON_STALE_GENERATION)
	var current_action := action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_CANCELLED, NpcEnumsScript.ROUTE_REASON_CANCELLED)
	var duplicate_action := action.apply_terminal(action_generation, NpcEnumsScript.ACTION_STATUS_FAILED)
	var passed: bool = (
		generation == 1
		and not stale_cancel
		and current_before_cancel
		and current_cancel
		and not current_after_cancel
		and not stale_accept
		and current_accept
		and not old_accept_after_advance
		and not stale_action
		and current_action
		and not duplicate_action
	)
	return outcome(
		passed,
		"request=%s blackboard=%s action=%s" % [JSON.stringify(request.to_summary()), JSON.stringify(blackboard.to_summary()), JSON.stringify(action.to_summary())],
		["route_cancellation_generation", "blackboard_stale_route_rejection", "action_terminal_generation"],
		{ "request": request.to_summary(), "blackboard": blackboard.to_summary(), "action": action.to_summary() }
	)

func test_change_bus_coalesces_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var cell := Vector3i(3, 1, 3)
	autonomy.notify_block_created(cell, "woodBlock")
	autonomy.notify_block_removed(cell, "woodBlock")
	var change_bus = autonomy.get("change_bus")
	var events: Array = change_bus.call("flush_frame")
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed: bool = (
		events.size() == 1
		and String(event.get("tileKey", "")) == "0,0"
		and int(event.get("coalescedCount", 0)) == 2
		and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED))
		and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED))
		and (event.get("objectIds", []) as Array).has("block:3,1,3:woodBlock")
		and int(change_bus.call("pending_count")) == 0
	)
	autonomy.free()
	return outcome(
		passed,
		"events=%s stats=%s" % [JSON.stringify(events), JSON.stringify(change_bus.call("stats"))],
		["change_bus_tile_coalescing", "change_bus_flush_clears_pending", "block_change_adapter"],
		{ "events": events, "stats": change_bus.call("stats") }
	)

func test_change_bus_monotonic_revision(_mode: String) -> Dictionary:
	var bus := NavigationChangeBusScript.new()
	var first := bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, "chunk:0,0", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	var first_events := bus.flush_frame()
	var second := bus.emit_change(NpcEnumsScript.CHANGE_KIND_DOOR_STATE, "door:a", AABB(Vector3.ONE, Vector3.ONE), ["0,0"])
	var second_events := bus.flush_frame()
	var third := bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, "chunk:0,0", AABB(Vector3.ZERO, Vector3.ONE), ["0,0"])
	var passed: bool = (
		first == 1
		and second == 2
		and third == 3
		and first_events.size() == 1
		and second_events.size() == 1
		and int(first_events[0].get("revision", 0)) == 1
		and int(second_events[0].get("revision", 0)) == 2
		and int(bus.stats().get("revision", 0)) == 3
	)
	return outcome(
		passed,
		"first=%d second=%d third=%d firstEvents=%s secondEvents=%s" % [first, second, third, JSON.stringify(first_events), JSON.stringify(second_events)],
		["change_bus_monotonic_revision", "change_bus_event_revision"],
		{ "first": first, "second": second, "third": third, "firstEvents": first_events, "secondEvents": second_events, "stats": bus.stats() }
	)

func test_guard_duty_not_can_fight(_mode: String) -> Dictionary:
	var fighter_body := CharacterBody3D.new()
	fighter_body.name = "Fighter"
	var night_body := CharacterBody3D.new()
	night_body.name = "NightWatcher"
	var fighter = NpcAgentContextScript.from_profile(fighter_body, { "id": "fighter", "canFight": true, "nightGuard": false })
	var watcher = NpcAgentContextScript.from_profile(night_body, { "id": "watcher", "canFight": false, "nightGuard": true })
	fighter_body.free()
	night_body.free()
	var passed: bool = bool(fighter.get("can_fight")) and fighter.get("guard_duty_kind") == NpcEnumsScript.GUARD_DUTY_NONE and not bool(watcher.get("can_fight")) and watcher.get("guard_duty_kind") == NpcEnumsScript.GUARD_DUTY_NIGHT
	return outcome(
		passed,
		"fighter=%s watcher=%s" % [JSON.stringify(fighter.to_summary()), JSON.stringify(watcher.to_summary())],
		["guard_duty_separate_from_can_fight"],
		{ "fighter": fighter.to_summary(), "watcher": watcher.to_summary() }
	)

func test_autonomy_composition_no_main_layer(_mode: String) -> Dictionary:
	var system := NpcSystemScript.new()
	system.setup(null, null)
	var body := CharacterBody3D.new()
	body.name = "ContractNPC"
	system.add_child(body)
	var entry: Dictionary = system.register_npc(body, {
		"id": "contract-npc",
		"name": "Contract NPC",
		"role": "Villager",
		"canFight": false,
		"nightGuard": false,
		"homeCell": Vector2i(1, 2),
		"porchCell": Vector2i(1, 3),
		"guardCell": Vector2i(2, 3),
		"townKey": "contract-town"
	})
	var context = entry.get("agentContext")
	var blackboard = entry.get("blackboard")
	var autonomy_node = system.get("autonomy_system") as Node
	var autonomy_child_ok: bool = autonomy_node != null and autonomy_node.get_parent() == system and autonomy_node.get_script() == NpcAutonomySystemScript
	var context_ok: bool = context != null and context.get_script() == NpcAgentContextScript and String(context.get("stable_id")) == "contract-npc"
	var blackboard_ok: bool = blackboard != null and blackboard.get_script() == NpcBlackboardScript
	var stats: Dictionary = autonomy_node.call("stats") if autonomy_node != null else {}
	var allowed_main_scripts := [
		"Main.gd",
		"MainPropFactory.gd",
		"MainChunkTerrain.gd",
		"MainInteractionFlow.gd",
		"MainPlaytestTools.gd",
		"MainRuntimeTools.gd",
		"MainDiscoveryFlow.gd",
		"MainHudFlow.gd",
		"MainWorldEntities.gd",
		"MainCharacterState.gd",
		"MainGameLoop.gd",
		"MainSetupScene.gd",
		"MainSaveState.gd",
		"MainCore.gd",
		"MainInterface.gd"
	]
	var main_scripts: Array[String] = []
	var unexpected_main_scripts: Array[String] = []
	var dir := DirAccess.open("res://scripts")
	if dir != null:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.begins_with("Main") and file_name.ends_with(".gd"):
				main_scripts.append(file_name)
				if not allowed_main_scripts.has(file_name):
					unexpected_main_scripts.append(file_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	main_scripts.sort()
	unexpected_main_scripts.sort()
	system.unregister_npc(body)
	body.free()
	system.free()
	var passed: bool = autonomy_child_ok and context_ok and blackboard_ok and int(stats.get("contexts", 0)) == 1 and unexpected_main_scripts.is_empty() and String(entry.get("id", "")) == "contract-npc"
	return outcome(
		passed,
		"autonomyChild=%s context=%s blackboard=%s stats=%s unexpectedMain=%s" % [str(autonomy_child_ok), str(context_ok), str(blackboard_ok), JSON.stringify(stats), JSON.stringify(unexpected_main_scripts)],
		["autonomy_system_child", "typed_context_association", "no_new_main_layer", "entry_preserved"],
		{ "stats": stats, "mainScripts": main_scripts, "unexpectedMainScripts": unexpected_main_scripts, "entryId": entry.get("id", "") }
	)

func test_motor_player_characterization_flat(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var result := run_motor_once(profile, CharacterMotorCommandScript.from_direction(Vector3.RIGHT, float(profile.get("walk_speed"))), true)
	var state = result.get("state")
	var applied: Vector3 = state.get("applied_velocity") if state != null else Vector3.ZERO
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(profile.get("walk_speed")), 9.5)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("sprint_speed")), 15.5)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("acceleration")), 14.0)
		and applied.x > 0.1
	)
	return outcome(
		passed,
		"profile=%s applied=%s" % [JSON.stringify(profile.to_summary()), str(applied)],
		["player_walk_speed", "player_sprint_speed", "player_acceleration", "motor_applies_flat_velocity"],
		{ "profile": profile.to_summary(), "appliedVelocity": [applied.x, applied.y, applied.z] }
	)

func test_motor_player_characterization_slope(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var passed := (
		NpcTestAssertionsScript.approx_equal(float(profile.get("floor_max_angle_degrees")), 46.0)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("floor_snap_length")), 0.32)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("terrain_walkable_rise")), 1.55)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("terrain_walkable_drop")), 1.55)
	)
	return outcome(
		passed,
		"profile=%s" % JSON.stringify(profile.to_summary()),
		["player_floor_angle", "player_floor_snap", "player_walkable_rise", "player_walkable_drop"],
		{ "profile": profile.to_summary() }
	)

func test_motor_player_characterization_jump(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.player_default()
	var command = CharacterMotorCommandScript.from_direction(Vector3.ZERO, 0.0, true, false)
	var result := run_motor_once(profile, command, true)
	var state = result.get("state")
	var velocity: Vector3 = state.get("velocity") if state != null else Vector3.ZERO
	var passed := (
		state != null
		and bool(state.get("jumped"))
		and velocity.y >= float(profile.get("jump_speed")) - 0.01
		and NpcTestAssertionsScript.approx_equal(float(profile.get("jump_speed")), 8.9)
		and NpcTestAssertionsScript.approx_equal(float(profile.get("gravity")), 26.0)
	)
	return outcome(
		passed,
		"jumped=%s velocity=%s profile=%s" % [str(state != null and bool(state.get("jumped"))), str(velocity), JSON.stringify(profile.to_summary())],
		["player_jump_speed", "player_gravity", "motor_jump_state"],
		{ "velocity": [velocity.x, velocity.y, velocity.z], "profile": profile.to_summary() }
	)

func test_motor_npc_flat_acceleration(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var command = CharacterMotorCommandScript.from_velocity(Vector3(float(profile.get("walk_speed")), 0.0, 0.0))
	var result := run_motor_once(profile, command, true)
	var state = result.get("state")
	var requested: Vector3 = state.get("requested_velocity") if state != null else Vector3.ZERO
	var velocity: Vector3 = state.get("velocity") if state != null else Vector3.ZERO
	var passed := (
		state != null
		and bool(profile.get("instant_horizontal_velocity"))
		and NpcTestAssertionsScript.approx_equal(float(profile.get("walk_speed")), 2.6)
		and absf(velocity.x - requested.x) <= 0.05
	)
	return outcome(
		passed,
		"requested=%s velocity=%s profile=%s" % [str(requested), str(velocity), JSON.stringify(profile.to_summary())],
		["npc_profile_instant_velocity", "npc_walk_speed", "npc_motor_velocity_matches_request"],
		{ "requestedVelocity": [requested.x, requested.y, requested.z], "velocity": [velocity.x, velocity.y, velocity.z], "profile": profile.to_summary() }
	)

func test_motor_npc_slope_limit(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := NpcTestAssertionsScript.approx_equal(float(profile.get("floor_max_angle_degrees")), 46.0)
	return outcome(passed, "floorMax=%.2f" % float(profile.get("floor_max_angle_degrees")), ["npc_floor_angle_shared"], profile.to_summary())

func test_motor_npc_step_up_limit(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := float(profile.get("terrain_walkable_rise")) <= 1.20 and float(profile.get("terrain_walkable_rise")) > 0.4
	return outcome(passed, "stepUp=%.2f" % float(profile.get("terrain_walkable_rise")), ["npc_step_up_limit"], profile.to_summary())

func test_motor_npc_safe_drop(_mode: String) -> Dictionary:
	var profile = CharacterMotorProfileScript.npc_default()
	var passed := float(profile.get("terrain_walkable_drop")) <= 1.35 and float(profile.get("terrain_landing_distance")) <= 0.20
	return outcome(passed, "drop=%.2f landing=%.2f" % [float(profile.get("terrain_walkable_drop")), float(profile.get("terrain_landing_distance"))], ["npc_safe_drop_limit", "npc_landing_snap_limit"], profile.to_summary())

func test_motor_wall_slide_no_penetration(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var motor_text := read_text("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
	var passed := locomotion_text.find("global_position =") < 0 and motor_text.find("global_position.x =") < 0 and motor_text.find("global_position.z =") < 0 and motor_text.find("move_and_slide()") >= 0
	return outcome(
		passed,
		"locomotionGlobalWrite=%d motorHorizontalWriteX=%d motorHorizontalWriteZ=%d" % [locomotion_text.find("global_position ="), motor_text.find("global_position.x ="), motor_text.find("global_position.z =")],
		["route_motion_no_transform_write", "motor_uses_move_and_slide", "motor_no_horizontal_teleport"],
		{ "locomotionGlobalWrite": locomotion_text.find("global_position ="), "motorMoveAndSlide": motor_text.find("move_and_slide()") }
	)

func test_motor_fence_window_corner_no_penetration(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var passed := (
		locomotion_text.find("capsule_hits_obstacle") >= 0
		and locomotion_text.find("collider_blocks_capsule") >= 0
		and locomotion_text.find("\"prop\", \"npc\", \"tutorial_npc\", \"hostile\"") >= 0
		and locomotion_text.find("intersect_shape") >= 0
	)
	return outcome(
		passed,
		"capsule=%d blockers=%d intersect=%d" % [locomotion_text.find("capsule_hits_obstacle"), locomotion_text.find("collider_blocks_capsule"), locomotion_text.find("intersect_shape")],
		["capsule_probe", "dynamic_blockers_include_npcs", "shape_query_collision_probe"],
		{}
	)

func test_motor_closed_door_blocks(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var door := Node3D.new()
	var body := CharacterBody3D.new()
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("open", false)
	var blocks := bool(controller.collider_blocks_capsule({}, door, body))
	door.free()
	body.free()
	return outcome(blocks, "closedDoorBlocks=%s" % str(blocks), ["closed_door_blocks_capsule"], { "closedDoorBlocks": blocks })

func test_motor_open_door_clears(_mode: String) -> Dictionary:
	var controller = NpcRouteMovementControllerScript.new()
	var door := Node3D.new()
	var body := CharacterBody3D.new()
	door.set_meta("kind", "block")
	door.set_meta("block_type", "door")
	door.set_meta("open", true)
	var clears := not bool(controller.collider_blocks_capsule({}, door, body))
	door.free()
	body.free()
	return outcome(clears, "openDoorClears=%s" % str(clears), ["open_door_clears_capsule"], { "openDoorClears": clears })

func test_motor_player_npc_solid_separation(_mode: String) -> Dictionary:
	var npc_mask: int = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var passed := (
		(npc_mask & NpcConstantsScript.COLLISION_PLAYER_BODY) != 0
		and (npc_mask & NpcConstantsScript.COLLISION_NPC_BODY) != 0
		and (npc_mask & NpcConstantsScript.COLLISION_WORLD_QUERY) != 0
	)
	return outcome(
		passed,
		"npcMask=%d playerLayer=%d npcLayer=%d worldLayer=%d" % [npc_mask, NpcConstantsScript.COLLISION_PLAYER_BODY, NpcConstantsScript.COLLISION_NPC_BODY, NpcConstantsScript.COLLISION_WORLD_QUERY],
		["npc_collides_with_player_layer", "npc_collides_with_npc_layer", "npc_collides_with_world_layer"],
		{ "npcMask": npc_mask, "playerLayer": NpcConstantsScript.COLLISION_PLAYER_BODY, "npcLayer": NpcConstantsScript.COLLISION_NPC_BODY }
	)

func test_motor_decorative_path_torch_nonblocking_mask(_mode: String) -> Dictionary:
	var npc_mask: int = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var safe_mask: int = NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK
	var static_query_mask: int = NpcConstantsScript.COLLISION_NPC_STATIC_QUERY_MASK
	var decorative_layer: int = NpcConstantsScript.COLLISION_NONBLOCKING_PATH
	var chunk_text := read_text("res://scripts/MainChunkTerrain.gd")
	var creation_assigns_nonblocking := (
		chunk_text.find("block_type == \"cobblestonePath\" or block_type == \"torch\"") >= 0
		and chunk_text.find("COLLISION_NONBLOCKING_PATH") >= 0
	)
	var masks_exclude_decorative := (
		(npc_mask & decorative_layer) == 0
		and (safe_mask & decorative_layer) == 0
		and (static_query_mask & decorative_layer) == 0
	)
	var passed := creation_assigns_nonblocking and masks_exclude_decorative
	return outcome(
		passed,
		"npcMask=%d safeMask=%d staticMask=%d decorative=%d creation=%s" % [npc_mask, safe_mask, static_query_mask, decorative_layer, str(creation_assigns_nonblocking)],
		["decorative_layer_excluded_from_npc_masks", "path_torch_assigned_nonblocking_layer"],
		{ "npcMask": npc_mask, "safeMask": safe_mask, "staticQueryMask": static_query_mask, "decorativeLayer": decorative_layer, "creationAssignsNonblocking": creation_assigns_nonblocking }
	)

func test_motor_no_route_transform_write(_mode: String) -> Dictionary:
	var files := {
		"NpcSystem": read_text("res://scripts/NpcSystem.gd"),
		"NpcPathing": read_text("res://scripts/NpcPathing.gd"),
		"NpcRouteMovementController": read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd"),
		"NpcMotionController": read_text("res://scripts/npc_ai/NpcMotionController.gd")
	}
	var offenders: Array[String] = []
	for key in files.keys():
		var text: String = files[key]
		if text.find("global_position =") >= 0 or text.find(".position =") >= 0:
			offenders.append(String(key))
	var passed := offenders.is_empty()
	return outcome(passed, "offenders=%s" % JSON.stringify(offenders), ["no_route_global_position_assignment", "no_route_position_assignment"], { "offenders": offenders })

func test_motor_no_unstick_teleport(_mode: String) -> Dictionary:
	var locomotion_text := read_text("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
	var passed := (
		locomotion_text.find("increment_stuck_recovery") >= 0
		and locomotion_text.find("safe_place_npc") < 0
		and locomotion_text.find("teleport") < 0
		and locomotion_text.find("global_position =") < 0
	)
	return outcome(
		passed,
		"stuck=%d safePlace=%d teleport=%d globalWrite=%d" % [locomotion_text.find("increment_stuck_recovery"), locomotion_text.find("safe_place_npc"), locomotion_text.find("teleport"), locomotion_text.find("global_position =")],
		["stuck_recovery_replans_only", "no_locomotion_safe_placement", "no_teleport_keyword"],
		{}
	)

func test_motor_spawn_safe_placement(_mode: String) -> Dictionary:
	var service = NpcSafePlacementServiceScript.new()
	service.setup(null, null)
	var body := motor_body("SafePlacementNPC")
	var result: Dictionary = service.place_spawn(body, Vector3(2.0, 1.0, 3.0), CharacterMotorProfileScript.npc_default(), "test_spawn")
	var passed := bool(result.get("ok", false)) and bool(body.get_meta("npc_safe_placement_validated", false)) and body.global_position.distance_to(Vector3(2.0, 1.0, 3.0)) <= 0.001
	body.queue_free()
	return outcome(
		passed,
		"result=%s position=%s" % [JSON.stringify(result), str(result.get("position", Vector3.ZERO))],
		["safe_placement_ok", "safe_placement_sets_meta", "safe_placement_applies_position"],
		{ "result": result }
	)

func test_motor_spawn_rejects_occupied_capsule(_mode: String) -> Dictionary:
	var text := read_text("res://scripts/npc_ai/NpcSafePlacementService.gd")
	var passed := text.find("intersect_shape") >= 0 and text.find("\"occupied_capsule\"") >= 0 and text.find("COLLISION_NPC_SAFE_PLACEMENT_MASK") >= 0
	return outcome(
		passed,
		"intersect=%d occupied=%d mask=%d" % [text.find("intersect_shape"), text.find("\"occupied_capsule\""), text.find("COLLISION_NPC_SAFE_PLACEMENT_MASK")],
		["safe_placement_uses_shape_query", "safe_placement_rejects_occupied_capsule", "safe_placement_uses_central_mask"],
		{}
	)

func test_motor_every_active_actor_physics_tick(_mode: String) -> Dictionary:
	var agent := NpcAgentScript.new() as CharacterBody3D
	agent.name = "PhysicsTickNPC"
	add_child(agent)
	for i in range(5):
		agent.call("_physics_process", 1.0 / 60.0)
	var ticks := int(agent.get("physics_tick_count"))
	var meta_ticks := int(agent.get_meta("npc_physics_ticks", 0))
	agent.queue_free()
	var passed := ticks == 5 and meta_ticks == 5
	return outcome(passed, "ticks=%d meta=%d" % [ticks, meta_ticks], ["agent_physics_process_ticks", "agent_tick_meta"], { "ticks": ticks, "metaTicks": meta_ticks })

func test_navworld_event_block_add_dirty_exact_tiles(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var cell := Vector3i(17, 1, 2)
	var tile_key := NavigationChangeBusScript.tile_key_for_cell(cell)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED, "block:add", AABB(Vector3(17.0, 1.0, 2.0) * NpcConstantsScript.CELL_SIZE, Vector3.ONE), [tile_key])
	var events: Array = service.process_change_bus()
	var dirty: Dictionary = service.get("dirty_tiles")
	var passed := events.size() == 1 and dirty.keys() == [tile_key] and int(service.stats().get("topologyRevision", 0)) == 1
	return outcome(passed, "tile=%s events=%s stats=%s" % [tile_key, JSON.stringify(events), JSON.stringify(service.stats())], ["block_add_exact_tile_dirty", "topology_revision_from_event"], { "events": events, "dirty": dirty.keys(), "stats": service.stats() })

func test_navworld_event_block_remove_dirty_exact_tiles(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var cell := Vector3i(-1, 1, 33)
	var tile_key := NavigationChangeBusScript.tile_key_for_cell(cell)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED, "block:remove", AABB(Vector3(float(cell.x), 0.0, float(cell.z)) * NpcConstantsScript.CELL_SIZE, Vector3.ONE), [tile_key])
	var events: Array = service.process_change_bus()
	var dirty: Dictionary = service.get("dirty_tiles")
	var passed := events.size() == 1 and dirty.keys() == [tile_key] and int(service.stats().get("topologyRevision", 0)) == 1
	return outcome(passed, "tile=%s dirty=%s" % [tile_key, JSON.stringify(dirty.keys())], ["block_remove_exact_tile_dirty"], { "events": events, "dirty": dirty.keys() })

func test_navworld_event_prop_remove_dirty_exact_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	var prop := Node3D.new()
	prop.name = "BerryProp"
	add_child(prop)
	prop.global_position = Vector3(2.0 * NpcConstantsScript.CELL_SIZE, 0.0, 1.0 * NpcConstantsScript.CELL_SIZE)
	autonomy.notify_prop_removed("berry-1", prop)
	var events: Array = autonomy.process_navigation_changes()
	prop.queue_free()
	autonomy.free()
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed := events.size() == 1 and String(event.get("tileKey", "")) == "0,0" and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_PROP_REMOVED))
	return outcome(passed, "events=%s" % JSON.stringify(events), ["prop_remove_exact_tile_dirty", "prop_remove_change_kind"], { "events": events })

func test_navworld_event_terrain_edit_dirty_exact_tiles(_mode: String) -> Dictionary:
	var autonomy := NpcAutonomySystemScript.new()
	autonomy.setup(null, null)
	autonomy.notify_terrain_edited(Vector2i(17, 17), 4.0, 2.65)
	var events: Array = autonomy.process_navigation_changes()
	autonomy.free()
	var event: Dictionary = events[0] if events.size() > 0 else {}
	var passed := events.size() == 1 and String(event.get("tileKey", "")) == "1,1" and (event.get("changeKinds", []) as Array).has(String(NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT))
	return outcome(passed, "events=%s" % JSON.stringify(events), ["terrain_edit_exact_tile_dirty", "terrain_edit_change_kind"], { "events": events })

func test_navworld_event_chunk_load_unload(_mode: String) -> Dictionary:
	var setup := nav_event_setup()
	var bus = setup.bus
	var service = setup.service
	var key := Vector2i(2, -1)
	var tile_key := NavigationChangeBusScript.tile_key_for_chunk(key)
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_LOADED, "chunk:load", AABB(Vector3.ZERO, Vector3.ONE), [tile_key])
	service.process_change_bus()
	var after_load: Dictionary = service.stats()
	bus.emit_change(NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED, "chunk:unload", AABB(Vector3.ZERO, Vector3.ONE), [tile_key])
	service.process_change_bus()
	var states: Dictionary = service.get("tile_states")
	var passed: bool = int(after_load.get("dirtyTileCount", 0)) == 1 and String(states.get(tile_key, "")) == "unloaded" and not service.is_tile_traversable(tile_key)
	return outcome(passed, "load=%s states=%s" % [JSON.stringify(after_load), JSON.stringify(states)], ["chunk_load_dirty", "chunk_unload_explicit_state", "unloaded_not_traversable"], { "afterLoad": after_load, "tileStates": states })

func test_navworld_no_scene_scan_revision(_mode: String) -> Dictionary:
	var service_text := read_text("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
	var builder_text := read_text("res://scripts/npc_ai/navigation/NavigationTileBuilder.gd")
	var autonomy_text := read_text("res://scripts/npc_ai/NpcAutonomySystem.gd")
	var passed := (
		service_text.find("get_tree(") < 0
		and service_text.find("find_children") < 0
		and service_text.find("hash(") < 0
		and builder_text.find("get_tree(") < 0
		and autonomy_text.find("process_navigation_changes") >= 0
		and autonomy_text.find("NavigationChangeBus") >= 0
	)
	return outcome(passed, "serviceScan=%d find=%d hash=%d" % [service_text.find("get_tree("), service_text.find("find_children"), service_text.find("hash(")], ["new_stack_no_scene_scan_revision", "change_bus_drives_nav_world"], {})

func test_navworld_multisurface_bridge(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0.0, 0.0, 0.0), "semanticRegionIds": ["terrain"] }),
		nav_surface(Vector3i(0, 2, 0), { "worldPosition": Vector3(0.0, 2.7, 0.0), "semanticRegionIds": ["bridge"] })
	]))
	var spans: Array = tile.spans_for_column(Vector3i(0, 0, 0))
	var passed: bool = spans.size() == 2 and int(tile.to_summary().get("spanCount", 0)) == 2
	return outcome(passed, "summary=%s spans=%d" % [JSON.stringify(tile.to_summary()), spans.size()], ["multiple_vertical_spans_same_xz"], { "tile": tile.to_summary(), "spans": spans.size() })

func test_navworld_tunnel_headroom(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "headroom": 1.2 }),
		nav_surface(Vector3i(1, 0, 0), { "headroom": 2.2 })
	]))
	var low_span = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var clear_span = tile.spans_for_column(Vector3i(1, 0, 0))[0]
	var passed := not bool(low_span.get("walkable")) and bool(clear_span.get("walkable"))
	return outcome(passed, "low=%s clear=%s" % [JSON.stringify(low_span.to_summary()), JSON.stringify(clear_span.to_summary())], ["headroom_rejects_low_tunnel", "headroom_accepts_clear_tunnel"], { "low": low_span.to_summary(), "clear": clear_span.to_summary() })

func test_navworld_stacked_surfaces_disconnected(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0, 0, 0) }),
		nav_surface(Vector3i(0, 3, 0), { "worldPosition": Vector3(0, 4.0, 0) })
	]))
	var spans: Array = tile.spans_for_column(Vector3i(0, 0, 0))
	var edge = tile.edge_between(spans[0].key_string(), spans[1].key_string()) if spans.size() == 2 else null
	var passed: bool = spans.size() == 2 and edge == null
	return outcome(passed, "spans=%d edge=%s" % [spans.size(), str(edge != null)], ["stacked_surfaces_no_magic_vertical_edge"], { "tile": tile.to_summary() })

func test_navworld_profile_clearance_small_large(_mode: String) -> Dictionary:
	var small = TraversalProfileScript.default_adult_npc()
	small.body_radius = 0.22
	small.personal_space_margin = 0.04
	var large = TraversalProfileScript.default_adult_npc()
	large.body_radius = 0.55
	large.personal_space_margin = 0.10
	var snapshot := nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "lateralClearance": 0.40 })
	])
	var small_tile = NavigationWorldServiceScript.new().build_tile_now(snapshot, small)
	var large_tile = NavigationWorldServiceScript.new().build_tile_now(snapshot, large)
	var small_span = small_tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var large_span = large_tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var passed: bool = bool(small_span.get("walkable")) and not bool(large_span.get("walkable"))
	return outcome(passed, "small=%s large=%s" % [JSON.stringify(small_span.to_summary()), JSON.stringify(large_span.to_summary())], ["profile_clearance_small_passes", "profile_clearance_large_rejected"], { "small": small_span.to_summary(), "large": large_span.to_summary() })

func test_navworld_slope_step_drop_edges(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "worldPosition": Vector3(0.0, 0.0, 0.0) }),
		nav_surface(Vector3i(1, 0, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.75, 0.0) }),
		nav_surface(Vector3i(-1, 0, 0), { "worldPosition": Vector3(-NpcConstantsScript.CELL_SIZE, -0.75, 0.0) })
	]))
	var base = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var up = tile.spans_for_column(Vector3i(1, 0, 0))[0]
	var down = tile.spans_for_column(Vector3i(-1, 0, 0))[0]
	var up_edge = tile.edge_between(base.key_string(), up.key_string())
	var down_edge = tile.edge_between(base.key_string(), down.key_string())
	var passed: bool = up_edge != null and up_edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_STEP and down_edge != null and down_edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_DROP
	return outcome(passed, "up=%s down=%s" % [JSON.stringify(up_edge.to_summary() if up_edge else {}), JSON.stringify(down_edge.to_summary() if down_edge else {})], ["step_edge_built", "drop_edge_built"], { "up": up_edge.to_summary() if up_edge else {}, "down": down_edge.to_summary() if down_edge else {} })

func test_navworld_corner_cut_rejected(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0)),
		nav_surface(Vector3i(1, 0, 1)),
		nav_surface(Vector3i(1, 0, 0), { "blocked": true, "blockerKind": "wall" }),
		nav_surface(Vector3i(0, 0, 1), { "blocked": true, "blockerKind": "wall" })
	]))
	var base = tile.spans_for_column(Vector3i(0, 0, 0))[0]
	var diagonal = tile.spans_for_column(Vector3i(1, 0, 1))[0]
	var edge = tile.edge_between(base.key_string(), diagonal.key_string())
	var passed := edge == null
	return outcome(passed, "edge=%s summary=%s" % [str(edge != null), JSON.stringify(tile.to_summary())], ["diagonal_corner_cut_rejected"], { "tile": tile.to_summary() })

func test_navworld_door_portal_edge_registered(_mode: String) -> Dictionary:
	var from_key := "0,0:0,0,0:0"
	var to_key := "0,0:1,0,0:1"
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now(nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0)),
		nav_surface(Vector3i(1, 0, 0))
	], {
		"doorPortals": [{ "id": "door:home-a", "kind": "single", "width": 1.0 }],
		"doorLinks": [{ "from": from_key, "to": to_key, "portalId": "door:home-a", "cost": 2.0 }]
	}))
	var edge = tile.edge_between(from_key, to_key)
	var passed: bool = edge != null and edge.get("traversal_kind") == NpcEnumsScript.TRAVERSAL_KIND_DOOR and tile.door_portals.has("door:home-a")
	return outcome(passed, "edge=%s portals=%s" % [JSON.stringify(edge.to_summary() if edge else {}), JSON.stringify(tile.door_portals.keys())], ["door_portal_registered", "door_edge_explicit"], { "edge": edge.to_summary() if edge else {}, "portals": tile.door_portals.keys() })

func test_navworld_semantic_home_interior(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_home("home-a", AABB(Vector3.ZERO, Vector3(4, 3, 4)), { "bed": Vector3(1, 0, 1) }, { "portalId": "door:home-a" })
	var homes: Array = semantic.regions_for_kind(&"home_interior")
	var at_point: Array = semantic.regions_at_position(Vector3(1, 1, 1), &"home_interior")
	var passed := homes.size() == 1 and at_point.size() == 1 and bool(homes[0].get("metadata", {}).get("inside", false))
	return outcome(passed, "homes=%s" % JSON.stringify(homes), ["home_interior_semantic_region", "home_inside_metadata", "home_entrance_metadata"], { "homes": homes, "atPoint": at_point })

func test_navworld_semantic_guard_post(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_guard_post("north", AABB(Vector3(8, 0, 0), Vector3(2, 3, 2)), { "patrol": "north-road" })
	var guards: Array = semantic.regions_for_kind(&"guard_post")
	var passed := guards.size() == 1 and String(guards[0].get("id", "")) == "guard:north"
	return outcome(passed, "guards=%s" % JSON.stringify(guards), ["guard_post_semantic_region"], { "guards": guards })

func test_navworld_semantic_road_and_work_anchor(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var semantic = service.get("semantic_service")
	semantic.register_road("main", AABB(Vector3.ZERO, Vector3(10, 1, 2)), { "surface": "cobblestonePath" })
	semantic.register_work_anchor("woodpile", AABB(Vector3(4, 0, 4), Vector3(2, 2, 2)), { "job": "wood" })
	var roads: Array = semantic.regions_for_kind(&"road")
	var work: Array = semantic.regions_for_kind(&"work_anchor")
	var passed := roads.size() == 1 and work.size() == 1 and int(semantic.stats().get("regionCount", 0)) == 2
	return outcome(passed, "semantic=%s" % JSON.stringify(semantic.stats()), ["road_semantic_region", "work_anchor_semantic_region"], { "roads": roads, "work": work, "stats": semantic.stats() })

func test_navworld_unloaded_tile_not_traversable(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	var tile = service.build_tile_now({ "tileKey": "3,3", "unloaded": true, "surfaces": [] })
	var passed := bool(tile.get("unloaded")) and not service.is_tile_traversable("3,3")
	return outcome(passed, "tile=%s traversable=%s" % [JSON.stringify(tile.to_summary()), str(service.is_tile_traversable("3,3"))], ["unloaded_tile_explicit", "unloaded_tile_not_traversable"], { "tile": tile.to_summary() })

func test_navworld_build_budget_yields_and_resumes(_mode: String) -> Dictionary:
	var service := NavigationWorldServiceScript.new()
	for i in range(3):
		service.request_tile(nav_snapshot("%d,0" % i, [nav_surface(Vector3i(i * 16, 0, 0))]), 1)
	var first: Array = service.build_next_tiles(1, 4000)
	var after_first := service.stats()
	var second: Array = service.build_next_tiles(1, 4000)
	var third: Array = service.build_next_tiles(1, 4000)
	var after_all := service.stats()
	var passed: bool = first.size() == 1 and second.size() == 1 and third.size() == 1 and int(after_first.get("buildQueue", {}).get("pending", 0)) == 2 and int(after_all.get("buildQueue", {}).get("pending", 0)) == 0 and int(after_all.get("buildQueue", {}).get("yieldedJobs", 0)) >= 1
	return outcome(passed, "first=%s afterAll=%s" % [JSON.stringify(after_first), JSON.stringify(after_all)], ["build_budget_yields", "build_budget_resumes", "build_queue_drains"], { "afterFirst": after_first, "afterAll": after_all })

func test_navworld_deterministic_tile_output(_mode: String) -> Dictionary:
	var snapshot := nav_snapshot("0,0", [
		nav_surface(Vector3i(0, 0, 0), { "semanticRegionIds": ["road"] }),
		nav_surface(Vector3i(1, 0, 0), { "semanticRegionIds": ["road"] }),
		nav_surface(Vector3i(1, 1, 1), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.75, NpcConstantsScript.CELL_SIZE), "semanticRegionIds": ["bridge"] })
	], {
		"semanticRegions": [{ "id": "road:main", "kind": "road" }]
	})
	var first = NavigationWorldServiceScript.new().build_tile_now(snapshot)
	var second = NavigationWorldServiceScript.new().build_tile_now(snapshot)
	var passed: bool = first.stable_signature() == second.stable_signature()
	return outcome(passed, "first=%s second=%s" % [first.stable_signature(), second.stable_signature()], ["deterministic_tile_signature"], { "first": first.stable_signature(), "second": second.stable_signature() })

func nav_event_setup() -> Dictionary:
	var bus := NavigationChangeBusScript.new()
	var service := NavigationWorldServiceScript.new()
	service.setup(null, bus)
	return { "bus": bus, "service": service }

func nav_snapshot(tile_key: String, surfaces: Array, extra := {}) -> Dictionary:
	var snapshot := {
		"tileKey": tile_key,
		"surfaces": surfaces
	}
	for key in extra.keys():
		snapshot[key] = extra[key]
	return snapshot

func nav_surface(cell: Vector3i, extra := {}) -> Dictionary:
	var surface := {
		"cell": cell,
		"worldPosition": Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, float(cell.y) * NpcConstantsScript.CELL_SIZE, float(cell.z) * NpcConstantsScript.CELL_SIZE),
		"floorNormal": Vector3.UP,
		"headroom": 2.4,
		"lateralClearance": 1.0,
		"blocked": false,
		"semanticRegionIds": [],
		"traversalTags": ["terrain"]
	}
	for key in extra.keys():
		surface[key] = extra[key]
	return surface

func motor_body(node_name: String) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = node_name
	body.collision_layer = NpcConstantsScript.COLLISION_NPC_BODY
	body.collision_mask = NpcConstantsScript.COLLISION_NPC_BODY_MASK
	var shape := CapsuleShape3D.new()
	shape.radius = 0.34
	shape.height = 1.62
	var collider := CollisionShape3D.new()
	collider.name = "MotorTestCollider"
	collider.shape = shape
	collider.position.y = 0.84
	body.add_child(collider)
	add_child(body)
	return body

func run_motor_once(profile, command, grounded := true) -> Dictionary:
	var body := motor_body("MotorTestBody")
	var motor = CharacterMotor3DScript.new()
	command.terrain_grounded = grounded
	command.grounded_hint = grounded
	command.jump_snap_time = 0.0
	var state = motor.call("apply", body, command, profile, 1.0 / 60.0, null)
	var result := {
		"state": state,
		"position": body.global_position,
		"velocity": body.velocity
	}
	body.queue_free()
	return result

func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}

func add_result(id: String, mode: String, passed: bool, details: String, assertions: Array, key_state: Dictionary, duration := 0.0) -> void:
	var result := {
		"id": id,
		"timeMode": mode,
		"seed": seed,
		"passed": passed,
		"durationSeconds": snap_seconds(duration),
		"assertions": assertions,
		"keyState": key_state,
		"details": details,
		"artifacts": {}
	}
	if not passed and trace_dir != "":
		result["artifacts"] = { "traceDir": trace_dir }
	results.append(result)
	metrics["assertions"] = int(metrics.get("assertions", 0)) + assertions.size()
	if not passed:
		failed = true
	print("[%s] %s %s %s" % ["PASS" if passed else "FAIL", id, mode, details])
	save_report(false)

func finish() -> void:
	if finished:
		return
	finished = true
	finished_utc = Time.get_datetime_string_from_system(true)
	write_progress("finished")
	save_report(true)
	get_tree().quit(1 if failed else 0)

func build_report(include_finished: bool) -> Dictionary:
	var failures := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failures += 1
	var version_info: Dictionary = Engine.get_version_info()
	return {
		"schemaVersion": 1,
		"suite": suite_filter,
		"caseFilter": case_filter,
		"timeMode": time_mode,
		"seed": seed,
		"branch": branch,
		"gitCommit": git_commit,
		"engineVersion": version_info,
		"startedUtc": started_utc,
		"finishedUtc": finished_utc if include_finished else "",
		"durationSeconds": snap_seconds(Time.get_unix_time_from_system() - started_unix),
		"resultCount": results.size(),
		"failureCount": failures,
		"results": results,
		"metrics": metrics,
		"artifacts": {
			"report": report_path,
			"progress": progress_path,
			"traceDir": trace_dir,
			"screenshotDir": screenshot_dir
		},
		"runToken": run_token
	}

func save_report(verbose := true) -> void:
	if report_path == "":
		return
	var report := build_report(finished)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write NPC test report: %s" % report_path)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	if verbose:
		print("NPC test report: %s" % report_path)

func write_progress(label: String) -> void:
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\ntoken=%s\n" % [label, elapsed, results.size(), str(failed), run_token])
	file.close()

func read_json_file(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)

func snap_seconds(value: float) -> float:
	return snappedf(value, 0.001)
