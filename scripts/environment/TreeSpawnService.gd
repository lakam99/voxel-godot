extends RefCounted
class_name TreeSpawnService

## The one public entry point for mathematical trees.  A caller supplies only
## deterministic ecological inputs; this service owns grammar selection,
## recipe identity, bounded render reduction and visual instantiation.

const RECIPE_VERSION := 10
const ConiferGrammar := preload("res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd")
const SavannaGrammar := preload("res://scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd")
const BushyOakGrammar := preload("res://scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd")
const VisualFactory := preload("res://scripts/visual/ProceduralTreeVisualFactory.gd")
const TreeRequestAdmissionScript := preload("res://scripts/environment/TreeRequestAdmission.gd")

# One publication is intentionally allowed per frame.  These caps keep that
# work below the visible-hitch threshold while each foliage anchor still
# carries a compact multi-leaf cluster rather than a single card.
# These are bounded branch/cluster anchors, not individual leaf cards. The
# publication queue assembles them across frames, so retain the density needed
# for a credible mature canopy rather than severing visible structure to chase
# a one-shot construction time.
# These are near-detail ceilings, not authored species counts. The request's
# age-derived canopy density and LOD tier select a deterministic fraction of
# them. A 180/260 ceiling was too low for a mature oak's allometric support
# graph: it reduced a valid crown to sparse candelabra limbs even though the
# same grammar was dense in the review fixture. The queue still publishes the
# result in 16-instance foliage slices, while mid/far/impostor tiers scale down
# through LOD_BUDGET_SCALE before any renderer work is scheduled.
const RUNTIME_BRANCH_BUDGET := 420
const RUNTIME_FOLIAGE_BUDGET := 620
const CACHE_CAPACITY := 192
const LOD_TIERS := ["near", "mid", "far", "impostor"]
const LOD_BUDGET_SCALE := {"near": 1.0, "mid": 0.52, "far": 0.23, "impostor": 0.0}

# Geometry and shader materials are immutable once prepared, so main-thread
# publishers share one visual factory. Recipe workers never materialize it:
# they own pure data construction only, avoiding renderer allocation or resource
# initialization on a background worker before any visual work is required.
static var shared_visual_factory
var visual_factory
var recipe_cache := {}
var cache_access := {}
var access_tick := 0
var cache_hits := 0

func spawn_tree(request: Dictionary) -> Node3D:
	var recipe := build_recipe(request)
	if recipe.is_empty():
		return null
	return instantiate_recipe(recipe, String(request.get("biome", "forest")), String(request.get("treeId", "procedural-tree")))

func instantiate_recipe(recipe: Dictionary, biome: String, tree_id: String) -> Node3D:
	if recipe.is_empty():
		return null
	return get_visual_factory().instantiate_recipe(recipe, biome, tree_id)

func prewarm_visuals() -> void:
	get_visual_factory().prewarm_runtime_resources()

func get_visual_factory():
	if visual_factory != null:
		return visual_factory
	if shared_visual_factory == null:
		shared_visual_factory = VisualFactory.new()
	visual_factory = shared_visual_factory
	return visual_factory

func build_recipe(request: Dictionary) -> Dictionary:
	var normalized := normalize_request(request)
	if normalized.is_empty():
		return {}
	var key := request_key(normalized)
	var canonical: Dictionary = recipe_cache.get(key, {})
	if canonical.is_empty():
		canonical = build_canonical_recipe(normalized)
		if canonical.is_empty():
			return {}
		store_recipe(key, canonical)
	else:
		cache_hits += 1
	touch(key)
	return render_recipe(canonical, normalized)

func build_recipe_for_worker(request: Dictionary) -> Dictionary:
	# A publication worker builds one immutable recipe, then returns its reduced
	# render form to the queue-owned bounded cache. Keeping this service's private
	# canonical cache alive until the staged visual commits retained a full grammar
	# graph on the main thread and made task retirement an avoidable publication
	# tail. Build and release the canonical graph wholly on the worker instead.
	var normalized := normalize_request(request)
	if normalized.is_empty():
		return {}
	var canonical := build_canonical_recipe(normalized)
	if canonical.is_empty():
		return {}
	return render_recipe(canonical, normalized)

func recipe_cache_key(request: Dictionary) -> String:
	var normalized := normalize_request(request)
	return recipe_cache_key_from_normalized(normalized)

func recipe_cache_key_from_normalized(normalized: Dictionary) -> String:
	return request_key(normalized) if not normalized.is_empty() else ""

func recipe_identity_key(request: Dictionary) -> String:
	var normalized := normalize_request(request)
	return recipe_identity_key_from_normalized(normalized) if not normalized.is_empty() else ""

func derive_recipe_for_lod(source_recipe: Dictionary, request: Dictionary) -> Dictionary:
	# Publication owns the bounded source cache; this service only derives a
	# smaller render graph from an immutable higher-detail recipe.  The work stays
	# on the recipe worker so cache reuse cannot introduce a main-thread copy or
	# reduction hitch while the player moves away from a tree.
	var normalized := normalize_request(request)
	if normalized.is_empty() or source_recipe.is_empty():
		return {}
	var source_tier := normalize_lod_tier(String((source_recipe.get("renderLod", {}) as Dictionary).get("tier", "")))
	var requested_tier := normalize_lod_tier(String(normalized.get("renderLodTier", "near")))
	if lod_detail_rank(source_tier) < lod_detail_rank(requested_tier):
		# A cache record must never manufacture visual detail it does not contain.
		# This defensive fallback retains the normal canonical build contract if a
		# caller hands the method an unsuitable source.
		return build_recipe_for_worker(normalized)
	var recipe := render_recipe(source_recipe, normalized)
	if recipe.is_empty():
		return {}
	recipe["runtimeLodSourceTier"] = source_tier
	recipe["runtimeLodDerived"] = true
	recipe["runtimeRecipePassCount"] = int(source_recipe.get("runtimeRecipePassCount", 1)) + 1
	recipe["signature"] = runtime_recipe_signature(recipe, normalized)
	return recipe

