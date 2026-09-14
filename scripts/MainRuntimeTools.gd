extends "res://scripts/MainDiscoveryFlow.gd"

const VoxelTerrainRuntimeScript := preload("res://scripts/terrain/VoxelTerrainRuntime.gd")

const STREAMING_CHUNK_CREATES_PER_FRAME := 1
const STREAMING_CHUNK_RETIREMENTS_PER_FRAME := 1
const STREAMING_CHUNK_PROP_ATTEMPTS_PER_FRAME := 1
const STREAMING_CHUNK_DETAIL_ATTEMPTS_PER_FRAME := 3
const STREAMING_CHUNK_PROP_FRAME_BUDGET_MS := 1.35
const STREAMING_COLLISION_DEFER_MIN_CHUNK_DISTANCE := 2
const STREAMING_TERRAIN_MESH_JOBS_PER_FRAME := 1
const STREAMING_TERRAIN_MESH_FRAME_BUDGET_MS := 3.25
const GAMEPLAY_WORLD_PUBLICATION_BUDGET_USEC := 6000
const STREAMING_EXTERIOR_LOD_MIN_CHUNK_DISTANCE := 0
const STREAMING_EXTERIOR_LOD_STEP_CELLS := 14
const STREAMING_SOLID_PLACEHOLDER_STEP_CELLS := 4
const STREAMING_EXTERIOR_REFRESH_STEP_CELLS := 4
const STREAMING_DETAIL_REFRESH_MAX_PLAYER_SPEED := 4.0
const STREAMING_EXTERIOR_FULL_REFRESH_FRAME_INTERVAL := 30
const STREAMING_EXTERIOR_FULL_REFRESH_MAX_CHUNK_DISTANCE := 0
const STREAMING_SOLID_PLACEHOLDER_DEPTH_CELLS := 80

var last_streaming_exterior_full_refresh_frame := -1000000
var voxel_terrain_runtime: Node3D

func setup_playtest_camp_case(cell: Vector2i) -> void:
    if inventory_system:
        inventory_system.add_item("hunterBow", 1)
        inventory_system.add_item("arrows", 18)
        inventory_system.add_item("fieldRation", 2)
    for offset in [Vector2i(-3, -3), Vector2i(-1, -3), Vector2i(1, -3), Vector2i(3, -3), Vector2i(-3, 3), Vector2i(-1, 3), Vector2i(1, 3), Vector2i(3, 3), Vector2i(-4, 0), Vector2i(4, 0)]:
        create_playtest_ground_block(cell, offset, "woodBlock", "camp")
    for offset in [Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2)]:
        create_playtest_ground_block(cell, offset, "torch", "camp")
    for offset in [Vector2i(-1, -4), Vector2i(1, -4), Vector2i(-4, -1), Vector2i(4, -1)]:
        create_playtest_ground_block(cell, offset, "spikeTrap", "camp")
    create_playtest_ground_block(cell, Vector2i(0, 0), "campfire", "camp")
    create_playtest_ground_block(cell, Vector2i(2, 0), "chest", "camp")
    spawn_playtest_enemy("camp", playtest_position(cell, Vector2i(-3, 6), 0.72), "shadow")
    spawn_playtest_enemy("camp", playtest_position(cell, Vector2i(3, 6), 0.72), "shadow")
    spawn_playtest_enemy("camp", playtest_position(cell, Vector2i(0, 8), 0.72), "seer")

func setup_playtest_combat_case(cell: Vector2i) -> void:
    if hostile_system:
        hostile_system.clear()
    if inventory_system:
        inventory_system.add_item("hunterBow", 1)
        inventory_system.add_item("arrows", 24)
        inventory_system.add_item("stoneSword", 1)
        inventory_system.add_item("fieldRation", 2)
    for offset in [Vector2i(2, -2), Vector2i(2, 0), Vector2i(2, 2), Vector2i(-2, -2), Vector2i(-2, 2)]:
        create_playtest_ground_block(cell, offset, "stoneBlock", "combat")
    for offset in [Vector2i(0, 5), Vector2i(-4, 6), Vector2i(4, 6)]:
        spawn_playtest_enemy("combat", playtest_position(cell, offset, 0.72), "shadow")
    spawn_playtest_enemy("combat", playtest_position(cell, Vector2i(0, 9), 0.72), "seer")

func spawn_playtest_enemy(case_id: String, position: Vector3, variant: String) -> Node:
    if hostile_system == null:
        return null
    var body: Node = hostile_system.spawn_enemy(position, variant)
    mark_playtest_node(body, case_id)
    var state: Dictionary = hostile_system.enemy_for_body(body)
    if not state.is_empty():
        state["aware"] = true
        state["daylightImmune"] = true
    return body

func find_biome_playtest_cell(biomes: Array, min_height: float, max_height: float, require_flat: bool) -> Vector2i:
    var best_cell := Vector2i(999999, 999999)
    var best_score := INF
    for z in range(-560, 561, 7):
        for x in range(-560, 561, 7):
            var height := surface_y_at_cell(Vector3i(x, 0, z))
            if height < min_height or height > max_height:
                continue
            var biome := surface_biome_at_cell(Vector3i(x, 0, z))
            if not biomes.has(biome):
                continue
            var variation := height_variation_cell(x, z, 2)
            if require_flat and variation > CELL * 0.72:
                continue
            var distance_score := Vector2(float(x), float(z)).length()
            var score: float = distance_score + variation * 9.0
            if min_height >= 60.0:
                score -= height * 1.9
            if biome == "town":
                score -= 1200.0
            if score < best_score:
                best_score = score
                best_cell = Vector2i(x, z)
    return best_cell

func find_standalone_structure_target(kind: String) -> Dictionary:
    if structure_system == null:
        return {}
    for rz in range(-7, 8):
        for rx in range(-7, 8):
            var roll: float = hash01("structure:%d,%d" % [rx, rz])
            if roll > STRUCTURE_SPAWN_CHANCE:
                continue
            var rng := RandomNumberGenerator.new()
            rng.seed = hash_string("%s:structure:%d,%d" % [seed_text, rx, rz])
            var base_x: int = rx * STRUCTURE_REGION_CELLS + rng.randi_range(16, STRUCTURE_REGION_CELLS - 18)
            var base_z: int = rz * STRUCTURE_REGION_CELLS + rng.randi_range(16, STRUCTURE_REGION_CELLS - 18)
            var structure_type: String = structure_system.standalone_structure_type(rng)
            if kind != "" and structure_type != kind:
                continue
            var dimensions: Vector2i = structure_system.structure_dimensions_for_type(structure_type, rng)
            var level: float = structure_system.flat_level_for_footprint(base_x, base_z, dimensions.x, dimensions.y)
            if is_nan(level):
                continue
            return {
                "cell": Vector2i(base_x + dimensions.x / 2, base_z + dimensions.y / 2),
                "label": structure_type.capitalize()
            }
    return {}

func create_playtest_ground_block(base_cell: Vector2i, offset: Vector2i, block_type: String, case_id: String, dy: int = 0) -> Node:
    var cell_x := base_cell.x + offset.x
    var cell_z := base_cell.y + offset.y
    var level := surface_y_at_cell(Vector3i(cell_x, 0, cell_z))
    return create_playtest_structure_block(cell_x, cell_z, level, dy, block_type, case_id)

func create_playtest_structure_block(cell_x: int, cell_z: int, level: float, dy: int, block_type: String, case_id: String = "collapse") -> Node:
    var world_y: float = level + CELL * 0.48 + float(dy) * CELL
    var cell_y := floori(world_y / CELL) + 1
    var cell := Vector3i(cell_x, cell_y, cell_z)
    if blocks.has(cell):
        return null
    var block := create_block(Vector3i(cell_x, cell_y, cell_z), block_type, {
        "player_placed": true,
        "world_y": world_y
    })
    if block:
        block.set_meta("playtest_case", case_id)
    return block

func create_playtest_collapse_case(base_cell: Vector2i) -> void:
    for cell_variant in blocks.keys().duplicate():
        var body := blocks[cell_variant] as Node
        if body and body.has_meta("playtest_case") and String(body.get_meta("playtest_case")) == "collapse":
            body.queue_free()
            blocks.erase(cell_variant)
    var level := surface_y_at_cell(Vector3i(base_cell.x, 0, base_cell.y))
    var supports := [
        Vector2i(-2, -2),
        Vector2i(2, -2),
        Vector2i(-2, 2),
        Vector2i(2, 2)
    ]
    for support in supports:
        for dy in range(0, 3):
            create_playtest_structure_block(base_cell.x + support.x, base_cell.y + support.y, level, dy, "woodBlock")
    for x in range(-2, 3):
        for z in range(-2, 3):
            create_playtest_structure_block(base_cell.x + x, base_cell.y + z, level, 3, "stoneBlock")
    for x in range(-2, 3):
        create_playtest_structure_block(base_cell.x + x, base_cell.y - 2, level, 4, "woodBlock")

func use_or_place() -> void:
    var hit: Dictionary = focused_interaction_hit()
    if not hit.is_empty():
        var collider: Node = hit.get("collider")
        if collider and tutorial_system and tutorial_system.is_tutorial_npc(collider):
            if tutorial_system.interact_with(collider):
                if held_item:
                    held_item.play_use("interact")
                show_tutorial_dialogue(tutorial_system.last_message)
                return
        if collider and interact_story_dialogue_node(collider):
            if held_item:
                held_item.play_use("interact")
            return
        if collider and interact_story_node(collider):
            if held_item:
                held_item.play_use("interact")
            return
        var block := interaction_block_from_collider(collider)
        if block and (String(block.get_meta("kind", "")) == "block" or (String(block.get_meta("block_type", "")) == "door" and block.has_meta("door_portal_id"))):
            var block_type := String(block.get_meta("block_type"))
            if block_type == "door":
                var door_result = request_player_door_use(block, player, "player")
                if door_result != null and String(door_result.get("status")) == "succeeded":
                    var door_open := bool(block.get_meta("open"))
                    play_feedback("doorOpen" if door_open else "doorClose", block.global_position if block is Node3D else Vector3.INF, feedback_color_for_material("door"), 2)
                    if door_open and tutorial_system and tutorial_system.has_method("on_door_opened") and bool(tutorial_system.on_door_opened(block)):
                        refresh_intro_knock_audio()
                        show_tutorial_dialogue(tutorial_system.last_message)
                    else:
                        update_hud("Opened door" if door_open else "Closed door")
                    return
            if block_type == "bed":
                if sleep_at_bed(block):
                    return
            if utility_system and utility_system.is_utility_block(block_type):
                if hud:
                    hud.set_inventory_open(false)
                if utility_system.open_block(block):
                    discover_shrine_cache(block)
                    if block_type == "chest":
                        play_feedback("chestOpen", block.global_position if block is Node3D else Vector3.INF, feedback_color_for_material("chest"), 2)
                    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
                    if tutorial_system and tutorial_system.has_method("on_utility_opened") and bool(tutorial_system.on_utility_opened(block)):
                        update_hud(tutorial_system.last_message)
                    else:
                        update_hud(utility_system.last_message)
                    return
            if is_utility_block(block_type):
                update_hud("%s ready" % ItemCatalogScript.label(block_type))
                return
    if try_use_active_consumable():
        return
    place_selected_block()

func try_use_active_consumable() -> bool:
    if survival_system == null or inventory_system == null:
        return false
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    if crafting_system and crafting_system.has_method("use_active_unlock_item") and bool(crafting_system.use_active_unlock_item()):
        if held_item:
            held_item.play_use("read")
        play_feedback("pickup", Vector3.INF, Color(0.78, 0.70, 0.46), 5)
        mark_world_dirty("crafting_book:%s" % item_id)
        update_hud(crafting_system.last_message)
        return true
    if item_id == "fishingRod":
        return fish_with_rod()
    if equipment_system and equipment_system.is_equippable(item_id):
        var equipped: bool = equipment_system.equip_active()
        if equipped:
            if held_item:
                held_item.play_use("equip")
            play_feedback("pickup", Vector3.INF, Color(0.72, 0.84, 0.95), 5)
            update_hud(equipment_system.last_message)
        return equipped
    if item_id == "" or not survival_system.can_use_item(item_id):
        return false
    var used: bool = survival_system.use_active_item(item_id)
    if used:
        if held_item:
            held_item.play_use("consume")
        play_feedback("eat", Vector3.INF, Color(0.80, 0.58, 0.36), 5)
        update_hud(survival_system.last_message)
    return used

