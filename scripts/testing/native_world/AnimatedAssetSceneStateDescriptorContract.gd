extends SceneTree

const RegistryScript := preload("res://scripts/visual/AnimatedAssetRegistry.gd")

var checks: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, passed: bool, detail: Variant = {}) -> void:
	checks.append({"name": name, "passed": passed, "detail": detail})

func _run() -> void:
	var registry = RegistryScript.new()
	var setup_ok: bool = registry.setup()
	_check("animated_registry_ready", setup_ok)
	var expected_assets := ["boar_idle_walk", "chest_open_close", "deer_idle_walk",
		"door_open_close", "hare_idle_walk"]
	_check("all_five_registered_animated_assets_present", registry.asset_ids() == PackedStringArray(expected_assets),
		registry.asset_ids())
	var imported: Array[Dictionary] = []
	for asset_id: String in registry.asset_ids():
		var descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(asset_id)
		var expected: String = String(registry.assets_by_id[asset_id].get("expected", ""))
		var passed: bool = bool(descriptor.get("ok", false)) \
			and bool(descriptor.get("expectedClipAvailable", false)) \
			and String(descriptor.get("expectedClip", "")) == expected \
			and (descriptor.get("availableClips", []) as Array).has(expected)
		_check("imported_descriptor:" + asset_id, passed, descriptor)
		imported.append({"assetId": asset_id, "expected": expected,
			"reason": descriptor.get("reason", ""),
			"diagnostic": descriptor.get("diagnostic", {}),
			"availableClips": descriptor.get("availableClips", [])})

	var default_row := {"animations": [], "animationLibraryKeys": {},
		"animationLibraryProperties": [], "animationLibrariesPresent": false}
	var default_library := _library_with_clip("idle")
	var default_result: Dictionary = registry._record_scene_state_animation_library(
		default_row, "AnimationPlayer", "libraries/", default_library)
	_check("default_library_key_and_clip", bool(default_result.get("ok", false)) \
		and (default_row.animationLibraryKeys as Dictionary).has("") \
		and (default_row.animations as Array) == ["idle"], default_row)

	var named_row := {"animations": [], "animationLibraryKeys": {},
		"animationLibraryProperties": [], "animationLibrariesPresent": false}
	var named_result: Dictionary = registry._record_scene_state_animation_library(
		named_row, "AnimationPlayer", "libraries/secondary", _library_with_clip("walk"))
	_check("named_library_key_and_clip", bool(named_result.get("ok", false)) \
		and (named_row.animationLibraryKeys as Dictionary).has("secondary") \
		and (named_row.animations as Array) == ["secondary/walk"], named_row)

	var invalid_row := {"animations": [], "animationLibraryKeys": {},
		"animationLibraryProperties": [], "animationLibrariesPresent": false}
	var invalid_result: Dictionary = registry._record_scene_state_animation_library(
		invalid_row, "AnimationPlayer", "libraries/default", "not a library")
	_check("invalid_library_resource_rejected_with_location", \
		not bool(invalid_result.get("ok", false)) \
		and String(invalid_result.get("reason", "")) == "animation_library_resource_unavailable" \
		and String(invalid_result.get("diagnostic", {}).get("nodePath", "")) == "AnimationPlayer" \
		and String(invalid_result.get("diagnostic", {}).get("propertyName", "")) == "libraries/default",
		invalid_result)

	var ambiguous_row := {"animations": [], "animationLibraryKeys": {},
		"animationLibraryProperties": [], "animationLibrariesPresent": false}
	var first_key: Dictionary = registry._record_scene_state_animation_library(
		ambiguous_row, "AnimationPlayer", "libraries/shared", _library_with_clip("one"))
	var duplicate_key: Dictionary = registry._record_scene_state_animation_library(
		ambiguous_row, "AnimationPlayer", "libraries/shared", _library_with_clip("two"))
	_check("duplicate_library_key_rejected", bool(first_key.get("ok", false)) \
		and not bool(duplicate_key.get("ok", false)) \
		and String(duplicate_key.get("reason", "")) == "animation_library_key_ambiguous",
		{"first": first_key, "duplicate": duplicate_key})

	var ambiguous_scene := _pack_scene_with_animation_players(2)
	var ambiguous_id := "synthetic_multiple_animation_players"
	var ambiguous_path := "res://synthetic/multiple_animation_players.tscn"
	ambiguous_scene.resource_path = ambiguous_path
	registry.assets_by_id[ambiguous_id] = {"id": ambiguous_id, "path": ambiguous_path,
		"expected": "idle"}
	registry.scene_cache[ambiguous_id] = ambiguous_scene
	var ambiguous_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(ambiguous_id)
	_check("multiple_animation_players_remain_ambiguous", \
		String(ambiguous_descriptor.get("reason", "")) == "multiple_animation_players_order_unproven",
		ambiguous_descriptor)

	var semantic_id := "synthetic_semantic_identity"
	var semantic_path := "res://synthetic/semantic_identity.tscn"
	var first_scene := _pack_scene_with_animation_players(1)
	first_scene.resource_path = semantic_path
	registry.assets_by_id[semantic_id] = {"id": semantic_id, "path": semantic_path,
		"expected": "idle"}
	registry.scene_cache[semantic_id] = first_scene
	var first_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(semantic_id)
	var second_scene := _pack_scene_with_animation_players(1)
	second_scene.take_over_path(semantic_path)
	registry.scene_cache[semantic_id] = second_scene
	var second_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(semantic_id)
	_check("semantic_digest_ignores_resource_owner_but_runtime_lease_does_not", \
		bool(first_descriptor.get("ok", false)) and bool(second_descriptor.get("ok", false)) \
		and first_descriptor.get("semanticSceneStateSchema") == "animated-scene-semantic-state/v1" \
		and String(first_descriptor.get("semanticSceneStateDigest", "")).length() == 64 \
		and first_descriptor.get("semanticSceneStateDigest") == second_descriptor.get("semanticSceneStateDigest") \
		and first_descriptor.get("sceneStateDigest") != second_descriptor.get("sceneStateDigest") \
		and not registry.asset_presentation_descriptor_is_current(first_descriptor),
		{"first": first_descriptor, "second": second_descriptor})
	registry.scene_cache.erase(ambiguous_id)
	registry.assets_by_id.erase(ambiguous_id)
	registry.scene_cache.erase(semantic_id)
	registry.assets_by_id.erase(semantic_id)
	ambiguous_scene = null
	first_scene = null
	second_scene = null

	var passed := true
	for row: Dictionary in checks:
		passed = passed and bool(row.get("passed", false))
	var report_path := OS.get_environment("VOXEL_ANIMATED_SCENE_STATE_DESCRIPTOR_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_ANIMATED_SCENE_STATE_DESCRIPTOR_REPORT is required")
		quit(2)
		return
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write animated SceneState descriptor report")
		quit(2)
		return
	file.store_string(JSON.stringify({"schema": "animated-asset-scene-state-descriptor-contract/v1",
		"passed": passed, "checkCount": checks.size(),
		"evidenceLevel": "synthetic_parser_contract_and_imported_scene_state_descriptor",
		"scope": "AnimationLibrary SceneState serialization and five registered animated asset descriptors; no runtime actor construction or live gameplay.",
		"checks": checks, "importedDescriptors": imported}, "  "))
	file.close()
	quit(0 if passed else 1)

func _library_with_clip(clip_name: String) -> AnimationLibrary:
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	animation.length = 1.0
	library.add_animation(clip_name, animation)
	return library

func _pack_scene_with_animation_players(player_count: int) -> PackedScene:
	var root := Node3D.new()
	root.name = "SyntheticRoot"
	for index in range(player_count):
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer%d" % index
		player.add_animation_library("", _library_with_clip("idle"))
		root.add_child(player)
		player.owner = root
	var packed := PackedScene.new()
	var pack_result: Error = packed.pack(root)
	root.free()
	if pack_result != OK:
		return null
	return packed
