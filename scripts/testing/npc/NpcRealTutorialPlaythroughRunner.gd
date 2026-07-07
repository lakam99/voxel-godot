extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "npc_tutorial_real_knock_repair_sleep_morning_foragers"
const CELL := 1.35
const STARTUP_FRAMES := 80
const POST_ACTION_FRAMES := 24
const SAMPLE_EVERY_FRAMES := 6
const MIRA_HOME_TIMEOUT_SECONDS := 36.0
const MIRA_HOME_SETTLED_FRAMES := 30
const MIRA_STARTER_WALL_STUCK_FRAMES := 240
const MORNING_FORAGE_TIMEOUT_SECONDS := 70.0
const MORNING_OUTSIDE_TIMEOUT_SECONDS := 60.0
const MORNING_OUTSIDE_TARGETS := ["rowan", "mira", "niko"]
const FOLLOWING_MORNING_TIME := 0.04
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const TUTORIAL_REPAIR_RADIUS_CELLS := 25
const FINAL_RESCUE_TIMEOUT_SECONDS := 190.0
const FINAL_RESCUE_MONSTER_COUNT := 6
const FINAL_RESCUE_RETURN_STALL_SAMPLES := 80

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var observer_camera: Camera3D
var observer_torch: OmniLight3D
var elapsed := 0.0
var finished := false
var failed := false
var report_data := {}
var results: Array[Dictionary] = []
var failure_reasons: Array[Dictionary] = []
var player_timeline: Array[Dictionary] = []
var door_timeline: Array[Dictionary] = []
var mira_timeline: Array[Dictionary] = []
var mira_speed_samples: Array[Dictionary] = []
var route_order_timeline: Array[Dictionary] = []
var schedule_matrix: Array[Dictionary] = []
var night_matrix: Dictionary = {}
var repair_placement_events: Array[Dictionary] = []
var sleep_timeline: Array[Dictionary] = []
var inventory_timeline: Array[Dictionary] = []
var interaction_timeline: Array[Dictionary] = []
var morning_observation_timeline: Array[Dictionary] = []
var day_one_timeline: Array[Dictionary] = []
var final_rescue_timeline: Array[Dictionary] = []
var final_rescue_normal_behavior_timeline: Array[Dictionary] = []
var final_rescue_speed_proofs: Array[Dictionary] = []
var resource_gather_events: Array[Dictionary] = []
var final_rescue_combat_events: Array[Dictionary] = []
var non_guard_home_visual_matrix: Array[Dictionary] = []
var morning_outside_visual_matrix: Array[Dictionary] = []
var morning_departure_matrix: Array[Dictionary] = []
var niko_timeline: Array[Dictionary] = []
var visual_captures: Array[Dictionary] = []
var niko_proof := {}
var max_mira_flat_speed := 0.0
var mira_total_flat_distance := 0.0
var previous_mira_position := Vector3.ZERO
var previous_mira_valid := false
var previous_mira_elapsed := 0.0
var physics_dt := 1.0 / 60.0
var gameplay_started := false
var screenshot_dir := ""
var visual_required := false
var mira_home_only := false
var morning_outside_only := false
var day_one_tutorial := false
var final_rescue_tutorial := false
var playtest_god_mode := false
var captured_mira_start := false
var captured_mira_route_departure := false
var captured_mira_route_midpoint := false
var captured_mira_at_door := false
var captured_mira_door_open := false
var captured_mira_inside_closed := false
var mira_route_start_position := Vector3.ZERO
var mira_route_start_valid := false
var mira_starter_route_regression := {}
var last_observer_camera_target := Vector3.ZERO

func _ready() -> void:
    physics_dt = 1.0 / float(Engine.physics_ticks_per_second)
    configure_visual_capture()
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    var limit := watchdog_seconds()
    if elapsed > limit:
        add_failure("runner_watchdog", "runner exceeded %.1f seconds" % limit)
        finish()

func configure_visual_capture() -> void:
    visual_required = OS.get_environment("VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED").strip_edges() == "1"
    mira_home_only = OS.get_environment("VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY").strip_edges() == "1"
    morning_outside_only = OS.get_environment("VOXEL_REAL_TUTORIAL_MORNING_OUTSIDE_ONLY").strip_edges() == "1"
    final_rescue_tutorial = OS.get_environment("VOXEL_REAL_TUTORIAL_FINAL_RESCUE").strip_edges() == "1"
    playtest_god_mode = OS.get_environment("VOXEL_REAL_TUTORIAL_GOD_MODE").strip_edges() == "1"
    day_one_tutorial = OS.get_environment("VOXEL_REAL_TUTORIAL_DAY_ONE").strip_edges() == "1" or final_rescue_tutorial
    screenshot_dir = OS.get_environment("VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR")
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/real-tutorial-playthrough")
    ensure_dir(screenshot_dir)

func run() -> void:
    mark_progress("start")
    report_data = {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "seed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "runToken": OS.get_environment("VOXEL_REAL_TUTORIAL_RUN_TOKEN"),
        "gitBranch": OS.get_environment("VOXEL_GIT_BRANCH"),
        "gitCommit": OS.get_environment("VOXEL_GIT_COMMIT"),
        "finished": false,
        "passed": false,
        "failureCount": 0,
        "resultCount": 0,
        "nonHeadlessVisualRequired": visual_required,
        "miraHomeOnly": mira_home_only,
        "morningOutsideOnly": morning_outside_only,
        "dayOneTutorial": day_one_tutorial,
        "finalRescueTutorial": final_rescue_tutorial,
        "playtestGodMode": playtest_god_mode,
        "fullPlayerPov": full_player_pov_visual_mode(),
        "screenshotDir": screenshot_dir,
        "visualCaptures": visual_captures,
        "timeline": morning_observation_timeline,
        "dayOneTimeline": day_one_timeline,
        "finalRescueTimeline": final_rescue_timeline,
        "finalRescueNormalBehaviorTimeline": final_rescue_normal_behavior_timeline,
        "finalRescueCombatEvents": final_rescue_combat_events,
        "morningOutsideVisualMatrix": morning_outside_visual_matrix,
        "deterministicSetup": {},
        "scriptErrorScan": { "status": "pending-wrapper-scan", "matches": [] },
        "forbiddenCallSelfScan": { "status": "passed-by-wrapper-before-launch" }
    }

    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("main_instantiated")
    mark_progress("waiting_initial_physics")
    await wait_physics_frames(30)
    mark_progress("initial_physics_ready")
    bind_scene_nodes()
    mark_progress("preparing_tutorial_world")
    await prepare_tutorial_world()
    mark_progress("tutorial_world_prepared")
    mark_progress("waiting_startup_frames")
    await wait_physics_frames(STARTUP_FRAMES)
    mark_progress("startup_frames_ready")
    bind_scene_nodes()

    if main == null or player == null or camera == null:
        add_failure("scene_bootstrap_failed", "main/player/camera missing")
        finish()
        return
    if not await apply_playtest_damage_policy():
        finish()
        return

    player.set("automated_input", true)
    player.set("automated_move", Vector3.ZERO)
    player.set("automated_sprint", false)
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    setup_observer_camera()
    gameplay_started = true
    mark_progress("gameplay_started")

    if final_rescue_tutorial:
        await run_final_rescue_from_ready_fixture()
    elif morning_outside_only:
        await run_following_morning_outside_observation()
    else:
        await run_real_knock_to_morning_foragers()
    finish()

func prepare_tutorial_world() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial != null and tutorial.has_method("start_new_world"):
        var started := bool(tutorial.call("start_new_world"))
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": true,
            "started": started
        }
    else:
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": false,
            "started": false
        }
    if main != null and main.has_method("update_chunks"):
        main.call("update_chunks", true)
    if main != null and main.has_method("refresh_intro_knock_audio"):
        main.call("refresh_intro_knock_audio")

func apply_playtest_damage_policy() -> bool:
    var survival = main.get("survival_system") if main != null else null
    if survival == null:
        if playtest_god_mode:
            add_failure("playtest_god_mode_missing_survival", "survival system was not available")
            return false
        report_data["playtestDamagePolicy"] = { "godMode": false, "reason": "survival_unavailable" }
        return true
    if playtest_god_mode:
        if not survival.has_method("set_test_god_mode"):
            add_failure("playtest_god_mode_unsupported", "survival system does not expose set_test_god_mode")
            return false
        survival.call("set_test_god_mode", true, TEST_ID)
    var state: Dictionary = survival.call("test_god_mode_state") if survival.has_method("test_god_mode_state") else { "enabled": false, "reason": "" }
    report_data["playtestDamagePolicy"] = {
        "godMode": bool(state.get("enabled", false)),
        "reason": String(state.get("reason", "")),
        "damageExpected": "zero" if bool(state.get("enabled", false)) else "normal"
    }
    return true
    await wait_physics_frames(20)

func run_following_morning_outside_observation() -> void:
    mark_progress("staging_following_morning")
    sample_player("following_morning_player_house_start")
    stage_following_morning_without_npc_forcing()
    await wait_physics_frames(POST_ACTION_FRAMES)
    if observer_camera != null and is_instance_valid(observer_camera):
        observer_camera.make_current()
    mark_progress("observing_following_morning_npcs")
    await observe_following_morning_outside_targets(MORNING_OUTSIDE_TIMEOUT_SECONDS)

func stage_following_morning_without_npc_forcing() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    var before_state := tutorial_state_summary(tutorial)
    if tutorial != null:
        tutorial.set("intro_door_opened", true)
        tutorial.set("intro_elder_dialogue_acknowledged", true)
        tutorial.set("intro_repair_active", false)
        tutorial.set("intro_repair_complete", true)
        tutorial.set("intro_repair_chest_opened", true)
        tutorial.set("intro_bed_used", true)
    if main != null:
        main.set("time_of_day", FOLLOWING_MORNING_TIME)
        if main.has_method("update_sky"):
            main.call("update_sky", 0.0)
        if main.has_method("update_objectives_and_contracts"):
            main.call("update_objectives_and_contracts")
    var after_state := tutorial_state_summary(tutorial)
    report_data["morningObservationSetup"] = {
        "stagedTutorialMorning": true,
        "forcedNpcActions": false,
        "forcedNpcIds": [],
        "playerStartsInHouse": true,
        "activeCameraMode": "freeform_morning_observer",
        "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0,
        "displayHour": rounded(clock_display_hour()),
        "tutorialBefore": before_state,
        "tutorialAfter": after_state,
        "playerStartSample": player_timeline[player_timeline.size() - 1] if not player_timeline.is_empty() else {}
    }

func run_final_rescue_from_ready_fixture() -> void:
    mark_progress("staging_final_rescue_ready_fixture")
    var tutorial = main.get("tutorial_system") if main != null else null
    stage_final_rescue_ready_fixture(tutorial)
    await wait_physics_frames(POST_ACTION_FRAMES * 2)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_final_rescue_ready_fixture",
            npc_target_position("mira"),
            { "fixture": report_data.get("finalRescueFixtureSetup", {}), "state": final_rescue_state_summary(tutorial) }
        )
    var exited_starter_house := await ensure_player_outside_starter_house_for_final_rescue(tutorial)
    if failed or not exited_starter_house:
        return
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_final_rescue_starter_exit",
            npc_target_position("mira"),
            { "state": final_rescue_state_summary(tutorial) }
        )
    await run_final_rescue_tutorial(tutorial)

func stage_final_rescue_ready_fixture(tutorial) -> void:
    var before_state := tutorial_state_summary(tutorial)
    var before_inventory := inventory_totals()
    if tutorial != null:
        tutorial.set("intro_door_opened", true)
        tutorial.set("intro_elder_dialogue_acknowledged", true)
        tutorial.set("intro_repair_active", false)
        tutorial.set("intro_repair_complete", true)
        tutorial.set("intro_repair_chest_opened", true)
        tutorial.set("intro_bed_used", true)
        tutorial.set("final_night_active", false)
        tutorial.set("final_night_complete", false)
        tutorial.set("rescue_escort_started", false)
        tutorial.set("rescue_returning", false)
        tutorial.set("rescue_site", Vector3.ZERO)
        tutorial.set("completed_steps", {
            "introDoorOpened": true,
            "introRepairChest": true,
            "introFenceBuilt": true,
            "introPerimeterRepaired": true,
            "introFirstSleep": true,
            "miraMorningBriefing": true,
            "nikoBerries": true,
            "nikoFoodReward": true,
            "rowanAxe": true,
            "rowanLogs": true,
            "rowanLogsReward": true,
            "rowanPickaxe": true,
            "rowanStones": true,
            "rowanBlocks": true,
            "rowanBlocksReward": true,
            "seraWeapon": true,
            "seraWeaponReward": true,
            "readyForWilds": true
        })
        tutorial.set("interacted", {
            "mira": true,
            "niko": true,
            "rowan": true,
            "sera": true
        })
    var granted_items := grant_final_rescue_fixture_items()
    if main != null:
        main.set("time_of_day", FOLLOWING_MORNING_TIME + 0.20)
        if main.has_method("update_sky"):
            main.call("update_sky", 0.0)
        if main.has_method("update_objectives_and_contracts"):
            main.call("update_objectives_and_contracts")
        var hostile_system = main.get("hostile_system")
        if hostile_system != null and hostile_system.has_method("clear"):
            hostile_system.call("clear")
    report_data["finalRescueFixtureSetup"] = {
        "stagedPriorQuestState": true,
        "acceptanceClaimStartsAfterSetup": true,
        "notAcceptanceForPriorQuests": true,
        "forcedNpcActions": false,
        "directFinalNightStart": false,
        "directRescueEscortStart": false,
        "directHostileDamage": false,
        "grantedItems": granted_items,
        "beforeTutorial": before_state,
        "afterTutorial": tutorial_state_summary(tutorial),
        "beforeInventory": before_inventory,
        "afterInventory": inventory_totals()
    }

func grant_final_rescue_fixture_items() -> Array[String]:
    var granted: Array[String] = []
    var final_rescue_fixture_inventory_system = main.get("inventory_system") if main != null else null
    if final_rescue_fixture_inventory_system == null:
        return granted
    var needed := {
        "woodenSword": 1,
        "fieldRation": 1,
        "torch": 1
    }
    for item_id in needed.keys():
        var current := int(inventory_totals().get(String(item_id), 0))
        var missing := int(needed[item_id]) - current
        if missing <= 0:
            continue
        final_rescue_fixture_inventory_system.add_item(String(item_id), missing) # final_rescue_fixture_setup_allowance
        granted.append(String(item_id))
    return granted

func ensure_player_outside_starter_house_for_final_rescue(tutorial) -> bool:
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var current_cell := flat_cell(player.global_position)
    if abs(current_cell.x - start_cell.x) > 8 or current_cell.y <= start_cell.y - 4:
        return true
    var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
    var starter_door := nearest_block("door", world_position_for_flat_cell(starter_door_cell))
    if starter_door == null or not is_instance_valid(starter_door):
        add_failure("final_rescue_starter_exit_door_missing", JSON.stringify({
            "startCell": vec2i(start_cell),
            "doorCell": vec2i(starter_door_cell),
            "player": vec3(player.global_position)
        }))
        return false
    if not bool(starter_door.get_meta("open", false)):
        var opened := await use_block_with_real_action(starter_door, "final_rescue_starter_exit_door", CELL * 1.85, 14.0)
        if not opened:
            return false
        await wait_physics_frames(POST_ACTION_FRAMES)
    var exit_cell := Vector2i(start_cell.x, start_cell.y - 5)
    var reached_exit := await walk_intro_waypoints(
        [Vector2i(start_cell.x, start_cell.y - 1), starter_door_cell, exit_cell],
        "final_rescue_starter_exit",
        CELL * 1.05,
        14.0
    )
    interaction_timeline.append({
        "label": "final_rescue_starter_house_exit",
        "player": vec3(player.global_position),
        "startCell": vec2i(start_cell),
        "door": block_summary(starter_door),
        "exitCell": vec2i(exit_cell),
        "reached": reached_exit
    })
    if not reached_exit:
        return false
    await wait_physics_frames(POST_ACTION_FRAMES)
    return true

func observe_following_morning_outside_targets(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    for frame in range(frame_count):
        await get_tree().physics_frame
        if frame % SAMPLE_EVERY_FRAMES == 0:
            morning_outside_visual_matrix = morning_outside_target_matrix()
            report_data["morningOutsideVisualMatrix"] = morning_outside_visual_matrix
            schedule_matrix = npc_schedule_matrix()
            morning_observation_timeline.append({
                "label": "morning_outside_%03d" % frame,
                "time": rounded(elapsed),
                "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0,
                "displayHour": rounded(clock_display_hour()),
                "targets": morning_outside_visual_matrix
            })
            report_data["timeline"] = morning_observation_timeline
            mark_progress("morning_outside_%03d" % frame)
        if morning_targets_outside(morning_outside_visual_matrix):
            settled_frames += 1
        else:
            settled_frames = 0
        if settled_frames >= MIRA_HOME_SETTLED_FRAMES:
            break
    morning_outside_visual_matrix = morning_outside_target_matrix()
    report_data["morningOutsideVisualMatrix"] = morning_outside_visual_matrix
    var outside := morning_targets_outside(morning_outside_visual_matrix)
    if not outside:
        add_failure("following_morning_targets_not_outside", JSON.stringify(morning_outside_visual_matrix))
        return
    var group_capture_saved := false
    var capture_map := {}
    if visual_required:
        group_capture_saved = await capture_morning_outside_group("morning_outside_group")
        for npc_id in MORNING_OUTSIDE_TARGETS:
            var entry := npc_entry(String(npc_id))
            var stage := "morning_outside_%s" % safe_capture_id(String(npc_id))
            capture_map[String(npc_id)] = await capture_npc_outside_stage(entry, stage)
    morning_outside_visual_matrix = morning_outside_target_matrix(capture_map)
    report_data["morningOutsideVisualMatrix"] = morning_outside_visual_matrix
    report_data["morningOutsideGroupCaptureSaved"] = group_capture_saved
    morning_observation_timeline.append({
        "label": "morning_outside_visual_proof",
        "time": rounded(elapsed),
        "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0,
        "displayHour": rounded(clock_display_hour()),
        "groupCaptureSaved": group_capture_saved,
        "captures": capture_names(),
        "targets": morning_outside_visual_matrix
    })
    report_data["timeline"] = final_rescue_timeline if final_rescue_tutorial else morning_observation_timeline
    if visual_required and (not group_capture_saved or not morning_outside_captures_saved(capture_map)):
        add_failure("following_morning_visual_captures_missing", JSON.stringify({
            "groupCaptureSaved": group_capture_saved,
            "targets": morning_outside_visual_matrix,
            "captures": capture_names()
        }))
        return
    results.append({
        "name": "following_morning_rowan_mira_niko_outside_visual",
        "passed": true,
        "details": "targets=%s groupCapture=%s captures=%s" % [
            JSON.stringify(MORNING_OUTSIDE_TARGETS),
            str(group_capture_saved),
            JSON.stringify(capture_names())
        ]
    })

func run_real_knock_to_morning_foragers() -> void:
    var tutorial = main.get("tutorial_system")
    var before_state := tutorial_state_summary(tutorial)
    report_data["initialTutorialState"] = before_state
    sample_player("initial")
    var layout_proof := tutorial_layout_proof(tutorial)
    report_data["tutorialLayoutProof"] = layout_proof
    var single_perimeter_radius := bool(layout_proof.get("singlePerimeterRadius", false))
    results.append({
        "name": "tutorial_generated_perimeter_matches_repair_radius",
        "passed": single_perimeter_radius,
        "details": "townRadius=%d repairRadius=%d" % [
            int(layout_proof.get("townRadius", 0)),
            int(layout_proof.get("repairRadius", TUTORIAL_REPAIR_RADIUS_CELLS))
        ]
    })
    if not single_perimeter_radius:
        add_failure("tutorial_double_perimeter_radius_mismatch", JSON.stringify(layout_proof))
        return
    var starter_door := nearest_block("door", player.global_position)
    if starter_door == null:
        add_failure("starter_door_missing", "no door block found near tutorial start")
        return
    sample_door("initial", starter_door)

    var door_position := starter_door.global_position
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_start",
            door_position + Vector3(0.0, CELL * 0.75, 0.0),
            { "stageReason": "tutorial_start_before_intro_door_walk" }
        )
    mark_progress("walking_to_door")
    await walk_near(door_position, CELL * 1.55, 9.0)
    sample_player("near_door")
    aim_at(door_position + Vector3(0.0, CELL * 0.75, 0.0))
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("before_click", starter_door)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_intro_door_before_click",
            door_position + Vector3(0.0, CELL * 0.75, 0.0),
            { "door": block_summary(starter_door) }
        )
    mark_progress("dispatching_door_action")
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("after_click", starter_door)
    sample_player("after_door_action")
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_intro_dialogue_open",
            door_position + Vector3(0.0, CELL * 0.75, 0.0),
            { "door": block_summary(starter_door), "dialogueOpen": hud_dialogue_open() }
        )

    var after_state := tutorial_state_summary(tutorial)
    report_data["afterDoorTutorialState"] = after_state
    var opened := bool(after_state.get("doorOpened", false))
    var dialogue_open := hud_dialogue_open()
    results.append({
        "name": "real_door_input_opened_tutorial_dialogue",
        "passed": opened and dialogue_open,
        "details": "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)]
    })
    if not opened or not dialogue_open:
        add_failure("real_input_path_failed_before_mira_observation", "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)])
        return

    mark_progress("closing_dialogue")
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    report_data["afterDialogueTutorialState"] = tutorial_state_summary(tutorial)
    sample_player("after_dialogue_ack")
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_dialogue_acknowledged",
            door_position + Vector3(0.0, CELL * 0.75, 0.0),
            { "tutorialState": report_data["afterDialogueTutorialState"] }
        )
    if hud_dialogue_open():
        add_failure("dialogue_still_open_after_real_ack", "HUD dialogue remained open after Escape close input")
        return
    if not bool(report_data["afterDialogueTutorialState"].get("elderAcknowledged", false)):
        add_failure("mira_dialogue_ack_not_recorded", "tutorial state did not record elder acknowledgement after HUD close")
        return

    mark_progress("observing_mira_return_home")
    var mira_home_timeout := mira_home_observation_timeout(MIRA_HOME_TIMEOUT_SECONDS)
    report_data["miraHomeObservationTimeout"] = rounded(mira_home_timeout)
    await observe_mira_until_home(mira_home_timeout)
    if focused_mira_visual_mode() and not captured_mira_inside_closed:
        await capture_mira_stage("mira_timeout_final_state", "front")
    var mira := npc_entry("mira")
    if full_player_pov_visual_mode():
        var mira_body := mira.get("body") as Node3D
        var mira_target := mira_body.global_position + Vector3(0.0, CELL * 0.75, 0.0) if mira_body != null and is_instance_valid(mira_body) else player.global_position
        await capture_player_pov_stage(
            "player_pov_after_mira_home",
            mira_target,
            { "mira": npc_summary(mira) if not mira.is_empty() else {} }
        )
    var speed_limit := profile_speed_limit(mira)
    report_data["miraSpeedLimit"] = rounded(speed_limit)
    report_data["miraMaxFlatSpeed"] = rounded(max_mira_flat_speed)
    report_data["miraTotalFlatDistance"] = rounded(mira_total_flat_distance)
    report_data["miraFinalHomeInteriorStatus"] = strict_home_status(mira)
    report_data["miraDoorWalkableProbe"] = home_door_walkable_probe(mira)
    if max_mira_flat_speed > speed_limit:
        add_failure(
            "mira_non_profile_speed",
            "max flat speed %.3f exceeded profile limit %.3f" % [max_mira_flat_speed, speed_limit]
        )
    elif mira_total_flat_distance < CELL * 0.4:
        add_failure(
            "mira_stalls_due_to_update_budget",
            "Mira moved only %.3f meters during observation" % mira_total_flat_distance
        )
    else:
        results.append({
            "name": "mira_timeline_speed_within_profile",
            "passed": true,
            "details": "max flat speed %.3f <= %.3f" % [max_mira_flat_speed, speed_limit]
        })
    if not bool(report_data["miraFinalHomeInteriorStatus"].get("strictInside", false)):
        add_failure("mira_did_not_reach_strict_home_interior", JSON.stringify(report_data["miraFinalHomeInteriorStatus"]))
    elif focused_mira_visual_mode() and not required_mira_captures_saved():
        add_failure("mira_visual_captures_missing", JSON.stringify(capture_names()))
    elif focused_mira_visual_mode():
        await verify_other_non_guard_npcs_home_visual()
    if failed:
        return
    if not failed and mira_home_only:
        results.append({
            "name": "mira_real_tutorial_go_home_visual",
            "passed": true,
            "details": "Mira reached strict home interior, other non-guard NPCs are visually home, and doors closed; captures=%s" % JSON.stringify(capture_names())
        })
    if mira_home_only:
        return
    await observe_night_matrix_until_ready(120.0)
    night_matrix = validate_night_matrix()
    report_data["nightGuardNonGuardMatrix"] = night_matrix
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_night_matrix_ready",
            null,
            { "nightMatrix": night_matrix }
        )

    mark_progress("checking_bed_locked_before_repair")
    var failures_before_stage := failure_reasons.size()
    await attempt_sleep_before_repair(tutorial)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_sleep_blocked_before_repair",
            null,
            { "sleepTimeline": sleep_timeline }
        )
    if failure_reasons.size() > failures_before_stage:
        return

    mark_progress("running_repair_flow")
    failures_before_stage = failure_reasons.size()
    await run_repair_flow(tutorial)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_after_repair_flow",
            null,
            { "repairEvents": repair_placement_events, "inventory": inventory_totals() }
        )
    if failure_reasons.size() > failures_before_stage:
        return

    mark_progress("sleeping_after_repair")
    failures_before_stage = failure_reasons.size()
    await attempt_sleep_after_repair(tutorial)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_after_sleep_attempt",
            null,
            { "sleepTimeline": sleep_timeline }
        )
    if failure_reasons.size() > failures_before_stage:
        return

    if day_one_tutorial:
        mark_progress("running_day_one_tutorial")
        await run_day_one_tutorial(tutorial)
        if failed:
            return
        if final_rescue_tutorial:
            mark_progress("running_final_rescue_tutorial")
            await run_final_rescue_tutorial(tutorial)
        return

    mark_progress("observing_morning_foragers")
    await observe_morning_npcs_and_foragers(MORNING_FORAGE_TIMEOUT_SECONDS)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_after_morning_forager_observation",
            final_morning_player_pov_target(),
            { "nikoProof": niko_proof }
        )

    report_data["nikoForagerState"] = forager_state_summary()
    report_data["repairTargetPlacementProof"] = repair_target_proof(tutorial)
    report_data["sleepTransitionProof"] = sleep_transition_proof(tutorial)
    report_data["morningNpcDepartureMatrix"] = morning_departure_matrix
    report_data["nikoForageProof"] = niko_proof