func fish_with_rod() -> bool:
    if inventory_system == null or player == null:
        return false
    if held_item:
        held_item.play_use("cast")
    if world_elapsed < next_fishing_ready_at:
        update_hud("Fishing Rod: ready in %ds" % ceili(next_fishing_ready_at - world_elapsed))
        return true

    var spot := find_fishing_spot()
    if spot.is_empty():
        next_fishing_ready_at = world_elapsed + 1.2
        play_feedback("strike", player.global_position + Vector3(0.0, 1.0, 0.0), Color(0.30, 0.70, 0.78), 3)
        update_hud("Fishing Rod: cast near water")
        return true

    var cell := Vector2i(world_to_cell(float(spot.get("x", 0.0))), world_to_cell(float(spot.get("z", 0.0))))
    var biome := surface_biome_at_cell(Vector3i(cell.x, 0, cell.y))
    var catch_chance := 0.58
    if biome == "ocean":
        catch_chance = 0.86
    elif biome == "beach":
        catch_chance = 0.74
    elif biome == "swamp":
        catch_chance = 0.66

    var caught := fishing_rng.randf() < catch_chance
    next_fishing_ready_at = world_elapsed + (5.4 if caught else 3.2)
    if not caught:
        play_feedback("strike", Vector3(float(spot.get("x", 0.0)), WATER_LEVEL + 0.65, float(spot.get("z", 0.0))), Color(0.30, 0.70, 0.78), 4)
        update_hud("Fishing Rod: line slipped")
        return true

    var amount := 2 if fishing_rng.randf() > 0.82 else 1
    var collected: int = inventory_system.add_item("rawFish", amount)
    play_feedback("pickup", Vector3(float(spot.get("x", 0.0)), WATER_LEVEL + 0.65, float(spot.get("z", 0.0))), feedback_color_for_material("rawFish"), 8)
    if collected > 0:
        update_objectives_and_contracts()
        update_hud("Caught Raw Fish x%d" % collected)
    else:
        update_hud("Inventory full: fish slipped")
    return true

func find_fishing_spot() -> Dictionary:
    if player == null or player.camera == null:
        return {}
    var forward: Vector3 = -player.camera.global_transform.basis.z
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        forward = Vector3(0.0, 0.0, -1.0)
    forward = forward.normalized()

    for distance in [4.0, 6.0, 8.0, 10.0, 12.0]:
        var x: float = player.camera.global_position.x + forward.x * float(distance)
        var z: float = player.camera.global_position.z + forward.z * float(distance)
        if surface_y_at_position(Vector3(x, 0.0, z)) <= WATER_LEVEL + 0.35:
            return { "x": x, "z": z }

    var cell_x := world_to_cell(player.camera.global_position.x)
    var cell_z := world_to_cell(player.camera.global_position.z)
    for radius in range(1, 7):
        for dx in range(-radius, radius + 1):
            for dz in range(-radius, radius + 1):
                if abs(dx) != radius and abs(dz) != radius:
                    continue
                var x: float = float(cell_x + dx) * CELL
                var z: float = float(cell_z + dz) * CELL
                if surface_y_at_position(Vector3(x, 0.0, z)) <= WATER_LEVEL + 0.35:
                    return { "x": x, "z": z }
    return {}

func is_utility_block(block_type: String) -> bool:
    return block_type in ["workbench", "anvil", "chest", "furnace", "campfire", "bed", "traderStall"]

