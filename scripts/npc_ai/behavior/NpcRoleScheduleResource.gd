extends Resource
class_name NpcRoleScheduleResource

@export var role_id: String = ""
@export var canonical_job: String = ""
@export var day_goal_kind: StringName = &"idle"
@export var dusk_goal_kind: StringName = &"home"
@export var night_goal_kind: StringName = &"home"
@export var can_take_night_guard := false
@export var requires_interior_home := true
@export var semantic_anchor_kinds: Array[String] = []

func to_dictionary() -> Dictionary:
	return {
		"roleId": role_id,
		"canonicalJob": canonical_job,
		"dayGoalKind": day_goal_kind,
		"duskGoalKind": dusk_goal_kind,
		"nightGoalKind": night_goal_kind,
		"canTakeNightGuard": can_take_night_guard,
		"requiresInteriorHome": requires_interior_home,
		"semanticAnchorKinds": semantic_anchor_kinds.duplicate()
	}
