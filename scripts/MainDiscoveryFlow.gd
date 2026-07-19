extends "res://scripts/MainHudFlow.gd"

const NpcDebugStateExporterScript := preload("res://scripts/npc_ai/debug/NpcDebugStateExporter.gd")

func apply_runtime_setting(setting: String, value, sync_hud: bool = true) -> void:
    if setting == "mouseSensitivity":
        value = clampf(float(value), 0.25, 2.5)
    elif setting == "fov":
        value = clampf(roundf(float(value)), 58.0, 104.0)
    elif setting == "renderDistance":
        value = clampi(roundi(float(value)), 2, 4)
    elif setting == "weatherParticles":
        value = clampf(float(value), 0.0, 1.0)
    elif setting == "hudScale":
        value = snappedf(clampf(float(value), 0.8, 1.4), 0.2)
    elif setting == "lookSmoothing":
        value = clampf(float(value), 0.0, 0.82)
    elif setting == "storyTextSpeed":
        value = clampf(float(value), 0.5, 2.0)
    elif setting == "storyJournalFontScale":
        value = clampf(float(value), 0.85, 1.35)
    elif setting in ["invertY", "shadows", "fullscreen", "headBob", "handSway"]:
        value = bool(value)
    elif setting in ["storySubtitles", "storyColorIndependentClues", "storyReplayDiscoveredText", "storyControllerNavigation"]:
        value = bool(value)
    else:
        return

    var previous_value = runtime_settings.get(setting)
    runtime_settings[setting] = value

    if setting in ["mouseSensitivity", "invertY", "fov", "lookSmoothing", "headBob"]:
        if player and player.has_method("apply_camera_settings"):
            player.apply_camera_settings(runtime_settings)
    elif setting == "renderDistance":
        render_distance = int(value)
        if player and chunk_root != null and previous_value != value:
            bootstrap_initial_chunks()
    elif setting == "shadows":
        shadows_enabled = bool(value)
        apply_local_light_shadows()
        if held_item and held_item.has_method("set_local_light_shadows_enabled"):
            held_item.set_local_light_shadows_enabled(shadows_enabled)
        if sun and moon:
            update_sky(0.0)
    elif setting == "weatherParticles":
        if weather_system and weather_system.has_method("set_particle_quality"):
            weather_system.set_particle_quality(float(value))
    elif setting == "hudScale":
        if hud and hud.has_method("set_hud_scale"):
            hud.set_hud_scale(float(value))
    elif setting == "handSway":
        if held_item and held_item.has_method("set_sway_enabled"):
            held_item.set_sway_enabled(bool(value))
    elif setting == "fullscreen" and OS.get_environment("VOXEL_PLAYTEST") == "":
        var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if bool(value) else DisplayServer.WINDOW_MODE_WINDOWED
        DisplayServer.window_set_mode(mode)
    elif setting.begins_with("story"):
        if story_accessibility_settings and story_accessibility_settings.has_method("apply_runtime_settings"):
            story_accessibility_settings.apply_runtime_settings(runtime_settings)
        if hud and hud.has_method("set_story_accessibility_state") and story_accessibility_settings:
            hud.set_story_accessibility_state(story_accessibility_settings.state())

    if sync_hud and hud:
        hud.set_settings_state(runtime_settings)

func update_performance_overlay(delta: float) -> void:
    if hud == null or not hud.is_performance_open():
        return
    perf_elapsed += delta
    if perf_elapsed < 0.25:
        return
    perf_elapsed = 0.0
    hud.set_performance(debug_performance_state())

