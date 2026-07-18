extends "res://scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd"

## VOX-140 approved Norway-spruce-like mathematical grammar.
##
## This is intentionally a separate species grammar. It reuses only the pure
## graph/pipe-model helpers and the generic renderer from the broadleaf PoC;
## it does not inherit a rounded crown, low broadleaf fork, or broadleaf growth
## targets. No SceneTree, Resource, renderer or global world RNG is touched.

const CONIFER_RECIPE_VERSION := 2
const MAX_CONIFER_WHORLS := 14
const MAX_CONIFER_BRANCH_SEGMENTS := 1120
const MAX_CONIFER_FOLIAGE_CLUSTERS := 1480

func build_recipe(seed := DEFAULT_SEED, maturity := 0.92, _growth_profile: Dictionary = {}) -> Dictionary:
	var resolved_seed := int(seed)
	var resolved_maturity := clampf(float(maturity), 0.12, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = resolved_seed

	# A spruce retains one leader as it ages. Its trunk stays markedly slimmer
	# than a mature broadleaf, while lower bough reach creates the species' deep
	# cone rather than a generic narrow cylinder.
	var normalized_growth := (1.0 - exp(-3.15 * resolved_maturity)) / (1.0 - exp(-3.15))
	var height := lerpf(15.5, 53.0, normalized_growth)
	var trunk_radius := lerpf(0.56, 2.08, pow(normalized_growth, 0.78))
	var crown_base := lerpf(1.35, 2.60, pow(normalized_growth, 0.82))
	var crown_height := height - crown_base
	var crown_radius := lerpf(3.65, 14.3, pow(normalized_growth, 0.88))
	# Spruce still has low limbs, but its first living whorl clears the flared
	# trunk/root zone. This preserves a readable, mature trunk at player scale.
	var first_whorl_height := crown_base + lerpf(1.80, 3.80, pow(normalized_growth, 0.66))
	var crown_center := Vector3(0.0, crown_base + crown_height * 0.46, 0.0)
	var crown_radii := Vector3(crown_radius, crown_height * 0.50, crown_radius * 0.94)

	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	build_apical_leader(nodes, raw_segments, trunk_nodes, height, resolved_seed)
	var whorl_stats := build_irregular_whorls(
		nodes,
		raw_segments,
		trunk_nodes,
		rng,
		crown_base,
		crown_height,
		crown_radius,
		first_whorl_height,
		normalized_growth,
		resolved_seed
	)

	var pipe_result := solve_pipe_model(nodes, raw_segments, trunk_radius, height, crown_base)
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	var foliage := build_needle_foliage(
		nodes,
		raw_segments,
		crown_center,
		crown_radii,
		height,
		resolved_seed
	)
	var counts := segment_counts_by_order(raw_segments)
	var occupancy := crown_occupancy(foliage, crown_center, crown_radii)
	var connected := graph_is_connected(nodes, raw_segments)
	var signature := recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)

	return {
		"recipeVersion": CONIFER_RECIPE_VERSION,
		"methodology": "deterministic_monopodial_bud_spacing_pipe_model",
		"architecture": "conifer",
		"speciesGrammar": "norway_spruce_like_poc",
		"crownHabit": "irregular_deep_conical",
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
			"nodeCount": nodes.size(),
			"segmentCountsByOrder": counts,
			"coniferWhorlCount": int(whorl_stats.get("whorlCount", 0)),
			"firstWhorlHeight": float(whorl_stats.get("firstWhorlHeight", 0.0)),
			"interstitialSprayCount": int(whorl_stats.get("interstitialSprayCount", 0)),
			"supportDrivenBranchletCount": int(whorl_stats.get("supportDrivenBranchletCount", 0)),
			"meanBoughBudCharge": float(whorl_stats.get("meanBoughBudCharge", 0.0)),
			"apicalLeaderContinuous": trunk_nodes.size() >= 8,
			"lowerWhorlMeanLength": float(whorl_stats.get("lowerMeanLength", 0.0)),
			"upperWhorlMeanLength": float(whorl_stats.get("upperMeanLength", 0.0)),
			"droopingCurtainMeanPitch": float(whorl_stats.get("droopingCurtainMeanPitch", 0.0)),
			"connected": connected,
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"foliageDerivedFromFineSegments": true,
			"budgetSaturation": {
				"branchSegments": float(branches.size()) / float(MAX_CONIFER_BRANCH_SEGMENTS),
				"foliageClusters": float(foliage.size()) / float(MAX_CONIFER_FOLIAGE_CLUSTERS),
				"branchLimitReached": raw_segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS,
				"foliageLimitReached": foliage.size() >= MAX_CONIFER_FOLIAGE_CLUSTERS
			}
		}
	}

