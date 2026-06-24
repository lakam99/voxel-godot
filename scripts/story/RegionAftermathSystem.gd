extends Node
class_name RegionAftermathSystem

const DAY_SECONDS := 600.0
const FIRST_QUEST_ID := "story.gloam_hart.storm"

var main
var story_director
var settlement_system
var last_message := ""

func setup(main_node, director_node, settlement_node) -> void:
    main = main_node
    story_director = director_node
    settlement_system = settlement_node
    reconstruct_after_load()

func reset() -> void:
    last_message = ""

func update(delta: float) -> void:
    sync_from_resolution()
    var state := current_aftermath_state()
    if state.is_empty() or String(state.get("status", "")) != "active":
        return
    advance_days(delta / DAY_SECONDS)

func sync_from_resolution() -> bool:
    var region_id := affected_region_id()
    var resolution := worldmark_resolution(region_id)
    if region_id == "" or resolution == "":
        return false
    var state := current_aftermath_state()
    if not state.is_empty():
        return false
    state = initial_aftermath_state(region_id, resolution)
    write_aftermath_state(region_id, state)
    apply_settlement_state(state)
    apply_visible_npc_activity(state)
    last_message = "Aftermath started: %s" % resolution
    return true

func advance_days(days: float) -> Dictionary:
    var region_id := affected_region_id()
    var state := current_aftermath_state()
    if region_id == "" or state.is_empty():
        return {}
    state["daysElapsed"] = maxf(0.0, float(state.get("daysElapsed", 0.0)) + maxf(0.0, days))
    apply_thresholds(state)
    write_aftermath_state(region_id, state)
    apply_settlement_state(state)
    apply_visible_npc_activity(state)
    return state.duplicate(true)

func advance_days_for_test(days: float) -> Dictionary:
    sync_from_resolution()
    return advance_days(days)

func reconstruct_after_load() -> void:
    var state := current_aftermath_state()
    if state.is_empty():
        sync_from_resolution()
        state = current_aftermath_state()
    if not state.is_empty():
        apply_settlement_state(state)
        apply_visible_npc_activity(state)

func initial_aftermath_state(region_id: String, resolution: String) -> Dictionary:
    var release := resolution == "release"
    return {
        "schemaVersion": 1,
        "status": "active",
        "regionId": region_id,
        "resolution": resolution,
        "daysElapsed": 0.0,
        "stormClearing": true,
        "stormCleared": false,
        "hostilePressureMultiplier": 0.65,
        "settlementTierUnlocked": false,
        "tradeLinkUnlocked": false,
        "serviceUnlocked": false,
        "cozySceneUnlocked": false,
        "cozySceneId": "",
        "residentActivity": "repair_public_space" if not release else "reopen_forage_paths",
        "wildlifeRecovery": "slow" if not release else "quick",
        "guardMood": "confident" if not release else "uncertain",
        "townRecord": "Gloam Hart %s" % ("released" if release else "slain"),
        "slayCombatRecipe": not release,
        "releaseNatureRoute": release,
        "distantHartMayAppear": release,
        "memorial": "hart_trophy_memorial" if not release else "living_compact_marker",
        "complete": false
    }

func apply_thresholds(state: Dictionary) -> void:
    var days := float(state.get("daysElapsed", 0.0))
    if days >= 0.5:
        state["stormCleared"] = true
        state["hostilePressureMultiplier"] = 0.45
    if days >= 1.0:
        state["settlementTierUnlocked"] = true
        state["tradeLinkUnlocked"] = true
        state["serviceUnlocked"] = true
        state["cozySceneUnlocked"] = true
        state["cozySceneId"] = "shared_meal"
    if days >= 2.0:
        state["status"] = "complete"
        state["complete"] = true
        state["hostilePressureMultiplier"] = 0.30

func apply_settlement_state(state: Dictionary) -> void:
    if settlement_system != null and settlement_system.has_method("apply_aftermath"):
        settlement_system.apply_aftermath(state)

func apply_visible_npc_activity(state: Dictionary) -> void:
    if main == null or main.get("npc_system") == null:
        return
    var npc_system = main.get("npc_system")
    var npcs_value = npc_system.get("npcs")
    if not (npcs_value is Array):
        return
    var activity := String(state.get("residentActivity", ""))
    var label := "repair public space" if activity == "repair_public_space" else "reopen forage paths"
    var applied := 0
    for entry_value in npcs_value:
        if applied >= 2 or not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var body := entry.get("body") as Node
        if body == null or not is_instance_valid(body):
            continue
        body.set_meta("story_aftermath_activity", activity)
        body.set_meta("npc_goal", label)
        applied += 1

func current_aftermath_state() -> Dictionary:
    var region_id := affected_region_id()
    if story_director == null or region_id == "":
        return {}
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var state_value = worldmark.get("aftermathState", {})
    return state_value.duplicate(true) if state_value is Dictionary else {}

func write_aftermath_state(region_id: String, state: Dictionary) -> void:
    if story_director == null or region_id == "":
        return
    var record: Dictionary = story_director.region_records.get(region_id, {})
    if record.is_empty():
        record = story_director.ensure_region_record_for_id(region_id)
    var worldmark: Dictionary = record.get("worldmark", {})
    worldmark["aftermathState"] = state.duplicate(true)
    record["worldmark"] = worldmark
    story_director.region_records[region_id] = record

func affected_region_id() -> String:
    if story_director == null or story_director.quest_system == null:
        return ""
    var quest: Dictionary = story_director.quest_system.first_quest() if story_director.quest_system.has_method("first_quest") else {}
    return String(quest.get("affectedRegionId", ""))

func worldmark_resolution(region_id: String) -> String:
    if story_director == null or region_id == "":
        return ""
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    return String(worldmark.get("resolution", ""))

func debug_state() -> Dictionary:
    var state := current_aftermath_state()
    if state.is_empty():
        return { "active": false, "lastMessage": last_message }
    state["active"] = String(state.get("status", "")) == "active"
    state["lastMessage"] = last_message
    return state
