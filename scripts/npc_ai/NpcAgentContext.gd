extends RefCounted
class_name NpcAgentContext

const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var stable_id := ""
var display_name := ""
var role := ""
var schedule_profile := "default"
var traversal_profile
var home_cell := Vector2i.ZERO
var porch_cell := Vector2i.ZERO
var guard_cell := Vector2i.ZERO
var job := ""
var settlement_id := ""
var faction_id := "settlement"
var can_fight := false
var guard_duty_kind: StringName = NpcEnumsScript.GUARD_DUTY_NONE
var body_ref: WeakRef
var inventory_adapter = null
var needs_adapter = null
var rng_stream_seeds := {}

static func from_profile(body: Node, profile: Dictionary):
	var context = load("res://scripts/npc_ai/NpcAgentContext.gd").new()
	context.configure_from_profile(body, profile)
	return context

static func stable_hash(text: String) -> int:
	var value := 2166136261
	for i in range(text.length()):
		value = int((value ^ text.unicode_at(i)) * 16777619) & 0x7fffffff
	return value

static func stable_order_key(value) -> String:
	if value is NpcAgentContext:
		return (value as NpcAgentContext).stable_id
	if value is Dictionary:
		return String(value.get("stableId", value.get("id", "")))
	return String(value)

static func stable_sort_ids(values: Array) -> Array:
	var result := []
	for value in values:
		result.append(stable_order_key(value))
	result.sort()
	return result

func configure_from_profile(body: Node, profile: Dictionary) -> void:
	var fallback_id := String(body.name) if body != null else "npc"
	stable_id = String(profile.get("id", fallback_id))
	display_name = String(profile.get("name", fallback_id))
	role = String(profile.get("role", "Villager"))
	home_cell = profile.get("homeCell", profile.get("cell", Vector2i.ZERO))
	porch_cell = profile.get("porchCell", home_cell)
	guard_cell = profile.get("guardCell", porch_cell)
	job = String(profile.get("job", ""))
	settlement_id = String(profile.get("townKey", ""))
	can_fight = bool(profile.get("canFight", false))
	guard_duty_kind = NpcEnumsScript.GUARD_DUTY_NIGHT if bool(profile.get("nightGuard", false)) else NpcEnumsScript.GUARD_DUTY_NONE
	traversal_profile = TraversalProfileScript.from_profile(profile, can_fight)
	body_ref = weakref(body) if body != null else null

func body() -> Node:
	return body_ref.get_ref() if body_ref != null else null

func rng_seed(world_seed: String, domain: String, phase: String) -> int:
	var key := "%s|%s" % [domain, phase]
	if not rng_stream_seeds.has(key):
		rng_stream_seeds[key] = stable_hash("%s|%s|%s|%s" % [world_seed, stable_id, domain, phase])
	return int(rng_stream_seeds[key])

func rng_stream(world_seed: String, domain: String, phase: String) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed(world_seed, domain, phase)
	return rng

func to_summary() -> Dictionary:
	return {
		"stableId": stable_id,
		"name": display_name,
		"role": role,
		"job": job,
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"guardCell": guard_cell,
		"settlementId": settlement_id,
		"canFight": can_fight,
		"guardDuty": String(guard_duty_kind),
		"traversalProfile": traversal_profile.to_summary() if traversal_profile != null else {}
	}
