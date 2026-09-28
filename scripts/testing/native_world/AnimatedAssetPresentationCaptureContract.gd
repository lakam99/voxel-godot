extends SceneTree

const RegistryScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func check(name: String, passed: bool) -> void:
	results.append({"name": name, "passed": passed})
	if not passed:
		push_error("animated presentation capture: " + name)

func run() -> void:
	var registry = RegistryScript.new()
	check("unready_rejected", not bool(registry.capture_active_presentation().get("ok", false)))
	check("imported_registry_ready", registry.setup())
	var captured: Dictionary = registry.capture_active_presentation()
	check("active_capture_ready", bool(captured.get("ok", false)))
	check("all_imported_rows_present", (captured.get("assets", []) as Array).size() == registry.asset_ids().size())
	check("initial_current", registry.presentation_capture_is_current(captured))
	var other_registry = RegistryScript.new()
	check("other_registry_ready", other_registry.setup())
	check("cross_registry_receipt_rejected", not other_registry.presentation_capture_is_current(captured))
	var changed_row := captured.duplicate(true)
	((changed_row.assets as Array)[0].definition as Dictionary)["expected"] = "tampered"
	check("copied_row_tamper_rejected", not registry.presentation_capture_is_current(changed_row))
	var changed_clip := captured.duplicate(true)
	(changed_clip.assets as Array)[0].availableClips = ["tampered"]
	check("copied_clip_tamper_rejected", not registry.presentation_capture_is_current(changed_clip))
	var changed_digest := captured.duplicate(true)
	changed_digest.contentIdentity = "tampered"
	check("copied_identity_tamper_rejected", not registry.presentation_capture_is_current(changed_digest))
	var first_id: String = registry.asset_ids()[0]
	registry.assets_by_id[first_id] = (registry.assets_by_id[first_id] as Dictionary).duplicate(true)
	var active_row: Dictionary = registry.assets_by_id[first_id]
	var previous_expected: String = String(active_row.expected)
	active_row.expected = "missing_expected_clip_contract"
	check("in_place_expected_clip_missing_rejected", not bool(registry.capture_active_presentation().get("ok", false)))
	check("in_place_expected_clip_invalidates", not registry.presentation_capture_is_current(captured))
	active_row.expected = previous_expected
	check("restored_content_current", registry.presentation_capture_is_current(captured))
	var previous_path: String = String(active_row.path)
	active_row.path = "res://different.glb"
	check("in_place_path_mismatch_rejected", not bool(registry.capture_active_presentation().get("ok", false)))
	active_row.path = previous_path
	var prior_scene: PackedScene = registry.scene_cache[first_id]
	registry.scene_cache.erase(first_id)
	check("partial_import_cache_rejected", not bool(registry.capture_active_presentation().get("ok", false)))
	registry.scene_cache[first_id] = prior_scene
	check("restored_cache_current", registry.presentation_capture_is_current(captured))
	var invalid_root := Node.new()
	invalid_root.name = "InvalidRoot"
	var invalid_scene := PackedScene.new()
	check("invalid_root_scene_packed", invalid_scene.pack(invalid_root) == OK)
	invalid_root.free()
	registry.scene_cache[first_id] = invalid_scene
	active_row.path = ""
	check("invalid_root_rejected", String(registry.capture_active_presentation().get("reason", "")) == "scene_root_invalid:" + first_id)
	registry.scene_cache[first_id] = prior_scene
	active_row.path = previous_path
	check("restored_after_invalid_root", registry.presentation_capture_is_current(captured))
	registry.loaded = false
	check("failed_state_rejected", not bool(registry.capture_active_presentation().get("ok", false)))
	registry.loaded = true
	check("ready_state_restored", registry.presentation_capture_is_current(captured))
	check("reload_setup_ready", registry.setup())
	check("reload_invalidates_prior_receipt", not registry.presentation_capture_is_current(captured))
	var passed := true
	for result in results:
		passed = passed and bool(result.passed)
	var path := ProjectSettings.globalize_path("res://artifacts/native-world-backend/n4-animated-presentation-capture-contract.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string(JSON.stringify({"finished": true, "passed": passed,
		"evidenceLevel": "contract", "scope": "Animated registry import and presentation capture only; not native adapter or live gameplay.",
		"resultCount": results.size(), "results": results}, "  "))
	file.close()
	quit(0 if passed else 1)
