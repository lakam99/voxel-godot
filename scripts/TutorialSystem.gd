extends Node
class_name TutorialSystem

const TutorialSceneBuilderScript := preload("res://scripts/TutorialSceneBuilder.gd")
const TutorialRepairQuestScript := preload("res://scripts/TutorialRepairQuest.gd")
const TutorialRescueSystemScript := preload("res://scripts/TutorialRescueSystem.gd")
const TutorialDialogueSystemScript := preload("res://scripts/TutorialDialogueSystem.gd")

const CELL := 1.35
const TUTORIAL_TOWN_REGION := Vector2i(1, 0)
const SAFE_RADIUS_CELLS := 24
const FENCE_RADIUS_CELLS := 25
const INTRO_REQUIRED_FENCE := 8
const INTRO_REQUIRED_LAMPS := 4
const REPAIR_FENCE_TOLERANCE_CELLS := 1
const REPAIR_LAMP_TOLERANCE_CELLS := 3
const RESCUE_MONSTER_COUNT := 6
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"
const INVALID_REPAIR_CELL := Vector2i(2147483647, 2147483647)

var main
var npc_root: Node3D
var light_root: Node3D
var repair_marker_root: Node3D
var started := false
var interacted := {}
var completed_steps := {}
var last_message := ""
var last_dialogue := {}
var last_dialogue_node: Node = null
var town := {}
var start_cell := Vector2i.ZERO
var intro_repair_active := false
var intro_repair_complete := false
var intro_bed_used := false
var intro_door_opened := false
var intro_elder_dialogue_acknowledged := false
var intro_repair_chest_opened := false
var final_night_active := false
var final_night_complete := false
var final_night_defeats_start := 0
var rescue_escort_started := false
var rescue_returning := false
var rescue_site := Vector3.ZERO
var rescue_hostiles: Array = []
var rescue_return_elapsed := 0.0
var rescue_torch: Node3D = null
var speech_bubbles: Array = []
var repair_fence_cells: Array[Vector2i] = []
var repair_lamp_cells: Array[Vector2i] = []
var repaired_fence := {}
var repaired_lamps := {}
var repair_chest_cell := Vector2i.ZERO
var repair_marker_wood_material: StandardMaterial3D
var repair_marker_lamp_material: StandardMaterial3D
var repair_marker_flame_material: StandardMaterial3D
var scene_builder
var repair_quest
var rescue_system
var dialogue_system

func setup(main_node) -> void:
    main = main_node
    scene_builder = TutorialSceneBuilderScript.new()
    scene_builder.setup(self)
    repair_quest = TutorialRepairQuestScript.new()
    repair_quest.setup(self)
    rescue_system = TutorialRescueSystemScript.new()
    rescue_system.setup(self)
    dialogue_system = TutorialDialogueSystemScript.new()
    dialogue_system.setup(self)

func _process(delta: float) -> void:
    update_speech_bubbles(delta)
    if final_night_active:
        refresh_rescue_progress(delta)

func start_new_world() -> bool:
    if main == null:
        return false
    clear_scene()
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    if town.is_empty():
        return false
    started = true
    interacted.clear()
    completed_steps.clear()
    configure_starting_inventory()
    ensure_town_generated()
    ensure_village_perimeter()
    ensure_village_lights()
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest()
    place_player_in_starter_house()
    spawn_tutorial_npcs()
    force_stormy_night()
    last_message = "Knock, knock. Someone is at the door."
    last_dialogue.clear()
    last_dialogue_node = null
    return true

