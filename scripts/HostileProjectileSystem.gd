extends Node3D
class_name HostileProjectileSystem

const CELL := 1.35

var main
var player: CharacterBody3D
var survival
var projectiles: Array = []
var projectile_pool: Array[MeshInstance3D] = []
var projectile_material: StandardMaterial3D
var projectile_mesh: SphereMesh
var projectile_nodes_created := 0
var projectile_nodes_reused := 0
var npc_target_hits := 0

func setup(main_node, player_node: CharacterBody3D, survival_system) -> void:
    main = main_node
    player = player_node
    survival = survival_system
    setup_projectile_assets()

func setup_projectile_assets() -> void:
    projectile_material = StandardMaterial3D.new()
    projectile_material.albedo_color = Color(0.58, 0.34, 0.96)
    projectile_material.emission_enabled = true
    projectile_material.emission = Color(0.34, 0.18, 0.82)
    projectile_mesh = SphereMesh.new()
    projectile_mesh.radius = 0.11
    projectile_mesh.height = 0.18
    projectile_mesh.radial_segments = 8
    projectile_mesh.rings = 4

func clear() -> void:
    for projectile_state in projectiles:
        recycle_projectile_node(projectile_state)
    projectiles.clear()

func spawn_projectile(start: Vector3, target: Vector3, damage := 8.0, owner: Node = null, target_node: Node = null, target_kind := "") -> MeshInstance3D:
    var direction: Vector3 = (target - start).normalized()
    var projectile := acquire_projectile_node()
    projectile.global_position = start
    projectile.visible = true
    projectiles.append({
        "mesh": projectile,
        "position": start,
        "velocity": direction * 18.0,
        "damage": damage,
        "owner": owner,
        "target": target_node,
        "targetKind": target_kind,
        "age": 0.0
    })
    return projectile

func update_projectiles(delta: float) -> void:
    for projectile_state in projectiles.duplicate():
        var mesh_value = projectile_state.get("mesh")
        if not is_instance_valid(mesh_value):
            projectiles.erase(projectile_state)
            continue
        var mesh := mesh_value as MeshInstance3D
        if mesh == null:
            projectiles.erase(projectile_state)
            continue
        var previous: Vector3 = projectile_state.get("position", mesh.global_position)
        var velocity: Vector3 = projectile_state.get("velocity", Vector3.ZERO)
        var next := previous + velocity * delta
        var query := PhysicsRayQueryParameters3D.create(previous, next)
        var owner_value = projectile_state.get("owner")
        var owner: Node = null
        if is_instance_valid(owner_value):
            owner = owner_value as Node
        query.exclude = [owner] if owner != null else []
        var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
        var block_hit: Dictionary = projectile_block_hit(previous, next)
        if bool(block_hit.get("hit", false)):
            var block_t := float(block_hit.get("t", 1.0))
            var physics_t := INF
            if not hit.is_empty():
                physics_t = previous.distance_to(hit.get("position", next)) / maxf(previous.distance_to(next), 0.001)
            if hit.is_empty() or block_t <= physics_t + 0.02:
                remove_projectile(projectile_state)
                continue
        if not hit.is_empty():
            var collider_value = hit.get("collider")
            var collider: Node = null
            if is_instance_valid(collider_value):
                collider = collider_value as Node
            var collider_kind := String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else ""
            if collider == player and survival:
                survival.apply_damage(float(projectile_state.get("damage", 8.0)), "Rift bolt", "hostile")
            elif collider_kind == "npc":
                npc_target_hits += 1
                collider.set_meta("npc_hostile_projectile_hits", int(collider.get_meta("npc_hostile_projectile_hits", 0)) + 1)
                collider.set_meta("npc_last_hostile_attack", "projectile")
                collider.set_meta("npc_last_hostile_attacker", owner.name if owner != null else "")
            remove_projectile(projectile_state)
            continue
        projectile_state["position"] = next
        mesh.global_position = next
        projectile_state["age"] = float(projectile_state.get("age", 0.0)) + delta
        if float(projectile_state.get("age", 0.0)) > 4.0 or next.distance_to(player.global_position) > 120.0:
            remove_projectile(projectile_state)

func acquire_projectile_node() -> MeshInstance3D:
    var projectile: MeshInstance3D
    if projectile_pool.is_empty():
        projectile = MeshInstance3D.new()
        projectile.name = "HostileProjectile_%03d" % projectile_nodes_created
        projectile.mesh = projectile_mesh
        projectile.material_override = projectile_material
        projectile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        add_child(projectile)
        projectile_nodes_created += 1
    else:
        projectile = projectile_pool.pop_back()
        projectile_nodes_reused += 1
    return projectile

func recycle_projectile_node(projectile_state: Dictionary) -> void:
    var mesh_value = projectile_state.get("mesh")
    if not is_instance_valid(mesh_value):
        return
    var mesh := mesh_value as MeshInstance3D
    if mesh == null:
        return
    mesh.visible = false
    mesh.scale = Vector3.ONE
    if projectile_pool.size() < 64:
        projectile_pool.append(mesh)

func remove_projectile(projectile_state: Dictionary) -> void:
    recycle_projectile_node(projectile_state)
    projectiles.erase(projectile_state)

func projectile_block_hit(previous: Vector3, next: Vector3) -> Dictionary:
    if main == null:
        return {}
    var blocks: Dictionary = main.get("blocks")
    if blocks.is_empty():
        return {}
    var segment := next - previous
    var length_sq := segment.length_squared()
    if length_sq < 0.0001:
        return {}
    var best_t := INF
    var steps := maxi(2, ceili(sqrt(length_sq) / (CELL * 0.35)))
    for i in range(steps + 1):
        var t := float(i) / float(steps)
        var point := previous + segment * t
        var cell := Vector3i(roundi(point.x / CELL), roundi(point.y / CELL), roundi(point.z / CELL))
        if not blocks.has(cell):
            continue
        var sampled_body := blocks[cell] as Node
        if sampled_body == null or first_enabled_box_collider(sampled_body) == null:
            continue
        best_t = minf(best_t, t)
    for block_value in blocks.values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        var collider := first_enabled_box_collider(body)
        if collider == null:
            continue
        var shape := collider.shape as BoxShape3D
        var center := body.global_position + collider.position
        var t := clampf((center - previous).dot(segment) / length_sq, 0.0, 1.0)
        if t >= best_t:
            continue
        var closest := previous + segment * t
        var half := shape.size * 0.5 + Vector3(0.08, 0.08, 0.08)
        var delta := closest - center
        if absf(delta.x) <= half.x and absf(delta.y) <= half.y and absf(delta.z) <= half.z:
            best_t = t
    if best_t < INF:
        return { "hit": true, "t": best_t }
    return {}

func first_enabled_box_collider(body: Node) -> CollisionShape3D:
    for child in body.get_children():
        if not (child is CollisionShape3D):
            continue
        var collider := child as CollisionShape3D
        if collider.disabled or not (collider.shape is BoxShape3D):
            continue
        return collider
    return null

func stats() -> Dictionary:
    return {
        "projectiles": projectiles.size(),
        "projectilePool": projectile_pool.size(),
        "projectileNodesCreated": projectile_nodes_created,
        "projectileNodesReused": projectile_nodes_reused,
        "hostileNpcProjectileHits": npc_target_hits
    }
