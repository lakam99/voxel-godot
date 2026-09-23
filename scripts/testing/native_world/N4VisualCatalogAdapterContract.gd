extends SceneTree

const MainScript := preload("res://scripts/Main.gd")
const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const VisualScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const AnimatedScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")
const BundleScript := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		push_error(label)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"visual-bundle-test",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend class")
	if backend == null:
		finish()
		return
	check(backend.initialize(initialization()).get("status") == "ready", "backend initialization")
	var main = MainScript.new()
	main.seed_text = "visual-bundle-test"
	var biome = CatalogScript.new()
	var visual = VisualScript.new()
	var animated = AnimatedScript.new()
	check(biome.setup(), "biome source ready")
	check(visual.setup(biome), "visual source ready")
	check(animated.setup(), "animated source ready")
	main.biome_environment_catalog = biome
	main.visual_asset_registry = visual
	main.animated_asset_registry = animated
	var bundle: Dictionary = BundleScript.capture(main)
	check(bool(bundle.get("ok", false)), "coherent owner bundle")
	check(backend.admit_visual_asset_catalog(bundle).get("status") == "failed", "biome prerequisite")
	var biome_receipt: Dictionary = backend.admit_biome_environment_catalog(bundle.biome)
	check(biome_receipt.get("status") == "ready", "biome admission")
	var receipt: Dictionary = backend.admit_visual_asset_catalog(bundle)
	check(receipt.get("status") == "ready", "visual admission: " + str(receipt.get("reason")))
	check(receipt.get("shadowOnly") == true and receipt.get("completeSurfacePropSource") == false
		and receipt.get("importReadinessProven") == false and receipt.get("liveCaptureFreshnessProven") == false,
		"shadow scope")
	check(receipt.get("nativeOwnerInstanceId") == backend.get_instance_id()
		and receipt.get("biomeCatalogIdentity") == biome_receipt.get("nativeCatalogIdentity")
		and backend.status().get("visualCatalogIdentity") == receipt.get("nativeCatalogIdentity"),
		"native owner and biome identity")
	check(receipt.get("rockGlbBytesVerified") == true and receipt.get("rockBoundsCount") == 6,
		"six active rock GLB bytes verified")
	for number in range(1, 7):
		var target_id := "rock_%02d" % number
		var prop_id := ""
		for candidate in range(10000):
			var proposed := "rock-bound-admission:%s:%d" % [target_id, candidate]
			if visual.select_rock_asset_id("forest", proposed) == target_id:
				prop_id = proposed
				break
		check(not prop_id.is_empty(), "rock selection search: " + target_id)
		if prop_id.is_empty():
			continue
		var selected_bounds: Dictionary = backend.select_rock_asset_shadow("forest", prop_id)
		var asset: Dictionary = visual.asset_record(target_id)
		var geometry: Dictionary = asset.get("rockGeometry", {})
		var expected_min: Array = geometry.get("min", [])
		var expected_max: Array = geometry.get("max", [])
		var actual_min: Vector3 = selected_bounds.get("importedMeshMin", Vector3.INF)
		var actual_max: Vector3 = selected_bounds.get("importedMeshMax", Vector3.INF)
		check(selected_bounds.get("rockBoundsReady") == true
			and selected_bounds.get("rockGlbSha256") == FileAccess.get_sha256("res://" + String(asset.path))
			and expected_min.size() == 3 and expected_max.size() == 3
			and actual_min.distance_to(
				Vector3(expected_min[0], expected_min[1], expected_min[2])) < 0.000001
			and actual_max.distance_to(
				Vector3(expected_max[0], expected_max[1], expected_max[2])) < 0.000001,
			"selected rock source bounds and file SHA: " + target_id)
	for case in [{"biome":"forest", "id":"atlas-1492:10,20:3"},
		{"biome":"swamp", "id":"atlas-1492:10,20:3"},
		{"biome":"desert", "id":"atlas-1492:10,20:3"},
		{"biome":"future_biome", "id":"atlas-1492:10,20:3"},
		{"biome":"forest", "id":"世界🌲:10,20:3"}]:
		var selected: Dictionary = backend.select_rock_asset_shadow(case.biome, case.id)
		check(selected.get("status") == "ready" and selected.get("assetId") == visual.select_rock_asset_id(case.biome, case.id),
			"registry selection parity: " + str(case))
	var rock_record: Dictionary = visual.assets_by_id["rock_01"]
	var original_geometry: Dictionary = rock_record.rockGeometry.duplicate(true)
	rock_record.rockGeometry.glbSha256 = "0".repeat(64)
	visual.assets_by_id["rock_01"] = rock_record
	var stale_file_bundle: Dictionary = BundleScript.capture(main)
	check(bool(stale_file_bundle.get("ok", false)), "stale rock file recapture constructed")
	var stale_receipt: Dictionary = backend.admit_visual_asset_catalog(stale_file_bundle)
	check(stale_receipt.get("status") == "failed"
		and String(stale_receipt.get("reason", "")).contains("rock GLB bytes differ")
		and backend.status().get("visualCatalogReady") == false,
		"same owner recapture with stale rock GLB hash rejects")
	rock_record.rockGeometry = original_geometry
	visual.assets_by_id["rock_01"] = rock_record
	check(backend.admit_visual_asset_catalog(bundle).get("status") == "ready",
		"valid rock geometry source recovers after rejected recapture")
	var tampered := bundle.duplicate(true)
	tampered.visual.contentIdentity = "0".repeat(64)
	check(backend.admit_visual_asset_catalog(tampered).get("status") == "failed"
		and backend.status().get("visualCatalogReady") == false
		and backend.select_rock_asset_shadow("forest", "id").get("status") == "failed",
		"identity tamper fails closed")
	var rock_ids: Array = visual.assets_by_family["rock"]
	rock_ids.append(rock_ids[0])
	var duplicate_bundle: Dictionary = BundleScript.capture(main)
	check(bool(duplicate_bundle.get("ok", false)), "duplicate membership recapture")
	var duplicate_receipt: Dictionary = backend.admit_visual_asset_catalog(duplicate_bundle)
	check(duplicate_receipt.get("status") == "ready"
		and duplicate_receipt.get("nativeCatalogIdentity") != receipt.get("nativeCatalogIdentity"),
		"duplicate membership changes native catalog")
	var duplicate_selection: Dictionary = backend.select_rock_asset_shadow("forest", "atlas-1492:10,20:3")
	check(duplicate_selection.get("candidateCount") == 7
		and duplicate_selection.get("assetId") == visual.select_rock_asset_id("forest", "atlas-1492:10,20:3"),
		"duplicate membership selection parity")
	visual.assets_by_id["rock_01"].erase("biomeTags")
	visual.assets_by_id["rock_01"].erase("boundingBox")
	var fallback_bundle: Dictionary = BundleScript.capture(main)
	check(bool(fallback_bundle.get("ok", false)), "active registry fallback recapture")
	check(backend.admit_visual_asset_catalog(fallback_bundle).get("status") == "ready",
		"missing optional registry fields admitted")
	var fallback_selected: Dictionary = backend.select_rock_asset_shadow("future_biome", "id")
	check(fallback_selected.get("assetId") == visual.select_rock_asset_id("future_biome", "id")
		and fallback_selected.get("assetSize") == visual.asset_size("rock_01")
		and fallback_selected.get("assetSize") == Vector3.ONE,
		"empty tags and missing size match live registry fallbacks")
	var reset_biome: Dictionary = backend.admit_biome_environment_catalog(bundle.biome)
	check(reset_biome.get("status") == "ready" and backend.status().get("visualCatalogReady") == false,
		"biome replacement invalidates visual catalog")
	main.free()
	finish()

func finish() -> void:
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-visual-catalog-adapter-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"finished":true,"passed":failures.is_empty(),
			"evidenceLevel":"Godot adapter contract",
			"scope":"Effective visual registry admission, on-disk rock GLB hashes and imported bounds; no live selected/fallback outcome, full surface manifest or gameplay.",
			"failures":failures}, "  "))
		file.close()
	quit(0 if failures.is_empty() and file != null else 1)
