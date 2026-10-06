extends SceneTree

const MainScript := preload("res://scripts/Main.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const AnimatedScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")
const BundleScript := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")
const BiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const VisualSnapshot := preload("res://scripts/visual/ActiveVisualAssetSnapshot.gd")
const RemovedSnapshot := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const Structures := preload("res://scripts/StructureSystem.gd")
const Admission := preload("res://scripts/world/CitadelTerrainAdmission.gd")

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})
	if not passed:
		push_error("surface owner bundle: " + name)

func run() -> void:
	var main = MainScript.new()
	main.seed_text = "bundle-seed"
	main.removed_props = {"bundle-seed:1,2:0": true}
	check("unready_rejected", not bool(BundleScript.capture(main).get("ok", false)))
	var catalog = CatalogScript.new()
	var visual = VisualScript.new()
	var animated = AnimatedScript.new()
	check("catalog_ready", catalog.setup())
	check("visual_ready", visual.setup(catalog))
	check("animated_ready", animated.setup())
	main.biome_environment_catalog = catalog
	main.visual_asset_registry = visual
	main.animated_asset_registry = animated
	var capture_start_usec := Time.get_ticks_usec()
	var bundle: Dictionary = BundleScript.capture(main)
	var capture_ms := float(Time.get_ticks_usec() - capture_start_usec) / 1000.0
	check("bundle_captured", bool(bundle.get("ok", false)))
	check("explicitly_incomplete", bundle.get("complete") == false \
		and bundle.get("scope") == "owner_catalogs_and_removals_only")
	var freshness_start_usec := Time.get_ticks_usec()
	var initially_current: bool = BundleScript.is_current(main, bundle)
	var freshness_ms := float(Time.get_ticks_usec() - freshness_start_usec) / 1000.0
	check("initial_current", initially_current)
	check("sealed_biome_alias_retained", is_same(bundle.biome, BiomeSnapshot.capture(catalog)))
	check("sealed_visual_alias_retained", is_same(bundle.visual.publication,
		visual.published_catalog_snapshot(catalog.published_catalog_snapshot())))
	check("sealed_presentation_alias_retained", is_same(bundle.presentation,
		animated.capture_active_presentation()))
	check("copied_catalog_bundle_rejected", not BundleScript.is_current(main, bundle.duplicate(true)))
	var structures := Structures.new()
	var admission := Admission.new()
	admission.configure(main.seed_text, {}, {"regionCells":384, "spawnChance":0.0})
	check("chunk_town_inputs_finalized", admission.finalize_town_inputs({}).status == "ready")
	structures.main = main
	structures.regional_source_generation = 1
	structures.citadel_terrain_admission = admission
	main.structure_system = structures
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check("native_backend_available", backend != null)
	if backend != null:
		var initialized: Dictionary = backend.initialize({
			"schema":"n3-native-world-backend-initialize/v1", "seedText":main.seed_text,
			"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
				"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
			"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
				"worldBottomCellY":-64,"waterLevelMeters":11.1,
				"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
			"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
				"ordinaryRegionCells":140,"ordinarySpawnChance":0.0,"townOverrides":[]}})
		check("native_backend_initialized", initialized.get("status") == "ready")
		var terrain_bundle: Dictionary = BundleScript.capture_terrain_chunk(main, Vector2i.ZERO, backend)
		check("terrain_bundle_captured", bool(terrain_bundle.get("ok", false)))
		check("terrain_bundle_explicitly_incomplete", terrain_bundle.get("complete") == false \
			and terrain_bundle.get("scope") == "owner_structure_and_effective_terrain_chunk_only")
		check("terrain_bundle_current", BundleScript.terrain_chunk_is_current(main, backend, terrain_bundle))
		check("nested_catalog_alias_retained", is_same(terrain_bundle.sources.owner.biome, bundle.biome) \
			and is_same(terrain_bundle.sources.owner.presentation, bundle.presentation))
		var native_owner: Dictionary = BundleScript.native_admission_projection(main, terrain_bundle.sources.owner)
		check("native_projection_admitted_from_current_owner", bool(native_owner.get("ok", false)))
		var structure_receipt: Dictionary = backend.admit_structure_exclusion_chunk(
			terrain_bundle.sources.exclusions)
		check("native_structure_chunk_admitted", structure_receipt.get("status") == "ready")
		if structure_receipt.get("status") == "ready":
			var native_chunk: Object = structure_receipt.snapshot
			var native_status: Dictionary = native_chunk.status()
			var native_clear: Dictionary = native_chunk.query(Vector2i.ZERO)
			check("native_structure_chunk_bound", native_status.get("chunk") == Vector2i.ZERO \
				and native_status.get("ownerGeneration") == structures.regional_source_generation \
				and native_status.get("completeFeatureManifest") == false)
			check("native_structure_chunk_clear", native_clear.get("complete") == true \
				and native_clear.get("blocked") == false)
			check("ordered_biome_admitted", backend.admit_biome_environment_catalog(
				native_owner.biome).get("status") == "ready")
			check("ordered_visual_admitted", backend.admit_visual_asset_catalog(
				native_owner).get("status") == "ready")
			check("ordered_removed_admitted", backend.admit_removed_props_tombstones(
				terrain_bundle.sources.owner.removed).get("status") == "ready")
			check("ordered_wildlife_admitted", backend.admit_wildlife_presentation_catalog(
				native_owner).get("status") == "ready")
			var ordered: Dictionary = backend.compose_surface_prop_ordered_shadow(
				terrain_bundle.terrain.page, native_chunk)
			check("ordered_native_28_attempts", ordered.get("status") == "ready" \
				and ordered.get("attemptCount") == 28 \
				and (ordered.get("attempts", []) as Array).size() == 28 \
				and String(ordered.get("placementIdentity", "")).length() == 64)
			check("ordered_native_shadow_scope", ordered.get("completeFeatureManifest") == false \
				and ordered.get("liveCaptureFreshnessProven") == false)
			check("ordered_native_owner_bundle_still_current",
				BundleScript.terrain_chunk_is_current(main, backend, terrain_bundle))
		var forged_exclusions: Dictionary = terrain_bundle.sources.exclusions.duplicate(true)
		forged_exclusions.content.citadel[0].reason = "forged"
		check("native_structure_content_tamper_rejected",
			backend.admit_structure_exclusion_chunk(forged_exclusions).get("status") == "failed")
		forged_exclusions = terrain_bundle.sources.exclusions.duplicate(true)
		forged_exclusions.admissionSeed = "different-seed"
		check("native_structure_seed_tamper_rejected",
			backend.admit_structure_exclusion_chunk(forged_exclusions).get("status") == "failed")
		forged_exclusions = terrain_bundle.sources.exclusions.duplicate(true)
		forged_exclusions.content.citadel.clear()
		forged_exclusions.contentIdentity = Marshalls.raw_to_base64(var_to_bytes([
			forged_exclusions.chunk, forged_exclusions.bounds, forged_exclusions.content])).sha256_text()
		check("native_structure_missing_region_rejected",
			backend.admit_structure_exclusion_chunk(forged_exclusions).get("status") == "failed")
		var tampered_terrain := terrain_bundle.duplicate()
		tampered_terrain.terrain = terrain_bundle.terrain.duplicate(true)
		tampered_terrain.terrain.pageStatus.terrainDeltaRevision = -1
		check("terrain_bundle_pin_tamper_rejected", not BundleScript.terrain_chunk_is_current(main, backend, tampered_terrain))
		main.seed_text = "replacement-seed"
		check("terrain_bundle_seed_replacement_rejected", not BundleScript.terrain_chunk_is_current(main, backend, terrain_bundle))
		main.seed_text = "bundle-seed"
	var chunk_bundle := BundleScript.capture_chunk(main, Vector2i.ZERO)
	check("chunk_bundle_captured", bool(chunk_bundle.get("ok", false)))
	check("chunk_bundle_explicitly_incomplete", chunk_bundle.get("complete") == false \
		and chunk_bundle.get("scope") == "owner_and_structure_chunk_only")
	check("chunk_bundle_current", BundleScript.chunk_is_current(main, chunk_bundle))
	admission.configure("different-seed", {}, {"regionCells":384, "spawnChance":0.0})
	check("chunk_admission_seed_change_rejected", not BundleScript.chunk_is_current(main, chunk_bundle))
	check("mismatched_admission_finalized", admission.finalize_town_inputs({}).status == "ready")
	check("chunk_mismatched_seed_not_captured", not BundleScript.capture_chunk(main, Vector2i.ZERO).ok)
	admission.configure(main.seed_text, {}, {"regionCells":384, "spawnChance":0.0})
	check("matching_admission_finalized", admission.finalize_town_inputs({}).status == "ready")
	check("chunk_same_seed_new_generation_rejected", not BundleScript.chunk_is_current(main, chunk_bundle))
	chunk_bundle = BundleScript.capture_chunk(main, Vector2i.ZERO)
	check("chunk_recap_after_admission_reset", BundleScript.chunk_is_current(main, chunk_bundle))
	var changed_chunk := chunk_bundle.duplicate()
	changed_chunk.exclusions = chunk_bundle.exclusions.duplicate(true)
	changed_chunk.exclusions.content.citadel[0].reason = "forged"
	check("chunk_exclusion_tamper_rejected", not BundleScript.chunk_is_current(main, changed_chunk))
	structures.regional_source_generation += 1
	check("chunk_structure_generation_rejected", not BundleScript.chunk_is_current(main, chunk_bundle))
	structures.regional_source_generation -= 1
	main.structure_system = null
	check("chunk_structure_replacement_rejected", not BundleScript.chunk_is_current(main, chunk_bundle))
	main.structure_system = structures
	var freshness_parts := {}
	var part_start := Time.get_ticks_usec()
	check("biome_current", BiomeSnapshot.is_current(catalog, bundle.biome))
	freshness_parts["biomeMs"] = float(Time.get_ticks_usec() - part_start) / 1000.0
	part_start = Time.get_ticks_usec()
	check("visual_current", VisualSnapshot.is_current(visual, bundle.visual))
	freshness_parts["visualMs"] = float(Time.get_ticks_usec() - part_start) / 1000.0
	part_start = Time.get_ticks_usec()
	check("presentation_current", animated.presentation_capture_is_current(bundle.presentation))
	freshness_parts["presentationMs"] = float(Time.get_ticks_usec() - part_start) / 1000.0
	part_start = Time.get_ticks_usec()
	check("removed_current", RemovedSnapshot.is_current(main, bundle.removed))
	freshness_parts["removedMs"] = float(Time.get_ticks_usec() - part_start) / 1000.0
	var forged_complete := bundle.duplicate()
	forged_complete.complete = true
	check("complete_claim_rejected", not BundleScript.is_current(main, forged_complete))
	var tampered := bundle.duplicate()
	tampered.removed = bundle.removed.duplicate(true)
	(tampered.removed.ids as Array)[0] = "tampered"
	check("nested_removal_tamper_rejected", not BundleScript.is_current(main, tampered))
	var other = MainScript.new()
	other.seed_text = main.seed_text
	other.removed_props = main.removed_props.duplicate(true)
	other.biome_environment_catalog = catalog
	other.visual_asset_registry = visual
	other.animated_asset_registry = animated
	check("cross_main_rejected", not BundleScript.is_current(other, bundle))
	other.free()
	var original_seed: String = main.seed_text
	main.seed_text = "replacement-seed"
	check("seed_change_rejected", not BundleScript.is_current(main, bundle))
	main.seed_text = original_seed
	main.restore_removed_props(["bundle-seed:1,2:0"])
	check("same_content_restore_rejected", not BundleScript.is_current(main, bundle))
	var recaptured: Dictionary = BundleScript.capture(main)
	check("recapture_current", BundleScript.is_current(main, recaptured))
	var other_visual = VisualScript.new()
	check("replacement_visual_ready", other_visual.setup(catalog))
	main.visual_asset_registry = other_visual
	check("registry_replacement_rejected", not BundleScript.is_current(main, recaptured))
	check("stale_owner_cannot_project_native", not bool(BundleScript.native_admission_projection(
		main, recaptured).get("ok", false)))
	main.free()
	var passed := true
	for item in results:
		passed = passed and bool(item.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-active-surface-owner-bundle-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed,
		"evidenceLevel": "contract", "resultCount": results.size(), "results": results,
		"captureMs": capture_ms, "freshnessMs": freshness_ms,
		"freshnessParts": freshness_parts,
		"scope": "Owner catalog/removal, structure-exclusion and native effective-terrain chunk pin capture/freshness only; no native feature manifest or gameplay."}, "  "))
	file.close()
	quit(0 if passed else 1)
