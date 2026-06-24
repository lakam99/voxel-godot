extends StaticBody3D
class_name GloamHartEncounter

signal phase_changed(phase)
signal resolved(resolution)

const MAX_HEALTH := 180.0
const PHASE_2_HEALTH := 120.0
const PHASE_3_HEALTH := 60.0
const ANIMATION_DURATIONS := {
    "idle_breathe": 1.4,
    "walk_stalk": 1.1,
    "charge_windup": 0.9,
    "charge_recovery": 0.8,
    "antler_sweep": 0.7,
    "storm_pulse": 1.0,
    "stagger_vulnerable": 1.2,
    "death": 1.3,
    "release_calm": 1.4
}

var main
var controller
var region_id := ""
var encounter_id := ""
var phase := 1
var health := MAX_HEALTH
var status := "inactive"
var release_available := false
var countermeasure_effect := false
var animation_state := ""
var animation_states_used: Array[String] = []
var animation_fallback_used := false
var state_elapsed := 0.0
var state_serial := 0
var pulse_count := 0
var minion_bodies: Array[Node] = []
var last_message := ""
var visual_root: Node3D
var storm_ring: MeshInstance3D

func _ready() -> void:
    set_meta("kind", "story_worldmark")
    set_meta("variant", "gloam_hart")
    if get_child_count() == 0:
        build_fallback_visual()

func setup(main_node, controller_node, config: Dictionary) -> void:
    main = main_node
    controller = controller_node
    region_id = String(config.get("regionId", ""))
    encounter_id = String(config.get("encounterId", "gloam_hart"))
    release_available = bool(config.get("releaseAvailable", false))
    countermeasure_effect = bool(config.get("countermeasureEffect", false))
    phase = clampi(int(config.get("phase", 1)), 1, 3)
    health = phase_start_health(phase)
    status = "active"
    global_position = config.get("position", global_position)
    if main != null and main.has_method("height_at_world"):
        global_position.y = main.height_at_world(global_position.x, global_position.z) + 0.15
    play_animation_state("idle_breathe")
    set_process(true)

func _process(delta: float) -> void:
    if status != "active":
        return
    state_elapsed += delta
    animate_fallback_visual(delta)
    if state_elapsed < current_state_duration():
        return
    complete_animation_state()
    choose_next_state()

func apply_player_damage(amount: float, source := "player") -> bool:
    if status != "active" or amount <= 0.0:
        return false
    var multiplier := 1.35 if animation_state == "stagger_vulnerable" else 1.0
    health = maxf(0.0, health - amount * multiplier)
    last_message = "Gloam Hart hit: %d" % ceili(health)
    if health <= 0.0:
        play_animation_state("death")
        resolve("slay")
        return true
    if phase < 3 and health <= PHASE_3_HEALTH:
        set_phase(3)
    elif phase < 2 and health <= PHASE_2_HEALTH:
        set_phase(2)
    return false

func try_release() -> bool:
    if status != "active":
        return false
    if phase < 3:
        last_message = "The release rite is not ready"
        return false
    if not release_available:
        last_message = "You do not know the old rite."
        return false
    play_animation_state("release_calm")
    resolve("release")
    return true

func force_animation_state(state_name: String) -> void:
    play_animation_state(state_name)

func play_animation_state(state_name: String) -> void:
    var next_state := state_name
    if not ANIMATION_DURATIONS.has(next_state):
        animation_fallback_used = true
        next_state = "idle_breathe"
    animation_state = next_state
    state_elapsed = 0.0
    state_serial += 1
    if not animation_states_used.has(next_state):
        animation_states_used.append(next_state)

func choose_next_state() -> void:
    if status != "active":
        return
    if phase == 1:
        if state_serial % 3 == 0:
            play_animation_state("charge_windup")
        elif state_serial % 2 == 0:
            play_animation_state("antler_sweep")
        else:
            play_animation_state("idle_breathe")
    elif phase == 2:
        if state_serial % 3 == 0:
            play_animation_state("storm_pulse")
        elif state_serial % 2 == 0:
            play_animation_state("charge_windup")
        else:
            play_animation_state("walk_stalk")
    else:
        if state_serial % 3 == 0:
            play_animation_state("storm_pulse")
        else:
            play_animation_state("stagger_vulnerable")