func debug_performance_state() -> Dictionary:
    debug_performance_state_trace("start")
    var hostile_stats: Dictionary = hostile_system.stats() if hostile_system else {}
    debug_performance_state_trace("hostile_stats")
    var prop_count := count_nodes_with_meta(chunk_root, "kind", "prop") + count_nodes_with_meta(prop_root, "kind", "prop")
    debug_performance_state_trace("prop_count")
    var visual_count := count_visual_nodes(chunk_root) + count_visual_nodes(prop_root) + count_visual_nodes(block_root)
    debug_performance_state_trace("visual_count")
    if weather_system:
        visual_count += count_visual_nodes(weather_system)
    debug_performance_state_trace("weather_visual_count")
    var story_perf := {
        "overlay": story_world_overlay_system.performance_state() if story_world_overlay_system != null and story_world_overlay_system.has_method("performance_state") else {},
        "encounter": worldmark_encounter_controller.performance_state() if worldmark_encounter_controller != null and worldmark_encounter_controller.has_method("performance_state") else {}
    }
    debug_performance_state_trace("story_perf")
    var perf_summary: Dictionary = runtime_perf_monitor.summary() if runtime_perf_monitor != null else {}
    debug_performance_state_trace("perf_summary")
    var save_stats: Dictionary = save_system.stats() if save_system != null and save_system.has_method("stats") else {}
    debug_performance_state_trace("save_stats")
    # This class is lower in the inherited Main chain than the queue owner. Resolve the
    # composed service by node rather than reaching upward into a child-class field.
    var tree_publication_queue: Node = get_node_or_null("TreePublicationQueue")
    var tree_publication_stats: Dictionary = tree_publication_queue.metrics() if tree_publication_queue != null and is_instance_valid(tree_publication_queue) and tree_publication_queue.has_method("metrics") else {}
    debug_performance_state_trace("tree_publication")
    var navigation_backend := {}
    var navmesh_world_stats := {}
    if npc_system != null:
        debug_performance_state_trace("npc_system_start")
        var autonomy = npc_system.get("autonomy_system")
        if autonomy != null:
            if autonomy.has_method("navigation_backend_summary"):
                navigation_backend = autonomy.navigation_backend_summary()
                debug_performance_state_trace("navigation_backend")
            if autonomy.has_method("stats"):
                var autonomy_stats: Dictionary = autonomy.stats()
                navmesh_world_stats = autonomy_stats.get("navmeshWorld", {}) if autonomy_stats.get("navmeshWorld", {}) is Dictionary else {}
                debug_performance_state_trace("autonomy_stats")
    debug_performance_state_trace("return")
    return {
        "fps": Engine.get_frames_per_second(),
        "chunks": chunks.size(),
        "props": prop_count,
        "blocks": blocks.size(),
        "hostiles": int(hostile_stats.get("enemies", 0)),
        "pickups": dropped_pickups.size(),
        "physicsBodies": count_physics_bodies(self),
        "drawEstimate": visual_count,
        "frameMs": perf_frame_ms,
        "chunkMs": perf_chunk_ms,
        "skyMs": perf_sky_ms,
        "utilityMs": perf_utility_ms,
        "pickupsMs": perf_pickups_ms,
        "survivalMs": perf_survival_ms,
        "hostilesMs": perf_hostiles_ms,
        "beaconMs": perf_beacon_ms,
        "autosaveMs": perf_autosave_ms,
        "npcMs": perf_npc_ms,
        "routePlanMs": perf_route_plan_ms,
        "navSnapshotMs": perf_nav_snapshot_ms,
        "jobScanMs": perf_job_scan_ms,
        "frameP50Ms": float(perf_summary.get("frameP50Ms", 0.0)),
        "frameP95Ms": float(perf_summary.get("frameP95Ms", 0.0)),
        "frameP99Ms": float(perf_summary.get("frameP99Ms", 0.0)),
        "frameMaxMs": float(perf_summary.get("frameMaxMs", 0.0)),
        "lastSpikeReason": String(perf_summary.get("lastSpikeReason", "")),
        "lastSpikeFrameMs": float(perf_summary.get("lastSpikeFrameMs", 0.0)),
        "lastSpikeTopSections": perf_summary.get("lastSpikeTopSections", []),
        "perfSections": perf_summary.get("sections", {}),
        "perfSectionMaxMs": perf_summary.get("sectionMaxMs", {}),
        "perfCounters": perf_summary.get("counters", {}),
        "autosaveDirty": autosave_dirty,
        "autosaveDirtyReasons": autosave_dirty_reasons.keys(),
        "autosaveInterval": autosave_interval_seconds,
        "autosaveJobsStarted": autosave_jobs_started,
        "autosaveJobsCompleted": autosave_jobs_completed,
        "autosaveJobsFailed": autosave_jobs_failed,
        "autosaveStats": save_stats,
        "breakMs": perf_break_ms,
        "hudMs": perf_hud_ms,
        "hudRefresh": hud_refresh_stats(),
        "chunkCache": chunk_asset_cache_stats(),
        "treePublication": tree_publication_stats,
        "npcDebug": npc_debug_overlay_state(),
        "navigationBackend": navigation_backend,
        "navmeshWorld": navmesh_world_stats,
        "story": story_perf
    }

