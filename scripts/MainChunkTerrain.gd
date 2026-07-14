extends "res://scripts/MainInteractionFlow.gd"

const LocalLightRigScript := preload("res://scripts/LocalLightRig.gd")

func add_block_mesh(parent: Node3D, size: Vector3, offset: Vector3, material_key: String, rotation := Vector3.ZERO) -> MeshInstance3D:
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "BlockVisual_%s" % material_key
    mesh_instance.mesh = block_visual_mesh(material_key)
    mesh_instance.material_override = block_visual_material(material_key)
    mesh_instance.position = offset
    mesh_instance.rotation = rotation
    mesh_instance.scale = size
    mesh_instance.cast_shadow = block_shadow_policy(material_key)
    mesh_instance.set_meta("visual_role", "block")
    mesh_instance.set_meta("material_key", material_key)
    parent.add_child(mesh_instance)
    return mesh_instance

func block_shadow_policy(material_key: String) -> int:
    if material_key in ["glass", "flame", "furnaceGlow", "wardLantern", "sanctuaryBeacon", "riftAnchor", "copperOreGlow", "ironOreGlow"]:
        return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

func block_visual_material(material_key: String) -> Material:
    return materials.get(material_key, materials["stoneBlock"])

func block_visual_mesh(material_key: String) -> Mesh:
    var mesh_key := "plain" if material_key in ["glass", "flame", "furnaceGlow", "copperOreGlow", "ironOreGlow"] else "chamfered"
    if block_meshes.has(mesh_key):
        return block_meshes[mesh_key]
    var mesh: Mesh
    if mesh_key == "plain":
        var plain := BoxMesh.new()
        plain.size = Vector3.ONE
        mesh = plain
    else:
        mesh = make_chamfered_unit_block_mesh()
    block_meshes[mesh_key] = mesh
    return mesh

func make_chamfered_unit_block_mesh() -> ArrayMesh:
    var st := begin_block_surface()
    var o := 0.5
    var i := 0.42
    add_block_quad(st, Vector3(-i, -i, o), Vector3(i, -i, o), Vector3(i, i, o), Vector3(-i, i, o))
    add_block_quad(st, Vector3(i, -i, -o), Vector3(-i, -i, -o), Vector3(-i, i, -o), Vector3(i, i, -o))
    add_block_quad(st, Vector3(o, -i, i), Vector3(o, -i, -i), Vector3(o, i, -i), Vector3(o, i, i))
    add_block_quad(st, Vector3(-o, -i, -i), Vector3(-o, -i, i), Vector3(-o, i, i), Vector3(-o, i, -i))
    add_block_quad(st, Vector3(-i, o, i), Vector3(i, o, i), Vector3(i, o, -i), Vector3(-i, o, -i))
    add_block_quad(st, Vector3(-i, -o, -i), Vector3(i, -o, -i), Vector3(i, -o, i), Vector3(-i, -o, i))

    add_block_quad(st, Vector3(-i, i, o), Vector3(i, i, o), Vector3(i, o, i), Vector3(-i, o, i))
    add_block_quad(st, Vector3(i, -i, o), Vector3(-i, -i, o), Vector3(-i, -o, i), Vector3(i, -o, i))
    add_block_quad(st, Vector3(i, -i, o), Vector3(i, i, o), Vector3(o, i, i), Vector3(o, -i, i))
    add_block_quad(st, Vector3(-i, i, o), Vector3(-i, -i, o), Vector3(-o, -i, i), Vector3(-o, i, i))

    add_block_quad(st, Vector3(i, i, -o), Vector3(-i, i, -o), Vector3(-i, o, -i), Vector3(i, o, -i))
    add_block_quad(st, Vector3(-i, -i, -o), Vector3(i, -i, -o), Vector3(i, -o, -i), Vector3(-i, -o, -i))
    add_block_quad(st, Vector3(o, -i, -i), Vector3(o, i, -i), Vector3(i, i, -o), Vector3(i, -i, -o))
    add_block_quad(st, Vector3(-o, i, -i), Vector3(-o, -i, -i), Vector3(-i, -i, -o), Vector3(-i, i, -o))

    add_block_quad(st, Vector3(o, i, i), Vector3(o, i, -i), Vector3(i, o, -i), Vector3(i, o, i))
    add_block_quad(st, Vector3(-o, i, -i), Vector3(-o, i, i), Vector3(-i, o, i), Vector3(-i, o, -i))
    add_block_quad(st, Vector3(o, -i, -i), Vector3(o, -i, i), Vector3(i, -o, i), Vector3(i, -o, -i))
    add_block_quad(st, Vector3(-o, -i, i), Vector3(-o, -i, -i), Vector3(-i, -o, -i), Vector3(-i, -o, i))

    for sx in [-1.0, 1.0]:
        for sy in [-1.0, 1.0]:
            for sz in [-1.0, 1.0]:
                add_block_triangle(
                    st,
                    Vector3(sx * o, sy * i, sz * i),
                    Vector3(sx * i, sy * o, sz * i),
                    Vector3(sx * i, sy * i, sz * o)
                )
    st.generate_normals()
    return st.commit()

func begin_block_surface(material: Material = null) -> SurfaceTool:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    if material != null:
        st.set_material(material)
    return st

func add_block_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
    st.add_vertex(a)
    st.add_vertex(b)
    st.add_vertex(c)

func add_block_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
    add_block_triangle(st, a, b, c)
    add_block_triangle(st, a, c, d)

func tag_visual(node: MeshInstance3D, role: String, visual_name: String = "") -> MeshInstance3D:
    if node == null:
        return node
    if visual_name != "":
        node.name = visual_name
    node.set_meta("visual_role", role)
    return node