func request_player_door_use(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
    door = interaction_block_from_collider(door)
    if not door or not door.has_meta("block_type") or String(door.get_meta("block_type")) != "door":
        return null
    if npc_system and npc_system.has_method("request_player_door_use"):
        return npc_system.request_player_door_use(door, actor, actor_kind, metadata)
    return null

func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
    door = interaction_block_from_collider(door)
    if not door or not door.has_meta("block_type") or String(door.get_meta("block_type")) != "door":
        return null
    if npc_system and npc_system.has_method("request_door_state"):
        return npc_system.request_door_state(door, desired_open, actor, actor_kind, metadata)
    return null

func process_pending_terrain_volume_light_updates(max_columns := 2) -> int:
    if world_generation_system == null or not world_generation_system.has_method("process_pending_sky_light_columns"):
        return 0
    var monitor = runtime_perf_monitor
    var light_start: int = monitor.begin_section("terrain_volume_light_update") if monitor != null else Time.get_ticks_usec()
    var processed := int(world_generation_system.call("process_pending_sky_light_columns", max_columns))
    if monitor != null:
        var pending := int(world_generation_system.call("pending_sky_light_column_count")) if world_generation_system.has_method("pending_sky_light_column_count") else 0
        monitor.increment_counter("terrain_volume_light_columns_processed", processed)
        monitor.increment_counter("terrain_volume_light_columns_pending", pending)
        monitor.end_section("terrain_volume_light_update", light_start)
    return processed

func update_chunks(force: bool = false) -> void:
    if not ensure_voxel_terrain_authority():
        report_voxel_authority_failure_once("update_chunks")
        return
    update_voxel_authority_chunks(force)

func update_legacy_terrain_chunks_for_diagnostics(force: bool = false) -> void:
    var monitor = runtime_perf_monitor
    var center := world_to_chunk(player.position.x, player.position.z)
    process_pending_terrain_volume_light_updates()
    var expected_chunk_count := maxi(1, (render_distance * 2 + 1) * (render_distance * 2 + 1))
    if not force and center == last_center_chunk and chunks.size() >= expected_chunk_count:
        if pending_streaming_structure_work_count() > 0 and pending_chunk_loads.is_empty():
            var early_structure_count := process_streaming_structure_work()
            if early_structure_count > 0:
                return
        queue_dirty_terrain_volume_chunk_refreshes()
        queue_nearby_streaming_lod_refreshes(center)
        var mesh_applied_count := apply_completed_terrain_meshing_jobs(center)
        var mesh_job_count := process_pending_terrain_meshing_jobs(center) if mesh_applied_count <= 0 else 0
        var exposure_scan_count := process_pending_generated_volume_exposure_scans(center) if mesh_applied_count <= 0 and mesh_job_count <= 0 else 0
        var refreshed_count := process_pending_chunk_terrain_refreshes(center) if mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0 else 0
        var loaded_count := process_pending_chunk_loads(center) if mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 else 0
        var collision_count := process_pending_chunk_collision_refreshes(center) if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 else 0
        var structure_count := 0
        var spawned_count := 0
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and collision_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0:
            structure_count = process_streaming_structure_work()
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and collision_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 and structure_count <= 0:
            spawned_count = process_pending_chunk_prop_spawns()
        return
    last_center_chunk = center

    var scan_start: int = monitor.begin_section("chunk_needed_scan") if monitor != null else Time.get_ticks_usec()
    var needed := {}
    var missing_chunks: Array[Vector2i] = []
    for dz in range(-render_distance, render_distance + 1):
        for dx in range(-render_distance, render_distance + 1):
            var chunk_key := Vector2i(center.x + dx, center.y + dz)
            needed[chunk_key] = true
            if not chunks.has(chunk_key):
                missing_chunks.append(chunk_key)
    if monitor != null:
        monitor.end_section("chunk_needed_scan", scan_start)
    for chunk_key in missing_chunks:
        if force:
            create_chunk(chunk_key.x, chunk_key.y)
        else:
            queue_chunk_load(chunk_key)
    if not force:
        queue_dirty_terrain_volume_chunk_refreshes()
        queue_nearby_streaming_lod_refreshes(center)
    var loaded_count := 0
    var mesh_applied_count := 0
    var mesh_job_count := 0
    var collision_count := 0
    var refreshed_count := 0
    var exposure_scan_count := 0
    var structure_count := 0
    var spawned_count := 0
    if not force:
        var chunk_coverage_incomplete := chunks.size() < expected_chunk_count or not missing_chunks.is_empty()
        if chunk_coverage_incomplete:
            loaded_count = process_pending_chunk_loads(center)
        mesh_applied_count = apply_completed_terrain_meshing_jobs(center) if loaded_count <= 0 else 0
        mesh_job_count = process_pending_terrain_meshing_jobs(center) if loaded_count <= 0 and mesh_applied_count <= 0 else 0
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0:
            exposure_scan_count = process_pending_generated_volume_exposure_scans(center)
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0:
            refreshed_count = process_pending_chunk_terrain_refreshes(center)
        if not chunk_coverage_incomplete:
            loaded_count = process_pending_chunk_loads(center) if mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 else 0
        collision_count = process_pending_chunk_collision_refreshes(center) if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 else 0
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and collision_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0:
            structure_count = process_streaming_structure_work()
        if loaded_count <= 0 and mesh_applied_count <= 0 and mesh_job_count <= 0 and collision_count <= 0 and exposure_scan_count <= 0 and refreshed_count <= 0 and structure_count <= 0:
            spawned_count = process_pending_chunk_prop_spawns()

    var unload_start: int = monitor.begin_section("chunk_unload") if monitor != null else Time.get_ticks_usec()
    for key in chunks.keys():
        if not needed.has(key):
            if voxel_terrain_authority_active() and voxel_terrain_runtime.has_method("release_gameplay_chunk"):
                voxel_terrain_runtime.call("release_gameplay_chunk", key)
            elif npc_system and npc_system.has_method("notify_navigation_chunk_unloaded"):
                npc_system.notify_navigation_chunk_unloaded(key)
            chunks[key].queue_free()
            chunks.erase(key)
            if monitor != null:
                monitor.increment_counter("chunks_unloaded")
    prune_stale_pending_chunk_loads(needed)
    prune_stale_pending_chunk_collision_refreshes(needed)
    prune_stale_pending_chunk_terrain_refreshes(needed)
    prune_stale_pending_generated_volume_exposure_scans(needed)
    prune_stale_pending_chunk_prop_spawns(needed)
    if monitor != null:
        monitor.end_section("chunk_unload", unload_start)
    if structure_system:
        var structure_start: int = monitor.begin_section("structure_update_around") if monitor != null else Time.get_ticks_usec()
        var center_cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
        if force:
            structure_system.update_around(center_cell)
        if monitor != null:
            monitor.end_section("structure_update_around", structure_start)

func ensure_voxel_terrain_authority() -> bool:
    if voxel_terrain_runtime != null and is_instance_valid(voxel_terrain_runtime):
        if voxel_terrain_runtime.generation_context_current():
            return bool(voxel_terrain_runtime.get("authority_ready"))
        push_error("Voxel terrain seed mismatch requires the staged runtime reset contract")
        return false
    var runtime := VoxelTerrainRuntimeScript.new() as Node3D
    runtime.name = "VoxelTerrainRuntime"
    add_child(runtime)
    var result: Dictionary = runtime.call("setup", self)
    if not bool(result.get("ok", false)):
        push_error("VOX-59 terrain authority failed: %s" % String(result.get("reason", "unknown")))
        runtime.queue_free()
        return false
    voxel_terrain_runtime = runtime
    clear_chunk_asset_cache()
    return true

func report_voxel_authority_failure_once(source: String) -> void:
    if bool(get_meta("voxel_authority_failure_reported", false)):
        return
    set_meta("voxel_authority_failure_reported", true)
    push_error("VOX-59 fail-closed terrain authority unavailable at %s; legacy terrain presenters will not be activated" % source)

func voxel_terrain_authority_active() -> bool:
    return voxel_terrain_runtime != null \
        and is_instance_valid(voxel_terrain_runtime) \
        and voxel_terrain_runtime.generation_context_current() \
        and bool(voxel_terrain_runtime.get("authority_ready"))

func terrain_collision_motion_proof(from_position: Vector3, to_position: Vector3, footprint_radius := 0.42) -> Dictionary:
    if not voxel_terrain_authority_active():
        return {"passed": false, "reason": "voxel_terrain_authority_unavailable"}
    if not voxel_terrain_runtime.has_method("collision_proof_for_motion"):
        return {"passed": false, "reason": "voxel_collision_motion_api_missing"}
    return voxel_terrain_runtime.call("collision_proof_for_motion", from_position, to_position, footprint_radius)

func update_voxel_authority_chunks(force: bool) -> void:
    var monitor = runtime_perf_monitor
    var publication_frame_started_usec := Time.get_ticks_usec()
    # Ordinary traversal stays on the bounded gameplay schedule even if a HUD
    # overlay is owned by an unrelated operation.  Only explicit loading and
    # relocation lifecycles may switch publication to their loading cadence.
    var shared_gameplay_schedule := not force and not startup_loading_active \
        and not runtime_loading_active and streaming_loading_request_owner.is_empty()
    if shared_gameplay_schedule:
        gameplay_publication_lane = posmod(gameplay_publication_lane + 1, 4)
        gameplay_publication_deadline_usec = publication_frame_started_usec + GAMEPLAY_WORLD_PUBLICATION_BUDGET_USEC
    else:
        gameplay_publication_lane = -1
        gameplay_publication_deadline_usec = 0
    npc_navigation_publication_permitted = true
    var center := world_to_chunk(player.position.x, player.position.z)
    var demand_start: int = monitor.begin_section("streaming_region_demand") if monitor != null else 0
    update_streaming_region_demand()
    if monitor != null:
        monitor.end_section("streaming_region_demand", demand_start)
    var retained_start: int = monitor.begin_section("streaming_retained_chunks") if monitor != null else 0
    var needed: Dictionary = world_streaming.retained_gameplay_chunks() if streaming_active else {}
    for dz in range(-render_distance, render_distance + 1):
        for dx in range(-render_distance, render_distance + 1):
            var chunk_key := Vector2i(center.x + dx, center.y + dz)
            needed[chunk_key] = true
            if chunks.has(chunk_key):
                continue
            if force:
                create_chunk(chunk_key.x, chunk_key.y)
            else:
                queue_chunk_load(chunk_key)
    for chunk_key: Vector2i in needed:
        if not chunks.has(chunk_key): queue_chunk_load(chunk_key)
    if monitor != null:
        monitor.end_section("streaming_retained_chunks", retained_start)
    if not force:
        process_pending_chunk_loads(center)
    var unload_start: int = monitor.begin_section("streaming_chunk_retirement") if monitor != null else 0
    var retired_chunks := 0
    for key_value in chunks.keys():
        if not force and retired_chunks>=STREAMING_CHUNK_RETIREMENTS_PER_FRAME:
            break
        var key: Vector2i = key_value
        if needed.has(key):
            continue
        voxel_terrain_runtime.release_gameplay_chunk(key)
        chunks[key].queue_free()
        chunks.erase(key)
        retired_chunks += 1
    if monitor != null:
        monitor.end_section("streaming_chunk_retirement", unload_start)
    var prune_start: int = monitor.begin_section("streaming_request_prune") if monitor != null else 0
    prune_stale_pending_chunk_loads(needed)
    prune_stale_pending_chunk_prop_spawns(needed)
    queue_dirty_terrain_volume_chunk_refreshes()
    if monitor != null:
        monitor.end_section("streaming_request_prune", prune_start)
    var publication_start: int = monitor.begin_section("streaming_terrain_publication") if monitor != null else 0
    var publication_time_available := not shared_gameplay_schedule or (
        gameplay_publication_lane == 1
        and Time.get_ticks_usec() < gameplay_publication_deadline_usec
    )
    var fluid_refreshes := 0
    var fluid_assets_applied := 0
    if publication_time_available:
        fluid_refreshes = process_pending_chunk_terrain_refreshes(center)
        fluid_assets_applied = apply_completed_terrain_meshing_jobs(center)
        if fluid_refreshes <= 0 and fluid_assets_applied <= 0:
            process_pending_terrain_meshing_jobs(center)
    elif monitor != null:
        monitor.increment_counter("gameplay_publication_terrain_deferred")
    if monitor != null:
        monitor.end_section("streaming_terrain_publication", publication_start)
    var deferred_start: int = monitor.begin_section("streaming_deferred_world_work") if monitor != null else 0
    var deferred_time_available := not shared_gameplay_schedule or (
        gameplay_publication_lane == 2
        and Time.get_ticks_usec() < gameplay_publication_deadline_usec
    )
    if not force and deferred_time_available:
        if pending_streaming_structure_work_count() > 0 and pending_chunk_loads.is_empty():
            process_streaming_structure_work()
        if pending_chunk_loads.is_empty():
            process_pending_chunk_prop_spawns()
    elif not force and monitor != null:
        monitor.increment_counter("gameplay_publication_world_work_deferred")
    elif structure_system != null:
        var center_cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
        structure_system.update_around(center_cell)
    if monitor != null:
        monitor.end_section("streaming_deferred_world_work", deferred_start)
    npc_navigation_publication_permitted = not shared_gameplay_schedule or (
        gameplay_publication_lane == 3
        and Time.get_ticks_usec() + 1000 < gameplay_publication_deadline_usec
    )
    last_center_chunk = center

func process_streaming_structure_work() -> int:
    if structure_system == null:
        return 0
    if should_defer_chunk_terrain_refresh_work():
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("structure_op_queue_deferred_motion")
            runtime_perf_monitor.increment_counter("structure_op_queue_depth", pending_streaming_structure_work_count())
        return 0
    var monitor = runtime_perf_monitor
    var structure_start: int = monitor.begin_section("structure_update_around") if monitor != null else Time.get_ticks_usec()
    var center_cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
    var processed := 0
    if structure_system.has_method("update_around_budgeted"):
        processed = int(structure_system.update_around_budgeted(center_cell, true))
    else:
        structure_system.update_around(center_cell)
    if monitor != null:
        monitor.end_section("structure_update_around", structure_start)
    return processed

func pending_streaming_structure_work_count() -> int:
    if structure_system == null or not structure_system.has_method("pending_structure_op_count"):
        return 0
    return int(structure_system.pending_structure_op_count())

func queue_chunk_load(chunk_key: Vector2i) -> void:
    if chunks.has(chunk_key) or pending_chunk_loads.has(chunk_key):
        return
    pending_chunk_loads[chunk_key] = true

func process_pending_chunk_loads(center: Vector2i) -> int:
    if pending_chunk_loads.is_empty():
        return 0
    var monitor = runtime_perf_monitor
    var queue_start: int = monitor.begin_section("chunk_load_queue") if monitor != null else Time.get_ticks_usec()
    var created := 0
    while created < STREAMING_CHUNK_CREATES_PER_FRAME and not pending_chunk_loads.is_empty():
        var chunk_key := nearest_pending_chunk_load(center)
        if chunk_key == Vector2i(999999, 999999):
            break
        if chunks.has(chunk_key):
            pending_chunk_loads.erase(chunk_key)
            continue
        if voxel_terrain_runtime != null and voxel_terrain_runtime.admit_gameplay_chunk(chunk_key).status != "ready":
            break # Keep the exact request until its authoritative ground is ready.
        pending_chunk_loads.erase(chunk_key)
        create_chunk(chunk_key.x, chunk_key.y, true, should_defer_streaming_chunk_collision(chunk_key, center))
        created += 1
    if monitor != null:
        monitor.increment_counter("chunk_load_queue_depth", pending_chunk_loads.size())
        monitor.end_section("chunk_load_queue", queue_start)
    return created

func nearest_pending_chunk_load(center: Vector2i) -> Vector2i:
    var best := Vector2i(999999, 999999)
    var best_distance := 2147483647
    for key_value in pending_chunk_loads.keys():
        var key: Vector2i = key_value
        if voxel_terrain_runtime != null and voxel_terrain_runtime.admit_gameplay_chunk(key).status != "ready":
            continue
        var distance := absi(key.x - center.x) + absi(key.y - center.y)
        if distance < best_distance:
            best = key
            best_distance = distance
        elif distance == best_distance:
            if key.x < best.x or (key.x == best.x and key.y < best.y):
                best = key
    return best

func should_defer_streaming_chunk_collision(chunk_key: Vector2i, center: Vector2i) -> bool:
    var max_axis_distance := maxi(absi(chunk_key.x - center.x), absi(chunk_key.y - center.y))
    return max_axis_distance >= STREAMING_COLLISION_DEFER_MIN_CHUNK_DISTANCE

func prune_stale_pending_chunk_loads(needed: Dictionary) -> void:
    if pending_chunk_loads.is_empty():
        return
    for key in pending_chunk_loads.keys():
        if not needed.has(key):
            pending_chunk_loads.erase(key)

func queue_chunk_collision_refresh(chunk_key: Vector2i) -> void:
    if not chunks.has(chunk_key):
        return
    pending_chunk_collision_refreshes[chunk_key] = true

func process_pending_chunk_collision_refreshes(center: Vector2i) -> int:
    if pending_chunk_collision_refreshes.is_empty():
        return 0
    var monitor = runtime_perf_monitor
    var queue_start: int = monitor.begin_section("chunk_collision_refresh_queue") if monitor != null else Time.get_ticks_usec()
    var chunk_key := nearest_chunk_key_from_lookup(pending_chunk_collision_refreshes, center)
    if chunk_key != Vector2i(999999, 999999):
        pending_chunk_collision_refreshes.erase(chunk_key)
        refresh_chunk_collision_shape(chunk_key.x, chunk_key.y)
    if monitor != null:
        monitor.increment_counter("chunk_collision_refresh_queue_depth", pending_chunk_collision_refreshes.size())
        monitor.end_section("chunk_collision_refresh_queue", queue_start)
    return 1

func prune_stale_pending_chunk_collision_refreshes(needed: Dictionary) -> void:
    if pending_chunk_collision_refreshes.is_empty():
        return
    for key in pending_chunk_collision_refreshes.keys():
        if not needed.has(key):
            pending_chunk_collision_refreshes.erase(key)

func queue_chunk_terrain_refresh(chunk_key: Vector2i) -> void:
    if not chunks.has(chunk_key):
        return
    pending_chunk_terrain_refreshes[chunk_key] = true

func should_use_cached_generated_volume_exposure_only() -> bool:
    return not bool(get("visual_capture_active")) \
        and not bool(get("force_underground_volume_debug")) \
        and not bool(get("force_underground_volume_fine_focus"))

func queue_generated_volume_exposure_scan(chunk_key: Vector2i) -> void:
    pending_generated_volume_exposure_scans[chunk_key] = true
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("terrain_volume_exposure_scan_queued")

func queue_generated_volume_exposure_scan_for_region(start_x: int, start_z: int) -> void:
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    queue_generated_volume_exposure_scan(chunk_key)

func process_pending_generated_volume_exposure_scans(center: Vector2i) -> int:
    if pending_generated_volume_exposure_scans.is_empty():
        return 0
    if should_defer_chunk_terrain_refresh_work():
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("terrain_volume_exposure_scan_deferred_motion")
            runtime_perf_monitor.increment_counter("terrain_volume_exposure_scan_queue_depth", pending_generated_volume_exposure_scans.size())
        return 0
    var monitor = runtime_perf_monitor
    var queue_start: int = monitor.begin_section("terrain_volume_exposure_scan_queue") if monitor != null else Time.get_ticks_usec()
    var chunk_key := nearest_chunk_key_from_lookup(pending_generated_volume_exposure_scans, center)
    if chunk_key == Vector2i(999999, 999999):
        if monitor != null:
            monitor.end_section("terrain_volume_exposure_scan_queue", queue_start)
        return 0
    pending_generated_volume_exposure_scans.erase(chunk_key)
    var start_x := chunk_key.x * CHUNK_SIZE
    var start_z := chunk_key.y * CHUNK_SIZE
    var has_exposure := false
    if has_method("chunk_has_generated_surface_volume_exposure"):
        has_exposure = bool(call("chunk_has_generated_surface_volume_exposure", start_x, start_z))
    if has_exposure and chunks.has(chunk_key):
        invalidate_chunk_asset_cache(chunk_key)
        queue_chunk_terrain_refresh(chunk_key)
    if monitor != null:
        monitor.increment_counter("terrain_volume_exposure_scans_processed")
        if has_exposure:
            monitor.increment_counter("terrain_volume_exposure_scans_found")
        monitor.increment_counter("terrain_volume_exposure_scan_queue_depth", pending_generated_volume_exposure_scans.size())
        monitor.end_section("terrain_volume_exposure_scan_queue", queue_start)
    return 1

func prune_stale_pending_generated_volume_exposure_scans(needed: Dictionary) -> void:
    if pending_generated_volume_exposure_scans.is_empty():
        return
    for key in pending_generated_volume_exposure_scans.keys():
        if not needed.has(key):
            pending_generated_volume_exposure_scans.erase(key)

func queue_dirty_terrain_volume_chunk_refreshes() -> int:
    if world_generation_system == null or not world_generation_system.has_method("consume_terrain_volume_dirty_chunk_keys"):
        return 0
    if voxel_terrain_authority_active() and voxel_terrain_runtime.has_method("collect_volume_edit_changes"):
        voxel_terrain_runtime.call("collect_volume_edit_changes")
    var dirty_value = world_generation_system.call("consume_terrain_volume_dirty_chunk_keys", CHUNK_SIZE)
    if not (dirty_value is Array):
        return 0
    var queued := 0
    for key_value in dirty_value:
        if not (key_value is Vector2i):
            continue
        var chunk_key: Vector2i = key_value
        if not chunks.has(chunk_key):
            continue
        queue_chunk_terrain_refresh(chunk_key)
        queued += 1
    if queued > 0 and runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("terrain_volume_dirty_chunks_queued", queued)
    return queued

func process_pending_chunk_terrain_refreshes(center: Vector2i) -> int:
    if pending_chunk_terrain_refreshes.is_empty():
        return 0
    if should_defer_chunk_terrain_refresh_work():
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("chunk_terrain_refresh_deferred_motion")
            runtime_perf_monitor.increment_counter("chunk_terrain_refresh_queue_depth", pending_chunk_terrain_refreshes.size())
        return 0
    var monitor = runtime_perf_monitor
    var queue_start: int = monitor.begin_section("chunk_terrain_refresh_queue") if monitor != null else Time.get_ticks_usec()
    var chunk_key := nearest_pending_chunk_terrain_refresh(center)
    if chunk_key != Vector2i(999999, 999999):
        if should_throttle_streaming_exterior_full_refresh(chunk_key):
            if monitor != null:
                monitor.increment_counter("chunk_terrain_refresh_throttled_streaming_lod")
                monitor.increment_counter("chunk_terrain_refresh_queue_depth", pending_chunk_terrain_refreshes.size())
                monitor.end_section("chunk_terrain_refresh_queue", queue_start)
            return 0
        pending_chunk_terrain_refreshes.erase(chunk_key)
        if chunks.has(chunk_key):
            refresh_chunk_terrain_assets(chunk_key.x, chunk_key.y, true, true)
            if streaming_exterior_full_refresh_is_noncritical(chunk_key):
                last_streaming_exterior_full_refresh_frame = Engine.get_process_frames()
    if monitor != null:
        monitor.increment_counter("chunk_terrain_refresh_queue_depth", pending_chunk_terrain_refreshes.size())
        monitor.end_section("chunk_terrain_refresh_queue", queue_start)
    return 1

func should_throttle_streaming_exterior_full_refresh(chunk_key: Vector2i) -> bool:
    if bool(get("visual_capture_active")) or bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus")):
        return false
    if not streaming_exterior_full_refresh_is_noncritical(chunk_key):
        return false
    return Engine.get_process_frames() - last_streaming_exterior_full_refresh_frame < STREAMING_EXTERIOR_FULL_REFRESH_FRAME_INTERVAL

func streaming_exterior_full_refresh_is_noncritical(chunk_key: Vector2i) -> bool:
    if not chunks.has(chunk_key):
        return false
    var chunk := chunks[chunk_key] as Node3D
    if chunk == null or not is_instance_valid(chunk):
        return false
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    var mesh := mesh_instance.mesh if mesh_instance != null else null
    if mesh == null or not bool(mesh.get_meta("terrainStreamingLod", false)):
        return false
    var start_x := chunk_key.x * CHUNK_SIZE
    var start_z := chunk_key.y * CHUNK_SIZE
    if has_method("chunk_has_terrain_volume_edits") and bool(call("chunk_has_terrain_volume_edits", start_x, start_z)):
        return false
    if has_method("chunk_has_excavation_overlap") and bool(call("chunk_has_excavation_overlap", start_x, start_z)):
        return false
    if has_method("chunk_needs_generated_underground_volume_mesh") and bool(call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)):
        return false
    return true

