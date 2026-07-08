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
var last_home_refresh_debug := {}

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

func ensure_rescue_system() -> bool:
    if rescue_system != null:
        return true
    rescue_system = TutorialRescueSystemScript.new()
    if rescue_system == null:
        return false
    rescue_system.setup(self)
    return true

func ensure_dialogue_system() -> bool:
    if dialogue_system != null:
        return true
    dialogue_system = TutorialDialogueSystemScript.new()
    if dialogue_system == null:
        return false
    dialogue_system.setup(self)
    return true

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
    reserve_tutorial_town_layout()
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
    refresh_tutorial_npc_home_records()
    force_stormy_night()
    last_message = "Knock, knock. Someone is at the door."
    last_dialogue.clear()
    last_dialogue_node = null
    return true

func start_new_world_staged() -> bool:
    if main == null:
        return false
    clear_scene()
    town = main.town_region(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)
    if town.is_empty():
        return false
    reserve_tutorial_town_layout()
    started = true
    interacted.clear()
    completed_steps.clear()
    configure_starting_inventory()
    await loading_yield("Building tutorial town")
    await ensure_town_generated_staged()
    await loading_yield("Preparing village perimeter")
    ensure_village_perimeter()
    await loading_yield("Preparing village lights")
    ensure_village_lights()
    await loading_yield("Preparing starter shelter")
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest()
    place_player_in_starter_house()
    await loading_yield("Preparing villagers")
    spawn_tutorial_npcs()
    refresh_tutorial_npc_home_records()
    force_stormy_night()
    last_message = "Knock, knock. Someone is at the door."
    last_dialogue.clear()
    last_dialogue_node = null
    return true

func ensure_town_generated_staged() -> void:
    if main == null or town.is_empty() or main.structure_system == null:
        return
    var center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
    var town_key := tutorial_town_key()
    var max_frames := 360
    for frame in range(max_frames):
        if main.structure_system.has_method("update_around_budgeted"):
            main.structure_system.update_around_budgeted(center, true)
        else:
            main.structure_system.update_around(center)
            return
        var pending := 0
        if main.structure_system.has_method("pending_structure_op_count"):
            pending = int(main.structure_system.pending_structure_op_count())
        var records_ready := false
        if main.structure_system.has_method("town_home_records_snapshot"):
            var records_by_town: Dictionary = main.structure_system.town_home_records_snapshot()
            var records: Array = records_by_town.get(town_key, []) if records_by_town.get(town_key, []) is Array else []
            records_ready = records.size() >= 4
        if records_ready and pending <= 0:
            return
        await loading_yield("Building tutorial town %d" % pending)
    ensure_tutorial_town_home_records(4)

func loading_yield(message: String) -> void:
    if main != null and main.has_method("startup_loading_yield"):
        await main.call("startup_loading_yield", message)
    elif get_tree() != null:
        await get_tree().process_frame

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
    reserve_tutorial_town_layout()
    ensure_town_generated()
    ensure_village_perimeter()
    ensure_village_lights()
    ensure_starter_shelter()
    ensure_starter_bed()
    setup_intro_repair_quest(false)
    spawn_tutorial_npcs()
    last_message = String(state.get("lastMessage", ""))
    sync_crafting_unlocks_from_tutorial()

func reserve_tutorial_town_layout() -> void:
    if main == null or town.is_empty():
        return
    town["radius"] = FENCE_RADIUS_CELLS
    town["homeExclusionRings"] = [
        {
            "radius": FENCE_RADIUS_CELLS,
            "margin": 3,
            "reason": "tutorial_repair_perimeter"
        }
    ]
    if main.get("town_region_cache") is Dictionary:
        var cache: Dictionary = main.get("town_region_cache")
        cache[Vector2i(TUTORIAL_TOWN_REGION.x, TUTORIAL_TOWN_REGION.y)] = town

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
        "homeRefresh": last_home_refresh_debug.duplicate(true),
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
    var generated_record := tutorial_home_record_from_records(index, fallback_home, fallback_porch, fallback_guard)
    if not generated_record.is_empty():
        return generated_record
    return normalized_tutorial_home_record({
        "homeCell": fallback_home,
        "porchCell": fallback_porch,
        "guardCell": fallback_guard
    }, fallback_home, fallback_porch, fallback_guard)

