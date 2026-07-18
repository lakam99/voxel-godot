extends "res://scripts/environment/tree_grammars/MathematicalTreePocRecipeBuilder.gd"

## VOX-141 approved umbrella-thorn-like mathematical grammar.
##
## This is a distinct species grammar: a finite, multi-forked lateral tree
## rather than a broadleaf crown compressed along Y.  It produces only pure
## recipe data and deliberately does not touch world generation or gameplay.

const SAVANNA_RECIPE_VERSION := 2
const MAX_SAVANNA_BRANCH_SEGMENTS := 1120
const MAX_SAVANNA_FOLIAGE_CLUSTERS := 1540
const MAX_RAISED_FORKS := 6
# Keep an explicit reserve for the pipe-driven second growth phase. The initial
# raised-fork scaffold must never consume the total tree budget by itself.
const MAX_SAVANNA_SCAFFOLD_SEGMENTS := 760

func build_recipe(seed := DEFAULT_SEED, maturity := 0.92, _growth_profile: Dictionary = {}) -> Dictionary:
	var resolved_seed := int(seed)
	var resolved_maturity := clampf(float(maturity), 0.12, 1.0)
	# Umbrella thorns stay proportionately lower and wider than the other two
	# grammars.  Maturity extends the raised forks and lateral reach first, then
	# makes the crown more complex; it never uniformly scales a prefab shape.
	var normalized_growth := (1.0 - exp(-3.25 * resolved_maturity)) / (1.0 - exp(-3.25))
	var height := lerpf(10.5, 29.5, normalized_growth)
	var trunk_radius := lerpf(0.58, 2.48, pow(normalized_growth, 0.71))
	var fork_height := lerpf(3.4, 8.8, pow(normalized_growth, 0.83))
	var canopy_radius := lerpf(7.0, 23.5, pow(normalized_growth, 0.86))
	var crown_depth := lerpf(3.8, 9.6, pow(normalized_growth, 0.78))
	var crown_center := Vector3(0.0, fork_height + crown_depth * 0.72, 0.0)
	var crown_radii := Vector3(canopy_radius, crown_depth * 0.66, canopy_radius * 0.91)

	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	build_twisted_trunk(nodes, raw_segments, trunk_nodes, fork_height, resolved_seed)
	var crown_stats := build_raised_fork_crown(
		nodes,
		raw_segments,
		trunk_nodes,
		fork_height,
		canopy_radius,
		crown_depth,
		normalized_growth,
		resolved_seed
	)

	# The initial fork scaffold establishes the mature tree's primary wood. A
	# preliminary pipe solve then lets viable non-bole axes spend their actual
	# carrying radius on successor shoots. This is the same developmental rule
	# learned from the oak PoC, expressed as a shallow savanna umbrella rather
	# than a dome or a hand-authored layer count.
	var preliminary_pipe := solve_pipe_model(nodes, raw_segments, trunk_radius, height, fork_height)
	var viable_axis_stats := germinate_viable_savanna_axes(
		nodes,
		raw_segments,
		preliminary_pipe,
		crown_center,
		crown_radii,
		canopy_radius,
		resolved_seed
	)
	var pipe_result := solve_pipe_model(nodes, raw_segments, trunk_radius, height, fork_height)
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	var foliage := build_perforated_umbrella_foliage(
		nodes,
		raw_segments,
		crown_center,
		crown_radii,
		height,
		resolved_seed
	)
	var counts := segment_counts_by_order(raw_segments)
	var connected := graph_is_connected(nodes, raw_segments)
	var occupancy := crown_occupancy(foliage, crown_center, crown_radii)
	var major_reach := maximum_major_wood_reach(branches)
	var signature := recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)

	return {
		"recipeVersion": SAVANNA_RECIPE_VERSION,
		"methodology": "deterministic_raised_fork_allometric_axis_pipe_model",
		"architecture": "savanna",
		"speciesGrammar": "umbrella_thorn_like_poc",
		"crownHabit": "wide_perforated_irregular_umbrella",
		"seed": resolved_seed,
		"maturity": resolved_maturity,
		"height": height,
		"trunkRadius": trunk_radius,
		"canopyRadius": canopy_radius,
		"crownBase": fork_height,
		"crownHeight": crown_depth,
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
			"raisedForkCount": int(crown_stats.get("raisedForkCount", 0)),
			"maxMajorScaffoldReach": major_reach,
			"meanLateralScaffoldPitch": float(crown_stats.get("meanLateralScaffoldPitch", 0.0)),
			"crownVerticalToHorizontalRatio": crown_depth / maxf(0.1, canopy_radius * 2.0),
			"crownWindowCount": int(crown_stats.get("crownWindowCount", 0)),
			"viableAxisBudCount": int(viable_axis_stats.get("viableAxisBudCount", 0)),
			"germinatedAxisCount": int(viable_axis_stats.get("germinatedAxisCount", 0)),
			"grownMetamerCount": int(viable_axis_stats.get("grownMetamerCount", 0)),
			"girthEligibleLength": float(viable_axis_stats.get("girthEligibleLength", 0.0)),
			"girthWeightedBudCharge": float(viable_axis_stats.get("girthWeightedBudCharge", 0.0)),
			"continuousTrunkPath": trunk_nodes.size() >= 7,
			"connected": connected,
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"foliageDerivedFromFineSegments": true,
			"budgetSaturation": {
				"branchSegments": float(branches.size()) / float(MAX_SAVANNA_BRANCH_SEGMENTS),
				"foliageClusters": float(foliage.size()) / float(MAX_SAVANNA_FOLIAGE_CLUSTERS),
				"branchLimitReached": raw_segments.size() >= MAX_SAVANNA_BRANCH_SEGMENTS,
				"foliageLimitReached": foliage.size() >= MAX_SAVANNA_FOLIAGE_CLUSTERS
			}
		}
	}

