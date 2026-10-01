extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "underground_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const VISUAL_SAMPLE_SEARCH_RADIUS_CELLS := 224
const VISUAL_SAMPLE_MIN_DEPTH_CELLS := 16
const VISUAL_SAMPLE_MAX_DEPTH_CELLS := 48
const VISUAL_SAMPLE_MIN_CONNECTED_CELLS := 32
const VISUAL_SAMPLE_CONNECTIVITY_RADIUS_CELLS := 8
const VISUAL_SAMPLE_SURFACE_EXPOSURE_MAX_CELLS := 4096
const VISUAL_SAMPLE_SURFACE_EXPOSURE_RADIUS_CELLS := 48
const REQUIRED_CAPTURE_STAGES := [
	"underground_air_reference",
	"underground_wall_boundary",
	"underground_floor_boundary",
	"underground_ceiling_boundary",
	"underground_material_probe",
	"underground_collision_probe"
]
const ACCEPTANCE_CLAIM := "procedural_underground_volume_visual"

var main: Node3D
var startup_failure_result: Dictionary = {}
var player: CharacterBody3D
var gameplay_camera: Camera3D
var camera: Camera3D
var observer_light: OmniLight3D
var target_light: OmniLight3D
var world_generation
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var sample_record: Dictionary = {}
var sample_cell := Vector3i.ZERO
var sample_position := Vector3.ZERO
var boundary_directions: Array[Vector3i] = []
var air_directions: Array[Vector3i] = []
var stage_targets := {}
var finished := false
var elapsed := 0.0
var watchdog_seconds := 90.0
var last_camera_target := Vector3.ZERO