func ground_light_offset() -> Vector3:
    return Vector3(0.0, CELL * 0.36, 0.0)

func add_world_light_rig(parent: Node3D, profile_id: String) -> Dictionary:
    return LocalLightRigScript.add_rig(parent, profile_id, {
        "context": "placed",
        "scale": CELL,
        "terrain_position": ground_light_offset(),
        "shadows": shadows_enabled
    })

func terrain_block_light_level(block_type: String) -> int:
    match block_type:
        "campfire":
            return 15
        "sanctuaryBeacon":
            return 15
        "riftAnchor":
            return 14
        "wardLantern":
            return 13
        "torch":
            return 12
        _:
            return 0

func sync_block_light_to_terrain(cell: Vector3i, block_type: String) -> void:
    var level := terrain_block_light_level(block_type)
    if level <= 0:
        return
    if world_generation_system != null and world_generation_system.has_method("set_cell_light"):
        world_generation_system.call("set_cell_light", cell, { "sky": 0, "block": level }, "block_light:%s" % block_type)

func sync_block_lights_to_terrain(entries: Array, reason := "block_light_batch") -> Dictionary:
    if world_generation_system == null:
        return {}
    var changes := block_light_changes_for_entries(entries)
    if changes.is_empty():
        return { "changedCount": 0, "sourceCount": 0 }
    if world_generation_system.has_method("set_cell_lights_batch"):
        var result: Variant = world_generation_system.call("set_cell_lights_batch", changes, reason)
        return result if result is Dictionary else {}
    for change in changes:
        world_generation_system.call("set_cell_light", change.get("cell", Vector3i.ZERO), change.get("light", {}), reason)
    return { "changedCount": changes.size() }

func sync_block_lights_to_terrain_staged(entries: Array, reason := "block_light_batch", frame_budget_ms := 2.0, max_work_units := 192) -> Dictionary:
    if world_generation_system == null:
        return {}
    var changes := block_light_changes_for_entries(entries)
    if changes.is_empty():
        return { "changedCount": 0, "sourceCount": 0, "complete": true, "frames": 0, "maxStepMs": 0.0 }
    if not world_generation_system.has_method("begin_cell_lights_batch") or not world_generation_system.has_method("advance_cell_lights_batch"):
        return sync_block_lights_to_terrain(entries, reason)
    var state_value: Variant = world_generation_system.call("begin_cell_lights_batch", changes, reason)
    if not (state_value is Dictionary):
        return sync_block_lights_to_terrain(entries, reason)
    var state: Dictionary = state_value
    var started_usec := Time.get_ticks_usec()
    var frames := 0
    var max_step_ms := 0.0
    var processed_work_units := 0
    while not bool(state.get("complete", false)):
        var advanced_value: Variant = world_generation_system.call("advance_cell_lights_batch", state, frame_budget_ms, max_work_units)
        if not (advanced_value is Dictionary):
            return sync_block_lights_to_terrain(entries, reason)
        var advanced: Dictionary = advanced_value
        var next_state_value: Variant = advanced.get("state", state)
        if not (next_state_value is Dictionary):
            return sync_block_lights_to_terrain(entries, reason)
        state = next_state_value
        frames += 1
        max_step_ms = maxf(max_step_ms, float(advanced.get("elapsedMs", 0.0)))
        processed_work_units += int(advanced.get("processedWorkUnits", 0))
        if not bool(state.get("complete", false)):
            await get_tree().process_frame
    return {
        "changedCount": int(state.get("changedCount", 0)),
        "sourceCount": int(state.get("sourceCount", 0)),
        "clearedCount": int(state.get("clearedCount", 0)),
        "propagatedSourceCount": int(state.get("propagatedSourceCount", 0)),
        "dirtySectionCount": int(state.get("dirtySectionCount", 0)),
        "lightWriteCount": int(state.get("lightWriteCount", 0)),
        "complete": bool(state.get("complete", false)),
        "frames": frames,
        "maxStepMs": max_step_ms,
        "processedWorkUnits": processed_work_units,
        "elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
    }

func block_light_changes_for_entries(entries: Array) -> Array[Dictionary]:
    var changes: Array[Dictionary] = []
    var seen_cells := {}
    for entry_value in entries:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var cell_value: Variant = entry.get("cell", Vector3i.ZERO)
        if not (cell_value is Vector3i):
            continue
        var cell: Vector3i = cell_value
        if seen_cells.has(cell):
            continue
        var block_type := String(entry.get("blockType", ""))
        var level := terrain_block_light_level(block_type)
        if level <= 0:
            continue
        seen_cells[cell] = true
        changes.append({
            "cell": cell,
            "light": { "sky": 0, "block": level }
        })
    if changes.is_empty():
        return changes
    return changes

func clear_block_light_from_terrain(cell: Vector3i, block_type: String, reason := "block_removed") -> void:
    if terrain_block_light_level(block_type) <= 0:
        return
    if world_generation_system != null and world_generation_system.has_method("set_cell_light"):
        world_generation_system.call("set_cell_light", cell, { "sky": 0, "block": 0 }, "%s:%s" % [reason, block_type])

func block_solid_for_terrain_state(block_type: String) -> bool:
    return not (block_type in ["cobblestonePath", "torch", "campfire"])

