extends SceneTree

const Snapshot := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")

class CaptureOwner extends RefCounted:
	var seed_text := "atlas-é"
	var removed_props_revision := 2
	var removed_props := {"tree:oak": true, "é-rock": false}

var failures: Array[String] = []

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func initialization() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-é",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func rejected(backend: Object, capture: Dictionary, label: String) -> void:
	check(backend.call("admit_removed_props_tombstones", capture).get("status") == "failed", label)

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "backend class")
	if backend == null:
		finish()
		return
	check(backend.initialize(initialization()).get("status") == "ready", "backend initialization")
	var owner := CaptureOwner.new()
	var capture: Dictionary = Snapshot.capture(owner)
	check(capture.get("ok") == true, "source capture")
	var receipt: Dictionary = backend.admit_removed_props_tombstones(capture)
	check(receipt.get("status") == "ready", "typed admission")
	check(receipt.get("receiptSchema") == "n4-removed-props-tombstone-receipt/v1", "receipt schema")
	check(receipt.get("scope") == "removed_prop_tombstones_only" and receipt.get("completeFeatureManifest") == false
		and receipt.get("shadowOnly") == true and receipt.get("liveCaptureFreshnessProven") == false, "partial shadow scope")
	check(receipt.get("tombstoneCount") == 2 and String(receipt.get("fd1Identity", "")).length() == 64, "typed count and identity")
	check(receipt.get("captureRevision") == 2 and receipt.get("captureOwnerInstanceId") == owner.get_instance_id(), "capture provenance")
	check(receipt.get("sourceIdentity") == backend.status().get("sourceIdentity"), "source identity binding")
	var changed := capture.duplicate(true)
	changed.schemaVersion = 2
	rejected(backend, changed, "schema tamper")
	changed = capture.duplicate(true)
	changed.revision = -1
	rejected(backend, changed, "revision tamper")
	changed = capture.duplicate(true)
	changed.seed = "another-seed"
	rejected(backend, changed, "seed tamper")
	changed = capture.duplicate(true)
	changed.ids[0] = "altered"
	rejected(backend, changed, "id tamper")
	changed = capture.duplicate(true)
	changed.ids = ["same", "same"]
	changed.contentIdentity = Snapshot._identity(changed.ids)
	rejected(backend, changed, "duplicate ids")
	changed = capture.duplicate(true)
	changed.ids = ["é-rock", "tree:oak"]
	changed.contentIdentity = Snapshot._identity(changed.ids)
	rejected(backend, changed, "reversed unicode order")
	changed = capture.duplicate(true)
	changed.ids = ["x".repeat(1025)]
	changed.contentIdentity = Snapshot._identity(changed.ids)
	rejected(backend, changed, "id byte limit")
	changed = capture.duplicate(true)
	changed.ids = ["é".repeat(512)]
	changed.contentIdentity = Snapshot._identity(changed.ids)
	check(backend.admit_removed_props_tombstones(changed).get("status") == "ready", "exact unicode byte limit")
	changed.ids = ["é".repeat(513)]
	changed.contentIdentity = Snapshot._identity(changed.ids)
	rejected(backend, changed, "unicode byte overflow")
	changed = capture.duplicate(true)
	changed.ids = []
	changed.ids.resize(Snapshot.MAX_IDS + 1)
	rejected(backend, changed, "tombstone capacity")
	var uninitialized = ClassDB.instantiate("NativeWorldBackend")
	rejected(uninitialized, capture, "uninitialized backend")
	finish()

func finish() -> void:
	var report := {"finished":true,"passed":failures.is_empty(),"evidenceLevel":"Godot adapter contract",
		"scope":"Typed removed-prop tombstone admission only; not freshness, complete feature footprints, or gameplay.","failures":failures}
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-removed-props-adapter-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if failures.is_empty() and file != null else 1)

func _init() -> void:
	call_deferred("run")
