extends SceneTree

# Direct engine construction oracle for the production ore methods. It does
# not enter gameplay, harvest props, or publish navigation.
const MainScript := preload("res://scripts/Main.gd")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const CELL := 1.35

func _bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func _v3(value: Vector3) -> Dictionary:
	return {"value": [value.x, value.y, value.z],
		"bits": [_bits(value.x), _bits(value.y), _bits(value.z)]}

func _mesh_row(node: MeshInstance3D) -> Dictionary:
	var row := {"name": String(node.name), "position": _v3(node.position),
		"rotation": _v3(node.rotation), "scale": _v3(node.scale)}
	if node.mesh is BoxMesh:
		row["meshSize"] = _v3((node.mesh as BoxMesh).size)
	elif node.mesh is SphereMesh:
		var sphere := node.mesh as SphereMesh
		row["meshRadius"] = sphere.radius
		row["meshRadiusBits"] = _bits(sphere.radius)
		row["meshHeight"] = sphere.height
		row["meshHeightBits"] = _bits(sphere.height)
	return row

func _child_row(body: StaticBody3D) -> Dictionary:
	var visuals: Array[MeshInstance3D] = []
	var collider: CollisionShape3D = null
	for child in body.get_children():
		if child is MeshInstance3D:
			visuals.append(child)
		elif child is CollisionShape3D:
			collider = child
	if visuals.size() != 9 or collider == null:
		return {"captureError": "unexpected ore child structure", "visualCount": visuals.size(),
			"hasCollider": collider != null}
	var base: MeshInstance3D = visuals[0]
	var sphere: SphereMesh = base.mesh as SphereMesh
	var collision_sphere: SphereShape3D = collider.shape as SphereShape3D
	var seams: Array[Dictionary] = []
	var glints: Array[Dictionary] = []
	for index in range(1, 6):
		seams.append(_mesh_row(visuals[index]))
	for index in range(6, 9):
		glints.append(_mesh_row(visuals[index]))
	return {"id": String(body.get_meta("prop_id", "")), "name": String(body.name),
		"localPosition": _v3(body.position), "globalPosition": _v3(body.global_position),
		"yaw": body.rotation.y, "yawBits": _bits(body.rotation.y),
		"drop": String(body.get_meta("drop", "")),
		"material": String(body.get_meta("material", "")),
		"oreType": String(body.get_meta("ore_type", "")),
		"requiredTool": String(body.get_meta("required_tool", "")),
		"requiredTier": int(body.get_meta("required_tier", -1)),
		"dropCount": int(body.get_meta("drop_count", -1)),
		"clusterSize": int(body.get_meta("cluster_size", -1)),
		"base": {"radius": sphere.radius, "radiusBits": _bits(sphere.radius),
			"height": sphere.height, "heightBits": _bits(sphere.height),
			"radialSegments": sphere.radial_segments, "rings": sphere.rings,
			"position": _v3(base.position), "scale": _v3(base.scale)},
		"seams": seams, "glints": glints,
		"collision": {"radius": collision_sphere.radius,
			"radiusBits": _bits(collision_sphere.radius),
			"center": _v3(collider.position)}}

func _case(ore_type: String, remove_second: bool, seed_value: int,
		chunk_x: int, chunk_z: int) -> Dictionary:
	var main: Node3D = MainScript.new()
	var material := StandardMaterial3D.new()
	main.materials = {"rock": material, "oreBase": material,
		"ironOre": material, "copperOre": material,
		"ironOreGlow": material, "copperOreGlow": material}
	var parent := Node3D.new()
	parent.name = "OreOracleChunk"
	root.add_child(parent)
	parent.global_position = Vector3(float(chunk_x * 28) * CELL, 0.0,
		float(chunk_z * 28) * CELL)
	var local_position := Vector3(26.0 * CELL, 24.3, 2.0 * CELL)
	var parent_id := "世界🌲:%d,%d:0" % [chunk_x * 28 + 26, chunk_z * 28 + 2]
	if remove_second:
		main.removed_props[parent_id + ":cluster1"] = true
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var before: int = rng.state
	var nodes: Array = main.make_ore_cluster(parent, parent_id, local_position,
		ore_type, rng, 2)
	var rows: Array[Dictionary] = []
	for node in nodes:
		rows.append(_child_row(node as StaticBody3D))
	var report := {"oreType": ore_type, "removeSecondChild": remove_second,
		"seed": seed_value, "stateBefore": before, "stateAfter": rng.state,
		"parentId": parent_id, "chunk": [chunk_x, chunk_z],
		"chunkOrigin": _v3(parent.global_position),
		"requestedLocalPosition": _v3(local_position), "children": rows,
		"catalogRequiredTool": ItemCatalogScript.material_required_tool(ore_type),
		"catalogRequiredTier": ItemCatalogScript.material_required_tier(ore_type)}
	root.remove_child(parent)
	parent.free()
	main.free()
	return report

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var cases: Array[Dictionary] = [
		_case("ironOre", false, 0, -1, 2),
		_case("ironOre", true, 0, -1, 2),
		_case("copperOre", false, 4294967295, -2, -1),
		_case("copperOre", true, 4294967295, -2, -1),
	]
	var passed := true
	for row in cases:
		# Pin the complete production construction, including every seam/glint,
		# collider and the skipped-child RNG consequence. This remains direct
		# engine evidence, not a live-gameplay acceptance claim.
		row["geometryDigest"] = JSON.stringify(row).sha256_text()
		var children: Array = row.children
		var expected_count := 1 if row.removeSecondChild else 2
		passed = passed and children.size() == expected_count
		for index in range(children.size()):
			var child: Dictionary = children[index]
			if child.has("captureError"):
				passed = false
				continue
			passed = passed and String(child.id) == String(row.parentId) + (":cluster1" if index == 1 else "")
			passed = passed and child.oreType == row.oreType and child.drop == row.oreType
			passed = passed and child.requiredTool == row.catalogRequiredTool
			passed = passed and child.requiredTier == row.catalogRequiredTier
			passed = passed and child.clusterSize == 2
			passed = passed and child.seams.size() == 5 and child.glints.size() == 3
	passed = passed and cases[0].children[0].id == cases[1].children[0].id
	passed = passed and cases[0].stateAfter != cases[1].stateAfter
	passed = passed and cases[2].children[0].id == cases[3].children[0].id
	passed = passed and cases[2].stateAfter != cases[3].stateAfter
	var expected_digests := [
		"c9a53f45bc0eb82fd4b71b86528742b09a1eb4de95f499a54d1087c75b1333a8", # iron, both children
		"c02c7d6b71bb83aa84751b9d03d738b8f4d49bd87eda386266dd71eac1a04df4", # iron, second child tombstoned
		"f5a6122bd1df7348f9ff9cc9fe1630a0856bfda19e117f31d043bc571d1d663c", # copper, both children
		"bd23760ce315b2f368ed6a4354ea013bb8465eb6dcd42d859a6e811bfdaabd2c", # copper, second child tombstoned
	]
	for index in range(cases.size()):
		passed = passed and cases[index].geometryDigest == expected_digests[index]
	var report := {"schema": "n4-ore-construction-oracle/v1", "evidenceLevel": "direct_godot_service_engine",
		"cases": cases, "passed": passed}
	var report_path := OS.get_environment("N4_ORE_CONSTRUCTION_ORACLE_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			push_error("N4 ore construction oracle report open failed")
			quit(1)
			return
		file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify({"schema": report.schema, "passed": passed,
		"cases": cases.size(), "reportPath": report_path}))
	quit(0 if passed else 1)
