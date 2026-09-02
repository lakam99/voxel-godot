extends SceneTree

## Synthetic inspector-state protocol only. No recipe publication/camera/GPU
## acceptance. Uses real resources to test lighting restoration and cut-instance
## identity without adding the full visual fixture to the scene tree.
const Visual = preload("res://scripts/testing/buildings/CitadelFacadeRecipeVisual.gd")
const Ray = preload("res://scripts/testing/buildings/CitadelPublishedMeshRay.gd")
var _checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, passed: bool) -> void:
	_checks.append({"name": name, "passed": passed})

func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_VISUAL_STATE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or path.get_extension() != "json" or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var fixture = Visual.new()
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.52
	fixture.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.48
	fixture.add_child(fill)
	var lantern := OmniLight3D.new()
	lantern.light_energy = 1.95
	var lantern_before := lantern.light_energy
	fixture.add_child(lantern)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.ambient_light_energy = 1.18
	world.environment.background_color = Color(0.265, 0.295, 0.305)
	world.environment.fog_light_energy = 0.42
	fixture.add_child(world)
	fixture._scene_nodes = [sun, fill, lantern]
	var before: Array = fixture._lighting_snapshot()
	fixture._set_night(true)
	var night_diagnostic := {"sun": sun.light_energy, "expectedSun": fixture.NightStyle.sun_min_energy,
		"ambient": world.environment.ambient_light_energy, "expectedAmbient": fixture.NightStyle.ambient_min_energy,
		"fog": world.environment.fog_light_energy, "expectedFog": fixture.NightStyle.fog_light_energy_night,
		"ambientColor": world.environment.ambient_light_color, "expectedAmbientColor": fixture.NightStyle.ambient_color(0.0, 0.0),
		"background": world.environment.background_color, "expectedBackground": fixture.NightStyle.sky_horizon_color(0.0, 0.0, 0.0)}
	_check("production_night_minima_applied", fixture._night_values_applied())
	_check("night_changes_real_state", before != fixture._lighting_snapshot())
	_check("recipe_lantern_energy_unchanged", lantern.light_energy == lantern_before)
	fixture._set_night(false)
	_check("exact_day_restoration", before == fixture._lighting_snapshot())
	fixture._set_night(false)
	_check("repeat_restore_is_noop", before == fixture._lighting_snapshot())
	fixture._set_night(true)
	sun.light_energy = 0.5
	_check("wrong_night_value_rejected", not fixture._night_values_applied())
	fixture._set_night(false)
	_check("failure_path_restores_original_not_corrupted_night", before == fixture._lighting_snapshot())
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	batch.instance_count = 1
	var pose := Transform3D(Basis.from_scale(Vector3(2, 3, 4)), Vector3(5, 6, 7))
	batch.set_instance_transform(0, pose)
	var node := MultiMeshInstance3D.new()
	node.multimesh = batch
	root.add_child(node)
	fixture._cut_meshes = {mesh.get_instance_id(): {"mesh": mesh, "prepared": Ray.prepare(mesh), "nodes": [node], "instances": [{"node": node, "index": 0, "transform": pose}]}}
	var instance_diagnostic := {"meshPrepared": Ray.prepare(mesh), "meshIdentityMatches": Ray.identity_matches(mesh, fixture._cut_meshes[mesh.get_instance_id()].prepared),
		"expectedPose": pose, "actualInstancePose": batch.get_instance_transform(0), "nodeGlobalPose": node.global_transform, "bufferSize": batch.buffer.size()}
	instance_diagnostic.meshPrepared.erase("localtriangles")
	_check("exact_published_cut_instance_accepted", fixture._cut_meshes_exact())
	batch.set_instance_transform(0, Transform3D.IDENTITY)
	_check("moved_instance_rejected", not fixture._cut_meshes_exact())
	batch.set_instance_transform(0, pose)
	_check("restored_instance_accepted", fixture._cut_meshes_exact())
	batch.instance_count = 2
	_check("duplicate_instance_rejected", not fixture._cut_meshes_exact())
	node.free()
	_check("removed_instance_rejected", not fixture._cut_meshes_exact())
	fixture._cut_meshes.clear()
	fixture.free()
	var passed: bool = _checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": _checks, "evidenceLevel": "synthetic_visual_state_protocol",
		"nightDiagnostic": Visual._json(night_diagnostic), "instanceDiagnostic": Visual._json(instance_diagnostic),
		"codeIdentity": Visual._visual_code_identity(), "doesNotProve": "No source publication, camera visibility, headed readiness, GPU image or gameplay acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if passed else 2)
