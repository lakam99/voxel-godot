extends RefCounted
class_name NpcScheduleService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const RoleScheduleResourceScript := preload("res://scripts/npc_ai/behavior/NpcRoleScheduleResource.gd")

const CLOCK_DISPLAY_OFFSET := 0.25
const DAWN_START_CLOCK := 5.25 / 24.0
const DAY_FULL_CLOCK := 7.0 / 24.0
const DUSK_START_CLOCK := 18.25 / 24.0
const NIGHT_FULL_CLOCK := 20.25 / 24.0
const ROLE_RESOURCE_PATHS := {
	"guard": "res://resources/npc_roles/guard.tres",
	"farmer": "res://resources/npc_roles/farmer.tres",
	"carpenter": "res://resources/npc_roles/carpenter.tres",
	"forager": "res://resources/npc_roles/forager.tres",
	"mason": "res://resources/npc_roles/mason.tres",
	"trader": "res://resources/npc_roles/trader.tres",
	"civilian": "res://resources/npc_roles/civilian.tres"
}

var guard_roster = null
var injected_snapshot := {}
var role_profiles := {}

func setup(roster) -> void:
	guard_roster = roster
	_load_default_role_profiles()

func inject_snapshot(snapshot: Dictionary) -> void:
	injected_snapshot = snapshot.duplicate(true)

func clear_injected_snapshot() -> void:
	injected_snapshot.clear()

func snapshot_for(context, entry: Dictionary, main: Node, night_factor := -1.0) -> Dictionary:
	if not injected_snapshot.is_empty():
		var injected := injected_snapshot.duplicate(true)
		injected["injected"] = true
		injected["activeGuardDuty"] = _active_guard_duty(context, entry, injected.get("scheduleState", NpcEnumsScript.SCHEDULE_STATE_DAY))
		injected["requiresInteriorHome"] = _requires_interior_home(context, entry)
		injected["mustBeInside"] = _must_be_inside(injected)
		injected["roleProfile"] = role_profile_for(context, entry)
		return injected
	var time_of_day := 0.25
	if main != null:
		time_of_day = float(main.get("time_of_day"))
	elif night_factor >= 0.45:
		time_of_day = 0.75
	var clock_phase := fposmod(time_of_day + CLOCK_DISPLAY_OFFSET, 1.0)
	var schedule_state := state_for_clock_phase(clock_phase)
	var active_guard := _active_guard_duty(context, entry, schedule_state)
	var snapshot := {
		"timeOfDay": time_of_day,
		"clockPhase": clock_phase,
		"displayHour": clock_phase * 24.0,
		"scheduleState": schedule_state,
		"activeGuardDuty": active_guard,
		"requiresInteriorHome": _requires_interior_home(context, entry),
		"mustBeInside": false,
		"earlyReturn": schedule_state == NpcEnumsScript.SCHEDULE_STATE_DUSK and not active_guard,
		"dayRelease": schedule_state == NpcEnumsScript.SCHEDULE_STATE_DAY or schedule_state == NpcEnumsScript.SCHEDULE_STATE_DAWN,
		"roleProfile": role_profile_for(context, entry),
		"injected": false
	}
	snapshot["mustBeInside"] = _must_be_inside(snapshot)
	return snapshot

func state_for_clock_phase(clock_phase: float) -> StringName:
	if clock_phase >= NIGHT_FULL_CLOCK or clock_phase < DAWN_START_CLOCK:
		return NpcEnumsScript.SCHEDULE_STATE_NIGHT
	if clock_phase < DAY_FULL_CLOCK:
		return NpcEnumsScript.SCHEDULE_STATE_DAWN
	if clock_phase >= DUSK_START_CLOCK:
		return NpcEnumsScript.SCHEDULE_STATE_DUSK
	return NpcEnumsScript.SCHEDULE_STATE_DAY