func complete_animation_state() -> void:
    match animation_state:
        "charge_windup":
            apply_close_damage(14.0, 5.2, "Gloam Hart charge")
            play_animation_state("charge_recovery")
        "antler_sweep":
            apply_close_damage(10.0, 3.8, "Gloam Hart antlers")
            play_animation_state("charge_recovery")
        "storm_pulse":
            apply_storm_pulse()
            play_animation_state("stagger_vulnerable")

func set_phase(next_phase: int) -> void:
    phase = clampi(next_phase, 1, 3)
    health = minf(health, phase_start_health(phase))
    last_message = "Gloam Hart phase %d" % phase
    if controller != null and controller.has_method("on_encounter_phase_changed"):
        controller.on_encounter_phase_changed(phase)
    phase_changed.emit(phase)
    if phase == 2:
        spawn_phase_minions()
        play_animation_state("storm_pulse")
    elif phase == 3:
        play_animation_state("stagger_vulnerable")

func phase_start_health(next_phase: int) -> float:
    if next_phase >= 3:
        return PHASE_3_HEALTH
    if next_phase == 2:
        return PHASE_2_HEALTH
    return MAX_HEALTH

func current_state_duration() -> float:
    return float(ANIMATION_DURATIONS.get(animation_state, 1.0))

func storm_pulse_damage() -> float:
    return 5.0 if countermeasure_effect else 12.0

func apply_storm_pulse() -> void:
    pulse_count += 1
    apply_close_damage(storm_pulse_damage(), 14.0, "Gloam Hart storm pulse")
    if phase >= 2 and minion_bodies.is_empty():
        spawn_phase_minions()

func apply_close_damage(amount: float, radius: float, label: String) -> void:
    if main == null or main.get("player") == null or main.get("survival_system") == null:
        return
    var player_node := main.get("player") as Node3D
    if player_node == null:
        return
    if player_node.global_position.distance_to(global_position) > radius:
        return
    var survival = main.get("survival_system")
    if survival != null and survival.has_method("apply_damage"):
        survival.apply_damage(amount, label, "hostile")

func spawn_phase_minions() -> int:
    if main == null or main.get("hostile_system") == null:
        return 0
    var hostile_system = main.get("hostile_system")
    var spawned := 0
    for i in range(2):
        var angle := (float(i) / 2.0) * TAU + PI * 0.25
        var position := global_position + Vector3(cos(angle) * 7.0, 0.0, sin(angle) * 7.0)
        if main.has_method("height_at_world"):
            position.y = main.height_at_world(position.x, position.z) + 0.72
        var body: StaticBody3D = hostile_system.spawn_enemy(position, "shadow") if hostile_system.has_method("spawn_enemy") else null
        if body == null:
            continue
        body.set_meta("story_minion", "gloam_hart")
        minion_bodies.append(body)
        var enemy: Dictionary = hostile_system.enemy_for_body(body) if hostile_system.has_method("enemy_for_body") else {}
        if not enemy.is_empty():
            enemy["aware"] = true
            enemy["daylightImmune"] = true
        spawned += 1
    return spawned

func cleanup_minions() -> void:
    if main == null or main.get("hostile_system") == null:
        minion_bodies.clear()
        return
    var hostile_system = main.get("hostile_system")
    for body in minion_bodies.duplicate():
        if body == null or not is_instance_valid(body):
            continue
        var enemy: Dictionary = hostile_system.enemy_for_body(body) if hostile_system.has_method("enemy_for_body") else {}
        if not enemy.is_empty() and hostile_system.has_method("remove_enemy"):
            hostile_system.remove_enemy(enemy, false)
        elif body is Node:
            (body as Node).queue_free()
    minion_bodies.clear()

func resolve(resolution: String) -> bool:
    if status != "active":
        return false
    status = "resolved"
    cleanup_minions()
    resolved.emit(resolution)
    if controller != null and controller.has_method("resolve_active_encounter"):
        return bool(controller.resolve_active_encounter(resolution))
    return true

func debug_state() -> Dictionary:
    return {
        "status": status,
        "regionId": region_id,
        "encounterId": encounter_id,
        "phase": phase,
        "health": health,
        "releaseAvailable": release_available,
        "countermeasureEffect": countermeasure_effect,
        "animationState": animation_state,
        "animationStatesUsed": animation_states_used.duplicate(),
        "animationFallbackUsed": animation_fallback_used,
        "pulseCount": pulse_count,
        "minions": minion_bodies.size(),
        "lastMessage": last_message
    }

