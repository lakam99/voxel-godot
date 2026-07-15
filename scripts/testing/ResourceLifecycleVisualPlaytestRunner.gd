extends "res://scripts/testing/CanopyReleasePlaytestRunner.gd"

const GROUND_FORAGE_MATERIALS := ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]
const RESOURCE_INTERACTION_OFFSETS := [
    Vector3(0.0, 0.0, CELL * 1.85),
    Vector3(CELL * 1.85, 0.0, 0.0),
    Vector3(0.0, 0.0, -CELL * 1.85),
    Vector3(-CELL * 1.85, 0.0, 0.0)
]

func configure_paths() -> void:
    report_path = OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/vox124-resource-lifecycle.json")
    progress_path = OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_PROGRESS").strip_edges()
    if progress_path == "":
        progress_path = ProjectSettings.globalize_path("res://artifacts/npc/progress/vox124-resource-lifecycle.txt")
    screenshot_dir = OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_SCREENSHOT_DIR").strip_edges()
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/vox124-resource-lifecycle")
    ensure_dir(report_path.get_base_dir())
    ensure_dir(progress_path.get_base_dir())
    ensure_dir(screenshot_dir)

func watchdog_seconds() -> float:
    var text := OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_WATCHDOG_SECONDS").strip_edges()
    return maxf(90.0, float(text)) if text != "" else 480.0

func run() -> void:
    release_stage = OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_STAGE").strip_edges().to_lower()
    report_data = {
        "schemaVersion": 1,
        "runnerId": "vox124_resource_lifecycle_visual",
        "testId": "vox_124_tree_and_ground_forage_resource_lifecycle",
        "runToken": OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_RUN_TOKEN"),
        "stage": release_stage,
        "finished": false,
        "passed": false,
        "failureCount": 0,
        "resultCount": 0,
        "evidenceLevel": "acceptance_visual",
        "acceptanceClaims": [
            "live_tree_and_ground_forage_retire_atomically",
            "unharvested_stream_rebind_is_available",
            "depleted_resources_survive_streaming_and_continue"
        ],
        "scope": "Headed production Main Menu input, generated tree and ground-forage props, real viewport harvest input, smart-object lifecycle observation, chunk unload/reload, isolated save, and Continue. Player relocation is fixture-only and never performs the harvest action.",
        "launchPath": "testing scene -> production MainMenu.tscn -> visible %s button viewport input" % ("Continue" if release_stage == "continue_verify" else "New Game"),
        "usesVoxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "",
        "voxelTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "fixtureBoundary": "Generated props are never created or modified by setup. Player relocation, chunk publication, and wooden-axe grant complete before each real viewport harvest act.",
        "visualCaptures": visual_captures,
        "inputTimeline": input_timeline,
        "startupLoadingSteps": startup_loading_steps
    }
    mark_progress("start_%s" % release_stage)
    if release_stage not in ["save_and_harvest", "continue_verify"]:
        add_failure("invalid_stage", "unsupported resource lifecycle stage: %s" % release_stage)
        finish()
        return
    if bool(report_data.usesVoxelPlaytest) or String(report_data.voxelTestSeed) != "":
        add_failure("gameplay_flags_present", "VOXEL_PLAYTEST and VOXEL_TEST_SEED must be unset")
        finish()
        return
    if not await launch_release_main_via_menu_input():
        finish()
        return
    bind_scene_nodes()
    if main == null or player == null or camera == null:
        add_failure("scene_bootstrap_failed", "main/player/camera missing after startup")
        finish()
        return
    if not enable_night_safe_player_policy("vox_124_resource_lifecycle_visual"):
        finish()
        return
    report_data["seed"] = String(main.get("seed_text"))
    if release_stage == "save_and_harvest":
        await run_save_and_harvest_stage()
    else:
        await run_continue_verify_stage()
    finish()