func restore(snapshot_value = {}) -> void:
    clear_scene()
    var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
    started = bool(state.get("started", false))
    interacted.clear()
    var interacted_ids = state.get("interacted", [])
    if interacted_ids is Array:
        for npc_id in interacted_ids:
            interacted[String(npc_id)] = true
    completed_steps.clear()
    var step_ids = state.get("completedSteps", [])
    if step_ids is Array:
        for step_id in step_ids:
            completed_steps[String(step_id)] = true
    var start_cell_value = state.get("startCell", [])
    if start_cell_value is Array and start_cell_value.size() >= 2:
        start_cell = Vector2i(int(start_cell_value[0]), int(start_cell_value[1]))
    restore_intro_state(state.get("introRepair", {}))
    if not started or main == null:
        town = {}
        return
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    ensure_town_generated()
    ensure_village_perimeter()
    ensure_village_lights()
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest(false)
    spawn_tutorial_npcs()
    last_message = String(state.get("lastMessage", ""))

func snapshot() -> Dictionary:
    return {
        "started": started,
        "interacted": interacted.keys(),
        "completedSteps": completed_steps.keys(),
        "lastMessage": last_message,
        "townRegion": [TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y],
        "startCell": [start_cell.x, start_cell.y],
        "introRepair": intro_snapshot(),
        "npcCount": npc_count()
    }

func state() -> Dictionary:
    return {
        "started": started,
        "interacted": interacted.duplicate(),
        "completedSteps": completed_steps.duplicate(),
        "readyForWilds": is_ready_for_wilds(),
        "npcCount": npc_count(),
        "lastMessage": last_message,
        "townCenter": Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0))) if not town.is_empty() else Vector2i.ZERO,
        "startCell": start_cell,
        "introDoorOpened": intro_door_opened,
        "introElderDialogueAcknowledged": intro_elder_dialogue_acknowledged,
        "introRepairChestOpened": intro_repair_chest_opened,
        "introRepairActive": intro_repair_active,
        "introRepairComplete": intro_repair_complete,
        "introBedUsed": intro_bed_used,
        "introFencePlaced": repaired_fence.size(),
        "introFenceRequired": INTRO_REQUIRED_FENCE,
        "introLampsPlaced": repaired_lamps.size(),
        "introLampsRequired": INTRO_REQUIRED_LAMPS,
        "introRepairChestCell": repair_chest_cell,
        "postIntroMiraBriefed": mira_morning_briefed(),
        "tutorialStage": current_tutorial_stage(),
        "finalNightActive": final_night_active,
        "finalNightComplete": final_night_complete,
        "finalNightDefeats": final_night_defeats(),
        "finalNightRequired": RESCUE_MONSTER_COUNT,
        "rescueEscortStarted": rescue_escort_started,
        "rescueReturning": rescue_returning,
        "rescueRemaining": rescue_remaining_hostiles(),
        "rescueRequired": RESCUE_MONSTER_COUNT,
        "rescueSite": rescue_site,
        "introRepairTargets": {
            "fence": repair_fence_cells.duplicate(),
            "lamps": repair_lamp_cells.duplicate()
        }
    }

func tutorial_town_key() -> String:
    if town.is_empty():
        return ""
    return "%d,%d" % [int(town.get("centerX", 0)), int(town.get("centerZ", 0))]

func tutorial_home_record(index: int, fallback_home: Vector2i, fallback_porch: Vector2i, fallback_guard: Vector2i = Vector2i.ZERO) -> Dictionary:
    if fallback_guard == Vector2i.ZERO:
        fallback_guard = fallback_porch
    if main != null and main.structure_system != null and main.structure_system.has_method("town_home_records_snapshot"):
        var records_by_town: Dictionary = main.structure_system.town_home_records_snapshot()
        var records: Array = records_by_town.get(tutorial_town_key(), [])
        for record_value in records:
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            if int(record.get("buildingIndex", -1)) != index:
                continue
            return {
                "homeCell": record.get("homeCell", fallback_home),
                "porchCell": record.get("porchCell", fallback_porch),
                "guardCell": record.get("guardCell", fallback_guard)
            }
    return {
        "homeCell": fallback_home,
        "porchCell": fallback_porch,
        "guardCell": fallback_guard
    }

func configure_starting_inventory() -> void:
    if main == null or main.inventory_system == null:
        return
    main.inventory_system.clear()
    main._sync_inventory_totals()

