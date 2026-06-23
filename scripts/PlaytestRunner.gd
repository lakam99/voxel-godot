extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const CELL := 1.35
const WATER_LEVEL := 11.1
const INTERACT_RANGE := 10.5
const ACTION_REACH := CELL * 1.85
const PLACEMENT_RANGE := CELL * 2.65
const MELEE_RANGE := CELL * 2.65

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var results: Array[Dictionary] = []
var failed := false
var elapsed := 0.0
var finished := false

func _ready() -> void:
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    if elapsed > 24.0:
        add_result("playtest_watchdog", false, "runner timed out before completion")
        finished = true
        save_optional_screenshot()
        save_report()
        get_tree().quit(1)

func run() -> void:
    mark_progress("start")
    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("main_instantiated")
    await wait_physics_frames(20)

    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        camera = player.get("camera") as Camera3D
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

    mark_progress("pre_warmup")
    await wait_physics_frames(80)
    mark_progress("scene_bootstrap")
    test_scene_bootstrap()
    mark_progress("tutorial_start")
    await test_tutorial_start_system()
    mark_progress("mouse_look")
    test_mouse_look_input()
    mark_progress("escape_menu_new_game")
    await test_escape_menu_new_game()
    mark_progress("inventory_and_crafting")
    test_inventory_and_crafting_systems()
    mark_progress("tool_weapon_catalog")
    test_tool_weapon_catalog_parity()
    mark_progress("progression")
    test_progression_system()
    mark_progress("equipment")
    test_equipment_system()
    mark_progress("navigation_map")
    test_navigation_map_system()
    mark_progress("contracts")
    test_contract_system()
    mark_progress("audio_effects")
    await test_audio_effects_system()
    mark_progress("teleport")
    await test_teleport_system()
    mark_progress("settings_playtest_debug")
    await test_settings_playtest_debug()
    mark_progress("hud_refresh_throttling")
    await test_hud_refresh_throttling()
    mark_progress("manual_playtest_cases")
    await test_manual_playtest_cases()
    mark_progress("objectives")
    test_objective_system()
    mark_progress("utility_blocks")
    test_utility_blocks()
    mark_progress("player_placement")
    await test_player_placement_system()
    mark_progress("trader_stall")
    test_trader_stall_system()
    mark_progress("fishing")
    await test_fishing_system()
    mark_progress("survival")
    test_survival_system()
    mark_progress("bed_respawn")
    test_bed_respawn_and_death_drop()
    mark_progress("save_load")
    test_save_load_round_trip()
    mark_progress("hostiles")
    await test_hostile_system()
    mark_progress("rift_hostiles")
    test_rift_hostile_system()
    mark_progress("sanctuary_beacon_raid")
    test_sanctuary_beacon_raid_system()
    mark_progress("defensive_blocks")
    test_defensive_blocks()
    mark_progress("player_ranged")
    await test_player_ranged_system()
    mark_progress("structures")
    test_structure_and_town_generation()
    mark_progress("npc_equipment_pathing")
    await test_npc_equipment_and_pathing()
    mark_progress("structural_integrity")
    test_structural_integrity()
    mark_progress("landmarks")
    test_landmark_generation_and_loot()
    mark_progress("ore_generation")
    test_ore_generation_and_drops()
    mark_progress("forage_wildlife")
    test_forage_and_wildlife_drops()
    mark_progress("held_item")
    await test_held_item_system()
    mark_progress("terrain_collision")
    test_terrain_collision_shapes()
    mark_progress("terrain_generation_profile")
    test_terrain_generation_profile()
    mark_progress("world_streaming")
    await test_world_chunk_streaming()
    mark_progress("chunk_detail_batches")
    test_chunk_detail_batches()
    mark_progress("sky_light")
    test_sky_light_consistency()
    mark_progress("environment_visual_style")
    test_environment_visual_style()
    mark_progress("weather_visual")
    test_weather_visual_system()
    mark_progress("spawn_clearance")
    test_spawn_clearance()
    mark_progress("player_movement")
    await test_player_movement()
    mark_progress("uphill_smoothing")
    await test_uphill_smoothing()
    mark_progress("steep_uphill")
    await test_steep_uphill_blocking()
    mark_progress("airborne_obstacle")
    await test_airborne_obstacle_blocking()
    mark_progress("jump")
    await test_jump()
    mark_progress("wait_grounded")
    await wait_until_grounded(120)
    mark_progress("mining_requirements")
    await test_mining_tool_requirements()
    mark_progress("mining_progression")
    await test_mining_upgrade_progression()
    mark_progress("material_hardness")
    await test_material_hardness_and_reset()
    mark_progress("block_destroy_ray")
    await test_block_destroy_ray()
    mark_progress("saving_report")
    save_optional_screenshot()
    save_report()
    finished = true
    mark_progress("finished")
    get_tree().quit(1 if failed else 0)

