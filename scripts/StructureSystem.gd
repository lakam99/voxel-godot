extends RefCounted
class_name StructureSystem

const StructureDoorRulesScript := preload("res://scripts/StructureDoorRules.gd")
const StructureLootScript := preload("res://scripts/StructureLoot.gd")
const TownRuntimeManifestScript := preload("res://scripts/world/TownRuntimeManifest.gd")
const StartupReadinessResultScript := preload("res://scripts/world/StartupReadinessResult.gd")

const STREAMING_STRUCTURE_OPS_PER_FRAME := 24
const STREAMING_STRUCTURE_FRAME_BUDGET_MS := 6.0
const STREAMING_STRUCTURE_QUEUE_COMPACT_THRESHOLD := 256

var main
var loot
var generated_towns := {}
var generated_structures := {}
var generated_building_count := 0
var generated_town_count := 0
var generated_mine_count := 0
var generated_ruin_count := 0
var generated_shrine_count := 0
var generated_camp_count := 0
var generated_path_count := 0
var generated_door_count := 0
var generated_utility_count := 0
var town_home_records := {}
var pending_structure_ops: Array = []
var pending_structure_op_index := 0
var defer_structure_ops := false
var deferred_town_home_records := {}
var town_manifest_publish_states := {}
var active_structure_town_key := ""
var terrain_surface_sample_cache := {}
var terrain_footprint_records := {}
var natural_prop_exclusion_records := {}
var private_interior_records := {}
var private_interior_revision := 0

func setup(main_node) -> void:
    main = main_node
    loot = StructureLootScript.new()

func reset() -> void:
    generated_towns.clear()
    generated_structures.clear()
    generated_building_count = 0
    generated_town_count = 0
    generated_mine_count = 0
    generated_ruin_count = 0
    generated_shrine_count = 0
    generated_camp_count = 0
    generated_path_count = 0
    generated_door_count = 0
    generated_utility_count = 0
    town_home_records.clear()
    pending_structure_ops.clear()
    pending_structure_op_index = 0
    defer_structure_ops = false
    deferred_town_home_records.clear()
    town_manifest_publish_states.clear()
    active_structure_town_key = ""
    terrain_surface_sample_cache.clear()
    terrain_footprint_records.clear()
    natural_prop_exclusion_records.clear()
    private_interior_records.clear()
    private_interior_revision += 1

func register_private_interior(stable_id: String, min_cell: Vector2i, max_cell: Vector2i, owner_actor_id := "") -> bool:
    var normalized_id := stable_id.strip_edges()
    if normalized_id == "":
        return false
    var record := {
        "stableId": normalized_id,
        "interiorMinCell": Vector2i(mini(min_cell.x, max_cell.x), mini(min_cell.y, max_cell.y)),
        "interiorMaxCell": Vector2i(maxi(min_cell.x, max_cell.x), maxi(min_cell.y, max_cell.y)),
        "ownerActorId": String(owner_actor_id).strip_edges()
    }
    if private_interior_records.get(normalized_id, {}) == record:
        return true
    private_interior_records[normalized_id] = record
    private_interior_revision += 1
    return true

func private_interior_records_snapshot() -> Array:
    var records: Array = []
    for stable_id in private_interior_records.keys():
        records.append((private_interior_records[stable_id] as Dictionary).duplicate(true))
    records.sort_custom(func(a, b): return String(a.get("stableId", "")) < String(b.get("stableId", "")))
    return records

func private_interior_records_revision() -> int:
    return private_interior_revision

func update_around(center_cell: Vector2i) -> void:
    if main == null:
        return
    terrain_surface_sample_cache.clear()
    update_towns(center_cell)
    update_standalone_structures(center_cell)

func update_around_budgeted(center_cell: Vector2i, allow_builds := true) -> int:
    if main == null:
        return 0
    terrain_surface_sample_cache.clear()
    var monitor = performance_monitor()
    var towns_start: int = monitor.begin_section("structure_scan_towns") if monitor != null else Time.get_ticks_usec()
    update_towns(center_cell, true)
    if monitor != null:
        monitor.end_section("structure_scan_towns", towns_start)
    var standalone_start: int = monitor.begin_section("structure_scan_standalone") if monitor != null else Time.get_ticks_usec()
    update_standalone_structures(center_cell, true, 1)
    if monitor != null:
        monitor.end_section("structure_scan_standalone", standalone_start)
    if not allow_builds:
        if monitor != null:
            monitor.increment_counter("structure_op_queue_depth", pending_structure_op_count())
        return 0
    return process_pending_structure_ops()

func update_towns(center_cell: Vector2i, defer_builds := false) -> void:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.TOWN_REGION_CELLS)), floori(float(center_cell.y) / float(main.TOWN_REGION_CELLS)))
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_towns.has(key):
                continue
            var town: Dictionary = main.town_region(rx, rz)
            if town.is_empty():
                generated_towns[key] = false
                continue
            var distance := Vector2(float(center_cell.x - int(town["centerX"])), float(center_cell.y - int(town["centerZ"]))).length()
            var active_render_distance: int = int(main.get("render_distance"))
            if active_render_distance <= 0:
                active_render_distance = main.RENDER_DISTANCE
            var activation_range: float = float(main.TOWN_RADIUS_CELLS + main.CHUNK_SIZE * active_render_distance + 20)
            if distance > activation_range:
                continue
            generated_towns[key] = true
            if defer_builds:
                enqueue_deferred_town_build(town)
            else:
                build_town(town)

func update_standalone_structures(center_cell: Vector2i, defer_builds := false, max_new_regions := 9) -> int:
    var center_region := Vector2i(floori(float(center_cell.x) / float(main.STRUCTURE_REGION_CELLS)), floori(float(center_cell.y) / float(main.STRUCTURE_REGION_CELLS)))
    var new_regions := 0
    for rz in range(center_region.y - 1, center_region.y + 2):
        for rx in range(center_region.x - 1, center_region.x + 2):
            var key := Vector2i(rx, rz)
            if generated_structures.has(key):
                continue
            new_regions += 1
            var roll: float = main.hash01("structure:%d,%d" % [rx, rz])
            if roll > main.STRUCTURE_SPAWN_CHANCE:
                generated_structures[key] = false
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            var rng := RandomNumberGenerator.new()
            rng.seed = main.hash_string("%s:structure:%d,%d" % [main.seed_text, rx, rz])
            var base_x: int = rx * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var base_z: int = rz * main.STRUCTURE_REGION_CELLS + rng.randi_range(16, main.STRUCTURE_REGION_CELLS - 18)
            var structure_type := standalone_structure_type(rng)
            var dimensions := structure_dimensions_for_type(structure_type, rng)
            var level := flat_level_for_footprint(base_x, base_z, dimensions.x, dimensions.y)
            if is_nan(level):
                generated_structures[key] = false
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            generated_structures[key] = true
            if defer_builds:
                enqueue_standalone_structure_build(structure_type, base_x, base_z, level, dimensions, rng)
                if max_new_regions > 0 and new_regions >= max_new_regions:
                    return new_regions
                continue
            if structure_type == "mine":
                build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "ruin":
                build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "shrine":
                build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            elif structure_type == "camp":
                build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
            else:
                var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
                var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
                build_building(base_x, base_z, level, dimensions.x, dimensions.y, rng.randi_range(4, 5), wall_type, roof_type, rng.randi_range(0, 3), rng, false)
            if max_new_regions > 0 and new_regions >= max_new_regions:
                return new_regions
    return new_regions

