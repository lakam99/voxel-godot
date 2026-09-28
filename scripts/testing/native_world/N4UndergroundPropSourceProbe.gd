extends SceneTree

## Direct production-method differential for the N4 underground prop source.
## This is a source/recipe shadow fixture, not headed gameplay acceptance.
const MainScript := preload("res://scripts/Main.gd")
const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Bundle := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")

func _init() -> void:
	call_deferred("run")

func native_initialization(seed_text: String) -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":seed_text,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.0,"townOverrides":[]}}

func bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_u32(0)

func vector_bits(value: Vector3) -> Array:
	return [bits(value.x), bits(value.y), bits(value.z)]

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
				"positionBits":vector_bits(child.position),
				"rotationBits":vector_bits(child.rotation),
				"scaleBits":vector_bits(child.scale),"materialId":role}
			if mesh is SphereMesh:
				row.merge({"radiusBits":bits(mesh.radius),"heightBits":bits(mesh.height),
					"radialSegments":mesh.radial_segments,"rings":mesh.rings})
			elif mesh is CylinderMesh:
				row.merge({"topRadiusBits":bits(mesh.top_radius),
					"bottomRadiusBits":bits(mesh.bottom_radius),"heightBits":bits(mesh.height),
					"radialSegments":mesh.radial_segments})
			meshes.append(row)
		elif child is CollisionShape3D and child.shape is SphereShape3D:
			collider = {"radiusBits":bits(child.shape.radius),
				"centerYBits":bits(child.position.y)}
	return {"materialId":body.get_meta("material"),"dropId":body.get_meta("drop"),
		"dropCount":body.get_meta("drop_count"),"rotationYBits":bits(body.rotation.y),
		"collider":collider,"meshes":meshes}

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

func result_for_new_children(
		chunk: Node3D, first_index: int, durable_id: String, materials: Dictionary) -> Dictionary:
	for index in range(first_index, chunk.get_child_count()):
		var child := chunk.get_child(index)
		if not child is StaticBody3D:
			continue
		var prop_id := String(child.get_meta("prop_id", ""))
		if prop_id != durable_id:
			continue
		var body := child as StaticBody3D
		var material := String(body.get_meta("material", ""))
		var row := {"localPosition":[body.position.x, body.position.y, body.position.z],
			"definition":{"material":material,"dropId":String(body.get_meta("drop", "")),
				"dropCount":int(body.get_meta("drop_count", 0)),"rotationY":body.rotation.y}}
		var collider: CollisionShape3D = null
		var first_mesh: MeshInstance3D = null
		for part in body.get_children():
			if collider == null and part is CollisionShape3D:
				collider = part
			elif first_mesh == null and part is MeshInstance3D:
				first_mesh = part
		if collider != null and collider.shape is SphereShape3D:
			row.definition["colliderRadius"] = (collider.shape as SphereShape3D).radius
			row.definition["colliderCenterY"] = collider.position.y
		if first_mesh != null and first_mesh.mesh is SphereMesh:
			row.definition["meshRadius"] = (first_mesh.mesh as SphereMesh).radius
			row.definition["meshHeight"] = (first_mesh.mesh as SphereMesh).height
			row.definition["meshScale"] = [first_mesh.scale.x, first_mesh.scale.y, first_mesh.scale.z]
		row.definition["visualBiome"] = String(body.get_meta("visual_biome", ""))
		row.definition["assetId"] = String(body.get_meta("visual_asset_id", ""))
		if material == "ironOre": row["family"] = "ironOre"
		elif material == "copperOre": row["family"] = "copperOre"
		if material in ["berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"]:
			row["family"] = "forage"
		elif not row.has("family"):
			row["family"] = "rock"
		if row.family in ["ironOre", "copperOre"]:
			row["geometry"] = ore_geometry(body)
		elif row.family == "forage":
			row["geometry"] = forage_geometry(body, materials)
		elif row.family == "rock":
			row["geometry"] = rock_geometry(body)
		return row
	return {"family":"none"}

