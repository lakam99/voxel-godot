extends RefCounted
class_name MotionVolumeRecipeBuilder

const MotionRecipeBuilderScript := preload("res://scripts/combat/motion/MotionRecipeBuilder.gd")
const MotionVolumeRecipeScript := preload("res://scripts/combat/contact/MotionVolumeRecipe.gd")

## Bounded deterministic contact recipes. This varies only generic envelope
## dimensions; its seed is supplied by the caller and never consumes global RNG.

static func build_capsule_segment(seed: int, overrides: Dictionary = {}) -> MotionVolumeRecipe:
	var parameters := {
		"radius": lerpf(0.18, 0.31, MotionRecipeBuilderScript.hash01(seed, "volume_radius")),
		"spanStart": lerpf(0.34, 0.49, MotionRecipeBuilderScript.hash01(seed, "volume_start")),
		"spanEnd": lerpf(0.88, 1.0, MotionRecipeBuilderScript.hash01(seed, "volume_end")),
		"activePhases": ["arc"]
	}
	for key in overrides:
		parameters[key] = overrides[key]
	var span_start := clampf(float(parameters.get("spanStart", 0.40)), 0.0, 0.90)
	var span_end := clampf(float(parameters.get("spanEnd", 1.0)), span_start + 0.05, 1.0)
	parameters["spanStart"] = span_start
	parameters["spanEnd"] = span_end
	parameters["radius"] = clampf(float(parameters.get("radius", 0.24)), 0.03, 1.50)
	return MotionVolumeRecipeScript.new("capsule_segment", seed, parameters)
