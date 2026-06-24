extends Node
class_name StoryDebugTools

const FIRST_QUEST_ID := "story.gloam_hart.storm"
const STAGE_ORDER := [
    "speak_with_mira",
    "speak_with_sera",
    "travel_to_affected_region",
    "find_ordinary_clues",
    "optional_find_historical_clue",
    "prepare_countermeasure_placeholder",
    "retune_boundary_stones_placeholder",
    "encounter_locked_placeholder",
    "worldmark_resolved"
]

var main
var story_director
var last_result := {}

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node

func is_available() -> bool:
    return OS.is_debug_build() or OS.get_environment("VOXEL_PLAYTEST") == "1" or OS.get_environment("VOXEL_STORY_PLAYTEST") == "1" or OS.get_environment("VOXEL_STORY_DEBUG") == "1"

func run_command(command: String, args := {}) -> Dictionary:
    if not is_available():
        return remember(false, command, "Story debug tools are disabled")
    var data: Dictionary = args if args is Dictionary else {}
    match command:
        "jump_to_quest_stage":
            return jump_to_quest_stage(String(data.get("stage", "")), String(data.get("regionId", "")))
        "reveal_clue":
            return reveal_clue(String(data.get("definitionId", data.get("clueId", ""))))
        "enter_region":
            return enter_region(String(data.get("regionId", "")))
        "start_encounter":
            return start_encounter(String(data.get("regionId", "")))
        "choose_resolution":
            return choose_resolution(String(data.get("resolution", "")), String(data.get("regionId", "")))
        "advance_aftermath_day":
            return advance_aftermath_day(float(data.get("days", 1.0)))
        "dump_region_record":
            return dump_region_record(String(data.get("regionId", "")))
        "clear_generated_prose_cache":
            return clear_generated_prose_cache()
    return remember(false, command, "Unknown story debug command")

func jump_to_quest_stage(stage: String, region_id := "") -> Dictionary:
    if not STAGE_ORDER.has(stage):
        return remember(false, "jump_to_quest_stage", "Unknown quest stage %s" % stage)
    var quest := ensure_first_quest(region_id)
    if quest.is_empty():
        return remember(false, "jump_to_quest_stage", "Could not create first story quest")
    var target_region := region_id if region_id != "" else String(quest.get("affectedRegionId", ""))
    if target_region != "":
        quest["affectedRegionId"] = target_region
        if story_director != null and story_director.has_method("mark_gloam_hart_region"):
            story_director.mark_gloam_hart_region(target_region, String(quest.get("affectedRegionBiome", "")))
    apply_stage_prerequisites(quest, stage)
    var quest_system = story_director.quest_system if story_director != null else null
    if quest_system != null:
        if quest_system.has_method("set_stage"):
            quest_system.set_stage(quest, stage)
        else:
            quest["stage"] = stage
            quest["stageIndex"] = STAGE_ORDER.find(stage)
        quest_system.quests[FIRST_QUEST_ID] = quest
    return remember(true, "jump_to_quest_stage", "Quest moved to %s" % stage, { "quest": quest.duplicate(true) })

func reveal_clue(definition_id: String) -> Dictionary:
    if definition_id == "":
        return remember(false, "reveal_clue", "Missing clue definition id")
    var quest := ensure_first_quest("")
    var region_id := String(quest.get("affectedRegionId", ""))
    if region_id == "":
        return remember(false, "reveal_clue", "No affected region")
    var clue_kind := "historical" if definition_id.find("historical") >= 0 or definition_id.find("compact") >= 0 else "ordinary"
    var facts: Dictionary = quest.get("facts", {}) if quest.get("facts", {}) is Dictionary else {}
    if clue_kind == "ordinary":
        var ids: Array = facts.get("ordinaryClueIds", [])
        if not ids.has(definition_id):
            ids.append(definition_id)
        facts["ordinaryClueIds"] = ids
        facts["ordinaryCluesFound"] = ids.size()
    else:
        facts["historyClueFound"] = true
        facts["historicalClueId"] = definition_id
        facts["releaseRouteUnlocked"] = true
        if bool(facts.get("stormWeakened", false)):
            facts["releaseRouteAvailable"] = true
        var optional: Dictionary = quest.get("optionalObjectives", {}) if quest.get("optionalObjectives", {}) is Dictionary else {}
        optional["learn_old_compact"] = true
        quest["optionalObjectives"] = optional
    quest["facts"] = facts
    story_director.quest_system.quests[FIRST_QUEST_ID] = quest
    if main != null and main.has_method("emit_story_event"):
        main.emit_story_event(
            "story_clue_found",
            "debug_clue:%s" % definition_id,
            region_id,
            "debug_story_clue:%s:%d" % [definition_id, Time.get_ticks_msec()],
            Vector3.INF,
            {
                "clueKind": clue_kind,
                "clueId": definition_id,
                "source": "story_debug_tools"
            }
        )
    return remember(true, "reveal_clue", "%s revealed" % definition_id, { "clueKind": clue_kind, "quest": first_quest().duplicate(true) })

