extends RefCounted
class_name TutorialRescueSystem

const CELL := 1.35
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")
const FENCE_RADIUS_CELLS := 25
const RESCUE_MONSTER_COUNT := 6
const RESCUE_ELDER_ID := "mira"
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"

var system
var main

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

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
        send_elder_home_after_rescue_briefing()
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
            forager.set_meta("npc_hostile_target_immune", false)
            forager.set_meta("hostile_target_immune", false)
        if main.npc_system:
            if forager:
                main.npc_system.clear_scripted_target(forager)
            if guard:
                main.npc_system.clear_scripted_target(guard)
        if main.hostile_system:
            main.hostile_system.clear()
        if main.has_method("emit_story_event"):
            var event_position: Vector3 = main.player.global_position if main.player else rescue_return_position()
            var cell := Vector2i(main.world_to_cell(event_position.x), main.world_to_cell(event_position.z))
            main.emit_story_event("tutorial_final_rescue_complete", "tutorial:final_rescue", main.story_region_id_for_cell(cell), "tutorial:final_rescue_complete", event_position, {
                "rescuedNpcId": RESCUE_FORAGER_ID,
                "guardNpcId": RESCUE_GUARD_ID,
                "tutorialStep": "finalNightComplete"
            })
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
        safe_place_tutorial_npc(forager, system.rescue_site, "rescue_encounter_spawn")
        forager.set_meta("npc_force_hold", true)
        forager.set_meta("npc_rescue_stranded", true)
        forager.set_meta("npc_hostile_target_immune", true)
        forager.set_meta("hostile_target_immune", true)
        show_speech_bubble(RESCUE_FORAGER_ID, "Help!", 3.8)
    spawn_rescue_hostiles()

func choose_rescue_site() -> Vector3:
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var preferred_offsets: Array[Vector2i] = [
        Vector2i(FENCE_RADIUS_CELLS + 13, 0),
        Vector2i(FENCE_RADIUS_CELLS + 14, 3),
        Vector2i(FENCE_RADIUS_CELLS + 14, -3),
        Vector2i(FENCE_RADIUS_CELLS + 12, 6),
        Vector2i(FENCE_RADIUS_CELLS + 12, -6),
        Vector2i(FENCE_RADIUS_CELLS + 16, 0)
    ]
    for offset in preferred_offsets:
        var preferred := Vector3(float(center_x + offset.x) * CELL, 0.0, float(center_z + offset.y) * CELL)
        preferred.y = surface_y_at_position(preferred) + 0.06
        if rescue_encounter_site_clear(preferred):
            return preferred
    var base_angle := -0.55
    var radius := float(FENCE_RADIUS_CELLS + 13) * CELL
    for attempt in range(12):
        var angle := base_angle + float(attempt) * 0.28
        var position := Vector3(float(center_x) * CELL + cos(angle) * radius, 0.0, float(center_z) * CELL + sin(angle) * radius)
        position.y = surface_y_at_position(position) + 0.06
        if rescue_encounter_site_clear(position):
            return position
    var fallback := Vector3(float(center_x + FENCE_RADIUS_CELLS + 10) * CELL, 0.0, float(center_z + 4) * CELL)
    fallback.y = surface_y_at_position(fallback) + 0.06
    return fallback

