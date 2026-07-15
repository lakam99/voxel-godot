extends "res://scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd"

const STAGE_SAVE_AND_HARVEST := "save_and_harvest"
const STAGE_CONTINUE_VERIFY := "continue_verify"
const WOODED_BIOMES := ["forest", "taiga"]
const MAX_FOREST_CANDIDATES := 8
const TREE_SEARCH_FRAMES := 420
const MIN_DENSE_FOREST_TREE_COUNT := 12

var release_stage := ""

func configure_paths() -> void:
    report_path = OS.get_environment("VOXEL_CANOPY_RELEASE_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/canopy-release-playtest.json")
    progress_path = OS.get_environment("VOXEL_CANOPY_RELEASE_PROGRESS").strip_edges()
    if progress_path == "":
        progress_path = ProjectSettings.globalize_path("res://artifacts/vegetation/canopy-release-playtest-progress.txt")
    screenshot_dir = OS.get_environment("VOXEL_CANOPY_RELEASE_SCREENSHOT_DIR").strip_edges()
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vegetation/canopy-release-screenshots")
    ensure_dir(report_path.get_base_dir())
    ensure_dir(progress_path.get_base_dir())
    ensure_dir(screenshot_dir)

func watchdog_seconds() -> float:
    var text := OS.get_environment("VOXEL_CANOPY_RELEASE_WATCHDOG_SECONDS").strip_edges()
    return maxf(60.0, float(text)) if text != "" else 360.0

func run() -> void:
    release_stage = OS.get_environment("VOXEL_CANOPY_RELEASE_STAGE").strip_edges().to_lower()
    report_data = {
        "schemaVersion": 1,
        "runnerId": "canopy_release_playtest",
        "testId": "vox_123_canopy_harvest_save_continue",
        "runToken": OS.get_environment("VOXEL_CANOPY_RELEASE_RUN_TOKEN"),
        "stage": release_stage,
        "finished": false,
        "passed": false,
        "failureCount": 0,
        "resultCount": 0,
        "evidenceLevel": "acceptance_visual",
        "acceptanceClaims": [
            "main_menu_forest_save_continue",
            "live_tree_break_fall_drop_and_removed_prop_persistence"
        ],
        "scope": "Headed production Main Menu input, generated wooded-biome chunk publication, fixture-only pre-act player/tool placement, real viewport mouse harvest input, falling-tree/drop observation, chunk unload/reload, isolated save, and Continue restoration. No NPC/pathfinding acceptance claim.",
        "launchPath": "testing scene -> production MainMenu.tscn -> visible %s button viewport input" % ("Continue" if release_stage == STAGE_CONTINUE_VERIFY else "New Game"),
        "usesVoxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "",
        "voxelTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "fixtureBoundary": "Player relocation and wooden-axe grant finish before the harvest act. Harvest itself uses real viewport mouse input and production targeting/break/reward code.",
        "visualCaptures": visual_captures,
        "inputTimeline": input_timeline,
        "startupLoadingSteps": startup_loading_steps
    }
    mark_progress("start_%s" % release_stage)
    if release_stage not in [STAGE_SAVE_AND_HARVEST, STAGE_CONTINUE_VERIFY]:
        add_failure("invalid_stage", "unsupported canopy release stage: %s" % release_stage)
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
    report_data["seed"] = String(main.get("seed_text"))
    if release_stage == STAGE_SAVE_AND_HARVEST:
        await run_save_and_harvest_stage()
    else:
        await run_continue_verify_stage()
    finish()

