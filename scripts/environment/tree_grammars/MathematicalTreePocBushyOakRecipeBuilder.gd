extends "res://scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd"

## VOX-142 approved bushy spreading-oak mathematical grammar.
##
## This is intentionally a second broadleaf habit. Its long, low scaffolds and
## dense fine protrusions are generated as a bounded graph, rather than being a
## rounded broadleaf recipe with a larger foliage scale.

const BUSHY_OAK_RECIPE_VERSION := 21
const MAX_OAK_BRANCH_SEGMENTS := 1800
const MAX_OAK_FOLIAGE_CLUSTERS := 1600
# The headed PoC's dense-leaf review cap. Keep this separate from the eventual
# asset budget so this experiment remains comparable with earlier captures.
const OAK_REVIEW_FOLIAGE_BUDGET := 1250
const MAX_PRIMARY_LEADERS := 8
const OAK_PRIMARY_REACH_FRACTION := 0.82
const OAK_COARSE_SPACE_ATTRACTION_POINTS := 260
const OAK_FINE_SPACE_ATTRACTION_POINTS := 480
## Crown-density field resolution. This is a spatial sampling budget, never a
## requested branch count; the points themselves still come from the species
## crown distribution and are re-evaluated every growth season.
const OAK_DENSITY_FIELD_SAMPLE_BUDGET := 96
const OAK_DENSITY_FIELD_CELL_SIZE := 4.5
## These are wood-capacity thresholds, not a requested number of branch
## layers. Each recursive axis can continue and fork while it still carries
## enough material; terminal twigs are emitted only after it becomes too thin
## to support another structural fork.
const OAK_MIN_FORK_RADIUS := 0.052
const OAK_MIN_TERMINAL_RADIUS := 0.025
const OAK_MIN_BRANCH_LENGTH := 0.74
const OAK_CONTINUATION_RADIUS_FRACTION := 0.72
const OAK_LATERAL_RADIUS_FRACTION := 0.42
const OAK_CONTINUATION_LENGTH_FRACTION := 0.76
const OAK_LATERAL_LENGTH_FRACTION := 0.63
const OAK_ENGINEERING_GENERATION_GUARD := 15
## A lateral axis opens into the remaining local crown space, but it cannot
## leap past the outward frontier already established by its parent axis.
const OAK_INNER_BLOOM_REACH_FRACTION := 0.72
## The active scaffold samples attachment points through this continuous crown
## interval. These are normalized bounds, not authored branch tiers: each
## bough gets a deterministic stratified height and its own envelope target.
const OAK_CROWN_ATTACHMENT_MIN := 0.04
const OAK_CROWN_ATTACHMENT_MAX := 0.82
# Historical V4 comparison helpers remain below, but are not called by this
# recipe. The active grammar has no fixed recursive-depth stop.
const OAK_MAX_RECURSIVE_DEPTH := 3
const OAK_CHILD_LENGTH_DECAY := 0.57
# Only referenced by the explicitly unused legacy comparison helper below.
# The active `build_spreading_scaffold_graph` does not use crown layers.
const OAK_CROWN_LAYER_COUNT := 8
const OAK_CROWN_LAYER_REACH_STEP := 0.10
const OAK_CROWN_BASE_REACH_FRACTION := 0.90

func build_recipe(seed := DEFAULT_SEED, maturity := 0.92, growth_profile: Dictionary = {}) -> Dictionary:
	return build_oak_space_colony_recipe(seed, maturity, growth_profile)

func oak_outward_dome_profile() -> Dictionary:
	# This defines a species growth field, not a list of boughs. A mature oak
	# grows toward available crown space but major wood may not reverse toward the
	# bole once it has established an outward frontier.
	return {
		# Keep V35's successful crown-space distribution. The dome behavior comes
		# from constrained growth, not from hollowing the interior target field.
		"attractionInnerRadius": 0.0,
		"attractionRadialExponent": 0.36,
		"enforceOutwardDome": true,
		"killDistanceMultiplier": 1.0,
		"branchSegmentBudget": 1600,
		"attractionPointCount": 900,
		"allowMidCrownTrunkBuds": true,
		"allowTrunkBudsInColonization": false,
		"midCrownBudPeak": 0.38,
		"midCrownBudSpread": 0.32,
		"trunkBudMinimumHorizontalReach": 2.0,
		"trunkBudActivationGain": 0.92,
		"trunkBudGerminationGain": 1.80,
		"trunkBudSiteDensity": 1.60,
		"midCrownChildCapacityGain": 3.00,
		# A non-base axis can branch wherever the pipe model says it carries
		# enough wood. These are continuous developmental thresholds, not a
		# authored list of branch layers or positions.
		"derivedAxisMinimumForkRadius": 0.520,
		"derivedAxisSupportRange": 0.80,
		"derivedAxisBudSiteDensity": 0.72,
		# Bud production is an allometric property of the carrying axis. A mature
		# split with twice the radius does not merely look thicker: it receives more
		# developmental opportunities along the same arclength.
		"derivedAxisBudGirthExponent": 0.72,
		"derivedAxisMaximumGirthBudGain": 2.25,
		# A thick non-bole axis may fork into a co-dominant continuation rather
		# than always producing a subordinate twig. Its probability is continuous
		# in pipe girth and declines acropetally along the parent axis.
		"derivedAxisCoDominantGirthRatio": 1.50,
		"derivedAxisCoDominantMaximumOrder": 2,
		"derivedAxisCoDominantMaximumProbability": 0.82,
		"derivedAxisMaximumBudsPerSegment": 3,
		"derivedAxisBudMinimumPotential": 0.20,
		"derivedAxisPostForkGreedGain": 0.65,
		"derivedAxisMaximumGrowthSeasons": 4,
		"derivedAxisDensityCompletionThreshold": 0.20,
		"derivedAxisLateralPriorityAtBase": 0.70,
		"derivedAxisLateralPriorityAtTip": 0.44,
		"derivedAxisHydraulicResourceScale": 12.0,
		"derivedAxisResourcePerMetamer": 3.20,
		# A successful lateral must establish a true axis, not a single cosmetic
		# spur. Further continuation and forks remain governed by the same pipe
		# radius test in later growth seasons.
		"derivedAxisMinimumMetamers": 2,
		"derivedAxisMaximumMetamers": 5,
		"derivedAxisMinimumForkSpan": 5.60,
		"derivedAxisSpanRadiusExponent": 0.62,
		# Fine oak wood continues the same radius-limited grammar below the
		# structural threshold, but only after a secondary axis exists. Its smaller
		# spatial/resource scale produces dense recursive ramification instead of
		# turning the main trunk or boughs into a forest of long spikes.
		"fineAxisMinimumForkRadius": 0.24,
		"fineAxisMinimumOrder": 2,
		"fineAxisBudSiteDensity": 0.34,
		"fineAxisMaximumBudsPerSegment": 1,
		"fineAxisHydraulicResourceScale": 8.0,
		"fineAxisResourcePerMetamer": 1.35,
		"fineAxisMinimumMetamers": 2,
		"fineAxisMaximumMetamers": 3,
		"fineAxisMinimumForkSpan": 1.35,
		"fineAxisSpanRadiusExponent": 0.56,
		"fineAxisMaximumSpanFraction": 0.18,
		"fineAxisBaseBudPressure": 0.34,
		"fineAxisTipBudPressure": 1.16,
		"fineAxisDistalPressureExponent": 0.58,
		"outwardWeightByOrder": [0.0, 0.17, 0.14, 0.09, 0.05],
		"minimumRadialAlignmentInnerByOrder": [0.0, 0.10, 0.07, 0.04, 0.015],
		"minimumRadialAlignmentOuterByOrder": [0.0, 0.02, 0.015, 0.01, 0.002],
		"forwardAttractionMinimumDotByOrder": [-1.0, -1.0, -1.0, -1.0, -1.0],
		"radialProgressStart": 0.13,
		"radialBacktrackByOrder": [1.0, 0.0, 0.008, 0.015, 0.08],
		# Competing woody axes cannot grow through occupied wood volume. The
		# clearance decays with branch order, so structural boughs reserve room for
		# their own crowns while terminal twigs can still form a dense oak outline.
		"woodClearanceByOrder": [0.0, 0.58, 0.38, 0.24, 0.13],
		"maximumTurnRadiansByOrder": [PI, 0.42, 0.52, 0.62, 1.20],
		# Directional persistence is a developmental memory, not an authored limb
		# path. A branch may respond to light and local space, but its continuation
		# cannot turn through its own emergence cone and curl back toward the core.
		"minimumHeadingAlignmentByOrder": [-1.0, 0.62, 0.50, 0.34, 0.12]
	}

func build_oak_reference_skeleton_recipe(seed: int, maturity: float) -> Dictionary:
	# A branch carries two coupled quantities: remaining span and available wood
	# resource. Its continuation keeps most of each; a lateral receives a smaller
	# share. Recursion stops only when either becomes too small. This makes the
	# familiar fractal hierarchy an outcome of allometry instead of a depth count.
	var resolved_seed: int = int(seed)
	var resolved_maturity: float = clampf(float(maturity), 0.12, 1.0)
	var normalized_growth: float = (1.0 - exp(-3.40 * resolved_maturity)) / (1.0 - exp(-3.40))
	var height: float = lerpf(15.0, 42.0, normalized_growth)
	var trunk_radius: float = lerpf(0.78, 3.10, pow(normalized_growth, 0.70))
	var fork_height: float = lerpf(5.4, 11.4, pow(normalized_growth, 0.76))
	var canopy_radius: float = lerpf(9.0, 28.0, pow(normalized_growth, 0.84))
	var crown_height: float = lerpf(13.0, 31.0, pow(normalized_growth, 0.80))
	var crown_center := Vector3(0.0, fork_height + crown_height * 0.40, 0.0)
	var crown_radii := Vector3(canopy_radius, crown_height * 0.58, canopy_radius * 0.93)
	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	var state: Dictionary = {"axisCount": 0, "prunedAxisCount": 0}
	var root: int = append_node(nodes, raw_segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var trunk_steps: int = maxi(13, ceili(fork_height / 0.78))
	var trunk_phase: float = stable_unit("oak-reference-trunk:%d" % resolved_seed) * TAU
	var previous: int = root
	for step_index in range(1, trunk_steps + 1):
		var unit: float = float(step_index) / float(trunk_steps)
		var bend: float = pow(unit, 1.42) * lerpf(0.12, 0.44, stable_unit("oak-reference-trunk-bend:%d" % resolved_seed))
		var position := Vector3(cos(trunk_phase + unit) * bend, fork_height * unit, sin(trunk_phase + unit * 0.86) * bend)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		previous = append_node(nodes, raw_segments, position, previous, 0, (position - start).normalized())
		trunk_nodes.append(previous)

	const primary_bough_count := 7
	var phase: float = stable_unit("oak-reference-primary:%d" % resolved_seed) * TAU
	for bough_index in range(primary_bough_count):
		var attachment_band: float = (float(bough_index) + 0.50 + stable_signed("oak-reference-height:%d:%d" % [resolved_seed, bough_index]) * 0.16) / float(primary_bough_count)
		var attachment_unit: float = lerpf(0.60, 0.98, clampf(attachment_band, 0.04, 0.96))
		var attachment_index: int = clampi(roundi(attachment_unit * float(trunk_nodes.size() - 1)), 1, trunk_nodes.size() - 1)
		var parent: int = trunk_nodes[attachment_index]
		var angle: float = phase + float(bough_index) * GOLDEN_ANGLE + stable_signed("oak-reference-angle:%d:%d" % [resolved_seed, bough_index]) * 0.10
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var initial_pitch: float = lerpf(-0.015, 0.26, attachment_unit)
		var heading := (radial * 0.95 + Vector3.UP * initial_pitch + side * stable_signed("oak-reference-curl:%d:%d" % [resolved_seed, bough_index]) * 0.028).normalized()
		var span: float = canopy_radius * lerpf(0.72, 0.88, stable_unit("oak-reference-span:%d:%d" % [resolved_seed, bough_index]))
		grow_oak_reference_axis(
			nodes, raw_segments, parent, heading, radial, span, 1.0, 1, bough_index + 1,
			crown_center, crown_radii, resolved_seed, state
		)

	smooth_non_junction_chains(nodes, 1)
	var pipe_result: Dictionary = solve_pipe_model(nodes, raw_segments, trunk_radius, height, fork_height)
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	var foliage: Array[Dictionary] = build_bushy_oak_foliage(nodes, raw_segments, crown_center, crown_radii, height, resolved_seed)
	var counts: Dictionary = segment_counts_by_order(raw_segments)
	var occupancy: Dictionary = crown_occupancy(foliage, crown_center, crown_radii)
	var major_reach: float = maximum_major_wood_reach(branches)
	var signature: String = recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)
	return {
		"recipeVersion": BUSHY_OAK_RECIPE_VERSION,
		"methodology": "deterministic_oak_allometric_axis_reiteration_pipe_model",
		"architecture": "broadleaf",
		"speciesGrammar": "bushy_spreading_oak_poc",
		"crownHabit": "decurrent_broad_oval_oak",
		"seed": resolved_seed,
		"maturity": resolved_maturity,
		"height": height,
		"trunkRadius": trunk_radius,
		"canopyRadius": canopy_radius,
		"crownBase": fork_height,
		"crownHeight": crown_height,
		"crownCenter": crown_center,
		"crownRadii": crown_radii,
		"pocContinuousWood": true,
		"signature": signature,
		"branches": branches,
		"foliage": foliage,
		"branchCount": branches.size(),
		"foliageClusterCount": foliage.size(),
		"stats": {
			"nodeCount": nodes.size(),
			"segmentCountsByOrder": counts,
			"scaffoldAxisCount": primary_bough_count,
			"allometricAxisCount": int(state.get("axisCount", 0)),
			"selfPrunedAxisCount": int(state.get("prunedAxisCount", 0)),
			"crownConstruction": "decurrent_oak_allometric_axis_reiteration",
			"continuousTrunkPath": trunk_nodes.size() >= 7,
			"majorWoodReach": major_reach,
			"majorWoodReachToTrunkWidth": major_reach / maxf(0.1, trunk_radius * 2.0),
			"connected": graph_is_connected(nodes, raw_segments),
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"foliageUsesSupportingWoodAcrossOrders": true,
			"budgetSaturation": {
				"branchSegments": float(branches.size()) / float(MAX_OAK_BRANCH_SEGMENTS),
				"foliageClusters": float(foliage.size()) / float(MAX_OAK_FOLIAGE_CLUSTERS),
				"branchLimitReached": raw_segments.size() >= MAX_OAK_BRANCH_SEGMENTS,
				"foliageLimitReached": foliage.size() >= MAX_OAK_FOLIAGE_CLUSTERS
			}
		}
	}