func rescue_encounter_site_clear(position: Vector3) -> bool:
    if main == null:
        return true
    var town_center_position := Vector3(float(int(system.town.get("centerX", 0))) * CELL, 0.0, float(int(system.town.get("centerZ", 0))) * CELL)
    var town_level := float(system.town.get("level", surface_y_at_position(town_center_position)))
    var ground_y: float = surface_y_at_position(position)
    if ground_y < main.WATER_LEVEL + 0.8:
        return false
    if absf(ground_y - town_level) > CELL * 2.0:
        return false
    if rescue_root_has_near_prop(main.get("prop_root") as Node, position, CELL * CELL * 14.0):
        return false
    for i in range(RESCUE_MONSTER_COUNT):
        var angle := TAU * float(i) / float(RESCUE_MONSTER_COUNT)
        var ring_radius := CELL * (3.7 + 0.35 * float(i % 2))
        var ring_position := position + Vector3(cos(angle) * ring_radius, 0.0, sin(angle) * ring_radius)
        var ring_ground_y: float = surface_y_at_position(ring_position)
        if ring_ground_y < main.WATER_LEVEL + 0.8:
            return false
        if absf(ring_ground_y - town_level) > CELL * 2.4:
            return false
        if rescue_root_has_near_prop(main.get("prop_root") as Node, ring_position, CELL * CELL * 3.0):
            return false
    return true

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
    flame.material_override = system.make_emissive_material(Color(1.0, 0.73, 0.42), 1.35)
    flame.position.y = 1.02
    root.add_child(flame)
    var cast_shadows := main != null and bool(main.get("shadows_enabled"))
    LocalLightRigScript.add_rig(root, "rescue_torch", {
        "context": "placed",
        "scale": CELL,
        "source_position": Vector3(0.0, 1.02, 0.0),
        "terrain_position": Vector3(0.0, CELL * 0.36, 0.0),
        "bounce_position": Vector3(0.0, CELL * 0.96, 0.0),
        "source_energy": 1.85,
        "source_range": CELL * 9.0,
        "terrain_energy": 1.35,
        "terrain_range": CELL * 8.6,
        "bounce_energy": 0.65,
        "bounce_range": CELL * 10.0,
        "shadows": cast_shadows,
        "day_suppressed": true
    })
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
        position.y = surface_y_at_position(position) + 0.72
        var variant := "seer" if i == RESCUE_MONSTER_COUNT - 1 else "shadow"
        var body: StaticBody3D = main.hostile_system.spawn_enemy(position, variant)
        if body == null:
            continue
        body.set_meta("tutorial_rescue_hostile", true)
        body.set_meta("hostile_frenzy", true)
        var enemy: Dictionary = main.hostile_system.enemy_for_body(body)
        if not enemy.is_empty():
            enemy["aware"] = false
            enemy["daylightImmune"] = true
            enemy["tutorialRescue"] = true
            enemy["frenzy"] = true
            enemy["spawnOrigin"] = system.rescue_site
            enemy["awarenessDelay"] = 0.0
        if main.hostile_system.has_method("configure_scripted_encounter"):
            main.hostile_system.configure_scripted_encounter(body, "tutorial_final_rescue", "circle_niko", {
                "targetName": "Niko",
                "targetNpcId": RESCUE_FORAGER_ID,
                "battleSourceNpcId": RESCUE_GUARD_ID,
                "damageable": false,
                "canAttack": false,
                "frenzy": true,
                "circleAnchor": system.rescue_site,
                "circleRadius": radius,
                "circleIndex": i,
                "circleCount": RESCUE_MONSTER_COUNT,
                "circleAngularSpeed": 0.17,
                "circlePhase": 0.0
            })
        system.rescue_hostiles.append(body)

func start_rescue_escort() -> void:
    if system.rescue_escort_started:
        return
    system.rescue_escort_started = true
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard and main and main.npc_system:
        system.clear_dialogue_focus()
        guard.set_meta("npc_dialogue_focused", false)
        guard.set_meta("npc_force_hold", false)
        var guard_target: Vector3 = rescue_guard_target(guard)
        main.npc_system.order_go_to(guard, guard_target, "rescue_escort_to_niko", CELL * 1.2, "sprinting", true)
    show_speech_bubble(RESCUE_GUARD_ID, "With me!", 2.5)
    show_speech_bubble(RESCUE_FORAGER_ID, "Over here!", 3.2)

