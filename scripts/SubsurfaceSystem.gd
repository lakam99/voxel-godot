extends RefCounted
class_name SubsurfaceSystem

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const CAVE_VISUAL_LAYER := 1 << 1
const PATCH_MARGIN_CELLS := 5
const VOLUME_SUBDIVISIONS := 1.0
const COARSE_VOLUME_SUBDIVISIONS := 1.0
const SHELL_GRID_SUBDIVISIONS := 2.0
const SHELL_WALL_VERTICAL_SEGMENTS := 4
const SHELL_WALL_OVERLAP := 0.10
const EXCAVATION_RADIUS_CELLS := 1.35
const MIN_SEPARATOR_CELLS := 2.0
const CAVE_AIR_THRESHOLD := 1.0

var main
var cave_patch_nodes := {}
var cave_patch_plans := {}
var cave_volume_footprint_cache := {}
var excavation_brushes: Array[Dictionary] = []
var excavation_sequence := 0
var excavation_patch_nodes := {}
var subsurface_material: StandardMaterial3D
var world_volume_sampler

func setup(main_node) -> void:
	main = main_node
	world_volume_sampler = main.get("world_generation_system") if main != null else null
	if world_volume_sampler == null:
		world_volume_sampler = WorldGenerationSystemScript.new()
		world_volume_sampler.setup(main)

func sampler():
	var main_world_generation = main.get("world_generation_system") if main != null else null
	if main_world_generation != null:
		world_volume_sampler = main_world_generation
	if world_volume_sampler == null:
		world_volume_sampler = WorldGenerationSystemScript.new()
		world_volume_sampler.setup(main)
	return world_volume_sampler

func reset() -> void:
	for cave_id in cave_patch_plans.keys():
		if sampler().has_method("unregister_cave"):
			sampler().call("unregister_cave", String(cave_id))
	for node in cave_patch_nodes.values():
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()
	for node in excavation_patch_nodes.values():
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()
	cave_patch_nodes.clear()
	cave_patch_plans.clear()
	cave_volume_footprint_cache.clear()
	excavation_patch_nodes.clear()
	excavation_brushes.clear()
	excavation_sequence = 0
	if sampler().has_method("clear_excavation_brushes"):
		sampler().call("clear_excavation_brushes")

func subsurface_material_at(cell: Vector3i) -> String:
	if main == null:
		return "air"
	if main.has_method("world_material_at_cell"):
		return String(main.call("world_material_at_cell", cell))
	return String(sampler().material_at_cell3(cell)) if sampler().has_method("material_at_cell3") else "air"

func subsurface_is_solid(cell: Vector3i) -> bool:
	return subsurface_material_at(cell) != "air"

func subsurface_biome_at(cell: Vector3i) -> String:
	if main == null:
		return "plains"
	if main.has_method("biome_at_cell3"):
		return String(main.call("biome_at_cell3", cell))
	return String(main.call("biome_at_cell", cell.x, cell.z)) if main.has_method("biome_at_cell") else "plains"

func break_target_for_hit(hit: Dictionary, collider: Node, kind: String) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var cell := world_to_cell3(sample_pos)
	var material_id := subsurface_material_at(cell)
	if material_id == "air":
		material_id = material_near_surface(sample_pos)
	var target_kind := "subsurface" if kind == "subsurface" else "terrain"
	return {
		"id": "%s:%d,%d,%d" % [target_kind, cell.x, cell.y, cell.z],
		"material": material_id,
		"cell3": cell
	}

func excavate_from_hit(hit: Dictionary, collider: Node = null) -> Dictionary:
	var sample_pos := hit_sample_position(hit)
	var cave_id := ""
	if collider != null and collider.has_meta("caveId"):
		cave_id = String(collider.get_meta("caveId", ""))
	if cave_id == "":
		cave_id = cave_id_at_world(sample_pos)
	var brush := add_excavation_brush(sample_pos, float(main.CELL) * EXCAVATION_RADIUS_CELLS, cave_id)
	if cave_id != "" and cave_patch_plans.has(cave_id):
		rebuild_cave_patch(cave_id)
	else:
		rebuild_excavation_patch(String(brush.get("id", "")))
	var affected := affected_surface_cells_for_brush(brush)
	for cell in affected:
		if main != null and main.has_method("rebuild_chunks_around_cell"):
			main.call("rebuild_chunks_around_cell", cell)
	return {
		"brush": brush,
		"affectedCells": affected,
		"caveId": cave_id
	}

func add_excavation_brush(center: Vector3, radius: float, cave_id := "") -> Dictionary:
	excavation_sequence += 1
	var brush := {
		"id": "dig:%d" % excavation_sequence,
		"center": center,
		"radius": radius,
		"caveId": cave_id
	}
	excavation_brushes.append(brush)
	mark_excavation_hidden_cells(brush)
	if sampler().has_method("register_excavation_brush"):
		sampler().call("register_excavation_brush", brush)
	return brush

func snapshot() -> Dictionary:
	var brushes := []
	for brush in excavation_brushes:
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		brushes.append({
			"id": String(brush.get("id", "")),
			"x": center.x,
			"y": center.y,
			"z": center.z,
			"radius": float(brush.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS)),
			"caveId": String(brush.get("caveId", ""))
		})
	return {
		"version": 2,
		"excavationSequence": excavation_sequence,
		"excavationBrushes": brushes
	}

func restore(snapshot_value) -> void:
	for node in excavation_patch_nodes.values():
		if node is Node and is_instance_valid(node):
			(node as Node).queue_free()
	excavation_patch_nodes.clear()
	excavation_brushes.clear()
	excavation_sequence = 0
	if sampler().has_method("clear_excavation_brushes"):
		sampler().call("clear_excavation_brushes")
	var state: Dictionary = snapshot_value if snapshot_value is Dictionary else {}
	excavation_sequence = max(0, int(state.get("excavationSequence", 0)))
	var brushes_value = state.get("excavationBrushes", [])
	if not (brushes_value is Array):
		return
	for entry_value in brushes_value:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var brush := {
			"id": String(entry.get("id", "dig:%d" % (excavation_sequence + 1))),
			"center": Vector3(float(entry.get("x", 0.0)), float(entry.get("y", 0.0)), float(entry.get("z", 0.0))),
			"radius": float(entry.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS)),
			"caveId": String(entry.get("caveId", ""))
		}
		excavation_brushes.append(brush)
		mark_excavation_hidden_cells(brush)
		if sampler().has_method("register_excavation_brush"):
			sampler().call("register_excavation_brush", brush)
		if String(brush.get("caveId", "")) == "":
			rebuild_excavation_patch(String(brush.get("id", "")))

func register_cave_plan(plan: Dictionary, cave_builder = null, rng: RandomNumberGenerator = null, metadata: Dictionary = {}) -> Node3D:
	if main == null or plan.is_empty():
		return null
	var cave_id := String(plan.get("id", "cave"))
	cave_volume_footprint_cache.erase(cave_id)
	cave_patch_plans[cave_id] = {
		"plan": plan.duplicate(true),
		"builder": cave_builder,
		"metadata": metadata.duplicate(true)
	}
	if sampler().has_method("register_cave_plan"):
		sampler().call("register_cave_plan", plan, metadata)
	return rebuild_cave_patch(cave_id, rng)