func mark_progress(label: String) -> void:
    var path: String = OS.get_environment("VOXEL_PLAYTEST_PROGRESS")
    if path == "":
        return
    var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\n" % [label, elapsed, results.size(), str(failed)])
    file.close()

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func add_result(name: String, passed: bool, details: String = "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    var status: String = "PASS" if passed else "FAIL"
    print("[%s] %s %s" % [status, name, details])
    save_report(false)

func test_scene_bootstrap() -> void:
    var chunks := get_chunks()
    add_result("scene_bootstrap", main != null and player != null and camera != null, "main/player/camera present")
    add_result("initial_chunks_loaded", chunks.size() >= 49, "%d chunks" % chunks.size())
    if player:
        add_result("controller_ticks", int(player.get("physics_ticks")) > 0, "%d ticks" % int(player.get("physics_ticks")))
    var hud = main.get("hud") if main else null
    var version_label: Label = hud.get("version_label") if hud else null
    add_result(
        "version_label_visible",
        version_label != null and version_label.visible and version_label.text.begins_with("build "),
        "label '%s'" % (version_label.text if version_label else "")
    )

func test_tutorial_start_system() -> void:
    if not main or not player:
        add_result("tutorial_start_system", false, "main/player missing")
        return
    var tutorial_system = main.get("tutorial_system")
    var weather_system = main.get("weather_system")
    var objective_system = main.get("objective_system")
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var hostile_system = main.get("hostile_system")
    var npc_system = main.get("npc_system")
    if tutorial_system == null or weather_system == null or objective_system == null or inventory_system == null or crafting_system == null or hostile_system == null or npc_system == null:
        add_result("tutorial_start_system", false, "tutorial/weather/objective/inventory/crafting/hostile/npc system missing")
        return

    var state: Dictionary = tutorial_system.state()
    var tutorial_original_position: Vector3 = player.global_position
    var tutorial_original_velocity: Vector3 = player.velocity
    var cell := Vector2i(main.call("world_to_cell", player.global_position.x), main.call("world_to_cell", player.global_position.z))
    var biome := String(main.call("biome_at_cell", cell.x, cell.y))
    var weather_state: Dictionary = weather_system.snapshot()
    var counts: Dictionary = main.call("structure_counts")
    var time_of_day := float(main.get("time_of_day"))
    var night_start := time_of_day >= 0.80 or time_of_day <= 0.20
    var safety := float(main.call("light_safety_at", player.global_position, false))
    var shelter_state: Dictionary = main.call("shelter_state_at", player.global_position)
    var spawned_inside_house := (
        String(shelter_state.get("label", "")) == "Sheltered"
        and float(shelter_state.get("roof", 0.0)) >= 0.95
        and int(shelter_state.get("wallSectors", 0)) >= 4
        and float(shelter_state.get("comfort", 0.0)) >= 0.62
    )
    var has_town_blocks := int(counts.get("door", 0)) >= 4 and int(counts.get("workbench", 0)) >= 1 and int(counts.get("torch", 0)) >= 2
    var town_center: Vector2i = state.get("townCenter", Vector2i.ZERO)
    var starter_bed_count := count_starter_beds(tutorial_system)
    var fence_radius := 25
    var fence_blocks := 0
    var perimeter_lights := 0
    var perimeter_doors := 0
    var blocks_for_fence := get_blocks()
    for block in blocks_for_fence.values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        var block_cell: Vector3i = body.get_meta("cell")
        var on_perimeter: bool = abs(block_cell.x - town_center.x) == fence_radius or abs(block_cell.z - town_center.y) == fence_radius
        if not on_perimeter:
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type == "woodBlock":
            fence_blocks += 1
        elif block_type == "torch":
            perimeter_lights += 1
        elif block_type == "door":
            perimeter_doors += 1
    var fenced_start := fence_blocks >= 90 and perimeter_lights >= 30 and perimeter_doors >= 8
    var starter_empty: bool = inventory_system.filled_count() == 0
    add_result(
        "tutorial_start_system",
        bool(state.get("started", false))
            and biome == "town"
            and night_start
            and String(weather_state.get("kind", "")) == "rain"
            and bool(weather_state.get("rainVisible", false))
            and int(state.get("npcCount", 0)) >= 4
            and spawned_inside_house
            and starter_bed_count == 1
            and has_town_blocks
            and fenced_start
            and safety > 0.15
            and starter_empty,
        "started %s, biome %s, time %.2f, weather %s rain %s, npcs %d, shelter %s, starter beds %d, safety %.2f, fence %d lights %d gates %d, starter empty %s, counts %s" % [
            str(state.get("started", false)),
            biome,
            time_of_day,
            String(weather_state.get("kind", "")),
            str(weather_state.get("rainVisible", false)),
            int(state.get("npcCount", 0)),
            str(shelter_state),
            starter_bed_count,
            safety,
            fence_blocks,
            perimeter_lights,
            perimeter_doors,
            str(starter_empty),
            str(counts)
        ]
    )

    var npc_root = tutorial_system.get("npc_root") as Node
    var mira := npc_root.get_node_or_null("TutorialNPC_mira") if npc_root else null
    var rowan := npc_root.get_node_or_null("TutorialNPC_rowan") if npc_root else null
    var niko := npc_root.get_node_or_null("TutorialNPC_niko") if npc_root else null
    var sera := npc_root.get_node_or_null("TutorialNPC_sera") if npc_root else null
    var audio_effects = main.get("audio_effects")
    var knock_started := audio_effects != null and bool(audio_effects.stats().get("knockLooping", false))
    var door_opened := bool(tutorial_system.on_door_opened(null))
    main.call("refresh_intro_knock_audio")
    var knock_stopped := audio_effects != null and not bool(audio_effects.stats().get("knockLooping", false))
    main.call("show_tutorial_dialogue", String(tutorial_system.get("last_message")))
    await get_tree().process_frame
    var game_hud = main.get("hud")
    var dialogue_open := game_hud != null and bool(game_hud.is_dialogue_open())
    if game_hud:
        game_hud.hide_dialogue(true)
    await get_tree().process_frame
    var dialogue_acknowledged: bool = tutorial_system.has_method("is_intro_elder_waiting_for_ack") and not bool(tutorial_system.is_intro_elder_waiting_for_ack())
    main.call("update_objectives_and_contracts")
    var door_objective := bool(objective_system.is_complete("tutorial_open_door", main.call("objective_state")))
    var starter_cell: Vector2i = tutorial_system.get("start_cell")
    var mira_home_cell: Vector2i = mira.get_meta("npc_home_cell", Vector2i.ZERO) if mira else Vector2i.ZERO
    var mira_has_separate_home := mira != null and mira_home_cell != starter_cell
    var mira_route_bounds: Dictionary = building_bounds_near(starter_cell, 9)
    add_result(
        "tutorial_intro_knock_elder",
        door_opened
            and door_objective
            and knock_started
            and knock_stopped
            and dialogue_open
            and dialogue_acknowledged
            and mira_has_separate_home
            and String(tutorial_system.get("last_message")).find("Mira:") == 0,
        "door %s, objective %s, knock %s->%s, dialogue open %s ack %s, mira home %s starter %s, message '%s'" % [
            str(door_opened),
            str(door_objective),
            str(knock_started),
            str(not knock_stopped),
            str(dialogue_open),
            str(dialogue_acknowledged),
            str(mira_home_cell),
            str(starter_cell),
            String(tutorial_system.get("last_message"))
        ]
    )
    var mira_entered_starter_house := false
    var mira_min_starter_distance := INF
    for i in range(30):
        npc_system.update_npcs(0.1, 0.0)
        if mira is Node3D:
            var mira_body_for_route := mira as Node3D
            var flat_distance := Vector2(
                mira_body_for_route.global_position.x - float(starter_cell.x) * CELL,
                mira_body_for_route.global_position.z - float(starter_cell.y) * CELL
            ).length()
            mira_min_starter_distance = minf(mira_min_starter_distance, flat_distance)
            if point_in_cell_bounds(world_to_flat_cell(mira_body_for_route.global_position), mira_route_bounds):
                mira_entered_starter_house = true
    add_result(
        "tutorial_mira_routes_around_starter_house",
        mira != null and not mira_entered_starter_house,
        "entered %s, min distance %.2f, bounds %s" % [str(mira_entered_starter_house), mira_min_starter_distance, str(mira_route_bounds)]
    )
    for i in range(40):
        npc_system.update_npcs(0.1, 0.0)
    var starter_position := Vector3(float(starter_cell.x) * CELL, player.global_position.y, float(starter_cell.y) * CELL)
    var mira_position := starter_position
    if mira is Node3D:
        mira_position = (mira as Node3D).global_position
    var mira_distance_from_starter := Vector2(mira_position.x - starter_position.x, mira_position.z - starter_position.z).length()
    var mira_inside_own_home := mira != null and bool(mira.get_meta("npc_inside_home", false)) and mira_distance_from_starter > CELL * 8.0
    add_result(
        "tutorial_elder_returns_home",
        mira_has_separate_home and mira_inside_own_home,
        "home %s, starter %s, distance %.2f, inside %s" % [
            str(mira_home_cell),
            str(starter_cell),
            mira_distance_from_starter,
            str(mira.get_meta("npc_inside_home", false) if mira else false)
        ]
    )

    var rowan_locked_interaction := rowan != null and bool(tutorial_system.interact_with(rowan))
    var locked_state: Dictionary = tutorial_system.state()
    var locked_talks: Dictionary = locked_state.get("interacted", {})
    var locked_objective_state: Dictionary = main.call("objective_state")
    var rowan_objective_locked := not bool(objective_system.is_complete("tutorial_rowan", locked_objective_state))
    var rowan_step_locked := not bool(locked_talks.get("rowan", false))
    add_result(
        "tutorial_followups_locked_until_sleep",
        rowan_locked_interaction and rowan_objective_locked and rowan_step_locked and String(tutorial_system.get("last_message")).find("after dawn") >= 0,
        "interact %s, objective locked %s, rowan talk locked %s, message '%s'" % [
            str(rowan_locked_interaction),
            str(rowan_objective_locked),
            str(rowan_step_locked),
            String(tutorial_system.get("last_message"))
        ]
    )

    var repair_chest := find_first_block_with_meta("intro_repair_chest", true)
    var utility_system = main.get("utility_system")
    var chest_opened := repair_chest != null and utility_system != null and bool(utility_system.open_block(repair_chest)) and bool(tutorial_system.on_utility_opened(repair_chest))
    var chest_slots: Array = repair_chest.get_meta("storage_slots", []) if repair_chest else []
    var chest_has_supplies := chest_slots.size() >= 2 and String(chest_slots[0].get("item", "")) == "logs" and int(chest_slots[0].get("count", 0)) >= 20 and String(chest_slots[1].get("item", "")) == "stones" and int(chest_slots[1].get("count", 0)) >= 12
    add_result(
        "tutorial_repair_chest_supplies",
        chest_opened and chest_has_supplies and bool(objective_system.is_complete("tutorial_repair_chest", main.call("objective_state"))),
        "opened %s, supplies %s, slots %s" % [str(chest_opened), str(chest_has_supplies), str(chest_slots)]
    )

    inventory_system.add_item("logs", 24)
    inventory_system.add_item("stones", 16)
    move_player_near_first_block_type("workbench")
    var crafted_repair_wood := bool(crafting_system.craft("woodBlock")) and bool(crafting_system.craft("woodBlock"))
    var crafted_repair_lamps := bool(crafting_system.craft("torch"))
    main.call("update_objectives_and_contracts")
    var repair_build_objective := bool(objective_system.is_complete("tutorial_build_repairs", main.call("objective_state")))
    add_result(
        "tutorial_build_repair_supplies",
        crafted_repair_wood and crafted_repair_lamps and inventory_system.count("woodBlock") >= 8 and inventory_system.count("torch") >= 4 and repair_build_objective,
        "wood craft %s, torch craft %s, wood %d, torch %d, objective %s" % [
            str(crafted_repair_wood),
            str(crafted_repair_lamps),
            inventory_system.count("woodBlock"),
            inventory_system.count("torch"),
            str(repair_build_objective)
        ]
    )

    var bed := find_first_block_by_type("bed")
    var blocked_sleep := bed != null and bool(main.call("sleep_at_bed", bed)) and not bool(tutorial_system.state().get("introBedUsed", false))
    var repair_state_before: Dictionary = tutorial_system.state()
    var repair_targets: Dictionary = repair_state_before.get("introRepairTargets", {})
    var repair_marker_root := tutorial_system.get("repair_marker_root") as Node
    var marker_count_before := repair_marker_root.get_child_count() if repair_marker_root else 0
    var expected_marker_count := int(repair_targets.get("fence", []).size()) + int(repair_targets.get("lamps", []).size())
    var level_for_repairs := float(tutorial_system.get("town").get("level", player.global_position.y))
    var repaired_all := true
    for cell_variant in repair_targets.get("fence", []):
        var flat: Vector2i = cell_variant
        var world_y := level_for_repairs + CELL * 0.48
        var block = main.call("create_block", Vector3i(flat.x, floori(world_y / CELL) + 1, flat.y), "woodBlock", { "player_placed": true, "world_y": world_y })
        repaired_all = bool(block != null and tutorial_system.on_block_placed(block)) and repaired_all
    for cell_variant in repair_targets.get("lamps", []):
        var flat: Vector2i = cell_variant
        var placed_flat := flat + Vector2i(2, 0)
        var block := Node.new()
        block.set_meta("block_type", "torch")
        block.set_meta("cell", Vector3i(placed_flat.x, 0, placed_flat.y))
        repaired_all = bool(tutorial_system.on_block_placed(block)) and repaired_all
        block.free()
    main.call("update_objectives_and_contracts")
    var repair_state_after: Dictionary = tutorial_system.state()
    var marker_count_after := repair_marker_root.get_child_count() if repair_marker_root else -1
    var repair_complete := bool(repair_state_after.get("introRepairComplete", false))
    var repair_objective := bool(objective_system.is_complete("tutorial_repair_perimeter", main.call("objective_state")))
    var sleep_started := bed != null and bool(main.call("sleep_at_bed", bed))
    if sleep_started:
        main.call("update_sleep_transition", 2.0)
    var slept_after_repair := sleep_started and bool(tutorial_system.state().get("introBedUsed", false))
    main.call("update_objectives_and_contracts")
    var sleep_objective := bool(objective_system.is_complete("tutorial_sleep_after_repair", main.call("objective_state")))
    add_result(
        "tutorial_repair_and_sleep_gate",
        blocked_sleep and marker_count_before >= expected_marker_count and marker_count_after == 0 and repaired_all and repair_complete and repair_objective and slept_after_repair and sleep_objective and float(main.get("time_of_day")) < 0.36,
        "blocked %s, markers %d/%d->%d, repaired %s, complete %s, repair objective %s, slept %s, sleep objective %s, time %.2f, state %s" % [
            str(blocked_sleep),
            marker_count_before,
            expected_marker_count,
            marker_count_after,
            str(repaired_all),
            str(repair_complete),
            str(repair_objective),
            str(slept_after_repair),
            str(sleep_objective),
            float(main.get("time_of_day")),
            str(tutorial_system.state())
        ]
    )
    if utility_system:
        utility_system.close()
    if main.get("hud"):
        var active_hud = main.get("hud")
        active_hud.call("hide_utility_panel")
        active_hud.call("set_inventory_open", false)
        active_hud.call("set_teleport_open", false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    var interacted := bool(tutorial_system.interact_with(mira))
    var dialogue_focus_ok := false
    if interacted and mira is Node3D:
        var mira_body := mira as Node3D
        var before_focus_position := mira_body.global_position
        main.call("show_tutorial_dialogue", String(tutorial_system.get("last_message")))
        npc_system.update_npcs(0.35, 1.0)
        var to_player_focus: Vector3 = player.global_position - mira_body.global_position
        to_player_focus.y = 0.0
        var expected_focus_yaw := atan2(to_player_focus.x, to_player_focus.z)
        dialogue_focus_ok = (
            bool(mira_body.get_meta("npc_dialogue_focused", false))
            and mira_body.global_position.distance_to(before_focus_position) <= 0.01
            and absf(angle_difference(mira_body.rotation.y, expected_focus_yaw)) < 0.20
        )
        if game_hud != null and bool(game_hud.is_dialogue_open()):
            game_hud.hide_dialogue(true)
    var objective_state: Dictionary = main.call("objective_state")
    var objective_complete := bool(objective_system.is_complete("tutorial_mira", objective_state))
    var message := String(tutorial_system.get("last_message"))
    add_result(
        "tutorial_npc_interaction",
        interacted and objective_complete and dialogue_focus_ok and message.find("Mira:") == 0,
        "interacted %s, objective %s, focus %s, message '%s'" % [str(interacted), str(objective_complete), str(dialogue_focus_ok), message]
    )

    var rowan_blocked_until_niko := rowan != null and bool(tutorial_system.interact_with(rowan)) and String(tutorial_system.get("last_message")).find("Niko") >= 0
    tutorial_system.interact_with(niko)
    inventory_system.add_item("berries", 2)
    tutorial_system.interact_with(niko)
    var niko_steps: Dictionary = tutorial_system.state().get("completedSteps", {})
    add_result(
        "tutorial_niko_food_errand",
        rowan_blocked_until_niko and bool(niko_steps.get("nikoBerries", false)) and inventory_system.count("fieldRation") >= 1 and inventory_system.count("berries") == 0,
        "rowan blocked %s, steps %s, ration %d, berries %d" % [str(rowan_blocked_until_niko), str(niko_steps), inventory_system.count("fieldRation"), inventory_system.count("berries")]
    )

    if rowan is Node3D:
        player.global_position = (rowan as Node3D).global_position + Vector3(0.0, 0.0, CELL * 0.9)
        player.velocity = Vector3.ZERO
        player.set("terrain_grounded", true)
    move_player_near_first_block_type("workbench")
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("logs", 10)
    var crafted_axe := bool(crafting_system.craft("woodenAxe"))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("logs", 4)
    main.call("update_objectives_and_contracts")
    var rowan_logs_ready := bool(objective_system.is_complete("tutorial_gather_logs", main.call("objective_state")))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("logs", 4)
    var crafted_pickaxe := bool(crafting_system.craft("woodenPickaxe"))
    tutorial_system.interact_with(rowan)
    inventory_system.add_item("stones", 4)
    main.call("update_objectives_and_contracts")
    tutorial_system.interact_with(rowan)
    var rowan_state: Dictionary = tutorial_system.state()
    var rowan_steps: Dictionary = rowan_state.get("completedSteps", {})
    add_result(
        "tutorial_rowan_errand_chain",
        rowan_logs_ready
            and crafted_axe
            and crafted_pickaxe
            and bool(rowan_steps.get("rowanAxe", false))
            and bool(rowan_steps.get("rowanLogs", false))
            and bool(rowan_steps.get("rowanPickaxe", false))
            and bool(rowan_steps.get("rowanStones", false))
            and bool(rowan_steps.get("rowanBlocks", false))
            and inventory_system.count("stones") >= 4,
        "logs %s, axe %s, pickaxe %s, steps %s, stones %d" % [
            str(rowan_logs_ready),
            str(crafted_axe),
            str(crafted_pickaxe),
            str(rowan_steps),
            inventory_system.count("stones")
        ]
    )

    tutorial_system.interact_with(sera)
    move_player_near_first_block_type("workbench")
    var crafted_sword := bool(crafting_system.craft("woodenSword"))
    tutorial_system.interact_with(sera)
    main.call("update_objectives_and_contracts")
    var final_tutorial_state: Dictionary = tutorial_system.state()
    var final_steps: Dictionary = final_tutorial_state.get("completedSteps", {})
    var weapon_state: Dictionary = main.call("objective_state")
    var ready_before_final := bool(objective_system.is_complete("tutorial_ready", weapon_state))
    var final_objective_available := bool(objective_system.is_available("tutorial_final_night", weapon_state))
    add_result(
        "tutorial_weapon_preps_final_night",
        crafted_sword
            and bool(final_steps.get("seraWeapon", false))
            and bool(final_steps.get("readyForWilds", false))
            and bool(final_tutorial_state.get("readyForWilds", false))
            and final_objective_available
            and not ready_before_final,
        "crafted sword %s, steps %s, final available %s, ready before final %s" % [
            str(crafted_sword),
            str(final_steps),
            str(final_objective_available),
            str(ready_before_final)
        ]
    )

    hostile_system.clear()
    var final_started: bool = mira != null and bool(tutorial_system.interact_with(mira))
    main.call("update_objectives_and_contracts")
    var final_started_state: Dictionary = tutorial_system.state()
    var final_active: bool = bool(final_started_state.get("finalNightActive", false))
    var final_bed_locked: bool = bool(tutorial_system.is_bed_locked())
    var rescue_required: int = int(final_started_state.get("rescueRequired", 6))
    var rescue_remaining_start: int = int(final_started_state.get("rescueRemaining", 0))
    var niko_body := niko as Node3D
    var niko_held: bool = niko_body != null and bool(niko_body.get_meta("npc_force_hold", false)) and bool(niko_body.get_meta("npc_rescue_stranded", false))
    var rescue_torch_present: bool = tutorial_system.get("rescue_torch") != null
    var rescue_bubble_present: bool = niko_body != null and niko_body.get_node_or_null("SpeechBubble") != null
    var guard_before: Vector3 = (sera as Node3D).global_position if sera is Node3D else Vector3.ZERO
    var guard_briefed: bool = sera != null and bool(tutorial_system.interact_with(sera))
    for i in range(36):
        npc_system.update_npcs(0.12, 0.0)
    var escort_state: Dictionary = tutorial_system.state()
    var escort_started: bool = bool(escort_state.get("rescueEscortStarted", false))
    var guard_moved: bool = sera is Node3D and (sera as Node3D).global_position.distance_to(guard_before) > 0.2
    var rescue_hostile_count := 0
    for enemy_state_variant in hostile_system.enemies.duplicate():
        var enemy_state: Dictionary = enemy_state_variant
        var enemy_body := enemy_state.get("body") as Node
        if enemy_body != null and is_instance_valid(enemy_body) and bool(enemy_body.get_meta("tutorial_rescue_hostile", false)):
            rescue_hostile_count += 1
            hostile_system.damage_hostile(enemy_body, 999.0)
            main.call("update_objectives_and_contracts")
    main.call("update_objectives_and_contracts")
    var rescue_returning_started: bool = bool(tutorial_system.state().get("rescueReturning", false))
    for i in range(90):
        npc_system.update_npcs(0.12, 0.0)
        tutorial_system.refresh_rescue_progress(0.12)
        main.call("update_objectives_and_contracts")
        if bool(tutorial_system.state().get("finalNightComplete", false)):
            break
    main.call("update_objectives_and_contracts")
    var final_done_state: Dictionary = tutorial_system.state()
    var final_done_steps: Dictionary = final_done_state.get("completedSteps", {})
    var final_objective_complete := bool(objective_system.is_complete("tutorial_final_night", main.call("objective_state")))
    var ready_objective := bool(objective_system.is_complete("tutorial_ready", main.call("objective_state")))
    add_result(
        "tutorial_final_rescue_mission",
        final_started
            and final_active
            and final_bed_locked
            and guard_briefed
            and escort_started
            and guard_moved
            and niko_held
            and rescue_torch_present
            and rescue_bubble_present
            and rescue_remaining_start == rescue_required
            and rescue_hostile_count == rescue_required
            and rescue_returning_started
            and bool(final_done_state.get("finalNightComplete", false))
            and bool(final_done_steps.get("finalNightComplete", false))
            and bool(final_done_steps.get("miraBlessing", false))
            and not bool(tutorial_system.is_bed_locked())
            and final_objective_complete
            and ready_objective,
        "started %s, active %s, bed locked %s, guard %s/%s/%s, niko held %s, torch %s, bubble %s, rescue %d/%d, returning %s, complete %s, objective %s, ready %s, steps %s" % [
            str(final_started),
            str(final_active),
            str(final_bed_locked),
            str(guard_briefed),
            str(escort_started),
            str(guard_moved),
            str(niko_held),
            str(rescue_torch_present),
            str(rescue_bubble_present),
            rescue_hostile_count,
            rescue_required,
            str(rescue_returning_started),
            str(final_done_state.get("finalNightComplete", false)),
            str(final_objective_complete),
            str(ready_objective),
            str(final_done_steps)
        ]
    )

    hostile_system.clear()
    player.global_position = tutorial_original_position
    player.velocity = tutorial_original_velocity
    for i in range(6):
        hostile_system.spawn_cooldown = 0.0
        hostile_system.update_hostiles(0.25, 0.0, "town", false)
    var perimeter_spawned: bool = hostile_system.enemies.size() >= 3
    var nearest: float = INF
    var unsafe_spawn: bool = true
    var inside_safe_radius := false
    var center := Vector3(float(town_center.x) * CELL, player.global_position.y, float(town_center.y) * CELL)
    var safe_radius := CELL * 24.0
    for enemy in hostile_system.enemies:
        var body := enemy.get("body") as Node3D
        if body == null:
            continue
        nearest = minf(nearest, body.global_position.distance_to(player.global_position))
        var flat_from_center := Vector2(body.global_position.x - center.x, body.global_position.z - center.z).length()
        inside_safe_radius = inside_safe_radius or flat_from_center < safe_radius
        unsafe_spawn = unsafe_spawn and float(main.call("light_safety_at", body.global_position, false)) < 0.26
    add_result(
        "tutorial_perimeter_hostiles",
        perimeter_spawned and nearest > CELL * 13.0 and unsafe_spawn and not inside_safe_radius,
        "spawned %d, nearest %.2f, outside light %s, inside safe %s" % [hostile_system.enemies.size(), nearest, str(unsafe_spawn), str(inside_safe_radius)]
    )

    var guard_target_position := Vector3(center.x, center.y, center.z - CELL * float(25 - 5))
    guard_target_position.y = float(main.call("height_at_world", guard_target_position.x, guard_target_position.z)) + 0.72
    hostile_system.spawn_enemy(guard_target_position, "shadow")
    var npc_stats_before: Dictionary = npc_system.stats()
    var guard_shots_before := int(npc_stats_before.get("guardShots", 0))
    var use_animations_before := int(npc_stats_before.get("useAnimations", 0))
    for i in range(140):
        npc_system.update_npcs(0.1, 0.0)
    var npc_stats_after: Dictionary = npc_system.stats()
    var tutorial_npc_count := npc_root.get_child_count() if npc_root else 0
    var all_tutorial_npcs_have_homes := int(npc_stats_after.get("homed", 0)) >= tutorial_npc_count
    var non_fighters_sheltered := int(npc_stats_after.get("sheltered", 0)) >= 3
    var tutorial_fighters_ready := int(npc_stats_after.get("fighters", 0)) >= 3
    var guards_fired := int(npc_stats_after.get("guardShots", 0)) > guard_shots_before
    var fighters_armed := int(npc_stats_after.get("armed", 0)) >= int(npc_stats_after.get("fighters", 0))
    var weapons_visible := int(npc_stats_after.get("visibleWeapons", 0)) >= int(npc_stats_after.get("fighters", 0))
    var weapon_use_animated := int(npc_stats_after.get("useAnimations", 0)) > use_animations_before
    add_result(
        "tutorial_npc_home_and_guard_behavior",
        all_tutorial_npcs_have_homes and non_fighters_sheltered and tutorial_fighters_ready and guards_fired and fighters_armed and weapons_visible and weapon_use_animated,
        "npcs %d, stats %s, shots %d->%d, use %d->%d" % [
            tutorial_npc_count,
            str(npc_stats_after),
            guard_shots_before,
            int(npc_stats_after.get("guardShots", 0)),
            use_animations_before,
            int(npc_stats_after.get("useAnimations", 0))
        ]
    )
    hostile_system.clear()
    player.global_position = tutorial_original_position
    player.velocity = tutorial_original_velocity

func test_mouse_look_input() -> void:
    if not main or not player or not camera:
        add_result("mouse_look_input", false, "main/player/camera missing")
        return
    var hud = main.get("hud")
    if hud:
        hud.set_inventory_open(false)
        hud.set_teleport_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    var yaw_before: float = player.rotation.y
    var pitch_before: float = camera.rotation.x
    var event := InputEventMouseMotion.new()
    event.relative = Vector2(42.0, -24.0)
    main.call("_input", event)
    var yaw_changed: bool = abs(player.rotation.y - yaw_before) > 0.001
    var pitch_changed: bool = abs(camera.rotation.x - pitch_before) > 0.001
    add_result(
        "mouse_look_input",
        yaw_changed and pitch_changed,
        "yaw %.4f->%.4f, pitch %.4f->%.4f" % [yaw_before, player.rotation.y, pitch_before, camera.rotation.x]
    )
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func test_escape_menu_new_game() -> void:
    if not main or not player:
        add_result("escape_menu_new_game", false, "main/player missing")
        return
    var hud = main.get("hud")
    var inventory_system = main.get("inventory_system")
    var save_system = main.get("save_system")
    var tutorial_system = main.get("tutorial_system")
    var weather_system = main.get("weather_system")
    if hud == null or inventory_system == null or save_system == null or tutorial_system == null or weather_system == null:
        add_result("escape_menu_new_game", false, "hud/inventory/save/tutorial/weather missing")
        return

    hud.set_inventory_open(false)
    hud.set_teleport_open(false)
    hud.set_settings_open(false)
    hud.set_playtest_open(false)
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

    var escape := InputEventKey.new()
    escape.keycode = KEY_ESCAPE
    escape.pressed = true
    main.call("_unhandled_input", escape)
    var opened_menu: bool = hud.is_game_menu_open() and Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE

    inventory_system.add_item("logs", 3)
    var old_seed := String(main.get("seed_text"))
    var saved_ok: bool = bool(main.call("save_world", false))
    var saved_snapshot: Dictionary = save_system.load(old_seed)
    var saved_before: bool = saved_ok and not saved_snapshot.is_empty()
    var new_game_button := find_button_by_text(hud.get("game_menu_panel") as Node, "New Game")
    if new_game_button:
        new_game_button.emit_signal("pressed")
    await wait_physics_frames(24)
    var new_seed := String(main.get("seed_text"))

    var cell := Vector2i(main.call("world_to_cell", player.global_position.x), main.call("world_to_cell", player.global_position.z))
    var biome := String(main.call("biome_at_cell", cell.x, cell.y))
    var shelter_state: Dictionary = main.call("shelter_state_at", player.global_position)
    var weather_state: Dictionary = weather_system.snapshot()
    var tutorial_state: Dictionary = tutorial_system.state()
    var reset_started: bool = bool(tutorial_state.get("started", false))
    var deleted_snapshot: Dictionary = save_system.load(old_seed)
    var save_deleted: bool = deleted_snapshot.is_empty()
    var active_seed_changed: bool = new_seed != old_seed and new_seed.begins_with("atlas-")
    var remembered_seed: bool = String(save_system.active_seed("")) == new_seed
    var mouse_mode_after: int = int(Input.get_mouse_mode())
    var inventory_totals: Dictionary = inventory_system.totals()
    var main_inventory_totals: Dictionary = main.get("inventory")
    var starter_bed_count := count_starter_beds(tutorial_system)
    var fresh_state: bool = (
        bool(tutorial_state.get("started", false))
        and biome == "town"
        and String(weather_state.get("kind", "")) == "rain"
        and String(shelter_state.get("label", "")) == "Sheltered"
        and starter_bed_count == 1
        and inventory_system.filled_count() == 0
        and not hud.is_game_menu_open()
    )
    add_result(
        "escape_menu_new_game",
        opened_menu and new_game_button != null and saved_before and reset_started and save_deleted and active_seed_changed and remembered_seed and fresh_state,
        "opened %s, button %s, saved %s, reset %s, deleted %s, seed %s->%s remembered %s, biome %s, weather %s, shelter %s, starter beds %d, inv %d, totals %s, main totals %s, menu %s, mouse %d" % [
            str(opened_menu),
            str(new_game_button != null),
            str(saved_before),
            str(reset_started),
            str(save_deleted),
            old_seed,
            new_seed,
            str(remembered_seed),
            biome,
            String(weather_state.get("kind", "")),
            str(shelter_state),
            starter_bed_count,
            inventory_system.filled_count(),
            str(inventory_totals),
            str(main_inventory_totals),
            str(hud.is_game_menu_open()),
            mouse_mode_after
        ]
    )
    if active_seed_changed:
        main.call("apply_world_seed", old_seed, true)
        main.call("reset_runtime_world_state")
        tutorial_system.start_new_world()
        main.call("update_chunks", true)
        main.call("refresh_intro_knock_audio")
    unlock_intro_gate_for_followup_tests(tutorial_system)

func find_button_by_text(node: Node, text: String) -> Button:
    if node == null:
        return null
    var button := node as Button
    if button != null and button.text == text:
        return button
    for child in node.get_children():
        var found := find_button_by_text(child, text)
        if found != null:
            return found
    return null

func unlock_intro_gate_for_followup_tests(tutorial_system) -> void:
    if tutorial_system == null:
        return
    tutorial_system.set("intro_repair_complete", true)
    tutorial_system.call("complete_step", "introPerimeterRepaired")
    tutorial_system.call("on_bed_used")
    tutorial_system.call("complete_step", "miraMorningBriefing")

func test_inventory_and_crafting_systems() -> void:
    if not main:
        add_result("inventory_system_present", false, "main missing")
        return

    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var hud = main.get("hud")
    var has_systems := inventory_system != null and crafting_system != null and hud != null
    add_result("inventory_system_present", has_systems, "inventory/crafting/hud present")
    if not has_systems:
        return

    add_result(
        "inventory_slots",
        inventory_system.slots.size() == 24 and inventory_system.hotbar_size == 8,
        "%d slots, %d hotbar" % [inventory_system.slots.size(), inventory_system.hotbar_size]
    )

    var seeded_slots := []
    for i in range(inventory_system.size):
        seeded_slots.append({ "item": "", "count": 0 })
    seeded_slots[5] = { "item": "logs", "count": 12 }
    inventory_system.restore({
        "slots": seeded_slots,
        "size": inventory_system.size,
        "selectedSlot": 5
    })

    inventory_system.select(5)
    var active: Dictionary = inventory_system.active_stack()
    add_result(
        "hotbar_switching",
        String(active.get("item", "")) == "logs",
        "slot 6 active %s" % String(active.get("item", ""))
    )
    var wheel_previous: int = int(main.call("select_hotbar_delta", -1))
    var wheel_next: int = int(main.call("select_hotbar_delta", 1))
    add_result(
        "hotbar_wheel_cycle",
        wheel_previous == 4 and wheel_next == 5 and String(inventory_system.active_stack().get("item", "")) == "logs",
        "wheel slots %d->%d active %s" % [wheel_previous, wheel_next, String(inventory_system.active_stack().get("item", ""))]
    )

    main.call("_on_ui_slot_clicked", 12)
    var empty_click_inert: bool = (
        inventory_system.selected_slot == 5
        and String(inventory_system.active_stack().get("item", "")) == "logs"
        and String(inventory_system.slots[12].get("item", "")) == ""
    )
    add_result(
        "inventory_empty_slot_click_inert",
        empty_click_inert,
        "selected %d, active %s, slot13 '%s'" % [
            inventory_system.selected_slot,
            String(inventory_system.active_stack().get("item", "")),
            String(inventory_system.slots[12].get("item", ""))
        ]
    )

    inventory_system.slots[10] = { "item": "stones", "count": 4 }
    inventory_system.slots[12] = { "item": "", "count": 0 }
    inventory_system.notify()
    var moved_stack: bool = inventory_system.move_slot(10, 12)
    var drag_reordered: bool = (
        moved_stack
        and String(inventory_system.slots[10].get("item", "")) == ""
        and String(inventory_system.slots[12].get("item", "")) == "stones"
        and int(inventory_system.slots[12].get("count", 0)) == 4
        and String(inventory_system.active_stack().get("item", "")) == "logs"
    )
    add_result(
        "inventory_drag_drop_reorders",
        drag_reordered,
        "moved %s, slot11 %s, slot13 %s x%d, active %s" % [
            str(moved_stack),
            String(inventory_system.slots[10].get("item", "")),
            String(inventory_system.slots[12].get("item", "")),
            int(inventory_system.slots[12].get("count", 0)),
            String(inventory_system.active_stack().get("item", ""))
        ]
    )

    var logs_before: int = inventory_system.count("logs")
    var workbench_before: int = inventory_system.count("workbench")
    var crafted_bench: bool = crafting_system.craft("workbench")
    add_result(
        "craft_workbench_without_station",
        crafted_bench and inventory_system.count("workbench") == workbench_before + 1 and inventory_system.count("logs") == logs_before - 4,
        "logs %d->%d, workbench %d->%d" % [logs_before, inventory_system.count("logs"), workbench_before, inventory_system.count("workbench")]
    )

    var wood_state: Dictionary = crafting_system.state_for(crafting_system.recipe_for("woodBlock"))
    add_result(
        "crafting_station_lock",
        bool(wood_state.get("benchLocked", false)),
        String(wood_state.get("status", ""))
    )

    var station_cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    main.call("create_block", station_cell, "workbench")
    var wood_before: int = inventory_system.count("woodBlock")
    logs_before = inventory_system.count("logs")
    var crafted_wood: bool = crafting_system.craft("woodBlock")
    add_result(
        "craft_with_near_workbench",
        crafted_wood and inventory_system.count("woodBlock") == wood_before + 4 and inventory_system.count("logs") == logs_before - 2,
        "wood %d->%d, logs %d->%d" % [wood_before, inventory_system.count("woodBlock"), logs_before, inventory_system.count("logs")]
    )
    var blocks := get_blocks()
    if blocks.has(station_cell):
        var station_block := blocks[station_cell] as Node
        if station_block:
            station_block.queue_free()
        blocks.erase(station_cell)

    hud.set_inventory_open(true)
    add_result(
        "inventory_ui_opens",
        hud.is_inventory_open() and hud.inventory_panel.visible and hud.inventory_grid.get_child_count() == inventory_system.slots.size(),
        "open %s, grid children %d" % [str(hud.is_inventory_open()), hud.inventory_grid.get_child_count()]
    )
    var empty_slot_button := hud.inventory_grid.get_child(10) as Control if hud.inventory_grid.get_child_count() > 10 else null
    var button_script_path := String(empty_slot_button.get_script().resource_path) if empty_slot_button != null and empty_slot_button.get_script() != null else ""
    var empty_slot_accepts_drop := empty_slot_button != null and bool(empty_slot_button.call("_can_drop_data", Vector2.ZERO, { "kind": "inventory_slot", "from": 12 }))
    add_result(
        "inventory_drag_drop_ui",
        button_script_path.ends_with("InventorySlotButton.gd") and empty_slot_accepts_drop,
        "script %s, accepts drop %s" % [button_script_path, str(empty_slot_accepts_drop)]
    )
    inventory_system.select(5)
    hud.call("_on_slot_pressed", 0, false)
    var panel_click_does_not_equip: bool = inventory_system.selected_slot == 5 and not hud.hotbar.visible
    add_result(
        "inventory_panel_click_does_not_equip",
        panel_click_does_not_equip,
        "selected %d, hotbar visible %s" % [inventory_system.selected_slot, str(hud.hotbar.visible)]
    )
    inventory_system.slots[9] = { "item": "stones", "count": 2 }
    inventory_system.slots[10] = { "item": "", "count": 0 }
    inventory_system.notify()
    main.call("_on_ui_slot_moved", 9, 10)
    var panel_drag_keeps_hotbar_hidden: bool = hud.is_inventory_open() and not hud.hotbar.visible and String(inventory_system.slots[10].get("item", "")) == "stones"
    add_result(
        "inventory_drag_keeps_single_ui",
        panel_drag_keeps_hotbar_hidden,
        "open %s, hotbar visible %s, slot11 %s" % [str(hud.is_inventory_open()), str(hud.hotbar.visible), String(inventory_system.slots[10].get("item", ""))]
    )
    var wood_icon := hud.call("icon_for", "woodBlock") as Texture2D
    var crossbow_icon := hud.call("icon_for", "ironCrossbow") as Texture2D
    var first_craft_button := hud.crafting_list.get_child(0) as Button if hud.crafting_list.get_child_count() > 0 else null
    var wood_color_count := icon_distinct_colors(wood_icon)
    var crossbow_color_count := icon_distinct_colors(crossbow_icon)
    add_result(
        "ui_item_icons_polished",
        wood_icon != null
            and crossbow_icon != null
            and wood_icon.get_width() >= 48
            and crossbow_icon.get_width() >= 48
            and wood_color_count >= 8
            and crossbow_color_count >= 6
            and first_craft_button != null
            and first_craft_button.icon != null,
        "wood %dx%d/%d colors, crossbow %dx%d/%d colors, craft icon %s" % [
            wood_icon.get_width() if wood_icon else 0,
            wood_icon.get_height() if wood_icon else 0,
            wood_color_count,
            crossbow_icon.get_width() if crossbow_icon else 0,
            crossbow_icon.get_height() if crossbow_icon else 0,
            crossbow_color_count,
            str(first_craft_button != null and first_craft_button.icon != null)
        ]
    )
    hud.set_inventory_open(false)

    main.call("update_hud")
    add_result(
        "navigation_ui_gated",
        not hud.compass_label.visible and not hud.map_panel.visible,
        "compass %s, map %s" % [str(hud.compass_label.visible), str(hud.map_panel.visible)]
    )

func test_held_item_system() -> void:
    if not main:
        add_result("held_item_present", false, "main missing")
        return
    var inventory_system = main.get("inventory_system")
    var held_item = main.get("held_item")
    var present: bool = held_item != null and camera != null and held_item.get_parent() == camera
    add_result("held_item_present", present, "held item parent camera %s" % str(present))
    if not present:
        return

    var wood_slot := find_inventory_slot(inventory_system, "woodBlock")
    inventory_system.select(0)
    if wood_slot > 0:
        inventory_system.swap_with_active(wood_slot)
    await wait_physics_frames(2)
    var item_matches: bool = String(held_item.get("current_item")) == "woodBlock" and held_item.visible
    add_result("held_item_tracks_hotbar", item_matches, "current %s" % String(held_item.get("current_item")))

    held_item.call("play_use", "strike")
    await wait_physics_frames(1)
    add_result(
        "held_item_use_animation",
        float(held_item.get("use_time")) > 0.0,
        "use time %.2f" % float(held_item.get("use_time"))
    )

    var original_player_position: Vector3 = player.global_position
    held_item.set("use_time", 0.0)
    var local_ground: float = main.call("height_at_world", original_player_position.x, original_player_position.z)
    player.global_position = Vector3(original_player_position.x, local_ground + 8.0, original_player_position.z)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    main.call("reset_break_progress")
    main.call("destroy_target")
    await wait_physics_frames(1)
    var miss_animated: bool = float(held_item.get("use_time")) > 0.0 and String(main.get("break_target_id")) == ""
    player.global_position = original_player_position
    add_result(
        "melee_miss_swing_animation",
        miss_animated,
        "use time %.2f, break target '%s'" % [float(held_item.get("use_time")), String(main.get("break_target_id"))]
    )

    inventory_system.add_item("ironCrossbow", 1)
    var crossbow_slot := find_inventory_slot(inventory_system, "ironCrossbow")
    inventory_system.select(0)
    if crossbow_slot > 0:
        inventory_system.swap_with_active(crossbow_slot)
    await wait_physics_frames(2)
    var held_root: Node = held_item.get_node_or_null("HeldItemRoot")
    var held_meshes := count_mesh_descendants(held_root) if held_root else 0
    add_result(
        "held_item_visual_detail",
        String(held_item.get("current_item")) == "ironCrossbow" and held_meshes >= 4,
        "current %s, meshes %d" % [String(held_item.get("current_item")), held_meshes]
    )

    main.call("clear_dropped_pickups")
    var pickup_stats_before: Dictionary = main.call("pickup_pool_stats")
    var pickup := main.call("spawn_pickup_stack", "nightShard", 1, player.global_position + Vector3(1.0, 1.0, 0.0)) as Node3D
    var pickup_meshes := count_mesh_descendants(pickup) if pickup else 0
    add_result(
        "pickup_item_visual_detail",
        pickup != null and pickup_meshes >= 2,
        "meshes %d" % pickup_meshes
    )
    main.call("clear_dropped_pickups")
    var pickup_stats_after_clear: Dictionary = main.call("pickup_pool_stats")
    var pooled_pickup := main.call("spawn_pickup_stack", "nightShard", 1, player.global_position + Vector3(1.2, 1.0, 0.0)) as Node3D
    var pickup_stats_after_reuse: Dictionary = main.call("pickup_pool_stats")
    add_result(
        "pickup_pool_reuse",
        pooled_pickup != null
            and int(pickup_stats_after_clear.get("pooled", 0)) > int(pickup_stats_before.get("pooled", 0))
            and int(pickup_stats_after_reuse.get("created", 0)) <= int(pickup_stats_after_clear.get("created", 0))
            and int(pickup_stats_after_reuse.get("reused", 0)) > int(pickup_stats_after_clear.get("reused", 0)),
        "pooled %d->%d, created %d->%d, reused %d->%d" % [
            int(pickup_stats_before.get("pooled", 0)),
            int(pickup_stats_after_clear.get("pooled", 0)),
            int(pickup_stats_after_clear.get("created", 0)),
            int(pickup_stats_after_reuse.get("created", 0)),
            int(pickup_stats_after_clear.get("reused", 0)),
            int(pickup_stats_after_reuse.get("reused", 0))
        ]
    )
    main.call("clear_dropped_pickups")
    var restored_wood_slot := find_inventory_slot(inventory_system, "woodBlock")
    inventory_system.select(0)
    if restored_wood_slot > 0:
        inventory_system.swap_with_active(restored_wood_slot)
    await wait_physics_frames(2)

func test_tool_weapon_catalog_parity() -> void:
    if not main or not player:
        add_result("tool_weapon_catalog_parity", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var blocks: Dictionary = main.get("blocks")
    var present: bool = inventory_system != null and crafting_system != null and blocks != null
    if not present:
        add_result("tool_weapon_catalog_parity", false, "inventory/crafting/blocks missing")
        return

    var expected_items := [
        "copperAxe", "copperPickaxe", "copperShovel", "copperSword",
        "ironAxe", "ironPickaxe", "ironShovel", "ironSword",
        "ironCrossbow", "nightBlade"
    ]
    var generated_items := ["copperVein", "ironVein"]
    var missing_items := []
    var missing_recipes := []
    for item_id in expected_items:
        if not ItemCatalogScript.ITEMS.has(item_id):
            missing_items.append(item_id)
        if crafting_system.recipe_for(item_id).is_empty():
            missing_recipes.append(item_id)
    for item_id in generated_items:
        if not ItemCatalogScript.ITEMS.has(item_id):
            missing_items.append(item_id)

    var cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    var anvil = main.call("create_block", cell, "anvil")
    inventory_system.add_item("logs", 8)
    inventory_system.add_item("copperIngot", 8)
    inventory_system.add_item("ironIngot", 8)
    inventory_system.add_item("stoneSword", 1)
    inventory_system.add_item("nightShard", 4)
    inventory_system.add_item("glass", 2)

    var crafted_copper: bool = bool(crafting_system.craft("copperPickaxe"))
    var crafted_crossbow: bool = bool(crafting_system.craft("ironCrossbow"))
    var crafted_night_blade: bool = bool(crafting_system.craft("nightBlade"))
    var crafted_inventory: bool = inventory_system.count("copperPickaxe") > 0 and inventory_system.count("ironCrossbow") > 0 and inventory_system.count("nightBlade") > 0

    if anvil:
        anvil.queue_free()
    if blocks.has(cell):
        blocks.erase(cell)

    add_result(
        "tool_weapon_catalog_parity",
        missing_items.is_empty()
            and missing_recipes.is_empty()
            and crafted_copper
            and crafted_crossbow
            and crafted_night_blade
            and crafted_inventory,
        "missing items %s, recipes %s, crafted copper/crossbow/night %s/%s/%s" % [
            str(missing_items),
            str(missing_recipes),
            str(crafted_copper),
            str(crafted_crossbow),
            str(crafted_night_blade)
        ]
    )
    var vein_inventory_snapshot: Array = inventory_system.snapshot()
    var vein_inventory_size: int = int(inventory_system.size)
    var vein_selected_slot: int = int(inventory_system.selected_slot)
    var copper_pickaxe_slot := find_inventory_slot(inventory_system, "copperPickaxe")
    if copper_pickaxe_slot >= 0:
        inventory_system.swap_with_active(copper_pickaxe_slot)
    var vein_materials_ok := (
        ItemCatalogScript.material_hardness("copperOre") == 7
        and ItemCatalogScript.material_hardness("ironOre") == 10
        and ItemCatalogScript.material_hardness("copperVein") == 8
        and ItemCatalogScript.material_hardness("ironVein") == 12
        and ItemCatalogScript.material_drop("copperVein") == "copperOre"
        and ItemCatalogScript.material_drop("ironVein") == "ironOre"
        and ItemCatalogScript.material_required_tool("copperVein") == "pickaxe"
        and ItemCatalogScript.material_required_tool("ironVein") == "pickaxe"
        and ItemCatalogScript.material_required_tier("copperVein") == 3
        and ItemCatalogScript.material_required_tier("ironVein") == 4
        and String(main.call("unmet_tool_requirement_message", "copperVein")) == ""
        and String(main.call("unmet_tool_requirement_message", "ironVein")) == ""
        and float(main.call("tool_power_for_material", "copperVein")) >= 3.0
    )
    inventory_system.restore({
        "slots": vein_inventory_snapshot,
        "size": vein_inventory_size,
        "selectedSlot": vein_selected_slot
    })
    add_result(
        "ore_vein_catalog_parity",
        vein_materials_ok,
        "hardness ore %d/%d veins %d/%d drops %s/%s" % [
            ItemCatalogScript.material_hardness("copperOre"),
            ItemCatalogScript.material_hardness("ironOre"),
            ItemCatalogScript.material_hardness("copperVein"),
            ItemCatalogScript.material_hardness("ironVein"),
            ItemCatalogScript.material_drop("copperVein"),
            ItemCatalogScript.material_drop("ironVein")
        ]
    )

func test_objective_system() -> void:
    if not main:
        add_result("objective_system_present", false, "main missing")
        return
    var objective_system = main.get("objective_system")
    var hud = main.get("hud")
    var present: bool = objective_system != null and hud != null
    add_result("objective_system_present", present, "objective system + hud present")
    if not present:
        return

    add_result(
        "objective_completion_from_crafting",
        objective_system.completed_count() >= 1 and hud.objective_toast.visible,
        "completed %d, toast %s" % [objective_system.completed_count(), str(hud.objective_toast.visible)]
    )

    var opened: bool = hud.toggle_objectives()
    add_result(
        "objective_list_opens",
        opened and hud.objective_panel.visible and hud.objective_list.get_child_count() == objective_system.all_objectives().size(),
        "opened %s, rows %d" % [str(opened), hud.objective_list.get_child_count()]
    )

    hud.set_inventory_open(true)
    add_result(
        "inventory_hides_objectives",
        hud.is_inventory_open() and not hud.objective_panel.visible,
        "inventory %s, objective panel %s" % [str(hud.is_inventory_open()), str(hud.objective_panel.visible)]
    )
    hud.set_inventory_open(false)

    var expected_ids := [
        "woodenPickaxe",
        "stonePickaxe",
        "mineCopper",
        "smeltCopper",
        "craftCopperPickaxe",
        "mineIron",
        "smeltIron",
        "craftIronPickaxe",
        "spikeTrap",
        "hunt",
        "fish",
        "ranged",
        "bed",
        "shelter",
        "torch",
        "mine",
        "anvil",
        "copperGear",
        "pack",
        "cookedFood",
        "nightShard",
        "wardTonic",
        "enemyCamp"
    ]
    var present_ids := {}
    for objective in objective_system.all_objectives():
        present_ids[String(objective.get("id", ""))] = true
    var missing_ids := []
    for objective_id in expected_ids:
        if not present_ids.has(objective_id):
            missing_ids.append(objective_id)
    var parity_state := {
        "totals": {
            "rawMeat": 1,
            "rawFish": 1,
            "hunterBow": 1,
            "torch": 1,
            "stonePickaxe": 1,
            "copperOre": 1,
            "copperIngot": 2,
            "copperPickaxe": 1,
            "ironOre": 1,
            "ironIngot": 1,
            "ironPickaxe": 1,
            "cookedBerries": 1,
            "nightShard": 2,
            "wardTonic": 1
        },
        "structureCounts": {
            "spikeTrap": 1,
            "bed": 1,
            "anvil": 1
        },
        "equipment": {},
        "generatedTierCounts": { "mine": 1 },
        "hostiles": { "defeated": 3, "defeatedVariants": {} },
        "inventorySize": 32,
        "level": 3,
        "discoveredBiomes": 4,
        "discoveredMines": 1,
        "discoveredRuins": 0,
        "discoveredShrines": 0,
        "discoveredCamps": 1,
        "shelterComfort": 0.75,
        "beaconRaidStage": 0,
        "sanctuaryEstablished": false
    }
    var incomplete_ids := []
    for objective_id in expected_ids:
        if not bool(objective_system.is_complete(objective_id, parity_state)):
            incomplete_ids.append(objective_id)
    add_result(
        "objective_browser_chain_parity",
        missing_ids.is_empty() and incomplete_ids.is_empty(),
        "missing %s, incomplete %s, total %d" % [str(missing_ids), str(incomplete_ids), objective_system.all_objectives().size()]
    )

func test_progression_system() -> void:
    if not main:
        add_result("progression_system_present", false, "main missing")
        return
    var progression_system = main.get("progression_system")
    var survival_system = main.get("survival_system")
    var hud = main.get("hud")
    var present: bool = progression_system != null and survival_system != null and hud != null
    add_result("progression_system_present", present, "progression + survival + hud present")
    if not present:
        return

    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    var awarded: bool = bool(main.call("award_progression", "playtest progress", 85))
    var state: Dictionary = progression_system.state()
    var leveled: bool = awarded and int(state.get("level", 1)) == 2 and int(state.get("xp", 0)) == 5
    var hud_updated: bool = hud.level_label.text.find("Lvl 2") >= 0 and abs(float(hud.xp_bar.value) - 5.0) < 0.01
    var survival_bonus: bool = abs(float(survival_system.call("max_health")) - 105.0) < 0.01 and abs(float(survival_system.call("max_stamina")) - 104.0) < 0.01
    add_result(
        "progression_awards_level_bonus_hud",
        leveled and hud_updated and survival_bonus,
        "level %d, xp %d, hud '%s', max hp %.1f" % [
            int(state.get("level", 1)),
            int(state.get("xp", 0)),
            hud.level_label.text,
            float(survival_system.call("max_health"))
        ]
    )
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })

func test_equipment_system() -> void:
    if not main:
        add_result("equipment_system_present", false, "main missing")
        return
    var equipment_system = main.get("equipment_system")
    var inventory_system = main.get("inventory_system")
    var survival_system = main.get("survival_system")
    var hud = main.get("hud")
    var present: bool = equipment_system != null and inventory_system != null and survival_system != null and hud != null
    add_result("equipment_system_present", present, "equipment + inventory + survival + hud present")
    if not present:
        return

    equipment_system.reset()
    inventory_system.add_item("stoneArmor", 1)
    inventory_system.add_item("trailCharm", 1)

    var armor_slot := find_inventory_slot(inventory_system, "stoneArmor")
    if armor_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(armor_slot)
    var armor_equipped: bool = bool(main.call("try_use_active_consumable"))
    var equipped_armor := String(equipment_system.equipped_item("body"))

    var charm_slot := find_inventory_slot(inventory_system, "trailCharm")
    if charm_slot >= 0:
        inventory_system.select(1)
        inventory_system.swap_with_active(charm_slot)
    var charm_equipped: bool = bool(main.call("try_use_active_consumable"))
    var equipped_charm := String(equipment_system.equipped_item("accessory"))

    survival_system.health = survival_system.max_health()
    var block_health_before: float = float(survival_system.health)
    survival_system.apply_damage(10.0, "equipment test", "hostile")
    hud.render()
    var damage_reduced: bool = float(survival_system.health) > 92.0 and float(survival_system.health) < 94.0
    var bonus_applied: bool = abs(float(survival_system.call("max_stamina")) - 115.0) < 0.01 and abs(float(survival_system.call("max_hunger")) - 110.0) < 0.01
    var hud_updated: bool = hud.equipment_readout.text.find("Stone Guard") >= 0 and hud.equipment_readout.text.find("Trail Charm") >= 0
    add_result(
        "equipment_slots_bonuses_damage_hud",
        armor_equipped and charm_equipped and equipped_armor == "stoneArmor" and equipped_charm == "trailCharm" and damage_reduced and bonus_applied and hud_updated,
        "armor %s, charm %s, health %.1f, max sta %.1f, hud '%s'" % [
            equipped_armor,
            equipped_charm,
            float(survival_system.health),
            float(survival_system.call("max_stamina")),
            hud.equipment_readout.text
        ]
    )
    equipment_system.reset()

func test_navigation_map_system() -> void:
    if not main or not player:
        add_result("navigation_map_system", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    if inventory_system == null or hud == null:
        add_result("navigation_map_system", false, "inventory or hud missing")
        return
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var nav_cell := Vector2i(roundi(player.global_position.x / CELL) + 72, roundi(player.global_position.z / CELL) + 72)
    reset_player_on_flat_patch(nav_cell)
    clear_blocks_near_cell(nav_cell, 12)
    main.call("update_chunks", true)
    inventory_system.add_item("compass", 1)
    inventory_system.add_item("surveyLens", 1)
    var marker_cell := Vector3i(roundi(player.global_position.x / CELL) + 3, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL))
    clear_blocks_near_cell(Vector2i(marker_cell.x, marker_cell.z), 2)
    main.call("create_block", marker_cell, "workbench")
    main.call("update_hud")
    var compass_visible: bool = hud.compass_label.visible and hud.compass_label.text.length() >= 4
    var waypoint_visible: bool = hud.compass_waypoint_label != null and hud.compass_waypoint_label.visible and hud.compass_waypoint_label.text.find("Workbench") >= 0
    var map_visible: bool = hud.map_panel.visible
    var marker_visible: bool = hud.mini_map != null and hud.mini_map.points.size() > 0
    var terrain_visible: bool = hud.mini_map != null and hud.mini_map.terrain_samples.size() > 0 and hud.mini_map.sample_count > 0
    var marker_summary: bool = hud.map_info_label != null and hud.map_info_label.text.find("Workbench") >= 0
    add_result(
        "navigation_map_system",
        compass_visible and waypoint_visible and map_visible and marker_visible and terrain_visible and marker_summary,
        "compass '%s' visible %s, waypoint '%s', map %s, markers %d, terrain %d, summary '%s'" % [
            hud.compass_label.text,
            str(compass_visible),
            hud.compass_waypoint_label.text if hud.compass_waypoint_label != null else "",
            str(map_visible),
            hud.mini_map.points.size() if hud.mini_map != null else 0,
            hud.mini_map.terrain_samples.size() if hud.mini_map != null else 0,
            hud.map_info_label.text if hud.map_info_label != null else ""
        ]
    )
    var collapsed: bool = hud.toggle_map()
    main.call("update_hud")
    var collapsed_ok: bool = collapsed and hud.is_map_collapsed() and hud.map_panel.visible and hud.mini_map != null and not hud.mini_map.visible and hud.map_info_label.text.find("hidden") >= 0
    var expanded: bool = not hud.toggle_map()
    main.call("update_hud")
    var expanded_ok: bool = expanded and not hud.is_map_collapsed() and hud.map_panel.visible and hud.mini_map != null and hud.mini_map.visible
    add_result(
        "map_toggle_collapse",
        collapsed_ok and expanded_ok,
        "collapsed %s/%s expanded %s/%s info '%s'" % [str(collapsed), str(collapsed_ok), str(expanded), str(expanded_ok), hud.map_info_label.text]
    )
    var blocks := get_blocks()
    if blocks.has(marker_cell):
        var marker := blocks[marker_cell] as Node
        if marker:
            marker.queue_free()
        blocks.erase(marker_cell)
    player.global_position = original_position
    player.velocity = original_velocity
    main.call("update_chunks", true)

func test_contract_system() -> void:
    if not main or not player:
        add_result("contract_system_present", false, "main or player missing")
        return
    var contract_system = main.get("contract_system")
    var inventory_system = main.get("inventory_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = contract_system != null and inventory_system != null and progression_system != null and hud != null
    add_result("contract_system_present", present, "contracts + inventory + progression + hud present")
    if not present:
        return

    var original_position: Vector3 = player.global_position
    contract_system.reset()
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    discovered_biomes.clear()
    discovered_towns.clear()
    var locked_open: bool = hud.toggle_contracts()
    var town: Dictionary = main.call("town_region", 1, 0)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    player.global_position = Vector3(center_x * CELL, float(town.get("level", 16.0)), center_z * CELL)
    main.call("update_hud")
    var unlocked: bool = bool(contract_system.state().get("townUnlocked", false))
    var opened: bool = hud.toggle_contracts()
    var xp_before: int = int(progression_system.total_xp)
    var stone_blocks_before: int = inventory_system.count("stoneBlock")
    inventory_system.add_item("stones", max(0, 18 - inventory_system.count("stones")))
    main.call("update_hud")
    var completed_count: int = int(contract_system.state().get("completed", 0))
    var rewarded: bool = int(progression_system.total_xp) > xp_before and inventory_system.count("stoneBlock") >= stone_blocks_before + 4
    add_result(
        "contract_unlock_complete_reward",
        not locked_open and unlocked and opened and completed_count >= 1 and rewarded and hud.contract_panel.visible,
        "locked open %s, unlocked %s, opened %s, completed %d, xp %d->%d, stoneBlock %d->%d" % [
            str(locked_open),
            str(unlocked),
            str(opened),
            completed_count,
            xp_before,
            int(progression_system.total_xp),
            stone_blocks_before,
            inventory_system.count("stoneBlock")
        ]
    )
    var base_contract_state := {
        "discoveredTowns": 1,
        "discoveredBiomes": 5,
        "totals": {},
        "structureCounts": {},
        "equipment": {},
        "hostiles": {}
    }
    var copper_tool_state := base_contract_state.duplicate(true)
    copper_tool_state["totals"] = { "copperPickaxe": 1 }
    var iron_tool_state := base_contract_state.duplicate(true)
    iron_tool_state["totals"] = { "ironPickaxe": 1 }
    var copper_sample_state := base_contract_state.duplicate(true)
    copper_sample_state["totals"] = { "copperOre": 4 }
    var smelter_state := base_contract_state.duplicate(true)
    smelter_state["totals"] = { "copperIngot": 2 }
    var iron_sample_state := base_contract_state.duplicate(true)
    iron_sample_state["totals"] = { "ironOre": 2 }
    var camp_clear_state := base_contract_state.duplicate(true)
    camp_clear_state["discoveredCamps"] = 1
    var contract_rule_parity := (
        bool(contract_system.is_contract_complete("copperCommission", copper_tool_state))
        and bool(contract_system.is_contract_complete("ironSupply", iron_tool_state))
        and bool(contract_system.is_contract_complete("copperSample", copper_sample_state))
        and bool(contract_system.is_contract_complete("smelterRun", smelter_state))
        and bool(contract_system.is_contract_complete("ironSample", iron_sample_state))
        and bool(contract_system.is_contract_complete("campClear", camp_clear_state))
    )
    add_result(
        "contract_gear_rule_parity",
        contract_rule_parity,
        "copper pickaxe %s, iron pickaxe %s, samples %s/%s/%s, camp %s" % [
            str(contract_system.is_contract_complete("copperCommission", copper_tool_state)),
            str(contract_system.is_contract_complete("ironSupply", iron_tool_state)),
            str(contract_system.is_contract_complete("copperSample", copper_sample_state)),
            str(contract_system.is_contract_complete("smelterRun", smelter_state)),
            str(contract_system.is_contract_complete("ironSample", iron_sample_state)),
            str(contract_system.is_contract_complete("campClear", camp_clear_state))
        ]
    )
    contract_system.toggle_menu(false)
    player.global_position = original_position
    discovered_biomes.clear()
    discovered_towns.clear()

func test_audio_effects_system() -> void:
    if not main:
        add_result("audio_effects_system_present", false, "main missing")
        return
    var audio_effects = main.get("audio_effects")
    var present: bool = audio_effects != null
    add_result("audio_effects_system_present", present, "audio/effects node present")
    if not present:
        return

    var start_stats: Dictionary = audio_effects.stats()
    audio_effects.play("craft")
    audio_effects.burst(player.global_position + Vector3(0.0, 1.0, 0.0) if player else Vector3.ZERO, Color(0.9, 0.7, 0.35), 3)
    await get_tree().process_frame
    var stats: Dictionary = audio_effects.stats()
    add_result(
        "audio_effects_play_and_burst",
        String(stats.get("lastPlayed", "")) == "craft"
            and int(stats.get("playCount", 0)) > int(start_stats.get("playCount", 0))
            and int(stats.get("visualEffects", 0)) >= 3,
        "last %s, plays %d->%d, effects %d" % [
            String(stats.get("lastPlayed", "")),
            int(start_stats.get("playCount", 0)),
            int(stats.get("playCount", 0)),
            int(stats.get("visualEffects", 0))
        ]
    )
    audio_effects.update_music({ "track": "tutorialTownDay", "volumeDb": -14.0 })
    var music_stats: Dictionary = audio_effects.stats()
    add_result(
        "tutorial_town_day_bgm",
        bool(music_stats.get("hasTutorialTownDayBgm", false))
            and float(music_stats.get("tutorialTownDayBgmLength", 0.0)) > 20.0
            and String(music_stats.get("currentMusic", "")) == "tutorialTownDay"
            and bool(music_stats.get("musicPlaying", false)),
        "loaded %s, length %.2f, current %s, playing %s" % [
            str(bool(music_stats.get("hasTutorialTownDayBgm", false))),
            float(music_stats.get("tutorialTownDayBgmLength", 0.0)),
            String(music_stats.get("currentMusic", "")),
            str(bool(music_stats.get("musicPlaying", false)))
        ]
    )
    audio_effects.update_music({ "track": "" })
    var created_after_first: int = int(stats.get("effectNodesCreated", 0))
    var reused_after_first: int = int(stats.get("effectNodesReused", 0))
    for i in range(70):
        await get_tree().process_frame
    var pooled_stats: Dictionary = audio_effects.stats()
    audio_effects.burst(player.global_position + Vector3(0.0, 1.0, 0.0) if player else Vector3.ZERO, Color(0.4, 0.8, 1.0), 2)
    await get_tree().process_frame
    var reused_stats: Dictionary = audio_effects.stats()
    add_result(
        "audio_effect_pool_reuse",
        int(pooled_stats.get("effectPool", 0)) >= 3
            and int(reused_stats.get("effectNodesReused", 0)) > reused_after_first
            and int(reused_stats.get("effectNodesCreated", 0)) <= created_after_first,
        "pool %d, created %d->%d, reused %d->%d" % [
            int(pooled_stats.get("effectPool", 0)),
            created_after_first,
            int(reused_stats.get("effectNodesCreated", 0)),
            reused_after_first,
            int(reused_stats.get("effectNodesReused", 0))
        ]
    )

func test_teleport_system() -> void:
    if not main or not player:
        add_result("teleport_system", false, "main or player missing")
        return
    var hud = main.get("hud")
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var panel_open := false
    if hud:
        hud.set_teleport_open(true)
        panel_open = hud.is_teleport_open() and hud.teleport_panel.visible
    var teleported_xz: bool = bool(main.call("teleport_to", "64 -32"))
    await wait_physics_frames(4)
    var terrain_y: float = main.call("height_at_world", 64.0, -32.0)
    var horizontal_ok := Vector2(player.global_position.x - 64.0, player.global_position.z + 32.0).length() < 0.35
    var safe_y := player.global_position.y >= maxf(terrain_y, WATER_LEVEL) - 0.1
    var teleported_xyz: bool = bool(main.call("teleport_to", "12 40 -18"))
    await wait_physics_frames(2)
    var exact_xyz := player.global_position.distance_to(Vector3(12.0, 40.0, -18.0)) < 0.35
    var rejected_bad: bool = not bool(main.call("teleport_to", "nowhere"))
    if hud:
        hud.set_teleport_open(false)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)
    main.call("update_chunks", true)
    add_result(
        "teleport_system",
        panel_open and teleported_xz and horizontal_ok and safe_y and teleported_xyz and exact_xyz and rejected_bad,
        "panel %s, xz %s/%s, xyz %s/%s, bad rejected %s" % [
            str(panel_open),
            str(teleported_xz),
            str(horizontal_ok),
            str(teleported_xyz),
            str(exact_xyz),
            str(rejected_bad)
        ]
    )

func test_settings_playtest_debug() -> void:
    if not main or not player or not camera:
        add_result("settings_playtest_debug", false, "main/player/camera missing")
        return
    var hud = main.get("hud")
    var weather_system = main.get("weather_system")
    var held_item = main.get("held_item")
    if hud == null or weather_system == null:
        add_result("settings_playtest_debug", false, "hud or weather missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_render_distance: int = int(main.get("render_distance"))
    var original_fov: float = camera.fov

    main.call("apply_runtime_setting", "mouseSensitivity", 1.45)
    main.call("apply_runtime_setting", "invertY", true)
    main.call("apply_runtime_setting", "lookSmoothing", 0.36)
    main.call("apply_runtime_setting", "fov", 84.0)
    main.call("apply_runtime_setting", "headBob", false)
    main.call("apply_runtime_setting", "handSway", false)
    main.call("apply_runtime_setting", "weatherParticles", 0.25)
    main.call("apply_runtime_setting", "shadows", false)
    main.call("apply_runtime_setting", "renderDistance", 2)
    await wait_physics_frames(2)

    var chunks := get_chunks()
    var settings_applied: bool = (
        abs(camera.fov - 84.0) < 0.1
        and float(player.get("mouse_sensitivity")) > 0.003
        and bool(player.get("invert_y"))
        and float(player.get("look_smoothing")) > 0.30
        and not bool(player.get("head_bob_enabled"))
        and (held_item == null or not bool(held_item.get("sway_enabled")))
        and abs(float(weather_system.snapshot().get("particleQuality", 1.0)) - 0.25) < 0.01
        and not bool(main.get("shadows_enabled"))
        and int(main.get("render_distance")) == 2
        and chunks.size() == 25
    )

    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
    hud.set_settings_open(true)
    var settings_blocks_mouse: bool = not bool(main.call("should_accept_mouse_look"))
    hud.set_settings_open(false)
    hud.set_playtest_open(true)
    var playtest_blocks_mouse: bool = not bool(main.call("should_accept_mouse_look"))
    var playtest_specs: Array = main.call("playtest_case_specs")
    hud.set_playtest_route("camp")
    var route_text: String = hud.playtest_route_label.text if hud.playtest_route_label else ""
    var route_overlay_ok: bool = route_text.find("Checks:") >= 0 and route_text.find("hostile camps") >= 0
    var playtest_case_buttons: bool = hud.playtest_list != null and hud.playtest_list.get_child_count() >= 8 and hud.playtest_status != null and playtest_specs.size() >= 8 and route_overlay_ok
    hud.set_playtest_open(false)
    hud.set_performance_open(true)
    main.call("update_performance_overlay", 1.0)
    var performance_state: Dictionary = main.call("debug_performance_state")
    var performance_text: String = hud.performance_label.text
    var performance_visible: bool = (
        hud.performance_label.visible
        and performance_text.find("FPS") >= 0
        and performance_text.find("frame") >= 0
        and performance_text.find("chunk cache") >= 0
        and performance_state.has("frameMs")
        and performance_state.has("hostilesMs")
        and performance_state.has("hudRefresh")
        and performance_state.has("chunkCache")
    )
    var town_target: Dictionary = main.call("playtest_case_target", "town")
    var forest_target: Dictionary = main.call("playtest_case_target", "forest")
    var targets_available: bool = not town_target.is_empty() and not forest_target.is_empty()

    add_result(
        "settings_runtime_controls",
        settings_applied,
        "fov %.1f, sens %.4f, particles %.2f, render %d, chunks %d" % [
            camera.fov,
            float(player.get("mouse_sensitivity")),
            float(weather_system.snapshot().get("particleQuality", 1.0)),
            int(main.get("render_distance")),
            chunks.size()
        ]
    )
    add_result(
        "performance_playtest_debug_hud",
        settings_blocks_mouse and playtest_blocks_mouse and playtest_case_buttons and performance_visible and targets_available,
        "blocks mouse %s/%s, playtest buttons %s, route %s, perf %s, targets %s/%s, frame %.2f, hostiles %.2f, hud refresh keys %d" % [
            str(settings_blocks_mouse),
            str(playtest_blocks_mouse),
            str(playtest_case_buttons),
            str(route_overlay_ok),
            str(performance_visible),
            str(not town_target.is_empty()),
            str(not forest_target.is_empty()),
            float(performance_state.get("frameMs", 0.0)),
            float(performance_state.get("hostilesMs", 0.0)),
            (performance_state.get("hudRefresh", {}) as Dictionary).size()
        ]
    )

    hud.set_performance_open(false)
    hud.set_settings_open(false)
    hud.set_playtest_open(false)
    main.call("apply_runtime_setting", "mouseSensitivity", 1.0)
    main.call("apply_runtime_setting", "invertY", false)
    main.call("apply_runtime_setting", "lookSmoothing", 0.0)
    main.call("apply_runtime_setting", "fov", original_fov)
    main.call("apply_runtime_setting", "headBob", true)
    main.call("apply_runtime_setting", "handSway", true)
    main.call("apply_runtime_setting", "weatherParticles", 1.0)
    main.call("apply_runtime_setting", "shadows", true)
    main.call("apply_runtime_setting", "renderDistance", original_render_distance)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)
    main.call("update_chunks", true)
    await wait_physics_frames(2)

func test_hud_refresh_throttling() -> void:
    if not main:
        add_result("hud_refresh_throttling", false, "main missing")
        return
    var hud = main.get("hud")
    if hud == null:
        add_result("hud_refresh_throttling", false, "hud missing")
        return

    var original_interval: float = float(main.get("hud_refresh_interval"))
    var original_elapsed: float = float(main.get("hud_refresh_elapsed"))
    main.set("hud_refresh_interval", 0.75)
    main.set("hud_refresh_elapsed", 0.0)
    var before: Dictionary = main.call("hud_refresh_stats")
    for i in range(3):
        main.call("update_hud_frame", 0.1)
    var after_wait: Dictionary = main.call("hud_refresh_stats")
    var skipped_delta: int = int(after_wait.get("skipped", 0)) - int(before.get("skipped", 0))
    var throttled_delta: int = int(after_wait.get("throttled", 0)) - int(before.get("throttled", 0))

    main.call("update_hud", "Immediate HUD Test")
    var after_message: Dictionary = main.call("hud_refresh_stats")
    var message_delta: int = int(after_message.get("messages", 0)) - int(after_wait.get("messages", 0))
    var message_visible: bool = hud.target_label.text.find("Immediate HUD Test") >= 0

    main.set("hud_refresh_interval", 0.0)
    main.call("update_hud_frame", 0.016)
    var after_zero_interval: Dictionary = main.call("hud_refresh_stats")
    var immediate_throttled_delta: int = int(after_zero_interval.get("throttled", 0)) - int(after_message.get("throttled", 0))

    main.set("hud_refresh_interval", original_interval)
    main.set("hud_refresh_elapsed", original_elapsed)
    await get_tree().process_frame

    add_result(
        "hud_refresh_throttling",
        skipped_delta > 0 and throttled_delta == 0 and message_delta == 1 and message_visible and immediate_throttled_delta > 0,
        "skipped %d, throttled before interval %d, messages %d, visible %s, zero interval refreshes %d" % [
            skipped_delta,
            throttled_delta,
            message_delta,
            str(message_visible),
            immediate_throttled_delta
        ]
    )

func test_manual_playtest_cases() -> void:
    if not main or not player:
        add_result("manual_playtest_cases", false, "main or player missing")
        return
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var case_ids := []
    for spec_value in main.call("playtest_case_specs"):
        if spec_value is Dictionary:
            case_ids.append(String((spec_value as Dictionary).get("id", "")))
    var missing_targets := []
    for case_id_variant in case_ids:
        var case_id := String(case_id_variant)
        var target: Dictionary = main.call("playtest_case_target", case_id)
        if target.is_empty():
            missing_targets.append(case_id)

    var expectations := [
        { "id": "mine", "props": 6, "blocks": 1, "hostiles": 0 },
        { "id": "camp", "props": 0, "blocks": 18, "hostiles": 3 },
        { "id": "forest", "props": 10, "blocks": 0, "hostiles": 0 },
        { "id": "mountain", "props": 8, "blocks": 0, "hostiles": 0 },
        { "id": "water", "props": 3, "blocks": 4, "hostiles": 0 },
        { "id": "combat", "props": 0, "blocks": 3, "hostiles": 4 },
        { "id": "collapse", "props": 0, "blocks": 28, "hostiles": 0 }
    ]
    var setup_failures := []
    var setup_details := []
    for expectation in expectations:
        var case_id := String(expectation.get("id", ""))
        var ran: bool = bool(main.call("run_playtest_case", case_id))
        await wait_physics_frames(2)
        var counts: Dictionary = main.call("playtest_case_counts")
        var props_ok: bool = int(counts.get("props", 0)) >= int(expectation.get("props", 0))
        var blocks_ok: bool = int(counts.get("blocks", 0)) >= int(expectation.get("blocks", 0))
        var hostiles_ok: bool = int(counts.get("hostiles", 0)) >= int(expectation.get("hostiles", 0))
        if not (ran and props_ok and blocks_ok and hostiles_ok):
            setup_failures.append(case_id)
        setup_details.append("%s p/b/h %d/%d/%d" % [
            case_id,
            int(counts.get("props", 0)),
            int(counts.get("blocks", 0)),
            int(counts.get("hostiles", 0))
        ])

    main.call("cleanup_playtest_case_assets")
    var cleaned_counts: Dictionary = main.call("playtest_case_counts")
    var cleanup_ok: bool = int(cleaned_counts.get("props", 0)) == 0 and int(cleaned_counts.get("blocks", 0)) == 0 and int(cleaned_counts.get("hostiles", 0)) == 0
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)
    main.call("update_chunks", true)
    await wait_physics_frames(2)

    add_result(
        "manual_playtest_cases",
        missing_targets.is_empty() and setup_failures.is_empty() and cleanup_ok,
        "missing %s, setup failures %s, %s, cleanup %s" % [
            str(missing_targets),
            str(setup_failures),
            ", ".join(setup_details),
            str(cleanup_ok)
        ]
    )

