extends Node
class_name WorldmarkInfluenceSystem

var main
var story_director
var active_region_id := ""
var active := false
var weather_bias := {}
var ambience_tag := ""
var hostile_modifier := {}

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node

func reset() -> void:
    clear_influence()

func sync_for_region(region_id: String) -> void:
    var affected := affected_region_id()
    if affected != "" and region_id == affected and not first_worldmark_resolved():
        apply_influence(region_id)
    else:
        clear_influence()

func apply_influence(region_id: String) -> void:
    active = true
    active_region_id = region_id
    weather_bias = {
        "kind": "rain",
        "intensity": 0.22,
        "cloudCover": 0.35,
        "removable": true
    }
    ambience_tag = "gloam_hart_ringing_storm"
    hostile_modifier = {
        "tag": "gloam_hart_pressure",
        "shadowBias": 0.12,
        "removable": true
    }

func clear_influence() -> void:
    active = false
    active_region_id = ""
    weather_bias.clear()
    ambience_tag = ""
    hostile_modifier.clear()

func affected_region_id() -> String:
    if story_director == null or story_director.quest_system == null:
        return ""
    var quest: Dictionary = story_director.quest_system.first_quest() if story_director.quest_system.has_method("first_quest") else {}
    return String(quest.get("affectedRegionId", ""))

func first_worldmark_resolved() -> bool:
    if story_director == null:
        return false
    var region_id := affected_region_id()
    if region_id == "" or not story_director.region_records.has(region_id):
        return false
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    return String(worldmark.get("resolution", "")) != ""

func debug_state() -> Dictionary:
    return {
        "active": active,
        "activeRegionId": active_region_id,
        "weatherBias": weather_bias.duplicate(true),
        "ambienceTag": ambience_tag,
        "hostileModifier": hostile_modifier.duplicate(true)
    }