func enter_region(region_id: String) -> Dictionary:
    if region_id == "":
        region_id = affected_region_id()
    if region_id == "":
        return remember(false, "enter_region", "No region id")
    var generator = main.get("region_story_generator") if main != null else null
    if generator == null:
        return remember(false, "enter_region", "Region generator unavailable")
    var center: Vector2i = generator.region_center_cell(region_id)
    var biome := String(main.biome_at_cell(center.x, center.y)) if main != null and main.has_method("biome_at_cell") else ""
    if main != null:
        main.set("last_story_region_id", "")
        main.update_story_region_entry(center, Vector3(float(center.x) * main.CELL, 0.0, float(center.y) * main.CELL), biome)
    return remember(true, "enter_region", "Entered %s" % region_id, { "cell": [center.x, center.y], "biome": biome })

func start_encounter(region_id := "") -> Dictionary:
    if region_id == "":
        region_id = affected_region_id()
    if region_id == "":
        return remember(false, "start_encounter", "No region id")
    var overlay = main.get("story_world_overlay_system") if main != null else null
    if overlay != null and overlay.has_method("ensure_sites_for_region"):
        overlay.ensure_sites_for_region(region_id)
    var controller = main.get("worldmark_encounter_controller") if main != null else null
    if controller == null or not controller.has_method("start_encounter"):
        return remember(false, "start_encounter", "Encounter controller unavailable")
    var started := bool(controller.start_encounter(region_id, Vector3.INF, 1, false))
    return remember(started, "start_encounter", "Encounter %s" % ("started" if started else "not started"), controller.debug_state() if controller.has_method("debug_state") else {})

func choose_resolution(resolution: String, region_id := "") -> Dictionary:
    if not (resolution in ["slay", "release"]):
        return remember(false, "choose_resolution", "Resolution must be slay or release")
    if region_id == "":
        region_id = affected_region_id()
    var controller = main.get("worldmark_encounter_controller") if main != null else null
    if controller == null or region_id == "":
        return remember(false, "choose_resolution", "Cannot resolve without controller and region")
    var resolved := bool(controller.resolve_region(region_id, resolution, Vector3.INF))
    return remember(resolved, "choose_resolution", "Resolution %s %s" % [resolution, "applied" if resolved else "not applied"], dump_region(region_id))

func advance_aftermath_day(days := 1.0) -> Dictionary:
    var aftermath = main.get("region_aftermath_system") if main != null else null
    if aftermath == null:
        return remember(false, "advance_aftermath_day", "Aftermath system unavailable")
    var state: Dictionary = aftermath.advance_days_for_test(maxf(0.0, days)) if aftermath.has_method("advance_days_for_test") else {}
    return remember(not state.is_empty(), "advance_aftermath_day", "Advanced aftermath by %.2f days" % days, state)

func dump_region_record(region_id := "") -> Dictionary:
    if region_id == "":
        region_id = affected_region_id()
    var record := dump_region(region_id)
    return remember(not record.is_empty(), "dump_region_record", "Dumped %s" % region_id, record)