func observe_npcs_for_seconds(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("observe_%03d" % frame)
            sample_mira("observe_%03d" % frame)
            route_order_timeline.append(route_order_sample("observe_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("observing_%03d" % frame)

func observe_mira_until_home(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    var starter_wall_stuck_frames := 0
    var starter_wall_stuck_sample := {}
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        var mira := npc_entry("mira")
        var starter_regression := mira_starter_house_route_regression_sample(mira)
        if bool(starter_regression.get("enteredStarterInterior", false)):
            mira_starter_route_regression = starter_regression
            report_data["miraStarterRouteRegression"] = mira_starter_route_regression
            if visual_required:
                var body := mira.get("body") as Node3D
                var target := body.global_position + Vector3(0.0, CELL * 0.75, 0.0) if body != null and is_instance_valid(body) else player.global_position
                await capture_player_pov_stage("player_pov_mira_starter_route_regression", target, starter_regression)
            add_failure("mira_route_crossed_starter_house_collision", JSON.stringify(starter_regression))
            break
        if bool(starter_regression.get("hitStarterWall", false)) and bool(starter_regression.get("routeStalled", false)):
            starter_wall_stuck_frames += 1
            starter_wall_stuck_sample = starter_regression
            starter_wall_stuck_sample["stuckFrames"] = starter_wall_stuck_frames
        else:
            starter_wall_stuck_frames = 0
        if starter_wall_stuck_frames >= MIRA_STARTER_WALL_STUCK_FRAMES:
            mira_starter_route_regression = starter_wall_stuck_sample
            report_data["miraStarterRouteRegression"] = mira_starter_route_regression
            if visual_required:
                var stuck_body := mira.get("body") as Node3D
                var stuck_target := stuck_body.global_position + Vector3(0.0, CELL * 0.75, 0.0) if stuck_body != null and is_instance_valid(stuck_body) else player.global_position
                await capture_player_pov_stage("player_pov_mira_starter_route_stuck", stuck_target, starter_wall_stuck_sample)
            add_failure("mira_stuck_on_starter_house_collision", JSON.stringify(starter_wall_stuck_sample))
            break
        var home_status := strict_home_status(mira)
        if focused_mira_visual_mode():
            await maybe_capture_mira_return_home(frame, mira, home_status)
        var strict_inside := bool(home_status.get("strictInside", false))
        var visual_settled := true
        if focused_mira_visual_mode():
            visual_settled = captured_mira_inside_closed and not any_mira_home_door_open(mira)
        if strict_inside and visual_settled:
            settled_frames += 1
        else:
            settled_frames = 0
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("mira_home_%03d" % frame)
            sample_mira("mira_home_%03d" % frame)
            route_order_timeline.append(route_order_sample("mira_home_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("mira_home_%03d" % frame)
        if settled_frames >= MIRA_HOME_SETTLED_FRAMES:
            break

func mira_home_observation_timeout(minimum_seconds: float) -> float:
    var mira := npc_entry("mira")
    if mira.is_empty():
        return minimum_seconds
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return minimum_seconds
    var home_position := entry_position(mira, "homePosition", body.global_position)
    var direct_distance := flat_distance(body.global_position, home_position)
    var route_distance := maxf(direct_distance, estimate_flat_route_distance(mira))
    var walk_speed := npc_walk_speed_for_timeout(mira)
    var travel_seconds := route_distance / walk_speed
    var door_and_settle_seconds := 12.0 + float(MIRA_HOME_SETTLED_FRAMES) / float(Engine.physics_ticks_per_second)
    return clampf(travel_seconds + door_and_settle_seconds, minimum_seconds, 78.0)

func estimate_flat_route_distance(entry: Dictionary) -> float:
    var cells: Array = entry.get("routeCells", [])
    if cells.is_empty():
        return 0.0
    var previous := flat_cell((entry.get("body") as Node3D).global_position) if entry.get("body") is Node3D else Vector2i.ZERO
    var total := 0.0
    for cell_value in cells:
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        total += Vector2(float(cell.x - previous.x), float(cell.y - previous.y)).length() * CELL
        previous = cell
    return total

func npc_walk_speed_for_timeout(entry: Dictionary) -> float:
    var speed := float(entry.get("npcSpeed", 0.0))
    if speed <= 0.01:
        var profile = entry.get("motorProfile")
        if profile != null:
            var walk_value = profile.get("walk_speed")
            if walk_value != null:
                speed = float(walk_value)
    if speed <= 0.01:
        speed = CELL * 1.8
    return maxf(speed * 0.72, CELL * 1.1)

func maybe_capture_mira_return_home(frame: int, mira: Dictionary, home_status: Dictionary) -> void:
    if mira.is_empty():
        return
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    if not captured_mira_start:
        mira_route_start_position = body.global_position
        mira_route_start_valid = true
        await capture_mira_stage("mira_go_home_start", "route")
        captured_mira_start = true
    var door := mira_home_door(mira)
    if door == null:
        return
    var distance_to_door := flat_distance(body.global_position, door.global_position)
    var door_open := bool(door.get_meta("open", false))
    var home_position := entry_position(mira, "homePosition", door.global_position)
    var route_progress := mira_route_progress(body.global_position, home_position)
    var moved_from_start := flat_distance(body.global_position, mira_route_start_position)
    if not captured_mira_route_departure and moved_from_start >= CELL * 1.5 and distance_to_door > CELL * 4.0:
        await capture_mira_stage("mira_route_departure", "route")
        captured_mira_route_departure = true
    if not captured_mira_route_midpoint and route_progress >= 0.35 and distance_to_door > CELL * 3.0:
        await capture_mira_stage("mira_route_midpoint", "route")
        captured_mira_route_midpoint = true
    if not captured_mira_at_door and distance_to_door <= CELL * 1.9:
        await capture_mira_stage("mira_at_home_door", "front")
        captured_mira_at_door = true
    if not captured_mira_door_open and door_open:
        await capture_mira_stage("mira_home_door_open", "front")
        captured_mira_door_open = true
    if not captured_mira_inside_closed and bool(home_status.get("strictInside", false)) and not any_mira_home_door_open(mira):
        await capture_mira_stage("mira_inside_home_closed_door", "inside")
        captured_mira_inside_closed = true

func setup_observer_camera() -> void:
    if observer_camera != null and is_instance_valid(observer_camera):
        return
    observer_camera = Camera3D.new()
    observer_camera.name = "RealTutorialMiraObserverCamera"
    observer_camera.fov = 62.0
    observer_camera.near = 0.04
    add_child(observer_camera)
    observer_torch = OmniLight3D.new()
    observer_torch.name = "RealTutorialObserverTorch"
    observer_torch.light_color = Color(1.0, 0.72, 0.42)
    observer_torch.light_energy = 3.8
    observer_torch.omni_range = CELL * 9.0
    observer_torch.shadow_enabled = false
    observer_torch.set_meta("visual_test_torch", true)
    observer_camera.add_child(observer_torch)

func capture_mira_stage(stage: String, camera_mode: String) -> void:
    setup_observer_camera()
    position_mira_observer_camera(camera_mode)
    configure_observer_torch(camera_mode)
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var mira := npc_entry("mira")
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": camera_mode,
        "time": rounded(elapsed),
        "sample": mira_visual_sample(mira)
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    restore_gameplay_camera()

func verify_other_non_guard_npcs_home_visual() -> void:
    var rows := npc_schedule_matrix()
    var failures: Array[Dictionary] = []
    non_guard_home_visual_matrix = []
    for row in rows:
        var npc_id := String(row.get("id", ""))
        if npc_id == "" or npc_id == "mira" or bool(row.get("nightGuard", false)):
            continue
        var entry := npc_entry(npc_id)
        var strict_inside := bool(row.get("strictInsideHome", false))
        var stage := "non_guard_home_%s" % safe_capture_id(npc_id)
        var capture_saved := false
        if visual_required:
            capture_saved = await capture_npc_home_stage(entry, stage)
        var proof := {
            "id": npc_id,
            "name": String(row.get("name", "")),
            "nightGuard": false,
            "strictInsideHome": strict_inside,
            "stage": stage,
            "captureSaved": capture_saved,
            "summary": npc_summary(entry) if not entry.is_empty() else row
        }
        non_guard_home_visual_matrix.append(proof)
        if not strict_inside or not capture_saved:
            failures.append(proof)
    report_data["nonGuardHomeVisualMatrix"] = non_guard_home_visual_matrix
    if non_guard_home_visual_matrix.is_empty():
        add_failure("non_guard_home_visual_no_targets", "no non-guard NPCs besides Mira were available to visually verify")
    elif not failures.is_empty():
        add_failure("non_guard_npcs_not_visually_home_after_mira", JSON.stringify(failures))
    else:
        results.append({
            "name": "other_non_guard_npcs_visually_home_after_mira",
            "passed": true,
            "details": "verified=%d captures=%s" % [non_guard_home_visual_matrix.size(), JSON.stringify(capture_names())]
        })

func capture_npc_home_stage(entry: Dictionary, stage: String) -> bool:
    if entry.is_empty():
        return false
    setup_observer_camera()
    position_npc_home_observer_camera(entry)
    configure_observer_torch("inside")
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": "non_guard_home_inside",
        "time": rounded(elapsed),
        "sample": npc_home_visual_sample(entry)
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    restore_gameplay_camera()
    return err == OK

func capture_morning_outside_group(stage: String) -> bool:
    setup_observer_camera()
    position_morning_group_observer_camera()
    configure_observer_torch("wide")
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": "freeform_morning_observer_group",
        "time": rounded(elapsed),
        "sample": {
            "targets": morning_outside_target_matrix(),
            "observerTorch": observer_torch_summary(),
            "observerCamera": observer_camera_summary()
        }
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    restore_gameplay_camera()
    return err == OK

func capture_npc_outside_stage(entry: Dictionary, stage: String) -> bool:
    if entry.is_empty():
        return false
    setup_observer_camera()
    position_npc_outside_observer_camera(entry)
    configure_observer_torch("wide")
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": "freeform_morning_observer_npc",
        "time": rounded(elapsed),
        "sample": npc_outside_visual_sample(entry)
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    restore_gameplay_camera()
    return err == OK

func restore_gameplay_camera() -> void:
    if camera != null and is_instance_valid(camera):
        camera.make_current()

func focused_mira_visual_mode() -> bool:
    return visual_required and mira_home_only and not morning_outside_only

func full_player_pov_visual_mode() -> bool:
    return visual_required and not mira_home_only and not morning_outside_only

func capture_player_pov_stage(stage: String, look_target = null, extra_sample: Dictionary = {}) -> bool:
    if not full_player_pov_visual_mode():
        return true
    restore_gameplay_camera()
    if look_target is Vector3:
        aim_at(look_target)
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var byte_count := 0
    if FileAccess.file_exists(path):
        byte_count = FileAccess.get_file_as_bytes(path).size()
    var saved_ok := err == OK and byte_count > 0
    var capture := {
        "stage": stage,
        "path": path,
        "saved": saved_ok,
        "bytes": byte_count,
        "cameraMode": "player_pov",
        "time": rounded(elapsed),
        "sample": player_pov_capture_sample(extra_sample)
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    if not saved_ok:
        add_failure("player_pov_screenshot_empty", JSON.stringify(capture))
    return saved_ok

func player_pov_capture_sample(extra_sample: Dictionary = {}) -> Dictionary:
    var sample := extra_sample.duplicate(true)
    if player != null and is_instance_valid(player):
        sample["player"] = {
            "position": vec3(player.global_position),
            "velocity": vec3(player.velocity),
            "automatedMove": vec3(player.get("automated_move")),
            "flatCell": vec2i(flat_cell(player.global_position))
        }
    if camera != null and is_instance_valid(camera):
        var active_camera := get_viewport().get_camera_3d()
        sample["camera"] = {
            "position": vec3(camera.global_position),
            "rotation": vec3(camera.global_rotation),
            "isActiveViewportCamera": active_camera == camera
        }
    var tutorial = main.get("tutorial_system") if main != null else null
    sample["tutorialState"] = tutorial_state_summary(tutorial)
    sample["runtimeActionState"] = runtime_action_state()
    sample["timeOfDay"] = rounded(float(main.get("time_of_day"))) if main != null else 0.0
    return sample

func final_morning_player_pov_target():
    if player == null or not is_instance_valid(player):
        return null
    var starter_door := nearest_block("door", player.global_position)
    if starter_door != null:
        return starter_door.global_position + Vector3(0.0, CELL * 0.75, 0.0)
    return player.global_position + (-player.global_transform.basis.z * CELL * 4.0) + Vector3(0.0, CELL * 0.75, 0.0)

func position_npc_home_observer_camera(entry: Dictionary) -> void:
    if observer_camera == null:
        return
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var body_position := body.global_position
    var home_position := entry_position(entry, "homePosition", body_position)
    var inside_direction := Vector3(home_position.x - body_position.x, 0.0, home_position.z - body_position.z)
    if inside_direction.length() < 0.05:
        inside_direction = Vector3(1.0, 0.0, 1.0)
    inside_direction = inside_direction.normalized()
    var side_direction := Vector3(-inside_direction.z, 0.0, inside_direction.x)
    var target := body_position + Vector3(0.0, CELL * 0.75, 0.0)
    var camera_position := body_position + inside_direction * CELL * 2.45 + side_direction * CELL * 0.65 + Vector3(0.0, CELL * 1.2, 0.0)
    camera_position.y = body_position.y + CELL * 1.15
    observer_camera.global_position = camera_position
    observer_camera.look_at(target, Vector3.UP)
    last_observer_camera_target = target
    observer_camera.make_current()

func position_morning_group_observer_camera() -> void:
    if observer_camera == null:
        return
    var positions: Array[Vector3] = []
    for npc_id in MORNING_OUTSIDE_TARGETS:
        var entry := npc_entry(String(npc_id))
        var body := entry.get("body") as Node3D
        if body != null and is_instance_valid(body):
            positions.append(body.global_position)
    var center := player.global_position if player != null else Vector3.ZERO
    if not positions.is_empty():
        center = Vector3.ZERO
        for position in positions:
            center += position
        center /= float(positions.size())
    var target := center + Vector3(0.0, CELL * 0.85, 0.0)
    var camera_position := center + Vector3(CELL * 6.2, CELL * 3.7, CELL * 6.2)
    observer_camera.global_position = camera_position
    observer_camera.look_at(target, Vector3.UP)
    last_observer_camera_target = target
    observer_camera.make_current()

func position_npc_outside_observer_camera(entry: Dictionary) -> void:
    if observer_camera == null or entry.is_empty():
        return
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var body_position := body.global_position
    var home_position := entry_position(entry, "homePosition", body_position)
    var away_from_home := Vector3(body_position.x - home_position.x, 0.0, body_position.z - home_position.z)
    if away_from_home.length() < 0.05:
        away_from_home = Vector3(1.0, 0.0, 1.0)
    away_from_home = away_from_home.normalized()
    var side_direction := Vector3(-away_from_home.z, 0.0, away_from_home.x)
    var target := body_position + Vector3(0.0, CELL * 0.85, 0.0)
    var camera_position := body_position + away_from_home * CELL * 4.0 + side_direction * CELL * 1.8 + Vector3(0.0, CELL * 1.75, 0.0)
    observer_camera.global_position = camera_position
    observer_camera.look_at(target, Vector3.UP)
    last_observer_camera_target = target
    observer_camera.make_current()

func position_mira_observer_camera(mode: String) -> void:
    if observer_camera == null:
        return
    var mira := npc_entry("mira")
    var body := mira.get("body") as Node3D
    var body_position := body.global_position if body != null and is_instance_valid(body) else player.global_position
    var door := mira_home_door(mira)
    var door_position := door.global_position if door != null else body_position
    var home_position := entry_position(mira, "homePosition", door_position)
    var porch_position := entry_position(mira, "porchPosition", door_position)
    var level := maxf(home_position.y, body_position.y)
    var outside_direction := Vector3(porch_position.x - home_position.x, 0.0, porch_position.z - home_position.z)
    if outside_direction.length() < 0.05:
        outside_direction = Vector3(0.0, 0.0, -1.0)
    outside_direction = outside_direction.normalized()
    var side_direction := Vector3(-outside_direction.z, 0.0, outside_direction.x)
    var route_direction := mira_route_direction(body_position, home_position)
    var route_side_direction := Vector3(-route_direction.z, 0.0, route_direction.x)
    var target := door_position + Vector3(0.0, CELL * 0.85, 0.0)
    var camera_position := door_position + outside_direction * CELL * 8.5 + Vector3(0.0, CELL * 3.2, 0.0)
    var camera_height := CELL * 3.2
    if mode == "route":
        var route_lookahead := body_position + route_direction * CELL * 5.0
        target = (body_position + route_lookahead) * 0.5 + Vector3(0.0, CELL * 0.9, 0.0)
        camera_position = body_position - route_direction * CELL * 4.6 + route_side_direction * CELL * 3.1 + Vector3(0.0, CELL * 1.85, 0.0)
        camera_height = CELL * 1.85
    elif mode == "wide":
        target = (body_position + home_position) * 0.5 + Vector3(0.0, CELL * 0.95, 0.0)
        camera_position = body_position - route_direction * CELL * 5.2 + route_side_direction * CELL * 3.4 + Vector3(0.0, CELL * 2.25, 0.0)
        camera_height = CELL * 2.25
    elif mode == "inside":
        target = (body_position + door_position) * 0.5 + Vector3(0.0, CELL * 0.85, 0.0)
        camera_position = body_position - outside_direction * CELL * 2.15 + side_direction * CELL * 1.15 + Vector3(0.0, CELL * 1.05, 0.0)
        camera_height = CELL * 1.05
    if mode == "inside":
        camera_position.y = level + camera_height
    else:
        camera_position.y = maxf(camera_position.y, level + camera_height)
    observer_camera.global_position = camera_position
    observer_camera.look_at(target, Vector3.UP)
    last_observer_camera_target = target
    observer_camera.make_current()

func mira_route_direction(body_position: Vector3, home_position: Vector3) -> Vector3:
    var route_start := mira_route_start_position if mira_route_start_valid else body_position
    var direction := Vector3(home_position.x - route_start.x, 0.0, home_position.z - route_start.z)
    if direction.length() < 0.05:
        direction = Vector3(home_position.x - body_position.x, 0.0, home_position.z - body_position.z)
    if direction.length() < 0.05:
        direction = Vector3(0.0, 0.0, -1.0)
    return direction.normalized()

func mira_route_progress(body_position: Vector3, home_position: Vector3) -> float:
    if not mira_route_start_valid:
        return 0.0
    var start_to_home := Vector2(home_position.x - mira_route_start_position.x, home_position.z - mira_route_start_position.z)
    var route_length := start_to_home.length()
    if route_length < 0.05:
        return 0.0
    var start_to_body := Vector2(body_position.x - mira_route_start_position.x, body_position.z - mira_route_start_position.z)
    return clampf(start_to_body.dot(start_to_home.normalized()) / route_length, 0.0, 1.0)

func configure_observer_torch(mode: String) -> void:
    if observer_torch == null or not is_instance_valid(observer_torch):
        return
    observer_torch.position = Vector3.ZERO
    observer_torch.visible = true
    if mode == "inside":
        observer_torch.light_energy = 5.5
        observer_torch.omni_range = CELL * 6.0
    elif mode == "wide":
        observer_torch.light_energy = 4.5
        observer_torch.omni_range = CELL * 12.0
    else:
        observer_torch.light_energy = 4.8
        observer_torch.omni_range = CELL * 10.0

func mira_visual_sample(mira: Dictionary) -> Dictionary:
    var body := mira.get("body") as Node3D
    var door := mira_home_door(mira)
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    return {
        "mira": npc_summary(mira) if not mira.is_empty() else {},
        "strictHome": strict_home_status(mira),
        "door": block_summary(door),
        "doorPortal": door_portal_summary(door),
        "doorOpen": bool(door.get_meta("open", false)) if door != null else false,
        "distanceToDoor": rounded(flat_distance(position, door.global_position)) if door != null else -1.0,
        "observerTorch": observer_torch_summary(),
        "observerCamera": observer_camera_summary(),
        "position": vec3(position)
    }

func npc_home_visual_sample(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var door := npc_home_door(entry)
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    return {
        "npc": npc_summary(entry) if not entry.is_empty() else {},
        "strictHome": strict_home_status(entry),
        "door": block_summary(door),
        "doorPortal": door_portal_summary(door),
        "doorOpen": bool(door.get_meta("open", false)) if door != null else false,
        "distanceToDoor": rounded(flat_distance(position, door.global_position)) if door != null else -1.0,
        "observerTorch": observer_torch_summary(),
        "observerCamera": observer_camera_summary(),
        "position": vec3(position)
    }

func npc_outside_visual_sample(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var door := npc_home_door(entry)
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    var home_status := strict_home_status(entry)
    return {
        "npc": npc_summary(entry) if not entry.is_empty() else {},
        "outsideOwnHome": not bool(home_status.get("strictInside", false)) and not entry.is_empty(),
        "strictHome": home_status,
        "door": block_summary(door),
        "doorPortal": door_portal_summary(door),
        "doorOpen": bool(door.get_meta("open", false)) if door != null else false,
        "distanceToDoor": rounded(flat_distance(position, door.global_position)) if door != null else -1.0,
        "observerTorch": observer_torch_summary(),
        "observerCamera": observer_camera_summary(),
        "position": vec3(position)
    }

func observer_camera_summary() -> Dictionary:
    if observer_camera == null or not is_instance_valid(observer_camera):
        return {}
    return {
        "position": vec3(observer_camera.global_position),
        "target": vec3(last_observer_camera_target)
    }

func observer_torch_summary() -> Dictionary:
    if observer_torch == null or not is_instance_valid(observer_torch):
        return {}
    return {
        "enabled": observer_torch.visible,
        "energy": rounded(observer_torch.light_energy),
        "range": rounded(observer_torch.omni_range)
    }

func door_portal_summary(door: Node) -> Dictionary:
    if door == null or main == null:
        return {}
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return {}
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null:
        return {}
    var door_portals = autonomy.get("door_portals")
    if door_portals == null or not door_portals.has_method("portal_for_door"):
        return {}
    var portal = door_portals.call("portal_for_door", door)
    if portal == null or not portal.has_method("to_summary"):
        return {}
    return portal.call("to_summary")

func mira_home_door(mira: Dictionary) -> Node3D:
    return npc_home_door(mira)

func npc_home_door(entry: Dictionary) -> Node3D:
    if entry.is_empty() or main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var porch_position := entry_position(entry, "porchPosition", entry_position(entry, "homePosition", Vector3.ZERO))
    var home_position := entry_position(entry, "homePosition", porch_position)
    var best: Node3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var distance := minf(flat_distance(block.global_position, porch_position), flat_distance(block.global_position, home_position))
        if distance < best_distance:
            best_distance = distance
            best = block
    return best

func safe_capture_id(value: String) -> String:
    var result := value.to_lower()
    for character in [" ", "/", "\\", ":", ";", ".", ",", "'", "\"", "(", ")", "[", "]"]:
        result = result.replace(character, "_")
    return result

func any_mira_home_door_open(mira: Dictionary) -> bool:
    var door := mira_home_door(mira)
    if door == null:
        return false
    var group_id := String(door.get_meta("door_group_id", ""))
    var portal_id := String(door.get_meta("door_portal_id", ""))
    var blocks_value = main.get("blocks") if main != null else {}
    if not (blocks_value is Dictionary):
        return bool(door.get_meta("open", false))
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var same_group := group_id != "" and String(block.get_meta("door_group_id", "")) == group_id
        var same_portal := portal_id != "" and String(block.get_meta("door_portal_id", "")) == portal_id
        if (same_group or same_portal or block == door) and bool(block.get_meta("open", false)):
            return true
    return false

func required_mira_captures_saved() -> bool:
    if not visual_required:
        return true
    var required := [
        "mira_go_home_start",
        "mira_route_departure",
        "mira_route_midpoint",
        "mira_at_home_door",
        "mira_home_door_open",
        "mira_inside_home_closed_door"
    ]
    var saved := {}
    for capture in visual_captures:
        if bool(capture.get("saved", false)):
            saved[String(capture.get("stage", ""))] = true
    for stage in required:
        if not bool(saved.get(stage, false)):
            return false
    return true

func morning_outside_target_matrix(capture_map := {}) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    for npc_id_value in MORNING_OUTSIDE_TARGETS:
        var npc_id := String(npc_id_value)
        var entry := npc_entry(npc_id)
        var found := not entry.is_empty()
        var home_status := strict_home_status(entry)
        var outside_home := found and not bool(home_status.get("strictInside", false))
        var stage := "morning_outside_%s" % safe_capture_id(npc_id)
        rows.append({
            "id": npc_id,
            "name": String(entry.get("name", "")) if found else "",
            "found": found,
            "outsideOwnHome": outside_home,
            "stage": stage,
            "captureSaved": bool(capture_map.get(npc_id, false)),
            "strictHome": home_status,
            "summary": npc_summary(entry) if found else {}
        })
    return rows

func morning_targets_outside(rows: Array[Dictionary]) -> bool:
    if rows.size() != MORNING_OUTSIDE_TARGETS.size():
        return false
    for row in rows:
        if not bool(row.get("found", false)) or not bool(row.get("outsideOwnHome", false)):
            return false
    return true

func morning_outside_captures_saved(capture_map: Dictionary) -> bool:
    for npc_id_value in MORNING_OUTSIDE_TARGETS:
        if not bool(capture_map.get(String(npc_id_value), false)):
            return false
    return true

func capture_names() -> Array[String]:
    var names: Array[String] = []
    for capture in visual_captures:
        names.append(String(capture.get("stage", "")))
    return names

func observe_night_matrix_until_ready(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        if night_matrix_rows_ready(npc_schedule_matrix()):
            settled_frames += 1
        else:
            settled_frames = 0
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("night_matrix_%03d" % frame)
            sample_mira("night_matrix_%03d" % frame)
            route_order_timeline.append(route_order_sample("night_matrix_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("night_matrix_%03d" % frame)
        if settled_frames >= 30:
            break

func night_matrix_rows_ready(rows: Array) -> bool:
    if rows.is_empty():
        return false
    for row_value in rows:
        if not (row_value is Dictionary):
            return false
        var row: Dictionary = row_value
        var strict_inside := bool(row.get("strictInsideHome", false))
        var is_guard := bool(row.get("nightGuard", false))
        if is_guard:
            if strict_inside:
                return false
        elif not strict_inside:
            return false
    return true

func validate_night_matrix() -> Dictionary:
    var rows := npc_schedule_matrix()
    var failures: Array[Dictionary] = []
    for index in range(rows.size()):
        var row: Dictionary = rows[index]
        var npc_id := String(row.get("id", ""))
        var strict_inside := bool(row.get("strictInsideHome", false))
        var is_guard := bool(row.get("nightGuard", false))
        var goal: Dictionary = row.get("activeMotionGoal", {}) if row.get("activeMotionGoal", {}) is Dictionary else {}
        var goal_kind := String(goal.get("goalKind", ""))
        var route_status := String(row.get("routeStatus", ""))
        var passed := false
        var reason := ""
        if is_guard:
            passed = not strict_inside and (goal_kind == "guard" or route_status in ["moving", "arrived", "pending", "waiting"])
            reason = "guard_on_duty_or_en_route" if passed else "guard_not_on_duty"
        else:
            passed = strict_inside
            reason = "non_guard_inside" if passed else "non_guard_not_strictly_inside"
        row["nightMatrixPassed"] = passed
        row["nightMatrixReason"] = reason
        rows[index] = row
        if not passed:
            failures.append({
                "id": npc_id,
                "reason": reason,
                "nightGuard": is_guard,
                "canFight": bool(row.get("canFight", false)),
                "cell": row.get("cell", []),
                "homeCell": row.get("homeCell", []),
                "porchCell": row.get("porchCell", []),
                "homeRouteIndex": int(row.get("homeRouteIndex", 0)),
                "homeRouteCount": int(row.get("homeRouteCount", 0)),
                "homeActiveTargetCell": row.get("homeActiveTargetCell", []),
                "routeStatus": route_status,
                "routeReason": String(row.get("routeReason", "")),
                "goalKind": goal_kind
            })
    var matrix := {
        "passed": failures.is_empty(),
        "failures": failures,
        "rows": rows
    }
    report_data["nightGuardNonGuardMatrix"] = matrix
    if not failures.is_empty():
        add_failure("night_matrix_invalid", JSON.stringify(failures))
    else:
        results.append({ "name": "night_guard_non_guard_matrix", "passed": true, "details": "rows=%d" % rows.size() })
    return matrix

func attempt_sleep_before_repair(tutorial) -> void:
    var bed := find_tutorial_bed()
    if bed == null:
        add_failure("starter_bed_missing", "could not find tutorial starter bed")
        return
    var before := tutorial_state_summary(tutorial)
    var route_reached := await walk_intro_path_to_starter_bed(tutorial, "bed_before_repair_route")
    if not route_reached:
        return
    var bed_used := await use_bed_with_real_action(bed, "bed_before_repair", 10.0)
    if not bed_used:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after := tutorial_state_summary(tutorial)
    var blocked := not bool(before.get("repairComplete", false)) and not bool(after.get("bedUsed", false)) and not bool(main.get("sleep_transition_active"))
    sleep_timeline.append({
        "label": "before_repair",
        "blocked": blocked,
        "before": before,
        "after": after,
        "sleepTransitionActive": bool(main.get("sleep_transition_active"))
    })
    if not blocked:
        add_failure("sleep_not_blocked_before_repair", JSON.stringify(sleep_timeline[sleep_timeline.size() - 1]))
    else:
        results.append({ "name": "sleep_blocked_before_repair", "passed": true, "details": "bed input did not sleep before repair" })

func run_repair_flow(tutorial) -> void:
    var chest := find_intro_repair_chest()
    if chest == null:
        add_failure("intro_repair_chest_missing", "could not find repair chest")
        return
    var chest_route_reached := await walk_intro_path_to_town_center(tutorial, "repair_chest_route")
    if not chest_route_reached:
        return
    var chest_used := await use_block_with_real_action(chest, "repair_chest", CELL * 1.75, 14.0)
    if not chest_used:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var utility_open := main.get("utility_system") != null and bool(main.get("utility_system").call("is_open"))
    var hud_open := main.get("hud") != null and bool(main.get("hud").call("is_utility_open"))
    var chest_state := tutorial_state_summary(tutorial)
    inventory_timeline.append({ "label": "repair_chest_open", "utilityOpen": utility_open, "hudOpen": hud_open, "tutorialState": chest_state, "inventory": inventory_totals() })
    if not utility_open or not hud_open or not bool(chest_state.get("repairChestOpened", false)):
        add_failure("repair_chest_real_open_failed", JSON.stringify(inventory_timeline[inventory_timeline.size() - 1]))
        return
    await press_utility_slot(0, "take_logs")
    await press_utility_slot(1, "take_stones")
    await press_utility_slot(2, "take_berries")
    inventory_timeline.append({ "label": "repair_chest_withdrawn", "inventory": inventory_totals(), "chest": chest_storage_summary(chest) })
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)

    var workbench := nearest_block("workbench", player.global_position)
    if workbench == null:
        add_failure("workbench_missing_for_repair_crafting", "could not find generated tutorial town workbench")
        return
    await walk_near(workbench.global_position, CELL * 1.65, 14.0, "walking_to_workbench")
    aim_at(workbench.global_position + Vector3(0.0, CELL * 0.6, 0.0))
    dispatch_key(KEY_I, true)
    dispatch_key(KEY_I, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var hud = main.get("hud")
    if hud == null or not bool(hud.call("is_inventory_open")):
        add_failure("inventory_not_open_for_repair_crafting", "inventory HUD did not open near workbench")
        return
    await press_craft_button("woodBlock", "craft_wood_block_1")
    await press_craft_button("woodBlock", "craft_wood_block_2")
    await press_craft_button("torch", "craft_torches")
    inventory_timeline.append({ "label": "repair_items_crafted", "inventory": inventory_totals() })
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)

    var raw_state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var targets: Dictionary = raw_state.get("introRepairTargets", {}) if raw_state.get("introRepairTargets", {}) is Dictionary else {}
    var fence_targets: Array = targets.get("fence", [])
    var lamp_targets: Array = targets.get("lamps", [])
    var town_center := intro_state_cell(tutorial, "townCenter", flat_cell(player.global_position))
    var failures_before_repair := failure_reasons.size()
    for north_side in [true, false]:
        if not north_side:
            var bypass_reached := await walk_to_south_repair_bypass(town_center)
            if not bypass_reached:
                return
        for index in repair_target_indices(fence_targets.size(), north_side):
            if fence_targets[index] is Vector2i:
                var fence_cell: Vector2i = fence_targets[index]
                if (fence_cell.y <= town_center.y) == north_side:
                    await place_repair_item("woodBlock", fence_cell, "repair_fence_%02d" % index, tutorial)
                    if failure_reasons.size() > failures_before_repair:
                        return
        for index in repair_target_indices(lamp_targets.size(), north_side):
            if lamp_targets[index] is Vector2i:
                var lamp_cell: Vector2i = lamp_targets[index]
                if (lamp_cell.y <= town_center.y) == north_side:
                    await place_repair_item("torch", lamp_cell, "repair_lamp_%02d" % index, tutorial)
                    if failure_reasons.size() > failures_before_repair:
                        return
    var final_state := tutorial_state_summary(tutorial)
    if not bool(final_state.get("repairComplete", false)):
        add_failure("repair_not_completed_by_real_placements", JSON.stringify({
            "state": final_state,
            "placements": repair_placement_events,
            "inventory": inventory_totals()
        }))
    else:
        results.append({ "name": "repair_completed_by_real_placements", "passed": true, "details": "placements=%d" % repair_placement_events.size() })

func attempt_sleep_after_repair(tutorial) -> void:
    var bed := find_tutorial_bed()
    if bed == null:
        add_failure("starter_bed_missing_after_repair", "could not find tutorial starter bed")
        return
    var before := tutorial_state_summary(tutorial)
    var bed_route_reached := await walk_intro_path_to_starter_bed(tutorial, "bed_after_repair_route")
    if not bed_route_reached:
        return
    var bed_used := await use_bed_with_real_action(bed, "bed_after_repair", 12.0)
    if not bed_used:
        return
    await wait_physics_frames(150)
    var after := tutorial_state_summary(tutorial)
    var slept := bool(after.get("bedUsed", false)) and float(main.get("time_of_day")) < 0.35
    sleep_timeline.append({
        "label": "after_repair",
        "slept": slept,
        "before": before,
        "after": after,
        "sleepTransitionActive": bool(main.get("sleep_transition_active")),
        "timeOfDay": rounded(float(main.get("time_of_day")))
    })
    if not slept:
        add_failure("sleep_after_repair_failed", JSON.stringify(sleep_timeline[sleep_timeline.size() - 1]))
    else:
        results.append({ "name": "sleep_after_repair_reached_morning", "passed": true, "details": "timeOfDay=%.3f" % float(main.get("time_of_day")) })

func observe_morning_npcs_and_foragers(seconds: float) -> void:
    var before_niko := npc_entry("niko")
    var before_runs := int(before_niko.get("jobRuns", 0))
    var before_hunger := float(before_niko.get("hunger", 0.0))
    var selected_object_id := ""
    var reservation_id := ""
    var approach_slot_id := ""
    var observed_departures := {}
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    for frame in range(frame_count):
        await get_tree().physics_frame
        if frame % SAMPLE_EVERY_FRAMES == 0:
            var rows := npc_schedule_matrix()
            morning_departure_matrix = rows
            for row in rows:
                var npc_id := String(row.get("id", ""))
                if npc_id == "":
                    continue
                if not observed_departures.has(npc_id):
                    observed_departures[npc_id] = { "id": npc_id, "leftHome": false, "samples": 0 }
                var departure: Dictionary = observed_departures[npc_id]
                departure["samples"] = int(departure.get("samples", 0)) + 1
                if not bool(row.get("strictInsideHome", false)):
                    departure["leftHome"] = true
                observed_departures[npc_id] = departure
            var niko := npc_entry("niko")
            if not niko.is_empty():
                var niko_row := niko_forage_row(niko, "morning_%03d" % frame)
                niko_timeline.append(niko_row)
                if selected_object_id == "" and String(niko.get("jobObjectId", "")) != "":
                    selected_object_id = String(niko.get("jobObjectId", ""))
                if reservation_id == "" and String(niko.get("jobReservationId", "")) != "":
                    reservation_id = String(niko.get("jobReservationId", ""))
                if approach_slot_id == "" and String(niko.get("jobApproachSlotId", "")) != "":
                    approach_slot_id = String(niko.get("jobApproachSlotId", ""))
                if int(niko.get("jobRuns", 0)) > before_runs:
                    break
            mark_progress("morning_%03d" % frame)
    var final_niko := npc_entry("niko")
    var final_runs := int(final_niko.get("jobRuns", 0))
    var final_hunger := float(final_niko.get("hunger", 0.0))
    var personal_inventory: Dictionary = final_niko.get("personalInventory", {}) if final_niko.get("personalInventory", {}) is Dictionary else {}
    niko_proof = {
        "selectedObjectId": selected_object_id,
        "reservationId": reservation_id,
        "approachSlot": approach_slot_id,
        "routeStatus": String(final_niko.get("routeStatus", "")),
        "routeReason": String(final_niko.get("routeReason", "")),
        "jobPhase": String(final_niko.get("jobPhase", "")),
        "jobRunsBefore": before_runs,
        "jobRunsAfter": final_runs,
        "hungerBefore": rounded(before_hunger),
        "hungerAfter": rounded(final_hunger),
        "personalInventory": personal_inventory.duplicate(true),
        "timeline": niko_timeline,
        "departureObservations": observed_departures
    }
    var forage_complete := final_runs > before_runs
    var route_proof := selected_object_id != "" and reservation_id != "" and approach_slot_id != ""
    if not route_proof:
        add_failure("niko_forager_route_proof_missing", JSON.stringify(niko_proof))
    elif not forage_complete:
        add_failure("niko_forager_cycle_not_completed", JSON.stringify(niko_proof))
    else:
        results.append({ "name": "niko_real_forage_cycle_completed", "passed": true, "details": "object=%s reservation=%s slot=%s runs=%d->%d" % [selected_object_id, reservation_id, approach_slot_id, before_runs, final_runs] })

func run_day_one_tutorial(tutorial) -> void:
    var initial_inventory := inventory_totals()
    day_one_timeline.append({
        "label": "day_one_start",
        "time": rounded(elapsed),
        "tutorial": tutorial_state_summary(tutorial),
        "completedSteps": tutorial_completed_steps(tutorial),
        "inventory": initial_inventory
    })
    report_data["dayOneRepairLeftoverInventory"] = initial_inventory
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_day_one_wake",
            null,
            { "tutorial": tutorial_state_summary(tutorial), "inventory": initial_inventory }
        )

    await talk_to_tutorial_npc("mira", "day_one_mira_briefing", 52.0)
    if failed:
        return
    if not tutorial_step_completed(tutorial, "miraMorningBriefing"):
        add_failure("day_one_mira_briefing_not_completed", JSON.stringify(day_one_snapshot(tutorial)))
        return
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_day_one_mira_briefing", null, day_one_snapshot(tutorial))

    await gather_resource_from_generated_prop("berries", "", 2, "day_one_gather_berries", 80.0)
    if failed:
        return
    await talk_to_tutorial_npc("niko", "day_one_niko_food", 120.0)
    if failed:
        return
    if not tutorial_step_completed(tutorial, "nikoBerries"):
        add_failure("day_one_niko_food_not_completed", JSON.stringify(day_one_snapshot(tutorial)))
        return
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_day_one_niko_food", null, day_one_snapshot(tutorial))

    await talk_to_tutorial_npc("rowan", "day_one_rowan_intro", 52.0)
    if failed:
        return
    await craft_recipe_at_workbench("woodenAxe", "day_one_craft_wooden_axe")
    if failed:
        return
    await talk_to_tutorial_npc("rowan", "day_one_rowan_axe_ready", 38.0)
    if failed:
        return
    if not tutorial_step_completed(tutorial, "rowanLogs"):
        await gather_resource_from_generated_prop("logs", "woodenAxe", 4, "day_one_gather_logs", 95.0)
        if failed:
            return
        await talk_to_tutorial_npc("rowan", "day_one_rowan_logs_ready", 38.0)
        if failed:
            return
    else:
        record_day_one_step_already_completed("day_one_rowan_logs_already_completed", tutorial)
    await craft_recipe_at_workbench("woodenPickaxe", "day_one_craft_wooden_pickaxe")
    if failed:
        return
    await talk_to_tutorial_npc("rowan", "day_one_rowan_pickaxe_ready", 38.0)
    if failed:
        return
    if not tutorial_step_completed(tutorial, "rowanStones"):
        await gather_resource_from_generated_prop("stones", "woodenPickaxe", 4, "day_one_gather_stones", 95.0)
        if failed:
            return
        await talk_to_tutorial_npc("rowan", "day_one_rowan_stones_ready", 38.0)
        if failed:
            return
    else:
        record_day_one_step_already_completed("day_one_rowan_stones_already_completed", tutorial)
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_day_one_rowan_tools", null, day_one_snapshot(tutorial))

    await talk_to_tutorial_npc("sera", "day_one_sera_intro", 52.0)
    if failed:
        return
    await craft_recipe_at_workbench("woodenSword", "day_one_craft_wooden_sword")
    if failed:
        return
    await talk_to_tutorial_npc("sera", "day_one_sera_weapon_ready", 38.0)
    if failed:
        return
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_day_one_ready", null, day_one_snapshot(tutorial))

    var steps := tutorial_completed_steps(tutorial)
    var required_steps := ["miraMorningBriefing", "nikoBerries", "rowanAxe", "rowanLogs", "rowanPickaxe", "rowanStones", "rowanBlocks", "seraWeapon", "readyForWilds"]
    var missing_steps := []
    for step_id in required_steps:
        if not steps.has(step_id):
            missing_steps.append(step_id)
    var berries_gathered_ok := resource_gather_delta("berries") >= 2
    var rowan_logs_ok := resource_gather_delta("logs") >= 4 or steps.has("rowanLogs")
    var rowan_stones_ok := resource_gather_delta("stones") >= 4 or steps.has("rowanStones")
    var gathered_ok := berries_gathered_ok and rowan_logs_ok and rowan_stones_ok
    report_data["dayOneTutorialProof"] = day_one_snapshot(tutorial)
    report_data["dayOneResourceGatherEvents"] = resource_gather_events
    if not missing_steps.is_empty() or not gathered_ok:
        add_failure("day_one_tutorial_not_verified", JSON.stringify({
            "missingSteps": missing_steps,
            "gatheredOk": gathered_ok,
            "resourceRequirements": {
                "berriesGatheredOk": berries_gathered_ok,
                "rowanLogsOk": rowan_logs_ok,
                "rowanStonesOk": rowan_stones_ok
            },
            "resourceDeltas": {
                "berries": resource_gather_delta("berries"),
                "logs": resource_gather_delta("logs"),
                "stones": resource_gather_delta("stones")
            },
            "snapshot": day_one_snapshot(tutorial)
        }))
        return
    results.append({
        "name": "day_one_post_storm_tutorial_real_playthrough",
        "passed": true,
        "details": "steps=%s resource deltas berries/logs/stones=%d/%d/%d rowanLogsStep=%s rowanStonesStep=%s" % [
            JSON.stringify(required_steps),
            resource_gather_delta("berries"),
            resource_gather_delta("logs"),
            resource_gather_delta("stones"),
            str(steps.has("rowanLogs")),
            str(steps.has("rowanStones"))
        ]
    })

func run_final_rescue_tutorial(tutorial) -> void:
    var started_at := elapsed
    record_final_rescue_step("final_rescue_start", tutorial)
    if not tutorial_step_completed(tutorial, "readyForWilds"):
        add_failure("final_rescue_not_ready_for_wilds", JSON.stringify(final_rescue_snapshot(tutorial)))
        return

    await talk_to_tutorial_npc("mira", "final_rescue_mira_briefing", 70.0)
    if failed:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after_mira := final_rescue_state_summary(tutorial)
    record_final_rescue_step("final_rescue_mira_briefing", tutorial, { "state": after_mira })
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_mira_briefing", null, final_rescue_snapshot(tutorial))
    if not bool(after_mira.get("finalNightActive", false)) or int(after_mira.get("rescueRemaining", 0)) <= 0:
        add_failure("final_rescue_mira_did_not_start_final_night", JSON.stringify(after_mira))
        return
    var staged_hostiles := final_rescue_snapshot(tutorial)
    var staged_assertion := rescue_hostile_phase_assertion(staged_hostiles, "circle_niko", false, false)
    report_data["finalRescuePreBattleHostileProof"] = staged_assertion
    record_final_rescue_step("final_rescue_hostiles_staged_circling", tutorial, { "phaseProof": staged_assertion })
    if not bool(staged_assertion.get("ok", false)):
        add_failure("final_rescue_hostiles_not_staged_before_battle", JSON.stringify(staged_assertion))
        return

    await talk_to_tutorial_npc("sera", "final_rescue_sera_escort", 70.0)
    if failed:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after_sera := final_rescue_state_summary(tutorial)
    record_final_rescue_step("final_rescue_sera_escort_started", tutorial, { "state": after_sera })
    var escort_speed := final_rescue_speed_phase_snapshot("escort_outbound")
    final_rescue_speed_proofs.append(escort_speed)
    report_data["finalRescueSpeedProofs"] = final_rescue_speed_proofs
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_sera_escort", npc_target_position("sera"), final_rescue_snapshot(tutorial))
    if not bool(after_sera.get("rescueEscortStarted", false)):
        add_failure("final_rescue_sera_did_not_start_escort", JSON.stringify(after_sera))
        return
    if not bool((escort_speed.get("seraSprintToNiko", {}) as Dictionary).get("ok", false)):
        add_failure("final_rescue_sera_not_sprinting_to_niko", JSON.stringify(escort_speed))
        return

    var gate_opened := await open_final_rescue_gate(tutorial)
    if failed or not gate_opened:
        return

    var rescue_site := final_rescue_site(tutorial)
    if rescue_site == Vector3.ZERO:
        add_failure("final_rescue_site_missing", JSON.stringify(final_rescue_snapshot(tutorial)))
        return
    var reached_site := await walk_final_rescue_route_to_site(tutorial, rescue_site, CELL * 3.0, 95.0)
    record_final_rescue_step("final_rescue_site_arrival", tutorial, {
        "reachedSite": reached_site,
        "rescueSite": vec3(rescue_site),
        "player": vec3(player.global_position)
    })
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_site_arrival", rescue_site + Vector3(0.0, CELL * 0.85, 0.0), final_rescue_snapshot(tutorial))
    if not reached_site:
        add_failure("final_rescue_site_not_reached", JSON.stringify(final_rescue_snapshot(tutorial)))
        return
    var sera_approached := await wait_for_sera_rescue_approach(tutorial, rescue_site, 32.0)
    if full_player_pov_visual_mode() and sera_approached:
        await capture_player_pov_stage("player_pov_final_rescue_sera_at_site", npc_target_position("sera"), final_rescue_snapshot(tutorial))
    if not sera_approached:
        return
    var sera_attacked := await wait_for_sera_rescue_attack(tutorial, 12.0)
    if full_player_pov_visual_mode() and sera_attacked:
        await capture_player_pov_stage("player_pov_final_rescue_sera_attack", npc_target_position("sera"), final_rescue_snapshot(tutorial))
    if not sera_attacked:
        return
    var battle_assertion := rescue_hostile_battle_assertion(final_rescue_snapshot(tutorial))
    report_data["finalRescueBattleCommencedProof"] = battle_assertion
    record_final_rescue_step("final_rescue_battle_commenced", tutorial, { "phaseProof": battle_assertion })
    if not bool(battle_assertion.get("ok", false)):
        add_failure("final_rescue_battle_not_commenced_by_allowed_actor", JSON.stringify(battle_assertion))
        return
    await maybe_record_rescue_hostile_npc_target(tutorial, true)

    await defeat_rescue_hostiles_with_player_input(tutorial, 155.0)
    if failed:
        return
    if not report_data.has("finalRescueHostileNpcTargetProof"):
        add_failure("final_rescue_hostiles_did_not_target_npcs", JSON.stringify({
            "snapshot": final_rescue_snapshot(tutorial),
            "combatEvents": final_rescue_combat_events
        }))
        return
    var after_combat := final_rescue_state_summary(tutorial)
    record_final_rescue_step("final_rescue_hostiles_defeated", tutorial, { "state": after_combat })
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_combat_complete", npc_target_position("niko"), final_rescue_snapshot(tutorial))
    if int(after_combat.get("rescueRemaining", 0)) > 0:
        add_failure("final_rescue_hostiles_remaining_after_combat", JSON.stringify(after_combat))
        return

    await wait_for_final_rescue_return(tutorial, maxf(55.0, FINAL_RESCUE_TIMEOUT_SECONDS - (elapsed - started_at)))
    if failed:
        return
    await wait_for_final_rescue_normal_behavior(tutorial, 150.0)
    if failed:
        return
    var final_state := final_rescue_state_summary(tutorial)
    report_data["finalRescueProof"] = final_rescue_snapshot(tutorial)
    if not bool(final_state.get("finalNightComplete", false)):
        add_failure("final_rescue_not_completed", JSON.stringify(final_state))
        return
    if not tutorial_step_completed(tutorial, "finalNightComplete"):
        add_failure("final_rescue_step_missing", JSON.stringify(final_state))
        return
    results.append({
        "name": "tutorial_final_rescue_real_player_pov",
        "passed": true,
        "details": "Mira briefing, Sera escort, gate crossing, %d hostile defeats, Niko returned home, and Sera resumed guard duty through live player/NPC systems; captures=%s" % [
            int(final_state.get("finalNightDefeats", final_rescue_combat_events.size())),
            JSON.stringify(capture_names())
        ]
    })

func record_final_rescue_step(label: String, tutorial, extra: Dictionary = {}) -> void:
    var row := final_rescue_snapshot(tutorial)
    row["label"] = label
    row["time"] = rounded(elapsed)
    for key in extra.keys():
        row[key] = extra[key]
    final_rescue_timeline.append(row)
    report_data["finalRescueTimeline"] = final_rescue_timeline
    report_data["finalRescueCombatEvents"] = final_rescue_combat_events

func final_rescue_snapshot(tutorial) -> Dictionary:
    return {
        "state": final_rescue_state_summary(tutorial),
        "completedSteps": tutorial_completed_steps(tutorial),
        "inventory": inventory_totals(),
        "survival": survival_snapshot(),
        "mira": npc_summary(npc_entry("mira")) if not npc_entry("mira").is_empty() else {},
        "niko": npc_summary(npc_entry("niko")) if not npc_entry("niko").is_empty() else {},
        "sera": npc_summary(npc_entry("sera")) if not npc_entry("sera").is_empty() else {},
        "hostiles": rescue_hostile_summaries(),
        "hostileStats": hostile_stats_summary(),
        "combatEvents": final_rescue_combat_events.duplicate(true)
    }

func final_rescue_state_summary(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return {}
    var state: Dictionary = tutorial.call("state")
    return {
        "stage": String(state.get("tutorialStage", "")),
        "finalNightActive": bool(state.get("finalNightActive", false)),
        "finalNightComplete": bool(state.get("finalNightComplete", false)),
        "finalNightDefeats": int(state.get("finalNightDefeats", 0)),
        "rescueEscortStarted": bool(state.get("rescueEscortStarted", false)),
        "rescueReturning": bool(state.get("rescueReturning", false)),
        "rescueRemaining": int(state.get("rescueRemaining", 0)),
        "rescueRequired": int(state.get("rescueRequired", FINAL_RESCUE_MONSTER_COUNT)),
        "rescueSite": vec3(state.get("rescueSite", Vector3.ZERO)),
        "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0,
        "displayHour": rounded(clock_display_hour())
    }

func final_rescue_site(tutorial) -> Vector3:
    if tutorial == null or not tutorial.has_method("state"):
        return Vector3.ZERO
    var state: Dictionary = tutorial.call("state")
    var value = state.get("rescueSite", Vector3.ZERO)
    if value is Vector3:
        return value
    return Vector3.ZERO

func open_final_rescue_gate(tutorial) -> bool:
    var state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var town_center: Vector2i = state.get("townCenter", flat_cell(player.global_position))
    var gate_position := world_position_for_flat_cell(Vector2i(town_center.x + TUTORIAL_REPAIR_RADIUS_CELLS, town_center.y))
    var gate := nearest_block("door", gate_position)
    if gate == null or not is_instance_valid(gate):
        add_failure("final_rescue_gate_missing", JSON.stringify({
            "gatePosition": vec3(gate_position),
            "townCenter": vec2i(town_center)
        }))
        return false
    var reached := await walk_tutorial_route_near(gate.global_position, CELL * 1.65, 36.0, "walking_to_final_rescue_gate")
    if not reached:
        add_failure("final_rescue_gate_not_reached", JSON.stringify({
            "gate": block_summary(gate),
            "player": vec3(player.global_position)
        }))
        return false
    if not bool(gate.get_meta("open", false)):
        var hit := await aim_until_interaction_hit(gate, "final_rescue_gate")
        if not interaction_hit_matches_block(hit, gate):
            add_failure("final_rescue_gate_aim_miss", JSON.stringify({
                "gate": block_summary(gate),
                "hit": hit,
                "player": vec3(player.global_position)
            }))
            return false
        dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
        dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
        await wait_physics_frames(POST_ACTION_FRAMES)
    var opened := bool(gate.get_meta("open", false))
    record_final_rescue_step("final_rescue_gate_open", tutorial, {
        "gate": block_summary(gate),
        "opened": opened,
        "player": vec3(player.global_position)
    })
    if full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_gate_open", gate.global_position + Vector3(0.0, CELL * 0.75, 0.0), final_rescue_snapshot(tutorial))
    if not opened:
        add_failure("final_rescue_gate_did_not_open", JSON.stringify(block_summary(gate)))
        return false
    return true

func walk_final_rescue_route_to_site(tutorial, rescue_site: Vector3, stop_distance: float, timeout_seconds: float) -> bool:
    var state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var town_center: Vector2i = state.get("townCenter", flat_cell(player.global_position))
    var target_cell := flat_cell(rescue_site)
    var route_cells: Array[Vector2i] = [
        Vector2i(town_center.x + TUTORIAL_REPAIR_RADIUS_CELLS - 2, town_center.y),
        Vector2i(town_center.x + TUTORIAL_REPAIR_RADIUS_CELLS + 2, town_center.y),
        Vector2i(target_cell.x, town_center.y),
        target_cell
    ]
    var started_at := elapsed
    for index in range(route_cells.size()):
        var remaining := timeout_seconds - (elapsed - started_at)
        if remaining <= 0.0:
            return false
        var cell := route_cells[index]
        var waypoint_position := world_position_for_flat_cell(cell)
        var waypoint_stop := stop_distance if index == route_cells.size() - 1 else CELL * 1.2
        var reached := await walk_near(waypoint_position, waypoint_stop, minf(remaining, 28.0), "walking_final_rescue_route_%02d_%d_%d" % [index, cell.x, cell.y])
        var encounter_reached := player_near_active_rescue_fight(tutorial, rescue_site)
        record_final_rescue_step("final_rescue_route_%02d" % index, tutorial, {
            "cell": vec2i(cell),
            "reached": reached,
            "encounterReached": encounter_reached,
            "player": vec3(player.global_position)
        })
        if encounter_reached:
            report_data["finalRescuePlayerEncounterReachProof"] = final_rescue_snapshot(tutorial)
            return true
        if not reached:
            return false
    if flat_distance(player.global_position, rescue_site) <= stop_distance:
        return true
    var final_encounter_reached := player_near_active_rescue_fight(tutorial, rescue_site)
    if final_encounter_reached:
        report_data["finalRescuePlayerEncounterReachProof"] = final_rescue_snapshot(tutorial)
    return final_encounter_reached

func player_near_active_rescue_fight(tutorial, rescue_site: Vector3) -> bool:
    var row := final_rescue_snapshot(tutorial)
    if not rescue_hostiles_engaging_sera(row):
        return false
    var nearest := nearest_rescue_hostile_body(alive_rescue_hostile_bodies())
    if nearest != null and is_instance_valid(nearest) and flat_distance(player.global_position, nearest.global_position) <= CELL * 9.5:
        return true
    return flat_distance(player.global_position, rescue_site) <= CELL * 10.0

func wait_for_sera_rescue_approach(tutorial, rescue_site: Vector3, timeout_seconds: float) -> bool:
    var started_at := elapsed
    var saw_beyond_gate := false
    var best_distance := INF
    var best_row := {}
    while elapsed - started_at < timeout_seconds:
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES != 0:
            continue
        var row := final_rescue_sera_approach_snapshot(tutorial, rescue_site)
        row["label"] = "final_rescue_sera_approach_%03d" % final_rescue_timeline.size()
        row["time"] = rounded(elapsed)
        final_rescue_timeline.append(row)
        report_data["finalRescueTimeline"] = final_rescue_timeline
        saw_beyond_gate = saw_beyond_gate or bool(row.get("beyondEastGate", false))
        var distance := float(row.get("distanceToRescueSite", INF))
        if distance < best_distance:
            best_distance = distance
            best_row = row
        var engaged_at_rescue_edge := rescue_hostiles_engaging_sera(row)
        if saw_beyond_gate and bool(row.get("sprinting", false)) and (bool(row.get("nearRescueSite", false)) or engaged_at_rescue_edge):
            row["sawBeyondEastGate"] = saw_beyond_gate
            row["engagedAtRescueEdge"] = engaged_at_rescue_edge
            report_data["finalRescueSeraApproachProof"] = row
            record_final_rescue_step("final_rescue_sera_reached_rescue_site", tutorial, row)
            return true
        mark_progress("final_rescue_sera_approach")
    var failure := {
        "sawBeyondEastGate": saw_beyond_gate,
        "bestDistanceToRescueSite": rounded(best_distance),
        "bestRow": best_row,
        "snapshot": final_rescue_snapshot(tutorial)
    }
    report_data["finalRescueSeraApproachProof"] = failure
    add_failure("final_rescue_sera_did_not_approach_niko", JSON.stringify(failure))
    return false

func rescue_hostiles_engaging_sera(row: Dictionary) -> bool:
    var sera: Dictionary = row.get("sera", {}) if row.get("sera", {}) is Dictionary else {}
    if int(sera.get("guardShots", 0)) > 0 or int(sera.get("guardMeleeStrikes", 0)) > 0:
        return true
    if int(sera.get("hostileTargetedCount", 0)) > 0 or int(sera.get("hostileProjectileHits", 0)) > 0:
        return true
    var hostiles: Array = row.get("hostiles", []) if row.get("hostiles", []) is Array else []
    for hostile_value in hostiles:
        var hostile: Dictionary = hostile_value if hostile_value is Dictionary else {}
        if String(hostile.get("targetName", "")).to_lower().find("sera") >= 0:
            return true
    return false

func wait_for_sera_rescue_attack(tutorial, timeout_seconds: float) -> bool:
    var started_at := elapsed
    var best_row := {}
    while elapsed - started_at < timeout_seconds:
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES != 0:
            continue
        var entry := npc_entry("sera")
        var row := final_rescue_snapshot(tutorial)
        var sera_summary := npc_summary(entry) if not entry.is_empty() else {}
        row["label"] = "final_rescue_sera_attack_%03d" % final_rescue_timeline.size()
        row["time"] = rounded(elapsed)
        row["sera"] = sera_summary
        final_rescue_timeline.append(row)
        report_data["finalRescueTimeline"] = final_rescue_timeline
        best_row = row
        if int(sera_summary.get("guardShots", 0)) > 0 or int(sera_summary.get("guardMeleeStrikes", 0)) > 0:
            report_data["finalRescueSeraAttackProof"] = row
            record_final_rescue_step("final_rescue_sera_attacked_hostile", tutorial, row)
            return true
        mark_progress("final_rescue_sera_attack")
    var failure := {
        "snapshot": final_rescue_snapshot(tutorial),
        "lastRow": best_row
    }
    report_data["finalRescueSeraAttackProof"] = failure
    add_failure("final_rescue_sera_did_not_attack_hostile", JSON.stringify(failure))
    return false

func wait_for_rescue_hostile_npc_target(tutorial, timeout_seconds: float) -> bool:
    var started_at := elapsed
    var best_row := {}
    while elapsed - started_at < timeout_seconds:
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES != 0:
            continue
        var row := final_rescue_snapshot(tutorial)
        row["label"] = "final_rescue_hostile_npc_target_%03d" % final_rescue_timeline.size()
        row["time"] = rounded(elapsed)
        final_rescue_timeline.append(row)
        report_data["finalRescueTimeline"] = final_rescue_timeline
        best_row = row
        if rescue_hostiles_targeting_npcs(row):
            report_data["finalRescueHostileNpcTargetProof"] = row
            record_final_rescue_step("final_rescue_hostiles_targeted_npc", tutorial, row)
            return true
        mark_progress("final_rescue_hostile_npc_target")
    var failure := {
        "snapshot": final_rescue_snapshot(tutorial),
        "lastRow": best_row
    }
    report_data["finalRescueHostileNpcTargetProof"] = failure
    add_failure("final_rescue_hostiles_did_not_target_npcs", JSON.stringify(failure))
    return false

func maybe_record_rescue_hostile_npc_target(tutorial, capture_on_seen := false) -> bool:
    if report_data.has("finalRescueHostileNpcTargetProof"):
        return true
    var row := final_rescue_snapshot(tutorial)
    row["label"] = "final_rescue_hostile_npc_target_%03d" % final_rescue_timeline.size()
    row["time"] = rounded(elapsed)
    final_rescue_timeline.append(row)
    report_data["finalRescueTimeline"] = final_rescue_timeline
    if not rescue_hostiles_targeting_npcs(row):
        return false
    report_data["finalRescueHostileNpcTargetProof"] = row
    record_final_rescue_step("final_rescue_hostiles_targeted_npc", tutorial, row)
    if capture_on_seen and full_player_pov_visual_mode():
        await capture_player_pov_stage("player_pov_final_rescue_hostiles_target_npc", npc_target_position("sera"), final_rescue_snapshot(tutorial))
    return true

func rescue_hostiles_targeting_npcs(row: Dictionary) -> bool:
    var hostiles: Array = row.get("hostiles", [])
    for hostile_value in hostiles:
        var hostile: Dictionary = hostile_value if hostile_value is Dictionary else {}
        if String(hostile.get("targetKind", "")) in ["npc", "tutorial_npc"]:
            return true
    for npc_id in ["sera", "niko"]:
        var summary: Dictionary = row.get(npc_id, {}) if row.get(npc_id, {}) is Dictionary else {}
        if int(summary.get("hostileTargetedCount", 0)) > 0 or int(summary.get("hostileProjectileHits", 0)) > 0:
            return true
    var stats: Dictionary = row.get("hostileStats", {}) if row.get("hostileStats", {}) is Dictionary else {}
    return int(stats.get("hostileNpcTargetAttacks", 0)) > 0 or int(stats.get("hostileNpcTargetProjectiles", 0)) > 0

func rescue_hostile_phase_assertion(row: Dictionary, expected_phase: String, expected_damageable: bool, expected_can_attack: bool) -> Dictionary:
    var hostiles: Array = row.get("hostiles", [])
    var violations: Array[Dictionary] = []
    for hostile_value in hostiles:
        var hostile: Dictionary = hostile_value if hostile_value is Dictionary else {}
        var hostile_violation := {
            "name": String(hostile.get("name", "")),
            "phase": String(hostile.get("scriptedPhase", "")),
            "damageable": bool(hostile.get("damageable", true)),
            "canAttack": bool(hostile.get("canAttack", true)),
            "targetKind": String(hostile.get("targetKind", "")),
            "targetName": String(hostile.get("targetName", ""))
        }
        if (
            String(hostile.get("scriptedPhase", "")) != expected_phase
            or bool(hostile.get("damageable", true)) != expected_damageable
            or bool(hostile.get("canAttack", true)) != expected_can_attack
        ):
            violations.append(hostile_violation)
    return {
        "ok": hostiles.size() == FINAL_RESCUE_MONSTER_COUNT and violations.is_empty(),
        "requires": "%d rescue hostiles phase=%s damageable=%s canAttack=%s" % [
            FINAL_RESCUE_MONSTER_COUNT,
            expected_phase,
            str(expected_damageable),
            str(expected_can_attack)
        ],
        "count": hostiles.size(),
        "violations": violations,
        "hostiles": hostiles
    }

func rescue_hostile_battle_assertion(row: Dictionary) -> Dictionary:
    var hostiles: Array = row.get("hostiles", [])
    var phase_violations: Array[Dictionary] = []
    var invalid_starters: Array[Dictionary] = []
    for hostile_value in hostiles:
        var hostile: Dictionary = hostile_value if hostile_value is Dictionary else {}
        if (
            String(hostile.get("scriptedPhase", "")) != "battle"
            or not bool(hostile.get("damageable", false))
            or not bool(hostile.get("canAttack", false))
        ):
            phase_violations.append({
                "name": String(hostile.get("name", "")),
                "phase": String(hostile.get("scriptedPhase", "")),
                "damageable": bool(hostile.get("damageable", false)),
                "canAttack": bool(hostile.get("canAttack", false))
            })
        var started_by := String(hostile.get("battleStartedBy", ""))
        if not (started_by in ["player", "sera"]):
            invalid_starters.append({
                "name": String(hostile.get("name", "")),
                "battleStartedBy": started_by,
                "phase": String(hostile.get("scriptedPhase", ""))
            })
    var stats: Dictionary = row.get("hostileStats", {}) if row.get("hostileStats", {}) is Dictionary else {}
    return {
        "ok": hostiles.size() > 0 and phase_violations.is_empty() and invalid_starters.is_empty() and int(stats.get("scriptedBattleStarts", 0)) > 0,
        "requires": "all remaining rescue hostiles entered battle, became damageable, can attack, and battleStartedBy is player or sera",
        "remainingCount": hostiles.size(),
        "phaseViolations": phase_violations,
        "invalidStarters": invalid_starters,
        "hostileStats": stats
    }

func final_rescue_sera_approach_snapshot(tutorial, rescue_site: Vector3) -> Dictionary:
    var state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var town_center: Vector2i = state.get("townCenter", flat_cell(player.global_position))
    var entry := npc_entry("sera")
    var body := entry.get("body") as Node3D
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    var cell := flat_cell(position)
    var beyond_gate := cell.x > town_center.x + TUTORIAL_REPAIR_RADIUS_CELLS
    var outside_perimeter := absi(cell.x - town_center.x) > TUTORIAL_REPAIR_RADIUS_CELLS or absi(cell.y - town_center.y) > TUTORIAL_REPAIR_RADIUS_CELLS
    var distance := flat_distance(position, rescue_site) if body != null and is_instance_valid(body) else INF
    var summary := npc_summary(entry) if not entry.is_empty() else {}
    return {
        "state": final_rescue_state_summary(tutorial),
        "townCenter": vec2i(town_center),
        "eastGateCell": vec2i(Vector2i(town_center.x + TUTORIAL_REPAIR_RADIUS_CELLS, town_center.y)),
        "rescueSite": vec3(rescue_site),
        "seraCell": vec2i(cell),
        "seraPosition": vec3(position),
        "beyondEastGate": beyond_gate,
        "outsidePerimeter": outside_perimeter,
        "nearRescueSite": distance <= CELL * 4.2,
        "distanceToRescueSite": rounded(distance),
        "sprinting": String(summary.get("npcSpeedMode", "")) == "sprinting" or String(summary.get("scriptedSpeedMode", "")) == "sprinting",
        "sera": summary
    }

func defeat_rescue_hostiles_with_player_input(tutorial, timeout_seconds: float) -> void:
    var selected_sword := await select_hotbar_item("woodenSword")
    if not selected_sword:
        add_failure("final_rescue_sword_not_selectable", JSON.stringify({
            "inventory": inventory_totals(),
            "active": active_stack_summary()
        }))
        return
    var started_at := elapsed
    var captured_combat := false
    var previous_remaining := alive_rescue_hostile_bodies().size()
    while elapsed - started_at < timeout_seconds:
        var bodies := alive_rescue_hostile_bodies()
        if bodies.is_empty():
            break
        await maybe_use_field_ration_for_rescue()
        var target := nearest_rescue_hostile_body(bodies)
        if target == null or not is_instance_valid(target):
            await wait_physics_frames(POST_ACTION_FRAMES)
            continue
        await maybe_record_rescue_hostile_npc_target(tutorial, true)
        var reached := await walk_near(target.global_position, CELL * 1.35, 8.0, "walking_to_final_rescue_hostile")
        var defeated := await attack_rescue_hostile_with_player_input(target, "final_rescue_hostile_%02d" % final_rescue_combat_events.size())
        var remaining := alive_rescue_hostile_bodies().size()
        record_final_rescue_step("final_rescue_combat_%02d" % final_rescue_combat_events.size(), tutorial, {
            "targetReached": reached,
            "defeated": defeated,
            "remainingBefore": previous_remaining,
            "remainingAfter": remaining
        })
        if full_player_pov_visual_mode() and not captured_combat:
            captured_combat = await capture_player_pov_stage("player_pov_final_rescue_combat", npc_target_position("niko"), final_rescue_snapshot(tutorial))
        previous_remaining = remaining
        if survival_health() <= 0.0:
            add_failure("final_rescue_player_collapsed", JSON.stringify(final_rescue_snapshot(tutorial)))
            return
    var remaining_after := alive_rescue_hostile_bodies().size()
    if remaining_after > 0:
        add_failure("final_rescue_hostiles_not_defeated", JSON.stringify({
            "remaining": remaining_after,
            "snapshot": final_rescue_snapshot(tutorial)
        }))

func attack_rescue_hostile_with_player_input(target: Node3D, label: String) -> bool:
    var started_at := elapsed
    var attempts := 0
    while elapsed - started_at < 15.0 and hostile_body_alive(target):
        var target_position := target.global_position + Vector3(0.0, CELL * 0.65, 0.0)
        if flat_distance(player.global_position, target.global_position) > CELL * 1.55:
            await walk_near(target.global_position, CELL * 1.25, 3.0, "closing_%s" % label)
        aim_at(target_position)
        await wait_physics_frames(3)
        var before_hit := combat_hit_summary()
        dispatch_mouse_button(MOUSE_BUTTON_LEFT, true)
        await wait_physics_frames(2)
        dispatch_mouse_button(MOUSE_BUTTON_LEFT, false)
        await wait_physics_frames(12)
        var alive_after := hostile_body_alive(target)
        attempts += 1
        final_rescue_combat_events.append({
            "label": label,
            "attempt": attempts,
            "time": rounded(elapsed),
            "hitBeforeAttack": before_hit,
            "targetPosition": vec3(target.global_position) if is_instance_valid(target) else [],
            "aliveAfter": alive_after,
            "remainingAfter": alive_rescue_hostile_bodies().size(),
            "survival": survival_snapshot(),
            "activeItem": active_stack_summary()
        })
        report_data["finalRescueCombatEvents"] = final_rescue_combat_events
        if not alive_after:
            return true
    return not hostile_body_alive(target)

func wait_for_final_rescue_return(tutorial, timeout_seconds: float) -> void:
    var started_at := elapsed
    var saw_returning := false
    var captured_returning := false
    var niko_sprint_home_ok := false
    var sera_walk_home_ok := false
    var return_stall_samples := { "niko": 0, "sera": 0 }
    while elapsed - started_at < timeout_seconds:
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES != 0:
            continue
        var state := final_rescue_state_summary(tutorial)
        var row := final_rescue_snapshot(tutorial)
        row["label"] = "final_rescue_return_%03d" % final_rescue_timeline.size()
        row["time"] = rounded(elapsed)
        final_rescue_timeline.append(row)
        report_data["finalRescueTimeline"] = final_rescue_timeline
        if final_rescue_timeline.size() % 12 == 0:
            save_live_report_checkpoint("final_rescue_return")
        var stall_failure := final_rescue_return_stall_failure(row, return_stall_samples)
        if not stall_failure.is_empty():
            add_failure("final_rescue_return_actor_stalled", JSON.stringify(stall_failure))
            return
        if bool(state.get("rescueReturning", false)):
            saw_returning = true
            var speed_proof := final_rescue_speed_phase_snapshot("return_home")
            final_rescue_speed_proofs.append(speed_proof)
            report_data["finalRescueSpeedProofs"] = final_rescue_speed_proofs
            niko_sprint_home_ok = niko_sprint_home_ok or bool((speed_proof.get("nikoSprintHome", {}) as Dictionary).get("ok", false))
            sera_walk_home_ok = sera_walk_home_ok or bool((speed_proof.get("seraWalkHome", {}) as Dictionary).get("ok", false))
            if full_player_pov_visual_mode() and not captured_returning:
                captured_returning = await capture_player_pov_stage("player_pov_final_rescue_niko_returning", npc_target_position("niko"), final_rescue_snapshot(tutorial))
        if bool(state.get("finalNightComplete", false)):
            if not niko_sprint_home_ok or not sera_walk_home_ok:
                add_failure("final_rescue_return_speed_modes_not_verified", JSON.stringify({
                    "nikoSprintHomeOk": niko_sprint_home_ok,
                    "seraWalkHomeOk": sera_walk_home_ok,
                    "proofs": final_rescue_speed_proofs
                }))
                return
            if full_player_pov_visual_mode():
                await capture_player_pov_stage("player_pov_final_rescue_complete", npc_target_position("niko"), final_rescue_snapshot(tutorial))
            return
        mark_progress("final_rescue_returning")
    if not saw_returning:
        add_failure("final_rescue_return_never_started", JSON.stringify(final_rescue_snapshot(tutorial)))
        return
    if not niko_sprint_home_ok or not sera_walk_home_ok:
        add_failure("final_rescue_return_speed_modes_not_verified", JSON.stringify({
            "nikoSprintHomeOk": niko_sprint_home_ok,
            "seraWalkHomeOk": sera_walk_home_ok,
            "proofs": final_rescue_speed_proofs
        }))
        return
    add_failure("final_rescue_party_did_not_return", JSON.stringify(final_rescue_snapshot(tutorial)))

func final_rescue_return_stall_failure(row: Dictionary, counters: Dictionary) -> Dictionary:
    for npc_id in ["niko", "sera"]:
        var summary: Dictionary = row.get(npc_id, {}) if row.get(npc_id, {}) is Dictionary else {}
        if summary.is_empty():
            continue
        var done := final_rescue_return_actor_done(npc_id, summary)
        var moved := float(summary.get("lastMoveDistance", 0.0))
        var route_status := String(summary.get("routeStatus", ""))
        var active_return := not done and route_status != "arrived"
        if active_return and moved <= 0.005:
            counters[npc_id] = int(counters.get(npc_id, 0)) + 1
        else:
            counters[npc_id] = 0
        if int(counters.get(npc_id, 0)) >= FINAL_RESCUE_RETURN_STALL_SAMPLES:
            return {
                "npcId": npc_id,
                "sampleCount": int(counters.get(npc_id, 0)),
                "seconds": rounded(float(counters.get(npc_id, 0)) * float(SAMPLE_EVERY_FRAMES) / float(Engine.physics_ticks_per_second)),
                "routeStatus": route_status,
                "routeReason": String(summary.get("routeReason", "")),
                "cell": summary.get("cell", []),
                "position": summary.get("position", []),
                "lastMoveDistance": moved,
                "motorRequestedVelocity": summary.get("motorRequestedVelocity", []),
                "motorBlockedContactKind": String(summary.get("motorBlockedContactKind", "")),
                "motorBlockedContactName": String(summary.get("motorBlockedContactName", "")),
                "corridorFollow": summary.get("corridorFollow", {}),
                "corridorProgress": summary.get("corridorProgress", {}),
                "row": row
            }
    return {}

func final_rescue_return_actor_done(npc_id: String, summary: Dictionary) -> bool:
    if npc_id == "niko":
        return bool(summary.get("strictInsideHome", false))
    if npc_id == "sera":
        return String(summary.get("routeStatus", "")) == "arrived"
    return false

func final_rescue_speed_phase_snapshot(label: String) -> Dictionary:
    var sera_sprint := npc_speed_mode_assertion("sera", "sprinting")
    var niko_sprint := npc_speed_mode_assertion("niko", "sprinting")
    var sera_walk := npc_speed_mode_assertion("sera", "walking")
    return {
        "label": label,
        "time": rounded(elapsed),
        "seraSprintToNiko": sera_sprint,
        "nikoSprintHome": niko_sprint,
        "seraWalkHome": sera_walk,
        "niko": npc_summary(npc_entry("niko")) if not npc_entry("niko").is_empty() else {},
        "sera": npc_summary(npc_entry("sera")) if not npc_entry("sera").is_empty() else {}
    }

func npc_speed_mode_assertion(npc_id: String, expected_mode: String) -> Dictionary:
    var entry := npc_entry(npc_id)
    if entry.is_empty():
        return { "ok": false, "npcId": npc_id, "expected": expected_mode, "reason": "entry_missing" }
    var summary := npc_summary(entry)
    var mode := String(summary.get("npcSpeedMode", ""))
    var scripted_mode := String(summary.get("scriptedSpeedMode", ""))
    var ok := mode == expected_mode or scripted_mode == expected_mode
    return {
        "ok": ok,
        "npcId": npc_id,
        "expected": expected_mode,
        "mode": mode,
        "scriptedMode": scripted_mode,
        "rushing": bool(summary.get("npcRushing", false)),
        "speed": summary.get("npcSpeed", 0.0),
        "scriptedOrder": summary.get("scriptedOrder", {}),
        "routeStatus": String(summary.get("routeStatus", "")),
        "lastMoveDistance": summary.get("lastMoveDistance", 0.0),
        "motorRequestedVelocity": summary.get("motorRequestedVelocity", [])
    }

func wait_for_final_rescue_normal_behavior(tutorial, timeout_seconds: float) -> void:
    var started_at := elapsed
    var settled_samples := 0
    var captured_niko_home := false
    var captured_sera_guard := false
    while elapsed - started_at < timeout_seconds:
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES != 0:
            continue
        var row := final_rescue_normal_behavior_snapshot(tutorial)
        row["label"] = "final_rescue_normal_behavior_%03d" % final_rescue_normal_behavior_timeline.size()
        row["time"] = rounded(elapsed)
        final_rescue_normal_behavior_timeline.append(row)
        report_data["finalRescueNormalBehaviorTimeline"] = final_rescue_normal_behavior_timeline
        if final_rescue_normal_behavior_timeline.size() % 12 == 0:
            save_live_report_checkpoint("final_rescue_normal_behavior")
        var niko_ok := bool((row.get("nikoNormal", {}) as Dictionary).get("ok", false))
        var sera_ok := bool((row.get("seraNormal", {}) as Dictionary).get("ok", false))
        if visual_required and niko_ok and not captured_niko_home:
            captured_niko_home = await capture_npc_home_stage(npc_entry("niko"), "final_rescue_niko_home_normal")
        if visual_required and sera_ok and not captured_sera_guard:
            captured_sera_guard = await capture_npc_outside_stage(npc_entry("sera"), "final_rescue_sera_guard_normal")
        var visual_ok := (not visual_required) or (captured_niko_home and captured_sera_guard)
        if niko_ok and sera_ok and visual_ok:
            settled_samples += 1
        else:
            settled_samples = 0
        if settled_samples >= 5:
            row["nikoHomeCaptureSaved"] = captured_niko_home
            row["seraGuardCaptureSaved"] = captured_sera_guard
            report_data["finalRescueNormalBehaviorProof"] = row
            record_final_rescue_step("final_rescue_normal_behavior_restored", tutorial, row)
            return
        mark_progress("final_rescue_normal_behavior")
    var final_row := final_rescue_normal_behavior_snapshot(tutorial)
    final_row["elapsedWaiting"] = rounded(elapsed - started_at)
    report_data["finalRescueNormalBehaviorProof"] = final_row
    add_failure("final_rescue_normal_behavior_not_restored", JSON.stringify(final_row))

func final_rescue_normal_behavior_snapshot(tutorial) -> Dictionary:
    var niko := npc_entry("niko")
    var sera := npc_entry("sera")
    return {
        "state": final_rescue_state_summary(tutorial),
        "nikoNormal": final_rescue_niko_home_assertion(niko),
        "seraNormal": final_rescue_sera_guard_assertion(sera),
        "niko": npc_summary(niko) if not niko.is_empty() else {},
        "sera": npc_summary(sera) if not sera.is_empty() else {},
        "captures": capture_names()
    }

func final_rescue_niko_home_assertion(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var strict := strict_home_status(entry)
    var door := npc_home_door(entry)
    var door_closed := door == null or not bool(door.get_meta("open", false))
    var scripted := body_valid and body.has_meta("npc_scripted_target")
    var force_hold := body_valid and bool(body.get_meta("npc_force_hold", false))
    var stranded := body_valid and bool(body.get_meta("npc_rescue_stranded", false))
    var goal: Dictionary = entry.get("activeMotionGoal", {}) if entry.get("activeMotionGoal", {}) is Dictionary else {}
    var ok := bool(strict.get("strictInside", false)) and door_closed and not scripted and not force_hold and not stranded
    return {
        "ok": ok,
        "requires": "strict home interior, closed home door, no scripted target, no force hold, no rescue stranded flag",
        "strictHome": strict,
        "doorClosed": door_closed,
        "door": block_summary(door),
        "scriptedTarget": scripted,
        "forceHold": force_hold,
        "rescueStranded": stranded,
        "goalKind": String(goal.get("goalKind", "")),
        "goalReason": String(goal.get("reason", "")),
        "routeStatus": String(entry.get("routeStatus", "")),
        "cell": vec2i(flat_cell(body.global_position)) if body_valid else []
    }

func final_rescue_sera_guard_assertion(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var guard_cell: Vector2i = entry.get("guardCell", entry.get("routeFallbackCell", Vector2i.ZERO))
    var guard_position := world_position_for_flat_cell(guard_cell)
    var distance_to_guard := flat_distance(body.global_position, guard_position) if body_valid else INF
    var goal: Dictionary = entry.get("activeMotionGoal", {}) if entry.get("activeMotionGoal", {}) is Dictionary else {}
    var goal_kind := String(goal.get("goalKind", ""))
    var route_status := String(entry.get("routeStatus", ""))
    var route_reason := String(entry.get("routeReason", ""))
    var route_ok := route_status in ["moving", "arrived"] and route_reason != "no_route"
    var scripted := body_valid and body.has_meta("npc_scripted_target")
    var force_hold := body_valid and bool(body.get_meta("npc_force_hold", false))
    var ok := (
        body_valid
        and bool(entry.get("nightGuard", false))
        and goal_kind == "guard"
        and route_ok
        and distance_to_guard <= CELL * 2.35
        and not scripted
        and not force_hold
    )
    return {
        "ok": ok,
        "requires": "night guard assignment, guard goal, near guard cell, no scripted target, no force hold",
        "nightGuard": bool(entry.get("nightGuard", false)),
        "goalKind": goal_kind,
        "goalReason": String(goal.get("reason", "")),
        "routeOk": route_ok,
        "guardCell": vec2i(guard_cell),
        "guardPosition": vec3(guard_position),
        "distanceToGuard": rounded(distance_to_guard),
        "scriptedTarget": scripted,
        "forceHold": force_hold,
        "routeStatus": route_status,
        "routeReason": route_reason,
        "cell": vec2i(flat_cell(body.global_position)) if body_valid else []
    }

func alive_rescue_hostile_bodies() -> Array[Node3D]:
    var result: Array[Node3D] = []
    var hostile_system = main.get("hostile_system") if main != null else null
    if hostile_system == null:
        return result
    var enemies: Array = hostile_system.get("enemies")
    for enemy_value in enemies:
        var enemy: Dictionary = enemy_value if enemy_value is Dictionary else {}
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if bool(body.get_meta("tutorial_rescue_hostile", false)) or bool(enemy.get("tutorialRescue", false)):
            result.append(body)
    return result

func nearest_rescue_hostile_body(bodies: Array[Node3D]) -> Node3D:
    var best: Node3D = null
    var best_distance := INF
    for body in bodies:
        if body == null or not is_instance_valid(body):
            continue
        var distance := flat_distance(player.global_position, body.global_position)
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func hostile_body_alive(body) -> bool:
    if body == null or not is_instance_valid(body):
        return false
    var hostile_system = main.get("hostile_system") if main != null else null
    if hostile_system == null or not hostile_system.has_method("enemy_for_body"):
        return false
    var enemy: Dictionary = hostile_system.call("enemy_for_body", body)
    return not enemy.is_empty()

func rescue_hostile_summaries() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var hostile_system = main.get("hostile_system") if main != null else null
    if hostile_system == null:
        return rows
    var enemies: Array = hostile_system.get("enemies")
    for enemy_value in enemies:
        var enemy: Dictionary = enemy_value if enemy_value is Dictionary else {}
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if not (bool(body.get_meta("tutorial_rescue_hostile", false)) or bool(enemy.get("tutorialRescue", false))):
            continue
        rows.append({
            "name": body.name,
            "variant": String(enemy.get("variant", body.get_meta("variant", ""))),
            "position": vec3(body.global_position),
            "health": rounded(float(enemy.get("health", 0.0))),
            "aware": bool(enemy.get("aware", false)),
            "frenzy": bool(enemy.get("frenzy", body.get_meta("hostile_frenzy", false))),
            "scriptedEncounter": String(enemy.get("scriptedEncounter", body.get_meta("hostile_scripted_encounter", ""))),
            "scriptedPhase": String(enemy.get("scriptedPhase", body.get_meta("hostile_scripted_phase", ""))),
            "damageable": bool(enemy.get("damageable", body.get_meta("hostile_damageable", true))),
            "canAttack": bool(enemy.get("canAttack", body.get_meta("hostile_can_attack", true))),
            "battleStartedBy": String(enemy.get("scriptedBattleStartedBy", body.get_meta("hostile_scripted_battle_started_by", ""))),
            "targetKind": String(enemy.get("targetKind", body.get_meta("hostile_target_kind", ""))),
            "targetName": String(enemy.get("targetName", body.get_meta("hostile_target_name", ""))),
            "targetDistance": rounded(float(enemy.get("targetDistance", INF))),
            "lastMoveDistance": rounded(float(enemy.get("lastMoveDistance", 0.0))),
            "cooldown": rounded(float(enemy.get("cooldown", 0.0)))
        })
    return rows

func hostile_stats_summary() -> Dictionary:
    var hostile_system = main.get("hostile_system") if main != null else null
    if hostile_system == null or not hostile_system.has_method("stats"):
        return {}
    return (hostile_system.call("stats") as Dictionary).duplicate(true)

func combat_hit_summary() -> Dictionary:
    if player == null or not player.has_method("view_ray"):
        return { "hit": false, "reason": "missing_player_view_ray" }
    var hit: Dictionary = player.call("view_ray", 5.4, true)
    if hit.is_empty():
        return { "hit": false }
    var collider := hit.get("collider") as Node
    var position: Vector3 = hit.get("position", Vector3.ZERO)
    return {
        "hit": true,
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "colliderPath": String(collider.get_path()) if collider != null else "",
        "variant": String(collider.get_meta("variant", "")) if collider != null and collider.has_meta("variant") else "",
        "distance": rounded(player.global_position.distance_to(position)),
        "position": vec3(position)
    }

func maybe_use_field_ration_for_rescue() -> void:
    if survival_health() > 46.0 or int(inventory_totals().get("fieldRation", 0)) <= 0:
        return
    var selected := await select_hotbar_item("fieldRation")
    if selected:
        dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
        dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
        await wait_physics_frames(POST_ACTION_FRAMES)
        final_rescue_combat_events.append({
            "label": "final_rescue_used_field_ration",
            "time": rounded(elapsed),
            "survival": survival_snapshot(),
            "inventory": inventory_totals()
        })
    await select_hotbar_item("woodenSword")

func survival_snapshot() -> Dictionary:
    var survival = main.get("survival_system") if main != null else null
    if survival == null or not survival.has_method("snapshot"):
        return {}
    var snapshot: Dictionary = survival.call("snapshot")
    return snapshot.duplicate(true)

func survival_health() -> float:
    return float(survival_snapshot().get("health", 100.0))

func npc_target_position(npc_id: String) -> Vector3:
    var entry := npc_entry(npc_id)
    var body := entry.get("body") as Node3D
    if body != null and is_instance_valid(body):
        return body.global_position + Vector3(0.0, CELL * 0.8, 0.0)
    return player.global_position + Vector3(0.0, CELL * 0.8, 0.0)

func talk_to_tutorial_npc(npc_id: String, label: String, timeout_seconds: float) -> void:
    mark_progress("talk_%s" % label)
    var entry := npc_entry(npc_id)
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        add_failure("day_one_npc_missing", "%s npc=%s" % [label, npc_id])
        return
    if bool(strict_home_status(entry).get("strictInside", false)):
        var initial_access := await ensure_npc_home_access_for_talk(entry, label, 18.0)
        if failed or not initial_access:
            return
    var started_at := elapsed
    var reached := false
    var talk_reach_distance := CELL * 1.35
    while elapsed - started_at < timeout_seconds:
        entry = npc_entry(npc_id)
        body = entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            break
        var remaining := maxf(1.5, timeout_seconds - (elapsed - started_at))
        var home_status := strict_home_status(entry)
        if bool(home_status.get("strictInside", false)):
            var access_ok := await ensure_npc_home_access_for_talk(entry, label, remaining)
            if failed or not access_ok:
                return
            entry = npc_entry(npc_id)
            body = entry.get("body") as Node3D
            if body == null or not is_instance_valid(body):
                break
            if not player_inside_entry_home(entry):
                var door := npc_home_door(entry)
                var porch_position := entry_position(entry, "porchPosition", door.global_position if door != null and is_instance_valid(door) else body.global_position)
                if flat_distance(player.global_position, porch_position) > CELL * 0.95:
                    var porch_reached := false
                    if day_one_tutorial:
                        porch_reached = await walk_tutorial_route_near(porch_position, CELL * 0.85, minf(14.0, remaining), "walking_to_%s_home_porch" % label)
                    else:
                        porch_reached = await walk_near(porch_position, CELL * 0.85, minf(6.0, remaining), "walking_to_%s_home_porch" % label)
                    interaction_timeline.append({
                        "label": "approach_%s_home_porch_for_talk" % label,
                        "npcId": npc_id,
                        "player": vec3(player.global_position),
                        "npc": vec3(body.global_position),
                        "porch": vec3(porch_position),
                        "strictHome": home_status,
                        "reached": porch_reached
                    })
                    if not porch_reached:
                        add_failure("day_one_npc_home_porch_not_reached", JSON.stringify({
                            "label": label,
                            "npcId": npc_id,
                            "player": vec3(player.global_position),
                            "npc": vec3(body.global_position),
                            "porch": vec3(porch_position),
                            "strictHome": home_status
                        }))
                        return
                    await wait_physics_frames(POST_ACTION_FRAMES)
                    continue
                var inside_door_position := home_inside_door_position(entry, body.global_position)
                if flat_distance(player.global_position, inside_door_position) > CELL * 0.7:
                    var inside_reached := false
                    if day_one_tutorial:
                        inside_reached = await walk_tutorial_route_near(inside_door_position, CELL * 0.52, minf(10.0, remaining), "walking_to_%s_home_inside_door" % label)
                    else:
                        inside_reached = await walk_near(inside_door_position, CELL * 0.52, minf(5.0, remaining), "walking_to_%s_home_inside_door" % label)
                    interaction_timeline.append({
                        "label": "approach_%s_home_inside_door_for_talk" % label,
                        "npcId": npc_id,
                        "player": vec3(player.global_position),
                        "npc": vec3(body.global_position),
                        "insideDoor": vec3(inside_door_position),
                        "strictHome": home_status,
                        "reached": inside_reached
                    })
                    if not inside_reached:
                        add_failure("day_one_npc_home_inside_door_not_reached", JSON.stringify({
                            "label": label,
                            "npcId": npc_id,
                            "player": vec3(player.global_position),
                            "npc": vec3(body.global_position),
                            "insideDoor": vec3(inside_door_position),
                            "strictHome": home_status
                        }))
                        return
                    await wait_physics_frames(POST_ACTION_FRAMES)
                    continue
        var threshold_door := npc_home_door(entry)
        if threshold_door != null and is_instance_valid(threshold_door) and not player_inside_entry_home(entry):
            var npc_at_home_threshold := flat_distance(body.global_position, threshold_door.global_position) <= CELL * 1.35
            var player_near_home_threshold := flat_distance(player.global_position, threshold_door.global_position) <= CELL * 10.0
            if npc_at_home_threshold and player_near_home_threshold and flat_distance(player.global_position, body.global_position) > talk_reach_distance:
                var threshold_porch_position := entry_position(entry, "porchPosition", threshold_door.global_position)
                if flat_distance(player.global_position, threshold_porch_position) > CELL * 0.95:
                    var threshold_porch_reached := false
                    if day_one_tutorial:
                        threshold_porch_reached = await walk_tutorial_route_near(threshold_porch_position, CELL * 0.85, minf(32.0, remaining), "walking_to_%s_home_threshold_porch" % label)
                    else:
                        threshold_porch_reached = await walk_near(threshold_porch_position, CELL * 0.85, minf(5.0, remaining), "walking_to_%s_home_threshold_porch" % label)
                    interaction_timeline.append({
                        "label": "approach_%s_home_threshold_porch_for_talk" % label,
                        "npcId": npc_id,
                        "player": vec3(player.global_position),
                        "npc": vec3(body.global_position),
                        "porch": vec3(threshold_porch_position),
                        "door": block_summary(threshold_door),
                        "reached": threshold_porch_reached
                    })
                    if not threshold_porch_reached:
                        add_failure("day_one_npc_home_threshold_porch_not_reached", JSON.stringify({
                            "label": label,
                            "npcId": npc_id,
                            "player": vec3(player.global_position),
                            "npc": vec3(body.global_position),
                            "porch": vec3(threshold_porch_position),
                            "door": block_summary(threshold_door)
                        }))
                        return
                    await wait_physics_frames(POST_ACTION_FRAMES)
                    continue
        if day_one_tutorial:
            reached = await walk_tutorial_route_near(body.global_position, talk_reach_distance, minf(24.0, remaining), "walking_to_%s" % label)
        else:
            reached = await walk_near(body.global_position, talk_reach_distance, minf(4.5, remaining), "walking_to_%s" % label)
        if reached:
            entry = npc_entry(npc_id)
            body = entry.get("body") as Node3D
            if body != null and is_instance_valid(body) and flat_distance(player.global_position, body.global_position) <= talk_reach_distance:
                break
            reached = false
        await wait_physics_frames(6)
    if not reached:
        add_failure("day_one_npc_not_reached", JSON.stringify({
            "label": label,
            "npcId": npc_id,
            "player": vec3(player.global_position),
            "npc": vec3(body.global_position) if body != null and is_instance_valid(body) else [],
            "strictHome": strict_home_status(entry),
            "homeDoor": block_summary(npc_home_door(entry)) if not entry.is_empty() else {}
        }))
        return
    var hit := await aim_until_npc_interaction_hit(body, label)
    interaction_timeline.append({
        "label": "before_%s_talk" % label,
        "npcId": npc_id,
        "player": vec3(player.global_position),
        "hit": hit
    })
    if not npc_interaction_hit_matches(hit, body):
        hit = await retry_npc_talk_after_obstructed_view(npc_id, label, hit, talk_reach_distance, maxf(4.0, timeout_seconds - (elapsed - started_at)))
        entry = npc_entry(npc_id)
        body = entry.get("body") as Node3D
        interaction_timeline.append({
            "label": "before_%s_talk_after_obstruction_retry" % label,
            "npcId": npc_id,
            "player": vec3(player.global_position),
            "hit": hit
        })
    if not npc_interaction_hit_matches(hit, body):
        add_failure("day_one_npc_aim_miss", JSON.stringify({
            "label": label,
            "npcId": npc_id,
            "hit": hit,
            "player": vec3(player.global_position),
            "npc": vec3(body.global_position)
        }))
        return
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var dialogue_open := hud_dialogue_open()
    var tutorial = main.get("tutorial_system") if main != null else null
    var row := {
        "label": label,
        "npcId": npc_id,
        "dialogueOpen": dialogue_open,
        "tutorial": tutorial_state_summary(tutorial),
        "completedSteps": tutorial_completed_steps(tutorial),
        "inventory": inventory_totals(),
        "lastMessage": String(tutorial.get("last_message")) if tutorial != null else ""
    }
    day_one_timeline.append(row)
    if not dialogue_open:
        add_failure("day_one_npc_dialogue_not_opened", JSON.stringify(row))
        return
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    if hud_dialogue_open():
        add_failure("day_one_npc_dialogue_not_closed", JSON.stringify(row))
        return
    if day_one_tutorial:
        await leave_npc_home_after_talk(entry, label)

func ensure_npc_home_access_for_talk(entry: Dictionary, label: String, time_remaining: float) -> bool:
    var home_status := strict_home_status(entry)
    if not bool(home_status.get("strictInside", false)):
        return true
    var door := npc_home_door(entry)
    if door == null or not is_instance_valid(door):
        interaction_timeline.append({
            "label": "missing_home_door_before_%s_talk" % label,
            "strictHome": home_status,
            "player": vec3(player.global_position)
        })
        return true
    if bool(door.get_meta("open", false)):
        return true
    if day_one_tutorial and not player_inside_entry_home(entry):
        var porch_position := entry_position(entry, "porchPosition", door.global_position)
        if flat_distance(player.global_position, porch_position) > CELL * 0.95:
            var porch_reached := await walk_tutorial_route_near(
                porch_position,
                CELL * 0.85,
                minf(maxf(time_remaining, 8.0), 18.0),
                "walking_to_%s_home_porch_before_door" % label
            )
            interaction_timeline.append({
                "label": "approach_%s_home_porch_before_door" % label,
                "player": vec3(player.global_position),
                "porch": vec3(porch_position),
                "door": block_summary(door),
                "strictHome": home_status,
                "reached": porch_reached
            })
            if not porch_reached:
                add_failure("day_one_npc_home_porch_not_reached", JSON.stringify({
                    "label": label,
                    "player": vec3(player.global_position),
                    "porch": vec3(porch_position),
                    "door": block_summary(door),
                    "strictHome": home_status
                }))
                return false
    var opened := await use_block_with_real_action(door, "%s_open_home_door" % label, CELL * 1.85, minf(maxf(time_remaining, 10.0), 28.0))
    if not opened:
        return false
    await wait_physics_frames(POST_ACTION_FRAMES)
    return true

func home_inside_door_position(entry: Dictionary, fallback: Vector3) -> Vector3:
    if entry.is_empty():
        return fallback
    var porch: Vector2i = entry.get("porchCell", entry.get("homeCell", flat_cell(fallback)))
    var home: Vector2i = entry.get("homeCell", porch)
    var delta := home - porch
    var step := Vector2i.ZERO
    if abs(delta.y) >= abs(delta.x):
        step.y = signi(delta.y)
    else:
        step.x = signi(delta.x)
    if step == Vector2i.ZERO:
        return entry_position(entry, "homePosition", fallback)
    var inside_cell := Vector2i(porch.x + step.x * 2, porch.y + step.y * 2)
    return world_position_for_flat_cell(inside_cell)

func leave_npc_home_after_talk(entry: Dictionary, label: String) -> void:
    if entry.is_empty() or not player_inside_entry_home(entry):
        return
    var door := npc_home_door(entry)
    if door != null and is_instance_valid(door) and not bool(door.get_meta("open", false)):
        var opened := await use_block_with_real_action(door, "%s_exit_home_door" % label, CELL * 1.85, 18.0)
        if not opened:
            return
        await wait_physics_frames(POST_ACTION_FRAMES)
    var porch := entry_position(entry, "porchPosition", player.global_position)
    await walk_tutorial_route_near(porch, CELL * 0.75, 18.0, "walking_out_of_%s_home" % label)

func player_inside_entry_home(entry: Dictionary) -> bool:
    if player == null or entry.is_empty():
        return false
    var cell: Vector2i = flat_cell(player.global_position)
    var min_cell: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", cell))
    var max_cell: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", cell))
    return cell.x >= min_cell.x and cell.x <= max_cell.x and cell.y >= min_cell.y and cell.y <= max_cell.y

func aim_until_npc_interaction_hit(body: Node3D, label: String) -> Dictionary:
    var summary := {}
    for height_scale in [0.35, 0.65, 0.95, 1.20]:
        if body == null or not is_instance_valid(body):
            break
        aim_at(body.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
        await wait_physics_frames(6)
        summary = interaction_hit_summary()
        if npc_interaction_hit_matches(summary, body):
            return summary
    interaction_timeline.append({
        "label": "aim_npc_miss_%s" % label,
        "player": vec3(player.global_position),
        "npc": vec3(body.global_position) if body != null and is_instance_valid(body) else [],
        "hit": summary
    })
    return summary

func retry_npc_talk_after_obstructed_view(npc_id: String, label: String, hit: Dictionary, talk_reach_distance: float, time_remaining: float) -> Dictionary:
    var block_type := String(hit.get("blockType", ""))
    if block_type == "":
        return hit
    var blocker := node_from_summary_path(String(hit.get("blockPath", ""))) as Node3D
    if blocker == null or not is_instance_valid(blocker):
        return hit
    interaction_timeline.append({
        "label": "obstructed_view_before_%s_talk" % label,
        "npcId": npc_id,
        "player": vec3(player.global_position),
        "blocker": block_summary(blocker),
        "hit": hit
    })
    if block_type == "door" and not bool(blocker.get_meta("open", false)):
        var opened := await use_block_with_real_action(blocker, "%s_open_obstructing_door" % label, CELL * 1.85, minf(maxf(time_remaining, 8.0), 24.0))
        if not opened:
            return hit
        await wait_physics_frames(POST_ACTION_FRAMES)
    var entry := npc_entry(npc_id)
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return hit
    var reach_time := minf(maxf(time_remaining, 8.0), 24.0)
    var tighter_reach := minf(talk_reach_distance, CELL * 0.62)
    if day_one_tutorial:
        await walk_tutorial_route_near(body.global_position, tighter_reach, reach_time, "walking_to_%s_after_obstructed_view" % label)
    else:
        await walk_near(body.global_position, tighter_reach, minf(reach_time, 6.0), "walking_to_%s_after_obstructed_view" % label)
    return await aim_until_npc_interaction_hit(body, label)

func node_from_summary_path(path: String) -> Node:
    if path == "":
        return null
    var direct := get_node_or_null(NodePath(path))
    if direct != null:
        return direct
    if path.begins_with("/root/") and get_tree() != null and get_tree().root != null:
        return get_tree().root.get_node_or_null(NodePath(path.trim_prefix("/root/")))
    return null

func npc_interaction_hit_matches(summary: Dictionary, body: Node3D) -> bool:
    if body == null or not bool(summary.get("hit", false)):
        return false
    return String(summary.get("colliderPath", "")) == String(body.get_path()) and bool(summary.get("withinReach", false))

func craft_recipe_at_workbench(recipe_id: String, label: String) -> void:
    mark_progress("craft_%s" % label)
    var workbench := nearest_block("workbench", player.global_position)
    if workbench == null:
        add_failure("day_one_workbench_missing", label)
        return
    if day_one_tutorial:
        var threshold_clear := await leave_nearby_home_threshold_for_route(label)
        if not threshold_clear:
            add_failure("day_one_home_threshold_exit_not_reached", JSON.stringify({
                "label": label,
                "player": vec3(player.global_position),
                "workbench": block_summary(workbench)
            }))
            return
    var reached := false
    if day_one_tutorial:
        reached = await walk_tutorial_route_near(workbench.global_position, CELL * 1.65, 24.0, "walking_to_%s_workbench" % label)
    else:
        reached = await walk_near(workbench.global_position, CELL * 1.65, 16.0, "walking_to_%s_workbench" % label)
    if not reached:
        add_failure("day_one_workbench_not_reached", JSON.stringify({
            "label": label,
            "player": vec3(player.global_position),
            "workbench": block_summary(workbench)
        }))
        return
    aim_at(workbench.global_position + Vector3(0.0, CELL * 0.6, 0.0))
    var hud = main.get("hud") if main != null else null
    if hud == null:
        add_failure("day_one_hud_missing_for_crafting", label)
        return
    if not bool(hud.call("is_inventory_open")):
        dispatch_key(KEY_I, true)
        dispatch_key(KEY_I, false)
        await wait_physics_frames(POST_ACTION_FRAMES)
    if not bool(hud.call("is_inventory_open")):
        add_failure("day_one_inventory_not_open_for_crafting", label)
        return
    await press_craft_button(recipe_id, label)
    var totals := inventory_totals()
    if int(totals.get(recipe_id, 0)) <= 0:
        add_failure("day_one_craft_missing_output", "%s inventory=%s" % [label, JSON.stringify(totals)])
        return
    day_one_timeline.append({ "label": label, "recipeId": recipe_id, "inventory": totals })
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)

func leave_nearby_home_threshold_for_route(label: String) -> bool:
    for npc_id in ["mira", "niko", "rowan", "sera"]:
        var entry := npc_entry(npc_id)
        if entry.is_empty():
            continue
        var door := npc_home_door(entry)
        if door == null or not is_instance_valid(door):
            continue
        if player_inside_entry_home(entry):
            continue
        if flat_distance(player.global_position, door.global_position) > CELL * 1.65:
            continue
        var porch_position := entry_position(entry, "porchPosition", door.global_position)
        if flat_distance(player.global_position, porch_position) <= CELL * 0.75:
            return true
        var reached := await walk_tutorial_route_near(porch_position, CELL * 0.65, 8.0, "walking_to_%s_leave_%s_threshold" % [label, npc_id])
        interaction_timeline.append({
            "label": "leave_%s_home_threshold_before_route" % npc_id,
            "routeLabel": label,
            "player": vec3(player.global_position),
            "door": block_summary(door),
            "porch": vec3(porch_position),
            "reached": reached
        })
        return reached
    return true

func gather_resource_from_generated_prop(drop_id: String, tool_item: String, required_delta: int, label: String, search_radius: float) -> void:
    mark_progress(label)
    var before_total := int(inventory_totals().get(drop_id, 0))
    var attempted := {}
    while int(inventory_totals().get(drop_id, 0)) - before_total < required_delta:
        var prop := nearest_prop_with_drop(drop_id, player.global_position, search_radius, attempted)
        if prop == null:
            add_failure("day_one_resource_prop_missing", JSON.stringify({
                "label": label,
                "drop": drop_id,
                "requiredDelta": required_delta,
                "currentDelta": int(inventory_totals().get(drop_id, 0)) - before_total,
                "attempted": attempted.keys()
            }))
            return
        attempted[String(prop.get_meta("prop_id", prop.name))] = true
        var failures_before_attempt := failure_reasons.size()
        var harvested := await harvest_prop_with_real_action(prop, drop_id, tool_item, label)
        if failure_reasons.size() > failures_before_attempt:
            return
        if not harvested:
            continue
    var after_total := int(inventory_totals().get(drop_id, 0))
    resource_gather_events.append({
        "label": label,
        "drop": drop_id,
        "before": before_total,
        "after": after_total,
        "delta": after_total - before_total,
        "requiredDelta": required_delta,
        "tool": tool_item
    })
    day_one_timeline.append({ "label": label, "inventory": inventory_totals(), "resourceEvents": resource_gather_events.duplicate(true) })

func harvest_prop_with_real_action(prop: Node3D, drop_id: String, tool_item: String, label: String) -> bool:
    if prop == null or not is_instance_valid(prop):
        add_failure("day_one_resource_prop_invalid", label)
        return false
    if tool_item != "":
        var selected := await select_hotbar_item(tool_item)
        if not selected:
            add_failure("day_one_tool_not_selectable", "%s tool=%s inventory=%s" % [label, tool_item, JSON.stringify(inventory_totals())])
            return false
    var before_count := int(inventory_totals().get(drop_id, 0))
    var target := prop.global_position
    var distance := Vector2(target.x - player.global_position.x, target.z - player.global_position.z).length()
    var reached := await walk_near(target, CELL * 1.65, clampf(distance / (CELL * 2.8) + 5.0, 8.0, 36.0), "walking_to_%s" % label)
    if not reached:
        resource_gather_events.append({
            "label": label,
            "drop": drop_id,
            "tool": tool_item,
            "prop": prop_summary(prop),
            "player": vec3(player.global_position),
            "attempt": "unreachable"
        })
        return false
    var last_hit := {}
    for attempt in range(72):
        if prop == null or not is_instance_valid(prop):
            break
        last_hit = await aim_until_prop_hit(prop, label)
        dispatch_mouse_button(MOUSE_BUTTON_LEFT, true)
        await wait_physics_frames(2)
        dispatch_mouse_button(MOUSE_BUTTON_LEFT, false)
        await wait_physics_frames(8)
        var current_count := int(inventory_totals().get(drop_id, 0))
        if current_count > before_count:
            resource_gather_events.append({
                "label": "%s_hit_%02d" % [label, attempt],
                "drop": drop_id,
                "before": before_count,
                "after": current_count,
                "delta": current_count - before_count,
                "tool": tool_item,
                "prop": prop_summary(prop) if prop != null and is_instance_valid(prop) else {},
                "lastHit": last_hit
            })
            return true
    var after_count := int(inventory_totals().get(drop_id, 0))
    add_failure("day_one_resource_not_harvested", JSON.stringify({
        "label": label,
        "drop": drop_id,
        "tool": tool_item,
        "before": before_count,
        "after": after_count,
        "lastHit": last_hit,
        "lastHudMessage": String(main.get("last_hud_refresh_message")) if main != null else "",
        "breakProgress": float(main.get("break_progress")) if main != null else 0.0,
        "breakTarget": String(main.get("break_target_id")) if main != null else ""
    }))
    return false

func aim_until_prop_hit(prop: Node3D, label: String) -> Dictionary:
    var summary := {}
    for height_scale in [0.35, 0.70, 1.15, 1.70, 2.30]:
        if prop == null or not is_instance_valid(prop):
            break
        aim_at(prop.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
        await wait_physics_frames(3)
        summary = interaction_hit_summary()
        if prop_interaction_hit_matches(summary, prop):
            return summary
    interaction_timeline.append({
        "label": "aim_prop_miss_%s" % label,
        "player": vec3(player.global_position),
        "prop": prop_summary(prop) if prop != null and is_instance_valid(prop) else {},
        "hit": summary
    })
    return summary

func prop_interaction_hit_matches(summary: Dictionary, prop: Node3D) -> bool:
    if prop == null or not bool(summary.get("hit", false)):
        return false
    return String(summary.get("colliderPath", "")) == String(prop.get_path()) and bool(summary.get("withinReach", false))

func nearest_prop_with_drop(drop_id: String, origin: Vector3, max_distance: float, excluded: Dictionary) -> Node3D:
    var candidates: Array[Node3D] = []
    collect_props_with_drop(get_tree().root, drop_id, candidates)
    var best: Node3D = null
    var best_distance := INF
    for candidate in candidates:
        if candidate == null or not is_instance_valid(candidate):
            continue
        var prop_id := String(candidate.get_meta("prop_id", candidate.name))
        if excluded.has(prop_id):
            continue
        var distance := Vector2(candidate.global_position.x - origin.x, candidate.global_position.z - origin.z).length()
        if distance > max_distance or distance >= best_distance:
            continue
        best = candidate
        best_distance = distance
    return best

func collect_props_with_drop(node: Node, drop_id: String, out: Array[Node3D]) -> void:
    if node == null:
        return
    if node is Node3D and node.has_meta("kind") and String(node.get_meta("kind")) == "prop" and String(node.get_meta("drop", "")) == drop_id:
        out.append(node as Node3D)
    for child in node.get_children():
        collect_props_with_drop(child, drop_id, out)

func prop_summary(prop: Node3D) -> Dictionary:
    if prop == null:
        return {}
    return {
        "name": prop.name,
        "path": String(prop.get_path()),
        "propId": String(prop.get_meta("prop_id", "")),
        "drop": String(prop.get_meta("drop", "")),
        "material": String(prop.get_meta("material", "")),
        "position": vec3(prop.global_position)
    }

func tutorial_completed_steps(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("snapshot"):
        return {}
    var snapshot: Dictionary = tutorial.call("snapshot")
    var result := {}
    var steps = snapshot.get("completedSteps", [])
    if steps is Array:
        for step in steps:
            result[String(step)] = true
    return result

func tutorial_step_completed(tutorial, step_id: String) -> bool:
    return tutorial_completed_steps(tutorial).has(step_id)

func resource_gather_delta(drop_id: String) -> int:
    var total := 0
    for event in resource_gather_events:
        if String(event.get("drop", "")) == drop_id:
            total += int(event.get("delta", 0))
    return total

func day_one_snapshot(tutorial) -> Dictionary:
    return {
        "tutorial": tutorial_state_summary(tutorial),
        "completedSteps": tutorial_completed_steps(tutorial),
        "inventory": inventory_totals(),
        "resourceGatherEvents": resource_gather_events,
        "timeline": day_one_timeline
    }

func record_day_one_step_already_completed(label: String, tutorial) -> void:
    day_one_timeline.append({
        "label": label,
        "reason": "already_completed_by_live_tutorial_state",
        "tutorial": tutorial_state_summary(tutorial),
        "completedSteps": tutorial_completed_steps(tutorial),
        "inventory": inventory_totals()
    })

func track_mira_speed() -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        previous_mira_valid = false
        previous_mira_elapsed = elapsed
        return
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        previous_mira_valid = false
        previous_mira_elapsed = elapsed
        return
    var current := body.global_position
    if previous_mira_valid:
        var flat_delta := Vector2(current.x - previous_mira_position.x, current.z - previous_mira_position.z).length()
        mira_total_flat_distance += flat_delta
        var sample_dt := maxf(elapsed - previous_mira_elapsed, physics_dt)
        var speed := flat_delta / maxf(sample_dt, 0.0001)
        max_mira_flat_speed = maxf(max_mira_flat_speed, speed)
        mira_speed_samples.append({
            "time": rounded(elapsed),
            "sampleDt": rounded(sample_dt),
            "flatSpeed": rounded(speed),
            "flatDelta": rounded(flat_delta),
            "position": vec3(current),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0))),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", ""))
        })
    previous_mira_position = current
    previous_mira_elapsed = elapsed
    previous_mira_valid = true

func walk_near(target: Vector3, stop_distance: float, timeout_seconds: float, label := "walking") -> bool:
    var started_at := elapsed
    var reached := false
    while elapsed - started_at < timeout_seconds:
        var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        if offset.length() <= stop_distance:
            reached = true
            break
        player.set("automated_move", offset.normalized())
        player.set("automated_sprint", false)
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES == 0:
            sample_player(label)
            mark_progress(label)
    player.set("automated_move", Vector3.ZERO)
    if not reached:
        var final_offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        reached = final_offset.length() <= stop_distance
    return reached

func walk_tutorial_route_near(target: Vector3, stop_distance: float, timeout_seconds: float, label: String) -> bool:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial == null or not tutorial.has_method("state"):
        return await walk_near(target, stop_distance, timeout_seconds, label)
    var state: Dictionary = tutorial.call("state")
    var town_center: Vector2i = state.get("townCenter", flat_cell(target))
    var start_cell: Vector2i = state.get("startCell", flat_cell(player.global_position))
    var target_cell := flat_cell(target)
    var route_target_cell := target_cell
    if stop_distance >= CELL * 1.5:
        var target_y_direction := 0
        if target_cell.y > town_center.y:
            target_y_direction = 1
        elif target_cell.y < town_center.y:
            target_y_direction = -1
        if target_y_direction != 0:
            route_target_cell = Vector2i(target_cell.x, target_cell.y + target_y_direction)
    var route_cells: Array[Vector2i] = []
    var current_cell := flat_cell(player.global_position)
    if flat_distance(player.global_position, target) <= CELL * 8.0:
        return await walk_near(target, stop_distance, timeout_seconds, label)
    var side_direction := 1
    if target_cell.x < town_center.x:
        side_direction = -1
    elif target_cell.x == town_center.x and current_cell.x < town_center.x:
        side_direction = -1
    var side_lane_x: int = town_center.x + side_direction * 6
    var use_side_lane: bool = abs(route_target_cell.x - town_center.x) >= 5 or abs(current_cell.x - town_center.x) >= 5
    var crossing_town_sides := (
        use_side_lane
        and (
            (current_cell.x < town_center.x - 4 and route_target_cell.x > town_center.x + 4)
            or (current_cell.x > town_center.x + 4 and route_target_cell.x < town_center.x - 4)
        )
    )
    var leaving_intro_home_lane: bool = (
        abs(current_cell.x - start_cell.x) <= 8
        and current_cell.y <= start_cell.y + 2
    )
    if leaving_intro_home_lane:
        append_unique_route_cell(route_cells, Vector2i(start_cell.x, start_cell.y - 1))
        append_unique_route_cell(route_cells, Vector2i(start_cell.x, start_cell.y - 3))
        append_unique_route_cell(route_cells, Vector2i(start_cell.x, start_cell.y - 5))
        append_unique_route_cell(route_cells, Vector2i(town_center.x, start_cell.y - 5))
        if use_side_lane:
            append_unique_route_cell(route_cells, Vector2i(side_lane_x, start_cell.y - 5))
    else:
        if crossing_town_sides:
            append_unique_route_cell(route_cells, Vector2i(town_center.x, current_cell.y))
            append_unique_route_cell(route_cells, town_center)
            append_unique_route_cell(route_cells, Vector2i(side_lane_x, town_center.y))
        else:
            append_unique_route_cell(route_cells, Vector2i(side_lane_x if use_side_lane else town_center.x, current_cell.y))
    if use_side_lane:
        append_unique_route_cell(route_cells, Vector2i(side_lane_x, route_target_cell.y))
    else:
        append_unique_route_cell(route_cells, town_center)
        append_unique_route_cell(route_cells, Vector2i(town_center.x, route_target_cell.y))
    append_unique_route_cell(route_cells, route_target_cell)
    var started_at := elapsed
    for index in range(route_cells.size()):
        var remaining := timeout_seconds - (elapsed - started_at)
        if remaining <= 0.0:
            return false
        var waypoint: Vector2i = route_cells[index]
        var waypoint_position := world_position_for_flat_cell(waypoint)
        var waypoint_stop := stop_distance if index == route_cells.size() - 1 else CELL * 0.85
        var distance := Vector2(waypoint_position.x - player.global_position.x, waypoint_position.z - player.global_position.z).length()
        var step_timeout := minf(remaining, clampf(distance / (CELL * 2.15) + 3.0, 3.0, 12.0))
        var reached := await walk_near(waypoint_position, waypoint_stop, step_timeout, "%s_route_%02d_%d_%d" % [label, index, waypoint.x, waypoint.y])
        if not reached:
            return false
    var remaining_final := timeout_seconds - (elapsed - started_at)
    if remaining_final <= 0.0:
        return flat_distance(player.global_position, target) <= stop_distance
    return await walk_near(target, stop_distance, remaining_final, "%s_final" % label)

func append_unique_route_cell(route_cells: Array[Vector2i], cell: Vector2i) -> void:
    if route_cells.is_empty() or route_cells[route_cells.size() - 1] != cell:
        route_cells.append(cell)

func walk_intro_path_to_town_center(tutorial, label: String) -> bool:
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var town_center := intro_state_cell(tutorial, "townCenter", start_cell)
    var inside_door_cell := Vector2i(start_cell.x, start_cell.y - 1)
    var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
    var exit_cell := Vector2i(start_cell.x, start_cell.y - 5)
    var center_north := Vector2i(town_center.x, exit_cell.y)
    return await walk_intro_waypoints([inside_door_cell, starter_door_cell, exit_cell, center_north], label, CELL * 1.25, 12.0)

func walk_intro_path_to_starter_bed(tutorial, label: String) -> bool:
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var town_center := intro_state_cell(tutorial, "townCenter", start_cell)
    var bed_cell := Vector2i(town_center.x - 14, town_center.y - 8)
    var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
    var inside_door_cell := Vector2i(start_cell.x, start_cell.y - 1)
    var current_cell := flat_cell(player.global_position)
    if abs(current_cell.x - start_cell.x) <= 6 and abs(current_cell.y - start_cell.y) <= 8:
        return await walk_intro_waypoints([inside_door_cell, bed_cell], label, CELL * 1.25, 8.0)
    var inner_lane := Vector2i(town_center.x, town_center.y - 8)
    var north_lane := Vector2i(town_center.x - 6, town_center.y - 16)
    return await walk_intro_waypoints([inner_lane, north_lane, starter_door_cell, inside_door_cell, bed_cell], label, CELL * 2.1, 12.0)

func walk_intro_waypoints(cells: Array, label: String, stop_distance: float, timeout_seconds: float) -> bool:
    for index in range(cells.size()):
        var cell_value = cells[index]
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var reached := await walk_near(world_position_for_flat_cell(cell), stop_distance, timeout_seconds, "%s_%02d_%d_%d" % [label, index, cell.x, cell.y])
        if reached:
            continue
        if full_player_pov_visual_mode():
            await capture_player_pov_stage(
                "player_pov_failure_%s_%02d" % [safe_capture_id(label), index],
                world_position_for_flat_cell(cell),
                {
                    "failureCandidate": "intro_route_waypoint_not_reached",
                    "label": label,
                    "index": index,
                    "cell": vec2i(cell),
                    "target": vec3(world_position_for_flat_cell(cell)),
                    "stopDistance": rounded(stop_distance)
                }
            )
        add_failure("intro_route_waypoint_not_reached", JSON.stringify({
            "label": label,
            "index": index,
            "cell": vec2i(cell),
            "player": vec3(player.global_position),
            "target": vec3(world_position_for_flat_cell(cell)),
            "stopDistance": rounded(stop_distance)
        }))
        return false
    return true

func intro_state_cell(tutorial, key: String, fallback: Vector2i) -> Vector2i:
    if tutorial == null or not tutorial.has_method("state"):
        return fallback
    var state: Dictionary = tutorial.call("state")
    var value = state.get(key, fallback)
    if value is Vector2i:
        return value
    return fallback

func mira_starter_house_route_regression_sample(mira: Dictionary) -> Dictionary:
    if main == null or player == null or mira.is_empty():
        return { "violation": false }
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "violation": false }
    var tutorial = main.get("tutorial_system")
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var bounds := starter_house_bounds(start_cell)
    var strict_bounds := shrink_flat_bounds(bounds, 1, 2, 1)
    var mira_cell := flat_cell(body.global_position)
    var entered_interior := cell_in_flat_bounds(mira_cell, strict_bounds)
    var blocker_value = body.get_meta("npc_capsule_blocker", {})
    var blocker: Dictionary = blocker_value if blocker_value is Dictionary else {}
    var blocker_cell := Vector2i(999999, 999999)
    if blocker.get("cell") is Vector2i:
        blocker_cell = blocker.get("cell")
    var blocker_type := String(blocker.get("blockType", ""))
    var hit_starter_wall := blocker_type != "" and blocker_type != "door" and cell_in_flat_bounds(blocker_cell, bounds)
    var route_status := String(mira.get("routeStatus", ""))
    var route_reason := String(mira.get("routeReason", ""))
    var route_stalled := route_status == "waiting" or route_status == "blocked" or route_reason in ["blocked_capsule", "blocked_static", "static_or_dynamic_collision"]
    return {
        "violation": entered_interior,
        "enteredStarterInterior": entered_interior,
        "hitStarterWall": hit_starter_wall,
        "routeStalled": route_stalled,
        "miraCell": vec2i(mira_cell),
        "startCell": vec2i(start_cell),
        "bounds": flat_bounds_summary(bounds),
        "strictInteriorBounds": flat_bounds_summary(strict_bounds),
        "blocker": blocker.duplicate(true),
        "routeStatus": route_status,
        "routeReason": route_reason,
        "routeCells": vec2i_array_limited(mira.get("routeCells", []), 10),
        "time": rounded(elapsed)
    }

func starter_house_bounds(start_cell: Vector2i) -> Dictionary:
    var min_cell := Vector2i(start_cell.x - 4, start_cell.y - 5)
    var max_cell := Vector2i(start_cell.x + 4, start_cell.y + 4)
    if main == null:
        return { "min": min_cell, "max": max_cell }
    var blocks: Dictionary = main.get("blocks")
    var found := false
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block) or not block.has_meta("cell"):
            continue
        var block_type := String(block.get_meta("block_type", ""))
        if block_type == "torch" or block_type == "cobblestonePath":
            continue
        var cell_value = block.get_meta("cell")
        if not (cell_value is Vector3i):
            continue
        var cell3: Vector3i = cell_value
        var flat := Vector2i(cell3.x, cell3.z)
        if abs(flat.x - start_cell.x) > 9 or abs(flat.y - start_cell.y) > 9:
            continue
        if not found:
            min_cell = flat
            max_cell = flat
            found = true
        else:
            min_cell.x = mini(min_cell.x, flat.x)
            min_cell.y = mini(min_cell.y, flat.y)
            max_cell.x = maxi(max_cell.x, flat.x)
            max_cell.y = maxi(max_cell.y, flat.y)
    return { "min": min_cell, "max": max_cell }

func shrink_flat_bounds(bounds: Dictionary, x_padding: int, min_z_padding: int, max_z_padding: int) -> Dictionary:
    var min_cell: Vector2i = bounds.get("min", Vector2i.ZERO)
    var max_cell: Vector2i = bounds.get("max", Vector2i.ZERO)
    return {
        "min": Vector2i(min_cell.x + x_padding, min_cell.y + min_z_padding),
        "max": Vector2i(max_cell.x - x_padding, max_cell.y - max_z_padding)
    }

func cell_in_flat_bounds(cell: Vector2i, bounds: Dictionary) -> bool:
    var min_cell: Vector2i = bounds.get("min", Vector2i.ZERO)
    var max_cell: Vector2i = bounds.get("max", Vector2i.ZERO)
    return cell.x >= mini(min_cell.x, max_cell.x) \
        and cell.x <= maxi(min_cell.x, max_cell.x) \
        and cell.y >= mini(min_cell.y, max_cell.y) \
        and cell.y <= maxi(min_cell.y, max_cell.y)

func flat_bounds_summary(bounds: Dictionary) -> Dictionary:
    return {
        "min": vec2i(bounds.get("min", Vector2i.ZERO)),
        "max": vec2i(bounds.get("max", Vector2i.ZERO))
    }

func use_block_with_real_action(block: Node3D, label: String, stop_distance: float, timeout_seconds: float) -> bool:
    if block == null or not is_instance_valid(block):
        add_failure("%s_block_missing_for_real_action" % label, "block was null or invalid")
        return false
    mark_progress("walking_to_%s" % label)
    var reached := false
    if day_one_tutorial and label.begins_with("day_one"):
        reached = await walk_tutorial_route_near(block.global_position, stop_distance, maxf(timeout_seconds, 36.0), "walking_to_%s" % label)
    else:
        reached = await walk_near(block.global_position, stop_distance, timeout_seconds, "walking_to_%s" % label)
    if not reached:
        if full_player_pov_visual_mode():
            await capture_player_pov_stage(
                "player_pov_failure_%s_not_reached" % safe_capture_id(label),
                block.global_position + Vector3(0.0, CELL * 0.65, 0.0),
                {
                    "failureCandidate": "%s_not_reached_for_real_action" % label,
                    "block": block_summary(block),
                    "stopDistance": rounded(stop_distance)
                }
            )
        add_failure("%s_not_reached_for_real_action" % label, JSON.stringify({
            "player": vec3(player.global_position),
            "block": vec3(block.global_position),
            "distance": rounded(Vector2(block.global_position.x - player.global_position.x, block.global_position.z - player.global_position.z).length()),
            "stopDistance": rounded(stop_distance)
        }))
        return false
    var flat_from_block := Vector3(player.global_position.x - block.global_position.x, 0.0, player.global_position.z - block.global_position.z)
    if flat_from_block.length() < CELL * 1.25:
        var away := flat_from_block.normalized() if flat_from_block.length() > 0.05 else Vector3(0.0, 0.0, -1.0)
        var stand_position := block.global_position + away * CELL * 1.65
        await walk_near(stand_position, CELL * 0.35, 4.0, "adjusting_%s_stand" % label)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var before_hit := await aim_until_interaction_hit(block, label)
    if not interaction_hit_matches_block(before_hit, block):
        before_hit = await reposition_and_aim_for_block_interaction(block, label)
    interaction_timeline.append({
        "label": "before_%s_action" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": before_hit
    })
    sample_player("before_%s_action" % label)
    if not interaction_hit_matches_block(before_hit, block):
        add_failure("%s_aim_miss_for_real_action" % label, JSON.stringify({
            "player": vec3(player.global_position),
            "block": block_summary(block),
            "hit": before_hit
        }))
        return false
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    interaction_timeline.append({
        "label": "after_%s_action" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": interaction_hit_summary()
    })
    sample_player("after_%s_action" % label)
    return true

func reposition_and_aim_for_block_interaction(block: Node3D, label: String) -> Dictionary:
    var last_hit := interaction_hit_summary()
    if block == null or not is_instance_valid(block):
        return last_hit
    var offsets := [
        Vector3(0.0, 0.0, CELL * 1.65),
        Vector3(0.0, 0.0, -CELL * 1.65),
        Vector3(CELL * 1.65, 0.0, 0.0),
        Vector3(-CELL * 1.65, 0.0, 0.0),
        Vector3(CELL * 1.25, 0.0, CELL * 1.25),
        Vector3(-CELL * 1.25, 0.0, CELL * 1.25),
        Vector3(CELL * 1.25, 0.0, -CELL * 1.25),
        Vector3(-CELL * 1.25, 0.0, -CELL * 1.25)
    ]
    for index in range(offsets.size()):
        var stand_position: Vector3 = block.global_position + offsets[index]
        var reached := false
        if day_one_tutorial:
            reached = await walk_tutorial_route_near(stand_position, CELL * 0.45, 6.0, "adjusting_%s_stand_%02d" % [label, index])
        else:
            reached = await walk_near(stand_position, CELL * 0.45, 4.0, "adjusting_%s_stand_%02d" % [label, index])
        await wait_physics_frames(POST_ACTION_FRAMES)
        last_hit = await aim_until_interaction_hit(block, "%s_stand_%02d" % [label, index])
        interaction_timeline.append({
            "label": "stand_%s_%02d" % [label, index],
            "player": vec3(player.global_position),
            "block": block_summary(block),
            "stand": vec3(stand_position),
            "reached": reached,
            "hit": last_hit
        })
        if interaction_hit_matches_block(last_hit, block):
            return last_hit
    return last_hit

func use_bed_with_real_action(bed: Node3D, label: String, timeout_seconds: float) -> bool:
    if bed == null or not is_instance_valid(bed):
        add_failure("%s_block_missing_for_real_action" % label, "bed was null or invalid")
        return false
    var last_hit := {}
    var stand_positions := [
        bed.global_position + Vector3(0.0, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(CELL * 0.42, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(-CELL * 0.42, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(0.0, 0.0, CELL * 0.72),
        bed.global_position + Vector3(CELL * 0.42, 0.0, CELL * 0.72),
        bed.global_position + Vector3(-CELL * 0.42, 0.0, CELL * 0.72)
    ]
    for index in range(stand_positions.size()):
        var stand_position: Vector3 = stand_positions[index]
        var flat_distance := Vector2(stand_position.x - player.global_position.x, stand_position.z - player.global_position.z).length()
        var stand_timeout := clampf(flat_distance / (CELL * 2.6) + 2.0, 3.0, timeout_seconds)
        var reached := await walk_near(stand_position, CELL * 0.22, stand_timeout, "walking_to_%s_stand_%02d" % [label, index])
        await wait_physics_frames(POST_ACTION_FRAMES)
        last_hit = await aim_until_interaction_hit(bed, "%s_stand_%02d" % [label, index])
        interaction_timeline.append({
            "label": "bed_stand_%s_%02d" % [label, index],
            "reached": reached,
            "stand": vec3(stand_position),
            "player": vec3(player.global_position),
            "block": block_summary(bed),
            "hit": last_hit
        })
        if interaction_hit_matches_block(last_hit, bed) and bool(last_hit.get("withinReach", false)):
            sample_player("before_%s_action" % label)
            dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
            dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
            await wait_physics_frames(POST_ACTION_FRAMES)
            interaction_timeline.append({
                "label": "after_%s_action" % label,
                "player": vec3(player.global_position),
                "block": block_summary(bed),
                "hit": interaction_hit_summary()
            })
            sample_player("after_%s_action" % label)
            return true
    if full_player_pov_visual_mode():
        await capture_player_pov_stage(
            "player_pov_failure_%s_no_reachable_bed_hit" % safe_capture_id(label),
            bed.global_position + Vector3(0.0, CELL * 0.45, 0.0),
            {
                "failureCandidate": "%s_no_reachable_bed_hit" % label,
                "bed": block_summary(bed),
                "lastHit": last_hit
            }
        )
    add_failure("%s_no_reachable_bed_hit" % label, JSON.stringify({
        "player": vec3(player.global_position),
        "bed": block_summary(bed),
        "lastHit": last_hit
    }))
    return false

func press_utility_slot(index: int, label: String) -> void:
    var hud = main.get("hud") if main != null else null
    if hud == null or hud.get("utility_grid") == null:
        add_failure("utility_grid_missing", label)
        return
    var grid: GridContainer = hud.get("utility_grid")
    if index < 0 or index >= grid.get_child_count():
        add_failure("utility_slot_missing", "%s index=%d childCount=%d" % [label, index, grid.get_child_count()])
        return
    var button := grid.get_child(index) as Button
    if button == null:
        add_failure("utility_slot_not_button", "%s index=%d" % [label, index])
        return
    button.emit_signal("pressed")
    await wait_physics_frames(POST_ACTION_FRAMES)
    inventory_timeline.append({ "label": label, "inventory": inventory_totals(), "utilityState": utility_state_summary() })

func press_craft_button(recipe_id: String, label: String) -> void:
    var hud = main.get("hud") if main != null else null
    var crafting = main.get("crafting_system") if main != null else null
    if hud == null or crafting == null or hud.get("crafting_list") == null:
        add_failure("crafting_hud_missing", label)
        return
    var recipe: Dictionary = crafting.call("recipe_for", recipe_id)
    var expected_label := String(recipe.get("label", recipe_id))
    var expected_amount := int(recipe.get("amount", 1))
    var prefix := "%s x%d" % [expected_label, expected_amount]
    var list: VBoxContainer = hud.get("crafting_list")
    for child in list.get_children():
        var button := child as Button
        if button == null:
            continue
        if not String(button.text).begins_with(prefix):
            continue
        if button.disabled:
            add_failure("craft_button_disabled", "%s text=%s inventory=%s" % [label, button.text, JSON.stringify(inventory_totals())])
            return
        button.emit_signal("pressed")
        await wait_physics_frames(POST_ACTION_FRAMES)
        inventory_timeline.append({ "label": label, "recipeId": recipe_id, "inventory": inventory_totals() })
        return
    add_failure("craft_button_missing", "%s prefix=%s" % [label, prefix])

func place_repair_item(item_id: String, cell: Vector2i, label: String, tutorial) -> void:
    var selected_item := await select_hotbar_item(item_id)
    if not selected_item:
        add_failure("repair_item_not_in_hotbar", "%s item=%s inventory=%s" % [label, item_id, JSON.stringify(inventory_totals())])
        return
    var before := tutorial_state_summary(tutorial)
    var before_fence := int(before.get("fencePlaced", 0))
    var before_lamps := int(before.get("lampsPlaced", 0))
    var target_position := world_position_for_flat_cell(cell)
    var stand_position := placement_stand_position(cell, tutorial)
    var reached_stand := await walk_to_repair_stand(cell, stand_position, tutorial, label)
    if not reached_stand:
        var stand_event := {
            "label": label,
            "item": item_id,
            "targetCell": vec2i(cell),
            "standPosition": vec3(stand_position),
            "playerPosition": vec3(player.global_position),
            "inventory": inventory_totals()
        }
        repair_placement_events.append(stand_event)
        if full_player_pov_visual_mode():
            await capture_player_pov_stage(
                "player_pov_failure_%s_stand_not_reached" % safe_capture_id(label),
                target_position + Vector3(0.0, CELL * 0.75, 0.0),
                stand_event
            )
        add_failure("repair_placement_stand_not_reached", JSON.stringify(stand_event))
        return
    var preview := await aim_until_placement_preview(item_id, cell, label)
    if not placement_preview_matches_target(preview, item_id, cell):
        var preview_event := {
            "label": label,
            "item": item_id,
            "targetCell": vec2i(cell),
            "standPosition": vec3(stand_position),
            "playerPosition": vec3(player.global_position),
            "preview": preview,
            "inventory": inventory_totals()
        }
        repair_placement_events.append(preview_event)
        if full_player_pov_visual_mode():
            await capture_player_pov_stage(
                "player_pov_failure_%s_preview_miss" % safe_capture_id(label),
                target_position + Vector3(0.0, CELL * 0.75, 0.0),
                preview_event
            )
        add_failure("repair_placement_preview_miss", JSON.stringify(preview_event))
        return
    if not active_hotbar_item_is(item_id):
        var reselected := await select_hotbar_item(item_id)
        if not reselected:
            var active_event := {
                "label": label,
                "item": item_id,
                "targetCell": vec2i(cell),
                "activeStack": active_stack_summary(),
                "inventory": inventory_totals()
            }
            repair_placement_events.append(active_event)
            add_failure("repair_item_selection_lost_before_place", JSON.stringify(active_event))
            return
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after := tutorial_state_summary(tutorial)
    var after_fence := int(after.get("fencePlaced", 0))
    var after_lamps := int(after.get("lampsPlaced", 0))
    var counted := after_fence > before_fence or after_lamps > before_lamps
    var event := {
        "label": label,
        "item": item_id,
        "targetCell": vec2i(cell),
        "standPosition": vec3(stand_position),
        "playerPosition": vec3(player.global_position),
        "preview": preview,
        "counted": counted,
        "beforeFence": before_fence,
        "afterFence": after_fence,
        "beforeLamps": before_lamps,
        "afterLamps": after_lamps,
        "inventory": inventory_totals()
    }
    repair_placement_events.append(event)
    if not counted:
        if full_player_pov_visual_mode():
            await capture_player_pov_stage(
                "player_pov_failure_%s_not_counted" % safe_capture_id(label),
                target_position + Vector3(0.0, CELL * 0.75, 0.0),
                event
            )
        add_failure("repair_placement_not_counted", JSON.stringify(event))

func select_hotbar_item(item_id: String) -> bool:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system == null:
        return false
    var slots: Array = inventory_system.get("slots")
    var hotbar_size := int(inventory_system.get("hotbar_size"))
    for i in range(mini(hotbar_size, slots.size())):
        var slot: Dictionary = slots[i] if slots[i] is Dictionary else {}
        if String(slot.get("item", "")) != item_id:
            continue
        var keycode: int = int(KEY_1) + i
        dispatch_key(keycode, true)
        dispatch_key(keycode, false)
        await wait_physics_frames(6)
        return active_hotbar_item_is(item_id)
    return false

func active_hotbar_item_is(item_id: String) -> bool:
    var active := active_stack_summary()
    return String(active.get("item", "")) == item_id

func active_stack_summary() -> Dictionary:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system == null or not inventory_system.has_method("active_stack"):
        return {}
    var active: Dictionary = inventory_system.call("active_stack")
    return active.duplicate(true)

func placement_stand_position(cell: Vector2i, tutorial) -> Vector3:
    var town_center := Vector2i.ZERO
    if tutorial != null and tutorial.has_method("state"):
        var state: Dictionary = tutorial.call("state")
        town_center = state.get("townCenter", Vector2i.ZERO)
    var direction := Vector2(float(town_center.x - cell.x), float(town_center.y - cell.y))
    if direction.length_squared() < 0.001:
        direction = Vector2(1.0, 0.0)
    direction = direction.normalized()
    var stand_x := float(cell.x) + direction.x * 1.55
    var stand_z := float(cell.y) + direction.y * 1.55
    return world_position_for_flat_coords(stand_x, stand_z)

func repair_target_indices(count: int, north_side: bool) -> Array:
    var result := []
    if north_side:
        for index in range(count):
            result.append(index)
    else:
        for index in range(count - 1, -1, -1):
            result.append(index)
    return result

func walk_to_south_repair_bypass(town_center: Vector2i) -> bool:
    var waypoints := [
        Vector2i(town_center.x + 24, town_center.y - 24),
        Vector2i(town_center.x + 24, town_center.y + 24)
    ]
    for index in range(waypoints.size()):
        var waypoint: Vector2i = waypoints[index]
        var waypoint_position := world_position_for_flat_cell(waypoint)
        var distance := Vector2(waypoint_position.x - player.global_position.x, waypoint_position.z - player.global_position.z).length()
        var timeout := clampf(distance / (CELL * 3.0) + 5.0, 10.0, 34.0)
        var reached := await walk_near(waypoint_position, CELL * 1.65, timeout, "walking_to_south_repair_bypass_%02d_%d_%d" % [index, waypoint.x, waypoint.y])
        if not reached:
            if full_player_pov_visual_mode():
                await capture_player_pov_stage(
                    "player_pov_failure_south_repair_bypass_%02d" % index,
                    waypoint_position,
                    {
                        "failureCandidate": "south_repair_bypass_not_reached",
                        "index": index,
                        "cell": vec2i(waypoint),
                        "target": vec3(waypoint_position),
                        "stopDistance": rounded(CELL * 1.65)
                    }
                )
            add_failure("south_repair_bypass_not_reached", JSON.stringify({
                "index": index,
                "cell": vec2i(waypoint),
                "player": vec3(player.global_position),
                "target": vec3(waypoint_position),
                "stopDistance": rounded(CELL * 1.65)
            }))
            return false
    return true

func walk_to_repair_stand(cell: Vector2i, stand_position: Vector3, tutorial, label: String) -> bool:
    var stand_distance := Vector2(stand_position.x - player.global_position.x, stand_position.z - player.global_position.z).length()
    var stand_timeout := clampf(stand_distance / (CELL * 2.8) + 5.0, 12.0, 30.0)
    return await walk_near(stand_position, CELL * 0.38, stand_timeout, "walking_to_%s" % label)

func aim_until_placement_preview(item_id: String, cell: Vector2i, label: String) -> Dictionary:
    var target_position := world_position_for_flat_cell(cell)
    var offsets := [
        Vector3(0.0, -CELL * 0.16, 0.0),
        Vector3(0.0, CELL * 0.02, 0.0),
        Vector3(0.0, CELL * 0.16, 0.0),
        Vector3(CELL * 0.18, -CELL * 0.12, 0.0),
        Vector3(-CELL * 0.18, -CELL * 0.12, 0.0),
        Vector3(0.0, -CELL * 0.12, CELL * 0.18),
        Vector3(0.0, -CELL * 0.12, -CELL * 0.18)
    ]
    var summary := {}
    for offset in offsets:
        aim_at(target_position + offset)
        await wait_physics_frames(2)
        summary = placement_preview_summary(item_id)
        if placement_preview_matches_target(summary, item_id, cell):
            repair_placement_events.append({
                "label": "preview_%s" % label,
                "item": item_id,
                "targetCell": vec2i(cell),
                "playerPosition": vec3(player.global_position),
                "preview": summary
            })
            return summary
    repair_placement_events.append({
        "label": "preview_miss_%s" % label,
        "item": item_id,
        "targetCell": vec2i(cell),
        "playerPosition": vec3(player.global_position),
        "preview": summary
    })
    return summary

func placement_preview_summary(item_id: String) -> Dictionary:
    if player == null or main == null or not player.has_method("view_ray") or not main.has_method("placement_from_hit"):
        return { "hit": false, "reason": "missing_placement_preview_dependencies" }
    var max_distance := CELL * 2.65
    var hit: Dictionary = player.call("view_ray", max_distance)
    var hit_source := "view_ray"
    if hit.is_empty() and main.has_method("fallback_ground_placement_hit"):
        hit = main.call("fallback_ground_placement_hit", max_distance)
        hit_source = "fallback_ground"
    if hit.is_empty():
        return { "hit": false, "reason": "no_placement_hit", "source": hit_source }
    var placement: Dictionary = main.call("placement_from_hit", hit, item_id)
    if placement.is_empty() or not placement.has("cell"):
        return { "hit": true, "reason": "empty_placement", "source": hit_source, "hitSummary": placement_hit_summary(hit) }
    var cell: Vector3i = placement["cell"]
    var blocks_value = main.get("blocks")
    var blocked := blocks_value is Dictionary and (blocks_value as Dictionary).has(cell)
    return {
        "hit": true,
        "source": hit_source,
        "hitSummary": placement_hit_summary(hit),
        "placementCell": vec3i(cell),
        "flatCell": vec2i(Vector2i(cell.x, cell.z)),
        "worldY": rounded(float(placement.get("world_y", 0.0))),
        "withinReach": bool(main.call("placement_within_action_reach", placement)) if main.has_method("placement_within_action_reach") else false,
        "blocked": blocked
    }

func placement_hit_summary(hit: Dictionary) -> Dictionary:
    var collider := hit.get("collider") as Node
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    var normal: Vector3 = hit.get("normal", Vector3.ZERO)
    var block_node := (main.call("interaction_block_from_collider", collider) if main != null and main.has_method("interaction_block_from_collider") else collider) as Node
    return {
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "colliderPath": String(collider.get_path()) if collider != null else "",
        "block": block_node.name if block_node != null else "",
        "blockPath": String(block_node.get_path()) if block_node != null else "",
        "blockType": String(block_node.get_meta("block_type", "")) if block_node != null and block_node.has_meta("block_type") else "",
        "position": vec3(hit_position),
        "normal": vec3(normal)
    }

func placement_preview_matches_target(summary: Dictionary, item_id: String, target_cell: Vector2i) -> bool:
    if not bool(summary.get("hit", false)) or not bool(summary.get("withinReach", false)) or bool(summary.get("blocked", false)):
        return false
    var flat_value = summary.get("flatCell", {})
    var flat := Vector2i(2147483647, 2147483647)
    if flat_value is Array and flat_value.size() >= 2:
        flat = Vector2i(int(flat_value[0]), int(flat_value[1]))
    elif flat_value is Dictionary:
        flat = Vector2i(int(flat_value.get("x", 2147483647)), int(flat_value.get("y", 2147483647)))
    else:
        return false
    var tolerance := 0 if item_id == "woodBlock" else 3
    return absi(flat.x - target_cell.x) + absi(flat.y - target_cell.y) <= tolerance

func world_position_for_flat_cell(cell: Vector2i) -> Vector3:
    return world_position_for_flat_coords(float(cell.x), float(cell.y))

func world_position_for_flat_coords(cell_x: float, cell_z: float) -> Vector3:
    var x := cell_x * CELL
    var z := cell_z * CELL
    var y := 0.0
    if main != null and main.has_method("surface_y_at_position"):
        y = float(main.call("surface_y_at_position", Vector3(x, 0.0, z))) + 0.08
    return Vector3(x, y, z)

func home_door_walkable_probe(entry: Dictionary) -> Array[Dictionary]:
    var npc_system = main.npc_system if main != null else null
    if npc_system == null:
        return []
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null or not autonomy.has_method("closest_walkable"):
        return []
    var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
    var result: Array[Dictionary] = []
    for dz in range(-5, 6):
        for dx in range(-5, 6):
            var cell := Vector2i(porch_cell.x + dx, porch_cell.y + dz)
            var position := world_position_for_flat_cell(cell)
            var walkable_value = autonomy.call("closest_walkable", position, CELL * 0.65)
            if not (walkable_value is Dictionary):
                continue
            var walkable: Dictionary = walkable_value
            if not bool(walkable.get("found", false)):
                continue
            result.append({
                "cell": vec2i(cell),
                "offset": [dx, dz],
                "position": vec3(position),
                "walkablePosition": vec3(walkable.get("position", Vector3.ZERO)),
                "distance": rounded(float(walkable.get("distance", -1.0))),
                "source": String(walkable.get("source", "")),
                "regionId": String(walkable.get("regionId", "")),
                "surfaceId": String(walkable.get("surfaceId", ""))
            })
    result.sort_custom(func(a, b):
        var a_offset: Array = a.get("offset", [0, 0])
        var b_offset: Array = b.get("offset", [0, 0])
        var ad := absi(int(a_offset[0])) + absi(int(a_offset[1]))
        var bd := absi(int(b_offset[0])) + absi(int(b_offset[1]))
        if ad == bd:
            var a_cell: Array = a.get("cell", [0, 0])
            var b_cell: Array = b.get("cell", [0, 0])
            if int(a_cell[0]) == int(b_cell[0]):
                return int(a_cell[1]) < int(b_cell[1])
            return int(a_cell[0]) < int(b_cell[0])
        return ad < bd
    )
    return result

func entry_position(entry: Dictionary, key: String, fallback: Vector3) -> Vector3:
    var value = entry.get(key, fallback)
    if value is Vector3:
        return value
    return fallback

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()

func aim_at(target: Vector3) -> void:
    if player == null or camera == null:
        return
    var flat_target := Vector3(target.x, player.global_position.y, target.z)
    if flat_target.distance_to(player.global_position) > 0.05:
        player.look_at(flat_target, Vector3.UP)
    if target.distance_to(camera.global_position) > 0.05:
        camera.look_at(target, Vector3.UP)
    player.set("pitch", camera.rotation.x)

func aim_until_interaction_hit(block: Node3D, label: String) -> Dictionary:
    var summary := {}
    for height_scale in [0.28, 0.48, 0.12, 0.70]:
        aim_at(block.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
        await wait_physics_frames(6)
        summary = interaction_hit_summary()
        if interaction_hit_matches_block(summary, block):
            return summary
    interaction_timeline.append({
        "label": "aim_miss_%s" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": summary
    })
    return summary

func interaction_hit_summary() -> Dictionary:
    if player == null or not player.has_method("view_ray"):
        return { "hit": false, "reason": "missing_player_view_ray" }
    var hit: Dictionary = player.call("view_ray", 10.5, true)
    if hit.is_empty():
        return { "hit": false }
    var collider := hit.get("collider") as Node
    var block_node := (main.call("interaction_block_from_collider", collider) if main != null and main.has_method("interaction_block_from_collider") else collider) as Node
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    return {
        "hit": true,
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "colliderPath": String(collider.get_path()) if collider != null else "",
        "block": block_node.name if block_node != null else "",
        "blockPath": String(block_node.get_path()) if block_node != null else "",
        "blockType": String(block_node.get_meta("block_type", "")) if block_node != null and block_node.has_meta("block_type") else "",
        "withinReach": bool(main.call("hit_within_action_reach", hit)) if main != null and main.has_method("hit_within_action_reach") else false,
        "distance": rounded(player.global_position.distance_to(hit_position)),
        "position": vec3(hit_position)
    }

func interaction_hit_matches_block(summary: Dictionary, block: Node) -> bool:
    if block == null or not bool(summary.get("hit", false)):
        return false
    return String(summary.get("blockPath", "")) == String(block.get_path())

func block_summary(block: Node3D) -> Dictionary:
    if block == null:
        return {}
    return {
        "name": block.name,
        "path": String(block.get_path()),
        "type": String(block.get_meta("block_type", "")) if block.has_meta("block_type") else "",
        "position": vec3(block.global_position)
    }

func dispatch_mouse_button(button_index: int, pressed: bool) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    var center := get_viewport().get_visible_rect().size * 0.5
    event.position = center
    event.global_position = center
    var has_use_or_place := main != null and main.has_method("use_or_place")
    var routes_to_use_or_place := pressed and button_index == MOUSE_BUTTON_RIGHT and has_use_or_place
    interaction_timeline.append({
        "label": "dispatch_mouse",
        "button": button_index,
        "pressed": pressed,
        "hasUseOrPlace": has_use_or_place,
        "usingUseOrPlace": routes_to_use_or_place
    })
    if routes_to_use_or_place:
        main.call("use_or_place")
        interaction_timeline.append({
            "label": "after_use_or_place_call",
            "state": runtime_action_state()
        })
    elif main != null and main.has_method("_unhandled_input"):
        main.call("_unhandled_input", event)
    else:
        get_viewport().push_input(event)

func dispatch_key(keycode: int, pressed: bool) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.pressed = pressed
    if main != null and main.has_method("_unhandled_input"):
        main.call("_unhandled_input", event)
    else:
        get_viewport().push_input(event)

func runtime_action_state() -> Dictionary:
    var utility = main.get("utility_system") if main != null else null
    var hud_node = main.get("hud") if main != null else null
    return {
        "utilitySystemExists": utility != null,
        "utilityOpen": bool(utility.call("is_open")) if utility != null and utility.has_method("is_open") else false,
        "utilityActiveType": String(utility.call("active_type")) if utility != null and utility.has_method("active_type") else "",
        "hudExists": hud_node != null,
        "hudUtilityOpen": bool(hud_node.call("is_utility_open")) if hud_node != null and hud_node.has_method("is_utility_open") else false,
        "hudInventoryOpen": bool(hud_node.call("is_inventory_open")) if hud_node != null and hud_node.has_method("is_inventory_open") else false,
        "hudDialogueOpen": bool(hud_node.call("is_dialogue_open")) if hud_node != null and hud_node.has_method("is_dialogue_open") else false,
        "lastHudMessage": String(main.get("last_hud_refresh_message")) if main != null else "",
        "focusedHit": interaction_hit_summary()
    }

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func ensure_dir(path: String) -> void:
    if path == "":
        return
    DirAccess.make_dir_recursive_absolute(path)

func bind_scene_nodes() -> void:
    if main == null:
        return
    player = main.get("player") as CharacterBody3D
    if player != null:
        camera = player.get("camera") as Camera3D

func nearest_block(block_type: String, origin: Vector3) -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    var blocks: Dictionary = blocks_value
    for block_value in blocks.values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        var distance := Vector2(body.global_position.x - origin.x, body.global_position.z - origin.z).length()
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func find_intro_repair_chest() -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    for block_value in (blocks_value as Dictionary).values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) == "chest" and bool(body.get_meta("intro_repair_chest", false)):
            return body
    return null

func find_tutorial_bed() -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != "bed":
            continue
        var cache_key := String(body.get_meta("cacheKey", ""))
        var tutorial_bed := cache_key.find("tutorial-bed") >= 0
        var distance := body.global_position.distance_squared_to(player.global_position)
        if tutorial_bed:
            return body
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func inventory_totals() -> Dictionary:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system == null or not inventory_system.has_method("totals"):
        return {}
    var totals: Dictionary = inventory_system.call("totals")
    return totals.duplicate(true)

func utility_state_summary() -> Dictionary:
    var utility = main.get("utility_system") if main != null else null
    if utility == null or not utility.has_method("active_state"):
        return {}
    var state: Dictionary = utility.call("active_state")
    return state.duplicate(true)

func chest_storage_summary(chest: Node) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    if chest == null or not is_instance_valid(chest):
        return rows
    var slots: Array = chest.get_meta("storage_slots", [])
    for index in range(slots.size()):
        var slot: Dictionary = slots[index] if slots[index] is Dictionary else {}
        rows.append({
            "index": index,
            "item": String(slot.get("item", "")),
            "count": int(slot.get("count", 0))
        })
    return rows

func hud_dialogue_open() -> bool:
    var hud = main.get("hud") if main != null else null
    return hud != null and hud.has_method("is_dialogue_open") and bool(hud.call("is_dialogue_open"))

func tutorial_layout_proof(tutorial) -> Dictionary:
    var town: Dictionary = {}
    if tutorial != null:
        var town_value = tutorial.get("town")
        if town_value is Dictionary:
            town = town_value
    var town_center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
    var town_radius := int(town.get("radius", 0))
    var repair_radius := TUTORIAL_REPAIR_RADIUS_CELLS
    return {
        "townCenter": vec2i(town_center),
        "townRadius": town_radius,
        "repairRadius": repair_radius,
        "singlePerimeterRadius": town_radius == repair_radius,
        "townRingBlockCount": perimeter_ring_block_count(town_center, town_radius),
        "repairRingBlockCount": perimeter_ring_block_count(town_center, repair_radius)
    }

func perimeter_ring_block_count(center: Vector2i, radius: int) -> int:
    if main == null or radius <= 0:
        return 0
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return 0
    var count := 0
    for block_value in (blocks_value as Dictionary).values():
        var body := block_value as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type != "woodBlock" and block_type != "door" and block_type != "torch":
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        var dx := absi(cell.x - center.x)
        var dz := absi(cell.z - center.y)
        if dx <= radius and dz <= radius and maxi(dx, dz) == radius:
            count += 1
    return count

func tutorial_state_summary(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return {}
    var state: Dictionary = tutorial.call("state")
    return {
        "started": bool(state.get("started", false)),
        "stage": String(state.get("tutorialStage", "")),
        "doorOpened": bool(state.get("introDoorOpened", false)),
        "elderAcknowledged": bool(state.get("introElderDialogueAcknowledged", false)),
        "repairActive": bool(state.get("introRepairActive", false)),
        "repairComplete": bool(state.get("introRepairComplete", false)),
        "repairChestOpened": bool(state.get("introRepairChestOpened", false)),
        "bedUsed": bool(state.get("introBedUsed", false)),
        "fencePlaced": int(state.get("introFencePlaced", 0)),
        "fenceRequired": int(state.get("introFenceRequired", 0)),
        "lampsPlaced": int(state.get("introLampsPlaced", 0)),
        "lampsRequired": int(state.get("introLampsRequired", 0)),
        "townCenter": vec2i(state.get("townCenter", Vector2i.ZERO)),
        "startCell": vec2i(state.get("startCell", Vector2i.ZERO)),
        "chestCell": vec2i(state.get("introRepairChestCell", Vector2i.ZERO))
    }

func repair_target_proof(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return { "reached": false, "targets": {}, "placements": repair_placement_events }
    var state: Dictionary = tutorial.call("state")
    var targets: Dictionary = state.get("introRepairTargets", {})
    return {
        "reached": bool(state.get("introRepairComplete", false)),
        "fenceTargets": vec2i_array(targets.get("fence", [])),
        "lampTargets": vec2i_array(targets.get("lamps", [])),
        "placedFence": int(state.get("introFencePlaced", 0)),
        "placedLamps": int(state.get("introLampsPlaced", 0)),
        "placements": repair_placement_events,
        "inventory": inventory_totals()
    }

func sleep_transition_proof(tutorial) -> Dictionary:
    var state := tutorial_state_summary(tutorial)
    var blocked_before := false
    var slept_after := false
    for row in sleep_timeline:
        if String(row.get("label", "")) == "before_repair":
            blocked_before = bool(row.get("blocked", false))
        elif String(row.get("label", "")) == "after_repair":
            slept_after = bool(row.get("slept", false))
    return {
        "reached": slept_after,
        "blockedBeforeRepair": blocked_before,
        "sleptAfterRepair": slept_after,
        "timeline": sleep_timeline,
        "finalTutorialState": state,
        "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0
    }

func sample_player(label: String) -> void:
    if player == null:
        return
    player_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(player.global_position),
        "velocity": vec3(player.velocity),
        "automatedMove": vec3(player.get("automated_move")),
        "mouseMode": Input.get_mouse_mode()
    })

func sample_door(label: String, door: Node3D) -> void:
    if door == null or not is_instance_valid(door):
        return
    door_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(door.global_position),
        "open": bool(door.get_meta("open", false)),
        "cell": vec3i(door.get_meta("cell", Vector3i.ZERO)),
        "blockType": String(door.get_meta("block_type", ""))
    })

func sample_mira(label: String) -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        mira_timeline.append({ "label": label, "time": rounded(elapsed), "missing": true })
        return
    var summary := npc_summary(mira)
    summary["label"] = label
    summary["time"] = rounded(elapsed)
    summary["strictHome"] = strict_home_status(mira)
    mira_timeline.append(summary)

func route_order_sample(label: String) -> Dictionary:
    var row := {
        "label": label,
        "time": rounded(elapsed),
        "mira": {}
    }
    var mira := npc_entry("mira")
    if not mira.is_empty():
        row["mira"] = {
            "homeRouteIndex": int(mira.get("homeRouteIndex", 0)),
            "homeActiveTargetCell": vec2i(mira.get("homeActiveTargetCell", Vector2i.ZERO)),
            "routePriority": int(mira.get("routePriority", 0)),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", "")),
            "activeDoorPortalId": String(mira.get("activeDoorPortalId", "")),
            "activeDoorDirection": String(mira.get("activeDoorDirection", "")),
            "portalRecenterTicks": int(mira.get("portalRecenterTicks", 0)),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0)))
        }
    return row

func npc_entry(npc_id: String) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {}
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        if String(entry.get("id", "")) == npc_id:
            return entry
    return {}

func npc_schedule_matrix() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        rows.append(npc_summary(entry))
    return rows

func npc_summary(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var position := body.global_position if body_valid else Vector3.ZERO
    var body_home_meta := false
    var force_hold_meta := false
    var dialogue_focused_meta := false
    var scripted_target_meta := false
    var scripted_arrived_meta := false
    var requested_velocity_meta := Vector3.ZERO
    var applied_velocity_meta := Vector3.ZERO
    var last_displacement_meta := Vector3.ZERO
    var blocked_contact_meta := ""
    var blocked_contact_name_meta := ""
    var blocked_contact_kind_meta := ""
    var blocked_contact_type_meta := ""
    var slide_collision_count_meta := 0
    var speed_mode_meta := ""
    var scripted_speed_mode_meta := ""
    var npc_speed_meta := 0.0
    var npc_rushing_meta := false
    var npc_sprint_requested_meta := false
    var hostile_targeted_meta := false
    var hostile_targeted_count_meta := 0
    var hostile_projectile_hits_meta := 0
    var hostile_target_immune_meta := false
    var last_hostile_attack_meta := ""
    var last_hostile_attacker_meta := ""
    var last_hostile_variant_meta := ""
    if body_valid:
        body_home_meta = bool(body.get_meta("npc_inside_home", false))
        force_hold_meta = bool(body.get_meta("npc_force_hold", false))
        dialogue_focused_meta = bool(body.get_meta("npc_dialogue_focused", false))
        scripted_target_meta = body.has_meta("npc_scripted_target")
        scripted_arrived_meta = bool(body.get_meta("npc_scripted_arrived", false))
        requested_velocity_meta = body.get_meta("npc_requested_velocity", Vector3.ZERO)
        applied_velocity_meta = body.get_meta("npc_applied_velocity", Vector3.ZERO)
        last_displacement_meta = body.get_meta("npc_last_displacement", Vector3.ZERO)
        blocked_contact_meta = String(body.get_meta("npc_blocked_contact", ""))
        blocked_contact_name_meta = String(body.get_meta("npc_blocked_contact_name", ""))
        blocked_contact_kind_meta = String(body.get_meta("npc_blocked_contact_kind", ""))
        blocked_contact_type_meta = String(body.get_meta("npc_blocked_contact_type", ""))
        slide_collision_count_meta = int(body.get_meta("npc_slide_collision_count", 0))
        speed_mode_meta = String(body.get_meta("npc_speed_mode", ""))
        scripted_speed_mode_meta = String(body.get_meta("npc_scripted_speed_mode", ""))
        npc_speed_meta = float(body.get_meta("npc_speed", 0.0))
        npc_rushing_meta = bool(body.get_meta("npc_rushing", false))
        npc_sprint_requested_meta = bool(body.get_meta("npc_sprint_requested", false))
        hostile_targeted_meta = bool(body.get_meta("npc_hostile_targeted", false))
        hostile_targeted_count_meta = int(body.get_meta("npc_hostile_targeted_count", 0))
        hostile_projectile_hits_meta = int(body.get_meta("npc_hostile_projectile_hits", 0))
        hostile_target_immune_meta = bool(body.get_meta("npc_hostile_target_immune", false)) or bool(body.get_meta("hostile_target_immune", false))
        last_hostile_attack_meta = String(body.get_meta("npc_last_hostile_attack", ""))
        last_hostile_attacker_meta = String(body.get_meta("npc_last_hostile_attacker", ""))
        last_hostile_variant_meta = String(body.get_meta("npc_last_hostile_variant", ""))
    var path_waypoints: Array = entry.get("pathWaypoints", [])
    var first_waypoint := Vector3.ZERO
    var first_waypoint_valid := false
    if not path_waypoints.is_empty() and path_waypoints[0] is Vector3:
        first_waypoint = path_waypoints[0]
        first_waypoint_valid = true
    return {
        "id": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "jobPhase": String(entry.get("jobPhase", "")),
        "jobObjectId": String(entry.get("jobObjectId", "")),
        "jobReservationId": String(entry.get("jobReservationId", "")),
        "jobApproachSlotId": String(entry.get("jobApproachSlotId", "")),
        "jobFailureReason": String(entry.get("jobFailureReason", "")),
        "jobRuns": int(entry.get("jobRuns", 0)),
        "jobTarget": vec3(entry.get("jobTarget", Vector3.ZERO)),
        "hunger": rounded(float(entry.get("hunger", 0.0))),
        "personalInventory": (entry.get("personalInventory", {}) as Dictionary).duplicate(true) if entry.get("personalInventory", {}) is Dictionary else {},
        "canFight": bool(entry.get("canFight", false)),
        "nightGuard": bool(entry.get("nightGuard", false)),
        "holdDoorOrder": bool(entry.get("holdIntroDoor", false)),
        "position": vec3(position),
        "cell": vec2i(flat_cell(position)),
        "homeCell": vec2i(entry.get("homeCell", Vector2i.ZERO)),
        "porchCell": vec2i(entry.get("porchCell", Vector2i.ZERO)),
        "guardCell": vec2i(entry.get("guardCell", Vector2i.ZERO)),
        "interiorMinCell": vec2i(entry.get("interiorMinCell", Vector2i.ZERO)),
        "interiorMaxCell": vec2i(entry.get("interiorMaxCell", Vector2i.ZERO)),
        "insideHomeMeta": body_home_meta,
        "strictInsideHome": bool(strict_home_status(entry).get("strictInside", false)),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routePriority": int(entry.get("routePriority", 0)),
        "npcSpeedMode": String(entry.get("npcSpeedMode", speed_mode_meta)),
        "scriptedSpeedMode": scripted_speed_mode_meta,
        "npcSpeed": rounded(float(entry.get("npcSpeed", npc_speed_meta))),
        "npcSpeedReason": String(entry.get("npcSpeedReason", "")),
        "npcRushing": bool(entry.get("npcRushing", npc_rushing_meta)),
        "npcSprintRequested": npc_sprint_requested_meta,
        "scriptedCombatOverlay": bool(entry.get("scriptedCombatOverlay", false)),
        "guardShots": int(entry.get("guardShots", 0)),
        "guardMeleeStrikes": int(entry.get("guardMeleeStrikes", 0)),
        "lastCombatAction": String(entry.get("lastCombatAction", "")),
        "hostileTargeted": hostile_targeted_meta,
        "hostileTargetedCount": hostile_targeted_count_meta,
        "hostileProjectileHits": hostile_projectile_hits_meta,
        "hostileTargetImmune": hostile_target_immune_meta,
        "lastHostileAttack": last_hostile_attack_meta,
        "lastHostileAttacker": last_hostile_attacker_meta,
        "lastHostileVariant": last_hostile_variant_meta,
        "scriptedOrder": entry.get("scriptedOrder", {}),
        "homeRouteIndex": int(entry.get("homeRouteIndex", 0)),
        "homeRouteCount": (entry.get("homeRoutePositions", []) as Array).size(),
        "homeActiveTargetCell": vec2i(entry.get("homeActiveTargetCell", Vector2i.ZERO)),
        "lastMoveDistance": rounded(float(entry.get("lastMoveDistance", 0.0))),
        "simulationLod": String(entry.get("simulationLod", "")),
        "movementHeldForTopology": bool(entry.get("movementHeldForTopology", false)),
        "npcMotionSkippedReason": String(entry.get("npc_motion_skipped_reason", "")),
        "npcMotionUpdates": int(entry.get("npc_motion_updates", 0)),
        "npcBrainUpdates": int(entry.get("npc_brain_updates", 0)),
        "forceHoldMeta": force_hold_meta,
        "dialogueFocusedMeta": dialogue_focused_meta,
        "scriptedTargetMeta": scripted_target_meta,
        "scriptedArrivedMeta": scripted_arrived_meta,
        "activeMotionGoal": entry.get("activeMotionGoal", {}),
        "activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
        "activeDoorDirection": String(entry.get("activeDoorDirection", "")),
        "portalRecenterTicks": int(entry.get("portalRecenterTicks", 0)),
        "activeTrafficStepGroup": String(entry.get("activeTrafficStepGroup", "")),
        "blockedMoveTime": rounded(float(entry.get("blockedMoveTime", 0.0))),
        "routeWaitTicks": int(entry.get("routeWaitTicks", 0)),
        "motorBlockedContact": blocked_contact_meta,
        "motorBlockedContactName": blocked_contact_name_meta,
        "motorBlockedContactKind": blocked_contact_kind_meta,
        "motorBlockedContactType": blocked_contact_type_meta,
        "motorSlideCollisionCount": slide_collision_count_meta,
        "motorRequestedVelocity": vec3(requested_velocity_meta),
        "motorAppliedVelocity": vec3(applied_velocity_meta),
        "motorLastDisplacement": vec3(last_displacement_meta),
        "routeFallbackCell": vec2i(entry.get("routeFallbackCell", Vector2i.ZERO)),
        "routeCells": vec2i_array_limited(entry.get("routeCells", []), 8),
        "routeDynamicAvoidCells": vec2i_array_limited(entry.get("routeDynamicAvoidCells", []), 8),
        "trafficWaitReason": String(entry.get("trafficWaitReason", "")),
        "pathWaypointCount": path_waypoints.size(),
        "firstPathWaypointValid": first_waypoint_valid,
        "firstPathWaypoint": vec3(first_waypoint),
        "lastRoutePlanDebug": entry.get("lastRoutePlanDebug", {}),
        "lastNavmeshTilePublishDebug": entry.get("lastNavmeshTilePublishDebug", []),
        "routePlannerStats": route_planner_stats(),
        "corridorFollow": entry.get("corridorFollow", {}),
        "corridorProgress": entry.get("corridorProgress", {}),
        "lastMotorLocalEscape": entry.get("lastMotorLocalEscape", {}),
        "lastMotorLocalEscapeFailed": entry.get("lastMotorLocalEscapeFailed", {})
    }

func route_planner_stats() -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {}
    var pathing = npc_system.get("pathing")
    if pathing == null:
        return {}
    var coordinator = pathing.get("coordinator")
    if coordinator == null:
        return {}
    var route_planner = coordinator.get("route_planner")
    if route_planner == null or not route_planner.has_method("stats"):
        return {}
    var stats: Dictionary = route_planner.stats()
    if stats.has("queuedNavmeshTileKeys") and stats["queuedNavmeshTileKeys"] is Array:
        stats["queuedNavmeshTileKeys"] = (stats["queuedNavmeshTileKeys"] as Array).slice(0, 12)
    return stats

func strict_home_status(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return { "strictInside": false, "reason": "entry_missing" }
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "strictInside": false, "reason": "body_missing" }
    var cell := flat_cell(body.global_position)
    var min_cell: Vector2i = entry.get("interiorMinCell", Vector2i.ZERO)
    var max_cell: Vector2i = entry.get("interiorMaxCell", Vector2i.ZERO)
    var porch: Vector2i = entry.get("porchCell", Vector2i.ZERO)
    var inside_bounds := (
        cell.x >= mini(min_cell.x, max_cell.x)
        and cell.x <= maxi(min_cell.x, max_cell.x)
        and cell.y >= mini(min_cell.y, max_cell.y)
        and cell.y <= maxi(min_cell.y, max_cell.y)
    )
    var strict_inside := inside_bounds and cell != porch
    return {
        "strictInside": strict_inside,
        "cell": vec2i(cell),
        "porchCell": vec2i(porch),
        "interiorMinCell": vec2i(min_cell),
        "interiorMaxCell": vec2i(max_cell),
        "insideBounds": inside_bounds,
        "reason": "interior_bounds" if strict_inside else "not_inside_interior"
    }

func forager_state_summary() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        var npc_id := String(entry.get("id", ""))
        if npc_id != "niko" and String(entry.get("job", "")) != "forage":
            continue
        var row := npc_summary(entry)
        row["target"] = vec3(entry.get("jobTarget", Vector3.ZERO))
        row["targetNode"] = target_node_summary(entry.get("jobTargetNode"))
        rows.append(row)
    return rows

func niko_forage_row(entry: Dictionary, label: String) -> Dictionary:
    var row := npc_summary(entry)
    row["label"] = label
    row["time"] = rounded(elapsed)
    row["targetNode"] = target_node_summary(entry.get("jobTargetNode"))
    row["target"] = vec3(entry.get("jobTarget", Vector3.ZERO))
    return row

func target_node_summary(node_value) -> Dictionary:
    if node_value == null:
        return { "state": "null" }
    if not is_instance_valid(node_value):
        return { "state": "freed" }
    var node := node_value as Node
    if node == null:
        return { "state": "valid_non_node" }
    var row := {
        "state": "valid",
        "name": node.name,
        "path": String(node.get_path())
    }
    var node_3d := node as Node3D
    if node_3d != null:
        row["position"] = vec3(node_3d.global_position)
    if node.has_meta("prop_id"):
        row["propId"] = String(node.get_meta("prop_id"))
    if node.has_meta("drop"):
        row["drop"] = String(node.get_meta("drop"))
    return row

func profile_speed_limit(entry: Dictionary) -> float:
    var limit := 6.4 * 1.15
    if entry.is_empty():
        return limit
    var profile = entry.get("motorProfile")
    if profile != null:
        var sprint_value = profile.get("sprint_speed")
        if sprint_value != null:
            limit = float(sprint_value) * 1.15
    return limit

func flat_cell(position: Vector3) -> Vector2i:
    if main != null and main.has_method("world_to_cell"):
        return Vector2i(int(main.call("world_to_cell", position.x)), int(main.call("world_to_cell", position.z)))
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func add_failure(code: String, details: String) -> void:
    failure_reasons.append({ "code": code, "details": details, "time": rounded(elapsed) })
    results.append({ "name": TEST_ID, "passed": false, "details": "%s: %s" % [code, details] })
    failed = true
    report_data["finished"] = finished
    report_data["passed"] = false
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["lastFailure"] = failure_reasons[failure_reasons.size() - 1]
    report_data["timeline"] = final_rescue_timeline if final_rescue_tutorial else morning_observation_timeline
    report_data["playerTimeline"] = player_timeline
    report_data["doorStateTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["miraRouteOrderTimeline"] = route_order_timeline
    report_data["miraSpeedSamples"] = mira_speed_samples
    report_data["visualCaptures"] = visual_captures
    report_data["nonGuardHomeVisualMatrix"] = non_guard_home_visual_matrix
    report_data["morningOutsideVisualMatrix"] = morning_outside_visual_matrix
    report_data["npcScheduleMatrix"] = schedule_matrix
    report_data["dayOneTimeline"] = day_one_timeline
    report_data["dayOneResourceGatherEvents"] = resource_gather_events
    report_data["finalRescueTimeline"] = final_rescue_timeline
    report_data["finalRescueNormalBehaviorTimeline"] = final_rescue_normal_behavior_timeline
    report_data["finalRescueSpeedProofs"] = final_rescue_speed_proofs
    report_data["finalRescueCombatEvents"] = final_rescue_combat_events
    var mira := npc_entry("mira")
    if not mira.is_empty():
        report_data["miraFailureSnapshot"] = npc_summary(mira)
    save_report()

func finish() -> void:
    if finished:
        return
    player_stop()
    finished = true
    report_data["finished"] = true
    report_data["passed"] = not failed
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["timeline"] = final_rescue_timeline if final_rescue_tutorial else morning_observation_timeline
    report_data["playerTimeline"] = player_timeline
    report_data["doorStateTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["miraRouteOrderTimeline"] = route_order_timeline
    report_data["miraSpeedSamples"] = mira_speed_samples
    report_data["visualCaptures"] = visual_captures
    report_data["nonGuardHomeVisualMatrix"] = non_guard_home_visual_matrix
    report_data["morningOutsideVisualMatrix"] = morning_outside_visual_matrix
    report_data["npcScheduleMatrix"] = schedule_matrix
    report_data["nightGuardNonGuardMatrix"] = night_matrix
    report_data["repairPlacementEvents"] = repair_placement_events
    report_data["sleepTimeline"] = sleep_timeline
    report_data["inventoryTimeline"] = inventory_timeline
    report_data["interactionTimeline"] = interaction_timeline
    report_data["morningNpcDepartureMatrix"] = morning_departure_matrix
    report_data["nikoTimeline"] = niko_timeline
    report_data["nikoForageProof"] = niko_proof
    report_data["nikoForagerState"] = forager_state_summary()
    report_data["dayOneTimeline"] = day_one_timeline
    report_data["dayOneResourceGatherEvents"] = resource_gather_events
    report_data["finalRescueTimeline"] = final_rescue_timeline
    report_data["finalRescueNormalBehaviorTimeline"] = final_rescue_normal_behavior_timeline
    report_data["finalRescueSpeedProofs"] = final_rescue_speed_proofs
    report_data["finalRescueCombatEvents"] = final_rescue_combat_events
    save_report()
    mark_progress("finished")
    get_tree().quit(1 if failed else 0)

func player_stop() -> void:
    if player != null:
        player.set("automated_move", Vector3.ZERO)
        player.set("automated_sprint", false)

func save_report() -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_REPORT")
    if path == "":
        path = "user://real-tutorial-playthrough-report.json"
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write real tutorial report: %s" % path)
        return
    file.store_string(JSON.stringify(report_data, "  "))
    file.close()

func save_live_report_checkpoint(label: String) -> void:
    if finished:
        return
    report_data["finished"] = false
    report_data["passed"] = false
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["liveCheckpoint"] = {
        "label": label,
        "time": rounded(elapsed),
        "physicsFrame": int(Engine.get_physics_frames())
    }
    report_data["timeline"] = final_rescue_timeline if final_rescue_tutorial else morning_observation_timeline
    report_data["playerTimeline"] = player_timeline
    report_data["visualCaptures"] = visual_captures
    report_data["finalRescueTimeline"] = final_rescue_timeline
    report_data["finalRescueNormalBehaviorTimeline"] = final_rescue_normal_behavior_timeline
    report_data["finalRescueSpeedProofs"] = final_rescue_speed_proofs
    report_data["finalRescueCombatEvents"] = final_rescue_combat_events
    save_report()

func mark_progress(label: String) -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_PROGRESS")
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    var contents := "%s\nelapsed=%.3f\nfailures=%d\nmaxMiraSpeed=%.3f\n" % [
        label,
        elapsed,
        failure_reasons.size(),
        max_mira_flat_speed
    ]
    if not failure_reasons.is_empty():
        var last_failure: Dictionary = failure_reasons[failure_reasons.size() - 1]
        var failure_details := String(last_failure.get("details", ""))
        if failure_details.length() > 1200:
            failure_details = "%s..." % failure_details.substr(0, 1200)
        contents += "lastFailureCode=%s\nlastFailureDetails=%s\n" % [
            String(last_failure.get("code", "")),
            failure_details
        ]
    file.store_string(contents)
    file.close()

func watchdog_seconds() -> float:
    var raw := OS.get_environment("VOXEL_REAL_TUTORIAL_WATCHDOG_SECONDS").strip_edges()
    if raw == "":
        return 220.0
    return maxf(10.0, float(raw))

func vec3(value) -> Array:
    if value is Vector3:
        return [rounded(value.x), rounded(value.y), rounded(value.z)]
    return [0.0, 0.0, 0.0]

func vec2i(value) -> Array:
    if value is Vector2i:
        return [value.x, value.y]
    return [0, 0]

func vec3i(value) -> Array:
    if value is Vector3i:
        return [value.x, value.y, value.z]
    return [0, 0, 0]

func vec2i_array(values) -> Array:
    var result := []
    if not (values is Array):
        return result
    for value in values:
        result.append(vec2i(value))
    return result

func vec2i_array_limited(values, limit := 8) -> Array:
    var result := []
    if not (values is Array):
        return result
    for value in values:
        if result.size() >= limit:
            break
        result.append(vec2i(value))
    return result

func rounded(value: float) -> float:
    return roundf(value * 1000.0) / 1000.0

func clock_display_hour() -> float:
    if main == null:
        return 0.0
    return fposmod(float(main.get("time_of_day")) + 0.25, 1.0) * 24.0
