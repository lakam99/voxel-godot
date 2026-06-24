extends Node
class_name StoryWorldOverlaySystem

const StoryInteractableScene := preload("res://scenes/story/StoryInteractable.tscn")
const STAGE_PREPARE_COUNTERMEASURE := "prepare_countermeasure_placeholder"
const STAGE_RETUNE_BOUNDARY_STONES := "retune_boundary_stones_placeholder"
const STAGE_ENCOUNTER_LOCKED := "encounter_locked_placeholder"
const REQUIRED_TOOL_ITEMS := ["surveyLens", "wardLantern"]
const RETUNE_COSTS := { "nightShard": 1 }

var main
var story_director
var site_placement
var overlay_root: Node3D
var active_region_id := ""
var spawned_sites := {}
var last_message := ""

func setup(main_node, director_node, placement_node) -> void:
    main = main_node
    story_director = director_node
    site_placement = placement_node
    if overlay_root == null:
        overlay_root = Node3D.new()
        overlay_root.name = "StoryWorldOverlay"
        add_child(overlay_root)

func reset() -> void:
    clear_overlay()
    active_region_id = ""
    last_message = ""

func ensure_sites_for_region(region_id: String) -> Array:
    if story_director == null or site_placement == null or region_id == "":
        return []
    var record: Dictionary = story_director.ensure_region_record_for_id(region_id)
    if record.is_empty():
        return []
    var sites: Array = site_placement.ensure_sites(record)
    story_director.region_records[region_id] = record
    return sites

func sync_for_region(region_id: String) -> void:
    var affected_region := affected_region_id()
    if region_id == affected_region and affected_region != "":
        spawn_region_overlay(region_id)
        return
    clear_overlay()

func spawn_region_overlay(region_id: String) -> void:
    if active_region_id == region_id and overlay_root != null and overlay_root.get_child_count() > 0:
        return
    clear_overlay()
    active_region_id = region_id
    var sites := ensure_sites_for_region(region_id)
    for site_value in sites:
        if not (site_value is Dictionary):
            continue
        var site: Dictionary = site_value
        var node := StoryInteractableScene.instantiate()
        overlay_root.add_child(node)
        if node.has_method("configure"):
            node.configure(site)
        spawned_sites[String(site.get("id", ""))] = node

func clear_overlay() -> void:
    if overlay_root != null:
        for child in overlay_root.get_children():
            overlay_root.remove_child(child)
            child.queue_free()
    spawned_sites.clear()
    active_region_id = ""

func interact_with_node(node: Node) -> bool:
    if node == null:
        return false
    var target := story_interactable_from_node(node)
    if target == null:
        return false
    var site: Dictionary = target.get_meta("storySite", {})
    if site.is_empty():
        return false
    var site_id := String(site.get("id", ""))
    var region_id := String(site.get("regionId", ""))
    var position := site_world_position(site)
    if target is Node3D and target.is_inside_tree():
        position = (target as Node3D).global_position
    if String(site.get("kind", "")) == "boundary_stone" and should_handle_boundary_retune(site):
        return interact_boundary_stone(site, position)
    var event_type := event_type_for_site(site)
    if main != null and main.has_method("emit_story_event"):
        main.emit_story_event(event_type, site_id, region_id, "story_site:%s" % site_id, position, {
            "siteId": site_id,
            "kind": String(site.get("kind", "")),
            "clueKind": String(site.get("clueKind", "")),
            "clueId": site_id,
            "textId": String(site.get("textId", "")),
            "label": String(site.get("label", ""))
        })
        if main.has_method("update_hud"):
            main.update_hud(authored_text_for_site(site))
    last_message = authored_text_for_site(site)
    return true

func should_handle_boundary_retune(site: Dictionary) -> bool:
    var quest := current_quest()
    if quest.is_empty():
        return false
    if String(site.get("regionId", "")) != String(quest.get("affectedRegionId", "")):
        return false
    return String(quest.get("stage", "")) in [
        STAGE_PREPARE_COUNTERMEASURE,
        STAGE_RETUNE_BOUNDARY_STONES,
        STAGE_ENCOUNTER_LOCKED
    ]

