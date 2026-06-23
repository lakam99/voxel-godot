extends Node
class_name StoryEventBus

signal story_event(event)

var main

func setup(main_node) -> void:
    main = main_node

func emit_event(event_type: String, subject_id := "", region_id := "", dedupe_key := "", position := Vector3.INF, payload := {}) -> Dictionary:
    var event := build_event(event_type, subject_id, region_id, dedupe_key, position, payload)
    if event.is_empty():
        return {}
    story_event.emit(event)
    return event

func build_event(event_type: String, subject_id := "", region_id := "", dedupe_key := "", position := Vector3.INF, payload := {}) -> Dictionary:
    var clean_type := event_type.strip_edges()
    if clean_type == "":
        return {}
    var world_time := 0.0
    if main != null:
        world_time = float(main.get("world_elapsed"))
    var payload_dict: Dictionary = payload.duplicate(true) if payload is Dictionary else {}
    return {
        "schemaVersion": 1,
        "type": clean_type,
        "subjectId": subject_id,
        "regionId": region_id,
        "dedupeKey": dedupe_key,
        "worldTime": world_time,
        "position": position_to_array(position),
        "payload": payload_dict
    }

func position_to_array(position: Vector3) -> Array:
    if not is_finite(position.x) or not is_finite(position.y) or not is_finite(position.z):
        return []
    return [position.x, position.y, position.z]
