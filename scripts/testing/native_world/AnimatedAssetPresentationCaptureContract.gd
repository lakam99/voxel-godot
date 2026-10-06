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
	check("sealed_projection_reused", is_same(captured, registry.capture_active_presentation()) \
		and captured.is_read_only() and (captured.assets as Array).is_read_only())
	check("native_v1_identity", String(captured.contentIdentity) == JSON.stringify({
		"domain":"animated_asset_registry_presentation", "schemaVersion":1,
		"assets":captured.assets}).sha256_text())
	check("native_v1_owner_receipt", (captured.ownerReceipt as Dictionary).size() == 3 \
		and int(captured.ownerReceipt.get("ownerInstanceId", 0)) == registry.get_instance_id() \
		and int(captured.ownerReceipt.get("revision", 0)) > 0)
	check("copied_projection_is_not_owner_proof", not registry.presentation_capture_is_current(captured.duplicate(true)))
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
	var detached_row: Dictionary = registry.assets_by_id[first_id]
	detached_row.expected = "missing_expected_clip_contract"
	detached_row.path = "res://different.glb"
	var detached_cache: Dictionary = registry.scene_cache
	detached_cache.erase(first_id)
	check("detached_edits_preserve_owner", registry.presentation_capture_is_current(captured))
	var expected := String(registry.asset_definition_copy(first_id).expected)
	var owner_library: AnimationLibrary = null
	for resource: Variant in registry._bound_scene_resources.values():
		if resource is AnimationLibrary and (resource as AnimationLibrary).has_animation(expected):
			owner_library = resource as AnimationLibrary
			break
	check("authoritative_library_found", owner_library != null)
	if owner_library != null:
		var original_animation := owner_library.get_animation(expected)
		owner_library.remove_animation(expected)
		check("owner_clip_removal_rejects_capture", not bool(registry.capture_active_presentation().get("ok", false)))
		check("owner_clip_removal_invalidates", not registry.presentation_capture_is_current(captured))
		check("incomplete_reload_rejected", not registry.setup())
		check("failed_reload_cannot_revive_projection", not registry.presentation_capture_is_current(captured))
		check("owner_clip_restored", owner_library.add_animation(expected, original_animation) == OK)
		check("restoration_requires_republication", not registry.presentation_capture_is_current(captured))
		check("restored_owner_republished", registry.setup())
		check("replacement_rejects_old_projection", not registry.presentation_capture_is_current(captured))
		captured = registry.capture_active_presentation()
		check("replacement_projection_current", registry.presentation_capture_is_current(captured))
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