func grow_oak_reference_axis(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial_hint: Vector3,
	span: float,
	resource: float,
	order: int,
	lineage: int,
	crown_center: Vector3,
	crown_radii: Vector3,
	seed: int,
	state: Dictionary
) -> void:
	if segments.size() >= MAX_OAK_BRANCH_SEGMENTS or order > 4 or resource < 0.042 or span < 0.34:
		return
	state["axisCount"] = int(state.get("axisCount", 0)) + 1
	var segment_count: int = clampi(ceili(span / (2.70 if order <= 2 else 0.62)), 2, 6)
	var segment_length: float = span / float(segment_count)
	var current: int = parent
	var current_heading: Vector3 = heading.normalized()
	var continuation_radial: Vector3 = radial_hint
	for segment_index in range(segment_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return
		var start: Vector3 = nodes[current].get("position", Vector3.ZERO)
		var local := start - crown_center
		var crown_unit: float = clampf((local.y / maxf(0.1, crown_radii.y) + 1.0) * 0.5, 0.0, 1.0)
		var radial := Vector3(local.x, 0.0, local.z)
		if radial.length_squared() < 0.001:
			radial = radial_hint
		else:
			radial = radial.normalized()
		continuation_radial = radial
		var progress: float = float(segment_index) / float(maxi(1, segment_count - 1))
		var rise: float = lerpf(-0.015, 0.055 + float(order) * 0.025, crown_unit) + progress * 0.010
		var direction := (current_heading * 0.90 + radial * 0.065 + Vector3.UP * rise + stable_noise_vector(seed, lineage, segment_index) * 0.012).normalized()
		var endpoint: Vector3 = start + direction * segment_length
		if not oak_point_inside_space_crown(endpoint, crown_center, crown_radii, 0.0) or endpoint_too_close(endpoint, nodes, current):
			state["prunedAxisCount"] = int(state.get("prunedAxisCount", 0)) + 1
			return
		var child: int = append_node(nodes, segments, endpoint, current, order, direction)
		tag_stratum(nodes, child, clampf(crown_unit * 2.0 - 1.0, -1.0, 1.0))
		current = child
		current_heading = direction
		if order < 4 and segment_index >= 1 and segment_index < segment_count - 1:
			var side := direction.cross(Vector3.UP)
			if side.length_squared() < 0.001:
				side = radial.cross(Vector3.UP)
			side = side.normalized()
			var fan_count: int = 2 if order >= 3 else 1
			for fan_index in range(fan_count):
				var handedness: float = -1.0 if posmod(lineage + segment_index + fan_index, 2) == 0 else 1.0
				var lateral_plane := (radial * 0.52 + side * handedness * 0.80).normalized()
				var lateral_heading := (lateral_plane * 0.86 + direction * 0.16 + Vector3.UP * lerpf(0.035, 0.16, crown_unit)).normalized()
				var remaining_span: float = span * (1.0 - (float(segment_index) + 0.25) / float(segment_count))
				var lateral_fraction: float = [0.0, 0.61, 0.54, 0.46, 0.0][clampi(order, 0, 4)]
				grow_oak_reference_axis(
					nodes, segments, current, lateral_heading, lateral_plane,
					remaining_span * lateral_fraction, resource * lateral_fraction,
					order + 1, lineage * 13 + segment_index * 3 + fan_index + 1,
					crown_center, crown_radii, seed, state
				)
	# The continuation retains more support than its lateral, then narrows by
	# repeated resource allocation. The stopping condition above—not an authored
	# recursion depth—eventually turns this into the fine perimeter twig network.
	var continuation_span: float = span * 0.72
	var continuation_resource: float = resource * 0.74
	if continuation_span >= 0.34 and continuation_resource >= 0.042:
		var continuation_heading := (current_heading * 0.89 + continuation_radial * 0.06 + Vector3.UP * (0.012 + float(order) * 0.016)).normalized()
		grow_oak_reference_axis(
			nodes, segments, current, continuation_heading, continuation_radial,
			continuation_span, continuation_resource, order, lineage * 13 + 7,
			crown_center, crown_radii, seed, state
		)

func build_oak_space_colony_recipe(seed: int, maturity: float, growth_profile: Dictionary = {}) -> Dictionary:
	# Runions-style space colonization supplies local competition for available
	# crown space. The oak grammar changes only the organism-scale constraints:
	# a taller clean bole, a broad oblate envelope, and a low number of durable
	# decurrent scaffold limbs. It never asks for a prescribed branch tier.
	var resolved_seed: int = int(seed)
	var resolved_maturity: float = clampf(float(maturity), 0.12, 1.0)
	# Keep a small, per-recipe timing breakdown for the production performance
	# benchmark. This is pure worker-side diagnostic data: it identifies which
	# biological process is costly without moving any render work onto gameplay
	# frames or changing the generated topology.
	var recipe_started_usec := Time.get_ticks_usec()
	var timing_usec := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = resolved_seed
	var normalized_growth: float = (1.0 - exp(-3.40 * resolved_maturity)) / (1.0 - exp(-3.40))
	var height: float = lerpf(16.0, 43.0, normalized_growth)
	var trunk_radius: float = lerpf(0.78, 3.10, pow(normalized_growth, 0.70))
	var crown_base: float = lerpf(5.8, 11.6, pow(normalized_growth, 0.78))
	var crown_radius: float = lerpf(9.0, 29.0, pow(normalized_growth, 0.84))
	var crown_height: float = lerpf(13.0, 32.5, pow(normalized_growth, 0.82))
	var crown_center := Vector3(0.0, crown_base + crown_height * 0.45, 0.0)
	var crown_radii := Vector3(crown_radius, crown_height * 0.54, crown_radius * 0.92)
	var crown_phase: float = rng.randf() * TAU
	var crown_lobes: Array[Dictionary] = build_crown_lobes(rng, crown_center, crown_radii, crown_phase)
	var dome_profile := oak_outward_dome_profile()
	# Streaming may reduce sample resolution, yet it still uses the oak's own
	# outward-dome, girth-gated bud, pipe, and leaf-on-wood rules.  These values
	# are therefore algorithmic budgets, never an authored alternate silhouette.
	for key in growth_profile:
		dome_profile[key] = growth_profile[key]

	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	build_trunk_and_scaffold_seeds(
		nodes, raw_segments, trunk_nodes, rng, height, crown_base, crown_radius,
		1.38, resolved_seed
	)
	var lower_primary_count: int = seed_oak_lower_primary_boughs(
		nodes, raw_segments, trunk_nodes, crown_radius, resolved_seed
	)
	var mid_crown_bud_count: int = germinate_mid_crown_buds(
		nodes, raw_segments, trunk_nodes, crown_center, crown_radii, crown_phase, resolved_seed, dome_profile
	)
	timing_usec["scaffold"] = Time.get_ticks_usec() - recipe_started_usec
	var attraction_started_usec := Time.get_ticks_usec()
	var attraction_points: Array[Vector3] = build_attraction_points(
		rng, crown_center, crown_radii, crown_phase, crown_lobes,
		int(dome_profile.get("attractionPointCount", 460)), dome_profile
	)
	timing_usec["attractions"] = Time.get_ticks_usec() - attraction_started_usec
	var initial_attraction_count: int = attraction_points.size()
	var colonization_started_usec := Time.get_ticks_usec()
	# The oak owns a spatially indexed SCA pass. Calling the inherited broadleaf
	# scan here made a mature near tree compare every crown target with every bud
	# on every iteration (quadratic worker time), even though this grammar already
	# defines the same deterministic nearest-bud rule with a local grid.
	var colonization: Dictionary = colonize_oak_space_crown(
		nodes, raw_segments, attraction_points, crown_center, crown_radii, crown_phase,
		1.38, resolved_seed,
		int(dome_profile.get("spaceColonizationIterationBudget", 15)),
		int(dome_profile.get("branchSegmentBudget", MAX_OAK_BRANCH_SEGMENTS))
	)
	timing_usec["colonization"] = Time.get_ticks_usec() - colonization_started_usec
	var remaining_attractions: Array = colonization.get("remainingAttractions", attraction_points)
	smooth_non_junction_chains(nodes, 2)

	# The first SCA pass establishes the continuous load-bearing skeleton. A
	# solved pipe pass then lets every derived (non-bole) axis expose latent bud
	# sites in proportion to its actual girth. This removes the old blank spans
	# on split trunks without turning the base bole into a brush of tiny twigs.
	var first_pipe_started_usec := Time.get_ticks_usec()
	var preliminary_pipe: Dictionary = solve_pipe_model(nodes, raw_segments, trunk_radius, height, crown_base)
	timing_usec["initialPipe"] = Time.get_ticks_usec() - first_pipe_started_usec
	var derived_axis_seasons: Array[Dictionary] = []
	# Developmental time is maturity-scaled. It is not a prescription of branch
	# layers: each season simply gives the resource and density feedback another
	# chance to act, and stops early once the target crown is served.
	var maximum_growth_seasons := maxi(1, int(dome_profile.get("derivedAxisMaximumGrowthSeasons", 4)))
	var season_count := clampi(ceili(resolved_maturity * float(maximum_growth_seasons)), 1, maximum_growth_seasons)
	var density_completion_threshold := clampf(
		float(dome_profile.get("derivedAxisDensityCompletionThreshold", 0.20)), 0.01, 0.95
	)
	var season_pipe := preliminary_pipe
	var seasonal_growth_started_usec := Time.get_ticks_usec()
	for season_index in range(season_count):
		var season_result: Dictionary = germinate_continuous_axis_buds(
			nodes, raw_segments, season_pipe, crown_center, crown_radii,
			# Re-evaluate the complete desired crown volume each season. The static
			# SCA remainder alone cannot express new gaps created behind or between
			# established limbs.
			crown_phase, resolved_seed, dome_profile, attraction_points, season_index
		)
		derived_axis_seasons.append(season_result)
		if int(season_result.get("germinatedBudCount", 0)) == 0 \
				or float(season_result.get("meanCrownDensityDeficit", 1.0)) <= density_completion_threshold:
			break
		season_pipe = solve_pipe_model(nodes, raw_segments, trunk_radius, height, crown_base)
	timing_usec["seasonalGrowth"] = Time.get_ticks_usec() - seasonal_growth_started_usec
	var derived_axis_buds: Dictionary = summarize_derived_axis_seasons(derived_axis_seasons)
	var final_pipe_started_usec := Time.get_ticks_usec()
	var pipe_result: Dictionary = solve_pipe_model(nodes, raw_segments, trunk_radius, height, crown_base)
	timing_usec["finalPipe"] = Time.get_ticks_usec() - final_pipe_started_usec
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	branches.append_array(build_root_buttresses(trunk_radius, resolved_seed))
	var foliage_budget := maxi(160, int(dome_profile.get("foliageClusterBudget", OAK_REVIEW_FOLIAGE_BUDGET)))
	var foliage_started_usec := Time.get_ticks_usec()
	var foliage: Array[Dictionary] = build_oak_full_axis_foliage(nodes, raw_segments, crown_center, crown_radii, height, resolved_seed, foliage_budget)
	timing_usec["foliage"] = Time.get_ticks_usec() - foliage_started_usec
	var analysis_started_usec := Time.get_ticks_usec()
	var counts: Dictionary = segment_counts_by_order(raw_segments)
	var occupancy: Dictionary = crown_occupancy(foliage, crown_center, crown_radii)
	var major_reach: float = maximum_major_wood_reach(branches)
	var signature: String = recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)
	timing_usec["analysis"] = Time.get_ticks_usec() - analysis_started_usec
	timing_usec["total"] = Time.get_ticks_usec() - recipe_started_usec
	return {
		"recipeVersion": BUSHY_OAK_RECIPE_VERSION,
		"methodology": "deterministic_oak_space_colonization_pipe_model",
		"architecture": "broadleaf",
		"speciesGrammar": "bushy_spreading_oak_poc",
		"crownHabit": "decurrent_broad_oval_oak",
		"seed": resolved_seed,
		"maturity": resolved_maturity,
		"height": height,
		"trunkRadius": trunk_radius,
		"canopyRadius": crown_radius,
		"crownBase": crown_base,
		"crownHeight": crown_height,
		"crownCenter": crown_center,
		"crownRadii": crown_radii,
		"pocContinuousWood": true,
		"signature": signature,
		"branches": branches,
		"foliage": foliage,
		"branchCount": branches.size(),
		"foliageClusterCount": foliage.size(),
		"stats": {
			"timingUsec": timing_usec,
			"nodeCount": nodes.size(),
			"segmentCountsByOrder": counts,
			"scaffoldAxisCount": 5 + lower_primary_count + mid_crown_bud_count,
			"germinatedMidCrownBudCount": mid_crown_bud_count,
			"midCrownBudField": "gaussian_height_times_core_proximity",
			"derivedAxisGrowth": derived_axis_buds,
			"attractionPointCount": initial_attraction_count,
			"remainingAttractionPoints": remaining_attractions.size(),
			"attractionConsumedRatio": 1.0 - float(remaining_attractions.size()) / float(maxi(1, initial_attraction_count)),
			"growthIterations": int(colonization.get("iterations", 0)),
			"crownConstruction": "decurrent_oak_space_colonization_with_outward_dome_constraint",
			"continuousTrunkPath": trunk_nodes.size() >= 7,
			"majorWoodReach": major_reach,
			"majorWoodReachToTrunkWidth": major_reach / maxf(0.1, trunk_radius * 2.0),
			"connected": graph_is_connected(nodes, raw_segments),
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"foliageUsesSupportingWoodAcrossOrders": true,
			"budgetSaturation": {
				"branchSegments": float(branches.size()) / float(maxi(1, int(colonization.get("branchSegmentLimit", MAX_BRANCH_SEGMENTS)))),
				"foliageClusters": float(foliage.size()) / float(foliage_budget),
				"branchLimitReached": raw_segments.size() >= int(colonization.get("branchSegmentLimit", MAX_BRANCH_SEGMENTS)),
				"foliageLimitReached": foliage.size() >= foliage_budget
			}
		}
	}

func seed_oak_lower_primary_boughs(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	crown_radius: float,
	seed: int
) -> int:
	# Four durable bough seeds establish the wide lower shoulder of an old oak.
	# Their phyllotactic placement and subsequent competition remain seed-driven;
	# this does not prescribe a ring or a set of crown layers.
	const bough_count := 4
	var phase: float = stable_unit("bushy-oak-v11-lower-bough-phase:%d" % seed) * TAU
	for bough_index in range(bough_count):
		var attachment_unit: float = lerpf(0.58, 0.88, (float(bough_index) + 0.50) / float(bough_count))
		var attachment_index: int = clampi(roundi(attachment_unit * float(trunk_nodes.size() - 1)), 1, trunk_nodes.size() - 1)
		var parent: int = trunk_nodes[attachment_index]
		var angle: float = phase + float(bough_index) * GOLDEN_ANGLE + stable_signed("bushy-oak-v11-lower-bough-angle:%d:%d" % [seed, bough_index]) * 0.10
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var heading := (radial * 0.97 + Vector3.UP * lerpf(-0.02, 0.12, attachment_unit) + side * stable_signed("bushy-oak-v11-lower-bough-curl:%d:%d" % [seed, bough_index]) * 0.035).normalized()
		for segment_index in range(2):
			var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
			heading = (heading * 0.88 + radial * 0.10 + Vector3.UP * 0.045).normalized()
			parent = append_node(nodes, segments, start + heading * crown_radius * 0.115, parent, 1, heading)
			tag_stratum(nodes, parent, lerpf(-0.58, -0.18, float(segment_index)))
	return bough_count

func germinate_mid_crown_buds(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	seed: int,
	dome_profile: Dictionary
) -> int:
	# Each trunk internode contains a latent bud. Its developmental activation is
	# a continuous Gaussian through the mid crown, its azimuth follows
	# phyllotaxis, and it becomes wood only when that deterministic local signal
	# wins. These are organism-level initial conditions for SCA, not authored
	# branches or a prescribed layer.
	var bud_count := 0
	var crown_bottom := crown_center.y - crown_radii.y
	var germination_gain := maxf(0.0, float(dome_profile.get("trunkBudGerminationGain", 1.0)))
	var trunk_arclength := 0.0
	for trunk_index in range(1, trunk_nodes.size()):
		var prior_position: Vector3 = nodes[trunk_nodes[trunk_index - 1]].get("position", Vector3.ZERO)
		var current_position: Vector3 = nodes[trunk_nodes[trunk_index]].get("position", Vector3.ZERO)
		trunk_arclength += prior_position.distance_to(current_position)
	var site_density := maxf(0.05, float(dome_profile.get("trunkBudSiteDensity", 0.25)))
	var candidate_site_count := maxi(1, ceili(trunk_arclength * site_density))
	for bud_site in range(candidate_site_count):
		var axial_unit := (float(bud_site) + 0.5) / float(candidate_site_count)
		var trunk_index := clampi(
			roundi(axial_unit * float(trunk_nodes.size() - 1)), 1, trunk_nodes.size() - 2
		)
		var parent_index := trunk_nodes[trunk_index]
		var position: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var activation := mid_crown_bud_activation(position, crown_center, crown_radii, dome_profile)
		if stable_unit("mid-crown-germination:%d:%d" % [seed, bud_site]) > clampf(activation * germination_gain, 0.0, 1.0):
			continue
		var azimuth := crown_phase + float(bud_site) * GOLDEN_ANGLE \
			+ stable_signed("mid-crown-azimuth:%d:%d" % [seed, bud_site]) * 0.17
		var radial := Vector3(cos(azimuth), 0.0, sin(azimuth))
		var tangent := radial.cross(Vector3.UP).normalized()
		var crown_unit := clampf((position.y - crown_bottom) / maxf(0.1, crown_radii.y * 2.0), 0.0, 1.0)
		var pitch := lerpf(-0.04, 0.24, crown_unit) \
			+ stable_signed("mid-crown-pitch:%d:%d" % [seed, bud_site]) * 0.045
		var heading := (radial * 0.94 + Vector3.UP * pitch \
			+ tangent * stable_signed("mid-crown-twist:%d:%d" % [seed, bud_site]) * 0.09).normalized()
		# A trunk-derived axis clears the parent wood before normal SCA competition
		# takes over. Its establishment span is continuous in the local
		# developmental signal; it is never a named branch tier or limb layout.
		var emergence_length := lerpf(
			maxf(0.25, float(dome_profile.get("trunkBudEstablishmentSpanMinimum", 0.52))),
			maxf(0.30, float(dome_profile.get("trunkBudEstablishmentSpanMaximum", 1.10))),
			activation
		)
		var bud_index := append_node(nodes, segments, position + heading * emergence_length, parent_index, 1, heading)
		var bud: Dictionary = nodes[bud_index]
		bud["domeAxis"] = radial
		bud["domeHeading"] = heading
		bud["stratumBias"] = crown_unit * 2.0 - 1.0
		nodes[bud_index] = bud
		bud_count += 1
	return bud_count

func annotate_derived_axes(nodes: Array[Dictionary]) -> Dictionary:
	# An axis is a continuous same-order path. Every new order starts a derived
	# axis, and a same-order fork begins a second axis rather than borrowing its
	# sibling's arclength. The order-zero bole is deliberately never an axis
	# eligible for lateral twig buds.
	var axis_lengths: Dictionary = {}
	var axis_count := 0
	for node_index in range(nodes.size()):
		var node: Dictionary = nodes[node_index]
		var parent_index := int(node.get("parent", -1))
		var order := int(node.get("order", 0))
		var axis_id := -1
		var axis_arclength := 0.0
		if parent_index >= 0 and order > 0:
			var parent: Dictionary = nodes[parent_index]
			var parent_order := int(parent.get("order", 0))
			var parent_axis_id := int(parent.get("axisId", -1))
			var prior_same_order_child := false
			for sibling_value in parent.get("children", []):
				var sibling_index := int(sibling_value)
				if sibling_index == node_index:
					break
				if sibling_index >= 0 and sibling_index < nodes.size() \
						and int(nodes[sibling_index].get("order", 0)) == order:
					prior_same_order_child = true
			var segment_length := (node.get("position", Vector3.ZERO) as Vector3).distance_to(
				parent.get("position", Vector3.ZERO) as Vector3
			)
			if parent_order == order and parent_axis_id >= 0 and not prior_same_order_child:
				axis_id = parent_axis_id
				axis_arclength = float(parent.get("axisArclength", 0.0)) + segment_length
			else:
				axis_id = node_index
				axis_arclength = segment_length
				axis_count += 1
			node["axisId"] = axis_id
			node["axisArclength"] = axis_arclength
			node["isBaseBole"] = axis_id < 0
			nodes[node_index] = node
			if axis_id >= 0:
				axis_lengths[axis_id] = maxf(float(axis_lengths.get(axis_id, 0.0)), axis_arclength)
	for node_index in range(nodes.size()):
		var node: Dictionary = nodes[node_index]
		var axis_id := int(node.get("axisId", -1))
		if axis_id >= 0:
			node["axisLength"] = float(axis_lengths.get(axis_id, 0.0))
			nodes[node_index] = node
	return {"axisCount": axis_count, "axisLengths": axis_lengths}

