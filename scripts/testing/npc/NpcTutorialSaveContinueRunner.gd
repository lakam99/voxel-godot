extends "res://scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd"

const STAGE_SAVE_POST_ACK := "save_post_ack"
const STAGE_CONTINUE_OBSERVE := "continue_observe"

var save_continue_stage := ""
var continue_approach := {}
var continue_previous_door_open := false
var continue_observation_active := false

func _on_main_startup_loading_completed() -> void:
    super._on_main_startup_loading_completed()
    if save_continue_stage != STAGE_CONTINUE_OBSERVE:
        return
    # Capture in the release signal itself, before screenshots or another frame
    # can advance the NPC. This observes state without issuing gameplay commands.
    bind_scene_nodes()
    if not is_instance_valid(player):
        add_failure("continue_release_player_missing", "Cannot establish observation at gameplay release")
        return
    sample_continue_loading_execution(startup_loading_state())
    var tutorial = main.get("tutorial_system")
    var start_cell := state_start_cell(tutorial, flat_cell(player.global_position))
    starter_door = nearest_block("door", world_position_for_flat_cell(Vector2i(start_cell.x, start_cell.y - 3)))
    if not is_instance_valid(starter_door):
        add_failure("continue_release_starter_door_missing", "Cannot establish the approach observation at gameplay release")
        return
    starter_door_position = starter_door.global_position
    begin_continue_approach_observation()

func _physics_process(_delta: float) -> void:
    if continue_observation_active and not finished:
        track_phase0_transitions(npc_entry("mira"))

func run() -> void:
    save_continue_stage = OS.get_environment("VOXEL_TUTORIAL_SAVE_CONTINUE_STAGE").strip_edges()
    await super.run()

func launch_main_via_menu_input() -> bool:
    if save_continue_stage != STAGE_CONTINUE_OBSERVE:
        return await super.launch_main_via_menu_input()
    startup_loading_completed_observed = false
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    var existing_menu := existing_main_menu_parent()
    if existing_menu == null:
        add_failure("continue_menu_missing", "Continue observation must attach to the production Main Menu")
        return false
    menu = existing_menu
    report_data["launchPath"] = "project main scene MainMenu.tscn Continue button input"
    report_data["saveContinueStage"] = save_continue_stage
    await wait_process_frames(4)
    var button := menu.get("continue_button") as Button
    if button == null or not is_instance_valid(button) or button.disabled:
        add_failure("main_menu_continue_button_missing_or_disabled", JSON.stringify(control_summary(button)))
        return false
    await capture_stage("menu_before_continue", {"button": control_summary(button)})
    var save_input := verify_continue_save_input()
    report_data["continueInputSave"] = save_input
    save_report(false)
    if not bool(save_input.get("ok", false)):
        add_failure("continue_input_save_not_preserved", JSON.stringify(save_input))
        return false
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, true, "menu_continue_press")
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, false, "menu_continue_release")
    record_phase0_event("continueClick", {"button": control_summary(button)})
    mark_progress("main_menu_continue_button_input")
    var max_frames := ceili(180.0 * float(Engine.physics_ticks_per_second))
    for frame in range(max_frames):
        await get_tree().process_frame
        var active_value = menu.get("active_main") if menu != null else null
        if active_value is Node3D:
            main = active_value
            connect_main_loading_diagnostics()
        if main != null and is_instance_valid(main):
            var loading_state := startup_loading_state()
            sample_continue_loading_execution(loading_state)
            if not (loading_state["failureResult"] as Dictionary).is_empty():
                await report_startup_loading_failure("continue", frame, loading_state)
                return false
            if startup_loading_completed_observed and not bool(loading_state["loadingActive"]):
                report_data["mainMenuLaunch"] = {
                    "clickedViaInput": true,
                    "mode": "continue",
                    "frames": frame,
                    "loadingActive": false,
                    "loadingCompletedSignalObserved": startup_loading_completed_observed
                }
                mark_progress("main_menu_continue_loaded")
                return true
        if frame % 60 == 0:
            mark_progress("main_menu_waiting_for_continue_load active=%s" % str(main != null))
    add_failure("main_menu_continue_timeout", "Continue button input did not produce a loaded Main scene")
    return false

