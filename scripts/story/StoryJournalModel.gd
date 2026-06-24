extends Node
class_name StoryJournalModel

const FIRST_QUEST_ID := "story.gloam_hart.storm"
const ORDINARY_CLUES_REQUIRED := 2
const ORDINARY_CLUES_TOTAL := 3
const BOUNDARY_STONES_TOTAL := 2

var main
var story_director

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node

func state() -> Dictionary:
    var quest := first_quest()
    if quest.is_empty():
        return {
            "active": false,
            "title": "Story Journal",
            "status": "No active investigation",
            "stage": "",
            "rows": []
        }
    var facts: Dictionary = quest.get("facts", {})
    var affected_region_id := String(quest.get("affectedRegionId", ""))
    var region_record := affected_region(affected_region_id)
    return {
        "active": true,
        "questId": FIRST_QUEST_ID,
        "title": String(quest.get("title", "The Storm That Stays")),
        "status": stage_label(String(quest.get("stage", ""))),
        "stage": String(quest.get("stage", "")),
        "affectedRegionId": affected_region_id,
        "navigation": navigation_rows(quest, region_record),
        "optionalObjectives": optional_objectives(quest),
        "dossier": dossier_rows(facts, region_record),
        "progress": progress_rows(facts),
        "foundClues": found_clue_rows(facts),
        "replayEntries": replay_entries_for_state(facts, region_record),
        "preparationRequirements": preparation_requirement_rows(facts),
        "knownPreparation": known_preparation(facts, quest),
        "affectedSettlement": affected_settlement_status(region_record),
        "resolutionHistory": resolution_rows(region_record),
        "aftermath": aftermath_rows(region_record)
    }

func replay_entries() -> Array:
    var quest := first_quest()
    if quest.is_empty():
        return []
    var facts: Dictionary = quest.get("facts", {})
    var region_record := affected_region(String(quest.get("affectedRegionId", "")))
    return replay_entries_for_state(facts, region_record)

func first_quest() -> Dictionary:
    if story_director == null or story_director.quest_system == null:
        return {}
    if story_director.quest_system.has_method("first_quest"):
        return story_director.quest_system.first_quest()
    return {}

func affected_region(region_id: String) -> Dictionary:
    if story_director == null or region_id == "":
        return {}
    return story_director.region_records.get(region_id, {})

func stage_label(stage: String) -> String:
    match stage:
        "speak_with_mira":
            return "Speak with Mira"
        "speak_with_sera":
            return "Speak with Sera"
        "travel_to_affected_region":
            return "Travel to the storm waypoint"
        "find_ordinary_clues":
            return "Investigate the region"
        "prepare_countermeasure_placeholder":
            return "Prepare a countermeasure"
        "retune_boundary_stones_placeholder":
            return "Retune the boundary stones"
        "encounter_locked_placeholder":
            return "Find the storm hollow"
        "worldmark_resolved":
            return "Worldmark resolved"
    return "Investigation pending"

func optional_objectives(quest: Dictionary) -> Array:
    var facts: Dictionary = quest.get("facts", {})
    var history_found := bool(facts.get("historyClueFound", false))
    return [
        {
            "label": "Old compact record",
            "value": "found; release rite understood" if history_found else "may reveal another way to resolve the Hart",
            "complete": history_found,
            "kind": "historical"
        }
    ]

func navigation_rows(quest: Dictionary, region_record: Dictionary) -> Array:
    var stage := String(quest.get("stage", ""))
    var affected_region_id := String(quest.get("affectedRegionId", ""))
    var starter_region_id := String(quest.get("starterRegionId", ""))
    var biome := String(quest.get("affectedRegionBiome", ""))
    if biome == "":
        biome = String(region_record.get("dominantBiome", "storm"))
    var direction := affected_region_direction(starter_region_id, affected_region_id)
    var distance := affected_region_distance_text(starter_region_id, affected_region_id)
    var waypoint := "Follow the fixed %s storm %s from town%s." % [
        biome if biome != "" else "wild",
        direction,
        " (%s)" % distance if distance != "" else ""
    ]
    if stage in ["find_ordinary_clues", "optional_find_historical_clue", "prepare_countermeasure_placeholder", "retune_boundary_stones_placeholder", "encounter_locked_placeholder"]:
        waypoint = "Storm waypoint reached; search the %s region for signs, stones, and the hollow." % (biome if biome != "" else "affected")
    if stage == "worldmark_resolved":
        waypoint = "The fixed storm region has been resolved."
    return [
        {
            "label": "Storm waypoint",
            "value": waypoint,
            "kind": "navigation",
            "complete": stage in ["find_ordinary_clues", "optional_find_historical_clue", "prepare_countermeasure_placeholder", "retune_boundary_stones_placeholder", "encounter_locked_placeholder", "worldmark_resolved"]
        }
    ]