func lod_policy_for_request(request: Dictionary) -> Dictionary:
	var normalized := normalize_request(request)
	return lod_policy_for_normalized_request(normalized)

func lod_policy_for_normalized_request(normalized: Dictionary) -> Dictionary:
	if normalized.is_empty():
		return {}
	var visibility_range := maxf(32.0, float((normalized.get("biomeParameters", {}) as Dictionary).get("visibilityRange", 440.0)))
	# The range bands are proportional to the biome's configured visibility
	# budget. They are not a stand planner: they only choose how much of an
	# already deterministic individual tree needs rendering at this distance.
	return {
		"near": maxf(48.0, visibility_range * 0.18),
		"mid": maxf(96.0, visibility_range * 0.46),
		"far": maxf(160.0, visibility_range * 0.78),
		"impostor": visibility_range,
		"hysteresis": 0.12
	}

func lod_tier_for_distance(request: Dictionary, distance: float, current_tier := "") -> String:
	var policy := lod_policy_for_request(request)
	return lod_tier_for_distance_with_policy(policy, distance, current_tier)

func lod_tier_for_distance_normalized(normalized: Dictionary, distance: float, current_tier := "") -> String:
	return lod_tier_for_distance_with_policy(
		lod_policy_for_normalized_request(normalized), distance, current_tier)

func lod_tier_for_distance_with_policy(policy: Dictionary, distance: float, current_tier := "") -> String:
	if policy.is_empty():
		return "near"
	var normalized_current := normalize_lod_tier(current_tier)
	var hysteresis := float(policy.get("hysteresis", 0.12))
	var near_limit := float(policy.get("near", 56.0))
	var mid_limit := float(policy.get("mid", 144.0))
	var far_limit := float(policy.get("far", 260.0))
	# Preserve an existing tier inside a small dead band. This avoids visual
	# rebuild thrash while a player is standing close to a boundary.
	if normalized_current == "near" and distance <= near_limit * (1.0 + hysteresis):
		return "near"
	if normalized_current == "mid" and distance >= near_limit * (1.0 - hysteresis) and distance <= mid_limit * (1.0 + hysteresis):
		return "mid"
	if normalized_current == "far" and distance >= mid_limit * (1.0 - hysteresis) and distance <= far_limit * (1.0 + hysteresis):
		return "far"
	if normalized_current == "impostor" and distance >= far_limit * (1.0 - hysteresis):
		return "impostor"
	if distance <= near_limit:
		return "near"
	if distance <= mid_limit:
		return "mid"
	if distance <= far_limit:
		return "far"
	return "impostor"

func cache_metrics() -> Dictionary:
	return {
		"recipeCacheEntries": recipe_cache.size(),
		"recipeCacheCapacity": CACHE_CAPACITY,
		"recipeCacheHits": cache_hits
	}

func normalize_request(request: Dictionary) -> Dictionary:
	var presentation := String(request.get("presentation", "runtime"))
	var admission: Dictionary = {}
	if presentation != "review":
		admission = TreeRequestAdmissionScript.validate_request(request)
		if String(admission.get("status", "")) != "ready":
			return {}
	var tree_id := String(request.get("treeId", "")).strip_edges()
	var world_seed := String(request.get("worldSeed", "")).strip_edges()
	var biome := String(request.get("biome", "forest")).strip_edges().to_lower()
	if tree_id == "":
		return {}
	if world_seed == "":
		world_seed = "default"
	var biome_parameters := normalize_biome_parameters(request.get("biomeParameters", {}), biome)
	var architecture := String(request.get("architecture", biome_parameters.get("architecture", "broadleaf"))).strip_edges().to_lower()
	if architecture not in ["broadleaf", "conifer", "savanna"]:
		architecture = "broadleaf"
	var grammar := String(request.get("speciesGrammar", "")).strip_edges().to_lower()
	# Rounded broadleaf was an early PoC-only scaffold.  Retire its request name
	# at the service boundary so legacy saved requests and direct callers join the
	# production oak family instead of quietly reviving a parallel tree model.
	if grammar == "rounded_broadleaf":
		grammar = "bushy_oak"
	if grammar == "":
		grammar = default_grammar(architecture, biome, tree_id, world_seed)
	var maturity := clampf(float(request.get("growthStage", request.get("maturity", 0.58))), 0.12, 1.0)
	var target_height := maxf(4.0, float(request.get("visualHeight", 20.0)))
	var target_trunk_radius := maxf(0.18, float(request.get("trunkRadius", target_height * 0.04)))
	var target_canopy_radius := maxf(target_trunk_radius * 2.2, float(request.get("canopyRadius", target_height * 0.34)))
	var supplied_genetic_seed := int(request.get("geneticSeed", 0))
	var local_genetic_seed := stable_hash("tree-local:%s:%s:%s:%s:%s:v%d" % [world_seed, tree_id, biome, architecture, grammar, RECIPE_VERSION])
	var canopy_density := clampf(float(request.get("canopyDensity", biome_parameters.get("canopyDensity", 0.78))), 0.20, 1.0)
	return {
		"treeId": tree_id,
		"worldSeed": world_seed,
		"biome": biome,
		"architecture": architecture,
		"speciesGrammar": grammar,
		"maturity": maturity,
		"visualHeight": target_height,
		"trunkRadius": target_trunk_radius,
		"canopyRadius": target_canopy_radius,
		"ageBand": String(request.get("ageBand", "mature")),
		"ageYears": float(request.get("ageYears", 0.0)),
		"canopyDensity": canopy_density,
		"renderLodTier": normalize_lod_tier(String(request.get("renderLodTier", "near"))),
		"biomeParameters": biome_parameters,
		"presentation": presentation,
		"treeAdmissionCertificate": admission.get("certificate", {}).duplicate(true) if admission.get("certificate", {}) is Dictionary else {},
		"treeProducerCatalogRevision": String(admission.get("profileCatalogRevision", "")),
		"treeProducerEnvelopeDigest": String(admission.get("requestEnvelopeDigest", "")),
		"worldPosition": request.get("worldPosition", Vector3.ZERO) as Vector3,
		"worldRotationY": float(request.get("worldRotationY", 0.0)),
		# The ecological sampler's seed is a required genetic channel. Use a
		# tree-local fallback only for review/direct-service callers that do not
		# supply one; neither option touches shared world-generation RNG.
		"geneticSeed": supplied_genetic_seed if supplied_genetic_seed != 0 else local_genetic_seed
	}

