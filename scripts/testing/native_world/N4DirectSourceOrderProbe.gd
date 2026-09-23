extends SceneTree

## Direct-service source-order probe. Not headed gameplay acceptance.
const MainScript := preload("res://scripts/Main.gd")
const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Bundle := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")
const TreeHalo := preload("res://scripts/world/ActiveStructureTreeHaloSnapshot.gd")

func native_initialization(seed_text: String) -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":seed_text,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.0,"townOverrides":[]}}

func _init() -> void:
	call_deferred("run")

func bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func vector_bits(value: Vector3) -> Array:
	return [bits(value.x), bits(value.y), bits(value.z)]

func forage_geometry(body: StaticBody3D, materials: Dictionary) -> Dictionary:
	var meshes := []
	var collider := {}
	for child in body.get_children():
		if child is MeshInstance3D:
			var role := ""
			for material_id in materials:
				if child.material_override == materials[material_id]:
					role = String(material_id)
					break
			var mesh: Mesh = child.mesh
			var row := {"kind":1 if mesh is SphereMesh else 2,
				"position":[child.position.x,child.position.y,child.position.z],
				"positionBits":vector_bits(child.position),
				"rotation":[child.rotation.x,child.rotation.y,child.rotation.z],
				"rotationBits":vector_bits(child.rotation),
				"scale":[child.scale.x,child.scale.y,child.scale.z],
				"scaleBits":vector_bits(child.scale),
				"materialId":role}
			if mesh is SphereMesh:
				row.merge({"radius":mesh.radius,"height":mesh.height,
					"radiusBits":bits(mesh.radius),"heightBits":bits(mesh.height),
					"radialSegments":mesh.radial_segments,"rings":mesh.rings})
			elif mesh is CylinderMesh:
				row.merge({"topRadius":mesh.top_radius,"bottomRadius":mesh.bottom_radius,
					"topRadiusBits":bits(mesh.top_radius),"bottomRadiusBits":bits(mesh.bottom_radius),
					"heightBits":bits(mesh.height),
					"height":mesh.height,"radialSegments":mesh.radial_segments})
			meshes.append(row)
		elif child is CollisionShape3D and child.shape is SphereShape3D:
			collider = {"radius":child.shape.radius,"centerY":child.position.y,
				"radiusBits":bits(child.shape.radius),"centerYBits":bits(child.position.y)}
	return {"materialId":body.get_meta("material"),"dropId":body.get_meta("drop"),
		"dropCount":body.get_meta("drop_count"),"rotationY":body.rotation.y,
		"rotationYBits":bits(body.rotation.y),
		"collider":collider,"meshes":meshes}

func ore_geometry(body: StaticBody3D) -> Dictionary:
	var visuals: Array[MeshInstance3D] = []
	var seams := []
	var glints := []
	var collider: CollisionShape3D = null
	for child in body.get_children():
		if child is MeshInstance3D:
			visuals.append(child)
		elif child is CollisionShape3D:
			collider = child
	if visuals.size() != 9 or collider == null or not (visuals[0].mesh is SphereMesh) \
			or not (collider.shape is SphereShape3D):
		return {"captureError":"incomplete_ore_body"}
	var base := visuals[0]
	for index in range(1, 6):
		var seam := visuals[index]
		if not (seam.mesh is BoxMesh):
			return {"captureError":"ore_seam_mesh_type"}
		seams.append({"positionBits":vector_bits(seam.position),
			"rotationBits":vector_bits(seam.rotation),
			"meshSizeBits":vector_bits((seam.mesh as BoxMesh).size)})
	for index in range(6, 9):
		var glint := visuals[index]
		if not (glint.mesh is SphereMesh):
			return {"captureError":"ore_glint_mesh_type"}
		glints.append({"positionBits":vector_bits(glint.position),
			"scaleBits":vector_bits(glint.scale),
			"meshRadiusBits":bits((glint.mesh as SphereMesh).radius),
			"meshHeightBits":bits((glint.mesh as SphereMesh).height)})
	var sphere := base.mesh as SphereMesh
	return {"durableId":body.get_meta("prop_id", ""),
		"oreType":body.get_meta("ore_type", ""),
		"clusterSize":body.get_meta("cluster_size", -1),
		"dropCount":body.get_meta("drop_count", -1),
		"localPositionBits":vector_bits(body.position),
		"rotationYBits":bits(body.rotation.y),
		"meshRadiusBits":bits(sphere.radius),"meshHeightBits":bits(sphere.height),
		"meshScaleBits":vector_bits(base.scale),
		"meshCenterYBits":bits(base.position.y),
		"colliderRadiusBits":bits((collider.shape as SphereShape3D).radius),
		"colliderCenterYBits":bits(collider.position.y),
		"seamCount":seams.size(),"glintCount":glints.size(),
		"seams":seams,"glints":glints}

