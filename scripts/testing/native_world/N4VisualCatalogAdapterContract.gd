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
	var owner_bundle: Dictionary = BundleScript.capture(main)
	check(BundleScript.is_current(main, owner_bundle), "sealed owner current before projection")
	var bundle: Dictionary = BundleScript.native_admission_projection(main, owner_bundle)
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
	# Synthetic ABI mutations exercise native validation without editing the
	# registry's detached compatibility views or asserting live publication.
	var stale_file_bundle: Dictionary = bundle.duplicate(true)
	for row: Dictionary in stale_file_bundle.visual.assets:
		if String(row.id) == "rock_01":
			row.value.rockGeometry.glbSha256 = "0".repeat(64)
	_refresh_visual_identity(stale_file_bundle)
	var stale_receipt: Dictionary = backend.admit_visual_asset_catalog(stale_file_bundle)
	check(stale_receipt.get("status") == "failed"
		and String(stale_receipt.get("reason", "")).contains("rock GLB bytes differ")
		and backend.status().get("visualCatalogReady") == false,
		"synthetic stale rock GLB hash rejects")
	check(backend.admit_visual_asset_catalog(bundle).get("status") == "ready",
		"valid rock geometry source recovers after rejected input")
	var tampered := bundle.duplicate(true)
	tampered.visual.contentIdentity = "0".repeat(64)
	check(backend.admit_visual_asset_catalog(tampered).get("status") == "failed"
		and backend.status().get("visualCatalogReady") == false
		and backend.select_rock_asset_shadow("forest", "id").get("status") == "failed",
		"identity tamper fails closed")
	var duplicate_bundle: Dictionary = bundle.duplicate(true)
	var duplicate_ids: Array = []
	for family: Dictionary in duplicate_bundle.visual.families:
		if String(family.family) == "rock":
			family.orderedIds.append(family.orderedIds[0])
			duplicate_ids = family.orderedIds
	_refresh_visual_identity(duplicate_bundle)
	var duplicate_receipt: Dictionary = backend.admit_visual_asset_catalog(duplicate_bundle)
	check(duplicate_receipt.get("status") == "ready"
		and duplicate_receipt.get("nativeCatalogIdentity") != receipt.get("nativeCatalogIdentity"),
		"synthetic duplicate membership changes native catalog")
	var candidates: Array[String] = []
	for id: String in duplicate_ids:
		var asset: Dictionary = visual.assets_by_id[id]
		var tags: Array = asset.get("biomeTags", [])
		if tags.is_empty() or tags.has("forest"):
			candidates.append(id)
	if candidates.is_empty():
		for id: String in duplicate_ids:
			candidates.append(id)
	candidates.sort()
	var expected_id := candidates[visual.stable_index("rock:forest:atlas-1492:10,20:3", candidates.size())]
	var duplicate_selection: Dictionary = backend.select_rock_asset_shadow("forest", "atlas-1492:10,20:3")
	check(duplicate_selection.get("candidateCount") == 7
		and duplicate_selection.get("assetId") == expected_id,
		"synthetic duplicate membership ordered selection parity")
	var fallback_bundle: Dictionary = bundle.duplicate(true)
	for row: Dictionary in fallback_bundle.visual.assets:
		if String(row.id) == "rock_01":
			row.value.erase("biomeTags")
			row.value.erase("boundingBox")
	_refresh_visual_identity(fallback_bundle)
	check(backend.admit_visual_asset_catalog(fallback_bundle).get("status") == "ready",
		"synthetic missing optional registry fields admitted")
	var fallback_selected: Dictionary = backend.select_rock_asset_shadow("future_biome", "id")
	check(fallback_selected.get("assetId") == "rock_01"
		and fallback_selected.get("assetSize") == Vector3.ONE,
		"synthetic empty tags and missing size use native fallbacks")
	check(BundleScript.is_current(main, owner_bundle), "synthetic variants leave sealed owner current")
	var reset_biome: Dictionary = backend.admit_biome_environment_catalog(bundle.biome)
	check(reset_biome.get("status") == "ready" and backend.status().get("visualCatalogReady") == false,
		"biome replacement invalidates visual catalog")
	main.free()
	finish()

func _refresh_visual_identity(bundle: Dictionary) -> void:
	var visual: Dictionary = bundle.visual
	visual.contentIdentity = JSON.stringify({"domain":"visual_asset_registry_active_values",
		"schemaVersion":1, "assets":visual.assets, "families":visual.families,
		"disabledIds":visual.disabledIds, "sceneCache":visual.sceneCache}).sha256_text()

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
