extends "res://scripts/MainDiscoveryFlow.gd"

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
            var height := terrain_height_cell(x, z)
            if height < min_height or height > max_height:
                continue
            var biome := biome_at_cell(x, z)
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
    var level := terrain_height_cell(cell_x, cell_z)
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
    var level := terrain_height_cell(base_cell.x, base_cell.y)
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
        if block and block.has_meta("kind") and String(block.get_meta("kind")) == "block":
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
    var biome := biome_at_cell(cell.x, cell.y)
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
        if height_at_world(x, z) <= WATER_LEVEL + 0.35:
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
                if height_at_world(x, z) <= WATER_LEVEL + 0.35:
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

func update_chunks(force: bool = false) -> void:
    var center := world_to_chunk(player.position.x, player.position.z)
    if not force and center == last_center_chunk:
        return
    last_center_chunk = center

    var needed := {}
    for dz in range(-render_distance, render_distance + 1):
        for dx in range(-render_distance, render_distance + 1):
            var chunk_key := Vector2i(center.x + dx, center.y + dz)
            needed[chunk_key] = true
            if not chunks.has(chunk_key):
                create_chunk(chunk_key.x, chunk_key.y)

    for key in chunks.keys():
        if not needed.has(key):
            if npc_system and npc_system.has_method("notify_navigation_chunk_unloaded"):
                npc_system.notify_navigation_chunk_unloaded(key)
            chunks[key].queue_free()
            chunks.erase(key)
    if structure_system:
        var center_cell := Vector2i(world_to_cell(player.position.x), world_to_cell(player.position.z))
        structure_system.update_around(center_cell)

func create_chunk(cx: int, cz: int) -> void:
    var chunk := Node3D.new()
    chunk.name = "Chunk_%d_%d" % [cx, cz]
    chunk.position = Vector3(cx * CHUNK_SIZE * CELL, 0.0, cz * CHUNK_SIZE * CELL)
    chunk_root.add_child(chunk)

    var assets := chunk_assets(cx, cz)
    var mesh := assets.get("mesh") as Mesh
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainMesh"
    mesh_instance.mesh = mesh
    chunk.add_child(mesh_instance)

    var body := StaticBody3D.new()
    body.name = "TerrainBody"
    body.collision_layer = 2
    body.collision_mask = 0
    body.set_meta("kind", "terrain")
    body.set_meta("chunk", Vector2i(cx, cz))
    var collision := CollisionShape3D.new()
    collision.name = "TerrainCollision"
    collision.shape = assets.get("shape") as Shape3D
    body.add_child(collision)
    chunk.add_child(body)

    spawn_chunk_props(chunk, cx, cz)
    var chunk_key := Vector2i(cx, cz)
    chunks[chunk_key] = chunk
    if npc_system and npc_system.has_method("notify_navigation_chunk_loaded"):
        npc_system.notify_navigation_chunk_loaded(chunk_key)

func chunk_assets(cx: int, cz: int) -> Dictionary:
    var key := Vector2i(cx, cz)
    if chunk_asset_cache.has(key):
        chunk_asset_cache_hits += 1
        touch_chunk_asset_cache_key(key)
        return chunk_asset_cache[key]
    chunk_asset_cache_misses += 1
    var mesh := build_chunk_mesh(cx, cz)
    var shape := mesh.create_trimesh_shape()
    var assets := {
        "mesh": mesh,
        "shape": shape
    }
    chunk_asset_cache[key] = assets
    chunk_asset_cache_order.append(key)
    prune_chunk_asset_cache()
    return assets

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

func clear_chunk_asset_cache() -> void:
    chunk_asset_cache.clear()
    chunk_asset_cache_order.clear()

func chunk_asset_cache_stats() -> Dictionary:
    return {
        "entries": chunk_asset_cache.size(),
        "hits": chunk_asset_cache_hits,
        "misses": chunk_asset_cache_misses,
        "invalidations": chunk_asset_cache_invalidations
    }

func rebuild_chunk(cx: int, cz: int) -> void:
    var key := Vector2i(cx, cz)
    invalidate_chunk_asset_cache(key)
    if chunks.has(key):
        if npc_system and npc_system.has_method("notify_navigation_chunk_unloaded"):
            npc_system.notify_navigation_chunk_unloaded(key)
        chunks[key].queue_free()
        chunks.erase(key)
    create_chunk(cx, cz)

func rebuild_chunks_around_cell(cell: Vector2i) -> void:
    var center := cell_to_chunk(cell.x, cell.y)
    for dz in range(-1, 2):
        for dx in range(-1, 2):
            var key := Vector2i(center.x + dx, center.y + dz)
            if chunks.has(key):
                rebuild_chunk(key.x, key.y)
