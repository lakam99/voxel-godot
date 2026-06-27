extends RefCounted
class_name TrafficReservation

const STATUS_PENDING := "pending"
const STATUS_GRANTED := "granted"
const STATUS_RELEASED := "released"

var reservation_id := ""
var group_id := ""
var owner_id := ""
var owner_generation := 0
var action_generation := 0
var resource_id := ""
var resource_kind := ""
var interval_start := 0.0
var interval_end := 0.0
var capacity := 1
var direction := ""
var from_node := ""
var to_node := ""
var priority := 0
var priority_class := "idle"
var status := STATUS_PENDING
var active_crossing := false
var wait_started_at := 0.0
var metadata := {}

static func make(data: Dictionary):
	var reservation = load("res://scripts/npc_ai/contracts/TrafficReservation.gd").new()
	reservation.apply(data)
	return reservation

func apply(data: Dictionary) -> void:
	reservation_id = String(data.get("reservationId", reservation_id))
	group_id = String(data.get("groupId", group_id))
	owner_id = String(data.get("ownerId", owner_id))
	owner_generation = int(data.get("ownerGeneration", owner_generation))
	action_generation = int(data.get("actionGeneration", action_generation))
	resource_id = String(data.get("resourceId", resource_id))
	resource_kind = String(data.get("resourceKind", resource_kind))
	interval_start = float(data.get("intervalStart", interval_start))
	interval_end = float(data.get("intervalEnd", interval_end))
	capacity = maxi(1, int(data.get("capacity", capacity)))
	direction = String(data.get("direction", direction))
	from_node = String(data.get("fromNode", from_node))
	to_node = String(data.get("toNode", to_node))
	priority = int(data.get("priority", priority))
	priority_class = String(data.get("priorityClass", priority_class))
	status = String(data.get("status", status))
	active_crossing = bool(data.get("activeCrossing", active_crossing))
	wait_started_at = float(data.get("waitStartedAt", wait_started_at))
	metadata = (data.get("metadata", {}) as Dictionary).duplicate(true) if data.get("metadata", {}) is Dictionary else {}

func overlaps(start_time: float, end_time: float) -> bool:
	return interval_start < end_time and start_time < interval_end

func is_active() -> bool:
	return status == STATUS_PENDING or status == STATUS_GRANTED

func conflicts_with(other) -> bool:
	if other == null:
		return false
	if owner_id != "" and owner_id == String(other.get("owner_id")):
		return false
	if not overlaps(float(other.get("interval_start")), float(other.get("interval_end"))):
		return false
	if resource_id != "" and resource_id == String(other.get("resource_id")):
		return true
	if String(metadata.get("oppositeResourceId", "")) == String(other.get("resource_id")):
		return true
	var other_metadata = other.get("metadata")
	if other_metadata is Dictionary and String((other_metadata as Dictionary).get("oppositeResourceId", "")) == resource_id:
		return true
	if from_node != "" and to_node != "":
		return from_node == String(other.get("to_node")) and to_node == String(other.get("from_node"))
	return false

func mark_granted(now: float) -> void:
	status = STATUS_GRANTED
	if wait_started_at <= 0.0:
		wait_started_at = now

func mark_released() -> void:
	status = STATUS_RELEASED

func wait_age(now: float) -> float:
	if wait_started_at <= 0.0:
		return 0.0
	return maxf(0.0, now - wait_started_at)

func to_summary() -> Dictionary:
	return {
		"id": reservation_id,
		"groupId": group_id,
		"ownerId": owner_id,
		"ownerGeneration": owner_generation,
		"actionGeneration": action_generation,
		"resourceId": resource_id,
		"resourceKind": resource_kind,
		"start": interval_start,
		"end": interval_end,
		"capacity": capacity,
		"direction": direction,
		"from": from_node,
		"to": to_node,
		"priority": priority,
		"priorityClass": priority_class,
		"status": status,
		"activeCrossing": active_crossing,
		"metadata": metadata.duplicate(true)
	}
