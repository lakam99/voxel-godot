extends SceneTree

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const RegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const SnapshotScript := preload("res://scripts/visual/ActiveVisualAssetSnapshot.gd")

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var catalog = CatalogScript.new()
	var registry = RegistryScript.new()
	check("unready_rejected", not bool(SnapshotScript.capture(registry).get("ok", false)))
	check("catalog_ready", catalog.setup())
	check("registry_ready", registry.setup(catalog))
	var captured: Dictionary = SnapshotScript.capture(registry)
	check("capture_ready", bool(captured.get("ok", false)))
	check("initial_current", SnapshotScript.is_current(registry, captured))
	var ordered: Dictionary = {}
	for row in captured.get("families", []):
		ordered[String(row.family)] = row.orderedIds
	var rock_ids: Array = ordered.get("rock", [])
	check("rock_family_order_exact", rock_ids == registry.assets_by_family.get("rock", []))
	var selection := registry.select_rock_asset_id("forest", "snapshot-selection-contract")
	check("selection_uses_captured_family", rock_ids.has(selection))
	var duplicate_snapshot: Dictionary = captured.duplicate(true)
	(duplicate_snapshot.families as Array)[0].orderedIds.append("tampered")
	check("tampered_family_rejected", not SnapshotScript.is_current(registry, duplicate_snapshot))
	var row_snapshot: Dictionary = captured.duplicate(true)
	(row_snapshot.assets as Array)[0].value["path"] = "tampered"
	check("tampered_asset_rejected", not SnapshotScript.is_current(registry, row_snapshot))
	var cache_snapshot: Dictionary = captured.duplicate(true)
	(cache_snapshot.sceneCache as Array)[0].resourcePath = "tampered"
	check("tampered_cache_rejected", not SnapshotScript.is_current(registry, cache_snapshot))
	var old_path = registry.assets_by_id[selection].get("path")
	registry.assets_by_id[selection]["path"] = "mutated.glb"
	check("public_asset_mutation_invalidates", not SnapshotScript.is_current(registry, captured))
	check("wrong_manifest_path_rejects_new_capture", not bool(SnapshotScript.capture(registry).get("ok", false)))
	registry.assets_by_id[selection]["path"] = old_path
	var family: Array = registry.assets_by_family["rock"]
	var original_family: Array = family.duplicate(true)
	family.reverse()
	check("public_family_order_mutation_invalidates", not SnapshotScript.is_current(registry, captured))
	registry.assets_by_family["rock"] = original_family
	var duplicate_ids: Array = original_family.duplicate(true)
	duplicate_ids.append(selection)
	registry.assets_by_family["rock"] = duplicate_ids
	var duplicate_capture: Dictionary = SnapshotScript.capture(registry)
	var duplicate_rock_ids: Array = []
	for row in duplicate_capture.get("families", []):
		if String(row.family) == "rock":
			duplicate_rock_ids = row.orderedIds
	check("duplicate_family_members_preserved", duplicate_rock_ids == duplicate_ids \
		and (duplicate_capture.assets as Array).size() == (captured.assets as Array).size())
	registry.assets_by_family["rock"] = original_family
	var original_scene := registry.scene_cache.get(selection) as PackedScene
	check("selected_scene_cached", original_scene != null)
	registry.scene_cache.erase(selection)
	check("missing_import_keeps_selection", registry.select_rock_asset_id("forest", "snapshot-selection-contract") == selection)
	check("missing_import_invalidates", not SnapshotScript.is_current(registry, captured))
	check("missing_import_rejects_new_capture", not bool(SnapshotScript.capture(registry).get("ok", false)))
	check("missing_import_cannot_instantiate", registry.instantiate_asset(selection) == null)
	registry.scene_cache[selection] = original_scene
	var replacement_scene := PackedScene.new()
	registry.scene_cache[selection] = replacement_scene
	check("scene_identity_replacement_invalidates", not SnapshotScript.is_current(registry, captured))
	check("wrong_scene_path_rejects_new_capture", not bool(SnapshotScript.capture(registry).get("ok", false)))
	var wrong_root := Node2D.new()
	var wrong_root_scene := PackedScene.new()
	check("wrong_root_fixture_packed", wrong_root_scene.pack(wrong_root) == OK)
	wrong_root.free()
	registry.assets_by_id[selection]["path"] = "snapshot-invalid-root-only.glb"
	wrong_root_scene.resource_path = "res://snapshot-invalid-root-only.glb"
	registry.scene_cache[selection] = wrong_root_scene
	check("wrong_root_rejects_new_capture", not bool(SnapshotScript.capture(registry).get("ok", false)))
	registry.scene_cache[selection] = original_scene
	registry.assets_by_id[selection]["path"] = old_path
	registry.disable_asset_for_test(selection)
	check("disabled_still_selected", registry.select_rock_asset_id("forest", "snapshot-selection-contract") == selection)
	check("disabled_invalidates", not SnapshotScript.is_current(registry, captured))
	check("disabled_cannot_instantiate", registry.instantiate_asset(selection) == null)
	registry.clear_test_disabled_assets()
	check("lifecycle_revision_does_not_revalidate_old", not SnapshotScript.is_current(registry, captured))
	var passed := true
	for result in results:
		passed = passed and bool(result.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-active-visual-snapshot-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed, "evidenceLevel": "contract",
		"scope": "VisualAssetRegistry active value capture, ordered rock selection, and import readiness only; excludes AnimatedAssetRegistry, native adapter, and live gameplay.",
		"resultCount": results.size(), "results": results, "capturedDigest": captured.get("contentIdentity", "")}, "  "))
	file.close()
	quit(0 if passed else 1)

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})
