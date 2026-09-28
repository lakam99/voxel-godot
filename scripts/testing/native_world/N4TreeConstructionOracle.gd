extends SceneTree

# Direct Godot construction evidence only; no headed gameplay admission.
const MainScript := preload("res://scripts/Main.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const StructuresScript := preload("res://scripts/StructureSystem.gd")

class AbsentAdmission extends RefCounted:
	func source_state(_region: Vector2i) -> Dictionary:
		return {"status": "absent", "reason": "source_not_requested"}

class FixtureAdmission extends RefCounted:
	var status := "ready"
	var reservation := Rect2i()
	func source_state(_region: Vector2i) -> Dictionary:
		return {"status": status, "reservationCells": reservation}

class RegionFixtureAdmission extends RefCounted:
	var target_region := Vector2i.ZERO
	var reservation := Rect2i()
	var queried_regions: Array[Vector2i] = []
	func source_state(region: Vector2i) -> Dictionary:
		queried_regions.append(region)
		if region == target_region:
			return {"status": "ready", "reservationCells": reservation}
		return {"status": "absent", "reason": "other_region"}

func _bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func _case(biome: String, seed_value: int, chunk_x: int, chunk_z: int,
		block_natural := false, exclusion_kind := "") -> Dictionary:
	var main: Node3D = MainScript.new()
	var catalog = CatalogScript.new()
	if not catalog.setup():
		return {"error": "catalog_setup", "biome": biome}
	main.biome_environment_catalog = catalog
	main.seed_text = "tree-order-oracle"
	var material := StandardMaterial3D.new()
	main.materials = {"trunk": material, "leaf": material}
	var parent := Node3D.new()
	root.add_child(parent)
	parent.global_position = Vector3(float(chunk_x * 28) * 1.35, 0.0,
		float(chunk_z * 28) * 1.35)
	var x := chunk_x * 28 + 26
	var z := chunk_z * 28 + 2
	var prop_id := "%s:%d,%d:0" % [main.seed_text, x, z]
	var local_position := Vector3(26.0 * 1.35, 24.3, 2.0 * 1.35)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# Replay production's visual-spec consumption on a separate RNG so the
	# make_tree call below still owns and advances its original shared stream.
	var replay_rng := RandomNumberGenerator.new()
	replay_rng.seed = seed_value
	var legacy_spec: Dictionary = main.tree_visual_spec(biome, replay_rng)
	var legacy_height := float(legacy_spec.get("height", 4.0))
	var expected_request: Dictionary = main.tree_runtime_spec_for_prop(
		biome, prop_id, legacy_height, Vector2i(x, z))
	var natural_margin := ceili((float(expected_request.get("trunkRadius", 0.0))
		+ float(expected_request.get("exclusionMargin", 0.0))) / 1.35)
	var structure_margin := ceili((float(expected_request.get("canopyRadius", 0.0))
		+ float(expected_request.get("exclusionMargin", 0.0))) / 1.35)
	var region_admission: RegionFixtureAdmission = null
	if block_natural or not exclusion_kind.is_empty():
		var structures = StructuresScript.new()
		structures.citadel_terrain_admission = AbsentAdmission.new()
		if block_natural:
			structures.reserve_natural_prop_exclusion(x + natural_margin, z, 1, 1,
				"tree-halo-oracle")
		elif exclusion_kind == "terrain_footprint":
			# The record expands its base by one cell. Its minCell lands at
			# x + structure_margin, exactly the live canopy boundary.
			structures.record_structure_terrain_footprint(x + structure_margin + 1,
				z, 24.3, 1, 1, 2, "tree-terrain-halo-oracle", "stone", 18)
		elif exclusion_kind in ["citadel_ready", "citadel_prepared"]:
			var admission := FixtureAdmission.new()
			admission.status = "ready" if exclusion_kind == "citadel_ready" else "prepared"
			admission.reservation = Rect2i(Vector2i(x + structure_margin, z), Vector2i.ONE)
			structures.citadel_terrain_admission = admission
		elif exclusion_kind == "citadel_cross_region":
			# x=-2 expands across the -1/0 2048-cell Citadel region edge.
			# Only region (0,-1) owns a ready reservation at x=1; a
			# center-region-only lookup would incorrectly admit this tree.
			region_admission = RegionFixtureAdmission.new()
			region_admission.target_region = Vector2i(0, -1)
			region_admission.reservation = Rect2i(Vector2i(1, z), Vector2i.ONE)
			structures.citadel_terrain_admission = region_admission
		main.structure_system = structures
	var before: int = rng.state
	var body: StaticBody3D = main.make_tree(parent, prop_id, local_position, biome, rng,
		Vector2i(x, z))
	var row := {"biome": biome, "seed": seed_value, "chunk": [chunk_x, chunk_z],
		"id": prop_id, "stateBefore": before, "stateAfter": rng.state,
		"replayedStateAfterVisualSpec": replay_rng.state,
		"legacyHeightBits": _bits(legacy_height),
		"drawMode": 22 if biome in ["taiga", "snow", "tundra"] else 36,
		"blockNatural": block_natural, "naturalMarginCells": natural_margin}
	if not exclusion_kind.is_empty():
		row["exclusionKind"] = exclusion_kind
		row["structureMarginCells"] = structure_margin
		row["exclusionBoundaryCell"] = [x + structure_margin, z]
	if region_admission != null:
		row["queriedRegions"] = region_admission.queried_regions.map(func(region: Vector2i): return [region.x, region.y])
		row["admittedRegion"] = [region_admission.target_region.x, region_admission.target_region.y]
	if body == null:
		row["presence"] = "absent"
		row["request"] = expected_request
	else:
		row["presence"] = "present"
		var collider: CollisionShape3D = null
		for child in body.get_children():
			if child is CollisionShape3D:
				collider = child
		var spec: Dictionary = expected_request
		row["localPositionBits"] = [_bits(body.position.x), _bits(body.position.y), _bits(body.position.z)]
		row["worldPositionBits"] = [_bits(body.global_position.x), _bits(body.global_position.y), _bits(body.global_position.z)]
		row["yawBits"] = _bits(body.rotation.y)
		row["request"] = spec
		row["bodyMetadata"] = {
			"propId": String(body.get_meta("prop_id", "")),
			"drop": String(body.get_meta("drop", "")),
			"material": String(body.get_meta("material", "")),
			"dropCount": int(body.get_meta("drop_count", -1)),
			"visualBiome": String(body.get_meta("visual_biome", "")),
			"treeFamily": String(body.get_meta("tree_family", "")),
			"treeGrowthClass": String(body.get_meta("tree_growth_class", "")),
			"treeArchitecture": String(body.get_meta("tree_architecture", "")),
			"treeAgeBand": String(body.get_meta("tree_age_band", "")),
			"treeAgeYears": float(body.get_meta("tree_age_years", 0.0)),
			"treeTrunkRadius": float(body.get_meta("tree_trunk_radius", 0.0)),
			"treeVisualHeight": float(body.get_meta("tree_visual_height", 0.0)),
			"treeCollisionHeight": float(body.get_meta("tree_collision_height", 0.0)),
		}
		if collider != null and collider.shape is CylinderShape3D:
			var cylinder := collider.shape as CylinderShape3D
			row["trunkRadiusBits"] = _bits(cylinder.radius)
			row["trunkHeightBits"] = _bits(cylinder.height)
			row["trunkCenterBits"] = _bits(collider.position.y)
		else:
			row["error"] = "missing_trunk_collider"
	parent.queue_free()
	main.free()
	return row

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var cases := [_case("taiga", 0, -1, 2), _case("plains", 4294967295, -2, -1),
		_case("taiga", 0, -1, 2, true),
		_case("plains", 4294967295, -2, -1, false, "terrain_footprint"),
		_case("plains", 4294967295, -2, -1, false, "citadel_ready"),
		_case("plains", 4294967295, -2, -1, false, "citadel_prepared"),
		_case("plains", 4294967295, -1, -1, false, "citadel_cross_region")]
	var passed := true
	for row in cases:
		# Pin the replay-derived production request, captured body metadata,
		# frame, trunk and RNG row; this exceeds sampled native assertions.
		row["constructionDigest"] = JSON.stringify(row).sha256_text()
		passed = passed and not row.has("error")
		passed = passed and (not row.blockNatural or row.presence == "absent")
		passed = passed and (not row.has("exclusionKind") or row.presence == "absent")
		if row.get("exclusionKind", "") == "citadel_cross_region":
			passed = passed and row.queriedRegions.has([-1, -1]) and row.queriedRegions.has([0, -1])
		passed = passed and (row.blockNatural or row.has("exclusionKind") or row.has("trunkRadiusBits"))
		passed = passed and row.replayedStateAfterVisualSpec == row.stateAfter
		if row.has("request") and row.has("bodyMetadata"):
			passed = passed and row.bodyMetadata.treeFamily == row.request.family
			passed = passed and row.bodyMetadata.treeVisualHeight == row.request.visualHeight
	var expected_digests := [
		"f92f4d1fa8a3767365d320786cbbd0e486733488574425c5b187343a98fe4ece", # taiga, 22 draws
		"847933285427ed48b78c8a3a2511a2d53a9954d657cf5db049d15d5d118c00ac", # plains, 36 draws
		"be80f155f6dc00b66465f0328897ed727b65e7e2d54d3b283349e1a56c147925", # taiga, natural margin blocks after draws
		"0ca8c79e107442b311097eee4bedd51b64ee1d00d174a25ed2a16a5bddaa1e35", # negative-region terrain footprint at canopy boundary
		"44fcfe6e3492ff8feac4772fea40c818fcbf097e6aeaacc1a4b4a817bfdcb526", # negative-region Citadel ready reservation at canopy boundary
		"fed38f4230b576f42575710349f8dfbc708c40faa662aa3882617239d786fee9", # negative-region Citadel prepared reservation at canopy boundary
		"cecb9d57aadd75d678952413ed4818bf967b509beb0762cf28ee9e35cb5dcc2c", # -1/0 Citadel region boundary, distinct source states
	]
	for index in range(cases.size()):
		passed = passed and cases[index].constructionDigest == expected_digests[index]
	var report := {"schema": "n4-tree-construction-oracle/v1",
		"evidenceLevel": "direct_godot_service_engine", "cases": cases, "passed": passed}
	var report_path := OS.get_environment("N4_TREE_CONSTRUCTION_ORACLE_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file == null:
			quit(1)
			return
		file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify({"schema": report.schema, "passed": passed,
		"cases": cases.size(), "reportPath": report_path}))
	quit(0 if passed else 1)