func germinate_continuous_axis_buds(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	preliminary_pipe: Dictionary,
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	seed: int,
	dome_profile: Dictionary,
	desired_crown_points: Array,
	season_index: int
) -> Dictionary:
	# An old oak does not wait for arbitrary mesh nodes before it branches. Every
	# supported non-bole axis owns a continuous, phyllotactic latent-bud bank.
	# Bud charge integrates along its real arclength and is amplified by actual
	# empty crown volume, so a thick bare stretch cannot silently remain dormant.
	var axis_data := annotate_derived_axes(nodes)
	var node_radii: Array = preliminary_pipe.get("nodeRadii", [])
	var branch_limit := maxi(1, int(dome_profile.get("branchSegmentBudget", MAX_OAK_BRANCH_SEGMENTS)))
	var remaining_budget := maxi(0, branch_limit - segments.size())
	var min_radius := maxf(0.050, float(dome_profile.get("derivedAxisMinimumForkRadius", 0.360)))
	var fine_min_radius := clampf(
		float(dome_profile.get("fineAxisMinimumForkRadius", min_radius)), 0.050, min_radius
	)
	var fine_minimum_order := clampi(int(dome_profile.get("fineAxisMinimumOrder", 2)), 1, 4)
	var support_range := maxf(0.05, float(dome_profile.get("derivedAxisSupportRange", 0.80)))
	var site_density := maxf(0.05, float(dome_profile.get("derivedAxisBudSiteDensity", 0.72)))
	var maximum_per_segment := maxi(1, int(dome_profile.get("derivedAxisMaximumBudsPerSegment", 1)))
	var minimum_potential := clampf(float(dome_profile.get("derivedAxisBudMinimumPotential", 0.20)), 0.0, 1.0)
	var candidate_plans: Array[Dictionary] = []
	var plans_by_child: Dictionary = {}
	var eligible_segments := 0
	var eligible_length := 0.0
	var greedy_space_sum := 0.0
	var lower_axis_bud_count := 0
	var fine_axis_bud_count := 0
	var axis_unit_sum := 0.0
	var crowding_rejections := 0
	var endpoint_rejections := 0
	var cone_competition_rejections := 0
	var resource_rejections := 0
	var allocated_resource_sum := 0.0
	var grown_metamer_count := 0
	var girth_eligible_length := 0.0
	var girth_weighted_bud_charge := 0.0
	var co_dominant_fork_count := 0
	var density_field := build_dynamic_crown_density_field(nodes, segments, desired_crown_points)
	var density_probes: Array = density_field.get("probes", [])
	var bud_charge_by_axis: Dictionary = {}
	var bud_serial_by_axis: Dictionary = {}
	var cumulative_bud_charge := 0.0
	var emitted_bud_charge := 0.0
	var observed_radius_by_order := {
		"primary": {"count": 0, "minimum": INF, "maximum": 0.0, "sum": 0.0},
		"secondary": {"count": 0, "minimum": INF, "maximum": 0.0, "sum": 0.0},
		"tertiary": {"count": 0, "minimum": INF, "maximum": 0.0, "sum": 0.0},
		"twig": {"count": 0, "minimum": INF, "maximum": 0.0, "sum": 0.0}
	}
	# Axis iteration is ordered by true arclength, not by graph insertion order.
	# That lets charge pass across segment boundaries instead of restarting every
	# time the SCA skeleton happens to add a node.
	var ordered_axis_segments: Array[Dictionary] = []
	for source_segment in segments:
		var source_child := int(source_segment.get("childNode", -1))
		if source_child < 0 or source_child >= nodes.size():
			continue
		var source_child_node: Dictionary = nodes[source_child]
		var source_axis := int(source_child_node.get("axisId", -1))
		if source_axis < 0:
			continue
		ordered_axis_segments.append({
			"segment": source_segment,
			"axisId": source_axis,
			"arclength": float(source_child_node.get("axisArclength", 0.0))
		})
	ordered_axis_segments.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_axis := int(left.get("axisId", -1))
		var right_axis := int(right.get("axisId", -1))
		if left_axis == right_axis:
			return float(left.get("arclength", 0.0)) < float(right.get("arclength", 0.0))
		return left_axis < right_axis
	)
	for segment_record in ordered_axis_segments:
		var segment: Dictionary = segment_record.get("segment", {})
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		var order := int(segment.get("order", 0))
		if order <= 0 or parent_index < 0 or child_index < 0 \
				or parent_index >= nodes.size() or child_index >= nodes.size() \
				or child_index >= node_radii.size():
			continue
		var parent: Dictionary = nodes[parent_index]
		var child: Dictionary = nodes[child_index]
		var axis_id := int(child.get("axisId", -1))
		if axis_id < 0:
			continue
		var start: Vector3 = parent.get("position", Vector3.ZERO)
		var end: Vector3 = child.get("position", Vector3.ZERO)
		var segment_length := start.distance_to(end)
		if segment_length < 0.08:
			continue
		var carrying_radius := float(node_radii[child_index])
		var order_name: String = String(["trunk", "primary", "secondary", "tertiary", "twig"][clampi(order, 0, 4)])
		if observed_radius_by_order.has(order_name):
			var observed: Dictionary = observed_radius_by_order[order_name]
			observed["count"] = int(observed.get("count", 0)) + 1
			observed["minimum"] = minf(float(observed.get("minimum", INF)), carrying_radius)
			observed["maximum"] = maxf(float(observed.get("maximum", 0.0)), carrying_radius)
			observed["sum"] = float(observed.get("sum", 0.0)) + carrying_radius
			observed_radius_by_order[order_name] = observed
		var fine_growth := order >= fine_minimum_order
		var segment_min_radius := fine_min_radius if fine_growth else min_radius
		if carrying_radius < segment_min_radius:
			continue
		# Pipe area is the developmental budget. This is deliberately evaluated
		# from the solved radius on the actual segment, so every viable portion of
		# a split trunk can participate without naming trunk levels or branch rows.
		var girth_ratio := maxf(1.0, carrying_radius / segment_min_radius)
		var girth_drive := clampf(
			pow(girth_ratio, maxf(0.05, float(dome_profile.get("derivedAxisBudGirthExponent", 0.72)))),
			1.0,
			maxf(1.0, float(dome_profile.get("derivedAxisMaximumGirthBudGain", 2.25)))
		)
		girth_eligible_length += segment_length
		var axis_length := maxf(0.001, float(child.get("axisLength", segment_length)))
		var end_arclength := float(child.get("axisArclength", segment_length))
		var start_arclength := maxf(0.0, end_arclength - segment_length)
		var support := clampf((carrying_radius - min_radius) / support_range, 0.0, 1.0)
		# Reaching the fork-radius threshold means a surface is biologically able
		# to initiate a bud. Radius above that threshold increases the probability
		# continuously, but a just-supported split is not treated as inert.
		var branchability := lerpf(0.38, 1.0, pow(support, 0.58))
		var axis_start_unit := clampf(start_arclength / axis_length, 0.0, 1.0)
		var post_fork_greed_gain := maxf(0.0, float(dome_profile.get("derivedAxisPostForkGreedGain", 0.65)))
		var post_fork_greed := 1.0 + post_fork_greed_gain * exp(-axis_start_unit * 3.8)
		# Structural axes exploit a strong junction first. Fine axes instead
		# differentiate toward their distal growing surface, preventing a thorny
		# brush at every major fork while still allowing them to fill their full
		# viable length through the continuous charge process.
		var axial_development_pressure := post_fork_greed
		if fine_growth:
			var fine_distal_unit := pow(
				axis_start_unit,
				maxf(0.05, float(dome_profile.get("fineAxisDistalPressureExponent", 0.58)))
			)
			axial_development_pressure = lerpf(
				maxf(0.01, float(dome_profile.get("fineAxisBaseBudPressure", 0.34))),
				maxf(0.01, float(dome_profile.get("fineAxisTipBudPressure", 1.16))),
				fine_distal_unit
			)
		var seasonal_vigor := 1.0 / sqrt(float(season_index + 1))
		var midpoint := start.lerp(end, 0.5)
		var local_density_deficit := sample_crown_density_deficit(
			midpoint, density_probes, CROWN_INFLUENCE_DISTANCE * 0.96
		)
		# Charge is integrated over arclength and carries forward to the next
		# segment of this same axis. It therefore fills a supported barren run even
		# when no one raw segment happens to cross an arbitrary site-count boundary.
		# A latent-bud bank is driven by the parent axis's material capacity and
		# continuous arclength. Crown volume only guides which outward direction a
		# surviving bud prefers; it cannot make a thick, healthy split sterile.
		var segment_site_density := maxf(
			0.05,
			float(dome_profile.get("fineAxisBudSiteDensity", site_density)) if fine_growth else site_density
		)
		var segment_maximum_buds := maxi(
			1,
			int(dome_profile.get("fineAxisMaximumBudsPerSegment", maximum_per_segment)) if fine_growth else maximum_per_segment
		)
		var charge_gain := segment_length * segment_site_density * branchability * girth_drive \
			* axial_development_pressure * seasonal_vigor
		girth_weighted_bud_charge += charge_gain
		var stored_charge := float(bud_charge_by_axis.get(
			axis_id, stable_unit("continuous-axis-bud-phase:%d:%d:%d" % [seed, axis_id, season_index]) * 0.82
		))
		var charge_after := stored_charge + charge_gain
		var site_count := clampi(floori(charge_after) - floori(stored_charge), 0, segment_maximum_buds)
		bud_charge_by_axis[axis_id] = charge_after - float(site_count)
		cumulative_bud_charge += charge_gain
		emitted_bud_charge += float(site_count)
		if site_count == 0:
			continue
		var first_threshold := floorf(stored_charge) + 1.0
		var bud_serial := int(bud_serial_by_axis.get(axis_id, 0))
		for site_slot in range(site_count):
			# Bud positions emerge where the integrated charge crosses its next
			# threshold, with only a small seed-derived developmental jitter. This is
			# a continuous bud process, not a prescribed row of branch sites.
			var threshold_unit := (first_threshold + float(site_slot) - stored_charge) / maxf(0.001, charge_gain)
			var local_unit := clampf(
				threshold_unit + stable_signed("continuous-axis-position:%d:%d:%d" % [seed, axis_id, bud_serial + site_slot]) * 0.065,
				0.055, 0.945
			)
			var position := start.lerp(end, local_unit)
			var axis_unit := clampf((start_arclength + segment_length * local_unit) / axis_length, 0.0, 1.0)
			var collar_release := clampf((axis_unit - 0.004) / 0.032, 0.0, 1.0)
			var incoming := (end - start).normalized()
			if incoming.length_squared() < 0.0001:
				incoming = child.get("direction", Vector3.UP)
			var outward := Vector3(position.x - crown_center.x, 0.0, position.z - crown_center.z)
			if outward.length_squared() < 0.001:
				outward = inherited_dome_axis(child, position, crown_center, incoming, crown_phase)
			else:
				outward = outward.normalized()
			var greedy_direction := choose_greedy_axis_bud_direction(
				position, outward, incoming, density_probes, crown_center, crown_radii,
				crown_phase, seed, child_index, bud_serial + site_slot
			)
			var heading: Vector3 = greedy_direction.get("heading", outward)
			var bud_axis: Vector3 = greedy_direction.get("axis", outward)
			var free_space := float(greedy_direction.get("availability", 0.0))
			var radial_exposure := clampf(normalized_crown_horizontal_radius(position, crown_center, crown_radii), 0.0, 1.0)
			var crown_bottom := crown_center.y - crown_radii.y
			var vertical_exposure := clampf((position.y - crown_bottom) / maxf(0.1, crown_radii.y * 2.0), 0.0, 1.0)
			var exposure := lerpf(0.72, 1.0, radial_exposure * 0.62 + vertical_exposure * 0.38)
			var split_potential := collar_release * branchability * girth_drive * exposure \
				* lerpf(0.72, 1.0, free_space) * axial_development_pressure
			if split_potential < minimum_potential or incoming.dot(heading) > 0.91:
				crowding_rejections += 1
				continue
			# Branch order is an emergent developmental state, not an authored tier.
			# Under Leonardo's area rule, a sufficiently stout axis can carry a
			# co-dominant sibling (same order). The probability fades toward the tip,
			# so mature oaks ramify their load-bearing core without turning every
			# terminal twig into a second trunk.
			var co_dominant_threshold := maxf(1.01, float(dome_profile.get("derivedAxisCoDominantGirthRatio", 1.72)))
			var co_dominant_maximum_order := clampi(int(dome_profile.get("derivedAxisCoDominantMaximumOrder", 2)), 1, 4)
			var co_dominant_probability := clampf(
				(girth_ratio - co_dominant_threshold) / maxf(0.01, co_dominant_threshold),
				0.0,
				1.0
			) * pow(1.0 - axis_unit, 0.62) * clampf(
				float(dome_profile.get("derivedAxisCoDominantMaximumProbability", 0.68)), 0.0, 1.0
			)
			var co_dominant := not fine_growth and order <= co_dominant_maximum_order and stable_unit(
				"continuous-axis-co-dominant:%d:%d:%d" % [seed, child_index, bud_serial + site_slot]
			) < co_dominant_probability
			var child_order := order if co_dominant else mini(4, order + 1)
			heading = constrain_to_outward_dome(
				heading, bud_axis, child_order,
				normalized_crown_horizontal_radius(position, crown_center, crown_radii), dome_profile
			)
			# Branch span follows actual pipe-model girth rather than the normalized
			# threshold surplus. A branch that is thick enough to fork is therefore
			# never rendered as a tiny spur; more carrying radius yields a longer
			# lateral according to the same allometric curve.
			var minimum_span := maxf(
				0.35,
				float(dome_profile.get("fineAxisMinimumForkSpan", 1.35)) if fine_growth \
				else float(dome_profile.get("derivedAxisMinimumForkSpan", 2.85))
			)
			var span_exponent := maxf(
				0.10,
				float(dome_profile.get("fineAxisSpanRadiusExponent", 0.56)) if fine_growth \
				else float(dome_profile.get("derivedAxisSpanRadiusExponent", 0.60))
			)
			var maximum_span := crown_radii.x * (
				clampf(float(dome_profile.get("fineAxisMaximumSpanFraction", 0.18)), 0.05, 0.40) if fine_growth else 0.34
			)
			var allometric_span := minimum_span * pow(maxf(1.0, carrying_radius / segment_min_radius), span_exponent)
			var length := clampf(
				allometric_span * lerpf(0.86, 1.16, free_space) \
					* lerpf(0.90, 1.10, stable_unit("continuous-axis-length:%d:%d:%d" % [seed, child_index, site_slot])),
				minimum_span,
				maximum_span
			)
			var endpoint := position + heading * length
			if not point_inside_crown(endpoint, crown_center, crown_radii, crown_phase, 1.08) \
					or not endpoint_respects_outward_dome_frontier(
						endpoint, position, crown_center, crown_radii, bud_axis, child_order, dome_profile
					):
				endpoint_rejections += 1
				continue
			if endpoint_too_close(endpoint, nodes, child_index):
				crowding_rejections += 1
				continue
			candidate_plans.append({
				"position": position,
				"heading": heading,
				"sourceHeading": incoming,
				"axis": bud_axis,
				"endpoint": endpoint,
				"order": child_order,
				"stratumBias": clampf(vertical_exposure * 2.0 - 1.0, -1.0, 1.0),
				"axisId": axis_id,
				"axisArclength": start_arclength + segment_length * local_unit,
				"edgeUnit": local_unit,
				"axisUnit": axis_unit,
				"coneReach": length,
				"coneHalfAngle": lerpf(0.36, 0.62, clampf(split_potential, 0.0, 1.0)),
				"score": split_potential * lerpf(0.82, 1.18, free_space) \
					+ stable_unit("continuous-axis-candidate-tie:%d:%d:%d" % [seed, child_index, site_slot]) * 0.0001,
				"resourceWeight": split_potential * lerpf(0.55, 1.25, free_space),
				"freeSpace": free_space,
				"densityDeficit": local_density_deficit,
				"segmentLength": segment_length,
				"childIndex": child_index,
				"carryingRadius": carrying_radius,
				"girthDrive": girth_drive,
				"coDominant": co_dominant,
				"fineGrowth": fine_growth,
				"minimumSpan": minimum_span,
				"spanExponent": span_exponent,
				"maximumSpan": maximum_span,
				"hydraulicScale": float(dome_profile.get("fineAxisHydraulicResourceScale", 8.0)) if fine_growth else float(dome_profile.get("derivedAxisHydraulicResourceScale", 16.0)),
				"resourcePerMetamer": float(dome_profile.get("fineAxisResourcePerMetamer", 1.35)) if fine_growth else float(dome_profile.get("derivedAxisResourcePerMetamer", 5.5)),
				"minimumMetamers": int(dome_profile.get("fineAxisMinimumMetamers", 2)) if fine_growth else int(dome_profile.get("derivedAxisMinimumMetamers", 2)),
				"maximumMetamers": int(dome_profile.get("fineAxisMaximumMetamers", 3)) if fine_growth else int(dome_profile.get("derivedAxisMaximumMetamers", 4))
			})
		bud_serial_by_axis[axis_id] = bud_serial + site_count
	# The field may nominate many sites on one stout axis. Resolve that competition
	# in three-dimensional crown space, rather than by a hand-tuned one-dimensional
	# spacing rule along the parent. Nearby sites may coexist when their growth
	# cones open into different portions of the crown.
	candidate_plans.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("score", 0.0)) > float(right.get("score", 0.0))
	)
	var cone_selected: Array[Dictionary] = []
	for candidate_value in candidate_plans:
		var candidate: Dictionary = candidate_value
		var blocked := false
		for existing_value in cone_selected:
			var existing: Dictionary = existing_value
			if growth_cones_compete(candidate, existing):
				blocked = true
				break
		if blocked:
			cone_competition_rejections += 1
			continue
		cone_selected.append(candidate)

	# A non-bole axis divides its actual pipe-model carrying capacity between the
	# surviving buds. The pipe-model area is a finite bank: a candidate must earn
	# enough of it to establish a real branch, rather than receiving a cosmetic
	# minimum spur. This yields fewer, longer laterals on a stout branch.
	var candidates_by_axis: Dictionary = {}
	var axis_ids: Array[int] = []
	for candidate_value in cone_selected:
		var candidate: Dictionary = candidate_value
		var axis_id := int(candidate.get("axisId", -1))
		if not candidates_by_axis.has(axis_id):
			candidates_by_axis[axis_id] = []
			axis_ids.append(axis_id)
		var axis_candidates: Array = candidates_by_axis.get(axis_id, [])
		axis_candidates.append(candidate)
		candidates_by_axis[axis_id] = axis_candidates
	axis_ids.sort()
	for axis_id in axis_ids:
		var axis_candidates: Array = candidates_by_axis.get(axis_id, [])
		axis_candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
			return float(left.get("score", 0.0)) > float(right.get("score", 0.0))
		)
		var maximum_radius := min_radius
		for candidate_value in axis_candidates:
			var candidate: Dictionary = candidate_value
			maximum_radius = maxf(maximum_radius, float(candidate.get("carryingRadius", min_radius)))
		# Radius squared is the available hydraulic/structural area. It is spent
		# once per season, in score order, and never duplicated among every latent
		# bud on the same axis.
		var axis_hydraulic_scale := maxf(0.01, float((axis_candidates[0] as Dictionary).get("hydraulicScale", 16.0)))
		var remaining_axis_resource := axis_hydraulic_scale * PI * maximum_radius * maximum_radius
		for candidate_value in axis_candidates:
			if remaining_budget <= 1:
				break
			var candidate: Dictionary = candidate_value
			var axis_unit := clampf(float(candidate.get("axisUnit", 1.0)), 0.0, 1.0)
			var lateral_priority := lerpf(
				float(dome_profile.get("derivedAxisLateralPriorityAtBase", 0.70)),
				float(dome_profile.get("derivedAxisLateralPriorityAtTip", 0.44)),
				axis_unit
			)
			var girth_drive := maxf(1.0, float(candidate.get("girthDrive", 1.0)))
			var resource_per_metamer := maxf(0.10, float(candidate.get("resourcePerMetamer", 5.5)))
			var minimum_metamers := maxi(2, int(candidate.get("minimumMetamers", 2)))
			var maximum_metamers := maxi(minimum_metamers, int(candidate.get("maximumMetamers", 4)))
			# Establishment has a hard biological minimum: wood that cannot fund two
			# metamers remains a dormant bud. Larger parent axes fund larger child
			# axes, which makes a mature oak recursively occupy its own crown rather
			# than decorating thick limbs with isolated spikes.
			var establishment_resource := resource_per_metamer * float(minimum_metamers) \
				* lerpf(0.94, 1.12, lateral_priority)
			if remaining_axis_resource < establishment_resource:
				resource_rejections += 1
				continue
			var allocation_target := establishment_resource * lerpf(
				1.0, 1.20, float(candidate.get("freeSpace", 0.0))
			) * sqrt(girth_drive)
			var allocated_resource := minf(allocation_target, remaining_axis_resource)
			remaining_axis_resource -= allocated_resource
			var metamer_count := clampi(
				floori(allocated_resource / resource_per_metamer), minimum_metamers, maximum_metamers
			)
			var candidate_minimum_radius := fine_min_radius if bool(candidate.get("fineGrowth", false)) else min_radius
			var carrying_radius := maxf(candidate_minimum_radius, float(candidate.get("carryingRadius", candidate_minimum_radius)))
			var minimum_span := maxf(0.35, float(candidate.get("minimumSpan", 2.85)))
			var span_exponent := maxf(0.10, float(candidate.get("spanExponent", 0.60)))
			var maximum_span := maxf(minimum_span, float(candidate.get("maximumSpan", crown_radii.x * 0.34)))
			var allometric_span := minimum_span * pow(carrying_radius / candidate_minimum_radius, span_exponent)
			var total_span := clampf(
				maxf(allometric_span, allocated_resource * 0.92) * lerpf(0.92, 1.16, float(candidate.get("freeSpace", 0.0))),
				minimum_span,
				maximum_span
			)
			var shoot_points := build_resource_allocated_shoot_points(
				candidate.get("position", Vector3.ZERO), candidate.get("heading", Vector3.RIGHT),
				candidate.get("axis", Vector3.RIGHT), candidate.get("sourceHeading", Vector3.UP),
				total_span, metamer_count, crown_center, crown_radii, crown_phase,
				int(candidate.get("order", 2)), dome_profile, seed,
				int(candidate.get("childIndex", -1)), int(candidate.get("axisArclength", 0.0) * 1000.0)
			)
			if shoot_points.is_empty():
				resource_rejections += 1
				continue
			var budget_cost := 1 + shoot_points.size()
			if budget_cost > remaining_budget:
				resource_rejections += 1
				continue
			candidate["shootPoints"] = shoot_points
			candidate["endpoint"] = shoot_points.back()
			candidate["allocatedResource"] = allocated_resource
			candidate["metamerCount"] = shoot_points.size()
			var child_index := int(candidate.get("childIndex", -1))
			if child_index < 0:
				resource_rejections += 1
				continue
			var child_plans: Array = plans_by_child.get(child_index, [])
			child_plans.append(candidate)
			plans_by_child[child_index] = child_plans
			eligible_segments += 1
			eligible_length += float(candidate.get("segmentLength", 0.0))
			greedy_space_sum += float(candidate.get("freeSpace", 0.0))
			axis_unit_sum += axis_unit
			if axis_unit <= 0.25:
				lower_axis_bud_count += 1
			if bool(candidate.get("fineGrowth", false)):
				fine_axis_bud_count += 1
			allocated_resource_sum += allocated_resource
			grown_metamer_count += shoot_points.size()
			if bool(candidate.get("coDominant", false)):
				co_dominant_fork_count += 1
			remaining_budget -= budget_cost
	for order_name in observed_radius_by_order:
		var observed: Dictionary = observed_radius_by_order[order_name]
		# A seasonal pass can legitimately have no axes of a fine order. Keep the
		# diagnostic finite so its report remains valid JSON; zero says exactly what
		# happened, whereas INF made otherwise valid runtime PoCs unparsable.
		if int(observed.get("count", 0)) == 0:
			observed["minimum"] = 0.0
			observed_radius_by_order[order_name] = observed
	var rebuilt := rebuild_graph_with_continuous_axis_buds(nodes, segments, plans_by_child)
	return {
		"rule": "continuous_derived_axis_resource_competition_seasons",
		"derivedAxisCount": int(axis_data.get("axisCount", 0)),
		"minimumForkRadius": min_radius,
		"eligibleSegmentCount": eligible_segments,
		"eligibleDerivedAxisLength": eligible_length,
		"germinatedBudCount": int(rebuilt.get("germinatedBudCount", 0)),
		"continuousSegmentSplitCount": int(rebuilt.get("continuousSegmentSplitCount", 0)),
		"meanGreedySpace": greedy_space_sum / float(maxi(1, eligible_segments)),
		"postForkGreedGain": maxf(0.0, float(dome_profile.get("derivedAxisPostForkGreedGain", 0.65))),
		"meanAxisUnit": axis_unit_sum / float(maxi(1, eligible_segments)),
		"lowerAxisBudCount": lower_axis_bud_count,
		"fineAxisBudCount": fine_axis_bud_count,
		"candidatePlanCount": candidate_plans.size(),
		"densityProbeCount": density_probes.size(),
		"meanCrownDensityDeficit": float(density_field.get("meanDeficit", 0.0)),
		"integratedBudCharge": cumulative_bud_charge,
		"emittedBudCharge": emitted_bud_charge,
		"coneCompetitionRejections": cone_competition_rejections,
		"resourceRejections": resource_rejections,
		"allocatedResource": allocated_resource_sum,
		"grownMetamerCount": grown_metamer_count,
		"girthEligibleLength": girth_eligible_length,
		"girthWeightedBudCharge": girth_weighted_bud_charge,
		"coDominantForkCount": co_dominant_fork_count,
		"growthSeason": season_index + 1,
		"crowdingRejections": crowding_rejections,
		"endpointRejections": endpoint_rejections,
		"remainingBranchBudget": remaining_budget,
		"observedRadiusByOrder": observed_radius_by_order
	}

