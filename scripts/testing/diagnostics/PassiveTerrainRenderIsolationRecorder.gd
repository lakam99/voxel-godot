extends Node

const REPORT_PATH := "res://artifacts/vox43-root-cause/render-isolation-report.json"
const CAPTURE_DIR := "res://artifacts/vox43-root-cause/captures"
const YAW_DEGREES := [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]
const TARGET_CHUNK := Vector2i(11, 0)
const CHUNK_SIZE := 28
const CELL := 1.35

var main: Node3D
var running := false

func _ready() -> void:
	main = get_parent() as Node3D
	set_process(true)

func _process(_delta: float) -> void:
	if running or not world_is_ready():
		return
	running = true
	call_deferred("run_isolation_capture")

func world_is_ready() -> bool:
	if main == null or main.get("player") == null:
		return false
	var chunks_value = main.get("chunks")
	if not (chunks_value is Dictionary) or (chunks_value as Dictionary).size() < 49:
		return false
	var player = main.get("player") as CharacterBody3D
	return player != null and player.camera != null and player.camera.current

func run_isolation_capture() -> void:
	for _frame in range(30):
		await get_tree().process_frame
	var player = main.get("player") as CharacterBody3D
	var origin_position: Vector3 = player.global_position
	var target_cell := Vector2i(TARGET_CHUNK.x * CHUNK_SIZE + CHUNK_SIZE / 2, TARGET_CHUNK.y * CHUNK_SIZE + CHUNK_SIZE / 2)
	var target_surface_y := float(main.call("chunk_bound_surface_y_at_cell", Vector3i(target_cell.x, 0, target_cell.y)))
	player.global_position = Vector3(float(target_cell.x) * CELL, target_surface_y + CELL * 1.8, float(target_cell.y) * CELL)
	player.velocity = Vector3.ZERO
	if main.has_method("update_chunks"):
		main.call("update_chunks", false)
	var fluid_wait_frames := 0
	while fluid_wait_frames < 2400 and terrain_fluid_nodes().is_empty():
		fluid_wait_frames += 1
		await get_tree().process_frame
	var source_camera: Camera3D = player.camera
	var diagnostic_camera := Camera3D.new()
	diagnostic_camera.name = "Vox43RenderIsolationCamera"
	diagnostic_camera.fov = source_camera.fov
	diagnostic_camera.global_position = source_camera.global_position
	add_child(diagnostic_camera)
	diagnostic_camera.current = true
	var fluid_nodes := terrain_fluid_nodes()
	var global_water = main.get_node_or_null("Water") as MeshInstance3D
	var fluid_summaries := []
	for fluid_node in fluid_nodes:
		fluid_summaries.append(fluid_node_summary(fluid_node))
	var report := {
		"schemaVersion": 1,
		"kind": "passive_real_boot_terrain_render_isolation",
		"diagnosticOnly": true,
		"gameplayFlags": gameplay_flag_snapshot(),
		"seed": String(main.get("seed_text")),
		"diagnosticPlacement": {
			"originPosition": vector3_json(origin_position),
			"targetChunk": [TARGET_CHUNK.x, TARGET_CHUNK.y],
			"targetCell": [target_cell.x, target_cell.y],
			"targetSurfaceY": snappedf(target_surface_y, 0.001),
			"fluidWaitFrames": fluid_wait_frames
		},
		"playerPosition": vector3_json(player.global_position),
		"cameraPosition": vector3_json(source_camera.global_position),
		"chunkCount": (main.get("chunks") as Dictionary).size(),
		"terrainFluidNodes": fluid_summaries,
		"globalWater": mesh_instance_summary(global_water),
		"captures": []
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CAPTURE_DIR))
	for yaw_degrees in YAW_DEGREES:
		diagnostic_camera.rotation = Vector3(deg_to_rad(-12.0), deg_to_rad(float(yaw_degrees)), 0.0)
		set_nodes_visible(fluid_nodes, true)
		set_node_visible(global_water, true)
		report["captures"].append(await capture_variant(diagnostic_camera, yaw_degrees, "all_visible"))
		set_nodes_visible(fluid_nodes, false)
		report["captures"].append(await capture_variant(diagnostic_camera, yaw_degrees, "chunk_fluid_hidden"))
		set_nodes_visible(fluid_nodes, true)
		set_node_visible(global_water, false)
		report["captures"].append(await capture_variant(diagnostic_camera, yaw_degrees, "global_water_hidden"))
		set_nodes_visible(fluid_nodes, false)
		report["captures"].append(await capture_variant(diagnostic_camera, yaw_degrees, "all_water_hidden"))
	set_nodes_visible(fluid_nodes, true)
	set_node_visible(global_water, true)
	source_camera.current = true
	diagnostic_camera.queue_free()
	write_report(report)

