extends RefCounted
class_name MotionArenaOpponentCatalog

## Narrow adapter registry for interactive motion fixtures. The arena owns only
## its playback/input/HUD; production visual and collision builders remain the
## authority for an opponent's presentation and physical contact shape.

const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const HostileBehaviorProfileCatalogScript := preload("res://scripts/combat/hostile/HostileBehaviorProfileCatalog.gd")

const DEFAULT_OPPONENT_ID := "hostile.shadow"
const HOSTILE_VARIANTS: Array[String] = ["shadow", "frost", "seer", "rift", "skitter"]


static func definition_for(opponent_id: String) -> Dictionary:
	var normalized := opponent_id.strip_edges().to_lower()
	var profile = HostileBehaviorProfileCatalogScript.profile_for(normalized)
	if profile != null:
		return {
			"id": profile.id,
			"family": "authored_hostile",
			"variant": profile.visual_variant,
			"displayName": profile.display_name,
			"motionVariant": profile.visual_variant,
			"testDamage": profile.motion_damage,
			"behaviorProfile": profile
		}
	if not normalized.begins_with("hostile."):
		normalized = DEFAULT_OPPONENT_ID
	var variant := normalized.trim_prefix("hostile.")
	if not HOSTILE_VARIANTS.has(variant):
		variant = "shadow"
	return {
		"id": "hostile.%s" % variant,
		"family": "hostile",
		"variant": variant,
		"displayName": hostile_display_name(variant),
		"motionVariant": variant,
		"testDamage": 16.0
	}


static func instantiate_opponent(definition: Dictionary) -> Dictionary:
	var family := String(definition.get("family", ""))
	if family not in ["hostile", "authored_hostile"]:
		return {}
	var variant := String(definition.get("variant", "shadow"))
	var body: Node3D = CharacterBody3D.new() if family == "authored_hostile" else StaticBody3D.new()
	body.name = "MotionArenaOpponent_%s" % variant
	var visual_factory = HostileVisualFactoryScript.new()
	var spec: Dictionary = visual_factory.build_visual(body, variant)
	# HostileMotionCombatSystem reads this production spec to keep its shared
	# contact anchor scaled to the actual opponent body.
	body.set_meta("hostile_pool_spec", spec)
	body.set_meta("kind", "hostile")
	body.set_meta("variant", variant)
	body.set_meta("arena_opponent_id", String(definition.get("id", DEFAULT_OPPONENT_ID)))
	return {
		"body": body,
		"spec": spec
	}


static func instantiate_static_opponent(definition: Dictionary) -> Dictionary:
	# Kept for focused callers that explicitly require the original stationary
	# fixture. The general arena entry point above is now the authority.
	return instantiate_opponent(definition)


static func hostile_display_name(variant: String) -> String:
	match variant:
		"wolf":
			return "Ash Wolf"
		"frost":
			return "Frost Stalker"
		"seer":
			return "Rift Seer"
		"rift":
			return "Rift Colossus"
		"skitter":
			return "Shadow Skitter"
		_:
			return "Shadow Stalker"