func verify_continue_save_input() -> Dictionary:
    var manifest_path := OS.get_environment("VOXEL_TUTORIAL_CONTINUE_INPUT_MANIFEST")
    if manifest_path == "" or not FileAccess.file_exists(manifest_path):
        return {"ok": false, "reason": "missing_prelaunch_input_manifest"}
    var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
    if not (value is Dictionary) or not bool(value.get("ok", false)) or value.get("files", []).size() != 2:
        return {"ok": false, "reason": "invalid_prelaunch_input_manifest"}
    for file in value.files:
        if String(file.sha256) == "" or FileAccess.get_sha256(file.source) != String(file.sha256) or FileAccess.get_sha256(file.path) != String(file.sha256):
            return {"ok": false, "reason": "continue_input_changed_before_click", "file": file}
    return value

func sample_continue_loading_execution(loading_state: Dictionary) -> void:
    var entry := npc_entry("mira")
    var body := entry.get("body") as Node3D
    if not is_instance_valid(body) or not body.is_inside_tree():
        return
    var sample := {"physicsFrame": Engine.get_physics_frames(), "time": rounded(elapsed),
        "loadingActive": loading_state.get("loadingActive", true),
        "position": vec3(body.global_position), "bodyInstance": body.get_instance_id(),
        "bodyPhysicsEnabled": body.is_physics_processing(),
        "npcExecutionEnabled": main.get("npc_system").get("autonomy_system").is_physics_processing(),
        "routePhysicsService": route_physics_service_summary(entry), "order": scripted_order_summary(entry)}
    var evidence: Dictionary = report_data.get("continueLoadingExecution", {})
    if not evidence.has("firstRegistered"):
        evidence["firstRegistered"] = sample
    if bool(sample.loadingActive):
        evidence["registeredLoadingSamples"] = int(evidence.get("registeredLoadingSamples", 0)) + 1
        evidence["executionEnabledWhileLoading"] = bool(evidence.get("executionEnabledWhileLoading", false)) or bool(sample.npcExecutionEnabled)
        evidence["lastWhileLoading"] = sample
        var first_position: Array = evidence.firstRegistered.position
        var first := Vector3(float(first_position[0]), float(first_position[1]), float(first_position[2]))
        evidence["maxDisplacementWhileLoading"] = maxf(float(evidence.get("maxDisplacementWhileLoading", 0.0)), flat_distance(first, body.global_position))
        evidence["maxRouteServiceTicksWhileLoading"] = maxi(int(evidence.get("maxRouteServiceTicksWhileLoading", 0)), int(sample.routePhysicsService.get("ticks", 0)))
        evidence["routeServiceChangedWhileLoading"] = bool(evidence.get("routeServiceChangedWhileLoading", false)) or int(sample.routePhysicsService.ticks) != int(evidence.firstRegistered.routePhysicsService.ticks)
    else:
        if not evidence.has("atLoadingComplete"):
            evidence["atLoadingComplete"] = sample
            evidence["passed"] = int(evidence.get("registeredLoadingSamples", 0)) > 0 \
                and not bool(evidence.get("executionEnabledWhileLoading", false)) \
                and not bool(evidence.get("routeServiceChangedWhileLoading", false)) \
                and int(sample.routePhysicsService.ticks) == int(evidence.firstRegistered.routePhysicsService.ticks) \
                and int(sample.bodyInstance) == int(evidence.firstRegistered.bodyInstance)
    report_data["continueLoadingExecution"] = evidence

func run_knock_and_mira_observation() -> void:
    if save_continue_stage == STAGE_CONTINUE_OBSERVE:
        await observe_after_continue()
        return
    await knock_then_save_post_ack()