func build_dynamic_crown_density_field(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	desired_crown_points: Array
) -> Dictionary:
	# Desired points describe the species crown volume. Existing wood contributes
	# an order-weighted occupancy kernel; terminal wood gets a broader kernel that
	# represents the foliage it can support. The result is a world-space field, so
	# it has no privileged camera-facing or "back" direction.
	# The field uses a sparse spatial index. Sampling every desired point against
	# every branch is correct but quadratic; indexing each segment's finite kernel
	# preserves the exact local rule while keeping density evaluation bounded.
	var occupancy_cells: Dictionary = {}
	for segment in segments:
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		if parent_index < 0 or child_index < 0 or parent_index >= nodes.size() or child_index >= nodes.size():
			continue
		var order := clampi(int(segment.get("order", 0)), 0, 4)
		if order <= 0:
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = nodes[child_index].get("position", Vector3.ZERO)
		var child: Dictionary = nodes[child_index]
		var terminal := (child.get("children", []) as Array).is_empty()
		var spread: float = float([0.0, 1.70, 1.34, 0.94, 0.62][order])
		var strength: float = float([0.0, 0.44, 0.54, 0.66, 0.74][order])
		if terminal and order >= 2:
			spread *= 1.70
			strength = minf(0.94, strength * 1.22)
		var entry := {"start": start, "end": end, "spread": spread, "strength": strength}
		var minimum := start.min(end) - Vector3.ONE * spread
		var maximum := start.max(end) + Vector3.ONE * spread
		var minimum_cell := density_field_cell(minimum)
		var maximum_cell := density_field_cell(maximum)
		for cell_x in range(int(minimum_cell.x), int(maximum_cell.x) + 1):
			for cell_y in range(int(minimum_cell.y), int(maximum_cell.y) + 1):
				for cell_z in range(int(minimum_cell.z), int(maximum_cell.z) + 1):
					var key := density_field_cell_key(Vector3i(cell_x, cell_y, cell_z))
					var entries: Array = occupancy_cells.get(key, [])
					entries.append(entry)
					occupancy_cells[key] = entries
	var probes: Array[Dictionary] = []
	var deficit_sum := 0.0
	var sample_count := mini(OAK_DENSITY_FIELD_SAMPLE_BUDGET, desired_crown_points.size())
	for sample_index in range(sample_count):
		# Equally spaced index strata sample the already seed-randomized 3D crown
		# distribution without privileging its front, back, or one azimuth sector.
		var source_index := clampi(
			floori((float(sample_index) + 0.5) * float(desired_crown_points.size()) / float(maxi(1, sample_count))),
			0,
			desired_crown_points.size() - 1
		)
		var desired_value = desired_crown_points[source_index]
		if not (desired_value is Vector3):
			continue
		var desired: Vector3 = desired_value
		var occupancy := 0.0
		var cell_entries: Array = occupancy_cells.get(density_field_cell_key(density_field_cell(desired)), [])
		for entry_value in cell_entries:
			var entry: Dictionary = entry_value
			var spread := float(entry.get("spread", 1.0))
			var distance_squared := point_segment_distance_squared(
				desired, entry.get("start", Vector3.ZERO), entry.get("end", Vector3.ZERO)
			)
			var influence := float(entry.get("strength", 0.0)) * exp(
				-distance_squared / maxf(0.01, 2.0 * spread * spread)
			)
			occupancy = maxf(occupancy, influence)
			if occupancy >= 0.985:
				break
		var deficit := clampf(1.0 - occupancy, 0.0, 1.0)
		deficit_sum += deficit
		if deficit > 0.025:
			probes.append({"position": desired, "deficit": deficit})
	return {
		"probes": probes,
		"sampleCount": sample_count,
		"meanDeficit": deficit_sum / float(maxi(1, sample_count))
	}

func density_field_cell(position: Vector3) -> Vector3i:
	return Vector3i(
		floori(position.x / OAK_DENSITY_FIELD_CELL_SIZE),
		floori(position.y / OAK_DENSITY_FIELD_CELL_SIZE),
		floori(position.z / OAK_DENSITY_FIELD_CELL_SIZE)
	)

func density_field_cell_key(cell: Vector3i) -> String:
	return "%d:%d:%d" % [cell.x, cell.y, cell.z]

func sample_crown_density_deficit(position: Vector3, density_probes: Array, radius: float) -> float:
	var weighted_deficit := 0.0
	var total_weight := 0.0
	var squared_radius := radius * radius
	for probe_value in density_probes:
		if not (probe_value is Dictionary):
			continue
		var probe: Dictionary = probe_value
		var probe_position: Vector3 = probe.get("position", Vector3.ZERO)
		var distance_squared := position.distance_squared_to(probe_position)
		if distance_squared > squared_radius:
			continue
		var unit := sqrt(distance_squared) / maxf(0.001, radius)
		var weight := pow(1.0 - unit, 0.72)
		weighted_deficit += float(probe.get("deficit", 0.0)) * weight
		total_weight += weight
	return weighted_deficit / maxf(0.0001, total_weight)

func point_segment_distance_squared(point: Vector3, start: Vector3, end: Vector3) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared < 0.000001:
		return point.distance_squared_to(start)
	var projection := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * projection)

func summarize_derived_axis_seasons(seasons: Array[Dictionary]) -> Dictionary:
	# The report keeps both the aggregate and each seasonal pass. This makes the
	# grammar inspectable: a review can distinguish a genuinely resource-limited
	# second season from a fixed branch-count recipe.
	var summary := {
		"rule": "continuous_derived_axis_resource_competition_seasons",
		"seasonCount": seasons.size(),
		"derivedAxisCount": 0,
		"minimumForkRadius": 0.0,
		"eligibleSegmentCount": 0,
		"eligibleDerivedAxisLength": 0.0,
		"germinatedBudCount": 0,
		"continuousSegmentSplitCount": 0,
		"lowerAxisBudCount": 0,
		"fineAxisBudCount": 0,
		"candidatePlanCount": 0,
		"densityProbeCount": 0,
		"meanCrownDensityDeficit": 0.0,
		"integratedBudCharge": 0.0,
		"emittedBudCharge": 0.0,
		"coneCompetitionRejections": 0,
		"resourceRejections": 0,
		"allocatedResource": 0.0,
		"grownMetamerCount": 0,
		"girthEligibleLength": 0.0,
		"girthWeightedBudCharge": 0.0,
		"coDominantForkCount": 0,
		"meanGreedySpace": 0.0,
		"meanAxisUnit": 0.0,
		"remainingBranchBudget": 0,
		"postForkGreedGain": 0.0,
		"seasons": seasons
	}
	var greedy_weight := 0
	var axis_weight := 0
	for season in seasons:
		var eligible := int(season.get("eligibleSegmentCount", 0))
		var buds := int(season.get("germinatedBudCount", 0))
		summary["derivedAxisCount"] = max(
			int(summary.get("derivedAxisCount", 0)), int(season.get("derivedAxisCount", 0))
		)
		summary["minimumForkRadius"] = maxf(
			float(summary.get("minimumForkRadius", 0.0)), float(season.get("minimumForkRadius", 0.0))
		)
		for key in [
			"eligibleSegmentCount", "germinatedBudCount", "continuousSegmentSplitCount",
			"lowerAxisBudCount", "fineAxisBudCount", "candidatePlanCount", "coneCompetitionRejections",
			"resourceRejections", "grownMetamerCount", "densityProbeCount"
		]:
			summary[key] = int(summary.get(key, 0)) + int(season.get(key, 0))
		for key in [
			"eligibleDerivedAxisLength", "allocatedResource", "integratedBudCharge",
			"emittedBudCharge", "girthEligibleLength", "girthWeightedBudCharge"
		]:
			summary[key] = float(summary.get(key, 0.0)) + float(season.get(key, 0.0))
		summary["coDominantForkCount"] = int(summary.get("coDominantForkCount", 0)) \
			+ int(season.get("coDominantForkCount", 0))
		summary["remainingBranchBudget"] = int(season.get("remainingBranchBudget", 0))
		summary["postForkGreedGain"] = float(season.get("postForkGreedGain", 0.0))
		greedy_weight += eligible
		axis_weight += eligible
		summary["meanGreedySpace"] = float(summary.get("meanGreedySpace", 0.0)) \
			+ float(season.get("meanGreedySpace", 0.0)) * float(eligible)
		summary["meanAxisUnit"] = float(summary.get("meanAxisUnit", 0.0)) \
			+ float(season.get("meanAxisUnit", 0.0)) * float(eligible)
		summary["meanCrownDensityDeficit"] = maxf(
			float(summary.get("meanCrownDensityDeficit", 0.0)),
			float(season.get("meanCrownDensityDeficit", 0.0))
		)
	if greedy_weight > 0:
		summary["meanGreedySpace"] = float(summary.get("meanGreedySpace", 0.0)) / float(greedy_weight)
	if axis_weight > 0:
		summary["meanAxisUnit"] = float(summary.get("meanAxisUnit", 0.0)) / float(axis_weight)
	return summary

func growth_cones_compete(candidate: Dictionary, existing: Dictionary) -> bool:
	# Buds suppress one another only when their forward cones overlap. This lets a
	# stout limb exploit its entire circumference instead of selecting a single
	# arbitrary successor along an edge.
	var candidate_position: Vector3 = candidate.get("position", Vector3.ZERO)
	var existing_position: Vector3 = existing.get("position", Vector3.ZERO)
	var separation := existing_position - candidate_position
	var distance := separation.length()
	var candidate_reach := maxf(0.10, float(candidate.get("coneReach", 1.0)))
	var existing_reach := maxf(0.10, float(existing.get("coneReach", 1.0)))
	if distance > minf(candidate_reach, existing_reach) * 0.82:
		return false
	var candidate_heading: Vector3 = candidate.get("heading", Vector3.RIGHT)
	var existing_heading: Vector3 = existing.get("heading", Vector3.RIGHT)
	if candidate_heading.length_squared() < 0.0001 or existing_heading.length_squared() < 0.0001:
		return false
	candidate_heading = candidate_heading.normalized()
	existing_heading = existing_heading.normalized()
	var combined_half_angle := float(candidate.get("coneHalfAngle", 0.45)) + float(existing.get("coneHalfAngle", 0.45))
	var angular_overlap := candidate_heading.dot(existing_heading) > cos(minf(PI * 0.86, combined_half_angle))
	if not angular_overlap:
		return false
	if distance < minf(candidate_reach, existing_reach) * 0.18:
		return true
	var toward_existing := separation / maxf(0.001, distance)
	var reciprocal_forward := candidate_heading.dot(toward_existing) > 0.16 \
		and existing_heading.dot(-toward_existing) > 0.16
	return reciprocal_forward

func build_resource_allocated_shoot_points(
	start: Vector3,
	heading: Vector3,
	bud_axis: Vector3,
	parent_heading: Vector3,
	total_span: float,
	metamer_count: int,
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	child_order: int,
	dome_profile: Dictionary,
	seed: int,
	child_index: int,
	stable_site: int
) -> Array[Vector3]:
	# A resource allocation grows a short metamer chain, not an isolated authored
	# spur. Each step keeps radial momentum, responds to the local dome, and bends
	# only through stable seed-derived variation.
	var points: Array[Vector3] = []
	var previous := start
	var direction := heading.normalized() if heading.length_squared() > 0.0001 else bud_axis.normalized()
	var segment_span := total_span / float(maxi(1, metamer_count))
	for metamer_index in range(metamer_count):
		var local_radial := Vector3(previous.x - crown_center.x, 0.0, previous.z - crown_center.z)
		if local_radial.length_squared() < 0.0001:
			local_radial = bud_axis
		else:
			local_radial = local_radial.normalized()
		var crown_bottom := crown_center.y - crown_radii.y
		var crown_unit := clampf((previous.y - crown_bottom) / maxf(0.10, crown_radii.y * 2.0), 0.0, 1.0)
		var noise := stable_noise_vector(seed, child_index * 31 + stable_site, metamer_index) * 0.055
		var upward_bias := lerpf(-0.02, 0.13, crown_unit)
		var proposed := (
			direction * 0.79 + local_radial * 0.14 + bud_axis * 0.07
			+ Vector3.UP * upward_bias + noise
		).normalized()
		proposed = constrain_to_outward_dome(
			proposed, local_radial, child_order,
			normalized_crown_horizontal_radius(previous, crown_center, crown_radii), dome_profile
		)
		proposed = constrain_branch_turn(proposed, direction if metamer_index > 0 else parent_heading, child_order, dome_profile)
		var endpoint := previous + proposed * segment_span
		if not point_inside_crown(endpoint, crown_center, crown_radii, crown_phase, 1.08) \
				or not endpoint_respects_outward_dome_frontier(
					endpoint, previous, crown_center, crown_radii, local_radial, child_order, dome_profile
				):
			break
		points.append(endpoint)
		previous = endpoint
		direction = proposed
	return points

func choose_greedy_axis_bud_direction(
	position: Vector3,
	outward: Vector3,
	incoming: Vector3,
	density_probes: Array,
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	seed: int,
	child_index: int,
	site_slot: int
) -> Dictionary:
	# Sample a seed-phyllotactic field over the outward hemisphere. The number of
	# samples is an integration resolution only: the chosen direction comes from
	# crown-space availability, never from a fixed left/right branch layout.
	const sector_count := 9
	var best_score := -INF
	var best_axis := outward
	var best_heading := outward
	var best_availability := 0.0
	var phyllotactic_phase := stable_unit(
		"continuous-axis-phyllotaxis:%d:%d:%d" % [seed, child_index, site_slot]
	)
	for sector_index in range(sector_count):
		var sector_unit := fposmod(
			phyllotactic_phase + float(sector_index) * 0.618033988749895,
			1.0
		)
		var sector_angle := lerpf(-1.25, 1.25, sector_unit) \
			+ stable_signed("continuous-axis-sector:%d:%d:%d:%d" % [seed, child_index, site_slot, sector_index]) * 0.055
		var axis := outward.rotated(Vector3.UP, sector_angle).normalized()
		var crown_bottom := crown_center.y - crown_radii.y
		var crown_unit := clampf((position.y - crown_bottom) / maxf(0.1, crown_radii.y * 2.0), 0.0, 1.0)
		var pitch := lerpf(-0.075, 0.18, crown_unit)
		var heading := (axis * 0.66 + incoming * 0.22 + Vector3.UP * pitch).normalized()
		var attraction_score := 0.0
		for probe_value in density_probes:
			if not (probe_value is Dictionary):
				continue
			var probe: Dictionary = probe_value
			var attraction: Vector3 = probe.get("position", Vector3.ZERO)
			var deficit := float(probe.get("deficit", 0.0))
			if deficit <= 0.0:
				continue
			var to_attraction := attraction - position
			var distance := to_attraction.length()
			if distance < 0.75 or distance > CROWN_INFLUENCE_DISTANCE * 1.18:
				continue
			var direction := to_attraction / distance
			var forward := heading.dot(direction)
			if forward <= 0.28:
				continue
			var horizontal := Vector3(direction.x, 0.0, direction.z)
			if horizontal.length_squared() > 0.0001 and axis.dot(horizontal.normalized()) < -0.06:
				continue
			attraction_score += deficit * pow(forward, 2.4) \
				* pow(1.0 - distance / (CROWN_INFLUENCE_DISTANCE * 1.18), 0.64)
		var separation := clampf((1.0 - incoming.dot(heading)) / 0.42, 0.0, 1.0)
		# Desired crown samples only choose among viable outward headings. They do
		# not decide whether the parent has permission to branch: that decision was
		# made from the parent axis's pipe radius and arclength above. The non-zero
		# floor prevents an already leafy foreground from suppressing a healthy axis
		# that must continue building the rest of the oak.
		var availability := lerpf(0.58, 1.0, clampf(attraction_score / 2.25, 0.0, 1.0))
		var tie_break := stable_unit("continuous-axis-sector-tie:%d:%d:%d:%d" % [seed, child_index, site_slot, sector_index]) * 0.0001
		var score := availability * lerpf(0.34, 1.0, separation) + tie_break
		if score > best_score:
			best_score = score
			best_axis = axis
			best_heading = heading
			best_availability = availability
	return {"heading": best_heading, "axis": best_axis, "availability": best_availability}

