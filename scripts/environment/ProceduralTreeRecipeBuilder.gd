extends RefCounted
class_name ProceduralTreeRecipeBuilder

const RECIPE_VERSION := 2
const MAX_BRANCH_SEGMENTS := 240
const MAX_FOLIAGE_ANCHORS := 280
const MAX_FOLIAGE_CANDIDATES := 1600

func build_recipe(runtime_spec: Dictionary, biome: String, prop_id: String, world_seed: String) -> Dictionary:
	if runtime_spec.is_empty():
		return {}
	var architecture := String(runtime_spec.get("architecture", "broadleaf"))
	if architecture not in ["broadleaf", "conifer", "savanna"]:
		architecture = architecture_for_family(String(runtime_spec.get("family", "")))
	var height := maxf(6.0, float(runtime_spec.get("visualHeight", 18.0)))
	var trunk_radius := maxf(0.28, float(runtime_spec.get("trunkRadius", height * 0.035)))
	var canopy_radius := maxf(trunk_radius * 2.4, float(runtime_spec.get("canopyRadius", height * 0.30)))
	var growth_stage := clampf(float(runtime_spec.get("growthStage", 0.55)), 0.0, 1.0)
	var canopy_density := clampf(float(runtime_spec.get("canopyDensity", 0.72)), 0.22, 1.0)
	var genetic_seed := int(runtime_spec.get("geneticSeed", stable_hash("%s:%s:%s" % [world_seed, biome, prop_id])))
	var rng := RandomNumberGenerator.new()
	rng.seed = genetic_seed
	var genotype := build_genotype(rng, architecture, growth_stage)
	var branches: Array[Dictionary] = []
	var foliage: Array[Dictionary] = []
	match architecture:
		"conifer":
			build_conifer(branches, foliage, rng, height, trunk_radius, canopy_radius, growth_stage, canopy_density, genotype)
		"savanna":
			build_savanna(branches, foliage, rng, height, trunk_radius, canopy_radius, growth_stage, canopy_density, genotype)
		_:
			build_broadleaf(branches, foliage, rng, height, trunk_radius, canopy_radius, growth_stage, canopy_density, genotype)
	foliage = select_foliage_anchors(foliage, foliage_budget(architecture, canopy_density, genotype), genetic_seed)
	var signature := recipe_signature(architecture, genetic_seed, height, trunk_radius, canopy_radius, genotype, branches, foliage)
	return {
		"version": RECIPE_VERSION,
		"signature": signature,
		"treeId": prop_id,
		"biome": biome,
		"architecture": architecture,
		"ageBand": String(runtime_spec.get("ageBand", "mature")),
		"ageYears": float(runtime_spec.get("ageYears", 0.0)),
		"growthStage": growth_stage,
		"geneticSeed": genetic_seed,
		"genotype": genotype,
		"crownHabit": String(genotype.get("habit", "natural")),
		"height": height,
		"trunkRadius": trunk_radius,
		"canopyRadius": canopy_radius,
		"canopyDensity": canopy_density,
		"branches": branches,
		"foliage": foliage,
		"branchCount": branches.size(),
		"foliageClusterCount": foliage.size()
	}

