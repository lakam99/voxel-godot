extends SceneTree

# Direct constructor/service oracle; this is not live gameplay or navigation acceptance.
const MainTools := preload("res://scripts/Main.gd")
const EnvironmentCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const NavigationAdapter := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const CELL := 1.35

func _bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func _vector(value: Vector3) -> Array:
	return [_bits(value.x), _bits(value.y), _bits(value.z)]

func _world_aabb(bounds: AABB) -> Dictionary:
	return {"minBits": _vector(bounds.position),
		"maxBits": _vector(bounds.position + bounds.size),
		"finite": bounds.position.is_finite() and bounds.size.is_finite()}

func _mesh_record(node: MeshInstance3D, materials: Dictionary) -> Dictionary:
	var mesh := node.mesh
	var material_role := "missing"
	for material_id in materials:
		if node.material_override == materials[material_id]:
			material_role = String(material_id)
			break
	if material_role == "missing" and node.material_override != null:
		material_role = "other"
	var result := {"name": String(node.name), "positionBits": _vector(node.position),
		"rotationBits": _vector(node.rotation), "scaleBits": _vector(node.scale),
		"meshClass": mesh.get_class(), "materialRole": material_role}
	if mesh is SphereMesh:
		result["radiusBits"] = _bits(mesh.radius)
		result["heightBits"] = _bits(mesh.height)
		result["radialSegments"] = mesh.radial_segments
		result["rings"] = mesh.rings
	elif mesh is CylinderMesh:
		result["topRadiusBits"] = _bits(mesh.top_radius)
		result["bottomRadiusBits"] = _bits(mesh.bottom_radius)
		result["heightBits"] = _bits(mesh.height)
		result["radialSegments"] = mesh.radial_segments
	return result

func _geometry_digest(row: Dictionary) -> String:
	var meshes: Array[Dictionary] = []
	for mesh_value in row.meshes:
		var mesh: Dictionary = mesh_value.duplicate(true)
		# Godot allocates incidental node names in construction order. They are
		# not part of the visual or physical recipe.
		mesh.erase("name")
		meshes.append(mesh)
	var payload := {"localPositionBits": row.localPositionBits,
		"globalPositionBits": row.globalPositionBits,
		"rotationBits": row.rotationBits, "metadata": row.metadata,
		"collider": row.collider, "meshes": meshes,
		"physicalColliderPresent": row.physicalColliderPresent,
		"navigationBlocksNpc": row.navigationBlocksNpc,
		"finalRngState": row.finalRngState}
	return JSON.stringify(payload).sha256_text()

