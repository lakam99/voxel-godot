extends RefCounted
class_name NpcCombat

const CELL := 1.35

var system
var hostile_system
var arrow_material: StandardMaterial3D
var tracer_pool: Array[MeshInstance3D] = []
var tracers: Array[Dictionary] = []
var tracer_nodes_created := 0
var last_shot_debug := {}

func setup(system_node, hostile_system_node, tracer_material: StandardMaterial3D) -> void:
    system = system_node
    hostile_system = hostile_system_node
    arrow_material = tracer_material

func clear() -> void:
    for tracer_state in tracers:
        recycle_tracer(tracer_state)
    tracers.clear()

func nearest_hostile(origin: Vector3, radius: float, owner: Node = null, prefer_clear_shot := false) -> Node3D:
    if hostile_system == null:
        return null
    var best: Node3D = null
    var best_dist := radius
    var best_clear: Node3D = null
    var best_clear_dist := radius
    var can_check_clear_shot := prefer_clear_shot and owner != null and is_instance_valid(owner) and system != null
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if hostile_system.has_method("hostile_available_for_npc_combat") and not bool(hostile_system.hostile_available_for_npc_combat(body, origin)):
            continue
        var distance := origin.distance_to(body.global_position)
        if distance < best_dist:
            best_dist = distance
            best = body
        if can_check_clear_shot and distance < best_clear_dist:
            var start := origin + Vector3(0.0, 1.58, 0.0)
            var end := body.global_position + Vector3(0.0, 1.02, 0.0)
            if bool(shot_visibility(owner, body, start, end).get("clear", false)):
                best_clear_dist = distance
                best_clear = body
    return best_clear if best_clear != null else best

func fire_at_hostile(entry: Dictionary, target: Node3D) -> void:
    if target == null or hostile_system == null or float(entry.get("cooldown", 0.0)) > 0.0:
        if float(entry.get("cooldown", 0.0)) > 0.0:
            record_shot_debug(entry, "cooldown", target)
        return
    var body := entry.get("body") as Node3D
    if body == null:
        record_shot_debug(entry, "missing_body", target)
        return
    var start := body.global_position + Vector3(0.0, 1.58, 0.0)
    var end := target.global_position + Vector3(0.0, 1.02, 0.0)
    var distance := start.distance_to(end)
    if distance > 42.0:
        record_shot_debug(entry, "out_of_range", target, { "distance": distance })
        return
    var visibility: Dictionary = shot_visibility(body, target, start, end)
    if not bool(visibility.get("clear", false)):
        record_shot_debug(entry, "line_blocked", target, visibility)
        return
    record_shot_debug(entry, "fired", target, { "distance": distance })
    system.face_position(body, target.global_position)
    system.play_npc_use(entry, "shoot")
    spawn_tracer(start, end)
    hostile_system.damage_hostile(target, 7.0, false, body, "npc_ranged")
    entry["cooldown"] = randf_range(1.65, 2.55)
    entry["guardShots"] = int(entry.get("guardShots", 0)) + 1
    entry["lastCombatAction"] = "shoot"
    body.set_meta("npc_guard_shots", int(entry["guardShots"]))
    body.set_meta("npc_last_combat_action", "shoot")
    system.guard_shots += 1
    system.last_message = "%s fired at a hostile" % String(entry.get("name", "Guard"))

func strike_hostile(entry: Dictionary, target: Node3D) -> void:
    if target == null or hostile_system == null or float(entry.get("cooldown", 0.0)) > 0.0:
        return
    var body := entry.get("body") as Node3D
    if body == null:
        return
    var flat_distance := Vector2(
        target.global_position.x - body.global_position.x,
        target.global_position.z - body.global_position.z
    ).length()
    if flat_distance > CELL * 1.82:
        return
    system.face_position(body, target.global_position)
    system.play_npc_use(entry, "strike")
    hostile_system.damage_hostile(target, 9.0, false, body, "npc_melee")
    entry["cooldown"] = randf_range(1.05, 1.55)
    entry["guardMeleeStrikes"] = int(entry.get("guardMeleeStrikes", 0)) + 1
    entry["lastCombatAction"] = "strike"
    body.set_meta("npc_guard_melee_strikes", int(entry["guardMeleeStrikes"]))
    body.set_meta("npc_last_combat_action", "strike")
    system.guard_melee_strikes += 1
    system.last_message = "%s struck a hostile" % String(entry.get("name", "Guard"))

