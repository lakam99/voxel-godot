extends "res://scripts/MainChunkTerrain.gd"

func destroy_target() -> void:
    if try_fire_ranged():
        return
    var hit: Dictionary = player.view_ray(monumental_tree_melee_ray_range())
    if hit.is_empty():
        reset_break_progress()
        if not begin_player_melee_motion():
            play_melee_miss()
        return
    if not hit_within_action_reach(hit):
        reset_break_progress()
        play_melee_miss()
        update_hud("Too far away")
        return
    var collider: Node = hit["collider"]
    if not collider or not collider.has_meta("kind"):
        reset_break_progress()
        play_melee_miss()
        return
    var kind := String(collider.get_meta("kind"))
    if kind == "story_worldmark":
        reset_break_progress()
        if held_item:
            held_item.play_use("strike")
        var resolved_worldmark := damage_story_worldmark(melee_damage_for_active_item(), "melee")
        var hit_position: Vector3 = collider.global_position + Vector3(0.0, 1.0, 0.0) if collider is Node3D else Vector3.INF
        play_feedback("defeat" if resolved_worldmark else "enemyHit", hit_position, Color(0.48, 0.68, 0.92), 16 if resolved_worldmark else 8)
        var message := "Worldmark hit"
        if worldmark_encounter_controller != null:
            message = String(worldmark_encounter_controller.get("last_message"))
        update_hud(message)
        return
    if kind == "hostile":
        reset_break_progress()
        if not begin_player_melee_motion():
            play_melee_miss()
        return
    var target: Dictionary = break_target_for_hit(hit, collider, kind)
    if target.is_empty():
        reset_break_progress()
        play_melee_miss()
        return

    var target_id := String(target.get("id", ""))
    var material_id := String(target.get("material", ""))
    var requirement_message := unmet_tool_requirement_message(material_id)
    if requirement_message != "":
        reset_break_progress()
        if held_item:
            held_item.play_use("strike")
        play_feedback(strike_effect_for_material(material_id), hit["position"], feedback_color_for_material(material_id).lerp(Color(1.0, 0.30, 0.12), 0.46), 7)
        update_hud(requirement_message)
        return
    if target_id != break_target_id:
        break_target_id = target_id
        break_progress = 0.0
    var hardness: int = max(1, ItemCatalogScript.material_hardness(material_id))
    break_progress += tool_power_for_material(material_id)
    break_idle_time = 0.0
    if held_item:
        held_item.play_use("strike")
    play_feedback(strike_effect_for_material(material_id), hit["position"], feedback_color_for_material(material_id), 3)
    var ratio: float = clamp(break_progress / float(hardness), 0.08, 1.0)
    show_break_overlay(hit["position"], hit["normal"], ratio)

    if break_progress < hardness:
        show_action_message("Breaking %s %.0f%%" % [ItemCatalogScript.material_label(material_id), ratio * 100.0])
        return

    reset_break_progress()
    hit["breakTargetId"] = target_id
    complete_destroy_target(hit, collider, kind, material_id)

func play_melee_miss() -> void:
    if held_item:
        held_item.play_use("strike")

func begin_player_melee_motion() -> bool:
    if player_motion_combat == null or not player_motion_combat.has_method("begin_arc_motion"):
        return false
    var started: bool = player_motion_combat.begin_arc_motion(melee_damage_for_active_item())
    if started and held_item:
        held_item.play_use("strike")
    return started

func _on_player_motion_hostile_contact_resolved(_body, variant: String, defeated: bool, position: Vector3, _resolution: Dictionary) -> void:
    if defeated:
        award_hostile_xp(variant)
        play_feedback("defeat", position, Color(0.62, 0.24, 0.82), 16)
    else:
        play_feedback("enemyHit", position, Color(0.82, 0.22, 0.20), 8)
    if hostile_system:
        update_hud(hostile_system.last_message)

