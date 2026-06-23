extends RefCounted
class_name NpcCombat

const CELL := 1.35

var system
var hostile_system
var arrow_material: StandardMaterial3D
var tracer_pool: Array[MeshInstance3D] = []
var tracers: Array[Dictionary] = []
var tracer_nodes_created := 0

func setup(system_node, hostile_system_node, tracer_material: StandardMaterial3D) -> void:
    system = system_node
    hostile_system = hostile_system_node
    arrow_material = tracer_material

func clear() -> void:
    for tracer_state in tracers:
        recycle_tracer(tracer_state)
    tracers.clear()

func nearest_hostile(origin: Vector3, radius: float) -> Node3D:
    if hostile_system == null:
        return null
    var best: Node3D = null
    var best_dist := radius
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        var distance := origin.distance_to(body.global_position)
        if distance < best_dist:
            best_dist = distance
            best = body
    return best

func fire_at_hostile(entry: Dictionary, target: Node3D) -> void:
    if target == null or hostile_system == null or float(entry.get("cooldown", 0.0)) > 0.0:
        return
    var body := entry.get("body") as StaticBody3D
    if body == null:
        return
    var start := body.global_position + Vector3(0.0, 1.58, 0.0)
    var end := target.global_position + Vector3(0.0, 1.02, 0.0)
    if start.distance_to(end) > 42.0 or not has_clear_shot(body, target, start, end):
        return
    system.face_position(body, target.global_position)
    system.play_npc_use(entry, "shoot")
    spawn_tracer(start, end)
    if not bool(target.get_meta("tutorial_rescue_hostile", false)):
        hostile_system.damage_hostile(target, 7.0, false)
    entry["cooldown"] = randf_range(1.65, 2.55)
    system.guard_shots += 1
    system.last_message = "%s fired at a hostile" % String(entry.get("name", "Guard"))

func strike_hostile(entry: Dictionary, target: Node3D) -> void:
    if target == null or hostile_system == null or float(entry.get("cooldown", 0.0)) > 0.0:
        return
    var body := entry.get("body") as StaticBody3D
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
    if not bool(target.get_meta("tutorial_rescue_hostile", false)):
        hostile_system.damage_hostile(target, 9.0, false)
    entry["cooldown"] = randf_range(1.05, 1.55)
    system.guard_melee_strikes += 1
    system.last_message = "%s struck a hostile" % String(entry.get("name", "Guard"))

func has_clear_shot(owner: Node, target: Node, start: Vector3, end: Vector3) -> bool:
    var query := PhysicsRayQueryParameters3D.create(start, end)
    query.exclude = [owner]
    query.collision_mask = 1 | 4
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var hit: Dictionary = system.get_world_3d().direct_space_state.intersect_ray(query)
    if hit.is_empty():
        return true
    return hit.get("collider") == target

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
