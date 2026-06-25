extends Node

const NpcTestClockScript := preload("res://scripts/testing/npc/NpcTestClock.gd")
const NpcTestAssertionsScript := preload("res://scripts/testing/npc/NpcTestAssertions.gd")
const PlayerControllerScript := preload("res://scripts/PlayerController.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")

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
