extends RefCounted
class_name RouteTicket

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

enum State {
	QUEUED,
	WAITING_NAV_DATA,
	PLANNING,
	PROBING,
	READY,
	FOLLOWING,
	ARRIVED,
	FAILED_INVALID_GOAL,
	FAILED_UNREACHABLE,
	CANCELLED,
	INVALIDATED,
	FAILED_INTERNAL
}

var ticket_id := ""
var actor_id := ""
var key := ""
var goal_key := ""
var start_cell := Vector2i(999999, 999999)
var target_cell := Vector2i(999999, 999999)
var intent := {}
var state := State.QUEUED
var reason := "queued"
var route := {}
var created_frame := 0
var updated_frame := 0
var retry_frame := 0
var attempts := 0
var generation := 0

func configure(ticket_id_value: String, actor_id_value: String, key_value: String, goal_key_value: String, start_cell_value: Vector2i, target_cell_value: Vector2i, intent_value: Dictionary, generation_value: int) -> void:
	ticket_id = ticket_id_value
	actor_id = actor_id_value
	key = key_value
	goal_key = goal_key_value
	start_cell = start_cell_value
	target_cell = target_cell_value
	intent = intent_value.duplicate(true)
	generation = generation_value
	created_frame = Engine.get_physics_frames()
	updated_frame = created_frame
	retry_frame = created_frame
	attempts = 0
	state = State.QUEUED
	reason = "queued"
	route = {}

func is_pending() -> bool:
	return state in [State.QUEUED, State.WAITING_NAV_DATA, State.PLANNING, State.PROBING]

func is_ready() -> bool:
	return state == State.READY or state == State.FOLLOWING

func is_terminal_failure() -> bool:
	return state in [State.FAILED_INVALID_GOAL, State.FAILED_UNREACHABLE, State.CANCELLED, State.INVALIDATED, State.FAILED_INTERNAL]

func to_pending_route() -> Dictionary:
	return {
		"ok": false,
		"status": "pending",
		"reason": reason,
		"ticketId": ticket_id,
		"routeTicketState": state_name(),
		"routeAuthorityState": "pending_budget" if state == State.QUEUED or state == State.PLANNING else "pending_nav_data",
		"routeAuthorityReady": false,
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"cells": [],
		"waypoints": [],
		"actions": {}
	}

func state_name() -> String:
	match state:
		State.QUEUED:
			return "queued"
		State.WAITING_NAV_DATA:
			return "waiting_nav_data"
		State.PLANNING:
			return "planning"
		State.PROBING:
			return "probing"
		State.READY:
			return "ready"
		State.FOLLOWING:
			return "following"
		State.ARRIVED:
			return "arrived"
		State.FAILED_INVALID_GOAL:
			return "failed_invalid_goal"
		State.FAILED_UNREACHABLE:
			return "failed_unreachable"
		State.CANCELLED:
			return "cancelled"
		State.INVALIDATED:
			return "invalidated"
		State.FAILED_INTERNAL:
			return "failed_internal"
	return "unknown"