func normalize_biome_parameters(source: Variant, biome: String) -> Dictionary:
	var raw: Dictionary = source.duplicate(true) if source is Dictionary else {}
	return {
		"version": maxi(1, int(raw.get("version", 1))),
		"biome": biome,
		"architecture": String(raw.get("architecture", "")).strip_edges().to_lower(),
		"heightMin": maxf(0.0, float(raw.get("heightMin", 0.0))),
		"heightMax": maxf(0.0, float(raw.get("heightMax", 0.0))),
		"trunkRadiusMin": maxf(0.0, float(raw.get("trunkRadiusMin", 0.0))),
		"trunkRadiusMax": maxf(0.0, float(raw.get("trunkRadiusMax", 0.0))),
		"canopyRadiusMin": maxf(0.0, float(raw.get("canopyRadiusMin", 0.0))),
		"canopyRadiusMax": maxf(0.0, float(raw.get("canopyRadiusMax", 0.0))),
		"canopyDensity": clampf(float(raw.get("canopyDensity", 0.78)), 0.20, 1.0),
		"windResponse": clampf(float(raw.get("windResponse", 1.0)), 0.0, 2.0),
		"visibilityRange": maxf(32.0, float(raw.get("visibilityRange", 440.0))),
		"shadowRange": maxf(16.0, float(raw.get("shadowRange", 220.0))),
		"exclusionMargin": maxf(0.0, float(raw.get("exclusionMargin", 0.0))),
	}

func default_grammar(architecture: String, biome: String, tree_id: String, world_seed: String) -> String:
	return grammar_for_architecture(architecture)

static func grammar_for_architecture(architecture: String) -> String:
	if architecture == "conifer":
		return "norway_spruce"
	if architecture == "savanna":
		return "umbrella_thorn"
	# The current broadleaf family is the allometric oak grammar. It remains
	# genetically varied by its stable tree seed, age and biome parameters; it is
	# not an authored tree template. The former rounded grammar's branch scaffold
	# produced sparse candelabra canopies in live world captures, so it must not
	# silently re-enter production through direct service callers.
	return "bushy_oak"

func build_canonical_recipe(request: Dictionary) -> Dictionary:
	if normalize_lod_tier(String(request.get("renderLodTier", "near"))) == "impostor":
		# An impostor has no structural branch or foliage anchors to publish.
		# Avoid invoking a grammar merely to discard its whole graph in
		# render_recipe; the deterministic request remains its visual identity.
		return adapt_grammar_recipe({
			"signature": "impostor:%s:%s:%s" % [request.get("worldSeed", ""), request.get("treeId", ""), request.get("speciesGrammar", "")],
			"height": 1.0,
			"trunkRadius": 1.0,
			"canopyRadius": 1.0,
			"architecture": String(request.get("architecture", "broadleaf")),
			"speciesGrammar": String(request.get("speciesGrammar", "bushy_oak")),
			"crownHabit": "distance_impostor",
			"branches": [],
			"foliage": []
		}, request)
	var grammar = grammar_for(String(request.get("speciesGrammar", "")))
	if grammar == null:
		return {}
	var is_review := String(request.get("presentation", "runtime")) == "review"
	var profile := {} if is_review else runtime_growth_profile(request)
	var raw: Dictionary = grammar.build_recipe(int(request.get("geneticSeed", 0)), float(request.get("maturity", 0.58)), profile)
	if raw.is_empty():
		return {}
	# Runtime publication has fixed graph/foliage budgets.  Select the supported
	# subset while it is still source-space data, before coordinate adaptation
	# deep-copies every discarded dictionary for renderer consumption.  The exact
	# same graph-preserving reducer is applied by render_recipe below, making this
	# a memory/worker-transfer optimization rather than a second tree model.
	# Review requests intentionally retain the complete grammar for PoC scrutiny.
	if not is_review:
		raw = reduce_raw_runtime_recipe(raw, request)
	return adapt_grammar_recipe(raw, request)

