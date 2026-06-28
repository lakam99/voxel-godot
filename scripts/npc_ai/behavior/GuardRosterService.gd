extends RefCounted
class_name GuardRosterService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var duty_by_npc := {}

func role_allows_guard_duty(role: String) -> bool:
	var lowered := role.to_lower()
	return lowered.find("guard") >= 0 or lowered.find("watch") >= 0

func assign_duty_from_entry(context, entry: Dictionary) -> bool:
	var explicit_night_guard := bool(entry.get("nightGuard", false))
	var assigned := explicit_night_guard
	if context != null:
		context.set("guard_duty_kind", NpcEnumsScript.GUARD_DUTY_NIGHT if assigned else NpcEnumsScript.GUARD_DUTY_NONE)
	entry["nightGuard"] = assigned
	entry["guardDutyKind"] = NpcEnumsScript.GUARD_DUTY_NIGHT if assigned else NpcEnumsScript.GUARD_DUTY_NONE
	var npc_id := String(entry.get("id", context.get("stable_id") if context != null else ""))
	if assigned:
		duty_by_npc[npc_id] = {
			"kind": String(NpcEnumsScript.GUARD_DUTY_NIGHT),
			"guardCell": entry.get("guardCell", entry.get("porchCell", Vector2i.ZERO)),
			"postId": "guard:%s" % npc_id
		}
	else:
		duty_by_npc.erase(npc_id)
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_guard_duty", String(entry["guardDutyKind"]))
	return assigned

func has_active_night_duty(context, entry: Dictionary) -> bool:
	if context != null and context.get("guard_duty_kind") == NpcEnumsScript.GUARD_DUTY_NIGHT:
		return true
	return bool(entry.get("nightGuard", false))

func duty_for(entry: Dictionary) -> Dictionary:
	return duty_by_npc.get(String(entry.get("id", "")), {})

func summary() -> Dictionary:
	return {
		"assignedCount": duty_by_npc.size(),
		"assignedIds": duty_by_npc.keys()
	}