func intro_snapshot() -> Dictionary:
    return {
        "active": intro_repair_active,
        "complete": intro_repair_complete,
        "bedUsed": intro_bed_used,
        "doorOpened": intro_door_opened,
        "elderAcknowledged": intro_elder_dialogue_acknowledged,
        "chestOpened": intro_repair_chest_opened,
        "finalNightActive": final_night_active,
        "finalNightComplete": final_night_complete,
        "finalNightDefeatsStart": final_night_defeats_start,
        "rescueEscortStarted": rescue_escort_started,
        "rescueReturning": rescue_returning,
        "rescueSite": [rescue_site.x, rescue_site.y, rescue_site.z],
        "fence": repaired_fence.keys(),
        "lamps": repaired_lamps.keys()
    }

func restore_intro_state(state_value = {}) -> void:
    var state: Dictionary = state_value if state_value is Dictionary else {}
    intro_repair_active = bool(state.get("active", true))
    intro_repair_complete = bool(state.get("complete", false))
    intro_bed_used = bool(state.get("bedUsed", false))
    intro_door_opened = bool(state.get("doorOpened", false))
    intro_elder_dialogue_acknowledged = bool(state.get("elderAcknowledged", intro_door_opened))
    intro_repair_chest_opened = bool(state.get("chestOpened", false))
    final_night_active = bool(state.get("finalNightActive", false))
    final_night_complete = bool(state.get("finalNightComplete", false))
    final_night_defeats_start = int(state.get("finalNightDefeatsStart", 0))
    rescue_escort_started = bool(state.get("rescueEscortStarted", false))
    rescue_returning = bool(state.get("rescueReturning", false))
    var rescue_site_value = state.get("rescueSite", [])
    if rescue_site_value is Array and rescue_site_value.size() >= 3:
        rescue_site = Vector3(float(rescue_site_value[0]), float(rescue_site_value[1]), float(rescue_site_value[2]))
    else:
        rescue_site = Vector3.ZERO
    repaired_fence.clear()
    for key_variant in state.get("fence", []):
        repaired_fence[String(key_variant)] = true
    repaired_lamps.clear()
    for key_variant in state.get("lamps", []):
        repaired_lamps[String(key_variant)] = true

func setup_intro_repair_quest(reset_state := true) -> void:
    repair_quest.setup_intro_repair_quest(reset_state)

func damage_intro_perimeter() -> void:
    repair_quest.damage_intro_perimeter()

func remove_repair_block(cell: Vector2i, block_type: String) -> void:
    repair_quest.remove_repair_block(cell, block_type)

func place_intro_repair_chest() -> void:
    repair_quest.place_intro_repair_chest()

func repair_chest_slots() -> Array:
    return repair_quest.repair_chest_slots()

func repair_cell_key(cell: Vector2i) -> String:
    return repair_quest.repair_cell_key(cell)

func repair_supplies_ready(state: Dictionary) -> bool:
    return repair_quest.repair_supplies_ready(state)

func nearest_unrepaired_cell(flat: Vector2i, targets: Array[Vector2i], repaired: Dictionary, tolerance: int) -> Vector2i:
    return repair_quest.nearest_unrepaired_cell(flat, targets, repaired, tolerance)

func valid_repair_cell(cell: Vector2i) -> bool:
    return repair_quest.valid_repair_cell(cell)

func repair_lamp_type(block_type: String) -> bool:
    return repair_quest.repair_lamp_type(block_type)

func intro_repair_progress_message() -> String:
    return repair_quest.intro_repair_progress_message()

func setup_repair_marker_materials() -> void:
    repair_quest.setup_marker_materials()

func make_repair_marker_material(albedo: Color, emission: Color, energy: float) -> StandardMaterial3D:
    return repair_quest.make_marker_material(albedo, emission, energy)

func refresh_repair_markers() -> void:
    repair_quest.refresh_repair_markers()