func unregister_cave(cave_id: String) -> void:
	if cave_patch_nodes.has(cave_id):
		var node := cave_patch_nodes[cave_id] as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	cave_patch_nodes.erase(cave_id)
	cave_patch_plans.erase(cave_id)
	cave_volume_footprint_cache.erase(cave_id)
	if sampler().has_method("unregister_cave"):
		sampler().call("unregister_cave", cave_id)

func rebuild_cave_patch(cave_id: String, rng: RandomNumberGenerator = null) -> Node3D:
	if not cave_patch_plans.has(cave_id):
		return null
	cave_perf_log("rebuild-start", { "id": cave_id })
	if cave_patch_nodes.has(cave_id):
		var old_node := cave_patch_nodes[cave_id] as Node
		if old_node != null and is_instance_valid(old_node):
			old_node.queue_free()
		cave_patch_nodes.erase(cave_id)
	var record: Dictionary = cave_patch_plans[cave_id]
	var plan: Dictionary = record.get("plan", {})
	if plan.is_empty():
		return null
	var patch_rng := rng
	if patch_rng == null:
		patch_rng = RandomNumberGenerator.new()
		patch_rng.seed = main.hash_string("%s:%s:subsurface-volume" % [String(main.get("seed_text")), cave_id])
	cave_perf_log("surface-cuts-authoritative", { "id": cave_id, "authority": "world_generation_solid_air_volume" })
	var mesh := build_cave_volume_mesh(plan, true)
	if mesh == null:
		return null
	cave_perf_log("mesh-built", { "id": cave_id })
	var root := Node3D.new()
	root.name = "SubsurfaceCaveVolume_%s" % cave_id.replace(":", "_").replace(",", "_")
	root.set_meta("generated", true)
	root.set_meta("generatedTier", "cave")
	root.set_meta("caveId", cave_id)
	root.set_meta("caveRole", "world_volume")
	root.set_meta("geometryAuthority", "subsurface_solid_air_volume")
	var metadata: Dictionary = record.get("metadata", {})
	for key in metadata.keys():
		root.set_meta(String(key), metadata[key])

	var visual := MeshInstance3D.new()
	visual.name = "SubsurfaceCaveVisual"
	visual.mesh = mesh
	visual.material_override = material()
	visual.layers = CAVE_VISUAL_LAYER
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(visual)

	var shadow := MeshInstance3D.new()
	shadow.name = "SubsurfaceCaveShadow"
	shadow.mesh = mesh
	shadow.material_override = material()
	shadow.layers = CAVE_VISUAL_LAYER
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	root.add_child(shadow)

	var body := StaticBody3D.new()
	body.name = "SubsurfaceCaveBody"
	body.collision_layer = 1 | 2
	body.collision_mask = 0
	body.set_meta("kind", "subsurface")
	body.set_meta("generated", true)
	body.set_meta("generatedTier", "cave")
	body.set_meta("caveId", cave_id)
	body.set_meta("caveRole", "world_volume_collision")
	body.set_meta("geometryAuthority", "subsurface_solid_air_volume")
	var collision := CollisionShape3D.new()
	collision.name = "SubsurfaceCaveCollision"
	collision.shape = mesh.create_trimesh_shape()
	cave_perf_log("collision-built", { "id": cave_id })
	body.add_child(collision)
	root.add_child(body)

	var cave_builder = record.get("builder", null)
	if cave_builder != null and cave_builder.has_method("build_formation_mesh"):
		cave_perf_log("formations-start", { "id": cave_id })
		var formation_mesh: Mesh = cave_builder.call("build_formation_mesh", plan, patch_rng)
		if formation_mesh != null:
			var formations := MeshInstance3D.new()
			formations.name = "SubsurfaceCaveFormations"
			formations.mesh = formation_mesh
			formations.material_override = cave_builder.call("cave_formation_material") if cave_builder.has_method("cave_formation_material") else material()
			formations.layers = CAVE_VISUAL_LAYER
			formations.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			root.add_child(formations)
		cave_perf_log("formations-done", { "id": cave_id })
	if cave_builder != null and cave_builder.has_method("add_support_frames"):
		cave_perf_log("supports-start", { "id": cave_id })
		cave_builder.call("add_support_frames", root, plan)
		cave_perf_log("supports-done", { "id": cave_id })

	var parent = main.get("block_root")
	if parent is Node:
		parent.add_child(root)
	elif main is Node:
		main.add_child(root)
	cave_patch_nodes[cave_id] = root
	cave_perf_log("rebuild-done", { "id": cave_id })
	return root

func build_cave_volume_mesh(plan: Dictionary, detailed := true) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_cave_volume_to_surface_tool(st, plan, detailed)
	st.generate_normals()
	return st.commit()

func add_cave_volume_to_surface_tool(st: SurfaceTool, plan: Dictionary, detailed := true) -> void:
	add_cave_voxel_volume_to_surface_tool(st, plan, detailed)

func add_cave_voxel_volume_to_surface_tool(st: SurfaceTool, plan: Dictionary, detailed := true) -> void:
	var cell_size := float(main.CELL)
	var step := cell_size / (VOLUME_SUBDIVISIONS if detailed else COARSE_VOLUME_SUBDIVISIONS)
	var bounds := cave_world_bounds(plan)
	var min_x := floori(float(bounds.get("minX", 0.0)) / step) - 1
	var max_x := ceili(float(bounds.get("maxX", 0.0)) / step) + 1
	var min_z := floori(float(bounds.get("minZ", 0.0)) / step) - 1
	var max_z := ceili(float(bounds.get("maxZ", 0.0)) / step) + 1
	var solid_cache := {}
	var air_indices := cave_extraction_air_indices(plan, step, min_x, max_x, min_z, max_z)
	cave_perf_log("extract-air", { "id": String(plan.get("id", "")), "air": air_indices.size(), "step": step })
	var emitted_faces := {}
	var directions := [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]
	for air_key_value in air_indices.keys():
		var air_key: Vector3i = air_key_value
		for dir in directions:
			var solid_key: Vector3i = air_key + dir
			if not cave_volume_solid_at_index(plan, solid_key.x, solid_key.y, solid_key.z, step, solid_cache):
				continue
			var face_dir := Vector3i(-dir.x, -dir.y, -dir.z)
			var face_key := "%d,%d,%d:%d,%d,%d" % [solid_key.x, solid_key.y, solid_key.z, face_dir.x, face_dir.y, face_dir.z]
			if emitted_faces.has(face_key):
				continue
			if face_dir.y == 0 and cave_face_center_in_air(plan, solid_key.x, solid_key.y, solid_key.z, face_dir, step):
				continue
			emitted_faces[face_key] = true
			add_voxel_face(st, plan, solid_key.x, solid_key.y, solid_key.z, face_dir, step)
	cave_perf_log("extract-faces", { "id": String(plan.get("id", "")), "faces": emitted_faces.size() })

