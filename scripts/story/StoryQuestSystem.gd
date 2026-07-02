extends Node
class_name StoryQuestSystem

const GloamHartArcScript := preload("res://scripts/story/arcs/GloamHartArc.gd")

const FIRST_QUEST_ID := "story.gloam_hart.storm"
const ARC_ID := "storm_that_stays"
const ORDINARY_CLUES_REQUIRED := 2
const STAGE_SPEAK_WITH_MIRA := "speak_with_mira"
const STAGE_SPEAK_WITH_SERA := "speak_with_sera"
const STAGE_TRAVEL_TO_AFFECTED_REGION := "travel_to_affected_region"
const STAGE_FIND_ORDINARY_CLUES := "find_ordinary_clues"
const STAGE_OPTIONAL_FIND_HISTORICAL_CLUE := "optional_find_historical_clue"
const STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER := "prepare_countermeasure_placeholder"
const STAGE_RETUNE_BOUNDARY_STONES_PLACEHOLDER := "retune_boundary_stones_placeholder"
const STAGE_ENCOUNTER_LOCKED_PLACEHOLDER := "encounter_locked_placeholder"
const STAGE_WORLDMARK_RESOLVED := "worldmark_resolved"
const STAGE_ORDER := [
    STAGE_SPEAK_WITH_MIRA,
    STAGE_SPEAK_WITH_SERA,
    STAGE_TRAVEL_TO_AFFECTED_REGION,
    STAGE_FIND_ORDINARY_CLUES,
    STAGE_OPTIONAL_FIND_HISTORICAL_CLUE,
    STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER,
    STAGE_RETUNE_BOUNDARY_STONES_PLACEHOLDER,
    STAGE_ENCOUNTER_LOCKED_PLACEHOLDER,
    STAGE_WORLDMARK_RESOLVED
]

var main
var story_director
var quests := {}

func setup(main_node, director_node = null) -> void:
    main = main_node
    if director_node != null:
        story_director = director_node

func set_story_director(director_node) -> void:
    story_director = director_node

func reset() -> void:
    quests.clear()

func handle_event(event: Dictionary) -> bool:
    var event_type := String(event.get("type", ""))
    if event_type == "tutorial_final_rescue_complete":
        return start_first_arc(event)
    if not quests.has(FIRST_QUEST_ID):
        return false
    match event_type:
        "npc_spoken_to":
            return handle_npc_spoken(event)
        "story_region_entered":
            return handle_region_entered(event)
        "story_clue_found":
            return handle_clue_found(event)
        "story_countermeasure_prepared":
            return handle_countermeasure_prepared(event)
        "story_boundary_stone_retuned":
            return handle_boundary_stone_retuned(event)
        "story_worldmark_resolved":
            return handle_worldmark_resolved(event)
    return false

func snapshot() -> Dictionary:
    return quests.duplicate(true)

func restore(snapshot_value) -> void:
    quests.clear()
    if snapshot_value is Dictionary:
        quests = snapshot_value.duplicate(true)