func strike_effect_for_material(material_id: String) -> String:
    var id := material_id.to_lower()
    if id.find("wood") >= 0 or id in ["tree", "logs", "door", "chest", "workbench", "bed", "torch", "campfire", "traderstall"]:
        return "woodChop"
    return "strike"

func break_target_for_hit(hit: Dictionary, collider: Node, kind: String) -> Dictionary:
    if (kind == "terrain" or kind == "subsurface") and subsurface_system != null and subsurface_system.has_method("break_target_for_hit"):
        return subsurface_system.break_target_for_hit(hit, collider, kind)
    if kind == "terrain":
        var sample_pos: Vector3 = hit.get("position", Vector3.ZERO) - hit.get("normal", Vector3.UP) * (CELL * 0.35)
        var cell := Vector3i(world_to_cell(sample_pos.x), world_to_cell(sample_pos.y), world_to_cell(sample_pos.z))
        return {
            "id": "terrain:%d,%d,%d" % [cell.x, cell.y, cell.z],
            "material": world_material_at_cell(cell)
        }
    if kind == "block":
        var block_cell: Vector3i = collider.get_meta("cell")
        var block_type: String = collider.get_meta("block_type")
        return {
            "id": "block:%d,%d,%d" % [block_cell.x, block_cell.y, block_cell.z],
            "material": block_type
        }
    if kind == "prop":
        var prop_id: String = collider.get_meta("prop_id")
        var drop: String = collider.get_meta("drop")
        return {
            "id": "prop:%s" % prop_id,
            "material": String(collider.get_meta("material", "tree" if drop == "logs" else "rock"))
        }
    return {}