func build_broadleaf(
	branches: Array[Dictionary],
	foliage: Array[Dictionary],
	rng: RandomNumberGenerator,
	height: float,
	trunk_radius: float,
	canopy_radius: float,
	growth_stage: float,
	canopy_density: float,
	genotype: Dictionary
) -> void:
	var trunk_top := height * lerpf(0.30, 0.39, rng.randf()) * float(genotype.get("forkHeight", 1.0))
	trunk_top = clampf(trunk_top, height * 0.24, height * 0.52)
	var trunk_segments := 6 + roundi(growth_stage * 3.0)
	var trunk_points: Array[Vector3] = [Vector3.ZERO]
	var bias_angle := float(genotype.get("biasAngle", 0.0))
	var crown_bias := Vector3(cos(bias_angle), 0.0, sin(bias_angle))
	var trunk_lean_strength := float(genotype.get("trunkLean", 0.02))
	var trunk_lean := Vector2(crown_bias.x, crown_bias.z) * trunk_lean_strength
	for index in range(1, trunk_segments + 1):
		var t := float(index) / float(trunk_segments)
		trunk_points.append(Vector3(trunk_lean.x * trunk_top * t * t, trunk_top * t, trunk_lean.y * trunk_top * t * t))
	for index in range(trunk_segments):
		var t0 := float(index) / float(trunk_segments)
		var t1 := float(index + 1) / float(trunk_segments)
		add_branch(branches, trunk_points[index], trunk_points[index + 1], trunk_radius * lerpf(1.08, 0.48, t0), trunk_radius * lerpf(1.08, 0.48, t1), 0, height)

	var scaffold_count := clampi(5 + roundi(growth_stage * 3.0) + int(genotype.get("branchCountBias", 0)) + rng.randi_range(-1, 1), 5, 10)
	var base_rotation := rng.randf() * TAU
	for scaffold_index in range(scaffold_count):
		if scaffold_index >= 4 and rng.randf() < float(genotype.get("branchGapChance", 0.04)):
			continue
		var angle := base_rotation + float(scaffold_index) * float(genotype.get("phyllotaxis", 2.39996323)) + rng.randf_range(-0.34, 0.34)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var asymmetry := float(genotype.get("asymmetry", 0.22))
		var directional_growth := lerpf(1.0, lerpf(0.58, 1.34, (direction.dot(crown_bias) + 1.0) * 0.5), asymmetry)
		direction = (direction + crown_bias * asymmetry * 0.24).normalized()
		var tangent := Vector3(-direction.z, 0.0, direction.x)
		var start_t := rng.randf_range(0.68, 1.02)
		var point := trunk_points[clampi(roundi(start_t * float(trunk_segments)), 1, trunk_segments)]
		var scaffold_segments: Array[Dictionary] = []
		var scaffold_length := canopy_radius * rng.randf_range(0.70, 1.08) * float(genotype.get("crownSpread", 1.0)) * directional_growth
		var segment_count := 4
		for segment_index in range(segment_count):
			var t := float(segment_index + 1) / float(segment_count)
			var outward := scaffold_length * rng.randf_range(0.20, 0.30)
			var rise := height * rng.randf_range(0.070, 0.125) * (1.12 - t * 0.30) * float(genotype.get("crownUpright", 1.0))
			var next := point + direction * outward + tangent * rng.randf_range(-0.05, 0.05) * canopy_radius + Vector3.UP * rise
			var radius_start := trunk_radius * lerpf(0.50, 0.16, float(segment_index) / float(segment_count))
			var radius_end := trunk_radius * lerpf(0.40, 0.075, t)
			add_branch(branches, point, next, radius_start, radius_end, 1, height)
			var segment := {"start": point, "end": next, "radiusStart": radius_start, "radiusEnd": radius_end}
			scaffold_segments.append(segment)
			if segment_index >= 1:
				add_foliage_along_segment(foliage, rng, point, next, canopy_radius * 0.085, 1 + roundi(canopy_density * 2.0), height, genotype)
			point = next
		for segment_index in range(1, scaffold_segments.size()):
			var parent: Dictionary = scaffold_segments[segment_index]
			var parent_start: Vector3 = parent["start"]
			var parent_end: Vector3 = parent["end"]
			var attachment := parent_start.lerp(parent_end, rng.randf_range(0.28, 0.82))
			var secondary_count := clampi(roundi((2.0 + float(int(growth_stage > 0.72))) * float(genotype.get("branchDensity", 1.0))), 1, 4)
			for side_index in range(secondary_count):
				var side := -1.0 if side_index % 2 == 0 else 1.0
				var secondary_direction := (direction.rotated(Vector3.UP, side * rng.randf_range(0.42, 0.82)) + Vector3.UP * rng.randf_range(0.24, 0.46)).normalized()
				var secondary_length := canopy_radius * rng.randf_range(0.25, 0.46) * (1.0 - float(segment_index) * 0.06)
				var middle := attachment + secondary_direction * secondary_length * 0.54 + Vector3.UP * height * rng.randf_range(0.025, 0.060)
				var end := middle + secondary_direction.rotated(Vector3.UP, rng.randf_range(-0.24, 0.24)) * secondary_length * 0.46 + Vector3.UP * height * rng.randf_range(0.025, 0.055)
				var secondary_radius := maxf(0.055, float(parent.get("radiusEnd", trunk_radius * 0.12)) * 0.74)
				add_branch(branches, attachment, middle, secondary_radius, secondary_radius * 0.62, 2, height)
				add_branch(branches, middle, end, secondary_radius * 0.62, secondary_radius * 0.30, 3, height)
				add_foliage_along_segment(foliage, rng, attachment, middle, canopy_radius * 0.075, 2 + roundi(canopy_density * 2.0), height, genotype)
				add_foliage_along_segment(foliage, rng, middle, end, canopy_radius * 0.082, 3 + roundi(canopy_density * 2.0), height, genotype)

	var leader_count := clampi(roundi(lerpf(4.0, 1.0, float(genotype.get("apicalDominance", 0.45))) + float(int(growth_stage > 0.62))), 1, 5)
	for leader_index in range(leader_count):
		var angle := base_rotation + (float(leader_index) + 0.35) * float(genotype.get("phyllotaxis", 2.39996323)) + rng.randf_range(-0.42, 0.42)
		var leader_direction := Vector3(cos(angle), 0.0, sin(angle))
		var point := trunk_points[trunk_segments]
		var leader_segments := 3
		for segment_index in range(leader_segments):
			var t := float(segment_index + 1) / float(leader_segments)
			var next := point + leader_direction * canopy_radius * rng.randf_range(0.10, 0.18) + Vector3.UP * (height - trunk_top) / float(leader_segments) * rng.randf_range(0.88, 1.05)
			var start_radius := trunk_radius * lerpf(0.40, 0.13, float(segment_index) / float(leader_segments))
			var end_radius := trunk_radius * lerpf(0.30, 0.06, t)
			add_branch(branches, point, next, start_radius, end_radius, 1 + segment_index, height)
			add_foliage_along_segment(foliage, rng, point, next, canopy_radius * 0.080, 2 + roundi(canopy_density * 3.0), height, genotype)
			point = next

