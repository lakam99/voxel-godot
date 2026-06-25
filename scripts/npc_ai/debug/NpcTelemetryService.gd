extends RefCounted
class_name NpcTelemetryService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var ring_capacity := NpcConstantsScript.TELEMETRY_RING_CAPACITY
var global_counters := {}
var per_npc_events := {}
var dropped_events := {}

func increment(counter: StringName, amount := 1) -> void:
	var key := String(counter)
	if not global_counters.has(key) and global_counters.size() >= NpcConstantsScript.TELEMETRY_GLOBAL_COUNTER_LIMIT:
		return
	global_counters[key] = int(global_counters.get(key, 0)) + amount

func record_event(npc_id: String, category: StringName, transition: String, reason: StringName = &"none", metrics := {}) -> Dictionary:
	var key := npc_id if npc_id != "" else "_global"
	var events: Array = per_npc_events.get(key, [])
	var event := {
		"tick": Engine.get_process_frames(),
		"timeUnix": Time.get_unix_time_from_system(),
		"actor": key,
		"category": String(category),
		"transition": transition,
		"reason": String(reason),
		"metrics": metrics.duplicate(true)
	}
	events.append(event)
	while events.size() > ring_capacity:
		events.pop_front()
		dropped_events[key] = int(dropped_events.get(key, 0)) + 1
	per_npc_events[key] = events
	increment(StringName("event_%s" % String(category)))
	return event

func events_for(npc_id: String) -> Array:
	return per_npc_events.get(npc_id if npc_id != "" else "_global", []).duplicate(true)

func stats() -> Dictionary:
	var sizes := {}
	for key in per_npc_events.keys():
		sizes[key] = (per_npc_events[key] as Array).size()
	return {
		"ringCapacity": ring_capacity,
		"counters": global_counters.duplicate(),
		"eventSizes": sizes,
		"droppedEvents": dropped_events.duplicate()
	}