func dossier_rows(facts: Dictionary, region_record: Dictionary) -> Array:
    var worldmark: Dictionary = region_record.get("worldmark", {})
    var history_known := bool(facts.get("historyClueFound", false))
    return [
        { "label": "Worldmark", "value": "The Gloam Hart" if not worldmark.is_empty() else "???" },
        { "label": "Domain", "value": "Storm and light" if not worldmark.is_empty() else "???" },
        { "label": "Condition", "value": "Bound to the lantern line" if history_known else "???" },
        { "label": "Hidden truth", "value": "The compact was meant to spare the Hart, not bind it" if history_known else "???" },
        { "label": "Desire", "value": "Silence the old lanterns" if history_known else "???" }
    ]

func progress_rows(facts: Dictionary) -> Array:
    var ordinary_found := clampi(int(facts.get("ordinaryCluesFound", 0)), 0, ORDINARY_CLUES_TOTAL)
    var ordinary_remaining_required := maxi(0, ORDINARY_CLUES_REQUIRED - ordinary_found)
    var ordinary_remaining_total := maxi(0, ORDINARY_CLUES_TOTAL - ordinary_found)
    var boundary_retuned := clampi(int(facts.get("boundaryStonesRetuned", 0)), 0, BOUNDARY_STONES_TOTAL)
    var boundary_remaining := maxi(0, BOUNDARY_STONES_TOTAL - boundary_retuned)
    return [
        {
            "label": "Ordinary clues",
            "value": "%d found, %d remaining to prepare (%d undiscovered in region)" % [ordinary_found, ordinary_remaining_required, ordinary_remaining_total],
            "complete": ordinary_found >= ORDINARY_CLUES_REQUIRED,
            "kind": "ordinary"
        },
        {
            "label": "Boundary stones",
            "value": "%d retuned, %d remaining" % [boundary_retuned, boundary_remaining],
            "complete": boundary_retuned >= BOUNDARY_STONES_TOTAL,
            "kind": "boundary"
        }
    ]

func found_clue_rows(facts: Dictionary) -> Array:
    var rows := []
    var ordinary_ids: Array = facts.get("ordinaryClueIds", [])
    for clue_id_value in ordinary_ids:
        rows.append({
            "label": clue_label(String(clue_id_value)),
            "kind": "ordinary"
        })
    if bool(facts.get("historyClueFound", false)):
        rows.append({
            "label": "Old compact record",
            "kind": "historical"
        })
    if rows.is_empty():
        rows.append({ "label": "???", "kind": "unknown" })
    return rows

func replay_entries_for_state(facts: Dictionary, region_record: Dictionary) -> Array:
    var entries := []
    var ordinary_ids: Array = facts.get("ordinaryClueIds", [])
    for clue_id_value in ordinary_ids:
        var clue_id := String(clue_id_value)
        entries.append({
            "id": clue_id,
            "label": clue_label(clue_id),
            "value": replay_text_for_clue(clue_id),
            "kind": "journal",
            "replayable": true
        })
    if bool(facts.get("historyClueFound", false)):
        entries.append({
            "id": "historical_old_compact",
            "label": "Old compact record",
            "value": "Lantern light was meant to spare the Hart, not bind it.",
            "kind": "letter",
            "replayable": true
        })
    var worldmark: Dictionary = region_record.get("worldmark", {})
    var resolution := String(worldmark.get("resolution", ""))
    if resolution != "":
        entries.append({
            "id": "gloam_hart_resolution",
            "label": "Resolution",
            "value": "The Gloam Hart was %s." % ("released" if resolution == "release" else "slain"),
            "kind": "resolution",
            "replayable": true
        })
    if entries.is_empty():
        entries.append({ "label": "No discovered text yet", "value": "", "kind": "unknown" })
    return entries

func clue_label(clue_id: String) -> String:
    if clue_id.find("antler") >= 0 or clue_id.find("scarred_tree") >= 0:
        return "Pale antler scars"
    if clue_id.find("ringing_stone") >= 0:
        return "Ringing boundary stone"
    if clue_id.find("broken_lantern") >= 0:
        return "Broken lantern frame"
    return "Regional clue"

func replay_text_for_clue(clue_id: String) -> String:
    if clue_id.find("antler") >= 0 or clue_id.find("scarred_tree") >= 0:
        return "Pale antler scars face away from the old lantern line."
    if clue_id.find("ringing_stone") >= 0:
        return "The boundary stone rings under rain, like metal under strain."
    if clue_id.find("broken_lantern") >= 0:
        return "The broken lantern frame was pushed away from the trees."
    return "A regional clue was recorded for later review."

