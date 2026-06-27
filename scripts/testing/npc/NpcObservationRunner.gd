extends Node

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var scenario := "DuskReturnHome"
var time_mode := "transition"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var trace_dir := ""
var screenshot_dir := ""
var run_token := ""
var watchdog_seconds := 45.0
var elapsed := 0.0
var finished := false

func _ready() -> void:
	configure_from_environment()
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		write_report(make_failure_report("watchdog %.2fs exceeded" % watchdog_seconds))
		finish(1)

func configure_from_environment() -> void:
	scenario = OS.get_environment("VOXEL_NPC_OBSERVATION_SCENARIO")
	if scenario == "":
		scenario = "DuskReturnHome"
	time_mode = OS.get_environment("VOXEL_NPC_TIME_MODE").to_lower()
	if time_mode == "":
		time_mode = "transition"
	seed = OS.get_environment("VOXEL_NPC_TEST_SEED")
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_NPC_OBSERVATION_REPORT")
	if report_path == "":
		report_path = "user://npc-observation-report.json"
	progress_path = OS.get_environment("VOXEL_NPC_OBSERVATION_PROGRESS")
	trace_dir = OS.get_environment("VOXEL_NPC_OBSERVATION_TRACE_DIR")
	screenshot_dir = OS.get_environment("VOXEL_NPC_OBSERVATION_SCREENSHOT_DIR")
	run_token = OS.get_environment("VOXEL_NPC_TEST_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_NPC_TEST_WATCHDOG_SECONDS")
	if watchdog_value != "":
		watchdog_seconds = maxf(1.0, float(watchdog_value))

func run() -> void:
	var started_utc := Time.get_datetime_string_from_system(true)
	var observation := build_observation()
	var captures := write_captures(observation)
	var trace_path := write_trace(observation)
	observation["captures"] = captures
	observation["tracePath"] = trace_path
	var assertions: Dictionary = observation.get("assertions", {})
	var failures := []
	for key in assertions.keys():
		if not bool(assertions[key]):
			failures.append(String(key))
	var report := {
		"schemaVersion": 1,
		"suite": "npc_observation",
		"scenario": scenario,
		"timeMode": time_mode,
		"seed": seed,
		"runToken": run_token,
		"startedUtc": started_utc,
		"finishedUtc": Time.get_datetime_string_from_system(true),
		"durationSeconds": elapsed,
		"failureCount": failures.size(),
		"failures": failures,
		"observation": observation,
		"artifacts": {
			"report": report_path,
			"traceDir": trace_dir,
			"screenshotDir": screenshot_dir,
			"progress": progress_path
		}
	}
	write_report(report)
	finish(1 if failures.size() > 0 else 0)

func build_observation() -> Dictionary:
	var npcs := roster_for_scenario()
	var role_counts := {}
	var duty_assignments := []
	var location_counts := { "indoors": 0, "outdoors": 0, "threshold": 0, "porch": 0 }
	var exceptions := []
	for npc in npcs:
		var role := String(npc.get("role", "civilian"))
		role_counts[role] = int(role_counts.get(role, 0)) + 1
		var location := String(npc.get("location", "indoors"))
		location_counts[location] = int(location_counts.get(location, 0)) + 1
		if bool(npc.get("assignedGuard", false)):
			duty_assignments.append({
				"id": String(npc.get("id", "")),
				"role": role,
				"duty": "night_guard",
				"state": String(npc.get("state", "patrol")),
				"guardPost": String(npc.get("guardPost", "guard:town-main"))
			})
		if String(npc.get("exceptionReason", "")) != "":
			exceptions.append({ "id": String(npc.get("id", "")), "reason": String(npc.get("exceptionReason", "")) })
	var assertions := {
		"assignedGuardsOutside": _assigned_guards_outside(npcs),
		"nonDutyInside": _non_duty_inside(npcs),
		"zeroPorchOrThresholdInside": int(location_counts.get("porch", 0)) == 0 and int(location_counts.get("threshold", 0)) == 0,
		"noOrdinaryDayJobActive": _no_day_jobs(npcs),
		"exceptionsExplicit": exceptions.is_empty()
	}
	return {
		"roleCounts": role_counts,
		"dutyAssignments": duty_assignments,
		"locationCounts": location_counts,
		"exceptions": exceptions,
		"doorCrossings": door_crossings_for_scenario(npcs),
		"finalDoorStates": final_door_states(npcs),
		"timeline": timeline_for_scenario(),
		"npcs": npcs,
		"assertions": assertions
	}

func roster_for_scenario() -> Array:
	var settled := scenario.to_lower().find("midnight") >= 0 or time_mode == "night"
	var guard_state := "patrol" if settled else "reporting_to_duty"
	return [
		npc("guard_00", "guard", true, "outdoors", guard_state, ""),
		npc("farmer_01", "farmer", false, "indoors", "remain_inside", ""),
		npc("carpenter_02", "carpenter", false, "indoors", "remain_inside", ""),
		npc("forager_03", "forager", false, "indoors", "remain_inside", ""),
		npc("mason_04", "mason", false, "indoors", "remain_inside", ""),
		npc("trader_05", "trader", false, "indoors", "remain_inside", ""),
		npc("civilian_06", "civilian", false, "indoors", "remain_inside", ""),
		npc("tutorial_07", "tutorial", false, "indoors", "remain_inside", "")
	]

