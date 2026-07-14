extends RefCounted
class_name TutorialDialogueSystem

const CELL := 1.35
const SAFE_RADIUS_CELLS := 24
const INTRO_REQUIRED_FENCE := 8
const INTRO_REQUIRED_LAMPS := 4
const RESCUE_MONSTER_COUNT := 6
const RESCUE_GUARD_ID := "sera"
const RESCUE_FORAGER_ID := "niko"

var system
var main

func setup(tutorial_system) -> void:
    system = tutorial_system
    main = system.main

func is_tutorial_npc(node: Node) -> bool:
    return node != null and String(node.get_meta("story_actor_scope", "")) == "tutorial"

func interact_with(node: Node) -> bool:
    if not is_tutorial_npc(node):
        return false
    var npc_id := String(node.get_meta("npc_id", ""))
    var npc_name := String(node.get_meta("npc_name", "Villager"))
    var npc_role := String(node.get_meta("npc_role", ""))
    system.last_dialogue_node = node
    emit_npc_spoken_event(node, npc_id, npc_name, npc_role)
    if not system.intro_bed_used and npc_id != "mira":
        var locked_line := "Help Mira finish the fence and lamps first. We can talk properly after dawn."
        system.last_message = "%s: %s" % [npc_name, locked_line]
        system.last_dialogue = make_dialogue_payload(npc_name, npc_role, locked_line, npc_id, false)
        return true
    if system.intro_bed_used and not system.mira_morning_briefed() and npc_id != "mira":
        var locked_line := "Mira asked to speak with you after sunrise. Start with them before taking work from anyone else."
        system.last_message = "%s: %s" % [npc_name, locked_line]
        system.last_dialogue = make_dialogue_payload(npc_name, npc_role, locked_line, npc_id, false)
        return true
    if system.intro_bed_used and is_after_training_hours() and npc_id != "mira":
        var night_line := "Come talk to me in the morning. We do not send new hands into errands after dark."
        system.last_message = "%s: %s" % [npc_name, night_line]
        system.last_dialogue = make_dialogue_payload(npc_name, npc_role, night_line, npc_id, false)
        return true
    if system.intro_bed_used and system.mira_morning_briefed() and not npc_allowed_for_current_stage(npc_id):
        var stage_line := locked_line_for_stage(npc_id)
        system.last_message = "%s: %s" % [npc_name, stage_line]
        system.last_dialogue = make_dialogue_payload(npc_name, npc_role, stage_line, npc_id, false)
        return true
    var lines_value = node.get_meta("dialogue", [])
    var lines: Array = lines_value if lines_value is Array else []
    var index := clampi(int(node.get_meta("dialogue_index", 0)), 0, maxi(0, lines.size() - 1))
    var line := "Stay inside the lights until you're ready."
    if lines.size() > 0:
        line = String(lines[index])
    if lines.size() > 1:
        node.set_meta("dialogue_index", mini(index + 1, lines.size() - 1))
    system.interacted[npc_id] = true
    var quest_line := handle_npc_quest(npc_id)
    if quest_line != "":
        line = quest_line
    var story_reaction := story_reaction_line(node, npc_id, npc_name, npc_role, line)
    if story_reaction != "":
        line = story_reaction
    system.last_message = "%s: %s" % [npc_name, line]
    system.last_dialogue = make_dialogue_payload(npc_name, npc_role, line, npc_id, npc_id == "mira" and system.is_intro_elder_waiting_for_ack())
    if main and main.has_method("update_objectives_and_contracts"):
        main.update_objectives_and_contracts()
    if main and main.has_method("award_progression") and not bool(node.get_meta("xp_awarded", false)):
        node.set_meta("xp_awarded", true)
        main.award_progression("Met %s" % npc_name, 4)
    return true

func story_reaction_line(node: Node, npc_id: String, npc_name: String, npc_role: String, fallback_line: String) -> String:
    if main == null or main.get("story_dialogue_router") == null:
        return ""
    var router = main.get("story_dialogue_router")
    if not router.has_method("response_for_npc"):
        return ""
    var response: Dictionary = router.response_for_npc(npc_id, npc_name, npc_role, fallback_line)
    if not bool(response.get("handled", false)):
        return ""
    router.last_response = response.duplicate(true)
    return String(response.get("text", ""))

