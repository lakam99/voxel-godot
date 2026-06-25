extends RefCounted
class_name NpcEnums

const ROUTE_STATUS_PENDING := &"pending"
const ROUTE_STATUS_SEARCHING := &"searching"
const ROUTE_STATUS_COMPLETE := &"complete"
const ROUTE_STATUS_PARTIAL := &"partial"
const ROUTE_STATUS_UNREACHABLE := &"unreachable"
const ROUTE_STATUS_INVALIDATED := &"invalidated"
const ROUTE_STATUS_CANCELLED := &"cancelled"
const ROUTE_STATUS_FAILED_INTERNAL := &"failed_internal"
const ROUTE_STATUS_ARRIVED := ROUTE_STATUS_COMPLETE
const ROUTE_STATUS_BLOCKED := ROUTE_STATUS_UNREACHABLE
const ROUTE_STATUS_FAILED := ROUTE_STATUS_FAILED_INTERNAL

const ROUTE_REASON_NONE := &"none"
const ROUTE_REASON_WAITING_FOR_TOPOLOGY := &"waiting_for_topology"
const ROUTE_REASON_NO_ROUTE := &"no_route"
const ROUTE_REASON_PARTIAL_ONLY := &"partial_only"
const ROUTE_REASON_CANCELLED := &"cancelled"
const ROUTE_REASON_STALE_GENERATION := &"stale_generation"
const ROUTE_REASON_PENDING_BUDGET := &"pending_budget"
const ROUTE_REASON_NO_START_SPAN := &"no_start_span"
const ROUTE_REASON_NO_GOAL_SPAN := &"no_goal_span"
const ROUTE_REASON_LOCKED_OR_UNAUTHORIZED := &"locked_or_unauthorized"
const ROUTE_REASON_QUEUE_CAPACITY := &"queue_capacity"

const ACTION_STATUS_PENDING := &"pending"
const ACTION_STATUS_RUNNING := &"running"
const ACTION_STATUS_SUCCEEDED := &"succeeded"
const ACTION_STATUS_FAILED := &"failed"
const ACTION_STATUS_CANCELLED := &"cancelled"

const INTERACTION_STATUS_PENDING := &"pending"
const INTERACTION_STATUS_RUNNING := &"running"
const INTERACTION_STATUS_SUCCEEDED := &"succeeded"
const INTERACTION_STATUS_FAILED := &"failed"
const INTERACTION_STATUS_CANCELLED := &"cancelled"

const DOOR_STATE_UNKNOWN := &"unknown"
const DOOR_STATE_CLOSED := &"closed"
const DOOR_STATE_OPEN := &"open"

const RESERVATION_STATUS_PENDING := &"pending"
const RESERVATION_STATUS_GRANTED := &"granted"
const RESERVATION_STATUS_DENIED := &"denied"
const RESERVATION_STATUS_RELEASED := &"released"

const RECOVERY_REASON_NONE := &"none"
const RECOVERY_REASON_STUCK := &"stuck"
const RECOVERY_REASON_BLOCKED := &"blocked"
const RECOVERY_REASON_STALE_ROUTE := &"stale_route"

const SCHEDULE_STATE_DAWN := &"dawn"
const SCHEDULE_STATE_DAY := &"day"
const SCHEDULE_STATE_DUSK := &"dusk"
const SCHEDULE_STATE_NIGHT := &"night"

const GOAL_KIND_IDLE := &"idle"
const GOAL_KIND_HOME := &"home"
const GOAL_KIND_WORK := &"work"
const GOAL_KIND_GUARD := &"guard"
const GOAL_KIND_FORAGE := &"forage"
const GOAL_KIND_SCRIPTED := &"scripted"

const TRAVERSAL_KIND_WALK := &"walk"
const TRAVERSAL_KIND_STEP := &"step"
const TRAVERSAL_KIND_DROP := &"drop"
const TRAVERSAL_KIND_DOOR := &"door"
const TRAVERSAL_KIND_SPECIAL := &"special"

const CHANGE_KIND_BLOCK_CREATED := &"block_created"
const CHANGE_KIND_BLOCK_REMOVED := &"block_removed"
const CHANGE_KIND_TERRAIN_EDIT := &"terrain_edit"
const CHANGE_KIND_PROP_CREATED := &"prop_created"
const CHANGE_KIND_PROP_REMOVED := &"prop_removed"
const CHANGE_KIND_CHUNK_LOADED := &"chunk_loaded"
const CHANGE_KIND_CHUNK_UNLOADED := &"chunk_unloaded"
const CHANGE_KIND_DOOR_REGISTERED := &"door_registered"
const CHANGE_KIND_DOOR_STATE := &"door_state"
const CHANGE_KIND_STRUCTURE_METADATA := &"structure_metadata"
const CHANGE_KIND_SEMANTIC_CHANGED := &"semantic_changed"

const GUARD_DUTY_NONE := &"none"
const GUARD_DUTY_NIGHT := &"night_guard"

static func normalize(value) -> StringName:
	return StringName(String(value))

static func route_terminal_statuses() -> Array[StringName]:
	return [
		ROUTE_STATUS_COMPLETE,
		ROUTE_STATUS_PARTIAL,
		ROUTE_STATUS_UNREACHABLE,
		ROUTE_STATUS_INVALIDATED,
		ROUTE_STATUS_CANCELLED,
		ROUTE_STATUS_FAILED_INTERNAL
	]

static func action_terminal_statuses() -> Array[StringName]:
	return [ACTION_STATUS_SUCCEEDED, ACTION_STATUS_FAILED, ACTION_STATUS_CANCELLED]

static func interaction_terminal_statuses() -> Array[StringName]:
	return [INTERACTION_STATUS_SUCCEEDED, INTERACTION_STATUS_FAILED, INTERACTION_STATUS_CANCELLED]

static func route_status_is_terminal(status) -> bool:
	return route_terminal_statuses().has(normalize(status))

static func action_status_is_terminal(status) -> bool:
	return action_terminal_statuses().has(normalize(status))

static func interaction_status_is_terminal(status) -> bool:
	return interaction_terminal_statuses().has(normalize(status))
