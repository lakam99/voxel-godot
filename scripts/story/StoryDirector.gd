extends Node
class_name StoryDirector

const WorldmarkDefinitionScript := preload("res://scripts/story/data/WorldmarkDefinition.gd")

const MAX_DEDUPE_KEYS := 512
const MAX_DEBUG_EVENTS := 24
const FIRST_QUEST_ID := "story.gloam_hart.storm"

var main
var event_bus
var region_generator
var quest_system
var campaign := {}
var region_records := {}
var settlements := {}
var processed_dedupe_keys: Array[String] = []
var processed_dedupe_lookup := {}
var generated_text := {}
var debug_recent_events: Array = []
var event_counts := {}
var current_story_region_id := ""

func setup(main_node, bus_node, generator_node, quest_node) -> void:
    main = main_node
    event_bus = bus_node
    region_generator = generator_node
    quest_system = quest_node
    if quest_system != null and quest_system.has_method("set_story_director"):
        quest_system.set_story_director(self)
    if event_bus != null:
        var callback := Callable(self, "_on_story_event")
        if not event_bus.is_connected("story_event", callback):
            event_bus.connect("story_event", callback)

func reset() -> void:
    campaign.clear()
    region_records.clear()
    settlements.clear()
    processed_dedupe_keys.clear()
    processed_dedupe_lookup.clear()
    generated_text.clear()
    debug_recent_events.clear()
    event_counts.clear()
    current_story_region_id = ""
    if quest_system != null and quest_system.has_method("reset"):
        quest_system.reset()

func region_id_for_cell(cell: Vector2i) -> String:
    if region_generator == null:
        return ""
    return String(region_generator.region_id_for_cell(cell))

func ensure_region_record_for_cell(cell: Vector2i, dominant_biome := "") -> Dictionary:
    return ensure_region_record_for_id(region_id_for_cell(cell), dominant_biome)

func ensure_region_record_for_id(region_id: String, dominant_biome := "") -> Dictionary:
    if region_id == "":
        return {}
    if region_records.has(region_id):
        return region_records[region_id]
    if region_generator == null:
        return {}
    var seed_text := ""
    var seed_hash := 0
    if main != null:
        seed_text = String(main.get("seed_text"))
        seed_hash = int(main.get("seed_hash"))
    var record: Dictionary = region_generator.generate_region_record(seed_text, seed_hash, region_id, dominant_biome)
    region_records[region_id] = record
    return record

func mark_gloam_hart_region(region_id: String, dominant_biome := "") -> Dictionary:
    var record := ensure_region_record_for_id(region_id, dominant_biome)
    if record.is_empty():
        return {}
    record["state"] = "affected_rumored"
    record["arcId"] = "storm_that_stays"
    record["questId"] = FIRST_QUEST_ID
    var existing_worldmark: Dictionary = record.get("worldmark", {})
    var definition := gloam_hart_definition()
    var worldmark: Dictionary = WorldmarkDefinitionScript.apply_to_existing(region_id, definition, existing_worldmark)
    if not worldmark.has("foundClueIds") or not (worldmark["foundClueIds"] is Array):
        worldmark["foundClueIds"] = []
    if not worldmark.has("preparationFlags") or not (worldmark["preparationFlags"] is Dictionary):
        worldmark["preparationFlags"] = {}
    if not worldmark.has("encounterState") or not (worldmark["encounterState"] is Dictionary):
        worldmark["encounterState"] = {}
    worldmark["resolution"] = String(worldmark.get("resolution", ""))
    record["worldmark"] = worldmark
    region_records[region_id] = record
    campaign["firstArcId"] = "storm_that_stays"
    campaign["firstQuestId"] = FIRST_QUEST_ID
    campaign["firstAffectedRegionId"] = region_id
    campaign["firstWorldmarkDefinitionId"] = "gloam_hart"
    return record

func gloam_hart_definition() -> Dictionary:
    if region_generator != null and region_generator.has_method("worldmark_definition"):
        var generated_definition: Dictionary = region_generator.worldmark_definition("gloam_hart")
        if not generated_definition.is_empty():
            return generated_definition
    return WorldmarkDefinitionScript.definition_for_id("gloam_hart")

