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

	var original_publication: Dictionary = registry.published_catalog_snapshot()
	var original_digest := String(original_publication.get("contentDigest", ""))
	var original_owner_receipt: Dictionary = original_publication.get("ownerReceipt", {})
	var imported_instance: Node = registry.instantiate_asset("door_open_close")
	var animation_player := _find_animation_player(imported_instance)
	var imported_library: AnimationLibrary = animation_player.get_animation_library("") \
		if animation_player != null else null
	var imported_library_is_owner_bound := false
	if imported_library != null:
		for bound_value: Variant in registry._bound_scene_resources.values():
			if is_same(bound_value, imported_library):
				imported_library_is_owner_bound = true
				break
	_check("instantiated_actor_owns_private_animation_library",
		imported_library != null and not imported_library_is_owner_bound,
		{"assetId":"door_open_close", "playerPath":String(
			registry._published_descriptors.get("door_open_close", {}).get("animationPlayerPath", "")),
			"libraryInstanceId":imported_library.get_instance_id() if imported_library != null else 0,
			"bound":imported_library_is_owner_bound})
	var expected_clip := String(registry._assets_by_id["door_open_close"].get("expected", ""))
	var actor_animation: Animation = imported_library.get_animation(expected_clip) \
		if imported_library != null else null
	if actor_animation != null:
		actor_animation.loop_mode = Animation.LOOP_LINEAR
		actor_animation.length += 0.125
	_check("actor_animation_mutation_keeps_catalog_owner_current",
		actor_animation != null \
		and String(registry.published_catalog_snapshot().get("status", "")) == "ready" \
		and is_same(registry.published_catalog_snapshot(), original_publication),
		{"assetId":"door_open_close", "expectedClip":expected_clip,
			"actorLibraryInstanceId":imported_library.get_instance_id() if imported_library != null else 0})

	var owner_library: AnimationLibrary = null
	for bound_value: Variant in registry._bound_scene_resources.values():
		if bound_value is AnimationLibrary \
				and (bound_value as AnimationLibrary).has_animation(expected_clip):
			owner_library = bound_value as AnimationLibrary
			break
	_check("resource_loader_animation_library_is_owner_bound", owner_library != null,
		{"assetId":"door_open_close", "expectedClip":expected_clip,
			"ownerLibraryInstanceId":owner_library.get_instance_id() if owner_library != null else 0})
	if owner_library != null:
		var original_animation: Animation = owner_library.get_animation(expected_clip)
		owner_library.remove_animation(expected_clip)
		var removed := not owner_library.has_animation(expected_clip)
		_check("authoritative_library_remove_invalidates_cached_publication", removed \
			and String(registry.published_catalog_snapshot().get("status", "")) == "pending",
			{"expectedClip":expected_clip, "removed":removed})
		var rejected_reload := not registry.setup()
		_check("failed_reload_cannot_resurrect_invalidated_publication", rejected_reload \
			and String(registry.published_catalog_snapshot().get("status", "")) == "pending" \
			and is_same(registry._published_snapshot, original_publication),
			{"reloadRejected":rejected_reload,
				"publicationStatus":registry.published_catalog_snapshot().get("status", "")})
		var restored := original_animation != null \
			and owner_library.add_animation(expected_clip, original_animation) == OK
		var restored_setup := restored and registry.setup()
		var restored_publication: Dictionary = registry.published_catalog_snapshot()
		_check("restoration_republishes_same_semantics_with_new_runtime_receipt",
			restored_setup \
			and String(restored_publication.get("contentDigest", "")) == original_digest \
			and not is_same(restored_publication.get("ownerReceipt"), original_owner_receipt) \
			and int(restored_publication.get("ownerReceipt", {}).get("publicationRevision", -1)) \
				!= int(original_owner_receipt.get("publicationRevision", -1)),
			{"restored":restored, "setup":restored_setup,
				"originalDigest":original_digest,
				"restoredDigest":restored_publication.get("contentDigest", ""),
				"originalOwnerReceipt":original_owner_receipt,
				"restoredOwnerReceipt":restored_publication.get("ownerReceipt", {})})
	if imported_instance != null:
		imported_instance.free()

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
	_register_synthetic_asset(registry, ambiguous_id, ambiguous_path, ambiguous_scene)
	var ambiguous_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(ambiguous_id)
	_check("multiple_animation_players_remain_ambiguous", \
		String(ambiguous_descriptor.get("reason", "")) == "multiple_animation_players_order_unproven",
		ambiguous_descriptor)

	var semantic_id := "synthetic_semantic_identity"
	var semantic_path := "res://synthetic/semantic_identity.tscn"
	var first_scene := _pack_scene_with_animation_players(1)
	first_scene.resource_path = semantic_path
	_register_synthetic_asset(registry, semantic_id, semantic_path, first_scene)
	var first_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(semantic_id)
	var second_scene := _pack_scene_with_animation_players(1)
	second_scene.take_over_path(semantic_path)
	registry._scene_cache[semantic_id] = second_scene
	var second_descriptor: Dictionary = registry.describe_asset_presentation_without_instantiation(semantic_id)
	_check("semantic_digest_ignores_resource_owner_but_runtime_lease_does_not", \
		bool(first_descriptor.get("ok", false)) and bool(second_descriptor.get("ok", false)) \
		and first_descriptor.get("semanticSceneStateSchema") == "animated-scene-semantic-state/v1" \
		and String(first_descriptor.get("semanticSceneStateDigest", "")).length() == 64 \
		and first_descriptor.get("semanticSceneStateDigest") == second_descriptor.get("semanticSceneStateDigest") \
		and first_descriptor.get("sceneStateDigest") != second_descriptor.get("sceneStateDigest") \
		and not registry.asset_presentation_descriptor_is_current(first_descriptor),
		{"first": first_descriptor, "second": second_descriptor})
	registry._scene_cache.erase(ambiguous_id)
	registry._assets_by_id.erase(ambiguous_id)
	registry._scene_cache.erase(semantic_id)
	registry._assets_by_id.erase(semantic_id)
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
		"evidenceLevel": "synthetic_parser_contract_and_imported_scene_state_and_runtime_actor_resource_ownership",
		"scope": "AnimationLibrary SceneState serialization, five registered animated asset descriptors, per-actor animation resource isolation, and authoritative owner mutation lifecycle; not live gameplay.",
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

func _register_synthetic_asset(registry, asset_id: String, resource_path: String,
		scene: PackedScene) -> void:
	# These parser-only fixtures are outside the sealed production manifest. Seed
	# the registry's owner storage directly because its compatibility getters are
	# intentionally detached and no runtime registration API exists.
	registry._assets_by_id[asset_id] = {"id": asset_id, "path": resource_path,
		"expected": "idle"}
	registry._scene_cache[asset_id] = scene

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child: Node in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null
