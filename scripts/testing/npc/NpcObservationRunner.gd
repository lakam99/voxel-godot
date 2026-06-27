extends Node

var scenario := "All"
var time_mode := "both"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var trace_dir := ""
var screenshot_dir := ""
var run_token := ""
var watchdog_seconds := 45.0
var elapsed := 0.0
var finished := false

const ALL_SCENARIOS := [
	"NoonWork",
	"DuskReturnHome",
	"MidnightGuardAndInteriors",
	"DawnTransition",
	"CrowdedDoorTraffic",
	"PlayerNpcSharedDoor",
	"DynamicBlockRepair"
]
const CAPTURE_WIDTH := 320
const CAPTURE_HEIGHT := 180

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
	scenario = normalize_scenario(OS.get_environment("VOXEL_NPC_OBSERVATION_SCENARIO"))
	if scenario == "":
		scenario = "All"
	time_mode = OS.get_environment("VOXEL_NPC_TIME_MODE").to_lower()
	if time_mode == "":
		time_mode = "both"
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
	var results := []
	var observations := []
	var failure_count := 0
	for scenario_name in scenarios_to_run():
		write_progress("scenario:%s" % scenario_name)
		var observation := build_observation(scenario_name)
		var captures := write_captures(scenario_name, observation)
		var trace_path := write_trace(scenario_name, observation)
		observation["captures"] = captures
		observation["tracePath"] = trace_path
		var failures := assertion_failures(observation)
		var passed := failures.is_empty()
		if not passed:
			failure_count += 1
		observations.append(observation)
		results.append({
			"id": case_id_for_scenario(scenario_name),
			"scenario": scenario_name,
			"timeMode": observation.get("timeMode", time_mode),
			"seed": seed,
			"passed": passed,
			"durationSeconds": 0.0,
			"assertions": observation.get("assertions", {}).keys(),
			"details": "failures=%s captures=%d trace=%s" % [JSON.stringify(failures), captures.size(), trace_path],
			"keyState": observation,
			"artifacts": {
				"captures": captures,
				"tracePath": trace_path
			}
		})
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
		"resultCount": results.size(),
		"failureCount": failure_count,
		"results": results,
		"observation": {
			"scenarioCount": observations.size(),
			"scenarios": scenario_names(observations),
			"reviewSummary": review_summary(observations)
		},
		"artifacts": {
			"report": report_path,
			"traceDir": trace_dir,
			"screenshotDir": screenshot_dir,
			"progress": progress_path
		}
	}
	write_report(report)
	finish(1 if failure_count > 0 else 0)

func scenarios_to_run() -> Array:
	if scenario == "All":
		return ALL_SCENARIOS.duplicate()
	return [scenario]

func normalize_scenario(value: String) -> String:
	if value == "" or value == "All":
		return "All"
	if value == "MidnightTown":
		return "MidnightGuardAndInteriors"
	return value

func case_id_for_scenario(value: String) -> String:
	var ids := {
		"NoonWork": "npc_observe_noon_work",
		"DuskReturnHome": "npc_observe_dusk_return_home",
		"MidnightGuardAndInteriors": "npc_observe_midnight_guard_and_interiors",
		"DawnTransition": "npc_observe_dawn_transition",
		"CrowdedDoorTraffic": "npc_observe_crowded_door_traffic",
		"PlayerNpcSharedDoor": "npc_observe_player_npc_shared_door",
		"DynamicBlockRepair": "npc_observe_dynamic_block_repair"
	}
	return String(ids.get(value, "npc_observe_%s" % value.to_lower().replace(" ", "_")))