func debug_performance_state_trace(label: String) -> void:
    var path := OS.get_environment("VOXEL_DEBUG_PERFORMANCE_STATE_TRACE").strip_edges()
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file != null:
        file.store_string(label)

func npc_debug_overlay_state() -> Dictionary:
    if npc_system == null or not npc_system.has_method("stats"):
        return {}
    var npc_stats: Dictionary = npc_system.stats()
    var autonomy_stats: Dictionary = {}
    var autonomy = npc_system.get("autonomy_system")
    if autonomy != null and autonomy.has_method("stats"):
        autonomy_stats = autonomy.stats()
    var npc_entries := []
    var entries_value = npc_system.get("npcs")
    if entries_value is Array:
        npc_entries = entries_value
    var exporter = NpcDebugStateExporterScript.new()
    return exporter.build_runtime_export(npc_stats, autonomy_stats, npc_entries)

func count_nodes_with_meta(node: Node, key: String, expected: String = "") -> int:
    if node == null:
        return 0
    var count := 0
    if node.has_meta(key) and (expected == "" or String(node.get_meta(key)) == expected):
        count += 1
    for child in node.get_children():
        count += count_nodes_with_meta(child, key, expected)
    return count

func count_visual_nodes(node: Node) -> int:
    if node == null:
        return 0
    if node is Node3D and not (node as Node3D).visible:
        return 0
    var count := 0
    if node is MeshInstance3D or node is MultiMeshInstance3D:
        count += 1
    for child in node.get_children():
        count += count_visual_nodes(child)
    return count

