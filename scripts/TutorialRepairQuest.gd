extends RefCounted
class_name TutorialRepairQuest

const CELL := 1.35
const FENCE_RADIUS_CELLS := 25
const INTRO_REQUIRED_FENCE := 8
const INTRO_REQUIRED_LAMPS := 4
const REPAIR_FENCE_TOLERANCE_CELLS := 1
const REPAIR_LAMP_TOLERANCE_CELLS := 3
const REPAIR_PROP_CLEARANCE_CELLS := 3
const INVALID_REPAIR_CELL := Vector2i(2147483647, 2147483647)

var system
var main
var wood_material: StandardMaterial3D
var lamp_material: StandardMaterial3D
var flame_material: StandardMaterial3D

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main
    system.repair_marker_root = Node3D.new()
    system.repair_marker_root.name = "TutorialRepairMarkers"
    system.add_child(system.repair_marker_root)
    setup_marker_materials()

func setup_intro_repair_quest(reset_state := true) -> void:
    if main == null or system.town.is_empty() or main.structure_system == null:
        return
    var center_x := int(system.town.get("centerX", 0))
    var center_z := int(system.town.get("centerZ", 0))
    system.repair_fence_cells.clear()
    for cell in [
        Vector2i(center_x - 19, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x - 18, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x - 17, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x - 16, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x + 16, center_z + FENCE_RADIUS_CELLS),
        Vector2i(center_x + 17, center_z + FENCE_RADIUS_CELLS),
        Vector2i(center_x + 18, center_z + FENCE_RADIUS_CELLS),
        Vector2i(center_x + 19, center_z + FENCE_RADIUS_CELLS)
    ]:
        system.repair_fence_cells.append(cell)
    system.repair_lamp_cells.clear()
    for cell in [
        Vector2i(center_x - 10, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x - 5, center_z - FENCE_RADIUS_CELLS),
        Vector2i(center_x + 5, center_z + FENCE_RADIUS_CELLS),
        Vector2i(center_x + 10, center_z + FENCE_RADIUS_CELLS)
    ]:
        system.repair_lamp_cells.append(cell)
    system.repair_chest_cell = Vector2i(center_x - 2, center_z + 1)
    reserve_repair_prop_clearance()
    clear_repair_target_props()
    if reset_state:
        reset_intro_state()
    damage_intro_perimeter()
    place_intro_repair_chest()
    refresh_repair_markers()
    refresh_intro_repair_complete()

func reset_intro_state() -> void:
    system.intro_repair_active = true
    system.intro_repair_complete = false
    system.intro_bed_used = false
    system.intro_door_opened = false
    system.intro_elder_dialogue_acknowledged = false
    system.intro_repair_chest_opened = false
    system.final_night_active = false
    system.final_night_complete = false
    system.final_night_defeats_start = 0
    system.rescue_escort_started = false
    system.rescue_returning = false
    system.rescue_site = Vector3.ZERO
    system.rescue_hostiles.clear()
    system.rescue_return_elapsed = 0.0
    system.clear_rescue_torch()
    system.repaired_fence.clear()
    system.repaired_lamps.clear()

func reserve_repair_prop_clearance() -> void:
    if main == null or main.structure_system == null:
        return
    if not main.structure_system.has_method("reserve_natural_prop_exclusion"):
        return
    var all_targets := repair_target_cells()
    for cell in all_targets:
        main.structure_system.reserve_natural_prop_exclusion(
            cell.x - REPAIR_PROP_CLEARANCE_CELLS,
            cell.y - REPAIR_PROP_CLEARANCE_CELLS,
            REPAIR_PROP_CLEARANCE_CELLS * 2 + 1,
            REPAIR_PROP_CLEARANCE_CELLS * 2 + 1,
            "tutorial_repair:%d,%d" % [cell.x, cell.y]
        )

func repair_target_cells() -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    for cell in system.repair_fence_cells:
        if cell is Vector2i:
            result.append(cell)
    for cell in system.repair_lamp_cells:
        if cell is Vector2i:
            result.append(cell)
    return result

func clear_repair_target_props() -> int:
    if main == null:
        return 0
    var targets := repair_target_cells()
    if targets.is_empty():
        return 0
    var roots: Array[Node] = []
    for root_name in ["prop_root", "chunk_root"]:
        var root = main.get(root_name) as Node
        if root != null and is_instance_valid(root) and not roots.has(root):
            roots.append(root)
    var removed := 0
    for root in roots:
        removed += clear_repair_target_props_under(root, targets)
    return removed

func clear_repair_target_props_under(root: Node, targets: Array[Vector2i]) -> int:
    var removed := 0
    var stack: Array[Node] = [root]
    var seen := {}
    while not stack.is_empty():
        var node := stack.pop_back() as Node
        if node == null or not is_instance_valid(node):
            continue
        var instance_id := node.get_instance_id()
        if seen.has(instance_id):
            continue
        seen[instance_id] = true
        if node is Node3D and String(node.get_meta("kind", "")) == "prop":
            var prop := node as Node3D
            if repair_prop_blocks_target(prop, targets):
                remove_repair_target_prop(prop)
                removed += 1
                continue
        for child in node.get_children():
            stack.append(child)
    return removed