func build_apical_leader(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	height: float,
	seed: int
) -> void:
	var root := append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var step_height := 1.18
	var step_count := maxi(12, ceili(height / step_height))
	var phase := stable_unit("conifer-leader-phase:%d" % seed) * TAU
	var previous := root
	for step_index in range(1, step_count + 1):
		var unit := float(step_index) / float(step_count)
		# A restrained, continuous leader wavers in wind and growth history, but
		# never becomes a broadleaf-style competing trunk.
		var drift := pow(unit, 1.72) * 0.46
		var position := Vector3(
			cos(phase + unit * 1.9) * drift,
			height * unit,
			sin(phase + unit * 1.6) * drift
		)
		var previous_position: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var direction := (position - previous_position).normalized()
		previous = append_node(nodes, segments, position, previous, 0, direction)
		trunk_nodes.append(previous)

func build_irregular_whorls(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	rng: RandomNumberGenerator,
	crown_base: float,
	crown_height: float,
	crown_radius: float,
	first_whorl_height: float,
	normalized_growth: float,
	seed: int
) -> Dictionary:
	var whorl_count := clampi(roundi(lerpf(6.0, float(MAX_CONIFER_WHORLS), normalized_growth)), 6, MAX_CONIFER_WHORLS)
	var phase := stable_unit("conifer-whorl-phase:%d" % seed) * TAU
	var lower_lengths: Array[float] = []
	var upper_lengths: Array[float] = []
	var curtain_pitch_sum := 0.0
	var curtain_count := 0
	var interstitial_spray_count := 0
	var support_driven_branchlet_count := 0
	var bough_bud_charge_sum := 0.0
	var crown_top := crown_base + crown_height * 0.96
	for whorl_index in range(whorl_count):
		if segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS:
			break
		var crown_unit := float(whorl_index) / float(maxi(1, whorl_count - 1))
		# Tighten upper spacing and jitter every tier. This yields a recognisable
		# whorled habit without the visually artificial stack of equal disks.
		var y := lerpf(first_whorl_height, crown_top, pow(crown_unit, 0.84))
		y += stable_signed("conifer-whorl-y:%d:%d" % [seed, whorl_index]) * lerpf(0.56, 0.14, crown_unit)
		y = clampf(y, first_whorl_height, crown_top)
		var attach := nearest_trunk_node(nodes, trunk_nodes, y)
		# Each internode has a finite circumference and a finite amount of stored
		# shoot vigour.  That determines how many buds can establish around it;
		# it is not a named lower/middle/upper bough-count recipe.  The monotonic
		# apical decline preserves the spruce's monopodial hierarchy.
		var length_irregularity := lerpf(0.88, 1.10, stable_unit("conifer-whorl-length:%d:%d" % [seed, whorl_index]))
		var bough_length := crown_radius * pow(1.0 - crown_unit, 0.64) * length_irregularity
		bough_length = maxf(1.45, bough_length)
		var internode_circumference := TAU * maxf(0.45, bough_length * lerpf(0.105, 0.072, crown_unit))
		var bud_spacing := lerpf(2.55, 1.64, crown_unit) * lerpf(0.90, 1.10, stable_unit("conifer-bud-spacing:%d:%d" % [seed, whorl_index]))
		var bud_charge := internode_circumference / maxf(0.30, bud_spacing) * lerpf(1.05, 0.64, crown_unit)
		var bough_count := clampi(floori(bud_charge + stable_unit("conifer-bud-phase:%d:%d" % [seed, whorl_index])), 2, 5)
		bough_bud_charge_sum += bud_charge
		if crown_unit < 0.34:
			lower_lengths.append(bough_length)
		elif crown_unit > 0.68:
			upper_lengths.append(bough_length)
		for bough_index in range(bough_count):
			if segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS:
				break
			var angle := phase + float(whorl_index) * GOLDEN_ANGLE * 0.38 + float(bough_index) * TAU / float(bough_count)
			angle += stable_signed("conifer-whorl-angle:%d:%d:%d" % [seed, whorl_index, bough_index]) * 0.18
			var radial := Vector3(cos(angle), 0.0, sin(angle))
			var primary_steps := clampi(ceili(bough_length / lerpf(2.24, 1.72, crown_unit)), 2, 6)
			var previous := attach
			for primary_index in range(primary_steps):
				if segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS:
					break
				var step_unit := float(primary_index + 1) / float(primary_steps)
				var droop := lerpf(-0.16, 0.18, crown_unit) - pow(step_unit, 1.32) * lerpf(0.16, 0.035, crown_unit)
				var direction := (radial * 0.985 + Vector3.UP * droop).normalized()
				var step_length := bough_length / float(primary_steps) * lerpf(0.92, 1.08, stable_unit("conifer-primary-step:%d:%d:%d" % [seed, whorl_index, primary_index]))
				var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
				var primary := append_node(nodes, segments, start + direction * step_length, previous, 1, direction)
				tag_stratum(nodes, primary, crown_unit * 2.0 - 1.0)
				# Every scaffold carries fine lateral sprays, including the short upper
				# boughs. Their pitch is a gentle curtain, not a vertical root-like
				# drop, so needle depth reads across the full branch length.
				if primary_steps > 1:
					# Fine shoots arise from the actual metamer length and remaining
					# vigour of the carrier. This makes a full lower bough carry more
					# needle-bearing branchlets without turning it into a fixed brush.
					var branchlet_charge := step_length * lerpf(0.96, 0.70, crown_unit) \
						* lerpf(1.12, 0.72, step_unit)
					var curtain_total := clampi(
						floori(branchlet_charge + stable_unit("conifer-branchlet-phase:%d:%d:%d:%d" % [seed, whorl_index, bough_index, primary_index])),
						1,
						3
					)
					for curtain_index in range(curtain_total):
						if segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS:
							break
						var side := radial.cross(Vector3.UP).normalized()
						var side_sign := -1.0 if (curtain_index + primary_index + bough_index) % 2 == 0 else 1.0
						var curtain_direction := (
							radial * 0.74
							+ side * side_sign * 0.36
							+ Vector3.DOWN * lerpf(0.38, 0.16, crown_unit)
						).normalized()
						var curtain_length := step_length * lerpf(1.18, 0.68, crown_unit)
						var curtain := append_node(nodes, segments, start + direction * step_length + curtain_direction * curtain_length, primary, 2, curtain_direction)
						tag_stratum(nodes, curtain, crown_unit * 2.0 - 1.0)
						var tip_direction := (curtain_direction * 0.80 + radial * 0.22 + Vector3.DOWN * 0.04).normalized()
						var curtain_tip := append_node(nodes, segments, nodes[curtain].get("position", Vector3.ZERO) + tip_direction * curtain_length * 0.76, curtain, 3, tip_direction)
						tag_stratum(nodes, curtain_tip, crown_unit * 2.0 - 1.0)
						curtain_pitch_sum += curtain_direction.y
						curtain_count += 1
						support_driven_branchlet_count += 1
				previous = primary
		# Between defining arms, short subordinate sprays fill the vertical gaps
		# that make a spruce look bushy. They never rival the principal whorl in
		# length, radius, or count, so the conical hierarchy remains legible.
		if whorl_index < whorl_count - 1 and segments.size() < MAX_CONIFER_BRANCH_SEGMENTS:
			var next_unit := float(whorl_index + 1) / float(maxi(1, whorl_count - 1))
			var next_y := lerpf(first_whorl_height, crown_top, pow(next_unit, 0.84))
			var interstitial_y := lerpf(y, next_y, 0.48)
			interstitial_y += stable_signed("conifer-interstitial-y:%d:%d" % [seed, whorl_index]) * 0.20
			var interstitial_attach := nearest_trunk_node(nodes, trunk_nodes, interstitial_y)
			var interstitial_length := bough_length * lerpf(0.48, 0.34, crown_unit)
			var interstitial_charge := interstitial_length / lerpf(3.10, 2.42, crown_unit)
			var interstitial_count := clampi(
				floori(interstitial_charge + stable_unit("conifer-interstitial-phase:%d:%d" % [seed, whorl_index])),
				1,
				2
			)
			for interstitial_index in range(interstitial_count):
				if segments.size() >= MAX_CONIFER_BRANCH_SEGMENTS:
					break
				var interstitial_angle := phase + float(whorl_index) * GOLDEN_ANGLE * 0.38 + PI * 0.44
				interstitial_angle += float(interstitial_index) * PI + stable_signed("conifer-interstitial-angle:%d:%d:%d" % [seed, whorl_index, interstitial_index]) * 0.18
				var interstitial_radial := Vector3(cos(interstitial_angle), 0.0, sin(interstitial_angle))
				append_interstitial_spray(
					nodes,
					segments,
					interstitial_attach,
					interstitial_radial,
					interstitial_length,
					crown_unit * 2.0 - 1.0
				)
				interstitial_spray_count += 1
	return {
		"whorlCount": whorl_count,
		"firstWhorlHeight": first_whorl_height,
		"interstitialSprayCount": interstitial_spray_count,
		"supportDrivenBranchletCount": support_driven_branchlet_count,
		"meanBoughBudCharge": bough_bud_charge_sum / float(maxi(1, whorl_count)),
		"lowerMeanLength": mean_float_values(lower_lengths),
		"upperMeanLength": mean_float_values(upper_lengths),
		"droopingCurtainMeanPitch": curtain_pitch_sum / float(maxi(1, curtain_count))
	}