func has_clear_shot(owner: Node, target: Node, start: Vector3, end: Vector3) -> bool:
    return bool(shot_visibility(owner, target, start, end).get("clear", false))

func shot_visibility(owner: Node, target: Node, start: Vector3, end: Vector3) -> Dictionary:
    var query := PhysicsRayQueryParameters3D.create(start, end)
    query.exclude = [owner]
    query.collision_mask = 1 | 4
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var hit: Dictionary = system.get_world_3d().direct_space_state.intersect_ray(query)
    if hit.is_empty():
        return { "clear": true, "distance": start.distance_to(end), "hit": "" }
    var collider: Object = hit.get("collider") as Object
    var clear: bool = collider == target
    var hit_position: Vector3 = hit.get("position", start)
    return {
        "clear": clear,
        "distance": start.distance_to(end),
        "hit": "target" if clear else _node_debug_name(collider),
        "hitPosition": hit_position,
        "hitDistance": start.distance_to(hit_position),
        "targetDistance": start.distance_to(end)
    }

func record_shot_debug(entry: Dictionary, reason: String, target: Node3D, extra := {}) -> void:
    var body := entry.get("body") as Node3D
    var target_position := target.global_position if target != null and is_instance_valid(target) else Vector3.ZERO
    var debug: Dictionary = {
        "npc": String(entry.get("name", entry.get("id", ""))),
        "reason": reason,
        "body": _node_debug_name(body),
        "bodyPosition": body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO,
        "target": _node_debug_name(target),
        "targetPosition": target_position
    }
    for key in extra.keys():
        debug[key] = extra[key]
    entry["lastShotDebug"] = debug
    last_shot_debug = debug

func debug_summary() -> Dictionary:
    return last_shot_debug.duplicate(true)

func _node_debug_name(value) -> String:
    var node := value as Node
    if node == null or not is_instance_valid(node):
        return ""
    var parent: Node = node.get_parent()
    var parent_name := String(parent.name) if parent != null else ""
    return "%s:%s" % [node.name, parent_name]

func spawn_tracer(start: Vector3, end: Vector3) -> void:
    var length := start.distance_to(end)
    if length <= 0.05:
        return
    var tracer := acquire_tracer()
    var mesh := tracer.mesh as BoxMesh
    if mesh:
        mesh.size = Vector3(0.035, 0.035, length)
    tracer.global_position = start.lerp(end, 0.5)
    tracer.look_at(end, Vector3.UP)
    tracer.visible = true
    tracers.append({ "node": tracer, "life": 0.22 })

func acquire_tracer() -> MeshInstance3D:
    var tracer: MeshInstance3D
    if tracer_pool.is_empty():
        tracer = MeshInstance3D.new()
        tracer.name = "NpcArrowTracer_%03d" % tracer_nodes_created
        var mesh := BoxMesh.new()
        mesh.size = Vector3(0.035, 0.035, 1.0)
        tracer.mesh = mesh
        tracer.material_override = arrow_material
        tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        system.add_child(tracer)
        tracer_nodes_created += 1
    else:
        tracer = tracer_pool.pop_back()
    return tracer

func recycle_tracer(tracer_state: Dictionary) -> void:
    var node := tracer_state.get("node") as MeshInstance3D
    if node == null or not is_instance_valid(node):
        return
    node.visible = false
    node.scale = Vector3.ONE
    if tracer_pool.size() < 48:
        tracer_pool.append(node)

func update_tracers(delta: float) -> void:
    for tracer_state in tracers.duplicate():
        var node := tracer_state.get("node") as Node
        if node == null or not is_instance_valid(node):
            tracers.erase(tracer_state)
            continue
        tracer_state["life"] = float(tracer_state.get("life", 0.0)) - delta
        if float(tracer_state.get("life", 0.0)) <= 0.0:
            recycle_tracer(tracer_state)
            tracers.erase(tracer_state)
