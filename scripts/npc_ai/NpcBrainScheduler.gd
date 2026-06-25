extends RefCounted
class_name NpcBrainScheduler

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var max_updates_per_tick := NpcConstantsScript.BRAIN_UPDATES_PER_TICK
var max_registered_agents := NpcConstantsScript.BRAIN_REGISTERED_AGENT_LIMIT
var registered_ids: Array[String] = []
var cursor := 0
var denied_registrations := 0

func register_agent(stable_id: String) -> bool:
	if stable_id == "" or registered_ids.has(stable_id):
		return stable_id != ""
	if registered_ids.size() >= max_registered_agents:
		denied_registrations += 1
		return false
	registered_ids.append(stable_id)
	registered_ids.sort()
	return true

func unregister_agent(stable_id: String) -> void:
	var index := registered_ids.find(stable_id)
	if index >= 0:
		registered_ids.remove_at(index)
		cursor = mini(cursor, max(0, registered_ids.size() - 1))

func next_update_slice() -> Array[String]:
	var result: Array[String] = []
	if registered_ids.is_empty():
		return result
	var count := mini(max_updates_per_tick, registered_ids.size())
	for i in range(count):
		result.append(registered_ids[(cursor + i) % registered_ids.size()])
	cursor = (cursor + count) % registered_ids.size()
	return result

func stats() -> Dictionary:
	return {
		"registered": registered_ids.size(),
		"maxRegistered": max_registered_agents,
		"maxUpdatesPerTick": max_updates_per_tick,
		"deniedRegistrations": denied_registrations,
		"cursor": cursor
	}