func enqueue_standalone_structure_build(structure_type: String, base_x: int, base_z: int, level: float, dimensions: Vector2i, rng: RandomNumberGenerator) -> void:
    if structure_type == "mine":
        enqueue_deferred_build(func() -> void:
            build_mine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "ruin":
        enqueue_deferred_build(func() -> void:
            build_ruin(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "shrine":
        enqueue_deferred_build(func() -> void:
            build_shrine(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    elif structure_type == "camp":
        enqueue_deferred_build(func() -> void:
            build_camp(base_x, base_z, level, dimensions.x, dimensions.y, rng)
        )
    else:
        var wall_type := "woodBlock" if rng.randf() < 0.5 else "stoneBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var wall_height := rng.randi_range(4, 5)
        var door_side := rng.randi_range(0, 3)
        enqueue_deferred_build(func() -> void:
            build_building(base_x, base_z, level, dimensions.x, dimensions.y, wall_height, wall_type, roof_type, door_side, rng, false)
        )

func enqueue_deferred_build(build_callable: Callable) -> void:
    var previous := defer_structure_ops
    defer_structure_ops = true
    build_callable.call()
    defer_structure_ops = previous

func enqueue_deferred_town_build(town: Dictionary) -> void:
    if town.is_empty() or main == null:
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var town_key := town_key_for(town)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    if String(publish_state.get("status", "")) in ["queued", "building", "published"]:
        return
    var attempts := int(publish_state.get("generationAttempts", 0)) + 1
    town_manifest_publish_states[town_key] = {
        "status": "queued",
        "generationAttempts": attempts,
        "startedUsec": int(publish_state.get("startedUsec", Time.get_ticks_usec())),
        "updatedUsec": Time.get_ticks_usec(),
        "desiredHomeCount": town_home_count(town),
        "builtHomeCount": 0,
        "failureReasons": []
    }
    deferred_town_home_records[town_key] = []
    generated_town_count += 1
    enqueue_structure_op({
        "type": "town_build_phase",
        "townKey": town_key,
        "state": {
            "town": town.duplicate(true),
            "townKey": town_key,
            "phase": "paths",
            "rng": rng,
            "sites": town_home_sites(town, rng),
            "desiredHomeCount": town_home_count(town),
            "homeSiteIndex": 0,
            "builtHomeCount": 0
        }
    })

func process_deferred_town_build_phase(state_value) -> void:
    if not (state_value is Dictionary):
        return
    var state: Dictionary = state_value
    var town: Dictionary = state.get("town", {}) if state.get("town", {}) is Dictionary else {}
    if town.is_empty():
        return
    var rng := state.get("rng") as RandomNumberGenerator
    if rng == null:
        return
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := String(state.get("townKey", town_key_for(town)))
    var phase := String(state.get("phase", "paths"))
    var complete := false
    var previous := defer_structure_ops
    var previous_town_key := active_structure_town_key
    defer_structure_ops = true
    active_structure_town_key = town_key
    update_town_manifest_publish_state(town_key, {
        "status": "building",
        "builtHomeCount": int(state.get("builtHomeCount", 0)),
        "desiredHomeCount": int(state.get("desiredHomeCount", town_home_count(town)))
    })
    if phase == "paths":
        build_town_paths(center_x, center_z, int(town["radius"]), level)
        state["phase"] = "perimeter"
    elif phase == "perimeter":
        build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
        state["phase"] = "homes"
    elif phase == "homes":
        process_deferred_town_home_phase(state, town, rng, town_key, level)
    elif phase == "market":
        build_town_market(center_x, center_z, level, rng)
        state["phase"] = "utilities"
    elif phase == "utilities":
        place_utility(center_x - 2, center_z + 1, level, "chest", {
            "storageSlots": loot.make_loot_slots(rng, "town"),
            "generatedTier": "town",
            "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
        })
        place_utility(center_x + 2, center_z + 1, level, "furnace")
        place_utility(center_x, center_z - 3, level, "workbench")
        state["phase"] = "publish"
    elif phase == "publish":
        enqueue_structure_op({
            "type": "publish_town_home_records",
            "townKey": town_key
        })
        complete = true
    else:
        complete = true
    defer_structure_ops = previous
    active_structure_town_key = previous_town_key
    if not complete:
        enqueue_structure_op({
            "type": "town_build_phase",
            "townKey": town_key,
            "state": state
        })

func process_deferred_town_home_phase(state: Dictionary, town: Dictionary, rng: RandomNumberGenerator, town_key: String, level: float) -> void:
    var sites: Array = state.get("sites", []) if state.get("sites", []) is Array else []
    var desired_home_count := int(state.get("desiredHomeCount", town_home_count(town)))
    var built_home_count := int(state.get("builtHomeCount", 0))
    var site_index := int(state.get("homeSiteIndex", 0))
    while site_index < sites.size() and built_home_count < desired_home_count:
        var site: Dictionary = sites[site_index] if sites[site_index] is Dictionary else {}
        site_index += 1
        if site.is_empty():
            continue
        var base_x := int(town["centerX"]) + int(site["dx"])
        var base_z := int(town["centerZ"]) + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if site_index % 2 == 1 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
        break
    state["homeSiteIndex"] = site_index
    state["builtHomeCount"] = built_home_count
    update_town_manifest_publish_state(town_key, {
        "builtHomeCount": built_home_count,
        "desiredHomeCount": desired_home_count
    })
    if built_home_count >= desired_home_count or site_index >= sites.size():
        state["phase"] = "market"

func performance_monitor():
    if main == null:
        return null
    return main.get("runtime_perf_monitor")

func pending_structure_op_count() -> int:
    return max(0, pending_structure_ops.size() - pending_structure_op_index)

func enqueue_structure_op(op: Dictionary) -> void:
    if active_structure_town_key != "" and String(op.get("townKey", "")) == "":
        op["townKey"] = active_structure_town_key
    pending_structure_ops.append(op)

func process_pending_structure_ops(max_ops := STREAMING_STRUCTURE_OPS_PER_FRAME, budget_ms := STREAMING_STRUCTURE_FRAME_BUDGET_MS) -> int:
    if pending_structure_op_index >= pending_structure_ops.size():
        pending_structure_ops.clear()
        pending_structure_op_index = 0
        return 0
    var monitor = performance_monitor()
    var queue_start: int = monitor.begin_section("structure_op_queue") if monitor != null else Time.get_ticks_usec()
    var processed := 0
    var frame_start := Time.get_ticks_usec()
    while pending_structure_op_index < pending_structure_ops.size() and processed < max_ops:
        var op: Dictionary = pending_structure_ops[pending_structure_op_index]
        pending_structure_op_index += 1
        execute_structure_op(op)
        processed += 1
        if float(Time.get_ticks_usec() - frame_start) / 1000.0 >= budget_ms:
            break
    if pending_structure_op_index >= pending_structure_ops.size():
        pending_structure_ops.clear()
        pending_structure_op_index = 0
    elif pending_structure_op_index >= STREAMING_STRUCTURE_QUEUE_COMPACT_THRESHOLD:
        pending_structure_ops = pending_structure_ops.slice(pending_structure_op_index)
        pending_structure_op_index = 0
    if monitor != null:
        monitor.increment_counter("structure_ops_processed", processed)
        monitor.increment_counter("structure_op_queue_depth", pending_structure_op_count())
        monitor.end_section("structure_op_queue", queue_start)
    return processed

func execute_structure_op(op: Dictionary) -> void:
    var previous := defer_structure_ops
    defer_structure_ops = false
    var op_type := String(op.get("type", ""))
    if op_type == "block":
        place_structure_block(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), int(op.get("dy", 0)), String(op.get("blockType", "")), op.get("options", {}))
    elif op_type == "path":
        place_path(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), op.get("options", {}))
    elif op_type == "utility":
        place_utility(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), String(op.get("blockType", "")), op.get("options", {}))
    elif op_type == "door":
        place_door(int(op.get("cellX", 0)), int(op.get("cellZ", 0)), float(op.get("level", 0.0)), int(op.get("side", 0)), bool(op.get("secondary", false)), String(op.get("doorPolicy", "private_home")))
    elif op_type == "terrain_footprint":
        reserve_structure_terrain_footprint(
            int(op.get("baseX", 0)),
            int(op.get("baseZ", 0)),
            float(op.get("level", 0.0)),
            int(op.get("width", 0)),
            int(op.get("depth", 0)),
            int(op.get("clearanceCells", 0)),
            String(op.get("source", "structure")),
            String(op.get("foundationMaterial", "stone"))
        )
    elif op_type == "publish_town_home_records":
        publish_deferred_town_home_records(String(op.get("townKey", "")))
    elif op_type == "town_build_phase":
        process_deferred_town_build_phase(op.get("state", {}))
    defer_structure_ops = previous

func publish_deferred_town_home_records(town_key: String) -> void:
    if town_key == "":
        return
    var records: Array = deferred_town_home_records.get(town_key, [])
    var existing_value = town_home_records.get(town_key, [])
    var existing_records: Array = existing_value if existing_value is Array else []
    if existing_records.size() > records.size():
        deferred_town_home_records.erase(town_key)
        update_town_manifest_publish_state(town_key, {
            "status": "published",
            "builtHomeCount": existing_records.size()
        })
        return
    town_home_records[town_key] = records.duplicate(true)
    deferred_town_home_records.erase(town_key)
    update_town_manifest_publish_state(town_key, {
        "status": "published",
        "builtHomeCount": records.size()
    })

func standalone_structure_type(rng: RandomNumberGenerator) -> String:
    var roll := rng.randf()
    if roll < 0.12:
        return "shrine"
    if roll < 0.32:
        return "mine"
    if roll < 0.58:
        return "ruin"
    if roll < 0.74:
        return "camp"
    return "cabin"

func structure_dimensions_for_type(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
    if structure_type == "shrine":
        return Vector2i(9, 9)
    if structure_type == "mine":
        return Vector2i(rng.randi_range(10, 12), rng.randi_range(12, 14))
    if structure_type == "camp":
        return Vector2i(rng.randi_range(11, 13), rng.randi_range(10, 12))
    return Vector2i(rng.randi_range(7, 10), rng.randi_range(7, 10))

func remember_terrain_surface_sample(cache_key: Vector2i, sample: Dictionary) -> Dictionary:
    terrain_surface_sample_cache[cache_key] = sample.duplicate(true)
    return sample

func terrain_surface_sample_at_cell(cell_x: int, cell_z: int) -> Dictionary:
    var cache_key := Vector2i(cell_x, cell_z)
    if terrain_surface_sample_cache.has(cache_key):
        var cached: Dictionary = terrain_surface_sample_cache[cache_key]
        return cached.duplicate(true)
    var column_cell := Vector3i(cell_x, 0, cell_z)
    var fallback_height := float(main.surface_y_at_cell(column_cell)) if main != null and main.has_method("surface_y_at_cell") else 0.0
    var fallback_biome := String(main.surface_biome_at_cell(column_cell)) if main != null and main.has_method("surface_biome_at_cell") else "plains"
    var fallback_material := ""
    var fallback := {
        "found": true,
        "height": fallback_height,
        "biome": fallback_biome,
        "material": fallback_material,
        "authority": "height_compat"
    }
    if main == null or main.world_generation_system == null:
        return remember_terrain_surface_sample(cache_key, fallback)
    var world_generation = main.world_generation_system
    if world_generation.has_method("terrain_volume_column_has_surface_projection_affecting_edits"):
        var has_surface_edits := bool(world_generation.call("terrain_volume_column_has_surface_projection_affecting_edits", column_cell))
        if not has_surface_edits:
            return remember_terrain_surface_sample(cache_key, fallback)
    if not world_generation.has_method("surface_projection_for_cell"):
        return remember_terrain_surface_sample(cache_key, fallback)
    var start_cell := Vector3i(cell_x, floori(fallback_height / main.CELL), cell_z)
    var projection: Dictionary = world_generation.call("surface_projection_for_cell", start_cell, 8, 32)
    if projection.is_empty() or not bool(projection.get("found", false)):
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        return remember_terrain_surface_sample(cache_key, fallback)
    var solid_state: Dictionary = projection.get("solidState", {}) if projection.get("solidState", {}) is Dictionary else {}
    var air_state: Dictionary = projection.get("airState", {}) if projection.get("airState", {}) is Dictionary else {}
    var material := String(solid_state.get("material", ""))
    if material == "" or material == "air" or material == "water" or material == "lava":
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        fallback["material"] = material
        return remember_terrain_surface_sample(cache_key, fallback)
    if String(air_state.get("fluid", "")) != "":
        fallback["found"] = false
        fallback["authority"] = "terrain_volume_projection"
        fallback["material"] = material
        return remember_terrain_surface_sample(cache_key, fallback)
    var air_cell: Vector3i = projection.get("airCell", start_cell + Vector3i(0, 1, 0))
    var biome := String(solid_state.get("biome", fallback_biome))
    if biome == "" or biome == "underground" or biome == "deep_underground" or biome == "underground_air":
        biome = fallback_biome
    return remember_terrain_surface_sample(cache_key, {
        "found": true,
        "height": float(air_cell.y) * main.CELL,
        "biome": biome,
        "material": material,
        "solidCell": projection.get("solidCell", start_cell),
        "airCell": air_cell,
        "authority": "terrain_volume_projection"
    })

func structure_surface_level_for_cell(cell_x: int, cell_z: int, fallback_level: float) -> float:
    var sample := terrain_surface_sample_at_cell(cell_x, cell_z)
    if bool(sample.get("found", false)):
        var level := float(sample.get("height", fallback_level))
        if not is_nan(level):
            return level
    return fallback_level

func structure_surface_level_for_gate_pair(first_cell: Vector2i, second_cell: Vector2i, fallback_level: float) -> float:
    var first_sample := terrain_surface_sample_at_cell(first_cell.x, first_cell.y)
    var second_sample := terrain_surface_sample_at_cell(second_cell.x, second_cell.y)
    var levels: Array[float] = []
    if bool(first_sample.get("found", false)):
        var first_level := float(first_sample.get("height", fallback_level))
        if not is_nan(first_level):
            levels.append(first_level)
    if bool(second_sample.get("found", false)):
        var second_level := float(second_sample.get("height", fallback_level))
        if not is_nan(second_level):
            levels.append(second_level)
    if levels.size() == 2:
        return (levels[0] + levels[1]) * 0.5
    if levels.size() == 1:
        return levels[0]
    return fallback_level

func reserve_structure_terrain_footprint(base_x: int, base_z: int, level: float, width: int, depth: int, clearance_cells: int, source: String, foundation_material := "stone") -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "terrain_footprint",
            "baseX": base_x,
            "baseZ": base_z,
            "level": level,
            "width": width,
            "depth": depth,
            "clearanceCells": clearance_cells,
            "source": source,
            "foundationMaterial": foundation_material
        })
        return
    if main == null or main.world_generation_system == null:
        return
    var world_generation = main.world_generation_system
    if not world_generation.has_method("apply_box_edit"):
        return
    var floor_y := floori(level / main.CELL)
    record_structure_terrain_footprint(base_x, base_z, level, width, depth, clearance_cells, source, foundation_material, floor_y)
    var center_sample := terrain_surface_sample_at_cell(base_x + int(width / 2), base_z + int(depth / 2))
    var biome := String(center_sample.get("biome", "plains"))
    var foundation_state := {
        "material": foundation_material,
        "biome": biome,
        "solid": true,
        "density": main.CELL * 1.65,
        "fluid": "",
        "light": { "sky": 0, "block": 0 },
        "metadata": {
            "source": "structure_foundation",
            "structureSource": source,
            "terrainMeshAffects": true,
            "saveDelta": false
        }
    }
    var floor_cap_state := foundation_state.duplicate(true)
    floor_cap_state["density"] = main.CELL * 0.08
    var floor_cap_metadata: Dictionary = floor_cap_state.get("metadata", {}) if floor_cap_state.get("metadata", {}) is Dictionary else {}
    floor_cap_metadata = floor_cap_metadata.duplicate(true)
    floor_cap_metadata["source"] = "structure_floor_cap"
    floor_cap_metadata["structureSource"] = source
    floor_cap_state["metadata"] = floor_cap_metadata
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x - 1, floor_y - 3, base_z - 1),
        Vector3i(base_x + width, floor_y - 1, base_z + depth),
        foundation_state,
        "structure_foundation:%s" % source
    )
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x - 1, floor_y, base_z - 1),
        Vector3i(base_x + width, floor_y, base_z + depth),
        floor_cap_state,
        "structure_floor_cap:%s" % source
    )
    if width <= 2 or depth <= 2 or clearance_cells <= 0:
        return
    var interior_air_state := {
        "material": "air",
        "biome": biome,
        "solid": false,
        "density": -main.CELL,
        "fluid": "",
        "light": { "sky": 15, "block": 0 },
        "metadata": {
            "source": "structure_reserved_air",
            "structureSource": source,
            "terrainMeshAffects": true,
            "saveDelta": false
        }
    }
    world_generation.call(
        "apply_box_edit",
        Vector3i(base_x + 1, floor_y + 1, base_z + 1),
        Vector3i(base_x + width - 2, floor_y + clearance_cells, base_z + depth - 2),
        interior_air_state,
        "structure_air:%s" % source
    )