func clear_repair_markers() -> void:
    repair_quest.clear_repair_markers()

func add_repair_marker(cell: Vector2i, block_type: String) -> void:
    repair_quest.add_repair_marker(cell, block_type)

func add_repair_marker_box(parent: Node3D, size: Vector3, offset: Vector3, material: Material, rotation := Vector3.ZERO) -> void:
    repair_quest.add_marker_box(parent, size, offset, material, rotation)

func on_door_opened(door: Node) -> bool:
    if not started or intro_door_opened:
        return false
    intro_door_opened = true
    intro_elder_dialogue_acknowledged = false
    interacted["mira"] = true
    var line := "I'm sorry to wake you. Monsters broke the outer lamps and fence. Take wood and stone from the town chest and patch the gaps before anyone sleeps."
    last_message = "Mira: %s" % line
    last_dialogue = dialogue_system.make_dialogue_payload("Mira", "Elder", line, "mira", true)
    complete_step("introDoorOpened")
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    return true

func on_utility_opened(block: Node) -> bool:
    if block == null or not bool(block.get_meta("intro_repair_chest", false)):
        return false
    intro_repair_chest_opened = true
    complete_step("introRepairChest")
    last_message = "Repair chest opened: craft wood blocks for the fence and torches for the broken lamps."
    last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    return true

func on_block_placed(block: Node) -> bool:
    return repair_quest.on_block_placed(block)

func refresh_intro_repair_complete() -> bool:
    return repair_quest.refresh_intro_repair_complete()

func is_bed_locked() -> bool:
    return (started and intro_repair_active and not intro_repair_complete) or final_night_active

func on_bed_blocked() -> void:
    if final_night_active:
        last_message = "Mira: Not yet. Bring Niko back before anyone sleeps."
    else:
        last_message = "Mira: Not yet. The lamps and fence have to be repaired before anyone can sleep."
    last_dialogue.clear()

func on_bed_used() -> void:
    if not started or intro_bed_used:
        return
    intro_bed_used = true
    intro_repair_active = false
    complete_step("introFirstSleep")
    last_message = "You slept through the storm. Dawn breaks over the repaired village."
    last_dialogue.clear()
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()

func should_freeze_intro_night() -> bool:
    return (started and intro_repair_active and not intro_bed_used) or (final_night_active and not final_night_complete)

func should_loop_intro_knock() -> bool:
    return started and intro_repair_active and not intro_door_opened

func is_intro_elder_waiting_for_ack() -> bool:
    return started and intro_repair_active and intro_door_opened and not intro_elder_dialogue_acknowledged

func acknowledge_dialogue(context := {}) -> void:
    var state: Dictionary = context if context is Dictionary else {}
    if bool(state.get("introElder", false)) or (String(state.get("npcId", "")) == "mira" and is_intro_elder_waiting_for_ack()):
        intro_elder_dialogue_acknowledged = true
    clear_dialogue_focus()

func dialogue_payload() -> Dictionary:
    return last_dialogue.duplicate(true)

func focus_dialogue_npc() -> void:
    if last_dialogue_node == null or main == null or main.npc_system == null or main.player == null:
        return
    if main.npc_system.has_method("focus_dialogue_npc"):
        main.npc_system.focus_dialogue_npc(last_dialogue_node, main.player.global_position)

func clear_dialogue_focus() -> void:
    if main and main.npc_system and main.npc_system.has_method("clear_dialogue_focus"):
        main.npc_system.clear_dialogue_focus()