func interact_boundary_stone(site: Dictionary, position: Vector3) -> bool:
    var quest := current_quest()
    var facts := facts_for_quest(quest)
    var stage := String(quest.get("stage", ""))
    var stone_id := stone_id_for_site(site)
    var stone_ids: Array = facts.get("boundaryStoneIds", [])
    if stone_ids.has(stone_id):
        set_story_message("This boundary stone already holds the quieter rhythm.")
        return true
    if stage == STAGE_ENCOUNTER_LOCKED:
        set_story_message("The boundary stones hold. The storm hollow can now be approached.")
        return true
    if not has_countermeasure_requirements():
        set_story_message(missing_countermeasure_text())
        return true
    if not bool(facts.get("countermeasurePrepared", false)):
        emit_countermeasure_prepared(site, position)
        quest = current_quest()
        facts = facts_for_quest(quest)
        stage = String(quest.get("stage", ""))
    if stage != STAGE_RETUNE_BOUNDARY_STONES:
        set_story_message(authored_text_for_site(site))
        return true
    var inventory = inventory_node()
    if inventory == null or not inventory.has_method("consume_costs") or not bool(inventory.consume_costs(RETUNE_COSTS)):
        set_story_message(missing_countermeasure_text())
        return true
    var emitted := emit_boundary_stone_retuned(site, position)
    if not emitted:
        restore_costs(RETUNE_COSTS)
        set_story_message("The boundary stone refuses the tuning for now.")
        return true
    var updated_facts := facts_for_quest(current_quest())
    if int(updated_facts.get("boundaryStonesRetuned", 0)) >= 2:
        set_story_message("Both boundary stones hold a calmer rhythm. The storm hollow can be approached.")
    else:
        set_story_message("The boundary stone answers the Ward Lantern. One stone remains.")
    return true

func emit_countermeasure_prepared(site: Dictionary, position: Vector3) -> bool:
    if main == null or not main.has_method("emit_story_event"):
        return false
    var region_id := String(site.get("regionId", ""))
    return bool(main.emit_story_event(
        "story_countermeasure_prepared",
        "countermeasure:gloam_hart",
        region_id,
        "story_countermeasure_prepared:%s" % region_id,
        position,
        {
            "siteId": String(site.get("id", "")),
            "stoneId": stone_id_for_site(site),
            "source": "boundary_stone",
            "items": REQUIRED_TOOL_ITEMS.duplicate(),
            "costs": RETUNE_COSTS.duplicate()
        }
    ))

func emit_boundary_stone_retuned(site: Dictionary, position: Vector3) -> bool:
    if main == null or not main.has_method("emit_story_event"):
        return false
    var region_id := String(site.get("regionId", ""))
    var stone_id := stone_id_for_site(site)
    return bool(main.emit_story_event(
        "story_boundary_stone_retuned",
        "boundary_stone:%s" % stone_id,
        region_id,
        "story_boundary_stone_retuned:%s:%s" % [region_id, stone_id],
        position,
        {
            "siteId": String(site.get("id", "")),
            "kind": "boundary_stone",
            "clueId": stone_id,
            "stoneId": stone_id,
            "definitionId": String(site.get("definitionId", "")),
            "itemsVerified": REQUIRED_TOOL_ITEMS.duplicate(),
            "costsConsumed": RETUNE_COSTS.duplicate(),
            "historyClueFound": bool(facts_for_quest(current_quest()).get("historyClueFound", false))
        }
    ))

func has_countermeasure_requirements() -> bool:
    var inventory = inventory_node()
    if inventory == null:
        return false
    for item_id in REQUIRED_TOOL_ITEMS:
        if not inventory.has_method("count") or int(inventory.count(String(item_id))) <= 0:
            return false
    if not inventory.has_method("has_costs"):
        return false
    return bool(inventory.has_costs(RETUNE_COSTS))