func complete_destroy_target(hit: Dictionary, collider: Node, kind: String, material_id: String) -> void:
    var monitor = runtime_perf_monitor
    var destroy_start: int = monitor.begin_section("destroy_target_complete") if monitor != null else Time.get_ticks_usec()
    var feedback_ms := 0.0
    var tree_fall_visual_ms := 0.0
    var block_mutation_ms := 0.0
    var block_reward_ms := 0.0
    var block_message_ms := 0.0
    var feedback_start: int = monitor.begin_section("destroy_target_feedback") if monitor != null else Time.get_ticks_usec()
    play_feedback("break", hit["position"], feedback_color_for_material(material_id), 12)
    feedback_ms = float(Time.get_ticks_usec() - feedback_start) / 1000.0
    if monitor != null:
        monitor.end_section("destroy_target_feedback", feedback_start)
    if (kind == "terrain" or kind == "subsurface") and subsurface_system != null and subsurface_system.has_method("begin_excavation_from_hit"):
        var excavate_start: int = monitor.begin_section("destroy_target_subsurface_excavate") if monitor != null else Time.get_ticks_usec()
        var queued := queue_terrain_excavation_followup(hit, collider, material_id, String(hit.get("breakTargetId", "")))
        if monitor != null:
            monitor.end_section("destroy_target_subsurface_excavate", excavate_start)
        show_action_message("Digging %s" % ItemCatalogScript.material_label(material_id) if queued else "Dig already in progress")
    elif kind == "terrain":
        update_hud("Cannot dig terrain until the volume sampler is ready")
    elif kind == "block":
        var block_mutation_start: int = monitor.begin_section("destroy_target_block_mutation") if monitor != null else Time.get_ticks_usec()
        var block_cell: Vector3i = collider.get_meta("cell")
        var block_type: String = collider.get_meta("block_type")
        if npc_system and npc_system.has_method("notify_navigation_block_removed"):
            npc_system.notify_navigation_block_removed(block_cell, block_type, collider)
        queue_block_removed_followup(block_cell, block_type, collider, "block_removed")
        blocks.erase(block_cell)
        invalidate_navigation_marker_cache()
        mark_world_dirty("block_removed")
        collider.queue_free()
        block_mutation_ms = float(Time.get_ticks_usec() - block_mutation_start) / 1000.0
        if monitor != null:
            monitor.end_section("destroy_target_block_mutation", block_mutation_start)
        var block_reward_start: int = monitor.begin_section("destroy_target_block_reward") if monitor != null else Time.get_ticks_usec()
        var recovered_item := ItemCatalogScript.material_drop(material_id)
        var block_reward_items := []
        if recovered_item != "":
            block_reward_items.append({ "item": recovered_item, "count": 1 })
        queue_break_reward(block_reward_items, material_id, material_id)
        block_reward_ms = float(Time.get_ticks_usec() - block_reward_start) / 1000.0
        if monitor != null:
            monitor.end_section("destroy_target_block_reward", block_reward_start)
        if is_structural_block_type(block_type):
            queue_structural_integrity_check(block_cell)
        var block_message := "Recovered %s" % ItemCatalogScript.label(block_type)
        var block_message_started_usec := Time.get_ticks_usec()
        show_action_message(block_message)
        block_message_ms = float(Time.get_ticks_usec() - block_message_started_usec) / 1000.0
    elif kind == "prop":
        var prop_id: String = collider.get_meta("prop_id")
        var drop: String = collider.get_meta("drop")
        var drop_count := int(collider.get_meta("drop_count", 1))
        if npc_system and npc_system.has_method("request_shared_prop_harvest"):
            var action_position: Vector3 = (collider as Node3D).global_position if collider is Node3D else hit.get("position", player.global_position if player != null else Vector3.ZERO)
            var harvest: Dictionary = npc_system.request_shared_prop_harvest(collider, player, "player", {
                "actorPosition": action_position,
                "request_id": "player:%s:%d" % [prop_id, Engine.get_process_frames()]
            })
            if not bool(harvest.get("ok", false)):
                update_hud("Unavailable: %s" % String(harvest.get("reason", "busy")))
                return
            var metrics: Dictionary = harvest.get("metrics", {})
            drop = String(metrics.get("drop", drop))
            drop_count = int(metrics.get("amount", drop_count))
        removed_props[prop_id] = true
        removed_props_revision += 1
        mark_world_dirty("prop_removed")
        if npc_system and npc_system.has_method("notify_navigation_prop_removed"):
            npc_system.notify_navigation_prop_removed(prop_id, collider)
        if material_id == "wildlife":
            wildlife_nodes.erase(collider)
        if drop == "logs":
            var tree_fall_started_usec := Time.get_ticks_usec()
            spawn_falling_tree_visual(collider as Node3D)
            tree_fall_visual_ms = float(Time.get_ticks_usec() - tree_fall_started_usec) / 1000.0
            queue_break_reward([{ "item": "logs", "count": max(1, drop_count) }], "tree", material_id)
            show_action_message("Tree dropped logs")
        elif drop == "stones":
            queue_break_reward([{ "item": "stones", "count": max(1, drop_count) }], material_id, material_id)
            show_action_message("Rock dropped stones")
        else:
            var prop_reward_items := [{ "item": drop, "count": max(1, drop_count) }]
            if collider.has_meta("extra_drop"):
                var extra_drop := String(collider.get_meta("extra_drop", ""))
                var extra_count := int(collider.get_meta("extra_drop_count", 0))
                if extra_drop != "" and extra_count > 0:
                    prop_reward_items.append({ "item": extra_drop, "count": extra_count })
            queue_break_reward(prop_reward_items, material_id, material_id)
            show_action_message("%s dropped" % ItemCatalogScript.label(drop))
        collider.queue_free()
    if monitor != null:
        monitor.end_section("destroy_target_complete", destroy_start)
    last_destroy_target_metrics = {
        "kind": kind,
        "materialId": material_id,
        "totalMs": float(Time.get_ticks_usec() - destroy_start) / 1000.0,
        "feedbackMs": feedback_ms,
        "treeFallVisualMs": tree_fall_visual_ms,
        "blockMutationMs": block_mutation_ms,
        "blockRewardMs": block_reward_ms,
        "blockMessageMs": block_message_ms
    }