func should_defer_chunk_terrain_refresh_work() -> bool:
    if player == null:
        return false
    if bool(player.get("automated_sprint")) or bool(player.get("is_sprinting")):
        return true
    if player is CharacterBody3D:
        var velocity: Vector3 = (player as CharacterBody3D).velocity
        var horizontal_speed := Vector2(velocity.x, velocity.z).length()
        return horizontal_speed >= STREAMING_DETAIL_REFRESH_MAX_PLAYER_SPEED
    return false

func nearest_pending_chunk_terrain_refresh(center: Vector2i) -> Vector2i:
    var best := Vector2i(999999, 999999)
    var best_distance := 2147483647
    for key_value in pending_chunk_terrain_refreshes.keys():
        var key: Vector2i = key_value
        var distance := absi(key.x - center.x) + absi(key.y - center.y)
        if distance < best_distance:
            best = key
            best_distance = distance
        elif distance == best_distance:
            if key.x < best.x or (key.x == best.x and key.y < best.y):
                best = key
    return best

func prune_stale_pending_chunk_terrain_refreshes(needed: Dictionary) -> void:
    if pending_chunk_terrain_refreshes.is_empty():
        return
    for key in pending_chunk_terrain_refreshes.keys():
        if not needed.has(key):
            pending_chunk_terrain_refreshes.erase(key)

func chunk_should_queue_terrain_meshing(cx: int, cz: int) -> bool:
    if terrain_meshing_service == null:
        return false
    if bool(get("visual_capture_active")) or bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus")):
        return false
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    if has_method("chunk_has_terrain_volume_edits") and bool(call("chunk_has_terrain_volume_edits", start_x, start_z)):
        return true
    if has_method("chunk_has_excavation_overlap") and bool(call("chunk_has_excavation_overlap", start_x, start_z)):
        return true
    return chunk_generated_volume_required_for_streaming(start_x, start_z)

func chunk_generated_volume_required_for_streaming(start_x: int, start_z: int) -> bool:
    if player != null and has_method("chunk_has_underground_focus_overlap") and bool(call("chunk_has_underground_focus_overlap", start_x, start_z)):
        return true
    if has_method("cached_generated_surface_volume_exposure"):
        var cached_value = call("cached_generated_surface_volume_exposure", start_x, start_z)
        if cached_value is Dictionary:
            var cached: Dictionary = cached_value
            if bool(cached.get("known", false)):
                return bool(cached.get("result", false))
    if should_use_cached_generated_volume_exposure_only():
        queue_generated_volume_exposure_scan_for_region(start_x, start_z)
        return false
    if has_method("chunk_needs_generated_underground_volume_mesh"):
        return bool(call("chunk_needs_generated_underground_volume_mesh", start_x, start_z))
    return false

func should_defer_generated_volume_exposure_scan() -> bool:
    if bool(get("visual_capture_active")) or bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus")):
        return false
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("backend_summary"):
        return false
    var summary: Dictionary = terrain_meshing_service.backend_summary()
    return bool(summary.get("normalQueuedWorkDeferredWithoutNative", false))

func note_deferred_generated_volume_exposure_scan() -> void:
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("terrain_volume_exposure_scan_deferred_without_native")

func request_chunk_terrain_mesh_assets(chunk_key: Vector2i, include_collision := true, priority := 0) -> bool:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("request_chunk_assets"):
        return false
    var signature := chunk_asset_signature(chunk_key)
    var result: Dictionary = terrain_meshing_service.request_chunk_assets(chunk_key.x, chunk_key.y, signature, include_collision, priority)
    var status := String(result.get("status", ""))
    if runtime_perf_monitor != null:
        if status == "queued":
            runtime_perf_monitor.increment_counter("terrain_meshing_jobs_queued")
            runtime_perf_monitor.increment_counter("terrain_fluid_jobs_queued")
        elif status == "pending":
            runtime_perf_monitor.increment_counter("terrain_meshing_jobs_already_pending")
        elif status == "ready":
            runtime_perf_monitor.increment_counter("terrain_meshing_jobs_already_ready")
    return status != ""

