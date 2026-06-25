extends "res://scripts/MainChunkTerrain.gd"

func destroy_target() -> void:
    if try_fire_ranged():
        return
    var hit: Dictionary = player.view_ray(MELEE_RANGE)
    if hit.is_empty():
        reset_break_progress()
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
        if held_item:
            held_item.play_use("strike")
        if hostile_system:
            var variant := String(collider.get_meta("variant", "shadow"))
            var defeated_hostile: bool = hostile_system.damage_hostile(collider, melee_damage_for_active_item())
            if defeated_hostile:
                award_hostile_xp(variant)
                play_feedback("defeat", collider.global_position + Vector3(0.0, 1.0, 0.0) if collider is Node3D else Vector3.INF, Color(0.62, 0.24, 0.82), 16)
            else:
                play_feedback("enemyHit", collider.global_position + Vector3(0.0, 1.0, 0.0) if collider is Node3D else Vector3.INF, Color(0.82, 0.22, 0.20), 8)
            update_hud(hostile_system.last_message)
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
        update_hud("Breaking %s %.0f%%" % [ItemCatalogScript.material_label(material_id), ratio * 100.0])
        return

    reset_break_progress()
    complete_destroy_target(hit, collider, kind, material_id)

func play_melee_miss() -> void:
    if held_item:
        held_item.play_use("strike")

func strike_effect_for_material(material_id: String) -> String:
    var id := material_id.to_lower()
    if id.find("wood") >= 0 or id in ["tree", "logs", "door", "chest", "workbench", "bed", "torch", "campfire", "traderstall"]:
        return "woodChop"
    return "strike"

