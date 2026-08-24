extends RefCounted
class_name CitadelTerrainOperationPolicy

const TERRAIN_CELL_SIZE := 1.35
const SITE_RADIUS_CELLS := 76
const MIN_APPROACH_CELLS := 32
const MAX_APPROACH_CELLS := 64
const APPROACH_STEP_CELLS := 4
const MAX_APPROACH_GRADE := 0.36
const MAX_CORE_CUT_FILL := 10.8
const MIN_DRY_CLEARANCE := 1.7

static func build_contract(center: Vector2i, natural_surface_sample: Callable) -> Dictionary:
	if not natural_surface_sample.is_valid():
		return {"accepted": false, "reason": "surface_sampler_unavailable"}
	var core_values: Array[float] = []
	var center_biome := ""
	for offset in core_sample_offsets():
		var sample := validated_sample(natural_surface_sample, center + offset)
		if not bool(sample.get("accepted", false)):
			return {"accepted": false, "reason": String(sample.get("reason", "invalid_core_sample")), "sampleCell": center + offset}
		if offset == Vector2i.ZERO:
			center_biome = String(sample.get("biome", ""))
		core_values.append(float(sample.get("surfaceY", 0.0)))
	core_values.sort()
	var level := snappedf(core_values[core_values.size() / 2], TERRAIN_CELL_SIZE)
	var max_cut_fill := 0.0
	for value in core_values:
		max_cut_fill = maxf(max_cut_fill, absf(value - level))
	if max_cut_fill > MAX_CORE_CUT_FILL:
		return {"accepted": false, "reason": "core_cut_fill_exceeded", "maxCutFill": max_cut_fill, "limit": MAX_CORE_CUT_FILL}
	for approach_cells in range(MIN_APPROACH_CELLS, MAX_APPROACH_CELLS + 1, APPROACH_STEP_CELLS):
		var grade_proof := verify_approach(center, level, approach_cells, natural_surface_sample)
		if bool(grade_proof.get("accepted", false)):
			return {
				"accepted": true,
				"level": level,
				"biome": center_biome,
				"coreSampleCount": core_values.size(),
				"minimumCoreSurfaceY": core_values.front(),
				"maximumCoreSurfaceY": core_values.back(),
				"maxCutFill": max_cut_fill,
				"approachCells": approach_cells,
				"maximumSampledApproachGrade": float(grade_proof.get("maximumSampledApproachGrade", 0.0)),
				"maximumApproachGrade": MAX_APPROACH_GRADE
			}
	return {"accepted": false, "reason": "bounded_approach_grade_exceeded", "maxCutFill": max_cut_fill, "maximumApproachCells": MAX_APPROACH_CELLS, "maximumApproachGrade": MAX_APPROACH_GRADE}

static func verify_approach(center: Vector2i, level: float, approach_cells: int, natural_surface_sample: Callable) -> Dictionary:
	var maximum_grade := 0.0
	for direction in sample_directions():
		var previous_y := level
		var previous_distance := SITE_RADIUS_CELLS
		for distance in range(SITE_RADIUS_CELLS + APPROACH_STEP_CELLS, SITE_RADIUS_CELLS + approach_cells + 1, APPROACH_STEP_CELLS):
			var sample_cell := center + Vector2i(roundi(direction.x * float(distance)), roundi(direction.y * float(distance)))
			var sample := validated_sample(natural_surface_sample, sample_cell)
			if not bool(sample.get("accepted", false)):
				return {"accepted": false, "reason": String(sample.get("reason", "invalid_approach_sample")), "sampleCell": sample_cell}
			var blend := clampf(float(distance - SITE_RADIUS_CELLS) / float(approach_cells), 0.0, 1.0)
			blend = blend * blend * (3.0 - 2.0 * blend)
			var blended_y := lerpf(level, float(sample.get("surfaceY", level)), blend)
			var horizontal_run := float(distance - previous_distance) * TERRAIN_CELL_SIZE
			maximum_grade = maxf(maximum_grade, absf(blended_y - previous_y) / maxf(horizontal_run, 0.001))
			previous_y = blended_y
			previous_distance = distance
	if maximum_grade > MAX_APPROACH_GRADE:
		return {"accepted": false, "reason": "approach_grade_exceeded", "maximumSampledApproachGrade": maximum_grade}
	return {"accepted": true, "maximumSampledApproachGrade": maximum_grade}

static func validated_sample(natural_surface_sample: Callable, cell: Vector2i) -> Dictionary:
	var sample_value = natural_surface_sample.call(Vector3i(cell.x, 0, cell.y))
	if not (sample_value is Dictionary):
		return {"accepted": false, "reason": "missing_surface_sample"}
	var sample: Dictionary = sample_value
	var surface_y := float(sample.get("surfaceY", NAN))
	var water_level := float(sample.get("waterLevel", 11.1))
	var biome := String(sample.get("biome", ""))
	if is_nan(surface_y):
		return {"accepted": false, "reason": "invalid_surface_height"}
	if not bool(sample.get("solid", false)) or String(sample.get("fluid", "")) != "":
		return {"accepted": false, "reason": "non_solid_or_fluid_surface"}
	if biome in ["", "ocean", "beach", "underground", "underground_air"]:
		return {"accepted": false, "reason": "invalid_surface_biome"}
	if surface_y < water_level + MIN_DRY_CLEARANCE:
		return {"accepted": false, "reason": "minimum_dry_clearance_failed"}
	return {"accepted": true, "surfaceY": surface_y, "biome": biome}

static func core_sample_offsets() -> Array[Vector2i]:
	var offsets: Array[Vector2i] = [Vector2i.ZERO]
	for radius in [24, 48, SITE_RADIUS_CELLS]:
		for direction in sample_directions():
			offsets.append(Vector2i(roundi(direction.x * float(radius)), roundi(direction.y * float(radius))))
	return offsets

static func sample_directions() -> Array[Vector2]:
	return [Vector2.RIGHT, Vector2(1.0, 1.0).normalized(), Vector2.DOWN, Vector2(-1.0, 1.0).normalized(), Vector2.LEFT, Vector2(-1.0, -1.0).normalized(), Vector2.UP, Vector2(1.0, -1.0).normalized()]

static func surface_y_for_cell(site: Dictionary, cell: Vector3i, natural_surface_y: Callable) -> float:
	var natural_y := float(natural_surface_y.call(cell))
	var terrain: Dictionary = site.get("terrain", {}) if site.get("terrain", {}) is Dictionary else {}
	var operation: Dictionary = terrain.get("citadelTerrainOperation", {}) if terrain.get("citadelTerrainOperation", {}) is Dictionary else {}
	var center: Variant = operation.get("center", site.get("center", Vector2i.ZERO))
	if not (center is Vector2i):
		return natural_y
	var radius := float(operation.get("coreRadiusCells", SITE_RADIUS_CELLS))
	var approach_cells := float(operation.get("approachCells", 0))
	var level := float(operation.get("level", natural_y))
	var distance := Vector2(float(cell.x - center.x), float(cell.z - center.y)).length()
	if distance <= radius:
		return level
	if approach_cells <= 0.0 or distance > radius + approach_cells:
		return natural_y
	var blend := clampf((distance - radius) / approach_cells, 0.0, 1.0)
	blend = blend * blend * (3.0 - 2.0 * blend)
	return lerpf(level, natural_y, blend)