func build_conifer(
	branches: Array[Dictionary],
	foliage: Array[Dictionary],
	rng: RandomNumberGenerator,
	height: float,
	trunk_radius: float,
	canopy_radius: float,
	growth_stage: float,
	canopy_density: float,
	genotype: Dictionary
) -> void:
	var trunk_segments := 9 + roundi(growth_stage * 4.0)
	var trunk_points: Array[Vector3] = [Vector3.ZERO]
	var bias_angle := float(genotype.get("biasAngle", 0.0))
	var crown_bias := Vector3(cos(bias_angle), 0.0, sin(bias_angle))
	var lean := Vector2(crown_bias.x, crown_bias.z) * float(genotype.get("trunkLean", 0.008))
	for index in range(1, trunk_segments + 1):
		var t := float(index) / float(trunk_segments)
		trunk_points.append(Vector3(lean.x * height * t * t, height * t, lean.y * height * t * t))
	for index in range(trunk_segments):
		var t0 := float(index) / float(trunk_segments)
		var t1 := float(index + 1) / float(trunk_segments)
		add_branch(branches, trunk_points[index], trunk_points[index + 1], trunk_radius * lerpf(1.05, 0.12, t0), trunk_radius * lerpf(1.05, 0.12, t1), 0, height)

	var whorl_count := clampi(roundi((8.0 + growth_stage * 6.0) * float(genotype.get("branchDensity", 1.0))), 7, 16)
	var base_rotation := rng.randf() * TAU
	for whorl_index in range(whorl_count):
		var crown_t := float(whorl_index) / float(maxi(1, whorl_count - 1))
		var height_t := lerpf(0.20, 0.91, crown_t)
		var branch_length := canopy_radius * pow(1.0 - crown_t * 0.82, 0.70) * rng.randf_range(0.84, 1.16) * float(genotype.get("crownSpread", 1.0))
		var whorl_branches := clampi(5 + int(genotype.get("branchCountBias", 0)) + rng.randi_range(0, 2), 4, 8)
		for branch_index in range(whorl_branches):
			if branch_index >= 3 and rng.randf() < float(genotype.get("branchGapChance", 0.04)):
				continue
			var angle := base_rotation + crown_t * float(genotype.get("whorlTwist", 1.9)) + TAU * float(branch_index) / float(whorl_branches) + rng.randf_range(-0.24, 0.24)
			var direction := Vector3(cos(angle), 0.0, sin(angle))
			var directional_growth := lerpf(1.0, lerpf(0.68, 1.24, (direction.dot(crown_bias) + 1.0) * 0.5), float(genotype.get("asymmetry", 0.16)))
			var resolved_branch_length := branch_length * directional_growth
			var start := Vector3(lean.x * height * height_t, height * height_t, lean.y * height * height_t)
			var droop := float(genotype.get("branchDroop", 1.0))
			var middle := start + direction * resolved_branch_length * 0.52 + Vector3.DOWN * height * lerpf(0.035, 0.008, crown_t) * droop
			var end := middle + direction.rotated(Vector3.UP, rng.randf_range(-0.10, 0.10)) * resolved_branch_length * 0.48 + Vector3.DOWN * height * lerpf(0.025, -0.006, crown_t) * droop
			var start_radius := maxf(0.045, trunk_radius * lerpf(0.24, 0.08, crown_t))
			add_branch(branches, start, middle, start_radius, start_radius * 0.56, 1, height)
			add_branch(branches, middle, end, start_radius * 0.56, start_radius * 0.20, 2, height)
			add_foliage_along_segment(foliage, rng, start, middle, maxf(0.75, canopy_radius * 0.075), 2 + roundi(canopy_density * 2.0), height, genotype, Vector3(1.15, 0.72, 1.15))
			add_foliage_along_segment(foliage, rng, middle, end, maxf(0.70, canopy_radius * 0.070), 3 + roundi(canopy_density * 2.0), height, genotype, Vector3(1.08, 0.76, 1.08))
			if whorl_index < whorl_count - 2:
				for curtain_index in range(2):
					var attach := start.lerp(end, 0.35 + 0.28 * float(curtain_index))
					var curtain_end := attach + direction.rotated(Vector3.UP, (-1.0 if curtain_index == 0 else 1.0) * rng.randf_range(0.22, 0.38)) * resolved_branch_length * 0.22 + Vector3.DOWN * height * rng.randf_range(0.020, 0.045)
					add_branch(branches, attach, curtain_end, start_radius * 0.34, start_radius * 0.10, 3, height)
					add_foliage_along_segment(foliage, rng, attach, curtain_end, maxf(0.62, canopy_radius * 0.060), 2 + roundi(canopy_density * 2.0), height, genotype, Vector3(0.92, 0.82, 0.92))