func record_structure_terrain_footprint(base_x: int, base_z: int, level: float, width: int, depth: int, clearance_cells: int, source: String, foundation_material: String, floor_y: int) -> void:
    if width <= 0 or depth <= 0:
        return
    var min_cell := Vector3i(base_x - 1, floor_y - 3, base_z - 1)
    var max_cell := Vector3i(base_x + width, floor_y, base_z + depth)
    var record_id := "%s:%d,%d:%dx%d:%d" % [source, base_x, base_z, width, depth, floor_y]
    terrain_footprint_records[record_id] = {
        "id": record_id,
        "source": source,
        "material": foundation_material,
        "baseX": base_x,
        "baseZ": base_z,
        "width": width,
        "depth": depth,
        "level": level,
        "floorY": floor_y,
        "clearanceCells": clearance_cells,
        "minCell": min_cell,
        "maxCell": max_cell
    }

func structure_terrain_footprints_for_chunk(chunk_key: Vector2i, chunk_size: int) -> Array:
    var result := []
    var size := maxi(1, int(chunk_size))
    var start_x := chunk_key.x * size
    var start_z := chunk_key.y * size
    var end_x := start_x + size
    var end_z := start_z + size
    for record_value in terrain_footprint_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var min_cell: Vector3i = record.get("minCell", Vector3i.ZERO)
        var max_cell: Vector3i = record.get("maxCell", Vector3i.ZERO)
        if max_cell.x < start_x or min_cell.x >= end_x:
            continue
        if max_cell.z < start_z or min_cell.z >= end_z:
            continue
        result.append(record.duplicate(true))
    return result