func count_physics_bodies(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is PhysicsBody3D or node is Area3D:
        count += 1
    for child in node.get_children():
        count += count_physics_bodies(child)
    return count

func _on_equipment_changed() -> void:
    mark_world_dirty("equipment_changed")
    if progression_system:
        apply_progression_bonuses(progression_system.state())
    if hud and equipment_system:
        hud.set_equipment(equipment_system.state())
        hud.set_survival(survival_system.snapshot())

func _on_equipment_slot_clicked(slot: String) -> void:
    if equipment_system == null:
        return
    var changed: bool = equipment_system.toggle_slot(slot)
    if changed and held_item:
        held_item.play_use("equip")
    if changed:
        play_feedback("pickup", Vector3.INF, Color(0.72, 0.84, 0.95), 5)
    update_hud(equipment_system.last_message)

func _on_contracts_changed() -> void:
    mark_world_dirty("contracts_changed")
    # Contract completion can be emitted inside the regular HUD/world-state
    # refresh. Rebuilding a closed panel here needlessly constructs every
    # contract row in that same gameplay frame. The authoritative system state
    # remains current; an open panel still refreshes immediately, and reopening
    # always renders from that state.
    if hud and contract_system and hud.is_contracts_open():
        hud.set_contracts(contract_system.state())

func _on_contract_rewarded(contract: Dictionary) -> void:
    mark_world_dirty("contract_rewarded")
    var reward: Dictionary = contract.get("reward", {})
    var xp := int(reward.get("xp", 0))
    if xp > 0:
        award_progression("contract: %s" % String(contract.get("label", "Contract")), xp)
    var items: Dictionary = reward.get("items", {})
    var granted := 0
    for item_id_variant in items.keys():
        var item_id := String(item_id_variant)
        granted += inventory_system.add_item(item_id, int(items[item_id_variant])) if inventory_system else 0
        maybe_emit_story_countermeasure_prepared(item_id, "contract_reward")
    _sync_inventory_totals()
    play_feedback("pickup", Vector3.INF, Color(0.86, 0.75, 0.42), 14)
    # ContractSystem emits this while it is evaluating the current state.
    # A full HUD refresh here re-entered objective/contract evaluation with the
    # newly granted reward items, allowing a completion cascade in one frame.
    # Keep the acknowledgement immediate without recursively rebuilding HUD
    # world state; the ordinary throttled refresh renders the new inventory.
    show_action_message("Contract complete: %s" % String(contract.get("label", "Contract")))

func parse_teleport_coords(value: String) -> Dictionary:
    var regex := RegEx.new()
    if regex.compile("-?\\d+(?:\\.\\d+)?") != OK:
        return {}
    var numbers := []
    for match in regex.search_all(value):
        numbers.append(float(match.get_string()))
    if numbers.size() == 2:
        return { "x": numbers[0], "z": numbers[1] }
    if numbers.size() >= 3:
        return { "x": numbers[0], "y": numbers[1], "z": numbers[2] }
    return {}

func teleport_to(value: String) -> bool:
    var coords := parse_teleport_coords(value)
    if coords.is_empty():
        if hud:
            hud.set_teleport_status("Enter x z or x y z")
        update_hud("Teleport: enter x z")
        return false
    var x := float(coords.get("x", 0.0))
    var z := float(coords.get("z", 0.0))
    var y := float(coords.get("y", maxf(surface_y_at_position(Vector3(x, 0.0, z)), WATER_LEVEL) + 0.35))
    if player == null:
        return false
    player.global_position = Vector3(x, y, z)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", false)
    bootstrap_initial_chunks()
    var message := "Teleported: %.0f, %.0f, %.0f" % [x, y, z] if coords.has("y") else "Teleported: %.0f, %.0f" % [x, z]
    if hud:
        hud.set_teleport_status(message)
    update_hud(message)
    return true

func teleport_to_cell(cell: Vector2i, message: String = "") -> bool:
    if player == null:
        return false
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := maxf(surface_y_at_position(Vector3(x, 0.0, z)), WATER_LEVEL) + 0.55
    player.global_position = Vector3(x, y, z)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", false)
    bootstrap_initial_chunks()
    update_hud(message if message != "" else "Teleported to playtest case")
    return true

func run_playtest_case(case_id: String) -> bool:
    var target := playtest_case_target(case_id)
    if target.is_empty():
        update_hud("Playtest case unavailable: %s" % case_id)
        return false
    cleanup_playtest_case_assets()
    var cell: Vector2i = target.get("cell", Vector2i.ZERO)
    var label := String(target.get("label", case_id.capitalize()))
    if not teleport_to_cell(cell, "Playtest: %s" % label):
        return false
    setup_playtest_case(case_id, cell)
    var counts := playtest_case_counts()
    if hud:
        hud.set_playtest_status("%s loaded: %d props, %d blocks, %d hostiles" % [
            label,
            int(counts.get("props", 0)),
            int(counts.get("blocks", 0)),
            int(counts.get("hostiles", 0))
        ])
    update_hud("Playtest: %s" % label)
    return true

func playtest_case_specs() -> Array:
    return PLAYTEST_CASE_SPECS.duplicate(true)

func playtest_case_target(case_id: String) -> Dictionary:
    match case_id:
        "town":
            var town := town_region(1, 0)
            if not town.is_empty():
                return {
                    "cell": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)) + 5),
                    "label": "Town"
                }
        "mine":
            var mine := find_standalone_structure_target("mine")
            if not mine.is_empty():
                return mine
        "camp":
            var camp_cell := find_biome_playtest_cell(["plains", "forest", "savanna", "taiga"], WATER_LEVEL + 2.5, 70.0, true)
            if camp_cell != Vector2i(999999, 999999):
                return { "cell": camp_cell, "label": "Camp" }
        "forest":
            var forest_cell := find_biome_playtest_cell(["forest", "taiga"], WATER_LEVEL + 2.5, 72.0, false)
            if forest_cell != Vector2i(999999, 999999):
                return { "cell": forest_cell, "label": "Forest" }
        "mountain":
            var mountain_cell := find_biome_playtest_cell(["snow", "alpine", "tundra"], 62.0, MAX_HEIGHT, false)
            if mountain_cell != Vector2i(999999, 999999):
                return { "cell": mountain_cell, "label": "Mountain" }
        "water":
            var water_cell := find_biome_playtest_cell(["ocean", "beach"], MIN_HEIGHT, WATER_LEVEL + 1.6, false)
            if water_cell != Vector2i(999999, 999999):
                return { "cell": water_cell, "label": "Water" }
        "combat":
            var combat_cell := find_biome_playtest_cell(["plains", "forest", "savanna", "taiga"], WATER_LEVEL + 2.5, 70.0, true)
            if combat_cell != Vector2i(999999, 999999):
                return { "cell": combat_cell, "label": "Combat Arena" }
        "collapse":
            var collapse_cell := find_biome_playtest_cell(["plains", "forest", "savanna", "town"], WATER_LEVEL + 2.5, 66.0, true)
            if collapse_cell != Vector2i(999999, 999999):
                return { "cell": collapse_cell, "label": "Structure Collapse Test" }
    var fallback := find_biome_playtest_cell(["plains", "forest", "savanna"], WATER_LEVEL + 2.5, 72.0, true)
    if fallback != Vector2i(999999, 999999):
        return { "cell": fallback, "label": case_id.capitalize() }
    return { "cell": Vector2i(0, 28), "label": case_id.capitalize() }