func build_savanna(
	branches: Array[Dictionary],
	foliage: Array[Dictionary],
	rng: RandomNumberGenerator,
	height: float,
	trunk_radius: float,
	canopy_radius: float,
	growth_stage: float,
	canopy_density: float,
	genotype: Dictionary
) -> void:
	var fork_height := height * rng.randf_range(0.42, 0.54) * float(genotype.get("forkHeight", 1.0))
	fork_height = clampf(fork_height, height * 0.34, height * 0.64)
	var trunk_segments := 6 + roundi(growth_stage * 2.0)
	var trunk_points: Array[Vector3] = [Vector3.ZERO]
	var lean_angle := float(genotype.get("biasAngle", rng.randf() * TAU))
	var crown_bias := Vector3(cos(lean_angle), 0.0, sin(lean_angle))
	var lean := crown_bias * float(genotype.get("trunkLean", 0.025))
	for index in range(1, trunk_segments + 1):
		var t := float(index) / float(trunk_segments)
		trunk_points.append(lean * fork_height * t * t + Vector3.UP * fork_height * t)
	for index in range(trunk_segments):
		var t0 := float(index) / float(trunk_segments)
		var t1 := float(index + 1) / float(trunk_segments)
		add_branch(branches, trunk_points[index], trunk_points[index + 1], trunk_radius * lerpf(1.10, 0.54, t0), trunk_radius * lerpf(1.10, 0.54, t1), 0, height)

	var fork_count := clampi(4 + roundi(growth_stage * 2.0) + int(genotype.get("branchCountBias", 0)), 4, 8)
	var base_rotation := rng.randf() * TAU
	for fork_index in range(fork_count):
		if fork_index >= 4 and rng.randf() < float(genotype.get("branchGapChance", 0.04)):
			continue
		var angle := base_rotation + float(fork_index) * float(genotype.get("phyllotaxis", 2.39996323)) + rng.randf_range(-0.36, 0.36)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var directional_growth := lerpf(1.0, lerpf(0.56, 1.40, (direction.dot(crown_bias) + 1.0) * 0.5), float(genotype.get("asymmetry", 0.24)))
		var tangent := Vector3(-direction.z, 0.0, direction.x)
		var point := trunk_points[trunk_segments]
		var fork_length := canopy_radius * rng.randf_range(0.72, 1.12) * float(genotype.get("crownSpread", 1.0)) * directional_growth
		for segment_index in range(4):
			var t := float(segment_index + 1) / 4.0
			var next := point + direction * fork_length * rng.randf_range(0.19, 0.28) + tangent * canopy_radius * rng.randf_range(-0.045, 0.045) + Vector3.UP * height * rng.randf_range(0.035, 0.080) * (1.0 - t * 0.35) * float(genotype.get("crownUpright", 1.0))
			var radius_start := trunk_radius * lerpf(0.52, 0.14, float(segment_index) / 4.0)
			var radius_end := trunk_radius * lerpf(0.42, 0.065, t)
			add_branch(branches, point, next, radius_start, radius_end, 1, height)
			if segment_index >= 1:
				add_foliage_along_segment(foliage, rng, point, next, canopy_radius * 0.080, 2 + roundi(canopy_density * 3.0), height, genotype, Vector3(1.22, 0.52, 1.22))
				for side_index in range(2):
					var side := -1.0 if side_index == 0 else 1.0
					var attach := point.lerp(next, 0.34 + float(side_index) * 0.28)
					var fan_direction := direction.rotated(Vector3.UP, side * rng.randf_range(0.38, 0.72))
					var fan_end := attach + fan_direction * canopy_radius * rng.randf_range(0.25, 0.42) + Vector3.UP * height * rng.randf_range(0.015, 0.045)
					add_branch(branches, attach, fan_end, radius_end * 0.68, radius_end * 0.20, 2, height)
					add_foliage_along_segment(foliage, rng, attach, fan_end, canopy_radius * 0.075, 3 + roundi(canopy_density * 3.0), height, genotype, Vector3(1.28, 0.48, 1.28))
			point = next

