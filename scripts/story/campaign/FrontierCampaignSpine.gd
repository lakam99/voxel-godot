extends Node
class_name FrontierCampaignSpine

const SCHEMA_VERSION := 1

const ACT_I := "act_i_beyond_lantern_line"
const ACT_II := "act_ii_far_roads"
const ACT_III := "act_iii_old_compact"
const POST_CAMPAIGN := "post_campaign"

const ANCHOR_DEFINITIONS := {
    "far_roads_network_junction": {
        "act": ACT_II,
        "label": "Far Roads Network Junction",
        "ringMin": 3,
        "ringMax": 6,
        "revelationId": "old_network_links_worldmarks",
        "milestones": ["settlements_reconnected", "network_instability_revealed"],
        "worldmarkConcept": "regional accord strained by old lantern roads"
    },
    "far_roads_living_boundary": {
        "act": ACT_II,
        "label": "Living Boundary",
        "ringMin": 5,
        "ringMax": 8,
        "revelationId": "worldmarks_have_different_bonds",
        "milestones": ["different_worldmark_relationships"],
        "worldmarkConcept": "a Worldmark that protects its region from overuse"
    },
    "old_compact_archive": {
        "act": ACT_III,
        "label": "Old Compact Archive",
        "ringMin": 9,
        "ringMax": 12,
        "revelationId": "compact_regulated_worldmarks",
        "milestones": ["old_compact_origin_discovered"],
        "worldmarkConcept": "records of rules meant to keep settlements and Worldmarks in balance"
    },
    "compact_failure_site": {
        "act": ACT_III,
        "label": "Compact Failure Site",
        "ringMin": 11,
        "ringMax": 14,
        "revelationId": "compact_failed_from_extraction",
        "milestones": ["compact_failure_discovered"],
        "worldmarkConcept": "proof that the old system failed when regulation became extraction"
    }
}

const REVELATION_DEFINITIONS := {
    "worldmarks_can_be_understood": {
        "act": ACT_I,
        "question": "Can a region's Worldmark be understood instead of only fought?",
        "answer": "The Gloam Hart proved that signs, history, and preparation can reveal what a Worldmark needs."
    },
    "old_network_links_worldmarks": {
        "act": ACT_II,
        "question": "Why do distant settlements suffer related instabilities?",
        "answer": "The old frontier network linked lantern roads, trade routes, and Worldmark boundaries into one system."
    },
    "worldmarks_have_different_bonds": {
        "act": ACT_II,
        "question": "Do all Worldmarks threaten settlements in the same way?",
        "answer": "Some defend, bargain, mourn, or bind their regions; the frontier must read each bond before acting."
    },
    "compact_regulated_worldmarks": {
        "act": ACT_III,
        "question": "What was the Old Compact?",
        "answer": "The Compact was a civic rule set for sharing land with Worldmarks, settlement by settlement."
    },
    "compact_failed_from_extraction": {
        "act": ACT_III,
        "question": "Why did the old system fail?",
        "answer": "It failed when leaders treated Worldmarks as resources to drain instead of neighbors with limits."
    },
    "rebuilt_frontier_principles_chosen": {
        "act": ACT_III,
        "question": "What does the rebuilt frontier stand for?",
        "answer": "The frontier continues by choosing practical principles for repair, restraint, and accountable settlement."
    }
}

const RECURRING_CHARACTER_DEFINITIONS := {
    "mara_trader": {
        "name": "Mara",
        "role": "trader",
        "relationship": "unknown",
        "memoryFlags": {
            "met_on_far_road": false,
            "shared_route_news": false
        }
    },
    "ivo_naturalist": {
        "name": "Ivo",
        "role": "naturalist",
        "relationship": "unknown",
        "memoryFlags": {
            "mapped_worldmark_signs": false,
            "warned_against_overharvest": false
        }
    },
    "rowan_builder": {
        "name": "Rowan",
        "role": "builder",
        "relationship": "known",
        "memoryFlags": {
            "helped_reconnect_settlement": false,
            "built_compact_marker": false
        }
    },
    "sera_messenger": {
        "name": "Sera",
        "role": "messenger",
        "relationship": "known",
        "memoryFlags": {
            "carried_lantern_attack_testimony": true,
            "reported_far_road_patrols": false
        }
    }
}