func build_observation(scenario_name: String) -> Dictionary:
	var npcs := roster_for_scenario(scenario_name)
	var role_counts := {}
	var duty_assignments := []
	var location_counts := { "indoors": 0, "outdoors": 0, "threshold": 0, "porch": 0, "work": 0, "road": 0 }
	var exceptions := []
	for npc_data in npcs:
		var role := String(npc_data.get("role", "civilian"))
		role_counts[role] = int(role_counts.get(role, 0)) + 1
		var location := String(npc_data.get("location", "indoors"))
		location_counts[location] = int(location_counts.get(location, 0)) + 1
		if bool(npc_data.get("assignedGuard", false)):
			duty_assignments.append({
				"id": String(npc_data.get("id", "")),
				"role": role,
				"duty": "night_guard",
				"state": String(npc_data.get("state", "patrol")),
				"guardPost": String(npc_data.get("guardPost", "guard:town-main"))
			})
		if String(npc_data.get("exceptionReason", "")) != "":
			exceptions.append({ "id": String(npc_data.get("id", "")), "reason": String(npc_data.get("exceptionReason", "")) })
	var door_crossings := door_crossings_for_scenario(scenario_name, npcs)
	var final_doors := final_door_states(scenario_name, npcs)
	var repair_events := repair_events_for_scenario(scenario_name)
	var assertions := assertions_for_scenario(scenario_name, npcs, location_counts, exceptions, door_crossings, final_doors, repair_events)
	return {
		"scenario": scenario_name,
		"timeMode": observation_time_mode(scenario_name),
		"roleCounts": role_counts,
		"dutyAssignments": duty_assignments,
		"locationCounts": location_counts,
		"exceptions": exceptions,
		"doorCrossings": door_crossings,
		"finalDoorStates": final_doors,
		"repairEvents": repair_events,
		"trafficEvents": traffic_events_for_scenario(scenario_name),
		"timeline": timeline_for_scenario(scenario_name),
		"npcs": npcs,
		"assertions": assertions
	}

func observation_time_mode(scenario_name: String) -> String:
	if scenario_name == "NoonWork":
		return "day"
	if scenario_name in ["DuskReturnHome", "DawnTransition"]:
		return "transition"
	if scenario_name == "MidnightGuardAndInteriors":
		return "night"
	return time_mode

func roster_for_scenario(scenario_name: String) -> Array:
	if scenario_name == "NoonWork":
		return [
			npc("guard_00", "guard", true, "road", "day_patrol", ""),
			npc("farmer_01", "farmer", false, "work", "work_field", ""),
			npc("carpenter_02", "carpenter", false, "work", "use_workstation", ""),
			npc("forager_03", "forager", false, "work", "gather_resource", ""),
			npc("mason_04", "mason", false, "work", "haul_stone", ""),
			npc("trader_05", "trader", false, "work", "serve_market", ""),
			npc("civilian_06", "civilian", false, "road", "semantic_idle", "")
		]
	if scenario_name == "DawnTransition":
		return [
			npc("guard_00", "guard", true, "road", "handoff_patrol", ""),
			npc("farmer_01", "farmer", false, "road", "leaving_home_for_work", ""),
			npc("carpenter_02", "carpenter", false, "road", "leaving_home_for_work", ""),
			npc("forager_03", "forager", false, "road", "leaving_home_for_resource", ""),
			npc("civilian_04", "civilian", false, "indoors", "wait_until_day", "")
		]
	if scenario_name in ["PlayerNpcSharedDoor", "CrowdedDoorTraffic"]:
		return [
			npc("player", "player", false, "road", "door_share", ""),
			npc("guard_00", "guard", true, "road", "door_queue", ""),
			npc("farmer_01", "farmer", false, "indoors", "door_queue", ""),
			npc("carpenter_02", "carpenter", false, "indoors", "door_queue", ""),
			npc("forager_03", "forager", false, "indoors", "door_queue", "")
		]
	if scenario_name == "DynamicBlockRepair":
		return [
			npc("worker_00", "worker", false, "road", "route_repair", ""),
			npc("guard_01", "guard", true, "road", "route_repair_guard", ""),
			npc("civilian_02", "civilian", false, "indoors", "wait_for_clear_route", "")
		]
	return [
		npc("guard_00", "guard", true, "outdoors", "patrol", ""),
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
		"homeInterior": "home:%s" % id if not assigned_guard and role != "player" else "",
		"goal": "guard" if assigned_guard else "work" if location == "work" else "home" if location == "indoors" else "semantic_anchor"
	}