func reduce_raw_runtime_recipe(raw: Dictionary, request: Dictionary) -> Dictionary:
	# Do graph selection before adapting coordinates and duplicating every source
	# dictionary.  This preserves the exact topology-aware reducer used by the
	# renderer, but prevents a 1,000+ segment conifer/savanna source recipe from
	# being scaled, deep-copied and then discarded on every unique tree request.
	var reduced := raw.duplicate(false)
	var source_branches: Array = raw.get("branches", [])
	var source_foliage: Array = raw.get("foliage", [])
	var budgets := runtime_render_budgets(request)
	reduced["sourceBranchCount"] = source_branches.size()
	reduced["sourceFoliageClusterCount"] = source_foliage.size()
	reduced["branches"] = graph_preserving_reduce(source_branches, int(budgets.get("branchBudget", RUNTIME_BRANCH_BUDGET)))
	# Retain at least one cluster on each represented supporting axis before
	# spending the remaining budget on finer exposed wood. An even whole-array
	# sample reintroduced the sparse "pom-pom" failure after the grammar had
	# already distributed leaf sites over the complete branch topology.
	reduced["foliage"] = support_aware_foliage_reduce(source_foliage, int(budgets.get("foliageBudget", RUNTIME_FOLIAGE_BUDGET)))
	return reduced

func runtime_growth_profile(request: Dictionary) -> Dictionary:
	var density := float(request.get("canopyDensity", 0.78))
	var architecture := String(request.get("architecture", "broadleaf"))
	var grammar := String(request.get("speciesGrammar", "bushy_oak"))
	var lod_scale := float(LOD_BUDGET_SCALE.get(normalize_lod_tier(String(request.get("renderLodTier", "near"))), 1.0))
	var maturity := clampf(float(request.get("maturity", 0.58)), 0.12, 1.0)
	if lod_scale <= 0.0:
		return {"branchSegmentBudget": 1, "foliageClusterBudget": 1, "spaceColonizationIterationBudget": 1}
	if architecture == "conifer":
		return {"branchSegmentBudget": maxi(48, roundi(260.0 * lod_scale)), "foliageClusterBudget": maxi(52, roundi(320.0 * lod_scale))}
	if architecture == "savanna":
		return {"branchSegmentBudget": maxi(48, roundi(250.0 * lod_scale)), "foliageClusterBudget": maxi(52, roundi(320.0 * lod_scale))}
	if grammar == "bushy_oak":
		# Developmental seasons are an allometric time budget, not authored crown
		# layers. An old near oak needs the same repeated local resource competition
		# that produces its PoC's twig-rich dome. Mid/far render tiers receive fewer
		# seasons before queue publication so distant trees remain bounded.
		var mature_season_capacity := clampi(roundi(lerpf(2.0, 4.0, maturity)), 2, 4)
		# Simulation detail may decline faster than visible-instance detail. A mid
		# tree still receives the same grammar and support-aware reduction, but it
		# does not spend multiple full developmental seasons producing fine wood that
		# the LOD cap must immediately remove. Near trees preserve every mature
		# season; this is an LOD budget, not a second authored oak model.
		var simulation_lod_scale := pow(lod_scale, 1.35)
		var lod_scaled_seasons := maxi(1, floori(float(mature_season_capacity) * simulation_lod_scale))
		# A graph-preserving reduction retains a selected axis' entire support path.
		# Its source therefore needs more candidates than the final renderer budget;
		# otherwise it spends all of that budget on ancestry and leaves no fine crown
		# wood. Derive the worker headroom from maturity and the already density/LOD
		# selected render cap—never from a hand-authored branch count.
		var render_budgets := runtime_render_budgets(request)
		var branch_target := int(render_budgets.get("branchBudget", RUNTIME_BRANCH_BUDGET))
		var foliage_target := int(render_budgets.get("foliageBudget", RUNTIME_FOLIAGE_BUDGET))
		# Preserve enough source-space ancestry for a graph-safe reduction, but do
		# not ask an asynchronous worker to cultivate a second invisible tree. The
		# spatial oak grammar grows until this allometric headroom is spent; the
		# renderer receives the same deterministic support-aware reduction.
		var topology_headroom := lerpf(1.24, 1.60, maturity)
		# A graph reducer needs source-space headroom to retain support paths, but a
		# distant tree needs less invisible ancestry than a close inspection tree.
		# Smoothly scale that headroom with LOD instead of using a species count.
		topology_headroom *= lerpf(0.72, 1.0, lod_scale)
		var branch_source_budget := clampi(ceili(float(branch_target) * topology_headroom), 144, 720)
		var foliage_source_budget := clampi(ceili(float(foliage_target) * lerpf(1.08, 1.42, maturity) * lerpf(0.82, 1.0, lod_scale)), 176, 960)
		var attraction_density := lerpf(0.62, 1.0, maturity)
		var attraction_budget := clampi(
			ceili(float(branch_source_budget) * maxf(0.45, attraction_density * pow(lod_scale, 0.90))),
			96,
			700
		)
		var colonization_iterations := clampi(
			roundi(lerpf(8.0, 18.0, maturity) * pow(lod_scale, 1.40)),
			4,
			18
		)
		return {
			"attractionPointCount": attraction_budget,
			"branchSegmentBudget": branch_source_budget,
			"foliageClusterBudget": foliage_source_budget,
			"spaceColonizationIterationBudget": colonization_iterations,
			"derivedAxisMaximumGrowthSeasons": lod_scaled_seasons
		}
	return {
		# Runtime and review use the same space-colonisation/pipe model.  The
		# difference is sample density only: retain just enough overdraw for the
		# graph-preserving reducer to choose a supported, full crown, instead of
		# constructing a 760-segment graph and immediately discarding 75% of it.
		"attractionPointCount": maxi(96, roundi(clampf(lerpf(324.0, 380.0, density), 312.0, 392.0) * lod_scale)),
		"branchSegmentBudget": maxi(120, roundi(clampf(lerpf(588.0, 664.0, density), 568.0, 680.0) * lod_scale)),
		"foliageClusterBudget": maxi(140, roundi(clampf(lerpf(724.0, 812.0, density), 700.0, 832.0) * lod_scale)),
		"spaceColonizationIterationBudget": maxi(5, roundi(15.0 * lod_scale))
	}