func rescue_guard_target(guard: Node3D) -> Vector3:
    var fallback: Vector3 = system.rescue_site + Vector3(-CELL * 1.45, 0.0, -CELL * 1.0)
    var origin: Vector3 = guard.global_position if guard != null else fallback
    var to_rescue: Vector3 = system.rescue_site - origin
    to_rescue.y = 0.0
    var direction: Vector3 = to_rescue.normalized() if to_rescue.length_squared() > 0.001 else Vector3.FORWARD
    var lateral := Vector3(-direction.z, 0.0, direction.x)
    var candidates: Array[Vector3] = [
        origin + direction * CELL * 8.0,
        origin + direction * CELL * 12.0,
        origin + direction * CELL * 16.0,
        origin + direction * CELL * 20.0,
        system.rescue_site - direction * CELL * 6.0,
        system.rescue_site - direction * CELL * 4.8,
        system.rescue_site - direction * CELL * 2.4,
        system.rescue_site - direction * CELL * 3.4 + lateral * CELL * 1.1,
        system.rescue_site - direction * CELL * 3.4 - lateral * CELL * 1.1,
        fallback,
        system.rescue_site - direction * CELL * 1.6
    ]
    for i in range(8):
        var angle := atan2(direction.x, direction.z) + TAU * float(i) / 8.0
        var ring_direction := Vector3(sin(angle), 0.0, cos(angle))
        candidates.append(system.rescue_site + ring_direction * CELL * 5.2)
        candidates.append(system.rescue_site + ring_direction * CELL * 7.0)
    var best_clear_candidate := Vector3.INF
    var best_clear_distance := INF
    var best_visible_clear_candidate := Vector3.INF
    var best_visible_clear_distance := INF
    var best_reachable_candidate := Vector3.INF
    var best_reachable_distance := INF
    var best_visible_reachable_candidate := Vector3.INF
    var best_visible_reachable_distance := INF
    var best_pending_candidate := Vector3.INF
    var best_pending_distance := INF
    var best_visible_pending_candidate := Vector3.INF
    var best_visible_pending_distance := INF
    for candidate in candidates:
        candidate.y = surface_y_at_position(candidate) + 0.04
        if not rescue_guard_target_clear(candidate):
            continue
        var distance_sq := rescue_target_distance_sq(candidate)
        if distance_sq < best_clear_distance:
            best_clear_distance = distance_sq
            best_clear_candidate = candidate
        var reachability := rescue_guard_target_reachability(guard, candidate)
        var reachable := bool(reachability.get("reachable", false))
        var pending := bool(reachability.get("pending", false))
        var visible := rescue_guard_target_has_line_of_sight(candidate)
        if visible and distance_sq < best_visible_clear_distance:
            best_visible_clear_distance = distance_sq
            best_visible_clear_candidate = candidate
        if reachable:
            if distance_sq < best_reachable_distance:
                best_reachable_distance = distance_sq
                best_reachable_candidate = candidate
            if visible and distance_sq < best_visible_reachable_distance:
                best_visible_reachable_distance = distance_sq
                best_visible_reachable_candidate = candidate
        elif pending:
            if distance_sq < best_pending_distance:
                best_pending_distance = distance_sq
                best_pending_candidate = candidate
            if visible and distance_sq < best_visible_pending_distance:
                best_visible_pending_distance = distance_sq
                best_visible_pending_candidate = candidate
    if best_visible_clear_candidate.is_finite():
        return best_visible_clear_candidate
    if best_clear_candidate.is_finite():
        return best_clear_candidate
    if best_visible_reachable_candidate.is_finite():
        return best_visible_reachable_candidate
    if best_reachable_candidate.is_finite():
        return best_reachable_candidate
    if best_visible_pending_candidate.is_finite():
        return best_visible_pending_candidate
    if best_pending_candidate.is_finite():
        return best_pending_candidate
    fallback.y = surface_y_at_position(fallback) + 0.04
    return fallback

func rescue_target_distance_sq(position: Vector3) -> float:
    var dx: float = position.x - system.rescue_site.x
    var dz: float = position.z - system.rescue_site.z
    return dx * dx + dz * dz

func rescue_guard_target_reachable(guard: Node3D, position: Vector3) -> bool:
    return bool(rescue_guard_target_reachability(guard, position).get("reachable", false))

func rescue_guard_target_reachability(guard: Node3D, position: Vector3) -> Dictionary:
    if guard == null or main == null or main.npc_system == null:
        return { "reachable": true, "pending": false }
    if not main.npc_system.has_method("npc_entry_for_actor"):
        return { "reachable": true, "pending": false }
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(guard)
    if entry.is_empty():
        return { "reachable": true, "pending": false }
    var pathing = main.npc_system.get("pathing")
    if pathing == null:
        return { "reachable": true, "pending": false }
    if pathing.has_method("ensure_ready"):
        pathing.ensure_ready()
    var goal_planner = pathing.get("goal_planner")
    var route_planner = pathing.get("route_planner")
    if goal_planner == null or route_planner == null or not goal_planner.has_method("make_intent") or not route_planner.has_method("plan_route"):
        return { "reachable": true, "pending": false }
    var probe_entry := entry.duplicate(true)
    probe_entry["body"] = entry.get("body")
    probe_entry["routeForceReplan"] = true
    var intent: Dictionary = goal_planner.make_intent(probe_entry, position, CELL * 1.2, false, true)
    intent["kind"] = "scripted"
    intent["priority"] = maxi(int(intent.get("priority", 0)), 220)
    intent["arrivalRadius"] = CELL * 1.2
    intent["strictArrival"] = false
    intent["allowPartial"] = false
    intent["fallbackCells"] = []
    var route: Dictionary = route_planner.plan_route(probe_entry, intent)
    if String(route.get("status", "")) == "pending":
        return { "reachable": false, "pending": true, "reason": String(route.get("reason", "")) }
    if String(route.get("status", "")) == "partial":
        return { "reachable": false, "pending": false, "reason": String(route.get("reason", "partial")) }
    return {
        "reachable": bool(route.get("ok", false)),
        "pending": false,
        "reason": String(route.get("reason", ""))
    }