func setup_playtest_case(case_id: String, cell: Vector2i) -> void:
    match case_id:
        "mine":
            setup_playtest_mine_case(cell)
        "forest":
            setup_playtest_forest_case(cell)
        "mountain":
            setup_playtest_mountain_case(cell)
        "water":
            setup_playtest_water_case(cell)
        "camp":
            setup_playtest_camp_case(cell)
        "combat":
            setup_playtest_combat_case(cell)
        "collapse":
            create_playtest_collapse_case(cell + Vector2i(6, 0))
        "town":
            setup_playtest_town_case(cell)

func cleanup_playtest_case_assets() -> void:
    for cell_variant in blocks.keys().duplicate():
        var body := blocks[cell_variant] as Node
        if body != null and body.has_meta("playtest_case"):
            body.queue_free()
            blocks.erase(cell_variant)
    cleanup_playtest_nodes(prop_root)
    cleanup_playtest_nodes(chunk_root)
    if hostile_system:
        for enemy in hostile_system.enemies.duplicate():
            var body := enemy.get("body") as Node
            if body != null and body.has_meta("playtest_case"):
                body.queue_free()
                hostile_system.enemies.erase(enemy)
        for projectile_state in hostile_system.projectiles.duplicate():
            hostile_system.remove_projectile(projectile_state)

func cleanup_playtest_nodes(root: Node) -> void:
    if root == null:
        return
    for child in root.get_children().duplicate():
        var child_node := child as Node
        if child_node == null:
            continue
        if child_node.has_meta("playtest_case"):
            child_node.queue_free()
        else:
            cleanup_playtest_nodes(child_node)

func playtest_case_counts() -> Dictionary:
    return {
        "props": count_playtest_nodes(prop_root) + count_playtest_nodes(chunk_root),
        "blocks": count_playtest_blocks(),
        "hostiles": count_playtest_hostiles()
    }

func count_playtest_nodes(root: Node) -> int:
    if root == null:
        return 0
    var count := 0
    if root.has_meta("playtest_case"):
        count += 1
    for child in root.get_children():
        count += count_playtest_nodes(child)
    return count

func count_playtest_blocks() -> int:
    var count := 0
    for block_value in blocks.values():
        var body := block_value as Node
        if body != null and body.has_meta("playtest_case"):
            count += 1
    return count

func count_playtest_hostiles() -> int:
    if hostile_system == null:
        return 0
    var count := 0
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node
        if body != null and body.has_meta("playtest_case"):
            count += 1
    return count

func playtest_rng(case_id: String, cell: Vector2i) -> RandomNumberGenerator:
    var rng := RandomNumberGenerator.new()
    rng.seed = hash_string("%s:manual-playtest:%s:%d:%d" % [seed_text, case_id, cell.x, cell.y])
    return rng

func playtest_position(cell: Vector2i, offset: Vector2i = Vector2i.ZERO, lift: float = 0.0) -> Vector3:
    var x := float(cell.x + offset.x) * CELL
    var z := float(cell.y + offset.y) * CELL
    var y := maxf(surface_y_at_position(Vector3(x, 0.0, z)), WATER_LEVEL) + lift
    return Vector3(x, y, z)

func mark_playtest_node(node: Node, case_id: String) -> void:
    if node == null:
        return
    node.set_meta("playtest_case", case_id)