func stage_player_beside_generated_tree() -> Dictionary:
    var existing := nearest_mature_tree(player.global_position, 120.0)
    if existing != null:
        await place_player_beside_tree(existing)
        return fixture_summary(existing)
    var candidates := wooded_surface_candidates(world_cell(player.global_position), MAX_FOREST_CANDIDATES)
    for index in range(candidates.size()):
        var cell: Vector3i = candidates[index]
        var y := float(main.call("surface_y_at_cell", cell))
        var ready := await relocate_resource_fixture_budgeted(
            Vector3(float(cell.x) * CELL, y + 0.15, float(cell.z) * CELL),
            "wooded_candidate_%d" % index
        )
        if not ready:
            continue
        for frame in range(TREE_SEARCH_FRAMES):
            var tree := nearest_mature_tree(player.global_position, 120.0)
            if tree != null:
                await place_player_beside_tree(tree)
                return fixture_summary(tree)
            await get_tree().process_frame
            if frame % 60 == 0:
                mark_progress("wooded_candidate_%d_tree_wait_%d" % [index, frame])
    return {}

func relocate_resource_fixture_budgeted(position: Vector3, label: String) -> bool:
    player.set_physics_process(false)
    var cell := world_cell(position)
    var y := float(main.call("surface_y_at_cell", cell))
    player.global_position = Vector3(position.x, y + 0.15, position.z) # resource_lifecycle_pre_act_pose_fixture
    player.velocity = Vector3.ZERO
    var stable_frames := 0
    var render_distance := int(main.get("render_distance"))
    var expected_chunks := maxi(1, (render_distance * 2 + 1) * (render_distance * 2 + 1))
    for frame in range(1800):
        main.call("update_chunks", false)
        await get_tree().process_frame
        var chunks = main.get("chunks")
        var chunk_count := (chunks as Dictionary).size() if chunks is Dictionary else 0
        var ready := chunk_count >= expected_chunks \
            and pending_main_dictionary_size("pending_chunk_loads") == 0
        stable_frames = stable_frames + 1 if ready else 0
        if stable_frames >= 12:
            player.set_physics_process(true)
            await wait_physics_frames(8)
            mark_progress("%s_ready" % label)
            return true
        if frame % 60 == 0:
            mark_progress("%s_%d_chunks_%d_of_%d" % [label, frame, chunk_count, expected_chunks])
    player.set_physics_process(true)
    mark_progress("%s_timeout" % label)
    return false

func pending_main_dictionary_size(property_name: String) -> int:
    var value = main.get(property_name) if main != null else null
    return (value as Dictionary).size() if value is Dictionary else 0

