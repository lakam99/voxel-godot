extends RefCounted
class_name TutorialSceneBuilder

const NpcVisualFactoryScript := preload("res://scripts/NpcVisualFactory.gd")
const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")
const CELL := 1.35
const SAFE_RADIUS_CELLS := 24
const FENCE_RADIUS_CELLS := 25
const STARTUP_LIGHT_BATCH_FRAME_BUDGET_MS := 8.0
const STARTUP_LIGHT_BATCH_MAX_WORK_UNITS := 768

var system
var main
var npc_visual_factory

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main
    npc_visual_factory = NpcVisualFactoryScript.new()
    npc_visual_factory.setup(main)
    system.npc_root = Node3D.new()
    system.npc_root.name = "TutorialNPCs"
    system.add_child(system.npc_root)
    system.light_root = Node3D.new()
    system.light_root.name = "TutorialLights"
    system.add_child(system.light_root)

func ensure_town_generated() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    main.structure_system.update_around(Vector2i(int(system.town.get("centerX", 0)), int(system.town.get("centerZ", 0))))

func ensure_starter_bed() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var bed_cell := Vector2i(center_x - 14, center_z - 8)
    clear_overlapping_starter_beds(bed_cell, level)
    main.structure_system.place_utility(bed_cell.x, bed_cell.y, level, "bed", {
        "generatedTier": "town",
        "cacheKey": "%s:tutorial-bed:%d,%d" % [main.seed_text, center_x, center_z]
    })

func clear_overlapping_starter_beds(center_cell: Vector2i, level: float) -> void:
    if main == null:
        return
    var tutorial_key_prefix := "%s:tutorial-bed:" % main.seed_text
    var expected_world_y: float = level + float(main.CELL) * 0.48
    for key in main.blocks.keys().duplicate():
        var body := main.blocks[key] as Node3D
        if body == null or not is_instance_valid(body) or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type", "")) != "bed" or bool(body.get_meta("player_placed", false)):
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        var same_footprint: bool = abs(cell.x - center_cell.x) <= 1 and abs(cell.z - center_cell.y) <= 1
        var same_level: bool = absf(body.global_position.y - expected_world_y) <= float(main.CELL) * 1.2
        var is_tutorial_bed := String(body.get_meta("cacheKey", "")).begins_with(tutorial_key_prefix)
        if (same_footprint and same_level) or is_tutorial_bed:
            main.blocks.erase(key)
            body.queue_free()

func ensure_starter_shelter() -> Dictionary:
    var metrics := {
        "shelterTerrainReservationMs": 0.0,
        "shelterRoofBlocksMs": 0.0,
        "shelterRoofBlockCount": 0
    }
    if main == null or system.town.is_empty() or main.structure_system == null:
        return metrics
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var terrain_started_usec := Time.get_ticks_usec()
    reserve_starter_shelter_volume(center_x, center_z, level)
    metrics["shelterTerrainReservationMs"] = float(Time.get_ticks_usec() - terrain_started_usec) / 1000.0
    var roof_center := Vector2i(center_x - 13, center_z - 10)
    var roof_started_usec := Time.get_ticks_usec()
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var cell := roof_center + Vector2i(dx, dz)
            main.structure_system.place_structure_block(cell.x, cell.y, level, 3, "woodBlock", {
                "generatedTier": "town",
                "cacheKey": "%s:tutorial-starter-roof:%d,%d" % [main.seed_text, cell.x, cell.y]
            })
            metrics["shelterRoofBlockCount"] = int(metrics.get("shelterRoofBlockCount", 0)) + 1
    metrics["shelterRoofBlocksMs"] = float(Time.get_ticks_usec() - roof_started_usec) / 1000.0
    return metrics