func structure_terrain_footprints_snapshot() -> Array:
    var result := []
    for record_value in terrain_footprint_records.values():
        if record_value is Dictionary:
            result.append((record_value as Dictionary).duplicate(true))
    return result

func reserve_natural_prop_exclusion(base_x: int, base_z: int, width: int, depth: int, source: String) -> void:
    if width <= 0 or depth <= 0:
        return
    var record_id := "%s:%d,%d:%dx%d" % [source, base_x, base_z, width, depth]
    natural_prop_exclusion_records[record_id] = {
        "id": record_id,
        "source": source,
        "minX": base_x,
        "maxX": base_x + width - 1,
        "minZ": base_z,
        "maxZ": base_z + depth - 1
    }

func blocks_natural_prop_at_cell(x: int, z: int) -> bool:
    return blocks_natural_prop_with_margin_at_cell(x, z, 0)

func blocks_natural_prop_with_margin_at_cell(x: int, z: int, margin_cells: int) -> bool:
    return blocks_natural_prop_with_separate_margins_at_cell(x, z, margin_cells, margin_cells)

func blocks_natural_prop_with_separate_margins_at_cell(
    x: int,
    z: int,
    natural_exclusion_margin_cells: int,
    structure_footprint_margin_cells: int
) -> bool:
    var natural_margin := maxi(0, natural_exclusion_margin_cells)
    for record_value in natural_prop_exclusion_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        if x >= int(record.get("minX", x)) - natural_margin \
            and x <= int(record.get("maxX", x)) + natural_margin \
            and z >= int(record.get("minZ", z)) - natural_margin \
            and z <= int(record.get("maxZ", z)) + natural_margin:
            return true
    var structure_margin := maxi(0, structure_footprint_margin_cells)
    for record_value in terrain_footprint_records.values():
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var min_cell: Vector3i = record.get("minCell", Vector3i.ZERO)
        var max_cell: Vector3i = record.get("maxCell", Vector3i.ZERO)
        if x >= min_cell.x - structure_margin and x <= max_cell.x + structure_margin \
            and z >= min_cell.z - structure_margin and z <= max_cell.z + structure_margin:
            return true
    return false

func build_town(town: Dictionary) -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = main.hash_string("%s:town-build:%d,%d" % [main.seed_text, int(town["regionX"]), int(town["regionZ"])])
    var center_x := int(town["centerX"])
    var center_z := int(town["centerZ"])
    var level := float(town["level"])
    var town_key := town_key_for(town)
    var previous_town_key := active_structure_town_key
    active_structure_town_key = town_key
    begin_town_manifest_generation_state(town_key, town)
    if defer_structure_ops:
        deferred_town_home_records[town_key] = []
    else:
        town_home_records[town_key] = []
    generated_town_count += 1
    build_town_paths(center_x, center_z, int(town["radius"]), level)
    build_town_perimeter(center_x, center_z, int(town["radius"]), level, town_key)
    var desired_home_count := town_home_count(town)
    var sites := town_home_sites(town, rng)
    var built_home_count := 0
    for i in range(sites.size()):
        if built_home_count >= desired_home_count:
            break
        var site: Dictionary = sites[i]
        var base_x := center_x + int(site["dx"])
        var base_z := center_z + int(site["dz"])
        var side := int(site["side"])
        if town_home_site_excluded(town, base_x, base_z, 10, 10, side):
            continue
        var width := rng.randi_range(7, 9)
        var depth := rng.randi_range(7, 9)
        var wall_height := rng.randi_range(4, 5)
        var wall_type := "woodBlock" if i % 2 == 0 else "stoneBlock"
        if rng.randf() < 0.35:
            wall_type = "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        var roof_type := "stoneBlock" if wall_type == "woodBlock" else "woodBlock"
        if town_home_site_excluded(town, base_x, base_z, width, depth, side):
            continue
        build_building(base_x, base_z, level, width, depth, wall_height, wall_type, roof_type, side, rng, true)
        record_town_home(town_key, town, base_x, base_z, width, depth, side, built_home_count)
        built_home_count += 1
    build_town_market(center_x, center_z, level, rng)
    place_utility(center_x - 2, center_z + 1, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "town"),
        "generatedTier": "town",
        "cacheKey": "%s:town-cache:%d,%d" % [main.seed_text, center_x, center_z]
    })
    place_utility(center_x + 2, center_z + 1, level, "furnace")
    place_utility(center_x, center_z - 3, level, "workbench")
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "publish_town_home_records",
            "townKey": town_key
        })
    else:
        update_town_manifest_publish_state(town_key, {
            "status": "published",
            "builtHomeCount": built_home_count
        })
    active_structure_town_key = previous_town_key

func build_town_paths(center_x: int, center_z: int, radius: int, level: float) -> void:
    var path_span: int = max(10, radius - 2)
    for offset in range(-path_span, path_span + 1):
        place_town_path_cell(center_x + offset, center_z, level)
        place_town_path_cell(center_x, center_z + offset, level)
        if offset % 4 == 0:
            place_town_path_cell(center_x + offset, center_z + 1, level)
            place_town_path_cell(center_x + 1, center_z + offset, level)

func place_town_path_cell(cell_x: int, cell_z: int, fallback_level: float, extra_options: Dictionary = {}) -> void:
    place_path(cell_x, cell_z, structure_surface_level_for_cell(cell_x, cell_z, fallback_level), extra_options)

func town_home_count(town: Dictionary) -> int:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var extra_from_radius: int = clampi(floori(float(radius - main.TOWN_RADIUS_CELLS) * 0.75), 0, 7)
    var bonus := int(main.hash01("town-home-count:%d,%d" % [int(town.get("regionX", 0)), int(town.get("regionZ", 0))]) * 3.0)
    return clampi(4 + extra_from_radius + bonus, 4, 12)

func town_home_sites(town: Dictionary, _rng: RandomNumberGenerator) -> Array:
    var radius := int(town.get("radius", main.TOWN_RADIUS_CELLS))
    var candidates := [
        { "dx": -16, "dz": -13, "side": 2 },
        { "dx": 8, "dz": -14, "side": 2 },
        { "dx": -17, "dz": 8, "side": 0 },
        { "dx": 9, "dz": 9, "side": 0 },
        { "dx": -5, "dz": -25, "side": 2 },
        { "dx": 22, "dz": -4, "side": 1 },
        { "dx": -29, "dz": -4, "side": 3 },
        { "dx": -5, "dz": 20, "side": 0 },
        { "dx": 18, "dz": 18, "side": 0 },
        { "dx": -24, "dz": 18, "side": 0 },
        { "dx": 18, "dz": -24, "side": 2 },
        { "dx": -24, "dz": -24, "side": 2 }
    ]
    var sites := []
    for candidate_value in candidates:
        var candidate: Dictionary = candidate_value
        var dx := int(candidate.get("dx", 0))
        var dz := int(candidate.get("dz", 0))
        if maxi(absi(dx), absi(dz)) > radius - 4:
            continue
        sites.append(candidate)
    return sites

func town_home_site_excluded(town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int) -> bool:
    var rings_value = town.get("homeExclusionRings", [])
    if not (rings_value is Array):
        return false
    var min_x := base_x - 1
    var max_x := base_x + width
    var min_z := base_z - 1
    var max_z := base_z + depth
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for entry_value in door_entries:
        var entry: Dictionary = entry_value
        var door_x := base_x + int(entry.get("x", 0))
        var door_z := base_z + int(entry.get("z", 0))
        if door_side == 0:
            max_z = maxi(max_z, door_z + 1)
        elif door_side == 2:
            min_z = mini(min_z, door_z - 1)
        elif door_side == 1:
            max_x = maxi(max_x, door_x + 1)
        elif door_side == 3:
            min_x = mini(min_x, door_x - 1)
    var center_x := int(town.get("centerX", 0))
    var center_z := int(town.get("centerZ", 0))
    for ring_value in rings_value:
        if not (ring_value is Dictionary):
            continue
        var ring: Dictionary = ring_value
        var radius := int(ring.get("radius", 0))
        if radius <= 0:
            continue
        var margin := maxi(0, int(ring.get("margin", 0)))
        if rect_intersects_town_ring(min_x, max_x, min_z, max_z, center_x, center_z, radius, margin):
            return true
    return false