func complete_terrain_excavation_followup(excavation: Dictionary, fallback_material: String) -> void:
    mark_world_dirty("subsurface_excavated")
    var affected_cells: Array = excavation.get("affectedCells", [])
    if npc_system and npc_system.has_method("notify_navigation_terrain_cells_edited"):
        npc_system.notify_navigation_terrain_cells_edited(affected_cells)
    else:
        for affected_cell in affected_cells:
            if affected_cell is Vector2i and npc_system and npc_system.has_method("notify_navigation_terrain_edited"):
                var old_height := surface_y_at_cell(Vector3i(affected_cell.x, 0, affected_cell.y))
                npc_system.notify_navigation_terrain_edited(affected_cell, old_height, old_height)
    var removed_material := String(excavation.get("primaryMaterial", fallback_material))
    if removed_material == "" or removed_material == "air":
        removed_material = fallback_material
    var terrain_drop := ItemCatalogScript.material_drop(removed_material)
    var terrain_reward_items := []
    if terrain_drop != "":
        terrain_reward_items.append({ "item": terrain_drop, "count": 1 })
    queue_break_reward(terrain_reward_items, removed_material, removed_material)
    show_action_message("Dug %s" % ItemCatalogScript.material_label(removed_material))

func complete_break_objectives(material_id: String) -> void:
    if objective_system == null:
        return
    if material_id == "copperOre" or material_id == "copperVein":
        objective_system.complete("mineCopper")
        objective_system.complete("mine")
    elif material_id == "ironOre" or material_id == "ironVein":
        objective_system.complete("mineIron")
        objective_system.complete("mine")

func is_station_near(station_id: String) -> bool:
    if not player:
        return false
    for block in blocks.values():
        var body := block as Node3D
        if not body or not body.has_meta("block_type"):
            continue
        if String(body.get_meta("block_type")) != station_id:
            continue
        if body.global_position.distance_to(player.global_position) <= ItemCatalogScript.CRAFTING_RANGE:
            return true
    return false

func surface_material_at_cell(cell: Vector3i) -> String:
    if world_generation_system != null and world_generation_system.has_method("top_material_for_biome"):
        return String(world_generation_system.call("top_material_for_biome", surface_biome_at_cell(cell)))
    return "grass"

func unmet_tool_requirement_message(material_id: String) -> String:
    var required_tool := ItemCatalogScript.material_required_tool(material_id)
    var required_tier := ItemCatalogScript.material_required_tier(material_id)
    if required_tool == "" or required_tier <= 0:
        return ""
    var active_tool := active_tool_info()
    if String(active_tool.get("tool", "")) == required_tool and int(active_tool.get("tier", 0)) >= required_tier:
        return ""
    if material_id == "wildlife":
        return "Needs %s or ranged weapon for %s" % [required_tool_label(required_tool, required_tier), ItemCatalogScript.material_label(material_id)]
    return "Needs %s for %s" % [required_tool_label(required_tool, required_tier), ItemCatalogScript.material_label(material_id)]

func active_tool_info() -> Dictionary:
    if not inventory_system:
        return { "item": "", "tool": "", "tier": 0 }
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    return {
        "item": item_id,
        "tool": tool_class_for_item(item_id),
        "tier": tool_tier_for_item(item_id)
    }

func tool_class_for_item(item_id: String) -> String:
    if item_id.ends_with("Pickaxe"):
        return "pickaxe"
    if item_id.ends_with("Axe"):
        return "axe"
    if item_id.ends_with("Shovel"):
        return "shovel"
    if item_id.ends_with("Sword") or item_id == "nightBlade":
        return "sword"
    return ""

func tool_tier_for_item(item_id: String) -> int:
    if item_id == "":
        return 0
    if item_id.begins_with("wooden"):
        return 2
    if item_id.begins_with("stone"):
        return 3
    if item_id.begins_with("copper"):
        return 4
    if item_id.begins_with("iron"):
        return 5
    if item_id == "nightBlade":
        return 6
    return 1