func launch_release_main_via_menu_input() -> bool:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    menu = MENU_SCENE.instantiate()
    if menu == null:
        add_failure("main_menu_bootstrap_failed", "MainMenu.tscn could not be instantiated")
        return false
    add_child(menu)
    await wait_process_frames(4)
    var button_name := "continue_button" if release_stage == STAGE_CONTINUE_VERIFY else "new_game_button"
    var button := menu.get(button_name) as Button
    if button == null or not is_instance_valid(button) or button.disabled or not button.visible:
        add_failure("menu_button_unavailable", "%s was missing, disabled, or hidden" % button_name)
        return false
    await capture_stage("menu_before_%s" % release_stage, {"button": control_summary(button)})
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, true, "%s_press" % button_name)
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, false, "%s_release" % button_name)
    mark_progress("menu_input_%s" % button_name)
    var max_frames := ceili(180.0 * float(Engine.physics_ticks_per_second))
    for frame in range(max_frames):
        await get_tree().process_frame
        var active_value = menu.get("active_main") if menu != null else null
        if active_value is Node3D:
            main = active_value
            connect_main_loading_diagnostics()
        if main != null and is_instance_valid(main):
            var failure = main.get("startup_loading_failure_result")
            if failure is Dictionary and not failure.is_empty():
                add_failure("startup_loading_failed", JSON.stringify(failure))
                return false
            if not bool(main.get("startup_loading_active")):
                report_data["mainMenuLaunch"] = {
                    "clickedViaViewportInput": true,
                    "mode": "continue" if release_stage == STAGE_CONTINUE_VERIFY else "new_game",
                    "frames": frame,
                    "startupReadiness": (main.get("startup_readiness_domains") as Dictionary).duplicate(true) if main.get("startup_readiness_domains") is Dictionary else {}
                }
                mark_progress("main_loaded_%s" % release_stage)
                return true
        if frame % 60 == 0:
            mark_progress("waiting_main_%s_%d" % [release_stage, frame])
    add_failure("main_menu_launch_timeout", "menu input did not produce a loaded Main scene")
    return false