func wildlife_geometry(body: StaticBody3D) -> Dictionary:
	var collider: CollisionShape3D = null
	var visual: Node3D = null
	for child in body.get_children():
		if child is CollisionShape3D:
			collider = child
		elif child is Node3D:
			visual = child
	if collider == null or not (collider.shape is BoxShape3D) or visual == null:
		return {"captureError":"incomplete_wildlife_body"}
	var animation_speed := 0.0
	if body.has_meta("wildlife_animation_player_path"):
		var player := body.get_node_or_null(NodePath(String(body.get_meta("wildlife_animation_player_path")))) as AnimationPlayer
		if player != null:
			animation_speed = player.speed_scale
	return {"variant":String(body.get_meta("wildlife_variant", "")),
		"primaryDropId":String(body.get_meta("drop", "")),
		"primaryDropCount":int(body.get_meta("drop_count", -1)),
		"extraDropId":String(body.get_meta("extra_drop", "")),
		"extraDropCount":int(body.get_meta("extra_drop_count", -1)),
		"bodyYawBits":bits(body.rotation.y),
		"colliderSizeBits":vector_bits((collider.shape as BoxShape3D).size),
		"colliderCenterBits":vector_bits(collider.position),
		"collisionLayer":body.collision_layer,"collisionMask":body.collision_mask,
		"presentationPath":2 if bool(body.get_meta("wildlife_animated", false)) else 1,
		"visualScaleBits":vector_bits(visual.scale),
		"visualRotationBits":vector_bits(visual.rotation),
		"animationSpeedBits":bits(animation_speed),
		"movementHomeBits":vector_bits(body.get_meta("wildlife_home", Vector3.ZERO)),
		"movementDirectionBits":vector_bits(body.get_meta("wildlife_direction", Vector3.ZERO)),
		"movementTimerBits":bits(float(body.get_meta("wildlife_timer", 0.0))),
		"movementSpeedBits":bits(float(body.get_meta("wildlife_speed", 0.0))),
		"movementLastMoveBits":bits(float(body.get_meta("wildlife_last_move", 0.0)))}

func rock_geometry(body: StaticBody3D) -> Dictionary:
	var collider: CollisionShape3D = null
	var visual: Node3D = null
	for child in body.get_children():
		if child is CollisionShape3D:
			collider = child
		elif child is Node3D:
			visual = child
	if collider == null or not (collider.shape is SphereShape3D) or visual == null:
		return {"captureError":"incomplete_rock_body"}
	return {"durableId":String(body.get_meta("prop_id", "")),
		"visualBiome":String(body.get_meta("visual_biome", "")),
		"rotationYBits":bits(body.rotation.y),
		"colliderRadiusBits":bits((collider.shape as SphereShape3D).radius),
		"colliderCenterYBits":bits(collider.position.y),
		"visualSource":String(body.get_meta("visual_source", "")),
		"assetId":String(body.get_meta("visual_asset_id", "")),
		"visualScaleBits":vector_bits(visual.scale)}

func tree_geometry(body: StaticBody3D) -> Dictionary:
	var collider: CollisionShape3D = null
	for child in body.get_children():
		if child is CollisionShape3D:
			collider = child
	if collider == null or not (collider.shape is CylinderShape3D):
		return {"captureError":"incomplete_tree_body"}
	return {"durableId":String(body.get_meta("prop_id", "")),
		"biome":String(body.get_meta("visual_biome", "")),
		"family":String(body.get_meta("tree_family", "")),
		"growthClass":String(body.get_meta("tree_growth_class", "")),
		"architecture":String(body.get_meta("tree_architecture", "")),
		"rotationYBits":bits(body.rotation.y),
		"visualHeightBits":bits(float(body.get_meta("tree_visual_height", 0.0))),
		"trunkRadiusBits":bits(float(body.get_meta("tree_trunk_radius", 0.0))),
		"canopyRadiusBits":bits(float(body.get_meta("tree_canopy_radius", 0.0))),
		"trunkRadius":float(body.get_meta("tree_trunk_radius", 0.0)),
		"canopyRadius":float(body.get_meta("tree_canopy_radius", 0.0)),
		"collisionHeightBits":bits(float(body.get_meta("tree_collision_height", 0.0))),
		"colliderRadiusBits":bits((collider.shape as CylinderShape3D).radius),
		"colliderHeightBits":bits((collider.shape as CylinderShape3D).height),
		"colliderCenterYBits":bits(collider.position.y)}