func knock_then_save_post_ack() -> void:
    var tutorial = main.get("tutorial_system")
    report_data["initialTutorialState"] = tutorial_state_summary(tutorial)
    await capture_stage("gameplay_start_before_door_walk", {
        "tutorialState": report_data["initialTutorialState"],
        "player": player_summary()
    })
    mark_progress("walking_to_player_house_door")
    var reached := await walk_to_target_with_key_input(starter_door_position, DOOR_CLOSE_APPROACH_DISTANCE, 12.0, "walking_to_player_house_door")
    sample_player("near_player_house_door")
    sample_door("before_knock_click", starter_door)
    if not reached:
        add_failure("player_could_not_reach_starter_door_by_input", JSON.stringify({"player": player_summary(), "door": block_summary(starter_door)}))
        return
    var hit := await aim_until_block_hit(starter_door, "starter_door")
    await capture_stage("player_pov_intro_door_before_click", {"door": block_summary(starter_door), "hit": hit, "player": player_summary()})
    if not block_hit_matches(hit, starter_door):
        add_failure("starter_door_aim_miss_before_knock", JSON.stringify({"door": block_summary(starter_door), "hit": hit}))
        return
    record_phase0_event("doorInteraction", {"door": block_summary(starter_door), "hit": hit, "player": player_summary()})
    dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_RIGHT, true, "starter_door_right_click_press")
    dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_RIGHT, false, "starter_door_right_click_release")
    var dialogue_ready := await wait_for_intro_dialogue_ready(5.0)
    var after_door_state := tutorial_state_summary(tutorial)
    if not bool(after_door_state.get("doorOpened", false)) or not bool(dialogue_ready.get("ok", false)) or not hud_dialogue_open():
        add_failure("actual_input_path_failed_before_save", JSON.stringify(tutorial_state_summary(tutorial)))
        return
    var close_button := dialogue_ready.get("closeButton", null) as Button
    if close_button == null:
        add_failure("dialogue_close_button_missing", "HUD dialogue was open but no visible Close button was found")
        return
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, true, "dialogue_close_button_press")
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, false, "dialogue_close_button_release")
    await get_tree().process_frame
    var acknowledged := tutorial_state_summary(tutorial)
    await capture_stage("player_pov_dialogue_acknowledged_before_save", {"tutorialState": acknowledged, "dialogueOpen": hud_dialogue_open()})
    if hud_dialogue_open() or not bool(acknowledged.get("elderAcknowledged", false)):
        add_failure("dialogue_acknowledgement_not_live_before_save", JSON.stringify(acknowledged))
        return
    var save_result := persist_post_ack_save(tutorial)
    results.append({
        "name": "actual_input_post_ack_save_created",
        "passed": bool(save_result.get("ok", false)),
        "details": JSON.stringify(save_result)
    })
    if not bool(save_result.get("ok", false)):
        add_failure("post_ack_save_failed", JSON.stringify(save_result))

func persist_post_ack_save(tutorial) -> Dictionary:
    if main == null or main.get("save_system") == null or not main.has_method("create_save_snapshot"):
        return {"ok": false, "reason": "missing_save_authority"}
    var snapshot: Dictionary = main.call("create_save_snapshot")
    var tutorial_snapshot: Dictionary = snapshot.get("tutorial", {}) if snapshot.get("tutorial", {}) is Dictionary else {}
    var save_contract: Dictionary = tutorial_snapshot.get("saveContract", {}) if tutorial_snapshot.get("saveContract", {}) is Dictionary else {}
    var intent: Dictionary = save_contract.get("introKnockIntent", {}) if save_contract.get("introKnockIntent", {}) is Dictionary else {}
    var saved := bool(main.get("save_system").call("save", String(main.get("seed_text")), snapshot))
    var result := {
        "ok": saved \
            and bool(tutorial_snapshot.get("started", false)) \
            and bool((tutorial_snapshot.get("introRepair", {}) as Dictionary).get("elderAcknowledged", false)) \
            and String(intent.get("kind", "")) == "go_home" \
            and not JSON.stringify(save_contract).contains("route"),
        "saved": saved,
        "seed": String(main.get("seed_text")),
        "tutorialSaveContract": save_contract,
        "tutorialState": tutorial_state_summary(tutorial),
        "npcFactsAtExplicitSave": snapshot.get("npcJobFacts", []),
        "saveSlotPath": main.get("save_system")._slot_path(String(main.get("seed_text"))),
        "activeSeedPath": main.get("save_system")._active_seed_path(),
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges()
    }
    report_data["postAckSave"] = result
    return result