func run_save_and_harvest_stage() -> void:
    var fixture := await stage_player_beside_generated_tree()
    if fixture.is_empty():
        add_failure("generated_wooded_tree_missing", "no real mature tree published after bounded wooded-biome search")
        return
    var tree := fixture.get("node") as Node3D
    fixture.erase("node")
    report_data["canopyFixture"] = fixture
    var tree_summary_before := summarize_tree(tree)
    report_data["treeBefore"] = tree_summary_before
    await capture_observer_stage("generated_tree_before_harvest", observer_eye_for_tree(tree), tree.global_position + Vector3.UP * 5.0, {
        "tree": tree_summary_before,
        "nearbyMatureTreeCount": count_mature_trees_near(tree.global_position, 72.0)
    })
    var inventory = main.get("inventory_system")
    if inventory == null:
        add_failure("inventory_missing", "inventory system unavailable for fixture tool grant")
        return
    inventory.set_size(24)
    inventory.add_item("woodenAxe", 1)
    if not select_inventory_item(inventory, "woodenAxe"):
        add_failure("wooden_axe_fixture_failed", "could not select wooden axe before act phase")
        return
    var held_item = main.get("held_item")
    if held_item != null and held_item.has_method("refresh_active"):
        held_item.call("refresh_active")
    var prop_id := String(tree.get_meta("prop_id", ""))
    var logs_before := int(inventory.count("logs"))
    var target_point := tree.global_position + Vector3.UP * clampf(float(tree.get_meta("tree_visual_height", 8.0)) * 0.16, 1.2, 2.2)
    aim_at(target_point)
    await wait_physics_frames(4)
    var initial_hit: Dictionary = player.call("view_ray", 3.6)
    var initial_collider := initial_hit.get("collider") as Node
    var hit_prop_id := String(initial_collider.get_meta("prop_id", "")) if initial_collider != null else ""
    var target_hit := initial_collider is Node3D \
        and hit_prop_id == prop_id \
        and String(initial_collider.get_meta("material", "")) == "tree"
    results.append({"name": "live_tree_targeting_hits_coherent_trunk", "passed": target_hit, "details": JSON.stringify({
        "propId": prop_id,
        "hitPropId": hit_prop_id,
        "collider": String(initial_collider.name) if initial_collider != null else "",
        "distance": camera.global_position.distance_to(initial_hit.get("position", camera.global_position)) if not initial_hit.is_empty() else -1.0
    })})
    if not target_hit:
        add_failure("tree_targeting_missed", JSON.stringify(tree_summary_before))
        return
    tree = initial_collider as Node3D
    target_point = tree.global_position + Vector3.UP * clampf(float(tree.get_meta("tree_visual_height", 8.0)) * 0.16, 1.2, 2.2)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var clicks := 0
    while is_instance_valid(tree) and clicks < 8:
        aim_at(target_point)
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, true, "tree_harvest_%d_press" % clicks)
        await wait_physics_frames(1)
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, false, "tree_harvest_%d_release" % clicks)
        clicks += 1
        await wait_physics_frames(4)
    var falling := find_named_in_world("FallingTree") as Node3D
    var removed_after_input := not is_instance_valid(tree)
    var falling_seen := falling != null and is_instance_valid(falling)
    if falling_seen:
        await capture_observer_stage("tree_falling_after_live_input", observer_eye_for_tree(falling), falling.global_position + Vector3.UP * 4.0, {
            "propId": prop_id,
            "clicks": clicks
        })
    for _frame in range(90):
        if int(inventory.count("logs")) > logs_before:
            break
        await get_tree().physics_frame
    var logs_after := int(inventory.count("logs"))
    var removed_state: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var destroy_metrics: Dictionary = main.get("last_destroy_target_metrics") if main.get("last_destroy_target_metrics") is Dictionary else {}
    var harvest_passed := removed_after_input and falling_seen and logs_after > logs_before and bool(removed_state.get(prop_id, false))
    results.append({"name": "live_input_tree_break_fall_drop_and_budgeted_completion", "passed": harvest_passed, "details": JSON.stringify({
        "propId": prop_id,
        "clicks": clicks,
        "fallingSeen": falling_seen,
        "logsBefore": logs_before,
        "logsAfter": logs_after,
        "removedState": bool(removed_state.get(prop_id, false)),
        "destroyMetrics": destroy_metrics
    })})
    if not harvest_passed:
        add_failure("live_tree_harvest_failed", JSON.stringify(results.back()))
        return
    var near_position := player.global_position
    await relocate_for_chunk_fixture(near_position + Vector3(CELL * 192.0, 0.0, CELL * 192.0), "chunk_unload")
    await relocate_for_chunk_fixture(near_position, "chunk_reload")
    var respawned := find_prop_in_world(prop_id) != null
    results.append({"name": "removed_tree_stays_removed_after_chunk_unload_reload", "passed": not respawned, "details": JSON.stringify({"propId": prop_id, "respawned": respawned})})
    if respawned:
        add_failure("removed_tree_respawned_after_chunk_reload", prop_id)
        return
    await capture_observer_stage("forest_after_chunk_reload", near_position + Vector3(12.0, 8.0, 14.0), near_position + Vector3.UP * 4.0, {
        "removedPropId": prop_id,
        "nearbyMatureTreeCount": count_mature_trees_near(near_position, 72.0)
    })
    var saved := persist_release_save()
    results.append({"name": "forest_harvest_save_created", "passed": saved, "details": JSON.stringify({"propId": prop_id, "seed": String(main.get("seed_text"))})})
    if not saved:
        add_failure("forest_save_failed", "save authority rejected post-harvest snapshot")
        return
    report_data["harvest"] = {
        "propId": prop_id,
        "logsBefore": logs_before,
        "logsAfter": logs_after,
        "clicks": clicks,
        "fallingSeen": falling_seen,
        "destroyMetrics": destroy_metrics,
        "savePlayerPosition": vec3(player.global_position),
        "saveBiome": String(main.call("surface_biome_at_cell", world_cell(player.global_position)))
    }