func _ready() -> void:
	configure_from_environment()
	apply_resolution()
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result("underground_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/underground/screenshots/underground-visual")
	run_token = OS.get_environment("VOXEL_UNDERGROUND_VISUAL_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_UNDERGROUND_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_value != "":
		watchdog_seconds = maxf(30.0, float(watchdog_value))
	ensure_dir(report_path.get_base_dir())
	ensure_dir(screenshot_dir)
	if progress_path != "":
		ensure_dir(progress_path.get_base_dir())

func apply_resolution() -> void:
	DisplayServer.window_set_size(Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	var root_window := get_tree().root
	root_window.set("size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	root_window.set("content_scale_size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 2)
	main.set("force_underground_volume_debug", true)
	main.set("force_underground_volume_fine_focus", true)
	main.set("visual_quality", {
		"decorativeDensity": 0.03,
		"decorativeDetailCap": 4,
		"particleDensity": 0.0
	})
	write_progress("main_instantiated")
	add_child(main)
	# Explicit diagnostic setup only; this is not playable-world readiness.
	if not await main.wait_for_startup_loading_complete(240.0, true):
		if is_instance_valid(main):
			startup_failure_result = main.get("startup_loading_failure_result").duplicate(true)
		add_result("underground_visual_startup_setup", false, JSON.stringify({"reason": "startup_setup_not_ready", "startupLoadingFailureResult": startup_failure_result, "gameplayAcceptance": false}))
		finish(1)
		return
	main.set_process(false)
	main.set_physics_process(false)
	write_progress("main_added")
	bind_scene_nodes()
	if main == null or world_generation == null:
		add_result("underground_visual_scene_ready", false, "main/world_generation missing")
		finish(1)
		return
	configure_scene()
	write_progress("scene_configured")
	if not select_underground_sample():
		add_result("underground_visual_volume_selected", false, "no generated underground_air sample found")
		finish(1)
		return
	load_underground_chunks()
	write_progress("underground_chunks_loaded")
	configure_camera_and_light()
	await wait_process_frames(3)
	await wait_physics_frames(3)
	await wait_process_frames(3)

	add_result("underground_visual_volume_selected", true, JSON.stringify(underground_summary()))
	add_result("underground_visual_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
	var boundary_summary := generated_boundary_summary()
	add_result("underground_visual_generated_solid_boundaries", bool(boundary_summary.get("passed", false)), JSON.stringify(boundary_summary))
	var geometry := chunk_geometry_summary()
	add_result("underground_visual_mesh_and_collision_loaded", bool(geometry.get("passed", false)), JSON.stringify(geometry))

	await capture_stage("underground_air_reference", stage_direction("air"))
	await capture_stage("underground_wall_boundary", stage_direction("wall"))
	await capture_stage("underground_floor_boundary", stage_direction("floor"))
	await capture_stage("underground_ceiling_boundary", stage_direction("ceiling"))
	await capture_stage("underground_material_probe", stage_direction("material"))
	await capture_stage("underground_collision_probe", stage_direction("collision"))
	add_result("underground_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
	finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D
	if player != null:
		gameplay_camera = player.get("camera") as Camera3D
	world_generation = main.get("world_generation_system") if main != null else null

func configure_scene() -> void:
	neutralize_intro_clock_freeze()
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
	main.set("time_of_day", fposmod((14.0 / 24.0) - 0.25, 1.0))
	var weather_system = main.get("weather_system")
	if weather_system != null and weather_system.has_method("force_weather"):
		weather_system.force_weather("clear", 0.0, 0.18, Vector3.ZERO)
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	var hud = main.get("hud")
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	elif hud is Node:
		var hud_root = hud.get("hud_root")
		if hud_root is Control:
			(hud_root as Control).visible = false

func neutralize_intro_clock_freeze() -> void:
	var tutorial = main.get("tutorial_system") if main != null else null
	if tutorial == null:
		return
	tutorial.set("intro_repair_active", false)
	tutorial.set("intro_repair_complete", true)
	tutorial.set("intro_bed_used", true)
	tutorial.set("intro_elder_dialogue_acknowledged", true)
	tutorial.set("final_night_active", false)
	tutorial.set("final_night_complete", true)
	if tutorial.has_method("clear_dialogue_focus"):
		tutorial.call("clear_dialogue_focus")

func select_underground_sample() -> bool:
	if world_generation == null or not world_generation.has_method("sample_cell"):
		return false
	if world_generation.has_method("find_underground_air_sample"):
		var found: Dictionary = world_generation.call(
			"find_underground_air_sample",
			VISUAL_SAMPLE_SEARCH_RADIUS_CELLS,
			VISUAL_SAMPLE_MIN_DEPTH_CELLS,
			VISUAL_SAMPLE_MAX_DEPTH_CELLS
		)
		if apply_underground_sample_record(found, "sampler"):
			return true
	if select_underground_sample_by_local_scan(
		mini(VISUAL_SAMPLE_SEARCH_RADIUS_CELLS, 128),
		VISUAL_SAMPLE_MIN_DEPTH_CELLS,
		VISUAL_SAMPLE_MAX_DEPTH_CELLS
	):
		return true
	return false

func apply_underground_sample_record(record: Dictionary, source: String) -> bool:
	if record.is_empty():
		return false
	var cell: Vector3i = record.get("cell", Vector3i.ZERO)
	var sample: Dictionary = world_generation.call("sample_cell", cell)
	if String(sample.get("biome", "")) != "underground_air" or bool(sample.get("solid", true)):
		return false
	if String(sample.get("fluid", "")) != "":
		return false
	sample_record = record.duplicate(true)
	sample_record["sample"] = sample
	sample_record["sampleId"] = "%s:%d,%d,%d" % [source, cell.x, cell.y, cell.z]
	sample_cell = cell
	sample_position = cell_center(sample_cell)
	classify_neighbor_directions()
	if not build_stage_targets() and not select_stageable_cell_from_region(record, source):
		sample_record.clear()
		stage_targets.clear()
		boundary_directions.clear()
		air_directions.clear()
		return false
	write_progress("%s_stage_targets_ready" % source)
	return true

func select_stageable_cell_from_region(record: Dictionary, source: String) -> bool:
	var origin: Vector3i = record.get("cell", Vector3i.ZERO)
	var cells := underground_region_air_cells(origin, 192, 12)
	for candidate in cells:
		var candidate_sample: Dictionary = world_generation.call("sample_cell", candidate)
		if String(candidate_sample.get("biome", "")) != "underground_air" or bool(candidate_sample.get("solid", true)):
			continue
		if String(candidate_sample.get("fluid", "")) != "":
			continue
		sample_cell = candidate
		sample_position = cell_center(sample_cell)
		sample_record = record.duplicate(true)
		sample_record["cell"] = sample_cell
		sample_record["position"] = sample_position
		sample_record["sample"] = candidate_sample
		sample_record["sampleId"] = "%s:%d,%d,%d" % [source, sample_cell.x, sample_cell.y, sample_cell.z]
		classify_neighbor_directions()
		if build_stage_targets():
			return true
	return false

func select_underground_sample_by_local_scan(search_radius: int, min_depth_cells: int, max_depth_cells: int) -> bool:
	if world_generation == null or not world_generation.has_method("sample_cell"):
		return false
	var step := 4
	var min_depth := maxi(1, min_depth_cells)
	var max_depth := maxi(min_depth, max_depth_cells)
	var depth_step := 1
	if search_radius > 32 or max_depth - min_depth > 24:
		depth_step = 4
	var best_record := {}
	var best_cell := Vector3i.ZERO
	var best_position := Vector3.ZERO
	var best_stage_targets := {}
	var best_boundary_directions: Array[Vector3i] = []
	var best_air_directions: Array[Vector3i] = []
	var best_score := -INF
	for radius in range(0, search_radius + 1, step):
		for z in range(-radius, radius + 1, step):
			for x in range(-radius, radius + 1, step):
				if radius > 0 and absi(x) != radius and absi(z) != radius:
					continue
				var surface_y := surface_y_for_visual_cell(Vector3i(x, 0, z))
				var surface_cell_y := floori(surface_y / CELL)
				for depth in range(min_depth, max_depth + 1, depth_step):
					var cell := Vector3i(x, surface_cell_y - depth, z)
					var sample: Dictionary = world_generation.call("sample_cell", cell)
					if String(sample.get("biome", "")) != "underground_air" or bool(sample.get("solid", true)):
						continue
					if String(sample.get("fluid", "")) != "":
						continue
					if float(sample.get("density", 0.0)) > -CELL * 0.18:
						continue
					var boundary := boundary_counts_for_cell(cell)
					if int(boundary.get("solid", 0)) < 2 or int(boundary.get("air", 0)) < 2:
						continue
					if underground_air_cell_has_surface_exposure(cell):
						continue
					var connected_region := connected_region_summary_for_cell(cell)
					if int(connected_region.get("airCells", 0)) < VISUAL_SAMPLE_MIN_CONNECTED_CELLS:
						continue
					var record := {
						"id": "underground-air-local:%d,%d,%d" % [cell.x, cell.y, cell.z],
						"sampleId": "underground-air-local:%d,%d,%d" % [cell.x, cell.y, cell.z],
						"cell": cell,
						"surfaceCell": Vector2i(x, z),
						"position": cell_center(cell),
						"surfaceY": surface_y,
						"depthCells": depth,
						"sample": sample,
						"connectedRegion": connected_region
					}
					sample_record = record
					sample_cell = cell
					sample_position = cell_center(sample_cell)
					classify_neighbor_directions()
					if not build_stage_targets():
						continue
					var score := float(depth) * 4.0
					score += float(int(connected_region.get("airCells", 0))) * 0.35
					score += float(int(connected_region.get("branchDirections", 0))) * 10.0
					score += float(int(boundary.get("solid", 0))) * 8.0
					score -= float(radius) * 0.05
					if score > best_score:
						best_score = score
						best_record = record.duplicate(true)
						best_cell = cell
						best_position = sample_position
						best_stage_targets = stage_targets.duplicate(true)
						best_boundary_directions.clear()
						best_air_directions.clear()
						for direction in boundary_directions:
							best_boundary_directions.append(direction)
						for direction in air_directions:
							best_air_directions.append(direction)
	if best_record.is_empty():
		sample_record.clear()
		stage_targets.clear()
		boundary_directions.clear()
		air_directions.clear()
		return false
	sample_record = best_record
	sample_cell = best_cell
	sample_position = best_position
	stage_targets = best_stage_targets
	boundary_directions.clear()
	air_directions.clear()
	for direction in best_boundary_directions:
		boundary_directions.append(direction)
	for direction in best_air_directions:
		air_directions.append(direction)
	write_progress("local_stage_targets_ready")
	return true

func underground_air_cell_has_surface_exposure(cell: Vector3i) -> bool:
	if world_generation == null or not world_generation.has_method("underground_air_sample_has_surface_exposure"):
		return false
	return bool(world_generation.call(
		"underground_air_sample_has_surface_exposure",
		cell,
		VISUAL_SAMPLE_SURFACE_EXPOSURE_MAX_CELLS,
		VISUAL_SAMPLE_SURFACE_EXPOSURE_RADIUS_CELLS
	))

func connected_region_summary_for_cell(cell: Vector3i) -> Dictionary:
	if world_generation != null and world_generation.has_method("underground_air_connected_region_summary"):
		return world_generation.call("underground_air_connected_region_summary", cell, VISUAL_SAMPLE_MIN_CONNECTED_CELLS * 4, VISUAL_SAMPLE_CONNECTIVITY_RADIUS_CELLS)
	var cells := underground_region_air_cells(cell, VISUAL_SAMPLE_MIN_CONNECTED_CELLS * 4, VISUAL_SAMPLE_CONNECTIVITY_RADIUS_CELLS)
	return {
		"airCells": cells.size(),
		"branchDirections": 0,
		"solidBoundarySamples": 0
	}

func nearest_boundary_record(cell: Vector3i, mode: String, directions: Array[Vector3i], max_steps: int) -> Dictionary:
	for direction in directions:
		for step in range(0, maxi(0, max_steps) + 1):
			var candidate := cell + direction * step
			var sample: Dictionary = world_generation.call("sample_cell", candidate)
			if bool(sample.get("solid", false)):
				break
			if String(sample.get("biome", "")) != "underground_air" or String(sample.get("fluid", "")) != "":
				break
			var boundary_directions := boundary_directions_for_mode(candidate, mode)
			if not boundary_directions.is_empty():
				return stage_target_record(candidate, boundary_directions[0], mode)
	return {}

func build_stage_targets_from_current_cell() -> bool:
	stage_targets.clear()
	var wall_directions := boundary_directions_for_mode(sample_cell, "wall")
	var floor_directions := boundary_directions_for_mode(sample_cell, "floor")
	var ceiling_directions := boundary_directions_for_mode(sample_cell, "ceiling")
	if wall_directions.is_empty() or floor_directions.is_empty() or ceiling_directions.is_empty():
		return false
	var air_direction := first_air_neighbor_direction(sample_cell)
	if air_direction == Vector3i.ZERO:
		return false
	var air_record := stage_target_record(sample_cell, air_direction, "air_reference")
	var wall_record := stage_target_record(sample_cell, wall_directions[0], "wall")
	var floor_record := stage_target_record(sample_cell, floor_directions[0], "floor")
	var ceiling_record := stage_target_record(sample_cell, ceiling_directions[0], "ceiling")
	stage_targets["underground_air_reference"] = air_record
	stage_targets["underground_air_reference_wall"] = wall_record
	stage_targets["underground_wall_boundary"] = wall_record
	stage_targets["underground_floor_boundary"] = floor_record
	stage_targets["underground_ceiling_boundary"] = ceiling_record
	stage_targets["underground_material_probe"] = wall_record
	stage_targets["underground_collision_probe"] = wall_record
	write_progress("local_stage_targets_ready")
	return true

func first_air_neighbor_direction(cell: Vector3i) -> Vector3i:
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		if bool(sample.get("solid", false)):
			continue
		if String(sample.get("biome", "")) == "underground_air" and String(sample.get("fluid", "")) == "":
			return direction
	return Vector3i.ZERO

func surface_y_for_visual_cell(cell: Vector3i) -> float:
	if world_generation != null and world_generation.has_method("surface_y_for_cell"):
		return float(world_generation.call("surface_y_for_cell", cell))
	if world_generation != null and world_generation.has_method("terrain_reference_surface_y_for_cell"):
		return float(world_generation.call("terrain_reference_surface_y_for_cell", cell))
	return float(cell.y) * CELL

func classify_neighbor_directions() -> void:
	boundary_directions.clear()
	air_directions.clear()
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", sample_cell + direction)
		if bool(sample.get("solid", false)):
			boundary_directions.append(direction)
		else:
			air_directions.append(direction)

func build_stage_targets() -> bool:
	stage_targets.clear()
	var region_cells := underground_region_air_cells(sample_cell, 96, 8)
	if region_cells.is_empty():
		region_cells = [sample_cell]
	var air_target := best_air_reference_target(region_cells)
	var wall_target := best_boundary_target(region_cells, "wall")
	var floor_target := best_boundary_target(region_cells, "floor")
	var ceiling_target := best_boundary_target(region_cells, "ceiling")
	if wall_target.is_empty() or floor_target.is_empty() or ceiling_target.is_empty():
		return false
	stage_targets["underground_air_reference"] = air_target if not air_target.is_empty() else wall_target
	stage_targets["underground_air_reference_wall"] = wall_target
	stage_targets["underground_wall_boundary"] = wall_target
	stage_targets["underground_floor_boundary"] = floor_target
	stage_targets["underground_ceiling_boundary"] = ceiling_target
	stage_targets["underground_material_probe"] = wall_target
	stage_targets["underground_collision_probe"] = wall_target
	return true

func underground_region_air_cells(start_cell: Vector3i, max_cells: int, max_radius: int) -> Array[Vector3i]:
	var start_sample: Dictionary = world_generation.call("sample_cell", start_cell)
	if bool(start_sample.get("solid", true)) or String(start_sample.get("biome", "")) != "underground_air":
		return []
	var cells: Array[Vector3i] = []
	var queue: Array[Vector3i] = [start_cell]
	var visited := { start_cell: true }
	var read_index := 0
	while read_index < queue.size() and cells.size() < maxi(1, max_cells):
		var cell: Vector3i = queue[read_index]
		read_index += 1
		cells.append(cell)
		for direction in cardinal_directions():
			var next := cell + direction
			if visited.has(next):
				continue
			if absi(next.x - start_cell.x) > max_radius or absi(next.y - start_cell.y) > max_radius or absi(next.z - start_cell.z) > max_radius:
				continue
			var sample: Dictionary = world_generation.call("sample_cell", next)
			if bool(sample.get("solid", false)):
				continue
			if String(sample.get("biome", "")) != "underground_air":
				continue
			if String(sample.get("fluid", "")) != "":
				continue
			visited[next] = true
			queue.append(next)
	return cells

func best_air_reference_target(cells: Array[Vector3i]) -> Dictionary:
	var best := {}
	var best_score := -INF
	for cell in cells:
		var solid_neighbors := 0
		var air_neighbors := 0
		var best_air_direction := Vector3i.ZERO
		var best_closure := 0
		for direction in cardinal_directions():
			var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
			if bool(sample.get("solid", false)):
				solid_neighbors += 1
				continue
			if String(sample.get("biome", "")) == "underground_air" and String(sample.get("fluid", "")) == "":
				air_neighbors += 1
				var closure := air_direction_closure_distance(cell, direction, 8)
				if closure > 0 and (best_closure == 0 or closure < best_closure):
					best_air_direction = direction
					best_closure = closure
		if air_neighbors < 2 or solid_neighbors < 1 or best_air_direction == Vector3i.ZERO:
			continue
		var score := float(air_neighbors * 9 + solid_neighbors * 7 + maxi(0, 10 - best_closure) * 6)
		if score > best_score:
			best_score = score
			best = stage_target_record(cell, best_air_direction, "air_reference")
	return best

func air_direction_closure_distance(cell: Vector3i, direction: Vector3i, max_steps: int) -> int:
	for step in range(2, maxi(2, max_steps) + 1):
		var probe := cell + Vector3i(direction.x * step, direction.y * step, direction.z * step)
		var sample: Dictionary = world_generation.call("sample_cell", probe)
		if bool(sample.get("solid", false)):
			return step
		if String(sample.get("biome", "")) != "underground_air" or String(sample.get("fluid", "")) != "":
			return 0
	return 0

func best_boundary_target(cells: Array[Vector3i], mode: String) -> Dictionary:
	var best := {}
	var best_score := -INF
	for cell in cells:
		var directions := boundary_directions_for_mode(cell, mode)
		if directions.is_empty():
			continue
		var boundary := boundary_counts_for_cell(cell)
		var air_neighbors := int(boundary.get("air", 0))
		if air_neighbors < 2:
			continue
		var score := float(air_neighbors * 10 + int(boundary.get("solid", 0)) * 5)
		if mode == "wall" and (solid_at_neighbor(cell, Vector3i(0, 1, 0)) or solid_at_neighbor(cell, Vector3i(0, -1, 0))):
			score += 8.0
		if score > best_score:
			best_score = score
			best = stage_target_record(cell, directions[0], mode)
	return best

func boundary_directions_for_mode(cell: Vector3i, mode: String) -> Array[Vector3i]:
	var directions: Array[Vector3i] = []
	if mode == "floor":
		if solid_at_neighbor(cell, Vector3i(0, -1, 0)):
			directions.append(Vector3i(0, -1, 0))
		return directions
	if mode == "ceiling":
		if solid_at_neighbor(cell, Vector3i(0, 1, 0)):
			directions.append(Vector3i(0, 1, 0))
		return directions
	for direction in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if solid_at_neighbor(cell, direction):
			directions.append(direction)
	return directions

func boundary_counts_for_cell(cell: Vector3i) -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
		elif String(sample.get("biome", "")) == "underground_air" and String(sample.get("fluid", "")) == "":
			air_neighbors += 1
	return {
		"solid": solid_neighbors,
		"air": air_neighbors
	}

func solid_at_neighbor(cell: Vector3i, direction: Vector3i) -> bool:
	var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
	return bool(sample.get("solid", false))

func stage_target_record(cell: Vector3i, direction: Vector3i, mode: String) -> Dictionary:
	var sample: Dictionary = world_generation.call("sample_cell", cell)
	return {
		"cell": cell,
		"direction": direction,
		"mode": mode,
		"position": cell_center(cell),
		"sample": sample_signature(sample),
		"boundary": boundary_counts_for_cell(cell)
	}

func cardinal_directions() -> Array[Vector3i]:
	return [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]

func load_underground_chunks() -> void:
	if player != null:
		player.global_position = sample_position
		player.velocity = Vector3.ZERO
	clear_loaded_chunks()
	var center_key: Vector2i = main.call("cell_to_chunk", sample_cell.x, sample_cell.z)
	var required_chunks := { center_key: true }
	for record_value in stage_targets.values():
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var cell: Vector3i = record.get("cell", sample_cell)
		var key: Vector2i = main.call("cell_to_chunk", cell.x, cell.z)
		required_chunks[key] = true
	for key_value in required_chunks.keys():
		load_chunk_key(key_value as Vector2i)
	clear_non_terrain_chunk_nodes()

func clear_loaded_chunks() -> void:
	var chunks_value = main.get("chunks") if main != null else {}
	if not (chunks_value is Dictionary):
		return
	var chunks: Dictionary = chunks_value
	for key in chunks.keys().duplicate():
		var chunk := chunks[key] as Node
		if chunk != null and is_instance_valid(chunk):
			chunk.queue_free()
		chunks.erase(key)
	if main.has_method("clear_chunk_asset_cache"):
		main.call("clear_chunk_asset_cache")

func load_chunk_key(chunk_key: Vector2i) -> void:
	if main == null or not main.has_method("create_chunk"):
		return
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	if chunks.has(chunk_key):
		return
	main.call("create_chunk", chunk_key.x, chunk_key.y, false)

func clear_non_terrain_chunk_nodes() -> void:
	if main == null:
		return
	var chunks_value = main.get("chunks")
	if not (chunks_value is Dictionary):
		return
	var chunks: Dictionary = chunks_value
	for key_value in chunks.keys():
		var chunk := chunks[key_value] as Node
		if chunk == null:
			continue
		for child in chunk.get_children():
			if child.name in ["TerrainMesh", "TerrainFluidMesh", "TerrainBody"]:
				continue
			if child is Node3D:
				(child as Node3D).visible = false

func configure_camera_and_light() -> void:
	if gameplay_camera != null:
		gameplay_camera.current = false
	camera = Camera3D.new()
	camera.name = "UndergroundVolumePlaytestCamera"
	camera.fov = 16.0
	add_child(camera)
	observer_light = make_capture_light("UndergroundVolumePlaytestCameraLight", 18.0, CELL * 18.0)
	add_child(observer_light)
	target_light = make_capture_light("UndergroundVolumePlaytestTargetLight", 12.0, CELL * 10.0)
	add_child(target_light)

func make_capture_light(light_name: String, energy: float, light_range: float) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = light_name
	light.light_energy = energy
	light.omni_range = light_range
	light.shadow_enabled = false
	light.light_cull_mask = 0xFFFFFFFF
	light.set("base_range", light_range)
	light.set_meta("light_role", "terrain_wash")
	light.add_to_group("local_light_rig_fill")
	return light

func capture_stage(stage: String, direction: Vector3i) -> void:
	position_camera(stage, direction)
	if player != null:
		player.global_position = camera.global_position
		player.velocity = Vector3.ZERO
	if main != null and main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var luminance := image_luminance_summary(image)
	var sky_leak := image_sky_leak_summary(image)
	var sightline := camera_sightline_summary()
	var line_target := volume_line_target_for_stage(stage, sightline)
	var line_summary := volume_line_summary(camera.global_position, line_target)
	var capture := {
		"stage": stage,
		"elapsed": rounded(elapsed),
		"camera": vec3(camera.global_position),
		"target": vec3(last_camera_target),
		"light": vec3(observer_light.global_position if observer_light != null else Vector3.ZERO),
		"targetLight": vec3(target_light.global_position if target_light != null else Vector3.ZERO),
		"direction": vec3i(direction),
		"volumeLine": line_summary,
		"sightline": sightline,
		"underground": underground_summary(),
		"luminance": luminance,
		"skyLeak": sky_leak
	}
	captures.append(capture)
	timeline.append({
		"event": "capture",
		"stage": stage,
		"elapsed": rounded(elapsed),
		"saved": err == OK,
		"path": path,
		"volumeLine": line_summary,
		"sightline": sightline
	})
	add_result("capture_%s_saved" % stage, err == OK and FileAccess.file_exists(path), path)
	if stage == "underground_air_reference":
		add_result("underground_visual_%s_line_stays_in_generated_air" % stage, int(line_summary.get("undergroundAirSamples", 0)) > 0 and int(line_summary.get("solidSamples", 0)) == 0, JSON.stringify(line_summary))
	else:
		add_result("underground_visual_%s_line_hits_generated_boundary" % stage, int(line_summary.get("solidSamples", 0)) > 0, JSON.stringify(line_summary))
	if stage in ["underground_wall_boundary", "underground_floor_boundary", "underground_ceiling_boundary", "underground_collision_probe"]:
		add_result("underground_visual_%s_raycast_hits_collision" % stage, bool(sightline.get("hit", false)), JSON.stringify(sightline))
	add_result("underground_visual_%s_no_visible_sky_leak" % stage, float(sky_leak.get("ratio", 1.0)) <= 0.001, JSON.stringify(sky_leak))
	write_progress(stage)

func volume_line_target_for_stage(stage: String, sightline: Dictionary) -> Vector3:
	if stage == "underground_air_reference":
		return last_camera_target
	var stage_record: Dictionary = stage_targets.get(stage, {}) if stage_targets.has(stage) else {}
	if stage_record.has("cell") and stage_record.has("direction"):
		var cell: Vector3i = stage_record.get("cell", sample_cell)
		var direction: Vector3i = stage_record.get("direction", Vector3i.ZERO)
		if direction != Vector3i.ZERO:
			return cell_center(cell + direction)
	return last_camera_target

func position_camera(stage: String, direction: Vector3i) -> void:
	var stage_record: Dictionary = stage_targets.get(stage, {}) if stage_targets.has(stage) else {}
	var stage_cell: Vector3i = stage_record.get("cell", sample_cell) if stage_record.has("cell") else sample_cell
	var stage_position: Vector3 = stage_record.get("position", cell_center(stage_cell)) if stage_record.has("position") else cell_center(stage_cell)
	if stage_record.has("direction"):
		direction = stage_record.get("direction", direction)
	var dir := Vector3(float(direction.x), float(direction.y), float(direction.z))
	if dir.length_squared() <= 0.001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	camera.fov = 16.0
	var eye := stage_position - dir * CELL * 0.38 + Vector3(0.0, CELL * 0.08, 0.0)
	var target_cell := stage_cell + direction
	if stage == "underground_air_reference":
		var wall_record: Dictionary = stage_targets.get("underground_air_reference_wall", stage_record)
		stage_cell = wall_record.get("cell", stage_cell) if wall_record.has("cell") else stage_cell
		stage_position = wall_record.get("position", cell_center(stage_cell)) if wall_record.has("position") else cell_center(stage_cell)
		direction = wall_record.get("direction", direction) if wall_record.has("direction") else direction
		dir = Vector3(float(direction.x), float(direction.y), float(direction.z)).normalized()
		eye = stage_position - dir * CELL * 0.40 - Vector3(0.0, CELL * 0.06, 0.0)
		last_camera_target = stage_position + dir * CELL * 0.18 - Vector3(0.0, CELL * 0.16, 0.0)
		camera.global_position = eye
		var air_up := Vector3.UP
		if absf(dir.dot(Vector3.UP)) > 0.92:
			air_up = Vector3.FORWARD
		camera.look_at(last_camera_target, air_up)
		camera.current = true
		position_capture_lights(eye, last_camera_target, dir)
		return
	if stage == "underground_material_probe":
		eye = stage_position - dir * CELL * 0.44 + Vector3(0.0, CELL * 0.10, 0.0)
	if stage == "underground_collision_probe":
		camera.fov = 12.0
		eye = stage_position - dir * CELL * 0.44 - Vector3(0.0, CELL * 0.02, 0.0)
	var horizontal_bias := Vector3.ZERO
	if absf(dir.y) < 0.20:
		var horizontal_bias_cells := 0.32
		if stage == "underground_collision_probe":
			horizontal_bias_cells = 0.56
		horizontal_bias = -Vector3(0.0, CELL * horizontal_bias_cells, 0.0)
		eye += horizontal_bias * 0.65
	last_camera_target = cell_center(target_cell) + horizontal_bias
	camera.global_position = eye
	var up_vector := Vector3.UP
	if absf(dir.dot(Vector3.UP)) > 0.92:
		up_vector = Vector3.FORWARD
	camera.look_at(last_camera_target, up_vector)
	camera.current = true
	position_capture_lights(eye, last_camera_target, dir)

func position_capture_lights(eye: Vector3, target: Vector3, dir: Vector3) -> void:
	if observer_light != null:
		observer_light.global_position = eye + Vector3(0.0, CELL * 0.20, 0.0)
	if target_light != null:
		target_light.global_position = target - dir.normalized() * CELL * 0.35 + Vector3(0.0, CELL * 0.22, 0.0)

func stage_direction(mode: String) -> Vector3i:
	var stage := stage_name_for_mode(mode)
	if stage_targets.has(stage):
		var record: Dictionary = stage_targets[stage]
		if record.has("direction"):
			return record.get("direction", Vector3i.ZERO)
	if mode == "floor" and boundary_directions.has(Vector3i(0, -1, 0)):
		return Vector3i(0, -1, 0)
	if mode == "ceiling" and boundary_directions.has(Vector3i(0, 1, 0)):
		return Vector3i(0, 1, 0)
	if mode == "air" and air_directions.size() > 0:
		return air_directions[0]
	var horizontal := first_horizontal_boundary()
	if mode in ["wall", "collision"] and horizontal != Vector3i.ZERO:
		return horizontal
	if mode == "material":
		for direction in boundary_directions:
			if direction != Vector3i(0, 1, 0) and direction != Vector3i(0, -1, 0):
				return direction
	return boundary_directions[0] if boundary_directions.size() > 0 else Vector3i(1, 0, 0)

func stage_name_for_mode(mode: String) -> String:
	match mode:
		"air":
			return "underground_air_reference"
		"wall":
			return "underground_wall_boundary"
		"floor":
			return "underground_floor_boundary"
		"ceiling":
			return "underground_ceiling_boundary"
		"material":
			return "underground_material_probe"
		"collision":
			return "underground_collision_probe"
		_:
			return mode

func first_horizontal_boundary() -> Vector3i:
	for direction in boundary_directions:
		if direction.y == 0:
			return direction
	return Vector3i.ZERO

func generated_boundary_summary() -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	var materials := {}
	for direction in cardinal_directions():
		var sample: Dictionary = world_generation.call("sample_cell", sample_cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
			materials[String(sample.get("material", ""))] = true
		else:
			air_neighbors += 1
	var target_boundary_hits := {}
	var required_target_keys := [
		"underground_wall_boundary",
		"underground_floor_boundary",
		"underground_ceiling_boundary"
	]
	for key in required_target_keys:
		var target: Dictionary = stage_targets.get(key, {}) if stage_targets.get(key, {}) is Dictionary else {}
		var cell: Vector3i = target.get("cell", Vector3i.ZERO)
		var direction: Vector3i = target.get("direction", Vector3i.ZERO)
		var target_sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		var target_solid := bool(target_sample.get("solid", false))
		target_boundary_hits[key] = target_solid
		if target_solid:
			materials[String(target_sample.get("material", ""))] = true
	var targets_pass := true
	for key in required_target_keys:
		if not bool(target_boundary_hits.get(key, false)):
			targets_pass = false
	return {
		"passed": targets_pass and stage_targets.has("underground_wall_boundary") and stage_targets.has("underground_floor_boundary") and stage_targets.has("underground_ceiling_boundary"),
		"cell": vec3i(sample_cell),
		"solidNeighbors": solid_neighbors,
		"airNeighbors": air_neighbors,
		"materials": materials.keys(),
		"targetBoundaryHits": target_boundary_hits,
		"stageTargets": stage_targets_summary()
	}

func chunk_geometry_summary() -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk_count := 0
	var mesh_count := 0
	var collision_count := 0
	var volume_faces := 0
	var volume_vertices := 0
	for key in chunks.keys():
		var chunk := chunks[key] as Node
		if chunk == null or not is_instance_valid(chunk):
			continue
		chunk_count += 1
		var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			mesh_count += 1
			volume_faces += int(mesh_instance.mesh.get_meta("chunk_volume_faces", 0))
			volume_vertices += int(mesh_instance.mesh.get_meta("chunk_volume_vertices", 0))
		var body := chunk.get_node_or_null("TerrainBody/TerrainCollision") as CollisionShape3D
		if body != null and body.shape != null:
			collision_count += 1
	return {
		"passed": chunk_count > 0 and mesh_count > 0 and collision_count > 0 and volume_faces > 0,
		"chunkCount": chunk_count,
		"meshCount": mesh_count,
		"collisionCount": collision_count,
		"volumeFaces": volume_faces,
		"volumeVertices": volume_vertices
	}

func volume_line_summary(from: Vector3, to: Vector3) -> Dictionary:
	var steps := 28
	var solid_samples := 0
	var air_samples := 0
	var underground_air_samples := 0
	var materials := {}
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var position := from.lerp(to, t)
		var sample: Dictionary = world_generation.call("sample_world", position)
		if bool(sample.get("solid", false)):
			solid_samples += 1
			materials[String(sample.get("material", ""))] = true
		else:
			air_samples += 1
			if String(sample.get("biome", "")) == "underground_air":
				underground_air_samples += 1
	return {
		"from": vec3(from),
		"to": vec3(to),
		"solidSamples": solid_samples,
		"airSamples": air_samples,
		"undergroundAirSamples": underground_air_samples,
		"materials": materials.keys()
	}

func camera_sightline_summary() -> Dictionary:
	if camera == null:
		return { "hit": false, "reason": "camera_missing" }
	var world := camera.get_world_3d()
	if world == null:
		return { "hit": false, "reason": "world_missing" }
	var space := world.direct_space_state
	var from := camera.global_position
	var to := last_camera_target
	var forward := (to - from).normalized()
	if forward.length_squared() <= 0.001:
		return { "hit": false, "reason": "zero_length_ray" }
	var right := forward.cross(Vector3.UP)
	if right.length_squared() <= 0.001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up := right.cross(forward).normalized()
	var offsets := [
		Vector2.ZERO,
		Vector2(CELL * 0.35, 0.0),
		Vector2(-CELL * 0.35, 0.0),
		Vector2(0.0, CELL * 0.35),
		Vector2(0.0, -CELL * 0.35),
		Vector2(CELL * 0.70, CELL * 0.35),
		Vector2(-CELL * 0.70, -CELL * 0.35)
	]
	var attempts := []
	for offset in offsets:
		var start: Vector3 = from + right * offset.x + up * offset.y
		var end: Vector3 = to + forward * CELL * 4.0 + right * offset.x + up * offset.y
		var query := PhysicsRayQueryParameters3D.create(start, end, 2)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		attempts.append({
			"from": vec3(start),
			"to": vec3(end),
			"hit": not hit.is_empty(),
			"position": vec3(hit.get("position", Vector3.ZERO)) if not hit.is_empty() else {},
			"collider": str(hit.get("collider", "")) if not hit.is_empty() else ""
		})
		if not hit.is_empty():
			return {
				"hit": true,
				"from": vec3(start),
				"to": vec3(end),
				"position": vec3(hit.get("position", Vector3.ZERO)),
				"collider": str(hit.get("collider", "")),
				"attempts": attempts.size()
			}
	return {
		"hit": false,
		"from": vec3(from),
		"to": vec3(to),
		"attempts": attempts
	}

func underground_summary() -> Dictionary:
	var sample: Dictionary = sample_record.get("sample", {}) if sample_record.has("sample") else {}
	return {
		"sampleId": String(sample_record.get("sampleId", "")),
		"cell": vec3i(sample_cell),
		"position": vec3(sample_position),
		"surfaceCell": cell_dict(sample_record.get("surfaceCell", Vector3i.ZERO)),
		"surfaceY": rounded(float(sample_record.get("surfaceY", 0.0))),
		"depthCells": rounded(float(sample_record.get("depthCells", sample.get("depthCells", 0.0)))),
		"sample": sample_signature(sample),
		"boundaryDirections": sanitize_array(boundary_directions),
		"airDirections": sanitize_array(air_directions),
		"stageTargets": stage_targets_summary()
	}

func stage_targets_summary() -> Dictionary:
	var summary := {}
	for key in stage_targets.keys():
		var record: Dictionary = stage_targets[key]
		summary[key] = {
			"cell": vec3i(record.get("cell", Vector3i.ZERO)),
			"direction": vec3i(record.get("direction", Vector3i.ZERO)),
			"mode": String(record.get("mode", "")),
			"boundary": record.get("boundary", {})
		}
	return summary

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": rounded(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"surfaceY": rounded(float(sample.get("surfaceY", 0.0))),
		"depthCells": rounded(float(sample.get("depthCells", 0.0)))
	}

func required_captures_saved() -> bool:
	for stage in REQUIRED_CAPTURE_STAGES:
		if not FileAccess.file_exists(screenshot_dir.path_join("%s.png" % stage)):
			return false
	return true

func capture_names() -> Array:
	var names := []
	for stage in REQUIRED_CAPTURE_STAGES:
		names.append("%s.png" % stage)
	return names

func image_luminance_summary(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var step_x := maxi(1, width / 64)
	var step_y := maxi(1, height / 36)
	var total := 0.0
	var max_luma := 0.0
	var count := 0
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			total += luma
			max_luma = maxf(max_luma, luma)
			count += 1
	return {
		"average": rounded(total / maxf(1.0, float(count))),
		"max": rounded(max_luma),
		"samples": count
	}

func image_sky_leak_summary(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var step_x := maxi(1, width / 96)
	var step_y := maxi(1, height / 54)
	var total := 0
	var sky_like := 0
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var color := image.get_pixel(x, y)
			total += 1
			if color.b > 0.52 and color.g > 0.48 and color.b > color.r + 0.08 and color.g > color.r + 0.035:
				sky_like += 1
	return {
		"skyLikePixels": sky_like,
		"samples": total,
		"ratio": rounded(float(sky_like) / maxf(1.0, float(total)))
	}

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func all_passed() -> bool:
	return failure_count() == 0

func finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	save_report()
	write_progress("finish:%d" % exit_code)
	if is_instance_valid(main) and main.is_inside_tree():
		main.request_graceful_quit(exit_code)
		return
	get_tree().quit(exit_code)

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": TEST_ID,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"finished": true,
		"passed": all_passed(),
		"status": "passed" if all_passed() else "failed",
		"nonHeadlessRequired": true,
		"startupScope": "diagnostic_setup_excluded_from_gameplay",
		"gameplayAcceptance": false,
		"startupLoadingFailureResult": startup_failure_result,
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [ACCEPTANCE_CLAIM],
		"requiredScreenshots": capture_names(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"timeline": timeline,
		"underground": underground_summary(),
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/UndergroundVisualPlaytestRunner.gd"))
	var legacy := "ca" + "ve"
	var banned := ["find_" + legacy + "_biome_sample", legacy + "_feature", legacy + "Value", "VOXEL_" + legacy.to_upper()]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	return {
		"status": "passed" if findings.is_empty() else "failed",
		"findings": findings
	}

func write_progress(stage: String) -> void:
	timeline.append({
		"event": "progress",
		"stage": stage,
		"elapsed": rounded(elapsed)
	})
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%s\n%.3f\n" % [stage, elapsed])
		file.close()

func ensure_dir(path: String) -> void:
	if path != "":
		DirAccess.make_dir_recursive_absolute(path)

func wait_process_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame

func wait_physics_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)

func vector3i_to_vector3(value: Vector3i) -> Vector3:
	return Vector3(float(value.x), float(value.y), float(value.z))

func rounded(value: float) -> float:
	return snappedf(value, 0.001)

func vec3(value: Vector3) -> Dictionary:
	return { "x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z) }

func dict_to_vec3(value: Dictionary, fallback: Vector3) -> Vector3:
	if value.has("x") and value.has("y") and value.has("z"):
		return Vector3(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)), float(value.get("z", fallback.z)))
	return fallback

func vec3i(value: Vector3i) -> Dictionary:
	return { "x": value.x, "y": value.y, "z": value.z }

func vec2i(value: Vector2i) -> Dictionary:
	return { "x": value.x, "z": value.y }

func cell_dict(value) -> Dictionary:
	if value is Vector3i:
		return vec3i(value)
	if value is Vector2i:
		return vec2i(value)
	return {}

func sanitize_array(values: Array) -> Array:
	var output := []
	for value in values:
		if value is Vector3i:
			output.append(vec3i(value))
		elif value is Vector3:
			output.append(vec3(value))
		else:
			output.append(value)
	return output
