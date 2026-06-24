extends RefCounted
class_name GloamHartArc

const ARC_ID := "storm_that_stays"
const FIRST_QUEST_ID := "story.gloam_hart.storm"
const WORLDMARK_DEFINITION_ID := "gloam_hart"

const STAGE_SPEAK_WITH_MIRA := "speak_with_mira"
const STAGE_SPEAK_WITH_SERA := "speak_with_sera"
const STAGE_TRAVEL_TO_AFFECTED_REGION := "travel_to_affected_region"

const OPENING_STAGE_ORDER := [
    STAGE_SPEAK_WITH_MIRA,
    STAGE_SPEAK_WITH_SERA,
    STAGE_TRAVEL_TO_AFFECTED_REGION
]

static func opening_stage_order() -> Array:
    return OPENING_STAGE_ORDER.duplicate()

static func opening_handoff() -> Dictionary:
    return {
        "stormCue": "fixed_over_selected_region",
        "miraLead": "introduces_the_mystery",
        "seraTestimony": "lantern_attacks",
        "travelObjective": "enter_affected_region"
    }

static func opening_definition() -> Dictionary:
    return {
        "arcId": ARC_ID,
        "questId": FIRST_QUEST_ID,
        "label": "The Storm That Stays",
        "worldmarkDefinitionId": WORLDMARK_DEFINITION_ID,
        "openingStages": opening_stage_order(),
        "handoff": opening_handoff()
    }

static func validate_opening_quest(quest: Dictionary) -> Dictionary:
    var problems: Array[String] = []
    if String(quest.get("id", "")) != FIRST_QUEST_ID:
        problems.append("unexpected quest id")
    if String(quest.get("arcId", "")) != ARC_ID:
        problems.append("unexpected arc id")
    if String(quest.get("worldmarkDefinitionId", "")) != WORLDMARK_DEFINITION_ID:
        problems.append("unexpected worldmark definition")
    if String(quest.get("stage", "")) != STAGE_SPEAK_WITH_MIRA:
        problems.append("opening stage must start with Mira")
    if not bool(quest.get("tracked", false)):
        problems.append("opening quest must be tracked")
    var stage_order: Array = quest.get("stageOrder", []) if quest.get("stageOrder", []) is Array else []
    for i in range(OPENING_STAGE_ORDER.size()):
        if stage_order.size() <= i or String(stage_order[i]) != String(OPENING_STAGE_ORDER[i]):
            problems.append("opening stage order mismatch at %d" % i)
            break
    var starter := String(quest.get("starterRegionId", ""))
    var affected := String(quest.get("affectedRegionId", ""))
    if affected == "":
        problems.append("affected region missing")
    if affected == starter:
        problems.append("affected region cannot be starter region")
    var biome := String(quest.get("affectedRegionBiome", ""))
    if not (biome in ["forest", "taiga"]):
        problems.append("affected region biome must be forest or taiga")
    var handoff: Dictionary = quest.get("openingHandoff", {}) if quest.get("openingHandoff", {}) is Dictionary else {}
    for key in ["stormCue", "miraLead", "seraTestimony", "travelObjective"]:
        if String(handoff.get(key, "")) == "":
            problems.append("missing handoff %s" % key)
    return { "ok": problems.is_empty(), "problems": problems }