func grammar_for(grammar: String):
	match grammar:
		"norway_spruce": return ConiferGrammar.new()
		"umbrella_thorn": return SavannaGrammar.new()
		"bushy_oak": return BushyOakGrammar.new()
		# Requests are normalized above; retain an oak fallback for malformed
		# external callers rather than retaining the retired rounded grammar.
		_: return BushyOakGrammar.new()

func adapt_grammar_recipe(raw: Dictionary, request: Dictionary) -> Dictionary:
	var source_height := maxf(0.01, float(raw.get("height", 1.0)))
	var source_radius := maxf(0.01, float(raw.get("trunkRadius", 0.1)))
	var source_canopy := maxf(0.01, float(raw.get("canopyRadius", 1.0)))
	var vertical_scale := float(request.get("visualHeight", source_height)) / source_height
	var radius_scale := float(request.get("trunkRadius", source_radius)) / source_radius
	var horizontal_scale := float(request.get("canopyRadius", source_canopy)) / source_canopy
	# Deep-copy the source graph once so nested recipe metadata stays detached,
	# then transform its already-owned branch and foliage dictionaries in place.
	# Previously each element was deep-copied here and the full raw graph was
	# deep-copied again below before those arrays were immediately replaced.
	var recipe: Dictionary = raw.duplicate(true)
	var branches: Array[Dictionary] = []
	var raw_branches: Array = recipe.get("branches", [])
	for source_value in raw_branches:
		if not (source_value is Dictionary):
			continue
		var branch: Dictionary = source_value
		branch["start"] = scale_position(branch.get("start", Vector3.ZERO), horizontal_scale, vertical_scale)
		branch["end"] = scale_position(branch.get("end", Vector3.UP), horizontal_scale, vertical_scale)
		branch["radiusStart"] = maxf(0.018, float(branch.get("radiusStart", 0.04)) * radius_scale)
		branch["radiusEnd"] = maxf(0.012, float(branch.get("radiusEnd", 0.02)) * radius_scale)
		var wind_response := float((request.get("biomeParameters", {}) as Dictionary).get("windResponse", 1.0))
		branch["windWeight"] = clampf(maxf((branch["start"] as Vector3).y, (branch["end"] as Vector3).y) / maxf(1.0, float(request.get("visualHeight", 1.0))) * wind_response, 0.0, 1.0)
		branches.append(branch)
	var foliage: Array[Dictionary] = []
	for source_value in recipe.get("foliage", []):
		if not (source_value is Dictionary):
			continue
		var anchor: Dictionary = source_value
		anchor["position"] = scale_position(anchor.get("position", Vector3.ZERO), horizontal_scale, vertical_scale)
		var source_scale: Vector3 = anchor.get("scale", Vector3.ONE)
		anchor["scale"] = Vector3(source_scale.x * horizontal_scale, source_scale.y * vertical_scale, source_scale.z * horizontal_scale)
		var foliage_wind_response := float((request.get("biomeParameters", {}) as Dictionary).get("windResponse", 1.0))
		anchor["windWeight"] = clampf((anchor["position"] as Vector3).y / maxf(1.0, float(request.get("visualHeight", 1.0))) * foliage_wind_response, 0.20, 1.0)
		foliage.append(anchor)
	recipe["version"] = RECIPE_VERSION
	recipe["treeId"] = String(request.get("treeId", ""))
	recipe["biome"] = String(request.get("biome", "forest"))
	recipe["architecture"] = String(request.get("architecture", raw.get("architecture", "broadleaf")))
	recipe["speciesGrammar"] = String(request.get("speciesGrammar", raw.get("speciesGrammar", "bushy_oak")))
	recipe["ageBand"] = String(request.get("ageBand", "mature"))
	recipe["ageYears"] = float(request.get("ageYears", 0.0))
	recipe["growthStage"] = float(request.get("maturity", 0.58))
	recipe["geneticSeed"] = int(request.get("geneticSeed", 0))
	recipe["height"] = float(request.get("visualHeight", source_height))
	recipe["trunkRadius"] = float(request.get("trunkRadius", source_radius))
	recipe["canopyRadius"] = float(request.get("canopyRadius", source_canopy))
	recipe["canopyDensity"] = float(request.get("canopyDensity", 0.78))
	recipe["biomeParameters"] = (request.get("biomeParameters", {}) as Dictionary).duplicate(true)
	recipe["treeAdmissionCertificate"] = (request.get("treeAdmissionCertificate", {}) as Dictionary).duplicate(true)
	recipe["treeProducerCatalogRevision"] = String(request.get("treeProducerCatalogRevision", ""))
	recipe["treeProducerEnvelopeDigest"] = String(request.get("treeProducerEnvelopeDigest", ""))
	recipe["renderPolicy"] = render_policy(request)
	recipe["branches"] = branches
	var root_buttress_footprints: Array[Dictionary] = []
	for footprint_value in raw.get("rootButtressFootprints", []) as Array:
		if not footprint_value is Dictionary:
			continue
		var footprint: Dictionary = footprint_value as Dictionary
		root_buttress_footprints.append({
			"start": scale_position(footprint.get("start", Vector3.ZERO), horizontal_scale, vertical_scale),
			"end": scale_position(footprint.get("end", Vector3.ZERO), horizontal_scale, vertical_scale),
			"radiusStart": maxf(0.018, float(footprint.get("radiusStart", 0.04)) * radius_scale),
			"radiusEnd": maxf(0.012, float(footprint.get("radiusEnd", 0.02)) * radius_scale),
			"role": String(footprint.get("role", "root_buttress"))
		})
	recipe["rootButtressFootprints"] = root_buttress_footprints
	recipe["foliage"] = foliage
	# Preserve source totals as bounded diagnostic metadata.  Runtime reduction
	# must be evidence-led: a healthy low-cost recipe arrives near the render
	# budget instead of spending worker time on a graph that is later discarded.
	recipe["sourceBranchCount"] = int(raw.get("sourceBranchCount", branches.size()))
	recipe["sourceFoliageClusterCount"] = int(raw.get("sourceFoliageClusterCount", foliage.size()))
	recipe["runtimeRecipePassCount"] = int(raw.get("runtimeRecipePassCount", 1))
	recipe["runtimeFoliageSupplementCount"] = int(raw.get("runtimeFoliageSupplementCount", 0))
	recipe["branchCount"] = branches.size()
	recipe["foliageClusterCount"] = foliage.size()
	recipe["topologySignature"] = String(raw.get("signature", ""))
	recipe["signature"] = runtime_recipe_signature(recipe, request)
	recipe["collision"] = collision_summary(recipe)
	return recipe