func break_target_for_hit(hit: Dictionary, collider: Node, kind: String) -> Dictionary:
    if kind == "terrain":
        var sample_pos: Vector3 = hit.position - hit.normal * (CELL * 0.35)
        var cell := Vector2i(world_to_cell(sample_pos.x), world_to_cell(sample_pos.z))
        return {
            "id": "terrain:%d,%d" % [cell.x, cell.y],
            "material": terrain_material_id_for_cell(cell.x, cell.y)
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
    play_feedback("break", hit["position"], feedback_color_for_material(material_id), 12)
    if kind == "terrain":
        var sample_pos: Vector3 = hit.position - hit.normal * (CELL * 0.35)
        var cell := Vector2i(world_to_cell(sample_pos.x), world_to_cell(sample_pos.z))
        var old_height := terrain_height_cell(cell.x, cell.y)
        height_edits[cell] = max(MIN_HEIGHT, old_height - CELL)
        rebuild_chunks_around_cell(cell)
        inventory_system.add_item(ItemCatalogScript.material_drop(material_id), 1)
        award_break_xp(material_id)
        complete_break_objectives(material_id)
        var collapsed_terrain_blocks := collapse_unsupported_structures()
        var terrain_message := "Dug %s" % ItemCatalogScript.material_label(material_id)
        if collapsed_terrain_blocks > 0:
            terrain_message = "Structure collapsed: %d blocks" % collapsed_terrain_blocks
        update_hud(terrain_message)
    elif kind == "block":
        var block_cell: Vector3i = collider.get_meta("cell")
        var block_type: String = collider.get_meta("block_type")
        blocks.erase(block_cell)
        collider.queue_free()
        inventory_system.add_item(ItemCatalogScript.material_drop(material_id), 1)
        award_break_xp(material_id)
        complete_break_objectives(material_id)
        var collapsed_blocks := collapse_unsupported_structures()
        var block_message := "Recovered %s" % ItemCatalogScript.label(block_type)
        if collapsed_blocks > 0:
            block_message = "Structure collapsed: %d blocks" % collapsed_blocks
        update_hud(block_message)
    elif kind == "prop":
        var prop_id: String = collider.get_meta("prop_id")
        var drop: String = collider.get_meta("drop")
        var drop_count := int(collider.get_meta("drop_count", 1))
        removed_props[prop_id] = true
        if material_id == "wildlife":
            wildlife_nodes.erase(collider)
        if drop == "logs":
            spawn_falling_tree_visual(collider as Node3D)
            inventory_system.add_item("logs", max(1, drop_count))
            award_break_xp("tree")
            complete_break_objectives(material_id)
            update_hud("Tree dropped logs")
        elif drop == "stones":
            inventory_system.add_item("stones", max(1, drop_count))
            award_break_xp(material_id)
            complete_break_objectives(material_id)
            update_hud("Rock dropped stones")
        else:
            inventory_system.add_item(drop, max(1, drop_count))
            if collider.has_meta("extra_drop"):
                var extra_drop := String(collider.get_meta("extra_drop", ""))
                var extra_count := int(collider.get_meta("extra_drop_count", 0))
                if extra_drop != "" and extra_count > 0:
                    inventory_system.add_item(extra_drop, extra_count)
            award_break_xp(material_id)
            complete_break_objectives(material_id)
            update_hud("%s dropped" % ItemCatalogScript.label(drop))
        collider.queue_free()

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

func terrain_material_id_for_cell(x: int, z: int) -> String:
    var biome := biome_at_cell(x, z)
    var height := terrain_height_cell(x, z)
    if biome == "beach" or biome == "desert":
        return "sand"
    if biome == "swamp":
        return "mud"
    if biome == "snow":
        return "snow"
    if biome == "alpine" or biome == "tundra" or height > 46.0:
        return "stone"
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
    var stone := ["stone", "rock", "stoneBlock", "cobblestonePath", "glass", "anvil", "furnace", "wardLantern", "sanctuaryBeacon", "riftAnchor"]
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
    var mesh := ImmediateMesh.new()
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

func height_at_world(x: float, z: float) -> float:
    return terrain_height_cell(world_to_cell(x), world_to_cell(z))

func terrain_height_cell(x: int, z: int) -> float:
    var key := Vector2i(x, z)
    if height_edits.has(key):
        return float(height_edits[key])
    return base_height_cell(x, z)

func base_height_cell(x: int, z: int) -> float:
    var town: Dictionary = town_region_for_height_cell(x, z)
    if not town.is_empty():
        var center_x := int(town["centerX"])
        var center_z := int(town["centerZ"])
        var radius := float(town["radius"])
        var distance := Vector2(float(x - center_x), float(z - center_z)).length()
        var level := float(town["level"])
        if distance <= radius:
            return level
        var apron := float(town_slope_apron_cells(town))
        var natural := natural_base_height_cell(x, z)
        var blend := clampf((distance - radius) / maxf(1.0, apron), 0.0, 1.0)
        var eased := blend * blend * (3.0 - 2.0 * blend)
        return lerp(level, natural, eased)
    return natural_base_height_cell(x, z)

func natural_base_height_cell(x: int, z: int) -> float:
    var continent: float = noise01(height_noise, x, z)
    var broad_hill: float = noise01(height_noise, x + 12000, z - 12200)
    var plain_field: float = noise01(flat_noise, x - 8400, z + 7200)
    var ridges: float = abs(noise01(ridge_noise, x - 200, z + 510) - 0.5) * 2.0
    var flatland_mask: float = smoothstep_range(plain_field, 0.42, 0.68)
    var mountain_mask: float = smoothstep_range(noise01(height_noise, x + 1800, z - 1500), 0.58, 0.82)
    var peak_mask: float = smoothstep_range(noise01(ridge_noise, x - 3900, z + 2600), 0.74, 0.93) * mountain_mask
    var plains: float = 6.0 + continent * 10.0 + (broad_hill - 0.5) * 2.0
    var hills: float = 7.2 + continent * 15.5 + pow(maxf(broad_hill - 0.18, 0.0), 1.45) * 12.0
    var mountains: float = 10.0 + continent * 21.0 + pow(ridges, 1.92) * (16.0 + mountain_mask * 44.0) + pow(peak_mask, 2.05) * 34.0
    var lowland: float = lerp(hills, plains, flatland_mask)
    var detail: float = (noise01(ridge_noise, x + 7800, z - 9100) - 0.5) * lerp(0.28, 1.35, mountain_mask)
    var raw: float = MIN_HEIGHT + lerp(lowland, mountains, mountain_mask) + detail
    var terrace: float = lerp(CELL * 0.34, CELL * 1.15, mountain_mask)
    return clamp(round(raw / terrace) * terrace, MIN_HEIGHT, MAX_HEIGHT)

func biome_at_cell(x: int, z: int) -> String:
    if not town_region_at_cell(x, z).is_empty():
        return "town"
    var h: float = terrain_height_cell(x, z)
    var moisture: float = noise01(moisture_noise, x - 1200, z + 800)
    var temp: float = clamp(0.42 + noise01(temp_noise, x + 1500, z - 900) * 0.46 - abs(z) / 1300.0 - max(0.0, h - 38.0) / 180.0, 0.0, 1.0)
    if h < WATER_LEVEL + 0.3:
        return "ocean"
    if h < WATER_LEVEL + 1.7:
        return "beach"
    if h > 78.0:
        return "snow"
    if h > 56.0:
        return "alpine" if temp < 0.48 else "tundra"
    if h > 42.0 and moisture < 0.5:
        return "alpine"
    if moisture > 0.78 and h < WATER_LEVEL + 6.0:
        return "swamp"
    if temp > 0.68 and moisture < 0.32:
        return "desert"
    if temp > 0.61 and moisture < 0.48:
        return "savanna"
    if temp < 0.33 and moisture > 0.42:
        return "taiga"
    if moisture > 0.64:
        return "forest"
    return "plains"

func town_region_at_cell(x: int, z: int) -> Dictionary:
    var region_x := floori(float(x) / float(TOWN_REGION_CELLS))
    var region_z := floori(float(z) / float(TOWN_REGION_CELLS))
    for rz in range(region_z - 1, region_z + 2):
        for rx in range(region_x - 1, region_x + 2):
            var town: Dictionary = town_region(rx, rz)
            if town.is_empty():
                continue
            var distance := Vector2(float(x - int(town["centerX"])), float(z - int(town["centerZ"]))).length()
            if distance <= float(town["radius"]):
                return town
    return {}

func town_region_for_height_cell(x: int, z: int) -> Dictionary:
    var region_x := floori(float(x) / float(TOWN_REGION_CELLS))
    var region_z := floori(float(z) / float(TOWN_REGION_CELLS))
    var best_town := {}
    var best_distance := INF
    for rz in range(region_z - 1, region_z + 2):
        for rx in range(region_x - 1, region_x + 2):
            var town: Dictionary = town_region(rx, rz)
            if town.is_empty():
                continue
            var distance := Vector2(float(x - int(town["centerX"])), float(z - int(town["centerZ"]))).length()
            var max_distance := float(town["radius"]) + float(town_slope_apron_cells(town))
            if distance <= max_distance and distance < best_distance:
                best_town = town
                best_distance = distance
    return best_town

func town_slope_apron_cells(town: Dictionary) -> int:
    var key: Vector2i = Vector2i(int(town.get("regionX", 0)), int(town.get("regionZ", 0)))
    if town_slope_apron_cache.has(key):
        return int(town_slope_apron_cache[key])
    var radius: int = int(town.get("radius", TOWN_RADIUS_CELLS))
    var center_x: int = int(town.get("centerX", 0))
    var center_z: int = int(town.get("centerZ", 0))
    var level: float = float(town.get("level", WATER_LEVEL + 3.0))
    var apron: int = maxi(18, ceili(float(radius) * 0.55))
    var max_apron: int = maxi(apron, int(float(TOWN_REGION_CELLS) * 0.5) - radius - 6)
    var sample_dirs: Array[Vector2] = [
        Vector2(1.0, 0.0),
        Vector2(-1.0, 0.0),
        Vector2(0.0, 1.0),
        Vector2(0.0, -1.0),
        Vector2(1.0, 1.0).normalized(),
        Vector2(-1.0, 1.0).normalized(),
        Vector2(1.0, -1.0).normalized(),
        Vector2(-1.0, -1.0).normalized()
    ]
    for _pass in range(3):
        var max_diff: float = 0.0
        var sample_distance: float = float(radius + apron)
        for direction in sample_dirs:
            var sample_x: int = center_x + roundi(direction.x * sample_distance)
            var sample_z: int = center_z + roundi(direction.y * sample_distance)
            max_diff = maxf(max_diff, absf(natural_base_height_cell(sample_x, sample_z) - level))
        var needed: int = ceili(max_diff / maxf(0.01, CELL * 0.72)) + 4
        var next_apron: int = mini(max_apron, maxi(apron, needed))
        if next_apron == apron:
            break
        apron = next_apron
    town_slope_apron_cache[key] = apron
    return apron
