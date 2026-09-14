extends "res://scripts/PlaytestRunner.gd"

func run() -> void:
    mark_progress("npc_nav_start")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("npc_nav_main_instantiated")
    if not await wait_for_runtime_loading_complete():
        add_result("startup_loading_complete", false, JSON.stringify({"startup_loading_failure_result": main.get("startup_loading_failure_result")}))
        finish_playtest()
        return
    if main != null:
        if main.get("tutorial_system") != null:
            var tutorial = main.get("tutorial_system")
            tutorial.set("intro_repair_active", false)
            tutorial.set("intro_bed_used", true)
            tutorial.set("final_night_active", false)
            tutorial.set("final_night_complete", true)
        main.set("time_of_day", 0.25)
    await wait_physics_frames(20)

    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        camera = player.get("camera") as Camera3D
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    hold_existing_ambient_npcs()

    var case_filter := OS.get_environment("VOXEL_NPC_NAV_CASE")
    mark_progress("npc_nav_warmup")
    await wait_physics_frames(80)
    var run_all := case_filter == ""
    var run_prelude_generic := case_filter == "prelude_generic"
    if run_all or run_prelude_generic or case_filter == "capsule" or case_filter == "door":
        mark_progress("npc_nav_capsule_gate")
        await test_npc_capsule_collision_gate()
    if run_all or run_prelude_generic or case_filter == "door":
        mark_progress("npc_nav_two_npc_door")
        await test_two_npcs_cross_narrow_door()
    if run_all or run_prelude_generic or case_filter == "home":
        mark_progress("npc_nav_home_fallback")
        await test_home_return_fallback_semantics()
    if run_all or run_prelude_generic or case_filter == "goals":
        mark_progress("npc_nav_reachable_goals")
        await test_reachability_aware_goal_selection()
    if run_all or run_prelude_generic or case_filter == "generic":
        mark_progress("npc_nav_generic_town")
        await test_generic_town_npc_navigation()
    if run_all or case_filter == "route":
        mark_progress("npc_nav_route_core")
        await test_npc_equipment_and_pathing()

    finish_playtest()

func hold_existing_ambient_npcs() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return
    if npc_system.has_method("spawn_generic_town_npcs"):
        npc_system.spawn_generic_town_npcs()
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        var body := entry.get("body") as Node
        if body != null and is_instance_valid(body):
            npc_system.order_wait(body, "npc_navigation_fixture_hold")

func snapshot_height_fixture() -> Array:
    if main != null and main.has_method("snapshot_volume_edits"):
        var snapshot = main.call("snapshot_volume_edits")
        if snapshot is Array:
            return snapshot
    return []

func restore_height_fixture(snapshot: Array, centers: Array) -> void:
    if main == null:
        return
    mark_progress("npc_nav_restore_height_start")
    if snapshot.is_empty():
        var markers = main.get("volume_edit_markers")
        mark_progress("npc_nav_restore_height_clear_markers")
        if markers is Dictionary:
            (markers as Dictionary).clear()
        mark_progress("npc_nav_restore_height_markers_cleared")
        invalidate_navigation_fixture()
        mark_progress("npc_nav_restore_height_done")
        return
    elif main.has_method("restore_volume_edits"):
        mark_progress("npc_nav_restore_height_restore_volume")
        main.call("restore_volume_edits", snapshot)
        mark_progress("npc_nav_restore_height_volume_restored")
    for center_value in centers:
        if center_value is Vector2i and main.has_method("rebuild_chunks_around_cell"):
            mark_progress("npc_nav_restore_height_rebuild_%s" % str(center_value))
            main.call("rebuild_chunks_around_cell", center_value)
            mark_progress("npc_nav_restore_height_rebuilt_%s" % str(center_value))
    invalidate_navigation_fixture()
    mark_progress("npc_nav_restore_height_done")

