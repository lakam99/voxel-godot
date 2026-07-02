extends Node
class_name WorldmarkEncounterController

const GloamHartEncounterScene := preload("res://scenes/story/GloamHartEncounter.tscn")
const FIRST_QUEST_ID := "story.gloam_hart.storm"
const ENCOUNTER_NODE_BUDGET := 80
const ENCOUNTER_MINION_BUDGET := 6
const REWARD_TABLE := {
    "slay": { "nightShard": 6, "riftCore": 1, "relicFragment": 2 },
    "release": { "wardTonic": 2, "relicFragment": 3 }
}

var main
var story_director
var active_encounter: Node
var active_region_id := ""
var last_message := ""
var recovered_from_save := false

func setup(main_node, director_node) -> void:
    main = main_node
    story_director = director_node

func reset() -> void:
    clear_active_encounter(false)
    active_region_id = ""
    last_message = ""
    recovered_from_save = false

func start_encounter_from_site(site: Dictionary, position: Vector3) -> bool:
    var region_id := String(site.get("regionId", ""))
    if region_id == "":
        last_message = "No story region for the storm hollow"
        return false
    var quest := first_quest()
    var facts := facts_for_quest(quest)
    if String(quest.get("affectedRegionId", "")) != region_id:
        last_message = "This hollow is quiet"
        return false
    if worldmark_resolution(region_id) != "":
        last_message = "The Gloam Hart has already been resolved"
        show_message(last_message)
        return true
    if not bool(facts.get("encounterUnlocked", false)):
        last_message = "The storm hollow is not ready"
        show_message(last_message)
        return true
    var phase := maxi(1, int(encounter_state(region_id).get("phase", 1)))
    return start_encounter(region_id, position, phase, false)

func start_encounter(region_id: String, position: Vector3, phase := 1, recovered := false) -> bool:
    if story_director == null or region_id == "":
        last_message = "No story director for the Worldmark encounter"
        return false
    if worldmark_resolution(region_id) != "":
        last_message = "The Gloam Hart has already been resolved"
        return true
    clear_active_encounter(false)
    var encounter := GloamHartEncounterScene.instantiate()
    active_encounter = encounter
    active_region_id = region_id
    encounter.name = "GloamHartEncounter"
    add_child(encounter)
    var safe_position := encounter_position(region_id, position)
    var facts := facts_for_quest(first_quest())
    encounter.setup(main, self, {
        "regionId": region_id,
        "encounterId": "gloam_hart",
        "position": safe_position,
        "phase": clampi(phase, 1, 3),
        "releaseAvailable": bool(facts.get("releaseRouteAvailable", false)),
        "countermeasureEffect": bool(facts.get("stormWeakened", false))
    })
    write_encounter_state(region_id, {
        "status": "active",
        "phase": clampi(phase, 1, 3),
        "entrancePosition": vector3_to_array(safe_position),
        "recoveredFromSave": recovered,
        "resolution": ""
    })
    recovered_from_save = recovered
    if recovered:
        move_player_to_recovery_position(safe_position)
        last_message = "Recovered at the Gloam Hart encounter"
    else:
        emit_story_event("story_worldmark_encounter_started", region_id, safe_position, {
            "phase": clampi(phase, 1, 3)
        })
        last_message = "The Gloam Hart steps from the storm hollow"
    show_message(last_message)
    return true

func damage_active_encounter(amount: float, source := "player") -> bool:
    if active_encounter == null or not is_instance_valid(active_encounter):
        last_message = "No active Worldmark encounter"
        return false
    var encounter := active_encounter
    if not encounter.has_method("apply_player_damage"):
        return false
    var resolved := bool(encounter.apply_player_damage(amount, source))
    if not resolved and is_instance_valid(encounter):
        last_message = String(encounter.get("last_message"))
    return resolved

func try_release_active_encounter() -> bool:
    if active_encounter == null or not is_instance_valid(active_encounter):
        last_message = "No active Worldmark encounter"
        return false
    var encounter := active_encounter
    if not encounter.has_method("try_release"):
        return false
    var released := bool(encounter.try_release())
    if not released and is_instance_valid(encounter):
        last_message = String(encounter.get("last_message"))
    return released

func on_encounter_phase_changed(phase: int) -> void:
    if active_region_id == "":
        return
    write_encounter_state(active_region_id, {
        "status": "active",
        "phase": clampi(phase, 1, 3)
    })
    emit_story_event("story_worldmark_encounter_phase", active_region_id, active_position(), {
        "phase": clampi(phase, 1, 3)
    }, "story_worldmark_encounter_phase:%s:%d" % [active_region_id, clampi(phase, 1, 3)])

