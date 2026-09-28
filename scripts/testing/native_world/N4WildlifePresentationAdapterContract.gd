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
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"wildlife-presentation-test",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func admit_prerequisites(backend: Object, bundle: Dictionary) -> void:
	check(backend.admit_biome_environment_catalog(bundle.biome).get("status") == "ready", "biome admission")
	check(backend.admit_visual_asset_catalog(bundle).get("status") == "ready", "visual admission")
	check(backend.admit_removed_props_tombstones(bundle.removed).get("status") == "ready", "removed admission")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend class")
	if backend == null:
		finish()
		return
	check(backend.initialize(initialization()).get("status") == "ready", "backend initialization")
	var main = MainScript.new()
	main.seed_text = "wildlife-presentation-test"
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
	check(backend.admit_wildlife_presentation_catalog(bundle).get("status") == "failed", "catalog prerequisites")
	admit_prerequisites(backend, bundle)
	var receipt: Dictionary = backend.admit_wildlife_presentation_catalog(bundle)
	check(receipt.get("status") == "ready", "presentation admission: " + str(receipt.get("reason")))
	check(receipt.get("receiptSchema") == "n4-wildlife-presentation-catalog-receipt/v1"
		and receipt.get("completeSurfacePropSource") == false
		and receipt.get("liveCaptureFreshnessProven") == false,
		"partial shadow scope")
	check(backend.status().get("wildlifePresentationReady") == true
		and backend.status().get("wildlifePresentationCaptureContentIdentity") == bundle.presentation.contentIdentity,
		"typed catalog retained")
	for variant in ["boar", "deer", "hare"]:
		var shadow: Dictionary = backend.wildlife_presentation_shadow(variant)
		check(shadow.get("status") == "ready"
			and shadow.get("assetId") == variant + "_idle_walk"
			and shadow.get("animationClipId") == variant + "_idle_walk"
			and shadow.get("presentationPath") == "animated_playable",
			"active animation parity: " + variant)
	check(backend.wildlife_presentation_shadow("fox").get("status") == "failed", "unknown wildlife rejected")
	var tampered := bundle.duplicate(true)
	tampered.presentation.contentIdentity = "0".repeat(64)
	check(backend.admit_wildlife_presentation_catalog(tampered).get("status") == "failed"
		and backend.status().get("wildlifePresentationReady") == false
		and backend.wildlife_presentation_shadow("boar").get("status") == "failed",
		"presentation identity tamper fails closed")
	animated.assets_by_id.erase("deer_idle_walk")
	animated.scene_cache.erase("deer_idle_walk")
	var fallback_bundle: Dictionary = BundleScript.capture(main)
	check(bool(fallback_bundle.get("ok", false)), "active missing-deer recapture")
	var fallback: Dictionary = backend.admit_wildlife_presentation_catalog(fallback_bundle)
	check(fallback.get("status") == "ready", "missing deer admitted: " + str(fallback.get("reason")))
	check(backend.wildlife_presentation_shadow("deer").get("presentationPath") == "procedural_fallback"
		and backend.wildlife_presentation_shadow("boar").get("presentationPath") == "animated_playable"
		and backend.wildlife_presentation_shadow("hare").get("presentationPath") == "animated_playable",
		"per-variant live fallback parity")
	check(backend.admit_removed_props_tombstones(fallback_bundle.removed).get("status") == "ready"
		and backend.status().get("wildlifePresentationReady") == false,
		"removed replacement invalidates presentation")
	check(backend.admit_wildlife_presentation_catalog(fallback_bundle).get("status") == "ready",
		"catalog can be readmitted after removed replacement")
	var stale := fallback_bundle.duplicate(true)
	stale.removed.revision = int(stale.removed.revision) + 1
	check(backend.admit_wildlife_presentation_catalog(stale).get("status") == "failed"
		and backend.status().get("wildlifePresentationReady") == false,
		"mixed removed generation rejected")
	main.free()
	finish()

func finish() -> void:
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-wildlife-presentation-adapter-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"finished":true,"passed":failures.is_empty(),
			"evidenceLevel":"Godot adapter contract",
			"scope":"Active animated wildlife presentation capture and native typed shadow only; no live freshness, full surface manifest or gameplay.",
			"failures":failures}, "  "))
		file.close()
	quit(0 if failures.is_empty() and file != null else 1)