func tutorial_home_records_for_current_town() -> Array:
    var records: Array = []
    if main == null or main.structure_system == null or not main.structure_system.has_method("town_home_records_snapshot"):
        return records
    var records_by_town: Dictionary = main.structure_system.town_home_records_snapshot()
    var exact_value = records_by_town.get(tutorial_town_key(), [])
    if exact_value is Array:
        records.append_array(exact_value)
    if not records.is_empty() or town.is_empty():
        return records
    var center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
    for town_key_value in records_by_town.keys():
        var town_records_value = records_by_town.get(town_key_value, [])
        if not (town_records_value is Array):
            continue
        for record_value in town_records_value:
            if not (record_value is Dictionary):
                continue
            var record: Dictionary = record_value
            var record_center: Vector2i = record.get("townCenter", Vector2i.ZERO)
            if record_center == center:
                records.append(record)
    return records

func ensure_tutorial_town_home_records(minimum_count := 4) -> bool:
    if main == null or main.structure_system == null or town.is_empty():
        return false
    if not main.structure_system.has_method("ensure_town_home_records"):
        return not tutorial_home_records_for_current_town().is_empty()
    var ensured_value = main.structure_system.call("ensure_town_home_records", town, minimum_count)
    if ensured_value is Array and not (ensured_value as Array).is_empty():
        return true
    return not tutorial_home_records_for_current_town().is_empty()

func tutorial_home_record_from_records(index: int, fallback_home: Vector2i, fallback_porch: Vector2i, fallback_guard: Vector2i = Vector2i.ZERO) -> Dictionary:
    if fallback_guard == Vector2i.ZERO:
        fallback_guard = fallback_porch
    var records := tutorial_home_records_for_current_town()
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var indexed_record: Dictionary = record_value
        if int(indexed_record.get("buildingIndex", -1)) == index:
            return normalized_tutorial_home_record(indexed_record, fallback_home, fallback_porch, fallback_guard)
    var nearest_record: Dictionary = {}
    var nearest_score := INF
    for record_value in records:
        if not (record_value is Dictionary):
            continue
        var record: Dictionary = record_value
        var record_home: Vector2i = record.get("homeCell", fallback_home)
        var record_porch: Vector2i = record.get("porchCell", record_home)
        var home_delta := record_home - fallback_home
        var porch_delta := record_porch - fallback_porch
        var score := float(home_delta.length_squared()) + float(porch_delta.length_squared()) * 0.35
        if int(record.get("buildingIndex", -1)) == index:
            score -= 0.01
        if score < nearest_score:
            nearest_score = score
            nearest_record = record
    if nearest_record.is_empty():
        return {}
    return normalized_tutorial_home_record(nearest_record, fallback_home, fallback_porch, fallback_guard)