func append_interstitial_spray(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	attach: int,
	radial: Vector3,
	length: float,
	stratum_bias: float
) -> void:
	var start: Vector3 = nodes[attach].get("position", Vector3.ZERO)
	var primary_direction := (radial * 0.98 + Vector3.DOWN * 0.10).normalized()
	var primary := append_node(nodes, segments, start + primary_direction * length * 0.58, attach, 1, primary_direction)
	tag_stratum(nodes, primary, stratum_bias)
	mark_latest_segment_interstitial(segments)
	var side := radial.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	var secondary_direction := (radial * 0.68 + side * 0.32 + Vector3.DOWN * 0.30).normalized()
	var secondary := append_node(nodes, segments, nodes[primary].get("position", Vector3.ZERO) + secondary_direction * length * 0.30, primary, 2, secondary_direction)
	tag_stratum(nodes, secondary, stratum_bias)
	mark_latest_segment_interstitial(segments)
	var tip_direction := (secondary_direction * 0.82 + radial * 0.18).normalized()
	var tip := append_node(nodes, segments, nodes[secondary].get("position", Vector3.ZERO) + tip_direction * length * 0.22, secondary, 3, tip_direction)
	tag_stratum(nodes, tip, stratum_bias)
	mark_latest_segment_interstitial(segments)

