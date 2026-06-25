extends RefCounted
class_name TraversalCapabilityService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

func span_supported(profile, span) -> bool:
	if span == null:
		return false
	if span.has_method("supports_profile"):
		return span.supports_profile(profile)
	return bool(span.get("walkable", false))

func edge_supported(profile, edge) -> bool:
	if edge == null:
		return false
	for capability in edge.get("required_capabilities"):
		if not profile_can(profile, capability):
			return false
	return true

func profile_can(profile, capability) -> bool:
	if profile == null:
		return true
	if profile.has_method("can"):
		return bool(profile.call("can", StringName(String(capability))))
	var abilities = profile.get("abilities")
	if abilities is Dictionary:
		return bool((abilities as Dictionary).get(StringName(String(capability)), false))
	return true

func profile_class(profile) -> String:
	if profile == null:
		return "default"
	var summary: Dictionary = profile.to_summary() if profile.has_method("to_summary") else {}
	return "%s:r%.2f:h%.2f:step%.2f:drop%.2f" % [
		String(summary.get("profileId", profile.get("profile_id") if profile != null else "default")),
		float(summary.get("radius", NpcConstantsScript.DEFAULT_NPC_RADIUS)),
		float(summary.get("standingHeight", NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT)),
		float(summary.get("stepUp", NpcConstantsScript.DEFAULT_NPC_STEP_UP)),
		float(summary.get("safeDrop", NpcConstantsScript.DEFAULT_NPC_SAFE_DROP))
	]