func reserve_starter_shelter_volume(center_x: int, center_z: int, level: float) -> void:
    if main == null or main.structure_system == null:
        return
    if not main.structure_system.has_method("reserve_structure_terrain_footprint"):
        return
    var base_x := center_x - 16
    var base_z := center_z - 14
    var width := 7
    var depth := 8
    main.structure_system.reserve_structure_terrain_footprint(
        base_x,
        base_z,
        level,
        width,
        depth,
        4,
        "tutorial_starter_shelter",
        "stone"
    )
    refresh_starter_shelter_terrain(base_x, base_z, width, depth)

func refresh_starter_shelter_terrain(base_x: int, base_z: int, width: int, depth: int) -> void:
    if main == null or not main.has_method("rebuild_chunks_for_cells"):
        return
    if main.has_method("queue_dirty_terrain_volume_chunk_refreshes"):
        main.queue_dirty_terrain_volume_chunk_refreshes()
    main.rebuild_chunks_for_cells([
        Vector2i(base_x, base_z),
        Vector2i(base_x + width, base_z),
        Vector2i(base_x, base_z + depth),
        Vector2i(base_x + width, base_z + depth),
        Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    ], 0, true)

func ensure_village_perimeter() -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var deferred_light_entries: Array[Dictionary] = []
    var deferred_light_cells := {}
    var gate_cells := {}
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - FENCE_RADIUS_CELLS)] = { "side": 2, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x + offset, center_z + FENCE_RADIUS_CELLS)] = { "side": 0, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x - FENCE_RADIUS_CELLS, center_z + offset)] = { "side": 3, "secondary": offset == 1 }
        gate_cells[Vector2i(center_x + FENCE_RADIUS_CELLS, center_z + offset)] = { "side": 1, "secondary": offset == 1 }
    for offset in range(-FENCE_RADIUS_CELLS, FENCE_RADIUS_CELLS + 1):
        place_perimeter_cell(center_x + offset, center_z - FENCE_RADIUS_CELLS, level, gate_cells)
        place_perimeter_cell(center_x + offset, center_z + FENCE_RADIUS_CELLS, level, gate_cells)
        place_perimeter_cell(center_x - FENCE_RADIUS_CELLS, center_z + offset, level, gate_cells)
        place_perimeter_cell(center_x + FENCE_RADIUS_CELLS, center_z + offset, level, gate_cells)