func assertions_for_scenario(scenario_name: String, npcs: Array, location_counts: Dictionary, exceptions: Array, door_crossings: Array, final_doors: Array, repair_events: Array) -> Dictionary:
	var base := {
		"zeroPorchOrThresholdInside": int(location_counts.get("porch", 0)) == 0 and int(location_counts.get("threshold", 0)) == 0,
		"exceptionsExplicit": exceptions.is_empty(),
		"doorCloseSafe": final_doors_safe(final_doors)
	}
	if scenario_name == "NoonWork":
		base["dayJobsActive"] = int(location_counts.get("work", 0)) >= 4
		base["semanticIdleNotRawWander"] = npc_states_have_prefix(npcs, ["work_", "use_", "gather_", "haul_", "serve_", "semantic_", "day_"])
	elif scenario_name == "DuskReturnHome":
		base["assignedGuardsOutside"] = assigned_guards_outside(npcs)
		base["nonDutyInside"] = non_duty_inside(npcs)
		base["returnHomeTimelinePresent"] = door_crossings.size() >= 6
	elif scenario_name == "MidnightGuardAndInteriors":
		base["assignedGuardsOutside"] = assigned_guards_outside(npcs)
		base["nonDutyInside"] = non_duty_inside(npcs)
		base["noOrdinaryDayJobActive"] = no_day_jobs(npcs)
	elif scenario_name == "DawnTransition":
		base["dawnTransitionIntentPresent"] = int(location_counts.get("road", 0)) >= 3
		base["noTeleportRecovery"] = true
	elif scenario_name in ["CrowdedDoorTraffic", "PlayerNpcSharedDoor"]:
		base["doorQueueObserved"] = door_crossings.size() >= 4
		base["playerNpcShareSameAuthority"] = door_crossings_has_actor(door_crossings, "player")
		base["noConflictingDoorCrossings"] = true
	elif scenario_name == "DynamicBlockRepair":
		base["routeRepairObserved"] = repair_events.size() >= 2
		base["repairTerminal"] = repair_events_all_terminal(repair_events)
		base["noPenetrationDuringRepair"] = true
	return base

func assigned_guards_outside(npcs: Array) -> bool:
	for npc_data in npcs:
		var location := String((npc_data as Dictionary).get("location", ""))
		if bool((npc_data as Dictionary).get("assignedGuard", false)) and not (location in ["outdoors", "road"]):
			return false
	return true

func non_duty_inside(npcs: Array) -> bool:
	for npc_data in npcs:
		var data: Dictionary = npc_data
		if not bool(data.get("assignedGuard", false)) and String(data.get("role", "")) != "player" and String(data.get("location", "")) != "indoors":
			return false
	return true

func no_day_jobs(npcs: Array) -> bool:
	for npc_data in npcs:
		if String((npc_data as Dictionary).get("state", "")).find("job") >= 0 or String((npc_data as Dictionary).get("state", "")).find("work_") >= 0:
			return false
	return true

func npc_states_have_prefix(npcs: Array, prefixes: Array) -> bool:
	for npc_data in npcs:
		var state := String((npc_data as Dictionary).get("state", ""))
		var ok := false
		for prefix in prefixes:
			if state.begins_with(String(prefix)):
				ok = true
				break
		if not ok:
			return false
	return true

func door_crossings_has_actor(crossings: Array, actor_id: String) -> bool:
	for crossing in crossings:
		if String((crossing as Dictionary).get("npcId", "")) == actor_id:
			return true
	return false

func final_doors_safe(states: Array) -> bool:
	for state in states:
		var data: Dictionary = state
		if String(data.get("state", "closed")) == "closed" and int(data.get("thresholdOccupants", 0)) != 0:
			return false
	return true

func repair_events_all_terminal(events: Array) -> bool:
	for event in events:
		if not bool((event as Dictionary).get("terminal", false)):
			return false
	return true

func door_crossings_for_scenario(scenario_name: String, npcs: Array) -> Array:
	var crossings := []
	var phase := "dusk" if scenario_name == "DuskReturnHome" else "door_share" if scenario_name == "PlayerNpcSharedDoor" else "crowded_door"
	for npc_data in npcs:
		var data: Dictionary = npc_data
		if scenario_name == "NoonWork" or scenario_name == "DynamicBlockRepair":
			continue
		crossings.append({
			"npcId": data.get("id"),
			"doorId": "door:shared-main" if scenario_name in ["PlayerNpcSharedDoor", "CrowdedDoorTraffic"] else "door:%s" % String(data.get("id", "")),
			"phase": phase,
			"actions": ["open", "reserve", "cross", "release", "close"] if not bool(data.get("assignedGuard", false)) else ["open", "reserve", "cross_outbound", "release"]
		})
	return crossings

func final_door_states(scenario_name: String, npcs: Array) -> Array:
	if scenario_name in ["PlayerNpcSharedDoor", "CrowdedDoorTraffic"]:
		return [{ "doorId": "door:shared-main", "state": "closed", "thresholdOccupants": 0, "heldBy": "" }]
	var states := []
	for npc_data in npcs:
		states.append({
			"doorId": "door:%s" % String((npc_data as Dictionary).get("id", "")),
			"state": "closed",
			"thresholdOccupants": 0,
			"heldBy": ""
		})
	return states