func add_cave_surface_shell_to_surface_tool(st: SurfaceTool, plan: Dictionary, detailed := true) -> void:
	var cell_size := float(main.CELL)
	var step := cell_size / (SHELL_GRID_SUBDIVISIONS if detailed else 1.0)
	var bounds := cave_world_bounds(plan)
	var min_x := floori(float(bounds.get("minX", 0.0)) / step) - 1
	var max_x := ceili(float(bounds.get("maxX", 0.0)) / step) + 1
	var min_z := floori(float(bounds.get("minZ", 0.0)) / step) - 1
	var max_z := ceili(float(bounds.get("maxZ", 0.0)) / step) + 1
	var inside := {}
	var columns := cave_extraction_column_indices(plan, step, min_x, max_x, min_z, max_z)
	for column_value in columns.keys():
		var column: Vector2i = column_value
		var center := Vector2((float(column.x) + 0.5) * step, (float(column.y) + 0.5) * step)
		if cave_volume_value(plan, center) <= 1.08:
			inside[column] = true
	var wall_segments := SHELL_WALL_VERTICAL_SEGMENTS if detailed else 2
	for column_value in inside.keys():
		var key: Vector2i = column_value
		var p00 := Vector2(float(key.x) * step, float(key.y) * step)
		var p10 := Vector2(float(key.x + 1) * step, float(key.y) * step)
		var p11 := Vector2(float(key.x + 1) * step, float(key.y + 1) * step)
		var p01 := Vector2(float(key.x) * step, float(key.y + 1) * step)
		if not cave_shell_exterior_mouth_slice(plan, (p00 + p11) * 0.5):
			add_cave_shell_floor_quad(st, plan, p00, p10, p11, p01)
			add_cave_shell_ceiling_quad(st, plan, p00, p01, p11, p10)
		add_cave_shell_boundary_walls(st, plan, inside, key, p00, p10, p11, p01, wall_segments)
	cave_perf_log("extract-shell", { "id": String(plan.get("id", "")), "columns": inside.size(), "step": step })

func add_cave_shell_floor_quad(st: SurfaceTool, plan: Dictionary, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2) -> void:
	add_quad(
		st,
		cave_shell_floor_point(plan, p00),
		cave_shell_floor_point(plan, p10),
		cave_shell_floor_point(plan, p11),
		cave_shell_floor_point(plan, p01),
		cave_shell_floor_color(world_cell2(p00))
	)

func add_cave_shell_ceiling_quad(st: SurfaceTool, plan: Dictionary, p00: Vector2, p01: Vector2, p11: Vector2, p10: Vector2) -> void:
	add_quad(
		st,
		cave_shell_ceiling_point(plan, p00),
		cave_shell_ceiling_point(plan, p01),
		cave_shell_ceiling_point(plan, p11),
		cave_shell_ceiling_point(plan, p10),
		cave_shell_ceiling_color(world_cell2(p00))
	)

func add_cave_shell_boundary_walls(st: SurfaceTool, plan: Dictionary, inside: Dictionary, key: Vector2i, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2, wall_segments: int) -> void:
	if not inside.has(key + Vector2i(0, -1)) and not cave_shell_mouth_edge_open(plan, (p00 + p10) * 0.5, Vector2i(0, -1)):
		add_cave_shell_wall_strip(st, plan, p10, p00, wall_segments)
	if not inside.has(key + Vector2i(1, 0)) and not cave_shell_mouth_edge_open(plan, (p10 + p11) * 0.5, Vector2i(1, 0)):
		add_cave_shell_wall_strip(st, plan, p11, p10, wall_segments)
	if not inside.has(key + Vector2i(0, 1)) and not cave_shell_mouth_edge_open(plan, (p11 + p01) * 0.5, Vector2i(0, 1)):
		add_cave_shell_wall_strip(st, plan, p01, p11, wall_segments)
	if not inside.has(key + Vector2i(-1, 0)) and not cave_shell_mouth_edge_open(plan, (p01 + p00) * 0.5, Vector2i(-1, 0)):
		add_cave_shell_wall_strip(st, plan, p00, p01, wall_segments)

func add_cave_shell_wall_strip(st: SurfaceTool, plan: Dictionary, a2: Vector2, b2: Vector2, wall_segments: int) -> void:
	var color := cave_shell_wall_color(world_cell2((a2 + b2) * 0.5))
	for segment in range(wall_segments):
		var t0 := float(segment) / float(wall_segments)
		var t1 := float(segment + 1) / float(wall_segments)
		var a0 := cave_shell_wall_point(plan, a2, t0)
		var b0 := cave_shell_wall_point(plan, b2, t0)
		var b1 := cave_shell_wall_point(plan, b2, t1)
		var a1 := cave_shell_wall_point(plan, a2, t1)
		add_quad(st, a0, b0, b1, a1, color)

func cave_shell_floor_point(plan: Dictionary, point: Vector2) -> Vector3:
	return Vector3(point.x, cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0))), point.y)

func cave_shell_ceiling_point(plan: Dictionary, point: Vector2) -> Vector3:
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	return Vector3(point.x, cave_ceiling_y_at_surface(plan, point, floor_y + float(main.CELL) * 3.0), point.y)

func cave_shell_wall_point(plan: Dictionary, point: Vector2, vertical_t: float) -> Vector3:
	var floor := cave_shell_floor_point(plan, point)
	var ceiling := cave_shell_ceiling_point(plan, point)
	var y := lerpf(floor.y - SHELL_WALL_OVERLAP, ceiling.y + SHELL_WALL_OVERLAP, vertical_t)
	var belly := sin(vertical_t * PI) * stable_signed(plan, "shell-wall-belly", floori(point.x * 0.5), floori(point.y * 0.5)) * 0.10
	return Vector3(point.x, y + belly, point.y)

func cave_shell_mouth_edge_open(plan: Dictionary, point: Vector2, direction: Vector2i) -> bool:
	var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
	var outward := Vector2i(-inward.x, -inward.y)
	if direction != outward:
		return false
	var axes := cave_mouth_depth_lateral(plan, point)
	if axes.x < cave_mouth_front_depth(plan) or axes.x > 1.35:
		return false
	var width := cave_mouth_width_at_depth(plan, axes.x)
	if width <= 0.0:
		width = float(plan.get("entranceMouthHalfWidth", 3.85))
	return absf(axes.y) <= width + 0.50

func cave_shell_exterior_mouth_slice(plan: Dictionary, point: Vector2) -> bool:
	var axes := cave_mouth_depth_lateral(plan, point)
	if axes.x < cave_mouth_front_depth(plan) or axes.x >= 0.0:
		return false
	var width := cave_mouth_width_at_depth(plan, axes.x)
	if width <= 0.0:
		return false
	return absf(axes.y) <= width + 0.60

func cave_shell_floor_color(cell: Vector2i) -> Color:
	var shade := 0.84 + stable01({}, "shell-floor", cell.x, cell.y) * 0.18
	return Color(0.105, 0.112, 0.112) * shade

func cave_shell_wall_color(cell: Vector2i) -> Color:
	var shade := 0.82 + stable01({}, "shell-wall", cell.x - 13, cell.y + 29) * 0.18
	return Color(0.155, 0.172, 0.166) * shade

func cave_shell_ceiling_color(cell: Vector2i) -> Color:
	var shade := 0.76 + stable01({}, "shell-ceiling", cell.x + 19, cell.y - 31) * 0.14
	return Color(0.050, 0.058, 0.060) * shade

func world_cell2(point: Vector2) -> Vector2i:
	var cell_size := float(main.CELL)
	return Vector2i(roundi(point.x / cell_size), roundi(point.y / cell_size))

func cave_extraction_air_indices(plan: Dictionary, step: float, min_x: int, max_x: int, min_z: int, max_z: int) -> Dictionary:
	var air_indices := {}
	var surface_cache := {}
	add_cave_mouth_air_indices(air_indices, surface_cache, plan, step, min_x, max_x, min_z, max_z)
	for profile_value in cave_extraction_graph_profiles(plan):
		if profile_value is Dictionary:
			add_cave_profile_air_indices(air_indices, surface_cache, plan, profile_value, step, min_x, max_x, min_z, max_z)
	return air_indices

