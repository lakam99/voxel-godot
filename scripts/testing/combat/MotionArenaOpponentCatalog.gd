extends RefCounted
class_name MotionArenaOpponentCatalog

## Narrow adapter registry for interactive motion fixtures. The arena owns only
## its playback/input/HUD; production visual and collision builders remain the
## authority for an opponent's presentation and physical contact shape.

const HostileVisualFactoryScript := preload("res://scripts/HostileVisualFactory.gd")
const HostileBehaviorProfileCatalogScript := preload("res://scripts/combat/hostile/HostileBehaviorProfileCatalog.gd")
const MotionEquipmentProfileScript := preload("res://scripts/combat/equipment/MotionEquipmentProfile.gd")
const MotionEquipmentAdapterScript := preload("res://scripts/combat/equipment/MotionEquipmentAdapter.gd")

const DEFAULT_OPPONENT_ID := "hostile.shadow"
const HOSTILE_VARIANTS: Array[String] = ["shadow", "frost", "seer", "rift", "skitter"]


static func definition_for(opponent_id: String) -> Dictionary:
	var normalized := opponent_id.strip_edges().to_lower()
	if normalized in ["rig.biped", "construct.motion", "hostile.motion_biped"]:
		return {
			"id": "rig.biped",
			"family": "rig_fixture",
			"variant": "motion_biped",
			"displayName": "Motion Construct",
			"motionVariant": "motion_biped",
			"testDamage": 16.0,
			"equipmentProfile": training_construct_sword_profile()
		}
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
	if family not in ["hostile", "authored_hostile", "rig_fixture"]:
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
	var equipment_profile = definition.get("equipmentProfile", null)
	if equipment_profile != null and body.has_meta("motion_rig_profile"):
		var rig_profile = body.get_meta("motion_rig_profile", null)
		var skeleton = body.get_node_or_null(rig_profile.skeleton_path) as Skeleton3D if rig_profile != null else null
		var adapter = MotionEquipmentAdapterScript.new()
		adapter.name = "MotionEquipmentAdapter"
		body.add_child(adapter)
		var equipment_validation: Dictionary = adapter.configure(body, skeleton, rig_profile, equipment_profile)
		body.set_meta("motion_equipment_validation", equipment_validation)
	return {
		"body": body,
		"spec": spec
	}


static func training_construct_sword_profile():
	return MotionEquipmentProfileScript.new({
		"id": "blade.training_iron.v1",
		"itemId": "ironSword",
		# The existing construct hand meshes sit at local -Y below each shoulder.
		# This attachment value is a rig fact, while the blade's own geometry stays
		# wholly item-side below.
		"socketOffset": Vector3(0.0, -0.66, 0.0),
		"itemRotation": Vector3(0.0, 0.0, PI),
		# Grip is a generated-item anchor, not a biped-specific offset. Both the
		# static asset and the procedural fallback expose this semantic node.
		"itemGripNodePath": "Grip",
		"itemGripLocal": Vector3(0.0, -0.30, 0.0),
		"contactBaseOffset": Vector3(0.0, -0.06, 0.0),
		"contactTipOffset": Vector3(0.0, -0.92, 0.0),
		"contactRadius": 0.075,
		"activePhases": ["arc"]
	})


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
		"motion_biped":
			return "Motion Construct"
		_:
			return "Shadow Stalker"
