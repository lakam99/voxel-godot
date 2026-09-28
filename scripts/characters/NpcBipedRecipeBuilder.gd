extends RefCounted
class_name NpcBipedRecipeBuilder

## Pure, deterministic appearance data for a generated human biped.  This is
## deliberately separate from NPC simulation: a caller provides one stable
## seed and receives presentation choices only.  The PoC and a later runtime
## publisher can therefore use the exact same visual authority.

const SKIN_TONES: Array[Dictionary] = [
	{"id": "deep_umber", "color": Color("3b2118")},
	{"id": "dark_cocoa", "color": Color("563222")},
	{"id": "warm_brown", "color": Color("744732")},
	{"id": "sienna", "color": Color("925d42")},
	{"id": "golden_tan", "color": Color("b97957")},
	{"id": "warm_beige", "color": Color("d59c78")},
	{"id": "light_rose", "color": Color("e6b998")},
	{"id": "pale_flesh", "color": Color("f2d0b5")}
]

const HAIR_COLORS: Array[Dictionary] = [
	{"id": "black", "color": Color("17151a")},
	{"id": "espresso", "color": Color("2f1b18")},
	{"id": "chestnut", "color": Color("623720")},
	{"id": "copper", "color": Color("9f542d")},
	{"id": "golden_blond", "color": Color("c99a4d")},
	{"id": "silver", "color": Color("b9b2ac")}
]

const CLOTH_PALETTES: Array[Dictionary] = [
	{"id": "moss", "primary": Color("466d4c"), "secondary": Color("c49a55")},
	{"id": "indigo", "primary": Color("455a88"), "secondary": Color("d4b36b")},
	{"id": "russet", "primary": Color("8d4935"), "secondary": Color("edbd70")},
	{"id": "plum", "primary": Color("674767"), "secondary": Color("d7a2b8")},
	{"id": "ochre", "primary": Color("9a7238"), "secondary": Color("5d4630")},
	{"id": "slate", "primary": Color("3d6270"), "secondary": Color("d8d0ab")},
	{"id": "rose", "primary": Color("9a5268"), "secondary": Color("f0c5a1")}
]

const OUTFIT_DESIGNS: Array[String] = ["tunic", "doublet", "traveller_wrap", "layered_vest"]
const HAIR_STYLES: Array[String] = ["bald", "receding", "long", "cropped"]
const EYE_COLORS: Array[Dictionary] = [
	{"id": "brown", "color": Color("281a18")},
	{"id": "hazel", "color": Color("645027")},
	{"id": "green", "color": Color("3f6655")},
	{"id": "blue", "color": Color("466b8b")}
]


static func build(seed: int, profile_id := "") -> Dictionary:
	var rng := RandomNumberGenerator.new()
	# Seed each recipe in isolation.  Appearance must not vary with the order in
	# which an NPC list happens to be iterated.
	rng.seed = normalized_seed(seed, profile_id)
	var skin: Dictionary = SKIN_TONES[rng.randi_range(0, SKIN_TONES.size() - 1)] as Dictionary
	var hair: Dictionary = HAIR_COLORS[rng.randi_range(0, HAIR_COLORS.size() - 1)] as Dictionary
	var cloth: Dictionary = CLOTH_PALETTES[rng.randi_range(0, CLOTH_PALETTES.size() - 1)] as Dictionary
	var eye: Dictionary = EYE_COLORS[rng.randi_range(0, EYE_COLORS.size() - 1)] as Dictionary
	var outfit_design := String(OUTFIT_DESIGNS[rng.randi_range(0, OUTFIT_DESIGNS.size() - 1)])
	var hair_style := String(HAIR_STYLES[rng.randi_range(0, HAIR_STYLES.size() - 1)])
	var stature := lerpf(0.92, 1.10, rng.randf())
	var shoulder_scale := lerpf(0.93, 1.08, rng.randf())
	var blink_interval := lerpf(2.45, 4.55, rng.randf())
	var blink_phase := rng.randf() * blink_interval
	return {
		"schema": "npc_biped_recipe_v1",
		"seed": seed,
		"profileId": profile_id,
		"stature": stature,
		"shoulderScale": shoulder_scale,
		"skin": skin.duplicate(true),
		"hair": {
			"style": hair_style,
			"colorId": String(hair.get("id", "black")),
			"color": hair.get("color", Color("17151a")) as Color
		},
		"outfit": {
			"design": outfit_design,
			"paletteId": String(cloth.get("id", "moss")),
			"primary": cloth.get("primary", Color("466d4c")) as Color,
			"secondary": cloth.get("secondary", Color("c49a55")) as Color
		},
		"eyes": {
			"colorId": String(eye.get("id", "brown")),
			"color": eye.get("color", Color("281a18")) as Color,
			"blinkInterval": blink_interval,
			"blinkPhase": blink_phase
		}
	}


static func normalized_seed(seed: int, profile_id: String) -> int:
	var mixed := int(seed) ^ stable_hash(profile_id)
	# RandomNumberGenerator accepts the full signed range, but avoiding zero
	# makes a default/unset seed visibly distinct from a deliberately empty id.
	return mixed if mixed != 0 else 1


static func stable_hash(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0x7fffffff
	return value


static func signature(recipe: Dictionary) -> String:
	var skin: Dictionary = recipe.get("skin", {}) as Dictionary
	var hair: Dictionary = recipe.get("hair", {}) as Dictionary
	var outfit: Dictionary = recipe.get("outfit", {}) as Dictionary
	var eyes: Dictionary = recipe.get("eyes", {}) as Dictionary
	return "%s|%d|%.4f|%.4f|%s|%s|%s|%s|%s" % [
		String(recipe.get("schema", "")),
		int(recipe.get("seed", 0)),
		float(recipe.get("stature", 1.0)),
		float(recipe.get("shoulderScale", 1.0)),
		String(skin.get("id", "")),
		String(hair.get("style", "")),
		String(hair.get("colorId", "")),
		String(outfit.get("design", "")),
		String(eyes.get("colorId", ""))
	]