func sync_block_state_to_terrain(cell: Vector3i, block_type: String, options: Dictionary = {}) -> void:
    if world_generation_system == null or not world_generation_system.has_method("set_cell_state"):
        return
    var solid := block_solid_for_terrain_state(block_type)
    var metadata := {
        "source": "scene_block",
        "blockType": block_type,
        "renderedBySceneBlock": true,
        "terrainMeshAffects": false,
        "saveDelta": bool(options.get("player_placed", false)),
        "generated": bool(options.get("generated", false)),
        "playerPlaced": bool(options.get("player_placed", false))
    }
    var inherited_biome := surface_biome_at_cell(Vector3i(cell.x, 0, cell.z))
    var inherited_light := { "sky": 0 if solid else 15, "block": terrain_block_light_level(block_type) }
    if world_generation_system.has_method("get_cell_state"):
        var previous: Dictionary = world_generation_system.call("get_cell_state", cell)
        var previous_metadata: Dictionary = previous.get("metadata", {}) if previous.get("metadata", {}) is Dictionary else {}
        inherited_biome = String(previous.get("biome", inherited_biome))
        var previous_light: Dictionary = previous.get("light", {}) if previous.get("light", {}) is Dictionary else {}
        inherited_light = {
            "sky": int(previous_light.get("sky", inherited_light.get("sky", 0))),
            "block": terrain_block_light_level(block_type)
        }
        if bool(previous.get("edited", false)) and String(previous_metadata.get("source", "")) != "scene_block":
            metadata["replacedState"] = previous.duplicate(true)
    world_generation_system.call("set_cell_state", cell, {
        "blockId": block_type,
        "material": block_type,
        "biome": inherited_biome,
        "solid": solid,
        "density": CELL if solid else -CELL,
        "fluid": "",
        "light": inherited_light,
        "metadata": metadata
    }, "scene_block_created:%s" % block_type)

func clear_block_state_from_terrain(cell: Vector3i, block_type: String, reason := "block_removed") -> void:
    if world_generation_system == null:
        return
    if not world_generation_system.has_method("get_cell_state"):
        return
    var state: Dictionary = world_generation_system.call("get_cell_state", cell)
    var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
    if String(metadata.get("source", "")) != "scene_block":
        return
    var replaced_value = metadata.get("replacedState", {})
    var replaced_state: Dictionary = replaced_value if replaced_value is Dictionary else {}
    if not replaced_state.is_empty() and world_generation_system.has_method("set_cell_state"):
        world_generation_system.call("set_cell_state", cell, replaced_state, "%s_restore:%s" % [reason, block_type])
        return
    if world_generation_system.has_method("clear_cell_state"):
        world_generation_system.call("clear_cell_state", cell, "%s:%s" % [reason, block_type])
        return
    if world_generation_system.has_method("set_cell_state"):
        world_generation_system.call("set_cell_state", cell, {
            "material": "air",
            "biome": "underground_air",
            "solid": false,
            "density": -CELL,
            "fluid": "",
            "light": { "sky": 15, "block": 0 },
            "metadata": { "source": "scene_block_removed", "terrainMeshAffects": false }
        }, "%s:%s" % [reason, block_type])

func apply_local_light_shadows(root: Node = null) -> void:
    if root != null:
        apply_local_light_shadows_recursive(root)
        return
    for scene_root in [block_root, prop_root, player, tutorial_system]:
        apply_local_light_shadows_recursive(scene_root)

func apply_local_light_shadows_recursive(node: Node) -> void:
    if node == null:
        return
    if node is Light3D and bool(node.get_meta("casts_shadow_when_enabled", false)):
        (node as Light3D).shadow_enabled = shadows_enabled
    for child in node.get_children():
        apply_local_light_shadows_recursive(child)

func add_generated_static_utility_visual(parent: Node3D, item_id: String, scale_value := CELL) -> Node3D:
    if static_item_asset_registry == null:
        return null
    if not static_item_asset_registry.has_method("has_asset") or not static_item_asset_registry.has_asset(item_id):
        return null
    var visual: Node3D = static_item_asset_registry.instantiate_item(item_id)
    if visual == null:
        return null
    visual.name = "GeneratedStaticUtility_%s" % item_id
    visual.scale = Vector3.ONE * scale_value
    visual.set_meta("visual_role", "generatedStaticUtility")
    parent.add_child(visual)
    return visual

func add_cached_mesh_visual(parent: Node3D, mesh_key: String, material_key: String, size: Vector3, offset: Vector3, rotation := Vector3.ZERO, role := "block", visual_name := "") -> MeshInstance3D:
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = visual_name if visual_name != "" else "Visual_%s" % mesh_key
    mesh_instance.mesh = cached_visual_mesh(mesh_key)
    mesh_instance.material_override = block_visual_material(material_key)
    mesh_instance.position = offset
    mesh_instance.rotation = rotation
    mesh_instance.scale = size
    mesh_instance.set_meta("visual_role", role)
    mesh_instance.set_meta("material_key", material_key)
    parent.add_child(mesh_instance)
    return mesh_instance

func cached_visual_mesh(mesh_key: String) -> Mesh:
    var key := "visual_%s" % mesh_key
    if block_meshes.has(key):
        return block_meshes[key]
    var plain := BoxMesh.new()
    plain.size = Vector3.ONE
    var mesh: Mesh = plain
    block_meshes[key] = mesh
    return mesh

func add_roof_block_visual(parent: Node3D, block_type: String, options: Dictionary) -> void:
    var role := String(options.get("roofRole", "slope"))
    var axis := String(options.get("roofAxis", "x"))
    var material_key := String(options.get("roofMaterial", "roofStone" if block_type == "stoneBlock" else "roofWood"))
    var trim_key := String(options.get("roofTrimMaterial", "trimStone" if block_type == "stoneBlock" else "trimWood"))
    var rotation := Vector3.ZERO
    tag_visual(add_block_mesh(parent, Vector3(CELL * 1.02, CELL * 0.22, CELL * 1.02), Vector3(0.0, -CELL * 0.30, 0.0), material_key), "roof", "RoofVisual_%s" % role)
    if role == "ridge":
        var ridge_size := Vector3(CELL * 1.16, CELL * 0.18, CELL * 0.30) if axis == "x" else Vector3(CELL * 0.30, CELL * 0.18, CELL * 1.16)
        add_cached_mesh_visual(parent, "roof_ridge_bar", material_key, ridge_size, Vector3(0.0, -CELL * 0.10, 0.0), rotation, "roof", "RoofRidgeCapVisual")
    add_roof_edge_trim(parent, options, trim_key)
    if String(options.get("roofAccent", "")) == "chimney":
        add_chimney_visual(parent, trim_key)