func run_save_and_harvest_stage() -> void:
    var tree_fixture := await stage_player_beside_generated_tree()
    var tree := tree_fixture.get("node") as Node3D
    if tree == null or not is_instance_valid(tree):
        add_failure("generated_tree_missing", "no real generated mature tree was published")
        return
    var tree_before := resource_summary(tree)
    var forage := await stage_generated_ground_forage(tree.global_position)
    if forage == null:
        add_failure("generated_ground_forage_missing", "bounded eligible-biome search published no real berry/aloe/mushroom/frost-herb prop")
        return
    var forage_before := resource_summary(forage)
    var tree_id := String(tree_before.get("propId", ""))
    var forage_id := String(forage_before.get("propId", ""))
    report_data["resourcesBefore"] = {"tree": tree_before, "groundForage": forage_before}
    await relocate_resource_fixture_budgeted(summary_vector3(tree_before.get("position", {})), "tree_before_capture")
    tree = find_prop_in_world(tree_id) as Node3D
    if tree == null:
        add_failure("generated_tree_missing_before_capture", tree_id)
        return
    await capture_observer_stage("tree_before_stream_rebind", observer_eye_for_tree(tree), tree.global_position + Vector3.UP * 4.0, tree_before)
    await relocate_resource_fixture_budgeted(summary_vector3(forage_before.get("position", {})), "ground_forage_before_capture")
    forage = find_prop_in_world(forage_id) as Node3D
    if forage == null:
        add_failure("generated_ground_forage_missing_before_capture", forage_id)
        return
    await capture_observer_stage("ground_forage_before_stream_rebind", forage.global_position + Vector3(7.0, 5.0, 8.0), forage.global_position + Vector3.UP * 0.7, forage_before)

    var tree_rebind := await stream_out_and_rebind_unharvested(tree_id, summary_vector3(tree_before.get("position", {})), "tree")
    var forage_rebind := await stream_out_and_rebind_unharvested(forage_id, summary_vector3(forage_before.get("position", {})), "ground_forage")
    add_checked_result("unharvested_tree_stream_rebind_remains_available", bool(tree_rebind.get("ok", false)), tree_rebind)
    add_checked_result("unharvested_ground_forage_stream_rebind_remains_available", bool(forage_rebind.get("ok", false)), forage_rebind)
    if failed:
        return

    tree = find_prop_in_world(tree_id) as Node3D
    forage = find_prop_in_world(forage_id) as Node3D
    if tree == null or forage == null:
        add_failure("rebound_resource_missing", JSON.stringify({"tree": tree_rebind, "groundForage": forage_rebind}))
        return
    var inventory = main.get("inventory_system")
    if inventory == null:
        add_failure("inventory_missing", "inventory system unavailable for pre-act tool fixture")
        return
    inventory.set_size(24)
    inventory.add_item("woodenAxe", 1)
    if not select_inventory_item(inventory, "woodenAxe"):
        add_failure("wooden_axe_fixture_failed", "could not select wooden axe before harvest acts")
        return
    var held_item = main.get("held_item")
    if held_item != null and held_item.has_method("refresh_active"):
        held_item.call("refresh_active")

    var forage_harvest := await harvest_generated_resource_with_input(forage_id, "ground_forage")
    add_checked_result("live_input_ground_forage_retires_prop_and_registration", bool(forage_harvest.get("ok", false)), forage_harvest)
    if failed:
        return
    tree = find_prop_in_world(tree_id) as Node3D
    var tree_harvest := await harvest_generated_resource_with_input(tree_id, "tree")
    add_checked_result("live_input_tree_retires_prop_and_registration", bool(tree_harvest.get("ok", false)), tree_harvest)
    if failed:
        return

    var tree_stream := await verify_removed_resource_after_stream(tree_id, summary_vector3(tree_before.get("position", {})), "tree")
    var forage_stream := await verify_removed_resource_after_stream(forage_id, summary_vector3(forage_before.get("position", {})), "ground_forage")
    add_checked_result("removed_tree_stays_retired_after_chunk_reload", bool(tree_stream.get("ok", false)), tree_stream)
    add_checked_result("removed_ground_forage_stays_retired_after_chunk_reload", bool(forage_stream.get("ok", false)), forage_stream)
    if failed:
        return
    await capture_observer_stage("resources_retired_after_chunk_reload", forage_stream.get("position", player.global_position) + Vector3(8.0, 6.0, 9.0), forage_stream.get("position", player.global_position) + Vector3.UP, {
        "tree": tree_stream,
        "groundForage": forage_stream
    })
    var saved := persist_release_save()
    add_checked_result("resource_lifecycle_save_created", saved, {"treePropId": tree_id, "groundForagePropId": forage_id})
    if not saved:
        return
    report_data["harvest"] = {
        "treePropId": tree_id,
        "groundForagePropId": forage_id,
        "treePosition": tree_before.get("position", {}),
        "groundForagePosition": forage_before.get("position", {}),
        "tree": tree_harvest,
        "groundForage": forage_harvest
    }

