extends Node
class_name StoryJournalModel

const FIRST_QUEST_ID := "story.gloam_hart.storm"

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
        "optionalObjectives": optional_objectives(quest),
        "dossier": dossier_rows(facts, region_record),
        "foundClues": found_clue_rows(facts),
        "replayEntries": replay_entries_for_state(facts, region_record),
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
            return "Travel to the marked storm region"
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
    return [
        {
            "label": "Old compact",
            "value": "Understood" if bool(facts.get("historyClueFound", false)) else "???",
            "complete": bool(facts.get("historyClueFound", false))
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