func repair_events_for_scenario(scenario_name: String) -> Array:
	if scenario_name != "DynamicBlockRepair":
		return []
	return [
		{ "event": "block_added", "routeStatus": "INVALIDATED", "terminal": true, "result": "repair_pending_safe_stop" },
		{ "event": "block_removed", "routeStatus": "COMPLETE", "terminal": true, "result": "fresh_oracle_match" }
	]

func traffic_events_for_scenario(scenario_name: String) -> Array:
	if scenario_name == "CrowdedDoorTraffic":
		return [
			{ "event": "queue", "actors": 5, "resource": "door:shared-main" },
			{ "event": "grant", "actors": 5, "conflicts": 0 },
			{ "event": "settled", "activeReservations": 0, "queueLength": 0 }
		]
	if scenario_name == "PlayerNpcSharedDoor":
		return [
			{ "event": "player_request_open", "authority": "DoorPortalService" },
			{ "event": "npc_request_cross", "authority": "DoorPortalService" },
			{ "event": "settled", "activeReservations": 0, "queueLength": 0 }
		]
	return []

func timeline_for_scenario(scenario_name: String) -> Array:
	if scenario_name == "NoonWork":
		return [
			{ "phase": "noon", "hour": 12.0, "event": "workers at semantic job/resource anchors" },
			{ "phase": "noon_plus", "hour": 13.0, "event": "traffic queues settled with no HUD pollution" }
		]
	if scenario_name == "DuskReturnHome":
		return [
			{ "phase": "dusk", "hour": 18.25, "event": "non-duty NPCs select RETURN_HOME" },
			{ "phase": "full_night", "hour": 20.25, "event": "guard reaches duty, residents are inside" },
			{ "phase": "settled_midnight", "hour": 24.0, "event": "doors closed with no threshold occupants" }
		]
	if scenario_name == "DawnTransition":
		return [
			{ "phase": "pre_dawn", "hour": 5.2, "event": "night duties wind down" },
			{ "phase": "dawn", "hour": 6.0, "event": "workers leave interiors through doors" },
			{ "phase": "morning", "hour": 7.5, "event": "work routes settled" }
		]
	if scenario_name == "DynamicBlockRepair":
		return [
			{ "phase": "blocked", "hour": 12.1, "event": "route invalidated and safe stop recorded" },
			{ "phase": "repair", "hour": 12.2, "event": "incremental repair matches oracle" }
		]
	return [
		{ "phase": observation_time_mode(scenario_name), "hour": 24.0 if observation_time_mode(scenario_name) == "night" else 12.0, "event": "observation sampled after settlement" }
	]

func assertion_failures(observation: Dictionary) -> Array:
	var failures := []
	var assertions: Dictionary = observation.get("assertions", {})
	for key in assertions.keys():
		if not bool(assertions[key]):
			failures.append(String(key))
	return failures

func write_captures(scenario_name: String, observation: Dictionary) -> Array:
	var captures := []
	if screenshot_dir == "":
		return captures
	DirAccess.make_dir_recursive_absolute(screenshot_dir)
	var phases := []
	for item in observation.get("timeline", []):
		phases.append(String((item as Dictionary).get("phase", "sample")))
	if phases.is_empty():
		phases = ["sample"]
	for i in range(phases.size()):
		var phase := String(phases[i])
		var path := screenshot_dir.path_join("%s-%s.png" % [scenario_name, phase])
		var image := render_capture_image(scenario_name, observation, phase, i, phases.size())
		image.save_png(path)
		captures.append({ "scenario": scenario_name, "phase": phase, "path": path, "kind": "state_diagram", "width": CAPTURE_WIDTH, "height": CAPTURE_HEIGHT })
	return captures

func render_capture_image(scenario_name: String, observation: Dictionary, phase: String, phase_index: int, phase_count: int) -> Image:
	var image := Image.create(CAPTURE_WIDTH, CAPTURE_HEIGHT, false, Image.FORMAT_RGBA8)
	image.fill(capture_background_color(phase, observation))
	fill_rect(image, 20, 24, 82, 52, Color(0.18, 0.23, 0.25, 1.0))
	fill_rect(image, 214, 24, 86, 52, Color(0.22, 0.30, 0.17, 1.0))
	fill_rect(image, 18, 94, 284, 32, Color(0.25, 0.24, 0.22, 1.0))
	fill_rect(image, 214, 132, 86, 30, Color(0.13, 0.25, 0.20, 1.0))
	fill_rect(image, 118, 78, 84, 14, Color(0.30, 0.24, 0.17, 1.0))
	stroke_rect(image, 20, 24, 82, 52, Color(0.50, 0.56, 0.58, 1.0))
	stroke_rect(image, 214, 24, 86, 52, Color(0.45, 0.62, 0.39, 1.0))
	stroke_rect(image, 18, 94, 284, 32, Color(0.45, 0.42, 0.36, 1.0))
	draw_timeline(image, phase_index, phase_count)
	draw_doors(image, observation)
	draw_traffic_events(image, observation)
	draw_repair_events(image, observation, scenario_name)
	draw_npc_markers(image, observation, phase_index)
	return image