func repair_prop_blocks_target(prop: Node3D, targets: Array[Vector2i]) -> bool:
    if prop == null:
        return false
    var cell := Vector2i(roundi(prop.global_position.x / CELL), roundi(prop.global_position.z / CELL))
    for target in targets:
        if maxi(absi(cell.x - target.x), absi(cell.y - target.y)) <= REPAIR_PROP_CLEARANCE_CELLS:
            return true
    return false

func remove_repair_target_prop(prop: Node3D) -> void:
    if prop == null or not is_instance_valid(prop):
        return
    var prop_id := String(prop.get_meta("prop_id", ""))
    if prop_id != "":
        var removed_props: Dictionary = main.get("removed_props")
        removed_props[prop_id] = true
        if main.npc_system and main.npc_system.has_method("notify_navigation_prop_removed"):
            main.npc_system.notify_navigation_prop_removed(prop_id, prop)
    prop.queue_free()

func damage_intro_perimeter() -> void:
    for cell in system.repair_fence_cells:
        if not system.repaired_fence.has(repair_cell_key(cell)):
            remove_repair_block(cell, "woodBlock")
    for cell in system.repair_lamp_cells:
        if not system.repaired_lamps.has(repair_cell_key(cell)):
            remove_repair_block(cell, "torch")

func remove_repair_block(cell: Vector2i, block_type: String) -> void:
    if main == null:
        return
    var blocks: Dictionary = main.get("blocks")
    for key_variant in blocks.keys():
        var body := blocks[key_variant] as Node
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        var block_cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        if block_cell.x == cell.x and block_cell.z == cell.y:
            blocks.erase(key_variant)
            body.queue_free()
            return

func place_intro_repair_chest() -> void:
    if main == null or main.structure_system == null or system.town.is_empty():
        return
    var level := float(system.town.get("level", 16.0))
    var cell: Vector2i = system.repair_chest_cell
    var chest = main.structure_system.place_utility(cell.x, cell.y, level, "chest", {
        "storageSlots": repair_chest_slots(),
        "generatedTier": "town",
        "cacheKey": "%s:intro-repair-chest:%d,%d" % [main.seed_text, cell.x, cell.y]
    })
    if chest:
        chest.set_meta("intro_repair_chest", true)
        chest.set_meta("storage_slots", repair_chest_slots())

func repair_chest_slots() -> Array:
    var slots := []
    for i in range(12):
        slots.append({ "item": "", "count": 0 })
    slots[0] = { "item": "logs", "count": 24 }
    slots[1] = { "item": "stones", "count": 16 }
    slots[2] = { "item": "berries", "count": 4 }
    return slots

func repair_cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func repair_supplies_ready(state: Dictionary) -> bool:
    var totals: Dictionary = state.get("totals", {})
    return int(totals.get("woodBlock", 0)) + system.repaired_fence.size() >= INTRO_REQUIRED_FENCE and int(totals.get("torch", 0)) + system.repaired_lamps.size() >= INTRO_REQUIRED_LAMPS

func nearest_unrepaired_cell(flat: Vector2i, targets: Array[Vector2i], repaired: Dictionary, tolerance: int) -> Vector2i:
    var best_cell := INVALID_REPAIR_CELL
    var best_distance := tolerance + 1
    for target in targets:
        if repaired.has(repair_cell_key(target)):
            continue
        var distance := absi(flat.x - target.x) + absi(flat.y - target.y)
        if distance <= tolerance and distance < best_distance:
            best_cell = target
            best_distance = distance
    return best_cell

func valid_repair_cell(cell: Vector2i) -> bool:
    return cell != INVALID_REPAIR_CELL

func repair_lamp_type(block_type: String) -> bool:
    return block_type == "torch" or block_type == "wardLantern"

func intro_repair_progress_message() -> String:
    var fence_left: int = maxi(0, INTRO_REQUIRED_FENCE - system.repaired_fence.size())
    var lamps_left: int = maxi(0, INTRO_REQUIRED_LAMPS - system.repaired_lamps.size())
    if fence_left <= 0 and lamps_left > 0:
        return "Fence repaired. Place %d more lamp%s near the broken perimeter lamp gaps." % [lamps_left, "" if lamps_left == 1 else "s"]
    if lamps_left <= 0 and fence_left > 0:
        return "Lamps repaired. Place %d more fence block%s in the broken perimeter gaps." % [fence_left, "" if fence_left == 1 else "s"]
    return "Repairs: fence %d/%d, lamps %d/%d" % [system.repaired_fence.size(), INTRO_REQUIRED_FENCE, system.repaired_lamps.size(), INTRO_REQUIRED_LAMPS]

func setup_marker_materials() -> void:
    wood_material = make_marker_material(Color(0.86, 0.54, 0.24, 0.34), Color(1.0, 0.68, 0.28), 0.18)
    lamp_material = make_marker_material(Color(0.98, 0.77, 0.30, 0.42), Color(1.0, 0.74, 0.26), 0.42)
    flame_material = make_marker_material(Color(1.0, 0.52, 0.15, 0.58), Color(1.0, 0.42, 0.10), 1.0)