func place_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        main.structure_system.place_door(cell_x, cell_z, level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    main.structure_system.place_structure_block(cell_x, cell_z, level, 0, "woodBlock", {
        "generatedTier": "town",
        "cacheKey": "%s:tutorial-fence:%d,%d" % [main.seed_text, cell_x, cell_z]
    })

func prepare_village_light_setup() -> Dictionary:
    var metrics := {
        "villageLightBlockCount": 0,
        "villageLightBlocksMs": 0.0,
        "villageLightRigCount": 0,
        "villageLightRigsMs": 0.0
    }
    if main == null or system.town.is_empty() or main.structure_system == null:
        return { "metrics": metrics, "entries": [] }
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var deferred_light_entries: Array[Dictionary] = []
    var deferred_light_cells := {}
    for cell in [
        Vector2i(center_x, center_z - 7), Vector2i(center_x - 8, center_z),
        Vector2i(center_x + 8, center_z), Vector2i(center_x, center_z + 8),
        Vector2i(center_x - 14, center_z - 9), Vector2i(center_x + 14, center_z + 9)
    ]:
        var terrain_cell := tutorial_light_terrain_cell(cell, level, 0)
        var should_defer_light: bool = not main.blocks.has(terrain_cell)
        var block_started_usec := Time.get_ticks_usec()
        main.structure_system.place_utility(cell.x, cell.y, level, "torch", {
            "generatedTier": "town",
            "cacheKey": "%s:tutorial-light:%d,%d" % [main.seed_text, cell.x, cell.y],
            "instrumentationMetrics": metrics,
            "instrumentationMetricPrefix": "villageLight",
            "deferBlockLightSync": true
        })
        if should_defer_light and main.blocks.has(terrain_cell) and not deferred_light_cells.has(terrain_cell):
            deferred_light_cells[terrain_cell] = true
            deferred_light_entries.append({ "cell": terrain_cell, "blockType": "torch" })
        metrics["villageLightBlockCount"] = int(metrics.get("villageLightBlockCount", 0)) + 1
        metrics["villageLightBlocksMs"] = float(metrics.get("villageLightBlocksMs", 0.0)) + float(Time.get_ticks_usec() - block_started_usec) / 1000.0
        var rig_started_usec := Time.get_ticks_usec()
        add_warm_light(Vector3(float(cell.x) * CELL, level + CELL * 1.25, float(cell.y) * CELL), 9.0, 1.15, level)
        metrics["villageLightRigCount"] = int(metrics.get("villageLightRigCount", 0)) + 1
        metrics["villageLightRigsMs"] = float(metrics.get("villageLightRigsMs", 0.0)) + float(Time.get_ticks_usec() - rig_started_usec) / 1000.0

    for offset in range(-FENCE_RADIUS_CELLS, FENCE_RADIUS_CELLS + 1, 5):
        for cell in [
            Vector2i(center_x + offset, center_z - FENCE_RADIUS_CELLS),
            Vector2i(center_x + offset, center_z + FENCE_RADIUS_CELLS),
            Vector2i(center_x - FENCE_RADIUS_CELLS, center_z + offset),
            Vector2i(center_x + FENCE_RADIUS_CELLS, center_z + offset)
        ]:
            var terrain_cell := tutorial_light_terrain_cell(cell, level, 1)
            var should_defer_light: bool = not main.blocks.has(terrain_cell)
            var block_started_usec := Time.get_ticks_usec()
            main.structure_system.place_structure_block(cell.x, cell.y, level, 1, "torch", {
                "generatedTier": "town",
                "cacheKey": "%s:tutorial-perimeter-light:%d,%d" % [main.seed_text, cell.x, cell.y],
                "instrumentationMetrics": metrics,
                "instrumentationMetricPrefix": "villageLight",
                "deferBlockLightSync": true
            })
            if should_defer_light and main.blocks.has(terrain_cell) and not deferred_light_cells.has(terrain_cell):
                deferred_light_cells[terrain_cell] = true
                deferred_light_entries.append({ "cell": terrain_cell, "blockType": "torch" })
            metrics["villageLightBlockCount"] = int(metrics.get("villageLightBlockCount", 0)) + 1
            metrics["villageLightBlocksMs"] = float(metrics.get("villageLightBlocksMs", 0.0)) + float(Time.get_ticks_usec() - block_started_usec) / 1000.0
            var rig_started_usec := Time.get_ticks_usec()
            add_warm_light(Vector3(float(cell.x) * CELL, level + CELL * 2.25, float(cell.y) * CELL), 9.0, 1.15, level)
            metrics["villageLightRigCount"] = int(metrics.get("villageLightRigCount", 0)) + 1
            metrics["villageLightRigsMs"] = float(metrics.get("villageLightRigsMs", 0.0)) + float(Time.get_ticks_usec() - rig_started_usec) / 1000.0
    return { "metrics": metrics, "entries": deferred_light_entries }

func ensure_village_lights() -> Dictionary:
    var setup_result: Dictionary = prepare_village_light_setup()
    var metrics: Dictionary = setup_result.get("metrics", {}) if setup_result.get("metrics", {}) is Dictionary else {}
    var deferred_light_entries: Array = setup_result.get("entries", []) if setup_result.get("entries", []) is Array else []
    var terrain_light_batch_started_usec := Time.get_ticks_usec()
    if not deferred_light_entries.is_empty() and main.has_method("sync_block_lights_to_terrain"):
        metrics["villageLightBatch"] = main.call("sync_block_lights_to_terrain", deferred_light_entries, "tutorial_village_lights")
    metrics["villageLightDeferredSourceCount"] = deferred_light_entries.size()
    metrics["villageLightTerrainLightBatchMs"] = float(Time.get_ticks_usec() - terrain_light_batch_started_usec) / 1000.0
    return metrics

func ensure_village_lights_staged() -> Dictionary:
    var setup_result: Dictionary = prepare_village_light_setup()
    var metrics: Dictionary = setup_result.get("metrics", {}) if setup_result.get("metrics", {}) is Dictionary else {}
    var deferred_light_entries: Array = setup_result.get("entries", []) if setup_result.get("entries", []) is Array else []
    var terrain_light_batch_started_usec := Time.get_ticks_usec()
    if not deferred_light_entries.is_empty() and main.has_method("sync_block_lights_to_terrain_staged"):
        var batch_value: Variant = await main.sync_block_lights_to_terrain_staged(
            deferred_light_entries,
            "tutorial_village_lights",
            STARTUP_LIGHT_BATCH_FRAME_BUDGET_MS,
            STARTUP_LIGHT_BATCH_MAX_WORK_UNITS
        )
        metrics["villageLightBatch"] = batch_value if batch_value is Dictionary else {}
    elif not deferred_light_entries.is_empty() and main.has_method("sync_block_lights_to_terrain"):
        metrics["villageLightBatch"] = main.call("sync_block_lights_to_terrain", deferred_light_entries, "tutorial_village_lights")
    metrics["villageLightDeferredSourceCount"] = deferred_light_entries.size()
    metrics["villageLightTerrainLightBatchMs"] = float(Time.get_ticks_usec() - terrain_light_batch_started_usec) / 1000.0
    return metrics

func tutorial_light_terrain_cell(cell: Vector2i, level: float, dy: int) -> Vector3i:
    var world_y := level + CELL * 0.48 + float(dy) * CELL
    return Vector3i(cell.x, floori(world_y / CELL) + 1, cell.y)

func place_player_in_starter_house() -> void:
    if main == null or system.town.is_empty() or main.player == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    system.start_cell = Vector2i(center_x - 13, center_z - 10)
    var spawn := Vector3(float(system.start_cell.x) * CELL, level + 0.12, float(system.start_cell.y) * CELL)
    main.player.global_position = spawn
    main.player.velocity = Vector3.ZERO
    main.player.rotation.y = PI
    main.player.set("pitch", 0.0)
    main.player.set("terrain_grounded", true)
    var camera := main.player.get("camera") as Camera3D
    if camera:
        camera.rotation.x = 0.0
    main.respawn_point = spawn

func force_stormy_night() -> void:
    if main == null or main.player == null:
        return
    main.time_of_day = 0.86
    if main.weather_system:
        main.weather_system.force_weather("rain", 0.86, 0.94, main.player.global_position)
    if main.has_method("update_sky"):
        main.update_sky(0.0)

func resolve_tutorial_actor_specs(manifest: Dictionary, scenarios: Array, town_data: Dictionary) -> Dictionary:
    var problems: Array[String] = []
    var specs: Array = []
    var homes: Dictionary = manifest.get("homesByKey", {}) if manifest.get("homesByKey", {}) is Dictionary else {}
    var town_key := String(manifest.get("townKey", ""))
    var center_value = manifest.get("center")
    if town_key == "":
        problems.append("manifest is missing townKey")
    if not (center_value is Vector2i):
        problems.append("manifest center must be Vector2i")
    if homes.is_empty():
        problems.append("manifest homesByKey is empty")
    if not problems.is_empty():
        return actor_resolution_result(specs, problems)
    var center: Vector2i = center_value
    var seen_ids := {}
    for scenario_value in scenarios:
        if not (scenario_value is Dictionary):
            problems.append("scenario entry must be a dictionary")
            continue
        var scenario: Dictionary = scenario_value
        var actor_id := String(scenario.get("id", "")).strip_edges()
        var home_key := int(scenario.get("homeKey", -1))
        if actor_id == "":
            problems.append("scenario actor is missing id")
            continue
        if seen_ids.has(actor_id):
            problems.append("duplicate scenario actor id %s" % actor_id)
            continue
        seen_ids[actor_id] = true
        var home_value = homes.get(str(home_key))
        if not (home_value is Dictionary):
            problems.append("actor %s cannot resolve homeKey %d" % [actor_id, home_key])
            continue
        var home: Dictionary = home_value
        var profile_problem := validate_manifest_home_for_actor(actor_id, home_key, home, town_key)
        if profile_problem != "":
            problems.append(profile_problem)
            continue
        var presentation: Dictionary = (scenario.get("presentation", {}) as Dictionary).duplicate(true) if scenario.get("presentation", {}) is Dictionary else {}
        var simulation: Dictionary = (scenario.get("simulation", {}) as Dictionary).duplicate(true) if scenario.get("simulation", {}) is Dictionary else {}
        var spawn: Dictionary = (scenario.get("spawn", {}) as Dictionary).duplicate(true) if scenario.get("spawn", {}) is Dictionary else {}
        var spawn_cell_result := resolve_actor_spawn_cell(actor_id, spawn, center, home)
        if not bool(spawn_cell_result.get("ok", false)):
            problems.append(String(spawn_cell_result.get("reason", "actor %s has invalid spawn" % actor_id)))
            continue
        var spawn_cell: Vector2i = spawn_cell_result.get("cell")
        var guard_cell: Vector2i = home.get("porchCell")
        if simulation.get("guardOffset") is Vector2i:
            guard_cell = center + (simulation.get("guardOffset") as Vector2i)
        simulation.erase("guardOffset")
        var profile := simulation.duplicate(true)
        profile.merge({
            "id": actor_id,
            "name": String(presentation.get("name", actor_id)),
            "displayRole": String(presentation.get("role", profile.get("role", "Villager"))),
            "townKey": town_key,
            "townCenter": center,
            "townRadius": int(town_data.get("radius", SAFE_RADIUS_CELLS)),
            "level": float(town_data.get("level", 16.0)),
            "cell": spawn_cell,
            "homeKey": home_key,
            "homeStableId": String(home.get("stableId")),
            "homeCell": home.get("homeCell"),
            "porchCell": home.get("porchCell"),
            "doorCell": home.get("doorCell"),
            "doorPortalId": String(home.get("doorPortalId")),
            "interiorLandingCell": home.get("interiorLandingCell"),
            "homeRouteCells": (home.get("homeRouteCells") as Array).duplicate(),
            "interiorMinCell": home.get("interiorMinCell"),
            "interiorMaxCell": home.get("interiorMaxCell"),
            "guardCell": guard_cell,
            "tutorial": true
        }, true)
        specs.append({
            "id": actor_id,
            "homeKey": home_key,
            "presentation": presentation,
            "profile": profile,
            "spawnCell": spawn_cell,
            "initialOrder": (scenario.get("initialOrder", {}) as Dictionary).duplicate(true) if scenario.get("initialOrder", {}) is Dictionary else {}
        })
    return actor_resolution_result(specs, problems)

func actor_resolution_result(specs: Array, problems: Array[String]) -> Dictionary:
    return {
        "ok": problems.is_empty(),
        "reason": "" if problems.is_empty() else "tutorial_actor_manifest_resolution_failed",
        "specs": specs,
        "problems": problems,
        "metrics": {
            "scenarioActorCount": specs.size() + problems.size(),
            "resolvedActorCount": specs.size(),
            "problemCount": problems.size()
        }
    }

func validate_manifest_home_for_actor(actor_id: String, home_key: int, home: Dictionary, town_key: String) -> String:
    if int(home.get("homeKey", -1)) != home_key:
        return "actor %s homeKey %d record identity mismatch" % [actor_id, home_key]
    if String(home.get("stableId", "")).strip_edges() == "":
        return "actor %s homeKey %d is missing stableId" % [actor_id, home_key]
    if String(home.get("townKey", "")) != town_key:
        return "actor %s homeKey %d belongs to wrong town" % [actor_id, home_key]
    if String(home.get("doorPortalId", "")).strip_edges() == "":
        return "actor %s homeKey %d is missing doorPortalId" % [actor_id, home_key]
    for field in ["homeCell", "porchCell", "doorCell", "interiorLandingCell", "interiorMinCell", "interiorMaxCell"]:
        if not (home.get(field) is Vector2i):
            return "actor %s homeKey %d is missing %s" % [actor_id, home_key, field]
    var route_value = home.get("homeRouteCells")
    if not (route_value is Array) or (route_value as Array).is_empty():
        return "actor %s homeKey %d has no homeRouteCells" % [actor_id, home_key]
    for route_cell in route_value:
        if not (route_cell is Vector2i):
            return "actor %s homeKey %d has an invalid home route cell" % [actor_id, home_key]
    return ""

func resolve_actor_spawn_cell(actor_id: String, spawn: Dictionary, center: Vector2i, home: Dictionary) -> Dictionary:
    match String(spawn.get("kind", "")):
        "home":
            return {"ok": true, "cell": home.get("homeCell")}
        "porch":
            return {"ok": true, "cell": home.get("porchCell")}
        "offset":
            if spawn.get("offset") is Vector2i:
                return {"ok": true, "cell": center + (spawn.get("offset") as Vector2i)}
    return {"ok": false, "reason": "actor %s has invalid spawn declaration" % actor_id}

func spawn_tutorial_npcs(specs: Array) -> Dictionary:
    clear_npcs()
    if main == null or system.town.is_empty() or specs.is_empty():
        return {"ok": false, "reason": "missing_resolved_tutorial_actor_specs", "problems": ["resolved actor specs are required"]}
    var cx := int(system.town.get("centerX", 0))
    var cz := int(system.town.get("centerZ", 0))
    var level := float(system.town.get("level", 16.0))
    var spawned_ids: Array[String] = []
    var problems: Array[String] = []
    for spec_value in specs:
        if not (spec_value is Dictionary):
            problems.append("resolved actor spec must be a dictionary")
            break
        var result: Dictionary = spawn_npc(spec_value, level, Vector3(float(cx) * CELL, level, float(cz) * CELL))
        if not bool(result.get("ok", false)):
            problems.append(String(result.get("reason", "tutorial actor spawn failed")))
            break
        spawned_ids.append(String(result.get("id", "")))
    if not problems.is_empty():
        clear_npcs()
    return {
        "ok": problems.is_empty(),
        "reason": "" if problems.is_empty() else "tutorial_actor_spawn_failed",
        "problems": problems,
        "spawnedIds": spawned_ids,
        "metrics": {"requestedActorCount": specs.size(), "spawnedActorCount": spawned_ids.size()}
    }

func spawn_npc(spec: Dictionary, level: float, look_target: Vector3) -> Dictionary:
    if main == null or main.npc_system == null or not main.npc_system.has_method("create_npc_body"):
        return {"ok": false, "reason": "missing_npc_body_factory"}
    var profile: Dictionary = spec.get("profile", {}) if spec.get("profile", {}) is Dictionary else {}
    var presentation: Dictionary = spec.get("presentation", {}) if spec.get("presentation", {}) is Dictionary else {}
    var actor_id := String(spec.get("id", ""))
    var body := main.npc_system.create_npc_body("TutorialNPC_%s" % actor_id, "tutorial_npc") as CharacterBody3D
    if body == null:
        return {"ok": false, "reason": "npc_body_creation_failed", "id": actor_id}
    var cell: Vector2i = spec.get("spawnCell")
    body.set_meta("npc_id", actor_id)
    body.set_meta("npc_name", String(presentation.get("name", actor_id)))
    body.set_meta("npc_role", String(presentation.get("role", profile.get("role", ""))))
    body.set_meta("dialogue", presentation.get("dialogue", []))
    body.set_meta("dialogue_index", 0)
    add_npc_visual(
        body,
        presentation.get("color", Color(0.55, 0.42, 0.31)),
        presentation.get("accent", Color(0.80, 0.66, 0.42)),
        String(presentation.get("name", actor_id)),
        String(presentation.get("role", profile.get("role", "")))
    )
    add_npc_collider(body)
    system.npc_root.add_child(body)
    var placement := place_tutorial_npc(body, cell, level, actor_id)
    if not bool(placement.get("ok", false)):
        system.npc_root.remove_child(body)
        body.free()
        return {"ok": false, "reason": "tutorial_actor_placement_failed", "id": actor_id, "placement": placement}
    var entry := register_with_npc_system(body, profile)
    if entry.is_empty():
        system.npc_root.remove_child(body)
        body.free()
        return {"ok": false, "reason": "tutorial_actor_registration_failed", "id": actor_id}
    if body.global_position.distance_to(look_target) > 0.2:
        body.look_at(look_target, Vector3.UP)
    return {"ok": true, "id": actor_id, "body": body, "entry": entry, "placement": placement}

func place_tutorial_npc(body: CharacterBody3D, requested_cell: Vector2i, level: float, npc_id: String) -> Dictionary:
    if body == null or main == null or main.npc_system == null or not main.npc_system.has_method("safe_place_npc"):
        return { "ok": false, "reason": "missing_safe_placement" }
    body.set_meta("npc_spawn_requested_cell", requested_cell)
    var requested_position := Vector3(float(requested_cell.x) * CELL, level + 0.02, float(requested_cell.y) * CELL)
    var initial: Dictionary = main.npc_system.safe_place_npc(body, requested_position, null, "tutorial_spawn")
    if bool(initial.get("ok", false)):
        body.set_meta("npc_spawn_fallback_used", false)
        body.set_meta("npc_spawn_placement", initial)
        return initial
    var max_radius := 10
    for radius in range(1, max_radius + 1):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if maxi(absi(dx), absi(dz)) != radius:
                    continue
                var candidate_cell := requested_cell + Vector2i(dx, dz)
                var candidate_position := Vector3(float(candidate_cell.x) * CELL, level + 0.02, float(candidate_cell.y) * CELL)
                var placement: Dictionary = main.npc_system.safe_place_npc(body, candidate_position, null, "tutorial_spawn_fallback")
                if not bool(placement.get("ok", false)):
                    continue
                placement["fallbackCell"] = candidate_cell
                placement["requestedCell"] = requested_cell
                placement["fallbackRadius"] = radius
                body.set_meta("npc_spawn_fallback_used", true)
                body.set_meta("npc_spawn_placement", placement)
                return placement
    var failed := {
        "ok": false,
        "position": requested_position,
        "reason": String(initial.get("reason", "placement_failed")),
        "requestedCell": requested_cell,
        "npcId": npc_id
    }
    body.set_meta("npc_spawn_fallback_used", false)
    body.set_meta("npc_spawn_placement", failed)
    return failed

func register_with_npc_system(body: Node3D, profile: Dictionary) -> Dictionary:
    if main == null or main.npc_system == null or not main.npc_system.has_method("register_npc"):
        return {}
    return main.npc_system.register_npc(body, profile)

func add_npc_collider(body: Node3D) -> void:
    if npc_visual_factory != null:
        npc_visual_factory.add_collider(body)

func add_npc_visual(parent: Node3D, color: Color, accent: Color, npc_name: String, role: String) -> void:
    var body_material := make_material(color, 0.82)
    var accent_material := make_material(accent, 0.74)
    if npc_visual_factory != null:
        npc_visual_factory.add_visual(parent, body_material, accent_material, npc_name, role)
        return
    var skin_material := make_material(Color(0.76, 0.55, 0.39), 0.70)
    var torso_mesh := CylinderMesh.new()
    torso_mesh.top_radius = 0.26
    torso_mesh.bottom_radius = 0.34
    torso_mesh.height = 0.92
    torso_mesh.radial_segments = 8
    add_mesh(parent, torso_mesh, body_material, Vector3(0.0, 0.72, 0.0), Vector3.ONE)
    var cloak_mesh := BoxMesh.new()
    cloak_mesh.size = Vector3(0.48, 0.48, 0.10)
    add_mesh(parent, cloak_mesh, accent_material, Vector3(0.0, 0.83, -0.28), Vector3.ONE)
    var head_mesh := SphereMesh.new()
    head_mesh.radius = 0.23
    head_mesh.height = 0.30
    head_mesh.radial_segments = 10
    head_mesh.rings = 6
    add_mesh(parent, head_mesh, skin_material, Vector3(0.0, 1.34, 0.0), Vector3.ONE)
    var hood_mesh := SphereMesh.new()
    hood_mesh.radius = 0.26
    hood_mesh.height = 0.20
    hood_mesh.radial_segments = 9
    hood_mesh.rings = 4
    add_mesh(parent, hood_mesh, accent_material, Vector3(0.0, 1.44, -0.03), Vector3(1.0, 0.54, 1.0))
    var arm_mesh := CylinderMesh.new()
    arm_mesh.top_radius = 0.055
    arm_mesh.bottom_radius = 0.065
    arm_mesh.height = 0.64
    arm_mesh.radial_segments = 6
    for side in [-1.0, 1.0]:
        var arm := MeshInstance3D.new()
        arm.mesh = arm_mesh
        arm.material_override = body_material
        arm.position = Vector3(side * 0.34, 0.78, 0.0)
        arm.rotation.z = side * 0.22
        parent.add_child(arm)
    var label := Label3D.new()
    label.text = "%s\n%s" % [npc_name, role]
    label.font_size = 28
    label.position.y = 1.88
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.no_depth_test = true
    parent.add_child(label)

func add_mesh(parent: Node3D, mesh: Mesh, material: Material, position: Vector3, scale: Vector3) -> void:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = material
    instance.position = position
    instance.scale = scale
    parent.add_child(instance)

func add_warm_light(position: Vector3, radius: float, energy: float, foundation_y := NAN) -> void:
    if system.light_root == null:
        return
    var cast_shadows := main != null and bool(main.get("shadows_enabled"))
    var fill_position := position
    if not is_nan(float(foundation_y)):
        fill_position.y = float(foundation_y) + CELL * 0.36
    elif main != null and main.has_method("surface_y_at_position"):
        fill_position.y = float(main.call("surface_y_at_position", position)) + CELL * 0.36
    else:
        fill_position.y = position.y - CELL * 0.85
    LocalLightRigScript.add_rig(system.light_root, "tutorial_lantern", {
        "context": "placed",
        "scale": CELL,
        "source_position": position,
        "terrain_position": fill_position,
        "bounce_position": fill_position + Vector3(0.0, CELL * 0.72, 0.0),
        "source_energy": energy,
        "source_range": radius,
        "terrain_energy": energy * 0.70,
        "terrain_range": radius * 0.85,
        "bounce_energy": energy * 0.38,
        "bounce_range": radius * 1.05,
        "shadows": cast_shadows,
        "day_suppressed": true
    })

func make_material(color: Color, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = roughness
    return material

func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D:
    var material := make_material(color, 0.48)
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = energy
    return material

func clear_scene() -> void:
    system.clear_speech_bubbles()
    system.clear_rescue_torch()
    clear_npcs()
    clear_lights()
    system.clear_repair_markers()

func clear_npcs() -> void:
    if system.npc_root == null:
        return
    for child in system.npc_root.get_children():
        if main and main.npc_system and main.npc_system.has_method("unregister_npc"):
            main.npc_system.unregister_npc(child)
        system.npc_root.remove_child(child)
        child.queue_free()

func clear_lights() -> void:
    if system.light_root == null:
        return
    for child in system.light_root.get_children():
        system.light_root.remove_child(child)
        child.queue_free()

func npc_count() -> int:
    if system.npc_root == null:
        return 0
    return system.npc_root.get_child_count()
