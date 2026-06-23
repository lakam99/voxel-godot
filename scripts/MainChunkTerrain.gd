extends "res://scripts/MainInteractionFlow.gd"

func add_block_mesh(parent: Node3D, size: Vector3, offset: Vector3, material_key: String, rotation := Vector3.ZERO) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = size
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.mesh = mesh
    mesh_instance.material_override = materials.get(material_key, materials["stoneBlock"])
    mesh_instance.position = offset
    mesh_instance.rotation = rotation
    parent.add_child(mesh_instance)
    return mesh_instance

func add_workbench_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 1.18, CELL * 0.16, CELL * 0.92), Vector3(0.0, CELL * 0.29, 0.0), "workbench")
    add_block_mesh(parent, Vector3(CELL * 1.24, CELL * 0.06, CELL * 0.98), Vector3(0.0, CELL * 0.41, 0.0), "door")
    add_block_mesh(parent, Vector3(CELL * 0.82, CELL * 0.08, CELL * 0.58), Vector3(0.0, -CELL * 0.20, 0.0), "workbench")
    for x_offset in [-0.43, 0.43]:
        for z_offset in [-0.31, 0.31]:
            add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 0.58, CELL * 0.10), Vector3(float(x_offset) * CELL, -CELL * 0.10, float(z_offset) * CELL), "door")
    for x_offset in [-0.28, 0.28]:
        add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.08, CELL * 0.78), Vector3(float(x_offset) * CELL, CELL * 0.11, 0.0), "door")
    add_block_mesh(parent, Vector3(CELL * 0.38, CELL * 0.035, CELL * 0.08), Vector3(-CELL * 0.25, CELL * 0.52, -CELL * 0.22), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.04, CELL * 0.34), Vector3(CELL * 0.25, CELL * 0.52, CELL * 0.10), "woodBlock")
    add_block_mesh(parent, Vector3(CELL * 0.12, CELL * 0.06, CELL * 0.12), Vector3(CELL * 0.34, CELL * 0.53, -CELL * 0.18), "stoneBlock")

func add_chest_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.98, CELL * 0.46, CELL * 0.72), Vector3(0.0, -CELL * 0.20, 0.0), "chest")
    add_block_mesh(parent, Vector3(CELL * 1.02, CELL * 0.18, CELL * 0.76), Vector3(0.0, CELL * 0.12, 0.0), "chest")
    add_block_mesh(parent, Vector3(CELL * 1.06, CELL * 0.08, CELL * 0.80), Vector3(0.0, CELL * 0.24, 0.0), "door")
    for x_offset in [-0.36, 0.36]:
        add_block_mesh(parent, Vector3(CELL * 0.075, CELL * 0.66, CELL * 0.80), Vector3(float(x_offset) * CELL, -CELL * 0.02, 0.0), "chestBand")
    add_block_mesh(parent, Vector3(CELL * 1.08, CELL * 0.055, CELL * 0.055), Vector3(0.0, CELL * 0.03, -CELL * 0.41), "chestBand")
    add_block_mesh(parent, Vector3(CELL * 0.17, CELL * 0.14, CELL * 0.045), Vector3(0.0, -CELL * 0.03, -CELL * 0.44), "hingeMetal")

func add_bed_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 1.18, CELL * 0.12, CELL * 0.78), Vector3(0.0, -CELL * 0.35, 0.0), "door")
    for x_offset in [-0.48, 0.48]:
        for z_offset in [-0.30, 0.30]:
            add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.34, CELL * 0.08), Vector3(float(x_offset) * CELL, -CELL * 0.49, float(z_offset) * CELL), "door")
    add_block_mesh(parent, Vector3(CELL * 1.10, CELL * 0.18, CELL * 0.72), Vector3(CELL * 0.02, -CELL * 0.21, 0.0), "bedPillow")
    add_block_mesh(parent, Vector3(CELL * 0.74, CELL * 0.20, CELL * 0.74), Vector3(CELL * 0.18, -CELL * 0.12, 0.0), "bedBlanket")
    add_block_mesh(parent, Vector3(CELL * 0.16, CELL * 0.56, CELL * 0.82), Vector3(-CELL * 0.57, -CELL * 0.18, 0.0), "door")