func normalized_tutorial_home_record(source: Dictionary, fallback_home: Vector2i, fallback_porch: Vector2i, fallback_guard: Vector2i) -> Dictionary:
    var home_cell: Vector2i = source.get("homeCell", fallback_home)
    var porch_cell: Vector2i = source.get("porchCell", fallback_porch)
    var inward := cardinal_home_direction(home_cell - porch_cell)
    var door_cell: Vector2i = source.get("doorCell", porch_cell + inward if inward != Vector2i.ZERO else porch_cell)
    var interior_landing_cell: Vector2i = source.get("interiorLandingCell", door_cell + inward if inward != Vector2i.ZERO else home_cell)
    var route_cells: Array = source.get("homeRouteCells", []) if source.get("homeRouteCells", []) is Array else []
    if route_cells.size() < 3:
        route_cells = []
        for candidate in [porch_cell, door_cell, interior_landing_cell, home_cell]:
            if route_cells.is_empty() or route_cells[route_cells.size() - 1] != candidate:
                route_cells.append(candidate)
    var interior_min: Vector2i = source.get("interiorMinCell", home_cell)
    var interior_max: Vector2i = source.get("interiorMaxCell", home_cell)
    for interior_cell in [interior_landing_cell, home_cell]:
        interior_min = Vector2i(mini(interior_min.x, interior_cell.x), mini(interior_min.y, interior_cell.y))
        interior_max = Vector2i(maxi(interior_max.x, interior_cell.x), maxi(interior_max.y, interior_cell.y))
    return {
        "homeCell": home_cell,
        "porchCell": porch_cell,
        "doorCell": door_cell,
        "interiorLandingCell": interior_landing_cell,
        "homeRouteCells": route_cells,
        "guardCell": source.get("guardCell", fallback_guard),
        "interiorMinCell": interior_min,
        "interiorMaxCell": interior_max
    }

func cardinal_home_direction(delta: Vector2i) -> Vector2i:
    if delta == Vector2i.ZERO:
        return Vector2i.ZERO
    if absi(delta.x) >= absi(delta.y):
        return Vector2i(1 if delta.x > 0 else -1, 0)
    return Vector2i(0, 1 if delta.y > 0 else -1)

func configure_starting_inventory() -> void:
    if main == null or main.inventory_system == null:
        return
    main.inventory_system.clear()
    if main.has_method("reset_crafting_unlocks"):
        main.reset_crafting_unlocks(["tutorial_repair"])
    main._sync_inventory_totals()

func unlock_crafting_group(group_id: String, reason := "") -> bool:
    if main == null or not main.has_method("unlock_crafting_group"):
        return false
    return bool(main.unlock_crafting_group(group_id, reason))

func sync_crafting_unlocks_from_tutorial() -> void:
    if main == null:
        return
    unlock_crafting_group("tutorial_repair", "tutorial repair crafting")
    if bool(interacted.get("rowan", false)) or bool(completed_steps.get("rowanAxe", false)) or bool(completed_steps.get("rowanPickaxe", false)) or bool(completed_steps.get("rowanBlocks", false)):
        unlock_crafting_group("rowan_basic_tools", "Rowan's basic tools")
    if bool(interacted.get("sera", false)) or bool(completed_steps.get("seraWeapon", false)) or bool(completed_steps.get("readyForWilds", false)) or final_night_active or final_night_complete:
        unlock_crafting_group("rescue_weapon", "rescue weapon training")

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
    if not started:
        return false
    if intro_door_opened:
        return intro_repair_active and not intro_elder_dialogue_acknowledged
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
    resume_intro_elder_schedule()
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
    var intro_ack := bool(state.get("introElder", false)) \
        or (
            String(state.get("npcId", "")) == "mira"
            and intro_door_opened
            and not intro_elder_dialogue_acknowledged
        )
    if intro_ack:
        intro_elder_dialogue_acknowledged = true
        release_intro_elder_home_order()
    clear_dialogue_focus()

func dialogue_payload() -> Dictionary:
    return last_dialogue.duplicate(true)

func release_intro_elder_home_order() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_go_home"):
        return
    if not refresh_tutorial_npc_home_records(true):
        last_message = "Mira waits while the village paths settle."
        return
    var actor = last_dialogue_node if last_dialogue_node != null and is_instance_valid(last_dialogue_node) else "mira"
    if main.npc_system.has_method("release_intro_hold_and_order_home"):
        var release_result: Dictionary = main.npc_system.release_intro_hold_and_order_home(actor, "intro_acknowledged_return_home")
        if String(release_result.get("state", "")) != "FAILED_TARGET_GONE":
            return
    var entry: Dictionary = main.npc_system.npc_entry_for_actor(actor) if main.npc_system.has_method("npc_entry_for_actor") else {}
    if entry.is_empty() and actor != "mira" and main.npc_system.has_method("npc_entry_for_actor"):
        entry = main.npc_system.npc_entry_for_actor("mira")
        actor = "mira"
    if not entry.is_empty():
        if main.npc_system.has_method("clear_intro_hold_for_entry"):
            main.npc_system.clear_intro_hold_for_entry(entry)
        else:
            entry["holdIntroDoor"] = false
        var body := entry.get("body") as Node
        if body != null and is_instance_valid(body):
            body.set_meta("npc_hold_intro_door", false)
    main.npc_system.order_go_home(actor, "intro_acknowledged_return_home")