func handle_npc_quest(npc_id: String) -> String:
    match npc_id:
        "mira":
            return handle_mira_quest()
        "rowan":
            return handle_rowan_quest()
        "niko":
            return handle_niko_quest()
        "sera":
            return handle_sera_quest()
    return ""

func emit_npc_spoken_event(node: Node, npc_id: String, npc_name: String, npc_role: String) -> void:
    if main == null or npc_id == "" or not main.has_method("emit_story_event"):
        return
    var position := (node as Node3D).global_position if node is Node3D else Vector3.INF
    var region_id: String = main.story_region_id_for_world_position(position) if main.has_method("story_region_id_for_world_position") else ""
    main.emit_story_event("npc_spoken_to", "npc:%s" % npc_id, region_id, "npc_spoken:%s:%s" % [npc_id, current_tutorial_stage()], position, {
        "npcId": npc_id,
        "name": npc_name,
        "role": npc_role,
        "tutorial": true
    })

func handle_mira_quest() -> String:
    if not system.intro_door_opened:
        system.intro_door_opened = true
        system.intro_elder_dialogue_acknowledged = false
        system.complete_step("introDoorOpened")
        return "I'm sorry to wake you. Monsters broke the outer lamps and fence. Take wood and stone from the town chest and patch the gaps before anyone sleeps."
    if system.intro_repair_active and not system.intro_repair_complete:
        return "Use the repair chest by the square. We need %d fence blocks and %d lamps placed back on the broken perimeter." % [INTRO_REQUIRED_FENCE, INTRO_REQUIRED_LAMPS]
    if system.intro_repair_complete and not system.intro_bed_used:
        return "That will hold until morning. Use your bed and sleep through the rest of the storm."
    if not system.mira_morning_briefed():
        system.complete_step("miraMorningBriefing")
        return "Thank you for last night. Despite everything you have lost, you showed us you can stand with the village. Niko is going out to gather food; find them and learn how to forage before we ask more of you."
    if not bool(system.completed_steps.get("nikoBerries", false)):
        return "Start with Niko. Food comes first; a tired survivor makes poor choices."
    if not bool(system.completed_steps.get("rowanBlocks", false)):
        return "Now find Rowan. An axe, a pickaxe, logs, and stone are how we turn panic into shelter."
    if not bool(system.completed_steps.get("seraWeapon", false)):
        return "Sera has the final lesson. Craft a weapon before you stand beyond the lanterns."
    if system.is_ready_for_wilds():
        if system.final_night_complete:
            system.complete_step("miraBlessing")
            return "You brought Niko home. You have food, tools, a weapon, and the village at your back. Sleep when you are ready for dawn."
        if system.final_night_active:
            if not system.rescue_escort_started:
                return "Niko stayed out too late. Sera knows the trail; speak with them and follow close."
            if system.rescue_returning:
                return "Get Niko and Sera back inside the lanterns. The storm is almost spent."
            return "Niko's torch is holding the swarm back. Clear the monsters around them."
        system.start_final_night()
        return "Niko stayed out too late and is pinned beyond the lamps. Speak with Sera at the gate and follow them to the rescue."
    return "One step at a time. Forage, gather, build, then arm yourself."