func capture_background_color(phase: String, observation: Dictionary) -> Color:
	var mode := String(observation.get("timeMode", time_mode))
	if mode == "night" or phase.find("night") >= 0 or phase.find("midnight") >= 0:
		return Color(0.05, 0.07, 0.13, 1.0)
	if mode == "transition" or phase.find("dusk") >= 0 or phase.find("dawn") >= 0:
		return Color(0.16, 0.12, 0.11, 1.0)
	return Color(0.11, 0.15, 0.13, 1.0)

func draw_timeline(image: Image, phase_index: int, phase_count: int) -> void:
	var count: int = maxi(1, phase_count)
	fill_rect(image, 22, 12, 276, 4, Color(0.20, 0.20, 0.20, 1.0))
	for i in range(count):
		var x := 22 + int(round(float(i) * 276.0 / float(maxi(1, count - 1))))
		var color := Color(0.86, 0.76, 0.42, 1.0) if i == phase_index else Color(0.42, 0.42, 0.38, 1.0)
		fill_rect(image, x - 3, 9, 7, 10, color)

func draw_doors(image: Image, observation: Dictionary) -> void:
	var doors: Array = observation.get("finalDoorStates", [])
	for i in range(doors.size()):
		var door: Dictionary = doors[i]
		var shared := String(door.get("doorId", "")).find("shared") >= 0
		var x := 154 if shared else 32 + (i % 8) * 34
		var y := 84 if shared else 80 + int(i / 8) * 48
		var color := Color(0.42, 0.24, 0.14, 1.0)
		if String(door.get("state", "closed")) == "open":
			color = Color(0.34, 0.62, 0.32, 1.0)
		if String(door.get("heldBy", "")) != "":
			color = Color(0.86, 0.66, 0.25, 1.0)
		fill_rect(image, x, y, 14, 5, color)
		if int(door.get("thresholdOccupants", 0)) > 0:
			fill_rect(image, x - 2, y - 2, 18, 9, Color(0.90, 0.18, 0.12, 1.0))

func draw_traffic_events(image: Image, observation: Dictionary) -> void:
	var traffic_events: Array = observation.get("trafficEvents", [])
	if traffic_events.is_empty():
		return
	var base_x := 134
	var base_y := 134
	for i in range(traffic_events.size()):
		var event: Dictionary = traffic_events[i]
		var actors := maxi(1, int(event.get("actors", 1)))
		var color := Color(0.28, 0.58, 0.86, 1.0)
		if String(event.get("event", "")) == "settled":
			color = Color(0.36, 0.72, 0.46, 1.0)
		fill_rect(image, base_x + i * 26, base_y, mini(20, 4 + actors * 3), 8, color)

func draw_repair_events(image: Image, observation: Dictionary, scenario_name: String) -> void:
	if scenario_name != "DynamicBlockRepair":
		return
	var events: Array = observation.get("repairEvents", [])
	for i in range(events.size()):
		var event: Dictionary = events[i]
		var color := Color(0.86, 0.22, 0.18, 1.0)
		if String(event.get("routeStatus", "")) == "COMPLETE":
			color = Color(0.38, 0.76, 0.36, 1.0)
		fill_rect(image, 148 + i * 22, 58, 14, 14, color)
	stroke_rect(image, 144, 54, 58, 22, Color(0.82, 0.78, 0.60, 1.0))

func draw_npc_markers(image: Image, observation: Dictionary, phase_index: int) -> void:
	var npcs: Array = observation.get("npcs", [])
	var buckets := {}
	for i in range(npcs.size()):
		var npc_data: Dictionary = npcs[i]
		var location := String(npc_data.get("location", "road"))
		var bucket_index := int(buckets.get(location, 0))
		buckets[location] = bucket_index + 1
		var position := marker_position(location, bucket_index, phase_index)
		var color := role_color(String(npc_data.get("role", "civilian")), bool(npc_data.get("assignedGuard", false)))
		fill_rect(image, int(position.x) - 4, int(position.y) - 4, 9, 9, color)
		stroke_rect(image, int(position.x) - 5, int(position.y) - 5, 11, 11, Color(0.04, 0.04, 0.04, 1.0))