func render_recipe(canonical: Dictionary, request: Dictionary) -> Dictionary:
	var recipe := canonical.duplicate(true)
	if String(request.get("presentation", "runtime")) == "review":
		recipe["pocContinuousWood"] = true
		return attach_interaction_facts(recipe, request)
	var lod_tier := normalize_lod_tier(String(request.get("renderLodTier", "near")))
	var budgets := runtime_render_budgets(request)
	if lod_tier == "impostor":
		recipe["branches"] = []
		recipe["foliage"] = []
		recipe["branchCount"] = 0
		recipe["foliageClusterCount"] = 0
		recipe["renderLod"] = {"tier": lod_tier, "branchBudget": 0, "foliageBudget": 0, "impostor": true}
		recipe["runtimeImpostor"] = true
		recipe["runtimeContinuousBole"] = false
		recipe["pocContinuousWood"] = false
		return attach_interaction_facts(recipe, request)
	var branch_budget := int(budgets.get("branchBudget", RUNTIME_BRANCH_BUDGET))
	var foliage_budget := int(budgets.get("foliageBudget", RUNTIME_FOLIAGE_BUDGET))
	# A tree is a directed support graph. A generic even sample can keep a child
	# while discarding its parent, leaving precisely the floating cylinders that
	# prompted this migration. Reduce only through a closure that retains every
	# selected segment's route back to the base wood.
	# canonical is a cached immutable recipe. Its deep clone above owns every
	# nested value, so only run reducers when the clone actually exceeds its
	# target. This avoids a second full deep-copy on the common within-budget
	# path and prevents a downshift result from aliasing cached branch/anchor
	# dictionaries selected from canonical.
	var recipe_branches: Array = recipe.get("branches", [])
	if recipe_branches.size() > branch_budget:
		recipe["branches"] = graph_preserving_reduce(recipe_branches, branch_budget)
	var recipe_foliage: Array = recipe.get("foliage", [])
	if recipe_foliage.size() > foliage_budget:
		recipe["foliage"] = support_aware_foliage_reduce(recipe_foliage, foliage_budget)
	recipe["branchCount"] = (recipe["branches"] as Array).size()
	recipe["foliageClusterCount"] = (recipe["foliage"] as Array).size()
	recipe["renderLod"] = {"tier": lod_tier, "branchBudget": branch_budget, "foliageBudget": foliage_budget, "impostor": false}
	recipe["runtimeImpostor"] = false
	# The viewer can approach the bole closely enough to see every wood seam.
	# Keep this continuous chain even at runtime; the numerous distal branches
	# remain instanced under the same bounded render budget.
	recipe["runtimeContinuousBole"] = true
	recipe["pocContinuousWood"] = false
	return attach_interaction_facts(recipe, request)


func attach_interaction_facts(recipe: Dictionary, request: Dictionary) -> Dictionary:
	var world_position: Vector3 = request.get("worldPosition", Vector3.ZERO) as Vector3
	var world_rotation := float(request.get("worldRotationY", 0.0))
	var basis := Basis(Vector3.UP, world_rotation)
	var root_buttresses: Array[Dictionary] = []
	for footprint_value in recipe.get("rootButtressFootprints", []) as Array:
		if not footprint_value is Dictionary:
			continue
		var footprint: Dictionary = footprint_value as Dictionary
		root_buttresses.append({
			"start": world_position + basis * (footprint.get("start", Vector3.ZERO) as Vector3),
			"end": world_position + basis * (footprint.get("end", Vector3.ZERO) as Vector3),
			"radiusStart": float(footprint.get("radiusStart", 0.10)),
			"radiusEnd": float(footprint.get("radiusEnd", 0.08)),
			"role": String(footprint.get("role", "root_buttress"))
		})
	recipe["interactionFacts"] = {
		"schemaVersion": 1,
		"treeId": String(request.get("treeId", recipe.get("treeId", ""))),
		"worldPosition": world_position,
		"worldRotationY": world_rotation,
		"rootButtresses": root_buttresses
	}
	return recipe

