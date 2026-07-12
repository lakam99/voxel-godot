extends Node3D

const CELL_SIZE := 1.35
const TIMEOUT_SECONDS := 45.0

var report_path := ""
var screenshot_path := ""
var started_msec := 0
var terrain: Node3D
var viewer: Node3D
var camera: Camera3D

func _ready() -> void:
	report_path = OS.get_environment("VOXEL_TOOLS_SMOKE_REPORT").strip_edges()
	screenshot_path = OS.get_environment("VOXEL_TOOLS_SMOKE_SCREENSHOT").strip_edges()
	started_msec = Time.get_ticks_msec()
	call_deferred("run_smoke")

func run_smoke() -> void:
	var result := build_runtime()
	if not bool(result.get("ok", false)):
		finish(false, String(result.get("reason", "runtime_setup_failed")), {})
		return
	while elapsed_seconds() < TIMEOUT_SECONDS:
		await get_tree().physics_frame
		await get_tree().process_frame
		var collision := downward_collision()
		if bool(collision.get("hit", false)):
			await capture_frame()
			finish(true, "voxel_mesh_and_collision_published", {
				"collision": collision,
				"terrainScale": vector3_json(terrain.scale),
				"packaging": dependency_packaging_summary(),
				"statistics": terrain.call("get_statistics") if terrain.has_method("get_statistics") else {},
				"terrainChildCount": terrain.get_child_count()
			})
			return
	finish(false, "collision_publish_timeout", {
		"lastCollision": downward_collision(),
		"statistics": terrain.call("get_statistics") if terrain != null and terrain.has_method("get_statistics") else {}
	})

func build_runtime() -> Dictionary:
	var packaging := dependency_packaging_summary()
	if not bool(packaging.get("complete", false)):
		return {"ok": false, "reason": "dependency_packaging_incomplete", "packaging": packaging}
	for required_class in ["VoxelTerrain", "VoxelViewer", "VoxelMesherTransvoxel", "VoxelGeneratorFlat", "VoxelBuffer"]:
		if not ClassDB.class_exists(required_class):
			return {"ok": false, "reason": "missing_class:%s" % required_class}
	terrain = ClassDB.instantiate("VoxelTerrain") as Node3D
	viewer = ClassDB.instantiate("VoxelViewer") as Node3D
	var mesher = ClassDB.instantiate("VoxelMesherTransvoxel")
	var generator = ClassDB.instantiate("VoxelGeneratorFlat")
	if terrain == null or viewer == null or mesher == null or generator == null:
		return {"ok": false, "reason": "class_instantiation_failed"}

	var sdf_channel := ClassDB.class_get_integer_constant("VoxelBuffer", "CHANNEL_SDF")
	generator.call("set_channel", sdf_channel)
	generator.call("set_height", 0.0)
	mesher.call("set_transitions_enabled", false)
	terrain.call("set_generator", generator)
	terrain.call("set_mesher", mesher)
	terrain.call("set_generate_collisions", true)
	terrain.call("set_mesh_block_size", 16)
	terrain.call("set_max_view_distance", 96)
	terrain.scale = Vector3.ONE * CELL_SIZE
	terrain.name = "VoxelToolsTerrain"
	add_child(terrain)

	viewer.call("set_view_distance", 80)
	viewer.call("set_requires_visuals", true)
	viewer.call("set_requires_collisions", true)
	viewer.position = Vector3(0.0, 9.0, 0.0)
	viewer.name = "VoxelToolsViewer"
	add_child(viewer)

	camera = Camera3D.new()
	camera.current = true
	camera.position = Vector3(19.0, 15.0, 19.0)
	add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.light_energy = 1.15
	light.shadow_enabled = true
	add_child(light)

	var environment := WorldEnvironment.new()
	var environment_resource := Environment.new()
	environment_resource.background_mode = Environment.BG_COLOR
	environment_resource.background_color = Color(0.62, 0.80, 0.86)
	environment_resource.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment_resource.ambient_light_color = Color(0.78, 0.82, 0.76)
	environment_resource.ambient_light_energy = 0.65
	environment.environment = environment_resource
	add_child(environment)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.28, 0.53, 0.24)
	material.roughness = 0.92
	terrain.call("set_material_override", material)
	return {"ok": true}

func dependency_packaging_summary() -> Dictionary:
	var descriptor_path := ProjectSettings.globalize_path("res://addons/zylann.voxel/voxel.gdextension")
	var editor_path := ProjectSettings.globalize_path("res://addons/zylann.voxel/bin/libvoxel.windows.editor.x86_64.dll")
	var release_path := ProjectSettings.globalize_path("res://addons/zylann.voxel/bin/libvoxel.windows.template_release.x86_64.dll")
	var license_path := ProjectSettings.globalize_path("res://addons/zylann.voxel/LICENSE.md")
	var summary := {
		"descriptor": FileAccess.file_exists(descriptor_path),
		"windowsEditorLibrary": FileAccess.file_exists(editor_path),
		"windowsReleaseLibrary": FileAccess.file_exists(release_path),
		"license": FileAccess.file_exists(license_path)
	}
	summary["complete"] = bool(summary.descriptor) and bool(summary.windowsEditorLibrary) and bool(summary.windowsReleaseLibrary) and bool(summary.license)
	return summary

func downward_collision() -> Dictionary:
	if get_world_3d() == null:
		return {"hit": false, "reason": "world_missing"}
	var query := PhysicsRayQueryParameters3D.create(Vector3(0.0, 20.0, 0.0), Vector3(0.0, -20.0, 0.0))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return {
		"hit": not hit.is_empty(),
		"colliderClass": hit.get("collider").get_class() if hit.get("collider") is Object else "",
		"position": vector3_json(hit.get("position", Vector3.ZERO)),
		"normal": vector3_json(hit.get("normal", Vector3.ZERO))
	}

func capture_frame() -> void:
	if screenshot_path == "":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(screenshot_path.get_base_dir())
	image.save_png(screenshot_path)

func finish(passed: bool, reason: String, details: Dictionary) -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": "voxel_tools_backend_smoke",
		"evidenceLevel": "headed-backend-smoke",
		"passed": passed,
		"reason": reason,
		"elapsedSeconds": elapsed_seconds(),
		"godotVersion": Engine.get_version_info(),
		"dependency": {
			"project": "Zylann/godot_voxel",
			"tag": "v1.6x",
			"sha256": "dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a"
		},
		"details": details,
		"screenshotPath": screenshot_path
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
	get_tree().quit(0 if passed else 1)

func elapsed_seconds() -> float:
	return float(Time.get_ticks_msec() - started_msec) / 1000.0

func vector3_json(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}