func start_first_arc(event: Dictionary) -> bool:
    if quests.has(FIRST_QUEST_ID):
        return false
    var starter_region_id := starter_region_id_from_event(event)
    var affected_region_id := select_first_affected_region(starter_region_id)
    var affected_biome := dominant_biome_for_region(affected_region_id)
    var opening_definition: Dictionary = GloamHartArcScript.opening_definition()
    if story_director != null and story_director.has_method("mark_gloam_hart_region"):
        story_director.mark_gloam_hart_region(affected_region_id, affected_biome)
    if main != null and main.get("story_world_overlay_system") != null:
        var overlay = main.get("story_world_overlay_system")
        if overlay.has_method("ensure_sites_for_region"):
            overlay.ensure_sites_for_region(affected_region_id)
    quests[FIRST_QUEST_ID] = {
        "id": FIRST_QUEST_ID,
        "arcId": ARC_ID,
        "status": "active",
        "stage": STAGE_SPEAK_WITH_MIRA,
        "stageIndex": stage_index(STAGE_SPEAK_WITH_MIRA),
        "tracked": true,
        "titleId": "story.gloam_hart.storm.title",
        "label": String(opening_definition.get("label", "The Storm That Stays")),
        "worldmarkDefinitionId": String(opening_definition.get("worldmarkDefinitionId", "gloam_hart")),
        "openingHandoff": opening_definition.get("handoff", {}),
        "starterRegionId": starter_region_id,
        "affectedRegionId": affected_region_id,
        "affectedRegionBiome": affected_biome,
        "stageOrder": STAGE_ORDER.duplicate(),
        "stageTextIds": {
            STAGE_SPEAK_WITH_MIRA: "story.gloam_hart.stage.speak_with_mira",
            STAGE_SPEAK_WITH_SERA: "story.gloam_hart.stage.speak_with_sera",
            STAGE_TRAVEL_TO_AFFECTED_REGION: "story.gloam_hart.stage.travel_to_affected_region",
            STAGE_FIND_ORDINARY_CLUES: "story.gloam_hart.stage.find_ordinary_clues",
            STAGE_OPTIONAL_FIND_HISTORICAL_CLUE: "story.gloam_hart.stage.optional_find_historical_clue",
            STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER: "story.gloam_hart.stage.prepare_countermeasure_placeholder",
            STAGE_RETUNE_BOUNDARY_STONES_PLACEHOLDER: "story.gloam_hart.stage.retune_boundary_stones_placeholder",
            STAGE_ENCOUNTER_LOCKED_PLACEHOLDER: "story.gloam_hart.stage.encounter_locked_placeholder",
            STAGE_WORLDMARK_RESOLVED: "story.gloam_hart.stage.worldmark_resolved"
        },
        "facts": {
            "miraSpoken": false,
            "seraSpoken": false,
            "enteredAffectedRegion": false,
            "ordinaryCluesFound": 0,
            "ordinaryClueIds": [],
            "historyClueFound": false,
            "historicalClueId": "",
            "releaseRouteUnlocked": false,
            "countermeasurePrepared": false,
            "countermeasureItems": [],
            "countermeasureSource": "",
            "boundaryStonesRetuned": 0,
            "boundaryStoneIds": [],
            "lastBoundaryStoneRetuned": "",
            "stormWeakened": false,
            "encounterUnlocked": false,
            "combatRouteUnlocked": false,
            "releaseRouteAvailable": false,
            "encounterLocked": true,
            "worldmarkResolved": false,
            "resolution": "",
            "rewardsGranted": false
        },
        "optionalObjectives": {
            "learn_old_compact": false
        }
    }
    return true

func handle_npc_spoken(event: Dictionary) -> bool:
    var quest := first_quest()
    var payload := payload_from_event(event)
    var npc_id := String(payload.get("npcId", subject_suffix(String(event.get("subjectId", "")))))
    var stage := String(quest.get("stage", ""))
    if stage == STAGE_SPEAK_WITH_MIRA and npc_id == "mira":
        var facts := facts_for_quest(quest)
        facts["miraSpoken"] = true
        quest["facts"] = facts
        set_stage(quest, STAGE_SPEAK_WITH_SERA)
        quests[FIRST_QUEST_ID] = quest
        return true
    if stage == STAGE_SPEAK_WITH_SERA and npc_id == "sera" and bool(facts_for_quest(quest).get("miraSpoken", false)):
        var facts := facts_for_quest(quest)
        facts["seraSpoken"] = true
        quest["facts"] = facts
        set_stage(quest, STAGE_TRAVEL_TO_AFFECTED_REGION)
        quests[FIRST_QUEST_ID] = quest
        return true
    return false

func handle_region_entered(event: Dictionary) -> bool:
    var quest := first_quest()
    if String(quest.get("stage", "")) != STAGE_TRAVEL_TO_AFFECTED_REGION:
        return false
    if String(event.get("regionId", "")) != String(quest.get("affectedRegionId", "")):
        return false
    var facts := facts_for_quest(quest)
    if bool(facts.get("enteredAffectedRegion", false)):
        return false
    facts["enteredAffectedRegion"] = true
    quest["facts"] = facts
    set_stage(quest, STAGE_FIND_ORDINARY_CLUES)
    quests[FIRST_QUEST_ID] = quest
    return true

