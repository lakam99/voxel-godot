extends RefCounted
class_name GameHudOverlayController

const GameHudRendererScript := preload("res://scripts/GameHudRenderer.gd")

static func play_sleep_fade(hud, fade_out := 0.55, hold := 0.45, fade_in := 0.70) -> void:
    if hud.sleep_fade_overlay == null:
        return
    if hud.sleep_fade_tween and hud.sleep_fade_tween.is_running():
        hud.sleep_fade_tween.kill()
    hud.sleep_fade_overlay.visible = true
    hud.sleep_fade_overlay.color = Color(0.0, 0.0, 0.0, 0.0)
    hud.sleep_fade_tween = hud.create_tween()
    hud.sleep_fade_tween.tween_property(hud.sleep_fade_overlay, "color:a", 1.0, fade_out)
    hud.sleep_fade_tween.tween_interval(hold)
    hud.sleep_fade_tween.tween_property(hud.sleep_fade_overlay, "color:a", 0.0, fade_in)
    hud.sleep_fade_tween.tween_callback(func():
        if hud.sleep_fade_overlay:
            hud.sleep_fade_overlay.visible = false
    )

static func show_victory(hud, stats: Array) -> void:
    if hud.victory_panel == null or hud.victory_stats_list == null:
        return
    hud.victory_panel.visible = true
    GameHudRendererScript.clear_container(hud.victory_stats_list)
    for row_value in stats:
        if not (row_value is Dictionary):
            continue
        var row: Dictionary = row_value
        var label := Label.new()
        label.text = str(row.get("label", ""))
        label.modulate = Color(0.82, 0.86, 0.80)
        hud.victory_stats_list.add_child(label)
        var value := Label.new()
        value.text = str(row.get("value", ""))
        value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        value.modulate = Color(1.0, 0.94, 0.70)
        hud.victory_stats_list.add_child(value)

static func show_dialogue(hud, speaker: String, role: String, body: String, context := {}) -> void:
    if hud.dialogue_panel == null:
        return
    hud.dialogue_context = context.duplicate(true) if context is Dictionary else {}
    hud.dialogue_speaker_label.text = speaker if speaker != "" else "Villager"
    hud.dialogue_role_label.text = role
    hud.dialogue_role_label.visible = role != ""
    hud.dialogue_body_label.text = body
    hud.dialogue_body_label.visible = hud.story_accessibility_bool("storySubtitles", true) if hud.has_method("story_accessibility_bool") else true
    hud.dialogue_reveal_elapsed = 0.0
    hud.dialogue_reveal_cps = hud.story_dialogue_cps() if hud.has_method("story_dialogue_cps") else -1.0
    hud.dialogue_body_label.visible_characters = 0 if hud.dialogue_reveal_cps > 0.0 else -1
    hud.dialogue_reply_label.visible = true
    hud.dialogue_panel.visible = true
    if hud.has_method("set_interaction_prompt"):
        hud.set_interaction_prompt("")
    elif hud.target_label:
        hud.target_label.text = ""
    if hud.inventory_panel:
        hud.inventory_panel.visible = false
    if hud.utility_panel:
        hud.utility_panel.visible = false
    if hud.objective_panel:
        hud.objective_panel.visible = false
    if hud.contract_panel:
        hud.contract_panel.visible = false
        if hud.contracts:
            hud.contracts.toggle_menu(false)
    if hud.teleport_panel:
        hud.teleport_panel.visible = false
    if hud.settings_panel:
        hud.settings_panel.visible = false
    if hud.playtest_panel:
        hud.playtest_panel.visible = false
    if hud.game_menu_panel:
        hud.game_menu_panel.visible = false
    var controller_navigation := true
    if hud.has_method("story_accessibility_bool"):
        controller_navigation = hud.story_accessibility_bool("storyControllerNavigation", true)
    if controller_navigation:
        hud.dialogue_panel.grab_focus()

static func hide_dialogue(hud, emit_signal := true) -> void:
    if hud.dialogue_panel == null or not hud.dialogue_panel.visible:
        return
    hud.dialogue_panel.visible = false
    var context: Dictionary = hud.dialogue_context.duplicate(true)
    hud.dialogue_context.clear()
    if emit_signal:
        hud.dialogue_closed.emit(context)
    if hud.dialogue_body_label:
        hud.dialogue_body_label.visible_characters = -1

static func show_objective_complete(hud, label: String) -> void:
    hud.objective_toast.text = "Objective Complete: %s" % label
    hud.objective_toast_time = 3.2
    hud.objective_toast.visible = true
    hud.objective_toast.modulate.a = 1.0

static func process(hud, delta: float) -> void:
    if hud.dialogue_panel != null and hud.dialogue_panel.visible and hud.dialogue_body_label != null and hud.dialogue_reveal_cps > 0.0:
        hud.dialogue_reveal_elapsed += delta
        var visible_count := roundi(hud.dialogue_reveal_elapsed * hud.dialogue_reveal_cps)
        hud.dialogue_body_label.visible_characters = mini(hud.dialogue_body_label.text.length(), visible_count)
    if hud.objective_toast_time > 0.0:
        hud.objective_toast_time = max(0.0, hud.objective_toast_time - delta)
        hud.objective_toast.modulate.a = clamp(hud.objective_toast_time / 0.8, 0.0, 1.0) if hud.objective_toast_time < 0.8 else 1.0
        if hud.objective_toast_time <= 0.0:
            hud.objective_toast.visible = false
    if hud.selected_item_time > 0.0 and hud.selected_item_label != null:
        hud.selected_item_time = max(0.0, hud.selected_item_time - delta)
        hud.selected_item_label.modulate.a = clamp(hud.selected_item_time / 0.55, 0.0, 1.0) if hud.selected_item_time < 0.55 else 1.0
        if hud.selected_item_time <= 0.0:
            hud.selected_item_label.visible = false
    if hud.notification_time > 0.0 and hud.notification_label != null:
        hud.notification_time = max(0.0, hud.notification_time - delta)
        hud.notification_label.modulate.a = clamp(hud.notification_time / 0.65, 0.0, 1.0) if hud.notification_time < 0.65 else 1.0
        if hud.notification_time <= 0.0:
            hud.notification_label.visible = false
