extends SceneTree

const Catalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const Snapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
const Bundle := preload("res://scripts/world/ActiveSurfacePropOwnerBundle.gd")

var failures: Array[String] = []

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"catalog-test",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func rejected(backend: Object, capture: Dictionary, label: String) -> void:
	check(backend.call("admit_biome_environment_catalog", capture).get("status") == "failed", label)
	check(not bool(backend.status().get("biomeCatalogReady", false)), label + " leaves no stale native catalog")

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend class")
	if backend == null:
		finish()
		return
	check(backend.initialize(initialization()).get("status") == "ready", "backend initialization")
	check(not bool(backend.status().get("biomeCatalogReady", false)), "native catalog initially absent")
	var catalog = Catalog.new()
	check(catalog.setup(), "source catalog ready")
	var capture: Dictionary = Bundle.native_biome_projection(catalog, Snapshot.capture(catalog))
	check(capture.get("ok") == true, "source capture")
	var receipt: Dictionary = backend.admit_biome_environment_catalog(capture)
	check(receipt.get("status") == "ready", "typed admission: " + str(receipt.get("reason")))
	check(receipt.get("receiptSchema") == "n4-biome-environment-catalog-receipt/v1", "receipt schema")
	check(receipt.get("scope") == "resolved_biome_environment_catalog_only" and receipt.get("shadowOnly") == true
		and receipt.get("completeSurfacePropSource") == false and receipt.get("liveCaptureFreshnessProven") == false, "shadow scope")
	check(receipt.get("profileCount") == 13 and receipt.get("fallbackId") == "default"
		and String(receipt.get("nativeCatalogIdentity", "")).length() == 64, "native typed identity")
	check(receipt.get("captureContentIdentity") == capture.contentIdentity
		and receipt.get("captureOwnerInstanceId") == catalog.get_instance_id(), "capture provenance")
	check(receipt.get("nativeOwnerInstanceId") == backend.get_instance_id()
		and receipt.get("sourceIdentity") == backend.status().get("sourceIdentity"), "native owner binding")
	check(backend.status().get("biomeCatalogReady") == true
		and backend.status().get("biomeCatalogIdentity") == receipt.get("nativeCatalogIdentity")
		and backend.status().get("biomeCaptureContentIdentity") == capture.contentIdentity,
		"typed catalog retained by native owner")
	var repeated: Dictionary = backend.admit_biome_environment_catalog(capture)
	check(repeated.get("nativeCatalogIdentity") == receipt.get("nativeCatalogIdentity"), "stable native identity")
	var changed := capture.duplicate(true)
	changed.schemaVersion = 2
	rejected(backend, changed, "schema tamper")
	changed = capture.duplicate(true)
	changed.ownerReceipt.ready = false
	rejected(backend, changed, "unready source")
	changed = capture.duplicate(true)
	changed.ownerReceipt.revision = 0
	rejected(backend, changed, "invalid source revision")
	changed = capture.duplicate(true)
	changed.contentIdentity = "0".repeat(64)
	rejected(backend, changed, "content identity tamper")
	changed = capture.duplicate(true)
	changed.profiles[0].tree_scale.float32BytesHex = "00000000"
	rejected(backend, changed, "float32 bits tamper")
	changed = capture.duplicate(true)
	changed.profiles[0].tree_scale.float64BytesHex = "0000000000000000"
	rejected(backend, changed, "float64 bits tamper")
	changed = capture.duplicate(true)
	changed.profiles[0].forage_drop_min = 0.5
	rejected(backend, changed, "integer type tamper")
	changed = capture.duplicate(true)
	changed.profiles[0].extra = true
	rejected(backend, changed, "extra profile field")
	changed = capture.duplicate(true)
	changed.profiles[0].biomeId = "forest"
	rejected(backend, changed, "biome ID alias tamper")
	changed = capture.duplicate(true)
	changed.profiles[0].biomeId = "beach"
	changed.profiles[0].biome_id = "beach"
	rejected(backend, changed, "duplicate and missing biome IDs")
	changed = capture.duplicate(true)
	changed.profiles[0].tree_scale = Snapshot._numeric(float(changed.profiles[0].tree_scale.value) + 0.125)
	var semantic := {"domain":"biome_environment_resolved_catalog", "schemaVersion":1,
		"fallbackId":"default", "profiles":changed.profiles}
	changed.contentIdentity = Snapshot._sha256(JSON.stringify(semantic))
	var changed_receipt: Dictionary = backend.admit_biome_environment_catalog(changed)
	check(changed_receipt.get("status") == "ready" and changed_receipt.get("nativeCatalogIdentity") != receipt.get("nativeCatalogIdentity"),
		"valid resolved value changes native identity")
	check(backend.status().get("biomeCatalogReady") == true
		and backend.status().get("biomeCatalogIdentity") == changed_receipt.get("nativeCatalogIdentity"),
		"valid replacement retained after failed captures")
	var uninitialized = ClassDB.instantiate("NativeWorldBackend")
	rejected(uninitialized, capture, "uninitialized backend")
	var another = ClassDB.instantiate("NativeWorldBackend")
	check(another.initialize(initialization()).get("status") == "ready", "second backend initialization")
	var second_receipt: Dictionary = another.admit_biome_environment_catalog(capture)
	check(second_receipt.get("status") == "ready" and second_receipt.get("nativeOwnerInstanceId") != receipt.get("nativeOwnerInstanceId")
		and second_receipt.get("nativeCatalogIdentity") == receipt.get("nativeCatalogIdentity"), "same source distinct native owner")
	finish()

func finish() -> void:
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-biome-catalog-adapter-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"finished":true,"passed":failures.is_empty(),"evidenceLevel":"Godot adapter contract",
			"scope":"Typed resolved catalog admission only; no live freshness, surface prop source, or gameplay.",
			"failures":failures}, "  "))
		file.close()
	quit(0 if failures.is_empty() and file != null else 1)

func _init() -> void:
	call_deferred("run")
