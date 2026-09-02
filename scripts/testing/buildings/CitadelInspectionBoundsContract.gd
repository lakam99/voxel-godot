extends SceneTree

## Synthetic CPU inspector geometry/protocol controls. No MultiMesh dummy
## transform is accepted as scene visibility and no GPU acceptance is claimed.
const Inspector = preload("res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd")
class Probe extends "res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd":
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass

var _checks: Array = []
func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, passed: bool) -> void:
	_checks.append({"name": name, "passed": passed})

func _run() -> void:
	var path := OS.get_environment("VOXEL_INSPECTION_BOUNDS_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	_check("plain_buffer_layout", Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_3D, 2, false, false, 24))
	_check("color_and_custom_layout", Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_3D, 2, true, true, 40))
	for size in [0, 23, 25, 39, 41]:
		_check("unavailable_or_wrong_stride_%d" % size, not Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_3D, 2, true, true, size))
	_check("wrong_transform_format", not Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_2D, 2, false, false, 24))
	_check("empty_instance_count", not Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_3D, 0, false, false, 0))
	_check("negative_instance_count", not Inspector._instance_buffer_shape_valid(MultiMesh.TRANSFORM_3D, -1, false, false, -12))
	var plane := AABB(Vector3(-1, 0, -1), Vector3(2, 0, 2))
	_check("zero_thickness_plane_retained", Inspector._finite_inspection_bounds(plane))
	_check("all_zero_bounds_rejected", not Inspector._finite_inspection_bounds(AABB()))
	_check("negative_extent_rejected", not Inspector._finite_inspection_bounds(AABB(Vector3.ZERO, Vector3(-1, 1, 1))))
	_check("nan_bounds_rejected", not Inspector._finite_inspection_bounds(AABB(Vector3(NAN, 0, 0), Vector3.ONE)))
	var extreme_a := AABB(Vector3(-3.0e38, 0, 0), Vector3.ONE)
	var extreme_b := AABB(Vector3(3.0e38, 0, 0), Vector3.ONE)
	_check("merge_overflow_rejected", not Inspector._finite_inspection_bounds(extreme_a.merge(extreme_b)))
	var fixture := Probe.new()
	root.add_child(fixture)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2, 4, 8)
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.transform = Transform3D(Basis(Vector3(0, 0, -2), Vector3(0, 1, 0), Vector3(0.5, 0, 0)), Vector3(8, 16, 32))
	fixture.add_child(part)
	_check("real_mesh_cpu_index_ready", await fixture._index_scene())
	_check("exact_one_mesh_indexed", fixture._visuals.size() == 1 and fixture._visuals[0].count == 1)
	if fixture._visuals.size() == 1:
		var actual: AABB = fixture._visuals[0].bounds
		_check("actual_composed_transform_bounds", actual == part.global_transform * mesh.get_aabb())
		for corner in range(8):
			var point: Vector3 = part.global_transform * mesh.get_aabb().get_endpoint(corner)
			_check("encloses_actual_mesh_corner_%d" % corner, Inspector._inside_closed(actual, point))
	fixture.free()
	var passed: bool = _checks.all(func(row): return row.passed)
	var report := {"passed": passed, "checks": _checks, "evidenceLevel": "synthetic_CPU_inspection_bounds_and_buffer_layout_contract",
		"inspectorSha256": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelChimneyRecipeVisual.gd"),
		"doesNotProve": "No GPU readback, full-scene visibility, screenshots, live traversal or physical gate acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if passed else 2)