func add_branch(
	branches: Array[Dictionary],
	start: Vector3,
	end: Vector3,
	radius_start: float,
	radius_end: float,
	generation: int,
	tree_height: float
) -> void:
	if branches.size() >= MAX_BRANCH_SEGMENTS or start.distance_squared_to(end) < 0.0025:
		return
	branches.append({
		"start": start,
		"end": end,
		"radiusStart": maxf(0.035, radius_start),
		"radiusEnd": maxf(0.018, minf(radius_start, radius_end)),
		"generation": generation,
		"windWeight": clampf(maxf(start.y, end.y) / maxf(1.0, tree_height), 0.0, 1.0)
	})

func add_foliage_along_segment(
	foliage: Array[Dictionary],
	rng: RandomNumberGenerator,
	start: Vector3,
	end: Vector3,
	cluster_radius: float,
	count: int,
	tree_height: float,
	genotype: Dictionary,
	shape := Vector3.ONE
) -> void:
	if foliage.size() >= MAX_FOLIAGE_CANDIDATES:
		return
	var delta := end - start
	var direction := delta.normalized()
	var side := direction.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = Vector3.RIGHT
	else:
		side = side.normalized()
	var normal := direction.cross(side).normalized()
	var effective_count := clampi(roundi(float(count) * float(genotype.get("foliageDensity", 1.0))), 1, 9)
	var effective_radius := cluster_radius * float(genotype.get("clusterScale", 1.0))
	for index in range(effective_count):
		if foliage.size() >= MAX_FOLIAGE_CANDIDATES:
			return
		var t := clampf((float(index) + rng.randf_range(0.28, 0.72)) / float(effective_count), 0.08, 0.98)
		var position := start.lerp(end, t)
		position += side * rng.randf_range(-0.36, 0.36) * effective_radius
		position += normal * rng.randf_range(-0.28, 0.28) * effective_radius
		var scale_variation := rng.randf_range(0.82, 1.18)
		foliage.append({
			"position": position,
			"rotation": Vector3(rng.randf_range(-0.26, 0.26), rng.randf() * TAU, rng.randf_range(-0.18, 0.18)),
			"scale": shape * effective_radius * scale_variation,
			"windWeight": clampf(position.y / maxf(1.0, tree_height), 0.20, 1.0),
			"variation": fmod(rng.randf() + float(genotype.get("leafVariation", 0.0)), 1.0),
			"clusterVariant": posmod(rng.randi() + int(genotype.get("clusterVariantBias", 0)), 4)
		})