func observe_after_continue() -> void:
    var loading_evidence: Dictionary = report_data.get("continueLoadingExecution", {})
    if not bool(loading_evidence.get("passed", false)):
        add_failure("continue_loading_execution_not_paused", JSON.stringify(loading_evidence))
        return
    var tutorial = main.get("tutorial_system")
    var continued_state := tutorial_state_summary(tutorial)
    report_data["continuedTutorialState"] = continued_state
    if not bool(continued_state.get("elderAcknowledged", false)):
        add_failure("continue_did_not_restore_dialogue_acknowledgement", JSON.stringify(continued_state))
        return
    var mira := npc_entry("mira")
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        add_failure("continue_mira_missing", JSON.stringify(continued_state))
        return
    var restored_order: Dictionary = report_data.get("continuedRestoredOrder", {})
    if String(restored_order.get("kind", "")) != "go_home" or String(restored_order.get("submissionReason", "")) != "tutorial_knock_complete":
        add_failure("continue_did_not_restore_generic_home_intent", JSON.stringify(restored_order))
        return
    await capture_stage("player_pov_continue_after_restore", {"mira": npc_summary(mira), "tutorialState": continued_state})
    if continue_approach.is_empty() or String(continue_approach.get("failure", "")) != "":
        add_failure("continue_live_approach_precondition_failed", JSON.stringify(continue_approach))
        return
    await observe_mira_after_knock(OBSERVE_SECONDS)
    mira = npc_entry("mira")
    report_data["miraFinal"] = npc_summary(mira) if not mira.is_empty() else {}
    report_data["miraFinalHomeInteriorStatus"] = strict_home_status(mira)
    report_data["miraLeftPlayerPorch"] = mira_left_player_porch
    report_data["miraReachedStrictHome"] = mira_reached_strict_home
    var observation_event: Dictionary = phase0_timing.get("continueObservationStart", {}) if phase0_timing.get("continueObservationStart", {}) is Dictionary else {}
    var clearance_event: Dictionary = phase0_timing.get("playerPorchClearance", {}) if phase0_timing.get("playerPorchClearance", {}) is Dictionary else {}
    var clearance_delay := float(clearance_event.get("time", INF)) - float(observation_event.get("time", 0.0))
    report_data["continuePorchClearanceDelayAfterObservation"] = rounded(clearance_delay) if is_finite(clearance_delay) else null
    await capture_stage("player_pov_continue_mira_final_state", {"mira": report_data["miraFinal"], "homeStatus": report_data["miraFinalHomeInteriorStatus"]})
    var observer_view := mira_observer_view(mira)
    if not observer_view.is_empty():
        await capture_observer_stage("observer_continue_mira_final_state", observer_view.get("eye", Vector3.ZERO), observer_view.get("target", Vector3.ZERO), {
            "mira": report_data["miraFinal"],
            "homeStatus": report_data["miraFinalHomeInteriorStatus"]
        })
    if not mira_left_player_porch:
        add_failure("continue_mira_did_not_leave_player_porch", JSON.stringify(report_data["miraFinal"]))
        return
    if not is_finite(clearance_delay) or clearance_delay > MAX_PORCH_CLEARANCE_DELAY_SECONDS:
        add_failure("continue_mira_porch_clearance_slow", JSON.stringify({"delaySeconds": clearance_delay, "maximumSeconds": MAX_PORCH_CLEARANCE_DELAY_SECONDS}))
        return
    if not mira_reached_strict_home:
        add_failure("continue_mira_did_not_reach_strict_home", JSON.stringify(report_data["miraFinalHomeInteriorStatus"]))
        return
    continue_observation_active = false
    var events: Dictionary = continue_approach.events
    var sequence_passed := String(continue_approach.failure) == ""
    var previous_frame := -1
    for event_name in ["initial", "displacement", "doorOpened", "doorCrossing", "strictInteriorClear", "doorClosed"]:
        var event: Dictionary = events.get(event_name, {})
        var frame := int(event.get("physicsFrame", -1))
        sequence_passed = sequence_passed and frame > previous_frame
        previous_frame = frame
    continue_approach["passed"] = sequence_passed
    report_data["continueLiveApproach"] = continue_approach
    if not sequence_passed:
        add_failure("continue_live_approach_sequence_not_observed", JSON.stringify(continue_approach))
        return
    results.append({
        "name": "post_ack_save_continue_restores_generic_home_intent_and_real_arrival",
        "passed": true,
        "details": "Live New Game input acknowledged the knock, the isolated save was loaded through Continue, and Mira cleared the player porch then reached strict home through normal NPC physics."
    })
    await finish()

