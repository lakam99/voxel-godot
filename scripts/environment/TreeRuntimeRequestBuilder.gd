extends RefCounted
class_name TreeRuntimeRequestBuilder

## Converts stable biome ecology into the pure request consumed by
## TreeSpawnService.  This deliberately has no asset-registry or renderer
## dependency: a natural tree's species, dimensions, and identity come from
## the world seed, stable prop ID, biome profile, and ecology sampler.

const TreeEcologySamplerScript := preload("res://scripts/environment/TreeEcologySampler.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const INVALID_TREE_CELL := Vector2i(2147483647, 2147483647)

var ecology_sampler = TreeEcologySamplerScript.new()

func build(
	profile: BiomeEnvironmentProfile,
	biome: String,
	prop_id: String,
	fallback_height := 4.0,
	world_cell := INVALID_TREE_CELL,
	world_seed := ""
) -> Dictionary:
	if profile == null:
		return {}
	var ecology := sample_ecology(profile, biome, prop_id, world_cell, world_seed)
	if ecology.is_empty():
		return {}
	var family := select_tree_family(profile, biome, prop_id, world_seed)
	var architecture := architecture_for_tree_family(family)
	if architecture == "":
		return {}
	var biome_parameters := biome_parameters_for_profile(profile, architecture)
	var scale_multiplier := float(profile.tree_scale)
	var height_min := float(biome_parameters.get("heightMin", 0.0))
	var height_max := float(biome_parameters.get("heightMax", 0.0))
	var genetics := float(ecology.get("geneticUnit", 0.5))
	var visual_height := maxf(0.1, fallback_height) * scale_multiplier
	if height_min > 0.0 and height_max >= height_min:
		visual_height = lerpf(height_min, height_max, float(ecology.get("heightGrowth", 0.5))) * lerpf(0.94, 1.06, genetics) * scale_multiplier
	var girth_growth := float(ecology.get("girthGrowth", 0.5))
	var crown_growth := float(ecology.get("crownGrowth", 0.5))
	var trunk_ratio := lerpf(0.038, 0.070, girth_growth)
	var canopy_ratio := lerpf(0.34, 0.56, crown_growth)
	if architecture == "conifer":
		trunk_ratio = lerpf(0.024, 0.034, girth_growth)
		canopy_ratio = lerpf(0.20, 0.34, crown_growth)
	elif architecture == "savanna":
		trunk_ratio = lerpf(0.038, 0.055, girth_growth)
		canopy_ratio = lerpf(0.42, 0.70, crown_growth)
	var trunk_radius := maxf(0.18, visual_height * trunk_ratio * lerpf(0.92, 1.08, genetics))
	var canopy_radius := maxf(trunk_radius * 2.2, visual_height * canopy_ratio * lerpf(0.90, 1.10, genetics))
	var trunk_min := float(biome_parameters.get("trunkRadiusMin", 0.0))
	var trunk_max := float(biome_parameters.get("trunkRadiusMax", 0.0))
	if trunk_max >= trunk_min and trunk_max > 0.0:
		trunk_radius = clampf(trunk_radius, maxf(0.18, trunk_min), trunk_max)
	var crown_min := float(biome_parameters.get("canopyRadiusMin", 0.0))
	var crown_max := float(biome_parameters.get("canopyRadiusMax", 0.0))
	if crown_max >= crown_min and crown_max > 0.0:
		canopy_radius = clampf(canopy_radius, maxf(trunk_radius * 2.2, crown_min), crown_max)
	var collision_height_fraction := 0.46
	if architecture == "conifer":
		collision_height_fraction = 0.82
	elif architecture == "savanna":
		collision_height_fraction = 0.52
	return {
		"assetId": "",
		"family": family,
		"growthClass": String(ecology.get("ageBand", "standard")),
		"architecture": architecture,
		"speciesGrammar": TreeSpawnServiceScript.grammar_for_architecture(architecture),
		"ageBand": String(ecology.get("ageBand", "standard")),
		"ageYears": float(ecology.get("ageYears", 0.0)),
		"ageRangeMin": float(ecology.get("ageRangeMin", 0.0)),
		"ageRangeMax": float(ecology.get("ageRangeMax", 0.0)),
		"localMaturity": float(ecology.get("maturity", 0.5)),
		"growthStage": float(ecology.get("growthStage", 0.5)),
		"geneticSeed": int(ecology.get("geneticSeed", 0)),
		"scale": 1.0,
		"barkScale": 1.0,
		"sourceHeight": visual_height,
		"visualHeight": visual_height,
		"trunkRadius": trunk_radius,
		"canopyRadius": canopy_radius,
		"collisionHeight": maxf(2.0, visual_height * collision_height_fraction),
		"oldGrowth": String(ecology.get("ageBand", "")) in ["old", "ancient"],
		"exclusionMargin": float(biome_parameters.get("exclusionMargin", 0.0)),
		"canopyDensity": float(biome_parameters.get("canopyDensity", 0.0)),
		"biomeParameters": biome_parameters,
	}

func sample_ecology(
	profile: BiomeEnvironmentProfile,
	biome: String,
	prop_id: String,
	world_cell := INVALID_TREE_CELL,
	world_seed := ""
) -> Dictionary:
	if profile == null or ecology_sampler == null:
		return {}
	return ecology_sampler.sample_tree(profile, biome, world_seed, prop_id, world_cell)

static func is_procedural_request(request: Dictionary) -> bool:
	return not request.is_empty() \
		and String(request.get("architecture", "")) in ["broadleaf", "conifer", "savanna"] \
		and String(request.get("speciesGrammar", "")).strip_edges() != ""

static func biome_parameters_for_profile(profile: BiomeEnvironmentProfile, architecture := "") -> Dictionary:
	if profile == null:
		return {}
	var resolved_architecture := architecture if architecture in ["broadleaf", "conifer", "savanna"] else String(profile.tree_architecture)
	return {
		"version": 1,
		"architecture": resolved_architecture,
		"heightMin": float(profile.tree_height_min),
		"heightMax": float(profile.tree_height_max),
		"trunkRadiusMin": float(profile.trunk_radius_min),
		"trunkRadiusMax": float(profile.trunk_radius_max),
		"canopyRadiusMin": float(profile.crown_radius_min),
		"canopyRadiusMax": float(profile.crown_radius_max),
		"canopyDensity": float(profile.canopy_density),
		"windResponse": float(profile.wind_response),
		"visibilityRange": float(profile.tree_visibility_range),
		"shadowRange": float(profile.tree_shadow_range),
		"exclusionMargin": float(profile.natural_prop_exclusion_margin),
	}

static func select_tree_family(profile: BiomeEnvironmentProfile, biome: String, prop_id: String, world_seed: String) -> String:
	if profile == null or profile.tree_families.is_empty():
		return ""
	var index := stable_index("tree-family:%s:%s:%s" % [world_seed, biome, prop_id], profile.tree_families.size())
	return String(profile.tree_families[index])

static func architecture_for_tree_family(family: String) -> String:
	if family.contains("conifer"):
		return "conifer"
	if family.contains("savanna"):
		return "savanna"
	if family.contains("broadleaf"):
		return "broadleaf"
	return ""

static func stable_index(text: String, modulo: int) -> int:
	if modulo <= 0:
		return 0
	return abs(stable_hash(text)) % modulo

static func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