func run_continue_verify_stage() -> void:
    var expected_prop_id := OS.get_environment("VOXEL_CANOPY_EXPECTED_REMOVED_PROP_ID").strip_edges()
    if expected_prop_id == "":
        add_failure("expected_removed_prop_missing", "wrapper did not pass the harvested prop ID")
        return
    var biome := String(main.call("surface_biome_at_cell", world_cell(player.global_position)))
    for _frame in range(TREE_SEARCH_FRAMES):
        if count_mature_trees_near(player.global_position, 96.0) >= MIN_DENSE_FOREST_TREE_COUNT:
            break
        await get_tree().process_frame
    var nearby_count := count_mature_trees_near(player.global_position, 96.0)
    var removed_state: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var respawned := find_prop_in_world(expected_prop_id) != null
    var passed := biome in WOODED_BIOMES \
        and nearby_count >= MIN_DENSE_FOREST_TREE_COUNT \
        and bool(removed_state.get(expected_prop_id, false)) \
        and not respawned
    results.append({"name": "continue_restores_dense_forest_pose_and_removed_tree", "passed": passed, "details": JSON.stringify({
        "biome": biome,
        "nearbyMatureTreeCount": nearby_count,
        "minimumDenseForestTreeCount": MIN_DENSE_FOREST_TREE_COUNT,
        "removedPropId": expected_prop_id,
        "removedState": bool(removed_state.get(expected_prop_id, false)),
        "respawned": respawned,
        "playerPosition": vec3(player.global_position)
    })})
    await capture_observer_stage("continue_dense_forest_removed_tree_persisted", player.global_position + Vector3(12.0, 8.0, 14.0), player.global_position + Vector3.UP * 4.0, {
        "biome": biome,
        "nearbyMatureTreeCount": nearby_count,
        "minimumDenseForestTreeCount": MIN_DENSE_FOREST_TREE_COUNT,
        "removedPropId": expected_prop_id,
        "removedState": bool(removed_state.get(expected_prop_id, false)),
        "respawned": respawned
    })
    report_data["continueVerification"] = results.back()
    if not passed:
        add_failure("continue_forest_removal_persistence_failed", JSON.stringify(results.back()))

func stage_player_beside_generated_tree() -> Dictionary:
    var existing := nearest_mature_tree(player.global_position, 120.0)
    if existing != null:
        await place_player_beside_tree(existing)
        return fixture_summary(existing)
    var candidates := wooded_surface_candidates(world_cell(player.global_position), MAX_FOREST_CANDIDATES)
    for index in range(candidates.size()):
        var cell: Vector3i = candidates[index]
        var y := float(main.call("surface_y_at_cell", cell))
        await relocate_for_chunk_fixture(Vector3(float(cell.x) * CELL, y + 0.15, float(cell.z) * CELL), "wooded_candidate_%d" % index)
        for _frame in range(TREE_SEARCH_FRAMES):
            var tree := nearest_mature_tree(player.global_position, 120.0)
            if tree != null:
                await place_player_beside_tree(tree)
                return fixture_summary(tree)
            await get_tree().process_frame
    return {}

func place_player_beside_tree(tree: Node3D) -> void:
    var offset := Vector3(0.0, 0.0, 2.55)
    var target_cell := world_cell(tree.global_position + offset)
    var y := float(main.call("surface_y_at_cell", target_cell))
    player.set_physics_process(false)
    player.global_position = Vector3(tree.global_position.x + offset.x, y + 0.15, tree.global_position.z + offset.z)
    player.velocity = Vector3.ZERO
    player.set_physics_process(true)
    await wait_physics_frames(8)
    aim_at(tree.global_position + Vector3.UP * 1.7)
    await wait_physics_frames(3)

func relocate_for_chunk_fixture(position: Vector3, label: String) -> void:
    player.set_physics_process(false)
    var cell := world_cell(position)
    var y := float(main.call("surface_y_at_cell", cell))
    player.global_position = Vector3(position.x, y + 0.15, position.z)
    player.velocity = Vector3.ZERO
    if main.has_method("update_chunks"):
        main.call("update_chunks", true)
    for frame in range(180):
        await get_tree().process_frame
        if frame % 60 == 0:
            mark_progress("%s_%d" % [label, frame])
    player.set_physics_process(true)
    await wait_physics_frames(8)

func wooded_surface_candidates(origin: Vector3i, limit: int) -> Array[Vector3i]:
    var candidates: Array[Vector3i] = []
    for radius in range(36, 520, 20):
        for direction_index in range(24):
            var angle := TAU * float(direction_index) / 24.0
            var cell := Vector3i(origin.x + roundi(cos(angle) * float(radius)), 0, origin.z + roundi(sin(angle) * float(radius)))
            if String(main.call("surface_biome_at_cell", cell)) in WOODED_BIOMES:
                candidates.append(cell)
                if candidates.size() >= limit:
                    return candidates
    return candidates

