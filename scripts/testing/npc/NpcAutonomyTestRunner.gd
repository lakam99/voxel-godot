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
	return [
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
		["legacy_focused_runner_files"],
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
		"npc_navigation_legacy",
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
	var body_10 := StaticBody3D.new()
	body_10.name = "fallback-10"
	var body_02 := StaticBody3D.new()
	body_02.name = "fallback-02"
	var context_10 = NpcAgentContextScript.from_legacy_profile(body_10, { "id": "npc-10", "name": "Ten" })
	var context_02 = NpcAgentContextScript.from_legacy_profile(body_02, { "id": "npc-02", "name": "Two" })
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
	var villager = TraversalProfileScript.from_legacy_profile({ "job": "forage" }, false)
	var worker = TraversalProfileScript.from_legacy_profile({ "job": "wood" }, false)
	var fighter = TraversalProfileScript.from_legacy_profile({ "job": "stone" }, true)
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
	var body_a := StaticBody3D.new()
	body_a.name = "NpcA"
	var body_b := StaticBody3D.new()
	body_b.name = "NpcB"
	var context_a = NpcAgentContextScript.from_legacy_profile(body_a, { "id": "npc-a" })
	var context_b = NpcAgentContextScript.from_legacy_profile(body_b, { "id": "npc-b" })
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
	var fighter_body := StaticBody3D.new()
	fighter_body.name = "Fighter"
	var night_body := StaticBody3D.new()
	night_body.name = "NightWatcher"
	var fighter = NpcAgentContextScript.from_legacy_profile(fighter_body, { "id": "fighter", "canFight": true, "nightGuard": false })
	var watcher = NpcAgentContextScript.from_legacy_profile(night_body, { "id": "watcher", "canFight": false, "nightGuard": true })
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
	var body := StaticBody3D.new()
	body.name = "ContractNPC"
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
		["autonomy_system_child", "typed_context_association", "no_new_main_layer", "legacy_entry_preserved"],
		{ "stats": stats, "mainScripts": main_scripts, "unexpectedMainScripts": unexpected_main_scripts, "entryId": entry.get("id", "") }
	)

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