func refresh_tutorial_npc_home_records(require_generated := false) -> bool:
    if main == null or main.npc_system == null or not main.npc_system.has_method("update_npc_home_record"):
        last_home_refresh_debug = { "ok": false, "reason": "missing_npc_system" }
        return false
    if town.is_empty():
        last_home_refresh_debug = { "ok": false, "reason": "missing_town" }
        return false
    var cx := int(town.get("centerX", 0))
    var cz := int(town.get("centerZ", 0))
    var records := tutorial_home_records_for_current_town()
    if records.size() < 4:
        ensure_tutorial_town_home_records(4)
        records = tutorial_home_records_for_current_town()
    if require_generated and records.size() < 4:
        last_home_refresh_debug = {
            "ok": false,
            "reason": "generated_records_missing" if records.is_empty() else "generated_records_incomplete",
            "generatedRecordCount": records.size(),
            "requiredGenerated": true,
            "townKey": tutorial_town_key(),
            "townCenter": [cx, cz]
        }
        return false
    var north_home: Dictionary = tutorial_home_record_from_records(1, Vector2i(cx + 12, cz - 10), Vector2i(cx + 12, cz - 15))
    var west_home: Dictionary = tutorial_home_record_from_records(2, Vector2i(cx - 13, cz + 12), Vector2i(cx - 13, cz + 17))
    var elder_home: Dictionary = tutorial_home_record_from_records(3, Vector2i(cx + 13, cz + 12), Vector2i(cx + 13, cz + 17))
    if north_home.is_empty():
        north_home = tutorial_home_record(1, Vector2i(cx + 12, cz - 10), Vector2i(cx + 12, cz - 15))
    if west_home.is_empty():
        west_home = tutorial_home_record(2, Vector2i(cx - 13, cz + 12), Vector2i(cx - 13, cz + 17))
    if elder_home.is_empty():
        elder_home = tutorial_home_record(3, Vector2i(cx + 13, cz + 12), Vector2i(cx + 13, cz + 17))
    var assignments := {
        "rowan": north_home,
        "sera": north_home,
        "toma": north_home,
        "niko": west_home,
        "lyra": west_home,
        "mira": elder_home
    }
    var updated := 0
    for actor_id in assignments.keys():
        if main.npc_system.update_npc_home_record(String(actor_id), assignments[actor_id]):
            updated += 1
    last_home_refresh_debug = {
        "ok": updated == assignments.size() and (not require_generated or not records.is_empty()),
        "reason": "refreshed" if updated == assignments.size() else "missing_npc_entry",
        "generatedRecordCount": records.size(),
        "updated": updated,
        "requiredGenerated": require_generated,
        "townKey": tutorial_town_key(),
        "miraHome": elder_home.duplicate(true)
    }
    return bool(last_home_refresh_debug.get("ok", false))

func resume_intro_elder_schedule() -> void:
    if main == null or main.npc_system == null or not main.npc_system.has_method("order_resume_schedule"):
        return
    main.npc_system.order_resume_schedule("mira")

func focus_dialogue_npc() -> void:
    if last_dialogue_node == null or main == null or main.npc_system == null or main.player == null:
        return
    if main.npc_system.has_method("focus_dialogue_npc"):
        main.npc_system.focus_dialogue_npc(last_dialogue_node, main.player.global_position)

func clear_dialogue_focus() -> void:
    last_dialogue_node = null
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
    if not ensure_dialogue_system():
        return false
    return dialogue_system.is_tutorial_npc(node)

