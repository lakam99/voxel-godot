extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")

const TEST_ID := "digging_visual_playtest"
const ACCEPTANCE_CLAIM := "digging_reveals_generated_subsurface_material_and_drops_item"
const CELL := 1.35
const MELEE_RANGE := CELL * 2.65
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
	"digging_before_surface",
	"digging_after_first_dig",
	"digging_after_second_dig",
	"digging_material_drop_inventory"
]
const SOIL_MATERIALS := ["grass", "dirt", "sand", "mud", "snow", "dirtBlock"]
const SOLID_MATERIALS := ["grass", "dirt", "sand", "mud", "snow", "stone", "deepStone", "copperOre", "ironOre"]
const DIG_VISUAL_PATCH_RADIUS := 4
const DIG_VISUAL_MIN_DRY_HEIGHT := 4.0

var main: Node3D
var player: CharacterBody3D
var gameplay_camera: Camera3D
var observer_camera: Camera3D
var observer_light: OmniLight3D
var world_generation
var inventory_system
var held_item
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var preferred_material := ""
var watchdog_seconds := 120.0
var live_process := false
var elapsed := 0.0
var finished := false
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var dig_outcomes: Array[Dictionary] = []
var test_column := Vector2i.ZERO
var top_cell := Vector3i.ZERO
var surface_position := Vector3.ZERO
var planned_materials: Array[Dictionary] = []
var dig_focus_points: Array[Vector3] = []
var last_camera_target := Vector3.ZERO
var surface_collision_position := Vector3.ZERO
var surface_collision_normal := Vector3.UP
var has_surface_collision := false

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
		add_result("digging_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_DIGGING_VISUAL_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/digging-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_DIGGING_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_DIGGING_VISUAL_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/underground/screenshots/digging-visual")
	run_token = OS.get_environment("VOXEL_DIGGING_VISUAL_RUN_TOKEN")
	preferred_material = OS.get_environment("VOXEL_DIGGING_VISUAL_PREFERRED_MATERIAL").strip_edges()
	var watchdog_value := OS.get_environment("VOXEL_DIGGING_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_value != "":
		watchdog_seconds = maxf(45.0, float(watchdog_value))
	live_process = OS.get_environment("VOXEL_DIGGING_VISUAL_LIVE_PROCESS").strip_edges() == "1"
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
	OS.set_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("visual_quality", {
		"decorativeDensity": 0.02,
		"decorativeDetailCap": 3,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	add_child(main)
	write_progress("main_instantiated")
	if not live_process:
		main.set_process(false)
		main.set_physics_process(false)
	await wait_process_frames(2)
	bind_scene_nodes()
	if main == null or player == null or gameplay_camera == null or world_generation == null or inventory_system == null:
		add_result("digging_visual_scene_ready", false, "main/player/camera/world_generation/inventory missing")
		finish(1)
		return
	configure_scene()
	if not select_dig_column():
		add_result("digging_visual_column_selected", false, "no deterministic solid column with generated material beneath was found")
		finish(1)
		return
	load_test_chunks()
	setup_inventory()
	position_player_for_depth(0)
	await wait_for_surface_collision(420)
	await flush_terrain_work_after_dig()

	add_result("digging_visual_scene_ready", true, "main scene ready with real player camera and terrain collision")
	add_result("digging_visual_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
	add_result("digging_visual_column_selected", true, JSON.stringify(column_summary()))
	add_result("digging_visual_surface_collision_calibrated", has_surface_collision, JSON.stringify(surface_collision_summary()))
	add_result("digging_visual_planned_cells_solid", planned_materials.size() >= 4, JSON.stringify(planned_materials))
	await capture_stage("digging_before_surface", "before digging", {})

	for dig_index in range(2):
		var outcome: Dictionary = await perform_dig(dig_index)
		dig_outcomes.append(outcome)
		await flush_terrain_work_after_dig()
		var vertical_probe := vertical_excavation_probe(outcome)
		outcome["verticalProbe"] = vertical_probe
		if bool(vertical_probe.get("passed", false)):
			var hit_value = vertical_probe.get("hit", {})
			if hit_value is Dictionary:
				dig_focus_points.append(dict_to_vec3(hit_value, target_point_for_depth(dig_index + 1)))
		position_player_for_depth(dig_index + 1)
		await wait_process_frames(5)
		await wait_physics_frames(2)
		var post_target := revealed_material_target_info(outcome)
		outcome["postTarget"] = post_target
		var smooth_profile := smooth_surface_profile_probe(outcome, post_target, vertical_probe)
		outcome["smoothSurfaceProfile"] = smooth_profile
		add_result(
			"digging_visual_dig_%d_drop_added" % [dig_index + 1],
			bool(outcome.get("dropAdded", false)),
			JSON.stringify(outcome)
		)
		add_result(
			"digging_visual_dig_%d_immediate_transaction_bounded" % [dig_index + 1],
			float(outcome.get("destroyTargetFinalMs", INF)) < 2.0,
			"finalDestroyMs=%.3f maxStrikeMs=%.3f" % [float(outcome.get("destroyTargetFinalMs", INF)), float(outcome.get("destroyTargetMaxMs", INF))]
		)
		add_result(
			"digging_visual_dig_%d_all_strikes_bounded" % [dig_index + 1],
			float(outcome.get("destroyTargetMaxMs", INF)) < 3.0,
			"maxStrikeMs=%.3f" % float(outcome.get("destroyTargetMaxMs", INF))
		)
		add_result(
			"digging_visual_dig_%d_opens_surface_cap" % [dig_index + 1],
			bool(vertical_probe.get("passed", false)),
			JSON.stringify(vertical_probe)
		)
		add_result(
			"digging_visual_dig_%d_reveals_generated_material" % [dig_index + 1],
			bool(post_target.get("hit", false)) and String(post_target.get("material", "air")) != "air",
			JSON.stringify(post_target)
		)
		add_result(
			"digging_visual_dig_%d_smooth_concave_surface" % [dig_index + 1],
			bool(smooth_profile.get("passed", false)),
			JSON.stringify(smooth_profile)
		)
		await capture_stage(REQUIRED_CAPTURE_STAGES[dig_index + 1], "after dig %d" % [dig_index + 1], outcome)

	add_result("digging_visual_expected_drops_recorded", expected_drops_recorded(), JSON.stringify(dig_outcomes))
	add_result("digging_visual_subsurface_material_drop_recorded", subsurface_material_drop_recorded(), JSON.stringify(dig_outcomes))
	await capture_stage("digging_material_drop_inventory", "material drops recorded", { "digOutcomes": dig_outcomes, "inventory": inventory_totals() })
	add_result("digging_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
	finish(1 if failure_count() > 0 else 0)

func flush_terrain_work_after_dig() -> void:
	if main == null:
		return
	for _i in range(90):
		if main.has_method("process_world_edit_followups"):
			main.call("process_world_edit_followups")
		if main.has_method("update_chunks"):
			main.call("update_chunks", false)
		await wait_process_frames(1)
		if terrain_flush_looks_idle():
			break

func wait_for_surface_collision(max_frames: int) -> bool:
	for _i in range(maxi(1, max_frames)):
		calibrate_surface_collision()
		if has_surface_collision:
			return true
		await wait_process_frames(1)
		await wait_physics_frames(1)
	return false

func terrain_flush_looks_idle() -> bool:
	if main != null and main.has_method("world_edit_followup_stats"):
		var edit_stats: Dictionary = main.call("world_edit_followup_stats")
		if int(edit_stats.get("pendingEdits", 0)) > 0 or bool(edit_stats.get("structurePending", false)):
			return false
	var runtime := main.get_node_or_null("VoxelTerrainRuntime") if main != null else null
	if runtime != null and runtime.has_method("stats"):
		var runtime_stats: Dictionary = runtime.call("stats")
		if int(runtime_stats.get("pendingEditSections", 0)) > 0:
			return false
	var terrain_refreshes = main.get("pending_chunk_terrain_refreshes") if main != null else null
	if terrain_refreshes is Dictionary and not (terrain_refreshes as Dictionary).is_empty():
		return false
	var collision_refreshes = main.get("pending_chunk_collision_refreshes") if main != null else null
	if collision_refreshes is Dictionary and not (collision_refreshes as Dictionary).is_empty():
		return false
	var meshing_service = main.get("terrain_meshing_service") if main != null else null
	if meshing_service != null:
		if meshing_service.has_method("pending_job_count") and int(meshing_service.call("pending_job_count")) > 0:
			return false
		if meshing_service.has_method("completed_job_count") and int(meshing_service.call("completed_job_count")) > 0:
			return false
	var world_gen = main.get("world_generation_system") if main != null else null
	if world_gen != null and world_gen.has_method("pending_sky_light_column_count"):
		if int(world_gen.call("pending_sky_light_column_count")) > 0:
			return false
	return true

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D
	if player != null:
		gameplay_camera = player.get("camera") as Camera3D
	world_generation = main.get("world_generation_system") if main != null else null
	inventory_system = main.get("inventory_system") if main != null else null
	held_item = main.get("held_item") if main != null else null

func configure_scene() -> void:
	neutralize_intro_clock_freeze()
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
	main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
	var weather_system = main.get("weather_system")
	if weather_system != null and weather_system.has_method("force_weather"):
		weather_system.force_weather("clear", 0.0, 0.12, Vector3.ZERO)
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	if player != null:
		player.set_process(false)
		player.set_physics_process(false)
	if gameplay_camera != null:
		gameplay_camera.current = true
	observer_camera = Camera3D.new()
	observer_camera.name = "DiggingVisualObserverCamera"
	observer_camera.fov = 68.0
	add_child(observer_camera)
	observer_light = OmniLight3D.new()
	observer_light.name = "DiggingVisualObserverLight"
	observer_light.light_energy = 7.5
	observer_light.omni_range = CELL * 12.0
	observer_light.light_cull_mask = 0xFFFFFFFF
	add_child(observer_light)

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

func select_dig_column() -> bool:
	var candidates := candidate_columns()
	for column in candidates:
		if column_in_town(column):
			continue
		var surface := top_solid_for_column(column)
		if surface.is_empty():
			continue
		var cell: Vector3i = surface.get("cell", Vector3i.ZERO)
		var material := String(surface.get("material", ""))
		if material == "" or material == "air":
			continue
		if cell_center(cell).y <= water_level() + DIG_VISUAL_MIN_DRY_HEIGHT:
			continue
		var surface_sample: Dictionary = surface.get("sample", {}) if surface.get("sample", {}) is Dictionary else {}
		var top_biome := String(surface_sample.get("biome", ""))
		if top_biome in ["ocean", "beach", "underground", "underground_air"]:
			continue
		if preferred_material != "" and material != preferred_material:
			continue
		if preferred_material != "" and not column_material_patch_matches(cell, preferred_material):
			continue
		var planned := planned_solid_cells(cell, 6)
		if planned.size() < 4:
			continue
		if not planned_sequence_has_subsurface_transition(planned):
			continue
		if not column_has_stable_surface_patch(cell):
			continue
		var usable := true
		for entry in planned.slice(0, 4):
			var planned_material := String(entry.get("material", ""))
			if not SOLID_MATERIALS.has(planned_material) and ItemCatalogScript.material_drop(planned_material) == planned_material:
				usable = false
				break
		if not usable:
			continue
		test_column = column
		top_cell = cell
		surface_position = cell_center(top_cell + Vector3i(0, 1, 0))
		planned_materials = planned
		return true
	return false

func column_has_stable_surface_patch(center_cell: Vector3i) -> bool:
	var center_y := cell_center(center_cell).y
	if center_y <= water_level() + DIG_VISUAL_MIN_DRY_HEIGHT:
		return false
	for dz in range(-DIG_VISUAL_PATCH_RADIUS, DIG_VISUAL_PATCH_RADIUS + 1):
		for dx in range(-DIG_VISUAL_PATCH_RADIUS, DIG_VISUAL_PATCH_RADIUS + 1):
			var surface := top_solid_for_column(Vector2i(center_cell.x + dx, center_cell.z + dz))
			if surface.is_empty():
				return false
			var neighbor_cell: Vector3i = surface.get("cell", Vector3i.ZERO)
			if absi(neighbor_cell.y - center_cell.y) > 1:
				return false
			var material := String(surface.get("material", ""))
			if material == "" or material == "air":
				return false
			var sample: Dictionary = surface.get("sample", {}) if surface.get("sample", {}) is Dictionary else {}
			var biome := String(sample.get("biome", ""))
			if biome in ["ocean", "beach", "underground", "underground_air"]:
				return false
	return true

func candidate_columns() -> Array[Vector2i]:
	var columns: Array[Vector2i] = []
	var anchors := [
		Vector2i(34, 28),
		Vector2i(42, -22),
		Vector2i(-36, 30),
		Vector2i(-44, -28),
		Vector2i(55, 16),
		Vector2i(18, 52)
	]
	for anchor in anchors:
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				columns.append(anchor + Vector2i(dx * 2, dz * 2))
	for z in range(-120, 121, 4):
		for x in range(-120, 121, 4):
			var cell := Vector2i(x, z)
			if not columns.has(cell):
				columns.append(cell)
	return columns

func column_material_patch_matches(center_cell: Vector3i, material_id: String) -> bool:
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var surface := top_solid_for_column(Vector2i(center_cell.x + dx, center_cell.z + dz))
			if surface.is_empty():
				return false
			if String(surface.get("material", "")) != material_id:
				return false
	return true

func planned_sequence_has_subsurface_transition(planned: Array[Dictionary]) -> bool:
	if planned.size() < 2:
		return false
	var top_material := String(planned[0].get("material", ""))
	for index in range(1, planned.size()):
		var material_id := String(planned[index].get("material", ""))
		if material_id != "" and material_id != "air" and material_id != top_material:
			return true
	return false

func column_in_town(column: Vector2i) -> bool:
	if main == null or not main.has_method("town_region_at_cell"):
		return false
	var region: Dictionary = main.call("town_region_at_cell", column.x, column.y)
	return not region.is_empty()

func top_solid_for_column(column: Vector2i) -> Dictionary:
	for y in range(96, -40, -1):
		var cell := Vector3i(column.x, y, column.y)
		var sample: Dictionary = world_generation.call("sample_cell", cell)
		if not bool(sample.get("solid", false)):
			continue
		var above: Dictionary = world_generation.call("sample_cell", cell + Vector3i(0, 1, 0))
		if bool(above.get("solid", false)):
			continue
		return {
			"cell": cell,
			"material": String(sample.get("material", "")),
			"sample": sample_signature(sample),
			"above": sample_signature(above)
		}
	return {}

func planned_solid_cells(start_cell: Vector3i, count: int) -> Array[Dictionary]:
	var planned: Array[Dictionary] = []
	for offset in range(count):
		var cell := start_cell + Vector3i(0, -offset, 0)
		var sample: Dictionary = world_generation.call("sample_cell", cell)
		if not bool(sample.get("solid", false)):
			break
		planned.append({
			"offset": offset,
			"cell": vec3i(cell),
			"material": String(sample.get("material", "")),
			"drop": ItemCatalogScript.material_drop(String(sample.get("material", ""))),
			"biome": String(sample.get("biome", "")),
			"depthCells": rounded(float(sample.get("depthCells", 0.0))),
			"density": rounded(float(sample.get("density", 0.0)))
		})
	return planned

func load_test_chunks() -> void:
	clear_loaded_chunks()
	var center_key: Vector2i = main.call("cell_to_chunk", top_cell.x, top_cell.z)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			load_chunk_key(Vector2i(center_key.x + dx, center_key.y + dz))

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

func setup_inventory() -> void:
	if inventory_system == null:
		return
	inventory_system.clear()
	inventory_system.add_item("ironPickaxe", 1)
	inventory_system.add_item("stoneShovel", 1)
	inventory_system.select(0)
	if held_item != null and held_item.has_method("refresh_active"):
		held_item.refresh_active()
	if main.has_method("update_hud"):
		main.call("update_hud", "Digging visual playtest: pickaxe")

func calibrate_surface_collision() -> void:
	has_surface_collision = false
	surface_collision_position = surface_position
	surface_collision_normal = Vector3.UP
	var world := player.get_world_3d() if player != null else null
	if world == null:
		return
	var offsets: Array[Vector3] = [Vector3.ZERO]
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			if dx == 0 and dz == 0:
				continue
			offsets.append(Vector3(float(dx) * CELL * 0.28, 0.0, float(dz) * CELL * 0.28))
	var best_hit := {}
	var best_y := -INF
	for offset in offsets:
		var ray_from: Vector3 = surface_position + offset + Vector3(0.0, CELL * 6.0, 0.0)
		var ray_to: Vector3 = surface_position + offset - Vector3(0.0, CELL * 6.0, 0.0)
		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.exclude = [player] if player != null else []
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit := world.direct_space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider := hit.get("collider") as Node
		var kind := String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else ""
		if kind != "terrain" and kind != "subsurface":
			continue
		var hit_position: Vector3 = hit.get("position", surface_position)
		if hit_position.y > best_y:
			best_y = hit_position.y
			best_hit = hit
	if best_hit.is_empty():
		return
	surface_collision_position = best_hit.get("position", surface_position)
	surface_collision_normal = best_hit.get("normal", Vector3.UP)
	if surface_collision_normal.length_squared() < 0.001:
		surface_collision_normal = Vector3.UP
	else:
		surface_collision_normal = surface_collision_normal.normalized()
	has_surface_collision = true

func perform_dig(dig_index: int) -> Dictionary:
	position_player_for_depth(dig_index)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	var first_target := current_target_info()
	var first_solid_target := first_target.duplicate(true) if bool(first_target.get("hit", false)) else {}
	var material_id := String(first_target.get("material", planned_material_for_depth(dig_index)))
	if material_id == "" or material_id == "air":
		return {
			"digIndex": dig_index,
			"dropAdded": false,
			"reason": "no solid target before dig",
			"targetBefore": first_target
		}
	if preferred_material != "" and dig_index == 0 and material_id != preferred_material:
		return {
			"digIndex": dig_index,
			"dropAdded": false,
			"reason": "preferred material target mismatch",
			"preferredMaterial": preferred_material,
			"actualMaterial": material_id,
			"targetBefore": first_target
		}
	select_tool_for_material(material_id)
	var drop_id := ItemCatalogScript.material_drop(material_id)
	var before_count := inventory_count(drop_id)
	var attempts := 0
	var target_snapshots: Array[Dictionary] = []
	var destroy_timings_ms: Array[float] = []
	var max_destroy_ms := 0.0
	var final_destroy_ms := 0.0
	var final_performance_summary := {}
	for attempt in range(36):
		attempts += 1
		position_player_for_depth(dig_index)
		await wait_process_frames(1)
		var target := current_target_info()
		if target_snapshots.size() < 5:
			target_snapshots.append(target)
		if not bool(target.get("hit", false)):
			await wait_process_frames(1)
			continue
		if first_solid_target.is_empty():
			first_solid_target = target.duplicate(true)
		var target_material := String(target.get("material", material_id))
		if target_material != "" and target_material != "air" and target_material != material_id:
			material_id = target_material
			drop_id = ItemCatalogScript.material_drop(material_id)
			before_count = inventory_count(drop_id)
			select_tool_for_material(material_id)
		var destroy_start_usec := Time.get_ticks_usec()
		main.call("destroy_target")
		var destroy_ms := float(Time.get_ticks_usec() - destroy_start_usec) / 1000.0
		destroy_timings_ms.append(destroy_ms)
		max_destroy_ms = maxf(max_destroy_ms, destroy_ms)
		final_destroy_ms = destroy_ms
		final_performance_summary = performance_summary()
		await drain_world_edit_followups(180)
		await wait_process_frames(3)
		await wait_physics_frames(1)
		var after_count := inventory_count(drop_id)
		if after_count > before_count:
			await wait_process_frames(5)
			await wait_physics_frames(2)
			return {
				"digIndex": dig_index,
				"dropAdded": true,
				"attempts": attempts,
				"material": material_id,
				"drop": drop_id,
				"countBefore": before_count,
				"countAfter": after_count,
				"destroyTargetMaxMs": max_destroy_ms,
				"destroyTargetFinalMs": final_destroy_ms,
				"destroyTargetTimingsMs": destroy_timings_ms,
				"performanceAfterDestroy": final_performance_summary,
				"targetBefore": first_solid_target if not first_solid_target.is_empty() else first_target,
				"targetSnapshots": target_snapshots,
				"inventoryAfter": inventory_totals()
			}
	return {
		"digIndex": dig_index,
		"dropAdded": false,
		"attempts": attempts,
		"material": material_id,
		"drop": drop_id,
		"countBefore": before_count,
		"countAfter": inventory_count(drop_id),
		"destroyTargetMaxMs": max_destroy_ms,
		"destroyTargetFinalMs": final_destroy_ms,
		"destroyTargetTimingsMs": destroy_timings_ms,
		"performanceAfterDestroy": final_performance_summary,
		"targetBefore": first_solid_target if not first_solid_target.is_empty() else first_target,
		"targetSnapshots": target_snapshots,
		"inventoryAfter": inventory_totals()
	}

func drain_world_edit_followups(max_frames: int) -> void:
	if main == null or live_process:
		return
	for _i in range(maxi(1, max_frames)):
		if main.has_method("process_world_edit_followups"):
			main.call("process_world_edit_followups")
		var stats: Dictionary = main.call("world_edit_followup_stats") if main.has_method("world_edit_followup_stats") else {}
		if int(stats.get("pendingEdits", 0)) <= 0 and not bool(stats.get("structurePending", false)):
			return
		await wait_process_frames(1)

func select_tool_for_material(material_id: String) -> void:
	if inventory_system == null:
		return
	inventory_system.select(0)
	if held_item != null and held_item.has_method("refresh_active"):
		held_item.refresh_active()

func performance_summary() -> Dictionary:
	if main == null:
		return {}
	var monitor = main.get("runtime_perf_monitor")
	if monitor == null or not monitor.has_method("summary"):
		return {}
	var summary: Dictionary = monitor.call("summary")
	return {
		"frameMs": float(summary.get("frameMs", 0.0)),
		"frameMaxMs": float(summary.get("frameMaxMs", 0.0)),
		"lastSpikeFrameMs": float(summary.get("lastSpikeFrameMs", 0.0)),
		"lastSpikeReason": String(summary.get("lastSpikeReason", "")),
		"lastSpikeTopSections": summary.get("lastSpikeTopSections", []),
		"sections": summary.get("sections", {}),
		"sectionMaxMs": summary.get("sectionMaxMs", {}),
		"counters": summary.get("counters", {})
	}

func current_target_info() -> Dictionary:
	if player == null:
		return { "hit": false, "reason": "player_missing" }
	var hit: Dictionary = player.call("view_ray", MELEE_RANGE)
	if hit.is_empty():
		return {
			"hit": false,
			"reason": "ray_missed",
			"camera": vec3(gameplay_camera.global_position if gameplay_camera != null else Vector3.ZERO),
			"target": vec3(last_camera_target)
		}
	var collider := hit.get("collider") as Node
	var kind := String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else ""
	var target := {}
	if collider != null and kind != "" and main.has_method("break_target_for_hit"):
		target = main.call("break_target_for_hit", hit, collider, kind)
	var material_id := String(target.get("material", ""))
	var cell_value = target.get("cell3", Vector3i.ZERO)
	return {
		"hit": true,
		"kind": kind,
		"material": material_id,
		"drop": ItemCatalogScript.material_drop(material_id) if material_id != "" else "",
		"cell": vec3i(cell_value) if cell_value is Vector3i else {},
		"position": vec3(hit.get("position", Vector3.ZERO)),
		"normal": vec3(hit.get("normal", Vector3.UP)),
		"collider": str(collider),
		"camera": vec3(gameplay_camera.global_position if gameplay_camera != null else Vector3.ZERO),
		"target": vec3(last_camera_target)
	}

func revealed_material_target_info(outcome: Dictionary) -> Dictionary:
	var primary := current_target_info()
	if target_info_has_solid_material(primary):
		return primary
	if gameplay_camera == null:
		return primary
	var original_target := last_camera_target
	var anchor := target_anchor_for_outcome(outcome)
	var position_value = anchor.get("position", {})
	var focus := target_point_for_depth(int(outcome.get("digIndex", 0)))
	if position_value is Dictionary:
		focus = dict_to_vec3(position_value, focus)
	var vertical_probe: Dictionary = outcome.get("verticalProbe", {}) if outcome.get("verticalProbe", {}) is Dictionary else {}
	var probe_hit = vertical_probe.get("hit", {})
	if probe_hit is Dictionary:
		focus = dict_to_vec3(probe_hit, focus)
	var probe_offsets: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(0.0, CELL * 0.35, 0.0),
		Vector3(0.0, -CELL * 0.10, 0.0),
		Vector3(CELL * 0.70, 0.0, 0.0),
		Vector3(-CELL * 0.70, 0.0, 0.0),
		Vector3(0.0, 0.0, CELL * 0.70),
		Vector3(0.0, 0.0, -CELL * 0.70),
		Vector3(CELL * 0.55, -CELL * 0.15, CELL * 0.55),
		Vector3(-CELL * 0.55, -CELL * 0.15, CELL * 0.55),
		Vector3(CELL * 0.55, -CELL * 0.15, -CELL * 0.55),
		Vector3(-CELL * 0.55, -CELL * 0.15, -CELL * 0.55)
	]
	for offset in probe_offsets:
		last_camera_target = focus + offset
		gameplay_camera.look_at(last_camera_target, Vector3.UP)
		var candidate := current_target_info()
		candidate["revealedProbeOffset"] = vec3(offset)
		if target_info_has_solid_material(candidate):
			return candidate
	last_camera_target = original_target
	gameplay_camera.look_at(last_camera_target, Vector3.UP)
	primary["revealedProbeTried"] = probe_offsets.size()
	return primary

func target_info_has_solid_material(target_info: Dictionary) -> bool:
	if not bool(target_info.get("hit", false)):
		return false
	var material_id := String(target_info.get("material", "air"))
	return material_id != "" and material_id != "air"

func position_player_for_depth(depth_index: int) -> void:
	if player == null or gameplay_camera == null:
		return
	if depth_index > 0 and dig_focus_points.size() >= depth_index:
		position_player_for_excavated_focus(dig_focus_points[depth_index - 1])
		return
	var target := target_point_for_depth(depth_index)
	var surface_target := target_point_for_depth(0)
	if depth_index == 0 and has_surface_collision:
		target = surface_collision_position
		surface_target = surface_collision_position
	var eye_offset := Vector3(CELL * 0.28, CELL * 2.05, CELL * 0.28) if preferred_material != "" else Vector3(CELL * 0.86, CELL * 1.45, CELL * 0.86)
	player.global_position = surface_target + eye_offset - Vector3(0.0, 1.65, 0.0)
	player.velocity = Vector3.ZERO
	gameplay_camera.rotation = Vector3.ZERO
	gameplay_camera.global_position = surface_target + eye_offset
	last_camera_target = target
	gameplay_camera.look_at(last_camera_target, Vector3.UP)
	gameplay_camera.current = true

func position_player_for_excavated_focus(focus: Vector3) -> void:
	var eye_offset := Vector3(CELL * 0.10, CELL * 1.85, CELL * 0.10)
	player.global_position = focus + eye_offset - Vector3(0.0, 1.65, 0.0)
	player.velocity = Vector3.ZERO
	gameplay_camera.rotation = Vector3.ZERO
	gameplay_camera.global_position = focus + eye_offset
	last_camera_target = focus - Vector3(0.0, CELL * 0.55, 0.0)
	gameplay_camera.look_at(last_camera_target, Vector3.UP)
	gameplay_camera.current = true

func position_observer_camera(stage: String) -> void:
	if observer_camera == null:
		return
	var surface_focus := surface_collision_position if has_surface_collision else surface_position
	if surface_focus == Vector3.ZERO:
		surface_focus = target_point_for_depth(0)
	var depth_index := 0
	if stage == "digging_after_first_dig":
		depth_index = 1
	elif stage == "digging_after_second_dig" or stage == "digging_material_drop_inventory":
		depth_index = 2
	var view_target := surface_focus - Vector3(0.0, CELL * (0.22 + float(depth_index) * 0.50), 0.0)
	observer_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	observer_camera.fov = 46.0
	observer_camera.global_position = surface_focus + Vector3(CELL * 3.0, CELL * 7.0, CELL * 3.0)
	observer_camera.look_at(view_target, Vector3.UP)
	observer_camera.current = true
	if observer_light != null:
		observer_light.global_position = surface_focus + Vector3(CELL * 0.25, CELL * 4.8, CELL * 0.25)

func focus_position_for_stage(stage: String) -> Vector3:
	var outcome_index := -1
	if stage == "digging_after_first_dig":
		outcome_index = 0
	elif stage == "digging_after_second_dig" or stage == "digging_material_drop_inventory":
		outcome_index = 1
	if outcome_index >= 0 and outcome_index < dig_outcomes.size():
		var outcome: Dictionary = dig_outcomes[outcome_index]
		var anchor := target_anchor_for_outcome(outcome)
		var position_value = anchor.get("position", {})
		if position_value is Dictionary:
			return dict_to_vec3(position_value, target_point_for_depth(outcome_index))
	var target := current_target_info()
	var target_position = target.get("position", {})
	if target_position is Dictionary:
		return dict_to_vec3(target_position, target_point_for_depth(0))
	return target_point_for_depth(0)

func target_point_for_depth(depth_index: int) -> Vector3:
	var y_cell := top_cell.y - depth_index
	return cell_center(Vector3i(top_cell.x, y_cell, top_cell.z))

func planned_material_for_depth(depth_index: int) -> String:
	if depth_index >= 0 and depth_index < planned_materials.size():
		return String(planned_materials[depth_index].get("material", ""))
	return ""

func capture_stage(stage: String, label: String, outcome: Dictionary) -> void:
	position_observer_camera(stage)
	hide_hud_for_capture()
	hide_non_terrain_visuals_for_capture()
	hide_objective_toast()
	hide_held_item_for_capture()
	await wait_process_frames(2)
	await wait_physics_frames(1)
	hide_hud_for_capture()
	hide_non_terrain_visuals_for_capture()
	hide_objective_toast()
	hide_held_item_for_capture()
	await wait_process_frames(2)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var target := current_target_info()
	var sky_summary := image_sky_pixel_summary(image)
	var capture := {
		"stage": stage,
		"label": label,
		"elapsed": rounded(elapsed),
		"path": path,
		"saved": err == OK,
		"camera": vec3(active_capture_camera_position()),
		"cameraRole": "observer",
		"target": target,
		"inventory": inventory_totals(),
		"digOutcome": outcome,
		"column": column_summary(),
		"luminance": image_luminance_summary(image),
		"skyLeak": sky_summary
	}
	captures.append(capture)
	timeline.append({
		"event": "capture",
		"stage": stage,
		"elapsed": rounded(elapsed),
		"saved": err == OK,
		"path": path,
		"target": target
	})
	add_result("capture_%s_saved" % stage, err == OK and FileAccess.file_exists(path), path)
	add_result("capture_%s_no_visible_sky" % stage, bool(sky_summary.get("passed", false)), JSON.stringify(sky_summary))
	write_progress(stage)

func hide_held_item_for_capture() -> void:
	if held_item is Node3D:
		(held_item as Node3D).visible = false
	elif held_item is CanvasItem:
		(held_item as CanvasItem).visible = false

func hide_hud_for_capture() -> void:
	var hud = main.get("hud") if main != null else null
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	elif hud is Node:
		var hud_root = hud.get("hud_root")
		if hud_root is CanvasItem:
			(hud_root as CanvasItem).visible = false

func hide_non_terrain_visuals_for_capture() -> void:
	if main == null:
		return
	var chunk_root = main.get("chunk_root")
	if chunk_root is Node:
		for chunk_value in (chunk_root as Node).get_children():
			var chunk := chunk_value as Node
			if chunk == null:
				continue
			for child_value in chunk.get_children():
				var child := child_value as Node
				if child == null or child.name in ["TerrainMesh", "TerrainFluidMesh", "TerrainBody"]:
					continue
				if child is Node3D:
					(child as Node3D).visible = false
	var prop_root = main.get("prop_root")
	if prop_root is Node3D:
		(prop_root as Node3D).visible = false

func hide_objective_toast() -> void:
	var hud = main.get("hud") if main != null else null
	if hud == null:
		return
	var objective_toast = hud.get("objective_toast")
	if objective_toast is CanvasItem:
		(objective_toast as CanvasItem).visible = false
		(objective_toast as CanvasItem).modulate.a = 0.0
	var objective_panel = hud.get("objective_panel")
	if objective_panel is CanvasItem:
		(objective_panel as CanvasItem).visible = false

func expected_drops_recorded() -> bool:
	for outcome in dig_outcomes:
		if not bool(outcome.get("dropAdded", false)):
			return false
		var drop_id := String(outcome.get("drop", ""))
		if drop_id == "" or int(outcome.get("countAfter", 0)) <= int(outcome.get("countBefore", 0)):
			return false
	return dig_outcomes.size() >= 2

func subsurface_material_drop_recorded() -> bool:
	if planned_materials.is_empty():
		return false
	var top_material := String(planned_materials[0].get("material", ""))
	for outcome in dig_outcomes:
		if not bool(outcome.get("dropAdded", false)):
			continue
		var material_id := String(outcome.get("material", ""))
		if material_id != "" and material_id != "air" and material_id != top_material:
			return true
	return false

func active_capture_camera_position() -> Vector3:
	if observer_camera != null and observer_camera.current:
		return observer_camera.global_position
	return gameplay_camera.global_position if gameplay_camera != null else Vector3.ZERO

func vertical_excavation_probe(outcome: Dictionary) -> Dictionary:
	var anchor := target_anchor_for_outcome(outcome)
	var position_value = anchor.get("position", {})
	if not (position_value is Dictionary):
		return { "passed": false, "reason": "missing_target_position" }
	var focus := dict_to_vec3(position_value, target_point_for_depth(int(outcome.get("digIndex", 0))))
	var from := focus + Vector3(0.0, CELL * 4.0, 0.0)
	var to := focus - Vector3(0.0, CELL * 5.0, 0.0)
	var world := player.get_world_3d() if player != null else null
	if world == null:
		return { "passed": false, "reason": "world_missing" }
	var query := PhysicsRayQueryParameters3D.create(from, to, 2)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {
			"passed": false,
			"reason": "vertical_probe_missed",
			"from": vec3(from),
			"to": vec3(to),
			"surfaceYBefore": rounded(focus.y)
		}
	var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
	return {
		"passed": hit_position.y < focus.y - CELL * 0.25,
		"from": vec3(from),
		"to": vec3(to),
		"hit": vec3(hit_position),
		"surfaceYBefore": rounded(focus.y),
		"dropY": rounded(focus.y - hit_position.y),
		"collider": str(hit.get("collider", ""))
	}

func smooth_surface_profile_probe(outcome: Dictionary, post_target: Dictionary, vertical_probe: Dictionary) -> Dictionary:
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return { "passed": false, "reason": "world_generation_surface_y_missing" }
	var anchor := target_anchor_for_outcome(outcome)
	var position_value = anchor.get("position", {})
	if not (position_value is Dictionary):
		return { "passed": false, "reason": "missing_target_position" }
	var focus := dict_to_vec3(position_value, target_point_for_depth(int(outcome.get("digIndex", 0))))
	var center_y := float(world_generation.call("surface_y_at", focus))
	var ring_radius := CELL * 2.35
	var offsets: Array[Vector3] = [
		Vector3(ring_radius, 0.0, 0.0),
		Vector3(-ring_radius, 0.0, 0.0),
		Vector3(0.0, 0.0, ring_radius),
		Vector3(0.0, 0.0, -ring_radius),
		Vector3(ring_radius * 0.707, 0.0, ring_radius * 0.707),
		Vector3(-ring_radius * 0.707, 0.0, ring_radius * 0.707),
		Vector3(ring_radius * 0.707, 0.0, -ring_radius * 0.707),
		Vector3(-ring_radius * 0.707, 0.0, -ring_radius * 0.707)
	]
	var ring_values: Array[float] = []
	var ring_sum := 0.0
	var ring_min := INF
	var ring_max := -INF
	for offset in offsets:
		var sample_position := focus + offset
		var sample_y := float(world_generation.call("surface_y_at", sample_position))
		ring_values.append(rounded(sample_y))
		ring_sum += sample_y
		ring_min = minf(ring_min, sample_y)
		ring_max = maxf(ring_max, sample_y)
	var ring_average := ring_sum / maxf(1.0, float(offsets.size()))
	var normal_value = post_target.get("normal", {})
	var normal := Vector3.UP
	if normal_value is Dictionary:
		normal = dict_to_vec3(normal_value, Vector3.UP)
	var drop_y := float(vertical_probe.get("dropY", 0.0))
	var rim_delta := ring_average - center_y
	var upward_surface_hit := normal.y >= 0.55
	var strong_concavity := drop_y >= CELL * 0.75 and rim_delta >= CELL * 0.35
	var passed := drop_y >= CELL * 0.25 and rim_delta >= CELL * 0.14 and (upward_surface_hit or strong_concavity)
	return {
		"passed": passed,
		"centerY": rounded(center_y),
		"ringAverageY": rounded(ring_average),
		"ringMinY": rounded(ring_min),
		"ringMaxY": rounded(ring_max),
		"ringValuesY": ring_values,
		"rimDeltaY": rounded(rim_delta),
		"dropY": rounded(drop_y),
		"normal": vec3(normal),
		"upwardSurfaceHit": upward_surface_hit,
		"strongConcavity": strong_concavity
	}

func target_anchor_for_outcome(outcome: Dictionary) -> Dictionary:
	var target_before: Dictionary = outcome.get("targetBefore", {}) if outcome.get("targetBefore", {}) is Dictionary else {}
	if bool(target_before.get("hit", false)) and target_before.has("position"):
		return target_before
	var snapshots: Array = outcome.get("targetSnapshots", []) if outcome.get("targetSnapshots", []) is Array else []
	for snapshot_value in snapshots:
		if not (snapshot_value is Dictionary):
			continue
		var snapshot: Dictionary = snapshot_value
		if bool(snapshot.get("hit", false)) and snapshot.has("position"):
			return snapshot
	var post_target: Dictionary = outcome.get("postTarget", {}) if outcome.get("postTarget", {}) is Dictionary else {}
	if bool(post_target.get("hit", false)) and post_target.has("position"):
		return post_target
	return target_before

func inventory_count(item_id: String) -> int:
	if inventory_system == null or not inventory_system.has_method("count"):
		return 0
	return int(inventory_system.count(item_id))

func inventory_totals() -> Dictionary:
	if inventory_system == null or not inventory_system.has_method("totals"):
		return {}
	return inventory_system.totals()

func dict_to_vec3(value: Dictionary, fallback: Vector3) -> Vector3:
	if value.has("x") and value.has("y") and value.has("z"):
		return Vector3(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)), float(value.get("z", fallback.z)))
	return fallback

func column_summary() -> Dictionary:
	return {
		"column": vec2i(test_column),
		"preferredMaterial": preferred_material,
		"topCell": vec3i(top_cell),
		"surfacePosition": vec3(surface_position),
		"surfaceCollision": surface_collision_summary(),
		"plannedMaterials": planned_materials
	}

func surface_collision_summary() -> Dictionary:
	return {
		"found": has_surface_collision,
		"position": vec3(surface_collision_position),
		"normal": vec3(surface_collision_normal)
	}

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

func image_sky_pixel_summary(image: Image) -> Dictionary:
	var width := image.get_width()
	var height := image.get_height()
	var step_x := maxi(1, width / 96)
	var step_y := maxi(1, height / 54)
	var sky_count := 0
	var count := 0
	var max_sky_score := 0.0
	for y in range(0, height, step_y):
		for x in range(0, width, step_x):
			var color := image.get_pixel(x, y)
			var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			var sky_score := minf(color.b - color.r, color.g - color.r)
			max_sky_score = maxf(max_sky_score, sky_score)
			if luma > 0.52 and color.b > 0.58 and color.g > 0.52 and sky_score > 0.055:
				sky_count += 1
			count += 1
	var ratio := float(sky_count) / maxf(1.0, float(count))
	return {
		"passed": ratio <= 0.003,
		"skyPixels": sky_count,
		"samples": count,
		"ratio": rounded(ratio),
		"maxSkyScore": rounded(max_sky_score)
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
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [ACCEPTANCE_CLAIM],
		"requiredScreenshots": capture_names(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"digOutcomes": dig_outcomes,
		"column": column_summary(),
		"liveProcess": live_process,
		"timeline": timeline,
		"forbiddenCallSelfScan": forbidden_call_self_scan()
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func forbidden_call_self_scan() -> Dictionary:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/testing/DiggingVisualPlaytestRunner.gd"))
	var banned := ["add_" + "excavation_brush", "excavate_" + "from_hit", "register_" + "excavation_brush"]
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

func water_level() -> float:
	return float(main.WATER_LEVEL) if main != null else 11.1

func rounded(value: float) -> float:
	return snappedf(value, 0.001)

func vec3(value: Vector3) -> Dictionary:
	return { "x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z) }

func vec3i(value: Vector3i) -> Dictionary:
	return { "x": value.x, "y": value.y, "z": value.z }

func vec2i(value: Vector2i) -> Dictionary:
	return { "x": value.x, "z": value.y }