func missing_countermeasure_text() -> String:
    var inventory = inventory_node()
    if inventory == null:
        return "Need a Survey Lens, a Ward Lantern, and a Night Shard charge to retune this stone."
    var missing: Array[String] = []
    if not inventory.has_method("count") or int(inventory.count("surveyLens")) <= 0:
        missing.append("Survey Lens")
    if not inventory.has_method("count") or int(inventory.count("wardLantern")) <= 0:
        missing.append("Ward Lantern")
    if not inventory.has_method("has_costs") or not bool(inventory.has_costs(RETUNE_COSTS)):
        missing.append("Night Shard charge")
    if missing.is_empty():
        return "The boundary stone is ready for tuning."
    return "Need %s to retune this boundary stone." % ", ".join(missing)

func restore_costs(costs: Dictionary) -> void:
    var inventory = inventory_node()
    if inventory == null or not inventory.has_method("add_item"):
        return
    for item_id_variant in costs.keys():
        inventory.add_item(String(item_id_variant), int(costs[item_id_variant]))

func current_quest() -> Dictionary:
    if story_director == null or story_director.quest_system == null:
        return {}
    if story_director.quest_system.has_method("first_quest"):
        return story_director.quest_system.first_quest()
    return {}

func facts_for_quest(quest: Dictionary) -> Dictionary:
    var facts_value = quest.get("facts", {})
    if facts_value is Dictionary:
        return facts_value
    return {}

func inventory_node():
    if main == null:
        return null
    return main.get("inventory_system")

func stone_id_for_site(site: Dictionary) -> String:
    var definition_id := String(site.get("definitionId", ""))
    if definition_id != "":
        return definition_id
    return String(site.get("id", ""))

func set_story_message(message: String) -> void:
    last_message = message
    if main != null and main.has_method("update_hud"):
        main.update_hud(message)

func story_interactable_from_node(node: Node) -> Node:
    var current := node
    while current != null:
        if current.has_meta("kind") and String(current.get_meta("kind")) == "story_interactable":
            return current
        current = current.get_parent()
    return null

func event_type_for_site(site: Dictionary) -> String:
    var kind := String(site.get("kind", ""))
    if kind == "clue":
        return "story_clue_found"
    if kind == "boundary_stone":
        return "story_boundary_stone_discovered"
    if kind == "encounter_marker":
        return "story_encounter_marker_found"
    return "story_site_inspected"

func authored_text_for_site(site: Dictionary) -> String:
    match String(site.get("definitionId", "")):
        "ordinary_antler_scars":
            return "Pale antler scars mark the bark, all facing away from the old lantern line."
        "ordinary_ringing_stone":
            return "The boundary stone gives a faint ring under the rain, like metal under strain."
        "ordinary_broken_lantern":
            return "The broken lantern frame was pushed away from the trees, not toward town."
        "historical_old_compact":
            return "The old record names a compact: lantern light was meant to spare the Hart, not bind it."
        "boundary_stone_north", "boundary_stone_south":
            return "The boundary stone is cold and waiting. You do not yet know how to retune it."
        "encounter_marker":
            return "A storm-lashed hollow waits beyond the signs. The way forward is not ready."
    return String(site.get("label", "Story sign"))

func site_world_position(site: Dictionary) -> Vector3:
    var cell_value = site.get("cell", [])
    if cell_value is Array and cell_value.size() >= 2:
        return Vector3(float(cell_value[0]) * 1.35, float(site.get("worldY", 0.0)), float(cell_value[1]) * 1.35)
    return Vector3.INF

func affected_region_id() -> String:
    if story_director == null or story_director.quest_system == null:
        return ""
    var quest: Dictionary = story_director.quest_system.first_quest() if story_director.quest_system.has_method("first_quest") else {}
    return String(quest.get("affectedRegionId", ""))

func debug_state() -> Dictionary:
    return {
        "activeRegionId": active_region_id,
        "spawnedSites": spawned_sites.keys(),
        "spawnedCount": spawned_sites.size(),
        "lastMessage": last_message
    }
