extends "res://scripts/testing/npc/NpcActualGameplayMiraPorchRegressionRunner.gd"

const PlaytestSearchLoadingControllerScript := preload("res://scripts/testing/PlaytestSearchLoadingController.gd")
const TreeEcologySamplerScript := preload("res://scripts/environment/TreeEcologySampler.gd")
const STAGE_SAVE_AND_HARVEST := "save_and_harvest"
const STAGE_CONTINUE_VERIFY := "continue_verify"
const DEFAULT_WOODED_BIOMES: Array[String] = ["forest", "taiga"]
const MAX_FOREST_CANDIDATES := 8
const TREE_SEARCH_FRAMES := 420
const CONTINUE_TREE_PUBLICATION_FRAMES := 1200
const MIN_RENDERED_FOREST_TREE_COUNT := 12
const MIN_UPPER_AGE_FOREST_TREE_COUNT := 6
# The harvest fixture removes one of the upper-age trees it will later count.
# Select a genuinely dense location up front so Continue still proves the same
# post-harvest forest population instead of making the release result depend on
# whether the first monumental candidate happened to be a sparse edge tree.
const MIN_SELECTABLE_UPPER_AGE_TREE_COUNT := MIN_UPPER_AGE_FOREST_TREE_COUNT + 1
const FIXTURE_NEAR_LOD_FRAMES := 720

var release_stage := ""
var search_loading_controller
var target_biome := ""
var target_architecture := ""
var required_age_band := ""
var generic_interaction_matrix := false
var fixture_ecology_sampler

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

func configure_fixture_selection() -> void:
    target_biome = OS.get_environment("VOXEL_CANOPY_RELEASE_TARGET_BIOME").strip_edges().to_lower()
    target_architecture = OS.get_environment("VOXEL_CANOPY_RELEASE_TARGET_ARCHITECTURE").strip_edges().to_lower()
    required_age_band = OS.get_environment("VOXEL_CANOPY_RELEASE_REQUIRED_AGE_BAND").strip_edges().to_lower()
    generic_interaction_matrix = target_biome != "" or target_architecture != "" or required_age_band != ""

func fixture_selection_is_valid() -> bool:
    if not generic_interaction_matrix:
        return true
    var valid := target_biome in ["forest", "taiga", "savanna"] \
        and target_architecture in ["broadleaf", "conifer", "savanna"] \
        and required_age_band in ["mature", "old", "ancient"]
    if not valid:
        add_failure("invalid_tree_interaction_matrix_selection", JSON.stringify(fixture_selection_summary()))
    return valid

func fixture_selection_summary() -> Dictionary:
    return {
        "mode": "family_age_interaction_matrix" if generic_interaction_matrix else "legacy_monumental_dense_forest",
        "targetBiome": target_biome,
        "targetArchitecture": target_architecture,
        "requiredAgeBand": required_age_band,
        "targetBiomes": selected_biomes(),
        "requiresDenseForest": not generic_interaction_matrix,
        "minimumVisualHeight": 8.0 if generic_interaction_matrix else 55.0,
        "minimumTrunkDiameter": 0.36 if generic_interaction_matrix else 7.0,
    }

func selected_biomes() -> Array[String]:
    var selected: Array[String] = []
    if target_biome != "":
        selected.append(target_biome)
        return selected
    selected.assign(DEFAULT_WOODED_BIOMES)
    return selected

func biome_is_selected(biome: String) -> bool:
    return biome.to_lower() in selected_biomes()

func has_required_fixture_dimensions(tree: Node3D) -> bool:
    if tree == null or not is_instance_valid(tree):
        return false
    var height := float(tree.get_meta("tree_visual_height", 0.0))
    var diameter := float(tree.get_meta("tree_trunk_radius", 0.0)) * 2.0
    if generic_interaction_matrix:
        return height >= 8.0 and diameter >= 0.36
    return height >= 55.0 and diameter >= 7.0

func tree_matches_fixture_selection(tree: Node3D, require_published := false) -> bool:
    if tree == null or not is_instance_valid(tree):
        return false
    if String(tree.get_meta("kind", "")) != "prop" or String(tree.get_meta("material", "")) != "tree":
        return false
    var biome := String(main.call("surface_biome_at_cell", world_cell(tree.global_position))) if main != null else ""
    if not biome_is_selected(biome):
        return false
    if target_architecture != "" and String(tree.get_meta("tree_architecture", "")) != target_architecture:
        return false
    if required_age_band != "" and String(tree.get_meta("tree_age_band", "")) != required_age_band:
        return false
    if not has_required_fixture_dimensions(tree):
        return false
    if require_published:
        return String(tree.get_meta("tree_visual_state", "")) == "published" \
            and String(tree.get_meta("visual_source", "")) == "procedural_tree_recipe" \
            and String(tree.get_meta("tree_recipe_signature", "")) != ""
    return true

func continue_population_ready(origin: Vector3) -> bool:
    if generic_interaction_matrix:
        # Continue must restore a real published world before the removed-prop
        # assertion. The exact selected tree must remain absent, so another
        # nearby published procedural trunk is the correct non-respawn witness.
        return count_published_trees_near(origin, 96.0) >= 1
    return count_published_trees_near(origin, 96.0) >= MIN_RENDERED_FOREST_TREE_COUNT \
        and count_mature_trees_near(origin, 96.0) >= MIN_UPPER_AGE_FOREST_TREE_COUNT

