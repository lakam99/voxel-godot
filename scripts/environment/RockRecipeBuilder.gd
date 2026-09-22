extends RefCounted
class_name RockRecipeBuilder

## Pure source recipe for natural surface rocks.  Placement, source identity,
## rendering assets, collision publication, and tombstone filtering remain with
## their respective owners.

const FULL_TURN := TAU

static func build_visual_spec(rng: RandomNumberGenerator) -> Dictionary:
	return {
		"rotation": rng.randf() * FULL_TURN,
		"radius": 0.55 + rng.randf() * 0.7,
		"height_factor": 0.75 + rng.randf() * 0.8,
		"scale": Vector3(
			1.15 + rng.randf() * 0.6,
			0.58 + rng.randf() * 0.72,
			1.0 + rng.randf() * 0.5
		)
	}