func required_tool_label(tool_class: String, tier: int) -> String:
    var tier_name := "Tool"
    if tier <= 2:
        tier_name = "Wooden"
    elif tier == 3:
        tier_name = "Stone"
    elif tier == 4:
        tier_name = "Copper"
    elif tier >= 5:
        tier_name = "Iron"
    var tool_name := tool_class.capitalize()
    return "%s %s" % [tier_name, tool_name]

func tool_power_for_material(material_id: String) -> float:
    if not inventory_system:
        return bare_hand_power_for_material(material_id)
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    if item_id == "":
        return bare_hand_power_for_material(material_id)
    var tier := 1.0
    if item_id.begins_with("wooden"):
        tier = 2.0
    elif item_id.begins_with("stone"):
        tier = 3.0
    elif item_id.begins_with("copper"):
        tier = 4.0
    elif item_id.begins_with("iron"):
        tier = 5.0
    elif item_id == "nightBlade":
        tier = 6.0

    var forage := ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]
    var soil := ["grass", "dirt", "sand", "mud", "snow", "dirtBlock"]
    var stone := ["stone", "deepStone", "rock", "stoneBlock", "cobblestonePath", "glass", "anvil", "furnace", "wardLantern", "sanctuaryBeacon", "riftAnchor"]
    var wood := ["tree", "woodBlock", "workbench", "door", "bed", "chest", "traderStall", "campfire", "torch", "spikeTrap"]
    if material_id == "hostile":
        if item_id.ends_with("Sword") or item_id == "nightBlade":
            return tier
        if item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel"):
            return 0.35 + tier * 0.15
        return bare_hand_power_for_material(material_id)
    if material_id == "wildlife" and (item_id.ends_with("Sword") or item_id.ends_with("Axe") or item_id == "nightBlade"):
        return tier + (1.0 if item_id.ends_with("Sword") else 0.0)
    if item_id.ends_with("Pickaxe") and material_id in ["copperOre", "copperVein"]:
        return tier if tier >= 3.0 else 1.0
    if item_id.ends_with("Pickaxe") and material_id in ["ironOre", "ironVein"]:
        return tier if tier >= 4.0 else 1.0
    if item_id.ends_with("Shovel") and (material_id in soil or material_id in forage):
        return tier
    if item_id.ends_with("Pickaxe") and material_id in stone:
        return tier
    if item_id.ends_with("Axe") and (material_id in wood or material_id in forage):
        return tier
    return bare_hand_power_for_material(material_id)

func bare_hand_power_for_material(material_id: String) -> float:
    if material_id == "hostile" or material_id == "wildlife":
        return 0.12
    if material_id in ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]:
        return 0.40
    if material_id in ["grass", "dirt", "sand", "mud", "snow", "dirtBlock"]:
        return 0.25
    if material_id in ["torch", "glass"]:
        return 0.35
    return 0.05

func melee_damage_for_active_item() -> float:
    if inventory_system == null:
        return 1.0
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    if item_id == "":
        return 1.0
    var tier := float(tool_tier_for_item(item_id))
    if item_id == "nightBlade":
        return 42.0
    if item_id.ends_with("Sword"):
        return 8.0 + tier * 5.0
    if item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel"):
        return 2.0 + tier * 1.25
    return 1.0

func try_fire_ranged() -> bool:
    if inventory_system == null:
        return false
    var active: Dictionary = inventory_system.active_stack()
    var item_id := String(active.get("item", ""))
    var item_spec: Dictionary = ItemCatalogScript.item_spec(item_id)
    if item_id == "" or not item_spec.has("ranged"):
        return false
    var fired := false
    if player_projectiles:
        fired = bool(player_projectiles.fire_active())
    if fired:
        if held_item:
            held_item.play_use("shoot")
        play_feedback("shoot", player.camera.global_position if player and player.camera else Vector3.INF, Color(0.86, 0.74, 0.42), 3)
    if player_projectiles:
        update_hud(player_projectiles.last_message)
    return true