func terrain_fluid_nodes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var chunks: Dictionary = main.get("chunks")
	for chunk_value in chunks.values():
		var chunk := chunk_value as Node3D
		if chunk == null:
			continue
		var fluid := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
		if fluid != null and fluid.mesh != null and fluid.mesh.get_surface_count() > 0:
			result.append(fluid)
	return result

func fluid_node_summary(node: MeshInstance3D) -> Dictionary:
	return mesh_instance_summary(node)

func mesh_instance_summary(node: MeshInstance3D) -> Dictionary:
	if node == null:
		return { "present": false }
	var mesh := node.mesh
	var result := {
		"present": mesh != null,
		"name": node.name,
		"path": String(node.get_path()),
		"position": vector3_json(node.global_position),
		"chunk": encode_value(node.get_meta("chunk", null)),
		"surfaceCount": mesh.get_surface_count() if mesh != null else 0,
		"aabb": aabb_json(mesh.get_aabb()) if mesh != null else {},
		"globalAabb": aabb_json(node.global_transform * mesh.get_aabb()) if mesh != null else {},
		"meshMetadata": mesh_metadata(mesh),
		"surfaces": []
	}
	if mesh == null:
		return result
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var alpha_min := 1.0
		var alpha_max := 1.0
		if not colors.is_empty():
			alpha_min = INF
			alpha_max = -INF
			for color in colors:
				alpha_min = minf(alpha_min, color.a)
				alpha_max = maxf(alpha_max, color.a)
		var material := mesh.surface_get_material(surface_index)
		result["surfaces"].append({
			"surface": surface_index,
			"vertexCount": vertices.size(),
			"vertexAlphaMin": snappedf(alpha_min, 0.001),
			"vertexAlphaMax": snappedf(alpha_max, 0.001),
			"material": material_summary(material)
		})
	return result

func mesh_metadata(mesh: Mesh) -> Dictionary:
	var result := {}
	if mesh == null:
		return result
	for key in mesh.get_meta_list():
		result[String(key)] = encode_value(mesh.get_meta(String(key)))
	return result

func material_summary(material: Material) -> Dictionary:
	if material == null:
		return { "present": false }
	var result := {
		"present": true,
		"class": material.get_class(),
		"resourcePath": material.resource_path
	}
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		result["shaderPath"] = shader_material.shader.resource_path if shader_material.shader != null else ""
		result["alphaBase"] = encode_value(shader_material.get_shader_parameter("alpha_base"))
	elif material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		result["transparency"] = base.transparency
		result["albedoAlpha"] = snappedf(base.albedo_color.a, 0.001)
	return result

func capture_variant(camera: Camera3D, yaw_degrees: float, variant: String) -> Dictionary:
	for _frame in range(3):
		await RenderingServer.frame_post_draw
	var filename := "yaw_%03d_%s.png" % [roundi(yaw_degrees), variant]
	var path := CAPTURE_DIR.path_join(filename)
	var image := camera.get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	return {
		"yawDegrees": yaw_degrees,
		"pitchDegrees": -12.0,
		"variant": variant,
		"path": ProjectSettings.globalize_path(path),
		"saved": error == OK
	}

func set_nodes_visible(nodes: Array[MeshInstance3D], visible_value: bool) -> void:
	for node in nodes:
		set_node_visible(node, visible_value)

func set_node_visible(node: MeshInstance3D, visible_value: bool) -> void:
	if node != null:
		node.visible = visible_value

func gameplay_flag_snapshot() -> Dictionary:
	return {
		"VOXEL_PLAYTEST": OS.get_environment("VOXEL_PLAYTEST"),
		"VOXEL_TEST_SEED": OS.get_environment("VOXEL_TEST_SEED"),
		"VOXEL_SAVE_PATH_OVERRIDE": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE"),
		"VOXEL_GOD_MODE": OS.get_environment("VOXEL_GOD_MODE")
	}

func write_report(report: Dictionary) -> void:
	var path := ProjectSettings.globalize_path(REPORT_PATH)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))

func vector3_json(value: Vector3) -> Dictionary:
	return {
		"x": snappedf(value.x, 0.001),
		"y": snappedf(value.y, 0.001),
		"z": snappedf(value.z, 0.001)
	}

func aabb_json(value: AABB) -> Dictionary:
	return {
		"position": vector3_json(value.position),
		"size": vector3_json(value.size),
		"end": vector3_json(value.end)
	}

func encode_value(value):
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector3:
		return vector3_json(value)
	if value is PackedStringArray:
		return Array(value)
	return value