func add_anvil_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.52, CELL * 0.18, CELL * 0.52), Vector3(0.0, -CELL * 0.41, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.38, CELL * 0.34, CELL * 0.38), Vector3(0.0, -CELL * 0.17, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.92, CELL * 0.20, CELL * 0.44), Vector3(0.0, CELL * 0.06, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.32, CELL * 0.16, CELL * 0.38), Vector3(CELL * 0.46, CELL * 0.02, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.22, CELL * 0.13, CELL * 0.34), Vector3(-CELL * 0.58, CELL * 0.00, 0.0), "anvil", Vector3(0.0, 0.0, 0.20))
    add_block_mesh(parent, Vector3(CELL * 0.26, CELL * 0.05, CELL * 0.32), Vector3(0.0, CELL * 0.20, 0.0), "hingeMetal")

func add_furnace_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.94, CELL * 0.82, CELL * 0.78), Vector3(0.0, -CELL * 0.06, 0.0), "furnace")
    add_block_mesh(parent, Vector3(CELL * 1.02, CELL * 0.12, CELL * 0.84), Vector3(0.0, CELL * 0.42, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.54, CELL * 0.34, CELL * 0.045), Vector3(0.0, -CELL * 0.09, -CELL * 0.42), "furnaceMouth")
    add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.10, CELL * 0.052), Vector3(0.0, -CELL * 0.14, -CELL * 0.45), "furnaceGlow")
    add_block_mesh(parent, Vector3(CELL * 0.52, CELL * 0.06, CELL * 0.05), Vector3(0.0, CELL * 0.14, -CELL * 0.43), "hingeMetal")
    add_block_mesh(parent, Vector3(CELL * 0.72, CELL * 0.10, CELL * 0.84), Vector3(0.0, -CELL * 0.51, 0.0), "stoneBlock")

func add_campfire_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.82, CELL * 0.08, CELL * 0.22), Vector3(0.0, -CELL * 0.38, 0.0), "trunk", Vector3(0.0, 0.72, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.82, CELL * 0.08, CELL * 0.22), Vector3(0.0, -CELL * 0.34, 0.0), "trunk", Vector3(0.0, -0.72, 0.0))
    for x_offset in [-0.34, 0.34]:
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.14, CELL * 0.18), Vector3(float(x_offset) * CELL, -CELL * 0.40, CELL * 0.30), "stoneBlock")
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.14, CELL * 0.18), Vector3(float(x_offset) * CELL, -CELL * 0.40, -CELL * 0.30), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.20, CELL * 0.50, CELL * 0.20), Vector3(0.0, -CELL * 0.08, 0.0), "flame", Vector3(0.0, 0.78, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.15, CELL * 0.38, CELL * 0.15), Vector3(0.0, -CELL * 0.03, 0.0), "furnaceGlow", Vector3(0.0, -0.78, 0.0))

func add_torch_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 0.78, CELL * 0.10), Vector3(0.0, -CELL * 0.04, 0.0), "trunk")
    add_block_mesh(parent, Vector3(CELL * 0.22, CELL * 0.12, CELL * 0.22), Vector3(0.0, CELL * 0.38, 0.0), "torch")
    add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.24, CELL * 0.18), Vector3(0.0, CELL * 0.56, 0.0), "flame")

func add_spike_trap_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 0.86, CELL * 0.10, CELL * 0.86), Vector3(0.0, -CELL * 0.44, 0.0), "spikeTrap")
    for x_offset in [-0.24, 0.0, 0.24]:
        for z_offset in [-0.24, 0.0, 0.24]:
            add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.34, CELL * 0.08), Vector3(float(x_offset) * CELL, -CELL * 0.24, float(z_offset) * CELL), "anvil", Vector3(0.35, 0.0, 0.35))