func run_continue_verify_stage() -> void:
    var tree_id := OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_ID").strip_edges()
    var forage_id := OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_ID").strip_edges()
    var tree_position := parse_position(OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_EXPECTED_TREE_POSITION"))
    var forage_position := parse_position(OS.get_environment("VOXEL_RESOURCE_LIFECYCLE_EXPECTED_FORAGE_POSITION"))
    if tree_id == "" or forage_id == "" or tree_position == Vector3.INF or forage_position == Vector3.INF:
        add_failure("continue_expectations_missing", "wrapper did not pass both removed IDs and positions")
        return
    var tree_check := await verify_removed_resource_after_stream(tree_id, tree_position, "continue_tree", true)
    var forage_check := await verify_removed_resource_after_stream(forage_id, forage_position, "continue_ground_forage", true)
    var removed: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var passed := bool(tree_check.get("ok", false)) \
        and bool(forage_check.get("ok", false)) \
        and bool(removed.get(tree_id, false)) \
        and bool(removed.get(forage_id, false))
    add_checked_result("continue_restores_tree_and_ground_forage_retirement", passed, {
        "tree": tree_check,
        "groundForage": forage_check,
        "treeRemovedState": bool(removed.get(tree_id, false)),
        "groundForageRemovedState": bool(removed.get(forage_id, false))
    })
    await capture_observer_stage("continue_resources_remain_retired", forage_position + Vector3(8.0, 6.0, 9.0), forage_position + Vector3.UP, {
        "tree": tree_check,
        "groundForage": forage_check
    })

func stream_out_and_rebind_unharvested(prop_id: String, position: Vector3, label: String) -> Dictionary:
    await relocate_resource_fixture_budgeted(position, "%s_initial_publication" % label)
    var before := await wait_for_prop_id(prop_id, 720)
    if before == null:
        return {"ok": false, "reason": "initial_prop_missing", "propId": prop_id}
    var far := position + Vector3(CELL * 224.0, 0.0, CELL * 224.0)
    await relocate_resource_fixture_budgeted(far, "%s_chunk_unload" % label)
    var service = smart_object_service()
    var unbound: Dictionary = service.call("object_available", "prop:%s" % prop_id, "vox124-observer") if service != null else {}
    await relocate_resource_fixture_budgeted(position, "%s_chunk_reload" % label)
    var rebound := await wait_for_prop_id(prop_id, 720)
    var available: Dictionary = service.call("object_available", "prop:%s" % prop_id, "vox124-observer") if service != null else {}
    return {
        "ok": rebound != null \
            and String(unbound.get("reason", "")) == "target_gone" \
            and bool(available.get("ok", false)) \
            and String(available.get("reason", "")) == "available",
        "propId": prop_id,
        "unboundAvailability": unbound,
        "reboundAvailability": available,
        "rebound": resource_summary(rebound)
    }

func harvest_generated_resource_with_input(prop_id: String, label: String) -> Dictionary:
    var prop := find_prop_in_world(prop_id) as Node3D
    if prop == null:
        return {"ok": false, "reason": "prop_missing_before_harvest", "propId": prop_id}
    var before := resource_summary(prop)
    await capture_observer_stage("%s_before_live_harvest" % label, prop.global_position + Vector3(7.0, 5.0, 8.0), prop.global_position + Vector3.UP, before)
    var pose := await place_player_for_resource_fixture(prop, label)
    if not bool(pose.get("ok", false)):
        return {"ok": false, "reason": "no_live_interaction_pose", "propId": prop_id, "pose": pose}
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var clicks := 0
    while prop != null and is_instance_valid(prop) and clicks < 12:
        var hit := await aim_until_resource_hit(prop_id)
        if not bool(hit.get("matches", false)):
            return {"ok": false, "reason": "raycast_miss", "propId": prop_id, "clicks": clicks, "hit": hit}
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, true, "%s_harvest_%02d_press" % [label, clicks])
        await wait_physics_frames(1)
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, false, "%s_harvest_%02d_release" % [label, clicks])
        clicks += 1
        await wait_physics_frames(5)
    await wait_physics_frames(8)
    var service = smart_object_service()
    var debug: Dictionary = service.call("reservation_debug", "prop:%s" % prop_id, "") if service != null else {}
    var available: Dictionary = service.call("object_available", "prop:%s" % prop_id, "vox124-observer") if service != null else {}
    var removed: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var reservations: Array = debug.get("reservations", []) if debug.get("reservations", []) is Array else []
    return {
        "ok": find_prop_in_world(prop_id) == null \
            and bool(removed.get(prop_id, false)) \
            and bool(debug.get("depleted", false)) \
            and reservations.is_empty() \
            and String(available.get("reason", "")) == "resource_depleted",
        "propId": prop_id,
        "clicks": clicks,
        "before": before,
        "pose": pose,
        "registration": debug,
        "availability": available,
        "removedState": bool(removed.get(prop_id, false)),
        "livePropPresent": find_prop_in_world(prop_id) != null
    }

