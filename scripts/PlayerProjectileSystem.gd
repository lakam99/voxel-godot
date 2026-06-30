extends Node3D
class_name PlayerProjectileSystem

signal hostile_hit(variant, defeated, position)
signal story_worldmark_hit(resolved, position)

var player: CharacterBody3D
var inventory
var hostile_system
var catalog := {}
var block_registry: Dictionary = {}
var projectiles: Array = []
var tracer_pool: Array[MeshInstance3D] = []
var last_message := ""
var tracer_material: StandardMaterial3D
var tracer_nodes_created := 0
var tracer_nodes_reused := 0
var shots_fired_count := 0
var last_hit_kind := ""
var last_hit_travel := -1.0
var last_manual_block_candidates := 0
var last_manual_block_hits := 0
var last_manual_block_cell := Vector3i.ZERO
var last_manual_block_type := ""

func setup(player_node: CharacterBody3D, inventory_system, hostile_system_node, catalog_value: Dictionary, blocks_value: Dictionary = {}) -> void:
    player = player_node
    inventory = inventory_system
    hostile_system = hostile_system_node
    catalog = catalog_value
    block_registry = blocks_value
    tracer_material = StandardMaterial3D.new()
    tracer_material.albedo_color = Color(0.86, 0.74, 0.42, 0.86)
    tracer_material.emission_enabled = true
    tracer_material.emission = Color(0.64, 0.44, 0.12)
    tracer_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    set_process(true)

func is_ranged_item(item_id: String) -> bool:
    return catalog.has(item_id) and catalog[item_id] is Dictionary and (catalog[item_id] as Dictionary).has("ranged")

func fire_active() -> bool:
    if player == null or inventory == null:
        last_message = "No ranged weapon ready"
        return false
    var stack: Dictionary = inventory.active_stack()
    var item_id := String(stack.get("item", ""))
    if not is_ranged_item(item_id):
        last_message = "No ranged weapon ready"
        return false
    var spec: Dictionary = catalog[item_id].get("ranged", {})
    var ammo := String(spec.get("ammo", ""))
    if ammo == "" or inventory.count(ammo) <= 0:
        last_message = "%s needs %s" % [label(item_id), label(ammo)]
        return false
    if not inventory.consume_costs({ ammo: 1 }):
        last_message = "%s needs %s" % [label(item_id), label(ammo)]
        return false
    shots_fired_count += 1

    var camera := player.get("camera") as Camera3D
    if camera == null:
        last_message = "No aim"
        return false
    var origin := camera.global_position
    var direction := -camera.global_transform.basis.z.normalized()
    var range := float(spec.get("range", 34.0))
    var end := origin + direction * range
    var hit: Dictionary = projectile_hit(origin, direction, range)
    var target := end
    if not hit.is_empty():
        target = hit.get("position", end)
    spawn_tracer(origin + direction * 0.65, target)

    if hit.is_empty():
        last_message = "%s missed" % label(item_id)
        return true

    var collider := hit.get("collider") as Node
    if collider and collider.has_meta("kind") and String(collider.get_meta("kind")) == "hostile" and hostile_system:
        var variant := String(collider.get_meta("variant", "shadow"))
        var defeated: bool = hostile_system.damage_hostile(collider, maxf(1.0, float(spec.get("damage", 1.0))), true, player, "player_ranged")
        hostile_hit.emit(variant, defeated, target)
        last_message = hostile_system.last_message
        return true

    if collider and collider.has_meta("kind") and String(collider.get_meta("kind")) == "story_worldmark":
        var controller = story_worldmark_controller()
        if controller != null and controller.has_method("damage_active_encounter"):
            var resolved: bool = bool(controller.damage_active_encounter(maxf(1.0, float(spec.get("damage", 1.0))), "ranged"))
            story_worldmark_hit.emit(resolved, target)
            last_message = String(controller.get("last_message"))
            return true

    if collider and collider.has_meta("kind") and String(collider.get_meta("kind")) == "prop" and String(collider.get_meta("material", "")) == "wildlife":
        var parent := get_parent()
        if parent != null and parent.has_method("complete_destroy_target"):
            if not hit.has("normal"):
                hit["normal"] = Vector3.UP
            parent.complete_destroy_target(hit, collider, "prop", "wildlife")
            last_message = "Wildlife dropped"
            return true

    last_message = "%s blocked" % label(item_id)
    return true

func projectile_hit(origin: Vector3, direction: Vector3, range: float) -> Dictionary:
    last_hit_kind = "miss"
    last_hit_travel = -1.0
    last_manual_block_candidates = 0
    last_manual_block_hits = 0
    last_manual_block_cell = Vector3i.ZERO
    last_manual_block_type = ""
    var right := direction.cross(Vector3.UP)
    if right.length_squared() < 0.001:
        right = Vector3.RIGHT
    right = right.normalized()
    var up := right.cross(direction).normalized()
    var radius := 0.18
    var offsets: Array[Vector3] = [
        Vector3.ZERO,
        right * radius,
        -right * radius,
        up * radius,
        -up * radius
    ]
    var best_hit: Dictionary = {}
    var best_travel := INF
    for offset in offsets:
        var start := origin + offset
        var end := start + direction * range
        var query := PhysicsRayQueryParameters3D.create(start, end)
        query.exclude = [player]
        query.collision_mask = 0xFFFFFFFF
        query.collide_with_bodies = true
        query.collide_with_areas = false
        query.hit_from_inside = true
        var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
        if hit.is_empty():
            continue
        var raw_position: Vector3 = hit.get("position", end)
        var travel := clampf((raw_position - start).dot(direction), 0.0, range)
        if travel >= best_travel:
            continue
        best_travel = travel
        best_hit = hit
        best_hit["position"] = origin + direction * travel
        best_hit["raw_position"] = raw_position
        best_hit["travel"] = travel
    var block_hit := manual_block_hit(origin, direction, range)
    if not block_hit.is_empty() and float(block_hit.get("travel", INF)) < best_travel:
        best_hit = block_hit
    if not best_hit.is_empty():
        var collider := best_hit.get("collider") as Node
        last_hit_kind = String(collider.get_meta("kind", "unknown")) if collider != null else "unknown"
        last_hit_travel = float(best_hit.get("travel", -1.0))
    return best_hit