func test_utility_blocks() -> void:
    if not main or not player:
        add_result("utility_system_present", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var utility_system = main.get("utility_system")
    var hud = main.get("hud")
    var present: bool = inventory_system != null and utility_system != null and hud != null
    add_result("utility_system_present", present, "utility system + hud present")
    if not present:
        return

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)

    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 10, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 2)
    var chest_cell := base_cell
    var furnace_cell := base_cell + Vector3i(2, 0, 0)
    var bed_cell := base_cell + Vector3i(4, 0, 0)
    var anvil_cell := base_cell + Vector3i(6, 0, 0)
    var campfire_cell := base_cell + Vector3i(8, 0, 0)
    var torch_cell := base_cell + Vector3i(10, 0, 0)
    var spike_cell := base_cell + Vector3i(12, 0, 0)
    var ward_cell := base_cell + Vector3i(14, 0, 0)
    var beacon_cell := base_cell + Vector3i(16, 0, 0)
    var rift_cell := base_cell + Vector3i(18, 0, 0)
    var utility_cells := [chest_cell, furnace_cell, bed_cell, anvil_cell, campfire_cell, torch_cell, spike_cell, ward_cell, beacon_cell, rift_cell]
    var preexisting_blocks := get_blocks()
    for cell in utility_cells:
        if preexisting_blocks.has(cell):
            var old_body := preexisting_blocks[cell] as Node
            if old_body:
                old_body.queue_free()
            preexisting_blocks.erase(cell)
    var chest := main.call("create_block", chest_cell, "chest") as StaticBody3D
    var furnace := main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    var visual_blocks := {
        "chest": chest,
        "furnace": furnace,
        "bed": main.call("create_block", bed_cell, "bed") as StaticBody3D,
        "anvil": main.call("create_block", anvil_cell, "anvil") as StaticBody3D,
        "campfire": main.call("create_block", campfire_cell, "campfire") as StaticBody3D,
        "torch": main.call("create_block", torch_cell, "torch") as StaticBody3D,
        "spikeTrap": main.call("create_block", spike_cell, "spikeTrap") as StaticBody3D,
        "wardLantern": main.call("create_block", ward_cell, "wardLantern") as StaticBody3D,
        "sanctuaryBeacon": main.call("create_block", beacon_cell, "sanctuaryBeacon") as StaticBody3D,
        "riftAnchor": main.call("create_block", rift_cell, "riftAnchor") as StaticBody3D
    }
    if chest == null or furnace == null:
        add_result("utility_blocks_created", false, "failed to create chest/furnace")
        inventory_system.restore(original_inventory)
        return

    var visual_details := []
    var visual_failures := []
    for item_id in visual_blocks.keys():
        var visual_body := visual_blocks[item_id] as Node
        var mesh_count := count_mesh_descendants(visual_body)
        visual_details.append("%s:%d" % [String(item_id), mesh_count])
        if mesh_count < 3:
            visual_failures.append(item_id)
    add_result(
        "placed_utility_visual_meshes",
        visual_failures.is_empty(),
        ", ".join(visual_details)
    )

    utility_system.close()
    var visual_cleanup_blocks := get_blocks()
    for cell in utility_cells:
        if visual_cleanup_blocks.has(cell):
            var visual_body_to_clear := visual_cleanup_blocks[cell] as Node
            if visual_body_to_clear:
                visual_body_to_clear.queue_free()
            visual_cleanup_blocks.erase(cell)

    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)
    chest_cell = base_cell + Vector3i(0, 0, 4)
    furnace_cell = base_cell + Vector3i(2, 0, 4)
    utility_cells = [chest_cell, furnace_cell]
    preexisting_blocks = get_blocks()
    for cell in utility_cells:
        if preexisting_blocks.has(cell):
            var behavior_old_body := preexisting_blocks[cell] as Node
            if behavior_old_body:
                behavior_old_body.queue_free()
            preexisting_blocks.erase(cell)
    chest = main.call("create_block", chest_cell, "chest") as StaticBody3D
    furnace = main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    if chest == null or furnace == null:
        add_result("utility_blocks_created", false, "failed to create fresh chest/furnace")
        inventory_system.restore(original_inventory)
        return

    set_active_inventory_item(inventory_system, "logs")
    var logs_before: int = inventory_system.count("logs")
    utility_system.open_block(chest)
    var chest_open: bool = hud.is_utility_open() and hud.utility_grid.get_child_count() == 12
    utility_system.transfer_chest_slot(0)
    var chest_slots_value: Variant = chest.get_meta("storage_slots")
    var chest_slots: Array = chest_slots_value if chest_slots_value is Array else []
    var chest_stored_logs: bool = chest_slots.size() > 0 and String(chest_slots[0].get("item", "")) == "logs" and inventory_system.count("logs") < logs_before
    inventory_system.add_item("stones", 1)
    set_active_inventory_item(inventory_system, "stones")
    utility_system.transfer_chest_slot(0)
    var chest_withdrew_logs: bool = inventory_system.count("logs") == logs_before and chest_slots.size() > 0 and String(chest_slots[0].get("item", "")) == ""
    var chest_preserved_active: bool = String(inventory_system.active_stack().get("item", "")) == "stones"
    add_result(
        "chest_storage_transfer",
        chest_open and chest_stored_logs and chest_withdrew_logs and chest_preserved_active,
        "open %s, stored %s, withdrew %s, active %s" % [
            str(chest_open),
            str(chest_stored_logs),
            str(chest_withdrew_logs),
            String(inventory_system.active_stack().get("item", ""))
        ]
    )
    inventory_system.clear()
    inventory_system.select(0)
    chest_slots = utility_system.ensure_chest(chest)
    chest_slots[0] = { "item": "berries", "count": 2 }
    utility_system.set_chest_slots(chest, chest_slots)
    utility_system.transfer_chest_slot(0)
    var berry_slot := find_inventory_slot(inventory_system, "berries")
    var chest_withdraw_avoids_active: bool = (
        berry_slot > 0
        and String(inventory_system.active_stack().get("item", "")) == ""
        and inventory_system.count("berries") == 2
    )
    add_result(
        "chest_withdraw_avoids_active_slot",
        chest_withdraw_avoids_active,
        "berry slot %d, active %s, berries %d" % [
            berry_slot,
            String(inventory_system.active_stack().get("item", "")),
            inventory_system.count("berries")
        ]
    )

    inventory_system.clear()
    inventory_system.add_item("logs", 4)
    inventory_system.add_item("sand", 3)
    utility_system.open_block(furnace)
    set_active_inventory_item(inventory_system, "sand")
    var sand_before: int = inventory_system.count("sand")
    utility_system.transfer_furnace_slot("input")
    set_active_inventory_item(inventory_system, "logs")
    logs_before = inventory_system.count("logs")
    utility_system.transfer_furnace_slot("fuel")
    var glass_before: int = inventory_system.count("glass")
    var started: bool = utility_system.start_processing()
    utility_system.update(5.0)
    inventory_system.select(3)
    utility_system.transfer_furnace_slot("output")
    var made_glass: bool = started and inventory_system.count("glass") == glass_before + 1
    inventory_system.select(4)
    utility_system.transfer_furnace_slot("input")
    inventory_system.select(5)
    utility_system.transfer_furnace_slot("fuel")
    var restored_inputs: bool = inventory_system.count("sand") == sand_before - 1 and inventory_system.count("logs") == logs_before - 1
    add_result(
        "furnace_smelting_transfer",
        made_glass and restored_inputs and hud.is_utility_open(),
        "glass %d->%d, sand %d, logs %d" % [glass_before, inventory_system.count("glass"), inventory_system.count("sand"), inventory_system.count("logs")]
    )

    utility_system.close()
    var blocks := get_blocks()
    for cell in utility_cells:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)