func build_twisted_trunk(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	fork_height: float,
	seed: int
) -> int:
	var root := append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var previous := root
	var step_count := maxi(7, ceili(fork_height / 0.92))
	var phase := stable_unit("savanna-trunk-phase:%d" % seed) * TAU
	for step_index in range(1, step_count + 1):
		var unit := float(step_index) / float(step_count)
		# The low-frequency offset makes one sealed, growing trunk read as an old
		# living column instead of stacked vertical cylinders.
		var sway := pow(unit, 1.45) * lerpf(0.16, 0.86, stable_unit("savanna-trunk-sway:%d" % seed))
		var position := Vector3(
			cos(phase + unit * 2.45) * sway + sin(unit * 5.2 + phase) * 0.13 * unit,
			fork_height * unit,
			sin(phase + unit * 2.04) * sway + cos(unit * 4.7 + phase) * 0.13 * unit
		)
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var direction := (position - start).normalized()
		previous = append_node(nodes, segments, position, previous, 0, direction)
		trunk_nodes.append(previous)
	return previous

func build_raised_fork_crown(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	fork_height: float,
	canopy_radius: float,
	crown_depth: float,
	normalized_growth: float,
	seed: int
) -> Dictionary:
	# The number of durable leaders follows the available mature crown perimeter,
	# moderated by age, rather than a fixed species row.  A savanna crown remains
	# finite and decurrent, but different seeds distribute viable axes differently
	# around the whole trunk.
	var leader_spacing := lerpf(7.6, 5.2, normalized_growth) * lerpf(0.88, 1.12, stable_unit("savanna-leader-spacing:%d" % seed))
	var fork_count := clampi(
		roundi(TAU * maxf(2.0, canopy_radius * 0.34) / maxf(2.4, leader_spacing)),
		3,
		MAX_RAISED_FORKS
	)
	var phase := stable_unit("savanna-fork-phase:%d" % seed) * TAU
	var pitch_sum := 0.0
	var pitch_count := 0
	var crown_window_count := 0
	for fork_index in range(fork_count):
		if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
			break
		var fork_phase := phase + float(fork_index) * TAU / float(fork_count)
		fork_phase += stable_signed("savanna-fork-angle:%d:%d" % [seed, fork_index]) * 0.26
		var radial := Vector3(cos(fork_phase), 0.0, sin(fork_phase))
		var side := radial.cross(Vector3.UP).normalized()
		# Successive leaders leave different, nearby points on the living trunk.
		# This is the multi-fork morphology of a savanna tree—not five tubes
		# welded to a single Y-shaped pinch point.
		var attachment_back := 1 + posmod(fork_index * 3, mini(5, maxi(1, trunk_nodes.size() - 2)))
		var fork_parent := trunk_nodes[maxi(2, trunk_nodes.size() - 1 - attachment_back)]
		var main_steps := clampi(ceili(canopy_radius / lerpf(4.60, 3.55, normalized_growth)), 4, 7)
		var previous := fork_parent
		var primary_nodes: Array[int] = []
		for step_index in range(main_steps):
			if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
				break
			var unit := float(step_index + 1) / float(main_steps)
			# Raised limbs begin upright and progressively spread into long laterals.
			var lift := lerpf(0.96, 0.06, unit) + stable_signed("savanna-fork-lift:%d:%d:%d" % [seed, fork_index, step_index]) * 0.10
			var curve := stable_signed("savanna-fork-curve:%d:%d:%d" % [seed, fork_index, step_index]) * 0.15
			var direction := (radial * 1.0 + side * curve + Vector3.UP * lift).normalized()
			var step_length := canopy_radius / float(main_steps) * lerpf(0.94, 1.12, stable_unit("savanna-fork-step:%d:%d:%d" % [seed, fork_index, step_index]))
			var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
			var current := append_node(nodes, segments, start + direction * step_length, previous, 1, direction)
			tag_stratum(nodes, current, -0.28 + unit * 0.54)
			primary_nodes.append(current)
			pitch_sum += direction.y
			pitch_count += 1
			previous = current
		for primary_index in range(1, primary_nodes.size()):
			if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
				break
			var branch_parent := primary_nodes[primary_index]
			var primary_unit := float(primary_index) / float(maxi(1, primary_nodes.size() - 1))
			var remaining_reach := canopy_radius * lerpf(0.34, 0.54, primary_unit)
			var local_girth_proxy := remaining_reach / maxf(1.0, canopy_radius)
			var arm_bud_charge := remaining_reach / lerpf(4.20, 3.05, primary_unit) \
				* lerpf(0.86, 1.14, local_girth_proxy)
			var arm_count := clampi(
				floori(arm_bud_charge + stable_unit("savanna-arm-phase:%d:%d:%d" % [seed, fork_index, primary_index])),
				1,
				3
			)
			for arm_index in range(arm_count):
				if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
					break
				var arm_sign := -1.0 if arm_index % 2 == 0 else 1.0
				var terminal_bias := 0.30 if arm_index == 2 else 0.0
				var arm_direction := (
					radial * (0.78 + terminal_bias)
					+ side * arm_sign * (0.60 - terminal_bias * 0.30)
					+ Vector3.UP * (0.18 + stable_signed("savanna-arm-rise:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index]) * 0.22)
				).normalized()
				var arm_length := remaining_reach * lerpf(0.78, 1.12, stable_unit("savanna-arm-reach:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index]))
				arm_length *= lerpf(0.80, 1.12, stable_unit("savanna-arm-length:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index]))
				append_lateral_arm_and_twig_fans(
					nodes,
					segments,
					branch_parent,
					arm_direction,
					radial,
					side * arm_sign,
					arm_length,
					fork_index,
					primary_index,
					arm_index,
					seed
				)
				crown_window_count += 1
	return {
		"raisedForkCount": fork_count,
		"meanLateralScaffoldPitch": pitch_sum / float(maxi(1, pitch_count)),
		"crownWindowCount": crown_window_count
	}

func append_lateral_arm_and_twig_fans(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	direction: Vector3,
	radial: Vector3,
	side: Vector3,
	arm_length: float,
	fork_index: int,
	primary_index: int,
	arm_index: int,
	seed: int
) -> void:
	var previous := parent
	var arm_steps := clampi(ceili(arm_length / 3.35), 2, 4)
	for arm_step in range(arm_steps):
		if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
			return
		var arm_unit := float(arm_step + 1) / float(arm_steps)
		var arch := lerpf(0.20, -0.11, arm_unit)
		var bend := stable_signed("savanna-arm-bend:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step]) * 0.13
		var arm_direction := (direction + radial * 0.18 + side * bend + Vector3.UP * arch).normalized()
		var start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var current := append_node(nodes, segments, start + arm_direction * arm_length / float(arm_steps), previous, 2, arm_direction)
		tag_stratum(nodes, current, -0.16 + arm_unit * 0.32)
		append_fine_twig_fan(nodes, segments, current, radial, side, arm_length, fork_index, primary_index, arm_index, arm_step, seed)
		previous = current

func append_fine_twig_fan(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	parent: int,
	radial: Vector3,
	side: Vector3,
	arm_length: float,
	fork_index: int,
	primary_index: int,
	arm_index: int,
	arm_step: int,
	seed: int
) -> void:
	# Base scaffold twigs establish the crown's first living surface. Later the
	# pipe-driven pass spends unused carrying capacity where it is viable, so this
	# seed stage must leave capacity rather than saturating every arm uniformly.
	var twig_charge := arm_length / 5.10
	var twig_count := clampi(
		floori(twig_charge + stable_unit("savanna-twig-phase:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step])),
		1,
		2
	)
	for twig_index in range(twig_count):
		if segments.size() >= MAX_SAVANNA_SCAFFOLD_SEGMENTS:
			return
		var sign := -1.0 if twig_index % 2 == 0 else 1.0
		var spread := side * sign * lerpf(0.38, 0.70, stable_unit("savanna-twig-spread:%d:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step, twig_index]))
		var rise := lerpf(-0.12, 0.26, stable_unit("savanna-twig-rise:%d:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step, twig_index]))
		var direction := (radial * 0.66 + spread + Vector3.UP * rise).normalized()
		var length := arm_length * lerpf(0.19, 0.31, stable_unit("savanna-twig-length:%d:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step, twig_index]))
		var start: Vector3 = nodes[parent].get("position", Vector3.ZERO)
		var twig := append_node(nodes, segments, start + direction * length, parent, 3, direction)
		tag_stratum(nodes, twig, stable_signed("savanna-twig-stratum:%d:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step, twig_index]) * 0.50)
		var tip_direction := (direction * 0.82 + radial * 0.16 + Vector3.UP * 0.08).normalized()
		var tip := append_node(nodes, segments, nodes[twig].get("position", Vector3.ZERO) + tip_direction * length * 0.72, twig, 4, tip_direction)
		tag_stratum(nodes, tip, stable_signed("savanna-tip-stratum:%d:%d:%d:%d:%d:%d" % [seed, fork_index, primary_index, arm_index, arm_step, twig_index]) * 0.60)

func germinate_viable_savanna_axes(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	preliminary_pipe: Dictionary,
	crown_center: Vector3,
	crown_radii: Vector3,
	canopy_radius: float,
	seed: int
) -> Dictionary:
	# Only non-bole axes may branch in this pass. A bud comes from a solved
	# carrying radius, has to fund a multi-metamer shoot, and grows outward within
	# the crown's shallow space. That replaces the old "one more fan here" shape
	# rule with a bounded, family-specific growth decision.
	var original_segment_count := segments.size()
	var node_radii: Array = preliminary_pipe.get("nodeRadii", [])
	var viable_axis_bud_count := 0
	var germinated_axis_count := 0
	var grown_metamer_count := 0
	var girth_eligible_length := 0.0
	var girth_weighted_bud_charge := 0.0
	for segment_index in range(original_segment_count):
		if segments.size() >= MAX_SAVANNA_BRANCH_SEGMENTS:
			break
		var segment: Dictionary = segments[segment_index]
		var order := int(segment.get("order", 0))
		if order < 1 or order > 2:
			continue
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		if parent_index < 0 or child_index < 0 or child_index >= nodes.size() or child_index >= node_radii.size():
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var position: Vector3 = nodes[child_index].get("position", Vector3.ZERO)
		var segment_length := start.distance_to(position)
		var carrying_radius := float(node_radii[child_index])
		var minimum_radius := 0.24 if order == 1 else 0.15
		if carrying_radius < minimum_radius or segment_length < 0.34:
			continue
		var local := position - crown_center
		var horizontal := Vector3(local.x, 0.0, local.z)
		if horizontal.length_squared() < 0.001:
			horizontal = (position - start).slide(Vector3.UP)
		if horizontal.length_squared() < 0.001:
			continue
		var outward := horizontal.normalized()
		var crown_unit := clampf(horizontal.length() / maxf(1.0, canopy_radius), 0.0, 1.0)
		var vertical_unit := clampf((position.y - (crown_center.y - crown_radii.y)) / maxf(0.1, crown_radii.y * 2.0), 0.0, 1.0)
		# A stronger axis earns a denser bud rhythm. Interior and mid-crown wood
		# is favoured so the tree fills its living umbrella instead of only adding
		# leaves at its terminal shell.
		var girth_drive := pow(maxf(1.0, carrying_radius / minimum_radius), 0.58)
		var interior_space := pow(1.0 - crown_unit, 0.42) * lerpf(0.78, 1.0, vertical_unit)
		var bud_charge := segment_length * 0.78 * girth_drive * interior_space
		girth_eligible_length += segment_length
		girth_weighted_bud_charge += bud_charge
		var established_buds := clampi(
			floori(bud_charge + stable_unit("savanna-viable-bud-phase:%d:%d" % [seed, segment_index])),
			0,
			2 if order == 1 else 1
		)
		if established_buds <= 0:
			continue
		var side := outward.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		for bud_index in range(established_buds):
			if segments.size() >= MAX_SAVANNA_BRANCH_SEGMENTS:
				break
			viable_axis_bud_count += 1
			var sign := -1.0 if (segment_index + bud_index) % 2 == 0 else 1.0
			var lateral_fraction := lerpf(0.30, 0.62, stable_unit("savanna-viable-axis-lateral:%d:%d:%d" % [seed, segment_index, bud_index]))
			var rise := lerpf(-0.05, 0.20, stable_unit("savanna-viable-axis-rise:%d:%d:%d" % [seed, segment_index, bud_index]))
			var heading := (outward * 0.78 + side * sign * lateral_fraction + Vector3.UP * rise).normalized()
			var span := maxf(1.35, carrying_radius * 4.35) * lerpf(0.80, 1.16, interior_space)
			span *= lerpf(0.88, 1.10, stable_unit("savanna-viable-axis-span:%d:%d:%d" % [seed, segment_index, bud_index]))
			var available_span := maxf(0.0, canopy_radius * 1.08 - horizontal.length())
			span = minf(span, maxf(0.0, available_span))
			if span < 1.05:
				continue
			var metamer_count := clampi(ceili(span / 1.55), 2, 4)
			var previous := child_index
			var current_heading := heading
			var grown := 0
			for metamer_index in range(metamer_count):
				if segments.size() >= MAX_SAVANNA_BRANCH_SEGMENTS:
					break
				var metamer_unit := float(metamer_index + 1) / float(metamer_count)
				var arch := lerpf(0.16, -0.09, metamer_unit)
				var bend := stable_signed("savanna-viable-axis-bend:%d:%d:%d:%d" % [seed, segment_index, bud_index, metamer_index]) * 0.12
				current_heading = (current_heading * 0.78 + outward * 0.16 + side * bend + Vector3.UP * arch).normalized()
				var metamer_start: Vector3 = nodes[previous].get("position", Vector3.ZERO)
				var endpoint := metamer_start + current_heading * span / float(metamer_count)
				var endpoint_local := endpoint - crown_center
				var endpoint_horizontal := Vector2(endpoint_local.x, endpoint_local.z)
				if endpoint_horizontal.length() > canopy_radius * 1.10:
					break
				if absf(endpoint_local.y) > crown_radii.y * 1.24:
					break
				var current := append_node(nodes, segments, endpoint, previous, mini(order + 1, 4), current_heading)
				tag_stratum(nodes, current, clampf(vertical_unit * 2.0 - 1.0, -1.0, 1.0))
				previous = current
				grown += 1
			if grown >= 2:
				germinated_axis_count += 1
				grown_metamer_count += grown
	return {
		"viableAxisBudCount": viable_axis_bud_count,
		"germinatedAxisCount": germinated_axis_count,
		"grownMetamerCount": grown_metamer_count,
		"girthEligibleLength": girth_eligible_length,
		"girthWeightedBudCharge": girth_weighted_bud_charge
	}

func build_perforated_umbrella_foliage(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	crown_center: Vector3,
	crown_radii: Vector3,
	height: float,
	seed: int
) -> Array[Dictionary]:
	# Discover every leaf site on actual supporting wood before applying the
	# foliage budget. The new pipe-driven axes are appended after the initial
	# scaffold, so stopping while walking graph order would leave their living
	# tips bare and recreate an authored-looking canopy edge.
	var candidates: Array[Dictionary] = []
	for segment_index in range(segments.size()):
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
		var child: Dictionary = nodes[child_index]
		var terminal := (child.get("children", []) as Array).is_empty()
		var direction := (end - start).normalized()
		var side := direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var normal := direction.cross(side).normalized()
		# Deliberate skipped carriers preserve sunlight windows.  Perforation comes
		# from real sparse twig zones, not a flattened foliage layer or hidden mask.
		if stable_unit("savanna-window:%d:%d" % [seed, segment_index]) < 0.18:
			continue
		# Secondary wood carries small interior leaf groups while finer or terminal
		# wood carries the sun-facing surface. Capacity is local to each viable
		# branch, never a flattened canopy mask.
		var cluster_count := 1 if order == 2 else 2
		for cluster_index in range(cluster_count):
			var unit := (float(cluster_index) + 0.40) / float(cluster_count)
			var jitter_a := stable_signed("savanna-leaf-a:%d:%d:%d" % [seed, segment_index, cluster_index])
			var jitter_b := stable_signed("savanna-leaf-b:%d:%d:%d" % [seed, segment_index, cluster_index])
			var position := start.lerp(end, clampf(unit + jitter_a * 0.13, 0.10, 1.0))
			position += side * jitter_a * 0.58 + normal * jitter_b * 0.42
			var local := position - crown_center
			var envelope := Vector3(
				local.x / maxf(0.1, crown_radii.x),
				local.y / maxf(0.1, crown_radii.y),
				local.z / maxf(0.1, crown_radii.z)
			).length()
			var exposure := clampf((envelope - 0.12) / 0.88, 0.0, 1.0)
			var priority := exposure * 0.40 + float(order) / 4.0 * 0.20 \
				+ (0.24 if terminal else 0.0) \
				+ stable_unit("savanna-leaf-priority:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.16
			candidates.append({
				"position": position,
				"sourceSegment": segment_index,
				"sourceOrder": order,
				"terminal": terminal,
				"clusterIndex": cluster_index,
				"exposure": exposure,
				"priority": priority
			})
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("priority", 0.0)) > float(right.get("priority", 0.0))
	)
	var foliage: Array[Dictionary] = []
	var leaf_budget := mini(MAX_SAVANNA_FOLIAGE_CLUSTERS, candidates.size())
	for candidate_index in range(leaf_budget):
		var candidate: Dictionary = candidates[candidate_index]
		var position: Vector3 = candidate.get("position", Vector3.ZERO)
		var segment_index := int(candidate.get("sourceSegment", -1))
		var cluster_index := int(candidate.get("clusterIndex", 0))
		var exposure := float(candidate.get("exposure", 0.0))
		var scale := lerpf(1.38, 2.54, exposure) * lerpf(0.94, 1.10, stable_unit("savanna-leaf-size:%d:%d:%d" % [seed, segment_index, cluster_index]))
		if bool(candidate.get("terminal", false)):
			scale *= 1.08
		foliage.append({
			"position": position,
			"rotation": Vector3(
				stable_signed("savanna-leaf-rx:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.21,
				stable_unit("savanna-leaf-ry:%d:%d:%d" % [seed, segment_index, cluster_index]) * TAU,
				stable_signed("savanna-leaf-rz:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.18
			),
			"scale": Vector3(scale * 1.40, scale * 1.04, scale * 1.27),
			"windWeight": clampf(position.y / maxf(1.0, height), 0.20, 1.0),
			"variation": clampf(0.16 + exposure * 0.56 + stable_unit("savanna-leaf-color:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.24, 0.0, 1.0),
			"clusterVariant": posmod(stable_hash("savanna-leaf-variant:%d:%d:%d" % [seed, segment_index, cluster_index]), 4),
			"sourceSegment": segment_index,
			"sourceOrder": int(candidate.get("sourceOrder", 0)),
			"exposure": exposure
		})
	return foliage

func tag_stratum(nodes: Array[Dictionary], node_index: int, value: float) -> void:
	var node: Dictionary = nodes[node_index]
	node["stratumBias"] = clampf(value, -1.0, 1.0)
	nodes[node_index] = node
