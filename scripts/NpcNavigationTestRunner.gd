extends "res://scripts/PlaytestRunner.gd"

func run() -> void:
    mark_progress("npc_nav_start")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("npc_nav_main_instantiated")
    await wait_physics_frames(20)

    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        camera = player.get("camera") as Camera3D
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    mark_progress("npc_nav_warmup")
    await wait_physics_frames(80)
    mark_progress("npc_nav_capsule_gate")
    await test_npc_capsule_collision_gate()
    mark_progress("npc_nav_two_npc_door")
    await test_two_npcs_cross_narrow_door()
    mark_progress("npc_nav_home_fallback")
    await test_home_return_fallback_semantics()
    mark_progress("npc_nav_reachable_goals")
    await test_reachability_aware_goal_selection()
    mark_progress("npc_nav_generic_town")
    await test_generic_town_npc_navigation()
    mark_progress("npc_nav_route_core")
    await test_npc_equipment_and_pathing()

    save_optional_screenshot()
    save_report()
    finished = true
    get_tree().quit(1 if failed else 0)

func test_generic_town_npc_navigation() -> void:
    if not main:
        add_result("npc_nav_generic_town_npc_homes", false, "main missing")
        return
    var structure_system = main.get("structure_system")
    var npc_system = main.get("npc_system")
    if structure_system == null or npc_system == null:
        add_result("npc_nav_generic_town_npc_homes", false, "structure/npc system missing")
        return

    var town: Dictionary = main.call("town_region", 1, 0)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    var level := float(town.get("level", 0.0))
    var generic_center_x := center_x + 116
    var generic_center_z := center_z + 116
    var generic_town := {
        "regionX": 94,
        "regionZ": 94,
        "centerX": generic_center_x,
        "centerZ": generic_center_z,
        "radius": 32,
        "level": level
    }
    structure_system.call("build_town", generic_town)
    npc_system.spawn_generic_town_npcs()
    npc_system.update_npcs(0.1, 1.0)

    var generic_key := "%d,%d" % [generic_center_x, generic_center_z]
    var home_records: Dictionary = structure_system.call("town_home_records_snapshot")
    var generic_homes: Array = home_records.get(generic_key, [])
    var npc_entries: Array = npc_system.get("npcs")
    var generic_npcs := 0
    var generic_homed := 0
    var generic_fighters := 0
    var job_workers := 0
    var generic_forager: Dictionary = {}
    for entry_variant in npc_entries:
        var entry: Dictionary = entry_variant
        if String(entry.get("townKey", "")) != generic_key:
            continue
        generic_npcs += 1
        var npc_body := entry.get("body") as Node
        if npc_body != null and bool(npc_body.get_meta("npc_has_home", false)):
            generic_homed += 1
        if bool(entry.get("canFight", false)):
            generic_fighters += 1
        if String(entry.get("job", "")) in ["forage", "wood", "stone"]:
            job_workers += 1
            entry["jobPhase"] = "idle"
            entry["jobTimer"] = 0.0
            if String(entry.get("job", "")) == "forage" and generic_forager.is_empty():
                generic_forager = entry

    add_result(
        "npc_nav_generic_town_npc_homes",
        generic_homes.size() >= 4 and generic_npcs >= generic_homes.size() and generic_homed == generic_npcs and generic_fighters >= 1,
        "homes %d, npcs %d, homed %d, fighters %d" % [generic_homes.size(), generic_npcs, generic_homed, generic_fighters]
    )

    var forage_node: Node3D = null
    var targeted_forage_selected := false
    if not generic_forager.is_empty():
        generic_forager["hunger"] = 38.0
        var prop_root := main.get("prop_root") as Node
        var porch_cell: Vector2i = generic_forager.get("porchCell", Vector2i(generic_center_x + 1, generic_center_z))
        var outward := Vector2(float(porch_cell.x - generic_center_x), float(porch_cell.y - generic_center_z))
        if outward.length_squared() < 0.001:
            outward = Vector2.RIGHT
        outward = outward.normalized()
        var forage_distance := float(generic_town.get("radius", 32)) + 8.0
        var forage_cell := Vector2i(
            roundi(float(generic_center_x) + outward.x * forage_distance),
            roundi(float(generic_center_z) + outward.y * forage_distance)
        )
        var forage_ground: float = main.call("height_at_world", float(forage_cell.x) * CELL, float(forage_cell.y) * CELL)
        if forage_ground < main.WATER_LEVEL + 0.55:
            for fallback_direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
                var fallback_cell := Vector2i(
                    roundi(float(generic_center_x) + fallback_direction.x * forage_distance),
                    roundi(float(generic_center_z) + fallback_direction.y * forage_distance)
                )
                var fallback_ground: float = main.call("height_at_world", float(fallback_cell.x) * CELL, float(fallback_cell.y) * CELL)
                if fallback_ground >= main.WATER_LEVEL + 0.55:
                    forage_cell = fallback_cell
                    forage_ground = fallback_ground
                    break
        clear_props_near_cell(forage_cell, 5)
        clear_blocks_near_cell(forage_cell, 3)
        forage_ground = main.call("height_at_world", float(forage_cell.x) * CELL, float(forage_cell.y) * CELL)
        var rng := RandomNumberGenerator.new()
        rng.seed = 77031
        forage_node = main.call(
            "make_forage",
            prop_root,
            "npc-nav:forager-berries",
            Vector3(float(forage_cell.x) * CELL, forage_ground, float(forage_cell.y) * CELL),
            "plains",
            rng
        ) as Node3D
        if forage_node != null:
            var pathing = npc_system.get("pathing")
            if pathing != null and pathing.has_method("choose_forage_target"):
                var forage_candidates: Array[Node3D] = [forage_node]
                targeted_forage_selected = pathing.choose_forage_target(generic_forager, forage_candidates) == forage_node
            generic_forager["jobTargetNode"] = forage_node
            generic_forager["jobTarget"] = pathing.forage_target_position(generic_forager, forage_node) if pathing != null and pathing.has_method("forage_target_position") else forage_node.global_position
            generic_forager["jobPhase"] = "outbound"
            generic_forager["jobTimer"] = 24.0
            generic_forager["routeForceReplan"] = true
            generic_forager["goal"] = "forage berries"

    var job_runs_before := int(npc_system.stats().get("jobRuns", 0))
    var forage_runs_before := int(npc_system.stats().get("forageRuns", 0))
    var door_opens_before := int(npc_system.stats().get("doorOpens", 0))
    var door_closes_before := int(npc_system.stats().get("doorCloses", 0))
    var saw_generic_worker_outside := false
    var forager_goal_seen := false
    var town_radius_world := float(generic_town.get("radius", 32)) * CELL
    var town_center_world := Vector2(float(generic_center_x) * CELL, float(generic_center_z) * CELL)
    for step in range(520):
        if step % 80 == 0:
            mark_progress("npc_nav_generic_town_jobs_%d" % step)
        npc_system.update_npcs(0.2, 1.0)
        for entry_variant in npc_entries:
            var entry: Dictionary = entry_variant
            if String(entry.get("townKey", "")) != generic_key or not (String(entry.get("job", "")) in ["forage", "wood", "stone"]):
                continue
            var npc_body := entry.get("body") as Node3D
            if npc_body == null or not is_instance_valid(npc_body):
                continue
            var flat := Vector2(npc_body.global_position.x, npc_body.global_position.z)
            if flat.distance_to(town_center_world) > town_radius_world + CELL * 0.5:
                saw_generic_worker_outside = true
            if String(entry.get("job", "")) == "forage" and String(entry.get("goal", "")).find("berr") >= 0:
                forager_goal_seen = true
        var stats_now: Dictionary = npc_system.stats()
        var targeted_forage_done := false
        if not generic_forager.is_empty():
            var inventory_now: Dictionary = generic_forager.get("personalInventory", {})
            var hunger_now := float(generic_forager.get("hunger", 0.0))
            targeted_forage_done = int(inventory_now.get("berries", 0)) > 0 and hunger_now > 38.0
        if saw_generic_worker_outside and int(stats_now.get("jobRuns", 0)) > job_runs_before and targeted_forage_done:
            break
        if step % 20 == 19:
            await wait_physics_frames(1)

    var job_stats: Dictionary = npc_system.stats()
    var forager_inventory: Dictionary = generic_forager.get("personalInventory", {}) if not generic_forager.is_empty() else {}
    var forager_food := int(forager_inventory.get("berries", 0))
    var forager_hunger := float(generic_forager.get("hunger", 0.0)) if not generic_forager.is_empty() else 0.0
    var stats_worker_outside := int(job_stats.get("outsideWorkers", 0)) > 0
    add_result(
        "npc_nav_generic_job_outings",
        job_workers >= 2 and (saw_generic_worker_outside or stats_worker_outside) and int(job_stats.get("jobRuns", 0)) > job_runs_before,
        "workers %d, outside seen %s, stats outside %s, runs %d->%d" % [
            job_workers,
            str(saw_generic_worker_outside),
            str(stats_worker_outside),
            job_runs_before,
            int(job_stats.get("jobRuns", 0))
        ]
    )
    add_result(
        "npc_nav_forager_goal_inventory_hunger",
        not generic_forager.is_empty()
            and forager_goal_seen
            and forager_food > 0
            and int(job_stats.get("forageRuns", 0)) > forage_runs_before
            and forager_hunger > 38.0
            and targeted_forage_selected,
        "goal %s, target selected %s, berries %d, hunger %.1f, forage %d->%d, phase %s, route %s/%s" % [
            str(forager_goal_seen),
            str(targeted_forage_selected),
            forager_food,
            forager_hunger,
            forage_runs_before,
            int(job_stats.get("forageRuns", 0)),
            String(generic_forager.get("jobPhase", "")),
            String(generic_forager.get("routeStatus", "")),
            String(generic_forager.get("routeReason", ""))
        ]
    )
    add_result(
        "npc_nav_door_open_close_cycle",
        int(job_stats.get("doorOpens", 0)) >= door_opens_before and int(job_stats.get("doorCloses", 0)) >= door_closes_before,
        "doors open %d->%d close %d->%d" % [
            door_opens_before,
            int(job_stats.get("doorOpens", 0)),
            door_closes_before,
            int(job_stats.get("doorCloses", 0))
        ]
    )
    cleanup_generated_blocks()

