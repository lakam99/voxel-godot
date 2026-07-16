extends RefCounted
class_name MathematicalTreePocRecipeBuilder

## VOX-138 proof-of-concept recipe builder.
##
## This intentionally lives under testing until the visual review gate passes. It
## produces pure numeric data and never touches the SceneTree, Resources, global
## world RNG, biome placement, saves, collision, or gameplay systems.

const RECIPE_VERSION := 2
const DEFAULT_SEED := 0x4D415448
const MAX_ATTRACTION_POINTS := 560
const MAX_GROWTH_ITERATIONS := 23
const MAX_BRANCH_SEGMENTS := 1050
const MAX_FOLIAGE_CLUSTERS := 1250
const GOLDEN_ANGLE := 2.399963229728653

const CROWN_INFLUENCE_DISTANCE := 7.4
const CROWN_KILL_DISTANCE := 1.35
const MIN_ENDPOINT_SEPARATION := 0.52

func build_recipe(seed := DEFAULT_SEED, maturity := 0.92) -> Dictionary:
	var resolved_seed := int(seed)
	var resolved_maturity := clampf(float(maturity), 0.12, 1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = resolved_seed

	# Bounded allometry: ancient trees approach, but never exceed, their species
	# ceiling. Age changes the architecture instead of uniformly scaling a mesh.
	var normalized_growth := (1.0 - exp(-3.45 * resolved_maturity)) / (1.0 - exp(-3.45))
	var height := lerpf(16.0, 47.0, normalized_growth)
	var trunk_radius := lerpf(0.72, 3.15, pow(normalized_growth, 0.72))
	# Reach is a crown architecture trait, not a hidden trunk-thinning scale.  It
	# deliberately rises faster than trunk width so a mature tree reads as a
	# wide, load-bearing organism instead of a dense ball on a monumental pole.
	# Future grammars inherit this ratio while choosing their own silhouette.
	var branch_reach_factor := lerpf(1.14, 1.38, pow(normalized_growth, 0.72))
	var crown_radius := lerpf(6.0, 20.4, pow(normalized_growth, 0.86)) * branch_reach_factor
	var crown_height := lerpf(9.2, height * 0.76, pow(normalized_growth, 0.92))
	var crown_base := maxf(5.8, height - crown_height)
	var crown_center := Vector3(0.0, crown_base + crown_height * 0.48, 0.0)
	var crown_radii := Vector3(crown_radius, crown_height * 0.43, crown_radius * 0.98)
	var crown_phase := rng.randf() * TAU
	var crown_lobes := build_crown_lobes(rng, crown_center, crown_radii, crown_phase)

	var nodes: Array[Dictionary] = []
	var raw_segments: Array[Dictionary] = []
	var trunk_nodes: Array[int] = []
	build_trunk_and_scaffold_seeds(
		nodes,
		raw_segments,
		trunk_nodes,
		rng,
		height,
		crown_base,
		crown_radius,
		branch_reach_factor,
		resolved_seed
	)

	var attraction_points := build_attraction_points(
		rng,
		crown_center,
		crown_radii,
		crown_phase,
		crown_lobes,
		MAX_ATTRACTION_POINTS
	)
	var initial_attraction_count := attraction_points.size()
	var colonization := colonize_crown(
		nodes,
		raw_segments,
		attraction_points,
		crown_center,
		crown_radii,
		crown_phase,
		branch_reach_factor,
		resolved_seed
	)
	attraction_points = colonization.get("remainingAttractions", attraction_points)
	smooth_non_junction_chains(nodes, 2)

	var pipe_result := solve_pipe_model(nodes, raw_segments, trunk_radius, height, crown_base)
	var branches: Array[Dictionary] = pipe_result.get("branches", [])
	var buttresses := build_root_buttresses(trunk_radius, resolved_seed)
	branches.append_array(buttresses)
	var foliage := build_twig_foliage(
		nodes,
		raw_segments,
		crown_center,
		crown_radii,
		height,
		resolved_seed
	)
	var order_counts := segment_counts_by_order(raw_segments)
	var occupancy := crown_occupancy(foliage, crown_center, crown_radii)
	var stratum_pitch := branch_pitch_by_crown_stratum(branches, crown_center, crown_radii)
	var major_wood_reach := maximum_major_wood_reach(branches)
	var major_wood_reach_to_trunk_width := major_wood_reach / maxf(0.1, trunk_radius * 2.0)
	var connected := graph_is_connected(nodes, raw_segments)
	var signature := recipe_signature(resolved_seed, resolved_maturity, height, branches, foliage)

	return {
		"recipeVersion": RECIPE_VERSION,
		"methodology": "bounded_space_colonization_pipe_model",
		"architecture": "broadleaf",
		"speciesGrammar": "temperate_rounded_broadleaf_poc",
		"crownHabit": "rounded_oval",
		"seed": resolved_seed,
		"maturity": resolved_maturity,
		"height": height,
		"trunkRadius": trunk_radius,
		"branchReachFactor": branch_reach_factor,
		"canopyRadius": crown_radius,
		"crownBase": crown_base,
		"crownHeight": crown_height,
		"crownCenter": crown_center,
		"crownRadii": crown_radii,
		"crownLobes": crown_lobes,
		# The headed PoC opts into one generated wood surface for the entire tree
		# graph. Production callers retain their instanced renderer until this
		# visual gate is explicitly approved and production performance work begins.
		"pocContinuousWood": true,
		"signature": signature,
		"branches": branches,
		"foliage": foliage,
		"branchCount": branches.size(),
		"foliageClusterCount": foliage.size(),
		"stats": {
			"nodeCount": nodes.size(),
			"segmentCountsByOrder": order_counts,
			"attractionPointCount": initial_attraction_count,
			"remainingAttractionPoints": attraction_points.size(),
			"attractionConsumedRatio": 1.0 - float(attraction_points.size()) / float(maxi(1, initial_attraction_count)),
			"growthIterations": int(colonization.get("iterations", 0)),
			"crownLobeCount": crown_lobes.size(),
			"rootButtressCount": buttresses.size(),
			"connected": connected,
			"pipeModelMaxRelativeError": float(pipe_result.get("maxRelativeError", 1.0)),
			"pipeModelJunctionCount": int(pipe_result.get("junctionCount", 0)),
			"crownOccupancy": occupancy,
			"branchPitchByCrownStratum": stratum_pitch,
			"majorWoodReach": major_wood_reach,
			"majorWoodReachToTrunkWidth": major_wood_reach_to_trunk_width,
			"foliageDerivedFromFineSegments": true,
			"budgetSaturation": {
				"attractionPoints": float(initial_attraction_count) / float(MAX_ATTRACTION_POINTS),
				"branchSegments": float(branches.size()) / float(MAX_BRANCH_SEGMENTS),
				"foliageClusters": float(foliage.size()) / float(MAX_FOLIAGE_CLUSTERS),
				"branchLimitReached": branches.size() >= MAX_BRANCH_SEGMENTS,
				"foliageLimitReached": foliage.size() >= MAX_FOLIAGE_CLUSTERS
			}
		}
	}

func build_trunk_and_scaffold_seeds(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_nodes: Array[int],
	rng: RandomNumberGenerator,
	height: float,
	crown_base: float,
	crown_radius: float,
	branch_reach_factor: float,
	seed: int
) -> void:
	var root := append_node(nodes, segments, Vector3.ZERO, -1, 0, Vector3.UP)
	trunk_nodes.append(root)
	var fork_height := crown_base + minf(1.55, height * 0.034)
	var trunk_step := 1.22
	var trunk_steps := maxi(5, ceili(fork_height / trunk_step))
	var lean_angle := rng.randf() * TAU
	var lean_strength := rng.randf_range(0.82, 1.62)
	var previous := root
	for step_index in range(1, trunk_steps + 1):
		var unit := float(step_index) / float(trunk_steps)
		var y := fork_height * unit
		var bend := pow(unit, 1.55) * lean_strength
		var position := Vector3(
			cos(lean_angle) * bend + sin(unit * 2.4 + lean_angle) * 0.22 * unit,
			y,
			sin(lean_angle) * bend + cos(unit * 2.1 + lean_angle) * 0.22 * unit
		)
		var previous_position: Vector3 = nodes[previous].get("position", Vector3.ZERO)
		var direction: Vector3 = (position - previous_position).normalized()
		previous = append_node(nodes, segments, position, previous, 0, direction)
		trunk_nodes.append(previous)

	# Primary scaffold seeds use phyllotaxis and multiple attachment elevations.
	# These are mathematical starting conditions, not authored branch transforms.
	var scaffold_count := 5
	var scaffold_from_end := [3, 2, 2, 1, 1]
	var scaffold_rise := [-0.30, -0.10, 0.12, 0.36, 0.62]
	var scaffold_stratum_bias := [-1.0, -0.52, 0.0, 0.52, 1.0]
	var genetic_phase := stable_unit("scaffold-phase:%d" % seed) * TAU
	for scaffold_index in range(scaffold_count):
		var from_end: int = scaffold_from_end[scaffold_index]
		var attach_node := trunk_nodes[maxi(1, trunk_nodes.size() - 1 - from_end)]
		var angle := genetic_phase + float(scaffold_index) * GOLDEN_ANGLE + rng.randf_range(-0.12, 0.12)
		var horizontal := Vector3(cos(angle), 0.0, sin(angle))
		var rise: float = scaffold_rise[scaffold_index] + rng.randf_range(-0.05, 0.05)
		var direction := (horizontal * rng.randf_range(0.94, 1.10) + Vector3.UP * rise).normalized()
		# Start the primary bough with enough radial momentum to make the
		# underlying skeleton readable beneath its foliage. The trunk remains
		# unchanged; only the organism's reach changes with maturity.
		var scaffold_reach := lerpf(1.10, 1.32, clampf((branch_reach_factor - 1.14) / 0.24, 0.0, 1.0))
		var length := (rng.randf_range(1.82, 2.35) + crown_radius * 0.020) * scaffold_reach
		var start: Vector3 = nodes[attach_node].get("position", Vector3.ZERO)
		var scaffold_node := append_node(nodes, segments, start + direction * length, attach_node, 1, direction)
		var scaffold: Dictionary = nodes[scaffold_node]
		scaffold["stratumBias"] = float(scaffold_stratum_bias[scaffold_index])
		nodes[scaffold_node] = scaffold

func build_crown_lobes(rng: RandomNumberGenerator, center: Vector3, radii: Vector3, phase: float) -> Array[Dictionary]:
	var lobes: Array[Dictionary] = []
	# A central overlapping volume keeps the crown coherent. The surrounding
	# lobes create the irregular silhouette and leader-specific bulges.
	lobes.append({
		"center": center + Vector3.UP * radii.y * 0.02,
		"radii": Vector3(radii.x * 0.69, radii.y * 0.82, radii.z * 0.69),
		"weight": 1.25
	})
	for lobe_index in range(6):
		var angle := phase + float(lobe_index) * GOLDEN_ANGLE + rng.randf_range(-0.16, 0.16)
		var radial_offset := radii.x * rng.randf_range(0.27, 0.46)
		var vertical_offset := radii.y * rng.randf_range(-0.24, 0.25)
		var lobe_center := center + Vector3(cos(angle) * radial_offset, vertical_offset, sin(angle) * radial_offset * 0.92)
		var width := rng.randf_range(0.48, 0.62)
		var depth := rng.randf_range(0.47, 0.61)
		var vertical := rng.randf_range(0.48, 0.66)
		lobes.append({
			"center": lobe_center,
			"radii": Vector3(radii.x * width, radii.y * vertical, radii.z * depth),
			"weight": rng.randf_range(0.82, 1.18)
		})
	return lobes

func build_attraction_points(
	rng: RandomNumberGenerator,
	center: Vector3,
	radii: Vector3,
	phase: float,
	lobes: Array[Dictionary],
	count: int,
	growth_profile: Dictionary = {}
) -> Array[Vector3]:
	var inner_radius := clampf(float(growth_profile.get("attractionInnerRadius", 0.0)), 0.0, 0.92)
	var radial_exponent := maxf(0.05, float(growth_profile.get("attractionRadialExponent", 0.36)))
	var points: Array[Vector3] = []
	points.resize(count)
	for index in range(count):
		var lobe_index := 0 if rng.randf() < 0.18 else rng.randi_range(1, lobes.size() - 1)
		var selected_lobe: Dictionary = lobes[lobe_index]
		var lobe_center: Vector3 = selected_lobe.get("center", center)
		var lobe_radii: Vector3 = selected_lobe.get("radii", radii)
		var azimuth := rng.randf() * TAU
		var vertical_unit := rng.randf_range(-1.0, 1.0)
		var horizontal_unit := sqrt(maxf(0.0, 1.0 - vertical_unit * vertical_unit))
		# A sub-cubic radial exponent biases attraction toward the outer crown,
		# producing foliage-bearing perimeter twigs without hollowing the center.
		var radial := lerpf(inner_radius, 1.0, pow(rng.randf(), radial_exponent))
		var lobe_factor := 0.91 \
			+ sin(azimuth * 3.0 + phase) * 0.055 \
			+ sin(azimuth * 5.0 - phase * 0.61) * 0.035
		var lower_fullness := lerpf(0.82, 1.0, clampf((vertical_unit + 1.0) * 0.5, 0.0, 1.0))
		var unit_point := Vector3(
			cos(azimuth) * horizontal_unit * radial * lobe_factor * lower_fullness,
			vertical_unit * radial,
			sin(azimuth) * horizontal_unit * radial * lobe_factor * lower_fullness
		)
		var point := lobe_center + unit_point * lobe_radii
		# Keep lobe unions bounded by the species-level crown ceiling.
		var main_local := point - center
		var normalized := Vector3(main_local.x / radii.x, main_local.y / radii.y, main_local.z / radii.z)
		if normalized.length() > 1.02:
			normalized = normalized.normalized() * 1.02
			point = center + normalized * radii
		points[index] = point
	return points

func colonize_crown(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	attractions: Array[Vector3],
	crown_center: Vector3,
	crown_radii: Vector3,
	crown_phase: float,
	branch_reach_factor: float,
	seed: int,
	growth_profile: Dictionary = {}
) -> Dictionary:
	var reach_intensity := clampf((branch_reach_factor - 1.14) / 0.24, 0.0, 1.0)
	var influence_multiplier := maxf(0.10, float(growth_profile.get("spaceColonizationInfluenceMultiplier", 1.0)))
	var influence_distance := CROWN_INFLUENCE_DISTANCE * lerpf(1.0, 1.20, reach_intensity) * influence_multiplier
	var influence_squared := influence_distance * influence_distance
	var kill_distance := CROWN_KILL_DISTANCE * maxf(0.1, float(growth_profile.get("killDistanceMultiplier", 1.0)))
	var kill_squared := kill_distance * kill_distance
	var branch_segment_limit := maxi(1, int(growth_profile.get("branchSegmentBudget", MAX_BRANCH_SEGMENTS)))
	var remaining := attractions.duplicate()
	var iterations := 0
	var iteration_budget := maxi(1, int(growth_profile.get("spaceColonizationIterationBudget", MAX_GROWTH_ITERATIONS)))
	for iteration in range(iteration_budget):
		if remaining.is_empty() or segments.size() >= branch_segment_limit:
			break
		iterations = iteration + 1
		var influenced := {}
		var survivors: Array[Vector3] = []
		for attraction in remaining:
			var nearest_index := -1
			var nearest_distance := INF
			for node_index in range(nodes.size()):
				var node: Dictionary = nodes[node_index]
				var position: Vector3 = node.get("position", Vector3.ZERO)
				if position.y < crown_center.y - crown_radii.y - crown_radii.y * 0.30:
					continue
				var children: Array = node.get("children", [])
				var order := int(node.get("order", 0))
				# A species may expose latent trunk buds to crown-space competition. The
				# generic case remains a terminated trunk; the oak profile activates only
				# mid-crown buds with both local developmental potential and available
				# horizontal crown space.
				if order == 0 and not trunk_bud_can_compete(
					position, attraction, crown_center, crown_radii, node_index, seed, growth_profile
				):
					continue
				var max_children := local_bud_child_capacity(
					position, order, crown_center, crown_radii, growth_profile
				)
				if children.size() >= max_children:
					continue
				if not attraction_is_ahead_of_growth(node, position, attraction, order, growth_profile):
					continue
				var distance := position.distance_squared_to(attraction)
				if distance < nearest_distance:
					nearest_distance = distance
					nearest_index = node_index
			if nearest_distance <= kill_squared:
				continue
			survivors.append(attraction)
			if nearest_index < 0 or nearest_distance > influence_squared:
				continue
			var nearest_position: Vector3 = nodes[nearest_index].get("position", Vector3.ZERO)
			var direction: Vector3 = (attraction - nearest_position).normalized()
			var row: Dictionary = influenced.get(nearest_index, {"sum": Vector3.ZERO, "count": 0})
			row["sum"] = row.get("sum", Vector3.ZERO) + direction
			row["count"] = int(row.get("count", 0)) + 1
			influenced[nearest_index] = row
		remaining = survivors
		if influenced.is_empty():
			break

		var added := 0
		var influenced_indices := influenced.keys()
		influenced_indices.sort()
		for node_key in influenced_indices:
			if segments.size() >= branch_segment_limit:
				break
			var node_index := int(node_key)
			var node: Dictionary = nodes[node_index]
			var children: Array = node.get("children", [])
			var parent_order := int(node.get("order", 0))
			var order_run := int(node.get("orderRun", 0))
			var position: Vector3 = node.get("position", Vector3.ZERO)
			var max_children := local_bud_child_capacity(
				position, parent_order, crown_center, crown_radii, growth_profile
			)
			# Longer major runs create a proportionate bough before it divides into
			# successively finer wood. This preserves trunk allometry while giving
			# the crown an English-oak-like horizontal reach.
			var run_limits := [999, 8, 7, 4, 3]
			var child_order := parent_order
			# A single existing child represents the continuing bough. Advance to a
			# finer generation only after a real fork or after the order's run limit;
			# this yields long primary/secondary scaffolds rather than a compact,
			# candelabra-like crown.
			if parent_order == 0:
				child_order = 1
			elif children.size() >= max_children or order_run >= int(run_limits[parent_order]):
				child_order = mini(4, parent_order + 1)
			var row: Dictionary = influenced[node_key]
			var attraction_direction: Vector3 = row.get("sum", Vector3.UP)
			if attraction_direction.length_squared() < 0.0001:
				continue
			attraction_direction = attraction_direction.normalized()
			var parent_direction: Vector3 = node.get("direction", Vector3.UP)
			var attraction_vertical_scale := [1.0, 0.30, 0.42, 0.72, 1.0]
			var shaped_attraction := Vector3(
				attraction_direction.x,
				attraction_direction.y * float(attraction_vertical_scale[child_order]),
				attraction_direction.z
			).normalized()
			var radial := Vector3(position.x - crown_center.x, 0.0, position.z - crown_center.z)
			if radial.length_squared() < 0.001:
				if parent_order == 0 and bool(growth_profile.get("allowMidCrownTrunkBuds", false)):
					var phyllotactic_angle := crown_phase + float(node_index) * GOLDEN_ANGLE
					radial = Vector3(cos(phyllotactic_angle), 0.0, sin(phyllotactic_angle))
				else:
					radial = Vector3(parent_direction.x, 0.0, parent_direction.z)
				if radial.length_squared() < 0.001:
					radial = Vector3(cos(crown_phase), 0.0, sin(crown_phase))
			radial = radial.normalized()
			var dome_axis := inherited_dome_axis(node, position, crown_center, parent_direction, crown_phase)
			var dome_heading := inherited_dome_heading(node, parent_direction, dome_axis)
			if parent_order == 0 and bool(growth_profile.get("allowMidCrownTrunkBuds", false)):
				dome_axis = radial
				dome_heading = (radial + Vector3.UP * 0.12).normalized()
			var crown_bottom := crown_center.y - crown_radii.y
			var crown_unit := clampf((position.y - crown_bottom) / maxf(0.1, crown_radii.y * 2.0), 0.0, 1.0)
			var centered_height := crown_unit * 2.0 - 1.0
			var signed_height_curve := signf(centered_height) * pow(absf(centered_height), 0.78)
			var inherited_stratum_bias := clampf(float(node.get("stratumBias", signed_height_curve)), -1.0, 1.0)
			var stratum_inheritance := [0.0, 0.82, 0.74, 0.46, 0.20]
			var structural_height_curve := lerpf(
				signed_height_curve,
				inherited_stratum_bias,
				float(stratum_inheritance[child_order])
			)
			var vertical_curve_strength := [0.0, 0.68, 0.54, 0.29, 0.12]
			var terminal_light_recovery := [0.0, 0.0, 0.015, 0.055, 0.12]
			var outward_curve_strength := [0.0, 0.17, 0.14, 0.09, 0.05]
			var profile_outward_strength := profile_order_value(
				growth_profile, "outwardWeightByOrder", child_order, float(outward_curve_strength[child_order])
			)
			var vertical_curve := structural_height_curve * float(vertical_curve_strength[child_order]) \
				+ float(terminal_light_recovery[child_order])
			var gravity := Vector3.DOWN * (0.030 if child_order <= 2 else 0.008)
			var noise := stable_noise_vector(seed, node_index, iteration) * lerpf(0.12, 0.055, float(child_order) / 4.0)
			var direction: Vector3 = (
				shaped_attraction * 0.62
				+ parent_direction * 0.19
				+ radial * profile_outward_strength
				+ Vector3.UP * vertical_curve
				+ gravity
				+ noise
			).normalized()
			var minimum_pitch := -0.55 if child_order <= 2 else -0.40
			if direction.y < minimum_pitch:
				direction.y = minimum_pitch
				direction = direction.normalized()
			if bool(growth_profile.get("enforceOutwardDome", false)):
				direction = constrain_to_outward_dome(
					direction,
					dome_axis,
					child_order,
					normalized_crown_horizontal_radius(position, crown_center, crown_radii),
					growth_profile
				)
				direction = constrain_branch_turn(
					direction, parent_direction, child_order, growth_profile
				)
				direction = constrain_to_growth_heading(
					direction, dome_heading, child_order, growth_profile
				)
			if not direction_diverges_from_children(nodes, node, direction, child_order):
				continue
			var base_step: float = [1.58, 1.95, 1.58, 1.00, 0.72][child_order]
			var step_variation := lerpf(0.88, 1.12, stable_unit("step:%d:%d:%d" % [seed, node_index, iteration]))
			var endpoint: Vector3 = position + direction * base_step * step_variation
			if not point_inside_crown(endpoint, crown_center, crown_radii, crown_phase, 1.08):
				continue
			if not endpoint_respects_outward_dome_frontier(
				endpoint, position, crown_center, crown_radii, dome_axis, child_order, growth_profile
			):
				continue
			if not candidate_segment_respects_wood_clearance(
				position, endpoint, node_index, nodes, segments, child_order, growth_profile
			):
				continue
			if endpoint_too_close(endpoint, nodes, node_index):
				continue
			var child_index := append_node(nodes, segments, endpoint, node_index, child_order, direction)
			if bool(growth_profile.get("enforceOutwardDome", false)):
				var child: Dictionary = nodes[child_index]
				var child_axis := dome_axis
				# A fork may claim a neighbouring lateral sector, but it retains the
				# structural heading of the limb that supports it. Resetting that
				# heading at every fork is what permits a multi-step hook to form.
				var child_heading := dome_heading
				if child_order > parent_order:
					var fork_axis := Vector3(direction.x, 0.0, direction.z)
					if fork_axis.length_squared() >= 0.0001:
						child_axis = fork_axis.normalized()
				child["domeAxis"] = child_axis
				child["domeHeading"] = child_heading
				nodes[child_index] = child
			added += 1
		if added == 0:
			break
	return {
		"remainingAttractions": remaining,
		"iterations": iterations,
		"branchSegmentLimit": branch_segment_limit
	}

func append_node(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	position: Vector3,
	parent_index: int,
	order: int,
	direction: Vector3
) -> int:
	var index := nodes.size()
	nodes.append({
		"position": position,
		"parent": parent_index,
		"children": [],
		"order": clampi(order, 0, 4),
		"orderRun": 0,
		"direction": direction.normalized() if direction.length_squared() > 0.0001 else Vector3.UP
	})
	if parent_index >= 0:
		var parent: Dictionary = nodes[parent_index]
		var parent_order := int(parent.get("order", 0))
		var child: Dictionary = nodes[index]
		child["orderRun"] = int(parent.get("orderRun", 0)) + 1 if parent_order == order else 1
		if parent.has("stratumBias"):
			child["stratumBias"] = float(parent.get("stratumBias", 0.0))
		nodes[index] = child
		var children: Array = parent.get("children", [])
		children.append(index)
		parent["children"] = children
		nodes[parent_index] = parent
		segments.append({
			"parentNode": parent_index,
			"childNode": index,
			"order": clampi(order, 0, 4)
		})
	return index

func direction_diverges_from_children(nodes: Array[Dictionary], node: Dictionary, direction: Vector3, child_order: int) -> bool:
	var children: Array = node.get("children", [])
	if children.is_empty():
		return true
	var maximum_dot := 0.91 if child_order <= 2 else 0.94
	for child_value in children:
		var child_index := int(child_value)
		if child_index < 0 or child_index >= nodes.size():
			continue
		var child_direction: Vector3 = nodes[child_index].get("direction", Vector3.UP)
		if child_direction.dot(direction) > maximum_dot:
			return false
	return true

func endpoint_too_close(endpoint: Vector3, nodes: Array[Dictionary], parent_index: int) -> bool:
	var minimum_squared := MIN_ENDPOINT_SEPARATION * MIN_ENDPOINT_SEPARATION
	for index in range(nodes.size()):
		if index == parent_index:
			continue
		var position: Vector3 = nodes[index].get("position", Vector3.ZERO)
		if position.distance_squared_to(endpoint) < minimum_squared:
			return true
	return false

func profile_order_value(profile: Dictionary, key: String, order: int, fallback: float) -> float:
	var values: Array = profile.get(key, [])
	if values.is_empty():
		return fallback
	return float(values[clampi(order, 0, values.size() - 1)])

func mid_crown_bud_activation(position: Vector3, center: Vector3, radii: Vector3, growth_profile: Dictionary) -> float:
	if not bool(growth_profile.get("allowMidCrownTrunkBuds", false)):
		return 0.0
	var crown_bottom := center.y - radii.y
	var crown_unit := clampf((position.y - crown_bottom) / maxf(0.1, radii.y * 2.0), 0.0, 1.0)
	var height_activation := 0.0
	# Species that define a crown-bearing trunk interval use a smooth two-gate
	# field. It is not a layer list: a site becomes viable continuously after the
	# lower gate opens and loses viability continuously near the crown apex. The
	# ungated Gaussian remains the fallback for existing recipe variants.
	if growth_profile.has("trunkBudZoneLower") and growth_profile.has("trunkBudZoneUpper"):
		var lower := clampf(float(growth_profile.get("trunkBudZoneLower", 0.20)), 0.0, 1.0)
		var upper := clampf(float(growth_profile.get("trunkBudZoneUpper", 0.80)), lower, 1.0)
		var softness := maxf(0.01, float(growth_profile.get("trunkBudZoneSoftness", 0.10)))
		var lower_gate := smoothstep(lower - softness, lower + softness, crown_unit)
		var upper_gate := 1.0 - smoothstep(upper - softness, upper + softness, crown_unit)
		height_activation = lower_gate * upper_gate
	else:
		var peak := clampf(float(growth_profile.get("midCrownBudPeak", 0.38)), 0.0, 1.0)
		var spread := maxf(0.05, float(growth_profile.get("midCrownBudSpread", 0.22)))
		height_activation = exp(-0.5 * pow((crown_unit - peak) / spread, 2.0))
	var horizontal_radius := normalized_crown_horizontal_radius(position, center, radii)
	var core_activation := pow(1.0 - clampf(horizontal_radius, 0.0, 1.0), 0.48)
	return height_activation * core_activation

func trunk_bud_can_compete(
	position: Vector3,
	attraction: Vector3,
	crown_center: Vector3,
	crown_radii: Vector3,
	node_index: int,
	seed: int,
	growth_profile: Dictionary
) -> bool:
	if not bool(growth_profile.get("allowTrunkBudsInColonization", false)):
		return false
	var horizontal_to_space := Vector3(attraction.x - position.x, 0.0, attraction.z - position.z)
	var minimum_horizontal_reach := float(growth_profile.get("trunkBudMinimumHorizontalReach", 2.0))
	if horizontal_to_space.length() < minimum_horizontal_reach:
		return false
	var activation := mid_crown_bud_activation(position, crown_center, crown_radii, growth_profile)
	var acceptance := clampf(
		activation * float(growth_profile.get("trunkBudActivationGain", 1.0)), 0.0, 1.0
	)
	return stable_unit("mid-crown-trunk-bud:%d:%d" % [seed, node_index]) <= acceptance

func local_bud_child_capacity(
	position: Vector3,
	order: int,
	crown_center: Vector3,
	crown_radii: Vector3,
	growth_profile: Dictionary
) -> int:
	# The default matches the prior sparse grammar exactly. A species may add
	# capacity through a smooth mid-crown field, so extra forks are earned by
	# local age/light geometry instead of a hand-authored tier or ring.
	var base_capacity := 1 if order == 2 or order >= 4 else 2
	if order == 0:
		base_capacity = 1
	var activation := mid_crown_bud_activation(position, crown_center, crown_radii, growth_profile)
	var boost := maxf(0.0, float(growth_profile.get("midCrownChildCapacityGain", 0.0)))
	var additional_capacity := floori(activation * boost)
	return base_capacity + additional_capacity

func attraction_is_ahead_of_growth(
	node: Dictionary,
	position: Vector3,
	attraction: Vector3,
	order: int,
	growth_profile: Dictionary
) -> bool:
	if not bool(growth_profile.get("enforceOutwardDome", false)):
		return true
	var toward_attraction := attraction - position
	if toward_attraction.length_squared() < 0.0001:
		return true
	var existing_direction: Vector3 = node.get("direction", Vector3.UP)
	if existing_direction.length_squared() < 0.0001:
		return true
	var minimum_forward_dot := profile_order_value(
		growth_profile, "forwardAttractionMinimumDotByOrder", order, -1.0
	)
	return existing_direction.normalized().dot(toward_attraction.normalized()) >= minimum_forward_dot

func normalized_crown_horizontal_radius(position: Vector3, center: Vector3, radii: Vector3) -> float:
	var local := position - center
	return sqrt(
		pow(local.x / maxf(0.1, radii.x), 2.0)
		+ pow(local.z / maxf(0.1, radii.z), 2.0)
	)

func inherited_dome_axis(
	node: Dictionary,
	position: Vector3,
	crown_center: Vector3,
	parent_direction: Vector3,
	crown_phase: float
) -> Vector3:
	var stored_axis: Vector3 = node.get("domeAxis", Vector3.ZERO)
	stored_axis.y = 0.0
	if stored_axis.length_squared() >= 0.0001:
		return stored_axis.normalized()
	var radial := Vector3(position.x - crown_center.x, 0.0, position.z - crown_center.z)
	if radial.length_squared() >= 0.0001:
		return radial.normalized()
	var inherited_heading := Vector3(parent_direction.x, 0.0, parent_direction.z)
	if inherited_heading.length_squared() >= 0.0001:
		return inherited_heading.normalized()
	return Vector3(cos(crown_phase), 0.0, sin(crown_phase))

func inherited_dome_heading(node: Dictionary, parent_direction: Vector3, dome_axis: Vector3) -> Vector3:
	var stored_heading: Vector3 = node.get("domeHeading", Vector3.ZERO)
	if stored_heading.length_squared() >= 0.0001:
		return stored_heading.normalized()
	if parent_direction.length_squared() >= 0.0001:
		return parent_direction.normalized()
	return dome_axis

func constrain_to_outward_dome(
	proposed_direction: Vector3,
	radial: Vector3,
	child_order: int,
	radial_fraction: float,
	growth_profile: Dictionary
) -> Vector3:
	var horizontal := Vector3(proposed_direction.x, 0.0, proposed_direction.z)
	if horizontal.length_squared() < 0.0001 or radial.length_squared() < 0.0001:
		return proposed_direction
	var inward_floor := profile_order_value(
		growth_profile, "minimumRadialAlignmentInnerByOrder", child_order, 0.0
	)
	var edge_floor := profile_order_value(
		growth_profile, "minimumRadialAlignmentOuterByOrder", child_order, 0.0
	)
	var required_alignment := lerpf(inward_floor, edge_floor, clampf(radial_fraction, 0.0, 1.0))
	if required_alignment <= 0.0:
		return proposed_direction
	# Preserve the local tangential response to nearby free space, while forcing
	# its horizontal component to retain an outward-facing projection. This is a
	# growth constraint, not a prescribed branch heading.
	var current_alignment := horizontal.dot(radial)
	var tangent := horizontal - radial * current_alignment
	var constrained_horizontal := tangent + radial * maxf(
		current_alignment,
		horizontal.length() * required_alignment
	)
	return Vector3(constrained_horizontal.x, proposed_direction.y, constrained_horizontal.z).normalized()

func constrain_branch_turn(
	proposed_direction: Vector3,
	parent_direction: Vector3,
	child_order: int,
	growth_profile: Dictionary
) -> Vector3:
	var maximum_turn := profile_order_value(
		growth_profile, "maximumTurnRadiansByOrder", child_order, PI
	)
	if maximum_turn >= PI - 0.0001 or parent_direction.length_squared() < 0.0001:
		return proposed_direction
	var normalized_parent := parent_direction.normalized()
	var normalized_proposed := proposed_direction.normalized()
	var turn_angle := acos(clampf(normalized_parent.dot(normalized_proposed), -1.0, 1.0))
	if turn_angle <= maximum_turn:
		return normalized_proposed
	return normalized_parent.slerp(normalized_proposed, maximum_turn / turn_angle).normalized()

func constrain_to_growth_heading(
	proposed_direction: Vector3,
	growth_heading: Vector3,
	child_order: int,
	growth_profile: Dictionary
) -> Vector3:
	var minimum_alignment := profile_order_value(
		growth_profile, "minimumHeadingAlignmentByOrder", child_order, -1.0
	)
	if minimum_alignment <= -0.999 or growth_heading.length_squared() < 0.0001:
		return proposed_direction
	var normalized_heading := growth_heading.normalized()
	var normalized_proposed := proposed_direction.normalized()
	var alignment := normalized_proposed.dot(normalized_heading)
	if alignment >= minimum_alignment:
		return normalized_proposed
	# Preserve the component that expresses local competition for space, then
	# project it onto the furthest legal heading cone for this branch order.
	var tangent := normalized_proposed - normalized_heading * alignment
	if tangent.length_squared() < 0.0001:
		tangent = normalized_heading.cross(Vector3.UP)
		if tangent.length_squared() < 0.0001:
			tangent = normalized_heading.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var tangent_magnitude := sqrt(maxf(0.0, 1.0 - minimum_alignment * minimum_alignment))
	return (normalized_heading * minimum_alignment + tangent * tangent_magnitude).normalized()

func endpoint_respects_outward_dome_frontier(
	endpoint: Vector3,
	parent_position: Vector3,
	crown_center: Vector3,
	crown_radii: Vector3,
	dome_axis: Vector3,
	child_order: int,
	growth_profile: Dictionary
) -> bool:
	if not bool(growth_profile.get("enforceOutwardDome", false)):
		return true
	var parent_radius := normalized_crown_horizontal_radius(parent_position, crown_center, crown_radii)
	var protected_start := clampf(float(growth_profile.get("radialProgressStart", 0.0)), 0.0, 1.0)
	if parent_radius < protected_start:
		return true
	# Once a bud has established a radial sector, all of its descendants may
	# branch and rise within that sector but cannot reclaim progress back toward
	# the bole. This rules out the large inward hooks without prescribing limbs.
	var crown_extent := maxf(0.1, minf(crown_radii.x, crown_radii.z))
	var parent_projection := (parent_position - crown_center).dot(dome_axis) / crown_extent
	var endpoint_projection := (endpoint - crown_center).dot(dome_axis) / crown_extent
	var bole := Vector3(crown_center.x, 0.0, crown_center.z)
	var parent_bole_distance := parent_position.distance_to(bole) / crown_extent
	var endpoint_bole_distance := endpoint.distance_to(bole) / crown_extent
	var permitted_retreat := profile_order_value(
		growth_profile, "radialBacktrackByOrder", child_order, 1.0
	)
	return endpoint_projection + permitted_retreat >= parent_projection \
		and endpoint_bole_distance + permitted_retreat >= parent_bole_distance

func candidate_segment_respects_wood_clearance(
	start: Vector3,
	endpoint: Vector3,
	parent_index: int,
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	child_order: int,
	growth_profile: Dictionary
) -> bool:
	var clearance := profile_order_value(growth_profile, "woodClearanceByOrder", child_order, 0.0)
	if clearance <= 0.0:
		return true
	var clearance_squared := clearance * clearance
	for segment in segments:
		var existing_parent := int(segment.get("parentNode", -1))
		var existing_child := int(segment.get("childNode", -1))
		# The candidate necessarily shares its first point with the parent wood.
		if existing_parent == parent_index or existing_child == parent_index:
			continue
		if existing_parent < 0 or existing_child < 0 or existing_parent >= nodes.size() or existing_child >= nodes.size():
			continue
		var existing_start: Vector3 = nodes[existing_parent].get("position", Vector3.ZERO)
		var existing_end: Vector3 = nodes[existing_child].get("position", Vector3.ZERO)
		if segment_segment_distance_squared(start, endpoint, existing_start, existing_end) < clearance_squared:
			return false
	return true

func segment_segment_distance_squared(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> float:
	var u := a1 - a0
	var v := b1 - b0
	var w := a0 - b0
	var a := u.dot(u)
	var b := u.dot(v)
	var c := v.dot(v)
	var d := u.dot(w)
	var e := v.dot(w)
	var determinant := a * c - b * b
	if a < 0.000001 or c < 0.000001:
		return INF
	var s_numerator: float
	var s_denominator: float = determinant
	var t_numerator: float
	var t_denominator: float = determinant
	if determinant < 0.000001:
		s_numerator = 0.0
		s_denominator = 1.0
		t_numerator = e
		t_denominator = c
	else:
		s_numerator = b * e - c * d
		t_numerator = a * e - b * d
		if s_numerator < 0.0:
			s_numerator = 0.0
			t_numerator = e
			t_denominator = c
		elif s_numerator > s_denominator:
			s_numerator = s_denominator
			t_numerator = e + b
			t_denominator = c
	if t_numerator < 0.0:
		t_numerator = 0.0
		if -d < 0.0:
			s_numerator = 0.0
		elif -d > a:
			s_numerator = s_denominator
		else:
			s_numerator = -d
			s_denominator = a
	elif t_numerator > t_denominator:
		t_numerator = t_denominator
		if -d + b < 0.0:
			s_numerator = 0.0
		elif -d + b > a:
			s_numerator = s_denominator
		else:
			s_numerator = -d + b
			s_denominator = a
	var s := 0.0 if absf(s_numerator) < 0.000001 else s_numerator / s_denominator
	var t := 0.0 if absf(t_numerator) < 0.000001 else t_numerator / t_denominator
	var difference := w + u * s - v * t
	return difference.length_squared()

func point_inside_crown(point: Vector3, center: Vector3, radii: Vector3, phase: float, margin: float) -> bool:
	var local := point - center
	var angle := atan2(local.z, local.x)
	var lobe := 0.91 + sin(angle * 3.0 + phase) * 0.055 + sin(angle * 5.0 - phase * 0.61) * 0.035
	var horizontal_scale := maxf(0.72, lobe) * margin
	var lower_extension := 1.24 if local.y < 0.0 else 1.0
	var normalized := Vector3(
		local.x / maxf(0.1, radii.x * horizontal_scale),
		local.y / maxf(0.1, radii.y * margin * lower_extension),
		local.z / maxf(0.1, radii.z * horizontal_scale)
	)
	return normalized.length_squared() <= 1.0

func smooth_non_junction_chains(nodes: Array[Dictionary], passes: int) -> void:
	for _pass_index in range(maxi(0, passes)):
		var smoothed: Array[Vector3] = []
		smoothed.resize(nodes.size())
		for index in range(nodes.size()):
			smoothed[index] = nodes[index].get("position", Vector3.ZERO)
		for index in range(1, nodes.size()):
			var node: Dictionary = nodes[index]
			var parent_index := int(node.get("parent", -1))
			var children: Array = node.get("children", [])
			if parent_index < 0 or children.size() != 1 or int(node.get("order", 0)) == 0:
				continue
			var child_index := int(children[0])
			var current: Vector3 = node.get("position", Vector3.ZERO)
			var parent_position: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
			var child_position: Vector3 = nodes[child_index].get("position", Vector3.ZERO)
			var curve_target := parent_position.lerp(child_position, 0.5)
			smoothed[index] = current.lerp(curve_target, 0.38)
		for index in range(1, nodes.size()):
			var node: Dictionary = nodes[index]
			node["position"] = smoothed[index]
			nodes[index] = node
	for index in range(1, nodes.size()):
		var node: Dictionary = nodes[index]
		var parent_index := int(node.get("parent", -1))
		var parent_position: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var position: Vector3 = node.get("position", Vector3.ZERO)
		node["direction"] = (position - parent_position).normalized()
		nodes[index] = node

func solve_pipe_model(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	trunk_radius: float,
	height: float,
	crown_base: float
) -> Dictionary:
	var support: Array[float] = []
	support.resize(nodes.size())
	for index in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[index]
		var children: Array = node.get("children", [])
		var area_units := 0.0
		for child_value in children:
			area_units += support[int(child_value)]
		if children.is_empty():
			var order := int(node.get("order", 0))
			area_units = 1.0 if order >= 3 else 0.72
		support[index] = maxf(0.0001, area_units)
	var root_support := sqrt(maxf(0.0001, support[0]))
	var radius_scale := trunk_radius / root_support
	var maximum_height := 1.0
	for node in nodes:
		maximum_height = maxf(maximum_height, float((node.get("position", Vector3.ZERO) as Vector3).y))
	var branches: Array[Dictionary] = []
	for segment_index in range(segments.size()):
		var segment: Dictionary = segments[segment_index]
		var parent_index := int(segment.get("parentNode", -1))
		var child_index := int(segment.get("childNode", -1))
		if parent_index < 0 or child_index < 0:
			continue
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = nodes[child_index].get("position", Vector3.UP)
		var carried_radius := sqrt(maxf(0.0001, support[child_index])) * radius_scale
		var radius_start := carried_radius * node_taper_factor(nodes[parent_index], height, crown_base)
		var radius_end := carried_radius * node_taper_factor(nodes[child_index], height, crown_base)
		if parent_index == 0:
			radius_start *= 1.24
		var order := int(segment.get("order", 0))
		branches.append({
			"start": start,
			"end": end,
			"radiusStart": maxf(0.055, radius_start),
			"radiusEnd": maxf(0.050, radius_end),
			"generation": order,
			"order": order,
			"parentNode": parent_index,
			"childNode": child_index,
			"stratumBias": float(nodes[child_index].get("stratumBias", 0.0)),
			"windWeight": clampf(maxf(start.y, end.y) / maximum_height, 0.0, 1.0)
		})
	var max_error := 0.0
	var junction_count := 0
	for node_index in range(nodes.size()):
		var children: Array = nodes[node_index].get("children", [])
		if children.size() < 2:
			continue
		junction_count += 1
		var taper := node_taper_factor(nodes[node_index], height, crown_base)
		var taper_area := taper * taper
		var parent_area := support[node_index] * radius_scale * radius_scale * taper_area
		var child_area := 0.0
		for child_value in children:
			child_area += support[int(child_value)] * radius_scale * radius_scale * taper_area
		var error := absf(parent_area - child_area) / maxf(0.0001, parent_area)
		max_error = maxf(max_error, error)
	# Expose the solved carrying radius at every node so species grammars can make
	# later developmental decisions from actual supported wood, rather than from
	# an authored branch depth. The root has no incoming segment, so its radius is
	# the trunk radius; every other value matches the radius at its segment end.
	var node_radii: Array[float] = []
	node_radii.resize(nodes.size())
	if not nodes.is_empty():
		node_radii[0] = trunk_radius
	for node_index in range(1, nodes.size()):
		var carried_radius := sqrt(maxf(0.0001, support[node_index])) * radius_scale
		node_radii[node_index] = maxf(
			0.050,
			carried_radius * node_taper_factor(nodes[node_index], height, crown_base)
		)
	return {
		"branches": branches,
		"maxRelativeError": max_error,
		"junctionCount": junction_count,
		"nodeRadii": node_radii
	}

func node_taper_factor(node: Dictionary, height: float, crown_base: float) -> float:
	var position: Vector3 = node.get("position", Vector3.ZERO)
	var order := int(node.get("order", 0))
	if order == 0:
		var trunk_unit := clampf(position.y / maxf(1.0, crown_base + 1.5), 0.0, 1.0)
		return lerpf(1.0, 0.76, pow(trunk_unit, 0.88))
	var crown_unit := clampf((position.y - crown_base) / maxf(1.0, height - crown_base), 0.0, 1.0)
	return lerpf(0.90, 0.73, crown_unit) * lerpf(1.0, 0.94, float(order) / 4.0)

func build_root_buttresses(trunk_radius: float, seed: int) -> Array[Dictionary]:
	var roots: Array[Dictionary] = []
	var root_count := 7
	var phase := stable_unit("root-phase:%d" % seed) * TAU
	for root_index in range(root_count):
		var angle := phase + float(root_index) * TAU / float(root_count) \
			+ stable_signed("root-angle:%d:%d" % [seed, root_index]) * 0.16
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var length := trunk_radius * lerpf(1.25, 1.95, stable_unit("root-length:%d:%d" % [seed, root_index]))
		var start := direction * trunk_radius * 0.24 + Vector3.UP * trunk_radius * 0.34
		var end := direction * length + Vector3.UP * 0.07
		roots.append({
			"start": start,
			"end": end,
			"radiusStart": trunk_radius * lerpf(0.42, 0.58, stable_unit("root-width:%d:%d" % [seed, root_index])),
			"radiusEnd": maxf(0.14, trunk_radius * 0.075),
			"generation": 0,
			"order": 0,
			"role": "root_buttress",
			"windWeight": 0.0
		})
	return roots

func build_twig_foliage(
	nodes: Array[Dictionary],
	segments: Array[Dictionary],
	crown_center: Vector3,
	crown_radii: Vector3,
	height: float,
	seed: int
) -> Array[Dictionary]:
	var foliage: Array[Dictionary] = []
	for segment_index in range(segments.size()):
		if foliage.size() >= MAX_FOLIAGE_CLUSTERS:
			break
		var segment: Dictionary = segments[segment_index]
		var order := int(segment.get("order", 0))
		var child_index := int(segment.get("childNode", -1))
		if child_index < 0 or child_index >= nodes.size():
			continue
		var child: Dictionary = nodes[child_index]
		var terminal := (child.get("children", []) as Array).is_empty()
		if order < 3 and not (order == 2 and terminal):
			continue
		var parent_index := int(segment.get("parentNode", -1))
		var start: Vector3 = nodes[parent_index].get("position", Vector3.ZERO)
		var end: Vector3 = child.get("position", Vector3.UP)
		var length := start.distance_to(end)
		var midpoint := start.lerp(end, 0.5)
		var midpoint_envelope := Vector3(
			(midpoint.x - crown_center.x) / maxf(0.1, crown_radii.x),
			(midpoint.y - crown_center.y) / maxf(0.1, crown_radii.y),
			(midpoint.z - crown_center.z) / maxf(0.1, crown_radii.z)
		).length()
		var exposure := clampf((midpoint_envelope - 0.18) / 0.82, 0.0, 1.0)
		# A wider crown must remain a crown rather than read as a handful of leaf
		# pads at the ends of long limbs. Increase density only from existing fine
		# wood, preserving the major-branch budget and the tree's architecture.
		# The hard cap is still a runaway guard rather than the source of leaf
		# quantity.
		var capacity := (length * (0.96 if order >= 4 else 0.72) + (0.82 if terminal else 0.28)) \
			* lerpf(0.68, 1.30, exposure) * 1.45
		var cluster_count := clampi(ceili(capacity), 1, 5)
		var direction := (end - start).normalized()
		var side := direction.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		else:
			side = side.normalized()
		var normal := direction.cross(side).normalized()
		for cluster_index in range(cluster_count):
			if foliage.size() >= MAX_FOLIAGE_CLUSTERS:
				break
			var unit := (float(cluster_index) + 0.42) / float(cluster_count)
			var jitter_a := stable_signed("leaf-a:%d:%d:%d" % [seed, segment_index, cluster_index])
			var jitter_b := stable_signed("leaf-b:%d:%d:%d" % [seed, segment_index, cluster_index])
			var position := start.lerp(end, clampf(unit + jitter_a * 0.08, 0.18, 1.0))
			position += side * jitter_a * 0.48 + normal * jitter_b * 0.42
			var envelope_unit := Vector3(
				(position.x - crown_center.x) / maxf(0.1, crown_radii.x),
				(position.y - crown_center.y) / maxf(0.1, crown_radii.y),
				(position.z - crown_center.z) / maxf(0.1, crown_radii.z)
			).length()
			var local_exposure := clampf((envelope_unit - 0.12) / 0.88, 0.0, 1.0)
			var outer_scale := lerpf(1.24, 2.42, local_exposure)
			if terminal:
				outer_scale *= 1.10
			var vertical_scale := outer_scale * lerpf(0.68, 0.82, stable_unit("leaf-y:%d:%d:%d" % [seed, segment_index, cluster_index]))
			foliage.append({
				"position": position,
				"rotation": Vector3(
					stable_signed("leaf-rx:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.24,
					stable_unit("leaf-ry:%d:%d:%d" % [seed, segment_index, cluster_index]) * TAU,
					stable_signed("leaf-rz:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.18
				),
				"scale": Vector3(outer_scale, vertical_scale, outer_scale),
				"windWeight": clampf(position.y / maxf(1.0, height), 0.22, 1.0),
				"variation": clampf(
					0.18 + local_exposure * 0.56
					+ stable_unit("leaf-color:%d:%d:%d" % [seed, segment_index, cluster_index]) * 0.26,
					0.0,
					1.0
				),
				"clusterVariant": posmod(stable_hash("leaf-variant:%d:%d:%d" % [seed, segment_index, cluster_index]), 4),
				"sourceSegment": segment_index,
				"sourceOrder": order,
				"twigCapacity": capacity,
				"exposure": local_exposure
			})
	return foliage

func graph_is_connected(nodes: Array[Dictionary], segments: Array[Dictionary]) -> bool:
	if nodes.is_empty() or segments.size() != nodes.size() - 1:
		return false
	for index in range(1, nodes.size()):
		var parent := int(nodes[index].get("parent", -1))
		if parent < 0 or parent >= index:
			return false
	return true

func segment_counts_by_order(segments: Array[Dictionary]) -> Dictionary:
	var counts := {"trunk": 0, "primary": 0, "secondary": 0, "tertiary": 0, "twig": 0}
	var names := ["trunk", "primary", "secondary", "tertiary", "twig"]
	for segment in segments:
		var order := clampi(int(segment.get("order", 0)), 0, 4)
		counts[names[order]] = int(counts[names[order]]) + 1
	return counts

func crown_occupancy(foliage: Array[Dictionary], center: Vector3, radii: Vector3) -> Dictionary:
	var occupied := {}
	var azimuth_bins := 10
	var height_bins := 5
	for anchor in foliage:
		var position: Vector3 = anchor.get("position", Vector3.ZERO)
		var local := position - center
		var angle := fposmod(atan2(local.z, local.x), TAU)
		var angle_bin := clampi(floori(angle / TAU * float(azimuth_bins)), 0, azimuth_bins - 1)
		var height_unit := clampf((local.y / maxf(0.1, radii.y) + 1.0) * 0.5, 0.0, 0.999)
		var height_bin := clampi(floori(height_unit * float(height_bins)), 0, height_bins - 1)
		occupied["%d:%d" % [angle_bin, height_bin]] = true
	return {
		"occupiedBins": occupied.size(),
		"totalBins": azimuth_bins * height_bins,
		"ratio": float(occupied.size()) / float(azimuth_bins * height_bins)
	}

func maximum_major_wood_reach(branches: Array[Dictionary]) -> float:
	# Measure the radial reach of primary and secondary wood only. Foliage can
	# extend past this, but this value answers the architectural question: how
	# far does the load-bearing branch skeleton travel relative to trunk width?
	var maximum_reach := 0.0
	for branch in branches:
		if int(branch.get("order", 0)) < 1 or int(branch.get("order", 0)) > 2:
			continue
		if String(branch.get("role", "")) == "root_buttress":
			continue
		var endpoint: Vector3 = branch.get("end", Vector3.ZERO)
		maximum_reach = maxf(maximum_reach, Vector2(endpoint.x, endpoint.z).length())
	return maximum_reach

func branch_pitch_by_crown_stratum(branches: Array[Dictionary], center: Vector3, radii: Vector3) -> Dictionary:
	var sums := {"lower": 0.0, "middle": 0.0, "upper": 0.0}
	var counts := {"lower": 0, "middle": 0, "upper": 0}
	var crown_bottom := center.y - radii.y
	for branch in branches:
		var order := int(branch.get("order", 0))
		if order < 1 or order > 2 or String(branch.get("role", "")) == "root_buttress":
			continue
		var start: Vector3 = branch.get("start", Vector3.ZERO)
		var end: Vector3 = branch.get("end", Vector3.ZERO)
		var direction := (end - start).normalized()
		var stratum_bias := float(branch.get("stratumBias", 0.0))
		var stratum := "lower" if stratum_bias < -0.25 else ("upper" if stratum_bias > 0.25 else "middle")
		sums[stratum] = float(sums[stratum]) + direction.y
		counts[stratum] = int(counts[stratum]) + 1
	var result := {}
	for stratum in ["lower", "middle", "upper"]:
		var count := int(counts[stratum])
		result[stratum] = {
			"segmentCount": count,
			"averageVerticalDirection": float(sums[stratum]) / float(maxi(1, count))
		}
	return result

func stable_noise_vector(seed: int, node_index: int, iteration: int) -> Vector3:
	var value := Vector3(
		stable_signed("noise-x:%d:%d:%d" % [seed, node_index, iteration]),
		stable_signed("noise-y:%d:%d:%d" % [seed, node_index, iteration]) * 0.55,
		stable_signed("noise-z:%d:%d:%d" % [seed, node_index, iteration])
	)
	return value.normalized() if value.length_squared() > 0.001 else Vector3.RIGHT

func recipe_signature(seed: int, maturity: float, height: float, branches: Array[Dictionary], foliage: Array[Dictionary]) -> String:
	var value := stable_hash("math-tree-v%d:%d:%d:%d:%d" % [
		RECIPE_VERSION,
		seed,
		roundi(maturity * 100000.0),
		roundi(height * 1000.0),
		branches.size()
	])
	for branch in branches:
		var start: Vector3 = branch.get("start", Vector3.ZERO)
		var end: Vector3 = branch.get("end", Vector3.ZERO)
		value = stable_hash("%d:%d,%d,%d:%d,%d,%d:%d:%d:%d" % [
			value,
			roundi(start.x * 1000.0), roundi(start.y * 1000.0), roundi(start.z * 1000.0),
			roundi(end.x * 1000.0), roundi(end.y * 1000.0), roundi(end.z * 1000.0),
			roundi(float(branch.get("radiusStart", 0.0)) * 1000.0),
			roundi(float(branch.get("radiusEnd", 0.0)) * 1000.0),
			int(branch.get("order", 0))
		])
	for anchor in foliage:
		var position: Vector3 = anchor.get("position", Vector3.ZERO)
		value = stable_hash("%d:%d,%d,%d:%d" % [
			value,
			roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0),
			int(anchor.get("sourceOrder", 0))
		])
	return "%08x" % [value & 0xffffffff]

func stable_unit(text: String) -> float:
	return float(stable_hash(text) & 0x7fffffff) / float(0x7fffffff)

func stable_signed(text: String) -> float:
	return stable_unit(text) * 2.0 - 1.0

func stable_hash(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return value
