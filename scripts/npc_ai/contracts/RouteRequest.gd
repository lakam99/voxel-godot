extends RefCounted
class_name RouteRequest

var request_id := ""
var owner_npc_id := ""
var start_position := Vector3.ZERO
var start_span = null
var goal_spec = null
var traversal_profile_id := ""
var goal_kind: StringName = &"idle"
var priority_class := 0
var allow_partial := false
var maximum_acceptable_goal_distance := 0.0
var semantic_preferences := {}
var semantic_avoidances := {}
var topology_revision := 0
var dynamic_revision := 0
var cancellation_generation := 0
var request_tick := 0
var cancelled_generation := -1

func next_generation() -> int:
	cancellation_generation += 1
	return cancellation_generation

func cancel(generation: int) -> bool:
	if generation != cancellation_generation:
		return false
	cancelled_generation = generation
	return true

func is_current_generation(generation: int) -> bool:
	return generation == cancellation_generation and cancelled_generation != generation

func to_summary() -> Dictionary:
	return {
		"requestId": request_id,
		"ownerNpcId": owner_npc_id,
		"goalKind": String(goal_kind),
		"priorityClass": priority_class,
		"allowPartial": allow_partial,
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"generation": cancellation_generation,
		"cancelledGeneration": cancelled_generation
	}