func add_roof_edge_trim(parent: Node3D, options: Dictionary, trim_key: String) -> void:
    var edge_x := int(options.get("roofEdgeX", 0))
    var edge_z := int(options.get("roofEdgeZ", 0))
    if edge_x != 0:
        tag_visual(add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.18, CELL * 1.18), Vector3(float(edge_x) * CELL * 0.57, -CELL * 0.22, 0.0), trim_key), "roofTrim", "RoofEaveTrimX")
    if edge_z != 0:
        tag_visual(add_block_mesh(parent, Vector3(CELL * 1.18, CELL * 0.18, CELL * 0.08), Vector3(0.0, -CELL * 0.22, float(edge_z) * CELL * 0.57), trim_key), "roofTrim", "RoofEaveTrimZ")

func add_chimney_visual(parent: Node3D, material_key: String) -> void:
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.90, CELL * 0.34), Vector3(CELL * 0.18, CELL * 0.45, CELL * 0.12), material_key), "chimney", "ChimneyVisual")
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.46, CELL * 0.14, CELL * 0.46), Vector3(CELL * 0.18, CELL * 0.96, CELL * 0.12), material_key), "chimney", "ChimneyCapVisual")

func add_window_frame_visual(parent: Node3D, options: Dictionary) -> void:
    var axis := String(options.get("windowAxis", "z"))
    var side := float(int(options.get("windowSide", 1)))
    var trim_key := String(options.get("windowTrimMaterial", "trimWood"))
    var face_offset := CELL * 0.515 * side
    if axis == "x":
        for z_offset in [-0.36, 0.36]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 0.055, CELL * 0.88, CELL * 0.065), Vector3(face_offset, 0.0, float(z_offset) * CELL), trim_key), "windowFrame", "WindowFramePost")
        for y_offset in [-0.42, 0.42]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 0.06, CELL * 0.06, CELL * 0.86), Vector3(face_offset, float(y_offset) * CELL, 0.0), trim_key), "windowFrame", "WindowFrameRail")
    else:
        for x_offset in [-0.36, 0.36]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 0.065, CELL * 0.88, CELL * 0.055), Vector3(float(x_offset) * CELL, 0.0, face_offset), trim_key), "windowFrame", "WindowFramePost")
        for y_offset in [-0.42, 0.42]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 0.86, CELL * 0.06, CELL * 0.06), Vector3(0.0, float(y_offset) * CELL, face_offset), trim_key), "windowFrame", "WindowFrameRail")

func add_corner_timber_visual(parent: Node3D, options: Dictionary) -> void:
    var sx := float(int(options.get("cornerX", 1)))
    var sz := float(int(options.get("cornerZ", 1)))
    var trim_key := String(options.get("cornerTrimMaterial", "trimWood"))
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 1.04, CELL * 0.16), Vector3(sx * CELL * 0.50, 0.0, sz * CELL * 0.43), trim_key), "cornerTimber", "CornerTimberX")
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.16, CELL * 1.04, CELL * 0.10), Vector3(sx * CELL * 0.43, 0.0, sz * CELL * 0.50), trim_key), "cornerTimber", "CornerTimberZ")

func add_door_frame_visual(parent: Node3D, options: Dictionary) -> void:
    var trim_key := String(options.get("doorTrimMaterial", "trimWood"))
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 1.86, CELL * 0.18), Vector3(-CELL * 0.55, CELL * 0.42, 0.0), trim_key), "doorFrame", "DoorFrameLeft")
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 1.86, CELL * 0.18), Vector3(CELL * 0.55, CELL * 0.42, 0.0), trim_key), "doorFrame", "DoorFrameRight")
    tag_visual(add_block_mesh(parent, Vector3(CELL * 1.20, CELL * 0.12, CELL * 0.20), Vector3(0.0, CELL * 1.34, 0.0), trim_key), "doorFrame", "DoorFrameLintel")
    if not bool(options.get("secondary", false)):
        tag_visual(add_block_mesh(parent, Vector3(CELL * 0.54, CELL * 0.22, CELL * 0.06), Vector3(0.0, CELL * 1.56, -CELL * 0.13), trim_key), "sign", "DoorSignVisual")

func add_fence_accent_visual(parent: Node3D, options: Dictionary) -> void:
    var axis := String(options.get("fenceAxis", "x"))
    var trim_key := String(options.get("fenceTrimMaterial", "trimWood"))
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 1.08, CELL * 0.18), Vector3.ZERO, trim_key), "fencePost", "FencePostVisual")
    if axis == "z":
        for y_offset in [0.18, -0.18]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 0.14, CELL * 0.12, CELL * 1.04), Vector3(0.0, float(y_offset) * CELL, 0.0), trim_key), "fenceRail", "FenceRailVisual")
    else:
        for y_offset in [0.18, -0.18]:
            tag_visual(add_block_mesh(parent, Vector3(CELL * 1.04, CELL * 0.12, CELL * 0.14), Vector3(0.0, float(y_offset) * CELL, 0.0), trim_key), "fenceRail", "FenceRailVisual")