func interact_with(node: Node) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.interact_with(node)

func handle_npc_quest(npc_id: String) -> String:
    if not ensure_dialogue_system():
        return ""
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
    if not ensure_rescue_system():
        return false
    return rescue_system.start_final_night()

func complete_final_night() -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.complete_final_night()

func final_night_defeats() -> int:
    if not ensure_rescue_system():
        return RESCUE_MONSTER_COUNT if final_night_complete else 0
    return rescue_system.final_night_defeats()

func current_hostile_defeats() -> int:
    if not ensure_rescue_system():
        return 0
    return rescue_system.current_hostile_defeats()

func setup_rescue_scene() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.setup_rescue_scene()

func choose_rescue_site() -> Vector3:
    if not ensure_rescue_system():
        return Vector3.ZERO
    return rescue_system.choose_rescue_site()

func spawn_rescue_torch(position: Vector3) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.spawn_rescue_torch(position)

func clear_rescue_torch() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.clear_rescue_torch()

func spawn_rescue_hostiles() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.spawn_rescue_hostiles()

func start_rescue_escort() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.start_rescue_escort()

func refresh_rescue_progress(delta := -1.0) -> bool:
    if not ensure_rescue_system():
        return false
    return rescue_system.refresh_rescue_progress(delta)

func rescue_remaining_hostiles() -> int:
    if not ensure_rescue_system():
        return 0
    return rescue_system.rescue_remaining_hostiles()

func start_rescue_return() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.start_rescue_return()

func rescue_return_position() -> Vector3:
    if not ensure_rescue_system():
        return Vector3.ZERO
    return rescue_system.rescue_return_position()

func rescue_party_home() -> bool:
    if not ensure_rescue_system():
        return true
    return rescue_system.rescue_party_home()

func settle_rescue_party_home() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.settle_rescue_party_home()

func find_tutorial_npc(npc_id: String) -> Node3D:
    if not ensure_rescue_system():
        return null
    return rescue_system.find_tutorial_npc(npc_id)

func show_speech_bubble(npc_id: String, text: String, duration := 2.6) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.show_speech_bubble(npc_id, text, duration)

func update_speech_bubbles(delta: float) -> void:
    if not ensure_rescue_system():
        return
    rescue_system.update_speech_bubbles(delta)

func clear_speech_bubbles() -> void:
    if not ensure_rescue_system():
        return
    rescue_system.clear_speech_bubbles()

func current_tutorial_stage() -> String:
    if not ensure_dialogue_system():
        return "intro" if not intro_bed_used else "wilds"
    return dialogue_system.current_tutorial_stage()

func npc_allowed_for_current_stage(npc_id: String) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.npc_allowed_for_current_stage(npc_id)

func locked_line_for_stage(npc_id: String) -> String:
    if not ensure_dialogue_system():
        return ""
    return dialogue_system.locked_line_for_stage(npc_id)

func is_after_training_hours() -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.is_after_training_hours()

func inventory_count(item_id: String) -> int:
    if not ensure_dialogue_system():
        return 0
    return dialogue_system.inventory_count(item_id)

func structure_count(block_type: String) -> int:
    if not ensure_dialogue_system():
        return 0
    return dialogue_system.structure_count(block_type)

func has_weapon(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_weapon(totals)

func has_axe(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_axe(totals)

func has_pickaxe(totals: Dictionary) -> bool:
    if not ensure_dialogue_system():
        return false
    return dialogue_system.has_pickaxe(totals)

func danger_profile(position: Vector3) -> Dictionary:
    if not ensure_dialogue_system():
        return {}
    return dialogue_system.danger_profile(position)

func ensure_town_generated() -> void:
    scene_builder.ensure_town_generated()
    ensure_tutorial_town_home_records(4)

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
    ensure_tutorial_town_home_records(4)
    scene_builder.spawn_tutorial_npcs()

func spawn_npc(spec: Dictionary, level: float, look_target: Vector3) -> Node3D:
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