func add_ward_object_visual(parent: Node3D, block_type: String) -> void:
    var glow_key := "sanctuaryBeacon" if block_type == "sanctuaryBeacon" else ("riftAnchor" if block_type == "riftAnchor" else "wardLantern")
    add_block_mesh(parent, Vector3(CELL * 0.44, CELL * 0.16, CELL * 0.44), Vector3(0.0, -CELL * 0.43, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.12, CELL * 0.70, CELL * 0.12), Vector3(0.0, -CELL * 0.08, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.34, CELL * 0.34), Vector3(0.0, CELL * 0.34, 0.0), glow_key, Vector3(0.0, 0.78, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.50, CELL * 0.045, CELL * 0.50), Vector3(0.0, CELL * 0.56, 0.0), "hingeMetal")

func add_door_visual(parent: Node3D, secondary: bool) -> void:
    var width := CELL * 0.90
    var height := CELL * 1.72
    var thickness := CELL * 0.14
    var hinge_side := 1.0 if secondary else -1.0
    var pivot := Node3D.new()
    pivot.name = "DoorPivot"
    pivot.position = Vector3(hinge_side * width * 0.5, CELL * 0.38, 0.0)
    parent.add_child(pivot)
    var panel_center := Vector3(-hinge_side * width * 0.5, 0.0, 0.0)
    add_block_mesh(pivot, Vector3(width, height, thickness), panel_center, "door")
    add_block_mesh(pivot, Vector3(width * 0.92, CELL * 0.08, thickness * 1.18), panel_center + Vector3(0.0, height * 0.26, -thickness * 0.10), "workbench")
    add_block_mesh(pivot, Vector3(width * 0.92, CELL * 0.08, thickness * 1.18), panel_center + Vector3(0.0, -height * 0.12, -thickness * 0.10), "workbench")
    add_block_mesh(pivot, Vector3(CELL * 0.07, height * 0.82, thickness * 1.22), Vector3(0.0, 0.0, -thickness * 0.08), "hingeMetal")
    add_block_mesh(pivot, Vector3(CELL * 0.12, CELL * 0.12, CELL * 0.06), Vector3(-hinge_side * width * 0.80, -height * 0.03, -thickness * 0.72), "hingeMetal")

func add_door_interaction_proxy(parent: StaticBody3D, collider_size: Vector3, collider_offset: Vector3) -> void:
    var area := Area3D.new()
    area.name = "DoorInteraction"
    area.collision_layer = 1
    area.collision_mask = 0
    area.monitoring = false
    area.monitorable = true
    area.set_meta("kind", "block")
    area.set_meta("block_type", "door")
    area.set_meta("cell", parent.get_meta("cell"))
    area.set_meta("interaction_parent", parent)
    var shape := BoxShape3D.new()
    shape.size = Vector3(collider_size.x * 1.10, collider_size.y * 1.08, maxf(collider_size.z, CELL * 0.50))
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position = collider_offset
    area.add_child(collider)
    parent.add_child(area)

func interaction_block_from_collider(collider: Node) -> Node:
    if collider == null:
        return null
    if collider.has_meta("interaction_parent"):
        var parent = collider.get_meta("interaction_parent")
        if parent is Node and is_instance_valid(parent):
            return parent
    return collider

func add_ore_block_visual(parent: Node3D, block_type: String, size: Vector3, offset: Vector3) -> void:
    add_block_mesh(parent, size, offset, "oreBase")
    var seam_material := block_type
    var glow_material := "ironOreGlow" if block_type == "ironVein" else "copperOreGlow"
    var face_z := -size.z * 0.51
    var seam_specs := [
        { "pos": Vector3(-size.x * 0.22, size.y * 0.18, face_z), "size": Vector3(size.x * 0.52, size.y * 0.075, size.z * 0.035), "rot": 0.18 },
        { "pos": Vector3(size.x * 0.18, -size.y * 0.10, face_z), "size": Vector3(size.x * 0.66, size.y * 0.075, size.z * 0.035), "rot": -0.24 },
        { "pos": Vector3(size.x * 0.02, size.y * 0.34, face_z), "size": Vector3(size.x * 0.34, size.y * 0.065, size.z * 0.035), "rot": 0.55 }
    ]
    for spec in seam_specs:
        var seam_size: Vector3 = spec["size"]
        var seam_pos: Vector3 = spec["pos"]
        var seam := add_block_mesh(parent, seam_size, offset + seam_pos, seam_material)
        seam.name = "OreBlockSeam"
        seam.rotation.z = float(spec["rot"])
    for x_offset in [-0.18, 0.16]:
        var glint := add_block_mesh(
            parent,
            Vector3(size.x * 0.10, size.y * 0.10, size.z * 0.045),
            offset + Vector3(float(x_offset) * size.x, size.y * (0.04 if x_offset < 0.0 else 0.30), face_z - size.z * 0.01),
            glow_material
        )
        glint.name = "OreBlockGlint"

