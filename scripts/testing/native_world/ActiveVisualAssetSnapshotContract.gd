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
	var publication: Dictionary = captured.get("publication", {})
	check("capture_retains_published_owner_alias", not publication.is_empty() \
		and is_same(publication, registry.published_catalog_snapshot(catalog.published_catalog_snapshot())))
	check("second_capture_keeps_current_owner_publication", SnapshotScript.is_current(registry,
		SnapshotScript.capture(registry)))
	var ordered: Dictionary = {}
	for row in captured.get("families", []):
		ordered[String(row.family)] = row.orderedIds
	var rock_ids: Array = ordered.get("rock", [])
	check("rock_family_order_exact", rock_ids == registry.assets_by_family.get("rock", []))
	var selection := registry.select_rock_asset_id("forest", "snapshot-selection-contract")
	check("selection_uses_captured_family", rock_ids.has(selection))
	check("rock_support_envelope_uses_forward_transformed_raw_mesh_bounds",
		_rock_envelope_matches_forward_bounds(registry, publication, selection,
			"forest", "snapshot-selection-contract"))
	var detached_assets: Dictionary = registry.assets_by_id
	var detached_asset: Dictionary = detached_assets.get(selection, {})
	var original_path := String(detached_asset.get("path", ""))
	detached_asset["path"] = "tampered.glb"
	detached_assets[selection] = detached_asset
	check("compatibility_asset_copy_cannot_mutate_owner", registry.assets_by_id.get(selection, {}).get("path") == original_path \
		and SnapshotScript.is_current(registry, captured))
	var detached_families: Dictionary = registry.assets_by_family
	var detached_rock_ids: Array = detached_families.get("rock", [])
	detached_rock_ids.reverse()
	detached_rock_ids.append(selection)
	check("compatibility_family_copy_cannot_mutate_owner", registry.assets_by_family.get("rock", []) == rock_ids \
		and SnapshotScript.is_current(registry, captured))
	var detached_scenes: Dictionary = registry.scene_cache
	var selected_scene_copy := detached_scenes.get(selection) as PackedScene
	var cached_scene_count_before := registry.cached_scene_count()
	detached_scenes.erase(selection)
	var selected_descriptor: Dictionary = registry.describe_static_asset_without_instantiation(selection)
	check("compatibility_scene_cache_copy_cannot_unload_owner", selected_scene_copy != null \
		and registry.cached_scene_count() == cached_scene_count_before \
		and String(selected_descriptor.get("status", "")) == "ready" \
		and SnapshotScript.is_current(registry, captured))
	var duplicate_snapshot: Dictionary = captured.duplicate(true)
	check("detached_snapshot_copy_is_not_owner_publication", not SnapshotScript.is_current(registry, duplicate_snapshot))
	var prior_digest := String(publication.get("contentDigest", ""))
	registry.disable_asset_for_test(selection)
	var disabled_capture: Dictionary = SnapshotScript.capture(registry)
	check("explicit_owner_mutation_replaces_publication", not SnapshotScript.is_current(registry, captured) \
		and not bool(disabled_capture.get("ok", false)) \
		and String(disabled_capture.get("reason", "")).begins_with("eligible_rock_asset_disabled:"),
		{"priorDigest":prior_digest, "disabledCaptureReason":disabled_capture.get("reason", "")})
	check("disabled_asset_remains_selected_but_cannot_instantiate", \
		registry.select_rock_asset_id("forest", "snapshot-selection-contract") == selection \
		and registry.instantiate_asset(selection) == null)
	registry.clear_test_disabled_assets()
	var restored_capture: Dictionary = SnapshotScript.capture(registry)
	check("explicit_owner_restore_publishes_current_snapshot", bool(restored_capture.get("ok", false)) \
		and SnapshotScript.is_current(registry, restored_capture) \
		and not SnapshotScript.is_current(registry, disabled_capture) \
		and String(restored_capture.get("contentIdentity", "")) == prior_digest)
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
		"scope": "VisualAssetRegistry published owner alias, detached compatibility reads, ordered rock selection, explicit disabled-asset publication, and reload identity; excludes native adapter and live gameplay.",
		"resultCount": results.size(), "results": results, "capturedDigest": captured.get("contentIdentity", "")}, "  "))
	file.close()
	quit(0 if passed else 1)

func check(name: String, passed: bool, detail: Variant = {}) -> void:
	results.append({"name": name, "passed": passed, "detail": detail})


func _rock_envelope_matches_forward_bounds(registry: Object, publication: Dictionary,
		selected_id: String, biome: String, prop_id: String) -> bool:
	var receipt: Dictionary = publication.get("ownerReceipt", {})
	var selected: Dictionary = registry.rock_source_descriptor_for_publication(
		receipt, biome, prop_id)
	if String(selected.get("status", "")) != "ready" \
			or String(selected.get("assetId", "")) != selected_id:
		return false
	var descriptor: Dictionary = selected.get("descriptor", {})
	var asset_size: Vector3 = selected.get("assetSize", Vector3.ZERO)
	var profile_scale := float(selected.get("profileScale", 0.0))
	if asset_size.x <= 0.0 or asset_size.y <= 0.0 or asset_size.z <= 0.0 \
			or profile_scale <= 0.0:
		return false
	var root_scale := Vector3(
		(2.0 * 1.25 * 1.75) / maxf(0.1, asset_size.x),
		(1.25 * 1.55 * 1.30) / maxf(0.1, asset_size.z),
		(2.0 * 1.25 * 1.50) / maxf(0.1, asset_size.y)) * profile_scale
	var root_transform := Transform3D(Basis.IDENTITY.scaled(root_scale), Vector3.ZERO)
	var expected_horizontal := 0.0
	var expected_vertical := 0.0
	var has_member := false
	for member_value: Variant in descriptor.get("renderMembers", []):
		if not member_value is Dictionary:
			return false
		var member: Dictionary = member_value
		var mesh_bounds: Variant = member.get("meshBounds", null)
		var member_transform: Variant = member.get("transform", null)
		if not mesh_bounds is AABB or not member_transform is Transform3D:
			return false
		var forward_transform := root_transform * (member_transform as Transform3D)
		var raw_bounds: AABB = mesh_bounds
		for x: float in [raw_bounds.position.x, raw_bounds.end.x]:
			for y: float in [raw_bounds.position.y, raw_bounds.end.y]:
				for z: float in [raw_bounds.position.z, raw_bounds.end.z]:
					var point: Vector3 = forward_transform * Vector3(x, y, z)
					expected_horizontal = maxf(expected_horizontal,
						Vector2(point.x, point.z).length())
					expected_vertical = maxf(expected_vertical, absf(point.y))
		has_member = true
	if not has_member:
		return false
	var envelope: Dictionary = publication.get("payload", {}).get("rockSupportEnvelope", {})
	for row_value: Variant in envelope.get("assetRows", []):
		if row_value is Dictionary and String(row_value.get("assetId", "")) == selected_id \
				and String(row_value.get("biomeId", "")) == biome:
			return is_equal_approx(float(row_value.get("maxHorizontalSupportMeters", 0.0)),
				expected_horizontal) and is_equal_approx(
				float(row_value.get("maxVerticalSupportMeters", 0.0)),
				expected_vertical)
	return false