func _row(main: Node3D, adapter: RefCounted, parent: Node3D, biome: String, seed: int, label: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var local := Vector3(3.0 * CELL, 18.25, 26.0 * CELL)
	var prop_id := "oracle:%s:%s" % [label, biome]
	var body := main.make_forage(parent, prop_id, local, biome, rng) as StaticBody3D
	if body == null:
		return {"label": label, "biome": biome, "error": "make_forage_returned_null"}
	var meshes: Array[Dictionary] = []
	var mesh_world_aabbs: Array[Dictionary] = []
	var collider_record := {}
	var collider_world_aabb := {}
	for child in body.get_children():
		if child is MeshInstance3D:
			var mesh_child := child as MeshInstance3D
			meshes.append(_mesh_record(mesh_child, main.materials))
			mesh_world_aabbs.append(_world_aabb(mesh_child.global_transform * mesh_child.mesh.get_aabb()))
		elif child is CollisionShape3D:
			var collision_child := child as CollisionShape3D
			var shape := collision_child.shape as SphereShape3D
			collider_record = {"shapeClass": collision_child.shape.get_class(), "radiusBits": _bits(shape.radius) if shape != null else -1,
				"positionBits": _vector(collision_child.position), "disabled": collision_child.disabled}
			if shape != null:
				var extent := Vector3.ONE * shape.radius
				collider_world_aabb = _world_aabb(AABB(collision_child.global_position - extent, extent * 2.0))
	var profile = main.biome_environment_catalog.profile_for_biome(biome)
	return {"label": label, "biome": biome, "seed": seed, "id": prop_id,
		"profile": profile.forage_spec(), "bodyClass": body.get_class(), "bodyName": String(body.name),
		"localPositionBits": _vector(body.position), "globalPositionBits": _vector(body.global_position),
		"parentGlobalPositionBits": _vector(parent.global_position), "rotationBits": _vector(body.rotation),
		"metadata": {"kind": body.get_meta("kind"), "prop_id": body.get_meta("prop_id"),
			"drop": body.get_meta("drop"), "material": body.get_meta("material"), "drop_count": body.get_meta("drop_count")},
		"meshes": meshes, "meshWorldAabbs": mesh_world_aabbs,
		"collider": collider_record, "colliderWorldAabb": collider_world_aabb,
		"physicalColliderPresent": not collider_record.is_empty(),
		"navigationBlocksNpc": adapter.prop_blocks_npc(body), "finalRngState": str(rng.state)}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog = EnvironmentCatalog.new()
	if not catalog.setup():
		push_error("N4 forage oracle catalog setup failed: %s" % str(catalog.last_errors))
		quit(1)
		return
	var main: Node3D = MainTools.new()
	main.biome_environment_catalog = catalog
	for material in ["aloePatch", "mushroomCluster", "mushroomCap", "frostHerbPatch", "berryBush", "berryFruit"]:
		main.materials[material] = StandardMaterial3D.new()
	var adapter = NavigationAdapter.new()
	var cases := [
		{"biome": "plains", "chunk": Vector2i(0, 0), "seed": 17, "label": "berry_origin"},
		{"biome": "desert", "chunk": Vector2i(-1, 0), "seed": 29, "label": "aloe_negative"},
		{"biome": "swamp", "chunk": Vector2i(-2, -1), "seed": 41, "label": "mushroom_negative"},
		{"biome": "snow", "chunk": Vector2i(9, -7), "seed": 53, "label": "frost_seam"},
	]
	var rows: Array[Dictionary] = []
	for case in cases:
		var parent := Node3D.new()
		root.add_child(parent)
		var chunk: Vector2i = case.chunk
		parent.global_position = Vector3(float(chunk.x * 28) * CELL, 0.0, float(chunk.y * 28) * CELL)
		rows.append(_row(main, adapter, parent, case.biome, case.seed, case.label))
		if not rows.back().has("error"):
			rows.back()["geometryDigest"] = _geometry_digest(rows.back())
		root.remove_child(parent)
		parent.free()
	var expected_materials := ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]
	var expected_meshes := [8, 6, 8, 5]
	# Frozen from the real constructor at these seeds. The digest excludes only
	# incidental auto-generated mesh node names; it covers every captured
	# transform, mesh dimension, collider, metadata field and final RNG state.
	var expected_digests := [
		"4bd17e95d1d239b663af57c219cbfa7da7ec4c29a57de7612013ce06d44d6bcb",
		"2f9fc2751241386c7e6847ef04e34efa024078029540a7b9df24a33bccace752",
		"343d7f9f35ad0e2ea645daa94cea4e17079ec1606c25d06b9cbc56630518b536",
		"0f6e2c41a5bca6583a66cc1762e08830bb5cbe69de23978f66db83bf8e239cc1",
	]
	var expected_mesh_classes := [
		["SphereMesh", "SphereMesh", "SphereMesh", "SphereMesh", "SphereMesh", "SphereMesh", "SphereMesh", "SphereMesh"],
		["CylinderMesh", "CylinderMesh", "CylinderMesh", "CylinderMesh", "CylinderMesh", "CylinderMesh"],
		["CylinderMesh", "SphereMesh", "CylinderMesh", "SphereMesh", "CylinderMesh", "SphereMesh", "CylinderMesh", "SphereMesh"],
		["CylinderMesh", "CylinderMesh", "CylinderMesh", "CylinderMesh", "CylinderMesh"],
	]
	var expected_material_roles := [
		["berryBush", "berryFruit", "berryFruit", "berryFruit", "berryFruit", "berryFruit", "berryFruit", "berryFruit"],
		["aloePatch", "aloePatch", "aloePatch", "aloePatch", "aloePatch", "aloePatch"],
		["mushroomCluster", "mushroomCap", "mushroomCluster", "mushroomCap", "mushroomCluster", "mushroomCap", "mushroomCluster", "mushroomCap"],
		["frostHerbPatch", "frostHerbPatch", "frostHerbPatch", "frostHerbPatch", "frostHerbPatch"],
	]
	var passed := rows.size() == 4
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		if row.has("error"):
			passed = false
			continue
		var profile: Dictionary = row.profile
		var metadata: Dictionary = row.metadata
		var collider: Dictionary = row.collider
		passed = passed and not row.has("error") and row.metadata.material == expected_materials[index]
		passed = passed and row.meshes.size() == expected_meshes[index] and row.physicalColliderPresent
		passed = passed and row.meshWorldAabbs.size() == row.meshes.size()
		passed = passed and row.colliderWorldAabb.get("finite", false)
		for world_aabb: Dictionary in row.meshWorldAabbs:
			passed = passed and world_aabb.finite
		passed = passed and bool(row.navigationBlocksNpc) == (index == 0)
		passed = passed and row.bodyClass == "StaticBody3D"
		passed = passed and row.bodyName == "Forage_%s" % expected_materials[index]
		passed = passed and metadata.kind == "prop" and metadata.prop_id == row.id
		passed = passed and metadata.material == profile.material and metadata.drop == profile.drop
		passed = passed and int(metadata.drop_count) >= int(profile.drop_min)
		passed = passed and int(metadata.drop_count) <= int(profile.drop_max)
		passed = passed and collider.shapeClass == "SphereShape3D" and not collider.disabled
		passed = passed and collider.radiusBits == _bits(float(profile.radius))
		# The profile's stored radius and the node-position expression cross
		# different f32 boundaries (notably 0.48); the golden below fixes the
		# exact Y bit rather than recomputing it from parsed profile JSON.
		passed = passed and collider.positionBits[0] == 0 and collider.positionBits[2] == 0
		passed = passed and int(collider.positionBits[1]) > 0
		passed = passed and row.geometryDigest == expected_digests[index]
		if row.meshes.size() == expected_mesh_classes[index].size():
			for mesh_index in range(row.meshes.size()):
				passed = passed and row.meshes[mesh_index].meshClass == expected_mesh_classes[index][mesh_index]
				passed = passed and row.meshes[mesh_index].materialRole == expected_material_roles[index][mesh_index]
	var report := {"schema": "n4-forage-construction-oracle/v1", "scope": "direct_godot_service_only",
		"rows": rows, "passed": passed}
	var path := OS.get_environment("N4_FORAGE_CONSTRUCTION_ORACLE_REPORT")
	if not path.is_empty():
		var output := FileAccess.open(path, FileAccess.WRITE)
		if output == null:
			push_error("N4 forage oracle report open failed: %s" % path)
			quit(1)
			return
		output.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	main.free()
	quit(0 if passed else 1)
