extends RefCounted
class_name TutorialRescueSystem

const CELL := 1.35
const FENCE_RADIUS_CELLS := 25
const RESCUE_MONSTER_COUNT := 6
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"

var system
var main

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main

func start_final_night() -> bool:
    if system.final_night_active or system.final_night_complete:
        return false
    system.final_night_active = true
    system.final_night_defeats_start = current_hostile_defeats()
    system.rescue_escort_started = false
    system.rescue_returning = false
    system.rescue_return_elapsed = 0.0
    system.rescue_hostiles.clear()
    system.complete_step("finalNightStarted")
    if main:
        main.time_of_day = 0.86
        if main.weather_system and main.player:
            main.weather_system.force_weather("rain", 0.58, 0.76, main.player.global_position)
        if main.hostile_system:
            main.hostile_system.clear()
            main.hostile_system.spawn_cooldown = 0.0
        setup_rescue_scene()
        if main.has_method("update_sky"):
            main.update_sky(0.0)
    return true

func complete_final_night() -> bool:
    if system.final_night_complete:
        return false
    system.final_night_active = false
    system.final_night_complete = true
    system.rescue_returning = false
    system.rescue_escort_started = true
    system.complete_step("finalNightComplete")
    system.complete_step("miraBlessing")
    system.last_message = "Niko is safe inside the lanterns. Dawn can come now."
    system.last_dialogue.clear()
    if main:
        var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
        var guard := find_tutorial_npc(RESCUE_GUARD_ID)
        if forager:
            forager.set_meta("npc_force_hold", false)
        if main.npc_system:
            if forager:
                main.npc_system.clear_scripted_target(forager)
            if guard:
                main.npc_system.clear_scripted_target(guard)
        if main.hostile_system:
            main.hostile_system.clear()
    clear_rescue_torch()
    return true

func final_night_defeats() -> int:
    if not system.final_night_active and not system.final_night_complete:
        return 0
    if system.final_night_complete:
        return RESCUE_MONSTER_COUNT
    return max(0, RESCUE_MONSTER_COUNT - rescue_remaining_hostiles())

func current_hostile_defeats() -> int:
    if main == null or main.hostile_system == null:
        return 0
    return int(main.hostile_system.stats().get("defeated", 0))

func setup_rescue_scene() -> void:
    if main == null or system.town.is_empty():
        return
    system.rescue_site = choose_rescue_site()
    clear_rescue_torch()
    spawn_rescue_torch(system.rescue_site)
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager:
        forager.global_position = system.rescue_site
        forager.set_meta("npc_force_hold", true)
        forager.set_meta("npc_rescue_stranded", true)
        show_speech_bubble(RESCUE_FORAGER_ID, "Help!", 3.8)
    spawn_rescue_hostiles()

func choose_rescue_site() -> Vector3:
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var base_angle := -0.55
    var radius := float(FENCE_RADIUS_CELLS + 13) * CELL
    for attempt in range(12):
        var angle := base_angle + float(attempt) * 0.28
        var position := Vector3(float(center_x) * CELL + cos(angle) * radius, 0.0, float(center_z) * CELL + sin(angle) * radius)
        var ground_y: float = main.height_at_world(position.x, position.z)
        if ground_y < main.WATER_LEVEL + 0.8:
            continue
        position.y = ground_y + 0.06
        return position
    var fallback := Vector3(float(center_x + FENCE_RADIUS_CELLS + 10) * CELL, 0.0, float(center_z + 4) * CELL)
    fallback.y = main.height_at_world(fallback.x, fallback.z) + 0.06
    return fallback

func spawn_rescue_torch(position: Vector3) -> void:
    if system.light_root == null:
        return
    var root := Node3D.new()
    root.name = "RescueTorch"
    root.position = position + Vector3(0.0, 0.04, 0.0)
    var pole_mesh := CylinderMesh.new()
    pole_mesh.top_radius = 0.045
    pole_mesh.bottom_radius = 0.06
    pole_mesh.height = 0.92
    pole_mesh.radial_segments = 6
    var pole := MeshInstance3D.new()
    pole.mesh = pole_mesh
    pole.material_override = system.make_material(Color(0.30, 0.16, 0.08), 0.72)
    pole.position.y = 0.46
    root.add_child(pole)
    var flame_mesh := SphereMesh.new()
    flame_mesh.radius = 0.18
    flame_mesh.height = 0.26
    flame_mesh.radial_segments = 8
    flame_mesh.rings = 4
    var flame := MeshInstance3D.new()
    flame.mesh = flame_mesh
    flame.material_override = system.make_emissive_material(Color(1.0, 0.58, 0.16), 1.8)
    flame.position.y = 1.02
    root.add_child(flame)
    var light := OmniLight3D.new()
    light.name = "RescueTorchLight"
    light.light_color = Color(1.0, 0.66, 0.34)
    light.light_energy = 1.85
    light.omni_range = CELL * 9.0
    root.add_child(light)
    system.light_root.add_child(root)
    system.rescue_torch = root

func clear_rescue_torch() -> void:
    if system.rescue_torch != null and is_instance_valid(system.rescue_torch):
        system.rescue_torch.queue_free()
    system.rescue_torch = null