func handle_rowan_quest() -> String:
    system.unlock_crafting_group("rowan_basic_tools", "Rowan's basic tools")
    var rowan_totals: Dictionary = main.inventory_system.totals() if main and main.inventory_system else {}
    if not bool(system.completed_steps.get("rowanAxe", false)):
        if has_axe(rowan_totals):
            system.complete_step("rowanAxe")
            return "Good. An axe makes every log easier. Use it and bring me 4 logs."
        return "Craft a wooden axe at a workbench first. You already patched the gate with blocks; now learn the tool."
    if not bool(system.completed_steps.get("rowanLogs", false)):
        if inventory_count("logs") >= 4:
            system.complete_step("rowanLogs")
            system.award_once("rowanLogsReward", "Rowan: gathered logs", { "stones": 1 }, 8)
            return "Good logs. Next craft a wooden pickaxe so stone is not just something you trip over."
        return "Bring me 4 logs with that axe. The trees inside the village edge are safe to cut."
    if not bool(system.completed_steps.get("rowanLogsReward", false)):
        system.award_once("rowanLogsReward", "Rowan: gathered logs", { "stones": 1 }, 8)
        return "Good logs. Next craft a wooden pickaxe so stone is not just something you trip over."
    if not bool(system.completed_steps.get("rowanPickaxe", false)):
        if has_pickaxe(rowan_totals):
            system.complete_step("rowanPickaxe")
            system.award_once("rowanPickaxeReward", "Rowan: pickaxe ready", { "logs": 1 }, 8)
            return "Pickaxe ready. Break rocks and bring me 4 stones."
        return "Craft a wooden pickaxe at a workbench. Three logs are enough for the first one."
    if not bool(system.completed_steps.get("rowanPickaxeReward", false)):
        system.award_once("rowanPickaxeReward", "Rowan: pickaxe ready", { "logs": 1 }, 8)
        return "Pickaxe ready. Break rocks and bring me 4 stones."
    if not bool(system.completed_steps.get("rowanStones", false)):
        if inventory_count("stones") >= 4:
            system.complete_step("rowanStones")
            system.complete_step("rowanBlocks")
            system.award_once("rowanBlocksReward", "Rowan: timber and stone", { "torch": 2 }, 10)
            return "Now you understand wood and stone. Take two torches for the road."
        return "Use the pickaxe on rocks and bring me 4 stones."
    if not bool(system.completed_steps.get("rowanBlocksReward", false)):
        system.award_once("rowanBlocksReward", "Rowan: timber and stone", { "torch": 2 }, 10)
        return "Now you understand wood and stone. Take two torches for the road."
    return "Your hands know the basics now. Tools first, structures after."

func handle_niko_quest() -> String:
    if not bool(system.completed_steps.get("nikoBerries", false)):
        if inventory_count("berries") >= 2:
            if main and main.inventory_system:
                main.inventory_system.consume_costs({ "berries": 2 })
            system.complete_step("nikoBerries")
            system.award_once("nikoFoodReward", "Niko: packed food", { "fieldRation": 1 }, 10)
            return "Berries packed. I traded them into a field ration; eat before hunger slows you."
        return "Find 2 berries near the village edge. Food keeps stamina from collapsing."
    if not bool(system.completed_steps.get("nikoFoodReward", false)):
        if inventory_count("berries") >= 2 and main and main.inventory_system:
            main.inventory_system.consume_costs({ "berries": 2 })
        system.award_once("nikoFoodReward", "Niko: packed food", { "fieldRation": 1 }, 10)
        return "Berries packed. I traded them into a field ration; eat before hunger slows you."
    return "Keep a ration ready before you leave the lanterns."

func handle_sera_quest() -> String:
    system.unlock_crafting_group("rescue_weapon", "rescue weapon training")
    var sera_totals: Dictionary = main.inventory_system.totals() if main and main.inventory_system else {}
    if system.final_night_active and not system.final_night_complete:
        if not system.rescue_escort_started:
            system.start_rescue_escort()
            return "Niko is surrounded beyond the lamps. Stay on my heels; we cut through to the torch."
        if system.rescue_returning:
            return "Niko is moving. Keep the path clear until we reach the village."
        return "Focus the monsters around Niko. The torch will not hold forever."
    if not bool(system.completed_steps.get("seraWeapon", false)):
        if has_weapon(sera_totals):
            system.complete_step("seraWeapon")
            system.award_once("seraWeaponReward", "Sera: armed for patrol", { "arrows": 8, "torch": 1 }, 12)
            system.complete_step_if("readyForWilds", system.is_ready_for_wilds())
            return "Now you can defend yourself. The shadows outside the lights will test that."
        return "Craft a wooden sword, stone sword, or bow before crossing the last lantern."
    if not bool(system.completed_steps.get("seraWeaponReward", false)):
        system.award_once("seraWeaponReward", "Sera: armed for patrol", { "arrows": 8, "torch": 1 }, 12)
        system.complete_step_if("readyForWilds", system.is_ready_for_wilds())
        return "Now you can defend yourself. The shadows outside the lights will test that."
    if system.is_ready_for_wilds():
        return "Stay in the light to rest. Step beyond it only when you mean to fight."
    return "Weapon alone is not enough. Get food and shelter supplies before the wilds."

func make_dialogue_payload(speaker: String, role: String, text: String, npc_id: String, intro_elder := false) -> Dictionary:
    return {
        "speaker": speaker,
        "role": role,
        "text": text,
        "npcId": npc_id,
        "introElder": intro_elder
    }