func runtime_render_budgets(request: Dictionary) -> Dictionary:
	var density := float(request.get("canopyDensity", 0.78))
	var lod_scale := float(LOD_BUDGET_SCALE.get(normalize_lod_tier(String(request.get("renderLodTier", "near"))), 1.0))
	return {
		"branchBudget": clampi(roundi(float(RUNTIME_BRANCH_BUDGET) * lerpf(0.70, 1.0, density) * lod_scale), 24, RUNTIME_BRANCH_BUDGET),
		"foliageBudget": clampi(roundi(float(RUNTIME_FOLIAGE_BUDGET) * lerpf(0.70, 1.0, density) * lod_scale), 32, RUNTIME_FOLIAGE_BUDGET)
	}

func render_policy(request: Dictionary) -> Dictionary:
	var biome_parameters: Dictionary = request.get("biomeParameters", {})
	var visibility_range := maxf(32.0, float(biome_parameters.get("visibilityRange", 440.0)))
	var shadow_range := clampf(float(biome_parameters.get("shadowRange", visibility_range * 0.5)), 16.0, visibility_range)
	return {
		"visibilityRange": visibility_range,
		"shadowRange": shadow_range,
		"windResponse": clampf(float(biome_parameters.get("windResponse", 1.0)), 0.0, 2.0),
		"shadowPolicy": "near_only",
		"lodTier": normalize_lod_tier(String(request.get("renderLodTier", "near"))),
	}

func collision_summary(recipe: Dictionary) -> Dictionary:
	var architecture := String(recipe.get("architecture", "broadleaf"))
	var height := float(recipe.get("height", 8.0))
	var trunk_fraction := 0.46
	if architecture == "conifer": trunk_fraction = 0.82
	elif architecture == "savanna": trunk_fraction = 0.52
	return {"trunkRadius": float(recipe.get("trunkRadius", 0.36)), "trunkHeight": maxf(2.0, height * trunk_fraction)}

func scale_position(position: Vector3, horizontal_scale: float, vertical_scale: float) -> Vector3:
	return Vector3(position.x * horizontal_scale, position.y * vertical_scale, position.z * horizontal_scale)

func evenly_reduce(source: Array, budget: int) -> Array:
	if source.size() <= budget:
		return source.duplicate(true)
	var result: Array = []
	var stride := float(source.size()) / float(budget)
	for index in range(budget):
		result.append(source[clampi(floori((float(index) + 0.5) * stride), 0, source.size() - 1)])
	return result

func support_aware_foliage_reduce(source: Array, budget: int) -> Array:
	# Foliage anchors carry the source branch segment that earned them. Preserve
	# the first high-priority anchor from every living axis before allocating
	# secondary clusters. This is a topology rule—not a screen-space canopy
	# shell—and therefore stays correct from every viewing angle.
	if source.size() <= budget:
		return source.duplicate(true)
	var anchors_by_segment := {}
	var segment_indices: Array[int] = []
	for source_value in source:
		if not (source_value is Dictionary):
			return evenly_reduce(source, budget)
		var anchor: Dictionary = source_value as Dictionary
		var segment_index := int(anchor.get("sourceSegment", -1))
		if segment_index < 0:
			return evenly_reduce(source, budget)
		if not anchors_by_segment.has(segment_index):
			anchors_by_segment[segment_index] = []
			segment_indices.append(segment_index)
		var segment_anchors: Array = anchors_by_segment[segment_index]
		segment_anchors.append(anchor)
		anchors_by_segment[segment_index] = segment_anchors
	if segment_indices.size() < 2:
		return evenly_reduce(source, budget)
	segment_indices.sort()
	var representatives: Array = []
	var overflow: Array = []
	for segment_index in segment_indices:
		var segment_anchors: Array = anchors_by_segment[segment_index]
		# Grammar builders return each segment's strongest candidate first. Keep
		# that ordering rather than imposing a view-dependent global rank here.
		representatives.append(segment_anchors[0])
		for anchor_index in range(1, segment_anchors.size()):
			overflow.append(segment_anchors[anchor_index])
	if representatives.size() > budget:
		return evenly_reduce(representatives, budget)
	var result: Array = representatives.duplicate(true)
	var remaining := mini(budget - result.size(), overflow.size())
	if remaining > 0:
		result.append_array(evenly_reduce(overflow, remaining))
	return result

