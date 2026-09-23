extends SceneTree

# Direct engine constructor oracle; not live gameplay, movement, or navigation acceptance.
const MainScript := preload("res://scripts/Main.gd")
const AnimatedRegistry := preload("res://scripts/visual/AnimatedAssetRegistry.gd")
const CELL := 1.35

func _bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func _v3(value: Vector3) -> Array:
	return [_bits(value.x), _bits(value.y), _bits(value.z)]

func _append_bits(parts: PackedStringArray, values: Array) -> void:
	for value in values:
		parts.append(str(int(value)))

func _geometry_digest(row: Dictionary) -> String:
	# Canonical bridge to the native typed decoder. Unlike the broader oracle
	# digest, this deliberately includes every mesh and collider field consumed
	# by native publication, and excludes imported GLB hierarchy internals.
	var parts := PackedStringArray()
	parts.append(String(row.collision.class))
	parts.append("1" if row.collision.disabled else "0")
	_append_bits(parts, row.collision.centerBits)
	_append_bits(parts, row.collision.sizeBits)
	_append_bits(parts, row.visual.scaleBits)
	_append_bits(parts, row.visual.rotationBits)
	var meshes: Array = row.visual.meshes if row.visual.has("meshes") else []
	parts.append(str(meshes.size()))
	for mesh in meshes:
		parts.append(String(mesh.class))
		parts.append(String(mesh.materialRole))
		_append_bits(parts, mesh.positionBits)
		_append_bits(parts, mesh.rotationBits)
		_append_bits(parts, mesh.scaleBits)
		for field in ["radiusBits", "heightBits", "topRadiusBits", "bottomRadiusBits",
				"radialSegments", "rings"]:
			parts.append(str(int(mesh.get(field, 0))))
	return "|".join(parts).sha256_text()

func _mesh(node: MeshInstance3D, wildlife_material: Material,
		dark_material: Material) -> Dictionary:
	var material_role := "missing"
	if node.material_override == wildlife_material:
		material_role = "wildlife"
	elif node.material_override == dark_material:
		material_role = "wildlifeDark"
	elif node.material_override != null:
		material_role = "other"
	var result := {"positionBits": _v3(node.position), "rotationBits": _v3(node.rotation),
		"scaleBits": _v3(node.scale), "class": node.mesh.get_class(),
		"materialRole": material_role}
	if node.mesh is SphereMesh:
		var shape := node.mesh as SphereMesh
		result["radiusBits"] = _bits(shape.radius)
		result["heightBits"] = _bits(shape.height)
		result["radialSegments"] = shape.radial_segments
		result["rings"] = shape.rings
	elif node.mesh is CylinderMesh:
		var shape := node.mesh as CylinderMesh
		result["topRadiusBits"] = _bits(shape.top_radius)
		result["bottomRadiusBits"] = _bits(shape.bottom_radius)
		result["heightBits"] = _bits(shape.height)
		result["radialSegments"] = shape.radial_segments
	return result