func ingest_event(event_value) -> bool:
    if not (event_value is Dictionary):
        return false
    var event: Dictionary = event_value.duplicate(true)
    var event_type := String(event.get("type", "")).strip_edges()
    if event_type == "":
        return false
    var dedupe_key := String(event.get("dedupeKey", ""))
    if dedupe_key != "":
        if processed_dedupe_lookup.has(dedupe_key):
            return false
        remember_dedupe_key(dedupe_key)
    var region_id := String(event.get("regionId", ""))
    if region_id != "":
        current_story_region_id = region_id
        ensure_region_record_for_id(region_id, dominant_biome_from_event(event))
    event_counts[event_type] = int(event_counts.get(event_type, 0)) + 1
    remember_debug_event(event)
    if quest_system != null and quest_system.has_method("handle_event"):
        quest_system.handle_event(event)
    return true

func snapshot() -> Dictionary:
    return {
        "schemaVersion": 1,
        "campaign": campaign.duplicate(true),
        "regionRecords": region_records.duplicate(true),
        "quests": quest_system.snapshot() if quest_system != null and quest_system.has_method("snapshot") else {},
        "settlements": settlements.duplicate(true),
        "processedDedupeKeys": processed_dedupe_keys.duplicate(),
        "generatedText": generated_text.duplicate(true),
        "debugRecentEvents": debug_recent_events.duplicate(true),
        "eventCounts": event_counts.duplicate(true),
        "currentStoryRegionId": current_story_region_id
    }

func debug_story_dump() -> Dictionary:
    var quest_debug := {}
    if quest_system != null and quest_system.has_method("debug_state"):
        quest_debug = quest_system.debug_state()
    return {
        "currentStoryRegionId": current_story_region_id,
        "setup": {
            "eventBus": event_bus != null,
            "regionGenerator": region_generator != null,
            "questSystem": quest_system != null
        },
        "campaign": campaign.duplicate(true),
        "quest": quest_debug,
        "recentEvents": debug_recent_events.duplicate(true)
    }

func restore(snapshot_value) -> void:
    reset()
    if not (snapshot_value is Dictionary):
        return
    var state: Dictionary = snapshot_value
    campaign = dictionary_value(state.get("campaign", {}))
    region_records = dictionary_value(state.get("regionRecords", {}))
    settlements = dictionary_value(state.get("settlements", {}))
    generated_text = dictionary_value(state.get("generatedText", {}))
    event_counts = dictionary_value(state.get("eventCounts", {}))
    current_story_region_id = String(state.get("currentStoryRegionId", ""))
    if quest_system != null and quest_system.has_method("restore"):
        quest_system.restore(state.get("quests", {}))
    var keys_value = state.get("processedDedupeKeys", [])
    if keys_value is Array:
        for key_value in keys_value:
            var dedupe_key := String(key_value)
            if dedupe_key != "":
                remember_dedupe_key(dedupe_key)
    var events_value = state.get("debugRecentEvents", [])
    if events_value is Array:
        for event_value in events_value:
            if event_value is Dictionary:
                debug_recent_events.append(event_value.duplicate(true))
    while debug_recent_events.size() > MAX_DEBUG_EVENTS:
        debug_recent_events.pop_front()

func _on_story_event(event: Dictionary) -> void:
    ingest_event(event)

func remember_dedupe_key(dedupe_key: String) -> void:
    if dedupe_key == "" or processed_dedupe_lookup.has(dedupe_key):
        return
    processed_dedupe_keys.append(dedupe_key)
    processed_dedupe_lookup[dedupe_key] = true
    while processed_dedupe_keys.size() > MAX_DEDUPE_KEYS:
        var removed = processed_dedupe_keys.pop_front()
        processed_dedupe_lookup.erase(removed)

func remember_debug_event(event: Dictionary) -> void:
    debug_recent_events.append({
        "type": String(event.get("type", "")),
        "subjectId": String(event.get("subjectId", "")),
        "regionId": String(event.get("regionId", "")),
        "dedupeKey": String(event.get("dedupeKey", "")),
        "worldTime": float(event.get("worldTime", 0.0))
    })
    while debug_recent_events.size() > MAX_DEBUG_EVENTS:
        debug_recent_events.pop_front()

func dominant_biome_from_event(event: Dictionary) -> String:
    var payload_value = event.get("payload", {})
    if payload_value is Dictionary:
        return String(payload_value.get("biome", payload_value.get("dominantBiome", "")))
    return ""

func dictionary_value(value) -> Dictionary:
    if value is Dictionary:
        return value.duplicate(true)
    return {}