func test_npc_capsule_collision_gate() -> void:
    if not main or not player:
        add_result("npc_nav_capsule_collision_gate", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_capsule_collision_gate", false, "npc system missing")
        return
    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 58, roundi(player.global_position.z / CELL) + 58)
    reset_player_on_flat_patch(start_cell)
    clear_blocks_near_cell(start_cell, 10)
    clear_props_near_cell(start_cell, 12)
    await wait_physics_frames(3)

    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var start_position := Vector3(float(start_cell.x) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var wall_y := base_height + CELL * 0.48
    var wall_cell_y := floori(wall_y / CELL) + 1
    var blocks := get_blocks()
    var blocker_cells: Array[Vector3i] = []
    var block_types := ["stoneBlock", "woodBlock", "glass"]
    for i in range(block_types.size()):
        var cell := Vector3i(start_cell.x + 2 + i, wall_cell_y, start_cell.y + 1)
        blocker_cells.append(cell)
        if blocks.has(cell):
            var old_block := blocks[cell] as Node
            if old_block:
                old_block.queue_free()
            blocks.erase(cell)
        main.call("create_block", cell, String(block_types[i]), { "world_y": wall_y })
    var door_cell := Vector3i(start_cell.x + 2, wall_cell_y, start_cell.y - 3)
    blocker_cells.append(door_cell)
    if blocks.has(door_cell):
        var old_door := blocks[door_cell] as Node
        if old_door:
            old_door.queue_free()
        blocks.erase(door_cell)
    main.call("create_block", door_cell, "door", { "world_y": wall_y })

    var rng := RandomNumberGenerator.new()
    rng.seed = 112358
    var prop := main.call(
        "make_rock",
        main.get("prop_root") as Node,
        "npc-nav:capsule-rock",
        Vector3(float(start_cell.x + 5) * CELL, base_height, float(start_cell.y - 1) * CELL),
        rng
    ) as Node3D
    await wait_physics_frames(3)

    var body := npc_system.create_npc_body("NpcNavCapsuleGateNPC", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    npc_system.safe_place_npc(body, start_position, null, "test_spawn")
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": "npc-nav-capsule-gate",
        "name": "Capsule Gate",
        "role": "Guard",
        "townKey": "npc-nav-capsule",
        "townCenter": start_cell,
        "townRadius": 14,
        "level": base_height,
        "cell": start_cell,
        "homeCell": start_cell,
        "porchCell": start_cell,
        "guardCell": Vector2i(start_cell.x + 1, start_cell.y),
        "canFight": true,
        "nightGuard": true
    })

    var pathing = npc_system.get("pathing")
    var locomotion = pathing.get("locomotion") if pathing != null else null
    var world = pathing.get("navigation_world") if pathing != null else null
    var blocked_by_block := false
    var blocked_by_prop := false
    var open_door_allowed := false
    if locomotion != null and world != null:
        var block_candidate := Vector3(float(start_cell.x + 2) * CELL, base_height + 0.04, float(start_cell.y + 1) * CELL)
        var block_validation: Dictionary = locomotion.validate_candidate(entry, start_position, block_candidate, false, false, world)
        blocked_by_block = not bool(block_validation.get("ok", false)) and String(block_validation.get("reason", "")).begins_with("blocked")
        var prop_candidate := prop.global_position if prop != null else Vector3(float(start_cell.x + 5) * CELL, base_height + 0.04, float(start_cell.y - 1) * CELL)
        prop_candidate.y = base_height + 0.04
        var prop_validation: Dictionary = locomotion.validate_candidate(entry, start_position, prop_candidate, false, false, world)
        blocked_by_prop = not bool(prop_validation.get("ok", false)) and String(prop_validation.get("reason", "")).begins_with("blocked")
        var door := blocks.get(door_cell) as Node
        if door != null:
            main.call("toggle_door", door)
            await wait_physics_frames(1)
            var door_candidate := Vector3(float(door_cell.x) * CELL, base_height + 0.04, float(door_cell.z) * CELL)
            var door_validation: Dictionary = locomotion.validate_candidate(entry, start_position, door_candidate, false, false, world)
            open_door_allowed = bool(door_validation.get("ok", false)) or String(door_validation.get("reason", "")) != "blocked_capsule"

    add_result(
        "npc_nav_capsule_collision_gate",
        locomotion != null and world != null and blocked_by_block and blocked_by_prop and open_door_allowed,
        "locomotion %s, world %s, block %s, prop %s, open door %s" % [
            str(locomotion != null),
            str(world != null),
            str(blocked_by_block),
            str(blocked_by_prop),
            str(open_door_allowed)
        ]
    )

    npc_system.unregister_npc(body)
    if is_instance_valid(body):
        body.queue_free()
    if prop != null and is_instance_valid(prop):
        prop.queue_free()
    blocks = get_blocks()
    for cell in blocker_cells:
        if blocks.has(cell):
            var block_body := blocks[cell] as Node
            if block_body:
                block_body.queue_free()
            blocks.erase(cell)