## The production world is backed by TerrainVolumeService and VoxelTerrain.
## Legacy column markers can guide old mesh helpers, but they do not change the
## native collider. Door acceptance therefore builds its pre-act floor through
## the authoritative volume and waits until real physics observes the result.
func prepare_authoritative_navigation_floor(center: Vector2i, radius: int, sample_cells: Array[Vector2i]) -> Dictionary:
    if main == null:
        return {"ok": false, "reason": "main_missing"}
    var generation = main.get("world_generation_system")
    if generation == null or not generation.has_method("apply_box_edit") or not generation.has_method("surface_projection_for_cell"):
        return {"ok": false, "reason": "terrain_volume_authority_missing"}
    var reference_y := surface_y_at_cell2(center)
    # Put the production viewer over the fixture before editing so the native
    # terrain runtime owns and publishes every affected chunk.
    if player != null:
        player.global_position = Vector3(float(center.x) * CELL, reference_y + CELL * 8.0, float(center.y) * CELL)
        player.velocity = Vector3.ZERO
        if main.has_method("update_chunks"):
            main.call("update_chunks", false)
        await wait_physics_frames(3)
    var projection: Dictionary = generation.surface_projection_for_cell(
        Vector3i(center.x, floori(reference_y / CELL), center.y), 32, 96
    )
    if not bool(projection.get("found", false)):
        return {"ok": false, "reason": "terrain_surface_projection_missing"}
    var solid_cell: Vector3i = projection.get("solidCell", Vector3i(center.x, floori(reference_y / CELL), center.y))
    var floor_y := solid_cell.y
    var min_x := center.x - radius
    var max_x := center.x + radius
    var min_z := center.y - radius
    var max_z := center.y + radius
    # This must participate in surface projection as well as native meshing.
    # The structure_* namespace intentionally opts out of terrain projection,
    # so a fixture-owned source is used here.
    var metadata := {"source": "npc_navigation_fixture", "terrainMeshAffects": true, "saveDelta": false}
    generation.apply_box_edit(
        Vector3i(min_x, floor_y, min_z), Vector3i(max_x, floor_y, max_z),
        {"material": "stone", "biome": "plains", "solid": true, "density": CELL, "fluid": "", "light": {"sky": 0, "block": 0}, "metadata": metadata},
        "npc_navigation_fixture_floor"
    )
    generation.apply_box_edit(
        Vector3i(min_x, floor_y + 1, min_z), Vector3i(max_x, floor_y + 4, max_z),
        {"material": "air", "biome": "plains", "solid": false, "density": -CELL, "fluid": "", "light": {"sky": 15, "block": 0}, "metadata": metadata},
        "npc_navigation_fixture_clearance"
    )
    var expected_y := (float(floor_y) + 0.5) * CELL
    var last_probe := {}
    var bounds := Rect2i(min_x, min_z, max_x - min_x + 1, max_z - min_z + 1)
    for frame in range(240):
        last_probe = authoritative_navigation_floor_probe(sample_cells, expected_y)
        var runtime = main.get("voxel_terrain_runtime")
        var runtime_stats: Dictionary = runtime.stats() if runtime != null and runtime.has_method("stats") else {}
        var readiness: Dictionary = runtime.region_publication_readiness(bounds) if runtime != null and runtime.has_method("region_publication_readiness") else {"status": "failed", "reason": "region_readiness_missing"}
        if bool(last_probe.get("ok", false)) and String(readiness.get("status", "")) == "ready":
            last_probe["runtime"] = runtime_stats
            last_probe["readiness"] = readiness
            return last_probe
        if frame % 30 == 0:
            mark_progress("npc_nav_authoritative_floor_%d" % frame)
        await wait_physics_frames(1)
    last_probe["reason"] = "authoritative_floor_collision_timeout"
    return last_probe

func authoritative_navigation_floor_probe(cells: Array[Vector2i], expected_y: float) -> Dictionary:
    if main == null or main.get_world_3d() == null:
        return {"ok": false, "reason": "physics_world_missing"}
    var heights := {}
    var min_height := INF
    var max_height := -INF
    for cell in cells:
        var x := float(cell.x) * CELL
        var z := float(cell.y) * CELL
        var query := PhysicsRayQueryParameters3D.create(
            Vector3(x, expected_y + CELL * 6.0, z),
            Vector3(x, expected_y - CELL * 6.0, z)
        )
        query.collision_mask = 2
        query.collide_with_bodies = true
        query.collide_with_areas = false
        var hit: Dictionary = main.get_world_3d().direct_space_state.intersect_ray(query)
        var collider = hit.get("collider")
        var normal: Vector3 = hit.get("normal", Vector3.ZERO)
        if hit.is_empty() or collider == null or String(collider.get_meta("kind", "")) != "terrain" or normal.y < 0.90:
            return {"ok": false, "reason": "authoritative_floor_not_published", "cell": cell, "hit": hit}
        var height := float((hit.get("position", Vector3.ZERO) as Vector3).y)
        heights["%d,%d" % [cell.x, cell.y]] = height
        min_height = minf(min_height, height)
        max_height = maxf(max_height, height)
    return {
        "ok": not heights.is_empty() and max_height - min_height <= CELL * 0.12,
        "reason": "" if max_height - min_height <= CELL * 0.12 else "authoritative_floor_not_flat",
        "heights": heights,
        "minHeight": min_height,
        "maxHeight": max_height
    }

func move_player_to_fixture_cell(cell: Vector2i) -> void:
    if main == null or player == null:
        return
    var height: float = surface_y_at_cell2(cell)
    player.global_position = Vector3(float(cell.x) * CELL, height + 0.04, float(cell.y) * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)