func handle_clue_found(event: Dictionary) -> bool:
    var quest := first_quest()
    if String(event.get("regionId", "")) != String(quest.get("affectedRegionId", "")):
        return false
    var payload := payload_from_event(event)
    var clue_kind := String(payload.get("clueKind", payload.get("kind", "")))
    var clue_id := clue_id_from_event(event)
    if clue_id == "":
        return false
    if clue_kind == "ordinary":
        return handle_ordinary_clue(quest, clue_id)
    if clue_kind == "historical" or clue_kind == "history":
        return handle_historical_clue(quest, clue_id)
    return false

func handle_ordinary_clue(quest: Dictionary, clue_id: String) -> bool:
    var stage := String(quest.get("stage", ""))
    if not (stage in [STAGE_FIND_ORDINARY_CLUES, STAGE_OPTIONAL_FIND_HISTORICAL_CLUE]):
        return false
    var facts := facts_for_quest(quest)
    var clue_ids: Array = facts.get("ordinaryClueIds", [])
    if clue_ids.has(clue_id):
        return false
    clue_ids.append(clue_id)
    facts["ordinaryClueIds"] = clue_ids
    facts["ordinaryCluesFound"] = clue_ids.size()
    quest["facts"] = facts
    if clue_ids.size() >= ORDINARY_CLUES_REQUIRED and stage == STAGE_FIND_ORDINARY_CLUES:
        set_stage(quest, STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER)
    quests[FIRST_QUEST_ID] = quest
    return true

func handle_historical_clue(quest: Dictionary, clue_id: String) -> bool:
    var stage := String(quest.get("stage", ""))
    if not (stage in [STAGE_FIND_ORDINARY_CLUES, STAGE_OPTIONAL_FIND_HISTORICAL_CLUE, STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER]):
        return false
    var facts := facts_for_quest(quest)
    if bool(facts.get("historyClueFound", false)) and String(facts.get("historicalClueId", "")) == clue_id:
        return false
    facts["historyClueFound"] = true
    facts["historicalClueId"] = clue_id
    facts["releaseRouteUnlocked"] = true
    if bool(facts.get("stormWeakened", false)):
        facts["releaseRouteAvailable"] = true
    quest["facts"] = facts
    var optional_objectives: Dictionary = quest.get("optionalObjectives", {})
    optional_objectives["learn_old_compact"] = true
    quest["optionalObjectives"] = optional_objectives
    if stage == STAGE_OPTIONAL_FIND_HISTORICAL_CLUE:
        set_stage(quest, STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER)
    quests[FIRST_QUEST_ID] = quest
    return true

func handle_countermeasure_prepared(event: Dictionary) -> bool:
    var quest := first_quest()
    var stage := String(quest.get("stage", ""))
    if not (stage in [STAGE_OPTIONAL_FIND_HISTORICAL_CLUE, STAGE_PREPARE_COUNTERMEASURE_PLACEHOLDER]):
        return false
    var facts := facts_for_quest(quest)
    if bool(facts.get("countermeasurePrepared", false)):
        return false
    var payload := payload_from_event(event)
    facts["countermeasurePrepared"] = true
    facts["countermeasureItems"] = payload.get("items", ["surveyLens", "wardLantern"])
    facts["countermeasureSource"] = String(payload.get("source", ""))
    quest["facts"] = facts
    set_stage(quest, STAGE_RETUNE_BOUNDARY_STONES_PLACEHOLDER)
    quests[FIRST_QUEST_ID] = quest
    return true

func handle_boundary_stone_retuned(event: Dictionary) -> bool:
    var quest := first_quest()
    if String(quest.get("stage", "")) != STAGE_RETUNE_BOUNDARY_STONES_PLACEHOLDER:
        return false
    var stone_id := clue_id_from_event(event)
    if stone_id == "":
        return false
    var facts := facts_for_quest(quest)
    var stone_ids: Array = facts.get("boundaryStoneIds", [])
    if stone_ids.has(stone_id):
        return false
    stone_ids.append(stone_id)
    facts["boundaryStoneIds"] = stone_ids
    facts["boundaryStonesRetuned"] = stone_ids.size()
    facts["lastBoundaryStoneRetuned"] = stone_id
    quest["facts"] = facts
    if stone_ids.size() >= 2:
        facts["stormWeakened"] = true
        facts["encounterUnlocked"] = true
        facts["combatRouteUnlocked"] = true
        facts["releaseRouteAvailable"] = bool(facts.get("historyClueFound", false))
        facts["encounterLocked"] = false
        quest["facts"] = facts
        set_stage(quest, STAGE_ENCOUNTER_LOCKED_PLACEHOLDER)
    quests[FIRST_QUEST_ID] = quest
    return true

