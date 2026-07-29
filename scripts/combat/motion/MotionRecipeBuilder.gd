extends RefCounted
class_name MotionRecipeBuilder

const MotionRecipeScript := preload("res://scripts/combat/motion/MotionRecipe.gd")

const PLANE_PROFILES: Array[String] = ["lateral", "rising", "falling", "overhead"]

## Builds bounded, deterministic recipe data without consuming global RNG.

static func build_side_arc(seed: int, overrides: Dictionary = {}) -> MotionRecipe:
	var parameters := {
		"reach": lerpf(2.45, 3.55, hash01(seed, "reach")),
		"arcDegrees": lerpf(106.0, 148.0, hash01(seed, "arc")),
		"startHeight": lerpf(0.72, 1.18, hash01(seed, "height")),
		"verticalLift": lerpf(0.30, 0.74, hash01(seed, "lift")),
		# Each recipe has a deterministic diagonal attack plane. The magnitude
		# intentionally never resolves to horizontal so seeded motions visibly
		# differ in their attack angle without a caller supplying an authored pose.
		"attackPlaneTiltDegrees": signed_tilt_degrees(seed),
		# Keep the existing side arc as an explicit, stable profile. New multi-plane
		# recipes use the same two generic orientation values below.
		"planeProfile": "lateral",
		"centralPitchDegrees": 0.0,
		"sweepRollDegrees": signed_tilt_degrees(seed),
		"windupFraction": lerpf(0.21, 0.29, hash01(seed, "windup")),
		"strikeFraction": lerpf(0.35, 0.44, hash01(seed, "strike")),
		"recoveryFraction": 0.0,
		"trailSamples": 15
	}
	for key in overrides:
		parameters[key] = overrides[key]
	var windup := clampf(float(parameters.get("windupFraction", 0.25)), 0.08, 0.46)
	var strike := clampf(float(parameters.get("strikeFraction", 0.40)), 0.14, 0.72)
	if windup + strike > 0.90:
		strike = 0.90 - windup
	parameters["windupFraction"] = windup
	parameters["strikeFraction"] = strike
	parameters["recoveryFraction"] = maxf(0.10, 1.0 - windup - strike)
	parameters["reach"] = clampf(float(parameters.get("reach", 3.0)), 0.25, 8.0)
	parameters["arcDegrees"] = clampf(float(parameters.get("arcDegrees", 126.0)), 18.0, 220.0)
	parameters["startHeight"] = clampf(float(parameters.get("startHeight", 0.9)), -2.0, 4.0)
	parameters["verticalLift"] = clampf(float(parameters.get("verticalLift", 0.5)), -1.0, 3.0)
	parameters["attackPlaneTiltDegrees"] = clampf(float(parameters.get("attackPlaneTiltDegrees", 0.0)), -62.0, 62.0)
	parameters["planeProfile"] = "lateral"
	parameters["centralPitchDegrees"] = clampf(float(parameters.get("centralPitchDegrees", 0.0)), -80.0, 80.0)
	parameters["sweepRollDegrees"] = clampf(float(parameters.get("sweepRollDegrees", parameters["attackPlaneTiltDegrees"])), -68.0, 68.0)
	parameters["trailSamples"] = clampi(int(parameters.get("trailSamples", 15)), 3, 48)
	return MotionRecipeScript.new("side_arc_motion", seed, parameters)


static func build_arc(seed: int, overrides: Dictionary = {}) -> MotionRecipe:
	# An arc is still the same pure mathematical primitive as a side arc. The
	# profile only chooses the plane in which that arc lives; it does not name a
	# weapon, creature, or gameplay action.
	var parameters: Dictionary = build_side_arc(seed).parameters.duplicate(true)
	var requested_profile := String(overrides.get("planeProfile", "seeded"))
	var profile := resolve_plane_profile(seed, requested_profile)
	var orientation := orientation_for_profile(seed, profile)
	parameters["planeProfile"] = profile
	parameters["centralPitchDegrees"] = float(orientation.get("centralPitchDegrees", 0.0))
	parameters["sweepRollDegrees"] = float(orientation.get("sweepRollDegrees", parameters.get("attackPlaneTiltDegrees", 0.0)))
	for key in overrides:
		parameters[key] = overrides[key]
	parameters["planeProfile"] = resolve_plane_profile(seed, String(parameters.get("planeProfile", profile)))
	parameters["centralPitchDegrees"] = clampf(float(parameters.get("centralPitchDegrees", 0.0)), -80.0, 80.0)
	parameters["sweepRollDegrees"] = clampf(float(parameters.get("sweepRollDegrees", parameters.get("attackPlaneTiltDegrees", 0.0))), -68.0, 68.0)
	# "Down" and "up" describe the visual travel of the strike rather than a
	# signed plane. Opposite limbs traverse a shared arc in opposite yaw
	# directions, so the plane roll must mirror with the side to preserve the
	# requested vertical travel for both arms. This stays entirely in recipe math:
	# a host declares intent and a rig maps the sampled side to its anatomy.
	var vertical_direction := String(parameters.get("verticalDirection", "")).strip_edges().to_lower()
	if vertical_direction in ["up", "down"]:
		var motion_side := -1.0 if float(parameters.get("motionSide", 1.0)) < 0.0 else 1.0
		var roll_magnitude := absf(float(parameters.get("sweepRollDegrees", 0.0)))
		if roll_magnitude <= 0.001:
			roll_magnitude = 42.0
		var roll_sign := motion_side if vertical_direction == "down" else -motion_side
		parameters["sweepRollDegrees"] = roll_magnitude * roll_sign
		parameters["verticalDirection"] = vertical_direction
	else:
		parameters.erase("verticalDirection")
	parameters.erase("motionSide")
	parameters["trailSamples"] = clampi(int(parameters.get("trailSamples", 15)), 3, 48)
	return MotionRecipeScript.new("arc_motion", seed, parameters)