func foliage_budget(architecture: String, canopy_density: float, genotype: Dictionary) -> int:
	var base := 236.0
	var minimum := 190
	match architecture:
		"broadleaf":
			base = 252.0
			minimum = 220
		"conifer":
			base = 226.0
			minimum = 190
		"savanna":
			base = 218.0
			minimum = 184
	var density_scale := clampf(canopy_density / 0.78, 0.72, 1.18)
	density_scale *= clampf(float(genotype.get("foliageDensity", 1.0)), 0.82, 1.22)
	return clampi(roundi(base * density_scale), minimum, MAX_FOLIAGE_ANCHORS)

func select_foliage_anchors(candidates: Array[Dictionary], budget: int, genetic_seed: int) -> Array[Dictionary]:
	var target := mini(maxi(0, budget), candidates.size())
	if candidates.size() <= target:
		return candidates
	var selected: Array[Dictionary] = []
	selected.resize(target)
	var stride := float(candidates.size()) / float(target)
	var phase := float(stable_hash("foliage-selection:%d" % genetic_seed) & 0xffff) / 65535.0
	for index in range(target):
		var candidate_index := clampi(floori((float(index) + 0.18 + phase * 0.62) * stride), 0, candidates.size() - 1)
		selected[index] = candidates[candidate_index]
	return selected

