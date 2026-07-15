extends RefCounted
class_name MissionTransitionRunner

## Generic responsive fade/loading bridge for atomic mission scene preparation.

var main
var active := false
var dot_index := 0
var last_dot_usec := 0

func setup(main_node) -> void:
    main = main_node

func begin(message: String) -> void:
    if active:
        return
    active = true
    dot_index = 0
    last_dot_usec = Time.get_ticks_usec()
    var hud = main.get("hud") if main != null else null
    if hud != null:
        var fade := hud.get("sleep_fade_overlay") as ColorRect
        if fade != null:
            fade.visible = true
            fade.color = Color(0.0, 0.0, 0.0, 0.0)
            var tween = hud.create_tween()
            tween.tween_property(fade, "color:a", 1.0, 0.22)
            await tween.finished
        if hud.has_method("show_loading_overlay"):
            hud.call("show_loading_overlay", message)
    set_simulation_enabled(false)
    await pulse(message)

func pulse(message: String) -> void:
    if not active:
        return
    var now := Time.get_ticks_usec()
    if now - last_dot_usec >= 220000:
        dot_index = (dot_index + 1) % 4
        last_dot_usec = now
    var hud = main.get("hud") if main != null else null
    if hud != null and hud.has_method("set_loading_message"):
        hud.call("set_loading_message", "%s%s" % [message, ".".repeat(dot_index)])
    var tree: SceneTree = main.get_tree() if main != null else null
    if tree != null:
        await tree.process_frame

func finish() -> void:
    if not active:
        return
    var hud = main.get("hud") if main != null else null
    if hud != null and hud.has_method("hide_loading_overlay"):
        hud.call("hide_loading_overlay")
    set_simulation_enabled(true)
    if hud != null:
        var fade := hud.get("sleep_fade_overlay") as ColorRect
        if fade != null:
            var tween = hud.create_tween()
            tween.tween_property(fade, "color:a", 0.0, 0.32)
            await tween.finished
            fade.visible = false
    active = false

func set_simulation_enabled(enabled: bool) -> void:
    if main == null:
        return
    var player = main.get("player") as Node
    if player != null:
        player.set_physics_process(enabled)
    if main.has_method("set_registered_npc_physics_enabled"):
        main.call("set_registered_npc_physics_enabled", enabled)
