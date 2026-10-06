extends SceneTree

# Direct production constructor/service oracle; not a headed gameplay claim.
const MainTools := preload("res://scripts/Main.gd")
const EnvironmentCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualRegistry := preload("res://scripts/visual/VisualAssetRegistry.gd")

func _vector(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _mesh_bounds(node: Node, rows: Array[Dictionary]) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mesh_node := child as MeshInstance3D
			if mesh_node.mesh != null:
				var aabb := mesh_node.global_transform * mesh_node.mesh.get_aabb()
				rows.append({"meshClass": mesh_node.mesh.get_class(),
					"min": _vector(aabb.position), "max": _vector(aabb.end)})
		_mesh_bounds(child, rows)

func _case(main: Node3D, registry: RefCounted, target_id: String, index: int, fallback: bool) -> Dictionary:
	var biome := "forest"
	var prop_id := ""
	for candidate in range(10000):
		var proposed := "rock-bounds:%s:%d" % [target_id, candidate]
		if registry.select_rock_asset_id(biome, proposed) == target_id:
			prop_id = proposed
			break
	if prop_id.is_empty():
		return {"id": target_id, "error": "selection_not_found"}
	var rng := RandomNumberGenerator.new()
	rng.seed = 101 + index
	var spec: Dictionary = main.rock_visual_spec(rng)
	var body := StaticBody3D.new()
	body.position = Vector3(-72.9 + float(index) * 3.0, 18.25, -39.15 + float(index) * 4.0)
	body.rotation.y = float(spec.get("rotation", 0.0))
	root.add_child(body)
	if fallback:
		registry.disable_asset_for_test(target_id)
	main.add_rock_visual(body, prop_id, biome, spec)
	if fallback:
		registry.clear_test_disabled_assets()
	var meshes: Array[Dictionary] = []
	_mesh_bounds(body, meshes)
	var row := {"id": target_id, "propId": prop_id, "fallback": fallback,
		"biome": biome, "bodyPosition": _vector(body.global_position),
		"bodyYaw": body.rotation.y, "radius": float(spec.radius),
		"heightFactor": float(spec.height_factor), "scale": _vector(spec.scale),
		"assetSize": _vector(registry.asset_size(target_id)),
		"profileScale": registry.rock_scale_for_biome(biome),
		"visualSource": String(body.get_meta("visual_source", "")),
		"selectedAssetId": String(body.get_meta("visual_asset_id", "")),
		"meshBounds": meshes}
	root.remove_child(body)
	body.free()
	return row

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var environment = EnvironmentCatalog.new()
	var registry = VisualRegistry.new()
	if not environment.setup() or not registry.setup(environment):
		push_error("N4 rock runtime oracle registry setup failed")
		quit(1)
		return
	var main: Node3D = MainTools.new()
	main.visual_asset_registry = registry
	main.materials["rock"] = StandardMaterial3D.new()
	var rows: Array[Dictionary] = []
	for index in range(6):
		var target_id := "rock_%02d" % (index + 1)
		rows.append(_case(main, registry, target_id, index, false))
	rows.append(_case(main, registry, "rock_01", 6, true))
	var passed := rows.size() == 7
	for row in rows:
		passed = passed and not row.has("error") and row.meshBounds.size() == 1
		passed = passed and row.visualSource == ("primitive_fallback" if row.fallback else "generated_asset")
		passed = passed and row.selectedAssetId == ("" if row.fallback else row.id)
	var report := {"schema": "n4-rock-runtime-bounds-oracle/v1", "scope": "direct_godot_constructor_only",
		"rows": rows, "passed": passed}
	var output_path := OS.get_environment("N4_ROCK_RUNTIME_BOUNDS_REPORT")
	if not output_path.is_empty():
		var output := FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			push_error("N4 rock runtime report open failed")
			quit(1)
			return
		output.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	main.free()
	quit(0 if passed else 1)