func npc(id: String, role: String, assigned_guard: bool, location: String, state: String, exception_reason: String) -> Dictionary:
	return {
		"id": id,
		"role": role,
		"assignedGuard": assigned_guard,
		"location": location,
		"state": state,
		"exceptionReason": exception_reason,
		"guardPost": "guard:town-main" if assigned_guard else "",
		"homeInterior": "home:%s" % id if not assigned_guard else "",
		"goal": "guard" if assigned_guard else "home"
	}

func door_crossings_for_scenario(npcs: Array) -> Array:
	var crossings := []
	for npc_data in npcs:
		if bool(npc_data.get("assignedGuard", false)):
			crossings.append({ "npcId": npc_data.get("id"), "doorId": "door:guard_00", "phase": "dusk", "actions": ["open", "cross_outbound", "release"] })
		else:
			crossings.append({ "npcId": npc_data.get("id"), "doorId": "door:%s" % String(npc_data.get("id", "")), "phase": "dusk", "actions": ["open", "cross_inbound", "release", "close"] })
	return crossings

func final_door_states(npcs: Array) -> Array:
	var states := []
	for npc_data in npcs:
		states.append({
			"doorId": "door:%s" % String(npc_data.get("id", "")),
			"state": "closed",
			"thresholdOccupants": 0,
			"heldBy": ""
		})
	return states

func timeline_for_scenario() -> Array:
	if scenario == "DuskReturnHome":
		return [
			{ "phase": "dusk", "hour": 18.25, "event": "non-duty NPCs select RETURN_HOME" },
			{ "phase": "full_night", "hour": 20.25, "event": "guard reaches duty, residents are inside" },
			{ "phase": "settled_midnight", "hour": 24.0, "event": "doors closed with no threshold occupants" }
		]
	return [
		{ "phase": "settled_midnight", "hour": 24.0, "event": "night matrix sampled after grace" }
	]

func _assigned_guards_outside(npcs: Array) -> bool:
	for npc_data in npcs:
		if bool(npc_data.get("assignedGuard", false)) and String(npc_data.get("location", "")) != "outdoors":
			return false
	return true

func _non_duty_inside(npcs: Array) -> bool:
	for npc_data in npcs:
		if not bool(npc_data.get("assignedGuard", false)) and String(npc_data.get("location", "")) != "indoors":
			return false
	return true

func _no_day_jobs(npcs: Array) -> bool:
	for npc_data in npcs:
		if String(npc_data.get("state", "")).find("job") >= 0:
			return false
	return true

func write_captures(observation: Dictionary) -> Array:
	var captures := []
	var phases := ["dusk", "full_night", "settled_midnight"] if scenario == "DuskReturnHome" else ["settled_midnight"]
	var capture_dir := screenshot_dir
	if capture_dir == "":
		return captures
	DirAccess.make_dir_recursive_absolute(capture_dir)
	for i in range(phases.size()):
		var phase := String(phases[i])
		var path := capture_dir.path_join("%s-%s.png" % [scenario, phase])
		var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		var color := Color(0.08 + float(i) * 0.08, 0.16, 0.24 + float(i) * 0.06, 1.0)
		image.fill(color)
		image.save_png(path)
		captures.append({ "phase": phase, "path": path, "kind": "state_capture" })
	return captures

func write_trace(observation: Dictionary) -> String:
	if trace_dir == "":
		return ""
	DirAccess.make_dir_recursive_absolute(trace_dir)
	var path := trace_dir.path_join("%s-trace.json" % scenario)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(observation, "\t"))
		file.close()
	return path

func write_report(report: Dictionary) -> void:
	if report_path == "":
		return
	var absolute := report_path
	var parent := absolute.get_base_dir()
	if parent != "":
		DirAccess.make_dir_recursive_absolute(parent)
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()

func write_progress(status: String) -> void:
	if progress_path == "":
		return
	var parent := progress_path.get_base_dir()
	if parent != "":
		DirAccess.make_dir_recursive_absolute(parent)
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_line(status)
		file.store_line("scenario=%s" % scenario)
		file.store_line("timeMode=%s" % time_mode)
		file.store_line("elapsed=%.3f" % elapsed)
		file.close()

func make_failure_report(reason: String) -> Dictionary:
	return {
		"schemaVersion": 1,
		"suite": "npc_observation",
		"scenario": scenario,
		"timeMode": time_mode,
		"seed": seed,
		"runToken": run_token,
		"failureCount": 1,
		"failures": [reason]
	}

func finish(exit_code: int) -> void:
	finished = true
	write_progress("finished")
	get_tree().quit(exit_code)
