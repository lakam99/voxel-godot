extends SceneTree

## Synthetic actual ArrayMesh arrays, no publication, renderer or GPU claim.
const Ray = preload("res://scripts/testing/buildings/CitadelPublishedMeshRay.gd")
var checks: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks.append({"label": label, "passed": passed})

func _mesh(vertices: PackedVector3Array, indices: PackedInt32Array = PackedInt32Array(), primitive: int = Mesh.PRIMITIVE_TRIANGLES) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	if not indices.is_empty(): arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(primitive, arrays)
	return mesh

func _run() -> void:
	var output: String = OS.get_environment("VOXEL_PUBLISHED_MESH_RAY_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var vertices := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var mesh: ArrayMesh = _mesh(vertices)
	var prepared: Dictionary = Ray.prepare(mesh)
	_check("actual_arraymesh_prepared", prepared.get("valid", false))
	if prepared.get("valid", false): _queries(mesh, prepared, vertices)
	_check("null_mesh_rejected", not Ray.prepare(null).valid)
	_check("empty_mesh_rejected", not Ray.prepare(ArrayMesh.new()).valid)
	_check("zero_prepare_budget_rejected", not Ray.prepare(mesh, 0).valid)
	var lines: ArrayMesh = _mesh(PackedVector3Array([Vector3.ZERO, Vector3.ONE]), PackedInt32Array(), Mesh.PRIMITIVE_LINES)
	_check("nontriangles_rejected", not Ray.prepare(lines).valid)
	var flat: ArrayMesh = _mesh(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.RIGHT * 2]))
	_check("degenerate_rejected", not Ray.prepare(flat).valid)
	# Malformed captured data tested at the pure ray boundary, without asking
	# Godot to construct illegal surfaces and polluting the main runner log.
	_check("malformed_prepared_rejected", not Ray.intersect({"valid": true}, Transform3D.IDENTITY, Vector3.BACK, Vector3.FORWARD, 1).valid)
	var passed: bool = checks.all(func(row): return row.passed)
	var report: Dictionary = {"passed": passed, "checkCount": checks.size(), "checks": checks,
		"helperSha256": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelPublishedMeshRay.gd"), "evidenceLevel": "synthetic_ArrayMesh_CPU_triangle_segment_contract",
		"doesNotProve": "No GPU, actual scene occlusion, visual readiness or gameplay acceptance."}
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if passed and written else 2)

func _queries(mesh: ArrayMesh, prepared: Dictionary, vertices: PackedVector3Array) -> void:
	var from := Vector3(0.25, 0.25, 1)
	var to := Vector3(0.25, 0.25, -1)
	var solid: Dictionary = Ray.intersect(prepared, Transform3D.IDENTITY, from, to, 1)
	_check("solid_hit", solid.valid and solid.hit and solid.point == Vector3(0.25, 0.25, 0) and solid.tests == 1 and solid.t == 0.5)
	var void_hit: Dictionary = Ray.intersect(prepared, Transform3D.IDENTITY, Vector3(0.75, 0.75, 1), Vector3(0.75, 0.75, -1), 1)
	_check("inside_aabb_outside_triangle_clear", void_hit.valid and not void_hit.hit and void_hit.tests == 1)
	var reverse: Dictionary = Ray.intersect(prepared, Transform3D.IDENTITY, to, from, 1)
	_check("double_sided", reverse.valid and reverse.hit and reverse.point == solid.point)
	var limited: Dictionary = Ray.intersect(prepared, Transform3D.IDENTITY, from, to, 0)
	_check("budget_reject_before_any_test", not limited.valid and limited.tests == 0)
	_check("zero_segment_rejected", not Ray.intersect(prepared, Transform3D.IDENTITY, from, from, 1).valid)
	_check("nonfinite_segment_rejected", not Ray.intersect(prepared, Transform3D.IDENTITY, Vector3(NAN, 0, 0), to, 1).valid)
	var singular := Transform3D(Basis.from_scale(Vector3(1, 0, 1)), Vector3.ZERO)
	_check("singular_transform_rejected", not Ray.intersect(prepared, singular, from, to, 1).valid)
	var nonfinite := Transform3D.IDENTITY
	nonfinite.origin.x = INF
	_check("nonfinite_transform_rejected", not Ray.intersect(prepared, nonfinite, from, to, 1).valid)
	# Exact quarter-turn basis avoids a synthetic trigonometric approximation.
	var pose := Transform3D(Basis(Vector3(0, 0, -2), Vector3(0, 3, 0), Vector3(0.5, 0, 0)), Vector3(7, 4, -3))
	var transformed: Dictionary = Ray.intersect(prepared, pose, pose * from, pose * to, 1)
	_check("rotated_nonuniform_world_hit", transformed.valid and transformed.hit and transformed.point == pose * Vector3(0.25, 0.25, 0))
	var indexed: Dictionary = Ray.prepare(_mesh(vertices, PackedInt32Array([2, 1, 0])))
	var indexed_hit: Dictionary = Ray.intersect(indexed, Transform3D.IDENTITY, from, to, 1)
	_check("indexed_reversed_winding", indexed_hit.valid and indexed_hit.hit and indexed_hit.point == solid.point)
	var two := vertices.duplicate()
	for vertex in vertices: two.append(vertex + Vector3(0, 0, 0.5))
	var nearest: Dictionary = Ray.intersect(Ray.prepare(_mesh(two)), Transform3D.IDENTITY, from, to, 2)
	_check("nearest_not_first_triangle", nearest.valid and nearest.hit and nearest.triangleIndex == 1 and nearest.point == Vector3(0.25, 0.25, 0.5))
	_check("prepare_triangle_cap", not Ray.prepare(_mesh(two), 1).valid)
	var coplanar: Dictionary = Ray.intersect(prepared, Transform3D.IDENTITY, Vector3(-1, 0.25, 0), Vector3(0.25, 0.25, 0), 1)
	_check("coplanar_entry", coplanar.valid and coplanar.hit and coplanar.point == Vector3(0, 0.25, 0))
	_check("identity_initial", Ray.identity_matches(mesh, prepared))
	_check("replacement_mesh_identity_rejected", not Ray.identity_matches(_mesh(vertices), prepared))
	var bad: Dictionary = prepared.duplicate(true)
	bad.localtriangles = prepared.localtriangles.duplicate()
	bad.localtriangles[0] = Vector3(NAN, 0, 0)
	var malformed: Dictionary = Ray.intersect(bad, Transform3D.IDENTITY, from, to, 1)
	_check("nonfinite_prepared_triangle_rejected", not malformed.valid and malformed.tests <= 1)
	_check("prepared_mutation_identity_rejected", not Ray.identity_matches(mesh, bad))
	mesh.clear_surfaces()
	_check("stale_cleared_mesh_rejected", not Ray.identity_matches(mesh, prepared))