func spawn_rescue_hostiles() -> void:
    if main == null or main.hostile_system == null:
        return
    system.rescue_hostiles.clear()
    for i in range(RESCUE_MONSTER_COUNT):
        var angle := TAU * float(i) / float(RESCUE_MONSTER_COUNT)
        var radius := CELL * (3.7 + 0.35 * float(i % 2))
        var position: Vector3 = system.rescue_site + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
        position.y = main.height_at_world(position.x, position.z) + 0.72
        var variant := "seer" if i == RESCUE_MONSTER_COUNT - 1 else "shadow"
        var body: StaticBody3D = main.hostile_system.spawn_enemy(position, variant)
        if body == null:
            continue
        body.set_meta("tutorial_rescue_hostile", true)
        var enemy: Dictionary = main.hostile_system.enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["daylightImmune"] = true
            enemy["tutorialRescue"] = true
            enemy["spawnOrigin"] = system.rescue_site
            enemy["awarenessDelay"] = 0.0
        system.rescue_hostiles.append(body)

func start_rescue_escort() -> void:
    if system.rescue_escort_started:
        return
    system.rescue_escort_started = true
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard and main and main.npc_system:
        var guard_target: Vector3 = system.rescue_site + Vector3(-CELL * 1.45, 0.0, -CELL * 1.0)
        guard_target.y = main.height_at_world(guard_target.x, guard_target.z) + 0.04
        main.npc_system.set_scripted_target(guard, guard_target, true, true)
    show_speech_bubble(RESCUE_GUARD_ID, "With me!", 2.5)
    show_speech_bubble(RESCUE_FORAGER_ID, "Over here!", 3.2)

func refresh_rescue_progress(delta := -1.0) -> bool:
    if not system.final_night_active or system.final_night_complete:
        return false
    if system.rescue_site == Vector3.ZERO:
        setup_rescue_scene()
    if not system.rescue_returning and rescue_remaining_hostiles() <= 0:
        start_rescue_return()
        return true
    if system.rescue_returning:
        system.rescue_return_elapsed += delta if delta >= 0.0 else system.get_process_delta_time()
        if rescue_party_home() or system.rescue_return_elapsed >= 8.0:
            if system.rescue_return_elapsed >= 8.0:
                settle_rescue_party_home()
            return complete_final_night()
    return false

func rescue_remaining_hostiles() -> int:
    if main == null or main.hostile_system == null:
        return 0
    var remaining := 0
    for body_variant in system.rescue_hostiles.duplicate():
        var body := body_variant as Node
        if body == null or not is_instance_valid(body):
            system.rescue_hostiles.erase(body_variant)
            continue
        if main.hostile_system.enemy_for_body(body).is_empty():
            system.rescue_hostiles.erase(body_variant)
            continue
        remaining += 1
    return remaining

func start_rescue_return() -> void:
    system.rescue_returning = true
    system.rescue_return_elapsed = 0.0
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    var home := rescue_return_position()
    if forager:
        forager.set_meta("npc_force_hold", false)
        forager.set_meta("npc_rescue_stranded", false)
        if main and main.npc_system:
            main.npc_system.set_scripted_target(forager, home, true, true)
    if guard and main and main.npc_system:
        main.npc_system.set_scripted_target(guard, home + Vector3(CELL * 0.65, 0.0, CELL * 0.65), true, true)
    show_speech_bubble(RESCUE_FORAGER_ID, "I can move!", 2.8)
    show_speech_bubble(RESCUE_GUARD_ID, "Back to town!", 2.8)

func rescue_return_position() -> Vector3:
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager:
        var home_cell: Vector2i = forager.get_meta("npc_home_cell", Vector2i(int(system.town.get("centerX", 0)), int(system.town.get("centerZ", 0))))
        return Vector3(float(home_cell.x) * CELL, float(system.town.get("level", 16.0)) + 0.04, float(home_cell.y) * CELL)
    return Vector3(float(system.town.get("centerX", 0)) * CELL, float(system.town.get("level", 16.0)) + 0.04, float(system.town.get("centerZ", 0)) * CELL)

func rescue_party_home() -> bool:
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    if forager == null:
        return true
    return forager.global_position.distance_to(rescue_return_position()) <= CELL * 1.35

func settle_rescue_party_home() -> void:
    var home := rescue_return_position()
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if forager:
        forager.global_position = home
    if guard:
        guard.global_position = home + Vector3(CELL * 0.75, 0.0, CELL * 0.75)

func find_tutorial_npc(npc_id: String) -> StaticBody3D:
    if system.npc_root == null:
        return null
    for child in system.npc_root.get_children():
        var body := child as StaticBody3D
        if body != null and String(body.get_meta("npc_id", "")) == npc_id:
            return body
    return null

func show_speech_bubble(npc_id: String, text: String, duration := 2.6) -> void:
    var npc := find_tutorial_npc(npc_id)
    if npc == null:
        return
    var existing := npc.get_node_or_null("SpeechBubble")
    if existing:
        existing.queue_free()
    var label := Label3D.new()
    label.name = "SpeechBubble"
    label.text = text
    label.font_size = 34
    label.position.y = 2.34
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    label.modulate = Color(1.0, 0.96, 0.78, 1.0)
    npc.add_child(label)
    system.speech_bubbles.append({ "node": label, "life": duration, "duration": duration })

func update_speech_bubbles(delta: float) -> void:
    for bubble in system.speech_bubbles.duplicate():
        var node := bubble.get("node") as Label3D
        if node == null or not is_instance_valid(node):
            system.speech_bubbles.erase(bubble)
            continue
        var life := float(bubble.get("life", 0.0)) - delta
        bubble["life"] = life
        var duration := maxf(0.1, float(bubble.get("duration", 1.0)))
        node.modulate.a = clampf(life / duration, 0.0, 1.0)
        if life <= 0.0:
            system.speech_bubbles.erase(bubble)
            node.queue_free()

func clear_speech_bubbles() -> void:
    for bubble in system.speech_bubbles:
        var node := bubble.get("node") as Node
        if node != null and is_instance_valid(node):
            node.queue_free()
    system.speech_bubbles.clear()