func _case(registry: RefCounted, biome: String, seed: int, chunk: Vector2i,
		animated: bool) -> Dictionary:
	var main: Node3D = MainScript.new()
	main.animated_asset_registry = registry if animated else null
	main.materials = {"wildlife": StandardMaterial3D.new(),
		"wildlifeDark": StandardMaterial3D.new()}
	var parent := Node3D.new()
	root.add_child(parent)
	parent.global_position = Vector3(float(chunk.x * 28) * CELL, 0.0, float(chunk.y * 28) * CELL)
	var local := Vector3(26.0 * CELL, 22.75, 2.0 * CELL)
	var prop_id := "oracle:wildlife:%d,%d:%s" % [chunk.x, chunk.y, biome]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var before := str(rng.state)
	var body := main.make_wildlife(parent, prop_id, local, biome, rng) as StaticBody3D
	if body == null:
		parent.free()
		main.free()
		return {"error": "make_wildlife_returned_null"}
	var collider: CollisionShape3D = null
	var visual: Node3D = null
	for child in body.get_children():
		if child is CollisionShape3D:
			collider = child
		elif child is Node3D:
			visual = child
	var visual_row := {}
	if visual != null:
		visual_row = {"class": visual.get_class(), "name": String(visual.name),
			"scaleBits": _v3(visual.scale), "rotationBits": _v3(visual.rotation),
			"source": String(visual.get_meta("visual_source", "")),
			"assetId": String(visual.get_meta("animated_asset_id", "")),
			"role": String(visual.get_meta("visual_role", ""))}
		if not animated:
			var meshes: Array[Dictionary] = []
			for child in visual.get_children():
				if child is MeshInstance3D:
					meshes.append(_mesh(child, main.materials["wildlife"],
						main.materials["wildlifeDark"]))
			visual_row["meshes"] = meshes
		else:
			var player: AnimationPlayer = registry.find_animation_player(visual)
			visual_row["animationPlayerPresent"] = player != null
			if player != null:
				visual_row["currentAnimation"] = player.current_animation
				visual_row["speedBits"] = _bits(player.speed_scale)
				visual_row["clipNames"] = Array(player.get_animation_list())
				var clip := player.get_animation(player.current_animation)
				visual_row["currentClipLoopMode"] = clip.loop_mode if clip != null else -1
	var collision_row := {}
	if collider != null:
		var shape := collider.shape as BoxShape3D
		collision_row = {"class": collider.shape.get_class(),
			"centerBits": _v3(collider.position),
			"sizeBits": _v3(shape.size) if shape != null else [],
			"disabled": collider.disabled}
	var row := {"biome": biome, "seed": seed, "chunk": [chunk.x, chunk.y],
		"animatedRequested": animated, "id": prop_id,
		"stateBefore": before, "stateAfter": str(rng.state),
		"parentOriginBits": _v3(parent.global_position),
		"localPositionBits": _v3(body.position),
		"globalPositionBits": _v3(body.global_position),
		"yawBits": _bits(body.rotation.y), "bodyName": String(body.name),
		"metadata": {"kind": String(body.get_meta("kind", "")),
			"id": String(body.get_meta("prop_id", "")),
			"material": String(body.get_meta("material", "")),
			"drop": String(body.get_meta("drop", "")),
			"dropCount": int(body.get_meta("drop_count", -1)),
			"extraDrop": String(body.get_meta("extra_drop", "")),
			"extraDropCount": int(body.get_meta("extra_drop_count", -1)),
			"variant": String(body.get_meta("wildlife_variant", "")),
			"speedMultiplierBits": _bits(float(body.get_meta("wildlife_speed_multiplier", 0.0))),
			"homeBits": _v3(body.get_meta("wildlife_home", Vector3.ZERO)),
			"directionBits": _v3(body.get_meta("wildlife_direction", Vector3.ZERO)),
			"timerBits": _bits(float(body.get_meta("wildlife_timer", 0.0))),
			"speedBits": _bits(float(body.get_meta("wildlife_speed", 0.0))),
			"lastMoveBits": _bits(float(body.get_meta("wildlife_last_move", -1.0))),
			"animated": bool(body.get_meta("wildlife_animated", false)),
			"animationName": String(body.get_meta("wildlife_animation_name", "")),
			"animationPath": String(body.get_meta("wildlife_animation_player_path", ""))},
		"collision": collision_row, "visual": visual_row,
		"registered": main.wildlife_nodes.has(body)}
	# The animation-player path intentionally pins its relative imported hierarchy;
	# procedural auto-generated child names are not captured.
	row["constructionDigest"] = JSON.stringify(row).sha256_text()
	root.remove_child(parent)
	parent.free()
	main.free()
	return row

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var registry = AnimatedRegistry.new()
	registry.setup()
	var degenerate_rng := RandomNumberGenerator.new()
	degenerate_rng.seed = 4294967295
	var degenerate_before := str(degenerate_rng.state)
	var degenerate_value := degenerate_rng.randi_range(1, 1)
	var degenerate_after := str(degenerate_rng.state)
	var cases: Array[Dictionary] = [
		_case(registry, "plains", 0, Vector2i(-1, 2), true),
		_case(registry, "snow", 4294967295, Vector2i(-2, -1), true),
		_case(registry, "swamp", 29, Vector2i(1, -3), true),
		_case(registry, "forest", 17, Vector2i(0, 0), false),
		_case(registry, "swamp", 29, Vector2i(9, -7), false),
		_case(registry, "snow", 4294967295, Vector2i(-3, 1), false),
	]
	for row in cases:
		if not row.has("error"):
			row["geometryDigest"] = _geometry_digest(row)
	var passed := cases.size() == 6
	passed = passed and degenerate_value == 1
	passed = passed and degenerate_before == "-9176265316429931931"
	passed = passed and degenerate_after == degenerate_before
	# The digest covers every captured transform, physical/visual dimension,
	# initial movement value, metadata field, and final shared-PCG state.
	var expected_variants := ["deer", "hare", "boar", "deer", "boar", "hare"]
	var expected_digests := [
		"7e4f4f68f50f0eb4ab6889c00238f7d5a50e26e2c58d16a0fc27bb9ebde2cb37",
		"9e6f65f5f0bc6c38986f42d6dda3cb8288c1e3be5ce58eca7708aa29e514ff56",
		"6ac133b3eb62b5151dcebc83aac93bbad9ac3d1b65117787459e600c72a58a38",
		"dc79879f94e422642aef171302cc070ee77a25ee5c41a8c77abbad9b9a21c81b",
		"8dd9da695f89cf31110c823efa9884f1d4295786c505817a88bcd59b5b1f9cd0",
		"0046cc13c80079ff0d0bfa381222ff51cb72418e0f18d9eee1c1f4676f5b8369",
	]
	var expected_geometry_digests := [
		"4cc4189f5f4cb1f9ae9f3b1e113782a9e986dc8995bf4bcac2542d807f58eb11",
		"d3a5d00e35b5a56b52de7564a4e5da3399b2b2781ab51ef018251c37ff4ed2d1",
		"d3198330a0505ca0baf13c1e151d7f24441f36590be0431ecc1ca9706b6eb992",
		"0cee1cc93ca2df1817780186f7dad6077c6d693197d7e63c5c6b9a2f187df0bb",
		"d808da18a92a2ee6a830964ba299c505d38629ef0c1ecb1a9cac1ee933df2e42",
		"ff107b7280a43c17ea38bb5baf029280ad6f147d278995a7e30657095fd3f1bf",
	]
	for index in range(cases.size()):
		var row: Dictionary = cases[index]
		if row.has("error"):
			passed = false
			continue
		passed = passed and row.metadata.variant == expected_variants[index]
		passed = passed and row.bodyName == "Wildlife_%s" % expected_variants[index]
		passed = passed and row.constructionDigest == expected_digests[index]
		passed = passed and row.geometryDigest == expected_geometry_digests[index]
		passed = passed and row.registered and row.collision.class == "BoxShape3D"
		passed = passed and row.metadata.kind == "prop" and row.metadata.id == row.id
		passed = passed and row.metadata.material == "wildlife" and row.metadata.drop == "rawMeat"
		passed = passed and row.metadata.extraDrop == "hide"
		passed = passed and row.metadata.homeBits == row.globalPositionBits
		passed = passed and row.stateBefore != row.stateAfter
		passed = passed and not row.collision.disabled
		if row.animatedRequested:
			passed = passed and row.metadata.animated and row.visual.animationPlayerPresent
			passed = passed and row.visual.currentAnimation == row.metadata.animationName
			passed = passed and row.visual.assetId == "%s_idle_walk" % expected_variants[index]
			passed = passed and row.visual.currentClipLoopMode == Animation.LOOP_LINEAR
		else:
			passed = passed and not row.metadata.animated and row.visual.meshes.size() == 8
			for mesh_index in range(row.visual.meshes.size()):
				var expected_role := "wildlife" if mesh_index < 2 else "wildlifeDark"
				passed = passed and row.visual.meshes[mesh_index].materialRole == expected_role
	passed = passed and registry.is_ready() and registry.last_errors.is_empty()
	var report := {"schema": "n4-wildlife-construction-oracle/v1",
		"evidenceLevel": "direct_godot_service_engine", "cases": cases,
		"degenerateRangeProbe": {"before": degenerate_before,
			"value": degenerate_value, "after": degenerate_after},
		"registryReady": registry.is_ready(), "registryErrors": registry.last_errors,
		"passed": passed}
	var path := OS.get_environment("N4_WILDLIFE_CONSTRUCTION_ORACLE_REPORT")
	if not path.is_empty():
		var output := FileAccess.open(path, FileAccess.WRITE)
		if output == null:
			push_error("N4 wildlife oracle report open failed")
			quit(1)
			return
		output.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify({"schema": report.schema, "passed": passed,
		"cases": cases.size(), "reportPath": path}))
	quit(0 if passed else 1)