func role_profile_for(context, entry: Dictionary) -> Dictionary:
	var role := String(entry.get("role", context.get("role") if context != null else "civilian")).to_lower()
	if role.find("guard") >= 0 or role.find("watch") >= 0:
		role = "guard"
	elif role.find("farmer") >= 0:
		role = "farmer"
	elif role.find("carpenter") >= 0 or role.find("wood") >= 0:
		role = "carpenter"
	elif role.find("forager") >= 0:
		role = "forager"
	elif role.find("mason") >= 0 or role.find("stone") >= 0:
		role = "mason"
	elif role.find("trader") >= 0:
		role = "trader"
	else:
		role = "civilian"
	var resource = role_profiles.get(role, role_profiles.get("civilian"))
	return resource.to_dictionary() if resource != null else {}

func _active_guard_duty(context, entry: Dictionary, schedule_state) -> bool:
	if not (schedule_state in [NpcEnumsScript.SCHEDULE_STATE_DUSK, NpcEnumsScript.SCHEDULE_STATE_NIGHT]):
		return false
	if guard_roster == null:
		return bool(entry.get("nightGuard", false))
	return guard_roster.has_active_night_duty(context, entry)

func _requires_interior_home(_context, entry: Dictionary) -> bool:
	return bool(entry.get("hasHome", true)) or bool(entry.get("homeCell", Vector2i.ZERO) is Vector2i)

func _must_be_inside(snapshot: Dictionary) -> bool:
	return bool(snapshot.get("requiresInteriorHome", true)) and not bool(snapshot.get("activeGuardDuty", false)) and String(snapshot.get("scheduleState", "")) in [String(NpcEnumsScript.SCHEDULE_STATE_DUSK), String(NpcEnumsScript.SCHEDULE_STATE_NIGHT)]

func _load_default_role_profiles() -> void:
	if not role_profiles.is_empty():
		return
	for role_id in ROLE_RESOURCE_PATHS.keys():
		var path := String(ROLE_RESOURCE_PATHS[role_id])
		if ResourceLoader.exists(path):
			var resource = load(path)
			if resource != null:
				role_profiles[String(role_id)] = resource
	if not role_profiles.has("guard"):
		role_profiles["guard"] = _profile("guard", "guard", NpcEnumsScript.GOAL_KIND_GUARD, NpcEnumsScript.GOAL_KIND_GUARD, NpcEnumsScript.GOAL_KIND_GUARD, true, ["guard_post", "road"])
	if not role_profiles.has("farmer"):
		role_profiles["farmer"] = _profile("farmer", "forage", NpcEnumsScript.GOAL_KIND_FORAGE, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["work_anchor", "road"])
	if not role_profiles.has("carpenter"):
		role_profiles["carpenter"] = _profile("carpenter", "wood", NpcEnumsScript.GOAL_KIND_WORK, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["work_anchor", "road"])
	if not role_profiles.has("forager"):
		role_profiles["forager"] = _profile("forager", "forage", NpcEnumsScript.GOAL_KIND_FORAGE, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["work_anchor", "road"])
	if not role_profiles.has("mason"):
		role_profiles["mason"] = _profile("mason", "stone", NpcEnumsScript.GOAL_KIND_WORK, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["work_anchor", "road"])
	if not role_profiles.has("trader"):
		role_profiles["trader"] = _profile("trader", "", NpcEnumsScript.GOAL_KIND_IDLE, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["trader_stall", "road"])
	if not role_profiles.has("civilian"):
		role_profiles["civilian"] = _profile("civilian", "", NpcEnumsScript.GOAL_KIND_IDLE, NpcEnumsScript.GOAL_KIND_HOME, NpcEnumsScript.GOAL_KIND_HOME, false, ["home_interior", "road"])

func _profile(role_id: String, job: String, day_goal: StringName, dusk_goal: StringName, night_goal: StringName, guard_capable: bool, anchors: Array[String]) -> Resource:
	var profile = RoleScheduleResourceScript.new()
	profile.role_id = role_id
	profile.canonical_job = job
	profile.day_goal_kind = day_goal
	profile.dusk_goal_kind = dusk_goal
	profile.night_goal_kind = night_goal
	profile.can_take_night_guard = guard_capable
	profile.requires_interior_home = true
	profile.semantic_anchor_kinds = anchors
	return profile