func handle_worldmark_resolved(event: Dictionary) -> bool:
    var quest := first_quest()
    if quest.is_empty():
        return false
    if String(event.get("regionId", "")) != String(quest.get("affectedRegionId", "")):
        return false
    var facts := facts_for_quest(quest)
    if bool(facts.get("worldmarkResolved", false)):
        return false
    var payload := payload_from_event(event)
    var resolution := String(payload.get("resolution", ""))
    if not (resolution in ["slay", "release"]):
        return false
    facts["worldmarkResolved"] = true
    facts["resolution"] = resolution
    facts["rewardsGranted"] = bool(payload.get("rewardsGranted", false))
    facts["encounterLocked"] = false
    quest["facts"] = facts
    quest["status"] = "completed"
    quest["resolution"] = resolution
    set_stage(quest, STAGE_WORLDMARK_RESOLVED)
    quests[FIRST_QUEST_ID] = quest
    return true

func first_quest() -> Dictionary:
    if not quests.has(FIRST_QUEST_ID) or not (quests[FIRST_QUEST_ID] is Dictionary):
        return {}
    return quests[FIRST_QUEST_ID].duplicate(true)

func facts_for_quest(quest: Dictionary) -> Dictionary:
    var facts_value = quest.get("facts", {})
    if facts_value is Dictionary:
        return facts_value.duplicate(true)
    return {}

func payload_from_event(event: Dictionary) -> Dictionary:
    var payload_value = event.get("payload", {})
    if payload_value is Dictionary:
        return payload_value
    return {}

func set_stage(quest: Dictionary, stage: String) -> void:
    quest["stage"] = stage
    quest["stageIndex"] = stage_index(stage)

func stage_index(stage: String) -> int:
    return STAGE_ORDER.find(stage)

func starter_region_id_from_event(event: Dictionary) -> String:
    var event_region_id := String(event.get("regionId", ""))
    if event_region_id != "":
        return event_region_id
    if main != null and main.get("tutorial_system") != null:
        var tutorial = main.get("tutorial_system")
        var town: Dictionary = tutorial.get("town") if tutorial.get("town") is Dictionary else {}
        if not town.is_empty():
            var town_cell := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
            return String(main.story_region_id_for_cell(town_cell))
        var start_cell = tutorial.get("start_cell")
        if start_cell is Vector2i:
            return String(main.story_region_id_for_cell(start_cell))
    return "r:0,0"

func select_first_affected_region(starter_region_id: String) -> String:
    if story_director == null or story_director.region_generator == null:
        return fallback_adjacent_region(starter_region_id)
    var generator = story_director.region_generator
    var starter_coords: Vector2i = generator.region_coords(starter_region_id)
    var fallback_region := ""
    for ring in range(1, 9):
        var candidates := ring_candidates(starter_coords, ring, generator)
        for region_id in candidates:
            if region_id == starter_region_id:
                continue
            var suitability := region_suitability(region_id)
            if bool(suitability.get("dry", false)) and fallback_region == "":
                fallback_region = region_id
            if bool(suitability.get("preferred", false)):
                return region_id
    if fallback_region != "":
        return fallback_region
    return fallback_adjacent_region(starter_region_id)

func ring_candidates(center: Vector2i, ring: int, generator) -> Array[String]:
    var result: Array[String] = []
    for dz in range(-ring, ring + 1):
        for dx in range(-ring, ring + 1):
            if maxi(absi(dx), absi(dz)) != ring:
                continue
            result.append(generator.region_id_from_coords(center + Vector2i(dx, dz)))
    result.sort_custom(func(a, b): return candidate_sort_key(a) < candidate_sort_key(b))
    return result

func candidate_sort_key(region_id: String) -> int:
    var seed_text := "story"
    if main != null:
        seed_text = String(main.get("seed_text"))
    if story_director != null and story_director.region_generator != null:
        return int(story_director.region_generator.stable_hash("%s|%s|first-gloam-region" % [seed_text, region_id]))
    return int(hash(region_id))

