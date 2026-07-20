extends RefCounted
class_name MotionRecipeBuilder

const MotionRecipeScript := preload("res://scripts/combat/motion/MotionRecipe.gd")

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
	parameters["trailSamples"] = clampi(int(parameters.get("trailSamples", 15)), 3, 48)
	return MotionRecipeScript.new("side_arc_motion", seed, parameters)


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