func _on_player_projectile_hostile_hit(variant: String, defeated: bool, position: Vector3) -> void:
    if defeated:
        award_hostile_xp(variant)
        play_feedback("defeat", position, Color(0.62, 0.24, 0.82), 16)
    else:
        play_feedback("enemyHit", position, Color(0.82, 0.22, 0.20), 8)
    if hostile_system:
        update_hud(hostile_system.last_message)

func _on_player_projectile_story_worldmark_hit(resolved: bool, position: Vector3) -> void:
    play_feedback("defeat" if resolved else "enemyHit", position, Color(0.48, 0.68, 0.92), 16 if resolved else 8)
    if worldmark_encounter_controller != null:
        update_hud(String(worldmark_encounter_controller.get("last_message")))

func show_break_overlay(hit_position: Vector3, normal: Vector3, ratio: float) -> void:
    if not break_overlay:
        return
    var n := normal.normalized()
    if n.length_squared() < 0.001:
        n = Vector3.UP
    var tangent: Vector3 = n.cross(Vector3.UP)
    if tangent.length_squared() < 0.001:
        tangent = n.cross(Vector3.RIGHT)
    tangent = tangent.normalized()
    var bitangent: Vector3 = n.cross(tangent).normalized()
    var center: Vector3 = hit_position + n * 0.035
    var size: float = lerp(CELL * 0.22, CELL * 0.86, ratio)
    var branch: float = size * 0.34
    var mesh := break_overlay.mesh as ImmediateMesh
    if mesh == null:
        mesh = ImmediateMesh.new()
    else:
        mesh.clear_surfaces()
    mesh.surface_begin(Mesh.PRIMITIVE_LINES, break_material)
    add_crack_line(mesh, center - tangent * size * 0.36, center + tangent * size * 0.24)
    add_crack_line(mesh, center - bitangent * size * 0.34, center + bitangent * size * 0.28)
    add_crack_line(mesh, center + tangent * size * 0.08, center + tangent * branch + bitangent * branch * 0.55)
    if ratio > 0.34:
        add_crack_line(mesh, center - tangent * size * 0.05, center - tangent * branch - bitangent * branch * 0.50)
        add_crack_line(mesh, center + bitangent * size * 0.04, center - tangent * branch * 0.78 + bitangent * branch)
    if ratio > 0.68:
        add_crack_line(mesh, center - bitangent * size * 0.06, center + tangent * branch * 0.92 - bitangent * branch)
        add_crack_line(mesh, center + tangent * size * 0.16, center + tangent * size * 0.44 - bitangent * branch * 0.48)
    mesh.surface_end()
    break_overlay.mesh = mesh
    break_overlay.visible = true

func add_crack_line(mesh: ImmediateMesh, a: Vector3, b: Vector3) -> void:
    mesh.surface_add_vertex(a)
    mesh.surface_add_vertex(b)

func surface_y_at_position(position: Vector3) -> float:
    return surface_y_at_cell(Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z)))

func ground_y_near_position(position: Vector3) -> float:
    var exterior_y := surface_y_at_position(position)
    var edit_key := Vector2i(world_to_cell(position.x), world_to_cell(position.z))
    if volume_edit_markers.has(edit_key):
        return exterior_y
    if (
        subsurface_system != null
        and position.y < exterior_y - CELL * 0.45
        and subsurface_system.has_method("is_air_at_world")
        and bool(subsurface_system.call("is_air_at_world", position + Vector3(0.0, CELL * 0.55, 0.0)))
        and subsurface_system.has_method("ground_y_near_position")
    ):
        var subsurface_y := float(subsurface_system.call("ground_y_near_position", position))
        if not is_nan(subsurface_y):
            return subsurface_y
    return exterior_y

func terrain_occupancy_at_cell(cell: Vector3i) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("terrain_occupancy_at_cell"):
        return world_generation_system.call("terrain_occupancy_at_cell", cell)
    var material_id := world_material_at_cell(cell)
    var solid := material_id != "" and material_id != "air"
    return {
        "cell": cell,
        "solid": solid,
        "air": not solid,
        "material": material_id,
        "biome": biome_at_volume_cell(cell),
        "fluid": ""
    }