var main
var story_director
var region_generator
var state := {}

func setup(main_node, director_node, generator_node) -> void:
    main = main_node
    story_director = director_node
    region_generator = generator_node
    if state.is_empty():
        reset()

func reset() -> void:
    state = default_state()

func default_state() -> Dictionary:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "act": ACT_I,
        "completed": false,
        "endlessWorldContinues": true,
        "regionalStoriesEnabled": true,
        "acts": act_definitions(),
        "milestones": {},
        "anchors": {},
        "revelations": {},
        "recurringCharacters": default_character_records(),
        "chosenPrinciples": [],
        "resolvedRegionalWorldmarks": [],
        "lastAnchorId": "",
        "lastMessage": "The frontier has a question to answer."
    }

func act_definitions() -> Dictionary:
    return {
        ACT_I: {
            "label": "Beyond the Lantern Line",
            "question": "What are Worldmarks, and can people understand them?",
            "milestones": ["tutorial_complete", "first_worldmark_resolved", "worldmarks_understood"]
        },
        ACT_II: {
            "label": "The Far Roads",
            "question": "Why are distant settlements and Worldmarks tied to the same instability?",
            "milestones": ["settlements_reconnected", "different_worldmark_relationships", "network_instability_revealed"]
        },
        ACT_III: {
            "label": "The Old Compact",
            "question": "Why did the old system fail, and what replaces it?",
            "milestones": ["old_compact_origin_discovered", "compact_failure_discovered", "frontier_principles_chosen"]
        }
    }

func default_character_records() -> Dictionary:
    var records := {}
    for character_id in RECURRING_CHARACTER_DEFINITIONS.keys():
        var definition: Dictionary = RECURRING_CHARACTER_DEFINITIONS[character_id]
        records[character_id] = {
            "id": character_id,
            "name": String(definition.get("name", character_id)),
            "role": String(definition.get("role", "")),
            "relationship": String(definition.get("relationship", "unknown")),
            "relationshipScore": 0,
            "encounterCount": 0,
            "memoryFlags": dictionary_value(definition.get("memoryFlags", {}))
        }
    return records

func snapshot() -> Dictionary:
    return state.duplicate(true)

func restore(snapshot_value) -> void:
    state = normalize_state(snapshot_value)

func normalize_state(snapshot_value) -> Dictionary:
    var base := default_state()
    if not (snapshot_value is Dictionary):
        return base
    var snapshot: Dictionary = snapshot_value
    base["schemaVersion"] = int(snapshot.get("schemaVersion", SCHEMA_VERSION))
    base["act"] = String(snapshot.get("act", ACT_I))
    base["completed"] = bool(snapshot.get("completed", false))
    base["endlessWorldContinues"] = bool(snapshot.get("endlessWorldContinues", true))
    base["regionalStoriesEnabled"] = bool(snapshot.get("regionalStoriesEnabled", true))
    base["acts"] = dictionary_value(snapshot.get("acts", base["acts"]))
    base["milestones"] = dictionary_value(snapshot.get("milestones", {}))
    base["anchors"] = dictionary_value(snapshot.get("anchors", {}))
    base["revelations"] = dictionary_value(snapshot.get("revelations", {}))
    base["recurringCharacters"] = merge_character_records(snapshot.get("recurringCharacters", {}))
    base["chosenPrinciples"] = array_value(snapshot.get("chosenPrinciples", []))
    base["resolvedRegionalWorldmarks"] = array_value(snapshot.get("resolvedRegionalWorldmarks", []))
    base["lastAnchorId"] = String(snapshot.get("lastAnchorId", ""))
    base["lastMessage"] = String(snapshot.get("lastMessage", base["lastMessage"]))
    base["completed"] = bool(base["completed"])
    if bool(base["completed"]):
        base["act"] = POST_CAMPAIGN
        base["endlessWorldContinues"] = true
        base["regionalStoriesEnabled"] = true
    return base