func rescue_guard_target_has_line_of_sight(position: Vector3) -> bool:
    if main == null:
        return true
    var start: Vector3 = position + Vector3(0.0, 1.55, 0.0)
    var end: Vector3 = system.rescue_site + Vector3(0.0, 1.05, 0.0)
    var query := PhysicsRayQueryParameters3D.create(start, end)
    query.collision_mask = 1 | 4
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var hit: Dictionary = main.get_world_3d().direct_space_state.intersect_ray(query)
    return hit.is_empty()

func rescue_guard_target_clear(position: Vector3) -> bool:
    if main == null:
        return true
    if surface_y_at_position(position) < main.WATER_LEVEL + 0.8:
        return false
    if rescue_guard_target_navigation_blocked(position):
        return false
    var radius_sq := CELL * CELL * 1.6
    for root in [main.get("prop_root"), main.get("chunk_root")]:
        if rescue_root_has_near_prop(root as Node, position, radius_sq):
            return false
    return true

func rescue_guard_target_navigation_blocked(position: Vector3) -> bool:
    if main == null or main.npc_system == null:
        return false
    var pathing = main.npc_system.get("pathing")
    if pathing == null:
        return false
    if pathing.has_method("ensure_ready"):
        pathing.ensure_ready()
    var world = pathing.get("navigation_world")
    if world == null or not world.has_method("world_cell"):
        return false
    var cell: Vector2i = world.world_cell(position)
    if world.has_method("live_static_blocker_for_cell") and world.live_static_blocker_for_cell(cell) != null:
        return true
    var snapshot: Dictionary = {}
    if world.has_method("cached_static_tile_snapshot"):
        snapshot = world.cached_static_tile_snapshot(true, false)
    elif world.has_method("build_snapshot"):
        snapshot = world.build_snapshot({}, true, false)
    if snapshot.is_empty():
        return false
    if world.has_method("static_blocker") and world.static_blocker(snapshot, cell) != null:
        return true
    if world.has_method("prop_clearance_blocker") and world.prop_clearance_blocker(snapshot, cell) != null:
        return true
    return false

func rescue_root_has_near_prop(root: Node, position: Vector3, radius_sq: float) -> bool:
    if root == null:
        return false
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < 400:
        scanned += 1
        var node := stack.pop_back() as Node
        if node == null:
            continue
        if node is Node3D and String(node.get_meta("kind", "")) == "prop":
            var prop := node as Node3D
            if Vector2(prop.global_position.x - position.x, prop.global_position.z - position.z).length_squared() <= radius_sq:
                return true
        for child in node.get_children():
            stack.append(child)
    return false

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
        if rescue_party_home():
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
        forager.set_meta("npc_hostile_target_immune", false)
        forager.set_meta("hostile_target_immune", false)
        if main and main.npc_system:
            main.npc_system.order_go_home(forager, "rescue_return_home", "sprinting")
    if guard and main and main.npc_system:
        main.npc_system.order_go_to(guard, rescue_guard_return_position(), "rescue_return_guard_post", CELL * 0.72, "walking")
    show_speech_bubble(RESCUE_FORAGER_ID, "I can move!", 2.8)
    show_speech_bubble(RESCUE_GUARD_ID, "Back to town!", 2.8)

func rescue_return_position() -> Vector3:
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    return Vector3(float(center_x + FENCE_RADIUS_CELLS - 5) * CELL, level + 0.04, float(center_z) * CELL)

func rescue_guard_return_position() -> Vector3:
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard != null and main != null and main.npc_system != null and main.npc_system.has_method("npc_entry_for_actor"):
        var entry: Dictionary = main.npc_system.npc_entry_for_actor(guard)
        if not entry.is_empty():
            var guard_position: Vector3 = entry.get("guardPosition", Vector3.INF)
            if guard_position.is_finite():
                guard_position.y = surface_y_at_position(guard_position) + 0.04
                return guard_position
            var guard_cell: Vector2i = entry.get("guardCell", Vector2i.ZERO)
            var level := float(entry.get("level", 16.0))
            var cell_target := Vector3(float(guard_cell.x) * CELL, level + 0.04, float(guard_cell.y) * CELL)
            cell_target.y = surface_y_at_position(cell_target) + 0.04
            return cell_target
    var target := rescue_return_position() + Vector3(CELL * 0.65, 0.0, CELL * 0.65)
    if main != null:
        target.y = surface_y_at_position(target) + 0.04
    return target