func add_block_accent_visuals(parent: Node3D, block_type: String, options: Dictionary) -> void:
    var accent := String(options.get("accentRole", ""))
    if accent == "windowFrame" and block_type == "glass":
        add_window_frame_visual(parent, options)
    elif accent == "cornerTimber":
        add_corner_timber_visual(parent, options)
    elif accent == "doorFrame" and block_type == "door":
        add_door_frame_visual(parent, options)
    elif accent == "fencePost":
        add_fence_accent_visual(parent, options)

func add_workbench_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "workbench") != null:
        return
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
    if add_generated_static_utility_visual(parent, "chest") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 0.98, CELL * 0.46, CELL * 0.72), Vector3(0.0, -CELL * 0.20, 0.0), "chest")
    add_block_mesh(parent, Vector3(CELL * 1.02, CELL * 0.18, CELL * 0.76), Vector3(0.0, CELL * 0.12, 0.0), "chest")
    add_block_mesh(parent, Vector3(CELL * 1.06, CELL * 0.08, CELL * 0.80), Vector3(0.0, CELL * 0.24, 0.0), "door")
    for x_offset in [-0.36, 0.36]:
        add_block_mesh(parent, Vector3(CELL * 0.075, CELL * 0.66, CELL * 0.80), Vector3(float(x_offset) * CELL, -CELL * 0.02, 0.0), "chestBand")
    add_block_mesh(parent, Vector3(CELL * 1.08, CELL * 0.055, CELL * 0.055), Vector3(0.0, CELL * 0.03, -CELL * 0.41), "chestBand")
    add_block_mesh(parent, Vector3(CELL * 0.17, CELL * 0.14, CELL * 0.045), Vector3(0.0, -CELL * 0.03, -CELL * 0.44), "hingeMetal")

func add_bed_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "bed") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 1.18, CELL * 0.12, CELL * 0.78), Vector3(0.0, -CELL * 0.35, 0.0), "door")
    for x_offset in [-0.48, 0.48]:
        for z_offset in [-0.30, 0.30]:
            add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.34, CELL * 0.08), Vector3(float(x_offset) * CELL, -CELL * 0.49, float(z_offset) * CELL), "door")
    add_block_mesh(parent, Vector3(CELL * 1.10, CELL * 0.18, CELL * 0.72), Vector3(CELL * 0.02, -CELL * 0.21, 0.0), "bedPillow")
    add_block_mesh(parent, Vector3(CELL * 0.74, CELL * 0.20, CELL * 0.74), Vector3(CELL * 0.18, -CELL * 0.12, 0.0), "bedBlanket")
    add_block_mesh(parent, Vector3(CELL * 0.16, CELL * 0.56, CELL * 0.82), Vector3(-CELL * 0.57, -CELL * 0.18, 0.0), "door")

func add_anvil_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "anvil") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 0.52, CELL * 0.18, CELL * 0.52), Vector3(0.0, -CELL * 0.41, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.38, CELL * 0.34, CELL * 0.38), Vector3(0.0, -CELL * 0.17, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.92, CELL * 0.20, CELL * 0.44), Vector3(0.0, CELL * 0.06, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.32, CELL * 0.16, CELL * 0.38), Vector3(CELL * 0.46, CELL * 0.02, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.22, CELL * 0.13, CELL * 0.34), Vector3(-CELL * 0.58, CELL * 0.00, 0.0), "anvil", Vector3(0.0, 0.0, 0.20))
    add_block_mesh(parent, Vector3(CELL * 0.26, CELL * 0.05, CELL * 0.32), Vector3(0.0, CELL * 0.20, 0.0), "hingeMetal")

func add_furnace_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "furnace") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 0.94, CELL * 0.82, CELL * 0.78), Vector3(0.0, -CELL * 0.06, 0.0), "furnace")
    add_block_mesh(parent, Vector3(CELL * 1.02, CELL * 0.12, CELL * 0.84), Vector3(0.0, CELL * 0.42, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.54, CELL * 0.34, CELL * 0.045), Vector3(0.0, -CELL * 0.09, -CELL * 0.42), "furnaceMouth")
    add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.10, CELL * 0.052), Vector3(0.0, -CELL * 0.14, -CELL * 0.45), "furnaceGlow")
    add_block_mesh(parent, Vector3(CELL * 0.52, CELL * 0.06, CELL * 0.05), Vector3(0.0, CELL * 0.14, -CELL * 0.43), "hingeMetal")
    add_block_mesh(parent, Vector3(CELL * 0.72, CELL * 0.10, CELL * 0.84), Vector3(0.0, -CELL * 0.51, 0.0), "stoneBlock")

func add_campfire_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "campfire") != null:
        add_world_light_rig(parent, "campfire")
        return
    add_block_mesh(parent, Vector3(CELL * 0.82, CELL * 0.08, CELL * 0.22), Vector3(0.0, -CELL * 0.38, 0.0), "trunk", Vector3(0.0, 0.72, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.82, CELL * 0.08, CELL * 0.22), Vector3(0.0, -CELL * 0.34, 0.0), "trunk", Vector3(0.0, -0.72, 0.0))
    for x_offset in [-0.34, 0.34]:
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.14, CELL * 0.18), Vector3(float(x_offset) * CELL, -CELL * 0.40, CELL * 0.30), "stoneBlock")
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.14, CELL * 0.18), Vector3(float(x_offset) * CELL, -CELL * 0.40, -CELL * 0.30), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.20, CELL * 0.50, CELL * 0.20), Vector3(0.0, -CELL * 0.08, 0.0), "flame", Vector3(0.0, 0.78, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.15, CELL * 0.38, CELL * 0.15), Vector3(0.0, -CELL * 0.03, 0.0), "furnaceGlow", Vector3(0.0, -0.78, 0.0))
    add_world_light_rig(parent, "campfire")