func test_player_placement_system() -> void:
    if not main or not player or not camera:
        add_result("player_placement_system", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var present: bool = inventory_system != null
    if not present:
        add_result("player_placement_system", false, "inventory missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_rotation: Vector3 = player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }

    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 18, roundi(player.global_position.z / CELL) + 18)
    reset_player_on_flat_patch(base_cell)
    clear_blocks_near_cell(base_cell, 14)
    main.call("update_chunks", true)
    await wait_physics_frames(8)

    inventory_system.clear()
    inventory_system.add_item("workbench", 3)
    inventory_system.add_item("woodBlock", 1)
    inventory_system.add_item("cobblestonePath", 1)

    var placed_keys: Array[Vector3i] = []
    var placement_target := base_cell + Vector2i(0, -1)
    var far_placement_target := base_cell + Vector2i(0, -4)
    var far_result: Dictionary = await place_item_far_from_player(inventory_system, "workbench", far_placement_target)
    var workbench_result: Dictionary = await place_item_via_player(inventory_system, "workbench", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()
    var wood_result: Dictionary = await place_item_via_player(inventory_system, "woodBlock", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()
    var path_result: Dictionary = await place_item_via_player(inventory_system, "cobblestonePath", placement_target, placed_keys)
    cleanup_test_blocks(placed_keys)
    placed_keys.clear()

    var slope_restore := make_relative_slope_patch(placement_target)
    main.call("rebuild_chunks_around_cell", placement_target)
    await wait_physics_frames(6)
    var slope_result: Dictionary = await place_item_via_player(inventory_system, "workbench", placement_target, placed_keys)

    var workbench_table := int(workbench_result.get("meshCount", 0)) >= 8
    var workbench_ok := bool(workbench_result.get("placed", false)) and bool(workbench_result.get("consumed", false)) and bool(workbench_result.get("grounded", false)) and workbench_table
    var wood_ok := bool(wood_result.get("placed", false)) and bool(wood_result.get("consumed", false)) and bool(wood_result.get("grounded", false))
    var path_ok := bool(path_result.get("placed", false)) and bool(path_result.get("consumed", false)) and bool(path_result.get("grounded", false))
    var slope_ok := bool(slope_result.get("placed", false)) and bool(slope_result.get("consumed", false)) and bool(slope_result.get("grounded", false))
    var far_blocked := not bool(far_result.get("placed", true)) and not bool(far_result.get("consumed", true))
    add_result(
        "player_placement_system",
        workbench_ok and wood_ok and path_ok and slope_ok and far_blocked,
        "far %s, workbench %s, wood %s, path %s, slope %s" % [
            str(far_result),
            str(workbench_result),
            str(wood_result),
            str(path_result),
            str(slope_result)
        ]
    )

    cleanup_test_blocks(placed_keys)
    restore_height_patch(slope_restore)
    main.call("rebuild_chunks_around_cell", placement_target)
    inventory_system.restore(original_inventory)
    player.global_position = original_position
    player.velocity = original_velocity
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    camera.rotation.x = original_camera_pitch
    player.set("terrain_grounded", false)

func place_item_far_from_player(inventory_system, item_id: String, target_cell: Vector2i) -> Dictionary:
    var blocks := get_blocks()
    var target_ground: float = main.call("terrain_height_cell", target_cell.x, target_cell.y)
    var anchor_cell := Vector3i(target_cell.x, roundi(camera.global_position.y / CELL), target_cell.y)
    if blocks.has(anchor_cell):
        var old_anchor := blocks[anchor_cell] as Node
        if old_anchor:
            old_anchor.queue_free()
        blocks.erase(anchor_cell)
    var anchor = main.call("create_block", anchor_cell, "stoneBlock", {
        "world_y": camera.global_position.y
    })
    var before := {}
    for key in blocks.keys():
        before[key] = true
    if not set_active_inventory_item(inventory_system, item_id):
        return { "placed": false, "consumed": false, "reason": "not active" }
    var count_before: int = inventory_system.count(item_id)
    aim_player_at(Vector3(float(target_cell.x) * CELL, camera.global_position.y, float(target_cell.y) * CELL))
    await wait_physics_frames(2)
    main.call("place_selected_block")
    await wait_physics_frames(4)
    var placed := false
    var placed_keys: Array[Vector3i] = []
    for key in blocks.keys():
        if before.has(key):
            continue
        var body := blocks[key] as Node
        if body == null or not bool(body.get_meta("player_placed", false)):
            continue
        if String(body.get_meta("block_type", "")) != item_id:
            continue
        placed = true
        placed_keys.append(key)
    cleanup_test_blocks(placed_keys)
    if blocks.has(anchor_cell):
        var anchor_body := blocks[anchor_cell] as Node
        if anchor_body:
            anchor_body.queue_free()
        blocks.erase(anchor_cell)
    var count_after: int = inventory_system.count(item_id)
    return {
        "placed": placed,
        "consumed": count_after == count_before - 1,
        "count": "%d->%d" % [count_before, count_after],
        "distance": Vector2(float(target_cell.x) * CELL - player.global_position.x, float(target_cell.y) * CELL - player.global_position.z).length(),
        "ground": target_ground,
        "message": String(main.get("last_hud_refresh_message"))
    }

func place_item_via_player(inventory_system, item_id: String, target_cell: Vector2i, placed_keys: Array[Vector3i]) -> Dictionary:
    var blocks := get_blocks()
    var before := {}
    for key in blocks.keys():
        before[key] = true
    if not set_active_inventory_item(inventory_system, item_id):
        return { "placed": false, "consumed": false, "grounded": false, "reason": "not active" }
    var count_before: int = inventory_system.count(item_id)
    var target_ground: float = main.call("terrain_height_cell", target_cell.x, target_cell.y)
    aim_player_at(Vector3(float(target_cell.x) * CELL, target_ground - CELL * 1.5, float(target_cell.y) * CELL))
    await wait_physics_frames(2)
    main.call("place_selected_block")
    await wait_physics_frames(4)

    var placed: StaticBody3D = null
    var placed_key := Vector3i.ZERO
    for key in blocks.keys():
        if before.has(key):
            continue
        var body := blocks[key] as StaticBody3D
        if body == null or not bool(body.get_meta("player_placed", false)):
            continue
        if String(body.get_meta("block_type", "")) != item_id:
            continue
        placed = body
        placed_key = key
        break
    if placed:
        placed_keys.append(placed_key)
    var count_after: int = inventory_system.count(item_id)
    var consumed := count_after == count_before - 1
    var grounded := false
    var bottom := 0.0
    var ground := 0.0
    if placed:
        bottom = float(main.call("block_bottom_y", placed))
        ground = float(main.call("placement_surface_height", placed.global_position.x, placed.global_position.z, item_id))
        grounded = bottom <= ground + CELL * 0.18 and bottom >= ground - CELL * 0.20
    return {
        "placed": placed != null,
        "consumed": consumed,
        "grounded": grounded,
        "count": "%d->%d" % [count_before, count_after],
        "bottom": bottom,
        "ground": ground,
        "meshCount": count_mesh_descendants(placed),
        "message": String(main.get("last_hud_refresh_message"))
    }

func cleanup_test_blocks(keys: Array[Vector3i]) -> void:
    var blocks := get_blocks()
    for key in keys:
        if blocks.has(key):
            var body := blocks[key] as Node
            if body:
                body.queue_free()
            blocks.erase(key)

func clear_blocks_near_cell(center_cell: Vector2i, radius: int) -> void:
    var blocks := get_blocks()
    for key in blocks.keys():
        var cell: Vector3i = key
        if abs(cell.x - center_cell.x) > radius or abs(cell.z - center_cell.y) > radius:
            continue
        var body := blocks[key] as Node
        if body:
            body.queue_free()
        blocks.erase(key)

func clear_blocks_along_segment(start: Vector3, end: Vector3, radius_cells: int = 1) -> void:
    var blocks := get_blocks()
    if blocks.is_empty():
        return
    var segment := end - start
    var steps: int = maxi(2, ceili(segment.length() / CELL))
    var cells := {}
    for i in range(steps + 1):
        var point: Vector3 = start.lerp(end, float(i) / float(steps))
        var cell_x := roundi(point.x / CELL)
        var cell_z := roundi(point.z / CELL)
        for dz in range(-radius_cells, radius_cells + 1):
            for dx in range(-radius_cells, radius_cells + 1):
                cells[Vector2i(cell_x + dx, cell_z + dz)] = true
    for key in blocks.keys():
        var cell: Vector3i = key
        if not cells.has(Vector2i(cell.x, cell.z)):
            continue
        var body := blocks[key] as Node
        if body:
            body.queue_free()
        blocks.erase(key)

func clear_props_near_cell(center_cell: Vector2i, radius: int) -> void:
    var roots := []
    var chunk_root = main.get("chunk_root") as Node
    var prop_root = main.get("prop_root") as Node
    if chunk_root:
        roots.append(chunk_root)
    if prop_root:
        roots.append(prop_root)
    for root in roots:
        clear_props_near_cell_recursive(root, center_cell, radius)

func clear_props_near_cell_recursive(node: Node, center_cell: Vector2i, radius: int) -> void:
    for child in node.get_children():
        var node3d := child as Node3D
        if node3d != null and node3d.has_meta("kind") and String(node3d.get_meta("kind")) == "prop":
            var cell := Vector2i(main.call("world_to_cell", node3d.global_position.x), main.call("world_to_cell", node3d.global_position.z))
            if abs(cell.x - center_cell.x) <= radius and abs(cell.y - center_cell.y) <= radius:
                node.remove_child(child)
                child.queue_free()
                continue
        clear_props_near_cell_recursive(child, center_cell, radius)

func disable_prop_colliders(node: Node, disabled_shapes: Array[CollisionShape3D]) -> void:
    if node == null:
        return
    if node.has_meta("kind") and String(node.get_meta("kind")) == "prop":
        collect_disabled_collision_shapes(node, disabled_shapes)
        return
    for child in node.get_children():
        disable_prop_colliders(child, disabled_shapes)

func collect_disabled_collision_shapes(node: Node, disabled_shapes: Array[CollisionShape3D]) -> void:
    for child in node.get_children():
        var shape := child as CollisionShape3D
        if shape != null and not shape.disabled:
            shape.disabled = true
            disabled_shapes.append(shape)
        collect_disabled_collision_shapes(child, disabled_shapes)

func restore_collision_shapes(shapes: Array[CollisionShape3D]) -> void:
    for shape in shapes:
        if shape != null and is_instance_valid(shape):
            shape.disabled = false

func make_relative_slope_patch(center_cell: Vector2i) -> Dictionary:
    var edits := get_height_edits()
    var restore := {}
    var base_height: float = main.call("terrain_height_cell", center_cell.x, center_cell.y)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := Vector2i(center_cell.x + dx, center_cell.y + dz)
            restore[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }
            edits[key] = base_height + float(dx + dz) * CELL * 0.12
    return restore

func restore_height_patch(restore: Dictionary) -> void:
    var edits := get_height_edits()
    for key in restore.keys():
        var entry: Dictionary = restore[key]
        if bool(entry.get("had", false)):
            edits[key] = float(entry.get("height", 0.0))
        elif edits.has(key):
            edits.erase(key)

func test_trader_stall_system() -> void:
    if not main or not player:
        add_result("trader_stall_system", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var utility_system = main.get("utility_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = inventory_system != null and utility_system != null and progression_system != null and hud != null
    if not present:
        add_result("trader_stall_system", false, "inventory/utility/progression/hud missing")
        return

    var original_slots: Array = inventory_system.snapshot()
    var original_size: int = int(inventory_system.size)
    var original_selected: int = int(inventory_system.selected_slot)
    var progression_snapshot: Dictionary = progression_system.snapshot()
    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 4)
    var stall := main.call("create_block", base_cell, "traderStall") as StaticBody3D
    if stall == null:
        add_result("trader_stall_system", false, "failed to create trader stall")
        return

    inventory_system.clear()
    inventory_system.add_item("logs", 2)
    utility_system.open_block(stall)
    hud.render_utility(utility_system.active_state())
    var trade_state: Dictionary = utility_system.active_state()
    var trade_rows: Array = trade_state.get("trades", [])
    var hud_open: bool = hud.is_utility_open() and String(trade_state.get("type", "")) == "traderStall" and hud.utility_grid.get_child_count() == trade_rows.size() and trade_rows.size() >= 10
    var logs_before: int = inventory_system.count("logs")
    var torches_before: int = inventory_system.count("torch")
    var xp_before: int = int(progression_system.total_xp)
    var traded: bool = bool(utility_system.handle_action("trade", "trailTorches"))
    var trade_changed_inventory: bool = inventory_system.count("logs") == logs_before - 2 and inventory_system.count("torch") == torches_before + 4
    var xp_after: int = int(progression_system.total_xp)
    var xp_awarded: bool = xp_after > xp_before
    var blocked_second: bool = not bool(utility_system.handle_action("trade", "trailTorches")) and inventory_system.count("torch") == torches_before + 4

    utility_system.close()
    inventory_system.restore({ "slots": original_slots, "size": original_size, "selectedSlot": original_selected })
    progression_system.restore(progression_snapshot)
    var blocks := get_blocks()
    if blocks.has(base_cell):
        var body := blocks[base_cell] as Node
        if body:
            body.queue_free()
        blocks.erase(base_cell)

    add_result(
        "trader_stall_system",
        hud_open and traded and trade_changed_inventory and xp_awarded and blocked_second,
        "hud %s, rows %d, traded %s, inventory %s, xp %d->%d, blocked %s" % [
            str(hud_open),
            trade_rows.size(),
            str(traded),
            str(trade_changed_inventory),
            xp_before,
            xp_after,
            str(blocked_second)
        ]
    )

func test_fishing_system() -> void:
    if not main or not player or not camera:
        add_result("fishing_system", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var held_item = main.get("held_item")
    if inventory_system == null or held_item == null:
        add_result("fishing_system", false, "inventory or held item missing")
        return

    var original_position: Vector3 = player.global_position
    var original_rotation: Vector3 = player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x
    var center_cell := Vector2i(roundi(player.global_position.x / CELL) + 7, roundi(player.global_position.z / CELL))
    var water_cell := Vector2i(center_cell.x, center_cell.y - 5)
    var edits := get_height_edits()
    var touched_edits := {}
    for dz in range(-5, 6):
        for dx in range(-5, 6):
            var key := Vector2i(center_cell.x + dx, center_cell.y + dz)
            touched_edits[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }
    for dz in range(-1, 2):
        for dx in range(-2, 3):
            var key := Vector2i(water_cell.x + dx, water_cell.y + dz)
            if not touched_edits.has(key):
                touched_edits[key] = { "had": edits.has(key), "height": float(edits[key]) if edits.has(key) else 0.0 }

    reset_player_on_flat_patch(center_cell)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    edits = get_height_edits()
    for dz in range(-1, 2):
        for dx in range(-2, 3):
            edits[Vector2i(water_cell.x + dx, water_cell.y + dz)] = WATER_LEVEL - 0.25
    main.call("rebuild_chunks_around_cell", water_cell)
    await wait_physics_frames(8)

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.add_item("fishingRod", 1)
    var rod_slot := find_inventory_slot(inventory_system, "fishingRod")
    if rod_slot >= 0:
        inventory_system.select(0)
        if rod_slot != 0:
            inventory_system.swap_with_active(rod_slot)
    await wait_physics_frames(2)

    var fishing_rng = main.get("fishing_rng") as RandomNumberGenerator
    if fishing_rng:
        fishing_rng.seed = 34117
    main.set("world_elapsed", 1000.0)
    main.set("next_fishing_ready_at", 0.0)
    var spot: Dictionary = main.call("find_fishing_spot")
    var fish_before: int = inventory_system.count("rawFish")
    var cast_used := false
    for i in range(16):
        cast_used = bool(main.call("try_use_active_consumable")) or cast_used
        await wait_physics_frames(2)
        if inventory_system.count("rawFish") > fish_before:
            break
        main.set("world_elapsed", float(main.get("next_fishing_ready_at")) + 0.2)
    var caught: bool = inventory_system.count("rawFish") > fish_before
    var rod_visible: bool = String(held_item.get("current_item")) == "fishingRod" and held_item.visible
    var cast_animation: bool = String(held_item.get("use_action")) == "cast"
    var passed: bool = not spot.is_empty() and cast_used and caught and rod_visible and cast_animation
    edits = get_height_edits()
    for key in touched_edits.keys():
        var entry: Dictionary = touched_edits[key]
        if bool(entry.get("had", false)):
            edits[key] = float(entry.get("height", 0.0))
        else:
            edits.erase(key)
    main.call("rebuild_chunks_around_cell", center_cell)
    main.call("rebuild_chunks_around_cell", water_cell)
    player.global_position = original_position
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    camera.rotation.x = original_camera_pitch
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", false)
    await wait_physics_frames(4)
    add_result(
        "fishing_system",
        passed,
        "spot %s, fish %d->%d, rod %s, cast %s" % [
            str(spot),
            fish_before,
            inventory_system.count("rawFish"),
            str(rod_visible),
            str(cast_animation)
        ]
    )

func test_save_load_round_trip() -> void:
    if not main or not player:
        add_result("save_system_present", false, "main or player missing")
        return
    var save_system = main.get("save_system")
    var inventory_system = main.get("inventory_system")
    var survival_system = main.get("survival_system")
    var progression_system = main.get("progression_system")
    var equipment_system = main.get("equipment_system")
    var contract_system = main.get("contract_system")
    var present: bool = save_system != null and inventory_system != null and survival_system != null and progression_system != null and equipment_system != null and contract_system != null
    add_result("save_system_present", present, "save system + inventory + survival + progression present")
    if not present:
        return

    save_system.delete(String(main.get("seed_text")))
    var original_autosave_enabled: bool = bool(main.get("autosave_enabled"))
    var save_cell := Vector3i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 4)
    var save_block := main.call("create_block", save_cell, "woodBlock", { "player_placed": true }) as StaticBody3D
    var edit_key := Vector2i(187, -91)
    var edits := get_height_edits()
    edits[edit_key] = 33.75
    var saved_position: Vector3 = player.global_position + Vector3(2.0, 0.0, 1.0)
    player.global_position = saved_position
    var saved_wood_count: int = inventory_system.count("woodBlock")
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    var discovered_shrines: Dictionary = main.get("discovered_shrine_keys")
    var discovered_mines: Dictionary = main.get("discovered_mine_keys")
    var discovered_ruins: Dictionary = main.get("discovered_ruin_keys")
    var discovered_camps: Dictionary = main.get("discovered_camp_keys")
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    var saved_cell_2d := Vector2i(main.call("world_to_cell", saved_position.x), main.call("world_to_cell", saved_position.z))
    discovered_biomes[String(main.call("biome_at_cell", saved_cell_2d.x, saved_cell_2d.y))] = true
    var saved_town: Dictionary = main.call("town_region_at_cell", saved_cell_2d.x, saved_cell_2d.y)
    if not saved_town.is_empty():
        discovered_towns["%d,%d" % [int(saved_town.get("centerX", 0)), int(saved_town.get("centerZ", 0))]] = true
    discovered_towns["playtest-town"] = true
    discovered_shrines["playtest-shrine"] = true
    discovered_mines["playtest-mine"] = true
    discovered_ruins["playtest-ruin"] = true
    discovered_camps["playtest-camp"] = true
    var save_scan_blocks := get_blocks()
    for block_value in save_scan_blocks.values():
        var discovery_body := block_value as Node3D
        if discovery_body == null or not discovery_body.has_meta("generatedTier"):
            continue
        var tier := String(discovery_body.get_meta("generatedTier", ""))
        if not (tier in ["mine", "ruin", "camp"]):
            continue
        if discovery_body.global_position.distance_to(saved_position) > CELL * 8.0:
            continue
        var landmark_key := String(discovery_body.get_meta("cacheKey", ""))
        if landmark_key == "":
            continue
        if tier == "mine":
            discovered_mines[landmark_key] = true
        elif tier == "ruin":
            discovered_ruins[landmark_key] = true
        elif tier == "camp":
            discovered_camps[landmark_key] = true
    contract_system.reset()
    survival_system.health = 72.0
    survival_system.hunger = 44.0
    progression_system.restore({ "level": 2, "xp": 17, "totalXp": 97 })
    equipment_system.restore({ "body": "stoneArmor", "accessory": "trailCharm" })
    contract_system.restore({ "completed": ["masonOrder"], "townUnlocked": true, "menuOpen": true })
    var saved: bool = main.call("save_world", true)

    player.global_position = saved_position + Vector3(22.0, 4.0, 0.0)
    inventory_system.clear()
    survival_system.health = 12.0
    survival_system.hunger = 2.0
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    equipment_system.reset()
    contract_system.reset()
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    edits.erase(edit_key)
    var blocks := get_blocks()
    if blocks.has(save_cell):
        save_block = blocks[save_cell] as StaticBody3D
        if save_block:
            save_block.queue_free()
        blocks.erase(save_cell)

    main.set("autosave_enabled", true)
    var loaded: bool = main.call("try_load_world", false)
    main.set("autosave_enabled", original_autosave_enabled)
    blocks = get_blocks()
    edits = get_height_edits()
    var player_restored := player.global_position.distance_to(saved_position) < 0.05
    var inventory_restored: bool = inventory_system.count("woodBlock") == saved_wood_count
    var survival_restored: bool = abs(float(survival_system.health) - 72.0) < 0.05 and abs(float(survival_system.hunger) - 44.0) < 0.05
    var progression_restored: bool = int(progression_system.level) == 2 and int(progression_system.xp) == 17 and int(progression_system.total_xp) == 97
    var equipment_restored: bool = String(equipment_system.equipped_item("body")) == "stoneArmor" and String(equipment_system.equipped_item("accessory")) == "trailCharm"
    var contract_state: Dictionary = contract_system.state()
    var contracts_restored: bool = bool(contract_state.get("townUnlocked", false)) and int(contract_state.get("completed", 0)) >= 1
    var exploration_restored: bool = (
        discovered_towns.has("playtest-town")
        and discovered_shrines.has("playtest-shrine")
        and discovered_mines.has("playtest-mine")
        and discovered_ruins.has("playtest-ruin")
        and discovered_camps.has("playtest-camp")
    )
    var terrain_restored: bool = edits.has(edit_key) and abs(float(edits[edit_key]) - 33.75) < 0.01
    var block_restored: bool = blocks.has(save_cell) and bool((blocks[save_cell] as Node).get_meta("player_placed", false))
    add_result(
        "save_load_round_trip",
        saved and loaded and player_restored and inventory_restored and survival_restored and progression_restored and equipment_restored and contracts_restored and exploration_restored and terrain_restored and block_restored,
        "saved %s, loaded %s, player %s, inventory %s, survival %s, progression %s, equipment %s, contracts %s, exploration %s, terrain %s, block %s" % [
            str(saved),
            str(loaded),
            str(player_restored),
            str(inventory_restored),
            str(survival_restored),
            str(progression_restored),
            str(equipment_restored),
            str(contracts_restored),
            str(exploration_restored),
            str(terrain_restored),
            str(block_restored)
        ]
    )

    save_system.delete(String(main.get("seed_text")))
    main.set("autosave_enabled", original_autosave_enabled)
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    equipment_system.reset()
    contract_system.reset()
    if blocks.has(save_cell):
        var restored_block := blocks[save_cell] as Node
        if restored_block:
            restored_block.queue_free()
        blocks.erase(save_cell)

func test_survival_system() -> void:
    if not main:
        add_result("survival_system_present", false, "main missing")
        return
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    var present: bool = survival_system != null and inventory_system != null and hud != null
    add_result("survival_system_present", present, "survival + inventory + hud present")
    if not present:
        return

    survival_system.health = 80.0
    survival_system.stamina = 50.0
    survival_system.hunger = 40.0
    inventory_system.add_item("berries", 2)
    var berry_slot := find_inventory_slot(inventory_system, "berries")
    if berry_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(berry_slot)
    var berries_before: int = inventory_system.count("berries")
    var used_food: bool = main.call("try_use_active_consumable")
    var food_helped: bool = used_food and inventory_system.count("berries") == berries_before - 1 and float(survival_system.hunger) > 40.0 and float(survival_system.health) > 80.0
    hud.set_survival(survival_system.snapshot())
    var hud_updated: bool = hud.health_label.text.begins_with("HP") and hud.hunger_label.text.begins_with("HUN")
    add_result(
        "survival_food_and_hud",
        food_helped and hud_updated,
        "used %s, hunger %.1f, health %.1f, hud %s/%s" % [
            str(used_food),
            float(survival_system.hunger),
            float(survival_system.health),
            hud.health_label.text,
            hud.hunger_label.text
        ]
    )

    var night_start_health: float = float(survival_system.call("max_health"))
    survival_system.health = night_start_health
    survival_system.hunger = 100.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    add_result(
        "night_does_not_damage_player",
        abs(float(survival_system.health) - night_start_health) < 0.01 and float(survival_system.hunger) < 100.0 and String(survival_system.last_danger) == "Nightfall",
        "health %.1f, hunger %.1f, danger '%s'" % [float(survival_system.health), float(survival_system.hunger), String(survival_system.last_danger)]
    )

    survival_system.health = 80.0
    survival_system.hunger = 80.0
    survival_system.warmth_timer = 0.0
    survival_system.ward_timer = 0.0
    var hunger_plain := float(survival_system.hunger)
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 1.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var plain_drain := hunger_plain - float(survival_system.hunger)
    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var wet_cold_drain := 80.0 - float(survival_system.hunger)
    survival_system.warmth_timer = 60.0
    survival_system.hunger = 80.0
    survival_system.update(10.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": false })
    var warmed_drain := 80.0 - float(survival_system.hunger)
    add_result(
        "survival_weather_warmth_drain",
        wet_cold_drain > plain_drain + 0.30 and warmed_drain <= plain_drain + 0.05 and String(survival_system.last_danger).begins_with("Warmed"),
        "plain %.3f, wet+cold %.3f, warmed %.3f, danger '%s'" % [plain_drain, wet_cold_drain, warmed_drain, String(survival_system.last_danger)]
    )

    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.stamina = 40.0
    survival_system.warmth_timer = 0.0
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "shelterComfort": 0.0, "sanctuaryEstablished": false })
    var exposed_snow_drain := 80.0 - float(survival_system.hunger)
    var exposed_stamina := float(survival_system.stamina)
    survival_system.hunger = 80.0
    survival_system.health = 80.0
    survival_system.stamina = 40.0
    survival_system.warmth_timer = 0.0
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "snow", "dayFactor": 1.0, "weather": { "kind": "snow", "intensity": 1.0 }, "lightSafety": 0.0, "shelterComfort": 0.75, "sanctuaryEstablished": false })
    var sheltered_snow_drain := 80.0 - float(survival_system.hunger)
    var sheltered_stamina := float(survival_system.stamina)
    var sheltered_status := String(survival_system.last_danger)

    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 18, roundi(player.global_position.z / CELL) + 18)
    var base_height: float = main.call("terrain_height_cell", base_cell.x, base_cell.y)
    for offset in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
        main.call("create_playtest_ground_block", base_cell, offset, "woodBlock", "shelter_test", 0)
        main.call("create_playtest_ground_block", base_cell, offset, "woodBlock", "shelter_test", 1)
    for x_offset in [-1, 0, 1]:
        for z_offset in [-1, 0, 1]:
            main.call("create_playtest_ground_block", base_cell, Vector2i(x_offset, z_offset), "woodBlock", "shelter_test", 2)
    main.call("create_playtest_ground_block", base_cell, Vector2i(0, 0), "bed", "shelter_test", 0)
    main.call("create_playtest_ground_block", base_cell, Vector2i(0, 1), "torch", "shelter_test", 0)
    var shelter_state: Dictionary = main.call("shelter_state_at", Vector3(float(base_cell.x) * CELL, base_height + 0.55, float(base_cell.y) * CELL))
    main.call("cleanup_playtest_case_assets")
    var shelter_score_ok: bool = float(shelter_state.get("comfort", 0.0)) >= 0.62 and String(shelter_state.get("label", "")) == "Sheltered"
    add_result(
        "survival_shelter_comfort",
        sheltered_snow_drain < exposed_snow_drain and sheltered_stamina > exposed_stamina and sheltered_status == "Sheltered" and shelter_score_ok,
        "drain %.3f->%.3f, stamina %.1f->%.1f, status '%s', scorer %.2f/%s" % [
            exposed_snow_drain,
            sheltered_snow_drain,
            exposed_stamina,
            sheltered_stamina,
            sheltered_status,
            float(shelter_state.get("comfort", 0.0)),
            String(shelter_state.get("label", ""))
        ]
    )

    survival_system.health = survival_system.max_health()
    survival_system.hunger = 80.0
    survival_system.ward_timer = 90.0
    survival_system.apply_damage(10.0, "Hostile hit", "hostile")
    var warded_health := float(survival_system.health)
    var warded_label := String(survival_system.last_danger)
    survival_system.health = survival_system.max_health()
    survival_system.ward_timer = 0.0
    survival_system.apply_damage(10.0, "Hostile hit", "hostile")
    var unwarded_health := float(survival_system.health)
    add_result(
        "survival_ward_damage_status",
        warded_health > unwarded_health and warded_label.find("(ward)") >= 0,
        "warded %.1f, unwarded %.1f, label '%s'" % [warded_health, unwarded_health, warded_label]
    )

    survival_system.health = 90.0
    survival_system.hunger = 80.0
    survival_system.ward_timer = 0.0
    survival_system.update(3.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.8, "sanctuaryEstablished": false })
    var light_status := String(survival_system.last_danger)
    var light_health := float(survival_system.health)
    survival_system.update(1.0, { "moving": false, "sprinting": false, "jumped": false, "biome": "plains", "dayFactor": 0.0, "weather": { "kind": "clear", "intensity": 0.0 }, "lightSafety": 0.0, "sanctuaryEstablished": true })
    add_result(
        "survival_light_sanctuary_status",
        light_status == "Light safe" and light_health > 90.0 and String(survival_system.last_danger) == "Sanctuary secured",
        "light '%s' health %.1f, sanctuary '%s'" % [light_status, light_health, String(survival_system.last_danger)]
    )
    if berry_slot >= 0:
        inventory_system.swap_with_active(berry_slot)
    inventory_system.select(0)

