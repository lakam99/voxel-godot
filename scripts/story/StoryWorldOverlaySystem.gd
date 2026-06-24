extends Node
class_name StoryWorldOverlaySystem

const StoryInteractableScene := preload("res://scenes/story/StoryInteractable.tscn")

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
    var event_type := event_type_for_site(site)
    var site_id := String(site.get("id", ""))
    var region_id := String(site.get("regionId", ""))
    var position := site_world_position(site)
    if target is Node3D and target.is_inside_tree():
        position = (target as Node3D).global_position
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
