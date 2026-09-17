extends SceneTree

# Direct registry contract. It proves that the production registry retains its
# importer-owned asset source and deterministic selection while dummy-renderer
# publication stops before PackedScene hydration. Headed geometry remains the
# responsibility of the existing visual/import acceptance coverage.
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")

var checks: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run_contract")

func check(name: String, passed: bool, details: Dictionary = {}) -> void:
	checks.append({"name": name, "passed": passed, "details": details})

func run_contract() -> void:
	var display_name := DisplayServer.get_name()
	check("contract_runs_with_dummy_headless_display", display_name.strip_edges().to_lower() == "headless", {
		"displayServer": display_name
	})
	check("display_classifier_rejects_headless_case_and_padding",
		not VisualAssetRegistryScript.imported_scene_visual_publication_supported("headless")
		and not VisualAssetRegistryScript.imported_scene_visual_publication_supported(" HEADLESS "))
	check("display_classifier_preserves_headed_renderers",
		VisualAssetRegistryScript.imported_scene_visual_publication_supported("windows")
		and VisualAssetRegistryScript.imported_scene_visual_publication_supported("x11")
		and VisualAssetRegistryScript.imported_scene_visual_publication_supported("macos"))

	var registry = VisualAssetRegistryScript.new()
	var setup_ready: bool = registry.setup()
	var first_id: String = registry.select_rock_asset_id("mountain", "headless-imported-rock-contract")
	var repeated_id: String = registry.select_rock_asset_id("mountain", "headless-imported-rock-contract")
	var cached_scene := registry.scene_cache.get(first_id) as PackedScene
	check("manifest_selection_and_importer_cache_remain_authoritative",
		setup_ready
		and not first_id.is_empty()
		and first_id == repeated_id
		and cached_scene != null
		and not cached_scene.resource_path.is_empty(), {
			"assetId": first_id,
			"cachedResourcePath": cached_scene.resource_path if cached_scene != null else "",
			"cachedSceneCount": registry.cached_scene_count(),
			"errors": registry.last_errors
		})

	var first: Node3D = registry.instantiate_asset(first_id)
	var second: Node3D = registry.instantiate_asset(first_id)
	var expected_shadow := registry.shadow_policy_for_family("rock")
	var expected_visibility := registry.visibility_range_for_family("rock")
	var first_ready := headless_proxy_matches(first, first_id, cached_scene, expected_shadow, expected_visibility)
	var second_ready := headless_proxy_matches(second, first_id, cached_scene, expected_shadow, expected_visibility)
	check("headless_publication_returns_fresh_nonrendering_proxies",
		first_ready and second_ready and first != second, {
			"firstReady": first_ready,
			"secondReady": second_ready,
			"distinctInstances": first != second,
			"firstChildCount": first.get_child_count() if first != null else -1,
			"secondChildCount": second.get_child_count() if second != null else -1
		})
	check("invalid_or_disabled_assets_still_reject",
		registry.instantiate_asset("") == null
		and registry.instantiate_asset("missing-headless-contract-asset") == null)
	check("proxy_creation_does_not_replace_cached_importer_source",
		registry.scene_cache.get(first_id) == cached_scene
		and cached_scene != null
		and not cached_scene.resource_path.is_empty(), {
			"assetId": first_id,
			"cachedResourcePath": cached_scene.resource_path if cached_scene != null else ""
		})

	if first != null:
		first.free()
	if second != null:
		second.free()
	finish()

func headless_proxy_matches(proxy: Node3D, asset_id: String, scene: PackedScene, expected_shadow: int, expected_visibility: float) -> bool:
	return proxy != null \
		and proxy.name == "HeadlessImportedVisualProxy" \
		and proxy.get_child_count() == 0 \
		and bool(proxy.get_meta("headless_visual_proxy", false)) \
		and String(proxy.get_meta("visual_publication", "")) == "headless_imported_scene_proxy" \
		and String(proxy.get_meta("visual_source", "")) == "generated_asset" \
		and String(proxy.get_meta("visual_asset_id", "")) == asset_id \
		and String(proxy.get_meta("imported_scene_resource_path", "")) == (scene.resource_path if scene != null else "") \
		and int(proxy.get_meta("shadow_policy", -1)) == expected_shadow \
		and is_equal_approx(float(proxy.get_meta("visibility_range_end", -1.0)), expected_visibility)

func finish() -> void:
	var failures := checks.filter(func(item: Dictionary) -> bool: return not bool(item.passed))
	var report := {
		"passed": failures.is_empty(),
		"evidenceLevel": "contract",
		"scope": "VisualAssetRegistry imported-scene cache/source identity and dummy-renderer publication boundary; excludes headed geometry and visual quality",
		"checks": checks,
		"failures": failures.size()
	}
	var report_path := OS.get_environment("VOXEL_VISUAL_ASSET_HEADLESS_REPORT").strip_edges()
	if not report_path.is_empty():
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print("VISUAL ASSET HEADLESS CONTRACT ", JSON.stringify({"passed": report.passed, "checks": checks.size()}))
	quit(0 if report.passed else 1)