## A publication receipt proves that a region RID and its source geometry were
## installed. Route acceptance additionally needs the engine map to own the
## actual endpoints. This bounded headed-fixture gate observes that production
## boundary after ordinary route demand has queued the tile.
func wait_for_route_fixture_server_endpoints(points: Array[Vector3], expected_tile_key: String, max_frames := 300) -> Dictionary:
    var result := {
        "ok": false,
        "reason": "navigation_endpoint_owner_timeout",
        "expectedRegion": "region:chunk:%s" % expected_tile_key,
        "points": []
    }
    if main == null or points.is_empty():
        result["reason"] = "navigation_endpoint_fixture_missing"
        return result
    var npc_system = main.get("npc_system")
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var service = autonomy.get("navmesh_world") if autonomy != null else null
    var pathing = npc_system.get("pathing") if npc_system != null else null
    if pathing != null and pathing.has_method("ensure_ready"):
        pathing.ensure_ready()
    var producer = pathing.get("navigation_world") if pathing != null else null
    var route_planner = pathing.get("route_planner") if pathing != null else null
    var publisher = route_planner.get("delegate") if route_planner != null else null
    var readiness_owner := {"kind":"readiness","id":"headed_route_fixture:%s" % expected_tile_key}
    if service == null or not service.get("navigation_map") is RID:
        result["reason"] = "navigation_endpoint_service_missing"
        return result
    var expected_region := String(result.expectedRegion)
    for frame in range(max_frames):
        # The fixture is the pre-act owner of this publication requirement.
        # Retain that exact demand if terrain/structure revisions change while
        # the asynchronous capture, preparation, upload and sync pipeline runs.
        if publisher != null and publisher.has_method("queue_navmesh_tile_publish"):
            publisher.queue_navmesh_tile_publish(expected_tile_key,true,readiness_owner)
        var navigation_map: RID = service.get("navigation_map")
        var observations: Array = []
        var source_key := String(producer.navmesh_tile_source_key_for_tile(expected_tile_key)) \
            if producer != null and producer.has_method("navmesh_tile_source_key_for_tile") else ""
        var receipt: Dictionary = service.tile_publication_readiness(expected_tile_key, source_key) \
            if not source_key.is_empty() and service.has_method("tile_publication_readiness") else {}
        var all_owned: bool = navigation_map.is_valid() and String(receipt.get("status", "")) == "ready"
        for point in points:
            var owner := NavigationServer3D.map_get_closest_point_owner(navigation_map, point) if navigation_map.is_valid() else RID()
            var closest := NavigationServer3D.map_get_closest_point(navigation_map, point) if navigation_map.is_valid() else Vector3.INF
            var region_id := String(service.get("region_ids_by_rid").get(owner, "")) if owner.is_valid() else ""
            var distance := point.distance_to(closest) if closest.is_finite() else INF
            observations.append({"point": point, "closest": closest, "distance": distance, "regionId": region_id, "ownerValid": owner.is_valid()})
            if not owner.is_valid() or region_id != expected_region or distance > CELL * 0.95:
                all_owned = false
        result["points"] = observations
        result["sourceKey"] = source_key
        result["receipt"] = {
            "status": receipt.get("status", ""),
            "reason": receipt.get("reason", ""),
            "sourceKey": receipt.get("sourceKey", ""),
            "sourceRevision": receipt.get("sourceRevision", -1),
            "installationSerial": receipt.get("installationSerial", 0),
            "completeSurfaceCoverage": receipt.get("completeSurfaceCoverage", false)
        }
        if all_owned:
            result["ok"] = true
            result["reason"] = ""
            result["frames"] = frame
            return result
        if frame % 30 == 0:
            mark_progress("npc_nav_route_endpoint_sync_%03d" % frame)
        await wait_physics_frames(1)
    return result

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
    mark_progress("npc_nav_generic_move_fixture")
    move_player_to_fixture_cell(Vector2i(generic_center_x, generic_center_z))
    mark_progress("npc_nav_generic_wait_chunks")
    await settle_streamed_chunks_after_relocation("npc_nav_generic_chunks", 180)
    mark_progress("npc_nav_generic_build_town")
    structure_system.call("build_town", generic_town)
    mark_progress("npc_nav_generic_spawn_npcs")
    npc_system.spawn_generic_town_npcs()
    mark_progress("npc_nav_generic_initial_update")
    npc_system.update_npcs(0.1, 1.0)
    mark_progress("npc_nav_generic_collect_homes")

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
        mark_progress("npc_nav_generic_setup_forager")
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
        var forage_ground: float = surface_y_at_cell2(forage_cell)
        if forage_ground < main.WATER_LEVEL + 0.55:
            for fallback_direction in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
                var fallback_cell := Vector2i(
                    roundi(float(generic_center_x) + fallback_direction.x * forage_distance),
                    roundi(float(generic_center_z) + fallback_direction.y * forage_distance)
                )
                var fallback_ground: float = surface_y_at_cell2(fallback_cell)
                if fallback_ground >= main.WATER_LEVEL + 0.55:
                    forage_cell = fallback_cell
                    forage_ground = fallback_ground
                    break
        clear_props_near_cell(forage_cell, 5)
        clear_blocks_near_cell(forage_cell, 3)
        mark_progress("npc_nav_generic_spawn_forage")
        forage_ground = surface_y_at_cell2(forage_cell)
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
    var generic_job_steps := 1600
    for step in range(generic_job_steps):
        if step % 160 == 0:
            mark_progress("npc_nav_generic_town_jobs_%d" % step)
        # This is headed acceptance: let the production game loop, physics motor,
        # navigation capture and publication queues advance together once per tick.
        await wait_physics_frames(1)
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

    var job_stats: Dictionary = npc_system.stats()
    var forager_inventory: Dictionary = generic_forager.get("personalInventory", {}) if not generic_forager.is_empty() else {}
    var forager_food := int(forager_inventory.get("berries", 0))
    var forager_hunger := float(generic_forager.get("hunger", 0.0)) if not generic_forager.is_empty() else 0.0
    var forager_target_distance := -1.0
    var forager_node_distance := -1.0
    var forager_debug := {}
    if not generic_forager.is_empty():
        var forager_body := generic_forager.get("body") as Node3D
        var forager_target: Vector3 = generic_forager.get("jobTarget", Vector3.ZERO)
        var forager_node := generic_forager.get("jobTargetNode") as Node3D
        if forager_body != null and is_instance_valid(forager_body):
            forager_target_distance = forager_body.global_position.distance_to(forager_target)
            if forager_node != null and is_instance_valid(forager_node):
                forager_node_distance = forager_body.global_position.distance_to(forager_node.global_position)
            forager_debug = {
                "actorPosition": forager_body.global_position,
                "cell": world_to_flat_cell(forager_body.global_position),
                "target": forager_target,
                "targetCell": world_to_flat_cell(forager_target),
                "targetPosition": forager_target,
                "targetNodePosition": forager_node.global_position if forager_node != null and is_instance_valid(forager_node) else Vector3.INF,
                "lastMove": float(generic_forager.get("lastMoveDistance", 0.0)),
                "routeWaitTicks": int(generic_forager.get("routeWaitTicks", 0)),
                "routeReplans": int(generic_forager.get("routeReplans", 0)),
                "waypoints": (generic_forager.get("pathWaypoints", []) as Array).size(),
                "routeCells": (generic_forager.get("routeCells", []) as Array).size(),
                "job": String(generic_forager.get("job", "")),
                "jobPhase": String(generic_forager.get("jobPhase", "")),
                "jobTimer": float(generic_forager.get("jobTimer", 0.0)),
                "jobFailureReason": String(generic_forager.get("jobFailureReason", "")),
                "jobReservationId": String(generic_forager.get("jobReservationId", "")),
                "jobApproachSlotId": String(generic_forager.get("jobApproachSlotId", "")),
                "scriptedOrder": generic_forager.get("scriptedOrder", {}),
                "lod": String(generic_forager.get("simulationLod", "")),
                "brainDue": bool(generic_forager.get("npc_lod_brain_due", false)),
                "brainUpdates": int(generic_forager.get("npc_brain_updates", 0)),
                "brainSkipped": int(generic_forager.get("npc_brain_budget_skipped", 0)),
                "motionUpdates": int(generic_forager.get("npc_motion_updates", 0)),
                "motionBudgetSkipped": int(generic_forager.get("npc_motion_budget_skipped", 0)),
                "motionSkipped": String(generic_forager.get("npc_motion_skipped_reason", "")),
                "routeTicketState": String(generic_forager.get("routeTicketState", "")),
                "routeTicketReason": String(generic_forager.get("routeTicketReason", "")),
                "routeTicketAttempts": int(generic_forager.get("routeTicketAttempts", 0)),
                "jobObjectId": String(generic_forager.get("jobObjectId", "")),
                "lastResolvedEndpointDebug": generic_forager.get("lastResolvedEndpointDebug", {}),
                "lastRoutePlanDebug": generic_forager.get("lastRoutePlanDebug", {}),
                "routePlannerStats": route_planner_stats(npc_system),
                "tilePublish": generic_forager.get("lastNavmeshTilePublishDebug", []),
                "routeFallbackCell": generic_forager.get("routeFallbackCell", Vector2i.ZERO),
                "blockedContact": String(forager_body.get_meta("npc_blocked_contact", "")),
                "blockedName": String(forager_body.get_meta("npc_blocked_contact_name", "")),
                "blockedKind": String(forager_body.get_meta("npc_blocked_contact_kind", "")),
                "blockedType": String(forager_body.get_meta("npc_blocked_contact_type", "")),
                "capsuleBlocker": generic_forager.get("capsuleBlocker", {}),
                "slideCount": int(forager_body.get_meta("npc_slide_collision_count", 0)),
                "corridor": generic_forager.get("corridorFollow", {})
            }
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
        "goal %s, target selected %s, berries %d, hunger %.1f, forage %d->%d, phase %s, route %s/%s, dist target %.2f node %.2f, debug %s" % [
            str(forager_goal_seen),
            str(targeted_forage_selected),
            forager_food,
            forager_hunger,
            forage_runs_before,
            int(job_stats.get("forageRuns", 0)),
            String(generic_forager.get("jobPhase", "")),
            String(generic_forager.get("routeStatus", "")),
            String(generic_forager.get("routeReason", "")),
            forager_target_distance,
            forager_node_distance,
            JSON.stringify(forager_debug)
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

func route_planner_stats(npc_system) -> Dictionary:
    if npc_system == null:
        return {}
    var pathing = npc_system.get("pathing")
    if pathing == null:
        return {}
    if pathing.has_method("stats"):
        return pathing.stats()
    var route_planner = pathing.get("route_planner") if pathing is Object else null
    if route_planner != null and route_planner.has_method("stats"):
        return route_planner.stats()
    return {}

func test_npc_capsule_collision_gate() -> void:
    if not main or not player:
        add_result("npc_nav_capsule_collision_gate", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_capsule_collision_gate", false, "npc system missing")
        return
    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 58, roundi(player.global_position.z / CELL) + 58)
    var height_snapshot := snapshot_height_fixture()
    reset_player_on_flat_patch(start_cell)
    clear_blocks_near_cell(start_cell, 10)
    clear_props_near_cell(start_cell, 12)
    await wait_physics_frames(3)

    var base_height: float = surface_y_at_cell2(start_cell)
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
            main.call("request_door_state", door, true, null, "test", { "authorized": true })
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
    restore_height_fixture(height_snapshot, [start_cell])
    invalidate_navigation_fixture()

func test_two_npcs_cross_narrow_door() -> void:
    if not main or not player:
        add_result("npc_nav_two_npc_door_crossing", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_nav_two_npc_door_crossing", false, "npc system missing")
        return
    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 64, roundi(player.global_position.z / CELL) + 64)
    var height_snapshot := snapshot_height_fixture()
    var floor_samples: Array[Vector2i] = [
        start_cell + Vector2i(1, 0),
        start_cell + Vector2i(4, 0),
        start_cell + Vector2i(7, 0)
    ]
    var floor_result: Dictionary = await prepare_authoritative_navigation_floor(start_cell, 9, floor_samples)
    if not bool(floor_result.get("ok", false)):
        add_result("npc_nav_two_npc_door_crossing", false, "authoritative floor failed %s" % JSON.stringify(floor_result))
        return
    var floor_heights: Dictionary = floor_result.get("heights", {})
    player.global_position = Vector3(float(start_cell.x) * CELL, float(floor_result.get("maxHeight", surface_y_at_cell2(start_cell))) + 0.08, float(start_cell.y) * CELL)
    player.velocity = Vector3.ZERO
    clear_blocks_near_cell(start_cell, 12)
    clear_props_near_cell(start_cell, 14)
    await wait_physics_frames(3)

    var base_height: float = float(floor_result.get("maxHeight", surface_y_at_cell2(start_cell)))
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
        var block_options := {"world_y": wall_y}
        if block_type == "door":
            block_options["doorPolicy"] = "public_gate"
            block_options["doorPublicAccess"] = true
        main.call("create_block", cell, block_type, block_options)
    await wait_physics_frames(3)

    var left_start := Vector3(float(start_cell.x + 1) * CELL, float(floor_heights.get("%d,%d" % [start_cell.x + 1, start_cell.y], base_height)) + 0.08, float(start_cell.y) * CELL)
    var right_start := Vector3(float(start_cell.x + 7) * CELL, float(floor_heights.get("%d,%d" % [start_cell.x + 7, start_cell.y], base_height)) + 0.08, float(start_cell.y) * CELL)
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
    var left_placement: Dictionary = npc_system.safe_place_npc(left_npc, left_start, null, "test_spawn")
    var right_placement: Dictionary = npc_system.safe_place_npc(right_npc, right_start, null, "test_spawn")
    if not bool(left_placement.get("ok", false)) or not bool(right_placement.get("ok", false)):
        add_result("npc_nav_two_npc_door_crossing", false, "authoritative spawn failed left=%s right=%s" % [JSON.stringify(left_placement), JSON.stringify(right_placement)])
        if is_instance_valid(left_npc):
            left_npc.queue_free()
        if is_instance_valid(right_npc):
            right_npc.queue_free()
        for cell in barrier_cells:
            if blocks.has(cell):
                var failed_block := blocks[cell] as Node
                if failed_block:
                    failed_block.queue_free()
                blocks.erase(cell)
        invalidate_navigation_fixture()
        return

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
    var traffic_before := {}
    if npc_system.get("autonomy_system") != null and npc_system.get("autonomy_system").has_method("stats"):
        var autonomy_before: Dictionary = npc_system.get("autonomy_system").stats()
        traffic_before = autonomy_before.get("traffic", {})
    var shared_cell := false
    var both_crossed := false
    var min_separation := INF
    var door_world_x := float(door_cell.x) * CELL
    for step in range(520):
        if step % 80 == 0:
            mark_progress("npc_nav_two_npc_door_%d" % step)
        if pathing != null and pathing.has_method("begin_frame"):
            pathing.begin_frame()
        npc_system.move_npc(left_entry, right_start, CELL * 0.22, false, false)
        npc_system.move_npc(right_entry, left_start, CELL * 0.22, false, false)
        npc_system.update_door_policies(0.18)
        var left_cell := world_to_flat_cell(left_npc.global_position)
        var right_cell := world_to_flat_cell(right_npc.global_position)
        if left_cell == right_cell:
            shared_cell = true
        min_separation = minf(min_separation, Vector2(left_npc.global_position.x - right_npc.global_position.x, left_npc.global_position.z - right_npc.global_position.z).length())
        if left_npc.global_position.x > door_world_x + CELL * 0.55 and right_npc.global_position.x < door_world_x - CELL * 0.55:
            both_crossed = true
            break
        await wait_physics_frames(1)
    for i in range(160):
        if pathing != null and pathing.has_method("begin_frame"):
            pathing.begin_frame()
        npc_system.move_npc(left_entry, right_start, CELL * 0.22, false, false)
        npc_system.move_npc(right_entry, left_start, CELL * 0.22, false, false)
        npc_system.update_door_policies(0.18)
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
    var traffic_state := {}
    var door_portal_summary := {}
    var pathing_state: Dictionary = pathing.stats() if pathing != null and pathing.has_method("stats") else {}
    if npc_system.get("autonomy_system") != null and npc_system.get("autonomy_system").has_method("stats"):
        var autonomy_stats: Dictionary = npc_system.get("autonomy_system").stats()
        traffic_state = autonomy_stats.get("traffic", {})
        door_portal_summary = autonomy_stats.get("doorPortals", {})
    # A safe alternating crossing can be granted without either actor ever
    # entering the wait state. The traffic contract suite separately proves
    # forced contention and waiting. This live case requires actual reservation
    # use and release, safe separation, both arrivals, and the door lifecycle.
    var traffic_used := int(traffic_state.get("granted", 0)) > int(traffic_before.get("granted", 0)) \
        and int(traffic_state.get("released", 0)) > int(traffic_before.get("released", 0)) \
        and int(traffic_state.get("activeReservations", 0)) == 0
    add_result(
        "npc_nav_two_npc_door_crossing",
        both_crossed
            and not shared_cell
            and min_separation >= CELL * 0.34
            and traffic_used
            and int(stats_after.get("doorOpens", 0)) > door_opens_before
            and int(stats_after.get("doorCloses", 0)) > door_closes_before
            and door_closed,
        "crossed %s, shared %s, minSep %.2f, left %.2f cell %s wants %s dist %.2f goal %s body %s actionCount %d activeDoor %s, right %.2f cell %s wants %s dist %.2f goal %s body %s actionCount %d activeDoor %s, doorX %.2f, waits %d->%d, door %d/%d -> %d/%d, closed %s, routes %s/%s %s/%s, leftDebug %s, rightDebug %s, leftTiles %s, rightTiles %s, rightEscape %s failedEscape %s capsule %s portalSummary %s, traffic active=%s waiting=%s granted=%s denied=%s released=%s, pathing %s" % [
            str(both_crossed),
            str(shared_cell),
            min_separation,
            left_npc.global_position.x,
            str(left_final_cell),
            str(left_requested_cell),
            left_target_dist,
            str(left_entry.get("routeGoalCell", Vector2i.ZERO)),
            str(left_entry_body == left_npc),
            (left_entry.get("routeActions", {}) as Dictionary).size(),
            String(left_entry.get("activeDoorPortalId", "")),
            right_npc.global_position.x,
            str(right_final_cell),
            str(right_requested_cell),
            right_target_dist,
            str(right_entry.get("routeGoalCell", Vector2i.ZERO)),
            str(right_entry_body == right_npc),
            (right_entry.get("routeActions", {}) as Dictionary).size(),
            String(right_entry.get("activeDoorPortalId", "")),
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
            String(right_entry.get("routeReason", "")),
            JSON.stringify(left_entry.get("lastRoutePlanDebug", {})),
            JSON.stringify(right_entry.get("lastRoutePlanDebug", {})),
            JSON.stringify(left_entry.get("lastNavmeshTilePublishDebug", [])),
            JSON.stringify(right_entry.get("lastNavmeshTilePublishDebug", [])),
            JSON.stringify(right_entry.get("lastMotorLocalEscape", {})),
            JSON.stringify(right_entry.get("lastMotorLocalEscapeFailed", {})),
            JSON.stringify(right_entry.get("capsuleBlocker", right_npc.get_meta("npc_capsule_blocker", {}) if right_npc.has_meta("npc_capsule_blocker") else {})),
            JSON.stringify(door_portal_summary),
            str(traffic_state.get("activeReservations", "")),
            str(traffic_state.get("waiting", "")),
            str(traffic_state.get("granted", "")),
            str(traffic_state.get("denied", "")),
            str(traffic_state.get("released", "")),
            JSON.stringify(pathing_state)
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
    restore_height_fixture(height_snapshot, [start_cell])
    invalidate_navigation_fixture()

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

    var level: float = surface_y_at_cell2(home_cell)
    var body := npc_system.create_npc_body("NpcNavHomeFallback", "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    npc_system.safe_place_npc(body, Vector3(float(start_cell.x) * CELL, level + 0.04, float(start_cell.y) * CELL), null, "test_spawn")
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": "npc-nav-home-terminal",
        "name": "Home Terminal Tester",
        "role": "Worker",
        "townKey": "npc-nav-home-terminal",
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
    NpcRouteStateStoreScript.write_status(entry, "moving", "", "NpcNavigationTestRunner.home_terminal_fixture")
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
    NpcRouteStateStoreScript.write_status_preserving_reason(entry, "arrived", "NpcNavigationTestRunner.home_route_fixture")
    entry["homeActiveTargetCell"] = first_route_cell
    var next_home_target: Vector3 = npc_system.home_route_target(entry)
    var advanced_route_waypoint := int(entry.get("homeRouteIndex", 0)) == 1 and world_to_flat_cell(next_home_target) == second_route_cell

    npc_system.safe_place_npc(body, Vector3(float(porch_cell.x + 1) * CELL, level + 0.04, float(porch_cell.y + 1) * CELL), null, "test_home_setup")
    entry["homeRoutePositions"] = []
    entry["homeRouteIndex"] = 0
    NpcRouteStateStoreScript.write_status_preserving_reason(entry, "arrived", "NpcNavigationTestRunner.porch_route_fixture")
    entry["homeActiveTargetCell"] = porch_cell
    var final_home_target: Vector3 = npc_system.home_route_target(entry)
    var advanced_from_porch := world_to_flat_cell(final_home_target) == home_cell

    var porch_position: Vector3 = entry.get("porchPosition", body.global_position)
    npc_system.safe_place_npc(body, porch_position, null, "test_home_setup")
    var blocked_start_position := body.global_position
    entry["insideHome"] = false
    body.set_meta("npc_inside_home", false)
    entry["homeRoutePositions"] = []
    entry["homeRouteIndex"] = 0
    NpcRouteStateStoreScript.write_status(entry, "blocked", "no_candidate_goal", "NpcNavigationTestRunner.blocked_home_fixture")
    entry["homeActiveTargetCell"] = home_cell
    entry.erase("homeSettleDebug")
    var unreachable_before := int(entry.get("unreachableGoals", 0))
    npc_system.settle_home_if_reached(entry)
    var unreachable_after := int(entry.get("unreachableGoals", 0))
    var terminal_blocked := not bool(entry.get("insideHome", false)) \
        and not bool(body.get_meta("npc_inside_home", false)) \
        and String(entry.get("routeStatus", "")) == "blocked" \
        and String(entry.get("routeReason", "")) == "home_route_terminal_outside" \
        and unreachable_after > unreachable_before \
        and body.global_position.distance_to(blocked_start_position) <= 0.001

    add_result(
        "npc_nav_home_return_terminal_semantics",
        timer_did_not_mark and advanced_route_waypoint and advanced_from_porch and terminal_blocked,
        "timer safe %s, route advance %s, porch advance %s, terminal %s, route %s/%s, unreachable %d->%d, debug %s" % [
            str(timer_did_not_mark),
            str(advanced_route_waypoint),
            str(advanced_from_porch),
            str(terminal_blocked),
            String(entry.get("routeStatus", "")),
            String(entry.get("routeReason", "")),
            unreachable_before,
            unreachable_after,
            JSON.stringify(entry.get("homeSettleDebug", {}))
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
    var height_snapshot := snapshot_height_fixture()
    clear_blocks_near_cell(start_cell, 18)
    clear_props_near_cell(start_cell, 36)
    var town_radius := 12
    var wood_cell := start_cell + Vector2i(-2, 0)
    var stone_cell := start_cell + Vector2i(2, 0)
    var guard_cell := start_cell + Vector2i(0, 3)
    var tree_cell := start_cell + Vector2i(6, 0)
    var rock_cell := start_cell + Vector2i(0, 7)
    var hostile_cell := start_cell + Vector2i(17, 0)
    var floor_result: Dictionary = await prepare_authoritative_navigation_floor(
        start_cell, 20, [start_cell, wood_cell, stone_cell, guard_cell, tree_cell, rock_cell, hostile_cell])
    if not bool(floor_result.get("ok", false)):
        add_result("npc_nav_reachability_goal_selection", false,
            "authoritative goal fixture floor failed %s" % JSON.stringify(floor_result))
        restore_height_fixture(height_snapshot, [start_cell])
        return
    move_player_to_fixture_cell(start_cell + Vector2i(0, -8))
    await wait_physics_frames(3)

    var base_height: float = surface_y_at_cell2(start_cell)
    var prop_root := main.get("prop_root") as Node
    var rng := RandomNumberGenerator.new()
    rng.seed = 908177
    var tree_pos := Vector3(float(tree_cell.x) * CELL, surface_y_at_cell2(tree_cell), float(tree_cell.y) * CELL)
    var rock_pos := Vector3(float(rock_cell.x) * CELL, surface_y_at_cell2(rock_cell), float(rock_cell.y) * CELL)
    var tree := main.call("make_tree", prop_root, "npc-nav:wood-target", tree_pos, "forest", rng) as Node3D
    var rock := main.call("make_rock", prop_root, "npc-nav:stone-target", rock_pos, rng) as Node3D
    await wait_physics_frames(3)

    var entries: Array[Dictionary] = []
    var bodies: Array[Node3D] = []
    var wood_entry := make_nav_test_npc(npc_system, "npc-nav-wood-worker", "Wood Worker", "wood", start_cell, town_radius, base_height, wood_cell)
    var stone_entry := make_nav_test_npc(npc_system, "npc-nav-stone-worker", "Stone Worker", "stone", start_cell, town_radius, base_height, stone_cell)
    var guard_entry := make_nav_test_npc(npc_system, "npc-nav-guard-worker", "Guard", "", start_cell, town_radius, base_height, guard_cell, true)
    var placement_failures := []
    for candidate_entry in [wood_entry, stone_entry, guard_entry]:
        if candidate_entry.has("fixturePlacementFailure"):
            placement_failures.append(candidate_entry)
    if not placement_failures.is_empty():
        add_result("npc_nav_reachability_goal_selection", false, "authoritative actor placement failed %s" % JSON.stringify(placement_failures))
        if tree != null and is_instance_valid(tree):
            tree.queue_free()
        if rock != null and is_instance_valid(rock):
            rock.queue_free()
        restore_height_fixture(height_snapshot, [start_cell])
        invalidate_navigation_fixture()
        return
    for entry in [wood_entry, stone_entry, guard_entry]:
        if not entry.is_empty():
            entries.append(entry)
            var body := entry.get("body") as Node3D
            if body != null:
                bodies.append(body)

    var hostile_height: float = surface_y_at_cell2(hostile_cell)
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
        first_wood_resource_cost = pathing.route_cost(wood_entry, wood_resource_candidates[0], false, false, CELL * 0.85)
    var wood_near_resource := false
    for candidate in wood_resource_candidates:
        if Vector2(wood_target.x - candidate.x, wood_target.z - candidate.z).length() <= CELL * 1.15:
            wood_near_resource = true
            break
    var wood_cost: float = pathing.route_cost(wood_entry, wood_target, false, false, CELL * 0.85)
    var stone_cost: float = pathing.route_cost(stone_entry, stone_target, false, false, CELL * 0.85)
    var guard_cost: float = pathing.route_cost(guard_entry, guard_target, true, false, CELL * 0.72)
    var wander_cost: float = pathing.route_cost(guard_entry, wander_target, false, false, CELL * 0.85)
    var wood_near_tree := tree != null and Vector2(wood_target.x - tree.global_position.x, wood_target.z - tree.global_position.z).length() <= CELL * 3.2
    var stone_near_rock := rock != null and Vector2(stone_target.x - rock.global_position.x, stone_target.z - rock.global_position.z).length() <= CELL * 3.2
    var wood_target_in_town: bool = pathing.point_inside_town(wood_entry, wood_target)
    var stone_target_in_town: bool = pathing.point_inside_town(stone_entry, stone_target)
    var guard_not_center := Vector2(guard_target.x - hostile.global_position.x, guard_target.z - hostile.global_position.z).length() >= CELL * 2.0
    var guard_in_work_area: bool = pathing.point_inside_work_area(guard_entry, guard_target)
    var wander_in_town: bool = pathing.point_inside_town(guard_entry, wander_target)
    var no_fallback_reasons := not String(wood_entry.get("routeReason", "")).begins_with("no_reachable_") and not String(stone_entry.get("routeReason", "")).begins_with("no_reachable_") and not String(guard_entry.get("routeReason", "")).begins_with("no_reachable_")

    add_result(
        "npc_nav_reachability_goal_selection",
        wood_near_resource
            and stone_near_rock
            and wood_target_in_town
            and stone_target_in_town
            and guard_not_center
            and guard_in_work_area
            and wander_in_town
            and wood_cost < INF
            and stone_cost < INF
            and guard_cost < INF
            and wander_cost < INF
            and no_fallback_reasons,
        "wood %.1f nearTree %s nearResource %s inTown %s cost %.1f resources %d first %.1f/%.1f debug %s, stone %.1f near %s inTown %s cost %.1f debug %s, guard offset %.1f work %s cost %.1f, wander town %s cost %.1f, reasons %s/%s/%s" % [
            Vector2(wood_target.x - tree_pos.x, wood_target.z - tree_pos.z).length(),
            str(wood_near_tree),
            str(wood_near_resource),
            str(wood_target_in_town),
            wood_cost,
            wood_resource_candidates.size(),
            first_wood_resource_distance,
            first_wood_resource_cost,
            JSON.stringify(wood_entry.get("lastResourceCandidateDebug", {})),
            Vector2(stone_target.x - rock_pos.x, stone_target.z - rock_pos.z).length(),
            str(stone_near_rock),
            str(stone_target_in_town),
            stone_cost,
            JSON.stringify(stone_entry.get("lastResourceCandidateDebug", {})),
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
    mark_progress("npc_nav_reachable_goals_cleanup_restore")
    restore_height_fixture(height_snapshot, [start_cell])
    mark_progress("npc_nav_reachable_goals_cleanup_wait")
    invalidate_navigation_fixture()
    await wait_physics_frames(3)
    invalidate_navigation_fixture()
    mark_progress("npc_nav_reachable_goals_cleanup_done")

func make_nav_test_npc(npc_system, npc_id: String, npc_name: String, job: String, town_center: Vector2i, town_radius: int, level: float, cell: Vector2i, can_fight := false) -> Dictionary:
    var body := npc_system.create_npc_body(npc_name, "npc") as CharacterBody3D
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    # Each fixture actor must be placed against the terrain at its own cell.
    # Reusing the town-center height can reject the spawn on ordinary slopes;
    # the old test ignored that receipt and then queried resources from the
    # body's default origin hundreds of metres away.
    var cell_level := surface_y_at_cell2(cell)
    var placement: Dictionary = npc_system.safe_place_npc(body, Vector3(float(cell.x) * CELL, cell_level + 0.04, float(cell.y) * CELL), null, "test_spawn")
    if not bool(placement.get("ok", false)):
        if is_instance_valid(body):
            body.queue_free()
        return {"fixturePlacementFailure": placement, "id": npc_id}
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": npc_id,
        "name": npc_name,
        "role": "Guard" if can_fight else "Worker",
        "townKey": "npc-nav-reachable-goals",
        "townCenter": town_center,
        "townRadius": town_radius,
        "level": cell_level,
        "homeCell": cell,
        "porchCell": cell,
        "guardCell": Vector2i(town_center.x + town_radius - 2, town_center.y),
        "job": job,
        "canFight": can_fight,
        "nightGuard": can_fight
    })
    entry["fixturePlacement"] = placement
    return entry

func dry_work_cell(center: Vector2i, min_radius: int, max_radius: int) -> Vector2i:
    for radius in range(min_radius, max_radius + 1):
        for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP, Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
            var cell: Vector2i = center + direction * radius
            var height: float = surface_y_at_cell2(cell)
            if height >= main.WATER_LEVEL + 0.55:
                return cell
    return center + Vector2i(max_radius, 0)