func resolve_active_encounter(resolution: String) -> bool:
    var region_id := active_region_id
    if region_id == "" and active_encounter != null and is_instance_valid(active_encounter):
        region_id = String(active_encounter.get("region_id"))
    return resolve_region(region_id, resolution, active_position())

func resolve_region(region_id: String, resolution: String, position := Vector3.INF) -> bool:
    if story_director == null or region_id == "" or not (resolution in ["slay", "release"]):
        return false
    var existing_resolution := worldmark_resolution(region_id)
    if existing_resolution != "":
        last_message = "The Gloam Hart has already been resolved"
        clear_active_encounter(false)
        return false
    var record: Dictionary = story_director.region_records.get(region_id, {})
    if record.is_empty():
        record = story_director.ensure_region_record_for_id(region_id)
    var worldmark: Dictionary = record.get("worldmark", {})
    var state: Dictionary = worldmark.get("encounterState", {})
    var rewards_granted := bool(state.get("rewardsGranted", false))
    if not rewards_granted:
        grant_resolution_rewards(resolution)
        rewards_granted = true
    state["status"] = "resolved"
    state["phase"] = 3
    state["resolution"] = resolution
    state["rewardsGranted"] = rewards_granted
    state["resolvedAtWorldTime"] = float(main.get("world_elapsed")) if main != null else 0.0
    worldmark["encounterState"] = state
    worldmark["resolution"] = resolution
    record["worldmark"] = worldmark
    record["state"] = "resolved_%s" % resolution
    story_director.region_records[region_id] = record
    emit_story_event("story_worldmark_resolved", region_id, position, {
        "resolution": resolution,
        "rewardsGranted": rewards_granted
    }, "story_worldmark_resolved:%s" % region_id)
    clear_active_encounter(false)
    last_message = "Gloam Hart slain" if resolution == "slay" else "Gloam Hart released"
    show_message(last_message)
    return true

func recover_after_load() -> bool:
    if story_director == null:
        return false
    clear_active_encounter(false)
    for region_id_value in story_director.region_records.keys():
        var region_id := String(region_id_value)
        var state := encounter_state(region_id)
        if String(state.get("status", "")) != "active":
            continue
        if worldmark_resolution(region_id) != "":
            continue
        var position := vector3_from_array(state.get("entrancePosition", []), Vector3.INF)
        return start_encounter(region_id, position, clampi(int(state.get("phase", 1)), 1, 3), true)
    return false

func clear_active_encounter(remove_node := true) -> void:
    if active_encounter != null and is_instance_valid(active_encounter):
        if active_encounter.has_method("cleanup_minions"):
            active_encounter.cleanup_minions()
        if remove_node:
            remove_child(active_encounter)
        active_encounter.queue_free()
    active_encounter = null
    active_region_id = ""

func grant_resolution_rewards(resolution: String) -> void:
    if main == null:
        return
    var inventory = main.get("inventory_system")
    if inventory == null or not inventory.has_method("add_item"):
        return
    var rewards: Dictionary = REWARD_TABLE.get(resolution, {})
    for item_id_variant in rewards.keys():
        inventory.add_item(String(item_id_variant), int(rewards[item_id_variant]))

func write_encounter_state(region_id: String, values: Dictionary) -> void:
    if story_director == null or region_id == "":
        return
    var record: Dictionary = story_director.region_records.get(region_id, {})
    if record.is_empty():
        record = story_director.ensure_region_record_for_id(region_id)
    var worldmark: Dictionary = record.get("worldmark", {})
    var state: Dictionary = worldmark.get("encounterState", {})
    for key in values.keys():
        state[key] = values[key]
    worldmark["encounterState"] = state
    record["worldmark"] = worldmark
    story_director.region_records[region_id] = record

func encounter_state(region_id: String) -> Dictionary:
    if story_director == null or not story_director.region_records.has(region_id):
        return {}
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    var state_value = worldmark.get("encounterState", {})
    return state_value.duplicate(true) if state_value is Dictionary else {}

func worldmark_resolution(region_id: String) -> String:
    if story_director == null or not story_director.region_records.has(region_id):
        return ""
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var worldmark: Dictionary = record.get("worldmark", {})
    return String(worldmark.get("resolution", ""))

func first_quest() -> Dictionary:
    if story_director == null or story_director.quest_system == null:
        return {}
    if story_director.quest_system.has_method("first_quest"):
        return story_director.quest_system.first_quest()
    return {}