func preparation_requirement_rows(facts: Dictionary) -> Array:
    var survey_count := inventory_count("surveyLens")
    var lantern_count := inventory_count("wardLantern")
    var shard_count := inventory_count("nightShard")
    var stones_retuned := clampi(int(facts.get("boundaryStonesRetuned", 0)), 0, BOUNDARY_STONES_TOTAL)
    var shard_required := maxi(0, BOUNDARY_STONES_TOTAL - stones_retuned)
    return [
        {
            "label": "Survey Lens",
            "value": "ready" if survey_count > 0 else "required before retuning",
            "complete": survey_count > 0,
            "kind": "preparation"
        },
        {
            "label": "Ward Lantern",
            "value": "ready" if lantern_count > 0 else "required before retuning",
            "complete": lantern_count > 0,
            "kind": "preparation"
        },
        {
            "label": "Night Shard charge",
            "value": "%d/%d available for remaining stones" % [mini(shard_count, shard_required), shard_required],
            "complete": shard_required == 0 or shard_count >= shard_required,
            "kind": "preparation"
        }
    ]

func known_preparation(facts: Dictionary, quest: Dictionary) -> String:
    if bool(facts.get("worldmarkResolved", false)):
        return "Worldmark resolved"
    if bool(facts.get("stormWeakened", false)):
        return "Boundary stones retuned"
    var stone_count := int(facts.get("boundaryStonesRetuned", 0))
    if stone_count > 0:
        return "Boundary stones retuned: %d/2" % stone_count
    if bool(facts.get("countermeasurePrepared", false)):
        return "Countermeasure prepared"
    if int(facts.get("ordinaryCluesFound", 0)) >= 2:
        return "Enough signs found to prepare a countermeasure"
    return "Find two ordinary clues"

func inventory_count(item_id: String) -> int:
    if main == null:
        return 0
    var inventory_system = main.get("inventory_system")
    if inventory_system == null or not inventory_system.has_method("count"):
        return 0
    return int(inventory_system.count(item_id))

func affected_region_direction(starter_region_id: String, affected_region_id: String) -> String:
    var delta := affected_region_delta(starter_region_id, affected_region_id)
    var east_west := ""
    var north_south := ""
    if delta.x > 0:
        east_west = "east"
    elif delta.x < 0:
        east_west = "west"
    if delta.y > 0:
        north_south = "south"
    elif delta.y < 0:
        north_south = "north"
    if east_west != "" and north_south != "":
        return "%s-%s" % [north_south, east_west]
    if east_west != "":
        return east_west
    if north_south != "":
        return north_south
    return "near town"

func affected_region_distance_text(starter_region_id: String, affected_region_id: String) -> String:
    var delta := affected_region_delta(starter_region_id, affected_region_id)
    var parts: Array[String] = []
    if delta.x != 0:
        parts.append("%d region%s %s" % [absi(delta.x), "" if absi(delta.x) == 1 else "s", "east" if delta.x > 0 else "west"])
    if delta.y != 0:
        parts.append("%d region%s %s" % [absi(delta.y), "" if absi(delta.y) == 1 else "s", "south" if delta.y > 0 else "north"])
    return ", ".join(parts)

func affected_region_delta(starter_region_id: String, affected_region_id: String) -> Vector2i:
    if story_director == null or story_director.region_generator == null:
        return Vector2i.ZERO
    var generator = story_director.region_generator
    return generator.region_coords(affected_region_id) - generator.region_coords(starter_region_id)

func affected_settlement_status(region_record: Dictionary) -> String:
    if region_record.is_empty():
        return "???"
    var worldmark: Dictionary = region_record.get("worldmark", {})
    if String(worldmark.get("resolution", "")) != "":
        return "Recovering"
    return "Unresolved regional pressure"

func resolution_rows(region_record: Dictionary) -> Array:
    var worldmark: Dictionary = region_record.get("worldmark", {})
    var resolution := String(worldmark.get("resolution", ""))
    if resolution == "":
        return [{ "label": "Resolution", "value": "???" }]
    return [{ "label": "Resolution", "value": "Released" if resolution == "release" else "Slain" }]

func aftermath_rows(region_record: Dictionary) -> Array:
    var worldmark: Dictionary = region_record.get("worldmark", {})
    var aftermath: Dictionary = worldmark.get("aftermathState", {})
    if aftermath.is_empty():
        return [{ "label": "Aftermath", "value": "Not begun" }]
    return [
        { "label": "Storm", "value": "Cleared" if bool(aftermath.get("stormCleared", false)) else "Clearing" },
        { "label": "Town", "value": "Secure" if bool(aftermath.get("settlementTierUnlocked", false)) else "Recovering" },
        { "label": "Activity", "value": String(aftermath.get("residentActivity", "")) },
        { "label": "Wildlife", "value": String(aftermath.get("wildlifeRecovery", "")) }
    ]