func add_torch_visual(parent: Node3D, visual_scale := 1.0, options: Dictionary = {}) -> void:
    visual_scale = clampf(float(visual_scale), 0.25, 1.5)
    if bool(options.get("torchWallMount", false)):
        add_wall_torch_visual(parent, visual_scale)
        add_wall_torch_light_rig(parent, visual_scale)
        return
    if add_generated_static_utility_visual(parent, "torch", CELL * visual_scale) != null:
        add_world_light_rig(parent, "torch")
        return
    add_block_mesh(parent, Vector3(CELL * 0.10, CELL * 0.78, CELL * 0.10) * visual_scale, Vector3(0.0, -CELL * 0.04 * visual_scale, 0.0), "trunk")
    add_block_mesh(parent, Vector3(CELL * 0.22, CELL * 0.12, CELL * 0.22) * visual_scale, Vector3(0.0, CELL * 0.38 * visual_scale, 0.0), "torch")
    add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.24, CELL * 0.18) * visual_scale, Vector3(0.0, CELL * 0.56 * visual_scale, 0.0), "flame")
    add_world_light_rig(parent, "torch")

func add_wall_torch_light_rig(parent: Node3D, visual_scale := 1.0) -> Dictionary:
    var s := clampf(float(visual_scale), 0.25, 0.75)
    var flame_position := Vector3(0.0, CELL * 0.52 * s, -CELL * 0.32 * s)
    return LocalLightRigScript.add_rig(parent, "torch", {
        "context": "placed",
        "scale": CELL,
        "source_position": flame_position,
        "terrain_position": flame_position + Vector3(0.0, -CELL * 0.22, -CELL * 0.06),
        "bounce_position": flame_position + Vector3(0.0, CELL * 0.24, -CELL * 0.03),
        "source_energy": 6.60,
        "source_range": 11.75,
        "terrain_energy": 2.85,
        "terrain_range": 8.90,
        "bounce_energy": 1.35,
        "bounce_range": 10.10,
        "shadows": shadows_enabled
    })

func add_wall_torch_visual(parent: Node3D, visual_scale := 1.0) -> void:
    var s := clampf(float(visual_scale), 0.25, 0.75)
    var plate := add_block_mesh(parent, Vector3(CELL * 0.24, CELL * 0.58, CELL * 0.20) * s, Vector3(0.0, CELL * 0.42 * s, CELL * 0.02 * s), "trunk")
    plate.name = "WallTorchBackplate"
    plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var bracket := add_block_mesh(parent, Vector3(CELL * 0.14, CELL * 0.12, CELL * 0.34) * s, Vector3(0.0, CELL * 0.41 * s, -CELL * 0.15 * s), "hingeMetal")
    bracket.name = "WallTorchBracket"
    bracket.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var body := add_block_mesh(parent, Vector3(CELL * 0.24, CELL * 0.30, CELL * 0.24) * s, Vector3(0.0, CELL * 0.52 * s, -CELL * 0.32 * s), "furnaceGlow")
    body.name = "WallTorchGlow"

func add_spike_trap_visual(parent: Node3D) -> void:
    if add_generated_static_utility_visual(parent, "spikeTrap") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 0.86, CELL * 0.10, CELL * 0.86), Vector3(0.0, -CELL * 0.44, 0.0), "spikeTrap")
    for x_offset in [-0.24, 0.0, 0.24]:
        for z_offset in [-0.24, 0.0, 0.24]:
            add_block_mesh(parent, Vector3(CELL * 0.08, CELL * 0.34, CELL * 0.08), Vector3(float(x_offset) * CELL, -CELL * 0.24, float(z_offset) * CELL), "anvil", Vector3(0.35, 0.0, 0.35))

func add_ward_object_visual(parent: Node3D, block_type: String) -> void:
    if add_generated_static_utility_visual(parent, block_type) != null:
        add_world_light_rig(parent, block_type)
        return
    var glow_key := "sanctuaryBeacon" if block_type == "sanctuaryBeacon" else ("riftAnchor" if block_type == "riftAnchor" else "wardLantern")
    add_block_mesh(parent, Vector3(CELL * 0.44, CELL * 0.16, CELL * 0.44), Vector3(0.0, -CELL * 0.43, 0.0), "stoneBlock")
    add_block_mesh(parent, Vector3(CELL * 0.12, CELL * 0.70, CELL * 0.12), Vector3(0.0, -CELL * 0.08, 0.0), "anvil")
    add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.34, CELL * 0.34), Vector3(0.0, CELL * 0.34, 0.0), glow_key, Vector3(0.0, 0.78, 0.0))
    add_block_mesh(parent, Vector3(CELL * 0.50, CELL * 0.045, CELL * 0.50), Vector3(0.0, CELL * 0.56, 0.0), "hingeMetal")
    if block_type == "riftAnchor":
        add_world_light_rig(parent, "riftAnchor")
    elif block_type == "sanctuaryBeacon":
        add_world_light_rig(parent, "sanctuaryBeacon")
    else:
        add_world_light_rig(parent, "wardLantern")

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
    if add_generated_static_utility_visual(parent, "traderStall") != null:
        return
    add_block_mesh(parent, Vector3(CELL * 1.08, CELL * 0.32, CELL * 0.64), Vector3(0.0, -CELL * 0.34, 0.0), "traderStall")
    for x_offset in [-0.45, 0.45]:
        for z_offset in [-0.30, 0.30]:
            add_block_mesh(parent, Vector3(CELL * 0.07, CELL * 1.05, CELL * 0.07), Vector3(float(x_offset) * CELL, CELL * 0.06, float(z_offset) * CELL), "traderStall")
    add_block_mesh(parent, Vector3(CELL * 1.24, CELL * 0.12, CELL * 0.86), Vector3(0.0, CELL * 0.62, 0.0), "traderCloth")
    for i in range(-2, 3):
        var material_key := "traderClothLight" if i % 2 == 0 else "traderCloth"
        add_block_mesh(parent, Vector3(CELL * 0.18, CELL * 0.16, CELL * 0.05), Vector3(float(i) * CELL * 0.20, CELL * 0.50, CELL * 0.45), material_key)
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.34, CELL * 0.26, CELL * 0.34), Vector3(-CELL * 0.42, -CELL * 0.02, -CELL * 0.50), "woodBlock"), "crate", "TraderCrateVisual")
    tag_visual(add_block_mesh(parent, Vector3(CELL * 0.26, CELL * 0.42, CELL * 0.26), Vector3(CELL * 0.44, -CELL * 0.03, -CELL * 0.48), "door"), "barrel", "TraderBarrelVisual")