func add_trader_stall_visual(parent: Node3D) -> void:
    add_block_mesh(parent, Vector3(CELL * 1.08, CELL * 0.32, CELL * 0.64), Vector3(0.0, -CELL * 0.34, 0.0), "traderStall")
    for x_offset in [-0.45, 0.45]:
        for z_offset in [-0.30, 0.30]:
            add_block_mesh(parent, Vector3(CELL * 0.07, CELL * 1.05, CELL * 0.07), Vector3(float(x_offset) * CELL, CELL * 0.06, float(z_offset) * CELL), "traderStall")
    add_block_mesh(parent, Vector3(CELL * 1.24, CELL * 0.12, CELL * 0.86), Vector3(0.0, CELL * 0.62, 0.0), "traderCloth")
    for i in range(-2, 3):
        var material_key := "traderClothLight" if i % 2 == 0 else "traderCloth"
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.16, CELL * 0.05), Vector3(float(i) * CELL * 0.20, CELL * 0.50, CELL * 0.45), material_key)

func create_block(cell: Vector3i, block_type: String, options: Dictionary = {}) -> StaticBody3D:
    if blocks.has(cell):
        return blocks[cell]
    var body := StaticBody3D.new()
    body.name = "Block_%s_%d_%d_%d" % [block_type, cell.x, cell.y, cell.z]
    var world_y := float(options.get("world_y", cell.y * CELL))
    body.position = Vector3(cell.x * CELL, world_y, cell.z * CELL)
    body.rotation.y = float(options.get("facing", 0.0))
    body.set_meta("kind", "block")
    body.set_meta("cell", cell)
    body.set_meta("block_type", block_type)
    body.set_meta("generated", bool(options.get("generated", false)))
    body.set_meta("player_placed", bool(options.get("player_placed", false)))
    if options.has("generatedTier"):
        body.set_meta("generatedTier", String(options.get("generatedTier", "")))
    if options.has("cacheKey"):
        body.set_meta("cacheKey", String(options.get("cacheKey", "")))
    if options.has("storageSlots"):
        body.set_meta("storage_slots", options.get("storageSlots", []))

    var profile := block_collision_profile(block_type)
    var mesh_size: Vector3 = profile.get("size", Vector3.ONE * CELL * 0.96)
    var mesh_offset: Vector3 = profile.get("offset", Vector3.ZERO)
    var collider_size := mesh_size
    var collider_offset := mesh_offset
    if block_type == "cobblestonePath":
        mesh_size = Vector3(CELL * 0.96, CELL * 0.045, CELL * 0.96)
        mesh_offset.y = 0.0
    elif block_type == "door":
        mesh_size = Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16)
        mesh_offset.y = CELL * 0.38
        body.set_meta("open", false)
        body.set_meta("closed_rotation", body.rotation.y)
        body.set_meta("secondary", bool(options.get("secondary", false)))
        var swing := 1.0 if bool(options.get("secondary", false)) else -1.0
        body.set_meta("open_swing", swing * PI * 0.5)
        body.set_meta("open_rotation", body.rotation.y)
    elif block_type == "torch":
        mesh_size = Vector3(CELL * 0.18, CELL * 0.82, CELL * 0.18)
        mesh_offset.y = CELL * 0.10
    elif block_type == "spikeTrap":
        mesh_size = Vector3(CELL * 0.82, CELL * 0.30, CELL * 0.82)
        mesh_offset.y = -CELL * 0.28
    elif block_type == "campfire":
        mesh_size = Vector3(CELL * 0.70, CELL * 0.32, CELL * 0.70)
        mesh_offset.y = -CELL * 0.28
    elif block_type == "traderStall":
        mesh_size = Vector3(CELL * 1.12, CELL * 0.74, CELL * 0.82)
        mesh_offset.y = -CELL * 0.14
    collider_size = mesh_size
    collider_offset = mesh_offset

    if block_type == "workbench":
        add_workbench_visual(body)
    elif block_type == "chest":
        add_chest_visual(body)
    elif block_type == "bed":
        add_bed_visual(body)
    elif block_type == "anvil":
        add_anvil_visual(body)
    elif block_type == "furnace":
        add_furnace_visual(body)
    elif block_type == "campfire":
        add_campfire_visual(body)
    elif block_type == "torch":
        add_torch_visual(body)
    elif block_type == "spikeTrap":
        add_spike_trap_visual(body)
    elif block_type == "wardLantern" or block_type == "sanctuaryBeacon" or block_type == "riftAnchor":
        add_ward_object_visual(body, block_type)
    elif block_type == "door":
        add_door_visual(body, bool(options.get("secondary", false)))
    elif block_type == "traderStall":
        add_trader_stall_visual(body)
    elif block_type == "copperVein" or block_type == "ironVein":
        add_ore_block_visual(body, block_type, mesh_size, mesh_offset)
    else:
        add_block_mesh(body, mesh_size, mesh_offset, block_type)

    var shape := BoxShape3D.new()
    shape.size = collider_size
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position = collider_offset
    body.add_child(collider)
    if block_type == "door":
        add_door_interaction_proxy(body, collider_size, collider_offset)
    elif block_type == "cobblestonePath":
        body.collision_layer = 8

    block_root.add_child(body)
    blocks[cell] = body
    return body