func surface_projection_for_cell(cell: Vector3i, max_up_cells := 32, max_down_cells := 96) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("surface_projection_for_cell"):
        return world_generation_system.call("surface_projection_for_cell", cell, max_up_cells, max_down_cells)
    return {
        "found": true,
        "solidCell": cell,
        "airCell": cell + Vector3i(0, 1, 0),
        "position": Vector3(float(cell.x) * CELL, surface_y_at_cell(cell), float(cell.z) * CELL),
        "solidState": terrain_occupancy_at_cell(cell)
    }

func walkable_surface_cell_near(cell: Vector3i, max_up_cells := 16, max_down_cells := 32) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("walkable_surface_cell_near"):
        return world_generation_system.call("walkable_surface_cell_near", cell, max_up_cells, max_down_cells)
    var projection := surface_projection_for_cell(cell, max_up_cells, max_down_cells)
    projection["walkable"] = true
    projection["occupancy"] = terrain_occupancy_at_cell(projection.get("airCell", cell + Vector3i(0, 1, 0)))
    return projection

func surface_y_at_cell(cell: Vector3i) -> float:
    var edit_key := Vector2i(cell.x, cell.z)
    if volume_edit_markers.has(edit_key):
        return float(volume_edit_markers[edit_key])
    if world_generation_system != null and world_generation_system.has_method("surface_y_for_cell"):
        return float(world_generation_system.call("surface_y_for_cell", cell))
    return 0.0

func base_surface_y_at_cell(cell: Vector3i) -> float:
    if world_generation_system != null and world_generation_system.has_method("base_surface_y_for_cell"):
        return float(world_generation_system.call("base_surface_y_for_cell", cell))
    return 0.0

func natural_surface_y_at_cell(cell: Vector3i) -> float:
    if world_generation_system != null and world_generation_system.has_method("natural_surface_y_for_cell"):
        return float(world_generation_system.call("natural_surface_y_for_cell", cell))
    return 0.0

func surface_biome_at_cell(cell: Vector3i) -> String:
    if world_generation_system != null and world_generation_system.has_method("surface_biome_for_cell3"):
        return String(world_generation_system.call("surface_biome_for_cell3", cell))
    return "plains"

func biome_at_volume_cell(cell: Vector3i) -> String:
    if world_generation_system != null and world_generation_system.has_method("biome_at_volume_cell"):
        return String(world_generation_system.call("biome_at_volume_cell", cell))
    return surface_biome_at_cell(Vector3i(cell.x, 0, cell.z))

func biome_at_world(position: Vector3) -> String:
    if world_generation_system != null and world_generation_system.has_method("biome_at_world"):
        return String(world_generation_system.call("biome_at_world", position))
    return surface_biome_at_cell(Vector3i(world_to_cell(position.x), world_to_cell(position.y), world_to_cell(position.z)))

func world_material_at_cell(cell: Vector3i) -> String:
    if world_generation_system != null and world_generation_system.has_method("material_at_cell3"):
        return String(world_generation_system.call("material_at_cell3", cell))
    return surface_material_at_cell(cell)

func town_region_at_cell(x: int, z: int) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("town_region_at_cell3"):
        return world_generation_system.call("town_region_at_cell3", Vector3i(x, 0, z))
    return {}

func town_region_for_height_cell(x: int, z: int) -> Dictionary:
    if world_generation_system != null and world_generation_system.has_method("town_region_for_surface_cell3"):
        return world_generation_system.call("town_region_for_surface_cell3", Vector3i(x, 0, z))
    return {}

func town_slope_apron_cells(town: Dictionary) -> int:
    if world_generation_system != null and world_generation_system.has_method("town_slope_apron_cells"):
        return int(world_generation_system.call("town_slope_apron_cells", town))
    return 18