func merge_character_records(value) -> Dictionary:
    var records := default_character_records()
    if not (value is Dictionary):
        return records
    var incoming: Dictionary = value
    for character_id_variant in incoming.keys():
        var character_id := String(character_id_variant)
        var incoming_record: Dictionary = dictionary_value(incoming[character_id_variant])
        var record: Dictionary = records.get(character_id, {
            "id": character_id,
            "name": String(incoming_record.get("name", character_id)),
            "role": String(incoming_record.get("role", "")),
            "relationship": "unknown",
            "relationshipScore": 0,
            "encounterCount": 0,
            "memoryFlags": {}
        })
        record["relationship"] = String(incoming_record.get("relationship", record.get("relationship", "unknown")))
        record["relationshipScore"] = int(incoming_record.get("relationshipScore", record.get("relationshipScore", 0)))
        record["encounterCount"] = int(incoming_record.get("encounterCount", record.get("encounterCount", 0)))
        var memory_flags: Dictionary = dictionary_value(record.get("memoryFlags", {}))
        var incoming_flags: Dictionary = dictionary_value(incoming_record.get("memoryFlags", {}))
        for flag in incoming_flags.keys():
            memory_flags[String(flag)] = bool(incoming_flags[flag])
        record["memoryFlags"] = memory_flags
        records[character_id] = record
    return records

func handle_event(event: Dictionary) -> bool:
    var event_type := String(event.get("type", ""))
    var changed := false
    match event_type:
        "tutorial_final_rescue_complete":
            ensure_initialized(String(event.get("regionId", "")))
            changed = mark_milestone("tutorial_complete") or changed
        "story_worldmark_resolved":
            ensure_initialized(String(event.get("regionId", "")))
            changed = record_resolved_worldmark(event) or changed
        "campaign_anchor_reached":
            ensure_initialized(String(event.get("regionId", "")))
            changed = complete_anchor(event) or changed
        "campaign_revelation_found":
            ensure_initialized(String(event.get("regionId", "")))
            changed = reveal(String(payload_from_event(event).get("revelationId", ""))) or changed
        "recurring_character_met":
            changed = update_character_memory(event, true) or changed
        "recurring_character_memory":
            changed = update_character_memory(event, false) or changed
        "campaign_principles_chosen":
            ensure_initialized(String(event.get("regionId", "")))
            changed = choose_principles(payload_from_event(event).get("principles", [])) or changed
    update_act()
    return changed

func ensure_initialized(starter_region_id := "") -> void:
    var anchors: Dictionary = state.get("anchors", {})
    if not anchors.is_empty():
        return
    var starter := starter_region_id
    if starter == "" and story_director != null:
        starter = String(story_director.campaign.get("firstAffectedRegionId", ""))
    if starter == "":
        starter = "r:1,0"
    var used := {}
    used[starter] = true
    if story_director != null:
        var first_affected := String(story_director.campaign.get("firstAffectedRegionId", ""))
        if first_affected != "":
            used[first_affected] = true
    var selected := {}
    var anchor_ids := ANCHOR_DEFINITIONS.keys()
    anchor_ids.sort()
    for anchor_id_variant in anchor_ids:
        var anchor_id := String(anchor_id_variant)
        var definition: Dictionary = ANCHOR_DEFINITIONS[anchor_id]
        var region_id := select_anchor_region(anchor_id, definition, starter, used)
        used[region_id] = true
        selected[anchor_id] = {
            "id": anchor_id,
            "label": String(definition.get("label", anchor_id)),
            "act": String(definition.get("act", "")),
            "regionId": region_id,
            "revelationId": String(definition.get("revelationId", "")),
            "worldmarkConcept": String(definition.get("worldmarkConcept", "")),
            "discovered": false,
            "completed": false
        }
    state["anchors"] = selected
    mark_milestone("campaign_initialized")