func rect_intersects_town_ring(min_x: int, max_x: int, min_z: int, max_z: int, center_x: int, center_z: int, radius: int, margin: int) -> bool:
    var west := center_x - radius
    var east := center_x + radius
    var north := center_z - radius
    var south := center_z + radius
    var min_ring_x := west - margin
    var max_ring_x := east + margin
    var min_ring_z := north - margin
    var max_ring_z := south + margin
    if ranges_intersect(min_z, max_z, north - margin, north + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_z, max_z, south - margin, south + margin) and ranges_intersect(min_x, max_x, min_ring_x, max_ring_x):
        return true
    if ranges_intersect(min_x, max_x, west - margin, west + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    if ranges_intersect(min_x, max_x, east - margin, east + margin) and ranges_intersect(min_z, max_z, min_ring_z, max_ring_z):
        return true
    return false

func ranges_intersect(a_min: int, a_max: int, b_min: int, b_max: int) -> bool:
    return a_min <= b_max and b_min <= a_max

func build_town_perimeter(center_x: int, center_z: int, radius: int, level: float, town_key: String) -> void:
    var gate_cells := {}
    var north_level := structure_surface_level_for_gate_pair(Vector2i(center_x, center_z - radius), Vector2i(center_x + 1, center_z - radius), level)
    var south_level := structure_surface_level_for_gate_pair(Vector2i(center_x, center_z + radius), Vector2i(center_x + 1, center_z + radius), level)
    var west_level := structure_surface_level_for_gate_pair(Vector2i(center_x - radius, center_z), Vector2i(center_x - radius, center_z + 1), level)
    var east_level := structure_surface_level_for_gate_pair(Vector2i(center_x + radius, center_z), Vector2i(center_x + radius, center_z + 1), level)
    for offset in [0, 1]:
        gate_cells[Vector2i(center_x + offset, center_z - radius)] = { "side": 2, "secondary": offset == 1, "axis": "x", "level": north_level }
        gate_cells[Vector2i(center_x + offset, center_z + radius)] = { "side": 0, "secondary": offset == 1, "axis": "x", "level": south_level }
        gate_cells[Vector2i(center_x - radius, center_z + offset)] = { "side": 3, "secondary": offset == 1, "axis": "z", "level": west_level }
        gate_cells[Vector2i(center_x + radius, center_z + offset)] = { "side": 1, "secondary": offset == 1, "axis": "z", "level": east_level }
    for offset in range(-radius, radius + 1):
        place_town_perimeter_cell(center_x + offset, center_z - radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x + offset, center_z + radius, level, gate_cells, "x", town_key)
        place_town_perimeter_cell(center_x - radius, center_z + offset, level, gate_cells, "z", town_key)
        place_town_perimeter_cell(center_x + radius, center_z + offset, level, gate_cells, "z", town_key)

func place_town_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary, axis: String, town_key: String) -> void:
    var cell := Vector2i(cell_x, cell_z)
    if gate_cells.has(cell):
        var gate: Dictionary = gate_cells[cell]
        var gate_level := float(gate.get("level", structure_surface_level_for_cell(cell_x, cell_z, level)))
        place_path(cell_x, cell_z, gate_level, { "generatedTier": "town", "cacheKey": "%s:town-gate-path:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z] })
        place_door(cell_x, cell_z, gate_level, int(gate.get("side", 0)), bool(gate.get("secondary", false)), "public_gate")
        return
    var fence_level := structure_surface_level_for_cell(cell_x, cell_z, level)
    place_structure_block(cell_x, cell_z, fence_level, 0, "woodBlock", {
        "generatedTier": "town",
        "accentRole": "fencePost",
        "fenceAxis": axis,
        "cacheKey": "%s:town-fence:%s:%d,%d" % [main.seed_text, town_key, cell_x, cell_z]
    })

func build_town_market(center_x: int, center_z: int, level: float, rng: RandomNumberGenerator) -> void:
    var stalls := [
        { "dx": -5, "dz": -5, "facing": PI * 0.5 },
        { "dx": 5, "dz": -5, "facing": -PI * 0.5 },
        { "dx": -5, "dz": 5, "facing": PI * 0.5 },
        { "dx": 5, "dz": 5, "facing": -PI * 0.5 }
    ]
    var count := 2 + rng.randi_range(0, 1)
    for i in range(count):
        var stall: Dictionary = stalls[i]
        place_utility(center_x + int(stall["dx"]), center_z + int(stall["dz"]), level, "traderStall", {
            "facing": float(stall["facing"]),
            "generatedTier": "town"
        })

func town_key_for(town: Dictionary) -> String:
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func town_home_door_portal_id(door_cell: Vector2i, level: float, door_side: int) -> String:
    if main == null:
        return ""
    var world_y: float = level + float(main.CELL) * 0.48
    var cell_y: int = floori(world_y / float(main.CELL)) + 1
    return "door:door-group:%d,%d,%d:%d" % [door_cell.x, cell_y, door_cell.y, door_side]

func record_town_home(town_key: String, town: Dictionary, base_x: int, base_z: int, width: int, depth: int, door_side: int, index: int) -> void:
    if town_key == "":
        return
    if not town_home_records.has(town_key):
        town_home_records[town_key] = []
    var center_cell := Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
    var home_cell := center_cell
    var porch_cell := home_cell
    var guard_cell := home_cell
    var interior_min_cell := Vector2i(base_x + 1, base_z + 1)
    var interior_max_cell := Vector2i(base_x + width - 2, base_z + depth - 2)
    var door_cell := porch_cell
    var interior_landing_cell := home_cell
    var door_entries := StructureDoorRulesScript.door_cells(width, depth, door_side)
    if not door_entries.is_empty():
        var entry: Dictionary = door_entries[0]
        door_cell = Vector2i(base_x + int(entry.get("x", 0)), base_z + int(entry.get("z", 0)))
        var interior_landing := door_cell
        var inward := Vector2i.ZERO
        porch_cell = door_cell
        if door_side == 0:
            porch_cell.y += 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y + 4)
            inward = Vector2i(0, -1)
        elif door_side == 2:
            porch_cell.y -= 1
            guard_cell = Vector2i(porch_cell.x, porch_cell.y - 4)
            inward = Vector2i(0, 1)
        elif door_side == 1:
            porch_cell.x += 1
            guard_cell = Vector2i(porch_cell.x + 4, porch_cell.y)
            inward = Vector2i(-1, 0)
        else:
            porch_cell.x -= 1
            guard_cell = Vector2i(porch_cell.x - 4, porch_cell.y)
            inward = Vector2i(1, 0)
        interior_landing = door_cell + inward
        home_cell = door_cell + inward * 3
        var lateral := Vector2i(-inward.y, inward.x)
        if lateral != Vector2i.ZERO:
            var center_delta := (center_cell.x - door_cell.x) * lateral.x + (center_cell.y - door_cell.y) * lateral.y
            var lateral_sign := 1 if center_delta >= 0 else -1
            home_cell += lateral * lateral_sign * 2
        interior_landing.x = clampi(interior_landing.x, interior_min_cell.x, interior_max_cell.x)
        interior_landing.y = clampi(interior_landing.y, interior_min_cell.y, interior_max_cell.y)
        interior_landing_cell = interior_landing
        home_cell.x = clampi(home_cell.x, interior_min_cell.x, interior_max_cell.x)
        home_cell.y = clampi(home_cell.y, interior_min_cell.y, interior_max_cell.y)
    var route_candidates := [porch_cell, door_cell, interior_landing_cell, home_cell]
    var home_route_cells: Array = []
    for route_cell_variant in route_candidates:
        if not (route_cell_variant is Vector2i):
            continue
        var route_cell: Vector2i = route_cell_variant
        if home_route_cells.is_empty() or home_route_cells[home_route_cells.size() - 1] != route_cell:
            home_route_cells.append(route_cell)
    var record := {
        "id": "%s:home:%d" % [town_key, index],
        "stableId": "%s:home:%d" % [town_key, index],
        "homeKey": index,
        "townKey": town_key,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        "townRadius": int(town.get("radius", main.TOWN_RADIUS_CELLS)),
        "level": float(town.get("level", 16.0)),
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "doorCell": door_cell,
        "doorPortalId": town_home_door_portal_id(door_cell, float(town.get("level", 16.0)), door_side),
        "interiorLandingCell": interior_landing_cell,
        "homeRouteCells": home_route_cells,
        "guardCell": guard_cell,
        "interiorMinCell": interior_min_cell,
        "interiorMaxCell": interior_max_cell,
        "buildingIndex": index
    }
    if defer_structure_ops:
        if not deferred_town_home_records.has(town_key):
            deferred_town_home_records[town_key] = []
        (deferred_town_home_records[town_key] as Array).append(record)
        return
    town_home_records[town_key].append(record)

func town_home_records_snapshot() -> Dictionary:
    return town_home_records.duplicate(true)

func ensure_town_home_records(town: Dictionary, requirements_or_minimum = {}) -> Array:
    var requirements := normalized_town_manifest_requirements(requirements_or_minimum)
    var status := town_manifest_status(town, requirements)
    if String(status.get("status", "")) != StartupReadinessResultScript.STATUS_READY:
        return []
    var town_key := town_key_for(town)
    var records_value = town_home_records.get(town_key, [])
    return (records_value as Array).duplicate(true) if records_value is Array else []

func town_manifest_status(town: Dictionary, requirements: Dictionary) -> Dictionary:
    if main == null:
        return StartupReadinessResultScript.failed("missing_structure_main", {}, [], {})
    if town.is_empty():
        return StartupReadinessResultScript.failed("missing_town", {}, [], {})
    var requirements_validation := validate_town_manifest_requirements(requirements)
    if not bool(requirements_validation.get("ok", false)):
        return StartupReadinessResultScript.failed("invalid_town_requirements", {}, [], {
            "failureReasons": requirements_validation.get("problems", [])
        })
    var town_key := town_key_for(town)
    var required_keys: Array = requirements.get("requiredHomeKeys", [])
    var records_value = town_home_records.get(town_key, [])
    var records: Array = records_value.duplicate(true) if records_value is Array else []
    var portal_ids: Array = []
    var published_keys: Array = []
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        published_keys.append(int(record.get("homeKey", record.get("buildingIndex", -1))))
        var portal_id := String(record.get("doorPortalId", ""))
        if portal_id != "":
            portal_ids.append(portal_id)
    published_keys = TownRuntimeManifestScript.sorted_unique_ints(published_keys)
    var pending_count := pending_structure_op_count_for_town(town_key)
    var manifest := TownRuntimeManifestScript.build(
        String(main.seed_text),
        town_key,
        Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))),
        1,
        required_keys,
        records,
        portal_ids,
        pending_count
    )
    var validation: Dictionary = TownRuntimeManifestScript.validate(manifest)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    var elapsed_ms := 0.0
    var started_usec := int(publish_state.get("startedUsec", 0))
    if started_usec > 0:
        elapsed_ms = maxf(0.0, float(Time.get_ticks_usec() - started_usec) / 1000.0)
    var metrics := {
        "townKey": town_key,
        "requiredKeys": required_keys.duplicate(),
        "publishedKeys": published_keys,
        "pendingOpCount": pending_count,
        "generationAttempts": int(publish_state.get("generationAttempts", 0)),
        "elapsedLoadingMs": snappedf(elapsed_ms, 0.001),
        "publishState": String(publish_state.get("status", "not_requested")),
        "failureReasons": validation.get("problems", [])
    }
    if pending_count > 0 or String(publish_state.get("status", "")) in ["queued", "building"]:
        return StartupReadinessResultScript.pending(
            "required_town_structure_operations_pending",
            manifest,
            ["town_structure_operations"],
            metrics
        )
    if bool(validation.get("ok", false)):
        return StartupReadinessResultScript.ready(manifest, metrics)
    if int(publish_state.get("generationAttempts", 0)) > 0 or String(publish_state.get("status", "")) in ["published", "failed"]:
        metrics["publishState"] = "failed"
        return StartupReadinessResultScript.failed("required_town_manifest_generation_failed", manifest, [], metrics)
    return StartupReadinessResultScript.pending("town_manifest_generation_not_requested", manifest, ["town_generation"], metrics)