func graph_preserving_reduce(source: Array, requested_budget: int) -> Array:
	if source.size() <= requested_budget:
		return source.duplicate(true)
	var branches: Array[Dictionary] = []
	var source_index_by_child := {}
	for source_value in source:
		if not (source_value is Dictionary):
			continue
		var branch: Dictionary = source_value as Dictionary
		var source_index := branches.size()
		branches.append(branch)
		var child_node := int(branch.get("childNode", -1))
		if child_node >= 0:
			source_index_by_child[child_node] = source_index
	if branches.size() <= requested_budget:
		return branches.duplicate(true)
	var selected := {}
	# The base bole is never sacrificed. The capacity expands only as far as
	# the actual order-zero trunk requires; all branch wood remains
	# subject to the runtime cap.
	for index in range(branches.size()):
		if int(branches[index].get("order", 4)) == 0:
			include_branch_ancestry(index, branches, source_index_by_child, selected)
	var effective_budget := maxi(requested_budget, selected.size())
	# Sample fine axes evenly by order, preserving coverage around the crown
	# rather than privileging insertion order. A candidate only enters when its
	# supporting ancestry fits inside the remaining bounded budget.
	for order in range(1, 5):
		var candidates: Array[int] = []
		for index in range(branches.size()):
			if int(branches[index].get("order", 4)) == order:
				candidates.append(index)
		if candidates.is_empty() or selected.size() >= effective_budget:
			continue
		var remaining := effective_budget - selected.size()
		var stride := float(candidates.size()) / float(maxi(1, remaining))
		var sample_count := mini(remaining, candidates.size())
		for sample in range(sample_count):
			var candidate_index := candidates[clampi(floori((float(sample) + 0.5) * stride), 0, candidates.size() - 1)]
			if selected.has(candidate_index):
				continue
			var ancestry := branch_ancestry(candidate_index, branches, source_index_by_child, selected)
			if selected.size() + ancestry.size() > effective_budget:
				continue
			for ancestry_index in ancestry:
				selected[ancestry_index] = true
			if selected.size() >= effective_budget:
				break
	var result: Array = []
	for index in range(branches.size()):
		if selected.has(index):
			result.append(branches[index])
	return result

func include_branch_ancestry(index: int, branches: Array[Dictionary], source_index_by_child: Dictionary, selected: Dictionary) -> void:
	for ancestor_index in branch_ancestry(index, branches, source_index_by_child, selected):
		selected[ancestor_index] = true

func branch_ancestry(index: int, branches: Array[Dictionary], source_index_by_child: Dictionary, selected: Dictionary) -> Array[int]:
	var ancestry: Array[int] = []
	var current := index
	var visited := {}
	while current >= 0 and current < branches.size() and not selected.has(current) and not visited.has(current):
		visited[current] = true
		ancestry.append(current)
		var parent_node := int(branches[current].get("parentNode", -1))
		current = int(source_index_by_child.get(parent_node, -1))
	ancestry.reverse()
	return ancestry

func request_key(request: Dictionary) -> String:
	return "%s:%s" % [recipe_identity_key_from_normalized(request), request.get("renderLodTier", "near")]

func recipe_identity_key_from_normalized(request: Dictionary) -> String:
	var biome_parameters: Dictionary = request.get("biomeParameters", {})
	return "%s:%s:%s:%s:%s:%s:%0.5f:%0.3f:%0.3f:%0.3f:%0.3f:%d:%s:%s" % [request.get("presentation", "runtime"), request.get("worldSeed", ""), request.get("treeId", ""), request.get("biome", ""), request.get("architecture", ""), request.get("speciesGrammar", ""), request.get("maturity", 0.0), request.get("visualHeight", 0.0), request.get("trunkRadius", 0.0), request.get("canopyRadius", 0.0), request.get("canopyDensity", 0.78), request.get("geneticSeed", 0), biome_parameter_key(biome_parameters), request.get("treeProducerEnvelopeDigest", "")]

func runtime_recipe_signature(recipe: Dictionary, request: Dictionary) -> String:
	return "tree-v%d-%08x" % [RECIPE_VERSION, stable_hash("%s:%s:%s" % [request_key(request), recipe.get("topologySignature", ""), int(recipe.get("branchCount", 0))])]

func lod_detail_rank(lod_tier: String) -> int:
	match normalize_lod_tier(lod_tier):
		"near": return 3
		"mid": return 2
		"far": return 1
		_: return 0

func normalize_lod_tier(value: String) -> String:
	var tier := value.strip_edges().to_lower()
	return tier if tier in LOD_TIERS else "near"

func biome_parameter_key(parameters: Dictionary) -> String:
	return "%d:%s:%0.2f:%0.2f:%0.3f:%0.3f:%0.3f:%0.3f:%0.3f:%0.3f:%0.1f:%0.1f" % [
		int(parameters.get("version", 1)), String(parameters.get("architecture", "")),
		float(parameters.get("heightMin", 0.0)), float(parameters.get("heightMax", 0.0)),
		float(parameters.get("trunkRadiusMin", 0.0)), float(parameters.get("trunkRadiusMax", 0.0)),
		float(parameters.get("canopyRadiusMin", 0.0)), float(parameters.get("canopyRadiusMax", 0.0)),
		float(parameters.get("canopyDensity", 0.78)), float(parameters.get("windResponse", 1.0)),
		float(parameters.get("visibilityRange", 440.0)), float(parameters.get("shadowRange", 220.0))
	]

func store_recipe(key: String, recipe: Dictionary) -> void:
	if recipe_cache.size() >= CACHE_CAPACITY:
		var oldest_key := ""
		var oldest_tick := 2147483647
		for cache_key in cache_access.keys():
			if int(cache_access[cache_key]) < oldest_tick:
				oldest_key = String(cache_key)
				oldest_tick = int(cache_access[cache_key])
		if oldest_key != "":
			recipe_cache.erase(oldest_key)
			cache_access.erase(oldest_key)
	recipe_cache[key] = recipe
	touch(key)

func touch(key: String) -> void:
	access_tick += 1
	cache_access[key] = access_tick

func stable_unit(text: String) -> float:
	return float(stable_hash(text) & 0x7fffffff) / float(0x7fffffff)

func stable_hash(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return value