func select_anchor_region(anchor_id: String, definition: Dictionary, starter_region_id: String, used: Dictionary) -> String:
    if region_generator == null:
        var fallback_index := ANCHOR_DEFINITIONS.keys().find(anchor_id) + 3
        return "r:%d,%d" % [fallback_index, -fallback_index]
    var starter_coords: Vector2i = region_generator.region_coords(starter_region_id)
    var ring_min := int(definition.get("ringMin", 3))
    var ring_max := int(definition.get("ringMax", ring_min))
    for ring in range(ring_min, ring_max + 1):
        var candidates := ring_candidates(starter_coords, ring)
        for region_id in candidates:
            if not used.has(region_id):
                return region_id
    return region_generator.region_id_from_coords(starter_coords + Vector2i(ring_max + 1, ring_max + 1))

func ring_candidates(center: Vector2i, ring: int) -> Array[String]:
    var result: Array[String] = []
    for dz in range(-ring, ring + 1):
        for dx in range(-ring, ring + 1):
            if maxi(absi(dx), absi(dz)) != ring:
                continue
            result.append(region_generator.region_id_from_coords(center + Vector2i(dx, dz)))
    result.sort_custom(func(a, b): return anchor_sort_key(a) < anchor_sort_key(b))
    return result

func anchor_sort_key(region_id: String) -> int:
    var seed_text := "story"
    if main != null:
        seed_text = String(main.get("seed_text"))
    if region_generator != null and region_generator.has_method("stable_hash"):
        return int(region_generator.stable_hash("%s|%s|campaign-anchor" % [seed_text, region_id]))
    return int(hash("%s|%s" % [seed_text, region_id]))

func record_resolved_worldmark(event: Dictionary) -> bool:
    var region_id := String(event.get("regionId", ""))
    if region_id == "":
        return false
    var resolved: Array = state.get("resolvedRegionalWorldmarks", [])
    if not resolved.has(region_id):
        resolved.append(region_id)
        state["resolvedRegionalWorldmarks"] = resolved
    var changed := mark_milestone("first_worldmark_resolved")
    changed = reveal("worldmarks_can_be_understood") or changed
    changed = mark_milestone("worldmarks_understood") or changed
    changed = mark_milestone("act_i_complete") or changed
    return changed

func complete_anchor(event: Dictionary) -> bool:
    var payload := payload_from_event(event)
    var anchor_id := String(payload.get("anchorId", event.get("subjectId", "")))
    anchor_id = anchor_id.replace("campaign_anchor:", "")
    if not ANCHOR_DEFINITIONS.has(anchor_id):
        return false
    var anchors: Dictionary = state.get("anchors", {})
    if not anchors.has(anchor_id):
        ensure_initialized(String(event.get("regionId", "")))
        anchors = state.get("anchors", {})
    var anchor: Dictionary = dictionary_value(anchors.get(anchor_id, {}))
    anchor["discovered"] = true
    anchor["completed"] = true
    anchor["regionId"] = String(event.get("regionId", anchor.get("regionId", "")))
    anchors[anchor_id] = anchor
    state["anchors"] = anchors
    state["lastAnchorId"] = anchor_id
    var definition: Dictionary = ANCHOR_DEFINITIONS[anchor_id]
    var changed := reveal(String(definition.get("revelationId", "")))
    for milestone_id in array_value(definition.get("milestones", [])):
        changed = mark_milestone(String(milestone_id)) or changed
    return changed

func choose_principles(principles_value) -> bool:
    var principles: Array = []
    if principles_value is Array:
        for principle_value in principles_value:
            var principle := String(principle_value).strip_edges()
            if principle == "":
                continue
            var lower := principle.to_lower()
            if lower.find("prophecy") >= 0 or lower.find("bloodline") >= 0:
                continue
            principles.append(principle)
    if principles.is_empty():
        principles = ["repair before expansion", "restraint around Worldmarks", "settlements remain accountable to their regions"]
    state["chosenPrinciples"] = principles
    var changed := mark_milestone("frontier_principles_chosen")
    changed = reveal("rebuilt_frontier_principles_chosen") or changed
    if has_milestone("old_compact_origin_discovered") and has_milestone("compact_failure_discovered"):
        changed = mark_milestone("act_iii_complete") or changed
        changed = mark_milestone("campaign_concluded") or changed
        state["completed"] = true
        state["act"] = POST_CAMPAIGN
        state["endlessWorldContinues"] = true
        state["regionalStoriesEnabled"] = true
        state["lastMessage"] = "The campaign has concluded; the frontier remains open."
        changed = true
    return changed