func current_tutorial_stage() -> String:
    if not system.intro_bed_used:
        return "introNight"
    if not system.mira_morning_briefed():
        return "miraMorning"
    if not bool(system.completed_steps.get("nikoBerries", false)):
        return "foraging"
    if not bool(system.completed_steps.get("rowanLogs", false)):
        return "gathering"
    if not bool(system.completed_steps.get("rowanBlocks", false)):
        return "crafting"
    if not bool(system.completed_steps.get("seraWeapon", false)):
        return "weapons"
    if system.final_night_active:
        return "finalNight"
    if not system.final_night_complete:
        return "finalBriefing"
    if not bool(system.completed_steps.get("miraBlessing", false)):
        return "ready"
    return "ready"

func npc_allowed_for_current_stage(npc_id: String) -> bool:
    if npc_id == "mira":
        return true
    match current_tutorial_stage():
        "foraging":
            return npc_id == "niko"
        "gathering", "crafting":
            return npc_id == "rowan"
        "weapons":
            return npc_id == "sera"
        "finalBriefing":
            return npc_id == "mira"
        "finalNight":
            return npc_id in [RESCUE_GUARD_ID, RESCUE_FORAGER_ID, "mira"]
        "ready":
            return true
    return false

func locked_line_for_stage(npc_id: String) -> String:
    match current_tutorial_stage():
        "miraMorning":
            return "Speak with Mira first. They are setting the work for the day."
        "foraging":
            return "Niko is gathering food near the village edge. Learn foraging before we move on."
        "gathering":
            return "Rowan is teaching tool work next: axe for logs, pickaxe for stone."
        "crafting":
            return "Stay with Rowan until you have gathered both wood and stone with tools."
        "weapons":
            return "Sera has the next lesson. Do not leave the lanterns unarmed."
        "finalBriefing":
            return "Mira wants to speak before the final perimeter drill."
        "finalNight":
            return "The perimeter is under attack. Stay near the lanterns and fight with the guards."
    return "Finish the current village task first."

func is_after_training_hours() -> bool:
    if main == null:
        return false
    var phase := float(main.call("clock_phase")) if main.has_method("clock_phase") else float(main.time_of_day)
    var hour := phase * 24.0
    return (hour < 6.0 or hour >= 18.0) and not (current_tutorial_stage() in ["finalBriefing", "finalNight", "ready"])

func inventory_count(item_id: String) -> int:
    if main == null or main.inventory_system == null:
        return 0
    return main.inventory_system.count(item_id)

func structure_count(block_type: String) -> int:
    if main == null or not main.has_method("structure_counts"):
        return 0
    return int(main.structure_counts().get(block_type, 0))

func has_weapon(totals: Dictionary) -> bool:
    for item_id in ["woodenSword", "stoneSword", "copperSword", "ironSword", "nightBlade", "hunterBow", "ironCrossbow"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func has_axe(totals: Dictionary) -> bool:
    for item_id in ["woodenAxe", "stoneAxe", "copperAxe", "ironAxe"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func has_pickaxe(totals: Dictionary) -> bool:
    for item_id in ["woodenPickaxe", "stonePickaxe", "copperPickaxe", "ironPickaxe"]:
        if int(totals.get(item_id, 0)) > 0:
            return true
    return false

func danger_profile(position: Vector3) -> Dictionary:
    if not system.started or system.town.is_empty():
        return {}
    var center := Vector3(float(system.town.get("centerX", 0)) * CELL, float(system.town.get("level", 16.0)), float(system.town.get("centerZ", 0)) * CELL)
    var flat_distance := Vector2(position.x - center.x, position.z - center.z).length()
    var safe_radius := CELL * float(SAFE_RADIUS_CELLS)
    return {
        "active": flat_distance <= CELL * 72.0,
        "center": center,
        "safeRadius": safe_radius,
        "outerRadius": CELL * 56.0,
        "outsideLights": flat_distance > safe_radius,
        "finalNight": system.final_night_active,
        "rescueMission": system.final_night_active and not system.final_night_complete,
        "rescueEscortStarted": system.rescue_escort_started,
        "rescueReturning": system.rescue_returning,
        "rescueRemaining": system.rescue_remaining_hostiles(),
        "finalNightDefeats": system.final_night_defeats(),
        "finalNightRequired": RESCUE_MONSTER_COUNT,
        "readyForWilds": system.is_ready_for_wilds()
    }
