extends RefCounted
class_name HostileBehaviorProfileCatalog

const HostileBehaviorProfileScript := preload("res://scripts/combat/hostile/HostileBehaviorProfile.gd")

## The first authored profile is deliberately a normal data entry. Future
## generated enemies may select or derive profiles through this same catalog.

static func profile_for(profile_id: String):
	var normalized := profile_id.strip_edges().to_lower()
	if normalized in ["wolf", "wolf.gray", "wolf_ash"]:
		return wolf_gray()
	if normalized in ["shadow.stalker", "shadow_stalker", "stalker.shadow"]:
		return shadow_stalker()
	if normalized in ["frost.predator", "frost_predator", "predator.frost"]:
		return frost_predator()
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
		# Quadrupeds move as a whole: their collision body and head both follow
		# measured travel instead of visually crab-walking while tracking a target.
		"facingMode": "movement",
		"gazeMode": "movement",
		"motionSet": ["arc", "forward_surge"]
	})


static func shadow_stalker():
	# Arena-only family grammar. It selects shared orbit/probe/arc/surge behavior
	# through data; there is no shadow-specific attack or motor code.
	return HostileBehaviorProfileScript.new({
		"id": "shadow.stalker",
		"displayName": "Shadow Stalker",
		"visualVariant": "shadow_stalker",
		"maxHealth": 58.0,
		"preferredDistance": 3.65,
		"engagementInnerDistance": 2.05,
		"engagementOuterDistance": 5.15,
		"clawDistance": 2.80,
		"lungeMinDistance": 3.15,
		"lungeMaxDistance": 5.00,
		"approachSpeed": 2.85,
		"orbitSpeed": 2.65,
		"retreatSpeed": 3.00,
		"lungeSpeed": 10.2,
		"evadeSpeed": 11.4,
		"orbitDuration": 1.16,
		"probeDuration": 0.34,
		"recoveryDuration": 0.76,
		"evadeDuration": 0.26,
		"evadeCooldown": 1.45,
		"evadeStaminaCost": 24.0,
		"evadeStaminaMax": 100.0,
		"evadeStaminaRegen": 26.0,
		"evadeLookaheadSeconds": 0.17,
		"motionDamage": 15.0,
		"clawPlaneProfile": "seeded",
		"facingMode": "movement",
		"gazeMode": "target",
		"motionSet": ["arc", "forward_surge"],
		# This is a data-declared combo, not a Stalker-only controller path. The
		# first left arc begins its normal wind-up while the ordinary shared motor
		# lunges; it becomes contactable only when that arc descends. Each follow-up
		# is an independently-instantiated shared downward arc whose side resolves
		# through the rig profile rather than a bespoke animation clip.
		"motionCombos": {
			"forward_surge": [
				{"motionKind": "arc", "side": -1.0, "planeProfile": "falling", "verticalDirection": "down", "locomotionKind": "lunge", "locomotionPhases": ["windup"]},
				{"motionKind": "arc", "side": 1.0, "planeProfile": "falling", "verticalDirection": "down"}
			]
		}
	})


static func frost_predator():
	# Arena-only cold-predator grammar. Its different pacing and reach are all
	# declared profile values; it still uses the shared behavior policy, motor,
	# arc recipe, semantic rig and contact pipeline.
	return HostileBehaviorProfileScript.new({
		"id": "frost.predator",
		"displayName": "Frost Predator",
		"visualVariant": "frost_predator",
		"maxHealth": 66.0,
		"preferredDistance": 4.20,
		"engagementInnerDistance": 2.35,
		"engagementOuterDistance": 5.75,
		"clawDistance": 3.05,
		"lungeMinDistance": 3.55,
		"lungeMaxDistance": 5.60,
		"approachSpeed": 3.55,
		"orbitSpeed": 3.25,
		"retreatSpeed": 4.05,
		"lungeSpeed": 8.85,
		"evadeSpeed": 9.20,
		"orbitDuration": 1.34,
		"probeDuration": 0.38,
		"recoveryDuration": 0.68,
		"evadeDuration": 0.24,
		"evadeCooldown": 1.72,
		"evadeStaminaCost": 30.0,
		"evadeStaminaMax": 100.0,
		"evadeStaminaRegen": 20.0,
		"evadeLookaheadSeconds": 0.16,
		"motionDamage": 17.0,
		"clawPlaneProfile": "falling",
		"facingMode": "movement",
		"gazeMode": "movement",
		"motionSet": ["arc", "forward_surge"],
		"motionCombos": {
			# Its paired foreclaws use two independently-instantiated downward arcs.
			# The first telegraphs and advances through the ordinary lunge intent;
			# no Frost-specific animation state or hit rule is introduced.
			"forward_surge": [
				{"motionKind": "arc", "side": -1.0, "planeProfile": "falling", "verticalDirection": "down", "locomotionKind": "lunge", "locomotionPhases": ["windup"]},
				{"motionKind": "arc", "side": 1.0, "planeProfile": "falling", "verticalDirection": "down"}
			]
		}
	})