func request_town_manifest_publication(town: Dictionary, requirements: Dictionary, max_ops := STREAMING_STRUCTURE_OPS_PER_FRAME, budget_ms := STREAMING_STRUCTURE_FRAME_BUDGET_MS) -> Dictionary:
    var initial := town_manifest_status(town, requirements)
    if String(initial.get("status", "")) in [StartupReadinessResultScript.STATUS_READY, StartupReadinessResultScript.STATUS_FAILED]:
        return initial
    var town_key := town_key_for(town)
    var publish_state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    if int(publish_state.get("generationAttempts", 0)) == 0 and pending_structure_op_count_for_town(town_key) == 0:
        generated_towns[Vector2i(int(town.get("regionX", 0)), int(town.get("regionZ", 0)))] = true
        enqueue_deferred_town_build(town)
    process_pending_structure_ops(maxi(1, int(max_ops)), maxf(0.1, float(budget_ms)))
    return town_manifest_status(town, requirements)

func pending_structure_op_count_for_town(town_key: String) -> int:
    if town_key == "":
        return 0
    var count := 0
    for index in range(pending_structure_op_index, pending_structure_ops.size()):
        var op_value = pending_structure_ops[index]
        if not (op_value is Dictionary):
            continue
        var op: Dictionary = op_value
        var owner_key := String(op.get("townKey", ""))
        if owner_key == "" and op.get("state", {}) is Dictionary:
            owner_key = String((op.get("state", {}) as Dictionary).get("townKey", ""))
        if owner_key == town_key:
            count += 1
    return count

func begin_town_manifest_generation_state(town_key: String, town: Dictionary) -> void:
    var current: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    town_manifest_publish_states[town_key] = {
        "status": "building",
        "generationAttempts": maxi(1, int(current.get("generationAttempts", 0))),
        "startedUsec": int(current.get("startedUsec", Time.get_ticks_usec())),
        "updatedUsec": Time.get_ticks_usec(),
        "desiredHomeCount": town_home_count(town),
        "builtHomeCount": int(current.get("builtHomeCount", 0)),
        "failureReasons": []
    }

func update_town_manifest_publish_state(town_key: String, changes: Dictionary) -> void:
    if town_key == "":
        return
    var state: Dictionary = town_manifest_publish_states.get(town_key, {}) if town_manifest_publish_states.get(town_key, {}) is Dictionary else {}
    for key in changes.keys():
        state[key] = changes[key]
    state["updatedUsec"] = Time.get_ticks_usec()
    town_manifest_publish_states[town_key] = state

func normalized_town_manifest_requirements(value) -> Dictionary:
    if value is Dictionary:
        return (value as Dictionary).duplicate(true)
    var minimum_count := maxi(0, int(value))
    var keys: Array = []
    for key in range(minimum_count):
        keys.append(key)
    return {
        "ok": true,
        "requiredHomeKeys": keys,
        "actorHomeAssignments": {},
        "problems": []
    }

func validate_town_manifest_requirements(requirements: Dictionary) -> Dictionary:
    var problems: Array[String] = []
    var required_keys_value = requirements.get("requiredHomeKeys", [])
    var required_keys := {}
    if not (required_keys_value is Array):
        problems.append("requiredHomeKeys must be an array")
    else:
        for index in range((required_keys_value as Array).size()):
            var key_value = (required_keys_value as Array)[index]
            if not (key_value is int):
                problems.append("requiredHomeKeys[%d] must be an integer" % index)
                continue
            var home_key := int(key_value)
            if home_key < 0:
                problems.append("requiredHomeKeys[%d] must be non-negative" % index)
            elif required_keys.has(home_key):
                problems.append("requiredHomeKeys contains duplicate key %d" % home_key)
            else:
                required_keys[home_key] = true
    var assignments_value = requirements.get("actorHomeAssignments", {})
    if not (assignments_value is Dictionary):
        problems.append("actorHomeAssignments must be a dictionary")
    else:
        for actor_id_value in (assignments_value as Dictionary).keys():
            var actor_id := String(actor_id_value).strip_edges()
            var assignment_value = (assignments_value as Dictionary).get(actor_id_value)
            if actor_id == "":
                problems.append("actorHomeAssignments contains an empty actor id")
            if not (assignment_value is int):
                problems.append("actorHomeAssignments[%s] must be an integer" % actor_id)
                continue
            var assigned_key := int(assignment_value)
            if assigned_key < 0 or not required_keys.has(assigned_key):
                problems.append("actorHomeAssignments[%s] references undeclared homeKey %d" % [actor_id, assigned_key])
    for problem in requirements.get("problems", []):
        problems.append(String(problem))
    if requirements.has("ok") and not bool(requirements.get("ok", false)) and problems.is_empty():
        problems.append("requirements builder reported failure")
    return {"ok": problems.is_empty(), "problems": problems}