func make_marker_material(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = albedo
    material.roughness = 0.62
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.emission_enabled = true
    material.emission = emission
    material.emission_energy_multiplier = energy
    return material

func refresh_repair_markers() -> void:
    clear_repair_markers()
    if system.repair_marker_root == null or not system.intro_repair_active or system.intro_repair_complete or system.town.is_empty():
        return
    for cell in system.repair_fence_cells:
        if not system.repaired_fence.has(repair_cell_key(cell)):
            add_repair_marker(cell, "woodBlock")
    for cell in system.repair_lamp_cells:
        if not system.repaired_lamps.has(repair_cell_key(cell)):
            add_repair_marker(cell, "torch")

func clear_repair_markers() -> void:
    if system.repair_marker_root == null:
        return
    for child in system.repair_marker_root.get_children():
        system.repair_marker_root.remove_child(child)
        child.queue_free()

func add_repair_marker(cell: Vector2i, block_type: String) -> void:
    if system.repair_marker_root == null or system.town.is_empty():
        return
    var level := float(system.town.get("level", 16.0))
    var marker := Node3D.new()
    marker.name = "RepairMarker_%s_%d_%d" % [block_type, cell.x, cell.y]
    marker.position = Vector3(float(cell.x) * CELL, level + CELL * (1.48 if block_type == "torch" else 0.48), float(cell.y) * CELL)
    marker.set_meta("intro_repair_marker", true)
    marker.set_meta("repair_cell", cell)
    marker.set_meta("block_type", block_type)
    if block_type == "torch":
        add_marker_box(marker, Vector3(CELL * 0.12, CELL * 0.82, CELL * 0.12), Vector3(0.0, -CELL * 0.05, 0.0), wood_material)
        add_marker_box(marker, Vector3(CELL * 0.36, CELL * 0.34, CELL * 0.36), Vector3(0.0, CELL * 0.39, 0.0), lamp_material, Vector3(0.0, 0.78, 0.0))
        add_marker_box(marker, Vector3(CELL * 0.44, CELL * 0.06, CELL * 0.44), Vector3(0.0, CELL * 0.60, 0.0), lamp_material)
        add_marker_box(marker, Vector3(CELL * 0.20, CELL * 0.26, CELL * 0.20), Vector3(0.0, CELL * 0.42, 0.0), flame_material, Vector3(0.0, -0.78, 0.0))
    else:
        add_marker_box(marker, Vector3(CELL * 0.96, CELL * 0.96, CELL * 0.96), Vector3.ZERO, wood_material)
    system.repair_marker_root.add_child(marker)

func add_marker_box(parent: Node3D, size: Vector3, offset: Vector3, material: Material, rotation := Vector3.ZERO) -> void:
    var mesh := BoxMesh.new()
    mesh.size = size
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = material
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.position = offset
    instance.rotation = rotation
    parent.add_child(instance)

func on_block_placed(block: Node) -> bool:
    if block == null or not system.intro_repair_active or system.intro_repair_complete:
        return false
    var block_type := String(block.get_meta("block_type", ""))
    var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
    var flat := Vector2i(cell.x, cell.z)
    var changed := false
    var handled := false
    if block_type == "woodBlock":
        handled = true
        var fence_target := nearest_unrepaired_cell(flat, system.repair_fence_cells, system.repaired_fence, REPAIR_FENCE_TOLERANCE_CELLS)
        if valid_repair_cell(fence_target):
            system.repaired_fence[repair_cell_key(fence_target)] = true
            changed = true
    elif repair_lamp_type(block_type):
        handled = true
        var lamp_target := nearest_unrepaired_cell(flat, system.repair_lamp_cells, system.repaired_lamps, REPAIR_LAMP_TOLERANCE_CELLS)
        if valid_repair_cell(lamp_target):
            system.repaired_lamps[repair_cell_key(lamp_target)] = true
            changed = true
    if not changed:
        return handled_placement_miss(block_type) if handled else false
    refresh_intro_repair_complete()
    system.last_message = "Perimeter repaired. The storm is still heavy, but you can sleep now." if system.intro_repair_complete else intro_repair_progress_message()
    system.last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    return true

func handled_placement_miss(block_type: String) -> bool:
    if block_type == "woodBlock":
        system.last_message = "Fence blocks count when placed in or beside the broken perimeter fence gaps."
    else:
        system.last_message = "Lamps count when placed near one of the broken perimeter lamp gaps."
    system.last_dialogue.clear()
    return true

func refresh_intro_repair_complete() -> bool:
    system.intro_repair_complete = system.repaired_fence.size() >= INTRO_REQUIRED_FENCE and system.repaired_lamps.size() >= INTRO_REQUIRED_LAMPS
    if system.intro_repair_complete:
        system.complete_step("introPerimeterRepaired")
    refresh_repair_markers()
    return system.intro_repair_complete