func door_side_from_facing(facing: float) -> int:
    if absf(sin(facing)) > absf(cos(facing)):
        return 1 if sin(facing) > 0.0 else 3
    return 0 if cos(facing) >= 0.0 else 2

func door_facing_from_side(side: int) -> float:
    if side == 1:
        return PI * 0.5
    if side == 3:
        return -PI * 0.5
    if side == 2:
        return PI
    return 0.0

func infer_door_side_from_neighbors(cell: Vector3i, fallback_side: int) -> int:
    var x_axis_neighbors := 0
    var z_axis_neighbors := 0
    for offset in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0)]:
        if is_door_wall_neighbor(cell + offset):
            x_axis_neighbors += 1
    for offset in [Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
        if is_door_wall_neighbor(cell + offset):
            z_axis_neighbors += 1
    if z_axis_neighbors > x_axis_neighbors:
        return 1
    if x_axis_neighbors > z_axis_neighbors:
        return 0
    return fallback_side

func is_door_wall_neighbor(cell: Vector3i) -> bool:
    var neighbor = blocks.get(cell)
    if not (neighbor is Node):
        return false
    var neighbor_type := String((neighbor as Node).get_meta("block_type", ""))
    return neighbor_type in ["woodBlock", "stoneBlock", "glass", "door"]

func door_primary_cell(cell: Vector3i, side: int, secondary: bool) -> Vector3i:
    if not secondary:
        return cell
    if side == 0 or side == 2:
        return Vector3i(cell.x - 1, cell.y, cell.z)
    if side == 1 or side == 3:
        return Vector3i(cell.x, cell.y, cell.z - 1)
    return cell

func door_group_id_for_cell(cell: Vector3i, side: int, secondary: bool) -> String:
    var primary := door_primary_cell(cell, side, secondary)
    return "door-group:%d,%d,%d:%d" % [primary.x, primary.y, primary.z, side]

func door_portal_id_for_cell(cell: Vector3i, side: int, secondary: bool) -> String:
    return "door:%s" % door_group_id_for_cell(cell, side, secondary)

func create_block(cell: Vector3i, block_type: String, options: Dictionary = {}) -> StaticBody3D:
    if blocks.has(cell):
        return blocks[cell]
    var instrumentation_metrics: Dictionary = options.get("instrumentationMetrics", {}) if options.get("instrumentationMetrics", {}) is Dictionary else {}
    var instrumentation_prefix := String(options.get("instrumentationMetricPrefix", ""))
    var node_build_started_usec := Time.get_ticks_usec()
    var body := StaticBody3D.new()
    body.name = "Block_%s_%d_%d_%d" % [block_type, cell.x, cell.y, cell.z]
    var world_y := float(options.get("world_y", cell.y * CELL))
    var world_x := float(options.get("world_x", cell.x * CELL))
    var world_z := float(options.get("world_z", cell.z * CELL))
    body.position = Vector3(world_x, world_y, world_z)
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
    if options.has("structureDy"):
        body.set_meta("structureDy", int(options.get("structureDy", 0)))
    if options.has("structureLevel"):
        body.set_meta("structureLevel", float(options.get("structureLevel", world_y)))
    if options.has("storageSlots"):
        body.set_meta("storage_slots", options.get("storageSlots", []))
    for visual_key in [
        "roofRole",
        "roofAxis",
        "roofSide",
        "roofMaterial",
        "roofTrimMaterial",
        "roofEdgeX",
        "roofEdgeZ",
        "roofAccent",
        "accentRole",
        "windowAxis",
        "windowSide",
        "cornerX",
        "cornerZ",
        "fenceAxis",
        "torchVisualScale",
        "torchWallMount",
        "torchWallNormalX",
        "torchWallNormalZ",
        "torchWallSurfaceX",
        "torchWallSurfaceZ",
        "torchWallNormalWorldX",
        "torchWallNormalWorldZ",
        "torchWallAnchorCellX",
        "torchWallAnchorCellZ"
    ]:
        if options.has(visual_key):
            body.set_meta(visual_key, options.get(visual_key))

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
        var secondary := bool(options.get("secondary", false))
        var side := int(options.get("doorSide", infer_door_side_from_neighbors(cell, door_side_from_facing(body.rotation.y))))
        if not options.has("facing"):
            body.rotation.y = door_facing_from_side(side)
        var group_id := String(options.get("doorGroupId", ""))
        if group_id == "":
            group_id = door_group_id_for_cell(cell, side, secondary)
        var portal_id := String(options.get("doorPortalId", ""))
        if portal_id == "":
            portal_id = "door:%s" % group_id
        body.set_meta("open", bool(options.get("open", false)))
        body.set_meta("closed_rotation", body.rotation.y)
        body.set_meta("secondary", secondary)
        body.set_meta("door_leaf_index", int(options.get("doorLeafIndex", 1 if secondary else 0)))
        body.set_meta("door_side", side)
        body.set_meta("door_group_id", group_id)
        body.set_meta("door_portal_id", portal_id)
        body.set_meta("door_building_id", String(options.get("doorBuildingId", "")))
        body.set_meta("door_public_access", bool(options.get("doorPublicAccess", true)))
        body.set_meta("door_policy", String(options.get("doorPolicy", "private_home")))
        body.set_meta("locked", bool(options.get("locked", false)))
        body.set_meta("jammed", bool(options.get("jammed", false)))
        body.set_meta("destroyed", bool(options.get("destroyed", false)))
        body.set_meta("unloaded", bool(options.get("unloaded", false)))
        var swing := 1.0 if secondary else -1.0
        body.set_meta("open_swing", swing * PI * 0.5)
        body.set_meta("open_rotation", body.rotation.y)
    elif block_type == "torch":
        var torch_visual_scale := clampf(float(options.get("torchVisualScale", 1.0)), 0.25, 1.5)
        mesh_size = Vector3(CELL * 0.18, CELL * 0.82, CELL * 0.18) * torch_visual_scale
        mesh_offset.y = CELL * 0.10 * torch_visual_scale
        if bool(options.get("torchWallMount", false)):
            var wall_normal := Vector2i(int(options.get("torchWallNormalX", 0)), int(options.get("torchWallNormalZ", 0)))
            if wall_normal != Vector2i.ZERO and not options.has("facing"):
                body.rotation.y = yaw_for_cell_direction(wall_normal)
            mesh_size = Vector3(CELL * 0.30, CELL * 0.74, CELL * 0.30) * torch_visual_scale
            mesh_offset.y = CELL * 0.38
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

    if options.has("roofRole") and (block_type == "woodBlock" or block_type == "stoneBlock"):
        add_roof_block_visual(body, block_type, options)
    elif block_type == "workbench":
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
        add_torch_visual(body, float(options.get("torchVisualScale", 1.0)), options)
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
    add_block_accent_visuals(body, block_type, options)

    var shape := BoxShape3D.new()
    shape.size = collider_size
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position = collider_offset
    body.add_child(collider)
    if block_type == "door":
        add_door_interaction_proxy(body, collider_size, collider_offset)
    elif block_type == "cobblestonePath" or block_type == "torch":
        body.collision_layer = NpcConstantsScript.COLLISION_NONBLOCKING_PATH

    block_root.add_child(body)
    blocks[cell] = body
    record_block_creation_instrumentation(instrumentation_metrics, instrumentation_prefix, "NodeBuild", node_build_started_usec)
    var terrain_state_started_usec := Time.get_ticks_usec()
    sync_block_state_to_terrain(cell, block_type, options)
    record_block_creation_instrumentation(instrumentation_metrics, instrumentation_prefix, "TerrainState", terrain_state_started_usec)
    var terrain_light_started_usec := Time.get_ticks_usec()
    if not bool(options.get("deferBlockLightSync", false)):
        sync_block_light_to_terrain(cell, block_type)
    record_block_creation_instrumentation(instrumentation_metrics, instrumentation_prefix, "TerrainLight", terrain_light_started_usec)
    var marker_cache_started_usec := Time.get_ticks_usec()
    invalidate_navigation_marker_cache()
    record_block_creation_instrumentation(instrumentation_metrics, instrumentation_prefix, "NavigationMarkerCache", marker_cache_started_usec)
    if bool(options.get("player_placed", false)):
        mark_world_dirty("block_created")
    if npc_system and npc_system.has_method("notify_navigation_block_created"):
        var navigation_notify_started_usec := Time.get_ticks_usec()
        npc_system.notify_navigation_block_created(cell, block_type, body)
        record_block_creation_instrumentation(instrumentation_metrics, instrumentation_prefix, "NavigationNotify", navigation_notify_started_usec)
    if block_type == "door" and npc_system and npc_system.has_method("notify_navigation_door_registered"):
        npc_system.notify_navigation_door_registered(body)
    return body

func record_block_creation_instrumentation(metrics: Dictionary, prefix: String, phase: String, started_usec: int) -> void:
    if metrics.is_empty() or prefix == "" or phase == "":
        return
    var metric_key := "%s%sMs" % [prefix, phase]
    metrics[metric_key] = float(metrics.get(metric_key, 0.0)) + float(Time.get_ticks_usec() - started_usec) / 1000.0

func yaw_for_cell_direction(direction: Vector2i) -> float:
    if direction == Vector2i.ZERO:
        return 0.0
    return atan2(-float(direction.x), -float(direction.y))

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
    var ground := surface_y_at_position(block.global_position)
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
        var block_cell: Vector3i = block.get_meta("cell")
        if npc_system and npc_system.has_method("notify_navigation_block_removed"):
            npc_system.notify_navigation_block_removed(block_cell, block_type, block)
        if world_generation_system != null and world_generation_system.has_method("set_cell_light"):
            world_generation_system.call("set_cell_light", block_cell, { "sky": 0, "block": 0 }, "block_collapsed:%s" % block_type)
        clear_block_state_from_terrain(block_cell, block_type, "block_collapsed")
        blocks.erase(block_cell)
        block.queue_free()
        collapsed += 1
    if collapsed > 0:
        invalidate_navigation_marker_cache()
        mark_world_dirty("structure_collapsed")
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