func add_cave_profile_air_indices(air_indices: Dictionary, surface_cache: Dictionary, plan: Dictionary, profile: Dictionary, step: float, min_x: int, max_x: int, min_z: int, max_z: int) -> void:
	var center2: Vector2 = profile.get("center", Vector2.ZERO)
	var radius := float(profile.get("radius", float(main.CELL) * 2.0))
	var half_height := float(profile.get("halfHeight", float(main.CELL)))
	var center_y := float(profile.get("centerY", float(plan.get("level", 0.0))))
	var start_x := maxi(min_x, floori((center2.x - radius - step) / step) - 1)
	var end_x := mini(max_x, ceili((center2.x + radius + step) / step) + 1)
	var start_z := maxi(min_z, floori((center2.y - radius - step) / step) - 1)
	var end_z := mini(max_z, ceili((center2.y + radius + step) / step) + 1)
	var start_y := floori((center_y - half_height - step) / step) - 1
	var end_y := ceili((center_y + half_height + step) / step) + 1
	for ix in range(start_x, end_x + 1):
		for iz in range(start_z, end_z + 1):
			var point := Vector2((float(ix) + 0.5) * step, (float(iz) + 0.5) * step)
			var horizontal_value := center2.distance_to(point) / maxf(0.001, radius)
			if horizontal_value > CAVE_AIR_THRESHOLD + 0.08:
				continue
			var surface_y := cave_cached_surface_y(surface_cache, plan, point)
			for iy in range(start_y, end_y + 1):
				var world_y := (float(iy) + 0.5) * step
				if world_y > surface_y + float(main.CELL) * 0.08:
					continue
				var vertical_value := absf(world_y - center_y) / maxf(0.001, half_height)
				if maxf(horizontal_value, vertical_value) <= CAVE_AIR_THRESHOLD:
					air_indices[Vector3i(ix, iy, iz)] = true

func add_cave_mouth_air_indices(air_indices: Dictionary, surface_cache: Dictionary, plan: Dictionary, step: float, min_x: int, max_x: int, min_z: int, max_z: int) -> void:
	var cell_size := float(main.CELL)
	var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
	var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
	var right: Vector2i = plan.get("right", Vector2i(1, 0))
	var front_depth := floori(cave_mouth_front_depth(plan)) - 1
	var interior_depth := int(plan.get("entranceOpenDepth", 7)) + 2
	var lateral_limit := ceili(float(plan.get("entranceMouthHalfWidth", 3.85)) + 2.0)
	var lookup := {}
	for depth in range(front_depth, interior_depth + 1):
		for lateral in range(-lateral_limit, lateral_limit + 1):
			var cell := entrance + inward * depth + right * lateral
			lookup[cell] = true
	for cell_value in lookup.keys():
		var cell: Vector2i = cell_value
		var base_x := floori(float(cell.x) * cell_size / step)
		var base_z := floori(float(cell.y) * cell_size / step)
		for sx in range(-1, 2):
			for sz in range(-1, 2):
				var ix := base_x + sx
				var iz := base_z + sz
				if ix < min_x or ix > max_x or iz < min_z or iz > max_z:
					continue
				var point := Vector2((float(ix) + 0.5) * step, (float(iz) + 0.5) * step)
				var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
				var ceiling_y := cave_ceiling_y_at_surface(plan, point, floor_y + cell_size * 3.0)
				var surface_y := cave_cached_surface_y(surface_cache, plan, point)
				var start_y := floori((floor_y - step) / step) - 1
				var end_y := ceili((minf(ceiling_y, surface_y + cell_size * 0.08) + step) / step) + 1
				for iy in range(start_y, end_y + 1):
					var world_pos := Vector3((float(ix) + 0.5) * step, (float(iy) + 0.5) * step, (float(iz) + 0.5) * step)
					if float(sampler().call("cave_mouth_air_value_at_world", plan, world_pos)) <= CAVE_AIR_THRESHOLD:
						air_indices[Vector3i(ix, iy, iz)] = true

func cave_cached_surface_y(surface_cache: Dictionary, plan: Dictionary, point: Vector2) -> float:
	var key := Vector2i(roundi(point.x / float(main.CELL)), roundi(point.y / float(main.CELL)))
	if surface_cache.has(key):
		return float(surface_cache[key])
	var value := surface_height_for_plan_point(plan, point)
	surface_cache[key] = value
	return value

func cave_extraction_graph_profiles(plan: Dictionary) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	var cell_size := float(main.CELL)
	for edge_value in plan.get("caveEdges", []):
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var radius := float(edge.get("radius", 1.6)) * cell_size
		var edge_id := String(edge.get("id", "edge"))
		var edge_noise := 0.92 + stable01(plan, "edge-radius:%s" % edge_id, 0, 0) * 0.18
		radius *= edge_noise
		for cell_value in edge.get("centerCells", []):
			if not (cell_value is Vector2i):
				continue
			var center2 := cell_world2(cell_value)
			var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
			var ceiling_y := cave_profile_ceiling_y_for_extraction(plan, center2, floor_y)
			profiles.append({
				"center": center2,
				"radius": radius,
				"halfHeight": maxf(cell_size * 0.72, (ceiling_y - floor_y) * 0.5),
				"centerY": (floor_y + ceiling_y) * 0.5
			})
	for node_value in plan.get("caveNodes", []):
		if not (node_value is Dictionary):
			continue
		var node: Dictionary = node_value
		var center_cell: Vector2i = node.get("cell", Vector2i.ZERO)
		var center2 := cell_world2(center_cell)
		var radius := float(node.get("radius", 2.0)) * cell_size
		var kind := String(node.get("kind", ""))
		if kind == "entrance":
			radius *= 0.88
		else:
			radius *= 1.04 + stable01(plan, "node-radius:%s" % String(node.get("id", "")), 0, 0) * 0.18
		var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
		var ceiling_y := cave_profile_ceiling_y_for_extraction(plan, center2, floor_y)
		profiles.append({
			"center": center2,
			"radius": radius,
			"halfHeight": maxf(cell_size * 0.85, (ceiling_y - floor_y) * 0.5),
			"centerY": (floor_y + ceiling_y) * 0.5
		})
	return profiles

func cave_profile_ceiling_y_for_extraction(plan: Dictionary, point: Vector2, floor_y: float) -> float:
	if sampler().has_method("cave_profile_ceiling_y"):
		return float(sampler().call("cave_profile_ceiling_y", plan, point, floor_y))
	return cave_ceiling_y_at_surface(plan, point, floor_y + float(main.CELL) * 3.0)