func facts_for_quest(quest: Dictionary) -> Dictionary:
    var facts_value = quest.get("facts", {})
    return facts_value if facts_value is Dictionary else {}

func encounter_position(region_id: String, fallback: Vector3) -> Vector3:
    if is_finite(fallback.x) and is_finite(fallback.z):
        var adjusted := fallback
        if main != null and main.has_method("surface_y_at_position"):
            adjusted.y = float(main.call("surface_y_at_position", adjusted)) + 0.15
        return adjusted
    var site_position := encounter_site_position(region_id)
    if is_finite(site_position.x) and is_finite(site_position.z):
        return site_position
    return Vector3.ZERO

func encounter_site_position(region_id: String) -> Vector3:
    if story_director == null or not story_director.region_records.has(region_id):
        return Vector3.INF
    var record: Dictionary = story_director.region_records.get(region_id, {})
    var sites: Array = record.get("storySites", [])
    for site_value in sites:
        if not (site_value is Dictionary):
            continue
        var site: Dictionary = site_value
        if String(site.get("definitionId", "")) != "encounter_marker":
            continue
        var cell_value = site.get("cell", [])
        if cell_value is Array and cell_value.size() >= 2:
            var pos := Vector3(float(cell_value[0]) * 1.35, float(site.get("worldY", 0.0)), float(cell_value[1]) * 1.35)
            if main != null and main.has_method("surface_y_at_position"):
                pos.y = float(main.call("surface_y_at_position", pos)) + 0.15
            return pos
    return Vector3.INF

func move_player_to_recovery_position(position: Vector3) -> void:
    if main == null or main.get("player") == null:
        return
    var player_node := main.get("player") as Node3D
    if player_node == null:
        return
    var recovery := position + Vector3(0.0, 0.0, 5.4)
    if main.has_method("surface_y_at_position"):
        recovery.y = float(main.call("surface_y_at_position", recovery)) + 1.2
    player_node.global_position = recovery

func active_position() -> Vector3:
    if active_encounter is Node3D and is_instance_valid(active_encounter):
        return (active_encounter as Node3D).global_position
    return Vector3.INF

func emit_story_event(event_type: String, region_id: String, position: Vector3, payload := {}, dedupe_key := "") -> bool:
    if main == null or not main.has_method("emit_story_event"):
        return false
    var key := dedupe_key
    if key == "":
        key = "%s:%s" % [event_type, region_id]
    return bool(main.emit_story_event(event_type, "worldmark:gloam_hart", region_id, key, position, payload))

func show_message(message: String) -> void:
    if main != null and main.has_method("update_hud"):
        main.update_hud(message)

func vector3_to_array(value: Vector3) -> Array:
    return [value.x, value.y, value.z]

func vector3_from_array(value, fallback: Vector3) -> Vector3:
    if value is Array and value.size() >= 3:
        return Vector3(float(value[0]), float(value[1]), float(value[2]))
    return fallback

func debug_state() -> Dictionary:
    return {
        "active": active_encounter != null and is_instance_valid(active_encounter),
        "activeRegionId": active_region_id,
        "recoveredFromSave": recovered_from_save,
        "lastMessage": last_message,
        "encounter": active_encounter.debug_state() if active_encounter != null and is_instance_valid(active_encounter) and active_encounter.has_method("debug_state") else {},
        "performance": performance_state()
    }

func performance_state() -> Dictionary:
    var node_count := count_nodes_recursive(active_encounter)
    var visual_count := count_visual_nodes(active_encounter)
    var minion_count := 0
    if active_encounter != null and is_instance_valid(active_encounter) and active_encounter.has_method("debug_state"):
        minion_count = int(active_encounter.debug_state().get("minions", 0))
    return {
        "active": active_encounter != null and is_instance_valid(active_encounter),
        "nodeCount": node_count,
        "nodeBudget": ENCOUNTER_NODE_BUDGET,
        "visualNodeCount": visual_count,
        "minionCount": minion_count,
        "minionBudget": ENCOUNTER_MINION_BUDGET,
        "budgetOk": node_count <= ENCOUNTER_NODE_BUDGET and minion_count <= ENCOUNTER_MINION_BUDGET
    }

func count_nodes_recursive(node: Node) -> int:
    if node == null or not is_instance_valid(node):
        return 0
    var count := 1
    for child in node.get_children():
        count += count_nodes_recursive(child)
    return count

func count_visual_nodes(node: Node) -> int:
    if node == null or not is_instance_valid(node):
        return 0
    var count := 1 if node is MeshInstance3D or node is MultiMeshInstance3D else 0
    for child in node.get_children():
        count += count_visual_nodes(child)
    return count