func build_building(base_x: int, base_z: int, level: float, width: int, depth: int, wall_height: int, wall_type: String, roof_type: String, door_side: int, rng: RandomNumberGenerator, town_building: bool) -> void:
    generated_building_count += 1
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, wall_height, "town_home" if town_building else "cabin", "stone")
    var doors := StructureDoorRulesScript.door_cells(width, depth, door_side)
    for dy in range(wall_height):
        for x in range(width):
            for z in range(depth):
                var perimeter := x == 0 or z == 0 or x == width - 1 or z == depth - 1
                if not perimeter:
                    continue
                var door_entry: Dictionary = StructureDoorRulesScript.door_entry_at(doors, x, z)
                if not door_entry.is_empty():
                    if dy == 0:
                        place_door(base_x + x, base_z + z, level, door_side, bool(door_entry.get("secondary", false)))
                    if dy <= 1:
                        continue
                var block_type := wall_type
                var window_line := dy == 2 and door_entry.is_empty() and wall_height >= 4
                var window_axis_match := z % 3 == 1 if (x == 0 or x == width - 1) else x % 3 == 1
                if window_line and window_axis_match:
                    block_type = "glass"
                place_structure_block(base_x + x, base_z + z, level, dy, block_type, wall_visual_options(x, z, width, depth, dy, block_type, wall_type))
    for x in range(-1, width + 1):
        for z in range(-1, depth + 1):
            place_structure_block(base_x + x, base_z + z, level, wall_height, roof_type, roof_visual_options(x, z, width, depth, roof_type))
    place_porch(base_x, base_z, level, width, depth, door_side)
    if town_building and rng.randf() > 0.35:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "town")
    elif not town_building and rng.randf() > 0.25:
        place_loot_chest(base_x, base_z, level, width, depth, door_side, rng, "cabin")
    if town_building and rng.randf() > 0.55:
        place_utility(base_x + 1, base_z + depth - 2, level, "bed")

func wall_visual_options(x: int, z: int, width: int, depth: int, dy: int, block_type: String, wall_type: String) -> Dictionary:
    var trim_key := "trimStone" if wall_type == "stoneBlock" else "trimWood"
    if block_type == "glass":
        var axis := "x" if (x == 0 or x == width - 1) else "z"
        var side := -1 if (x == 0 or z == 0) else 1
        if axis == "z":
            side = -1 if z == 0 else 1
        return {
            "accentRole": "windowFrame",
            "windowAxis": axis,
            "windowSide": side,
            "windowTrimMaterial": trim_key
        }
    var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
    if corner and dy <= 2:
        return {
            "accentRole": "cornerTimber",
            "cornerX": -1 if x == 0 else 1,
            "cornerZ": -1 if z == 0 else 1,
            "cornerTrimMaterial": trim_key
        }
    return {}

func roof_visual_options(x: int, z: int, width: int, depth: int, roof_type: String) -> Dictionary:
    var axis := "x" if width >= depth else "z"
    var cross_value := z if axis == "x" else x
    var cross_min := -1
    var cross_max := depth if axis == "x" else width
    var center := float(cross_min + cross_max) * 0.5
    var distance_to_center := absf(float(cross_value) - center)
    var role := "ridge" if distance_to_center <= 0.52 else "slope"
    var side := -1 if float(cross_value) < center else 1
    var edge_x := 0
    var edge_z := 0
    if x == -1:
        edge_x = -1
    elif x == width:
        edge_x = 1
    if z == -1:
        edge_z = -1
    elif z == depth:
        edge_z = 1
    if edge_x != 0 or edge_z != 0:
        role = "eave" if role != "ridge" else role
    var options := {
        "roofRole": role,
        "roofAxis": axis,
        "roofSide": side,
        "roofMaterial": "roofStone" if roof_type == "stoneBlock" else "roofWood",
        "roofTrimMaterial": "trimStone" if roof_type == "stoneBlock" else "trimWood",
        "roofEdgeX": edge_x,
        "roofEdgeZ": edge_z
    }
    var chimney_x: int = clampi(width - 2, 1, width - 2)
    var chimney_z: int = clampi(2, 1, depth - 2)
    if x == chimney_x and z == chimney_z:
        options["roofAccent"] = "chimney"
    return options

func camp_fence_options(base_options: Dictionary, axis: String) -> Dictionary:
    var options := base_options.duplicate()
    options["accentRole"] = "fencePost"
    options["fenceAxis"] = axis
    options["fenceTrimMaterial"] = "trimWood"
    return options

func build_ruin(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_ruin_count += 1
    var cache_key := "%s:ruin:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "ruin", "cacheKey": cache_key }
    var wall_height := rng.randi_range(2, 5)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, maxi(2, wall_height - 1), "ruin", "stone")
    for x in range(width):
        for z in range(depth):
            var edge := x == 0 or z == 0 or x == width - 1 or z == depth - 1
            if not edge:
                continue
            var corner := (x == 0 or x == width - 1) and (z == 0 or z == depth - 1)
            if rng.randf() < (0.14 if corner else 0.42):
                continue
            var height := clampi(1 + rng.randi_range(0, wall_height), 1, wall_height)
            for dy in range(height):
                place_structure_block(base_x + x, base_z + z, level, dy, "stoneBlock", tier_options)
    place_loot_chest(base_x, base_z, level, width, depth, -1, rng, "ruin", cache_key)
    for i in range(rng.randi_range(3, 6)):
        var rubble_x := base_x + rng.randi_range(1, width - 2)
        var rubble_z := base_z + rng.randi_range(1, depth - 2)
        place_structure_block(rubble_x, rubble_z, level, 0, "stoneBlock", tier_options)

func build_camp(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_camp_count += 1
    var cache_key := "%s:camp:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "camp", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 2, "camp", "dirt")
    for x in range(width):
        for z in range(depth):
            var offset := Vector2(float(x - center_x), float(z - center_z))
            if offset.length() <= 4.2 or x == center_x or z == center_z or rng.randf() > 0.72:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    place_utility(base_x + center_x, base_z + center_z, level, "campfire", tier_options)
    place_utility(base_x + max(1, center_x - 3), base_z + max(1, center_z - 2), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "camp"),
        "generatedTier": "camp",
        "cacheKey": cache_key
    })
    var torch_cells := [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]
    for cell in torch_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "torch", tier_options)
    for x in range(1, width - 1):
        if x % 3 == 0:
            place_structure_block(base_x + x, base_z, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
            place_structure_block(base_x + x, base_z + depth - 1, level, 0, "woodBlock", camp_fence_options(tier_options, "x"))
    for z in range(1, depth - 1):
        if z % 3 == 1:
            place_structure_block(base_x, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
            place_structure_block(base_x + width - 1, base_z + z, level, 0, "woodBlock", camp_fence_options(tier_options, "z"))
    var trap_cells := [
        Vector2i(center_x - 1, -2),
        Vector2i(center_x + 1, -2),
        Vector2i(1, center_z),
        Vector2i(width - 2, center_z)
    ]
    for cell in trap_cells:
        place_utility(base_x + cell.x, base_z + cell.y, level, "spikeTrap", tier_options)

func build_mine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_mine_count += 1
    var cache_key := "%s:mine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "mine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 4, "mine", "stone")
    for z in range(depth):
        for x in range(1, width - 1):
            if x == 1 or x == width - 2 or z % 2 == 0:
                place_path(base_x + x, base_z + z, level, tier_options)
    for z in range(-5, 0):
        for lane in range(-1, 2):
            place_path(base_x + center_x + lane, base_z + z, level, tier_options)
    for torch_offset in [Vector2i(center_x - 2, -1), Vector2i(center_x + 2, -1), Vector2i(1, 2), Vector2i(width - 2, 2)]:
        place_structure_block(base_x + torch_offset.x, base_z + torch_offset.y, level, 0, "torch", tier_options)
    for z in range(2, depth):
        for x in [0, width - 1]:
            place_structure_block(base_x + x, base_z + z, level, 0, "stoneBlock", tier_options)
            if z > 4 and z < depth - 1 and rng.randf() > 0.42:
                place_structure_block(base_x + x, base_z + z, level, 1, mine_vein_type(rng), tier_options)
            elif z % 3 == 0:
                place_structure_block(base_x + x, base_z + z, level, 1, "stoneBlock", tier_options)
    for x in range(width):
        place_structure_block(base_x + x, base_z + depth - 1, level, 0, "stoneBlock", tier_options)
        if x > 1 and x < width - 2:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, mine_vein_type(rng), tier_options)
            if rng.randf() > 0.62:
                place_structure_block(base_x + x, base_z + depth - 1, level, 2, mine_vein_type(rng), tier_options)
        else:
            place_structure_block(base_x + x, base_z + depth - 1, level, 1, "stoneBlock", tier_options)
    for z in [2, 6, depth - 3]:
        for x in [2, width - 3]:
            for dy in range(3):
                place_structure_block(base_x + x, base_z + z, level, dy, "woodBlock", tier_options)
            place_structure_block(base_x + x, base_z + z + 1, level, 0, "torch", tier_options)
        for x in range(2, width - 2):
            place_structure_block(base_x + x, base_z + z, level, 3, "woodBlock", tier_options)
    place_utility(base_x + center_x, base_z + 3, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "mine"),
        "generatedTier": "mine",
        "cacheKey": cache_key
    })

