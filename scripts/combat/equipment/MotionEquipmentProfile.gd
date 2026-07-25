extends RefCounted
class_name MotionEquipmentProfile

## Immutable item-side data for a motion rig. A motion remains a body-neutral
## path; this profile describes how a held item's real grip-to-contact segment
## is attached to a compatible semantic socket.

var id := ""
var item_id := ""
var socket_offset := Vector3.ZERO
var item_rotation := Vector3.ZERO
# Optional visual anchor path, resolved below the item root after the visual
# factory has instantiated the asset. This takes precedence over the fallback
# coordinate so a generated asset can declare its real hilt/grip itself.
var item_grip_node_path := ""
# Fallback local grip position after the item's visual factory has applied any
# visual scale. The adapter places this exact point at the semantic hand socket.
var item_grip_local := Vector3.ZERO
var contact_base_offset := Vector3.ZERO
var contact_tip_offset := Vector3.DOWN
var contact_radius := 0.06
var active_phases: Array[String] = []


func _init(values: Dictionary = {}) -> void:
	id = String(values.get("id", "motion_equipment")).strip_edges().to_lower()
	item_id = String(values.get("itemId", "")).strip_edges()
	socket_offset = values.get("socketOffset", Vector3.ZERO) as Vector3
	item_rotation = values.get("itemRotation", Vector3.ZERO) as Vector3
	item_grip_node_path = String(values.get("itemGripNodePath", "")).strip_edges()
	item_grip_local = values.get("itemGripLocal", Vector3.ZERO) as Vector3
	contact_base_offset = values.get("contactBaseOffset", Vector3.ZERO) as Vector3
	contact_tip_offset = values.get("contactTipOffset", Vector3.DOWN) as Vector3
	if contact_tip_offset.distance_squared_to(contact_base_offset) <= 0.000001:
		contact_tip_offset = contact_base_offset + Vector3.DOWN
	contact_radius = clampf(float(values.get("contactRadius", 0.06)), 0.01, 0.42)
	for raw_phase in values.get("activePhases", ["arc"]):
		var phase := String(raw_phase).strip_edges().to_lower()
		if not phase.is_empty() and not active_phases.has(phase):
			active_phases.append(phase)
	if active_phases.is_empty():
		active_phases.append("arc")


func allows_phase(phase: String) -> bool:
	return active_phases.has(phase.strip_edges().to_lower())


func snapshot() -> Dictionary:
	return {
		"id": id,
		"itemId": item_id,
		"socketOffset": socket_offset,
		"itemRotation": item_rotation,
		"itemGripNodePath": item_grip_node_path,
		"itemGripLocal": item_grip_local,
		"contactBaseOffset": contact_base_offset,
		"contactTipOffset": contact_tip_offset,
		"contactRadius": contact_radius,
		"activePhases": active_phases.duplicate()
	}
