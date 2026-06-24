extends RefCounted
class_name Phase14StoryPolishTests

const StoryAuthoringValidatorScript := preload("res://scripts/story/tools/StoryAuthoringValidator.gd")

func run(main: Node) -> Dictionary:
    var problems: Array[String] = []
    if main == null:
        return result(false, "main missing")
    var baseline: Dictionary = main.create_save_snapshot() if main.has_method("create_save_snapshot") else {}
    var validation := StoryAuthoringValidatorScript.new().validate_all()
    if not bool(validation.get("ok", false)):
        problems.append("validator %s" % str(validation.get("problems", [])))
    validate_accessibility(main, problems)
    validate_debug_tools(main, problems)
    validate_performance_and_replay(main, problems)
    if not baseline.is_empty() and main.has_method("apply_save_snapshot"):
        main.apply_save_snapshot(baseline)
    return result(problems.is_empty(), "; ".join(problems) if not problems.is_empty() else "authoring validation, accessibility, debug commands, replay, and budgets passed")

func validate_accessibility(main: Node, problems: Array[String]) -> void:
    var hud = main.get("hud")
    var accessibility = main.get("story_accessibility_settings")
    if hud == null or accessibility == null:
        problems.append("accessibility nodes missing")
        return
    main.apply_runtime_setting("storyTextSpeed", 1.0)
    main.apply_runtime_setting("storyJournalFontScale", 1.25)
    main.apply_runtime_setting("storySubtitles", false)
    main.apply_runtime_setting("storyColorIndependentClues", true)
    main.apply_runtime_setting("storyReplayDiscoveredText", true)
    main.apply_runtime_setting("storyControllerNavigation", true)
    var state: Dictionary = accessibility.state()
    if absf(float(state.get("storyTextSpeed", 0.0)) - 1.0) > 0.01 or absf(float(state.get("storyJournalFontScale", 0.0)) - 1.25) > 0.01:
        problems.append("story accessibility sliders did not apply")
    if not hud.setting_controls.has("storyTextSpeed") or not hud.setting_controls.has("storyJournalFontScale") or not hud.setting_controls.has("storySubtitles"):
        problems.append("settings UI missing story controls")
    hud.show_dialogue("Mira", "Archivist", "The storm is staying where it should move on.", {})
    if hud.dialogue_body_label == null or hud.dialogue_body_label.visible:
        problems.append("subtitle toggle did not hide dialogue text")
    main.apply_runtime_setting("storySubtitles", true)
    hud.show_dialogue("Mira", "Archivist", "The storm is staying where it should move on.", {})
    if hud.dialogue_body_label == null or not hud.dialogue_body_label.visible:
        problems.append("subtitle toggle did not restore dialogue text")
    if hud.dialogue_body_label != null and int(hud.dialogue_body_label.visible_characters) != 0:
        problems.append("story text speed did not enable dialogue reveal")
    main.apply_runtime_setting("storyTextSpeed", 2.0)
    hud.hide_dialogue(false)

func validate_debug_tools(main: Node, problems: Array[String]) -> void:
    var debug_tools = main.get("story_debug_tools")
    if debug_tools == null or not debug_tools.has_method("run_command"):
        problems.append("story debug tools missing")
        return
    var jump: Dictionary = debug_tools.run_command("jump_to_quest_stage", { "stage": "encounter_locked_placeholder" })
    if not bool(jump.get("ok", false)):
        problems.append("jump stage failed")
        return
    var clue: Dictionary = debug_tools.run_command("reveal_clue", { "definitionId": "historical_old_compact" })
    var entered: Dictionary = debug_tools.run_command("enter_region", {})
    var started: Dictionary = debug_tools.run_command("start_encounter", {})
    var resolved: Dictionary = debug_tools.run_command("choose_resolution", { "resolution": "release" })
    var advanced: Dictionary = debug_tools.run_command("advance_aftermath_day", { "days": 1.0 })
    var dumped: Dictionary = debug_tools.run_command("dump_region_record", {})
    main.get("story_director").generated_text["narrativeText"] = { "debug": { "text": "cached" } }
    var cleared: Dictionary = debug_tools.run_command("clear_generated_prose_cache", {})
    if not bool(clue.get("ok", false)) or not bool(entered.get("ok", false)) or not bool(started.get("ok", false)) or not bool(resolved.get("ok", false)) or not bool(advanced.get("ok", false)) or not bool(dumped.get("ok", false)) or not bool(cleared.get("ok", false)):
        problems.append("debug command chain failed %s %s %s %s %s %s %s" % [str(clue), str(entered), str(started), str(resolved), str(advanced), str(dumped), str(cleared)])

func validate_performance_and_replay(main: Node, problems: Array[String]) -> void:
    var director = main.get("story_director")
    var overlay = main.get("story_world_overlay_system")
    var journal = main.get("story_journal_model")
    var controller = main.get("worldmark_encounter_controller")
    if director == null or overlay == null or journal == null or controller == null:
        problems.append("story systems missing for performance/replay")
        return
    var quest: Dictionary = director.quest_system.first_quest()
    var region_id := String(quest.get("affectedRegionId", ""))
    if region_id != "":
        overlay.ensure_sites_for_region(region_id)
        overlay.spawn_region_overlay(region_id)
    var overlay_perf: Dictionary = overlay.performance_state() if overlay.has_method("performance_state") else {}
    var encounter_perf: Dictionary = controller.performance_state() if controller.has_method("performance_state") else {}
    var replay: Array = journal.replay_entries() if journal.has_method("replay_entries") else []
    var perf_state: Dictionary = main.debug_performance_state()
    if overlay_perf.is_empty() or not bool(overlay_perf.get("budgetOk", false)):
        problems.append("overlay performance budget failed %s" % str(overlay_perf))
    if encounter_perf.is_empty() or not bool(encounter_perf.get("budgetOk", false)):
        problems.append("encounter performance budget failed %s" % str(encounter_perf))
    if not perf_state.has("story"):
        problems.append("main performance state missing story section")
    if replay.is_empty():
        problems.append("journal replay entries missing")

func result(ok: bool, details: String) -> Dictionary:
    return {
        "ok": ok,
        "details": details
    }