func direct_tree_halo_margins(main: Object, row: Dictionary) -> Dictionary:
	var profile: BiomeEnvironmentProfile = main.biome_environment_catalog.profile_for_biome(
		String(row.sourceBiome))
	var exclusion := float(profile.natural_prop_exclusion_margin)
	var trunk := maxf(0.12, float(row.tree.trunkRadius))
	var canopy := maxf(trunk, float(row.tree.canopyRadius))
	return {"ordinal":row.ordinal,
		"naturalMarginCells":ceili(maxf(0.0, trunk + exclusion) / MainScript.CELL),
		"structureMarginCells":ceili(maxf(0.0, canopy + exclusion) / MainScript.CELL)}

func run() -> void:
	var main = MainScript.new()
	main.apply_world_seed("atlas-1492", false)
	main.setup_biome_environment_catalog()
	main.setup_visual_asset_registry()
	main.setup_animated_asset_registry()
	main.setup_materials()
	var structures := Structures.new()
	structures.main = main
	structures.regional_source_generation = 1
	var admission := Admission.new()
	admission.configure(main.seed_text, {}, {"regionCells":384,"spawnChance":0.0})
	admission.finalize_town_inputs({})
	structures.citadel_terrain_admission = admission
	main.structure_system = structures
	var cases := []
	for spec in [
		{"chunk": Vector2i.ZERO, "removed": []},
		{"chunk": Vector2i.ZERO, "removed": ["atlas-1492:16,17:0"]},
		{"chunk": Vector2i(-1, -1), "removed": []}]:
		main.restore_removed_props(spec.removed)
		cases.append(run_case(main, spec.chunk, spec.removed))
	# This seed/chunk was found by a one-time, bounded native-outcome search.
	# Pinning it keeps each later differential focused and reproducible.
	var ore_chunk := Vector2i(3, 2)
	var ore_case: Dictionary = run_case(main, ore_chunk, [])
	var ore_chunk_found := false
	for row in ore_case.native:
		if int(row.outcome) in [6, 7]:
			ore_chunk_found = true
			break
	if ore_chunk_found:
		cases.append(ore_case)
		for row in ore_case.native:
			if int(row.outcome) in [6, 7]:
				var child_tombstone := String(row.durableId) + ":cluster1"
				main.restore_removed_props([child_tombstone])
				cases.append(run_case(main, ore_chunk, [child_tombstone]))
				main.restore_removed_props([])
				break
	# A blocker can originate outside the 28-cell source chunk but intersect
	# a post-draw tree margin. The center-cell stream must stay unchanged.
	var edge_case_ready := false
	for request in cases[0].nativeTreeHaloRequests:
		if not cases[0].direct[int(request.ordinal)].has("tree"): continue
		var cell := Vector2i(int(request.cell[0]), int(request.cell[1]))
		var margin := int(request.naturalMarginCells)
		var outside := Vector2i(2147483647, 2147483647)
		if cell.x - margin < 0: outside = Vector2i(-1, cell.y)
		elif cell.x + margin >= 28: outside = Vector2i(28, cell.y)
		elif cell.y - margin < 0: outside = Vector2i(cell.x, -1)
		elif cell.y + margin >= 28: outside = Vector2i(cell.x, 28)
		if outside.x == 2147483647: continue
		main.structure_system.reserve_natural_prop_exclusion(outside.x, outside.y, 1, 1, "n4_edge_halo")
		var edge_case: Dictionary = run_case(main, Vector2i.ZERO, [])
		edge_case["edgeBlockerCell"] = [outside.x, outside.y]
		edge_case["edgeBlockerId"] = "n4_edge_halo:%d,%d:1x1" % [outside.x, outside.y]
		cases.append(edge_case)
		edge_case_ready = true
		break
	var result := {"scope":"direct_production_method_and_native_shadow_contract_not_live_gameplay",
		"seed":main.seed_text,"cases":cases,"oreFixtureChunk":[ore_chunk.x,ore_chunk.y],
		"oreChunkFound":ore_chunk_found,"edgeCaseReady":edge_case_ready}
	var path := OS.get_environment("N4_DIRECT_SOURCE_ORDER_PROBE_REPORT")
	if path.is_empty():
		push_error("N4_DIRECT_SOURCE_ORDER_PROBE_REPORT is required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	await process_frame
	main.free()
	quit(0)

func run_case(main: Object, chunk_key: Vector2i, removed: Array) -> Dictionary:
	var chunk := Node3D.new()
	root.add_child(chunk)
	chunk.global_position = Vector3(float(chunk_key.x * 28) * 1.35, 0.0,
		float(chunk_key.y * 28) * 1.35)
	var state: Dictionary = main.begin_chunk_prop_spawn_state(chunk, chunk_key.x, chunk_key.y)
	var backend = ClassDB.instantiate("NativeWorldBackend")
	var initialized: Dictionary = backend.initialize(native_initialization(main.seed_text))
	var bundle: Dictionary = Bundle.capture_terrain_chunk(main, chunk_key, backend)
	var admissions := {}
	if initialized.get("status") == "ready" and bool(bundle.get("ok", false)):
		var owner: Dictionary = bundle.sources.owner
		admissions["biome"] = backend.admit_biome_environment_catalog(owner.biome).get("status")
		admissions["visual"] = backend.admit_visual_asset_catalog(owner).get("status")
		admissions["removed"] = backend.admit_removed_props_tombstones(owner.removed).get("status")
		admissions["wildlife"] = backend.admit_wildlife_presentation_catalog(owner).get("status")
	var structure_receipt: Dictionary = backend.admit_structure_exclusion_chunk(bundle.sources.exclusions) \
		if bool(bundle.get("ok", false)) else {}
	var ordered: Dictionary = backend.compose_surface_prop_ordered_shadow(
		bundle.terrain.page, structure_receipt.snapshot) \
		if structure_receipt.get("status") == "ready" else {}
	var tree_requests: Array = ordered.get("treeHaloRequests", [])
	var tree_halo: Dictionary = TreeHalo.capture(main.structure_system, tree_requests) \
		if not tree_requests.is_empty() else {}
	var rng: RandomNumberGenerator = state.rng
	var direct_rows := []
	for index in range(28):
		var before_state := rng.state
		var preview := RandomNumberGenerator.new()
		preview.seed = rng.seed
		preview.state = before_state
		var x: int = state.startX + 2 + preview.randi_range(0, 24)
		var z: int = state.startZ + 2 + preview.randi_range(0, 24)
		var sample: Dictionary = main.surface_volume_spawn_sample_at_cell(x, z)
		var child_count_before := chunk.get_child_count()
		main.spawn_chunk_prop_attempt(state, index, rng)
		var id := "%s:%d,%d:%d" % [main.seed_text,x,z,index]
		var direct_row := {"ordinal":index,"cell":[x,z],
			"durableId":id,"sourceSampleApplicable":not removed.has(id),
			"stateBeforeCoordinates":str(before_state),"stateAfterRecipe":str(rng.state),
			"sourceBiome":String(sample.get("biome","")),
			"sourceHeightMeters":float(sample.get("height",0.0)),
			"surfaceFound":bool(sample.get("found",false)),
			"childCountDelta":chunk.get_child_count()-child_count_before}
		var ore_children := []
		for child in chunk.get_children():
			if child is StaticBody3D and child.get_meta("prop_id", "") == id \
					and String(child.get_meta("material", "")) in \
					["berryBush","aloePatch","mushroomCluster","frostHerbPatch"]:
				direct_row["forage"] = forage_geometry(child, main.materials)
			if child is StaticBody3D and String(child.get_meta("prop_id", "")) in [id,id + ":cluster1"] \
					and String(child.get_meta("material", "")) in ["ironOre","copperOre"]:
				ore_children.append(ore_geometry(child))
			if child is StaticBody3D and child.get_meta("prop_id", "") == id \
					and String(child.get_meta("material", "")) == "wildlife":
				direct_row["wildlife"] = wildlife_geometry(child)
			if child is StaticBody3D and child.get_meta("prop_id", "") == id \
					and String(child.get_meta("material", "")) == "rock":
				direct_row["rock"] = rock_geometry(child)
			if child is StaticBody3D and child.get_meta("prop_id", "") == id \
					and String(child.get_meta("material", "")) == "tree":
				direct_row["tree"] = tree_geometry(child)
		if not ore_children.is_empty():
			direct_row["oreChildren"] = ore_children
		direct_rows.append(direct_row)
	var native_rows := []
	for row in ordered.get("attempts", []):
		var feature: Dictionary = row.get("feature", {})
		var projected_feature := {}
		if feature.get("kind") == "forage":
			var meshes := []
			for mesh in feature.meshes:
				meshes.append({"kind":mesh.kind,
					"position":[mesh.position.x,mesh.position.y,mesh.position.z],
					"positionBits":vector_bits(mesh.position),
					"rotation":[mesh.rotation.x,mesh.rotation.y,mesh.rotation.z],
					"rotationBits":vector_bits(mesh.rotation),
					"scale":[mesh.scale.x,mesh.scale.y,mesh.scale.z],
					"scaleBits":vector_bits(mesh.scale),
					"materialId":mesh.materialId,"radius":mesh.radius,
					"radiusBits":bits(mesh.radius),"heightBits":bits(mesh.height),
					"height":mesh.height,"topRadius":mesh.topRadius,
					"topRadiusBits":bits(mesh.topRadius),"bottomRadiusBits":bits(mesh.bottomRadius),
					"bottomRadius":mesh.bottomRadius,
					"radialSegments":mesh.radialSegments,"rings":mesh.rings})
			projected_feature = {"kind":feature.kind,"contentIdentity":feature.contentIdentity,
				"materialId":feature.materialId,"dropId":feature.dropId,
				"dropCount":feature.dropCount,"rotationY":feature.rotationY,
				"rotationYBits":bits(feature.rotationY),
				"colliderRadius":feature.colliderRadius,
				"colliderRadiusBits":bits(feature.colliderRadius),
				"colliderCenterY":feature.colliderCenterY,
				"colliderCenterYBits":bits(feature.colliderCenterY),
				"physicalColliderPresent":feature.physicalColliderPresent,
				"navigationBlocker":feature.navigationBlocker,"meshes":meshes}
		elif feature.get("kind") == "oreCluster":
			var children := []
			for child in feature.children:
				var seams := []
				for seam in child.seams:
					seams.append({"positionBits":vector_bits(seam.localPosition),
						"rotationBits":vector_bits(seam.rotation),
						"meshSizeBits":vector_bits(child.seamMeshSize)})
				var glints := []
				for glint in child.glints:
					glints.append({"positionBits":vector_bits(glint.localPosition),
						"scaleBits":vector_bits(glint.scale),
						"meshRadiusBits":bits(child.glintMeshRadius),
						"meshHeightBits":bits(child.glintMeshHeight)})
				children.append({"durableId":child.durableId,"present":child.present,
					"dropCount":child.dropCount,
					"localPositionBits":vector_bits(child.localPosition),
					"rotationYBits":bits(child.rotationY),
					"meshRadiusBits":bits(child.meshRadius),
					"meshHeightBits":bits(child.meshHeight),
					"meshScaleBits":vector_bits(child.meshScale),
					"meshCenterYBits":bits(child.meshCenterY),
					"colliderRadiusBits":bits(child.colliderRadius),
					"colliderCenterYBits":bits(child.colliderCenterY),
					"seamCount":child.seams.size(),"glintCount":child.glints.size(),
					"seams":seams,"glints":glints})
			projected_feature = {"kind":feature.kind,"oreKind":feature.oreKind,
				"rootDurableId":feature.rootDurableId,"children":children}
		elif feature.get("kind") == "wildlife":
			projected_feature = {"kind":feature.kind,"variant":feature.variant,
				"primaryDropId":feature.primaryDropId,
				"primaryDropCount":feature.primaryDropCount,
				"extraDropId":feature.extraDropId,
				"extraDropCount":feature.extraDropCount,
				"bodyYawBits":bits(feature.bodyYaw),
				"colliderSizeBits":vector_bits(feature.colliderSize),
				"colliderCenterBits":vector_bits(feature.colliderCenter),
				"collisionLayer":feature.collisionLayer,
				"collisionMask":feature.collisionMask,"cold":feature.cold,
				"presentationPath":feature.presentationPath,
				"visualScaleBits":vector_bits(feature.visualScale),
				"visualRotationBits":vector_bits(feature.visualRotation),
				"animationSpeedBits":bits(feature.animationSpeedScale),
				"movementHomeBits":vector_bits(feature.movementHome),
				"movementDirectionBits":vector_bits(feature.movementDirection),
				"movementTimerBits":bits(feature.movementTimer),
				"movementSpeedBits":bits(feature.movementSpeed),
				"movementLastMoveBits":bits(feature.movementLastMove)}
		elif feature.get("kind") == "rock":
			var expected_rock_scale: Vector3 = feature.visualScale
			if int(feature.visualIntent) == 1:
				var radius: float = feature.visualRadius
				var height_factor: float = feature.visualHeightFactor
				var old_scale: Vector3 = feature.visualScale
				var asset_size: Vector3 = feature.assetSize
				var sx := (radius * 2.0 * old_scale.x) / maxf(0.1, asset_size.x)
				var sy := (radius * height_factor * old_scale.y) / maxf(0.1, asset_size.z)
				var sz := (radius * 2.0 * old_scale.z) / maxf(0.1, asset_size.y)
				expected_rock_scale = Vector3(sx, sy, sz) * float(feature.profileScale)
			projected_feature = {"kind":feature.kind,
				"durableId":feature.durableId,"visualBiome":feature.visualBiome,
				"rotationYBits":bits(feature.rotationY),
				"visualRadiusBits":bits(feature.visualRadius),
				"visualHeightFactorBits":bits(feature.visualHeightFactor),
				"visualScaleBits":vector_bits(feature.visualScale),
				"expectedRenderedScaleBits":vector_bits(expected_rock_scale),
				"colliderRadiusBits":bits(feature.colliderRadius),
				"colliderCenterYBits":bits(feature.colliderCenterY),
				"visualIntent":feature.visualIntent,"assetId":feature.assetId,
				"assetPath":feature.assetPath,
				"assetSizeBits":vector_bits(feature.assetSize),
				"profileScaleBits":bits(feature.profileScale)}
		elif feature.get("kind") == "treeDefinition":
			projected_feature = {"kind":feature.kind,
				"durableId":feature.durableId,"biome":feature.biome,
				"family":feature.family,"growthClass":feature.growthClass,
				"architecture":feature.architecture,
				"speciesGrammar":feature.speciesGrammar,
				"rotationYBits":bits(feature.rotationY),
				"visualHeightBits":bits(feature.visualHeight),
				"trunkRadiusBits":bits(feature.trunkRadius),
				"canopyRadiusBits":bits(feature.canopyRadius),
				"collisionHeightBits":bits(feature.collisionHeight),
				"exclusionMarginBits":bits(feature.exclusionMargin),
				"colliderRadiusBits":bits(feature.trunkColliderRadius),
				"colliderHeightBits":bits(feature.trunkColliderHeight),
				"colliderCenterYBits":bits(feature.trunkColliderCenterY),
				"haloRequired":feature.haloRequired}
		native_rows.append({"ordinal":row.ordinal,"cell":[row.cell.x,row.cell.y],
			"durableId":row.durableId,"stateBeforeCoordinates":row.stateBeforeCoordinates,
			"stateAfterRecipe":row.stateAfterRecipe,"sourceBiome":row.sourceBiome,
			"sourceHeightMeters":row.sourceHeightMeters,"outcome":row.outcome,
			"presence":row.presence,"feature":projected_feature})
	var result := {"chunk":[chunk_key.x,chunk_key.y],"removed":removed,
		"nativeInitialization":initialized.get("status"),
		"bundleReady":bundle.get("ok",false),"admissions":admissions,
		"structureAdmission":structure_receipt.get("status"),"orderedStatus":ordered.get("status"),
		"nativeTreeHaloRequests":tree_requests.map(func(row): return {
			"ordinal":row.ordinal,"cell":[row.cell.x,row.cell.y],
			"naturalMarginCells":row.naturalMarginCells,
			"structureMarginCells":row.structureMarginCells}),
		"godotTreeHaloMargins":direct_rows.filter(
			func(row): return row.has("tree")
		).map(func(row): return direct_tree_halo_margins(main, row)),
		"treeHaloCaptureReady":bool(tree_halo.get("ok", false)),
		"treeHaloCaptureCurrent":TreeHalo.is_current(main.structure_system, tree_halo) \
			if bool(tree_halo.get("ok", false)) else false,
		"treeHaloNaturalIds":tree_halo.halo.content.natural.map(func(row): return row.id) \
			if bool(tree_halo.get("ok", false)) else [],
		"direct":direct_rows,"native":native_rows,
		"nativeFinalRngState":ordered.get("finalRngState"),"directFinalRngState":str(rng.state),
		"childCount":chunk.get_child_count()}
	chunk.free()
	return result