func update_progress(state: Dictionary) -> bool:
    if not started:
        return false
    var changed := false
    changed = complete_step_if("introDoorOpened", intro_door_opened) or changed
    changed = complete_step_if("introRepairChest", intro_repair_chest_opened) or changed
    changed = complete_step_if("introFenceBuilt", repair_supplies_ready(state)) or changed
    changed = complete_step_if("introPerimeterRepaired", intro_repair_complete) or changed
    changed = complete_step_if("introFirstSleep", intro_bed_used) or changed
    changed = complete_step_if("finalNightStarted", final_night_active or final_night_complete) or changed
    changed = refresh_rescue_progress() or changed
    changed = complete_step_if("finalNightComplete", final_night_complete) or changed
    var totals: Dictionary = state.get("totals", {})
    if bool(interacted.get("rowan", false)):
        changed = complete_step_if("rowanAxe", has_axe(totals)) or changed
        changed = complete_step_if("rowanLogs", bool(completed_steps.get("rowanAxe", false)) and int(totals.get("logs", 0)) >= 4) or changed
        changed = complete_step_if("rowanPickaxe", has_pickaxe(totals)) or changed
        changed = complete_step_if("rowanStones", bool(completed_steps.get("rowanPickaxe", false)) and int(totals.get("stones", 0)) >= 4) or changed
        changed = complete_step_if("rowanBlocks", bool(completed_steps.get("rowanStones", false))) or changed
    if bool(interacted.get("niko", false)):
        changed = complete_step_if("nikoBerries", int(totals.get("berries", 0)) >= 2 or int(totals.get("fieldRation", 0)) > 0) or changed
    if bool(interacted.get("sera", false)):
        changed = complete_step_if("seraWeapon", has_weapon(totals)) or changed
    changed = complete_step_if("readyForWilds", is_ready_for_wilds()) or changed
    return changed

func is_tutorial_npc(node: Node) -> bool:
    return dialogue_system.is_tutorial_npc(node)

func interact_with(node: Node) -> bool:
    return dialogue_system.interact_with(node)

func handle_npc_quest(npc_id: String) -> String:
    return dialogue_system.handle_npc_quest(npc_id)

func award_once(step_id: String, reason: String, items: Dictionary, xp := 0) -> bool:
    if bool(completed_steps.get(step_id, false)):
        return false
    completed_steps[step_id] = true
    if main and main.inventory_system:
        for item_id_variant in items.keys():
            main.inventory_system.add_item(String(item_id_variant), int(items[item_id_variant]))
        main._sync_inventory_totals()
    if xp > 0 and main and main.has_method("award_progression"):
        main.award_progression(reason, xp)
    return true

func complete_step(step_id: String) -> bool:
    if bool(completed_steps.get(step_id, false)):
        return false
    completed_steps[step_id] = true
    return true

func complete_step_if(step_id: String, condition: bool) -> bool:
    if not condition:
        return false
    return complete_step(step_id)

func is_ready_for_wilds() -> bool:
    return bool(completed_steps.get("rowanBlocks", false)) and bool(completed_steps.get("nikoBerries", false)) and bool(completed_steps.get("seraWeapon", false))

func mira_morning_briefed() -> bool:
    return bool(completed_steps.get("miraMorningBriefing", false))

func start_final_night() -> bool:
    return rescue_system.start_final_night()

func complete_final_night() -> bool:
    return rescue_system.complete_final_night()

func final_night_defeats() -> int:
    return rescue_system.final_night_defeats()

func current_hostile_defeats() -> int:
    return rescue_system.current_hostile_defeats()

func setup_rescue_scene() -> void:
    rescue_system.setup_rescue_scene()

func choose_rescue_site() -> Vector3:
    return rescue_system.choose_rescue_site()

func spawn_rescue_torch(position: Vector3) -> void:
    rescue_system.spawn_rescue_torch(position)

func clear_rescue_torch() -> void:
    rescue_system.clear_rescue_torch()

func spawn_rescue_hostiles() -> void:
    rescue_system.spawn_rescue_hostiles()

func start_rescue_escort() -> void:
    rescue_system.start_rescue_escort()

func refresh_rescue_progress(delta := -1.0) -> bool:
    return rescue_system.refresh_rescue_progress(delta)

func rescue_remaining_hostiles() -> int:
    return rescue_system.rescue_remaining_hostiles()

