extends RefCounted
class_name HostileBehaviorProfileCatalog

const HostileBehaviorProfileScript := preload("res://scripts/combat/hostile/HostileBehaviorProfile.gd")

## The first authored profile is deliberately a normal data entry. Future
## generated enemies may select or derive profiles through this same catalog.

static func profile_for(profile_id: String):
	var normalized := profile_id.strip_edges().to_lower()
	if normalized in ["wolf", "wolf.gray", "wolf_ash"]:
		return wolf_gray()
	return null


static func wolf_gray():
	return HostileBehaviorProfileScript.new({
		"id": "wolf.gray",
		"displayName": "Ash Wolf",
		"visualVariant": "wolf",
		"maxHealth": 74.0,
		"preferredDistance": 4.05,
		"engagementInnerDistance": 2.28,
		"engagementOuterDistance": 5.55,
		"clawDistance": 3.05,
		"lungeMinDistance": 3.25,
		"lungeMaxDistance": 5.45,
		"approachSpeed": 4.15,
		"orbitSpeed": 3.72,
		"retreatSpeed": 4.18,
		"lungeSpeed": 9.6,
		"evadeSpeed": 10.9,
		"orbitDuration": 1.48,
		"probeDuration": 0.44,
		"recoveryDuration": 0.88,
		"evadeDuration": 0.30,
		"evadeCooldown": 1.60,
		"evadeStaminaCost": 28.0,
		"evadeStaminaMax": 100.0,
		"evadeStaminaRegen": 23.0,
		"evadeLookaheadSeconds": 0.19,
		"motionDamage": 14.0,
		"clawPlaneProfile": "lateral",
		"motionSet": ["arc", "forward_surge"]
	})
