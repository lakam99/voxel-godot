extends SceneTree

# Direct imported-scene geometry oracle. No gameplay or native publication.
const MANIFEST := "res://assets/visual/generated/visual-manifest.json"

func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _meshes(node: Node, from_root: Transform3D, rows: Array[Dictionary]) -> void:
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var spatial := child as Node3D
		var transform := from_root * spatial.transform
		if spatial is MeshInstance3D:
			var mesh_node := spatial as MeshInstance3D
			if mesh_node.mesh != null:
				var aabb := transform * mesh_node.mesh.get_aabb()
				rows.append({"path": String(node.get_path_to(spatial)),
					"min": _vector(aabb.position), "max": _vector(aabb.end),
					"meshClass": mesh_node.mesh.get_class()})
		_meshes(spatial, transform, rows)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not (manifest is Dictionary):
		push_error("N4 rock import oracle missing visual manifest")
		quit(1)
		return
	var rows: Array[Dictionary] = []
	for value in manifest.get("assets", []):
		if not (value is Dictionary) or value.get("family", "") != "rock" or not bool(value.get("runtimeEnabled", true)):
			continue
		var resource_path := "res://" + String(value.path)
		var scene := ResourceLoader.load(resource_path, "PackedScene") as PackedScene
		if scene == null:
			rows.append({"id": value.id, "error": "load_failed"})
			continue
		var root_node := scene.instantiate() as Node3D
		if root_node == null:
			rows.append({"id": value.id, "error": "instantiate_failed"})
			continue
		var meshes: Array[Dictionary] = []
		_meshes(root_node, root_node.transform, meshes)
		rows.append({"id": value.id, "path": value.path, "meshBounds": meshes,
			"rootScale": _vector(root_node.scale), "rootPosition": _vector(root_node.position)})
		root_node.free()
	var passed := rows.size() == 6
	for row in rows:
		passed = passed and not row.has("error") and row.meshBounds.size() > 0
	var report := {"schema": "n4-rock-import-bounds-oracle/v1", "scope": "direct_godot_import_only",
		"rows": rows, "passed": passed}
	var output_path := OS.get_environment("N4_ROCK_IMPORT_BOUNDS_REPORT")
	if not output_path.is_empty():
		var output := FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			push_error("N4 rock import report open failed")
			quit(1)
			return
		output.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