func rebuild_graph_with_continuous_axis_buds(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	plans_by_child: Dictionary
) -> Dictionary:
	# Rebuild in topological order so a junction inserted in the middle of an old
	# edge is a genuine parent of both its new lateral and the old continuation.
	# This keeps the graph connected and preserves the reverse-topological pipe
	# solve without a special-case mesh seam.
	if plans_by_child.is_empty():
		return {"germinatedBudCount": 0, "continuousSegmentSplitCount": 0, "grownMetamerCount": 0}
	var source_nodes: Array = nodes.duplicate(true)
	var rebuilt_nodes: Array[Dictionary] = []
	var rebuilt_segments: Array[Dictionary] = []
	var old_to_new: Array[int] = []
	var grown_metamer_count := 0
	old_to_new.resize(source_nodes.size())
	for old_index in range(source_nodes.size()):
		var source: Dictionary = source_nodes[old_index]
		var parent_index := int(source.get("parent", -1))
		var rebuilt_parent := -1 if parent_index < 0 else old_to_new[parent_index]
		if plans_by_child.has(old_index):
			var edge_plans: Array = plans_by_child[old_index]
			edge_plans.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
				return float(left.get("edgeUnit", 0.0)) < float(right.get("edgeUnit", 0.0))
			)
			var continuation_parent := rebuilt_parent
			for plan_value in edge_plans:
				var plan: Dictionary = plan_value
				var junction_index := append_cloned_growth_node(
					rebuilt_nodes, rebuilt_segments, source, continuation_parent,
					plan.get("position", source.get("position", Vector3.ZERO))
				)
				var shoot_parent := junction_index
				var shoot_points: Array = plan.get("shootPoints", [])
				for point_value in shoot_points:
					var endpoint: Vector3 = point_value
					var parent_position: Vector3 = rebuilt_nodes[shoot_parent].get("position", Vector3.ZERO)
					var bud_direction := (endpoint - parent_position).normalized()
					var bud_index := append_node(
						rebuilt_nodes, rebuilt_segments, endpoint, shoot_parent,
						int(plan.get("order", 2)), bud_direction
					)
					var bud: Dictionary = rebuilt_nodes[bud_index]
					bud["domeAxis"] = plan.get("axis", Vector3.RIGHT)
					bud["domeHeading"] = bud_direction
					bud["stratumBias"] = float(plan.get("stratumBias", 0.0))
					rebuilt_nodes[bud_index] = bud
					shoot_parent = bud_index
					grown_metamer_count += 1
				continuation_parent = junction_index
			old_to_new[old_index] = append_cloned_growth_node(
				rebuilt_nodes, rebuilt_segments, source, continuation_parent,
				source.get("position", Vector3.ZERO)
			)
		else:
			old_to_new[old_index] = append_cloned_growth_node(
				rebuilt_nodes, rebuilt_segments, source, rebuilt_parent,
				source.get("position", Vector3.ZERO)
			)
	nodes.clear()
	nodes.append_array(rebuilt_nodes)
	segments.clear()
	segments.append_array(rebuilt_segments)
	return {
		"germinatedBudCount": count_growth_plans(plans_by_child),
		"continuousSegmentSplitCount": count_growth_plans(plans_by_child),
		"grownMetamerCount": grown_metamer_count
	}

func count_growth_plans(plans_by_child: Dictionary) -> int:
	var count := 0
	for edge_plans_value in plans_by_child.values():
		var edge_plans: Array = edge_plans_value
		count += edge_plans.size()
	return count

func append_cloned_growth_node(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	source: Dictionary,
	parent_index: int,
	position: Vector3
) -> int:
	var direction: Vector3 = source.get("direction", Vector3.UP)
	if parent_index >= 0:
		var parent_position: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var local_direction := position - parent_position
		if local_direction.length_squared() > 0.0001:
			direction = local_direction.normalized()
	var index := append_node(nodes, segments, position, parent_index, int(source.get("order", 0)), direction)
	var clone: Dictionary = nodes[index]
	for metadata_key in ["stratumBias", "domeAxis", "domeHeading"]:
		if source.has(metadata_key):
			clone[metadata_key] = source[metadata_key]
	nodes[index] = clone
	return index

func build_oak_full_axis_foliage(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	crown_center: Vector3,
	crown_radii: Vector3,
	height: float,
	seed: int,
	foliage_budget := OAK_REVIEW_FOLIAGE_BUDGET
) -> Array[Dictionary]:
	# Leaf sites are first discovered across the entire supporting wood graph,
	# then compete for the bounded foliage budget. Iterating until the cap used to
	# bias every leaf toward early-created branches, leaving later radius-limited
	# twigs visibly bare. This remains leaf-on-wood generation, never a canopy
	# shell or a view-dependent fill operation.
	var candidates: Array[Dictionary] = []
	for segment_index in range(segments.size()):
		var segment: Dictionary = segments[segment_index]
		var order := int(segment.get("order", 0))
		var child_index := int(segment.get("childNode", -1))
		var parent_index := int(segment.get("parentNode", -1))
		if child_index < 0 or parent_index < 0 or child_index >= nodes.size() or parent_index >= nodes.size():
			continue
		var child: Dictionary = nodes[child_index]
		var terminal := (child.get("children", []) as Array).is_empty()
		# The base bole and first structural split remain wood-dominant, but any
		# secondary axis carries living crown tissue along its full length. Limiting
		# leaves to third-order wood (or a terminal second-order stub) made shallow,
		# perfectly valid mature runtime graphs look bare even though they had ample
		# viable supporting branch length. This is an allometric eligibility rule,
		# not a crown fill: every emitted cluster is still attached to actual wood.
		# Runtime LOD may legitimately end an otherwise living primary limb before
		# it has emitted a secondary split. Treat that terminal limb as crown tissue
		# too. The main bole remains excluded, while every supported non-bole axis
		# can develop leaves rather than producing a seed-dependent bare candelabra.
		if order < 2 and not (order == 1 and terminal):
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = child.get("position", Vector3.UP)
		var length := start.distance_to(end)
		if length < 0.05:
			continue
		var midpoint := start.lerp(end, 0.5)
		var midpoint_envelope := Vector3(
			(midpoint.x - crown_center.x) / maxf(0.1, crown_radii.x),
			(midpoint.y - crown_center.y) / maxf(0.1, crown_radii.y),
			(midpoint.z - crown_center.z) / maxf(0.1, crown_radii.z)
		).length()
		var exposure := clampf((midpoint_envelope - 0.12) / 0.88, 0.0, 1.0)
		var capacity := (length * (0.96 if order >= 4 else 0.72) + (0.82 if terminal else 0.28)) \
			* lerpf(0.76, 1.34, exposure) * 1.42
		# Longer, better exposed living axes support proportionally more leaf
		# clusters. The runtime foliage budget selects a deterministic bounded
		# subset later, so this increases ecological colonization without allowing
		# an unbounded publication cost.
		var density_multiplier := lerpf(1.28, 1.72, exposure)
		var cluster_count := clampi(ceili(capacity * density_multiplier), 1, 6)
		var direction := (end - start).normalized()
		var side := direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var normal := direction.cross(side).normalized()
		for cluster_index in range(cluster_count):
			var unit := (float(cluster_index) + 0.42) / float(cluster_count)
			var jitter_a := stable_signed("oak-full-axis-leaf-a:%d:%d:%d" % [seed, segment_index, cluster_index])
			var jitter_b := stable_signed("oak-full-axis-leaf-b:%d:%d:%d" % [seed, segment_index, cluster_index])
			var position := start.lerp(end, clampf(unit + jitter_a * 0.08, 0.16, 1.0))
			position += side * jitter_a * 0.48 + normal * jitter_b * 0.42
			var envelope_unit := Vector3(
				(position.x - crown_center.x) / maxf(0.1, crown_radii.x),
				(position.y - crown_center.y) / maxf(0.1, crown_radii.y),
				(position.z - crown_center.z) / maxf(0.1, crown_radii.z)
			).length()
			var local_exposure := clampf((envelope_unit - 0.08) / 0.92, 0.0, 1.0)
			# Fine/terminal wood has earned greater leaf priority because it is the
			# active photosynthetic frontier. The stable term resolves equal biological
			# priority without relying on graph insertion order.
			var priority := local_exposure * 0.44 + float(order) / 4.0 * 0.24 \
				+ (0.22 if terminal else 0.0) \
				+ stable_unit("oak-full-axis-leaf-priority:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.10
			candidates.append({
				"position": position,
				"order": order,
				"terminal": terminal,
				"exposure": local_exposure,
				"priority": priority,
				"sourceSegment": segment_index,
				"clusterIndex": cluster_index,
				"capacity": capacity
			})
	var selected_candidates := select_full_axis_foliage_candidates(candidates, foliage_budget)
	var foliage: Array[Dictionary] = []
	for candidate in selected_candidates:
		var position: Vector3 = candidate.get("position", Vector3.ZERO)
		var exposure := float(candidate.get("exposure", 0.0))
		var segment_index := int(candidate.get("sourceSegment", -1))
		var cluster_index := int(candidate.get("clusterIndex", 0))
		var outer_scale := lerpf(1.22, 2.46, exposure)
		if bool(candidate.get("terminal", false)):
			outer_scale *= 1.10
		var vertical_scale := outer_scale * lerpf(
			0.68,
			0.82,
			stable_unit("oak-full-axis-leaf-y:%d:%d:%d" % [seed, segment_index, cluster_index])
		)
		foliage.append({
			"position": position,
			"rotation": Vector3(
				stable_signed("oak-full-axis-leaf-rx:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.24,
				stable_unit("oak-full-axis-leaf-ry:%d:%d:%d" % [seed, segment_index, cluster_index]) * TAU,
				stable_signed("oak-full-axis-leaf-rz:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.18
			),
			"scale": Vector3(outer_scale, vertical_scale, outer_scale),
			"windWeight": clampf(position.y / maxf(1.0, height), 0.22, 1.0),
			"variation": clampf(
				0.18 + exposure * 0.56
				+ stable_unit("oak-full-axis-leaf-color:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.26,
				0.0,
				1.0
			),
			"clusterVariant": posmod(stable_hash("oak-full-axis-leaf-variant:%d:%d:%d" % [seed, segment_index, cluster_index]), 4),
			"sourceSegment": segment_index,
			"sourceOrder": int(candidate.get("order", 0)),
			"twigCapacity": float(candidate.get("capacity", 0.0)),
			"exposure": exposure
		})
	return foliage

func select_full_axis_foliage_candidates(candidates: Array[Dictionary], foliage_budget: int) -> Array[Dictionary]:
	# Foliage is attached to living wood, not painted into a crown volume. Give
	# each eligible supporting axis its best leaf site before allowing exposed
	# terminal twigs to consume the rest of the bounded budget. The old global
	# priority sort concentrated a mathematically large leaf count on only a few
	# tips, producing the visible pom-pom/candelabra failure in runtime trees.
	if candidates.is_empty() or foliage_budget <= 0:
		return []
	var candidates_by_segment := {}
	var segment_indices: Array[int] = []
	for candidate in candidates:
		var segment_index := int(candidate.get("sourceSegment", -1))
		if not candidates_by_segment.has(segment_index):
			candidates_by_segment[segment_index] = []
			segment_indices.append(segment_index)
		var segment_candidates: Array = candidates_by_segment[segment_index]
		segment_candidates.append(candidate)
		candidates_by_segment[segment_index] = segment_candidates
	segment_indices.sort()
	var representatives: Array[Dictionary] = []
	var overflow: Array[Dictionary] = []
	for segment_index in segment_indices:
		var segment_candidates: Array = candidates_by_segment[segment_index]
		segment_candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
			return float(left.get("priority", 0.0)) > float(right.get("priority", 0.0))
		)
		if not segment_candidates.is_empty():
			representatives.append(segment_candidates[0] as Dictionary)
		for candidate_index in range(1, segment_candidates.size()):
			overflow.append(segment_candidates[candidate_index] as Dictionary)
	if representatives.size() > foliage_budget:
		# At reduced LOD, not every axis can be represented. Evenly traverse the
		# independent supporting axes instead of reverting to global tip priority.
		var reduced: Array[Dictionary] = []
		var stride := float(representatives.size()) / float(foliage_budget)
		for index in range(foliage_budget):
			reduced.append(representatives[clampi(floori((float(index) + 0.5) * stride), 0, representatives.size() - 1)])
		return reduced
	var selected: Array[Dictionary] = representatives.duplicate(true)
	overflow.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("priority", 0.0)) > float(right.get("priority", 0.0))
	)
	var remaining := mini(foliage_budget - selected.size(), overflow.size())
	for index in range(remaining):
		selected.append(overflow[index])
	return selected

func build_recipe_v10_allometric(seed := DEFAULT_SEED, maturity := 0.92) -> Dictionary:
	var resolved_seed := int(seed)
	var resolved_maturity := clampf(float(maturity), 0.12, 1.0)
	var normalized_growth := (1.0 - exp(-3.40 * resolved_maturity)) / (1.0 - exp(-3.40))
	var height := lerpf(13.5, 39.0, normalized_growth)
	var trunk_radius := lerpf(0.78, 3.10, pow(normalized_growth, 0.70))
	var fork_height := lerpf(5.4, 11.8, pow(normalized_growth, 0.74))
	var canopy_radius := lerpf(10.5, 29.0, pow(normalized_growth, 0.82))
	var crown_height := lerpf(14.0, 31.5, pow(normalized_growth, 0.78))
	var crown_center := Vector3(0.0, fork_height + crown_height * 0.40, 0.0)
	# Mature oaks are broad, decurrent crowns: their load-bearing wood spreads
	# over a wider, lower volume than a rounded generic broadleaf.
	var crown_radii := Vector3(canopy_radius, crown_height * 0.54, canopy_radius * 0.93)

	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	var allometric_growth: Dictionary = build_oak_allometric_crown(
		nodes,
		raw_segments,
		trunk_nodes,
		fork_height,
		canopy_radius,
		crown_center,
		crown_radii,
		resolved_seed
	)
	var axis_count: int = int(allometric_growth.get("axisCount", 0))
	var pruned_axis_count: int = int(allometric_growth.get("prunedAxisCount", 0))
	# Coarse targets establish the major limbs. A later, denser cohort then
	# fills only the unclaimed crown gaps with finer wood—the same staged idea
	# that makes space-colonization produce mature branch hierarchy.
	smooth_non_junction_chains(nodes, 1)

	var pipe_result := solve_pipe_model(nodes, raw_segments, trunk_radius, height, fork_height)
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	var foliage := build_bushy_oak_foliage(nodes, raw_segments, crown_center, crown_radii, height, resolved_seed)
	var counts := segment_counts_by_order(raw_segments)
	var occupancy := crown_occupancy(foliage, crown_center, crown_radii)
	var major_reach := maximum_major_wood_reach(branches)
	var signature := recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)

	return {
		"recipeVersion": BUSHY_OAK_RECIPE_VERSION,
		"methodology": "deterministic_allometric_oak_bud_reiteration_pipe_model",
		"architecture": "broadleaf",
		"speciesGrammar": "bushy_spreading_oak_poc",
		"crownHabit": "dense_irregular_broad_spreading_oak",
		"seed": resolved_seed,
		"maturity": resolved_maturity,
		"height": height,
		"trunkRadius": trunk_radius,
		"canopyRadius": canopy_radius,
		"crownBase": fork_height,
		"crownHeight": crown_height,
		"crownCenter": crown_center,
		"crownRadii": crown_radii,
		"pocContinuousWood": true,
		"signature": signature,
		"branches": branches,
		"foliage": foliage,
		"branchCount": branches.size(),
		"foliageClusterCount": foliage.size(),
		"stats": {
			"nodeCount": nodes.size(),
			"segmentCountsByOrder": counts,
			"scaffoldAxisCount": axis_count,
			"allometricAxisCount": axis_count,
			"selfPrunedAxisCount": pruned_axis_count,
			"crownConstruction": "decurrent_oak_reiteration_with_envelope_self_pruning",
			"continuousTrunkPath": trunk_nodes.size() >= 7,
			"majorWoodReach": major_reach,
			"majorWoodReachToTrunkWidth": major_reach / maxf(0.1, trunk_radius * 2.0),
			"connected": graph_is_connected(nodes, raw_segments),
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"foliageUsesSupportingWoodAcrossOrders": true,
			"budgetSaturation": {
				"branchSegments": float(branches.size()) / float(MAX_OAK_BRANCH_SEGMENTS),
				"foliageClusters": float(foliage.size()) / float(MAX_OAK_FOLIAGE_CLUSTERS),
				"branchLimitReached": raw_segments.size() >= MAX_OAK_BRANCH_SEGMENTS,
				"foliageLimitReached": foliage.size() >= MAX_OAK_FOLIAGE_CLUSTERS
			}
		}
	}