func send_elder_home_after_rescue_briefing() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_go_home"):
        return
    var elder := find_tutorial_npc(RESCUE_ELDER_ID)
    if elder == null:
        return
    elder.set_meta("npc_force_hold", false)
    main.npc_system.order_go_home(elder, "final_rescue_briefing_return_home", "walking")

func rescue_party_home() -> bool:
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var forager_home := true if forager == null else tutorial_npc_strictly_inside_home(forager)
    if not forager_home:
        return false
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if guard == null:
        return true
    return rescue_guard_returned(guard)

func rescue_guard_returned(guard: Node3D) -> bool:
    if guard == null:
        return true
    if rescue_guard_route_arrived(guard):
        return true
    var target := rescue_guard_return_position()
    var flat := Vector2(guard.global_position.x - target.x, guard.global_position.z - target.z)
    return flat.length() <= CELL * 1.45

func rescue_guard_route_arrived(guard: Node3D) -> bool:
    if guard == null or main == null or main.npc_system == null:
        return false
    if not main.npc_system.has_method("npc_entry_for_actor"):
        return false
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(guard)
    if entry.is_empty():
        return false
    var scripted_order: Dictionary = entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}
    if String(scripted_order.get("kind", "")) != "go_to":
        return false
    if String(scripted_order.get("state", "")) != "ARRIVED":
        return false
    var ordered_target: Vector3 = scripted_order.get("target", Vector3.INF)
    if not ordered_target.is_finite():
        return false
    var return_target := rescue_guard_return_position()
    var ordered_flat := Vector2(ordered_target.x - return_target.x, ordered_target.z - return_target.z)
    if ordered_flat.length() > CELL * 0.35:
        return false
    var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
    var proof: Dictionary = authority.get("proof", {}) if authority.get("proof", {}) is Dictionary else {}
    var authority_arrived := String(authority.get("state", "")) == "arrived" or String(entry.get("routeStatus", "")) == "arrived"
    return authority_arrived and bool(proof.get("ok", false)) and bool(proof.get("collisionBacked", false))

func tutorial_npc_strictly_inside_home(body: Node3D) -> bool:
    if body == null or main == null or main.npc_system == null:
        return false
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(body) if main.npc_system.has_method("npc_entry_for_actor") else {}
    if entry.is_empty():
        return false
    var cell := Vector2i(roundi(body.global_position.x / CELL), roundi(body.global_position.z / CELL))
    var min_cell: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", cell))
    var max_cell: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", cell))
    return (
        cell.x >= mini(min_cell.x, max_cell.x)
        and cell.x <= maxi(min_cell.x, max_cell.x)
        and cell.y >= mini(min_cell.y, max_cell.y)
        and cell.y <= maxi(min_cell.y, max_cell.y)
    )

func settle_rescue_party_home() -> void:
    var home := rescue_return_position()
    var forager := find_tutorial_npc(RESCUE_FORAGER_ID)
    var guard := find_tutorial_npc(RESCUE_GUARD_ID)
    if forager:
        safe_place_tutorial_npc(forager, home, "rescue_return_home")
    if guard:
        safe_place_tutorial_npc(guard, rescue_guard_return_position(), "rescue_return_home")

func safe_place_tutorial_npc(body: Node3D, position: Vector3, reason: String) -> void:
    if body == null or main == null or main.npc_system == null or not main.npc_system.has_method("safe_place_npc"):
        return
    main.npc_system.safe_place_npc(body, position, null, reason)

func find_tutorial_npc(npc_id: String) -> Node3D:
    if system.npc_root == null:
        return null
    for child in system.npc_root.get_children():
        var body := child as Node3D
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
        var node_value = bubble.get("node")
        if not is_instance_valid(node_value):
            system.speech_bubbles.erase(bubble)
            continue
        var node := node_value as Label3D
        if node == null:
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
        var node_value = bubble.get("node")
        if is_instance_valid(node_value):
            var node := node_value as Node
            if node != null:
                node.queue_free()
    system.speech_bubbles.clear()