func build_fallback_visual() -> void:
    visual_root = Node3D.new()
    visual_root.name = "GloamHartFallbackVisual"
    add_child(visual_root)
    var body_material := material(Color(0.18, 0.16, 0.20), Color(0.06, 0.10, 0.16), 0.35)
    var antler_material := material(Color(0.72, 0.80, 0.72), Color(0.18, 0.28, 0.22), 0.18)
    var storm_material := material(Color(0.48, 0.68, 0.92), Color(0.22, 0.46, 0.86), 0.9)
    add_mesh(visual_root, "Body", capsule_mesh(0.72, 1.7), body_material, Vector3(0.0, 1.05, 0.0), Vector3(PI * 0.5, 0.0, 0.0), Vector3(1.0, 0.92, 1.22))
    add_mesh(visual_root, "Chest", sphere_mesh(0.58, 0.72), body_material, Vector3(0.0, 1.32, -0.42), Vector3.ZERO, Vector3(1.0, 0.9, 0.82))
    add_mesh(visual_root, "Head", sphere_mesh(0.34, 0.46), body_material, Vector3(0.0, 1.78, -1.05), Vector3.ZERO, Vector3(0.82, 1.0, 1.08))
    for x in [-0.34, 0.34]:
        var side := -1.0 if x < 0.0 else 1.0
        add_mesh(visual_root, "AntlerStem", cylinder_mesh(0.045, 0.82, 5), antler_material, Vector3(x, 2.18, -1.05), Vector3(0.35, 0.0, 0.22 * side), Vector3.ONE)
        add_mesh(visual_root, "AntlerBranch", cylinder_mesh(0.035, 0.56, 5), antler_material, Vector3(x * 1.45, 2.38, -1.14), Vector3(0.82, 0.0, 1.05 * side), Vector3.ONE)
    for x in [-0.42, 0.42]:
        for z in [-0.42, 0.42]:
            add_mesh(visual_root, "Leg", cylinder_mesh(0.08, 1.0, 6), body_material, Vector3(x, 0.52, z), Vector3.ZERO, Vector3.ONE)
    storm_ring = add_mesh(visual_root, "StormRing", torus_mesh(1.22, 1.34), storm_material, Vector3(0.0, 1.26, 0.0), Vector3(PI * 0.5, 0.0, 0.0), Vector3.ONE) as MeshInstance3D
    var collider := CollisionShape3D.new()
    var shape := CapsuleShape3D.new()
    shape.radius = 0.95
    shape.height = 2.4
    collider.shape = shape
    collider.position.y = 1.2
    add_child(collider)

func animate_fallback_visual(delta: float) -> void:
    if visual_root != null:
        var breathe := sin(Time.get_ticks_msec() * 0.004) * 0.035
        visual_root.scale = Vector3(1.0 + breathe, 1.0 - breathe * 0.5, 1.0 + breathe)
    if storm_ring != null:
        storm_ring.rotate_y(delta * (1.4 + float(phase) * 0.4))
        storm_ring.visible = animation_state in ["storm_pulse", "stagger_vulnerable", "release_calm"]

func material(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()
    mat.albedo_color = albedo
    mat.roughness = 0.72
    mat.emission_enabled = true
    mat.emission = emission
    mat.emission_energy_multiplier = energy
    return mat

func add_mesh(parent: Node, node_name: String, mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3, scl: Vector3) -> MeshInstance3D:
    var node := MeshInstance3D.new()
    node.name = node_name
    node.mesh = mesh
    node.material_override = mat
    node.position = pos
    node.rotation = rot
    node.scale = scl
    parent.add_child(node)
    return node

func sphere_mesh(radius: float, height: float) -> SphereMesh:
    var mesh := SphereMesh.new()
    mesh.radius = radius
    mesh.height = height
    mesh.radial_segments = 10
    mesh.rings = 5
    return mesh

func cylinder_mesh(radius: float, height: float, segments: int) -> CylinderMesh:
    var mesh := CylinderMesh.new()
    mesh.top_radius = radius
    mesh.bottom_radius = radius
    mesh.height = height
    mesh.radial_segments = segments
    return mesh

func capsule_mesh(radius: float, height: float) -> CapsuleMesh:
    var mesh := CapsuleMesh.new()
    mesh.radius = radius
    mesh.height = height
    mesh.radial_segments = 10
    mesh.rings = 4
    return mesh

func torus_mesh(inner: float, outer: float) -> TorusMesh:
    var mesh := TorusMesh.new()
    mesh.inner_radius = inner
    mesh.outer_radius = outer
    mesh.ring_segments = 20
    mesh.rings = 6
    return mesh
