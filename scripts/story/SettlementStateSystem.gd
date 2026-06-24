extends Node
class_name SettlementStateSystem

const STARTER_SETTLEMENT_ID := "starter"

var main
var story_director
var last_message := ""

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node
    ensure_starter_settlement()

func reset() -> void:
    last_message = ""

func ensure_starter_settlement() -> Dictionary:
    if story_director == null:
        return {}
    var settlements: Dictionary = story_director.settlements
    var state: Dictionary = settlements.get(STARTER_SETTLEMENT_ID, {})
    if state.is_empty():
        state = {
            "id": STARTER_SETTLEMENT_ID,
            "label": "Starter Settlement",
            "tier": 0,
            "status": "struggling",
            "resolution": "",
            "resolutionRecorded": false,
            "tradeLinkUnlocked": false,
            "serviceUnlocked": false,
            "cozySceneUnlocked": false,
            "cozySceneId": "",
            "residentActivity": "",
            "wildlifeRecovery": "",
            "guardMood": "",
            "townRecord": ""
        }
    state["townKey"] = starter_town_key()
    state["regionId"] = starter_region_id()
    settlements[STARTER_SETTLEMENT_ID] = state
    story_director.settlements = settlements
    return state.duplicate(true)

func apply_aftermath(aftermath: Dictionary) -> Dictionary:
    var state := ensure_starter_settlement()
    if state.is_empty():
        return {}
    var resolution := String(aftermath.get("resolution", ""))
    state["resolution"] = resolution
    state["resolutionRecorded"] = resolution != ""
    state["townRecord"] = "Gloam Hart %s" % ("released" if resolution == "release" else "slain")
    state["wildlifeRecovery"] = String(aftermath.get("wildlifeRecovery", ""))
    state["guardMood"] = String(aftermath.get("guardMood", ""))
    state["residentActivity"] = String(aftermath.get("residentActivity", ""))
    if bool(aftermath.get("settlementTierUnlocked", false)):
        state["tier"] = 1
        state["status"] = "secure"
    if bool(aftermath.get("tradeLinkUnlocked", false)):
        state["tradeLinkUnlocked"] = true
    if bool(aftermath.get("serviceUnlocked", false)):
        state["serviceUnlocked"] = true
    if bool(aftermath.get("cozySceneUnlocked", false)):
        state["cozySceneUnlocked"] = true
        state["cozySceneId"] = String(aftermath.get("cozySceneId", "shared_meal"))
    var settlements: Dictionary = story_director.settlements
    settlements[STARTER_SETTLEMENT_ID] = state
    story_director.settlements = settlements
    last_message = "%s is %s" % [String(state.get("label", "Settlement")), String(state.get("status", "struggling"))]
    return state.duplicate(true)

func state() -> Dictionary:
    return ensure_starter_settlement()

func starter_town_key() -> String:
    if main != null and main.get("tutorial_system") != null:
        var tutorial = main.get("tutorial_system")
        if tutorial.has_method("tutorial_town_key"):
            return String(tutorial.tutorial_town_key())
    return "tutorial"

func starter_region_id() -> String:
    if story_director == null or story_director.quest_system == null:
        return ""
    var quest: Dictionary = story_director.quest_system.first_quest() if story_director.quest_system.has_method("first_quest") else {}
    return String(quest.get("starterRegionId", ""))

func debug_state() -> Dictionary:
    var current := state()
    current["lastMessage"] = last_message
    return current