func place_player_for_resource_fixture(prop: Node3D, label: String) -> Dictionary:
    for index in range(RESOURCE_INTERACTION_OFFSETS.size()):
        var offset: Vector3 = RESOURCE_INTERACTION_OFFSETS[index]
        await relocate_resource_fixture_budgeted(prop.global_position + offset, "%s_pre_act_pose_%02d" % [label, index])
        var hit := await aim_until_resource_hit(String(prop.get_meta("prop_id", "")))
        if bool(hit.get("matches", false)):
            return {"ok": true, "offsetIndex": index, "playerPosition": vec3(player.global_position), "hit": hit}
    return {"ok": false, "playerPosition": vec3(player.global_position)}

func aim_until_resource_hit(prop_id: String) -> Dictionary:
    var prop := find_prop_in_world(prop_id) as Node3D
    if prop == null:
        return {"matches": false, "reason": "prop_missing"}
    var last := {}
    for height in [0.32, 0.65, 1.0, 1.6, 2.2]:
        aim_at(prop.global_position + Vector3.UP * float(height))
        await wait_physics_frames(3)
        var hit: Dictionary = player.call("view_ray", 3.8)
        var collider := hit.get("collider") as Node
        var hit_prop_id := String(collider.get_meta("prop_id", "")) if collider != null else ""
        last = {
            "matches": hit_prop_id == prop_id,
            "propId": prop_id,
            "hitPropId": hit_prop_id,
            "collider": String(collider.name) if collider != null else "",
            "distance": camera.global_position.distance_to(hit.get("position", camera.global_position)) if not hit.is_empty() else -1.0
        }
        if bool(last.get("matches", false)):
            return last
    return last

func verify_removed_resource_after_stream(prop_id: String, position: Vector3, label: String, allow_unregistered := false) -> Dictionary:
    var far := position + Vector3(CELL * 224.0, 0.0, CELL * 224.0)
    await relocate_resource_fixture_budgeted(far, "%s_removed_chunk_unload" % label)
    await relocate_resource_fixture_budgeted(position, "%s_removed_chunk_reload" % label)
    var service = smart_object_service()
    var available: Dictionary = service.call("object_available", "prop:%s" % prop_id, "vox124-observer") if service != null else {}
    var registration: Dictionary = service.call("reservation_debug", "prop:%s" % prop_id, "") if service != null else {}
    var reservations: Array = registration.get("reservations", []) if registration.get("reservations", []) is Array else []
    var removed: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var availability_reason := String(available.get("reason", ""))
    var availability_retired := availability_reason == "resource_depleted" \
        or (allow_unregistered and availability_reason == "target_gone")
    return {
        "ok": find_prop_in_world(prop_id) == null \
            and bool(removed.get(prop_id, false)) \
            and availability_retired \
            and reservations.is_empty(),
        "propId": prop_id,
        "position": position,
        "livePropPresent": find_prop_in_world(prop_id) != null,
        "removedState": bool(removed.get(prop_id, false)),
        "availability": available,
        "registration": registration,
        "acceptedAvailabilityReasons": ["resource_depleted", "target_gone"] if allow_unregistered else ["resource_depleted"]
    }

func nearest_ground_forage(origin: Vector3, maximum_distance: float) -> Node3D:
    var candidates: Array[Node3D] = []
    collect_ground_forage(main, candidates)
    var best: Node3D = null
    var best_distance := maximum_distance
    for candidate in candidates:
        var distance := Vector2(candidate.global_position.x - origin.x, candidate.global_position.z - origin.z).length()
        if distance < best_distance:
            best = candidate
            best_distance = distance
    return best