func is_structural_block_type(block_type: String) -> bool:
    return not NON_STRUCTURAL_BLOCK_TYPES.has(block_type)

func block_bottom_y(block: Node3D) -> float:
    for child in block.get_children():
        var collider := child as CollisionShape3D
        if collider == null or collider.shape == null or collider.disabled:
            continue
        if collider.shape is BoxShape3D:
            var box := collider.shape as BoxShape3D
            return block.global_position.y + collider.position.y - box.size.y * 0.5
    return block.global_position.y - CELL * 0.48

func block_touches_terrain(block: Node3D) -> bool:
    var ground := height_at_world(block.global_position.x, block.global_position.z)
    return block_bottom_y(block) <= ground + CELL * 0.55

func adjacent_structure_blocks(block: Node) -> Array:
    var result := []
    if block == null or not block.has_meta("cell"):
        return result
    var cell: Vector3i = block.get_meta("cell")
    var offsets := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]
    for offset in offsets:
        var neighbor = blocks.get(cell + offset)
        if neighbor != null and is_instance_valid(neighbor):
            result.append(neighbor)
    return result

func connected_structure_component(start: Node, visited: Dictionary) -> Array:
    var component := []
    if start == null or not start.has_meta("cell"):
        return component
    var stack := [start]
    visited[start.get_meta("cell")] = true
    while not stack.is_empty():
        var block = stack.pop_back()
        if block == null or not is_instance_valid(block):
            continue
        component.append(block)
        for neighbor in adjacent_structure_blocks(block):
            var neighbor_cell: Vector3i = neighbor.get_meta("cell")
            if visited.has(neighbor_cell):
                continue
            visited[neighbor_cell] = true
            stack.append(neighbor)
    return component

func structure_component_has_grounded_base(component: Array) -> bool:
    var structural := []
    var base_bottom := INF
    for block_value in component:
        var block := block_value as Node3D
        if block == null or not block.has_meta("block_type"):
            continue
        if not is_structural_block_type(String(block.get_meta("block_type", ""))):
            continue
        structural.append(block)
        base_bottom = minf(base_bottom, block_bottom_y(block))
    if structural.is_empty():
        return true
    for block_value in structural:
        var block := block_value as Node3D
        if block == null:
            continue
        if block_bottom_y(block) <= base_bottom + CELL * 0.18 and not block_touches_terrain(block):
            return false
    return true