func build_oak_allometric_crown(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	fork_height: float,
	canopy_radius: float,
	crown_center: Vector3,
	crown_radii: Vector3,
	seed: int
) -> Dictionary:
	# Oak form is decurrent: there is a strong trunk, then several durable,
	# unequal boughs. Each bough carries a continuation and a bank of lateral
	# buds. A lateral only survives while its resource allocation can carry it
	# inside the available crown envelope. This is deliberately not a sequence
	# of authored crown tiers.
	var state: Dictionary = {"axisCount": 0, "prunedAxisCount": 0}
	var root: int = append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var trunk_steps: int = maxi(14, ceili(fork_height / 0.74))
	var trunk_phase: float = stable_unit("bushy-oak-v10-trunk-phase:%d" % seed) * TAU
	var previous: int = root
	for step_index in range(1, trunk_steps + 1):
		var unit: float = float(step_index) / float(trunk_steps)
		var bend: float = pow(unit, 1.54) * lerpf(0.14, 0.48, stable_unit("bushy-oak-v10-trunk-bend:%d" % seed))
		var position := Vector3(
			cos(trunk_phase + unit * 1.18) * bend,
			fork_height * unit,
			sin(trunk_phase + unit * 0.93) * bend
		)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		previous = append_node(nodes, segments, position, previous, 0, (position - start).normalized())
		trunk_nodes.append(previous)

	# The first boughs are phyllotactically distributed around the trunk, and
	# their attachment heights are stratified rather than all originating from a
	# single knot. That gives the silhouette its broad, old-oak shoulder.
	const primary_bough_count := 6
	var phase: float = stable_unit("bushy-oak-v10-primary-phase:%d" % seed) * TAU
	for bough_index in range(primary_bough_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			break
		var stratum: float = (float(bough_index) + 0.50 + stable_signed("bushy-oak-v10-primary-height:%d:%d" % [seed, bough_index]) * 0.18) / float(primary_bough_count)
		var attachment_unit: float = lerpf(0.62, 0.98, clampf(stratum, 0.05, 0.95))
		var attachment_index: int = clampi(roundi(attachment_unit * float(trunk_nodes.size() - 1)), 1, trunk_nodes.size() - 1)
		var parent: int = trunk_nodes[attachment_index]
		var angle: float = phase + float(bough_index) * GOLDEN_ANGLE + stable_signed("bushy-oak-v10-primary-angle:%d:%d" % [seed, bough_index]) * 0.11
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var upward_pitch: float = lerpf(0.02, 0.16, attachment_unit)
		var heading := (radial * 0.93 + Vector3.UP * upward_pitch + side * stable_signed("bushy-oak-v10-primary-curl:%d:%d" % [seed, bough_index]) * 0.035).normalized()
		var limb_length: float = canopy_radius * lerpf(0.78, 0.90, stable_unit("bushy-oak-v10-primary-length:%d:%d" % [seed, bough_index]))
		grow_oak_allometric_axis(
			nodes, segments, parent, heading, radial, limb_length, 1.0, 1,
			bough_index + 1, crown_center, crown_radii, seed, state
		)

	# Reiterated upper leaders are smaller than the low boughs, but they keep the
	# crown from becoming a flat umbrella. They share the same axis rule and are
	# allowed to lose dominance when the envelope has no remaining space.
	for leader_index in range(2):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			break
		var parent: int = trunk_nodes.back()
		var angle: float = phase + (float(leader_index) + 0.5) * TAU / 2.0
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var heading := (Vector3.UP * 0.72 + radial * 0.58).normalized()
		grow_oak_allometric_axis(
			nodes, segments, parent, heading, radial, crown_radii.y * 0.84, 0.76, 1,
			100 + leader_index, crown_center, crown_radii, seed, state
		)
	return state

func grow_oak_allometric_axis(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial_hint: Vector3,
	axis_length: float,
	resource: float,
	order: int,
	lineage: int,
	crown_center: Vector3,
	crown_radii: Vector3,
	seed: int,
	state: Dictionary
) -> void:
	if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
		state["prunedAxisCount"] = int(state.get("prunedAxisCount", 0)) + 1
		return
	if order > 4 or resource < 0.035 or axis_length < 0.28:
		return
	state["axisCount"] = int(state.get("axisCount", 0)) + 1
	var segment_count: int = clampi(ceili(axis_length / 2.65), 2, 7)
	if order >= 3:
		segment_count = clampi(ceili(axis_length / 0.42), 3, 6)
	var segment_length: float = axis_length / float(segment_count)
	var current: int = parent
	var current_heading: Vector3 = heading.normalized()
	for segment_index in range(segment_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			state["prunedAxisCount"] = int(state.get("prunedAxisCount", 0)) + 1
			return
		var start: Vector3 = nodes[current].get("position", Vector3.ZERO)
		var local := start - crown_center
		var crown_unit: float = clampf((local.y / maxf(0.1, crown_radii.y) + 1.0) * 0.5, 0.0, 1.0)
		var radial := Vector3(local.x, 0.0, local.z)
		if radial.length_squared() < 0.001:
			radial = radial_hint
		else:
			radial = radial.normalized()
		var local_progress: float = float(segment_index) / float(maxi(1, segment_count - 1))
		# Lower branches briefly accept their weight, then turn upward. Inner and
		# upper branches progressively seek light; this is a continuous tropism
		# curve, not a prescribed stack of branch layers.
		var lower_sag: float = -0.025 * (1.0 - crown_unit) * (1.0 - local_progress)
		var order_light_limit: float = [0.0, 0.13, 0.19, 0.27, 0.35][clampi(order, 0, 4)]
		var light_seeking_rise: float = lerpf(0.012, order_light_limit, oak_smooth_unit(crown_unit)) + lower_sag
		var curving_noise: Vector3 = stable_noise_vector(seed, lineage * 41 + segment_index, order) * 0.022
		var direction := (
			current_heading * 0.86
			+ radial * lerpf(0.10, 0.045, crown_unit)
			+ Vector3.UP * light_seeking_rise
			+ curving_noise
		).normalized()
		var endpoint: Vector3 = start + direction * segment_length
		if not oak_point_inside_space_crown(endpoint, crown_center, crown_radii, 0.0):
			# The envelope is a self-pruning constraint. A tip may bend inward once;
			# it is not teleported or extended through unavailable crown space.
			var inward: Vector3 = (crown_center - start).normalized()
			direction = (current_heading * 0.50 + inward * 0.30 + Vector3.UP * 0.20).normalized()
			endpoint = start + direction * segment_length
			if not oak_point_inside_space_crown(endpoint, crown_center, crown_radii, 0.0):
				state["prunedAxisCount"] = int(state.get("prunedAxisCount", 0)) + 1
				return
		if endpoint_too_close(endpoint, nodes, current):
			state["prunedAxisCount"] = int(state.get("prunedAxisCount", 0)) + 1
			return
		var child: int = append_node(nodes, segments, endpoint, current, order, direction)
		tag_stratum(nodes, child, clampf(crown_unit * 2.0 - 1.0, -1.0, 1.0))
		current = child
		current_heading = direction

		var may_branch: bool = order < 4 and segment_index >= 1 and segment_index < segment_count - 1
		var branch_stride: int = 1
		if may_branch and posmod(segment_index + lineage, branch_stride) == 0:
			var lateral_count: int = 3 if order == 3 else 1
			for lateral_slot in range(lateral_count):
				var side := direction.cross(Vector3.UP)
				if side.length_squared() < 0.001:
					side = radial.cross(Vector3.UP)
				side = side.normalized()
				var handedness: float = -1.0 if posmod(lineage + segment_index + lateral_slot, 2) == 0 else 1.0
				var lateral_plane := (radial * 0.56 + side * handedness * 0.78).normalized()
				var lateral_pitch: float = lerpf(0.055, 0.28, crown_unit) + stable_signed("bushy-oak-v10-lateral-pitch:%d:%d:%d:%d" % [seed, lineage, segment_index, lateral_slot]) * 0.035
				var lateral_heading := (lateral_plane * 0.86 + direction * 0.18 + Vector3.UP * lateral_pitch).normalized()
				var remaining_span: float = axis_length * (1.0 - (float(segment_index) + 0.35) / float(segment_count))
				var length_fraction: float = [0.0, 0.59, 0.52, 0.45, 0.0][clampi(order, 0, 4)]
				var lateral_length: float = maxf(0.26, remaining_span * length_fraction)
				var resource_fraction: float = [0.0, 0.58, 0.50, 0.42, 0.0][clampi(order, 0, 4)]
				var lateral_resource: float = resource * resource_fraction
				grow_oak_allometric_axis(
					nodes, segments, current, lateral_heading, lateral_plane, lateral_length,
					lateral_resource, order + 1, lineage * 11 + segment_index * 2 + lateral_slot + 1,
					crown_center, crown_radii, seed, state
				)

func build_oak_space_colonization_scaffold(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	fork_height: float,
	canopy_radius: float,
	seed: int
) -> int:
	var root := append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var trunk_steps := maxi(8, ceili(fork_height / 0.82))
	var trunk_phase := stable_unit("bushy-oak-v7-trunk-phase:%d" % seed) * TAU
	var previous := root
	for step_index in range(1, trunk_steps + 1):
		var unit := float(step_index) / float(trunk_steps)
		var bend := pow(unit, 1.42) * lerpf(0.16, 0.64, stable_unit("bushy-oak-v7-trunk-bend:%d" % seed))
		var position := Vector3(
			cos(trunk_phase + unit * 1.32) * bend,
			fork_height * unit,
			sin(trunk_phase + unit * 1.07) * bend
		)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		previous = append_node(nodes, segments, position, previous, 0, (position - start).normalized())
		trunk_nodes.append(previous)

	# These are the young oak's durable scaffold axes. They are distributed up
	# the upper trunk with phyllotactic rotation: a real oak's boughs are not a
	# horizontal whorl, but neither does its crown originate from one fork.
	# Subsequent space-colonization decides which buds persist and fill gaps.
	var bough_count := 6
	var phase := stable_unit("bushy-oak-v7-scaffold-phase:%d" % seed) * TAU
	for bough_index in range(bough_count):
		var attachment_jitter := stable_signed("bushy-oak-v8-scaffold-height:%d:%d" % [seed, bough_index]) * 0.18
		var attachment_band := (float(bough_index) + 0.50 + attachment_jitter) / float(bough_count)
		var attachment_unit := lerpf(0.62, 0.98, clampf(attachment_band, 0.04, 0.96))
		var attachment_index := clampi(roundi(attachment_unit * float(trunk_nodes.size() - 1)), 1, trunk_nodes.size() - 1)
		var parent: int = trunk_nodes[attachment_index]
		var angle := phase + float(bough_index) * GOLDEN_ANGLE
		angle += stable_signed("bushy-oak-v7-scaffold-angle:%d:%d" % [seed, bough_index]) * 0.22
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var initial_pitch := lerpf(0.08, 0.36, attachment_unit)
		var heading := (radial * 0.92 + Vector3.UP * initial_pitch + side * stable_signed("bushy-oak-v7-scaffold-curl:%d:%d" % [seed, bough_index]) * 0.05).normalized()
		var segment_count := 2
		for segment_index in range(segment_count):
			var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
			var upward_turn := lerpf(0.08, 0.20, float(segment_index) / float(segment_count - 1)) + attachment_unit * 0.06
			heading = (heading * 0.82 + radial * 0.13 + Vector3.UP * upward_turn).normalized()
			var segment_length := canopy_radius * lerpf(0.09, 0.115, attachment_unit)
			parent = append_node(nodes, segments, start + heading * segment_length, parent, 1, heading)
			tag_stratum(nodes, parent, lerpf(-0.82, 0.12, float(segment_index) / float(segment_count - 1)))

	# Three short reiterations seed the upper inner crown. Their
	# eventual dominance is decided by claimed space, not by a permanent leader
	# privilege or a fixed branch layer.
	for leader_index in range(3):
		var parent: int = trunk_nodes.back()
		var angle := phase + (float(leader_index) + 0.5) * TAU / 3.0
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var heading := (Vector3.UP * 0.84 + radial * 0.34).normalized()
		for segment_index in range(3):
			var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
			heading = (heading * 0.82 + radial * 0.10 + Vector3.UP * 0.11).normalized()
			parent = append_node(nodes, segments, start + heading * canopy_radius * 0.095, parent, 1, heading)
			tag_stratum(nodes, parent, lerpf(0.30, 0.82, float(segment_index) / 2.0))
	return bough_count + 3

func build_oak_space_attraction_points(
	seed: int,
	center: Vector3,
	radii: Vector3,
	count: int,
	salt: int
) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x4F414B37 ^ salt
	var points: Array[Vector3] = []
	points.resize(count)
	for index in range(count):
		var azimuth := rng.randf() * TAU
		# Most targets sit near the crown surface where light is plentiful; a
		# smaller interior population keeps the skeleton connected and prevents a
		# hollow leaf shell. This is an available-space field, not a branch tier.
		var surface_biased := rng.randf() < 0.76
		var radial := lerpf(0.58, 1.0, pow(rng.randf(), 0.42)) if surface_biased else pow(rng.randf(), 0.56)
		# Mature oaks carry far more active crown in the middle and upper crown
		# than directly below the primary boughs. Skewing the available-space
		# field upward lets lower limbs open, then rise into the dome.
		var vertical_unit := lerpf(-0.56, 0.94, pow(rng.randf(), 0.78))
		var horizontal_unit := sqrt(maxf(0.0, 1.0 - vertical_unit * vertical_unit))
		var vertical_normalized := clampf((vertical_unit + 1.0) * 0.5, 0.0, 1.0)
		# A mature oak remains broad through its lower and middle crown, then
		# contracts gently above. The uneven sinusoid gives seed-stable natural
		# lobes without ever becoming a circular branch whorl.
		var height_width := 0.70 + 0.30 * pow(maxf(0.0, sin(PI * vertical_normalized)), 0.58)
		var lobe := 0.94 + sin(azimuth * 3.0 + stable_unit("bushy-oak-v7-lobe:%d" % seed) * TAU) * 0.075 + sin(azimuth * 5.0 - 0.91) * 0.045
		points[index] = center + Vector3(
			cos(azimuth) * horizontal_unit * radial * radii.x * height_width * lobe,
			vertical_unit * radial * radii.y,
			sin(azimuth) * horizontal_unit * radial * radii.z * height_width * lobe
		)
	return points

func colonize_oak_space_crown(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	attraction_points: Array[Vector3],
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	_branch_reach_factor: float,
	seed: int,
	maximum_iterations: int,
	branch_segment_budget: int
) -> Dictionary:
	# This is the bounded, spatial-hashed form of space colonization. It keeps
	# the research model's "nearest bud claims available space" rule without the
	# quadratic all-points/all-nodes scan that is unsuitable for iteration.
	const influence_distance := 8.6
	const kill_distance := 1.05
	# Match the grid cell to the influence radius. A nearest-bud query then needs
	# the containing cell and its 26 neighbors, not a 5x5x5 neighborhood.
	const cell_size := influence_distance
	var branch_budget := clampi(branch_segment_budget, 48, MAX_OAK_BRANCH_SEGMENTS)
	var remaining: Array[Vector3] = attraction_points.duplicate()
	var claimed_points := 0
	var iterations := 0
	for iteration in range(maximum_iterations):
		if remaining.is_empty() or segments.size() >= branch_budget:
			break
		iterations = iteration + 1
		var active_bud_grid: Dictionary = build_oak_node_grid(nodes, cell_size, true)
		var influenced: Dictionary = {}
		var survivors: Array[Vector3] = []
		for attraction in remaining:
			var nearest_bud: Dictionary = oak_nearest_grid_node(nodes, active_bud_grid, attraction, influence_distance, cell_size)
			var bud_index := int(nearest_bud.get("index", -1))
			if bud_index >= 0 and float(nearest_bud.get("distanceSquared", INF)) <= kill_distance * kill_distance:
				claimed_points += 1
				continue
			survivors.append(attraction)
			if bud_index < 0:
				continue
			var bud_position: Vector3 = nodes[bud_index].get("position", Vector3.ZERO)
			var attraction_direction: Vector3 = (attraction - bud_position).normalized()
			var row: Dictionary = influenced.get(bud_index, {"sum": Vector3.ZERO, "count": 0})
			row["sum"] = row.get("sum", Vector3.ZERO) + attraction_direction
			row["count"] = int(row.get("count", 0)) + 1
			influenced[bud_index] = row
		remaining = survivors
		if influenced.is_empty():
			break

		var influenced_indices: Array = influenced.keys()
		influenced_indices.sort()
		var added := 0
		var all_nodes_grid: Dictionary = build_oak_node_grid(nodes, cell_size, false)
		for bud_key in influenced_indices:
			if segments.size() >= branch_budget:
				break
			var bud_index := int(bud_key)
			if bud_index < 0 or bud_index >= nodes.size():
				continue
			var bud: Dictionary = nodes[bud_index]
			if not oak_node_can_grow(bud):
				continue
			var position: Vector3 = bud.get("position", Vector3.ZERO)
			var attraction_direction: Vector3 = (influenced[bud_key] as Dictionary).get("sum", Vector3.UP)
			if attraction_direction.length_squared() < 0.0001:
				continue
			attraction_direction = attraction_direction.normalized()
			var parent_direction: Vector3 = bud.get("direction", Vector3.UP)
			var local := position - crown_center
			var crown_unit := clampf((local.y / maxf(0.1, crown_radii.y) + 1.0) * 0.5, 0.0, 1.0)
			var radial := Vector3(local.x, 0.0, local.z)
			if radial.length_squared() < 0.001:
				radial = Vector3(cos(crown_phase), 0.0, sin(crown_phase))
			else:
				radial = radial.normalized()
			# Lower oak limbs may sag under their own weight; as the available crown
			# space rises, the same rule naturally turns succeeding wood upward.
			var tropism := lerpf(-0.025, 0.18, oak_smooth_unit(crown_unit))
			var direction := (
				attraction_direction * 0.55
				+ parent_direction * 0.36
				+ radial * 0.045
				+ Vector3.UP * tropism
				+ stable_noise_vector(seed, bud_index, iteration) * 0.020
			).normalized()
			var children: Array = bud.get("children", [])
			# A second successor represents a lateral branch. It may only activate
			# when it earns distinct crown space. A durable oak bough continues at
			# its own order through several internodes before it becomes finer; an
			# immediate order promotion produces a short-forked antler instead of a
			# weight-bearing limb with subordinate axes.
			var parent_order := int(bud.get("order", 0))
			var order_run := int(bud.get("orderRun", 0))
			var run_limits: Array[int] = [999, 7, 6, 4, 3]
			var child_order: int = parent_order
			if children.size() >= 2 or (parent_order > 0 and order_run >= run_limits[parent_order]):
				child_order = mini(4, parent_order + 1)
			if not direction_diverges_from_children(nodes, bud, direction, child_order):
				continue
			var step_length: float = float([1.55, 2.05, 1.36, 0.88, 0.56][clampi(child_order, 0, 4)])
			step_length *= lerpf(0.88, 1.12, stable_unit("bushy-oak-v7-step:%d:%d:%d" % [seed, bud_index, iteration]))
			var endpoint := position + direction * step_length
			if not oak_point_inside_space_crown(endpoint, crown_center, crown_radii, crown_phase):
				continue
			var nearby: Dictionary = oak_nearest_grid_node(nodes, all_nodes_grid, endpoint, MIN_ENDPOINT_SEPARATION, cell_size)
			if int(nearby.get("index", -1)) >= 0:
				continue
			var child := append_node(nodes, segments, endpoint, bud_index, child_order, direction)
			tag_stratum(nodes, child, clampf(crown_unit * 2.0 - 1.0, -1.0, 1.0))
			oak_append_grid_node(all_nodes_grid, child, endpoint, cell_size)
			added += 1
		if added == 0:
			break
	return {
		"remainingAttractions": remaining,
		"claimedAttractionPoints": claimed_points,
		"iterations": iterations
	}

func build_oak_node_grid(nodes: Array[Dictionary], cell_size: float, active_buds_only: bool) -> Dictionary:
	var grid: Dictionary = {}
	for node_index in range(nodes.size()):
		var node: Dictionary = nodes[node_index]
		if active_buds_only and not oak_node_can_grow(node):
			continue
		oak_append_grid_node(grid, node_index, node.get("position", Vector3.ZERO), cell_size)
	return grid

func oak_append_grid_node(grid: Dictionary, node_index: int, position: Vector3, cell_size: float) -> void:
	var key := oak_grid_key(position, cell_size)
	var bucket: Array = grid.get(key, [])
	bucket.append(node_index)
	grid[key] = bucket

func oak_grid_key(position: Vector3, cell_size: float) -> Vector3i:
	return Vector3i(floori(position.x / cell_size), floori(position.y / cell_size), floori(position.z / cell_size))

func oak_nearest_grid_node(
	nodes: Array[Dictionary],
	grid: Dictionary,
	point: Vector3,
	radius: float,
	cell_size: float
) -> Dictionary:
	var base_x := floori(point.x / cell_size)
	var base_y := floori(point.y / cell_size)
	var base_z := floori(point.z / cell_size)
	var cell_range := ceili(radius / cell_size)
	var radius_squared := radius * radius
	var nearest_index := -1
	var nearest_squared := radius_squared
	for offset_x in range(-cell_range, cell_range + 1):
		for offset_y in range(-cell_range, cell_range + 1):
			for offset_z in range(-cell_range, cell_range + 1):
				var key := Vector3i(base_x + offset_x, base_y + offset_y, base_z + offset_z)
				var bucket: Array = grid.get(key, [])
				for node_value in bucket:
					var node_index := int(node_value)
					var position: Vector3 = nodes[node_index].get("position", Vector3.ZERO)
					var distance_squared := position.distance_squared_to(point)
					if distance_squared <= nearest_squared:
						nearest_squared = distance_squared
						nearest_index = node_index
	return {"index": nearest_index, "distanceSquared": nearest_squared}

func oak_node_can_grow(node: Dictionary) -> bool:
	var order := int(node.get("order", 0))
	if order <= 0:
		return false
	var children: Array = node.get("children", [])
	# A continuing apex and a lateral successor can both develop from a viable
	# oak bud. Letting orders 1--3 do that is what creates a true tapering
	# fractal hierarchy instead of an antler with one generation of forks.
	var child_limit := 2 if order <= 3 else 1
	return children.size() < child_limit

func oak_point_inside_space_crown(point: Vector3, center: Vector3, radii: Vector3, phase: float) -> bool:
	var local := point - center
	var vertical_unit := local.y / maxf(0.1, radii.y)
	if absf(vertical_unit) > 1.06:
		return false
	var height_unit := clampf((vertical_unit + 1.0) * 0.5, 0.0, 1.0)
	var height_width := 0.70 + 0.30 * pow(maxf(0.0, sin(PI * height_unit)), 0.58)
	var azimuth := atan2(local.z, local.x)
	var lobe := 0.94 + sin(azimuth * 3.0 + phase) * 0.075 + sin(azimuth * 5.0 - 0.91) * 0.045
	var horizontal := Vector2(
		local.x / maxf(0.1, radii.x * height_width * lobe),
		local.z / maxf(0.1, radii.z * height_width * lobe)
	).length()
	return horizontal * horizontal + vertical_unit * vertical_unit <= 1.06

func build_oak_trunk(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	trunk_scaffold_height: float,
	seed: int
) -> void:
	var root := append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var previous := root
	var step_count := maxi(11, ceili(trunk_scaffold_height / 0.92))
	var phase := stable_unit("bushy-oak-trunk:%d" % seed) * TAU
	for step_index in range(1, step_count + 1):
		var unit := float(step_index) / float(step_count)
		var bend := pow(unit, 1.40) * lerpf(0.14, 0.72, stable_unit("bushy-oak-trunk-bend:%d" % seed))
		var position := Vector3(
			cos(phase + unit * 1.7) * bend,
			trunk_scaffold_height * unit,
			sin(phase + unit * 1.33) * bend
		)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		previous = append_node(nodes, segments, position, previous, 0, (position - start).normalized())
		trunk_nodes.append(previous)

func build_v4_recursive_scaffold_graph(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	canopy_radius: float,
	_crown_height: float,
	normalized_growth: float,
	seed: int
) -> Dictionary:
	# Oak architecture is a low, multi-leader recursive graph—not a central
	# spine with radial shelves. Each primary leader becomes a local growth axis
	# whose descendants shorten, fork, and turn upward from their own parent.
	# A mature oak is decurrent: substantial boughs emerge all around the
	# trunk, then a smaller number of leaders carry the crown upward. This is
	# an azimuth/elevation distribution rule, not a crown-layer count.
	var leader_count := clampi(roundi(lerpf(6.0, float(MAX_PRIMARY_LEADERS), normalized_growth)), 6, MAX_PRIMARY_LEADERS)
	var phase := stable_unit("bushy-oak-primary-phase:%d" % seed) * TAU
	var fork_parent: int = trunk_nodes.back()
	var upright_leader_count := clampi(roundi(float(leader_count) * 0.40), 1, 2)
	var spreading_leader_count := leader_count - upright_leader_count
	var pitch_sum := 0.0
	var pitch_count := 0
	var fine_protrusion_count := 0
	var recursive_fork_count := 0
	for leader_index in range(leader_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			break
		var is_upright_leader := leader_index >= spreading_leader_count
		var local_index := leader_index - spreading_leader_count if is_upright_leader else leader_index
		var local_count := upright_leader_count if is_upright_leader else spreading_leader_count
		var angle := phase + float(local_index) * TAU / float(local_count)
		if is_upright_leader:
			angle += GOLDEN_ANGLE * 0.42
		angle += stable_signed("bushy-oak-primary-angle:%d:%d" % [seed, leader_index]) * 0.19
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var initial_pitch := lerpf(0.68, 0.92, stable_unit("bushy-oak-primary-pitch:%d:%d" % [seed, leader_index])) if is_upright_leader else lerpf(0.17, 0.32, stable_unit("bushy-oak-primary-pitch:%d:%d" % [seed, leader_index]))
		var horizontal_weight := 0.46 if is_upright_leader else 0.96
		var initial_heading := (
			radial * horizontal_weight
			+ Vector3.UP * initial_pitch
			+ side * stable_signed("bushy-oak-primary-curl:%d:%d" % [seed, leader_index]) * 0.10
		).normalized()
		var primary_length := canopy_radius * (0.64 if is_upright_leader else OAK_PRIMARY_REACH_FRACTION)
		primary_length *= lerpf(0.90, 1.08, stable_unit("bushy-oak-primary-length:%d:%d" % [seed, leader_index]))
		var leader_parent := fork_parent if is_upright_leader else trunk_nodes[maxi(4, trunk_nodes.size() - 2 - posmod(leader_index * 2, 4))]
		var leader_result: Dictionary = grow_v4_oak_leader(
			nodes, segments, leader_parent, initial_heading, radial, side, primary_length,
			0, leader_index, leader_index, seed
		)
		fine_protrusion_count += int(leader_result.get("fineProtrusions", 0))
		recursive_fork_count += int(leader_result.get("forkCount", 0))
		pitch_sum += initial_heading.y
		pitch_count += 1
	return {
		"primaryLeaderCount": leader_count,
		"fineProtrusionCount": fine_protrusion_count,
		"longLimbMeanPitch": pitch_sum / float(maxi(1, pitch_count)),
		"recursiveForkCount": recursive_fork_count,
		"maxRecursiveDepth": OAK_MAX_RECURSIVE_DEPTH,
		"crownConstruction": "low_multi_leader_recursive_growth"
	}

func grow_v4_oak_leader(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial: Vector3,
	side: Vector3,
	limb_length: float,
	depth: int,
	leader_index: int,
	lineage: int,
	seed: int
) -> Dictionary:
	var protrusions := 0
	var fork_count := 0
	var previous := parent
	var limb_steps := 3 if depth <= 1 else 2
	var current_heading := heading
	for limb_step in range(limb_steps):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return {"fineProtrusions": protrusions, "forkCount": fork_count}
		var limb_unit := float(limb_step + 1) / float(limb_steps)
		# The first-order bough rises from the fork, then relaxes outward. Each
		# successive generation turns more upward, filling an oak's rounded dome.
		var rise := lerpf(0.04, 0.28, float(depth) / float(OAK_MAX_RECURSIVE_DEPTH))
		if depth == 0:
			rise += 0.12 - 0.07 * limb_unit
		var bend := stable_signed("bushy-oak-recursive-bend:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, depth, limb_step]) * 0.16
		var outward_bias := lerpf(0.15, 0.04, float(depth) / float(OAK_MAX_RECURSIVE_DEPTH))
		var direction := (current_heading * 0.84 + radial * outward_bias + side * bend + Vector3.UP * rise).normalized()
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var branch_order: int = mini(depth + 1, 4)
		var current := append_node(nodes, segments, start + direction * limb_length / float(limb_steps), previous, branch_order, direction)
		tag_stratum(nodes, current, clampf(-0.55 + float(depth) * 0.42 + limb_unit * 0.18, -1.0, 1.0))
		protrusions += append_v4_oak_recursive_fine_protrusions(
			nodes, segments, current, direction, radial, side, limb_length,
			depth, leader_index, lineage, limb_step, seed
		)
		if should_spawn_v4_oak_child(depth, limb_step, limb_steps, seed, leader_index, lineage):
			var child_count := 2 if depth == 0 and limb_step == 1 else 1
			for child_slot in range(child_count):
				if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
					break
				var sign := -1.0 if posmod(leader_index + lineage + limb_step + child_slot, 2) == 0 else 1.0
				if stable_signed("bushy-oak-child-side:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, child_slot]) < 0.0:
					sign *= -1.0
				var child_radial := (radial * 0.82 + side * sign * 0.45).normalized()
				var child_side := child_radial.cross(Vector3.UP).normalized()
				var child_rise := lerpf(0.26, 0.48, float(depth) / float(OAK_MAX_RECURSIVE_DEPTH))
				var child_heading := (direction * 0.50 + child_radial * 0.62 + Vector3.UP * child_rise).normalized()
				var child_length := limb_length * OAK_CHILD_LENGTH_DECAY
				child_length *= lerpf(0.88, 1.04, stable_unit("bushy-oak-child-length:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, child_slot]))
				var child_lineage := lineage * 7 + limb_step * 2 + child_slot + 1
				var child_result: Dictionary = grow_v4_oak_leader(
					nodes, segments, current, child_heading, child_radial, child_side,
					child_length, depth + 1, leader_index, child_lineage, seed
				)
				protrusions += int(child_result.get("fineProtrusions", 0))
				fork_count += 1 + int(child_result.get("forkCount", 0))
		previous = current
		current_heading = direction
	return {"fineProtrusions": protrusions, "forkCount": fork_count}

func should_spawn_v4_oak_child(
	depth: int,
	limb_step: int,
	limb_steps: int,
	seed: int,
	leader_index: int,
	lineage: int
) -> bool:
	if depth >= OAK_MAX_RECURSIVE_DEPTH:
		return false
	if depth == 0:
		return limb_step >= 1
	if depth == 1:
		return limb_step == 0 or limb_step == limb_steps - 1
	return limb_step == 0 and stable_unit("bushy-oak-terminal-fork:%d:%d:%d" % [seed, leader_index, lineage]) >= 0.28

func append_v4_oak_recursive_fine_protrusions(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial: Vector3,
	side: Vector3,
	arm_length: float,
	depth: int,
	leader_index: int,
	lineage: int,
	limb_step: int,
	seed: int
) -> int:
	var count := 0
	var twig_count := 2 if depth < 2 else 3
	for twig_index in range(twig_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return count
		var sign := -1.0 if twig_index % 2 == 0 else 1.0
		var fan := side * sign * lerpf(0.26, 0.70, stable_unit("bushy-oak-twig-fan:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, twig_index]))
		var rise := lerpf(0.08, 0.34, float(depth) / float(OAK_MAX_RECURSIVE_DEPTH))
		rise += stable_signed("bushy-oak-twig-rise:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, twig_index]) * 0.20
		var direction := (heading * 0.40 + radial * 0.42 + fan + Vector3.UP * rise).normalized()
		var length := arm_length * lerpf(0.08, 0.17, stable_unit("bushy-oak-twig-length:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, twig_index]))
		var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
		var twig_order: int = mini(depth + 2, 4)
		var twig := append_node(nodes, segments, start + direction * length, parent, twig_order, direction)
		tag_stratum(nodes, twig, stable_signed("bushy-oak-twig-stratum:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, twig_index]) * 0.78)
		var tip_direction := (direction * 0.84 + radial * 0.16 + Vector3.UP * 0.10).normalized()
		var tip := append_node(nodes, segments, nodes[twig].get("position", Vector3.ZERO) + tip_direction * length * 0.74, twig, mini(twig_order + 1, 4), tip_direction)
		tag_stratum(nodes, tip, stable_signed("bushy-oak-tip-stratum:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, limb_step, twig_index]) * 0.82)
		count += 2
	return count

## V6 active grammar: a continuous trunk scaffold carries bough origins through
## the crown. Each bough is aimed toward a smooth radial crown envelope, then
## recursively subdivides until its wood becomes too thin to support another
## fork. This distributes limbs through space rather than creating shelves.
func build_spreading_scaffold_graph(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	canopy_radius: float,
	crown_base_height: float,
	crown_height: float,
	normalized_growth: float,
	seed: int
) -> Dictionary:
	# This population is a maturity-scaled spatial sample count. It does not
	# define a number of visual layers: each bough gets an individual elevation,
	# azimuth, reachable envelope, and radius-limited recursive future.
	var spreading_bough_count := clampi(roundi(lerpf(7.0, 11.0, normalized_growth)), 7, 11)
	var upper_leader_count := 3
	var leader_count := spreading_bough_count + upper_leader_count
	var phase := stable_unit("bushy-oak-v5-primary-phase:%d" % seed) * TAU
	var crown_start_index := 0
	while crown_start_index < trunk_nodes.size() - 1:
		var candidate: Vector3 = nodes[trunk_nodes[crown_start_index]].get("position", Vector3.ZERO)
		if candidate.y >= crown_base_height:
			break
		crown_start_index += 1
	var crown_base_node := trunk_nodes[crown_start_index]
	var pitch_sum := 0.0
	var pitch_count := 0
	var attachment_bands := {}
	var upper_crown_bough_count := 0
	var stats := {
		"primaryLeaderCount": leader_count,
		"trunkAttachedBoughCount": spreading_bough_count,
		"trunkBranchAzimuthCount": spreading_bough_count,
		"fineProtrusionCount": 0,
		"longLimbMeanPitch": 0.0,
		"recursiveForkCount": 0,
		"maximumRecursiveGeneration": 0,
		"radiusLimitedTerminationCount": 0,
		"minimumTerminalRadiusBudget": INF,
		"maximumForkRadiusBudget": 0.0,
		"crownConstruction": "nested_bloom_crown_envelope_radius_limited_recursive_growth",
		"bloomAxisCount": 0,
		"bloomRadiusClampCount": 0
	}
	for leader_index in range(leader_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			break
		var is_upper_leader := leader_index >= spreading_bough_count
		var local_index := leader_index - spreading_bough_count if is_upper_leader else leader_index
		# The main bough azimuth is deliberately decoupled from height. Incrementing
		# both by the same index would create a visual helix: one side low and the
		# opposite side high. The golden angle distributes every elevation through
		# the full circumference without authored branch rings.
		var angle := phase
		if is_upper_leader:
			angle += (float(local_index) + 0.50) * TAU / float(upper_leader_count)
		else:
			angle += float(local_index) * GOLDEN_ANGLE
		angle += stable_signed("bushy-oak-v5-primary-angle:%d:%d" % [seed, leader_index]) * 0.17
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var side := radial.cross(Vector3.UP).normalized()
		var attachment_unit := 0.0
		if is_upper_leader:
			attachment_unit = lerpf(0.68, OAK_CROWN_ATTACHMENT_MAX, (float(local_index) + 0.50) / float(upper_leader_count))
		else:
			var stratified_unit := (float(local_index) + 0.50 + stable_signed("bushy-oak-v6-attachment:%d:%d" % [seed, local_index]) * 0.21) / float(spreading_bough_count)
			attachment_unit = OAK_CROWN_ATTACHMENT_MIN + (OAK_CROWN_ATTACHMENT_MAX - OAK_CROWN_ATTACHMENT_MIN) * pow(clampf(stratified_unit, 0.0, 1.0), 0.86)
		attachment_unit = clampf(attachment_unit, OAK_CROWN_ATTACHMENT_MIN, OAK_CROWN_ATTACHMENT_MAX)
		var attachment_index := clampi(
			roundi(lerpf(float(crown_start_index), float(trunk_nodes.size() - 2), attachment_unit)),
			crown_start_index,
			trunk_nodes.size() - 2
		)
		var attachment_position: Vector3 = nodes[trunk_nodes[attachment_index]].get("position", Vector3.ZERO)
		var crown_base_position: Vector3 = nodes[crown_base_node].get("position", Vector3.ZERO)
		var physical_attachment_unit := clampf((attachment_position.y - crown_base_position.y) / maxf(0.1, crown_height), 0.0, 1.0)
		var attachment_band := clampi(floori(physical_attachment_unit * 5.0), 0, 4)
		attachment_bands[attachment_band] = true
		if is_upper_leader:
			upper_crown_bough_count += 1
		var initial_pitch := lerpf(0.24, 0.45, physical_attachment_unit) if is_upper_leader else lerpf(-0.13, 0.20, physical_attachment_unit)
		var initial_heading := (
			radial * (0.86 if is_upper_leader else 1.04)
			+ Vector3.UP * initial_pitch
			+ side * stable_signed("bushy-oak-v5-primary-curl:%d:%d" % [seed, leader_index]) * 0.12
		).normalized()
		var root_radius_budget := 0.40 if is_upper_leader else lerpf(0.43, 0.32, physical_attachment_unit)
		# Each axis is given the first term of a recursive geometric reach series.
		# Its complete reach is determined by the radial crown envelope at the
		# elevation where that bough emerged from the trunk.
		var target_reach := oak_crown_envelope_reach(physical_attachment_unit, canopy_radius)
		var root_length := target_reach * (0.96 if is_upper_leader else 1.0) * (1.0 - OAK_CONTINUATION_LENGTH_FRACTION)
		root_length *= lerpf(0.92, 1.06, stable_unit("bushy-oak-v5-primary-length:%d:%d" % [seed, leader_index]))
		grow_radius_limited_oak_axis(
			nodes,
			segments,
			trunk_nodes[attachment_index],
			initial_heading,
			radial,
			side,
			root_radius_budget,
			root_length,
			1,
			0,
			leader_index,
			leader_index + 1,
			seed,
			target_reach,
			stats,
			crown_base_node,
			crown_height,
			canopy_radius
		)
		pitch_sum += initial_heading.y
		pitch_count += 1
	stats["longLimbMeanPitch"] = pitch_sum / float(maxi(1, pitch_count))
	stats["trunkBranchHeightBandCount"] = attachment_bands.size()
	stats["upperCrownBoughCount"] = upper_crown_bough_count
	if is_inf(float(stats.get("minimumTerminalRadiusBudget", INF))):
		stats["minimumTerminalRadiusBudget"] = 0.0
	return stats

func oak_crown_envelope_reach(crown_unit: float, canopy_radius: float) -> float:
	var unit := clampf(crown_unit, 0.0, 1.0)
	# A broad dome, not a stack of horizontal shelves: lower limbs are already
	# substantial, the middle reaches furthest, and the top contracts smoothly.
	var dome := pow(maxf(0.0, sin(PI * unit)), 0.66)
	var upper_taper := 1.0 - 0.22 * oak_smooth_unit((unit - 0.58) / 0.42)
	return canopy_radius * lerpf(0.42, 0.98, dome) * upper_taper

func oak_smooth_unit(value: float) -> float:
	var unit := clampf(value, 0.0, 1.0)
	return unit * unit * (3.0 - 2.0 * unit)

func grow_radius_limited_oak_axis(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial: Vector3,
	side: Vector3,
	radius_budget: float,
	axis_length: float,
	branch_order: int,
	recursive_generation: int,
	leader_index: int,
	lineage: int,
	seed: int,
	bloom_reach_limit: float,
	stats: Dictionary,
	crown_base_node: int,
	crown_height: float,
	canopy_radius: float
) -> void:
	if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
		return
	stats["bloomAxisCount"] = int(stats.get("bloomAxisCount", 0)) + 1
	stats["maximumRecursiveGeneration"] = maxi(int(stats.get("maximumRecursiveGeneration", 0)), recursive_generation)
	stats["maximumForkRadiusBudget"] = maxf(float(stats.get("maximumForkRadiusBudget", 0.0)), radius_budget)
	# The generation guard is only a malformed-input safety valve. Normal growth
	# reaches this terminal path through the radius/length inequalities below.
	if radius_budget <= OAK_MIN_FORK_RADIUS or axis_length <= OAK_MIN_BRANCH_LENGTH or recursive_generation >= OAK_ENGINEERING_GENERATION_GUARD:
		if radius_budget <= OAK_MIN_FORK_RADIUS or axis_length <= OAK_MIN_BRANCH_LENGTH:
			stats["radiusLimitedTerminationCount"] = int(stats.get("radiusLimitedTerminationCount", 0)) + 1
			stats["minimumTerminalRadiusBudget"] = minf(float(stats.get("minimumTerminalRadiusBudget", INF)), radius_budget)
		append_radius_limited_terminal_twigs(
			nodes, segments, parent, heading, radial, side, radius_budget, axis_length,
			branch_order, recursive_generation, leader_index, lineage, seed, stats
		)
		return

	var axis_steps := 3 if radius_budget >= 0.26 else 2
	var previous := parent
	var current_heading := heading
	var generation_order := mini(branch_order, 4)
	for axis_step in range(axis_steps):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return
		var unit := float(axis_step + 1) / float(axis_steps)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var crown_base: Vector3 = nodes[crown_base_node].get("position", Vector3.ZERO)
		var crown_unit := clampf((start.y - crown_base.y) / maxf(0.1, crown_height), 0.0, 1.0)
		var local_radial := Vector3(start.x - crown_base.x, 0.0, start.z - crown_base.z)
		if local_radial.length_squared() < 0.001:
			local_radial = radial
		else:
			local_radial = local_radial.normalized()
		var desired_reach := oak_crown_envelope_reach(crown_unit, canopy_radius)
		var current_reach := Vector2(start.x - crown_base.x, start.z - crown_base.z).length()
		# The global envelope describes the oak silhouette. The local bloom limit
		# describes the opening frontier inherited from the parent bough. Together
		# they let each generation open outward without overtaking the prior one.
		var allowed_reach := minf(desired_reach, bloom_reach_limit)
		allowed_reach = maxf(allowed_reach, current_reach + 0.06)
		var reach_gap := clampf((allowed_reach - current_reach) / maxf(0.1, canopy_radius), -0.75, 1.0)
		# Low boughs may sag, middle boughs spread, and high boughs turn upward;
		# the radial target remains present at every height so the top cannot
		# collapse into a vertical bundle.
		var rise := lerpf(-0.12, 0.17, oak_smooth_unit(crown_unit)) + lerpf(0.09, -0.025, unit)
		var outward_push := lerpf(0.10, 0.34, maxf(0.0, reach_gap))
		var curl := stable_signed("bushy-oak-v5-axis-curl:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, recursive_generation, axis_step]) * 0.13
		var direction := (
			current_heading * 0.69
			+ local_radial * outward_push
			+ side * curl
			+ Vector3.UP * rise
		).normalized()
		var endpoint := start + direction * axis_length / float(axis_steps)
		var endpoint_local := Vector3(endpoint.x - crown_base.x, 0.0, endpoint.z - crown_base.z)
		var endpoint_reach := endpoint_local.length()
		if endpoint_reach > allowed_reach:
			var endpoint_radial := endpoint_local.normalized() if endpoint_reach > 0.001 else local_radial
			endpoint.x = crown_base.x + endpoint_radial.x * allowed_reach
			endpoint.z = crown_base.z + endpoint_radial.z * allowed_reach
			direction = (endpoint - start).normalized()
			stats["bloomRadiusClampCount"] = int(stats.get("bloomRadiusClampCount", 0)) + 1
		var current := append_node(
			nodes,
			segments,
			endpoint,
			previous,
			generation_order,
			direction
		)
		tag_stratum(nodes, current, clampf(start.y / 22.0 - 0.56 + unit * 0.16, -1.0, 1.0))
		previous = current
		current_heading = direction

	# At every viable axis end the grammar may produce one lateral successor.
	# The continuation and lateral capacities obey r_c^2 + r_l^2 < r_p^2,
	# while solve_pipe_model later applies the exact all-descendant pipe rule.
	var lateral_radius := radius_budget * OAK_LATERAL_RADIUS_FRACTION
	var can_fork := lateral_radius > OAK_MIN_FORK_RADIUS and axis_length * OAK_LATERAL_LENGTH_FRACTION > OAK_MIN_BRANCH_LENGTH
	if can_fork and stable_unit("bushy-oak-v5-fork:%d:%d:%d:%d" % [seed, leader_index, lineage, recursive_generation]) >= 0.10:
		# Two oblique child axes are the fractal fork. Their combined radial
		# capacity plus the continuing axis stays below the parent capacity, so
		# the topology can keep subdividing without hand-authored extra layers.
		var child_count := 2 if radius_budget >= 0.26 else 1
		var fork_position: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var fork_reach := Vector2(fork_position.x - nodes[crown_base_node].get("position", Vector3.ZERO).x, fork_position.z - nodes[crown_base_node].get("position", Vector3.ZERO).z).length()
		var lateral_bloom_limit := fork_reach + maxf(0.0, bloom_reach_limit - fork_reach) * OAK_INNER_BLOOM_REACH_FRACTION
		for child_slot in range(child_count):
			var fork_sign := -1.0 if child_slot == 0 else 1.0
			if stable_signed("bushy-oak-v5-fork-side:%d:%d:%d:%d:%d" % [seed, leader_index, lineage, recursive_generation, child_slot]) < 0.0:
				fork_sign *= -1.0
			var lateral_radial := (radial * 0.62 + side * fork_sign * 0.78).normalized()
			var lateral_side := lateral_radial.cross(Vector3.UP).normalized()
			var crown_base: Vector3 = nodes[crown_base_node].get("position", Vector3.ZERO)
			var fork_crown_unit := clampf((fork_position.y - crown_base.y) / maxf(0.1, crown_height), 0.0, 1.0)
			var lateral_heading := (
				current_heading * 0.30
				+ lateral_radial * 0.68
				+ Vector3.UP * lerpf(-0.05, 0.18, oak_smooth_unit(fork_crown_unit))
			).normalized()
			stats["recursiveForkCount"] = int(stats.get("recursiveForkCount", 0)) + 1
			grow_radius_limited_oak_axis(
				nodes,
				segments,
				previous,
				lateral_heading,
				lateral_radial,
				lateral_side,
				lateral_radius,
				axis_length * OAK_LATERAL_LENGTH_FRACTION,
				mini(branch_order + 1, 4),
				recursive_generation + 1,
				leader_index,
				lineage * 7 + child_slot + 2,
				seed,
				lateral_bloom_limit,
				stats,
				crown_base_node,
				crown_height,
				canopy_radius
			)

	var continuation_radius := radius_budget * OAK_CONTINUATION_RADIUS_FRACTION
	grow_radius_limited_oak_axis(
		nodes,
		segments,
		previous,
		current_heading,
		radial,
		side,
		continuation_radius,
		axis_length * OAK_CONTINUATION_LENGTH_FRACTION,
		branch_order,
		recursive_generation,
		leader_index,
		lineage * 5 + 1,
		seed,
		bloom_reach_limit,
		stats,
		crown_base_node,
		crown_height,
		canopy_radius
	)

func append_radius_limited_terminal_twigs(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	heading: Vector3,
	radial: Vector3,
	side: Vector3,
	radius_budget: float,
	axis_length: float,
	branch_order: int,
	recursive_generation: int,
	leader_index: int,
	lineage: int,
	seed: int,
	stats: Dictionary
) -> void:
	if radius_budget < OAK_MIN_TERMINAL_RADIUS or segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
		return
	# The structural graph has already reached its thin-wood terminal condition.
	# A second terminal pair is decorative, so admit it selectively to preserve
	# a fine silhouette without allowing leaf-adjacent twigs to consume the
	# structural budget needed by the whole crown.
	var twig_count := 2 if stable_unit("bushy-oak-v5-terminal-count:%d:%d" % [seed, lineage]) >= 0.55 else 1
	for twig_index in range(twig_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return
		var sign := -1.0 if twig_index == 0 else 1.0
		var fan := side * sign * lerpf(0.42, 0.74, stable_unit("bushy-oak-v5-terminal-fan:%d:%d:%d" % [seed, lineage, twig_index]))
		var terminal_direction := (heading * 0.47 + radial * 0.34 + fan + Vector3.UP * 0.24).normalized()
		var twig_length := maxf(0.32, minf(axis_length * 0.66, 1.52))
		var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
		var twig := append_node(nodes, segments, start + terminal_direction * twig_length, parent, 4, terminal_direction)
		tag_stratum(nodes, twig, clampf(start.y / 22.0 - 0.10, -1.0, 1.0))
		var tip_direction := (terminal_direction * 0.80 + Vector3.UP * 0.20).normalized()
		var tip := append_node(nodes, segments, nodes[twig].get("position", Vector3.ZERO) + tip_direction * twig_length * 0.58, twig, 4, tip_direction)
		tag_stratum(nodes, tip, clampf(start.y / 22.0, -1.0, 1.0))
		stats["fineProtrusionCount"] = int(stats.get("fineProtrusionCount", 0)) + 2

func build_legacy_layered_scaffold_graph(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	canopy_radius: float,
	crown_height: float,
	normalized_growth: float,
	seed: int
) -> Dictionary:
	# Every visible oak limb belongs to this one crown-layer system. The base
	# layer establishes the long spreading boughs; each layer above it loses a
	# fixed 10 percentage points of that original reach (100, 90, 80 … 30).
	# There is deliberately no independent upper-spine or minimum-length branch
	# system that can flatten that taper.
	var base_branch_count := clampi(roundi(lerpf(4.0, float(MAX_PRIMARY_LEADERS), normalized_growth)), 4, MAX_PRIMARY_LEADERS)
	var phase := stable_unit("bushy-oak-layer-phase:%d" % seed) * TAU
	var pitch_sum := 0.0
	var pitch_count := 0
	var fine_protrusion_count := 0
	var layer_lengths: Array[float] = []
	var layer_reach_fractions: Array[float] = []
	var layer_minimum_limb_lengths: Array[float] = []
	var layer_maximum_limb_lengths: Array[float] = []
	var layer_parent: int = trunk_nodes.back()
	for layer_index in range(OAK_CROWN_LAYER_COUNT):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			break
		var layer_unit := float(layer_index) / float(maxi(1, OAK_CROWN_LAYER_COUNT - 1))
		var layer_reach_fraction := 1.0 - OAK_CROWN_LAYER_REACH_STEP * float(layer_index)
		var reach_envelope := canopy_radius * OAK_CROWN_BASE_REACH_FRACTION * layer_reach_fraction
		layer_lengths.append(reach_envelope)
		layer_reach_fractions.append(layer_reach_fraction)
		# An age/height-aware population curve: lower oak layers bear more major
		# limbs, while upper layers retain enough branches to close the crown.
		var branch_population := lerpf(float(base_branch_count), 2.0, layer_unit)
		branch_population += stable_signed("bushy-oak-layer-population:%d:%d" % [seed, layer_index]) * 0.30
		var branch_count := clampi(roundi(branch_population), 2, base_branch_count)
		var minimum_limb_length := INF
		var maximum_limb_length := 0.0
		for branch_index in range(branch_count):
			if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
				break
			var angle := phase + float(layer_index) * GOLDEN_ANGLE * 0.36 + float(branch_index) * TAU / float(branch_count)
			angle += stable_signed("bushy-oak-layer-angle:%d:%d:%d" % [seed, layer_index, branch_index]) * 0.18
			var radial := Vector3(cos(angle), 0.0, sin(angle))
			var side := radial.cross(Vector3.UP).normalized()
			# Only shorten siblings within a layer. The 96% floor guarantees that
			# even the longest limb above is shorter than every limb below.
			var limb_length := reach_envelope * lerpf(0.96, 1.0, stable_unit(
				"bushy-oak-layer-reach:%d:%d:%d" % [seed, layer_index, branch_index]
			))
			minimum_limb_length = minf(minimum_limb_length, limb_length)
			maximum_limb_length = maxf(maximum_limb_length, limb_length)
			fine_protrusion_count += append_oak_layer_limb(
				nodes, segments, layer_parent, radial, side, limb_length, layer_unit,
				layer_index, branch_index, seed
			)
			pitch_sum += lerpf(-0.16, 0.44, layer_unit)
			pitch_count += 1
		layer_minimum_limb_lengths.append(minimum_limb_length)
		layer_maximum_limb_lengths.append(maximum_limb_length)
		if layer_index < OAK_CROWN_LAYER_COUNT - 1:
			var drift_angle := phase + float(layer_index) * GOLDEN_ANGLE * 0.31
			var drift := Vector3(cos(drift_angle), 0.0, sin(drift_angle))
			var leader_direction := (Vector3.UP + drift * lerpf(0.16, 0.05, layer_unit)).normalized()
			var leader_length := crown_height / float(OAK_CROWN_LAYER_COUNT - 1)
			var leader_start: Vector3 = nodes[layer_parent].get("position", Vector3.ZERO)
			layer_parent = append_node(nodes, segments, leader_start + leader_direction * leader_length, layer_parent, 1, leader_direction)
			tag_stratum(nodes, layer_parent, lerpf(-0.15, 1.0, layer_unit))
	return {
		"primaryLeaderCount": base_branch_count,
		"fineProtrusionCount": fine_protrusion_count,
		"longLimbMeanPitch": pitch_sum / float(maxi(1, pitch_count)),
		"upperTierArmLengths": layer_lengths,
		"crownLayerReachFractions": layer_reach_fractions,
		"crownLayerMinimumLimbLengths": layer_minimum_limb_lengths,
		"crownLayerMaximumLimbLengths": layer_maximum_limb_lengths
	}

func append_oak_layer_limb(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	radial: Vector3,
	side: Vector3,
	limb_length: float,
	layer_unit: float,
	layer_index: int,
	branch_index: int,
	seed: int
) -> int:
	var protrusions := 0
	var previous := parent
	var limb_steps := 4
	for limb_step in range(limb_steps):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return protrusions
		var limb_unit := float(limb_step + 1) / float(limb_steps)
		# Lower limbs arc then sag; progressively higher layers turn upward. This
		# is also height-derived, so it cannot introduce a separate branch habit.
		var pitch := lerpf(-0.16, 0.44, layer_unit)
		var arch := 0.18 * sin(limb_unit * PI) - limb_unit * lerpf(0.13, 0.01, layer_unit)
		var bend := stable_signed("bushy-oak-layer-bend:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step]) * 0.14
		var direction := (radial + side * bend + Vector3.UP * (pitch + arch)).normalized()
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var current := append_node(nodes, segments, start + direction * limb_length / float(limb_steps), previous, 1, direction)
		tag_stratum(nodes, current, lerpf(-0.65, 1.0, layer_unit))
		protrusions += append_fine_oak_protrusions(
			nodes, segments, current, radial, side, limb_length, layer_unit,
			layer_index, branch_index, limb_step, seed
		)
		previous = current
	return protrusions

func append_fine_oak_protrusions(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	radial: Vector3,
	side: Vector3,
	arm_length: float,
	layer_unit: float,
	layer_index: int,
	branch_index: int,
	limb_step: int,
	seed: int
) -> int:
	var count := 0
	# Fine forks thin with height using the same layer coordinate as their
	# parent limb. This stays within the shared oak grammar instead of adding a
	# separate top-of-tree branch rule.
	var twig_population := lerpf(3.0, 2.0, layer_unit)
	twig_population += stable_signed("bushy-oak-twig-population:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step]) * 0.16
	var twig_count := clampi(roundi(twig_population), 2, 3)
	for twig_index in range(twig_count):
		if segments.size() >= MAX_OAK_BRANCH_SEGMENTS:
			return count
		var sign := -1.0 if twig_index % 2 == 0 else 1.0
		var fan := side * sign * lerpf(0.30, 0.68, stable_unit("bushy-oak-twig-fan:%d:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step, twig_index]))
		var rise := stable_signed("bushy-oak-twig-rise:%d:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step, twig_index]) * 0.30
		var direction := (radial * 0.58 + fan + Vector3.UP * rise).normalized()
		# Twigs provide fine oak protrusions without becoming a second major
		# branch tier that could visually defeat the parent layer's envelope.
		var length := arm_length * lerpf(0.10, 0.18, stable_unit("bushy-oak-twig-length:%d:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step, twig_index]))
		var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
		var twig := append_node(nodes, segments, start + direction * length, parent, 3, direction)
		tag_stratum(nodes, twig, clampf(lerpf(-0.55, 1.0, layer_unit) + stable_signed("bushy-oak-twig-stratum:%d:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step, twig_index]) * 0.12, -1.0, 1.0))
		var tip_direction := (direction * 0.84 + radial * 0.16 + Vector3.UP * 0.10).normalized()
		var tip := append_node(nodes, segments, nodes[twig].get("position", Vector3.ZERO) + tip_direction * length * 0.74, twig, 4, tip_direction)
		tag_stratum(nodes, tip, clampf(lerpf(-0.48, 1.0, layer_unit) + stable_signed("bushy-oak-tip-stratum:%d:%d:%d:%d:%d" % [seed, layer_index, branch_index, limb_step, twig_index]) * 0.12, -1.0, 1.0))
		count += 2
	return count

func build_bushy_oak_foliage(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	crown_center: Vector3,
	crown_radii: Vector3,
	height: float,
	seed: int
) -> Array[Dictionary]:
	var foliage: Array[Dictionary] = []
	for segment_index in range(segments.size()):
		if foliage.size() >= MAX_OAK_FOLIAGE_CLUSTERS:
			break
		var segment: Dictionary = segments[segment_index]
		var order := int(segment.get("order", 0))
		if order < 1:
			continue
		# Mature oak leaves can emerge from fine sidewood along a primary bough,
		# not only from its terminal tips. Keep this sparse so the trunk and the
		# recursive wood remain readable.
		if order == 1 and stable_unit("bushy-oak-v5-primary-leaf-window:%d:%d" % [seed, segment_index]) < 0.62:
			continue
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		if parent_index < 0 or child_index < 0 or child_index >= nodes.size():
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = nodes[child_index].get("position", Vector3.UP)
		var direction := (end - start).normalized()
		var side := direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var normal := direction.cross(side).normalized()
		# Skip only a small deterministic fraction so mature oaks remain bushy but
		# never become a featureless leaf balloon.
		if stable_unit("bushy-oak-window:%d:%d" % [seed, segment_index]) < 0.16:
			continue
		var cluster_count := 1 if order <= 3 else 2
		for cluster_index in range(cluster_count):
			if foliage.size() >= MAX_OAK_FOLIAGE_CLUSTERS:
				break
			var unit := (float(cluster_index) + 0.40) / float(cluster_count)
			var jitter_a := stable_signed("bushy-oak-leaf-a:%d:%d:%d" % [seed, segment_index, cluster_index])
			var jitter_b := stable_signed("bushy-oak-leaf-b:%d:%d:%d" % [seed, segment_index, cluster_index])
			var position := start.lerp(end, clampf(unit + jitter_a * 0.12, 0.08, 1.0))
			position += side * jitter_a * 0.54 + normal * jitter_b * 0.48
			var local := position - crown_center
			var envelope := Vector3(
				local.x / maxf(0.1, crown_radii.x),
				local.y / maxf(0.1, crown_radii.y),
				local.z / maxf(0.1, crown_radii.z)
			).length()
			var exposure := clampf((envelope - 0.08) / 0.92, 0.0, 1.0)
			var scale := lerpf(1.24, 2.46, exposure) * lerpf(0.94, 1.12, stable_unit("bushy-oak-leaf-size:%d:%d:%d" % [seed, segment_index, cluster_index]))
			foliage.append({
				"position": position,
				"rotation": Vector3(
					stable_signed("bushy-oak-leaf-rx:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.23,
					stable_unit("bushy-oak-leaf-ry:%d:%d:%d" % [seed, segment_index, cluster_index]) * TAU,
					stable_signed("bushy-oak-leaf-rz:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.20
				),
				"scale": Vector3(scale * 1.28, scale * 1.05, scale * 1.22),
				"windWeight": clampf(position.y / maxf(1.0, height), 0.20, 1.0),
				"variation": clampf(0.18 + exposure * 0.58 + stable_unit("bushy-oak-leaf-color:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.22, 0.0, 1.0),
				"clusterVariant": posmod(stable_hash("bushy-oak-leaf-variant:%d:%d:%d" % [seed, segment_index, cluster_index]), 4),
				"sourceSegment": segment_index,
				"sourceOrder": order,
				"exposure": exposure
			})
	return foliage

func tag_stratum(nodes: Array[Dictionary], node_index: int, value: float) -> void:
	var node: Dictionary = nodes[node_index]
	node["stratumBias"] = clampf(value, -1.0, 1.0)
	nodes[node_index] = node