func stage_generated_ground_forage(origin: Vector3) -> Node3D:
    var existing := nearest_ground_forage(origin, 180.0)
    if existing != null:
        return existing
    var origin_cell := world_cell(origin)
    var candidates: Array[Vector3i] = []
    var seen_biomes := {}
    for radius in range(56, 720, 28):
        for direction_index in range(24):
            var angle := TAU * float(direction_index) / 24.0
            var cell := Vector3i(
                origin_cell.x + roundi(cos(angle) * float(radius)),
                0,
                origin_cell.z + roundi(sin(angle) * float(radius))
            )
            var biome := String(main.call("surface_biome_at_cell", cell))
            if biome not in ["forest", "desert", "swamp", "taiga"]:
                continue
            var key := "%s:%d,%d" % [biome, cell.x, cell.z]
            if seen_biomes.has(key):
                continue
            seen_biomes[key] = true
            candidates.append(cell)
            if candidates.size() >= 12:
                break
        if candidates.size() >= 12:
            break
    for index in range(candidates.size()):
        var cell: Vector3i = candidates[index]
        var y := float(main.call("surface_y_at_cell", cell))
        var position := Vector3(float(cell.x) * CELL, y + 0.15, float(cell.z) * CELL)
        await relocate_resource_fixture_budgeted(position, "ground_forage_candidate_%02d" % index)
        for frame in range(720):
            var forage := nearest_ground_forage(player.global_position, 135.0)
            if forage != null:
                report_data["groundForageSearch"] = {
                    "candidateIndex": index,
                    "candidateCell": {"x": cell.x, "z": cell.z},
                    "candidateBiome": String(main.call("surface_biome_at_cell", cell)),
                    "resource": resource_summary(forage)
                }
                return forage
            await get_tree().process_frame
            if frame % 120 == 0:
                mark_progress("ground_forage_candidate_%02d_wait_%d" % [index, frame])
    report_data["groundForageSearch"] = {"candidateCount": candidates.size(), "found": false}
    return null

func collect_ground_forage(node: Node, output: Array[Node3D]) -> void:
    if node == null:
        return
    if node is Node3D \
        and String(node.get_meta("kind", "")) == "prop" \
        and String(node.get_meta("material", "")) in GROUND_FORAGE_MATERIALS:
        output.append(node as Node3D)
    for child in node.get_children():
        collect_ground_forage(child, output)

func wait_for_prop_id(prop_id: String, maximum_frames: int) -> Node3D:
    for frame in range(maximum_frames):
        var prop := find_prop_in_world(prop_id) as Node3D
        if prop != null:
            return prop
        await get_tree().process_frame
        if frame % 120 == 0:
            mark_progress("waiting_for_prop_%s_%d" % [prop_id, frame])
    return null

func resource_summary(prop: Node3D) -> Dictionary:
    if prop == null or not is_instance_valid(prop):
        return {}
    return {
        "propId": String(prop.get_meta("prop_id", "")),
        "material": String(prop.get_meta("material", "")),
        "drop": String(prop.get_meta("drop", "")),
        "position": vec3(prop.global_position)
    }

func smart_object_service():
    var npc_system = main.get("npc_system") if main != null else null
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    return autonomy.get("smart_objects") if autonomy != null else null

func add_checked_result(name: String, passed: bool, details: Dictionary) -> void:
    results.append({"name": name, "passed": passed, "details": JSON.stringify(details)})
    if not passed:
        add_failure(name, JSON.stringify(details))

func summary_vector3(value) -> Vector3:
    if value is Vector3:
        return value
    if value is Dictionary:
        return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)), float(value.get("z", 0.0)))
    if value is Array and value.size() >= 3:
        return Vector3(float(value[0]), float(value[1]), float(value[2]))
    return Vector3.INF

func parse_position(value: String) -> Vector3:
    var parts := value.split(",")
    if parts.size() != 3:
        return Vector3.INF
    return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