func start_rescue_return() -> void:
    rescue_system.start_rescue_return()

func rescue_return_position() -> Vector3:
    return rescue_system.rescue_return_position()

func rescue_party_home() -> bool:
    return rescue_system.rescue_party_home()

func settle_rescue_party_home() -> void:
    rescue_system.settle_rescue_party_home()

func find_tutorial_npc(npc_id: String) -> StaticBody3D:
    return rescue_system.find_tutorial_npc(npc_id)

func show_speech_bubble(npc_id: String, text: String, duration := 2.6) -> void:
    rescue_system.show_speech_bubble(npc_id, text, duration)

func update_speech_bubbles(delta: float) -> void:
    rescue_system.update_speech_bubbles(delta)

func clear_speech_bubbles() -> void:
    rescue_system.clear_speech_bubbles()

func current_tutorial_stage() -> String:
    return dialogue_system.current_tutorial_stage()

func npc_allowed_for_current_stage(npc_id: String) -> bool:
    return dialogue_system.npc_allowed_for_current_stage(npc_id)

func locked_line_for_stage(npc_id: String) -> String:
    return dialogue_system.locked_line_for_stage(npc_id)

func is_after_training_hours() -> bool:
    return dialogue_system.is_after_training_hours()

func inventory_count(item_id: String) -> int:
    return dialogue_system.inventory_count(item_id)

func structure_count(block_type: String) -> int:
    return dialogue_system.structure_count(block_type)

func has_weapon(totals: Dictionary) -> bool:
    return dialogue_system.has_weapon(totals)

func has_axe(totals: Dictionary) -> bool:
    return dialogue_system.has_axe(totals)

func has_pickaxe(totals: Dictionary) -> bool:
    return dialogue_system.has_pickaxe(totals)

func danger_profile(position: Vector3) -> Dictionary:
    return dialogue_system.danger_profile(position)

func ensure_town_generated() -> void:
    scene_builder.ensure_town_generated()

func ensure_starter_bed() -> void:
    scene_builder.ensure_starter_bed()

func clear_overlapping_starter_beds(center_cell: Vector2i, level: float) -> void:
    scene_builder.clear_overlapping_starter_beds(center_cell, level)

func ensure_starter_shelter() -> void:
    scene_builder.ensure_starter_shelter()

func ensure_village_perimeter() -> void:
    scene_builder.ensure_village_perimeter()

func place_perimeter_cell(cell_x: int, cell_z: int, level: float, gate_cells: Dictionary) -> void:
    scene_builder.place_perimeter_cell(cell_x, cell_z, level, gate_cells)

func ensure_village_lights() -> void:
    scene_builder.ensure_village_lights()

func place_player_in_starter_house() -> void:
    scene_builder.place_player_in_starter_house()

func force_stormy_night() -> void:
    scene_builder.force_stormy_night()

func spawn_tutorial_npcs() -> void:
    scene_builder.spawn_tutorial_npcs()

func spawn_npc(spec: Dictionary, level: float, look_target: Vector3) -> StaticBody3D:
    return scene_builder.spawn_npc(spec, level, look_target)

func add_npc_visual(parent: Node3D, color: Color, accent: Color, npc_name: String, role: String) -> void:
    scene_builder.add_npc_visual(parent, color, accent, npc_name, role)

func add_warm_light(position: Vector3, radius: float, energy: float) -> void:
    scene_builder.add_warm_light(position, radius, energy)

func make_material(color: Color, roughness: float) -> StandardMaterial3D:
    return scene_builder.make_material(color, roughness)

func make_emissive_material(color: Color, energy: float) -> StandardMaterial3D:
    return scene_builder.make_emissive_material(color, energy)

func clear_scene() -> void:
    scene_builder.clear_scene()

func clear_npcs() -> void:
    scene_builder.clear_npcs()

func clear_lights() -> void:
    scene_builder.clear_lights()

func npc_count() -> int:
    return scene_builder.npc_count()