func region_suitability(region_id: String) -> Dictionary:
    if main == null or story_director == null or story_director.region_generator == null:
        return { "preferred": false, "dry": true, "biome": "" }
    var center: Vector2i = story_director.region_generator.region_center_cell(region_id)
    var offsets: Array[Vector2i] = [
        Vector2i.ZERO,
        Vector2i(-48, 0),
        Vector2i(48, 0),
        Vector2i(0, -48),
        Vector2i(0, 48),
        Vector2i(-36, -36),
        Vector2i(36, -36),
        Vector2i(-36, 36),
        Vector2i(36, 36)
    ]
    var counts := {}
    var dry_samples := 0
    for offset in offsets:
        var sample: Vector2i = center + offset
        var biome := String(main.call("surface_biome_at_cell", Vector3i(sample.x, 0, sample.y)))
        counts[biome] = int(counts.get(biome, 0)) + 1
        if not (biome in ["ocean", "beach"]):
            dry_samples += 1
    var dominant := dominant_biome_from_counts(counts)
    return {
        "preferred": dry_samples >= 5 and dominant in ["forest", "taiga"],
        "dry": dry_samples >= 5,
        "biome": dominant
    }

func dominant_biome_for_region(region_id: String) -> String:
    var suitability := region_suitability(region_id)
    return String(suitability.get("biome", ""))

func dominant_biome_from_counts(counts: Dictionary) -> String:
    var best := ""
    var best_count := -1
    for biome_variant in counts.keys():
        var biome := String(biome_variant)
        var count := int(counts[biome_variant])
        if count > best_count:
            best = biome
            best_count = count
    return best

func fallback_adjacent_region(starter_region_id: String) -> String:
    if story_director != null and story_director.region_generator != null:
        var coords: Vector2i = story_director.region_generator.region_coords(starter_region_id)
        return story_director.region_generator.region_id_from_coords(coords + Vector2i(1, 0))
    return "r:1,0"

func subject_suffix(subject_id: String) -> String:
    var colon := subject_id.find(":")
    if colon < 0:
        return subject_id
    return subject_id.substr(colon + 1)

func clue_id_from_event(event: Dictionary) -> String:
    var payload := payload_from_event(event)
    var clue_id := String(payload.get("clueId", payload.get("id", "")))
    if clue_id != "":
        return clue_id
    return String(event.get("subjectId", ""))

func debug_state() -> Dictionary:
    var quest := first_quest()
    if quest.is_empty():
        return {
            "activeQuestId": "",
            "stage": "",
            "affectedRegionId": "",
            "ordinaryCluesFound": 0,
            "historyClueFound": false,
            "releaseRouteUnlocked": false
        }
    var facts := facts_for_quest(quest)
    return {
        "activeQuestId": String(quest.get("id", "")),
        "stage": String(quest.get("stage", "")),
        "affectedRegionId": String(quest.get("affectedRegionId", "")),
        "ordinaryCluesFound": int(facts.get("ordinaryCluesFound", 0)),
        "ordinaryClueIds": facts.get("ordinaryClueIds", []),
        "historyClueFound": bool(facts.get("historyClueFound", false)),
        "historicalClueId": String(facts.get("historicalClueId", "")),
        "releaseRouteUnlocked": bool(facts.get("releaseRouteUnlocked", false)),
        "countermeasurePrepared": bool(facts.get("countermeasurePrepared", false)),
        "countermeasureItems": facts.get("countermeasureItems", []),
        "countermeasureSource": String(facts.get("countermeasureSource", "")),
        "boundaryStonesRetuned": int(facts.get("boundaryStonesRetuned", 0)),
        "boundaryStoneIds": facts.get("boundaryStoneIds", []),
        "stormWeakened": bool(facts.get("stormWeakened", false)),
        "encounterUnlocked": bool(facts.get("encounterUnlocked", false)),
        "combatRouteUnlocked": bool(facts.get("combatRouteUnlocked", false)),
        "releaseRouteAvailable": bool(facts.get("releaseRouteAvailable", false)),
        "encounterLocked": bool(facts.get("encounterLocked", true)),
        "worldmarkResolved": bool(facts.get("worldmarkResolved", false)),
        "resolution": String(facts.get("resolution", "")),
        "rewardsGranted": bool(facts.get("rewardsGranted", false))
    }