static func build_forward_surge(seed: int, overrides: Dictionary = {}) -> MotionRecipe:
	# A forward surge is a reusable line motion. It describes the same kind of
	# pure sampled output as an arc; a caller may pair it with real locomotion,
	# but the recipe itself has no knowledge of an actor or a lunge.
	var parameters := {
		"reach": lerpf(2.85, 4.15, hash01(seed, "surge_reach")),
		"startHeight": lerpf(0.52, 0.94, hash01(seed, "surge_height")),
		"verticalLift": lerpf(0.04, 0.22, hash01(seed, "surge_lift")),
		"windupFraction": lerpf(0.23, 0.31, hash01(seed, "surge_windup")),
		"strikeFraction": lerpf(0.29, 0.38, hash01(seed, "surge_strike")),
		"trailSamples": 15
	}
	for key in overrides:
		parameters[key] = overrides[key]
	var windup := clampf(float(parameters.get("windupFraction", 0.27)), 0.08, 0.46)
	var strike := clampf(float(parameters.get("strikeFraction", 0.34)), 0.14, 0.72)
	if windup + strike > 0.90:
		strike = 0.90 - windup
	parameters["windupFraction"] = windup
	parameters["strikeFraction"] = strike
	parameters["recoveryFraction"] = maxf(0.10, 1.0 - windup - strike)
	parameters["reach"] = clampf(float(parameters.get("reach", 3.4)), 0.25, 8.0)
	parameters["startHeight"] = clampf(float(parameters.get("startHeight", 0.7)), -2.0, 4.0)
	parameters["verticalLift"] = clampf(float(parameters.get("verticalLift", 0.1)), -1.0, 3.0)
	parameters["trailSamples"] = clampi(int(parameters.get("trailSamples", 15)), 3, 48)
	return MotionRecipeScript.new("forward_surge_motion", seed, parameters)


static func resolve_plane_profile(seed: int, requested_profile: String) -> String:
	var normalized := requested_profile.strip_edges().to_lower()
	if normalized in PLANE_PROFILES:
		return normalized
	return seeded_plane_profile(seed)


static func seeded_plane_profile(seed: int) -> String:
	# Bias toward lateral/diagonal sweeps so they remain common in ordinary play,
	# while still making rising, falling, and overhead geometry reproducible from
	# a seed rather than an authored per-enemy decision.
	var selector := hash01(seed, "plane_profile")
	if selector < 0.30:
		return "lateral"
	if selector < 0.56:
		return "rising"
	if selector < 0.82:
		return "falling"
	return "overhead"


static func orientation_for_profile(seed: int, profile: String) -> Dictionary:
	match profile:
		"rising":
			return {
				# Keep the midpoint aimed through the shared forward contact corridor;
				# only the sweep plane turns upward from there. This avoids visually
				# readable arcs that can never reach a forward target capsule.
				"centralPitchDegrees": lerpf(-5.0, 5.0, hash01(seed, "plane_pitch")),
				"sweepRollDegrees": lerpf(34.0, 52.0, hash01(seed, "plane_roll"))
			}
		"falling":
			return {
				"centralPitchDegrees": lerpf(-5.0, 5.0, hash01(seed, "plane_pitch")),
				"sweepRollDegrees": -lerpf(34.0, 52.0, hash01(seed, "plane_roll"))
			}
		"overhead":
			return {
				"centralPitchDegrees": lerpf(-3.0, 3.0, hash01(seed, "plane_pitch")),
				"sweepRollDegrees": signed_range(seed, "plane_roll", 60.0, 68.0)
			}
		_:
			return {
				"centralPitchDegrees": 0.0,
				"sweepRollDegrees": signed_tilt_degrees(seed)
			}


static func hash01(seed: int, salt: String) -> float:
	var value := posmod(seed, 2147483629)
	var text := "%d:%s" % [seed, salt]
	for index in range(text.length()):
		value = posmod((value * 48271) + text.unicode_at(index) + 1, 2147483629)
	return float(value) / 2147483629.0


static func signed_tilt_degrees(seed: int) -> float:
	# Reuse two independent bounded recipe channels rather than relying on an
	# arbitrary authored angle. Keeping magnitude and sign separate produces a
	# broad, deterministic distribution across seeds.
	# A side arc stays visibly non-horizontal, but its bounded plane rotation
	# must remain legible from a first-person anchor. At the old 42 degree cap,
	# a full-reach side sweep could rise or fall by over two metres and project
	# as a screen-spanning diagonal instead of a coherent motion afterimage.
	var magnitude := lerpf(12.0, 26.0, hash01(seed, "lift"))
	return -magnitude if hash01(seed, "windup") < 0.5 else magnitude


static func signed_range(seed: int, salt: String, minimum: float, maximum: float) -> float:
	var magnitude := lerpf(minimum, maximum, hash01(seed, "%s_magnitude" % salt))
	return -magnitude if hash01(seed, "%s_sign" % salt) < 0.5 else magnitude