func test_bed_respawn_and_death_drop() -> void:
    if not main or not player:
        add_result("bed_respawn_and_death_drop", false, "main or player missing")
        return
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var equipment_system = main.get("equipment_system")
    if survival_system == null or inventory_system == null or equipment_system == null:
        add_result("bed_respawn_and_death_drop", false, "survival/inventory/equipment missing")
        return

    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    var original_equipment: Dictionary = equipment_system.snapshot()
    var original_survival: Dictionary = survival_system.snapshot()
    var original_respawn = main.get("respawn_point")
    var original_deaths: int = int(main.get("death_count"))
    var blocks := get_blocks()

    var bed_center := player.global_position + Vector3(CELL * 4.0, 0.0, 0.0)
    var bed_level: float = main.call("height_at_world", bed_center.x, bed_center.z)
    var bed_cell := Vector3i(roundi(bed_center.x / CELL), floori((bed_level + CELL * 0.48) / CELL) + 1, roundi(bed_center.z / CELL))
    if blocks.has(bed_cell):
        var old_block := blocks[bed_cell] as Node
        if old_block:
            old_block.queue_free()
        blocks.erase(bed_cell)
    var bed = main.call("create_block", bed_cell, "bed", {
        "player_placed": true,
        "world_y": bed_level + CELL * 0.48
    })
    var bed_set: bool = bool(main.call("sleep_at_bed", bed))
    if bed_set:
        main.call("update_sleep_transition", 2.0)
    var respawn_value = main.get("respawn_point")
    var respawn_set: bool = bed_set and respawn_value is Vector3

    inventory_system.clear()
    inventory_system.add_item("logs", 5)
    inventory_system.add_item("stoneArmor", 1)
    var armor_slot := find_inventory_slot(inventory_system, "stoneArmor")
    if armor_slot >= 0:
        inventory_system.select(0)
        inventory_system.swap_with_active(armor_slot)
        equipment_system.equip_active()
    var death_position := player.global_position + Vector3(CELL * 8.0, 0.0, CELL * 2.0)
    player.global_position = death_position
    survival_system.health = 1.0
    survival_system.apply_damage(99.0, "test collapse", "hostile")
    var collapsed: bool = bool(main.call("handle_collapse_if_needed"))
    var death_after: int = int(main.get("death_count"))
    var death_counted: bool = death_after == original_deaths + 1
    var woke_near_bed: bool = respawn_set and player.global_position.distance_to(respawn_value) < CELL * 1.2
    var inventory_cleared: bool = inventory_system.count("logs") == 0 and equipment_system.equipped_item("body") == ""
    var pickup_count: int = (main.get("dropped_pickups") as Array).size()
    var drops_spawned: bool = pickup_count >= 2

    var collected_logs := false
    var pickups: Array = main.get("dropped_pickups")
    if not pickups.is_empty():
        var pickup: Dictionary = pickups[0]
        var pickup_node := pickup.get("node") as Node3D
        if pickup_node and is_instance_valid(pickup_node):
            player.global_position = pickup_node.global_position
            main.call("update_dropped_pickups", 0.1)
            collected_logs = inventory_system.count("logs") > 0 or inventory_system.count("stoneArmor") > 0

    main.call("clear_dropped_pickups")
    if bed and is_instance_valid(bed):
        bed.queue_free()
    if blocks.has(bed_cell):
        blocks.erase(bed_cell)
    inventory_system.restore(original_inventory)
    equipment_system.restore(original_equipment)
    survival_system.restore(original_survival)
    main.set("respawn_point", original_respawn)
    main.set("death_count", original_deaths)
    player.global_position = original_position
    player.velocity = original_velocity
    player.set("terrain_grounded", false)

    add_result(
        "bed_respawn_and_death_drop",
        respawn_set and collapsed and death_counted and woke_near_bed and inventory_cleared and drops_spawned and collected_logs,
        "respawn %s, collapsed %s, deaths %d, woke %s, cleared %s, drops %d, collected %s" % [
            str(respawn_set),
            str(collapsed),
            death_after,
            str(woke_near_bed),
            str(inventory_cleared),
            pickup_count,
            str(collected_logs)
        ]
    )