func nearest_mature_tree(origin: Vector3, maximum_distance: float) -> Node3D:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var best: Node3D = null
    var best_distance := maximum_distance
    for tree in all:
        var distance := Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length()
        if distance < best_distance:
            best = tree
            best_distance = distance
    return best

func count_mature_trees_near(origin: Vector3, maximum_distance: float) -> int:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var count := 0
    for tree in all:
        if Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length() <= maximum_distance:
            count += 1
    return count

func collect_world_mature_trees(output: Array[Node3D]) -> void:
    collect_mature_trees(main.get("chunk_root") as Node, output)
    collect_mature_trees(main.get("prop_root") as Node, output)

func collect_mature_trees(node: Node, output: Array[Node3D]) -> void:
    if node == null:
        return
    if node is Node3D and String(node.get_meta("kind", "")) == "prop" and String(node.get_meta("material", "")) == "tree":
        var family := String(node.get_meta("tree_family", ""))
        if family.begins_with("mature_") or family.begins_with("old_growth_"):
            output.append(node as Node3D)
    for child in node.get_children():
        collect_mature_trees(child, output)

func find_prop_id_recursive(node: Node, prop_id: String) -> Node:
    if node == null:
        return null
    if String(node.get_meta("prop_id", "")) == prop_id:
        return node
    for child in node.get_children():
        var found := find_prop_id_recursive(child, prop_id)
        if found != null:
            return found
    return null

func find_prop_in_world(prop_id: String) -> Node:
    var found := find_prop_id_recursive(main.get("chunk_root") as Node, prop_id)
    if found != null:
        return found
    return find_prop_id_recursive(main.get("prop_root") as Node, prop_id)

func find_named_recursive(node: Node, node_name: String) -> Node:
    if node == null:
        return null
    if String(node.name) == node_name:
        return node
    for child in node.get_children():
        var found := find_named_recursive(child, node_name)
        if found != null:
            return found
    return null

func find_named_in_world(node_name: String) -> Node:
    var found := find_named_recursive(main.get("chunk_root") as Node, node_name)
    if found != null:
        return found
    return find_named_recursive(main.get("prop_root") as Node, node_name)

func fixture_summary(tree: Node3D) -> Dictionary:
    var summary := summarize_tree(tree)
    summary["node"] = tree
    summary["biome"] = String(main.call("surface_biome_at_cell", world_cell(tree.global_position)))
    summary["playerPosition"] = vec3(player.global_position)
    summary["nearbyMatureTreeCount"] = count_mature_trees_near(tree.global_position, 72.0)
    return summary

func summarize_tree(tree: Node3D) -> Dictionary:
    if tree == null or not is_instance_valid(tree):
        return {}
    return {
        "propId": String(tree.get_meta("prop_id", "")),
        "assetId": String(tree.get_meta("visual_asset_id", "")),
        "family": String(tree.get_meta("tree_family", "")),
        "visualHeight": float(tree.get_meta("tree_visual_height", 0.0)),
        "trunkRadius": float(tree.get_meta("tree_trunk_radius", 0.0)),
        "position": vec3(tree.global_position)
    }

func observer_eye_for_tree(tree: Node3D) -> Vector3:
    return tree.global_position + Vector3(12.0, clampf(float(tree.get_meta("tree_visual_height", 12.0)) * 0.64, 7.0, 12.0), 14.0)

func select_inventory_item(inventory, item_id: String) -> bool:
    var slots: Array = inventory.slots if inventory.get("slots") is Array else []
    var slot := -1
    for index in range(slots.size()):
        if slots[index] is Dictionary and String((slots[index] as Dictionary).get("item", "")) == item_id:
            slot = index
            break
    if slot < 0:
        return false
    inventory.select(0)
    if slot != 0:
        inventory.swap_with_active(slot)
    return true

func persist_release_save() -> bool:
    if main == null or main.get("save_system") == null or not main.has_method("create_save_snapshot"):
        return false
    var snapshot: Dictionary = main.call("create_save_snapshot")
    return bool(main.get("save_system").call("save", String(main.get("seed_text")), snapshot))

func world_cell(position: Vector3) -> Vector3i:
    return Vector3i(roundi(position.x / CELL), 0, roundi(position.z / CELL))