func build_genotype(rng: RandomNumberGenerator, architecture: String, growth_stage: float) -> Dictionary:
	var habit := "natural"
	var habit_index := 0
	var crown_spread := rng.randf_range(0.86, 1.16)
	var crown_upright := rng.randf_range(0.86, 1.16)
	var fork_height := rng.randf_range(0.88, 1.12)
	var apical_dominance := rng.randf_range(0.28, 0.72)
	var asymmetry := rng.randf_range(0.10, 0.38)
	var branch_gap_chance := rng.randf_range(0.015, 0.095)
	match architecture:
		"broadleaf":
			var habits := ["spreading", "rounded", "upright_oval", "windswept", "irregular"]
			habit_index = rng.randi_range(0, habits.size() - 1)
			habit = habits[habit_index]
			match habit:
				"spreading":
					crown_spread *= 1.22
					crown_upright *= 0.82
					fork_height *= 0.90
					apical_dominance *= 0.72
				"upright_oval":
					crown_spread *= 0.78
					crown_upright *= 1.28
					fork_height *= 1.12
					apical_dominance = minf(1.0, apical_dominance * 1.34)
				"windswept":
					crown_spread *= 1.10
					crown_upright *= 0.90
					asymmetry = rng.randf_range(0.58, 0.84)
				"irregular":
					asymmetry = rng.randf_range(0.34, 0.64)
					branch_gap_chance = rng.randf_range(0.10, 0.22) if growth_stage > 0.55 else rng.randf_range(0.05, 0.12)
		"conifer":
			var habits := ["conical", "columnar", "broad_mature", "windswept"]
			habit_index = rng.randi_range(0, habits.size() - 1)
			habit = habits[habit_index]
			apical_dominance = rng.randf_range(0.78, 0.98)
			if habit == "columnar":
				crown_spread *= 0.72
				crown_upright *= 1.15
			elif habit == "broad_mature":
				crown_spread *= 1.25
				crown_upright *= 0.88
			elif habit == "windswept":
				asymmetry = rng.randf_range(0.50, 0.78)
		"savanna":
			var habits := ["wide_umbrella", "multi_dome", "windswept_umbrella", "high_fork"]
			habit_index = rng.randi_range(0, habits.size() - 1)
			habit = habits[habit_index]
			crown_spread *= 1.16
			crown_upright *= 0.72
			apical_dominance *= 0.55
			if habit == "windswept_umbrella":
				asymmetry = rng.randf_range(0.58, 0.86)
			elif habit == "high_fork":
				fork_height *= 1.20
				crown_spread *= 0.88
	return {
		"habit": habit,
		"habitIndex": habit_index,
		"crownSpread": clampf(crown_spread, 0.62, 1.45),
		"crownUpright": clampf(crown_upright, 0.62, 1.45),
		"forkHeight": clampf(fork_height, 0.76, 1.28),
		"apicalDominance": clampf(apical_dominance, 0.12, 1.0),
		"asymmetry": clampf(asymmetry, 0.05, 0.88),
		"biasAngle": rng.randf() * TAU,
		"trunkLean": rng.randf_range(0.004, 0.040) * lerpf(0.72, 1.45, asymmetry),
		"phyllotaxis": rng.randf_range(2.22, 2.58),
		"branchCountBias": rng.randi_range(-1, 2),
		"branchDensity": rng.randf_range(0.84, 1.18),
		"branchGapChance": branch_gap_chance,
		"branchDroop": rng.randf_range(0.72, 1.36),
		"whorlTwist": rng.randf_range(1.45, 2.48),
		"foliageDensity": rng.randf_range(0.82, 1.22),
		"clusterScale": rng.randf_range(0.86, 1.16),
		"clusterVariantBias": rng.randi_range(0, 3),
		"leafVariation": rng.randf()
	}

func architecture_for_family(family: String) -> String:
	if family.contains("conifer"):
		return "conifer"
	if family.contains("savanna"):
		return "savanna"
	return "broadleaf"

func recipe_signature(
	architecture: String,
	genetic_seed: int,
	height: float,
	trunk_radius: float,
	canopy_radius: float,
	genotype: Dictionary,
	branches: Array[Dictionary],
	foliage: Array[Dictionary]
) -> String:
	var hash_value := stable_hash("v%d:%s:%d:%d:%d:%d" % [
		RECIPE_VERSION,
		architecture,
		genetic_seed,
		roundi(height * 1000.0),
		roundi(trunk_radius * 1000.0),
		roundi(canopy_radius * 1000.0)
	])
	hash_value = stable_hash("%d:%s:%d:%d:%d" % [
		hash_value,
		String(genotype.get("habit", "natural")),
		roundi(float(genotype.get("crownSpread", 1.0)) * 1000.0),
		roundi(float(genotype.get("crownUpright", 1.0)) * 1000.0),
		roundi(float(genotype.get("asymmetry", 0.0)) * 1000.0)
	])
	for branch in branches:
		var start: Vector3 = branch["start"]
		var end: Vector3 = branch["end"]
		hash_value = stable_hash("%d:%d,%d,%d:%d,%d,%d:%d:%d" % [
			hash_value,
			roundi(start.x * 1000.0), roundi(start.y * 1000.0), roundi(start.z * 1000.0),
			roundi(end.x * 1000.0), roundi(end.y * 1000.0), roundi(end.z * 1000.0),
			roundi(float(branch["radiusStart"]) * 1000.0), roundi(float(branch["radiusEnd"]) * 1000.0)
		])
	for anchor in foliage:
		var position: Vector3 = anchor["position"]
		hash_value = stable_hash("%d:%d,%d,%d" % [hash_value, roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0)])
	return "%08x" % [hash_value & 0xffffffff]

func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