func mark_latest_segment_interstitial(segments: Array[Dictionary]) -> void:
	if segments.is_empty():
		return
	var segment: Dictionary = segments[segments.size() - 1]
	segment["interstitial"] = true
	segments[segments.size() - 1] = segment

func build_needle_foliage(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	crown_center: Vector3,
	crown_radii: Vector3,
	height: float,
	seed: int
) -> Array[Dictionary]:
	var foliage: Array[Dictionary] = []
	for segment_index in range(segments.size()):
		if foliage.size() >= MAX_CONIFER_FOLIAGE_CLUSTERS:
			break
		var segment: Dictionary = segments[segment_index]
		var order := int(segment.get("order", 0))
		if order < 2:
			continue
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		if parent_index < 0 or child_index < 0 or child_index >= nodes.size():
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = nodes[child_index].get("position", Vector3.UP)
		var direction := (end - start).normalized()
		var length := start.distance_to(end)
		# Needle clusters are substantially denser than broadleaf anchors, but the
		# branchlet curtain already supplies depth. Keep each carrier bounded so
		# density comes from many valid branchlets rather than a saturated cap.
		# Two instanced needle sprays cover each valid branchlet segment. Their
		# density comes from the fine-wood network, not a forest of Node3Ds.
		var cluster_count := 1 if bool(segment.get("interstitial", false)) else 2
		var side := direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var normal := direction.cross(side).normalized()
		for cluster_index in range(cluster_count):
			if foliage.size() >= MAX_CONIFER_FOLIAGE_CLUSTERS:
				break
			var unit := (float(cluster_index) + 0.44) / float(cluster_count)
			var jitter_a := stable_signed("needle-a:%d:%d:%d" % [seed, segment_index, cluster_index])
			var jitter_b := stable_signed("needle-b:%d:%d:%d" % [seed, segment_index, cluster_index])
			var position := start.lerp(end, clampf(unit + jitter_a * 0.09, 0.12, 1.0))
			position += side * jitter_a * 0.34 + normal * jitter_b * 0.28
			var local := position - crown_center
			var envelope := Vector3(
				local.x / maxf(0.1, crown_radii.x),
				local.y / maxf(0.1, crown_radii.y),
				local.z / maxf(0.1, crown_radii.z)
			).length()
			var exposure := clampf((envelope - 0.16) / 0.84, 0.0, 1.0)
			var scale := lerpf(1.22, 2.05, exposure) * lerpf(1.10, 0.82, clampf(local.y / maxf(1.0, height), 0.0, 1.0))
			foliage.append({
				"position": position,
				"rotation": Vector3(
					stable_signed("needle-rx:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.18,
					stable_unit("needle-ry:%d:%d:%d" % [seed, segment_index, cluster_index]) * TAU,
					stable_signed("needle-rz:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.16
				),
				"scale": Vector3(scale * 0.86, scale * 0.72, scale * 0.86),
				"windWeight": clampf(position.y / maxf(1.0, height), 0.18, 1.0),
				"variation": clampf(0.18 + exposure * 0.58 + stable_unit("needle-color:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.18, 0.0, 1.0),
				"clusterVariant": posmod(stable_hash("needle-variant:%d:%d:%d" % [seed, segment_index, cluster_index]), 4),
				"sourceSegment": segment_index,
				"sourceOrder": order,
				"exposure": exposure
			})
	return foliage

func nearest_trunk_node(nodes: Array[Dictionary], trunk_nodes: Array[int], y: float) -> int:
	var selected := trunk_nodes[0]
	var nearest_distance := INF
	for node_index in trunk_nodes:
		var position: Vector3 = nodes[node_index].get("position", Vector3.ZERO)
		var distance := absf(position.y - y)
		if distance < nearest_distance:
			nearest_distance = distance
			selected = node_index
	return selected

func tag_stratum(nodes: Array[Dictionary], node_index: int, value: float) -> void:
	var node: Dictionary = nodes[node_index]
	node["stratumBias"] = clampf(value, -1.0, 1.0)
	nodes[node_index] = node

func mean_float_values(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())
