extends SceneTree

## Direct-service source-order probe. Not headed gameplay acceptance.
const MainScript := preload("res://scripts/Main.gd")
const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Bundle := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")

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
	var result := {"scope":"direct_production_method_and_native_shadow_contract_not_live_gameplay",
		"seed":main.seed_text,"cases":cases}
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
		direct_rows.append({"ordinal":index,"cell":[x,z],
			"durableId":"%s:%d,%d:%d" % [main.seed_text,x,z,index],
			"sourceSampleApplicable":not removed.has("%s:%d,%d:%d" % [main.seed_text,x,z,index]),
			"stateBeforeCoordinates":str(before_state),"stateAfterRecipe":str(rng.state),
			"sourceBiome":String(sample.get("biome","")),
			"sourceHeightMeters":float(sample.get("height",0.0)),
			"surfaceFound":bool(sample.get("found",false)),
			"childCountDelta":chunk.get_child_count()-child_count_before})
	var native_rows := []
	for row in ordered.get("attempts", []):
		native_rows.append({"ordinal":row.ordinal,"cell":[row.cell.x,row.cell.y],
			"durableId":row.durableId,"stateBeforeCoordinates":row.stateBeforeCoordinates,
			"stateAfterRecipe":row.stateAfterRecipe,"sourceBiome":row.sourceBiome,
			"sourceHeightMeters":row.sourceHeightMeters,"outcome":row.outcome,
			"presence":row.presence})
	var result := {"chunk":[chunk_key.x,chunk_key.y],"removed":removed,
		"nativeInitialization":initialized.get("status"),
		"bundleReady":bundle.get("ok",false),"admissions":admissions,
		"structureAdmission":structure_receipt.get("status"),"orderedStatus":ordered.get("status"),
		"direct":direct_rows,"native":native_rows,
		"nativeFinalRngState":ordered.get("finalRngState"),"directFinalRngState":str(rng.state),
		"childCount":chunk.get_child_count()}
	chunk.free()
	return result