func process_pending_terrain_meshing_jobs(center: Vector2i) -> int:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("process_jobs"):
        return 0
    var monitor = runtime_perf_monitor
    if not terrain_meshing_runtime_work_allowed(center):
        if monitor != null:
            monitor.increment_counter("terrain_meshing_jobs_deferred_surface_idle")
            if terrain_meshing_service.has_method("pending_job_count"):
                monitor.increment_counter("terrain_meshing_job_queue_depth", int(terrain_meshing_service.pending_job_count()))
            if terrain_meshing_service.has_method("completed_job_count"):
                monitor.increment_counter("terrain_meshing_completed_queue_depth", int(terrain_meshing_service.completed_job_count()))
        return 0
    if should_defer_chunk_terrain_refresh_work():
        if monitor != null:
            monitor.increment_counter("terrain_meshing_jobs_deferred_motion")
            if terrain_meshing_service.has_method("pending_job_count"):
                monitor.increment_counter("terrain_meshing_job_queue_depth", int(terrain_meshing_service.pending_job_count()))
            if terrain_meshing_service.has_method("completed_job_count"):
                monitor.increment_counter("terrain_meshing_completed_queue_depth", int(terrain_meshing_service.completed_job_count()))
        return 0
    if should_defer_blocking_native_terrain_meshing_jobs():
        if monitor != null:
            monitor.increment_counter("terrain_meshing_jobs_deferred_blocking_native")
            if terrain_meshing_service.has_method("pending_job_count"):
                monitor.increment_counter("terrain_meshing_job_queue_depth", int(terrain_meshing_service.pending_job_count()))
            if terrain_meshing_service.has_method("completed_job_count"):
                monitor.increment_counter("terrain_meshing_completed_queue_depth", int(terrain_meshing_service.completed_job_count()))
        return 0
    var queue_start: int = monitor.begin_section("terrain_meshing_job_queue") if monitor != null else Time.get_ticks_usec()
    var result: Dictionary = terrain_meshing_service.process_jobs(
        STREAMING_TERRAIN_MESH_JOBS_PER_FRAME,
        STREAMING_TERRAIN_MESH_FRAME_BUDGET_MS,
        center
    )
    var processed := int(result.get("processed", 0))
    var work_count := processed
    if work_count <= 0 and int(result.get("payloadCells", 0)) > 0:
        work_count = 1
    if work_count <= 0 and int(result.get("preparedSections", 0)) > 0:
        work_count = 1
    if work_count <= 0 and int(result.get("dropped", 0)) > 0:
        work_count = 1
    if monitor != null:
        monitor.increment_counter("terrain_meshing_jobs_processed", processed)
        monitor.increment_counter("terrain_meshing_jobs_dropped", int(result.get("dropped", 0)))
        monitor.increment_counter("terrain_meshing_jobs_deferred_without_native", int(result.get("deferredWithoutNative", 0)))
        monitor.increment_counter("terrain_volume_sections_prepared_for_mesh", int(result.get("preparedSections", 0)))
        monitor.increment_counter("terrain_meshing_payload_cells_prepared", int(result.get("payloadCells", 0)))
        monitor.increment_counter("terrain_meshing_bounds_columns_prepared", int(result.get("boundsColumns", 0)))
        monitor.increment_counter("terrain_fluid_payload_cells_prepared", int(result.get("fluidPayloadCells", 0)))
        monitor.increment_counter("terrain_fluid_payload_sections_prepared", int(result.get("fluidPreparedSections", 0)))
        monitor.increment_counter("terrain_fluid_jobs_completed", processed)
        monitor.increment_counter("terrain_fluid_jobs_dropped", int(result.get("dropped", 0)))
        monitor.increment_counter("terrain_meshing_job_queue_depth", int(result.get("pendingJobs", 0)))
        monitor.increment_counter("terrain_meshing_completed_queue_depth", int(result.get("completedJobs", 0)))
        monitor.observe_external_duration("terrain_meshing_payload_prep", float(result.get("payloadPrepMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_payload_begin", float(result.get("payloadBeginMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_bounds_state_begin", float(result.get("boundsStateBeginMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_bounds_prep", float(result.get("boundsPrepMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_signature_check", float(result.get("signatureCheckMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_payload_select", float(result.get("payloadSelectMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_payload_signature", float(result.get("payloadSignatureMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_terrain_state_begin", float(result.get("terrainPayloadStateBeginMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_fluid_state_begin", float(result.get("fluidPayloadStateBeginMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_terrain_payload_publish", float(result.get("terrainPayloadPublishMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_fluid_payload_publish", float(result.get("fluidPayloadPublishMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_payload_handoff_prep", float(result.get("payloadHandoffPrepMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_worker_handoff", float(result.get("workerHandoffMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_retired_payload_cleanup", float(result.get("retiredPayloadCleanupMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_retired_worker_collect", float(result.get("retiredWorkerCollectMs", 0.0)))
        monitor.observe_external_duration("terrain_fluid_payload_prep", float(result.get("fluidPayloadPrepMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_collect", float(result.get("collectMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_worker_join", float(result.get("workerJoinMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_worker_start", float(result.get("workerStartMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_asset_finalize", float(result.get("assetFinalizeMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_native_mesh_build", float(result.get("terrainMeshBuildMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_native_fluid_build", float(result.get("fluidMeshBuildMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_native_collision_build", float(result.get("collisionBuildMs", 0.0)))
        monitor.observe_external_duration("terrain_meshing_job_elapsed", float(result.get("elapsedMs", 0.0)))
        var process_phase := String(result.get("processPhase", "unknown"))
        monitor.observe_external_duration("terrain_meshing_phase_%s" % process_phase, float(result.get("elapsedMs", 0.0)))
        var drop_reason := String(result.get("dropReason", ""))
        if drop_reason == "stale_worker_signature" or drop_reason == "exact_fluid_payload_stale":
            monitor.increment_counter("terrain_fluid_stale_results_rejected")
        monitor.end_section("terrain_meshing_job_queue", queue_start)
    return work_count

func terrain_meshing_runtime_work_allowed(_center: Vector2i) -> bool:
    if voxel_terrain_authority_active() and terrain_meshing_service != null and terrain_meshing_service.has_method("pending_job_count"):
        if int(terrain_meshing_service.call("pending_job_count")) > 0:
            return true
    if bool(get("visual_capture_active")) or bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus")):
        return true
    if loaded_provisional_volume_mesh_work_pending():
        return true
    if player != null and has_method("position_is_near_underground_air_focus") and bool(call("position_is_near_underground_air_focus", player.global_position)):
        return true
    if world_generation_system != null and world_generation_system.has_method("terrain_volume_edit_count"):
        if int(world_generation_system.call("terrain_volume_edit_count", false)) > 0:
            return true
    if has_method("active_volume_excavation_brushes"):
        var brushes: Array = call("active_volume_excavation_brushes")
        if not brushes.is_empty():
            return true
    return false

func loaded_provisional_volume_mesh_work_pending() -> bool:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("pending_job_count"):
        return false
    if int(terrain_meshing_service.pending_job_count()) <= 0:
        return false
    for key_value in chunks.keys():
        if not (key_value is Vector2i):
            continue
        var key: Vector2i = key_value
        var chunk := chunks.get(key) as Node3D
        if chunk == null or not is_instance_valid(chunk):
            continue
        var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
        var mesh := mesh_instance.mesh if mesh_instance != null else null
        if mesh == null or not bool(mesh.get_meta("terrainMeshingProvisional", false)):
            continue
        var start_x := key.x * CHUNK_SIZE
        var start_z := key.y * CHUNK_SIZE
        if has_method("chunk_has_terrain_volume_edits") and bool(call("chunk_has_terrain_volume_edits", start_x, start_z)):
            return true
        if has_method("chunk_has_excavation_overlap") and bool(call("chunk_has_excavation_overlap", start_x, start_z)):
            return true
        if has_method("chunk_needs_generated_underground_volume_mesh") and bool(call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)):
            return true
    return false

func should_defer_blocking_native_terrain_meshing_jobs() -> bool:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("backend_summary"):
        return false
    var summary: Dictionary = terrain_meshing_service.backend_summary()
    if not bool(summary.get("native", false)):
        return false
    if bool(summary.get("async", false)):
        return false
    if OS.get_environment("VOXEL_ALLOW_BLOCKING_NATIVE_TERRAIN_MESHING").strip_edges() == "1":
        return false
    if bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus")):
        return false
    return true

func apply_completed_terrain_meshing_jobs(center: Vector2i) -> int:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("completed_chunk_keys"):
        return 0
    var keys: Array = terrain_meshing_service.completed_chunk_keys()
    if keys.is_empty():
        return 0
    var attempts := keys.size()
    while attempts > 0:
        attempts -= 1
        var lookup := {}
        for key_value in keys:
            if key_value is Vector2i:
                lookup[key_value] = true
        if lookup.is_empty():
            return 0
        var chunk_key := nearest_chunk_key_from_lookup(lookup, center)
        if chunk_key == Vector2i(999999, 999999):
            return 0
        var assets := take_completed_terrain_mesh_assets(chunk_key)
        if assets.is_empty():
            keys = terrain_meshing_service.completed_chunk_keys()
            continue
        store_chunk_assets(chunk_key, assets)
        apply_terrain_mesh_assets_to_chunk(chunk_key, assets, true)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("terrain_meshing_completed_applied")
        observe_terrain_mesh_asset_backend(assets)
        return 1
    return 0

func take_completed_terrain_mesh_assets(chunk_key: Vector2i) -> Dictionary:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("take_completed_chunk_assets"):
        return {}
    return terrain_meshing_service.take_completed_chunk_assets(chunk_key.x, chunk_key.y, chunk_asset_signature(chunk_key))

func provisional_chunk_assets(cx: int, cz: int, defer_collision_shape := false) -> Dictionary:
    var mesh: Mesh = streaming_provisional_exterior_surface_mesh(cx, cz)
    mesh.set_meta("terrainMeshingProvisional", true)
    mesh.set_meta("terrainMeshingNative", false)
    mesh.set_meta("terrainMeshingBackend", "provisional_exterior_surface")
    var shape: Shape3D = null
    if not defer_collision_shape:
        shape = chunk_collision_shape_for_mesh(mesh)
    return {
        "mesh": mesh,
        "shape": shape,
        "fluidMesh": ArrayMesh.new(),
        "terrainSignature": chunk_asset_signature(Vector2i(cx, cz)),
        "terrainMeshingProvisional": true
    }

func streaming_provisional_exterior_surface_mesh(cx: int, cz: int) -> ArrayMesh:
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var town_context := streaming_chunk_has_town_surface_context(start_x, start_z)
    var town_edge := has_method("chunk_has_town_surface_volume_edge") and bool(call("chunk_has_town_surface_volume_edge", start_x, start_z))
    if town_context or town_edge:
        var solid_mesh := streaming_solid_volume_placeholder_mesh(cx, cz, STREAMING_SOLID_PLACEHOLDER_STEP_CELLS)
        if solid_mesh.get_surface_count() > 0:
            solid_mesh.set_meta("terrainVisualUndersideClosed", true)
            solid_mesh.set_meta("terrainProvisionalSolidPlaceholder", true)
            return solid_mesh
    var mesh := streaming_lod_exterior_mesh(cx, cz, STREAMING_EXTERIOR_REFRESH_STEP_CELLS)
    if mesh.get_surface_count() <= 0:
        mesh = streaming_lod_exterior_mesh(cx, cz, 1)
    return mesh

func streaming_chunk_has_town_surface_context(start_x: int, start_z: int) -> bool:
    if not has_method("exterior_surface_chunk_context"):
        return false
    var context_value = call("exterior_surface_chunk_context", start_x, start_z)
    if not (context_value is Dictionary):
        return false
    var towns_value = (context_value as Dictionary).get("towns", [])
    return towns_value is Array and not (towns_value as Array).is_empty()

func streaming_provisional_solid_slab_mesh(cx: int, cz: int) -> ArrayMesh:
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var mesh := ArrayMesh.new()
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var top_nw := streaming_placeholder_surface_y(start_x, start_z)
    var top_ne := streaming_placeholder_surface_y(start_x + CHUNK_SIZE, start_z)
    var top_se := streaming_placeholder_surface_y(start_x + CHUNK_SIZE, start_z + CHUNK_SIZE)
    var top_sw := streaming_placeholder_surface_y(start_x, start_z + CHUNK_SIZE)
    var bottom_y := streaming_placeholder_bottom_y(start_x, start_z, PackedVector3Array([
        Vector3(0.0, top_nw, 0.0),
        Vector3(float(CHUNK_SIZE) * CELL, top_ne, 0.0),
        Vector3(float(CHUNK_SIZE) * CELL, top_se, float(CHUNK_SIZE) * CELL),
        Vector3(0.0, top_sw, float(CHUNK_SIZE) * CELL)
    ]))
    streaming_append_placeholder_quad(
        vertices,
        normals,
        colors,
        indices,
        Vector3(0.0, top_nw, 0.0),
        Vector3(float(CHUNK_SIZE) * CELL, top_ne, 0.0),
        Vector3(float(CHUNK_SIZE) * CELL, top_se, float(CHUNK_SIZE) * CELL),
        Vector3(0.0, top_sw, float(CHUNK_SIZE) * CELL),
        Vector3.UP,
        streaming_placeholder_color(Vector3.UP)
    )
    streaming_append_placeholder_sides(vertices, normals, colors, indices, start_x, start_z, bottom_y, CHUNK_SIZE)
    streaming_append_placeholder_bottom(vertices, normals, colors, indices, bottom_y)
    if has_method("add_terrain_array_surface"):
        call("add_terrain_array_surface", mesh, {
            "vertices": vertices,
            "normals": normals,
            "colors": colors,
            "indices": indices
        }, terrain_material)
    return mesh

func streaming_lod_exterior_mesh(cx: int, cz: int, step_cells := STREAMING_EXTERIOR_LOD_STEP_CELLS) -> ArrayMesh:
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var mesh := ArrayMesh.new()
    if has_method("build_natural_exterior_arrays_lod") and has_method("add_terrain_array_surface"):
        var arrays: Dictionary = call("build_natural_exterior_arrays_lod", start_x, start_z, maxi(1, int(step_cells)))
        call("add_terrain_array_surface", mesh, arrays, terrain_material)
    elif has_method("build_natural_exterior_array_mesh"):
        var fallback_mesh = call("build_natural_exterior_array_mesh", start_x, start_z)
        if fallback_mesh is ArrayMesh:
            mesh = fallback_mesh as ArrayMesh
    return mesh

func streaming_lod_chunk_assets(cx: int, cz: int, defer_collision_shape := true, step_cells := STREAMING_SOLID_PLACEHOLDER_STEP_CELLS) -> Dictionary:
    var mesh := streaming_lod_exterior_mesh(cx, cz, step_cells)
    mesh.set_meta("terrainStreamingLod", true)
    mesh.set_meta("terrainStreamingLodStepCells", maxi(1, int(step_cells)))
    mesh.set_meta("terrainMeshingNative", false)
    mesh.set_meta("terrainMeshingBackend", "streaming_lod_exterior_surface")
    var shape: Shape3D = null
    if not defer_collision_shape:
        shape = chunk_collision_shape_for_mesh(mesh)
    return {
        "mesh": mesh,
        "shape": shape,
        "fluidMesh": ArrayMesh.new(),
        "terrainSignature": chunk_asset_signature(Vector2i(cx, cz)),
        "terrainStreamingLod": true
    }

func player_is_in_underground_volume_context() -> bool:
    if player == null:
        return false
    if has_method("position_is_near_underground_air_focus") and bool(call("position_is_near_underground_air_focus", player.global_position)):
        return true
    if has_method("chunk_bound_surface_y_at_cell"):
        var cell := Vector3i(world_to_cell(player.global_position.x), 0, world_to_cell(player.global_position.z))
        var surface_y := float(call("chunk_bound_surface_y_at_cell", cell))
        return player.global_position.y < surface_y - CELL * 0.35
    return false

func streaming_solid_volume_placeholder_mesh(cx: int, cz: int, step_cells := STREAMING_SOLID_PLACEHOLDER_STEP_CELLS) -> ArrayMesh:
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var arrays := streaming_solid_volume_placeholder_arrays(start_x, start_z, step_cells)
    var mesh := ArrayMesh.new()
    if has_method("add_terrain_array_surface"):
        call("add_terrain_array_surface", mesh, arrays, terrain_material)
    var foundation_vertices := int(arrays.get("structureFoundationPlaceholderVertices", 0))
    if foundation_vertices > 0:
        mesh.set_meta("terrainProvisionalStructureFoundation", true)
        mesh.set_meta("terrainProvisionalStructureFoundationVertices", foundation_vertices)
    return mesh

func streaming_solid_volume_placeholder_arrays(start_x: int, start_z: int, step_cells: int) -> Dictionary:
    var arrays: Dictionary = {}
    if has_method("build_natural_exterior_arrays_lod"):
        arrays = call("build_natural_exterior_arrays_lod", start_x, start_z, maxi(1, int(step_cells)))
    if arrays.is_empty():
        arrays = {
            "vertices": PackedVector3Array(),
            "normals": PackedVector3Array(),
            "colors": PackedColorArray(),
            "indices": PackedInt32Array()
        }
    var vertices: PackedVector3Array = arrays.get("vertices", PackedVector3Array())
    var normals: PackedVector3Array = arrays.get("normals", PackedVector3Array())
    var colors: PackedColorArray = arrays.get("colors", PackedColorArray())
    var indices: PackedInt32Array = arrays.get("indices", PackedInt32Array())
    if vertices.is_empty():
        arrays["vertices"] = vertices
        arrays["normals"] = normals
        arrays["colors"] = colors
        arrays["indices"] = indices
        return arrays
    streaming_append_reversed_indexed_surface(vertices, normals, colors, indices)
    var bottom_y := streaming_placeholder_bottom_y(start_x, start_z, vertices)
    streaming_append_placeholder_sides(vertices, normals, colors, indices, start_x, start_z, bottom_y, step_cells)
    streaming_append_placeholder_bottom(vertices, normals, colors, indices, bottom_y)
    var foundation_vertex_start := vertices.size()
    streaming_append_structure_foundation_placeholders(vertices, normals, colors, indices, start_x, start_z)
    arrays["structureFoundationPlaceholderVertices"] = vertices.size() - foundation_vertex_start
    arrays["vertices"] = vertices
    arrays["normals"] = normals
    arrays["colors"] = colors
    arrays["indices"] = indices
    return arrays

func streaming_placeholder_bottom_y(start_x: int, start_z: int, vertices: PackedVector3Array) -> float:
    var lowest_surface_y := INF
    for vertex in vertices:
        lowest_surface_y = minf(lowest_surface_y, vertex.y)
    if lowest_surface_y == INF:
        lowest_surface_y = 0.0
    var fallback := lowest_surface_y - CELL * float(STREAMING_SOLID_PLACEHOLDER_DEPTH_CELLS)
    if world_generation_system != null and world_generation_system.has_method("world_bottom_cell_y"):
        return minf(fallback, float(int(world_generation_system.call("world_bottom_cell_y"))) * CELL)
    return fallback

func streaming_append_reversed_indexed_surface(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array
) -> void:
    var original_vertex_count := vertices.size()
    if original_vertex_count <= 0:
        return
    var original_index_count := indices.size()
    if original_index_count <= 0:
        for i in range(original_vertex_count):
            indices.append(i)
        original_index_count = indices.size()
    var duplicate_offset := vertices.size()
    for i in range(original_vertex_count):
        vertices.append(vertices[i])
        var normal := normals[i] if i < normals.size() else Vector3.UP
        normals.append(-normal)
        colors.append(colors[i] if i < colors.size() else Color(0.12, 0.13, 0.12))
    var index_count := original_index_count - (original_index_count % 3)
    for i in range(0, index_count, 3):
        indices.append(duplicate_offset + int(indices[i]))
        indices.append(duplicate_offset + int(indices[i + 2]))
        indices.append(duplicate_offset + int(indices[i + 1]))

func streaming_append_placeholder_sides(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    start_x: int,
    start_z: int,
    bottom_y: float,
    step_cells: int
) -> void:
    var step := maxi(1, int(step_cells))
    var stops: Array[int] = []
    var local := 0
    while local < CHUNK_SIZE:
        stops.append(local)
        local += step
    if stops.is_empty() or stops[stops.size() - 1] != CHUNK_SIZE:
        stops.append(CHUNK_SIZE)
    for index in range(stops.size() - 1):
        var a: int = stops[index]
        var b: int = stops[index + 1]
        streaming_append_placeholder_wall(vertices, normals, colors, indices, Vector3(0.0, streaming_placeholder_surface_y(start_x, start_z + a), float(a) * CELL), Vector3(0.0, streaming_placeholder_surface_y(start_x, start_z + b), float(b) * CELL), Vector3(0.0, bottom_y, float(b) * CELL), Vector3(0.0, bottom_y, float(a) * CELL), Vector3.LEFT)
        streaming_append_placeholder_wall(vertices, normals, colors, indices, Vector3(float(CHUNK_SIZE) * CELL, streaming_placeholder_surface_y(start_x + CHUNK_SIZE, start_z + b), float(b) * CELL), Vector3(float(CHUNK_SIZE) * CELL, streaming_placeholder_surface_y(start_x + CHUNK_SIZE, start_z + a), float(a) * CELL), Vector3(float(CHUNK_SIZE) * CELL, bottom_y, float(a) * CELL), Vector3(float(CHUNK_SIZE) * CELL, bottom_y, float(b) * CELL), Vector3.RIGHT)
        streaming_append_placeholder_wall(vertices, normals, colors, indices, Vector3(float(b) * CELL, streaming_placeholder_surface_y(start_x + b, start_z), 0.0), Vector3(float(a) * CELL, streaming_placeholder_surface_y(start_x + a, start_z), 0.0), Vector3(float(a) * CELL, bottom_y, 0.0), Vector3(float(b) * CELL, bottom_y, 0.0), Vector3.BACK)
        streaming_append_placeholder_wall(vertices, normals, colors, indices, Vector3(float(a) * CELL, streaming_placeholder_surface_y(start_x + a, start_z + CHUNK_SIZE), float(CHUNK_SIZE) * CELL), Vector3(float(b) * CELL, streaming_placeholder_surface_y(start_x + b, start_z + CHUNK_SIZE), float(CHUNK_SIZE) * CELL), Vector3(float(b) * CELL, bottom_y, float(CHUNK_SIZE) * CELL), Vector3(float(a) * CELL, bottom_y, float(CHUNK_SIZE) * CELL), Vector3.FORWARD)

func streaming_placeholder_surface_y(cell_x: int, cell_z: int) -> float:
    if has_method("chunk_bound_surface_y_at_cell"):
        return float(call("chunk_bound_surface_y_at_cell", Vector3i(cell_x, 0, cell_z)))
    if world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.call("surface_y_for_cell", Vector3i(cell_x, 0, cell_z)))
    return 0.0

func streaming_append_placeholder_wall(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    d: Vector3,
    normal: Vector3
) -> void:
    var color := streaming_placeholder_color(normal)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, b, c, d, normal, color)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, d, c, b, -normal, color)

func streaming_append_placeholder_bottom(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    bottom_y: float
) -> void:
    var a := Vector3(0.0, bottom_y, 0.0)
    var b := Vector3(float(CHUNK_SIZE) * CELL, bottom_y, 0.0)
    var c := Vector3(float(CHUNK_SIZE) * CELL, bottom_y, float(CHUNK_SIZE) * CELL)
    var d := Vector3(0.0, bottom_y, float(CHUNK_SIZE) * CELL)
    var color := streaming_placeholder_color(Vector3.DOWN)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, b, c, d, Vector3.DOWN, color)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, d, c, b, Vector3.UP, color)

func streaming_append_structure_foundation_placeholders(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    start_x: int,
    start_z: int
) -> void:
    if structure_system == null or not structure_system.has_method("structure_terrain_footprints_for_chunk"):
        return
    var chunk_key := Vector2i(floori(float(start_x) / float(CHUNK_SIZE)), floori(float(start_z) / float(CHUNK_SIZE)))
    var footprints_value = structure_system.call("structure_terrain_footprints_for_chunk", chunk_key, CHUNK_SIZE)
    if not (footprints_value is Array):
        return
    for footprint_value in footprints_value:
        if footprint_value is Dictionary:
            streaming_append_structure_foundation_placeholder(vertices, normals, colors, indices, start_x, start_z, footprint_value)

func streaming_append_structure_foundation_placeholder(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    start_x: int,
    start_z: int,
    footprint: Dictionary
) -> void:
    var min_value = footprint.get("minCell", null)
    var max_value = footprint.get("maxCell", null)
    if not (min_value is Vector3i) or not (max_value is Vector3i):
        return
    var min_cell: Vector3i = min_value
    var max_cell: Vector3i = max_value
    var chunk_end_x := start_x + CHUNK_SIZE
    var chunk_end_z := start_z + CHUNK_SIZE
    var x0_cell := clampi(min_cell.x, start_x, chunk_end_x)
    var x1_cell := clampi(max_cell.x + 1, start_x, chunk_end_x)
    var z0_cell := clampi(min_cell.z, start_z, chunk_end_z)
    var z1_cell := clampi(max_cell.z + 1, start_z, chunk_end_z)
    if x1_cell <= x0_cell or z1_cell <= z0_cell:
        return
    var level := float(footprint.get("level", float(max_cell.y) * CELL))
    var top_y := level - CELL * 0.015
    var bottom_y := float(min_cell.y) * CELL
    if top_y <= bottom_y:
        return
    var x0 := float(x0_cell - start_x) * CELL
    var x1 := float(x1_cell - start_x) * CELL
    var z0 := float(z0_cell - start_z) * CELL
    var z1 := float(z1_cell - start_z) * CELL
    var material_id := String(footprint.get("material", "stone"))
    streaming_append_structure_placeholder_wall(vertices, normals, colors, indices, Vector3(x0, top_y, z0), Vector3(x1, top_y, z0), Vector3(x1, bottom_y, z0), Vector3(x0, bottom_y, z0), Vector3.BACK, material_id)
    streaming_append_structure_placeholder_wall(vertices, normals, colors, indices, Vector3(x1, top_y, z0), Vector3(x1, top_y, z1), Vector3(x1, bottom_y, z1), Vector3(x1, bottom_y, z0), Vector3.RIGHT, material_id)
    streaming_append_structure_placeholder_wall(vertices, normals, colors, indices, Vector3(x1, top_y, z1), Vector3(x0, top_y, z1), Vector3(x0, bottom_y, z1), Vector3(x1, bottom_y, z1), Vector3.FORWARD, material_id)
    streaming_append_structure_placeholder_wall(vertices, normals, colors, indices, Vector3(x0, top_y, z1), Vector3(x0, top_y, z0), Vector3(x0, bottom_y, z0), Vector3(x0, bottom_y, z1), Vector3.LEFT, material_id)
    var top_color := streaming_structure_placeholder_color(material_id, Vector3.UP)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, Vector3(x0, top_y, z1), Vector3(x1, top_y, z1), Vector3(x1, top_y, z0), Vector3(x0, top_y, z0), Vector3.UP, top_color)

func streaming_append_structure_placeholder_wall(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    d: Vector3,
    normal: Vector3,
    material_id: String
) -> void:
    var color := streaming_structure_placeholder_color(material_id, normal)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, b, c, d, normal, color)
    streaming_append_placeholder_quad(vertices, normals, colors, indices, a, d, c, b, -normal, color)

func streaming_structure_placeholder_color(material_id: String, normal: Vector3) -> Color:
    var shade := 0.95
    if normal.y < -0.35:
        shade = 0.62
    elif normal.y > 0.35:
        shade = 0.98
    elif absf(normal.x) > 0.5:
        shade = 0.74
    else:
        shade = 0.80
    if has_method("volume_material_surface_color"):
        return call("volume_material_surface_color", material_id, "town", normal, shade, false)
    if material_id == "dirt":
        return Color(0.36, 0.25, 0.16) * shade
    if material_id == "sand":
        return Color(0.62, 0.57, 0.42) * shade
    return Color(0.34, 0.35, 0.31) * shade

func streaming_append_placeholder_quad(
    vertices: PackedVector3Array,
    normals: PackedVector3Array,
    colors: PackedColorArray,
    indices: PackedInt32Array,
    a: Vector3,
    b: Vector3,
    c: Vector3,
    d: Vector3,
    normal: Vector3,
    color: Color
) -> void:
    var offset := vertices.size()
    vertices.append(a)
    vertices.append(b)
    vertices.append(c)
    vertices.append(d)
    for i in range(4):
        normals.append(normal)
        colors.append(color)
    indices.append(offset)
    indices.append(offset + 1)
    indices.append(offset + 2)
    indices.append(offset)
    indices.append(offset + 2)
    indices.append(offset + 3)

func streaming_placeholder_color(normal: Vector3) -> Color:
    if has_method("volume_material_surface_color"):
        return call("volume_material_surface_color", "dirt", "underground", normal, 0.96, true)
    if normal.y < -0.35:
        return Color(0.045, 0.047, 0.045)
    if normal.y > 0.35:
        return Color(0.120, 0.125, 0.112)
    return Color(0.100, 0.080, 0.060)

func apply_terrain_mesh_assets_to_chunk(chunk_key: Vector2i, assets: Dictionary, notify_navigation := true) -> bool:
    if not chunks.has(chunk_key):
        return false
    var chunk := chunks[chunk_key] as Node3D
    if chunk == null or not is_instance_valid(chunk):
        chunks.erase(chunk_key)
        return false
    if bool(chunk.get_meta("terrain_geometry_owned_by_chunk", true)) == false:
        apply_chunk_fluid_mesh(chunk, assets.get("fluidMesh") as Mesh, chunk_key)
        return true
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
    var collision := body.get_node_or_null("TerrainCollision") as CollisionShape3D if body != null else null
    var mesh := assets.get("mesh") as Mesh
    if mesh_instance != null and mesh != null:
        mesh_instance.mesh = mesh
    if collision != null:
        if assets.get("shape") is Shape3D:
            collision.shape = assets.get("shape") as Shape3D
        elif mesh != null:
            queue_chunk_collision_refresh(chunk_key)
    apply_chunk_fluid_mesh(chunk, assets.get("fluidMesh") as Mesh, chunk_key)
    if notify_navigation and npc_system and npc_system.has_method("notify_navigation_chunk_loaded"):
        var monitor = runtime_perf_monitor
        var nav_start: int = monitor.begin_section("chunk_nav_loaded_notify") if monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_chunk_loaded(chunk_key)
        if monitor != null:
            monitor.end_section("chunk_nav_loaded_notify", nav_start)
    return true

func valid_node3d_from_variant(value) -> Node3D:
    if value == null or not is_instance_valid(value):
        return null
    return value as Node3D

func queue_chunk_prop_spawn(chunk_key: Vector2i, chunk: Node3D) -> void:
    if chunk == null or not is_instance_valid(chunk):
        return
    pending_chunk_prop_spawns[chunk_key] = begin_chunk_prop_spawn_state(chunk, chunk_key.x, chunk_key.y)

func process_pending_chunk_prop_spawns() -> int:
    if pending_chunk_prop_spawns.is_empty():
        return 0
    var monitor = runtime_perf_monitor
    var queue_start: int = monitor.begin_section("chunk_prop_spawn_queue") if monitor != null else Time.get_ticks_usec()
    var processed := 0
    for key in pending_chunk_prop_spawns.keys():
        var state_value = pending_chunk_prop_spawns[key]
        if not (state_value is Dictionary):
            pending_chunk_prop_spawns.erase(key)
            continue
        var state: Dictionary = state_value
        var chunk := valid_node3d_from_variant(state.get("chunk"))
        if chunk == null or not is_instance_valid(chunk) or not chunk.is_inside_tree():
            pending_chunk_prop_spawns.erase(key)
            continue
        var props_start: int = monitor.begin_section("chunk_spawn_props") if monitor != null else Time.get_ticks_usec()
        var complete := process_chunk_prop_spawn_state(
            state,
            STREAMING_CHUNK_PROP_ATTEMPTS_PER_FRAME,
            STREAMING_CHUNK_DETAIL_ATTEMPTS_PER_FRAME,
            STREAMING_CHUNK_PROP_FRAME_BUDGET_MS,
            props_start
        )
        if monitor != null:
            monitor.end_section("chunk_spawn_props", props_start)
        if complete:
            pending_chunk_prop_spawns.erase(key)
            if monitor != null:
                monitor.increment_counter("chunk_prop_spawns_completed")
        else:
            pending_chunk_prop_spawns.erase(key)
            pending_chunk_prop_spawns[key] = state
        processed += 1
        if monitor != null:
            monitor.increment_counter("chunk_prop_spawn_slices")
        break
    if monitor != null:
        monitor.increment_counter("chunk_prop_spawn_queue_depth", pending_chunk_prop_spawns.size())
        monitor.end_section("chunk_prop_spawn_queue", queue_start)
    return processed

func prune_stale_pending_chunk_prop_spawns(needed: Dictionary) -> void:
    if pending_chunk_prop_spawns.is_empty():
        return
    for key in pending_chunk_prop_spawns.keys():
        if not needed.has(key):
            pending_chunk_prop_spawns.erase(key)

func create_chunk(cx: int, cz: int, defer_props := false, defer_streaming_collision := false) -> void:
    if not ensure_voxel_terrain_authority():
        report_voxel_authority_failure_once("create_chunk")
        return
    create_voxel_authority_chunk_container(cx, cz, defer_props)

func create_legacy_terrain_chunk_for_diagnostics(cx: int, cz: int, defer_props := false, defer_streaming_collision := false) -> void:
    var monitor = runtime_perf_monitor
    var create_start: int = monitor.begin_section("chunk_create") if monitor != null else Time.get_ticks_usec()
    var chunk_key := Vector2i(cx, cz)
    var chunk := Node3D.new()
    chunk.name = "Chunk_%d_%d" % [cx, cz]
    chunk.position = Vector3(cx * CHUNK_SIZE * CELL, 0.0, cz * CHUNK_SIZE * CELL)
    chunk_root.add_child(chunk)

    var assets_start: int = monitor.begin_section("chunk_assets") if monitor != null else Time.get_ticks_usec()
    var has_valid_cached_assets := chunk_asset_cache.has(chunk_key) and chunk_asset_cache_entry_valid(chunk_key, chunk_asset_cache[chunk_key])
    var defer_collision_shape := defer_props and defer_streaming_collision and not has_valid_cached_assets
    var queue_terrain_meshing := defer_props and not has_valid_cached_assets and chunk_should_queue_terrain_meshing(cx, cz)
    var center_chunk := world_to_chunk(player.position.x, player.position.z) if player != null else chunk_key
    var stream_distance = maxi(absi(chunk_key.x - center_chunk.x), absi(chunk_key.y - center_chunk.y))
    var force_volume_geometry := bool(get("visual_capture_active")) or bool(get("force_underground_volume_debug")) or bool(get("force_underground_volume_fine_focus"))
    var use_streaming_lod := defer_props and not has_valid_cached_assets and not queue_terrain_meshing and not force_volume_geometry and stream_distance >= STREAMING_EXTERIOR_LOD_MIN_CHUNK_DISTANCE
    var assets := {}
    if queue_terrain_meshing:
        assets = provisional_chunk_assets(cx, cz, defer_collision_shape)
        request_chunk_terrain_mesh_assets(chunk_key, true, 0)
        if monitor != null:
            monitor.increment_counter("terrain_meshing_provisional_chunks")
            if defer_collision_shape:
                monitor.increment_counter("terrain_meshing_provisional_collision_deferred")
    elif use_streaming_lod:
        assets = streaming_lod_chunk_assets(cx, cz, defer_collision_shape)
        if monitor != null:
            monitor.increment_counter("streaming_lod_chunks")
    elif defer_collision_shape:
        assets = {
            "mesh": chunk_mesh_asset(cx, cz),
            "shape": null,
            "fluidMesh": chunk_fluid_mesh_asset(cx, cz)
        }
        if monitor != null:
            monitor.increment_counter("chunk_collision_shape_deferred")
    else:
        assets = chunk_assets(cx, cz)
    if monitor != null:
        monitor.end_section("chunk_assets", assets_start)
    var mesh := assets.get("mesh") as Mesh
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainMesh"
    mesh_instance.mesh = mesh
    mesh_instance.set_meta("geometry_source", "volume_sample_extraction")
    mesh_instance.set_meta("chunk", Vector2i(cx, cz))
    chunk.add_child(mesh_instance)
    apply_chunk_fluid_mesh(chunk, assets.get("fluidMesh") as Mesh, chunk_key)

    var body := StaticBody3D.new()
    body.name = "TerrainBody"
    body.collision_layer = 2
    body.collision_mask = 0
    body.set_meta("kind", "terrain")
    body.set_meta("chunk", Vector2i(cx, cz))
    body.set_meta("geometry_source", "volume_sample_extraction")
    body.set_meta("collision_source", "terrain_mesh_create_trimesh_shape")
    var collision := CollisionShape3D.new()
    collision.name = "TerrainCollision"
    if assets.get("shape") is Shape3D:
        collision.shape = assets.get("shape") as Shape3D
    collision.set_meta("geometry_source", "volume_sample_extraction")
    collision.set_meta("collision_source", "terrain_mesh_create_trimesh_shape")
    body.add_child(collision)
    chunk.add_child(body)

    chunks[chunk_key] = chunk
    if bool(assets.get("terrainStreamingLod", false)) and should_queue_streaming_lod_full_refresh(chunk_key):
        queue_chunk_terrain_refresh(chunk_key)
    var temporary_terrain_asset := bool(assets.get("terrainStreamingLod", false)) or bool(assets.get("terrainMeshingProvisional", false))
    if defer_collision_shape and not temporary_terrain_asset:
        queue_chunk_collision_refresh(chunk_key)
    if defer_props:
        queue_chunk_prop_spawn(chunk_key, chunk)
    else:
        var props_start: int = monitor.begin_section("chunk_spawn_props") if monitor != null else Time.get_ticks_usec()
        spawn_chunk_props(chunk, cx, cz)
        if monitor != null:
            monitor.end_section("chunk_spawn_props", props_start)
    if npc_system and npc_system.has_method("notify_navigation_chunk_loaded"):
        var nav_start: int = monitor.begin_section("chunk_nav_loaded_notify") if monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_chunk_loaded(chunk_key)
        if monitor != null:
            monitor.end_section("chunk_nav_loaded_notify", nav_start)
    if monitor != null:
        monitor.increment_counter("chunks_created")
        monitor.end_section("chunk_create", create_start)

func create_voxel_authority_chunk_container(cx: int, cz: int, defer_props := false) -> void:
    var chunk_key := Vector2i(cx, cz)
    if chunks.has(chunk_key):
        return
    if voxel_terrain_runtime.admit_gameplay_chunk(chunk_key).status != "ready":
        queue_chunk_load(chunk_key)
        return
    var monitor = runtime_perf_monitor
    var create_start: int = monitor.begin_section("chunk_create") if monitor != null else Time.get_ticks_usec()
    var chunk := Node3D.new()
    chunk.name = "Chunk_%d_%d" % [cx, cz]
    chunk.position = Vector3(cx * CHUNK_SIZE * CELL, 0.0, cz * CHUNK_SIZE * CELL)
    chunk.set_meta("terrain_authority", "VoxelTerrain")
    chunk.set_meta("terrain_geometry_owned_by_chunk", false)
    chunk_root.add_child(chunk)
    chunks[chunk_key] = chunk
    if voxel_terrain_runtime != null and voxel_terrain_runtime.has_method("request_gameplay_chunk_publication"):
        voxel_terrain_runtime.call("request_gameplay_chunk_publication", chunk_key)
    request_voxel_authority_chunk_fluid(chunk_key, 0)
    if defer_props:
        queue_chunk_prop_spawn(chunk_key, chunk)
    else:
        var props_start: int = monitor.begin_section("chunk_spawn_props") if monitor != null else Time.get_ticks_usec()
        spawn_chunk_props(chunk, cx, cz)
        if monitor != null:
            monitor.end_section("chunk_spawn_props", props_start)
    if monitor != null:
        monitor.increment_counter("voxel_authority_chunk_containers_created")
        monitor.increment_counter("chunks_created")
        monitor.end_section("chunk_create", create_start)

func request_voxel_authority_chunk_fluid(chunk_key: Vector2i, priority := 0) -> bool:
    if terrain_meshing_service == null or not terrain_meshing_service.has_method("request_chunk_assets"):
        return false
    var signature := chunk_asset_signature(chunk_key)
    var result: Dictionary = terrain_meshing_service.call(
        "request_chunk_assets",
        chunk_key.x,
        chunk_key.y,
        signature,
        false,
        priority,
        true
    )
    return String(result.get("status", "")) in ["queued", "pending", "ready"]

func chunk_assets(cx: int, cz: int) -> Dictionary:
    var monitor = runtime_perf_monitor
    var key := Vector2i(cx, cz)
    if chunk_asset_cache.has(key):
        var cached_assets: Dictionary = chunk_asset_cache[key]
        if chunk_asset_cache_entry_valid(key, cached_assets):
            chunk_asset_cache_hits += 1
            if monitor != null:
                monitor.increment_counter("chunk_asset_cache_hits")
            touch_chunk_asset_cache_key(key)
            if not cached_assets.has("fluidMesh"):
                cached_assets["fluidMesh"] = chunk_fluid_mesh_asset(cx, cz)
                cached_assets["terrainSignature"] = chunk_asset_signature(key)
                chunk_asset_cache[key] = cached_assets
            return cached_assets
        var completed_assets := take_completed_terrain_mesh_assets(key)
        if not completed_assets.is_empty():
            store_chunk_assets(key, completed_assets)
            if monitor != null:
                monitor.increment_counter("terrain_meshing_completed_cache_replacement")
            observe_terrain_mesh_asset_backend(completed_assets)
            return completed_assets
        invalidate_chunk_asset_cache(key)
        if monitor != null:
            monitor.increment_counter("chunk_asset_cache_stale")
    var completed_uncached_assets := take_completed_terrain_mesh_assets(key)
    if not completed_uncached_assets.is_empty():
        store_chunk_assets(key, completed_uncached_assets)
        if monitor != null:
            monitor.increment_counter("terrain_meshing_completed_cache_fill")
        observe_terrain_mesh_asset_backend(completed_uncached_assets)
        return completed_uncached_assets
    chunk_asset_cache_misses += 1
    if monitor != null:
        monitor.increment_counter("chunk_asset_cache_misses")
    var mesh := chunk_mesh_asset(cx, cz)
    var shape := chunk_collision_shape_for_mesh(mesh)
    var fluid_mesh := chunk_fluid_mesh_asset(cx, cz)
    var assets := {
        "mesh": mesh,
        "shape": shape,
        "fluidMesh": fluid_mesh
    }
    store_chunk_assets(key, assets)
    return assets

func chunk_mesh_asset(cx: int, cz: int) -> Mesh:
    var monitor = runtime_perf_monitor
    var mesh_start: int = monitor.begin_section("chunk_build_mesh") if monitor != null else Time.get_ticks_usec()
    var mesh: Mesh = null
    if terrain_meshing_service != null and terrain_meshing_service.has_method("build_chunk_mesh"):
        mesh = terrain_meshing_service.build_chunk_mesh(cx, cz)
    else:
        mesh = build_chunk_mesh(cx, cz)
    if monitor != null:
        if mesh != null and bool(mesh.get_meta("terrainMeshingNative", false)):
            monitor.increment_counter("terrain_meshing_native_chunks")
        elif mesh != null and bool(mesh.get_meta("terrainMeshingDeferredWithoutNative", false)):
            monitor.increment_counter("terrain_meshing_direct_build_deferred_without_native")
        else:
            monitor.increment_counter("terrain_meshing_gdscript_fallback_chunks")
        monitor.end_section("chunk_build_mesh", mesh_start)
    return mesh

func chunk_fluid_mesh_asset(cx: int, cz: int) -> Mesh:
    var monitor = runtime_perf_monitor
    var mesh_start: int = monitor.begin_section("chunk_build_fluid_mesh") if monitor != null else Time.get_ticks_usec()
    var mesh: Mesh = null
    if terrain_meshing_service != null and terrain_meshing_service.has_method("build_chunk_fluid_mesh"):
        mesh = terrain_meshing_service.build_chunk_fluid_mesh(cx, cz)
    else:
        mesh = build_chunk_fluid_mesh(cx, cz)
    if monitor != null:
        if mesh != null and bool(mesh.get_meta("terrainFluidDeferredWithoutNative", false)):
            monitor.increment_counter("terrain_fluid_direct_build_deferred_without_native")
        monitor.end_section("chunk_build_fluid_mesh", mesh_start)
    return mesh

func apply_chunk_fluid_mesh(chunk: Node3D, fluid_mesh: Mesh, key: Vector2i) -> void:
    var existing := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
    var has_surface := fluid_mesh != null and fluid_mesh.get_surface_count() > 0
    if not has_surface:
        if existing != null:
            existing.queue_free()
        return
    var fluid_instance := existing
    if fluid_instance == null:
        fluid_instance = MeshInstance3D.new()
        fluid_instance.name = "TerrainFluidMesh"
        fluid_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        fluid_instance.set_meta("geometry_source", "volume_fluid_state")
        chunk.add_child(fluid_instance)
    fluid_instance.mesh = fluid_mesh
    fluid_instance.set_meta("chunk", key)
    fluid_instance.set_meta("collision_source", "none")

func clear_stale_chunk_fluid_mesh(chunk: Node3D, key: Vector2i) -> bool:
    if chunk == null:
        return false
    var existing := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
    var existing_mesh: Mesh = existing.mesh if existing != null else null
    if existing_mesh == null:
        return false
    var current_signature := chunk_asset_signature(key)
    if String(existing_mesh.get_meta("terrainSignature", "")) == current_signature:
        return false
    apply_chunk_fluid_mesh(chunk, ArrayMesh.new(), key)
    if runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("terrain_fluid_stale_mesh_cleared")
    return true

func chunk_collision_shape_for_mesh(mesh: Mesh) -> Shape3D:
    var monitor = runtime_perf_monitor
    var shape_start: int = monitor.begin_section("chunk_create_trimesh_shape") if monitor != null else Time.get_ticks_usec()
    var shape: Shape3D = null
    if terrain_meshing_service != null and terrain_meshing_service.has_method("collision_shape_for_mesh"):
        var service_shape = terrain_meshing_service.collision_shape_for_mesh(mesh)
        if service_shape is Shape3D:
            shape = service_shape as Shape3D
    elif mesh != null:
        shape = mesh.create_trimesh_shape()
    if shape is ConcavePolygonShape3D:
        (shape as ConcavePolygonShape3D).backface_collision = true
    if monitor != null:
        monitor.end_section("chunk_create_trimesh_shape", shape_start)
    return shape

func store_chunk_assets(key: Vector2i, assets: Dictionary) -> void:
    assets["terrainSignature"] = chunk_asset_signature(key)
    if not chunk_asset_cache.has(key):
        chunk_asset_cache_order.append(key)
    chunk_asset_cache[key] = assets
    touch_chunk_asset_cache_key(key)
    prune_chunk_asset_cache()

func observe_terrain_mesh_asset_backend(assets: Dictionary) -> void:
    if runtime_perf_monitor == null:
        return
    var mesh = assets.get("mesh") as Mesh
    var is_native_mesh := bool(assets.get("terrainMeshingNative", false)) or (mesh != null and bool(mesh.get_meta("terrainMeshingNative", false)))
    var deferred_without_native := mesh != null and bool(mesh.get_meta("terrainMeshingDeferredWithoutNative", false))
    if is_native_mesh:
        runtime_perf_monitor.increment_counter("terrain_meshing_native_chunks")
        if mesh != null and bool(mesh.get_meta("terrainMeshingQueued", false)):
            runtime_perf_monitor.increment_counter("terrain_meshing_completed_native_chunks")
    elif deferred_without_native:
        runtime_perf_monitor.increment_counter("terrain_meshing_direct_build_deferred_without_native")
    else:
        runtime_perf_monitor.increment_counter("terrain_meshing_gdscript_fallback_chunks")
    var fluid_mesh = assets.get("fluidMesh") as Mesh
    if fluid_mesh != null:
        runtime_perf_monitor.increment_counter("terrain_fluid_exact_cells", int(fluid_mesh.get_meta("nativeFluidCellCount", 0)))
        runtime_perf_monitor.increment_counter("terrain_fluid_water_faces", int(fluid_mesh.get_meta("chunk_water_faces", 0)))
        runtime_perf_monitor.increment_counter("terrain_fluid_lava_faces", int(fluid_mesh.get_meta("chunk_lava_faces", 0)))
        if bool(fluid_mesh.get_meta("forbiddenCoarseFluidPayload", false)):
            runtime_perf_monitor.increment_counter("terrain_fluid_forbidden_coarse_payload_attempts")

func touch_chunk_asset_cache_key(key: Vector2i) -> void:
    var index := chunk_asset_cache_order.find(key)
    if index >= 0:
        chunk_asset_cache_order.remove_at(index)
    chunk_asset_cache_order.append(key)

func prune_chunk_asset_cache() -> void:
    while chunk_asset_cache_order.size() > CHUNK_ASSET_CACHE_LIMIT:
        var key: Vector2i = chunk_asset_cache_order.pop_front()
        if chunk_asset_cache.has(key):
            chunk_asset_cache.erase(key)

func invalidate_chunk_asset_cache(key: Vector2i) -> void:
    if chunk_asset_cache.has(key):
        chunk_asset_cache.erase(key)
        chunk_asset_cache_invalidations += 1
    var index := chunk_asset_cache_order.find(key)
    if index >= 0:
        chunk_asset_cache_order.remove_at(index)
    if terrain_meshing_service != null and terrain_meshing_service.has_method("invalidate_chunk"):
        terrain_meshing_service.invalidate_chunk(key.x, key.y)

func clear_chunk_asset_cache() -> void:
    chunk_asset_cache.clear()
    chunk_asset_cache_order.clear()
    if terrain_meshing_service != null and terrain_meshing_service.has_method("clear_jobs"):
        terrain_meshing_service.clear_jobs(false)

func _exit_tree() -> void:
    if is_instance_valid(npc_system):
        var autonomy = npc_system.get("autonomy_system")
        var navigation = autonomy.get("navmesh_world") if is_instance_valid(autonomy) else null
        if navigation != null: navigation.finish_publication_for_owner_exit()
    if terrain_meshing_service != null and terrain_meshing_service.has_method("clear_jobs"):
        terrain_meshing_service.clear_jobs(true)

func chunk_asset_cache_stats() -> Dictionary:
    return {
        "entries": chunk_asset_cache.size(),
        "hits": chunk_asset_cache_hits,
        "misses": chunk_asset_cache_misses,
        "invalidations": chunk_asset_cache_invalidations
    }

func chunk_asset_cache_entry_valid(key: Vector2i, assets: Dictionary) -> bool:
    if not assets.has("terrainSignature"):
        return false
    return String(assets.get("terrainSignature", "")) == chunk_asset_signature(key)

func chunk_asset_signature(key: Vector2i) -> String:
    var chunk_revision := 0
    var fluid_revision := 0
    if world_generation_system != null:
        if world_generation_system.has_method("terrain_volume_chunk_revision"):
            chunk_revision = int(world_generation_system.call("terrain_volume_chunk_revision", key, CHUNK_SIZE))
        if world_generation_system.has_method("terrain_fluid_chunk_revision_with_halo"):
            fluid_revision = int(world_generation_system.call("terrain_fluid_chunk_revision_with_halo", key, CHUNK_SIZE))
    var backend_id := "none"
    var backend_native := false
    if terrain_meshing_service != null and terrain_meshing_service.has_method("backend_summary"):
        var backend_summary: Dictionary = terrain_meshing_service.backend_summary()
        backend_id = String(backend_summary.get("id", "unknown"))
        backend_native = bool(backend_summary.get("native", false))
    var volume_required := false
    var mesh_step := 0
    var lod_radius := 0
    var start_x := key.x * CHUNK_SIZE
    var start_z := key.y * CHUNK_SIZE
    if has_method("chunk_has_terrain_volume_edits") and bool(call("chunk_has_terrain_volume_edits", start_x, start_z)):
        volume_required = true
    elif has_method("chunk_has_excavation_overlap") and bool(call("chunk_has_excavation_overlap", start_x, start_z)):
        volume_required = true
    else:
        volume_required = chunk_generated_volume_required_for_streaming(start_x, start_z)
    if volume_required and has_method("underground_volume_mesh_step_for_chunk"):
        mesh_step = int(call("underground_volume_mesh_step_for_chunk", start_x, start_z))
    if volume_required and has_method("underground_volume_focus_radius_cells"):
        lod_radius = int(call("underground_volume_focus_radius_cells"))
    var focus_key := "none"
    if player != null and has_method("position_is_near_underground_air_focus") and has_method("chunk_has_underground_focus_overlap"):
        var focus_active := bool(call("position_is_near_underground_air_focus", player.global_position))
        var focus_overlap := bool(call("chunk_has_underground_focus_overlap", start_x, start_z)) if focus_active else false
        if focus_overlap:
            focus_key = "active"
    return "seed=%s|chunk=%d,%d|chunkRev=%d|fluidRev=%d|backend=%s|native=%s|volume=%s|step=%d|radius=%d|focus=%s" % [
        seed_text,
        key.x,
        key.y,
        chunk_revision,
        fluid_revision,
        backend_id,
        str(backend_native),
        str(volume_required),
        mesh_step,
        lod_radius,
        focus_key
    ]

func refresh_chunk_terrain_assets(cx: int, cz: int, notify_navigation := true, defer_collision_shape := false) -> bool:
    var key := Vector2i(cx, cz)
    if not chunks.has(key):
        return false
    var chunk := chunks[key] as Node3D
    if chunk == null or not is_instance_valid(chunk):
        chunks.erase(key)
        return false
    if bool(chunk.get_meta("terrain_geometry_owned_by_chunk", true)) == false:
        invalidate_chunk_asset_cache(key)
        clear_stale_chunk_fluid_mesh(chunk, key)
        return request_voxel_authority_chunk_fluid(key, 10)
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
    var collision := body.get_node_or_null("TerrainCollision") as CollisionShape3D if body != null else null
    if mesh_instance == null or body == null or collision == null:
        return false
    invalidate_chunk_asset_cache(key)
    clear_stale_chunk_fluid_mesh(chunk, key)
    var start_x := cx * CHUNK_SIZE
    var start_z := cz * CHUNK_SIZE
    var has_volume_edits := false
    if has_method("chunk_has_terrain_volume_edits"):
        has_volume_edits = bool(call("chunk_has_terrain_volume_edits", start_x, start_z))
    var generated_volume_required := false
    if has_method("chunk_needs_generated_underground_volume_mesh"):
        generated_volume_required = bool(call("chunk_needs_generated_underground_volume_mesh", start_x, start_z))
    var has_excavation := false
    if has_method("chunk_has_excavation_overlap"):
        has_excavation = bool(call("chunk_has_excavation_overlap", start_x, start_z))
    var volume_mesh_required := has_volume_edits or generated_volume_required or has_excavation
    if chunk_should_queue_terrain_meshing(cx, cz):
        var include_collision := volume_mesh_required and not defer_collision_shape
        request_chunk_terrain_mesh_assets(key, include_collision, 10)
        if runtime_perf_monitor != null:
            runtime_perf_monitor.increment_counter("terrain_meshing_refresh_deferred")
        return true
    if defer_collision_shape and not volume_mesh_required:
        mesh_instance.mesh = chunk_mesh_asset(cx, cz)
        apply_chunk_fluid_mesh(chunk, chunk_fluid_mesh_asset(cx, cz), key)
        queue_chunk_collision_refresh(key)
        return true
    var assets := chunk_assets(cx, cz)
    mesh_instance.mesh = assets.get("mesh") as Mesh
    collision.shape = assets.get("shape") as Shape3D
    apply_chunk_fluid_mesh(chunk, assets.get("fluidMesh") as Mesh, key)
    if notify_navigation and npc_system and npc_system.has_method("notify_navigation_chunk_loaded"):
        var monitor = runtime_perf_monitor
        var nav_start: int = monitor.begin_section("chunk_nav_loaded_notify") if monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_chunk_loaded(key)
        if monitor != null:
            monitor.end_section("chunk_nav_loaded_notify", nav_start)
    return true

func queue_nearby_streaming_lod_refreshes(center: Vector2i) -> void:
    if chunks.is_empty():
        return
    for key_value in chunks.keys():
        var chunk_key: Vector2i = key_value
        if pending_chunk_terrain_refreshes.has(chunk_key):
            continue
        if not should_queue_streaming_lod_full_refresh(chunk_key, center):
            continue
        var chunk := chunks.get(chunk_key) as Node3D
        if chunk == null or not is_instance_valid(chunk):
            continue
        var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
        var mesh := mesh_instance.mesh if mesh_instance != null else null
        if mesh != null and bool(mesh.get_meta("terrainStreamingLod", false)):
            queue_chunk_terrain_refresh(chunk_key)

func should_queue_streaming_lod_full_refresh(chunk_key: Vector2i, center := Vector2i(999999, 999999)) -> bool:
    if player == null:
        return true
    var reference_center := center
    if reference_center == Vector2i(999999, 999999):
        reference_center = world_to_chunk(player.position.x, player.position.z)
    var max_axis_distance := maxi(absi(chunk_key.x - reference_center.x), absi(chunk_key.y - reference_center.y))
    return max_axis_distance <= STREAMING_EXTERIOR_FULL_REFRESH_MAX_CHUNK_DISTANCE

func refresh_chunk_collision_shape(cx: int, cz: int) -> bool:
    var key := Vector2i(cx, cz)
    if not chunks.has(key):
        return false
    var chunk := chunks[key] as Node3D
    if chunk == null or not is_instance_valid(chunk):
        chunks.erase(key)
        return false
    var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
    var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
    var collision := body.get_node_or_null("TerrainCollision") as CollisionShape3D if body != null else null
    if mesh_instance == null or mesh_instance.mesh == null or collision == null:
        return false
    var mesh := mesh_instance.mesh
    if bool(mesh.get_meta("terrainStreamingLod", false)) or bool(mesh.get_meta("terrainMeshingProvisional", false)):
        queue_chunk_terrain_refresh(key)
        return true
    var shape := chunk_collision_shape_for_mesh(mesh)
    collision.shape = shape
    var fluid_instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
    var fluid_mesh: Mesh = fluid_instance.mesh if fluid_instance != null else ArrayMesh.new()
    if fluid_instance == null and runtime_perf_monitor != null:
        runtime_perf_monitor.increment_counter("chunk_fluid_mesh_deferred_during_collision_refresh")
    store_chunk_assets(key, {
        "mesh": mesh,
        "shape": shape,
        "fluidMesh": fluid_mesh,
        "terrainFluidDeferred": fluid_instance == null
    })
    if npc_system and npc_system.has_method("notify_navigation_chunk_loaded"):
        var monitor = runtime_perf_monitor
        var nav_start: int = monitor.begin_section("chunk_nav_loaded_notify") if monitor != null else Time.get_ticks_usec()
        npc_system.notify_navigation_chunk_loaded(key)
        if monitor != null:
            monitor.end_section("chunk_nav_loaded_notify", nav_start)
    return true

func rebuild_chunk(cx: int, cz: int, defer_props := false) -> void:
    if voxel_terrain_authority_active():
        if voxel_terrain_runtime.has_method("collect_volume_edit_changes"):
            voxel_terrain_runtime.call("collect_volume_edit_changes")
        return
    var key := Vector2i(cx, cz)
    if defer_props and refresh_chunk_terrain_assets(cx, cz, true, is_processing()):
        return
    invalidate_chunk_asset_cache(key)
    if chunks.has(key):
        if npc_system and npc_system.has_method("notify_navigation_chunk_unloaded"):
            npc_system.notify_navigation_chunk_unloaded(key)
        chunks[key].queue_free()
        chunks.erase(key)
    create_chunk(cx, cz, defer_props)

func rebuild_chunks_for_cells(cells: Array, neighbor_radius := 0, defer_props := false) -> void:
    if voxel_terrain_authority_active():
        if voxel_terrain_runtime.has_method("collect_volume_edit_changes"):
            voxel_terrain_runtime.call("collect_volume_edit_changes")
        return
    var chunk_keys := {}
    for value in cells:
        if not (value is Vector2i):
            continue
        var cell: Vector2i = value
        var center := cell_to_chunk(cell.x, cell.y)
        var radius := maxi(0, int(neighbor_radius))
        for dz in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                var key := Vector2i(center.x + dx, center.y + dz)
                if chunks.has(key):
                    chunk_keys[key] = true
    if defer_props:
        for key_value in chunk_keys.keys():
            var queued_key: Vector2i = key_value
            queue_chunk_terrain_refresh(queued_key)
        return
    for key_value in chunk_keys.keys():
        var key: Vector2i = key_value
        rebuild_chunk(key.x, key.y, defer_props)

func nearest_chunk_key_from_lookup(chunk_keys: Dictionary, center: Vector2i) -> Vector2i:
    var best := Vector2i(999999, 999999)
    var best_distance := 2147483647
    for key_value in chunk_keys.keys():
        var key: Vector2i = key_value
        var distance := absi(key.x - center.x) + absi(key.y - center.y)
        if distance < best_distance:
            best = key
            best_distance = distance
        elif distance == best_distance:
            if key.x < best.x or (key.x == best.x and key.y < best.y):
                best = key
    return best

func rebuild_chunks_around_cell(cell: Vector2i) -> void:
    rebuild_chunks_for_cells([cell], 1, true)