func manual_block_hit(origin: Vector3, direction: Vector3, range: float) -> Dictionary:
    var source_blocks := current_block_registry()
    if source_blocks.is_empty():
        return {}
    var best_hit: Dictionary = {}
    var best_travel := INF
    for block_value in source_blocks.values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        last_manual_block_candidates += 1
        for child in body.get_children():
            var collider := child as CollisionShape3D
            if collider == null or collider.disabled or not (collider.shape is BoxShape3D):
                continue
            var box := collider.shape as BoxShape3D
            var half := box.size * 0.5 + Vector3.ONE * 0.12
            var center := collider.global_position
            var travel := ray_aabb_intersection(origin, direction, center - half, center + half, range)
            if travel < 0.0 or travel >= best_travel:
                continue
            last_manual_block_hits += 1
            best_travel = travel
            last_manual_block_cell = body.get_meta("cell", Vector3i.ZERO)
            last_manual_block_type = String(body.get_meta("block_type", ""))
            best_hit = {
                "collider": body,
                "position": origin + direction * travel,
                "raw_position": origin + direction * travel,
                "travel": travel
            }
    return best_hit

func current_block_registry() -> Dictionary:
    var parent := get_parent()
    if parent:
        var parent_blocks = parent.get("blocks")
        if parent_blocks is Dictionary:
            return parent_blocks
    return block_registry

func story_worldmark_controller():
    var parent := get_parent()
    if parent == null:
        return null
    return parent.get("worldmark_encounter_controller")

func ray_aabb_intersection(origin: Vector3, direction: Vector3, box_min: Vector3, box_max: Vector3, max_distance: float) -> float:
    var t_min := 0.0
    var t_max := max_distance
    for axis in range(3):
        var axis_origin := vector_axis(origin, axis)
        var axis_direction := vector_axis(direction, axis)
        var axis_min := vector_axis(box_min, axis)
        var axis_max := vector_axis(box_max, axis)
        if absf(axis_direction) < 0.00001:
            if axis_origin < axis_min or axis_origin > axis_max:
                return -1.0
            continue
        var inverse := 1.0 / axis_direction
        var t1 := (axis_min - axis_origin) * inverse
        var t2 := (axis_max - axis_origin) * inverse
        if t1 > t2:
            var swap := t1
            t1 = t2
            t2 = swap
        t_min = maxf(t_min, t1)
        t_max = minf(t_max, t2)
        if t_min > t_max:
            return -1.0
    return t_min if t_min <= max_distance else -1.0

func vector_axis(value: Vector3, axis: int) -> float:
    if axis == 0:
        return value.x
    if axis == 1:
        return value.y
    return value.z

func spawn_tracer(origin: Vector3, target: Vector3) -> void:
    var length := origin.distance_to(target)
    if length <= 0.05:
        return
    var tracer := acquire_tracer()
    var mesh := tracer.mesh as BoxMesh
    if mesh:
        mesh.size = Vector3(0.035, 0.035, length)
    tracer.global_position = origin.lerp(target, 0.5)
    tracer.look_at(target, Vector3.UP)
    tracer.visible = true
    projectiles.append({ "node": tracer, "life": 0.18 })

func acquire_tracer() -> MeshInstance3D:
    var tracer: MeshInstance3D
    if tracer_pool.is_empty():
        tracer = MeshInstance3D.new()
        tracer.name = "PlayerProjectileTracer_%03d" % tracer_nodes_created
        var mesh := BoxMesh.new()
        mesh.size = Vector3(0.035, 0.035, 1.0)
        tracer.mesh = mesh
        tracer.material_override = tracer_material
        tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        add_child(tracer)
        tracer_nodes_created += 1
    else:
        tracer = tracer_pool.pop_back()
        tracer_nodes_reused += 1
    return tracer

func recycle_tracer(projectile: Dictionary) -> void:
    var node := projectile.get("node") as MeshInstance3D
    if node == null or not is_instance_valid(node):
        return
    node.visible = false
    node.scale = Vector3.ONE
    if tracer_pool.size() < 64:
        tracer_pool.append(node)

func _process(delta: float) -> void:
    for projectile in projectiles.duplicate():
        var node := projectile.get("node") as Node
        if node == null or not is_instance_valid(node):
            projectiles.erase(projectile)
            continue
        projectile["life"] = float(projectile.get("life", 0.0)) - delta
        if float(projectile.get("life", 0.0)) <= 0.0:
            recycle_tracer(projectile)
            projectiles.erase(projectile)

func label(item_id: String) -> String:
    if catalog.has(item_id):
        return String(catalog[item_id].get("label", item_id))
    return item_id

func stats() -> Dictionary:
    return {
        "projectiles": projectiles.size(),
        "lastMessage": last_message,
        "lastHitKind": last_hit_kind,
        "lastHitTravel": last_hit_travel,
        "manualBlockCandidates": last_manual_block_candidates,
        "manualBlockHits": last_manual_block_hits,
        "manualBlockCell": last_manual_block_cell,
        "manualBlockType": last_manual_block_type,
        "shotsFired": shots_fired_count,
        "tracerPool": tracer_pool.size(),
        "tracerNodesCreated": tracer_nodes_created,
        "tracerNodesReused": tracer_nodes_reused
    }