func test_two_npcs_cross_narrow_door() -> void:
    if not main or not player:
        add_result("npc_nav_two_npc_door_crossing", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_two_npc_door_crossing", false, "npc system missing")
        return
    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 64, roundi(player.global_position.z / CELL) + 64)
    reset_player_on_flat_patch(start_cell)
    clear_blocks_near_cell(start_cell, 12)
    clear_props_near_cell(start_cell, 14)
    await wait_physics_frames(3)

    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var wall_y := base_height + CELL * 0.48
    var wall_cell_y := floori(wall_y / CELL) + 1
    var door_cell := Vector3i(start_cell.x + 4, wall_cell_y, start_cell.y)
    var barrier_cells: Array[Vector3i] = []
    var blocks := get_blocks()
    for dz in range(-3, 4):
        var cell := Vector3i(start_cell.x + 4, wall_cell_y, start_cell.y + dz)
        barrier_cells.append(cell)
        if blocks.has(cell):
            var old_block := blocks[cell] as Node
            if old_block:
                old_block.queue_free()
            blocks.erase(cell)
        var block_type := "door" if cell == door_cell else "stoneBlock"
        main.call("create_block", cell, block_type, { "world_y": wall_y })
    await wait_physics_frames(3)

    var left_start := Vector3(float(start_cell.x + 1) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var right_start := Vector3(float(start_cell.x + 7) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var left_npc := npc_system.create_npc_body("NpcNavDoorLeft", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", left_npc)
    var right_npc := npc_system.create_npc_body("NpcNavDoorRight", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", right_npc)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(left_npc)
        npc_root.add_child(right_npc)
    else:
        npc_system.add_child(left_npc)
        npc_system.add_child(right_npc)
    npc_system.safe_place_npc(left_npc, left_start, null, "test_spawn")
    npc_system.safe_place_npc(right_npc, right_start, null, "test_spawn")

    var town_center := Vector2i(start_cell.x + 4, start_cell.y)
    var left_entry: Dictionary = npc_system.register_npc(left_npc, {
        "id": "npc-nav-door-left",
        "name": "Door Left",
        "role": "Villager",
        "townKey": "npc-nav-door",
        "townCenter": town_center,
        "townRadius": 18,
        "level": base_height,
        "homeCell": Vector2i(start_cell.x + 1, start_cell.y),
        "porchCell": Vector2i(start_cell.x + 1, start_cell.y),
        "guardCell": Vector2i(start_cell.x + 1, start_cell.y)
    })
    var right_entry: Dictionary = npc_system.register_npc(right_npc, {
        "id": "npc-nav-door-right",
        "name": "Door Right",
        "role": "Villager",
        "townKey": "npc-nav-door",
        "townCenter": town_center,
        "townRadius": 18,
        "level": base_height,
        "homeCell": Vector2i(start_cell.x + 7, start_cell.y),
        "porchCell": Vector2i(start_cell.x + 7, start_cell.y),
        "guardCell": Vector2i(start_cell.x + 7, start_cell.y)
    })
    left_entry["goal"] = "door crossing"
    right_entry["goal"] = "door crossing"
    npc_system.set_scripted_target(left_npc, right_start, false, true)
    npc_system.set_scripted_target(right_npc, left_start, false, true)

    var pathing = npc_system.get("pathing")
    var reservation_waits_before := int(npc_system.stats().get("reservationWaits", 0))
    var door_opens_before := int(npc_system.stats().get("doorOpens", 0))
    var door_closes_before := int(npc_system.stats().get("doorCloses", 0))
    var shared_cell := false
    var both_crossed := false
    var min_separation := INF
    var door_world_x := float(door_cell.x) * CELL
    for step in range(260):
        if pathing != null and pathing.has_method("begin_frame"):
            pathing.begin_frame()
        npc_system.move_npc(left_entry, right_start, CELL * 0.22, false, false)
        npc_system.move_npc(right_entry, left_start, CELL * 0.22, false, false)
        npc_system.update_pending_door_closes(0.18)
        var left_cell := world_to_flat_cell(left_npc.global_position)
        var right_cell := world_to_flat_cell(right_npc.global_position)
        if left_cell == right_cell:
            shared_cell = true
        min_separation = minf(min_separation, Vector2(left_npc.global_position.x - right_npc.global_position.x, left_npc.global_position.z - right_npc.global_position.z).length())
        if left_npc.global_position.x > door_world_x + CELL * 0.55 and right_npc.global_position.x < door_world_x - CELL * 0.55:
            both_crossed = true
            break
        await wait_physics_frames(1)
    for i in range(24):
        npc_system.update_pending_door_closes(0.18)
        await wait_physics_frames(1)
    var stats_after: Dictionary = npc_system.stats()
    var door := blocks.get(door_cell) as Node
    var door_closed := door != null and not bool(door.get_meta("open", false))
    var left_final_cell := world_to_flat_cell(left_npc.global_position)
    var right_final_cell := world_to_flat_cell(right_npc.global_position)
    var left_requested_cell := world_to_flat_cell(right_start)
    var right_requested_cell := world_to_flat_cell(left_start)
    var left_target_dist := Vector2(left_npc.global_position.x - right_start.x, left_npc.global_position.z - right_start.z).length()
    var right_target_dist := Vector2(right_npc.global_position.x - left_start.x, right_npc.global_position.z - left_start.z).length()
    var left_entry_body := left_entry.get("body") as Node3D
    var right_entry_body := right_entry.get("body") as Node3D
    add_result(
        "npc_nav_two_npc_door_crossing",
        both_crossed
            and not shared_cell
            and min_separation >= CELL * 0.34
            and int(stats_after.get("reservationWaits", 0)) > reservation_waits_before
            and int(stats_after.get("doorOpens", 0)) > door_opens_before
            and int(stats_after.get("doorCloses", 0)) > door_closes_before
            and door_closed,
        "crossed %s, shared %s, minSep %.2f, left %.2f cell %s wants %s dist %.2f goal %s body %s, right %.2f cell %s wants %s dist %.2f goal %s body %s, doorX %.2f, waits %d->%d, door %d/%d -> %d/%d, closed %s, routes %s/%s %s/%s" % [
            str(both_crossed),
            str(shared_cell),
            min_separation,
            left_npc.global_position.x,
            str(left_final_cell),
            str(left_requested_cell),
            left_target_dist,
            str(left_entry.get("routeGoalCell", Vector2i.ZERO)),
            str(left_entry_body == left_npc),
            right_npc.global_position.x,
            str(right_final_cell),
            str(right_requested_cell),
            right_target_dist,
            str(right_entry.get("routeGoalCell", Vector2i.ZERO)),
            str(right_entry_body == right_npc),
            door_world_x,
            reservation_waits_before,
            int(stats_after.get("reservationWaits", 0)),
            door_opens_before,
            door_closes_before,
            int(stats_after.get("doorOpens", 0)),
            int(stats_after.get("doorCloses", 0)),
            str(door_closed),
            String(left_entry.get("routeStatus", "")),
            String(left_entry.get("routeReason", "")),
            String(right_entry.get("routeStatus", "")),
            String(right_entry.get("routeReason", ""))
        ]
    )

    npc_system.unregister_npc(left_npc)
    npc_system.unregister_npc(right_npc)
    if is_instance_valid(left_npc):
        left_npc.queue_free()
    if is_instance_valid(right_npc):
        right_npc.queue_free()
    blocks = get_blocks()
    for cell in barrier_cells:
        if blocks.has(cell):
            var block_body := blocks[cell] as Node
            if block_body:
                block_body.queue_free()
            blocks.erase(cell)

func test_home_return_fallback_semantics() -> void:
    if not main or not player:
        add_result("npc_nav_home_return_fallback_semantics", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_home_return_fallback_semantics", false, "npc system missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 104, roundi(player.global_position.z / CELL) + 104)
    var home_cell := start_cell + Vector2i(10, 0)
    var porch_cell := home_cell + Vector2i(-1, 0)
    clear_blocks_near_cell(start_cell, 18)
    clear_props_near_cell(start_cell, 18)
    await wait_physics_frames(2)

    var level: float = main.call("terrain_height_cell", home_cell.x, home_cell.y)
    var body := npc_system.create_npc_body("NpcNavHomeFallback", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    npc_system.safe_place_npc(body, Vector3(float(start_cell.x) * CELL, level + 0.04, float(start_cell.y) * CELL), null, "test_spawn")
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": "npc-nav-home-fallback",
        "name": "Home Fallback Tester",
        "role": "Worker",
        "townKey": "npc-nav-home-fallback",
        "townCenter": start_cell,
        "townRadius": 24,
        "level": level,
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "guardCell": porch_cell,
        "job": ""
    })

    entry["homeReturnTime"] = 8.0
    entry["homeActiveTargetCell"] = home_cell
    entry["routeStatus"] = "moving"
    entry["routeReason"] = ""
    entry["routeFallbackCell"] = start_cell
    var timed_position := body.global_position
    npc_system.settle_home_if_reached(entry)
    var timer_did_not_mark := not bool(entry.get("insideHome", false)) and not bool(body.get_meta("npc_inside_home", false)) and body.global_position.distance_to(timed_position) <= 0.001

    var first_route_cell := start_cell + Vector2i(1, -1)
    var second_route_cell := start_cell + Vector2i(3, -1)
    entry["homeRoutePositions"] = [
        npc_system.cell_to_position(first_route_cell, level),
        npc_system.cell_to_position(second_route_cell, level)
    ]
    entry["homeRouteIndex"] = 0
    entry["routeStatus"] = "arrived"
    entry["homeActiveTargetCell"] = first_route_cell
    var next_home_target: Vector3 = npc_system.home_route_target(entry)
    var advanced_route_waypoint := int(entry.get("homeRouteIndex", 0)) == 1 and world_to_flat_cell(next_home_target) == second_route_cell

    npc_system.safe_place_npc(body, Vector3(float(porch_cell.x + 1) * CELL, level + 0.04, float(porch_cell.y + 1) * CELL), null, "test_home_setup")
    entry["homeRoutePositions"] = []
    entry["homeRouteIndex"] = 0
    entry["routeStatus"] = "arrived"
    entry["homeActiveTargetCell"] = porch_cell
    var final_home_target: Vector3 = npc_system.home_route_target(entry)
    var advanced_from_porch := world_to_flat_cell(final_home_target) == home_cell

    var porch_position: Vector3 = entry.get("porchPosition", body.global_position)
    npc_system.safe_place_npc(body, porch_position, null, "test_home_setup")
    entry["insideHome"] = false
    body.set_meta("npc_inside_home", false)
    entry["homeRoutePositions"] = []
    entry["homeRouteIndex"] = 0
    entry["routeStatus"] = "blocked"
    entry["routeReason"] = "no_candidate_goal"
    entry["routeFallbackCell"] = Vector2i(999999, 999999)
    entry["homeActiveTargetCell"] = home_cell
    var unreachable_before := int(npc_system.stats().get("unreachableGoals", 0))
    npc_system.settle_home_if_reached(entry)
    var unreachable_after := int(npc_system.stats().get("unreachableGoals", 0))
    var fallback_marked := bool(entry.get("insideHome", false)) \
        and bool(body.get_meta("npc_inside_home", false)) \
        and String(entry.get("routeStatus", "")) == "partial" \
        and String(entry.get("routeReason", "")) == "home_porch_fallback" \
        and unreachable_after > unreachable_before \
        and body.global_position.distance_to(porch_position) <= 0.001

    add_result(
        "npc_nav_home_return_fallback_semantics",
        timer_did_not_mark and advanced_route_waypoint and advanced_from_porch and fallback_marked,
        "timer safe %s, route advance %s, porch advance %s, fallback %s, route %s/%s, unreachable %d->%d" % [
            str(timer_did_not_mark),
            str(advanced_route_waypoint),
            str(advanced_from_porch),
            str(fallback_marked),
            String(entry.get("routeStatus", "")),
            String(entry.get("routeReason", "")),
            unreachable_before,
            unreachable_after
        ]
    )

    npc_system.unregister_npc(body)
    if is_instance_valid(body):
        body.queue_free()

func test_reachability_aware_goal_selection() -> void:
    if not main or not player:
        add_result("npc_nav_reachability_goal_selection", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_reachability_goal_selection", false, "npc system missing")
        return
    var pathing = npc_system.get("pathing")
    if pathing == null:
        add_result("npc_nav_reachability_goal_selection", false, "pathing missing")
        return
    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 78, roundi(player.global_position.z / CELL) + 78)
    reset_player_on_flat_patch(start_cell)
    clear_blocks_near_cell(start_cell, 18)
    clear_props_near_cell(start_cell, 36)
    await wait_physics_frames(3)

    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var town_radius := 12
    var tree_cell := dry_work_cell(start_cell, town_radius + 8, town_radius + 22)
    var rock_cell := dry_work_cell(Vector2i(start_cell.x, start_cell.y + 2), town_radius + 8, town_radius + 24)
    var hostile_cell := dry_work_cell(Vector2i(start_cell.x + 2, start_cell.y), town_radius + 5, town_radius + 18)
    var prop_root := main.get("prop_root") as Node
    var rng := RandomNumberGenerator.new()
    rng.seed = 908177
    var tree_pos := Vector3(float(tree_cell.x) * CELL, main.call("height_at_world", float(tree_cell.x) * CELL, float(tree_cell.y) * CELL), float(tree_cell.y) * CELL)
    var rock_pos := Vector3(float(rock_cell.x) * CELL, main.call("height_at_world", float(rock_cell.x) * CELL, float(rock_cell.y) * CELL), float(rock_cell.y) * CELL)
    var tree := main.call("make_tree", prop_root, "npc-nav:wood-target", tree_pos, "forest", rng) as Node3D
    var rock := main.call("make_rock", prop_root, "npc-nav:stone-target", rock_pos, rng) as Node3D
    await wait_physics_frames(3)

    var entries: Array[Dictionary] = []
    var bodies: Array[Node3D] = []
    var wood_entry := make_nav_test_npc(npc_system, "npc-nav-wood-worker", "Wood Worker", "wood", start_cell, town_radius, base_height, Vector2i(start_cell.x - 1, start_cell.y))
    var stone_entry := make_nav_test_npc(npc_system, "npc-nav-stone-worker", "Stone Worker", "stone", start_cell, town_radius, base_height, Vector2i(start_cell.x + 1, start_cell.y))
    var guard_entry := make_nav_test_npc(npc_system, "npc-nav-guard-worker", "Guard", "", start_cell, town_radius, base_height, Vector2i(start_cell.x, start_cell.y + 2), true)
    for entry in [wood_entry, stone_entry, guard_entry]:
        if not entry.is_empty():
            entries.append(entry)
            var body := entry.get("body") as Node3D
            if body != null:
                bodies.append(body)

    var hostile_height: float = main.call("terrain_height_cell", hostile_cell.x, hostile_cell.y)
    var hostile := StaticBody3D.new()
    hostile.name = "NpcNavGoalHostile"
    hostile.position = Vector3(float(hostile_cell.x) * CELL, hostile_height + 0.04, float(hostile_cell.y) * CELL)
    hostile.set_meta("kind", "hostile")
    add_child(hostile)

    var wood_target: Vector3 = pathing.choose_job_target(wood_entry)
    var stone_target: Vector3 = pathing.choose_job_target(stone_entry)
    var guard_target: Vector3 = pathing.choose_guard_target(guard_entry, hostile, false)
    var wander_target: Vector3 = pathing.choose_day_target(guard_entry)
    var goal_planner = pathing.get("goal_planner")
    var wood_resource_candidates: Array[Vector3] = []
    if goal_planner != null and goal_planner.has_method("add_resource_prop_candidates"):
        goal_planner.add_resource_prop_candidates(wood_resource_candidates, wood_entry, "wood")
    var first_wood_resource_distance := -1.0
    var first_wood_resource_cost := INF
    if not wood_resource_candidates.is_empty():
        first_wood_resource_distance = Vector2(wood_resource_candidates[0].x - tree_pos.x, wood_resource_candidates[0].z - tree_pos.z).length()
        first_wood_resource_cost = pathing.route_cost(wood_entry, wood_resource_candidates[0], true, false, CELL * 0.85)
    var wood_near_resource := false
    for candidate in wood_resource_candidates:
        if Vector2(wood_target.x - candidate.x, wood_target.z - candidate.z).length() <= CELL * 1.15:
            wood_near_resource = true
            break
    var wood_cost: float = pathing.route_cost(wood_entry, wood_target, true, false, CELL * 0.85)
    var stone_cost: float = pathing.route_cost(stone_entry, stone_target, true, false, CELL * 0.85)
    var guard_cost: float = pathing.route_cost(guard_entry, guard_target, true, false, CELL * 0.72)
    var wander_cost: float = pathing.route_cost(guard_entry, wander_target, false, false, CELL * 0.85)
    var wood_near_tree := tree != null and Vector2(wood_target.x - tree.global_position.x, wood_target.z - tree.global_position.z).length() <= CELL * 3.2
    var stone_near_rock := rock != null and Vector2(stone_target.x - rock.global_position.x, stone_target.z - rock.global_position.z).length() <= CELL * 3.2
    var guard_not_center := Vector2(guard_target.x - hostile.global_position.x, guard_target.z - hostile.global_position.z).length() >= CELL * 2.0
    var guard_in_work_area: bool = pathing.point_inside_work_area(guard_entry, guard_target)
    var wander_in_town: bool = pathing.point_inside_town(guard_entry, wander_target)
    var no_fallback_reasons := not String(wood_entry.get("routeReason", "")).begins_with("no_reachable_") and not String(stone_entry.get("routeReason", "")).begins_with("no_reachable_") and not String(guard_entry.get("routeReason", "")).begins_with("no_reachable_")

    add_result(
        "npc_nav_reachability_goal_selection",
        wood_near_resource
            and stone_near_rock
            and guard_not_center
            and guard_in_work_area
            and wander_in_town
            and wood_cost < INF
            and stone_cost < INF
            and guard_cost < INF
            and wander_cost < INF
            and no_fallback_reasons,
        "wood %.1f nearTree %s nearResource %s cost %.1f resources %d first %.1f/%.1f, stone %.1f near %s cost %.1f, guard offset %.1f work %s cost %.1f, wander town %s cost %.1f, reasons %s/%s/%s" % [
            Vector2(wood_target.x - tree_pos.x, wood_target.z - tree_pos.z).length(),
            str(wood_near_tree),
            str(wood_near_resource),
            wood_cost,
            wood_resource_candidates.size(),
            first_wood_resource_distance,
            first_wood_resource_cost,
            Vector2(stone_target.x - rock_pos.x, stone_target.z - rock_pos.z).length(),
            str(stone_near_rock),
            stone_cost,
            Vector2(guard_target.x - hostile.global_position.x, guard_target.z - hostile.global_position.z).length(),
            str(guard_in_work_area),
            guard_cost,
            str(wander_in_town),
            wander_cost,
            String(wood_entry.get("routeReason", "")),
            String(stone_entry.get("routeReason", "")),
            String(guard_entry.get("routeReason", ""))
        ]
    )

    for entry in entries:
        var body := entry.get("body") as Node3D
        if body != null:
            npc_system.unregister_npc(body)
    for body in bodies:
        if is_instance_valid(body):
            body.queue_free()
    if tree != null and is_instance_valid(tree):
        tree.queue_free()
    if rock != null and is_instance_valid(rock):
        rock.queue_free()
    if is_instance_valid(hostile):
        hostile.queue_free()

func make_nav_test_npc(npc_system, npc_id: String, npc_name: String, job: String, town_center: Vector2i, town_radius: int, level: float, cell: Vector2i, can_fight := false) -> Dictionary:
    var body := npc_system.create_npc_body(npc_name, "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    npc_system.safe_place_npc(body, Vector3(float(cell.x) * CELL, level + 0.04, float(cell.y) * CELL), null, "test_spawn")
    return npc_system.register_npc(body, {
        "id": npc_id,
        "name": npc_name,
        "role": "Guard" if can_fight else "Worker",
        "townKey": "npc-nav-reachable-goals",
        "townCenter": town_center,
        "townRadius": town_radius,
        "level": level,
        "homeCell": cell,
        "porchCell": cell,
        "guardCell": Vector2i(town_center.x + town_radius - 2, town_center.y),
        "job": job,
        "canFight": can_fight,
        "nightGuard": can_fight
    })

func dry_work_cell(center: Vector2i, min_radius: int, max_radius: int) -> Vector2i:
    for radius in range(min_radius, max_radius + 1):
        for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP, Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
            var cell: Vector2i = center + direction * radius
            var height: float = main.call("terrain_height_cell", cell.x, cell.y)
            if height >= main.WATER_LEVEL + 0.55:
                return cell
    return center + Vector2i(max_radius, 0)