func begin_continue_approach_observation() -> void:
    var mira := npc_entry("mira")
    var body := mira.get("body") as Node3D
    if not is_instance_valid(body):
        add_failure("continue_release_actor_missing", "Cannot establish approach observation at gameplay release")
        return
    mira_ack_position = body.global_position
    mira_ack_position_valid = true
    record_phase0_event("continueObservationStart", {"mira": npc_summary(mira), "tutorialState": tutorial_state_summary(main.get("tutorial_system"))})
    report_data["continuedRestoredOrder"] = scripted_order_summary(mira)
    var home_door := home_door_for_entry(mira)
    var initial_home := strict_home_status(mira)
    continue_approach = {"events": {}, "failure": "", "maxDisplacement": 0.0,
        "bodyInstance": body.get_instance_id(), "doorInstance": home_door.get_instance_id() if is_instance_valid(home_door) else 0}
    if not is_instance_valid(home_door) or bool(initial_home.get("strictInside", false)) or bool(home_door.get_meta("open", false)) or flat_distance(body.global_position, starter_door_position) > PORCH_LEAVE_DISTANCE:
        continue_approach.failure = "observation_must_begin_at_player_porch_outside_home_with_home_door_closed"
    continue_previous_door_open = bool(home_door.get_meta("open", false)) if is_instance_valid(home_door) else false
    continue_observation_active = true
    track_phase0_transitions(mira)

func track_phase0_transitions(entry: Dictionary) -> void:
    super.track_phase0_transitions(entry)
    if not continue_observation_active or entry.is_empty():
        return
    var body := entry.get("body") as Node3D
    var door := home_door_for_entry(entry)
    if not is_instance_valid(body) or not is_instance_valid(door) or body.get_instance_id() != int(continue_approach.bodyInstance) or door.get_instance_id() != int(continue_approach.doorInstance):
        continue_approach.failure = "observed_actor_or_door_replaced"
        report_data["continueLiveApproach"] = continue_approach
        return
    var autonomy = main.get("npc_system").get("autonomy_system")
    var home: Dictionary = autonomy.home_interior_status(entry, body.global_position)
    var opened := bool(door.get_meta("open", false))
    var crossing := bool(home.get("onDoorCell", false)) or bool(home.get("doorThresholdOccupied", false))
    var clear_inside := bool(home.get("strictInside", false)) and bool(home.get("clearOfDoor", false))
    var sample := {"physicsFrame": Engine.get_physics_frames(), "time": rounded(elapsed),
        "position": vec3(body.global_position), "doorOpen": opened, "home": home,
        "routePhysicsService": route_physics_service_summary(entry)}
    var events: Dictionary = continue_approach.events
    if not events.has("initial"):
        events["initial"] = sample
    var displacement := flat_distance(body.global_position, mira_ack_position)
    continue_approach.maxDisplacement = maxf(float(continue_approach.maxDisplacement), displacement)
    if displacement >= FIRST_DISPLACEMENT_DISTANCE and not events.has("displacement"):
        events["displacement"] = sample
    if opened and not continue_previous_door_open and not events.has("doorOpened"):
        events["doorOpened"] = sample
    if crossing and not events.has("doorCrossing"):
        events["doorCrossing"] = sample
        if not opened or not events.has("doorOpened") or int(events.doorOpened.physicsFrame) >= int(sample.physicsFrame):
            continue_approach.failure = "door_opening_not_observed_before_crossing"
    if clear_inside and not events.has("strictInteriorClear"):
        events["strictInteriorClear"] = sample
    if not opened and continue_previous_door_open and not events.has("doorClosed"):
        events["doorClosed"] = sample
        if not clear_inside or not events.has("strictInteriorClear") or int(events.strictInteriorClear.physicsFrame) >= int(sample.physicsFrame):
            continue_approach.failure = "door_closed_before_observed_interior_clearance"
    continue_previous_door_open = opened
    report_data["continueLiveApproach"] = continue_approach