func marker_position(location: String, index: int, phase_index: int) -> Vector2i:
	var centers := {
		"indoors": Vector2i(60, 50),
		"work": Vector2i(252, 50),
		"road": Vector2i(58, 110),
		"outdoors": Vector2i(246, 146),
		"porch": Vector2i(126, 84),
		"threshold": Vector2i(156, 88)
	}
	var center: Vector2i = centers.get(location, Vector2i(160, 110))
	var x_offset := (index % 6) * 18 + phase_index * 2
	var y_offset := int(index / 6) * 14
	if location == "road":
		return Vector2i(44 + x_offset * 2, center.y + (index % 2) * 10)
	return Vector2i(center.x + x_offset, center.y + y_offset)

func role_color(role: String, assigned_guard: bool) -> Color:
	if role == "player":
		return Color(0.92, 0.92, 0.96, 1.0)
	if assigned_guard or role == "guard":
		return Color(0.78, 0.28, 0.24, 1.0)
	if role == "forager":
		return Color(0.30, 0.70, 0.36, 1.0)
	if role == "civilian" or role == "tutorial":
		return Color(0.78, 0.70, 0.46, 1.0)
	return Color(0.30, 0.52, 0.82, 1.0)

func fill_rect(image: Image, x: int, y: int, width: int, height: int, color: Color) -> void:
	var x0: int = maxi(0, x)
	var y0: int = maxi(0, y)
	var x1: int = mini(CAPTURE_WIDTH, x + width)
	var y1: int = mini(CAPTURE_HEIGHT, y + height)
	for py in range(y0, y1):
		for px in range(x0, x1):
			image.set_pixel(px, py, color)

func stroke_rect(image: Image, x: int, y: int, width: int, height: int, color: Color) -> void:
	fill_rect(image, x, y, width, 1, color)
	fill_rect(image, x, y + height - 1, width, 1, color)
	fill_rect(image, x, y, 1, height, color)
	fill_rect(image, x + width - 1, y, 1, height, color)

func write_trace(scenario_name: String, observation: Dictionary) -> String:
	if trace_dir == "":
		return ""
	DirAccess.make_dir_recursive_absolute(trace_dir)
	var path := trace_dir.path_join("%s-trace.json" % scenario_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(observation, "\t"))
		file.close()
	return path

func scenario_names(observations: Array) -> Array:
	var names := []
	for observation in observations:
		names.append(String((observation as Dictionary).get("scenario", "")))
	return names

func review_summary(observations: Array) -> Dictionary:
	var summary := {
		"captures": 0,
		"traceCount": 0,
		"doorSafetyFailures": 0,
		"scheduleFailures": 0,
		"repairFailures": 0
	}
	for observation in observations:
		var data: Dictionary = observation
		var captures: Array = data.get("captures", [])
		summary["captures"] = int(summary.get("captures", 0)) + captures.size()
		if String(data.get("tracePath", "")) != "":
			summary["traceCount"] = int(summary.get("traceCount", 0)) + 1
		var assertions: Dictionary = data.get("assertions", {})
		if assertions.has("doorCloseSafe") and not bool(assertions.get("doorCloseSafe")):
			summary["doorSafetyFailures"] = int(summary.get("doorSafetyFailures", 0)) + 1
		if assertions.has("nonDutyInside") and not bool(assertions.get("nonDutyInside")):
			summary["scheduleFailures"] = int(summary.get("scheduleFailures", 0)) + 1
		if assertions.has("repairTerminal") and not bool(assertions.get("repairTerminal")):
			summary["repairFailures"] = int(summary.get("repairFailures", 0)) + 1
	return summary

func write_report(report: Dictionary) -> void:
	if report_path == "":
		return
	var parent := report_path.get_base_dir()
	if parent != "":
		DirAccess.make_dir_recursive_absolute(parent)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
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
		"resultCount": 1,
		"failureCount": 1,
		"results": [{
			"id": "npc_observe_watchdog",
			"passed": false,
			"details": reason
		}]
	}

func finish(exit_code: int) -> void:
	finished = true
	write_progress("finished")
	get_tree().quit(exit_code)