func drop_stored_items_for_block(block: Node3D) -> void:
    if block == null:
        return
    var position := block.global_position
    if block.has_meta("storage_slots"):
        for slot in block.get_meta("storage_slots"):
            if not (slot is Dictionary):
                continue
            var item_id := String(slot.get("item", ""))
            var count := int(slot.get("count", 0))
            if item_id != "" and count > 0:
                spawn_pickup_stack(item_id, count, position)
    if block.has_meta("furnace_state"):
        var state: Dictionary = block.get_meta("furnace_state")
        for slot_name in ["input", "fuel", "output"]:
            var slot = state.get(slot_name, {})
            if not (slot is Dictionary):
                continue
            var item_id := String(slot.get("item", ""))
            var count := int(slot.get("count", 0))
            if item_id != "" and count > 0:
                spawn_pickup_stack(item_id, count, position)

func collapse_structure_component(component: Array) -> int:
    var collapsed := 0
    var center := Vector3.ZERO
    for block_value in component:
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block) or not block.has_meta("cell"):
            continue
        center += block.global_position
        var block_type := String(block.get_meta("block_type", ""))
        drop_stored_items_for_block(block)
        spawn_pickup_stack(ItemCatalogScript.material_drop(block_type), 1, block.global_position)
        if utility_system and utility_system.active_block == block:
            utility_system.close()
        blocks.erase(block.get_meta("cell"))
        block.queue_free()
        collapsed += 1
    if collapsed > 0:
        center /= float(collapsed)
        play_feedback("break", center, Color(0.80, 0.64, 0.42), min(18, collapsed + 4))
    return collapsed

func collapse_unsupported_structures() -> int:
    var visited := {}
    var collapsed_total := 0
    for block_value in blocks.values().duplicate():
        var block := block_value as Node
        if block == null or not is_instance_valid(block) or not block.has_meta("cell"):
            continue
        var cell: Vector3i = block.get_meta("cell")
        if visited.has(cell):
            continue
        var component := connected_structure_component(block, visited)
        if structure_component_has_grounded_base(component):
            continue
        collapsed_total += collapse_structure_component(component)
    if collapsed_total > 0:
        update_hud("Structure collapsed: %d blocks" % collapsed_total)
    return collapsed_total

func trap_damage_at(position: Vector3, delta: float = 0.0) -> float:
    var damage := 0.0
    for block in blocks.values():
        var body := block as StaticBody3D
        if body == null or String(body.get_meta("block_type", "")) != "spikeTrap":
            continue
        var cooldown := maxf(0.0, float(body.get_meta("trapCooldown", 0.0)) - delta)
        body.set_meta("trapCooldown", cooldown)
        if cooldown > 0.0:
            continue
        if abs(body.global_position.x - position.x) > CELL * 0.54:
            continue
        if abs(body.global_position.z - position.z) > CELL * 0.54:
            continue
        body.set_meta("trapCooldown", 0.72)
        damage += 12.0
    return damage

func light_safety_at(position: Vector3, include_beacon := true, range: float = CELL * 9.0) -> float:
    var safety := 0.0
    for block in blocks.values():
        var body := block as StaticBody3D
        if body == null:
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if not (block_type in ["campfire", "torch", "wardLantern", "sanctuaryBeacon", "riftAnchor"]):
            continue
        if block_type == "sanctuaryBeacon" and not include_beacon:
            continue
        var effect_range := range
        var strength := 1.0
        if block_type == "riftAnchor":
            effect_range = CELL * 42.0
            strength = 2.2
        elif block_type == "sanctuaryBeacon":
            effect_range = CELL * 34.0
            strength = 1.65
        elif block_type == "wardLantern":
            effect_range = CELL * 18.0
            strength = 1.3
        elif block_type == "campfire":
            effect_range = CELL * 13.0
            strength = 1.18
        var distance := body.global_position.distance_to(position)
        if distance > effect_range:
            continue
        safety = maxf(safety, minf(1.0, (1.0 - distance / effect_range) * strength))
    return safety