func make_playtest_prop(case_id: String, prop_type: String, position: Vector3, rng: RandomNumberGenerator, biome: String = "", ore_type: String = "") -> Node:
    if prop_root == null:
        return null
    var prop_id := "playtest:%s:%s:%d" % [case_id, prop_type, count_playtest_nodes(prop_root)]
    var node: Node = null
    match prop_type:
        "tree":
            node = make_tree(prop_root, prop_id, position, biome, rng)
        "rock":
            node = make_rock(prop_root, prop_id, position, rng)
        "ore":
            var ore_nodes: Array = make_ore_cluster(prop_root, prop_id, position, ore_type, rng, 3)
            if ore_nodes.size() > 0:
                node = ore_nodes[0]
                for ore_node in ore_nodes:
                    mark_playtest_node(ore_node, case_id)
        "forage":
            node = make_forage(prop_root, prop_id, position, biome, rng)
        "wildlife":
            node = make_wildlife(prop_root, prop_id, position, biome, rng)
    mark_playtest_node(node, case_id)
    return node

func setup_playtest_town_case(cell: Vector2i) -> void:
    create_playtest_ground_block(cell, Vector2i(2, 2), "workbench", "town")
    create_playtest_ground_block(cell, Vector2i(3, 2), "chest", "town")
    create_playtest_ground_block(cell, Vector2i(4, 2), "torch", "town")

func setup_playtest_mine_case(cell: Vector2i) -> void:
    var rng := playtest_rng("mine", cell)
    for offset in [Vector2i(3, 0), Vector2i(4, 1), Vector2i(5, -1), Vector2i(6, 1), Vector2i(7, 0), Vector2i(7, 2)]:
        var ore_type := "ironOre" if offset.x % 2 == 0 else "copperOre"
        make_playtest_prop("mine", "ore", playtest_position(cell, offset), rng, "", ore_type)
    for offset in [Vector2i(2, -2), Vector2i(6, -2), Vector2i(2, 2), Vector2i(6, 2)]:
        make_playtest_prop("mine", "rock", playtest_position(cell, offset), rng)
    create_playtest_ground_block(cell, Vector2i(1, 0), "torch", "mine")
    create_playtest_ground_block(cell, Vector2i(2, 0), "chest", "mine")

func setup_playtest_forest_case(cell: Vector2i) -> void:
    var rng := playtest_rng("forest", cell)
    var biome := surface_biome_at_cell(Vector3i(cell.x, 0, cell.y))
    if biome == "":
        biome = "forest"
    for offset in [Vector2i(3, 1), Vector2i(5, -2), Vector2i(7, 2), Vector2i(-3, 3), Vector2i(-5, -2)]:
        make_playtest_prop("forest", "tree", playtest_position(cell, offset), rng, biome)
    for offset in [Vector2i(2, -3), Vector2i(4, 3), Vector2i(-4, 1)]:
        make_playtest_prop("forest", "rock", playtest_position(cell, offset), rng)
    for offset in [Vector2i(1, 3), Vector2i(-2, 2), Vector2i(6, 0)]:
        make_playtest_prop("forest", "forage", playtest_position(cell, offset), rng, biome)
    make_playtest_prop("forest", "wildlife", playtest_position(cell, Vector2i(0, 6)), rng, biome)

func setup_playtest_mountain_case(cell: Vector2i) -> void:
    var rng := playtest_rng("mountain", cell)
    for offset in [Vector2i(3, 0), Vector2i(4, 2), Vector2i(-3, 2), Vector2i(-4, -1), Vector2i(6, -2)]:
        make_playtest_prop("mountain", "rock", playtest_position(cell, offset), rng)
    for offset in [Vector2i(2, -2), Vector2i(5, 1), Vector2i(-5, 2)]:
        make_playtest_prop("mountain", "ore", playtest_position(cell, offset), rng, "", "ironOre")
    make_playtest_prop("mountain", "forage", playtest_position(cell, Vector2i(1, 4)), rng, "snow")

func setup_playtest_water_case(cell: Vector2i) -> void:
    var rng := playtest_rng("water", cell)
    for offset in [Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0), Vector2i(5, 0)]:
        create_playtest_ground_block(cell, offset, "woodBlock", "water")
    create_playtest_ground_block(cell, Vector2i(2, 1), "campfire", "water")
    create_playtest_ground_block(cell, Vector2i(3, 1), "chest", "water")
    for offset in [Vector2i(1, -2), Vector2i(4, -2), Vector2i(6, 2)]:
        make_playtest_prop("water", "forage", playtest_position(cell, offset), rng, "beach")
    if inventory_system:
        inventory_system.add_item("fishingRod", 1)
