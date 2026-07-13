extends "res://scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd"

const STAGE_SAVE_POST_ACK := "save_post_ack"
const STAGE_CONTINUE_OBSERVE := "continue_observe"

var save_continue_stage := ""

func run() -> void:
    save_continue_stage = OS.get_environment("VOXEL_TUTORIAL_SAVE_CONTINUE_STAGE").strip_edges()
    await super.run()

func launch_main_via_menu_input() -> bool:
    if save_continue_stage != STAGE_CONTINUE_OBSERVE:
        return await super.launch_main_via_menu_input()
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
        if main != null and is_instance_valid(main) and not bool(main.get("startup_loading_active")):
            report_data["mainMenuLaunch"] = {
                "clickedViaInput": true,
                "mode": "continue",
                "frames": frame,
                "loadingActive": false
            }
            mark_progress("main_menu_continue_loaded")
            return true
        if frame % 60 == 0:
            mark_progress("main_menu_waiting_for_continue_load active=%s" % str(main != null))
    add_failure("main_menu_continue_timeout", "Continue button input did not produce a loaded Main scene")
    return false

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
    await wait_physics_frames(POST_ACTION_FRAMES)
    if not bool(tutorial_state_summary(tutorial).get("doorOpened", false)) or not hud_dialogue_open():
        add_failure("actual_input_path_failed_before_save", JSON.stringify(tutorial_state_summary(tutorial)))
        return
    var close_button := dialogue_close_button()
    if close_button == null:
        add_failure("dialogue_close_button_missing", "HUD dialogue was open but no visible Close button was found")
        return
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, true, "dialogue_close_button_press")
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, false, "dialogue_close_button_release")
    await wait_physics_frames(POST_ACTION_FRAMES)
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
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges()
    }
    report_data["postAckSave"] = result
    return result

func observe_after_continue() -> void:
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
    mira_ack_position = body.global_position
    mira_ack_position_valid = true
    record_phase0_event("continueObservationStart", {"mira": npc_summary(mira), "tutorialState": continued_state})
    var restored_order := scripted_order_summary(mira)
    report_data["continuedRestoredOrder"] = restored_order
    if String(restored_order.get("kind", "")) != "go_home" or String(restored_order.get("submissionReason", "")) != "tutorial_knock_complete":
        add_failure("continue_did_not_restore_generic_home_intent", JSON.stringify(restored_order))
        return
    await capture_stage("player_pov_continue_after_restore", {"mira": npc_summary(mira), "tutorialState": continued_state})
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
    if not mira_left_player_porch:
        add_failure("continue_mira_did_not_leave_player_porch", JSON.stringify(report_data["miraFinal"]))
        return
    if not is_finite(clearance_delay) or clearance_delay > MAX_PORCH_CLEARANCE_DELAY_SECONDS:
        add_failure("continue_mira_porch_clearance_slow", JSON.stringify({"delaySeconds": clearance_delay, "maximumSeconds": MAX_PORCH_CLEARANCE_DELAY_SECONDS}))
        return
    if not mira_reached_strict_home:
        add_failure("continue_mira_did_not_reach_strict_home", JSON.stringify(report_data["miraFinalHomeInteriorStatus"]))
        return
    results.append({
        "name": "post_ack_save_continue_restores_generic_home_intent_and_real_arrival",
        "passed": true,
        "details": "Live New Game input acknowledged the knock, the isolated save was loaded through Continue, and Mira cleared the player porch then reached strict home through normal NPC physics."
    })
    await finish()