func run() -> void:
    release_stage = OS.get_environment("VOXEL_CANOPY_RELEASE_STAGE").strip_edges().to_lower()
    configure_fixture_selection()
    var acceptance_claims := [
        "main_menu_forest_save_continue",
        "live_tree_break_fall_drop_and_removed_prop_persistence",
        "live_wooded_world_screen_filling_upper_age_trunk"
    ]
    if generic_interaction_matrix:
        acceptance_claims = [
            "main_menu_family_age_save_continue",
            "live_tree_break_fall_drop_and_removed_prop_persistence",
            "selected_natural_tree_is_published_procedural_family_age"
        ]
    report_data = {
        "schemaVersion": 1,
        "runnerId": "canopy_release_playtest",
        "testId": "vox_136_family_age_tree_harvest_save_continue" if generic_interaction_matrix else "vox_131_monumental_canopy_harvest_save_continue",
        "runToken": OS.get_environment("VOXEL_CANOPY_RELEASE_RUN_TOKEN"),
        "stage": release_stage,
        "finished": false,
        "passed": false,
        "failureCount": 0,
        "resultCount": 0,
        "evidenceLevel": "acceptance_visual",
        "acceptanceClaims": acceptance_claims,
        "scope": "Headed production Main Menu input, generated wooded-biome chunk publication, fixture-only pre-act player/tool placement, real viewport mouse harvest input, falling-tree/drop observation, chunk unload/reload, isolated save, and Continue restoration. No NPC/pathfinding acceptance claim.",
        "launchPath": "testing scene -> production MainMenu.tscn -> visible %s button viewport input" % ("Continue" if release_stage == STAGE_CONTINUE_VERIFY else "New Game"),
        "usesVoxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "",
        "voxelTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "fixtureBoundary": "Player relocation and wooden-axe grant finish before the harvest act. Harvest itself uses real viewport mouse input and production targeting/break/reward code.",
        "fixtureSelection": fixture_selection_summary(),
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
    if not fixture_selection_is_valid():
        finish()
        return
    mark_progress("canopy_post_startup_scene_bound")
    if not enable_night_safe_player_policy("canopy_release_visual"):
        finish()
        return
    main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
    report_data["visualTimePolicy"] = "13:00 daylight; godmode remains enabled so this runner is also safe if time advances into night"
    mark_progress("canopy_daylight_policy_ready")
    await wait_process_frames(8)
    mark_progress("canopy_pre_fixture")
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
    mark_progress("tree_fixture_begin")
    var fixture := await stage_player_beside_generated_tree()
    if fixture.is_empty():
        # Keep failed headed searches diagnostic. This reports the live collision
        # bodies and queue state without changing the production setup or
        # weakening the requirement for a published mature canopy.
        add_failure("generated_wooded_tree_missing", JSON.stringify(tree_publication_search_diagnostic()))
        return
    await force_canopy_capture_daylight("pre_harvest")
    var tree := fixture.get("node") as Node3D
    fixture.erase("node")
    report_data["canopyFixture"] = fixture
    var tree_summary_before := summarize_tree(tree)
    report_data["treeBefore"] = tree_summary_before
    var fixture_dimensions_pass := has_required_fixture_dimensions(tree)
    var fixture_result_name := "live_procedural_tree_matches_requested_family_age" if generic_interaction_matrix else "live_wooded_world_publishes_screen_filling_upper_age_trunk"
    results.append({"name": fixture_result_name, "passed": fixture_dimensions_pass, "details": JSON.stringify({"tree": tree_summary_before, "selection": fixture_selection_summary()})})
    await capture_stage("generated_tree_trunk_player_pov", {"tree": tree_summary_before, "fixtureDimensionsPass": fixture_dimensions_pass, "selection": fixture_selection_summary()})
    # A saved PNG alone is not visual evidence. The first production capture was
    # technically present while the player camera was grazing the continuous
    # bole, producing a nearly black frame. Keep the true player POV but require
    # that its daylight image contains readable scene detail.
    var trunk_pov_luminance := current_viewport_sample_luminance()
    results.append({"name": "live_trunk_player_pov_is_daylight_readable", "passed": trunk_pov_luminance >= 0.100, "details": JSON.stringify({
        "averageLuminance": trunk_pov_luminance,
        "minimum": 0.100,
        "cameraPosition": vec3(camera.global_position) if camera != null else []
    })})
    if trunk_pov_luminance < 0.100:
        add_failure("tree_trunk_player_pov_unreadable", "daylight player POV luminance %.4f" % trunk_pov_luminance)
        return
    var observer_target_height := clampf(float(tree.get_meta("tree_visual_height", 12.0)) * 0.44, 5.0, 38.0)
    await capture_observer_stage("generated_tree_before_harvest", observer_eye_for_tree(tree), tree.global_position + Vector3.UP * observer_target_height, {
        "tree": tree_summary_before,
        "nearbyMatureTreeCount": count_mature_trees_near(tree.global_position, 72.0),
        "nearbyTreeVariety": tree_variety_summary_near(tree.global_position, 72.0)
    })
    await capture_observer_stage("generated_tree_ground_oblique", ground_oblique_eye_for_tree(tree), tree.global_position + Vector3.UP * observer_target_height, {
        "tree": tree_summary_before,
        "cameraPolicy": "ground-referenced oblique view from the player-facing side",
        "nearbyTreeVariety": tree_variety_summary_near(tree.global_position, 72.0)
    })
    if not fixture_dimensions_pass:
        add_failure("tree_fixture_below_required_dimensions", JSON.stringify({"tree": tree_summary_before, "selection": fixture_selection_summary()}))
        return
    # Observer captures temporarily replace the viewport camera and the player
    # has had several real physics frames in a dense stand. Re-establish the
    # same collision-backed player pose immediately before the live input act;
    # otherwise a neighbouring legitimate trunk can become the closer ray hit
    # and the runner would falsely attribute that interaction to the captured
    # tree. This is fixture setup, not a direct harvest shortcut.
    if not await place_player_beside_tree(tree):
        add_failure("tree_harvest_pose_unavailable", JSON.stringify(tree_summary_before))
        return
    var inventory = main.get("inventory_system")
    if inventory == null:
        add_failure("inventory_missing", "inventory system unavailable for fixture tool grant")
        return
    inventory.set_size(24)
    inventory.add_item("woodenAxe", 1)
    if not select_inventory_item(inventory, "woodenAxe"):
        add_failure("wooden_axe_fixture_failed", "could not select wooden axe before act phase")
        return
    close_gameplay_overlays()
    var held_item = main.get("held_item")
    if held_item != null and held_item.has_method("refresh_active"):
        held_item.call("refresh_active")
    report_data["toolFixture"] = {
        "activeStack": inventory.active_stack().duplicate(true),
        "selectedSlot": int(inventory.get("selected_slot")),
        "mainProcessesInput": main.is_processing_input(),
        "mouseMode": int(Input.get_mouse_mode()),
    }
    var prop_id := String(tree.get_meta("prop_id", ""))
    var logs_before := int(inventory.count("logs"))
    var target_point := tree.global_position + Vector3.UP * clampf(float(tree.get_meta("tree_visual_height", 8.0)) * 0.16, 1.2, 2.2)
    # Use the same production-range, multi-height targeting path for the
    # pre-act proof and every real harvest click. The former fixed 3.6m probe
    # could reject a legitimate tall conifer pose that the actual interaction
    # range successfully targets, turning fixture geometry into a false
    # gameplay regression.
    var initial_target: Dictionary = await aim_until_tree_hit(prop_id, target_point)
    var initial_hit: Dictionary = initial_target.get("hit", {})
    var initial_collider := initial_hit.get("collider") as Node
    var hit_prop_id := String(initial_collider.get_meta("prop_id", "")) if initial_collider != null else ""
    var target_hit := bool(initial_target.get("matches", false)) \
        and initial_collider is Node3D \
        and hit_prop_id == prop_id \
        and String(initial_collider.get_meta("material", "")) == "tree"
    results.append({"name": "live_tree_targeting_hits_coherent_trunk", "passed": target_hit, "details": JSON.stringify({
        "propId": prop_id,
        "hitPropId": hit_prop_id,
        "collider": String(initial_collider.name) if initial_collider != null else "",
        "distance": float(initial_target.get("distance", -1.0))
    })})
    if not target_hit:
        add_failure("tree_targeting_missed", JSON.stringify(tree_summary_before))
        return
    tree = initial_collider as Node3D
    target_point = tree.global_position + Vector3.UP * clampf(float(tree.get_meta("tree_visual_height", 8.0)) * 0.16, 1.2, 2.2)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var clicks := 0
    var registered_hits := 0
    var last_hit := initial_hit
    var harvest_trace: Array = []
    while is_instance_valid(tree) and clicks < 12:
        var live_hit := await aim_until_tree_hit(prop_id, target_point)
        if not bool(live_hit.get("matches", false)):
            add_failure("tree_raycast_lost_during_harvest", JSON.stringify(live_hit))
            break
        registered_hits += 1
        last_hit = live_hit.get("hit", {})
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, true, "tree_harvest_%d_press" % clicks)
        await wait_physics_frames(1)
        dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_LEFT, false, "tree_harvest_%d_release" % clicks)
        clicks += 1
        await wait_physics_frames(5)
        harvest_trace.append({
            "click": clicks,
            "breakProgress": float(main.get("break_progress")),
            "breakTargetId": String(main.get("break_target_id")),
            "activeStack": inventory.active_stack().duplicate(true),
        })
        report_data["harvestTrace"] = harvest_trace
    var falling := find_named_in_world("FallingTree") as Node3D
    var removed_after_input := not is_instance_valid(tree)
    var falling_seen := falling != null and is_instance_valid(falling)
    var falling_mode := String(falling.get_meta("tree_fall_visual_mode", "")) if falling_seen else ""
    var falling_mesh_count := count_mesh_descendants(falling) if falling_seen else 0
    var falling_collision_count := count_collision_descendants(falling) if falling_seen else 0
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
    var harvest_passed := removed_after_input and falling_seen \
        and falling_mode == "shared_structural_wood" \
        and falling_mesh_count == 1 \
        and falling_collision_count == 0 \
        and logs_after > logs_before and bool(removed_state.get(prop_id, false))
    results.append({"name": "live_input_tree_break_fall_drop_and_budgeted_completion", "passed": harvest_passed, "details": JSON.stringify({
        "propId": prop_id,
        "clicks": clicks,
        "registeredHits": registered_hits,
        "lastHitPosition": vec3(last_hit.get("position", Vector3.ZERO)) if last_hit is Dictionary else [],
        "fallingSeen": falling_seen,
        "fallingMode": falling_mode,
        "fallingMeshCount": falling_mesh_count,
        "fallingCollisionCount": falling_collision_count,
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
    await force_canopy_capture_daylight("post_reload")
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
        "registeredHits": registered_hits,
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
    var publication_wait_frames := 0
    for _frame in range(CONTINUE_TREE_PUBLICATION_FRAMES):
        publication_wait_frames += 1
        if continue_population_ready(player.global_position):
            break
        await get_tree().process_frame
    var rendered_count := count_published_trees_near(player.global_position, 96.0)
    var upper_age_count := count_mature_trees_near(player.global_position, 96.0)
    var removed_state: Dictionary = main.get("removed_props") if main.get("removed_props") is Dictionary else {}
    var respawned := find_prop_in_world(expected_prop_id) != null
    await force_canopy_capture_daylight("continue_verify")
    var passed := biome_is_selected(biome) \
        and continue_population_ready(player.global_position) \
        and bool(removed_state.get(expected_prop_id, false)) \
        and not respawned
    results.append({"name": "continue_restores_dense_forest_pose_and_removed_tree", "passed": passed, "details": JSON.stringify({
        "biome": biome,
        "nearbyRenderedTreeCount": rendered_count,
        "minimumRenderedForestTreeCount": 0 if generic_interaction_matrix else MIN_RENDERED_FOREST_TREE_COUNT,
        "nearbyUpperAgeTreeCount": upper_age_count,
        "minimumUpperAgeForestTreeCount": 0 if generic_interaction_matrix else MIN_UPPER_AGE_FOREST_TREE_COUNT,
        "fixtureSelection": fixture_selection_summary(),
        "publicationWaitFrames": publication_wait_frames,
        "publicationWaitLimitFrames": CONTINUE_TREE_PUBLICATION_FRAMES,
        "removedPropId": expected_prop_id,
        "removedState": bool(removed_state.get(expected_prop_id, false)),
        "respawned": respawned,
        "playerPosition": vec3(player.global_position)
    })})
    await capture_observer_stage("continue_dense_forest_removed_tree_persisted", player.global_position + Vector3(12.0, 8.0, 14.0), player.global_position + Vector3.UP * 4.0, {
        "biome": biome,
        "nearbyRenderedTreeCount": rendered_count,
        "minimumRenderedForestTreeCount": 0 if generic_interaction_matrix else MIN_RENDERED_FOREST_TREE_COUNT,
        "nearbyUpperAgeTreeCount": upper_age_count,
        "minimumUpperAgeForestTreeCount": 0 if generic_interaction_matrix else MIN_UPPER_AGE_FOREST_TREE_COUNT,
        "fixtureSelection": fixture_selection_summary(),
        "removedPropId": expected_prop_id,
        "removedState": bool(removed_state.get(expected_prop_id, false)),
        "respawned": respawned
    })
    report_data["continueVerification"] = results.back()
    if not passed:
        add_failure("continue_forest_removal_persistence_failed", JSON.stringify(results.back()))

func force_canopy_capture_daylight(stage_name: String) -> void:
    var tutorial = main.get("tutorial_system")
    if tutorial != null:
        tutorial.set("intro_repair_active", false)
        tutorial.set("intro_repair_complete", true)
        tutorial.set("intro_bed_used", true)
        tutorial.set("intro_elder_dialogue_acknowledged", true)
        tutorial.set("final_night_active", false)
        tutorial.set("final_night_complete", true)
    main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
    var weather = main.get("weather_system")
    if weather != null and weather.has_method("force_weather"):
        weather.call("force_weather", "clear", 0.0, 0.12, player.global_position if player != null else Vector3.ZERO)
    await wait_process_frames(24)
    report_data["captureTime_%s" % stage_name] = {
        "timeOfDay": float(main.get("time_of_day")),
        "displayHour": float(main.call("display_hour")) if main.has_method("display_hour") else -1.0,
        "weatherPolicy": "forced clear for canopy silhouette review"
    }

func close_gameplay_overlays() -> void:
    var hud = main.get("hud")
    if hud == null:
        return
    for method_name in [
        "set_inventory_open",
        "set_utility_open",
        "set_teleport_open",
        "set_objectives_open",
        "set_contracts_open",
        "set_story_journal_open",
        "set_settings_open",
        "set_playtest_open",
        "set_game_menu_open",
    ]:
        if hud.has_method(method_name):
            hud.call(method_name, false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func aim_until_tree_hit(prop_id: String, preferred_target: Vector3) -> Dictionary:
    var last := {}
    for target in [preferred_target, preferred_target + Vector3.UP * 0.6, preferred_target - Vector3.UP * 0.6]:
        aim_at(target)
        await wait_physics_frames(3)
        var tree_melee_range := float(main.call("monumental_tree_melee_ray_range")) if main != null and main.has_method("monumental_tree_melee_ray_range") else 3.8
        var hit: Dictionary = player.call("view_ray", tree_melee_range)
        var collider := hit.get("collider") as Node
        var hit_prop_id := String(collider.get_meta("prop_id", "")) if collider != null else ""
        last = {
            "matches": hit_prop_id == prop_id,
            "propId": prop_id,
            "hitPropId": hit_prop_id,
            "collider": String(collider.name) if collider != null else "",
            "distance": camera.global_position.distance_to(hit.get("position", camera.global_position)) if not hit.is_empty() else -1.0,
            "hit": hit,
        }
        if bool(last.get("matches", false)):
            return last
    return last

func stage_player_beside_generated_tree() -> Dictionary:
    mark_progress("tree_fixture_existing_query")
    var existing := nearest_selected_tree(player.global_position, 120.0)
    if await prepare_dense_near_tree_fixture(existing):
        return fixture_summary(existing)
    mark_progress("tree_fixture_search_overlay")
    await begin_tree_search_loading()
    mark_progress("tree_fixture_candidate_scan")
    var candidate_limit := MAX_FOREST_CANDIDATES * (2 if generic_interaction_matrix else 1)
    var candidates := await wooded_surface_candidates(world_cell(player.global_position), candidate_limit)
    for index in range(candidates.size()):
        var cell: Vector3i = candidates[index]
        update_tree_search_loading("Candidate %d/%d — publishing nearby chunks" % [index + 1, candidates.size()])
        var y := float(main.call("surface_y_at_cell", cell))
        await relocate_for_chunk_fixture(Vector3(float(cell.x) * CELL, y + 0.15, float(cell.z) * CELL), "wooded_candidate_%d" % index)
        for search_frame in range(TREE_SEARCH_FRAMES):
            if search_frame % 12 == 0:
                update_tree_search_loading("Candidate %d/%d — searching trees %d/%d" % [index + 1, candidates.size(), search_frame, TREE_SEARCH_FRAMES])
            # Choose a real collision body even before its visual is published.
            # The preparation step still waits for the required near-LOD visual
            # density, so this cannot turn a queued trunk into visual evidence.
            var tree := nearest_selected_tree_candidate(player.global_position, 120.0)
            if await prepare_dense_near_tree_fixture(tree):
                await finish_tree_search_loading("found")
                return fixture_summary(tree)
            await get_tree().process_frame
    await finish_tree_search_loading("not_found")
    return {}

func prepare_dense_near_tree_fixture(tree: Node3D) -> bool:
    if tree == null or not is_instance_valid(tree):
        return false
    if not tree_matches_fixture_selection(tree):
        return false
    # This is a fixture-selection rule, not a world-generation rule. The actual
    # runtime still places entirely seed-driven trees; the acceptance runner
    # simply needs enough upper-age neighbours to prove the post-harvest
    # population assertion after it removes its target.
    # Body-level density only chooses a viable fixture. The loop below retains
    # the stricter published-canopy requirement before the live harvest act.
    if not generic_interaction_matrix and count_mature_tree_bodies_near(tree.global_position, 96.0) < MIN_SELECTABLE_UPPER_AGE_TREE_COUNT:
        return false
    if not await place_player_beside_tree(tree):
        return false
    for frame in range(FIXTURE_NEAR_LOD_FRAMES):
        if tree_matches_fixture_selection(tree, true) \
            and String(tree.get_meta("tree_render_lod_tier", "")) == "near" \
            and (generic_interaction_matrix or count_mature_trees_near(tree.global_position, 96.0) >= MIN_SELECTABLE_UPPER_AGE_TREE_COUNT):
            return true
        if frame % 24 == 0:
            update_tree_search_loading("Preparing nearby canopy detail %d/%d" % [frame, FIXTURE_NEAR_LOD_FRAMES])
        await get_tree().process_frame
    return false

func begin_tree_search_loading() -> void:
    if search_loading_controller == null or not is_instance_valid(search_loading_controller):
        search_loading_controller = PlaytestSearchLoadingControllerScript.new()
        search_loading_controller.name = "PlaytestTreeSearchLoadingController"
        add_child(search_loading_controller)
    var hud = main.get("hud") if main != null else null
    var shown: bool = bool(search_loading_controller.begin(hud, "Searching generated forests", "Preparing deterministic candidate scan"))
    report_data["treeSearchLoadingOverlayShown"] = shown
    if shown:
        await wait_process_frames(2)
        await capture_stage("tree_search_loading", search_loading_controller.snapshot())

func update_tree_search_loading(detail: String) -> void:
    if search_loading_controller != null and is_instance_valid(search_loading_controller):
        search_loading_controller.set_detail(detail)

func finish_tree_search_loading(result: String) -> void:
    if search_loading_controller == null or not is_instance_valid(search_loading_controller):
        return
    var summary: Dictionary = search_loading_controller.finish()
    summary["result"] = result
    report_data["treeSearchLoading"] = summary
    await wait_process_frames(2)

func place_player_beside_tree(tree: Node3D) -> bool:
    var trunk_radius := float(tree.get_meta("tree_trunk_radius", 1.4))
    # Keep a collision-safe daylight viewing clearance from an upper-age bole.
    # The old 1.15m clearance left the first-person camera grazing a 7m+ trunk,
    # which can clip into the continuous wood surface even though the action ray
    # still succeeds. This preserves the real near-range harvest interaction:
    # the bark remains within the normal 3.8m tree-melee ray.
    var offset_distance := maxf(5.0, trunk_radius + 2.15)
    for direction in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT, Vector3(1.0, 0.0, 1.0).normalized(), Vector3(-1.0, 0.0, 1.0).normalized(), Vector3(1.0, 0.0, -1.0).normalized(), Vector3(-1.0, 0.0, -1.0).normalized()]:
        var candidate_offset: Vector3 = direction * offset_distance
        var candidate_cell := world_cell(tree.global_position + candidate_offset)
        if not biome_is_selected(String(main.call("surface_biome_at_cell", candidate_cell))):
            continue
        var y := float(main.call("surface_y_at_cell", candidate_cell))
        player.set_physics_process(false)
        player.global_position = Vector3(tree.global_position.x + candidate_offset.x, y + 0.15, tree.global_position.z + candidate_offset.z)
        player.velocity = Vector3.ZERO
        player.set_physics_process(true)
        await wait_physics_frames(8)
        var target_point := tree.global_position + Vector3.UP * clampf(float(tree.get_meta("tree_visual_height", 8.0)) * 0.16, 1.2, 2.2)
        var hit := await aim_until_tree_hit(String(tree.get_meta("prop_id", "")), target_point)
        if bool(hit.get("matches", false)):
            return true
    return false

func relocate_for_chunk_fixture(position: Vector3, label: String) -> void:
    player.set_physics_process(false)
    var cell := world_cell(position)
    var y := float(main.call("surface_y_at_cell", cell))
    player.global_position = Vector3(position.x, y + 0.15, position.z)
    player.velocity = Vector3.ZERO
    update_tree_search_loading("%s — yielding before chunk publication" % label.replace("_", " "))
    await wait_process_frames(2)
    # Main's ordinary runtime loop publishes the relocated chunks. The former
    # force path bypassed its streaming budget and could freeze this window.
    for frame in range(180):
        if frame % 12 == 0:
            update_tree_search_loading("%s — streaming %d/180" % [label.replace("_", " "), frame])
        await get_tree().process_frame
        if frame % 60 == 0:
            mark_progress("%s_%d" % [label, frame])
    player.set_physics_process(true)
    await wait_physics_frames(8)

func wooded_surface_candidates(origin: Vector3i, limit: int) -> Array[Vector3i]:
    var candidates: Array[Vector3i] = []
    var scored_candidates: Array[Dictionary] = []
    # A low-maturity region can legitimately contain no old trees. For an old
    # family/age acceptance case, look across several mature-field cells first,
    # then stream only the most ecologically favourable natural locations. This
    # does not place or age a tree: the production world still selects every
    # prop and recipe from its own seeded generation path.
    var prefers_old_maturity := generic_interaction_matrix and required_age_band == "old"
    var max_radius := 2200 if prefers_old_maturity else 520
    var radius_step := 40 if prefers_old_maturity else 20
    var inspected := 0
    for radius in range(36, max_radius, radius_step):
        for direction_index in range(24):
            var angle := TAU * float(direction_index) / 24.0
            var cell := Vector3i(origin.x + roundi(cos(angle) * float(radius)), 0, origin.z + roundi(sin(angle) * float(radius)))
            inspected += 1
            # Keep every generated-world query frame-cooperative so the
            # loading UI continues animating through deterministic search.
            update_tree_search_loading("Scanning deterministic forest cell %d" % inspected)
            await get_tree().process_frame
            var biome := String(main.call("surface_biome_at_cell", cell))
            if inspected % 12 == 0:
                mark_progress("tree_candidate_cell_%d" % inspected)
            if biome_is_selected(biome):
                if prefers_old_maturity:
                    scored_candidates.append({
                        "cell": cell,
                        "maturity": fixture_candidate_maturity(cell, biome),
                    })
                else:
                    candidates.append(cell)
                    if candidates.size() >= limit:
                        return candidates
            # Biome discovery can touch generated-world state. Budget it across
            # frames so the search overlay's animated progress continues to
            # render rather than presenting a single frozen loading frame.
            if inspected % 12 == 0:
                update_tree_search_loading("Scanning deterministic forest cells — %d checked" % inspected)
    if prefers_old_maturity:
        scored_candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
            var first_maturity := float(first.get("maturity", 0.0))
            var second_maturity := float(second.get("maturity", 0.0))
            if not is_equal_approx(first_maturity, second_maturity):
                return first_maturity > second_maturity
            var first_cell: Vector3i = first.get("cell", Vector3i.ZERO)
            var second_cell: Vector3i = second.get("cell", Vector3i.ZERO)
            if first_cell.x == second_cell.x:
                return first_cell.z < second_cell.z
            return first_cell.x < second_cell.x
        )
        var selected: Array[Dictionary] = []
        for candidate in scored_candidates:
            if candidates.size() >= limit:
                break
            var selected_cell: Vector3i = candidate.get("cell", Vector3i.ZERO)
            candidates.append(selected_cell)
            selected.append({
                "cell": [selected_cell.x, selected_cell.z],
                "maturity": float(candidate.get("maturity", 0.0)),
            })
        report_data["treeSearchCandidateEcology"] = {
            "strategy": "highest_local_maturity_for_old_age_case",
            "inspectedCells": inspected,
            "selected": selected,
        }
    return candidates

func fixture_candidate_maturity(cell: Vector3i, biome: String) -> float:
    if main == null:
        return 0.0
    var catalog = main.get("biome_environment_catalog")
    if catalog == null or not catalog.has_method("profile_for_biome"):
        return 0.0
    var profile := catalog.call("profile_for_biome", biome) as BiomeEnvironmentProfile
    if profile == null:
        return 0.0
    if fixture_ecology_sampler == null:
        fixture_ecology_sampler = TreeEcologySamplerScript.new()
    var ecology: Dictionary = fixture_ecology_sampler.sample_tree(
        profile,
        biome,
        String(main.get("seed_text")),
        "canopy-release-fixture-maturity:%d,%d" % [cell.x, cell.z],
        Vector2i(cell.x, cell.z)
    )
    return float(ecology.get("effectiveMaturity", 0.0))

func nearest_mature_tree(origin: Vector3, maximum_distance: float) -> Node3D:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var best: Node3D = null
    var best_distance := maximum_distance
    var best_radius := -1.0
    for tree in all:
        var distance := Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length()
        var radius := float(tree.get_meta("tree_trunk_radius", 0.0))
        if distance < maximum_distance and (radius > best_radius + 0.001 or (is_equal_approx(radius, best_radius) and distance < best_distance)):
            best = tree
            best_distance = distance
            best_radius = radius
    return best

func nearest_selected_tree(origin: Vector3, maximum_distance: float) -> Node3D:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var best: Node3D = null
    var best_distance := maximum_distance
    var best_radius := -1.0
    for tree in all:
        if not tree_matches_fixture_selection(tree, true):
            continue
        var distance := Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length()
        var radius := float(tree.get_meta("tree_trunk_radius", 0.0))
        if distance < maximum_distance and (radius > best_radius + 0.001 or (is_equal_approx(radius, best_radius) and distance < best_distance)):
            best = tree
            best_distance = distance
            best_radius = radius
    return best

func nearest_selected_tree_candidate(origin: Vector3, maximum_distance: float) -> Node3D:
    # This is fixture selection only. The candidate is a real gameplay trunk,
    # but it must pass `prepare_dense_near_tree_fixture`'s published-canopy
    # gate before any visual or harvest acceptance can proceed.
    var all: Array[Node3D] = []
    collect_world_mature_tree_bodies(all)
    var best: Node3D = null
    var best_distance := maximum_distance
    var best_radius := -1.0
    for tree in all:
        if not tree_matches_fixture_selection(tree):
            continue
        var distance := Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length()
        var radius := float(tree.get_meta("tree_trunk_radius", 0.0))
        if distance < maximum_distance and (radius > best_radius + 0.001 or (is_equal_approx(radius, best_radius) and distance < best_distance)):
            best = tree
            best_distance = distance
            best_radius = radius
    return best

func count_mature_trees_near(origin: Vector3, maximum_distance: float) -> int:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var count := 0
    for tree in all:
        if Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length() <= maximum_distance:
            count += 1
    return count

func count_mature_tree_bodies_near(origin: Vector3, maximum_distance: float) -> int:
    var all: Array[Node3D] = []
    collect_world_mature_tree_bodies(all)
    var count := 0
    for tree in all:
        if Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length() <= maximum_distance:
            count += 1
    return count

func count_published_trees_near(origin: Vector3, maximum_distance: float) -> int:
    var count := 0
    for node in get_tree().get_nodes_in_group("generated_tree_trunks"):
        if not (node is Node3D) or not is_instance_valid(node):
            continue
        var tree := node as Node3D
        if String(tree.get_meta("kind", "")) != "prop" \
            or String(tree.get_meta("material", "")) != "tree" \
            or String(tree.get_meta("tree_visual_state", "")) != "published":
            continue
        if Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length() <= maximum_distance:
            count += 1
    return count

func tree_variety_summary_near(origin: Vector3, maximum_distance: float) -> Dictionary:
    var all: Array[Node3D] = []
    collect_world_mature_trees(all)
    var signatures := {}
    var habits := {}
    var included := 0
    for tree in all:
        if Vector2(tree.global_position.x - origin.x, tree.global_position.z - origin.z).length() > maximum_distance:
            continue
        included += 1
        var signature := String(tree.get_meta("tree_recipe_signature", ""))
        var habit := String(tree.get_meta("tree_crown_habit", ""))
        if signature != "":
            signatures[signature] = true
        if habit != "":
            habits[habit] = true
    var habit_names: Array[String] = []
    for habit_value in habits.keys():
        habit_names.append(String(habit_value))
    habit_names.sort()
    return {
        "treeCount": included,
        "uniqueRecipeSignatures": signatures.size(),
        "uniqueCrownHabits": habit_names
    }

func collect_world_mature_trees(output: Array[Node3D]) -> void:
    # Tree placement registers its authoritative collision body in this group.
    # Query it directly rather than recursively walking every terrain, voxel,
    # navigation and visual child in loaded chunks. The previous recursive scan
    # could monopolize the main thread before the search overlay rendered its
    # next animation frame; this keeps the acceptance fixture tied to the real
    # gameplay bodies while remaining frame-responsive.
    var bodies: Array[Node3D] = []
    collect_world_mature_tree_bodies(bodies)
    for tree in bodies:
        # A queued tree already has authoritative gameplay collision, but this
        # runner claims a rendered canopy. Do not let a transitional body
        # satisfy visual acceptance before its recipe has actually published.
        if String(tree.get_meta("tree_visual_state", "")) == "published":
            output.append(tree)

func collect_world_mature_tree_bodies(output: Array[Node3D]) -> void:
    # This is deliberately a body-level selection helper. All live visual
    # assertions use collect_world_mature_trees above and therefore require a
    # published procedural recipe.
    for node in get_tree().get_nodes_in_group("generated_tree_trunks"):
        if node is Node3D and is_instance_valid(node) and String(node.get_meta("kind", "")) == "prop" and String(node.get_meta("material", "")) == "tree":
            var tree := node as Node3D
            var family := String(tree.get_meta("tree_family", ""))
            var age_band := String(tree.get_meta("tree_age_band", ""))
            if family.begins_with("mature_") \
                or family.begins_with("old_growth_") \
                or (family.begins_with("ecological_") and age_band in ["mature", "old", "ancient"]):
                output.append(tree)

func tree_publication_search_diagnostic() -> Dictionary:
    var state_counts := {}
    var family_age_counts := {}
    var example_bodies: Array[Dictionary] = []
    for node in get_tree().get_nodes_in_group("generated_tree_trunks"):
        if not (node is Node3D) or not is_instance_valid(node):
            continue
        var tree := node as Node3D
        var state := String(tree.get_meta("tree_visual_state", "missing"))
        var family := String(tree.get_meta("tree_family", "missing"))
        var age_band := String(tree.get_meta("tree_age_band", "missing"))
        state_counts[state] = int(state_counts.get(state, 0)) + 1
        var family_age := "%s:%s" % [family, age_band]
        family_age_counts[family_age] = int(family_age_counts.get(family_age, 0)) + 1
        if example_bodies.size() < 12:
            example_bodies.append({
                "id": String(tree.get_meta("prop_id", "")),
                "state": state,
                "family": family,
                "ageBand": age_band,
                "asset": String(tree.get_meta("visual_asset_id", "")),
                "source": String(tree.get_meta("visual_source", "")),
                "height": float(tree.get_meta("tree_visual_height", 0.0)),
                "trunkRadius": float(tree.get_meta("tree_trunk_radius", 0.0))
            })
    var queue_metrics := {}
    var queue = main.get("tree_publication_queue") if main != null else null
    if queue != null and is_instance_valid(queue) and queue.has_method("metrics"):
        queue_metrics = queue.metrics()
    return {
        "reason": "no_real_mature_or_older_ecological_tree_published_after_bounded_wooded_biome_search",
        "stateCounts": state_counts,
        "familyAgeCounts": family_age_counts,
        "exampleBodies": example_bodies,
        "queueMetrics": queue_metrics
    }

func find_prop_id_recursive(node: Node, prop_id: String) -> Node:
    if node == null:
        return null
    # FallingTree is a short-lived, non-colliding visual duplicate that keeps the
    # source prop ID. It is evidence of the fall animation, not an active resource.
    if String(node.get_meta("prop_id", "")) == prop_id \
        and String(node.get_meta("kind", "")) == "prop":
        return node
    for child in node.get_children():
        var found := find_prop_id_recursive(child, prop_id)
        if found != null:
            return found
    return null

func count_mesh_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 1 if node is MeshInstance3D else 0
    for child in node.get_children():
        count += count_mesh_descendants(child)
    return count

func count_collision_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 1 if node is CollisionShape3D else 0
    for child in node.get_children():
        count += count_collision_descendants(child)
    return count

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
    summary["nearbyUpperAgeTreeCount"] = count_mature_trees_near(tree.global_position, 96.0)
    summary["minimumSelectableUpperAgeTreeCount"] = MIN_SELECTABLE_UPPER_AGE_TREE_COUNT
    return summary

func summarize_tree(tree: Node3D) -> Dictionary:
    if tree == null or not is_instance_valid(tree):
        return {}
    return {
        "propId": String(tree.get_meta("prop_id", "")),
        "assetId": String(tree.get_meta("visual_asset_id", "")),
        "family": String(tree.get_meta("tree_family", "")),
        "ageBand": String(tree.get_meta("tree_age_band", "")),
        "crownHabit": String(tree.get_meta("tree_crown_habit", "")),
        "recipeSignature": String(tree.get_meta("tree_recipe_signature", "")),
        "branchCount": int(tree.get_meta("tree_branch_count", 0)),
        "foliageClusterCount": int(tree.get_meta("tree_foliage_cluster_count", 0)),
        "visualState": String(tree.get_meta("tree_visual_state", "")),
        "renderLodTier": String(tree.get_meta("tree_render_lod_tier", "")),
        "visualHeight": float(tree.get_meta("tree_visual_height", 0.0)),
        "trunkRadius": float(tree.get_meta("tree_trunk_radius", 0.0)),
        "position": vec3(tree.global_position)
    }

func current_viewport_sample_luminance() -> float:
    var image := get_viewport().get_texture().get_image()
    if image == null or image.is_empty():
        return 0.0
    var size := image.get_size()
    if size.x <= 0 or size.y <= 0:
        return 0.0
    # Sample the middle viewport rather than HUD/status regions. Thirty-six
    # evenly distributed points are enough to reject a black camera clip without
    # adding a per-pixel capture hitch to the headed runner.
    var luminance := 0.0
    var samples := 0
    for grid_y in range(6):
        for grid_x in range(6):
            var x := clampi(roundi(lerpf(float(size.x) * 0.23, float(size.x) * 0.77, (float(grid_x) + 0.5) / 6.0)), 0, size.x - 1)
            var y := clampi(roundi(lerpf(float(size.y) * 0.20, float(size.y) * 0.78, (float(grid_y) + 0.5) / 6.0)), 0, size.y - 1)
            var color := image.get_pixel(x, y)
            luminance += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            samples += 1
    return luminance / float(maxi(1, samples))

func observer_eye_for_tree(tree: Node3D) -> Vector3:
    var height := float(tree.get_meta("tree_visual_height", 12.0))
    var distance := maxf(28.0, height * 1.38)
    return tree.global_position + Vector3(distance * 0.68, clampf(height * 0.46, 9.0, 42.0), distance * 0.84)

func ground_oblique_eye_for_tree(tree: Node3D) -> Vector3:
    var height := maxf(12.0, float(tree.get_meta("tree_visual_height", 12.0)))
    var outward := Vector3.FORWARD
    if player != null:
        outward = Vector3(player.global_position.x - tree.global_position.x, 0.0, player.global_position.z - tree.global_position.z)
    if outward.length_squared() < 0.001:
        outward = Vector3(0.86, 0.0, 0.52)
    outward = outward.normalized().rotated(Vector3.UP, 0.52)
    var distance := maxf(42.0, height * 1.62)
    var horizontal_position := tree.global_position + outward * distance
    var ground_cell := world_cell(horizontal_position)
    var ground_y := float(main.call("surface_y_at_cell", ground_cell)) if main != null and main.has_method("surface_y_at_cell") else tree.global_position.y
    return Vector3(horizontal_position.x, ground_y + clampf(height * 0.08, 3.0, 7.0), horizontal_position.z)

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