func cave_extraction_column_indices(plan: Dictionary, step: float, min_x: int, max_x: int, min_z: int, max_z: int) -> Dictionary:
	var columns := {}
	var cell_size := float(main.CELL)
	var subdivision := maxi(1, roundi(cell_size / step))
	var footprint_cells := cave_volume_footprint_cells(plan)
	for cell_value in footprint_cells.keys():
		var cell: Vector2i = cell_value
		var base_x := floori(float(cell.x) * cell_size / step)
		var base_z := floori(float(cell.y) * cell_size / step)
		for sx in range(-1, subdivision + 1):
			for sz in range(-1, subdivision + 1):
				var ix := base_x + sx
				var iz := base_z + sz
				if ix < min_x or ix > max_x or iz < min_z or iz > max_z:
					continue
				columns[Vector2i(ix, iz)] = true
	if columns.is_empty():
		for ix in range(min_x, max_x + 1):
			for iz in range(min_z, max_z + 1):
				columns[Vector2i(ix, iz)] = true
	cave_perf_log("extract-columns", { "id": String(plan.get("id", "")), "columns": columns.size(), "footprintCells": footprint_cells.size() })
	return columns

func cave_extraction_column_relevant(plan: Dictionary, point: Vector2) -> bool:
	return cave_volume_value(plan, point) <= 2.55 or cave_mound_overlay(plan, point) > float(main.CELL) * 0.015

func cave_volume_footprint_cells(plan: Dictionary) -> Dictionary:
	var cave_id := String(plan.get("id", ""))
	if cave_id != "" and cave_volume_footprint_cache.has(cave_id):
		var cached = cave_volume_footprint_cache[cave_id]
		return (cached as Dictionary).duplicate() if cached is Dictionary else {}
	var lookup := {}
	for cell_value in cave_surface_cut_candidate_cells(plan):
		lookup[cell_value] = true
	for edge_value in plan.get("caveEdges", []):
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var radius := ceili(float(edge.get("radius", 1.6)) + 0.75)
		for center_value in edge.get("centerCells", []):
			if center_value is Vector2i:
				add_cave_footprint_disc(lookup, center_value, radius)
	for node_value in plan.get("caveNodes", []):
		if not (node_value is Dictionary):
			continue
		var node: Dictionary = node_value
		var radius := ceili(float(node.get("radius", 2.0)) + 1.0)
		add_cave_footprint_disc(lookup, node.get("cell", Vector2i.ZERO), radius)
	if cave_id != "":
		cave_volume_footprint_cache[cave_id] = lookup.duplicate()
	return lookup

func add_cave_footprint_disc(lookup: Dictionary, center: Vector2i, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if Vector2(float(dx), float(dz)).length() <= float(radius):
				lookup[center + Vector2i(dx, dz)] = true

func cave_extraction_column_sample(plan: Dictionary, point: Vector2) -> Dictionary:
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var ceiling_y := cave_ceiling_y_at_surface(plan, point, floor_y + float(main.CELL) * 3.0)
	return {
		"inside": cave_volume_value(plan, point) <= CAVE_AIR_THRESHOLD,
		"floorY": floor_y,
		"ceilingY": ceiling_y
	}

func cave_extraction_y_indices(sample: Dictionary, step: float) -> Dictionary:
	var indices := {}
	var floor_y := float(sample.get("floorY", 0.0))
	var ceiling_y := float(sample.get("ceilingY", floor_y + step * 3.0))
	add_y_index_range(indices, floor_y - step * 1.75, ceiling_y + step * 1.75, step)
	return indices

func add_y_index_range(indices: Dictionary, min_y: float, max_y: float, step: float) -> void:
	var start := floori(min_y / step) - 1
	var end := ceili(max_y / step) + 1
	for iy in range(start, end + 1):
		indices[iy] = true

func cave_extraction_sample_is_air(sample: Dictionary, world_pos: Vector3, step: float) -> bool:
	if bool(sample.get("inside", false)) \
		and world_pos.y >= float(sample.get("floorY", 0.0)) - step * 0.05 \
		and world_pos.y <= float(sample.get("ceilingY", 0.0)) + step * 0.05:
		return true
	for brush in excavation_brushes:
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius + step:
			return true
	return false

func surface_cut_point(plan: Dictionary, point: Vector2) -> bool:
	return surface_patch_quad_cut_by_cave_pipe(plan, point, point, point, point)

func cave_volume_solid_at_index(plan: Dictionary, ix: int, iy: int, iz: int, step: float, cache: Dictionary) -> bool:
	var key := Vector3i(ix, iy, iz)
	if cache.has(key):
		return bool(cache[key])
	var center := Vector3((float(ix) + 0.5) * step, (float(iy) + 0.5) * step, (float(iz) + 0.5) * step)
	var solid := solid_at_world(plan, center)
	cache[key] = solid
	return solid

func solid_at_world(plan: Dictionary, world_pos: Vector3) -> bool:
	if sampler().has_method("solid_at_world_for_plan"):
		return bool(sampler().call("solid_at_world_for_plan", plan, world_pos, excavation_brushes))
	return bool(sampler().call("solid_at_world", world_pos, cave_patch_plans, excavation_brushes))

func cave_face_center_in_air(plan: Dictionary, ix: int, iy: int, iz: int, dir: Vector3i, step: float) -> bool:
	var center := Vector3(
		(float(ix) + 0.5) * step + float(dir.x) * step * 0.5,
		(float(iy) + 0.5) * step + float(dir.y) * step * 0.5,
		(float(iz) + 0.5) * step + float(dir.z) * step * 0.5
	)
	return not solid_at_world(plan, center)

func add_voxel_face(st: SurfaceTool, plan: Dictionary, ix: int, iy: int, iz: int, dir: Vector3i, step: float) -> void:
	var x0 := float(ix) * step
	var x1 := float(ix + 1) * step
	var y0 := float(iy) * step
	var y1 := float(iy + 1) * step
	var z0 := float(iz) * step
	var z1 := float(iz + 1) * step
	var center := Vector3((x0 + x1) * 0.5 + float(dir.x) * step * 0.5, (y0 + y1) * 0.5 + float(dir.y) * step * 0.5, (z0 + z1) * 0.5 + float(dir.z) * step * 0.5)
	var color := material_color_at_world(plan, center, dir)
	if dir == Vector3i(1, 0, 0):
		add_quad(st, Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), color)
	elif dir == Vector3i(-1, 0, 0):
		add_quad(st, Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0), color)
	elif dir == Vector3i(0, 1, 0):
		add_quad(st, Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0), color)
	elif dir == Vector3i(0, -1, 0):
		add_quad(st, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), color)
	elif dir == Vector3i(0, 0, 1):
		add_quad(st, Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1), color)
	else:
		add_quad(st, Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0), color)

func material_color_at_world(plan: Dictionary, world_pos: Vector3, dir: Vector3i) -> Color:
	var surface_y := surface_height_for_plan_point(plan, Vector2(world_pos.x, world_pos.z))
	var depth := surface_y - world_pos.y
	if dir.y > 0 and depth < float(main.CELL) * 0.90:
		return surface_color_for_cell(Vector2i(roundi(world_pos.x / float(main.CELL)), roundi(world_pos.z / float(main.CELL))))
	if dir.y > 0:
		return Color(0.105, 0.115, 0.112)
	if dir.y < 0:
		return Color(0.045, 0.052, 0.054)
	var shade := 0.84 + stable01(plan, "volume-wall-shade", floori(world_pos.x), floori(world_pos.z)) * 0.22
	if depth <= float(main.CELL) * 4.0:
		return Color(0.185, 0.205, 0.190) * shade
	return Color(0.155, 0.168, 0.164) * shade