func test_hostile_system() -> void:
    if not main or not player:
        add_result("hostile_system_present", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var survival_system = main.get("survival_system")
    var inventory_system = main.get("inventory_system")
    var present: bool = hostile_system != null and survival_system != null and inventory_system != null
    add_result("hostile_system_present", present, "hostiles + survival + inventory present")
    if not present:
        return

    hostile_system.clear()
    hostile_system.spawn_cooldown = 999.0
    var original_position: Vector3 = player.global_position
    var enemy_pos: Vector3 = original_position + Vector3(12.0, 0.0, 0.0)
    enemy_pos.y = main.call("height_at_world", enemy_pos.x, enemy_pos.z) + 0.72
    var enemy: StaticBody3D = hostile_system.spawn_enemy(enemy_pos, "shadow")
    var enemy_start: Vector3 = enemy.global_position if enemy else enemy_pos
    hostile_system.update_hostiles(0.25, 0.0, "plains")
    var became_aware: bool = hostile_system.enemies.size() > 0 and bool(hostile_system.enemies[0].get("aware", false))
    var moved_when_aware: bool = enemy != null and is_instance_valid(enemy) and enemy.global_position.distance_to(enemy_start) > 0.12
    var aware_distance: float = enemy.global_position.distance_to(enemy_start) if enemy != null and is_instance_valid(enemy) else 0.0
    player.global_position = original_position + Vector3(90.0, 0.0, 0.0)
    hostile_system.update_hostiles(0.25, 0.0, "plains")
    var leashed: bool = hostile_system.enemies.size() > 0 and not bool(hostile_system.enemies[0].get("aware", true))
    player.global_position = original_position
    var shards_before: int = inventory_system.count("nightShard")
    hostile_system.damage_hostile(enemy, 999.0)
    var defeated_drop: bool = hostile_system.enemies.is_empty() and inventory_system.count("nightShard") == shards_before + 1
    add_result(
        "hostile_awareness_leash_drop",
        became_aware and leashed and defeated_drop,
        "aware %s, leashed %s, shard %d->%d" % [str(became_aware), str(leashed), shards_before, inventory_system.count("nightShard")]
    )
    add_result(
        "hostile_chase_movement",
        became_aware and moved_when_aware,
        "aware %s, moved %.2f" % [str(became_aware), aware_distance]
    )

    hostile_system.clear()
    var wall_blocks := get_blocks()
    var wall_ground: float = main.call("height_at_world", original_position.x + CELL * 4.0, original_position.z)
    var wall_y: float = wall_ground + CELL * 0.48
    var wall_cells: Array[Vector3i] = []
    var wall_x := roundi((original_position.x + CELL * 4.0) / CELL)
    var wall_z := roundi(original_position.z / CELL)
    var wall_cell_y := floori(wall_y / CELL) + 1
    for dz in range(-1, 2):
        var wall_cell := Vector3i(wall_x, wall_cell_y, wall_z + dz)
        wall_cells.append(wall_cell)
        if wall_blocks.has(wall_cell):
            var old_wall := wall_blocks[wall_cell] as Node
            if old_wall:
                old_wall.queue_free()
            wall_blocks.erase(wall_cell)
        main.call("create_block", wall_cell, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)
    var blocked_enemy_pos := original_position + Vector3(CELL * 8.0, 0.0, 0.0)
    blocked_enemy_pos.y = main.call("height_at_world", blocked_enemy_pos.x, blocked_enemy_pos.z) + 0.72
    var blocked_enemy: StaticBody3D = hostile_system.spawn_enemy(blocked_enemy_pos, "shadow")
    var blocked_start_x := blocked_enemy.global_position.x if blocked_enemy else blocked_enemy_pos.x
    for i in range(28):
        hostile_system.update_hostiles(0.16, 0.0, "plains")
    var blocked_end_x := blocked_enemy.global_position.x if blocked_enemy and is_instance_valid(blocked_enemy) else blocked_start_x
    var wall_world_x := float(wall_x) * CELL
    var stopped_by_wall := blocked_enemy != null and blocked_end_x > wall_world_x + CELL * 0.55
    hostile_system.clear()
    wall_blocks = get_blocks()
    for wall_cell in wall_cells:
        if wall_blocks.has(wall_cell):
            var wall_body := wall_blocks[wall_cell] as Node
            if wall_body:
                wall_body.queue_free()
            wall_blocks.erase(wall_cell)
    add_result(
        "hostile_obstacle_collision",
        stopped_by_wall,
        "start x %.2f, end x %.2f, wall x %.2f" % [blocked_start_x, blocked_end_x, wall_world_x]
    )

    survival_system.health = survival_system.max_health()
    var block_health_before: float = float(survival_system.health)
    var block_cell: Vector3i = Vector3i(roundi(player.global_position.x / CELL) + 4, roundi((player.global_position.y + 0.9) / CELL), roundi(player.global_position.z / CELL))
    var blocks := get_blocks()
    if blocks.has(block_cell):
        var old_projectile_block := blocks[block_cell] as Node
        if old_projectile_block:
            old_projectile_block.queue_free()
        blocks.erase(block_cell)
    main.call("create_block", block_cell, "stoneBlock")
    await wait_physics_frames(3)
    var block_y: float = float(block_cell.y) * CELL
    var projectile_start := Vector3((block_cell.x - 3) * CELL, block_y, block_cell.z * CELL)
    var projectile_target := Vector3((block_cell.x + 3) * CELL, block_y, block_cell.z * CELL)
    var direct_block_probe: Dictionary = hostile_system.projectile_block_hit(projectile_start, projectile_target)
    var projectile_pool_stats_before: Dictionary = hostile_system.stats()
    hostile_system.spawn_projectile(projectile_start, projectile_target, 8.0, null)
    hostile_system.update_hostiles(0.45, 1.0, "plains")
    var projectile_pool_stats_after_block: Dictionary = hostile_system.stats()
    var block_projectiles_after: int = hostile_system.projectiles.size()
    var block_health_after: float = float(survival_system.health)
    var blocked_projectile: bool = block_projectiles_after == 0 and block_health_after >= block_health_before - 0.01
    if blocks.has(block_cell):
        var block := blocks[block_cell] as Node
        if block:
            block.queue_free()
        blocks.erase(block_cell)

    survival_system.health = survival_system.max_health()
    var dodge_health_before: float = float(survival_system.health)
    var old_target: Vector3 = player.global_position + Vector3(0.0, 0.8, 0.0)
    hostile_system.spawn_projectile(player.global_position + Vector3(0.0, 0.8, -10.0), old_target, 8.0, null)
    var projectile_pool_stats_after_reuse: Dictionary = hostile_system.stats()
    player.global_position = original_position + Vector3(5.0, 0.0, 0.0)
    await wait_physics_frames(1)
    for i in range(18):
        hostile_system.update_hostiles(0.08, 1.0, "plains")
    var dodgeable_projectile: bool = float(survival_system.health) >= dodge_health_before - 0.01
    player.global_position = original_position
    hostile_system.clear()
    var hostile_projectile_reused: bool = (
        int(projectile_pool_stats_after_block.get("projectilePool", 0)) >= 1
        and int(projectile_pool_stats_after_reuse.get("projectileNodesCreated", 0)) <= int(projectile_pool_stats_after_block.get("projectileNodesCreated", 0))
        and int(projectile_pool_stats_after_reuse.get("projectileNodesReused", 0)) > int(projectile_pool_stats_before.get("projectileNodesReused", 0))
    )
    add_result(
        "hostile_projectile_collision_and_dodge",
        blocked_projectile and dodgeable_projectile and hostile_projectile_reused,
        "blocked %s, probe %s, block remaining %d, block health %.1f->%.1f, remaining %d, dodge health %.1f->%.1f, pool %d, created %d->%d, reused %d->%d" % [
            str(blocked_projectile),
            str(direct_block_probe),
            block_projectiles_after,
            block_health_before,
            block_health_after,
            hostile_system.projectiles.size(),
            dodge_health_before,
            float(survival_system.health),
            int(projectile_pool_stats_after_block.get("projectilePool", 0)),
            int(projectile_pool_stats_before.get("projectileNodesCreated", 0)),
            int(projectile_pool_stats_after_reuse.get("projectileNodesCreated", 0)),
            int(projectile_pool_stats_before.get("projectileNodesReused", 0)),
            int(projectile_pool_stats_after_reuse.get("projectileNodesReused", 0))
        ]
    )

    hostile_system.clear()
    player.global_position = original_position
    var natural_enemy: StaticBody3D = hostile_system.spawn_near_player("plains")
    var natural_distance := 0.0
    var natural_aware := true
    var natural_start := Vector3.ZERO
    if natural_enemy and is_instance_valid(natural_enemy):
        natural_distance = natural_enemy.global_position.distance_to(player.global_position)
        natural_start = natural_enemy.global_position
        var natural_state: Dictionary = hostile_system.enemy_for_body(natural_enemy)
        natural_aware = bool(natural_state.get("aware", true))
    for i in range(10):
        hostile_system.update_hostiles(0.12, 0.0, "plains")
    var natural_roam_distance := 0.0
    if natural_enemy and is_instance_valid(natural_enemy):
        natural_roam_distance = natural_enemy.global_position.distance_to(natural_start)
    var reduced_awareness: bool = hostile_system.awareness_radius({ "variant": "shadow" }) <= 26.0 and hostile_system.awareness_radius({ "variant": "seer" }) <= 32.0
    add_result(
        "hostile_natural_spawn_spacing",
        natural_enemy != null and natural_distance >= 44.0 and not natural_aware and reduced_awareness,
        "spawned %s, distance %.2f, aware %s, shadow radius %.1f, seer radius %.1f" % [
            str(natural_enemy != null),
            natural_distance,
            str(natural_aware),
            hostile_system.awareness_radius({ "variant": "shadow" }),
            hostile_system.awareness_radius({ "variant": "seer" })
        ]
    )
    add_result(
        "hostile_natural_roaming",
        natural_enemy != null and natural_roam_distance > 0.08,
        "spawned %s, roam %.2f, aware %s" % [str(natural_enemy != null), natural_roam_distance, str(natural_aware)]
    )
    hostile_system.clear()

func test_rift_hostile_system() -> void:
    if not main or not player:
        add_result("rift_hostile_core_drop", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var inventory_system = main.get("inventory_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var present: bool = hostile_system != null and inventory_system != null and objective_system != null and contract_system != null
    if not present:
        add_result("rift_hostile_core_drop", false, "rift dependencies missing")
        return

    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var rift_position: Vector3 = original_position + Vector3(10.0, 0.0, -8.0)
    rift_position.y = main.call("height_at_world", rift_position.x, rift_position.z) + 0.78
    var cores_before: int = inventory_system.count("riftCore")
    var shards_before: int = inventory_system.count("nightShard")
    var meat_before: int = inventory_system.count("rawMeat")
    var stats_before: Dictionary = hostile_system.stats()
    var variants_before: Dictionary = stats_before.get("defeatedVariants", {})
    var rifts_before := int(variants_before.get("rift", 0))

    var rift_enemy: StaticBody3D = hostile_system.spawn_enemy(rift_position, "rift")
    var enemy_state: Dictionary = hostile_system.enemy_for_body(rift_enemy)
    var spawned_as_rift: bool = String(rift_enemy.get_meta("variant", "")) == "rift" and float(enemy_state.get("health", 0.0)) >= 90.0
    var defeated: bool = hostile_system.damage_hostile(rift_enemy, 999.0)
    var stats_after: Dictionary = hostile_system.stats()
    var variants_after: Dictionary = stats_after.get("defeatedVariants", {})
    var state: Dictionary = main.call("objective_state")
    state["discoveredTowns"] = max(1, int(state.get("discoveredTowns", 0)))
    var objective_complete: bool = bool(objective_system.is_complete("riftColossus", state))
    var contract_complete: bool = bool(contract_system.is_contract_complete("riftTrophy", state))
    var core_dropped: bool = inventory_system.count("riftCore") == cores_before + 1
    var shard_drop: bool = inventory_system.count("nightShard") >= shards_before + 7
    var meat_drop: bool = inventory_system.count("rawMeat") >= meat_before + 3
    var variant_tracked: bool = int(variants_after.get("rift", 0)) == rifts_before + 1
    add_result(
        "rift_hostile_core_drop",
        spawned_as_rift and defeated and core_dropped and shard_drop and meat_drop and variant_tracked and objective_complete and contract_complete,
        "spawned %s, defeated %s, core %d->%d, shards %d->%d, meat %d->%d, rifts %d->%d, objective %s, contract %s, message '%s'" % [
            str(spawned_as_rift),
            str(defeated),
            cores_before,
            inventory_system.count("riftCore"),
            shards_before,
            inventory_system.count("nightShard"),
            meat_before,
            inventory_system.count("rawMeat"),
            rifts_before,
            int(variants_after.get("rift", 0)),
            str(objective_complete),
            str(contract_complete),
            String(hostile_system.last_message)
        ]
    )
    player.global_position = original_position
    hostile_system.clear()

func test_sanctuary_beacon_raid_system() -> void:
    if not main or not player:
        add_result("sanctuary_beacon_raid_system", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var objective_system = main.get("objective_system")
    var progression_system = main.get("progression_system")
    var hud = main.get("hud")
    var present: bool = hostile_system != null and objective_system != null and progression_system != null and hud != null
    if not present:
        add_result("sanctuary_beacon_raid_system", false, "hostile/objective/progression/hud system missing")
        return

    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var beacon_cell := Vector2i(roundi(player.global_position.x / CELL) + 14, roundi(player.global_position.z / CELL) + 4)
    var level: float = main.call("terrain_height_cell", beacon_cell.x, beacon_cell.y)
    var block_cell := Vector3i(beacon_cell.x, floori((level + CELL * 0.48) / CELL) + 1, beacon_cell.y)
    var blocks := get_blocks()
    if blocks.has(block_cell):
        var existing := blocks[block_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(block_cell)
    var beacon = main.call("create_block", block_cell, "sanctuaryBeacon", {
        "player_placed": true,
        "world_y": level + CELL * 0.48
    })
    main.set("beacon_charge", 24.8)
    main.set("beacon_raid_stage", 0)
    main.set("sanctuary_established", false)
    main.set("beacon_status_message", "")

    main.call("update_beacon_charge", 1.0)
    var stage_one: bool = int(main.get("beacon_raid_stage")) == 1 and hostile_system.enemies.size() >= 3
    var charge_after_stage_one: float = float(main.get("beacon_charge"))
    main.call("update_beacon_charge", 1.0)
    var contested_drop: bool = float(main.get("beacon_charge")) < charge_after_stage_one

    hostile_system.clear()
    main.set("beacon_charge", 84.8)
    main.set("beacon_raid_stage", 2)
    main.call("update_beacon_charge", 1.0)
    var rift_spawned := false
    for enemy in hostile_system.enemies:
        if String(enemy.get("variant", "")) == "rift":
            rift_spawned = true
            break
    var final_surge: bool = int(main.get("beacon_raid_stage")) == 3 and rift_spawned

    hostile_system.clear()
    main.set("beacon_charge", 99.8)
    main.set("beacon_raid_stage", 3)
    var xp_before: int = int(progression_system.total_xp)
    main.call("update_beacon_charge", 1.0)
    var state: Dictionary = main.call("objective_state")
    var raid_objective: bool = bool(objective_system.is_complete("riftRaid", state))
    var sanctuary_objective: bool = bool(objective_system.is_complete("sanctuary", state))
    var snapshot: Dictionary = main.call("create_save_snapshot")
    var established: bool = (
        bool(main.get("sanctuary_established"))
        and abs(float(main.get("beacon_charge")) - 100.0) < 0.01
        and int(main.get("beacon_raid_stage")) == 3
        and hostile_system.enemies.is_empty()
    )
    var saved_state: bool = (
        bool(snapshot.get("sanctuaryEstablished", false))
        and int(snapshot.get("beaconRaidStage", 0)) == 3
        and abs(float(snapshot.get("beaconCharge", 0.0)) - 100.0) < 0.01
    )
    var victory_open: bool = hud.is_victory_open() and hud.victory_stats_list.get_child_count() >= 20
    add_result(
        "sanctuary_beacon_raid_system",
        stage_one and contested_drop and final_surge and established and raid_objective and sanctuary_objective and saved_state and victory_open and int(progression_system.total_xp) > xp_before,
        "stage1 %s, contested %s, final %s, established %s, objectives %s/%s, saved %s, victory %s, enemies %d, charge %.1f, stage %d" % [
            str(stage_one),
            str(contested_drop),
            str(final_surge),
            str(established),
            str(raid_objective),
            str(sanctuary_objective),
            str(saved_state),
            str(victory_open),
            hostile_system.enemies.size(),
            float(main.get("beacon_charge")),
            int(main.get("beacon_raid_stage"))
        ]
    )
    player.global_position = original_position
    if beacon and is_instance_valid(beacon):
        beacon.queue_free()
    if blocks.has(block_cell):
        blocks.erase(block_cell)
    main.set("sanctuary_established", false)
    main.set("beacon_charge", 0.0)
    main.set("beacon_raid_stage", 0)
    main.set("beacon_status_message", "")
    hud.hide_victory()
    hostile_system.clear()

func test_defensive_blocks() -> void:
    if not main or not player:
        add_result("defensive_blocks", false, "main or player missing")
        return
    var hostile_system = main.get("hostile_system")
    var inventory_system = main.get("inventory_system")
    var present: bool = hostile_system != null and inventory_system != null
    if not present:
        add_result("defensive_blocks", false, "hostile or inventory system missing")
        return

    hostile_system.clear()
    main.set("sanctuary_established", false)
    var original_position: Vector3 = player.global_position
    var original_velocity: Vector3 = player.velocity
    var defensive_cell := Vector2i(roundi(player.global_position.x / CELL) + 180, roundi(player.global_position.z / CELL) + 180)
    reset_player_on_flat_patch(defensive_cell)
    clear_blocks_near_cell(defensive_cell, 12)
    clear_props_near_cell(defensive_cell, 12)
    main.call("update_chunks", true)
    await wait_physics_frames(4)
    var blocks := get_blocks()
    var level: float = main.call("height_at_world", player.global_position.x, player.global_position.z)
    var torch_cell := Vector3i(roundi(player.global_position.x / CELL) + 1, floori((level + CELL * 0.48) / CELL) + 1, roundi(player.global_position.z / CELL))
    if blocks.has(torch_cell):
        var existing_torch := blocks[torch_cell] as Node
        if existing_torch:
            existing_torch.queue_free()
        blocks.erase(torch_cell)
    var torch = main.call("create_block", torch_cell, "torch", {
        "player_placed": true,
        "world_y": level + CELL * 0.48
    })
    var safety: float = main.call("light_safety_at", player.global_position, false)
    hostile_system.spawn_cooldown = 0.0
    hostile_system.update_hostiles(0.25, 0.0, "plains", false)
    var spawn_suppressed: bool = safety > 0.82 and hostile_system.enemies.is_empty()
    if torch and is_instance_valid(torch):
        torch.queue_free()
    if blocks.has(torch_cell):
        blocks.erase(torch_cell)

    var trap_center := player.global_position + Vector3(8.0, 0.0, 0.0)
    var trap_level: float = main.call("height_at_world", trap_center.x, trap_center.z)
    var trap_cell := Vector3i(roundi(trap_center.x / CELL), floori((trap_level + CELL * 0.48) / CELL) + 1, roundi(trap_center.z / CELL))
    if blocks.has(trap_cell):
        var existing_trap := blocks[trap_cell] as Node
        if existing_trap:
            existing_trap.queue_free()
        blocks.erase(trap_cell)
    var trap = main.call("create_block", trap_cell, "spikeTrap", {
        "player_placed": true,
        "world_y": trap_level + CELL * 0.08
    })
    var shards_before: int = inventory_system.count("nightShard")
    var enemy_position := Vector3(trap_cell.x * CELL, trap_level + 0.72, trap_cell.z * CELL)
    var enemy: StaticBody3D = hostile_system.spawn_enemy(enemy_position, "shadow")
    hostile_system.spawn_cooldown = 999.0
    var health_before := 0.0
    var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy)
    if not enemy_state.is_empty():
        health_before = float(enemy_state.get("health", 0.0))
        enemy_state["aware"] = false
    hostile_system.update_hostiles(0.0, 1.0, "plains", false)
    enemy_state = hostile_system.enemy_for_body(enemy) if enemy and is_instance_valid(enemy) else {}
    var damaged: bool = not enemy_state.is_empty() and float(enemy_state.get("health", health_before)) < health_before
    if trap and is_instance_valid(trap):
        trap.set_meta("trapCooldown", 0.0)
    if enemy and is_instance_valid(enemy):
        enemy.global_position = enemy_position
        enemy_state = hostile_system.enemy_for_body(enemy)
        if not enemy_state.is_empty():
            enemy_state["aware"] = false
    hostile_system.update_hostiles(0.0, 1.0, "plains", false)
    var trap_defeated: bool = hostile_system.enemies.is_empty() and inventory_system.count("nightShard") > shards_before
    if trap and is_instance_valid(trap):
        trap.queue_free()
    if blocks.has(trap_cell):
        blocks.erase(trap_cell)
    hostile_system.clear()
    player.global_position = original_position
    player.velocity = original_velocity

    add_result(
        "defensive_blocks",
        spawn_suppressed and damaged and trap_defeated,
        "safety %.2f, suppressed %s, damaged %s, trap defeated %s" % [
            safety,
            str(spawn_suppressed),
            str(damaged),
            str(trap_defeated)
        ]
    )

func test_player_ranged_system() -> void:
    if not main or not player:
        add_result("player_ranged_system_present", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var hostile_system = main.get("hostile_system")
    var player_projectiles = main.get("player_projectiles")
    var blocks: Dictionary = main.get("blocks")
    var present: bool = inventory_system != null and hostile_system != null and player_projectiles != null and blocks != null
    add_result("player_ranged_system_present", present, "ranged system + inventory + hostiles present")
    if not present:
        return

    var original_position := player.global_position
    var original_velocity := player.velocity
    var original_rotation := player.rotation
    var original_pitch := float(player.get("pitch"))
    var original_camera_pitch := camera.rotation.x if camera else 0.0
    var ranged_cell := Vector2i(roundi(player.global_position.x / CELL) + 24, roundi(player.global_position.z / CELL) + 24)
    reset_player_on_flat_patch(ranged_cell)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    main.call("update_chunks", true)
    await wait_physics_frames(6)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    await wait_physics_frames(3)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    if camera:
        camera.rotation.x = 0.0

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.add_item("hunterBow", 1)
    inventory_system.add_item("arrows", 5)
    var bow_slot := find_inventory_slot(inventory_system, "hunterBow")
    if bow_slot >= 0:
        inventory_system.select(0)
        if bow_slot != 0:
            inventory_system.swap_with_active(bow_slot)

    var block_cell := Vector3i(
        roundi(player.global_position.x / CELL),
        roundi((player.global_position.y + 1.65) / CELL),
        roundi((player.global_position.z - 4.0) / CELL)
    )
    var block = main.call("create_block", block_cell, "stoneBlock")
    await wait_physics_frames(2)
    var arrows_before_block: int = inventory_system.count("arrows")
    var tracer_stats_before: Dictionary = player_projectiles.stats()
    var shots_before_block: int = int(tracer_stats_before.get("shotsFired", 0))
    main.call("destroy_target")
    var tracer_stats_after_block_fire: Dictionary = player_projectiles.stats()
    var block_shot_message := String(player_projectiles.last_message)
    var arrows_after_block_fire: int = inventory_system.count("arrows")
    var block_shot_fired: bool = int(tracer_stats_after_block_fire.get("shotsFired", 0)) == shots_before_block + 1
    await wait_physics_frames(16)
    var tracer_stats_after_block: Dictionary = player_projectiles.stats()
    var arrows_after_block_wait: int = inventory_system.count("arrows")
    var block_exists_after_shot: bool = blocks.has(block_cell)
    var blocked: bool = block_shot_fired and block_shot_message.find("blocked") >= 0 and block_exists_after_shot
    if block:
        block.queue_free()
    if blocks.has(block_cell):
        blocks.erase(block_cell)
    await wait_physics_frames(3)
    clear_blocks_near_cell(ranged_cell, 16)
    clear_props_near_cell(ranged_cell, 16)
    await wait_physics_frames(3)

    var enemy = hostile_system.spawn_enemy(player.global_position + Vector3(8.0, 0.0, 0.0), "shadow")
    await wait_physics_frames(2)
    if enemy and is_instance_valid(enemy):
        var aim_point: Vector3 = enemy.global_position + Vector3(0.0, 0.75, 0.0)
        clear_blocks_along_segment(camera.global_position if camera else player.global_position + Vector3.UP * 1.6, aim_point, 2)
        await wait_physics_frames(2)
        aim_player_at(aim_point)
        await wait_physics_frames(1)
    var arrows_before_hit: int = inventory_system.count("arrows")
    var shots_before_hit: int = int(player_projectiles.stats().get("shotsFired", 0))
    main.call("destroy_target")
    await wait_physics_frames(2)
    var tracer_stats_after_reuse: Dictionary = player_projectiles.stats()
    var hit_shot_fired: bool = int(tracer_stats_after_reuse.get("shotsFired", 0)) == shots_before_hit + 1
    var final_hit_kind := String(tracer_stats_after_reuse.get("lastHitKind", ""))
    var enemy_still_valid: bool = enemy and is_instance_valid(enemy)
    var enemy_state: Dictionary = hostile_system.enemy_for_body(enemy) if enemy_still_valid else {}
    var hit_hostile: bool = hit_shot_fired and (
        (not enemy_state.is_empty() and float(enemy_state.get("health", 18.0)) < 18.0)
        or (not enemy_still_valid and final_hit_kind == "hostile")
    )
    var final_hit_travel := float(tracer_stats_after_reuse.get("lastHitTravel", -1.0))
    var final_manual_hits := int(tracer_stats_after_reuse.get("manualBlockHits", 0))
    var final_manual_candidates := int(tracer_stats_after_reuse.get("manualBlockCandidates", 0))
    var final_manual_cell := str(tracer_stats_after_reuse.get("manualBlockCell", Vector3i.ZERO))
    var final_manual_type := String(tracer_stats_after_reuse.get("manualBlockType", ""))
    if enemy and is_instance_valid(enemy):
        hostile_system.damage_hostile(enemy, 999.0)

    player.global_position = original_position
    player.velocity = original_velocity
    player.rotation = original_rotation
    player.set("pitch", original_pitch)
    if camera:
        camera.rotation.x = original_camera_pitch

    var player_tracer_reused: bool = (
        int(tracer_stats_after_block.get("tracerPool", 0)) >= 1
        and int(tracer_stats_after_reuse.get("tracerNodesCreated", 0)) <= int(tracer_stats_after_block.get("tracerNodesCreated", 0))
        and int(tracer_stats_after_reuse.get("tracerNodesReused", 0)) > int(tracer_stats_before.get("tracerNodesReused", 0))
    )
    add_result(
        "player_ranged_weapon_collision",
        blocked and hit_hostile and player_tracer_reused,
        "blocked %s, hit %s, first '%s' shots %d->%d arrows %d->%d->%d kind %s travel %.2f manual %d/%d exists %s, hit shots %d->%d arrows before %d, final '%s' kind %s travel %.2f manual %d/%d %s %s, pool %d, created %d->%d, reused %d->%d" % [
            str(blocked),
            str(hit_hostile),
            block_shot_message,
            shots_before_block,
            int(tracer_stats_after_block_fire.get("shotsFired", 0)),
            arrows_before_block,
            arrows_after_block_fire,
            arrows_after_block_wait,
            String(tracer_stats_after_block_fire.get("lastHitKind", "")),
            float(tracer_stats_after_block_fire.get("lastHitTravel", -1.0)),
            int(tracer_stats_after_block_fire.get("manualBlockHits", 0)),
            int(tracer_stats_after_block_fire.get("manualBlockCandidates", 0)),
            str(block_exists_after_shot),
            shots_before_hit,
            int(tracer_stats_after_reuse.get("shotsFired", 0)),
            arrows_before_hit,
            String(player_projectiles.last_message),
            final_hit_kind,
            final_hit_travel,
            final_manual_hits,
            final_manual_candidates,
            final_manual_type,
            final_manual_cell,
            int(tracer_stats_after_block.get("tracerPool", 0)),
            int(tracer_stats_before.get("tracerNodesCreated", 0)),
            int(tracer_stats_after_reuse.get("tracerNodesCreated", 0)),
            int(tracer_stats_before.get("tracerNodesReused", 0)),
            int(tracer_stats_after_reuse.get("tracerNodesReused", 0))
        ]
    )

func test_structure_and_town_generation() -> void:
    if not main:
        add_result("structure_system_present", false, "main missing")
        return
    var structure_system = main.get("structure_system")
    add_result("structure_system_present", structure_system != null, "structure system present")
    if structure_system == null:
        return

    var town: Dictionary = main.call("town_region", 1, 0)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    var level := float(town.get("level", 0.0))
    structure_system.call("build_town", town)
    var counts: Dictionary = structure_system.call("counts")
    add_result(
        "town_generation_counts",
        int(counts.get("buildings", 0)) >= 4 and int(counts.get("doors", 0)) >= 8 and int(counts.get("paths", 0)) > 20 and int(counts.get("utilities", 0)) >= 3,
        str(counts)
    )
    add_result(
        "town_biome_flattened",
        String(main.call("biome_at_cell", center_x, center_z)) == "town" and main.call("height_variation_cell", center_x, center_z, 5) <= 0.05,
        "biome %s, variation %.2f" % [String(main.call("biome_at_cell", center_x, center_z)), float(main.call("height_variation_cell", center_x, center_z, 5))]
    )

    var blocks := get_blocks()
    var generated_type_counts := {}
    var doors := []
    var paths := []
    var generated_glass_ground := 0
    var grounded_base_found := false
    var grounded_base_ok := false
    for block in blocks.values():
        var body := block as StaticBody3D
        if body == null or not bool(body.get_meta("generated", false)):
            continue
        var block_type := String(body.get_meta("block_type"))
        generated_type_counts[block_type] = int(generated_type_counts.get(block_type, 0)) + 1
        if block_type == "door":
            doors.append(body)
        elif block_type == "cobblestonePath":
            paths.append(body)
        elif block_type == "glass":
            var glass_ground: float = main.call("height_at_world", body.global_position.x, body.global_position.z)
            if body.global_position.y < glass_ground + CELL * 2.0:
                generated_glass_ground += 1
        elif (block_type == "woodBlock" or block_type == "stoneBlock") and body.global_position.y < level + CELL * 1.1:
            var shape := first_collision_shape(body)
            if shape != null and shape.shape is BoxShape3D:
                grounded_base_found = true
                var box := shape.shape as BoxShape3D
                var bottom := body.global_position.y + shape.position.y - box.size.y * 0.5
                grounded_base_ok = abs(bottom - level) <= 0.08

    add_result("structure_base_grounded", grounded_base_found and grounded_base_ok, "found %s, ok %s" % [str(grounded_base_found), str(grounded_base_ok)])
    add_result("no_ground_level_glass", generated_glass_ground == 0, "%d ground-level generated glass blocks" % generated_glass_ground)

    var paired_door := false
    for i in range(doors.size()):
        for j in range(i + 1, doors.size()):
            var a := doors[i] as StaticBody3D
            var b := doors[j] as StaticBody3D
            if abs(a.global_position.y - b.global_position.y) > 0.05:
                continue
            var distance := Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()
            if distance <= CELL * 1.15:
                paired_door = true
                break
        if paired_door:
            break
    add_result("double_doors_adjacent", paired_door, "%d generated doors, types %s" % [doors.size(), str(generated_type_counts)])

    if doors.is_empty():
        add_result("door_toggle_collision", false, "no generated door")
    else:
        var door := doors[0] as StaticBody3D
        var closed_shape := first_collision_shape(door)
        var pivot := door.get_node_or_null("DoorPivot") as Node3D
        var proxy := door.get_node_or_null("DoorInteraction") as Area3D
        var closed_body_rotation := door.rotation.y
        main.call("toggle_door", door)
        var opened_once: bool = bool(door.get_meta("open")) and closed_shape != null and closed_shape.disabled and pivot != null and abs(pivot.rotation.y) > 0.5 and abs(door.rotation.y - closed_body_rotation) < 0.001
        var closed_via_proxy := false
        var reopened_via_proxy := false
        if proxy:
            main.call("toggle_door", proxy)
            closed_via_proxy = not bool(door.get_meta("open")) and closed_shape != null and not closed_shape.disabled and pivot != null and abs(pivot.rotation.y) < 0.001
            main.call("toggle_door", proxy)
            reopened_via_proxy = bool(door.get_meta("open")) and closed_shape != null and closed_shape.disabled and pivot != null and abs(pivot.rotation.y) > 0.5
        add_result(
            "door_toggle_collision",
            opened_once and closed_via_proxy and reopened_via_proxy,
            "opened %s, closed proxy %s, reopened proxy %s, proxy %s, body rotation fixed %s" % [
                str(opened_once),
                str(closed_via_proxy),
                str(reopened_via_proxy),
                str(proxy != null),
                str(abs(door.rotation.y - closed_body_rotation) < 0.001)
            ]
        )

    if paths.is_empty():
        add_result("path_collision_low", false, "no generated path")
    else:
        var path := paths[0] as StaticBody3D
        var path_shape := first_collision_shape(path)
        var low := path_shape != null and path_shape.shape is BoxShape3D and (path_shape.shape as BoxShape3D).size.y <= CELL * 0.25
        add_result("path_collision_low", low, "path collision height %.2f" % ((path_shape.shape as BoxShape3D).size.y if low else -1.0))

    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("generic_town_npc_homes", false, "npc system missing")
    else:
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
        add_result(
            "generic_town_npc_homes",
            generic_homes.size() >= 4 and generic_npcs >= generic_homes.size() and generic_homed == generic_npcs and generic_fighters >= 1,
            "homes %d, npcs %d, homed %d, fighters %d" % [generic_homes.size(), generic_npcs, generic_homed, generic_fighters]
        )
        var job_workers := 0
        for entry_variant in npc_entries:
            var entry: Dictionary = entry_variant
            if String(entry.get("townKey", "")) != generic_key:
                continue
            if String(entry.get("job", "")) in ["forage", "wood", "stone"]:
                job_workers += 1
                entry["jobPhase"] = "idle"
                entry["jobTimer"] = 0.0
        var job_runs_before := int(npc_system.stats().get("jobRuns", 0))
        var saw_generic_worker_outside := false
        var town_radius_world := float(generic_town.get("radius", 32)) * CELL
        var town_center_world := Vector2(float(generic_center_x) * CELL, float(generic_center_z) * CELL)
        for step in range(360):
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
            if saw_generic_worker_outside and int(npc_system.stats().get("jobRuns", 0)) > job_runs_before:
                break
        var job_stats: Dictionary = npc_system.stats()
        add_result(
            "generic_npc_job_outings",
            job_workers >= 2 and saw_generic_worker_outside and int(job_stats.get("jobRuns", 0)) > job_runs_before,
            "workers %d, outside seen %s, runs %d->%d, stats %s" % [
                job_workers,
                str(saw_generic_worker_outside),
                job_runs_before,
                int(job_stats.get("jobRuns", 0)),
                str(job_stats)
            ]
        )

    cleanup_generated_blocks()

func test_npc_equipment_and_pathing() -> void:
    if not main or not player:
        add_result("npc_equipment_and_pathing", false, "main/player missing")
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        add_result("npc_equipment_and_pathing", false, "npc system missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 72, roundi(player.global_position.z / CELL) + 72)
    reset_player_on_flat_patch(start_cell)
    clear_blocks_near_cell(start_cell, 12)
    await wait_physics_frames(3)

    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var start_position := Vector3(float(start_cell.x) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var target_position := Vector3(float(start_cell.x + 8) * CELL, base_height + 0.04, float(start_cell.y) * CELL)
    var wall_x := start_cell.x + 3
    var wall_z := start_cell.y
    var wall_y := base_height + CELL * 0.48
    var wall_cell_y := floori(wall_y / CELL) + 1
    var wall_cells: Array[Vector3i] = []
    var blocks := get_blocks()
    for dz in range(-2, 3):
        var wall_cell := Vector3i(wall_x, wall_cell_y, wall_z + dz)
        wall_cells.append(wall_cell)
        if blocks.has(wall_cell):
            var old_wall := blocks[wall_cell] as Node
            if old_wall:
                old_wall.queue_free()
            blocks.erase(wall_cell)
        main.call("create_block", wall_cell, "stoneBlock", { "world_y": wall_y })
    await wait_physics_frames(3)

    var body := StaticBody3D.new()
    body.name = "PlaytestPathingNPC"
    body.collision_layer = 4
    body.collision_mask = 0
    body.position = start_position
    body.set_meta("kind", "npc")
    npc_system.call("add_npc_collider", body)
    var npc_root := npc_system.get("npc_root") as Node3D
    if npc_root:
        npc_root.add_child(body)
    else:
        npc_system.add_child(body)
    var entry: Dictionary = npc_system.register_npc(body, {
        "id": "playtest-pathing-npc",
        "name": "Path Tester",
        "role": "Guard",
        "townKey": "playtest-path",
        "townCenter": start_cell,
        "townRadius": 18,
        "level": base_height,
        "cell": start_cell,
        "homeCell": start_cell,
        "porchCell": start_cell,
        "guardCell": Vector2i(start_cell.x + 1, start_cell.y),
        "canFight": true,
        "nightGuard": true,
        "weapon": "woodenSword"
    })

    var weapon_visible := bool(body.get_meta("npc_weapon_visible", false)) and String(body.get_meta("npc_weapon", "")) == "woodenSword"
    var anchor := entry.get("heldAnchor") as Node3D
    var rest_rotation := anchor.rotation if anchor else Vector3.ZERO
    var uses_before := int(npc_system.stats().get("useAnimations", 0))
    npc_system.play_npc_use(entry, "strike")
    npc_system.update_npc_visual_state(entry, 0.08)
    var sword_animated := anchor != null and int(npc_system.stats().get("useAnimations", 0)) > uses_before and anchor.rotation.distance_to(rest_rotation) > 0.001

    var detours_before := int(npc_system.stats().get("pathDetours", 0))
    var max_lateral := 0.0
    for i in range(130):
        npc_system.move_npc(entry, target_position, CELL * 0.24, false, false)
        max_lateral = maxf(max_lateral, absf(body.global_position.z - start_position.z))
        await wait_physics_frames(1)
    var detours_after := int(npc_system.stats().get("pathDetours", 0))
    var wall_world_x := float(wall_x) * CELL
    var progressed_past_wall := body.global_position.x > wall_world_x + CELL * 0.35
    var detoured_around_wall := detours_after > detours_before and max_lateral > CELL * 0.75 and progressed_past_wall
    add_result(
        "npc_equipment_and_pathing",
        weapon_visible and sword_animated and detoured_around_wall,
        "weapon %s, sword animated %s, detours %d->%d, lateral %.2f, end %.2f %.2f, wall %.2f" % [
            str(weapon_visible),
            str(sword_animated),
            detours_before,
            detours_after,
            max_lateral,
            body.global_position.x,
            body.global_position.z,
            wall_world_x
        ]
    )

    npc_system.unregister_npc(body)
    if is_instance_valid(body):
        body.queue_free()
    blocks = get_blocks()
    for wall_cell in wall_cells:
        if blocks.has(wall_cell):
            var wall_body := blocks[wall_cell] as Node
            if wall_body:
                wall_body.queue_free()
            blocks.erase(wall_cell)

func test_structural_integrity() -> void:
    if not main or not player:
        add_result("structural_integrity", false, "main or player missing")
        return

    main.call("clear_dropped_pickups")
    var blocks := get_blocks()
    var base_x := roundi(player.global_position.x / CELL) + 78
    var base_z := roundi(player.global_position.z / CELL) + 41
    var ground: float = float(main.call("terrain_height_cell", base_x, base_z))
    var world_y := ground + CELL * 0.48
    var grounded_cell := Vector3i(base_x, floori(world_y / CELL) + 1, base_z)
    var grounded_top := grounded_cell + Vector3i(0, 1, 0)
    var floating_cell := Vector3i(base_x + 3, grounded_cell.y + 7, base_z)
    var floating_top := floating_cell + Vector3i(0, 1, 0)

    for cell in [grounded_cell, grounded_top, floating_cell, floating_top]:
        if blocks.has(cell):
            var existing := blocks[cell] as Node
            if existing:
                existing.queue_free()
            blocks.erase(cell)

    main.call("create_block", grounded_cell, "woodBlock", { "player_placed": true, "world_y": world_y })
    main.call("create_block", grounded_top, "woodBlock", { "player_placed": true, "world_y": world_y + CELL })
    main.call("create_block", floating_cell, "woodBlock", { "player_placed": true })
    main.call("create_block", floating_top, "woodBlock", { "player_placed": true })
    var collapsed: int = int(main.call("collapse_unsupported_structures"))
    var dropped_pickups: Array = main.get("dropped_pickups")
    var grounded_ok := blocks.has(grounded_cell) and blocks.has(grounded_top)
    var floating_removed := not blocks.has(floating_cell) and not blocks.has(floating_top)
    var drops_ok := dropped_pickups.size() >= 2
    add_result(
        "structural_integrity_supports_grounded_collapses_floating",
        collapsed >= 2 and grounded_ok and floating_removed and drops_ok,
        "collapsed %d, grounded %s, floating removed %s, drops %d" % [
            collapsed,
            str(grounded_ok),
            str(floating_removed),
            dropped_pickups.size()
        ]
    )

    for cell in [grounded_cell, grounded_top]:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    main.call("clear_dropped_pickups")

func test_landmark_generation_and_loot() -> void:
    if not main or not player:
        add_result("landmark_generation_and_loot", false, "main or player missing")
        return
    var structure_system = main.get("structure_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var hostile_system = main.get("hostile_system")
    var progression_system = main.get("progression_system")
    var present: bool = structure_system != null and objective_system != null and contract_system != null and hostile_system != null and progression_system != null
    if not present:
        add_result("landmark_generation_and_loot", false, "structure/objective/contract/hostile/progression system missing")
        return

    cleanup_generated_blocks()
    hostile_system.clear()
    var original_position: Vector3 = player.global_position
    var discovered_shrines: Dictionary = main.get("discovered_shrine_keys")
    var discovered_mines: Dictionary = main.get("discovered_mine_keys")
    var discovered_ruins: Dictionary = main.get("discovered_ruin_keys")
    var discovered_camps: Dictionary = main.get("discovered_camp_keys")
    discovered_shrines.clear()
    discovered_mines.clear()
    discovered_ruins.clear()
    discovered_camps.clear()
    var base_cell := Vector2i(roundi(player.global_position.x / CELL) + 34, roundi(player.global_position.z / CELL) + 18)
    var level: float = maxf(float(main.call("terrain_height_cell", base_cell.x, base_cell.y)), WATER_LEVEL + 2.4)
    var edits := get_height_edits()
    for dz in range(-8, 24):
        for dx in range(-8, 76):
            edits[Vector2i(base_cell.x + dx, base_cell.y + dz)] = level
    main.call("rebuild_chunks_around_cell", base_cell)

    var rng := RandomNumberGenerator.new()
    rng.seed = 41001
    structure_system.call("build_mine", base_cell.x, base_cell.y, level, 11, 13, rng)
    rng.seed = 41002
    structure_system.call("build_ruin", base_cell.x + 18, base_cell.y, level, 9, 9, rng)
    rng.seed = 41003
    structure_system.call("build_shrine", base_cell.x + 36, base_cell.y, level, 9, 9, rng)
    rng.seed = 41004
    structure_system.call("build_camp", base_cell.x + 54, base_cell.y, level, 12, 11, rng)

    var tier_counts: Dictionary = main.call("generated_tier_counts")
    var counts: Dictionary = structure_system.call("counts")
    var blocks := get_blocks()
    var mine_ore_blocks := 0
    var mine_ore_glints := 0
    var mine_torches := 0
    var camp_fire_count := 0
    var camp_torches := 0
    var camp_traps := 0
    var camp_barricades := 0
    var shrine_chest: Node = null
    var chest_tiers := {}
    var loot_checks := {
        "mine": false,
        "ruin": false,
        "shrine": false,
        "camp": false
    }
    for block_value in blocks.values():
        var body := block_value as Node
        if body == null or not body.has_meta("generatedTier"):
            continue
        var tier := String(body.get_meta("generatedTier"))
        var block_type := String(body.get_meta("block_type", ""))
        if tier == "mine" and block_type in ["copperVein", "ironVein"]:
            mine_ore_blocks += 1
            mine_ore_glints += count_named_descendants(body, "OreBlockGlint")
        if tier == "mine" and block_type == "torch":
            mine_torches += 1
        if tier == "camp" and block_type == "campfire":
            camp_fire_count += 1
        if tier == "camp" and block_type == "torch":
            camp_torches += 1
        if tier == "camp" and block_type == "spikeTrap":
            camp_traps += 1
        if tier == "camp" and block_type == "woodBlock":
            camp_barricades += 1
        if tier == "shrine" and block_type == "chest":
            shrine_chest = body
        if block_type != "chest":
            continue
        chest_tiers[tier] = int(chest_tiers.get(tier, 0)) + 1
        if not body.has_meta("storage_slots"):
            continue
        var slots: Array = body.get_meta("storage_slots")
        for slot in slots:
            if not (slot is Dictionary):
                continue
            var item_id := String(slot.get("item", ""))
            var count := int(slot.get("count", 0))
            if count <= 0:
                continue
            if tier == "mine" and item_id in ["copperOre", "ironOre"]:
                loot_checks["mine"] = true
            elif tier == "ruin" and item_id == "relicFragment":
                loot_checks["ruin"] = true
            elif tier == "shrine" and item_id == "nightShard":
                loot_checks["shrine"] = true
            elif tier == "camp" and item_id in ["arrows", "fieldRation"]:
                loot_checks["camp"] = true

    var discovery_xp_before: int = int(progression_system.total_xp)
    player.global_position = Vector3(float(base_cell.x + 2) * CELL, level + 0.8, float(base_cell.y + 2) * CELL)
    main.call("update_hud")
    var mine_discovered: bool = discovered_mines.size() > 0
    var mine_ambush: bool = hostile_system.enemies.size() >= 2
    hostile_system.clear()
    player.global_position = Vector3(float(base_cell.x + 20) * CELL, level + 0.8, float(base_cell.y + 2) * CELL)
    main.call("update_hud")
    var ruin_discovered: bool = discovered_ruins.size() > 0
    var ruin_ambush: bool = hostile_system.enemies.size() >= 1
    hostile_system.clear()
    var shrine_opened: bool = shrine_chest != null and bool(main.call("discover_shrine_cache", shrine_chest))
    var shrine_discovered: bool = discovered_shrines.size() > 0
    var shrine_guardians: bool = hostile_system.enemies.size() >= 1
    hostile_system.clear()
    player.global_position = Vector3(float(base_cell.x + 58) * CELL, level + 0.8, float(base_cell.y + 3) * CELL)
    main.call("update_hud")
    var camp_discovered: bool = discovered_camps.size() > 0
    var camp_ambush: bool = hostile_system.enemies.size() >= 3
    var discovery_xp: bool = int(progression_system.total_xp) > discovery_xp_before
    add_result(
        "landmark_discovery_ambush_parity",
        mine_discovered and mine_ambush and ruin_discovered and ruin_ambush and shrine_opened and shrine_discovered and shrine_guardians and camp_discovered and camp_ambush and discovery_xp,
        "mine %s/%s, ruin %s/%s, shrine %s/%s/%s, camp %s/%s, xp %d->%d" % [
            str(mine_discovered),
            str(mine_ambush),
            str(ruin_discovered),
            str(ruin_ambush),
            str(shrine_opened),
            str(shrine_discovered),
            str(shrine_guardians),
            str(camp_discovered),
            str(camp_ambush),
            discovery_xp_before,
            int(progression_system.total_xp)
        ]
    )
    hostile_system.clear()
    player.global_position = original_position

    var state: Dictionary = main.call("objective_state")
    state["discoveredTowns"] = max(1, int(state.get("discoveredTowns", 0)))
    var hostile_state: Dictionary = state.get("hostiles", {})
    hostile_state["defeated"] = max(3, int(hostile_state.get("defeated", 0)))
    state["hostiles"] = hostile_state
    var landmark_objective: bool = bool(objective_system.is_complete("landmarkScout", state))
    var camp_objective: bool = bool(objective_system.is_complete("enemyCamp", state))
    var shrine_objective: bool = bool(objective_system.is_complete("shrine", state))
    var prospector_contract: bool = bool(contract_system.is_contract_complete("prospector", state))
    var ruin_contract: bool = bool(contract_system.is_contract_complete("ruinSurveyor", state))
    var camp_contract: bool = bool(contract_system.is_contract_complete("campClear", state))
    var passed: bool = (
        int(tier_counts.get("mine", 0)) > 0
        and int(tier_counts.get("ruin", 0)) > 0
        and int(tier_counts.get("shrine", 0)) > 0
        and int(tier_counts.get("camp", 0)) > 0
        and mine_ore_blocks > 0
        and mine_ore_glints >= mine_ore_blocks
        and mine_torches >= 4
        and camp_fire_count >= 1
        and camp_torches >= 4
        and camp_traps >= 3
        and camp_barricades >= 4
        and bool(loot_checks.get("mine", false))
        and bool(loot_checks.get("ruin", false))
        and bool(loot_checks.get("shrine", false))
        and bool(loot_checks.get("camp", false))
        and landmark_objective
        and camp_objective
        and shrine_objective
        and prospector_contract
        and ruin_contract
        and camp_contract
    )
    add_result(
        "landmark_generation_and_loot",
        passed,
        "tiers %s, counts %s, chests %s, ore blocks %d, glints %d, mine torches %d, camp fire/torches/traps/barricades %d/%d/%d/%d, loot %s, objectives %s/%s/%s, contracts %s/%s/%s" % [
            str(tier_counts),
            str(counts),
            str(chest_tiers),
            mine_ore_blocks,
            mine_ore_glints,
            mine_torches,
            camp_fire_count,
            camp_torches,
            camp_traps,
            camp_barricades,
            str(loot_checks),
            str(landmark_objective),
            str(camp_objective),
            str(shrine_objective),
            str(prospector_contract),
            str(ruin_contract),
            str(camp_contract)
        ]
    )
    hostile_system.clear()
    cleanup_generated_blocks()

func test_ore_generation_and_drops() -> void:
    if not main:
        add_result("ore_generation_and_drops", false, "main missing")
        return
    var inventory_system = main.get("inventory_system")
    var prop_root = main.get("prop_root") as Node3D
    if inventory_system == null or prop_root == null:
        add_result("ore_generation_and_drops", false, "inventory or prop root missing")
        return

    var rng := RandomNumberGenerator.new()
    rng.seed = 481516
    var copper_seen := false
    var iron_seen := false
    for i in range(260):
        var ore: String = main.call("ore_for_cell", "alpine", 72.0, rng)
        copper_seen = copper_seen or ore == "copperOre"
        iron_seen = iron_seen or ore == "ironOre"
        if copper_seen and iron_seen:
            break

    var copper_before: int = inventory_system.count("copperOre")
    rng.seed = 9901
    var cluster_nodes: Array = main.call("make_ore_cluster", prop_root, "playtest:copperOreCluster", player.global_position + Vector3(3.0, 0.0, 0.0), "copperOre", rng, 3)
    var ore_body := cluster_nodes[0] as StaticBody3D if cluster_nodes.size() > 0 else null
    var copper_visual_ok := false
    var copper_meshes := 0
    var copper_children := 0
    if ore_body:
        copper_meshes = count_mesh_descendants(ore_body)
        copper_children = ore_body.get_child_count()
        copper_visual_ok = (
            copper_meshes >= 9
            and copper_children >= 10
            and String(ore_body.get_meta("ore_type", "")) == "copperOre"
        )
        main.call("complete_destroy_target", { "position": ore_body.global_position + Vector3.UP, "normal": Vector3.UP }, ore_body, "prop", "copperOre")
    var dropped: bool = inventory_system.count("copperOre") > copper_before
    rng.seed = 9902
    var iron_body := main.call("make_ore", prop_root, "playtest:ironOreVisual", player.global_position + Vector3(5.5, 0.0, 0.0), "ironOre", rng) as StaticBody3D
    var iron_meshes := count_mesh_descendants(iron_body) if iron_body != null else 0
    var iron_children := iron_body.get_child_count() if iron_body != null else 0
    var iron_visual_ok := iron_body != null and iron_meshes >= 9 and iron_children >= 10 and String(iron_body.get_meta("ore_type", "")) == "ironOre"
    for node_value in cluster_nodes:
        var node := node_value as Node
        if node != null and is_instance_valid(node):
            node.queue_free()
    if iron_body != null and is_instance_valid(iron_body):
        iron_body.queue_free()
    add_result(
        "ore_generation_and_drops",
        copper_seen and iron_seen and dropped and copper_visual_ok and iron_visual_ok and cluster_nodes.size() >= 3,
        "copper seen %s, iron seen %s, copper %d->%d, visuals %s/%s meshes %d/%d children %d/%d, cluster %d" % [
            str(copper_seen),
            str(iron_seen),
            copper_before,
            inventory_system.count("copperOre"),
            str(copper_visual_ok),
            str(iron_visual_ok),
            copper_meshes,
            iron_meshes,
            copper_children,
            iron_children,
            cluster_nodes.size()
        ]
    )

func test_forage_and_wildlife_drops() -> void:
    if not main or not player:
        add_result("forage_and_wildlife_drops", false, "main or player missing")
        return
    var inventory_system = main.get("inventory_system")
    var prop_root = main.get("prop_root") as Node3D
    if inventory_system == null or prop_root == null:
        add_result("forage_and_wildlife_drops", false, "inventory or prop root missing")
        return

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    var expectations := {
        "plains": { "material": "berryBush", "drop": "berries" },
        "desert": { "material": "aloePatch", "drop": "aloe" },
        "swamp": { "material": "mushroomCluster", "drop": "mirecap" },
        "snow": { "material": "frostHerbPatch", "drop": "frostHerb" }
    }
    var rng := RandomNumberGenerator.new()
    rng.seed = 772031
    var forage_ok := true
    var forage_details := []
    var offset := 0.0
    for biome in expectations.keys():
        var expected: Dictionary = expectations[biome]
        var spec: Dictionary = main.call("forage_for_biome", String(biome))
        var material_id := String(spec.get("material", ""))
        var drop_id := String(spec.get("drop", ""))
        var before: int = inventory_system.count(drop_id)
        var child_count := prop_root.get_child_count()
        main.call("make_forage", prop_root, "playtest:forage:%s" % String(biome), player.global_position + Vector3(3.0 + offset, 0.0, 3.0), String(biome), rng)
        var forage_body := prop_root.get_child(child_count) as StaticBody3D
        if forage_body:
            main.call("complete_destroy_target", { "position": forage_body.global_position + Vector3.UP, "normal": Vector3.UP }, forage_body, "prop", material_id)
        var dropped: bool = inventory_system.count(drop_id) > before
        var matched: bool = material_id == String(expected.get("material", "")) and drop_id == String(expected.get("drop", ""))
        forage_ok = forage_ok and matched and dropped
        forage_details.append("%s:%s/%s %d->%d" % [String(biome), material_id, drop_id, before, inventory_system.count(drop_id)])
        offset += 1.6

    var meat_before: int = inventory_system.count("rawMeat")
    var hide_before: int = inventory_system.count("hide")
    var child_count := prop_root.get_child_count()
    main.call("make_wildlife", prop_root, "playtest:wildlife", player.global_position + Vector3(3.0, 0.0, 5.0), "snow", rng)
    var wildlife_body := prop_root.get_child(child_count) as StaticBody3D
    var wildlife_start := wildlife_body.global_position if wildlife_body else Vector3.ZERO
    if wildlife_body:
        for i in range(10):
            main.call("update_wildlife", 0.125)
    var wildlife_roamed := wildlife_body != null and is_instance_valid(wildlife_body) and wildlife_body.global_position.distance_to(wildlife_start) > 0.08
    var wildlife_roam_distance := wildlife_body.global_position.distance_to(wildlife_start) if wildlife_body != null and is_instance_valid(wildlife_body) else 0.0
    if wildlife_body:
        main.call("complete_destroy_target", { "position": wildlife_body.global_position + Vector3.UP, "normal": Vector3.UP }, wildlife_body, "prop", "wildlife")
    var meat_after: int = inventory_system.count("rawMeat")
    var hide_after: int = inventory_system.count("hide")
    var wildlife_drop_ok: bool = meat_after > meat_before and hide_after > hide_before

    var logs_before: int = inventory_system.count("logs")
    child_count = prop_root.get_child_count()
    main.call("make_tree", prop_root, "playtest:tree", player.global_position + Vector3(6.0, 0.0, 5.0), "forest", rng)
    var tree_body := prop_root.get_child(child_count) as StaticBody3D
    if tree_body:
        main.call("complete_destroy_target", { "position": tree_body.global_position + Vector3.UP, "normal": Vector3.UP }, tree_body, "prop", "tree")
    var falling_tree_found := false
    for child in prop_root.get_children():
        var node := child as Node
        if node and node.name.begins_with("FallingTree"):
            falling_tree_found = true
            node.queue_free()
    add_result(
        "tree_fall_visual_and_logs",
        falling_tree_found and inventory_system.count("logs") > logs_before,
        "falling %s, logs %d->%d" % [str(falling_tree_found), logs_before, inventory_system.count("logs")]
    )

    inventory_system.clear()
    inventory_system.add_item("stoneSword", 1)
    set_active_inventory_item(inventory_system, "stoneSword")
    var sword_power_ok := float(main.call("tool_power_for_material", "wildlife")) >= 4.0
    inventory_system.clear()
    inventory_system.add_item("stoneShovel", 1)
    set_active_inventory_item(inventory_system, "stoneShovel")
    var shovel_power_ok := float(main.call("tool_power_for_material", "berryBush")) >= 3.0

    add_result(
        "forage_and_wildlife_drops",
        forage_ok and wildlife_drop_ok and wildlife_roamed and sword_power_ok and shovel_power_ok,
        "forage %s, meat %d->%d, hide %d->%d, roamed %.2f, sword %s, shovel %s" % [
            str(forage_details),
            meat_before,
            meat_after,
            hide_before,
            hide_after,
            wildlife_roam_distance,
            str(sword_power_ok),
            str(shovel_power_ok)
        ]
    )
    inventory_system.restore(original_inventory)

func cleanup_generated_blocks() -> void:
    var blocks := get_blocks()
    for key in blocks.keys():
        var body := blocks[key] as Node
        if body != null and bool(body.get_meta("generated", false)):
            body.queue_free()
            blocks.erase(key)

func first_collision_shape(node: Node) -> CollisionShape3D:
    for child in node.get_children():
        if child is CollisionShape3D:
            return child
    return null

func test_spawn_clearance() -> void:
    if not player or not camera:
        add_result("spawn_clearance", false, "player or camera missing")
        return
    var terrain_height: float = main.call("height_at_world", player.global_position.x, player.global_position.z)
    var camera_clearance: float = camera.global_position.y - terrain_height
    var above_water: bool = player.global_position.y > WATER_LEVEL + 1.2
    var clear: bool = camera_clearance > 1.25 and above_water
    add_result("spawn_clearance", clear, "camera clearance %.2f, player y %.2f" % [camera_clearance, player.global_position.y])

func test_terrain_collision_shapes() -> void:
    var chunks := get_chunks()
    var checked := 0
    var with_shape := 0
    for chunk_node in chunks.values():
        var chunk := chunk_node as Node
        if not chunk:
            continue
        var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
        if not body:
            continue
        checked += 1
        var shape_node := body.get_node_or_null("TerrainCollision") as CollisionShape3D
        if shape_node and shape_node.shape:
            with_shape += 1
    add_result("terrain_collision_shapes", checked > 0 and checked == with_shape, "%d/%d chunks with shapes" % [with_shape, checked])

func test_terrain_generation_profile() -> void:
    if not main:
        add_result("terrain_generation_profile", false, "main missing")
        return
    var normal_biomes := ["plains", "forest", "savanna", "taiga"]
    var mountain_biomes := ["snow", "alpine", "tundra"]
    var normal_samples := 0
    var smooth_samples := 0
    var variation_total := 0.0
    var mountain_samples := 0
    var max_mountain := 0.0
    for z in range(-360, 361, 12):
        for x in range(-360, 361, 12):
            var height := float(main.call("terrain_height_cell", x, z))
            var biome := String(main.call("biome_at_cell", x, z))
            if normal_biomes.has(biome) and height > WATER_LEVEL + 2.4 and height < 56.0:
                var variation := float(main.call("height_variation_cell", x, z, 1))
                variation_total += variation
                normal_samples += 1
                if variation <= CELL:
                    smooth_samples += 1
            elif mountain_biomes.has(biome) and height >= 62.0:
                mountain_samples += 1
                max_mountain = maxf(max_mountain, height)
    var average_variation := variation_total / float(maxi(1, normal_samples))
    var smooth_ratio := float(smooth_samples) / float(maxi(1, normal_samples))
    var mountain_cell: Vector2i = main.call("find_biome_playtest_cell", mountain_biomes, 62.0, 120.0, false)
    var mountain_target_found := mountain_cell != Vector2i(999999, 999999)
    var mountain_target_height := 0.0
    if mountain_target_found:
        mountain_target_height = float(main.call("terrain_height_cell", mountain_cell.x, mountain_cell.y))
        max_mountain = maxf(max_mountain, mountain_target_height)
    var mountain_ok := (mountain_samples > 0 and max_mountain >= 62.0) or (mountain_target_found and mountain_target_height >= 62.0)
    add_result(
        "terrain_generation_profile",
        normal_samples >= 80
            and average_variation <= CELL * 1.15
            and smooth_ratio >= 0.45
            and mountain_ok
            and mountain_target_found,
        "normal %d, avg variation %.2f, smooth %.0f%%, mountain samples %d, max %.2f, target %s height %.2f" % [
            normal_samples,
            average_variation,
            smooth_ratio * 100.0,
            mountain_samples,
            max_mountain,
            str(mountain_cell),
            mountain_target_height
        ]
    )

func test_world_chunk_streaming() -> void:
    if not main or not player:
        add_result("world_chunk_streaming", false, "main or player missing")
        return

    var original_position: Vector3 = player.global_position
    var original_chunk: Vector2i = main.call("world_to_chunk", original_position.x, original_position.z)
    var cache_before: Dictionary = main.call("chunk_asset_cache_stats")
    var target_x := original_position.x + CELL * 128.0
    var target_z := original_position.z + CELL * 96.0
    var target_y: float = float(main.call("height_at_world", target_x, target_z)) + 0.45
    player.global_position = Vector3(target_x, target_y, target_z)
    main.call("update_chunks", true)
    await wait_physics_frames(2)
    var cache_after_stream_out: Dictionary = main.call("chunk_asset_cache_stats")

    var chunks := get_chunks()
    var target_chunk: Vector2i = main.call("world_to_chunk", target_x, target_z)
    var target_node := chunks.get(target_chunk, null) as Node
    var target_body := target_node.get_node_or_null("TerrainBody") as StaticBody3D if target_node else null
    var target_shape := target_body.get_node_or_null("TerrainCollision") as CollisionShape3D if target_body else null
    var streamed := target_chunk != original_chunk and chunks.has(target_chunk) and chunks.size() >= 49
    var collision_ready := target_shape != null and target_shape.shape != null
    add_result(
        "world_chunk_streaming",
        streamed and collision_ready,
        "chunk %s->%s, chunks %d, target collision %s" % [
            str(original_chunk),
            str(target_chunk),
            chunks.size(),
            str(collision_ready)
        ]
    )

    player.global_position = original_position
    main.call("update_chunks", true)
    await wait_physics_frames(2)
    var cache_after_return: Dictionary = main.call("chunk_asset_cache_stats")
    var cache_hit: bool = int(cache_after_return.get("hits", 0)) > int(cache_after_stream_out.get("hits", 0))
    var invalidations_before: int = int(cache_after_return.get("invalidations", 0))
    var edits := get_height_edits()
    var edit_cell := Vector2i(main.call("world_to_cell", original_position.x), main.call("world_to_cell", original_position.z))
    edits[edit_cell] = float(main.call("terrain_height_cell", edit_cell.x, edit_cell.y)) + CELL
    main.call("rebuild_chunks_around_cell", edit_cell)
    var cache_after_invalidation: Dictionary = main.call("chunk_asset_cache_stats")
    var invalidated: bool = int(cache_after_invalidation.get("invalidations", 0)) > invalidations_before
    edits.erase(edit_cell)
    main.call("rebuild_chunks_around_cell", edit_cell)
    add_result(
        "chunk_asset_cache_reuse_invalidation",
        cache_hit and invalidated and int(cache_after_invalidation.get("entries", 0)) <= 96,
        "hits %d->%d->%d, misses %d->%d, entries %d, invalidations %d->%d" % [
            int(cache_before.get("hits", 0)),
            int(cache_after_stream_out.get("hits", 0)),
            int(cache_after_return.get("hits", 0)),
            int(cache_before.get("misses", 0)),
            int(cache_after_return.get("misses", 0)),
            int(cache_after_invalidation.get("entries", 0)),
            invalidations_before,
            int(cache_after_invalidation.get("invalidations", 0))
        ]
    )

func test_chunk_detail_batches() -> void:
    if not main:
        add_result("chunk_detail_batches", false, "main missing")
        return
    var chunks := get_chunks()
    var batch_nodes := 0
    var detail_instances := 0
    var collider_count := 0
    var chunk_count_with_decor := 0
    var detail_types := {}
    for chunk_node_variant in chunks.values():
        var chunk_node := chunk_node_variant as Node
        if chunk_node == null:
            continue
        var decor_root := chunk_node.get_node_or_null("DecorBatches")
        if decor_root == null:
            continue
        chunk_count_with_decor += 1
        collider_count += count_collision_descendants(decor_root)
        for child in decor_root.get_children():
            var batch := child as MultiMeshInstance3D
            if batch == null or batch.multimesh == null:
                continue
            batch_nodes += 1
            detail_instances += batch.multimesh.instance_count
            detail_types[String(batch.get_meta("detail_type", "unknown"))] = true
    var batched: bool = batch_nodes > 0 and detail_instances > batch_nodes * 3
    add_result(
        "chunk_detail_batches",
        batched and collider_count == 0 and detail_types.size() >= 3,
        "chunks %d/%d, batches %d, instances %d, colliders %d, types %s" % [
            chunk_count_with_decor,
            chunks.size(),
            batch_nodes,
            detail_instances,
            collider_count,
            str(detail_types.keys())
        ]
    )

func test_sky_light_consistency() -> void:
    if not main or not player:
        add_result("sky_light_consistency", false, "main or player missing")
        return
    var sun_light := main.get("sun") as DirectionalLight3D
    var sun_disc := main.get("sun_visual") as MeshInstance3D
    if not sun_light or not sun_disc:
        add_result("sky_light_consistency", false, "sun light or disc missing")
        return
    var day_factor := float(main.call("clock_day_factor")) if main.has_method("clock_day_factor") else 1.0
    var casts_day_shadows := sun_light.shadow_enabled and sun_light.light_energy > 0.1
    var sun_above_player := sun_disc.visible and sun_disc.global_position.y > player.global_position.y + 40.0
    add_result(
        "sky_light_consistency",
        not casts_day_shadows or (day_factor > 0.18 and sun_above_player),
        "clock day %.2f, sun shadows %s, disc visible %s, disc y %.2f, player y %.2f" % [
            day_factor,
            str(casts_day_shadows),
            str(sun_disc.visible),
            sun_disc.global_position.y,
            player.global_position.y
        ]
    )

func test_environment_visual_style() -> void:
    if not main:
        add_result("environment_visual_style", false, "main missing")
        return
    var world_env := main.get("world_environment") as WorldEnvironment
    var sun_light := main.get("sun") as DirectionalLight3D
    var moon_light := main.get("moon") as DirectionalLight3D
    if world_env == null or world_env.environment == null or sun_light == null or moon_light == null:
        add_result("environment_visual_style", false, "environment or lights missing")
        return
    var env := world_env.environment
    var sky_mat := main.get("sky_material") as ProceduralSkyMaterial
    var style := main.get("visual_style") as Resource
    var structure_ok := env.background_mode == Environment.BG_SKY \
        and env.sky != null \
        and sky_mat != null \
        and env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY \
        and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC \
        and env.fog_enabled \
        and bool(env.get("ssao_enabled")) \
        and style != null
    var original_time := float(main.get("time_of_day"))
    main.set("time_of_day", 0.25)
    main.call("update_sky", 0.0)
    var noon_sun := sun_light.light_energy
    var noon_ambient := env.ambient_light_energy
    var noon_fog := env.fog_density
    main.set("time_of_day", 0.75)
    main.call("update_sky", 0.0)
    var night_sun := sun_light.light_energy
    var night_moon := moon_light.light_energy
    var night_ambient := env.ambient_light_energy
    var night_fog := env.fog_density
    main.set("time_of_day", original_time)
    main.call("update_sky", 0.0)
    var range_ok := noon_sun >= 0.55 \
        and noon_sun <= 1.70 \
        and noon_ambient >= 0.34 \
        and noon_ambient <= 0.62 \
        and noon_fog >= 0.002 \
        and noon_fog <= 0.020 \
        and night_sun <= 0.12 \
        and night_moon >= 0.09 \
        and night_moon <= 0.30 \
        and night_ambient >= 0.13 \
        and night_ambient <= 0.34 \
        and night_fog >= 0.004 \
        and night_fog <= 0.030
    add_result(
        "environment_visual_style",
        structure_ok and range_ok,
        "sky %s, filmic %s, sky ambient %s, fog %s, ssao %s, noon sun %.2f amb %.2f fog %.4f, night sun %.2f moon %.2f amb %.2f fog %.4f" % [
            str(env.background_mode == Environment.BG_SKY and env.sky != null and sky_mat != null),
            str(env.tonemap_mode == Environment.TONE_MAPPER_FILMIC),
            str(env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY),
            str(env.fog_enabled),
            str(bool(env.get("ssao_enabled"))),
            noon_sun,
            noon_ambient,
            noon_fog,
            night_sun,
            night_moon,
            night_ambient,
            night_fog
        ]
    )

func test_weather_visual_system() -> void:
    if not main or not player:
        add_result("weather_visual_system", false, "main or player missing")
        return
    var weather_system = main.get("weather_system")
    if weather_system == null:
        add_result("weather_visual_system", false, "weather system missing")
        return

    weather_system.force_weather("rain", 0.82, 0.90, player.global_position)
    var rain_state: Dictionary = weather_system.snapshot()
    weather_system.force_weather("snow", 0.78, 0.86, player.global_position)
    var snow_state: Dictionary = weather_system.snapshot()
    weather_system.force_weather("clear", 0.0, 0.10, player.global_position)
    var star_state: Dictionary = weather_system.snapshot()
    add_result(
        "weather_visual_system",
        bool(rain_state.get("rainVisible", false))
            and bool(snow_state.get("snowVisible", false))
            and bool(star_state.get("starsVisible", false))
            and int(star_state.get("clouds", 0)) >= 12
            and int(star_state.get("stars", 0)) >= 100,
        "rain %s, snow %s, stars %s, clouds %d, stars %d" % [
            str(rain_state.get("rainVisible", false)),
            str(snow_state.get("snowVisible", false)),
            str(star_state.get("starsVisible", false)),
            int(star_state.get("clouds", 0)),
            int(star_state.get("stars", 0))
        ]
    )

func test_player_movement() -> void:
    if not player:
        add_result("player_movement", false, "player missing")
        return
    var start: Vector3 = player.global_position
    player.set("automated_move", Vector3.RIGHT)
    await wait_physics_frames(70)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(10)
    var travel: float = Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
    var velocity: Vector3 = player.velocity
    var move_value: Vector3 = player.get("automated_move")
    var max_downward_correction: float = player.get("max_downward_terrain_correction")
    add_result(
        "player_movement",
        travel > 4.0,
        "travel %.2f, ticks %d, floor %s, velocity %s, automated_move %s" % [
            travel,
            int(player.get("physics_ticks")),
            str(is_player_grounded()),
            str(velocity),
            str(move_value)
        ]
    )
    add_result("terrain_descent_smoothing", max_downward_correction <= 0.22, "max downward correction %.3f" % max_downward_correction)

    var pre_path_position: Vector3 = player.global_position
    var pre_path_velocity: Vector3 = player.velocity
    var path_base := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL) + 2)
    reset_player_on_flat_patch(path_base)
    await wait_physics_frames(8)
    var path_ground: float = main.call("terrain_height_cell", path_base.x, path_base.y)
    var path_cells: Array[Vector3i] = []
    var blocks := get_blocks()
    for dx in range(0, 6):
        var path_cell := Vector3i(path_base.x + dx, roundi(path_ground / CELL), path_base.y)
        path_cells.append(path_cell)
        if blocks.has(path_cell):
            var old_path := blocks[path_cell] as Node
            if old_path:
                old_path.queue_free()
            blocks.erase(path_cell)
        main.call("create_block", path_cell, "cobblestonePath", { "world_y": path_ground + CELL * 0.024 })
    player.global_position = Vector3((path_base.x - 1.15) * CELL, path_ground, float(path_base.y) * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    await wait_physics_frames(8)
    var path_start_x: float = player.global_position.x
    var path_max_y: float = player.global_position.y
    player.set("automated_move", Vector3.RIGHT)
    for i in range(45):
        await get_tree().physics_frame
        path_max_y = maxf(path_max_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(4)
    var path_travel: float = player.global_position.x - path_start_x
    var path_rise: float = path_max_y - path_ground
    blocks = get_blocks()
    for path_cell in path_cells:
        if blocks.has(path_cell):
            var path_body := blocks[path_cell] as Node
            if path_body:
                path_body.queue_free()
            blocks.erase(path_cell)
    player.global_position = pre_path_position
    player.velocity = pre_path_velocity
    player.set("terrain_grounded", true)
    add_result(
        "cobblestone_path_walkable",
        path_travel > CELL * 4.1 and path_rise < 0.18,
        "travel %.2f, rise %.3f" % [path_travel, path_rise]
    )

func test_uphill_smoothing() -> void:
    if not player or not main:
        add_result("terrain_ascent_smoothing", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL), roundi(player.global_position.z / CELL))
    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var edits := get_height_edits()

    for dz in range(-1, 2):
        edits[Vector2i(start_cell.x, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = base_height + CELL
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = base_height + CELL

    main.call("rebuild_chunks_around_cell", start_cell)
    main.call("rebuild_chunks_around_cell", Vector2i(start_cell.x + 2, start_cell.y))
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("max_upward_terrain_correction", 0.0)
    await wait_physics_frames(8)

    player.set("automated_move", Vector3.RIGHT)
    var peak_y: float = player.global_position.y
    for i in range(32):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(8)

    var max_upward_correction: float = player.get("max_upward_terrain_correction")
    var climbed: float = peak_y - base_height
    add_result(
        "terrain_ascent_smoothing",
        max_upward_correction <= 0.18 and climbed > 0.55,
        "max upward correction %.3f, climbed %.2f" % [max_upward_correction, climbed]
    )

func test_steep_uphill_blocking() -> void:
    if not player or not main:
        add_result("terrain_steep_ascent_blocking", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 6, roundi(player.global_position.z / CELL))
    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var edits := get_height_edits()

    for dz in range(-1, 2):
        edits[Vector2i(start_cell.x, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = base_height + CELL * 3.0
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = base_height + CELL * 3.0

    main.call("rebuild_chunks_around_cell", start_cell)
    main.call("rebuild_chunks_around_cell", Vector2i(start_cell.x + 2, start_cell.y))
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("max_upward_terrain_correction", 0.0)
    await wait_physics_frames(8)

    var start_x: float = player.global_position.x
    player.set("automated_move", Vector3.RIGHT)
    await wait_physics_frames(32)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(8)

    var climbed: float = player.global_position.y - base_height
    var advanced: float = player.global_position.x - start_x
    var max_upward_correction: float = player.get("max_upward_terrain_correction")
    add_result(
        "terrain_steep_ascent_blocking",
        climbed < 0.45 and advanced < CELL * 0.95 and max_upward_correction <= 0.18,
        "climbed %.2f, advanced %.2f, max upward correction %.3f" % [climbed, advanced, max_upward_correction]
    )

func test_airborne_obstacle_blocking() -> void:
    if not player or not main:
        add_result("airborne_obstacle_blocking", false, "player or main missing")
        return

    var start_cell := Vector2i(roundi(player.global_position.x / CELL) + 9, roundi(player.global_position.z / CELL))
    var base_height: float = main.call("terrain_height_cell", start_cell.x, start_cell.y)
    var obstacle_height: float = base_height + CELL * 4.0
    var edits := get_height_edits()

    for dz in range(-2, 3):
        for dx in range(-2, 4):
            edits[Vector2i(start_cell.x + dx, start_cell.y + dz)] = base_height
        edits[Vector2i(start_cell.x + 1, start_cell.y + dz)] = obstacle_height
        edits[Vector2i(start_cell.x + 2, start_cell.y + dz)] = obstacle_height

    main.call("rebuild_chunks_around_cell", start_cell)
    main.call("rebuild_chunks_around_cell", Vector2i(start_cell.x + 2, start_cell.y))
    player.global_position = Vector3((start_cell.x - 0.35) * CELL, base_height, start_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
    player.set("airborne_obstacle_blocks", 0)
    await wait_physics_frames(8)

    var start_x: float = player.global_position.x
    player.set("automated_jump", true)
    player.set("automated_move", Vector3.RIGHT)
    var peak_y: float = player.global_position.y
    for i in range(45):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
    player.set("automated_move", Vector3.ZERO)
    await wait_physics_frames(8)

    var advanced: float = player.global_position.x - start_x
    var block_count := int(player.get("airborne_obstacle_blocks"))
    add_result(
        "airborne_obstacle_blocking",
        block_count > 0 and peak_y < obstacle_height - 0.55 and advanced < CELL * 1.15,
        "blocks %d, peak y %.2f, obstacle y %.2f, advanced %.2f" % [block_count, peak_y, obstacle_height, advanced]
    )

func test_jump() -> void:
    if not player:
        add_result("jump", false, "player missing")
        return
    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL)))
    await wait_physics_frames(8)
    for i in range(90):
        if is_player_grounded():
            break
        await get_tree().physics_frame
    var start_y: float = player.global_position.y
    player.set("automated_jump", true)
    var peak_y: float = start_y
    var landing_frame := -1
    var became_airborne := false
    var jumped_seen := false
    var max_velocity_y := -999.0
    var max_snap_time := 0.0
    for i in range(90):
        await get_tree().physics_frame
        peak_y = max(peak_y, player.global_position.y)
        jumped_seen = jumped_seen or bool(player.get("jumped_this_frame"))
        max_velocity_y = max(max_velocity_y, player.velocity.y)
        max_snap_time = max(max_snap_time, float(player.get("jump_snap_time")))
        if not is_player_grounded():
            became_airborne = true
        elif became_airborne:
            landing_frame = i + 1
            break
    var rise: float = peak_y - start_y
    var natural_air_time := landing_frame >= 36 or landing_frame == -1
    add_result(
        "jump",
        rise > 0.55 and natural_air_time,
        "rise %.2f, landing frame %d, floor %s, jumped %s, max vy %.2f, snap %.2f, y %.2f->%.2f" % [
            rise,
            landing_frame,
            str(is_player_grounded()),
            str(jumped_seen),
            max_velocity_y,
            max_snap_time,
            start_y,
            player.global_position.y
        ]
    )

func test_block_destroy_ray() -> void:
    if not player or not camera:
        add_result("block_destroy_ray", false, "player or camera missing")
        return
    var inventory_system = main.get("inventory_system")
    if inventory_system == null:
        add_result("block_destroy_ray", false, "inventory missing")
        return
    inventory_system.add_item("stoneShovel", 1)
    set_active_inventory_item(inventory_system, "stoneShovel")
    var hardness_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    reset_player_on_flat_patch(hardness_cell)
    clear_blocks_near_cell(hardness_cell, 10)
    clear_props_near_cell(hardness_cell, 10)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    var forward: Vector3 = -camera.global_transform.basis.z
    forward = forward.normalized()
    var target_pos: Vector3 = camera.global_position + forward * 2.2
    var test_cell := Vector3i(roundi(target_pos.x / CELL), roundi(target_pos.y / CELL), roundi(target_pos.z / CELL))
    main.call("create_block", test_cell, "dirtBlock")
    await wait_physics_frames(4)
    var block_center := Vector3(test_cell.x * CELL, test_cell.y * CELL, test_cell.z * CELL)
    aim_player_at(block_center)
    await wait_physics_frames(2)

    var hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
    var hit_block: bool = false
    if not hit.is_empty():
        var collider: Node = hit["collider"]
        hit_block = collider != null and collider.has_meta("kind") and String(collider.get_meta("kind")) == "block"
    if not hit_block:
        add_result("block_destroy_ray", false, "ray did not hit placed block")
        return

    main.call("destroy_target")
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(4)
    var blocks := get_blocks()
    add_result("block_destroy_ray", not blocks.has(test_cell), "placed block removed")

    main.call("reset_break_progress")
    var far_pos: Vector3 = camera.global_position + forward * 7.4
    var far_cell := Vector3i(roundi(far_pos.x / CELL), roundi(far_pos.y / CELL), roundi(far_pos.z / CELL))
    if blocks.has(far_cell):
        var old_far := blocks[far_cell] as Node
        if old_far:
            old_far.queue_free()
        blocks.erase(far_cell)
    main.call("create_block", far_cell, "dirtBlock")
    await wait_physics_frames(4)
    var far_center := Vector3(far_cell.x * CELL, far_cell.y * CELL, far_cell.z * CELL)
    aim_player_at(far_center)
    await wait_physics_frames(2)
    var old_range_hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
    var old_range_can_see := false
    if not old_range_hit.is_empty():
        var far_collider := old_range_hit.get("collider") as Node
        old_range_can_see = far_collider != null and far_collider.has_meta("cell") and far_collider.get_meta("cell") == far_cell
    var far_distance := camera.global_position.distance_to(far_center)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var far_block_still_present: bool = blocks.has(far_cell)
    var far_not_started: bool = String(main.get("break_target_id")) == "" and float(main.get("break_progress")) == 0.0
    if blocks.has(far_cell):
        var far_block := blocks[far_cell] as Node
        if far_block:
            far_block.queue_free()
        blocks.erase(far_cell)
    var far_enemy_safe := true
    var far_enemy_visible_old_range := false
    var hostile_system = main.get("hostile_system")
    if hostile_system:
        var far_enemy_pos: Vector3 = camera.global_position + forward * 6.3
        far_enemy_pos.y = player.global_position.y + 0.04
        var far_enemy = hostile_system.spawn_enemy(far_enemy_pos, "shadow")
        await wait_physics_frames(4)
        aim_player_at(far_enemy.global_position + Vector3(0.0, 0.9, 0.0))
        await wait_physics_frames(2)
        var far_enemy_hit: Dictionary = player.call("view_ray", INTERACT_RANGE)
        if not far_enemy_hit.is_empty():
            far_enemy_visible_old_range = far_enemy_hit.get("collider") == far_enemy
        main.call("destroy_target")
        await wait_physics_frames(2)
        var far_enemy_state: Dictionary = hostile_system.call("enemy_for_body", far_enemy)
        far_enemy_safe = not far_enemy_state.is_empty() and is_equal_approx(float(far_enemy_state.get("health", 0.0)), 18.0)
        if not far_enemy_state.is_empty():
            hostile_system.call("remove_enemy", far_enemy_state, false)
    add_result(
        "melee_targeting_short_range",
        old_range_can_see and far_distance > MELEE_RANGE and far_block_still_present and far_not_started and far_enemy_safe,
        "old range sees %s, distance %.2f, block still present %s, enemy old-range %s safe %s, progress %.2f, target '%s'" % [
            str(old_range_can_see),
            far_distance,
            str(far_block_still_present),
            str(far_enemy_visible_old_range),
            str(far_enemy_safe),
            float(main.get("break_progress")),
            String(main.get("break_target_id"))
        ]
    )

func test_mining_tool_requirements() -> void:
    if not main or not player or not camera:
        add_result("mining_tool_requirements", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var hud = main.get("hud")
    if inventory_system == null or hud == null:
        add_result("mining_tool_requirements", false, "inventory or hud missing")
        return
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("woodenPickaxe", 1)
    inventory_system.add_item("stonePickaxe", 1)
    inventory_system.add_item("copperPickaxe", 1)
    inventory_system.select(0)

    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 9, roundi(player.global_position.z / CELL)))
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    var forward: Vector3 = -camera.global_transform.basis.z.normalized()
    var copper_pos: Vector3 = camera.global_position + forward * 2.2
    var copper_cell := Vector3i(roundi(copper_pos.x / CELL), roundi(copper_pos.y / CELL), roundi(copper_pos.z / CELL))
    var iron_cell := copper_cell
    var blocks := get_blocks()
    if blocks.has(copper_cell):
        var existing := blocks[copper_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(copper_cell)
    main.call("create_block", copper_cell, "copperVein")
    await wait_physics_frames(4)

    set_active_inventory_item(inventory_system, "woodenPickaxe")
    aim_player_at(Vector3(copper_cell.x * CELL, copper_cell.y * CELL, copper_cell.z * CELL))
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var copper_wrong_blocked: bool = blocks.has(copper_cell) and float(main.get("break_progress")) == 0.0 and hud.target_label.text.find("Stone Pickaxe") >= 0

    set_active_inventory_item(inventory_system, "stonePickaxe")
    var copper_before: int = inventory_system.count("copperOre")
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var copper_mined: bool = not blocks.has(copper_cell) and inventory_system.count("copperOre") > copper_before

    main.call("reset_break_progress")
    if blocks.has(iron_cell):
        var existing_iron := blocks[iron_cell] as Node
        if existing_iron:
            existing_iron.queue_free()
        blocks.erase(iron_cell)
    main.call("create_block", iron_cell, "ironVein")
    await wait_physics_frames(4)
    set_active_inventory_item(inventory_system, "stonePickaxe")
    aim_player_at(Vector3(iron_cell.x * CELL, iron_cell.y * CELL, iron_cell.z * CELL))
    await wait_physics_frames(2)
    main.call("destroy_target")
    await wait_physics_frames(2)
    var iron_wrong_blocked: bool = blocks.has(iron_cell) and float(main.get("break_progress")) == 0.0 and hud.target_label.text.find("Copper Pickaxe") >= 0

    set_active_inventory_item(inventory_system, "copperPickaxe")
    var iron_before: int = inventory_system.count("ironOre")
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var iron_mined: bool = not blocks.has(iron_cell) and inventory_system.count("ironOre") > iron_before

    for cell in [copper_cell, iron_cell]:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)
    main.call("reset_break_progress")

    add_result(
        "mining_tool_requirements",
        copper_wrong_blocked and copper_mined and iron_wrong_blocked and iron_mined,
        "copper blocked %s/mined %s, iron blocked %s/mined %s, hud '%s'" % [
            str(copper_wrong_blocked),
            str(copper_mined),
            str(iron_wrong_blocked),
            str(iron_mined),
            hud.target_label.text
        ]
    )

func test_mining_upgrade_progression() -> void:
    if not main or not player or not camera:
        add_result("mining_upgrade_progression", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    var crafting_system = main.get("crafting_system")
    var objective_system = main.get("objective_system")
    var contract_system = main.get("contract_system")
    var progression_system = main.get("progression_system")
    var utility_system = main.get("utility_system")
    if inventory_system == null or crafting_system == null or objective_system == null or contract_system == null or progression_system == null or utility_system == null:
        add_result("mining_upgrade_progression", false, "required systems missing")
        return

    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    var original_objectives: Dictionary = objective_system.snapshot()
    var original_contracts: Dictionary = contract_system.snapshot()
    var original_progression: Dictionary = progression_system.snapshot()
    var discovered_biomes: Dictionary = main.get("discovered_biomes")
    var discovered_towns: Dictionary = main.get("discovered_town_keys")
    var original_biomes: Dictionary = discovered_biomes.duplicate(true)
    var original_towns: Dictionary = discovered_towns.duplicate(true)
    var created_cells: Array[Vector3i] = []

    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("logs", 34)
    inventory_system.add_item("stones", 8)
    objective_system.restore({ "completed": [], "total": objective_system.all_objectives().size() })
    contract_system.reset()
    progression_system.restore({ "level": 1, "xp": 0, "totalXp": 0 })
    discovered_biomes.clear()
    discovered_towns.clear()
    discovered_towns["playtestTown"] = true

    reset_player_on_flat_patch(Vector2i(roundi(player.global_position.x / CELL) + 11, roundi(player.global_position.z / CELL) + 1))
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    var base_cell := Vector3i(roundi(player.global_position.x / CELL) + 2, roundi(player.global_position.y / CELL), roundi(player.global_position.z / CELL) + 1)
    var workbench_cell := base_cell
    var furnace_cell := base_cell + Vector3i(2, 0, 0)
    var anvil_cell := base_cell + Vector3i(3, 0, 0)
    var workbench := main.call("create_block", workbench_cell, "workbench") as StaticBody3D
    var furnace := main.call("create_block", furnace_cell, "furnace") as StaticBody3D
    var anvil := main.call("create_block", anvil_cell, "anvil") as StaticBody3D
    created_cells.append(workbench_cell)
    created_cells.append(furnace_cell)
    created_cells.append(anvil_cell)
    if workbench == null or furnace == null or anvil == null:
        add_result("mining_upgrade_progression", false, "failed to create workbench/furnace/anvil")
        inventory_system.restore(original_inventory)
        objective_system.restore(original_objectives)
        contract_system.restore(original_contracts)
        progression_system.restore(original_progression)
        discovered_biomes.clear()
        for key in original_biomes.keys():
            discovered_biomes[key] = original_biomes[key]
        discovered_towns.clear()
        for key in original_towns.keys():
            discovered_towns[key] = original_towns[key]
        return

    main.call("update_objectives_and_contracts")
    var crafted_wooden: bool = bool(crafting_system.craft("woodenPickaxe"))
    var crafted_stone: bool = bool(crafting_system.craft("stonePickaxe"))
    await wait_physics_frames(2)

    var forward: Vector3 = -camera.global_transform.basis.z.normalized()
    var ore_pos: Vector3 = camera.global_position + forward * 2.2
    var ore_cell := Vector3i(roundi(ore_pos.x / CELL), roundi(ore_pos.y / CELL), roundi(ore_pos.z / CELL))
    var blocks := get_blocks()
    if blocks.has(ore_cell):
        var existing := blocks[ore_cell] as Node
        if existing:
            existing.queue_free()
        blocks.erase(ore_cell)
    created_cells.append(ore_cell)

    main.call("create_block", ore_cell, "copperVein")
    await wait_physics_frames(4)
    set_active_inventory_item(inventory_system, "stonePickaxe")
    aim_player_at(Vector3(ore_cell.x * CELL, ore_cell.y * CELL, ore_cell.z * CELL))
    await wait_physics_frames(2)
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var copper_mined: bool = not blocks.has(ore_cell) and inventory_system.count("copperOre") > 0

    inventory_system.add_item("copperOre", max(0, 4 - inventory_system.count("copperOre")))
    var copper_smelted: int = smelt_test_items(utility_system, furnace, inventory_system, "copperOre", 4)
    main.call("update_objectives_and_contracts")
    var crafted_copper_pickaxe: bool = bool(crafting_system.craft("copperPickaxe"))
    await wait_physics_frames(2)

    if blocks.has(ore_cell):
        var stale := blocks[ore_cell] as Node
        if stale:
            stale.queue_free()
        blocks.erase(ore_cell)
    main.call("create_block", ore_cell, "ironVein")
    await wait_physics_frames(4)
    set_active_inventory_item(inventory_system, "copperPickaxe")
    aim_player_at(Vector3(ore_cell.x * CELL, ore_cell.y * CELL, ore_cell.z * CELL))
    await wait_physics_frames(2)
    for i in range(3):
        main.call("destroy_target")
        await wait_physics_frames(2)
    var iron_mined: bool = not blocks.has(ore_cell) and inventory_system.count("ironOre") > 0

    inventory_system.add_item("ironOre", max(0, 3 - inventory_system.count("ironOre")))
    var iron_smelted: int = smelt_test_items(utility_system, furnace, inventory_system, "ironOre", 3)
    main.call("update_objectives_and_contracts")
    var crafted_iron_pickaxe: bool = bool(crafting_system.craft("ironPickaxe"))
    for i in range(8):
        main.call("update_objectives_and_contracts")

    var objective_state: Dictionary = main.call("objective_state")
    var objective_ids := ["woodenPickaxe", "stonePickaxe", "mineCopper", "smeltCopper", "craftCopperPickaxe", "mineIron", "smeltIron", "craftIronPickaxe"]
    var incomplete_objectives := []
    for objective_id in objective_ids:
        if not bool(objective_system.is_complete(String(objective_id), objective_state)):
            incomplete_objectives.append(objective_id)
    var completed_contracts: Array = contract_system.snapshot().get("completed", [])
    var contract_ids := ["copperSample", "smelterRun", "ironSample"]
    var missing_contracts := []
    for contract_id in contract_ids:
        if not completed_contracts.has(contract_id):
            missing_contracts.append(contract_id)
    var progression_ok: bool = crafted_wooden and crafted_stone and copper_mined and copper_smelted >= 4 and crafted_copper_pickaxe and iron_mined and iron_smelted >= 3 and crafted_iron_pickaxe

    utility_system.close()
    for cell in created_cells:
        if blocks.has(cell):
            var body := blocks[cell] as Node
            if body:
                body.queue_free()
            blocks.erase(cell)
    inventory_system.restore(original_inventory)
    objective_system.restore(original_objectives)
    contract_system.restore(original_contracts)
    progression_system.restore(original_progression)
    main.call("reset_break_progress")
    discovered_biomes.clear()
    for key in original_biomes.keys():
        discovered_biomes[key] = original_biomes[key]
    discovered_towns.clear()
    for key in original_towns.keys():
        discovered_towns[key] = original_towns[key]

    add_result(
        "mining_upgrade_progression",
        progression_ok and incomplete_objectives.is_empty() and missing_contracts.is_empty(),
        "crafted %s/%s/%s/%s, mined %s/%s, smelted %d/%d, incomplete %s, contracts %s" % [
            str(crafted_wooden),
            str(crafted_stone),
            str(crafted_copper_pickaxe),
            str(crafted_iron_pickaxe),
            str(copper_mined),
            str(iron_mined),
            copper_smelted,
            iron_smelted,
            str(incomplete_objectives),
            str(missing_contracts)
        ]
    )

func test_material_hardness_and_reset() -> void:
    if not main or not player or not camera:
        add_result("material_hardness", false, "main/player/camera missing")
        return
    var inventory_system = main.get("inventory_system")
    if inventory_system == null:
        add_result("material_hardness", false, "inventory missing")
        return
    var original_inventory := {
        "slots": inventory_system.snapshot(),
        "size": inventory_system.size,
        "selectedSlot": inventory_system.selected_slot
    }
    inventory_system.set_size(ItemCatalogScript.MAX_INVENTORY_SIZE)
    inventory_system.clear()
    inventory_system.add_item("woodenPickaxe", 1)
    set_active_inventory_item(inventory_system, "woodenPickaxe")

    var hardness_cell := Vector2i(roundi(player.global_position.x / CELL) + 8, roundi(player.global_position.z / CELL))
    reset_player_on_flat_patch(hardness_cell)
    clear_blocks_near_cell(hardness_cell, 10)
    clear_props_near_cell(hardness_cell, 10)
    var disabled_prop_shapes: Array[CollisionShape3D] = []
    disable_prop_colliders(main, disabled_prop_shapes)
    player.rotation.y = 0.0
    player.set("pitch", 0.0)
    camera.rotation.x = 0.0
    await wait_physics_frames(8)

    var forward: Vector3 = -camera.global_transform.basis.z
    var target_pos: Vector3 = camera.global_position + forward.normalized() * 2.2
    var test_cell := Vector3i(roundi(target_pos.x / CELL), roundi(target_pos.y / CELL), roundi(target_pos.z / CELL))
    main.call("create_block", test_cell, "stoneBlock")
    await wait_physics_frames(4)
    var block_center := Vector3(test_cell.x * CELL, test_cell.y * CELL, test_cell.z * CELL)
    aim_player_at(block_center)
    await wait_physics_frames(2)

    var pre_hit: Dictionary = player.call("view_ray", MELEE_RANGE)
    var pre_hit_kind := ""
    var pre_hit_type := ""
    var pre_hit_cell := Vector3i.ZERO
    if not pre_hit.is_empty():
        var pre_collider := pre_hit.get("collider") as Node
        if pre_collider != null:
            pre_hit_kind = String(pre_collider.get_meta("kind", ""))
            pre_hit_type = String(pre_collider.get_meta("block_type", pre_collider.get_meta("material", "")))
            if pre_collider.has_meta("cell"):
                pre_hit_cell = pre_collider.get_meta("cell")
    main.call("destroy_target")
    await wait_physics_frames(4)
    var blocks := get_blocks()
    var overlay := main.get("break_overlay") as MeshInstance3D
    var cracked_not_destroyed := blocks.has(test_cell) and float(main.get("break_progress")) > 0.0 and overlay != null and overlay.visible
    add_result(
        "material_hardness_first_strike",
        cracked_not_destroyed,
        "progress %.2f, overlay %s, prehit %s/%s cell %s target %s active %s dist %.2f" % [
            float(main.get("break_progress")),
            str(overlay != null and overlay.visible),
            pre_hit_kind,
            pre_hit_type,
            str(pre_hit_cell),
            str(test_cell),
            String(inventory_system.active_stack().get("item", "")),
            camera.global_position.distance_to(block_center)
        ]
    )

    await wait_physics_frames(160)
    var reset := float(main.get("break_progress")) == 0.0 and String(main.get("break_target_id")) == "" and overlay != null and not overlay.visible
    add_result("break_progress_resets", reset, "progress %.2f, target '%s'" % [float(main.get("break_progress")), String(main.get("break_target_id"))])

    for i in range(7):
        main.call("destroy_target")
        await wait_physics_frames(2)
    blocks = get_blocks()
    add_result("material_hardness_destroyed", not blocks.has(test_cell), "stone block removed after repeated strikes")
    restore_collision_shapes(disabled_prop_shapes)
    inventory_system.restore(original_inventory)

func save_optional_screenshot() -> void:
    var screenshot_path: String = OS.get_environment("VOXEL_PLAYTEST_SCREENSHOT")
    if screenshot_path == "":
        return
    var image: Image = get_viewport().get_texture().get_image()
    var err: Error = image.save_png(screenshot_path)
    add_result("screenshot_saved", err == OK, screenshot_path)

func save_report(verbose := true) -> void:
    var report_path: String = OS.get_environment("VOXEL_PLAYTEST_REPORT")
    if report_path == "":
        report_path = "user://playtest-report.json"
    var report: Dictionary = {
        "passed": not failed,
        "results": results
    }
    var file: FileAccess = FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write playtest report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()
    if verbose:
        print("Playtest report: %s" % report_path)

func get_chunks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("chunks")
    if value is Dictionary:
        return value
    return {}

func get_blocks() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("blocks")
    if value is Dictionary:
        return value
    return {}

func get_height_edits() -> Dictionary:
    if not main:
        return {}
    var value: Variant = main.get("height_edits")
    if value is Dictionary:
        return value
    return {}

func move_player_near_first_block_type(block_type: String, offset := Vector3(0.0, 0.0, CELL * 1.25)) -> bool:
    if player == null:
        return false
    for block in get_blocks().values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        player.global_position = body.global_position + offset
        player.velocity = Vector3.ZERO
        player.set("terrain_grounded", true)
        return true
    return false

func find_first_block_by_type(block_type: String) -> Node:
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) == block_type:
            return body
    return null

func count_starter_beds(tutorial_system) -> int:
    if tutorial_system == null:
        return 0
    var starter_cell: Vector2i = tutorial_system.get("start_cell")
    if starter_cell == Vector2i.ZERO:
        var state: Dictionary = tutorial_system.state()
        var town_center: Vector2i = state.get("townCenter", Vector2i.ZERO)
        starter_cell = Vector2i(town_center.x - 13, town_center.y - 10)
    var bed_cell := starter_cell + Vector2i(-1, 2)
    var count := 0
    for block in get_blocks().values():
        var body := block as Node3D
        if body == null or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != "bed":
            continue
        var block_cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if abs(block_cell.x - bed_cell.x) <= 1 and abs(block_cell.z - bed_cell.y) <= 1:
            count += 1
    return count

func world_to_flat_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func building_bounds_near(center_cell: Vector2i, radius: int) -> Dictionary:
    var min_x := 2147483647
    var min_z := 2147483647
    var max_x := -2147483648
    var max_z := -2147483648
    var found := false
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta("block_type") or not body.has_meta("cell"):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if not (block_type in ["woodBlock", "stoneBlock", "glass", "door"]):
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if abs(cell.x - center_cell.x) > radius or abs(cell.z - center_cell.y) > radius:
            continue
        min_x = mini(min_x, cell.x)
        max_x = maxi(max_x, cell.x)
        min_z = mini(min_z, cell.z)
        max_z = maxi(max_z, cell.z)
        found = true
    return { "valid": found, "minX": min_x, "maxX": max_x, "minZ": min_z, "maxZ": max_z }

func point_in_cell_bounds(cell: Vector2i, bounds: Dictionary) -> bool:
    if not bool(bounds.get("valid", false)):
        return false
    return (
        cell.x >= int(bounds.get("minX", 0))
        and cell.x <= int(bounds.get("maxX", 0))
        and cell.y >= int(bounds.get("minZ", 0))
        and cell.y <= int(bounds.get("maxZ", 0))
    )

func find_first_block_with_meta(meta_key: String, expected_value) -> Node:
    for block in get_blocks().values():
        var body := block as Node
        if body == null or not body.has_meta(meta_key):
            continue
        if body.get_meta(meta_key) == expected_value:
            return body
    return null

func find_inventory_slot(inventory_system, item_id: String) -> int:
    if inventory_system == null:
        return -1
    for i in range(inventory_system.slots.size()):
        var slot: Dictionary = inventory_system.slots[i]
        if String(slot.get("item", "")) == item_id and int(slot.get("count", 0)) > 0:
            return i
    return -1

func set_active_inventory_item(inventory_system, item_id: String) -> bool:
    var slot := find_inventory_slot(inventory_system, item_id)
    if slot < 0:
        return false
    inventory_system.select(0)
    if slot != 0:
        inventory_system.swap_with_active(slot)
    return true

func smelt_test_items(utility_system, furnace: Node, inventory_system, input_item: String, count: int) -> int:
    if utility_system == null or furnace == null or inventory_system == null:
        return 0
    var produced := 0
    utility_system.open_block(furnace)
    for i in range(count):
        if not inventory_system.consume_costs({ input_item: 1, "logs": 1 }):
            break
        var state: Dictionary = utility_system.ensure_furnace(furnace)
        state["input"] = { "item": input_item, "count": 1 }
        state["fuel"] = { "item": "logs", "count": 1 }
        state["output"] = { "item": "", "count": 0 }
        state["processing"] = false
        state["progress"] = 0.0
        utility_system.set_furnace_state(furnace, state)
        if not bool(utility_system.start_processing()):
            break
        utility_system.update(12.0)
        state = utility_system.ensure_furnace(furnace)
        var output_slot: Dictionary = state.get("output", {})
        var output_item := String(output_slot.get("item", ""))
        var output_count := int(output_slot.get("count", 0))
        if output_item == "" or output_count <= 0:
            continue
        produced += inventory_system.add_item(output_item, output_count)
        output_slot["item"] = ""
        output_slot["count"] = 0
        state["output"] = output_slot
        utility_system.set_furnace_state(furnace, state)
    return produced

func count_mesh_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is MeshInstance3D:
        count += 1
    for child in node.get_children():
        count += count_mesh_descendants(child)
    return count

func count_named_descendants(node: Node, node_name: String) -> int:
    if node == null:
        return 0
    var count := 0
    if String(node.name).begins_with(node_name):
        count += 1
    for child in node.get_children():
        count += count_named_descendants(child, node_name)
    return count

func count_collision_descendants(node: Node) -> int:
    if node == null:
        return 0
    var count := 0
    if node is CollisionShape3D or node is PhysicsBody3D or node is Area3D:
        count += 1
    for child in node.get_children():
        count += count_collision_descendants(child)
    return count

func icon_distinct_colors(texture: Texture2D) -> int:
    if texture == null:
        return 0
    var image := texture.get_image()
    if image == null:
        return 0
    var colors := {}
    for y in range(0, image.get_height(), 4):
        for x in range(0, image.get_width(), 4):
            var color := image.get_pixel(x, y)
            if color.a <= 0.04:
                continue
            var key := "%d:%d:%d:%d" % [
                roundi(color.r * 16.0),
                roundi(color.g * 16.0),
                roundi(color.b * 16.0),
                roundi(color.a * 16.0)
            ]
            colors[key] = true
    return colors.size()

func is_player_grounded() -> bool:
    if not player:
        return false
    if float(player.get("jump_snap_time")) > 0.0:
        return false
    return player.is_on_floor() or bool(player.get("terrain_grounded"))

func wait_until_grounded(max_frames: int) -> void:
    for i in range(max_frames):
        if is_player_grounded():
            return
        await get_tree().physics_frame

func aim_player_at(world_point: Vector3) -> void:
    if not player or not camera:
        return
    var eye: Vector3 = camera.global_position
    var direction: Vector3 = world_point - eye
    var flat_direction := Vector3(direction.x, 0.0, direction.z)
    if flat_direction.length_squared() > 0.0001:
        player.rotation.y = atan2(-flat_direction.x, -flat_direction.z)
    var local_direction: Vector3 = player.global_transform.basis.inverse() * direction.normalized()
    var pitch_value: float = clamp(atan2(local_direction.y, -local_direction.z), deg_to_rad(-82.0), deg_to_rad(82.0))
    player.set("pitch", pitch_value)
    camera.rotation.x = pitch_value

func reset_player_on_flat_patch(center_cell: Vector2i) -> void:
    if not main or not player:
        return
    var base_height: float = main.call("terrain_height_cell", center_cell.x, center_cell.y)
    var edits := get_height_edits()
    for dz in range(-5, 6):
        for dx in range(-5, 6):
            edits[Vector2i(center_cell.x + dx, center_cell.y + dz)] = base_height
    main.call("rebuild_chunks_around_cell", center_cell)
    player.global_position = Vector3(center_cell.x * CELL, base_height, center_cell.y * CELL)
    player.velocity = Vector3.ZERO
    player.set("terrain_grounded", true)