func build_shrine(base_x: int, base_z: int, level: float, width: int, depth: int, rng: RandomNumberGenerator) -> void:
    generated_shrine_count += 1
    var cache_key := "%s:shrine:%d,%d" % [main.seed_text, base_x, base_z]
    var tier_options := { "generatedTier": "shrine", "cacheKey": cache_key }
    var center_x := int(width / 2)
    var center_z := int(depth / 2)
    reserve_structure_terrain_footprint(base_x, base_z, level, width, depth, 5, "shrine", "stone")
    for x in range(width):
        for z in range(depth):
            place_path(base_x + x, base_z + z, level, tier_options)
    for xz in [
        Vector2i(1, 1),
        Vector2i(width - 2, 1),
        Vector2i(1, depth - 2),
        Vector2i(width - 2, depth - 2)
    ]:
        for dy in range(5):
            place_structure_block(base_x + xz.x, base_z + xz.y, level, dy, "stoneBlock", tier_options)
    for x in range(1, width - 1):
        place_structure_block(base_x + x, base_z + 1, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + x, base_z + depth - 2, level, 5, "stoneBlock", tier_options)
    for z in range(1, depth - 1):
        place_structure_block(base_x + 1, base_z + z, level, 5, "stoneBlock", tier_options)
        place_structure_block(base_x + width - 2, base_z + z, level, 5, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 0, "stoneBlock", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 2, "glass", tier_options)
    place_structure_block(base_x + center_x, base_z + center_z, level, 3, "glass", tier_options)
    for offset in [Vector2i(0, -3), Vector2i(3, 0), Vector2i(0, 3), Vector2i(-3, 0)]:
        place_structure_block(base_x + center_x + offset.x, base_z + center_z + offset.y, level, 1, "torch", tier_options)
    place_utility(base_x + center_x, base_z + center_z + 2, level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, "shrine"),
        "generatedTier": "shrine",
        "cacheKey": cache_key
    })

func mine_vein_type(rng: RandomNumberGenerator) -> String:
    return "ironVein" if rng.randf() > 0.76 else "copperVein"

func place_loot_chest(base_x: int, base_z: int, level: float, width: int, depth: int, door_side: int, rng: RandomNumberGenerator, tier: String, cache_key: String = "") -> bool:
    if width < 4 or depth < 4:
        return false
    var cell := loot_chest_cell(width, depth, door_side, rng)
    var key := cache_key
    if key == "":
        key = "%s:%s-cache:%d,%d" % [main.seed_text, tier, base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0))]
    return place_utility(base_x + int(cell.get("x", 0)), base_z + int(cell.get("z", 0)), level, "chest", {
        "storageSlots": loot.make_loot_slots(rng, tier),
        "generatedTier": tier,
        "cacheKey": key
    }) != null

func loot_chest_cell(width: int, depth: int, door_side: int, rng: RandomNumberGenerator) -> Dictionary:
    var side_x := 1 if rng.randf() < 0.5 else width - 2
    var side_z := 1 if rng.randf() < 0.5 else depth - 2
    if door_side == 0:
        return { "x": side_x, "z": depth - 2 }
    if door_side == 1:
        return { "x": 1, "z": side_z }
    if door_side == 2:
        return { "x": side_x, "z": 1 }
    if door_side == 3:
        return { "x": width - 2, "z": side_z }
    return { "x": side_x, "z": side_z }

func flat_level_for_footprint(base_x: int, base_z: int, width: int, depth: int) -> float:
    var samples := []
    for x in range(base_x, base_x + width):
        var near_sample := terrain_surface_sample_at_cell(x, base_z)
        var far_sample := terrain_surface_sample_at_cell(x, base_z + depth - 1)
        if not bool(near_sample.get("found", false)) or not bool(far_sample.get("found", false)):
            return NAN
        samples.append(float(near_sample.get("height", 0.0)))
        samples.append(float(far_sample.get("height", 0.0)))
    for z in range(base_z, base_z + depth):
        var left_sample := terrain_surface_sample_at_cell(base_x, z)
        var right_sample := terrain_surface_sample_at_cell(base_x + width - 1, z)
        if not bool(left_sample.get("found", false)) or not bool(right_sample.get("found", false)):
            return NAN
        samples.append(float(left_sample.get("height", 0.0)))
        samples.append(float(right_sample.get("height", 0.0)))
    var min_h := 999999.0
    var max_h := -999999.0
    for h in samples:
        min_h = min(min_h, float(h))
        max_h = max(max_h, float(h))
    if max_h - min_h > main.CELL * 0.65 or max_h <= main.WATER_LEVEL + 1.2:
        return NAN
    return (min_h + max_h) * 0.5

func place_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, extra_options: Dictionary = {}) -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "block",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "dy": dy,
            "blockType": block_type,
            "options": extra_options.duplicate(true)
        })
        return
    var world_y: float = level + main.CELL * 0.48 + float(dy) * main.CELL + float(extra_options.get("worldYOffset", 0.0))
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y,
        "structureDy": dy,
        "structureLevel": level
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)

func place_path(cell_x: int, cell_z: int, level: float, extra_options: Dictionary = {}) -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "path",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "options": extra_options.duplicate(true)
        })
        return
    var cell_y: int = roundi(level / main.CELL)
    var options := {
        "generated": true,
        "world_y": level + main.CELL * 0.024
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "cobblestonePath", options)
    if block:
        generated_path_count += 1

func place_utility(cell_x: int, cell_z: int, level: float, block_type: String, extra_options: Dictionary = {}) -> StaticBody3D:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "utility",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "blockType": block_type,
            "options": extra_options.duplicate(true)
        })
        return null
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var options := {
        "generated": true,
        "world_y": world_y
    }
    for key in extra_options.keys():
        options[key] = extra_options[key]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), block_type, options)
    if block:
        generated_utility_count += 1
    return block

func place_door(cell_x: int, cell_z: int, level: float, side: int, secondary: bool, door_policy := "private_home") -> void:
    if defer_structure_ops:
        enqueue_structure_op({
            "type": "door",
            "cellX": cell_x,
            "cellZ": cell_z,
            "level": level,
            "side": side,
            "secondary": secondary,
            "doorPolicy": door_policy
        })
        return
    var world_y: float = level + main.CELL * 0.48
    var cell_y: int = floori(world_y / main.CELL) + 1
    var facing: float = StructureDoorRulesScript.door_facing(side)
    var group_x := cell_x
    var group_z := cell_z
    if secondary:
        if side == 0 or side == 2:
            group_x -= 1
        elif side == 1 or side == 3:
            group_z -= 1
    var group_id := "door-group:%d,%d,%d:%d" % [group_x, cell_y, group_z, side]
    var block = main.create_block(Vector3i(cell_x, cell_y, cell_z), "door", {
        "generated": true,
        "world_y": world_y,
        "facing": facing,
        "secondary": secondary,
        "doorSide": side,
        "doorLeafIndex": 1 if secondary else 0,
        "doorGroupId": group_id,
        "doorPortalId": "door:%s" % group_id,
        "doorPublicAccess": true,
        "doorPolicy": door_policy,
        "door": true,
        "accentRole": "doorFrame",
        "doorTrimMaterial": "trimWood"
    })
    if block:
        generated_door_count += 1

func place_porch(base_x: int, base_z: int, level: float, width: int, depth: int, side: int) -> void:
    var doors := StructureDoorRulesScript.door_cells(width, depth, side)
    for entry in doors:
        var x := base_x + int(entry["x"])
        var z := base_z + int(entry["z"])
        if side == 0:
            place_path(x, z + 1, level)
        elif side == 2:
            place_path(x, z - 1, level)
        elif side == 1:
            place_path(x + 1, z, level)
        else:
            place_path(x - 1, z, level)

func counts() -> Dictionary:
    return {
        "towns": generated_town_count,
        "buildings": generated_building_count,
        "mines": generated_mine_count,
        "ruins": generated_ruin_count,
        "shrines": generated_shrine_count,
        "camps": generated_camp_count,
        "paths": generated_path_count,
        "doors": generated_door_count,
        "utilities": generated_utility_count
    }