func cave_world_bounds(plan: Dictionary) -> Dictionary:
	var cell_size := float(main.CELL)
	var cells := cave_relevant_cells(plan, true)
	if cells.is_empty():
		var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
		cells.append(entrance)
	var min_cell_x := 999999
	var max_cell_x := -999999
	var min_cell_z := 999999
	var max_cell_z := -999999
	for cell in cells:
		min_cell_x = mini(min_cell_x, cell.x)
		max_cell_x = maxi(max_cell_x, cell.x)
		min_cell_z = mini(min_cell_z, cell.y)
		max_cell_z = maxi(max_cell_z, cell.y)
	var margin := PATCH_MARGIN_CELLS + 3
	min_cell_x -= margin
	max_cell_x += margin
	min_cell_z -= margin
	max_cell_z += margin
	var min_y := float(plan.get("level", 0.0)) - cell_size * 2.0
	var max_y := float(plan.get("surfaceLevel", plan.get("ceilingLevel", min_y + cell_size * 4.0))) + cell_size * 3.0
	for z in range(min_cell_z, max_cell_z + 1, maxi(1, int((max_cell_z - min_cell_z) / 8))):
		for x in range(min_cell_x, max_cell_x + 1, maxi(1, int((max_cell_x - min_cell_x) / 8))):
			var surface_y := surface_height_for_plan_point(plan, Vector2(float(x) * cell_size, float(z) * cell_size))
			max_y = maxf(max_y, surface_y + cell_size * 1.5)
	return {
		"minX": float(min_cell_x) * cell_size,
		"maxX": float(max_cell_x + 1) * cell_size,
		"minY": min_y,
		"maxY": max_y,
		"minZ": float(min_cell_z) * cell_size,
		"maxZ": float(max_cell_z + 1) * cell_size
	}

func cave_patch_cells(plan: Dictionary, _unused = null) -> Dictionary:
	var lookup := {}
	var cell_size := float(main.CELL)
	for cell in cave_surface_cut_candidate_cells(plan):
		var p00 := Vector2(float(cell.x) * cell_size, float(cell.y) * cell_size)
		var p10 := Vector2(float(cell.x + 1) * cell_size, float(cell.y) * cell_size)
		var p01 := Vector2(float(cell.x) * cell_size, float(cell.y + 1) * cell_size)
		var p11 := Vector2(float(cell.x + 1) * cell_size, float(cell.y + 1) * cell_size)
		if surface_patch_quad_cut_by_cave_pipe(plan, p00, p10, p11, p01):
			lookup[cell] = true
	return lookup

func cave_surface_cut_candidate_cells(plan: Dictionary) -> Array[Vector2i]:
	var lookup := {}
	var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
	var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
	var right: Vector2i = plan.get("right", Vector2i(1, 0))
	var interior_depth := int(plan.get("entranceOpenDepth", 7))
	var front_depth := floori(cave_mouth_front_depth(plan)) - 1
	var lateral_limit := ceili(float(plan.get("entranceMouthHalfWidth", 3.85)) + 2.0)
	for depth in range(front_depth, interior_depth + 2):
		for lateral in range(-lateral_limit, lateral_limit + 1):
			var anchor := entrance + inward * depth + right * lateral
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					lookup[anchor + Vector2i(dx, dz)] = true
	var cells: Array[Vector2i] = []
	for key in lookup.keys():
		cells.append(key)
	return cells