func clear_generated_prose_cache() -> Dictionary:
    if story_director == null:
        return remember(false, "clear_generated_prose_cache", "Story director unavailable")
    var generated: Dictionary = story_director.get("generated_text")
    var cache: Dictionary = generated.get("narrativeText", {}) if generated.get("narrativeText", {}) is Dictionary else {}
    var cleared := cache.size()
    generated["narrativeText"] = {}
    story_director.set("generated_text", generated)
    return remember(true, "clear_generated_prose_cache", "Cleared %d generated prose entries" % cleared, { "cleared": cleared })

func ensure_first_quest(region_id := "") -> Dictionary:
    var quest := first_quest()
    if not quest.is_empty():
        return quest
    if story_director == null or not story_director.has_method("ingest_event"):
        return {}
    var starter_region := region_id if region_id != "" else "r:1,0"
    story_director.ingest_event({
        "schemaVersion": 1,
        "type": "tutorial_final_rescue_complete",
        "subjectId": "tutorial:final_rescue",
        "regionId": starter_region,
        "dedupeKey": "debug:tutorial_final_rescue:%d" % Time.get_ticks_msec(),
        "worldTime": 0.0,
        "position": [],
        "payload": { "source": "story_debug_tools" }
    })
    return first_quest()

func apply_stage_prerequisites(quest: Dictionary, stage: String) -> void:
    var facts: Dictionary = quest.get("facts", {}) if quest.get("facts", {}) is Dictionary else {}
    var index := STAGE_ORDER.find(stage)
    if index >= STAGE_ORDER.find("speak_with_sera"):
        facts["miraSpoken"] = true
    if index >= STAGE_ORDER.find("travel_to_affected_region"):
        facts["seraSpoken"] = true
    if index >= STAGE_ORDER.find("find_ordinary_clues"):
        facts["enteredAffectedRegion"] = true
    if index >= STAGE_ORDER.find("prepare_countermeasure_placeholder"):
        facts["ordinaryClueIds"] = ["ordinary_antler_scars", "ordinary_ringing_stone"]
        facts["ordinaryCluesFound"] = 2
    if index >= STAGE_ORDER.find("retune_boundary_stones_placeholder"):
        facts["countermeasurePrepared"] = true
        facts["countermeasureItems"] = ["surveyLens", "wardLantern"]
        facts["countermeasureSource"] = "story_debug_tools"
    if index >= STAGE_ORDER.find("encounter_locked_placeholder"):
        facts["boundaryStoneIds"] = ["boundary_stone_north", "boundary_stone_south"]
        facts["boundaryStonesRetuned"] = 2
        facts["stormWeakened"] = true
        facts["encounterUnlocked"] = true
        facts["combatRouteUnlocked"] = true
        facts["encounterLocked"] = false
        facts["releaseRouteAvailable"] = bool(facts.get("historyClueFound", false))
    if stage == "worldmark_resolved":
        facts["worldmarkResolved"] = true
        facts["resolution"] = "slay"
    quest["facts"] = facts

func first_quest() -> Dictionary:
    if story_director == null or story_director.quest_system == null or not story_director.quest_system.has_method("first_quest"):
        return {}
    return story_director.quest_system.first_quest()

func affected_region_id() -> String:
    var quest := first_quest()
    return String(quest.get("affectedRegionId", ""))

func dump_region(region_id: String) -> Dictionary:
    if story_director == null or region_id == "":
        return {}
    var record: Dictionary = story_director.region_records.get(region_id, {})
    if record.is_empty() and story_director.has_method("ensure_region_record_for_id"):
        record = story_director.ensure_region_record_for_id(region_id)
    return record.duplicate(true)

func remember(ok: bool, command: String, message: String, data := {}) -> Dictionary:
    last_result = {
        "ok": ok,
        "command": command,
        "message": message,
        "data": data.duplicate(true) if data is Dictionary else data
    }
    return last_result.duplicate(true)

func debug_state() -> Dictionary:
    return {
        "available": is_available(),
        "commands": [
            "jump_to_quest_stage",
            "reveal_clue",
            "enter_region",
            "start_encounter",
            "choose_resolution",
            "advance_aftermath_day",
            "dump_region_record",
            "clear_generated_prose_cache"
        ],
        "lastResult": last_result.duplicate(true)
    }