func update_character_memory(event: Dictionary, mark_seen: bool) -> bool:
    var payload := payload_from_event(event)
    var character_id := String(payload.get("characterId", event.get("subjectId", "")))
    character_id = character_id.replace("character:", "")
    if character_id == "":
        return false
    var characters: Dictionary = state.get("recurringCharacters", {})
    var record: Dictionary = dictionary_value(characters.get(character_id, {}))
    if record.is_empty():
        record = {
            "id": character_id,
            "name": String(payload.get("name", character_id)),
            "role": String(payload.get("role", "")),
            "relationship": "unknown",
            "relationshipScore": 0,
            "encounterCount": 0,
            "memoryFlags": {}
        }
    if mark_seen:
        record["encounterCount"] = int(record.get("encounterCount", 0)) + 1
    var delta := int(payload.get("relationshipDelta", 0))
    record["relationshipScore"] = int(record.get("relationshipScore", 0)) + delta
    var score := int(record.get("relationshipScore", 0))
    if score >= 6:
        record["relationship"] = "trusted"
    elif score >= 2:
        record["relationship"] = "familiar"
    elif score < 0:
        record["relationship"] = "strained"
    var memory_flags: Dictionary = dictionary_value(record.get("memoryFlags", {}))
    var flag := String(payload.get("memoryFlag", ""))
    if flag != "":
        memory_flags[flag] = bool(payload.get("value", true))
    record["memoryFlags"] = memory_flags
    characters[character_id] = record
    state["recurringCharacters"] = characters
    return true

func update_act() -> void:
    if bool(state.get("completed", false)):
        state["act"] = POST_CAMPAIGN
        state["endlessWorldContinues"] = true
        state["regionalStoriesEnabled"] = true
        return
    if has_milestone("old_compact_origin_discovered") or has_milestone("compact_failure_discovered"):
        state["act"] = ACT_III
    elif has_milestone("act_i_complete") or has_milestone("settlements_reconnected") or has_milestone("different_worldmark_relationships"):
        state["act"] = ACT_II
    else:
        state["act"] = ACT_I
    if has_milestone("settlements_reconnected") and has_milestone("different_worldmark_relationships") and has_milestone("network_instability_revealed"):
        mark_milestone("act_ii_complete")
        if not bool(state.get("completed", false)):
            state["act"] = ACT_III

func mark_milestone(milestone_id: String) -> bool:
    if milestone_id == "":
        return false
    var milestones: Dictionary = state.get("milestones", {})
    if bool(milestones.get(milestone_id, false)):
        return false
    milestones[milestone_id] = true
    state["milestones"] = milestones
    state["lastMessage"] = "Milestone reached: %s" % milestone_id
    return true

func has_milestone(milestone_id: String) -> bool:
    var milestones: Dictionary = state.get("milestones", {})
    return bool(milestones.get(milestone_id, false))

func reveal(revelation_id: String) -> bool:
    if revelation_id == "" or not REVELATION_DEFINITIONS.has(revelation_id):
        return false
    var revelations: Dictionary = state.get("revelations", {})
    if revelations.has(revelation_id):
        return false
    revelations[revelation_id] = REVELATION_DEFINITIONS[revelation_id].duplicate(true)
    state["revelations"] = revelations
    return true

func payload_from_event(event: Dictionary) -> Dictionary:
    var payload_value = event.get("payload", {})
    if payload_value is Dictionary:
        return payload_value
    return {}

func allows_endless_play() -> bool:
    return bool(state.get("endlessWorldContinues", true))

func allows_regional_stories() -> bool:
    return bool(state.get("regionalStoriesEnabled", true))

func is_campaign_complete() -> bool:
    return bool(state.get("completed", false))

func debug_state() -> Dictionary:
    return snapshot()

func dictionary_value(value) -> Dictionary:
    if value is Dictionary:
        return value.duplicate(true)
    return {}

func array_value(value) -> Array:
    if value is Array:
        return value.duplicate(true)
    return []