func cave_patch_cells_array(plan: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for key in cave_patch_cells(plan).keys():
		result.append(key)
	return result

func cave_volume_footprint_cells_array(plan: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for key in cave_volume_footprint_cells(plan).keys():
		result.append(key)
	return result

func terrain_quad_hidden_for_cell(x: int, z: int) -> bool:
	if sampler().has_method("surface_quad_hidden_for_cell3") \
		and bool(sampler().call("surface_quad_hidden_for_cell3", Vector3i(x, 0, z))):
		return true
	var cell := Vector2i(x, z)
	for brush in excavation_brushes:
		var hidden_cells = brush.get("hiddenCells", {})
		if hidden_cells is Dictionary and (hidden_cells as Dictionary).has(cell):
			return true
	return false

func terrain_material_override_for_cell(x: int, z: int) -> String:
	return ""

func ground_height_at_world(x: float, z: float, current_y: float) -> float:
	var point := Vector2(x, z)
	for record_value in cave_patch_plans.values():
		if not (record_value is Dictionary):
			continue
		var plan: Dictionary = (record_value as Dictionary).get("plan", {})
		if cave_volume_value(plan, point) > CAVE_AIR_THRESHOLD:
			continue
		var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
		var ceiling_y := cave_ceiling_y_at_surface(plan, point, floor_y + float(main.CELL) * 3.0)
		if current_y >= floor_y - float(main.CELL) * 0.85 and current_y <= ceiling_y + float(main.CELL) * 1.25:
			return floor_y
	return NAN

func is_air_at_world(world_pos: Vector3) -> bool:
	return sampler().is_air_at_world(world_pos, cave_patch_plans, excavation_brushes)

func cave_contains_world(plan: Dictionary, world_pos: Vector3) -> bool:
	return sampler().cave_contains_world(plan, world_pos)

func cave_id_at_world(world_pos: Vector3) -> String:
	for cave_id in cave_patch_plans.keys():
		var record: Dictionary = cave_patch_plans[cave_id]
		if cave_contains_world(record.get("plan", {}), world_pos):
			return String(cave_id)
	return ""

func cave_volume_value(plan: Dictionary, point: Vector2) -> float:
	return minf(float(sampler().cave_volume_value(plan, point)), cave_excavation_volume_value(plan, point))

func cave_mouth_volume_value(plan: Dictionary, point: Vector2) -> float:
	return sampler().cave_mouth_volume_value(plan, point)

func cave_mouth_depth_lateral(plan: Dictionary, point: Vector2) -> Vector2:
	return sampler().cave_mouth_depth_lateral(plan, point)

func cave_mouth_width_at_depth(plan: Dictionary, depth_cells: float) -> float:
	return sampler().cave_mouth_width_at_depth(plan, depth_cells)

func cave_mouth_front_depth(plan: Dictionary) -> float:
	return sampler().cave_mouth_front_depth(plan)

func cave_mouth_inner_half_width(mouth_width: float) -> float:
	return sampler().cave_mouth_inner_half_width(mouth_width)

func cave_floor_point(plan: Dictionary, point: Vector2) -> Vector3:
	return sampler().cave_floor_point(plan, point)

func cave_ceiling_point(plan: Dictionary, point: Vector2) -> Vector3:
	return sampler().cave_ceiling_point(plan, point)

func cave_floor_y_at_surface(plan: Dictionary, point: Vector2, fallback_level: float) -> float:
	return sampler().cave_floor_y_at_surface(plan, point, fallback_level)

func cave_ceiling_y_at_surface(plan: Dictionary, point: Vector2, fallback_level: float) -> float:
	return sampler().cave_ceiling_y_at_surface(plan, point, fallback_level)

func cave_point_is_inside(plan: Dictionary, point: Vector2) -> bool:
	return cave_volume_value(plan, point) <= CAVE_AIR_THRESHOLD

func cave_excavation_volume_value(plan: Dictionary, point: Vector2) -> float:
	var cave_id := String(plan.get("id", ""))
	var best := INF
	for brush in excavation_brushes:
		if String(brush.get("caveId", "")) != cave_id:
			continue
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius <= 0.0:
			continue
		var distance := Vector2(center.x, center.z).distance_to(point)
		best = minf(best, distance / maxf(radius, 0.001))
	return best

func surface_height_at_world(x: float, z: float) -> float:
	return sampler().surface_height_at_world(x, z, cave_patch_plans)

func surface_height_for_cell(x: int, z: int) -> float:
	return sampler().surface_height_for_cell(x, z, cave_patch_plans)

func surface_height_for_plan_point(plan: Dictionary, point: Vector2) -> float:
	return sampler().surface_height_for_plan_point(plan, point)

func cave_mound_overlay(plan: Dictionary, point: Vector2) -> float:
	return sampler().cave_mound_overlay(plan, point)

func cave_ceiling_y_without_surface_clamp(plan: Dictionary, point: Vector2) -> float:
	return sampler().cave_ceiling_y_without_surface_clamp(plan, point)

func surface_patch_quad_cut_by_cave_pipe(plan: Dictionary, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2) -> bool:
	return sampler().surface_patch_quad_cut_by_cave_pipe(plan, p00, p10, p11, p01)

func rebuild_excavation_patch(brush_id: String) -> void:
	var brush := excavation_brush_by_id(brush_id)
	if brush.is_empty():
		return
	if excavation_patch_nodes.has(brush_id):
		var old_node := excavation_patch_nodes[brush_id] as Node
		if old_node != null and is_instance_valid(old_node):
			old_node.queue_free()
		excavation_patch_nodes.erase(brush_id)
	var mesh := build_excavation_mesh(brush)
	if mesh == null:
		return
	var root := Node3D.new()
	root.name = "SubsurfaceExcavationPatch_%s" % brush_id.replace(":", "_")
	root.set_meta("generated", true)
	root.set_meta("generatedTier", "subsurface_excavation")
	root.set_meta("caveRole", "player_excavation")
	var visual := MeshInstance3D.new()
	visual.name = "ExcavationVisual"
	visual.mesh = mesh
	visual.material_override = material()
	visual.layers = CAVE_VISUAL_LAYER
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(visual)
	var body := StaticBody3D.new()
	body.name = "ExcavationBody"
	body.collision_layer = 1 | 2
	body.collision_mask = 0
	body.set_meta("kind", "subsurface")
	body.set_meta("generated", true)
	body.set_meta("generatedTier", "subsurface_excavation")
	body.set_meta("caveRole", "player_excavation_collision")
	var collision := CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	body.add_child(collision)
	root.add_child(body)
	var parent = main.get("block_root")
	if parent is Node:
		parent.add_child(root)
	elif main is Node:
		main.add_child(root)
	excavation_patch_nodes[brush_id] = root

func build_excavation_mesh(brush: Dictionary) -> ArrayMesh:
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := float(brush.get("radius", float(main.CELL) * EXCAVATION_RADIUS_CELLS))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 7
	var segments := 18
	var color := Color(0.35, 0.38, 0.35)
	for iy in range(rings):
		var v0 := -PI * 0.5 + PI * float(iy) / float(rings)
		var v1 := -PI * 0.5 + PI * float(iy + 1) / float(rings)
		for ix in range(segments):
			var u0 := TAU * float(ix) / float(segments)
			var u1 := TAU * float(ix + 1) / float(segments)
			var a := excavation_sphere_point(center, radius, u0, v0)
			var b := excavation_sphere_point(center, radius, u1, v0)
			var c := excavation_sphere_point(center, radius, u1, v1)
			var d := excavation_sphere_point(center, radius, u0, v1)
			add_quad(st, d, c, b, a, color)
	st.generate_normals()
	return st.commit()

func excavation_sphere_point(center: Vector3, radius: float, yaw: float, pitch: float) -> Vector3:
	var horizontal := cos(pitch)
	return center + Vector3(cos(yaw) * horizontal * radius, sin(pitch) * radius * 0.82, sin(yaw) * horizontal * radius)

func cave_patch_summary(cave_id: String) -> Dictionary:
	var node := cave_patch_nodes.get(cave_id, null) as Node
	var visual_count := 0
	var collision_kind := ""
	var authority := ""
	if node != null and is_instance_valid(node):
		authority = String(node.get_meta("geometryAuthority", ""))
		for child in node.get_children():
			if child is MeshInstance3D:
				visual_count += 1
			if child is StaticBody3D:
				collision_kind = String(child.get_meta("kind", ""))
	return {
		"id": cave_id,
		"hasNode": node != null and is_instance_valid(node),
		"hiddenCellCount": 0,
		"visualMeshCount": visual_count,
		"collisionKind": collision_kind,
		"sharedCollision": collision_kind == "subsurface",
		"geometryAuthority": authority
	}

func cave_roof_integrity_summary(plan: Dictionary) -> Dictionary:
	if main == null or plan.is_empty():
		return { "passed": false, "reason": "missing main or plan" }
	var cell_size := float(main.CELL)
	var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
	var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
	var right: Vector2i = plan.get("right", Vector2i(1, 0))
	var interior_depth := int(plan.get("entranceOpenDepth", 7))
	var sampled := 0
	var thin_cover_samples := 0
	var top_hole_samples := 0
	var mound_overlay_samples := 0
	var min_cover := INF
	var worst_cell := Vector2i.ZERO
	var required_cover := cell_size * 0.62
	for depth in range(0, int(plan.get("pathLength", interior_depth + 8)) + 4):
		var half_width := maxf(1.35, cave_mouth_width_at_depth(plan, float(depth)))
		if half_width <= 0.0:
			half_width = 3.0
		var lateral_limit := ceili(half_width + 1.5)
		for lateral in range(-lateral_limit, lateral_limit + 1):
			var cell := entrance + inward * depth + right * lateral
			var point := cell_world2(cell)
			if cave_volume_value(plan, point) > 1.05:
				continue
			sampled += 1
			var cover := surface_height_for_plan_point(plan, point) - cave_ceiling_y_at_surface(plan, point, 0.0)
			if cover < min_cover:
				min_cover = cover
				worst_cell = cell
			if depth > interior_depth + 1 and cover < required_cover:
				thin_cover_samples += 1
			if depth > interior_depth + 1 and surface_patch_quad_cut_by_cave_pipe(plan, point, point, point, point):
				top_hole_samples += 1
			if cave_mound_overlay(plan, point) > cell_size * 0.10:
				mound_overlay_samples += 1
	var needs_mound_overlay := bool(plan.get("moundBacked", false))
	var passed := sampled > 0 and thin_cover_samples == 0 and top_hole_samples == 0 and (not needs_mound_overlay or mound_overlay_samples > 0)
	return {
		"passed": passed,
		"sampledRoofCells": sampled,
		"coverSamples": sampled,
		"cutTopQuads": top_hole_samples,
		"thinCoverSamples": thin_cover_samples,
		"moundOverlaySamples": mound_overlay_samples,
		"requiredCover": snappedf(required_cover, 0.001),
		"minCover": snappedf(0.0 if min_cover == INF else min_cover, 0.001),
		"worstCoverCell": { "x": worst_cell.x, "z": worst_cell.y },
		"worstCoverDepth": 0,
		"moundBacked": needs_mound_overlay
	}

func cave_wall_integrity_summary(plan: Dictionary) -> Dictionary:
	var nodes_value = plan.get("caveNodes", [])
	var edges_value = plan.get("caveEdges", [])
	var sampled_pairs := 0
	var thin_pairs := 0
	if not (nodes_value is Array) or not (edges_value is Array):
		return { "sampledPairs": 0, "thinPairs": 0, "passed": false }
	for i in range(nodes_value.size()):
		var a = nodes_value[i]
		if not (a is Dictionary):
			continue
		var a_id := String(a.get("id", ""))
		var a_cell: Vector2i = a.get("cell", Vector2i.ZERO)
		var a_radius := float(a.get("radius", 2.0))
		for j in range(i + 1, nodes_value.size()):
			var b = nodes_value[j]
			if not (b is Dictionary):
				continue
			var b_id := String(b.get("id", ""))
			if cave_nodes_directly_connected(edges_value, a_id, b_id):
				continue
			var b_cell: Vector2i = b.get("cell", Vector2i.ZERO)
			var b_radius := float(b.get("radius", 2.0))
			var gap := Vector2(float(a_cell.x - b_cell.x), float(a_cell.y - b_cell.y)).length() - a_radius - b_radius
			sampled_pairs += 1
			if gap < MIN_SEPARATOR_CELLS:
				thin_pairs += 1
	return {
		"sampledPairs": sampled_pairs,
		"thinPairs": thin_pairs,
		"passed": sampled_pairs > 0 and thin_pairs == 0
	}

func cave_nodes_directly_connected(edges: Array, a_id: String, b_id: String) -> bool:
	for edge_value in edges:
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		if (from_id == a_id and to_id == b_id) or (from_id == b_id and to_id == a_id):
			return true
	return false

func material_near_surface(world_pos: Vector3) -> String:
	var cell2 := Vector2i(main.world_to_cell(world_pos.x), main.world_to_cell(world_pos.z))
	return top_material_for_biome(String(main.call("biome_at_cell", cell2.x, cell2.y)))

func top_material_for_biome(biome: String) -> String:
	if biome == "beach" or biome == "desert":
		return "sand"
	if biome == "swamp":
		return "mud"
	if biome == "snow":
		return "snow"
	if biome == "alpine" or biome == "tundra":
		return "stone"
	return "dirt"

func subsoil_material_for_biome(biome: String) -> String:
	if biome == "beach" or biome == "desert":
		return "sand"
	if biome == "swamp":
		return "mud"
	if biome == "snow":
		return "snow"
	return "dirt"

func ore_material_at(cell: Vector3i, depth: float) -> String:
	var depth_cells := depth / maxf(0.001, float(main.CELL))
	var copper_noise: float = float(main.hash01("subsurface-copper:%s:%d,%d,%d" % [String(main.get("seed_text")), cell.x / 3, cell.y / 3, cell.z / 3]))
	if depth_cells >= 8.0 and copper_noise > 0.985:
		return "copperOre"
	var iron_noise: float = float(main.hash01("subsurface-iron:%s:%d,%d,%d" % [String(main.get("seed_text")), cell.x / 4, cell.y / 4, cell.z / 4]))
	if depth_cells >= 15.0 and iron_noise > 0.992:
		return "ironOre"
	return ""

func surface_color_for_cell(cell: Vector2i) -> Color:
	var biome := String(main.call("biome_at_cell", cell.x, cell.y)) if main.has_method("biome_at_cell") else "plains"
	if biome == "beach" or biome == "desert":
		return Color(0.62, 0.57, 0.42)
	if biome == "swamp":
		return Color(0.30, 0.38, 0.29)
	if biome == "snow":
		return Color(0.77, 0.82, 0.82)
	if biome == "alpine" or biome == "tundra":
		return Color(0.38, 0.41, 0.39)
	return Color(0.37, 0.47, 0.34)

func hit_sample_position(hit: Dictionary) -> Vector3:
	var position: Vector3 = hit.get("position", Vector3.ZERO)
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	return position - normal * float(main.CELL) * 0.35

func world_to_cell3(position: Vector3) -> Vector3i:
	var cell_size := float(main.CELL)
	return Vector3i(roundi(position.x / cell_size), roundi(position.y / cell_size), roundi(position.z / cell_size))

func affected_surface_cells_for_brush(brush: Dictionary) -> Array[Vector2i]:
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := float(brush.get("radius", float(main.CELL)))
	var cell_size := float(main.CELL)
	var center_cell := Vector2i(roundi(center.x / cell_size), roundi(center.z / cell_size))
	var cell_radius := ceili(radius / cell_size) + 2
	var cells: Array[Vector2i] = []
	for dz in range(-cell_radius, cell_radius + 1):
		for dx in range(-cell_radius, cell_radius + 1):
			if Vector2(float(dx), float(dz)).length() <= float(cell_radius):
				cells.append(center_cell + Vector2i(dx, dz))
	return cells

func mark_excavation_hidden_cells(brush: Dictionary) -> void:
	var hidden := {}
	for cell in affected_surface_cells_for_brush(brush):
		hidden[cell] = true
	brush["hiddenCells"] = hidden

func excavation_brush_by_id(brush_id: String) -> Dictionary:
	for brush in excavation_brushes:
		if String(brush.get("id", "")) == brush_id:
			return brush
	return {}

func cave_relevant_cells(plan: Dictionary, include_approach := true) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if include_approach:
		for cell_value in plan.get("approachCells", []):
			if cell_value is Vector2i:
				result.append(cell_value)
	for key in ["pathCells", "chamberCells"]:
		for cell_value in plan.get(key, []):
			if cell_value is Vector2i:
				result.append(cell_value)
	for node_value in plan.get("caveNodes", []):
		if node_value is Dictionary:
			result.append((node_value as Dictionary).get("cell", Vector2i.ZERO))
	return result

func cell_world2(cell: Vector2i) -> Vector2:
	var cell_size := float(main.CELL)
	return Vector2(float(cell.x) * cell_size, float(cell.y) * cell_size)

func stable01(plan: Dictionary, salt: String, x: int, z: int) -> float:
	var text := "%s:%s:%s:%d,%d" % [String(main.get("seed_text")), String(plan.get("id", "cave")), salt, x, z]
	var h := int(main.hash_string(text)) if main != null and main.has_method("hash_string") else hash(text)
	return float(abs(h) % 100000) / 99999.0

func stable_signed(plan: Dictionary, salt: String, x: int, z: int) -> float:
	return stable01(plan, salt, x, z) * 2.0 - 1.0

func material() -> StandardMaterial3D:
	if subsurface_material != null:
		return subsurface_material
	subsurface_material = StandardMaterial3D.new()
	subsurface_material.vertex_color_use_as_albedo = true
	subsurface_material.albedo_color = Color(0.38, 0.41, 0.38)
	subsurface_material.roughness = 0.96
	subsurface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	subsurface_material.set("disable_ambient_light", true)
	return subsurface_material

func add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	add_triangle(st, a, b, c, color)
	add_triangle(st, a, c, d, color)

func add_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	st.set_color(color)
	st.add_vertex(a)
	st.set_color(color)
	st.add_vertex(b)
	st.set_color(color)
	st.add_vertex(c)

func cave_perf_log(label: String, data: Dictionary = {}) -> void:
	if OS.get_environment("VOXEL_CAVE_PERF_LOG").strip_edges() != "1":
		return
	var payload := data.duplicate()
	payload["label"] = label
	payload["ticksMsec"] = Time.get_ticks_msec()
	print("[cave-perf] %s" % JSON.stringify(payload))
	var path := OS.get_environment("VOXEL_CAVE_PERF_REPORT").strip_edges()
	if path == "":
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify(payload))
	file.close()