func direct_case(main: Object, chunk_key: Vector2i, removed: Array) -> Dictionary:
	main.restore_removed_props(removed)
	var chunk := Node3D.new()
	root.add_child(chunk)
	chunk.global_position = Vector3(float(chunk_key.x * 28) * MainScript.CELL, 0.0,
		float(chunk_key.y * 28) * MainScript.CELL)
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
	var native: Dictionary = backend.compose_underground_prop_ordered_shadow(
		bundle.terrain.page, chunk_key) if bool(bundle.get("ok", false)) else {}
	var cells: Array[Vector3i] = main.underground_prop_candidate_cells(chunk_key.x, chunk_key.y)
	var direct := []
	var rng: RandomNumberGenerator = state.undergroundRng
	for ordinal in range(cells.size()):
		var cell := cells[ordinal]
		var durable_id := "%s:underground:%d,%d,%d" % [main.seed_text, cell.x, cell.y, cell.z]
		var sample: Dictionary = main.world_generation_system.call("sample_cell", cell)
		var before_state := rng.state
		var preview := RandomNumberGenerator.new()
		preview.seed = rng.seed
		preview.state = before_state
		var parent_tombstoned := removed.has(durable_id)
		var selection_roll := -1.0
		if not parent_tombstoned:
			selection_roll = preview.randf()
		var state_after_selection := preview.state
		var deep_iron_roll := -1.0
		var material := String(sample.get("material", ""))
		if not parent_tombstoned and material not in ["copperOre", "ironOre"] and selection_roll < 0.12 \
				and material in ["stone", "deepStone", "bedrock"] and cell.y < -22:
			deep_iron_roll = preview.randf()
		var first_child := chunk.get_child_count()
		main.spawn_underground_prop_attempt(state, cell, rng)
		var direct_row := {"ordinal":ordinal,"floorCell":[cell.x,cell.y,cell.z],
			"durableId":durable_id,"material":material,
			"candidateRoll":main.hash01("underground-prop-candidate:%d,%d,%d" % [cell.x,cell.y,cell.z]),
			"stateBefore":str(before_state),
			"stateAfterSelection":str(state_after_selection),
			"stateAfterRecipe":str(rng.state),
			"selectionRoll":selection_roll,"deepIronRoll":deep_iron_roll,
			"parentTombstoned":parent_tombstoned}
		direct_row.merge(result_for_new_children(chunk, first_child, durable_id, main.materials))
		direct.append(direct_row)
	var result := {"chunk":[chunk_key.x,chunk_key.y],"removed":removed.duplicate(),
		"initialization":initialized.get("status"),"bundleReady":bool(bundle.get("ok",false)),
		"admissions":admissions,"direct":direct,"native":native,
		"directFinalRngState":str(rng.state)}
	chunk.free()
	var process_chunk := Node3D.new()
	root.add_child(process_chunk)
	process_chunk.global_position = Vector3(float(chunk_key.x * 28) * MainScript.CELL, 0.0,
		float(chunk_key.y * 28) * MainScript.CELL)
	var process_state: Dictionary = main.begin_chunk_prop_spawn_state(
		process_chunk, chunk_key.x, chunk_key.y)
	while not main.process_underground_chunk_prop_spawn_state(process_state, 36, -1.0, 0):
		pass
	var process_cells := []
	for cell_value in process_state.get("undergroundCandidates", []):
		if cell_value is Vector3i:
			process_cells.append([cell_value.x, cell_value.y, cell_value.z])
	var process_rng: RandomNumberGenerator = process_state.undergroundRng
	result["processReplay"] = {"candidateCells":process_cells,
		"finalRngState":str(process_rng.state),
		"publishedChildCount":process_chunk.get_child_count()}
	process_chunk.free()
	return result

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
	var intact: Dictionary = direct_case(main, Vector2i.ZERO, [])
	var removed := []
	if not intact.direct.is_empty():
		removed = [String(intact.direct[0].durableId)]
	var tombstoned: Dictionary = direct_case(main, Vector2i.ZERO, removed)
	var negative: Dictionary = direct_case(main, Vector2i(-1, -1), [])
	var ore_search: Dictionary = direct_case(main, Vector2i(5, 3), [])
	var result := {"scope":"direct_production_method_and_native_diagnostic_shadow_not_gameplay",
		"seed":main.seed_text,"cases":[intact,tombstoned,negative,ore_search]}
	var path := OS.get_environment("N4_UNDERGROUND_PROP_PROBE_REPORT")
	if path.is_empty():
		push_error("N4_UNDERGROUND_PROP_PROBE_REPORT is required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	await process_frame
	main.free()
	quit(0)
