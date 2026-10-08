extends SceneTree

const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const VisualRecipe := preload("res://scripts/world/OrdinaryStructureBlockVisualRecipe.gd")
const AssetRegistry := preload("res://scripts/visual/StaticItemAssetRegistry.gd")
const MainChunkTerrainScript := preload("res://scripts/MainChunkTerrain.gd")
const CitadelSiteField := preload("res://scripts/world/CitadelSiteField.gd")
const CitadelTerrainAdmission := preload("res://scripts/world/CitadelTerrainAdmission.gd")
const StandaloneCandidate := preload("res://scripts/world/StandaloneStructureCandidate.gd")


func _visual_recipe_input(block_type: String, options: Dictionary) -> Dictionary:
	var sealed_options: Dictionary = StructureSystemScript._sealed_ordinary_visual_value(options)
	var result := {"schema":"ordinary-structure-visual-recipe-input/v1",
		"blockType":block_type, "options":sealed_options,
		"digest":StructureSystemScript._ordinary_visual_recipe_digest(block_type, sealed_options)}
	result.make_read_only()
	return result

class FixtureWorld extends Node3D:
	var CELL := 1.0
	var blocks: Dictionary = {}
	var seed_text := "ordinary-section-geometry-contract"
	var TOWN_REGION_CELLS := 100000
	var TOWN_RADIUS_CELLS := 24
	var STRUCTURE_REGION_CELLS := 1000000
	var STRUCTURE_SPAWN_CHANCE := 0.0
	var town_region_cache: Dictionary = {}
	var block_root: Node3D
	var meshes: Dictionary = {}
	var materials: Dictionary = {}
	var static_item_asset_registry: Object
	var shadow_policy_overrides: Dictionary = {}

	func _init() -> void:
		block_root = self
		for material_key: String in ["stoneBlock", "woodBlock", "cobblestonePath",
			"workbench", "door", "bedPillow", "bedBlanket", "traderStall",
			"traderCloth", "traderClothLight", "anvil", "oreBase", "copperVein",
			"ironVein", "copperOreGlow", "ironOreGlow"]:
			materials[material_key] = StandardMaterial3D.new()

	func block_visual_mesh(_key: String) -> Mesh:
		if not meshes.has("base"):
			meshes.base = BoxMesh.new()
		return meshes.base

	func block_visual_material(key: String) -> Material:
		return materials.get(key, materials.stoneBlock)

	func block_shadow_policy(material_key: String) -> int:
		if shadow_policy_overrides.has(material_key):
			return int(shadow_policy_overrides[material_key])
		if material_key in ["glass", "flame", "furnaceGlow", "wardLantern",
			"sanctuaryBeacon", "riftAnchor", "copperOreGlow", "ironOreGlow"]:
			return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	func block_collision_profile(_block_type: String) -> Dictionary:
		return {"size":Vector3.ONE * CELL * 0.96, "offset":Vector3.ZERO}

	func town_region(region_x: int, region_z: int) -> Dictionary:
		var key := Vector2i(region_x, region_z)
		if town_region_cache.has(key): return town_region_cache[key]
		town_region_cache[key] = {}
		return {}

	func hash01(value: String) -> float:
		return float(value.hash() & 0x7fffffff) / 2147483647.0

	func hash_string(value: String) -> int:
		return value.hash()

class FixtureCitadelAdmission extends RefCounted:
	var main_world: Object
	var request_status := "ready"
	var request_reason := ""
	var generation := 3

	func request_bounds(bounds: Rect2i) -> Dictionary:
		return {"status":request_status, "reason":request_reason,
			"generation":generation, "worldSeed":String(main_world.get("seed_text")), "bounds":bounds}

	func source_state(_region: Vector2i) -> Dictionary:
		return {"status":"absent", "reason":"source_not_requested"}

var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	var asset_registry := AssetRegistry.new()
	var asset_registry_ready := asset_registry.setup()
	world.static_item_asset_registry = asset_registry
	var structures = StructureSystemScript.new()
	structures.main = world
	var source_id := "standalone:4,-2"
	var cell := Vector3i(-3, 5, 16)
	var body := _make_body(source_id, cell, "stoneBlock")
	body.position = Vector3(-3.0, 5.0, 16.0)
	world.add_child(body)
	world.blocks[cell] = body
	structures._begin_ordinary_visual_source(source_id)
	structures.active_structure_visual_source_id = source_id
	structures._record_ordinary_visual_block(cell, "stoneBlock", body)
	structures.active_structure_visual_source_id = ""
	structures._complete_ordinary_visual_source(source_id)
	var collider := CollisionShape3D.new()
	collider.shape = BoxShape3D.new()
	body.add_child(collider)
	var captured: Dictionary = Adapter.capture_block(structures, world, source_id, cell)
	check("published_static_mesh_captured_as_immutable_partition_input",
		captured.get("status") == "ready" and captured.sourceInput.is_read_only()
		and captured.sourceInput.buffer.is_read_only()
		and captured.sourceInput.get("sourcePartId", "") == "ordinary:%s:cell:-3,5,16" % source_id,
		captured)
	var repeated: Dictionary = Adapter.capture_block(structures, world, source_id, cell)
	check("unchanged_source_and_geometry_keep_revision",
		captured.get("sourceRevision", "") == repeated.get("sourceRevision", ""), repeated)
	var original_recipe: Dictionary = structures.ordinary_visual_sources[source_id] \
		.get("visualRecipeInputs", {}).get(cell, {})
	var updated_recipe := _visual_recipe_input("stoneBlock", {"generatedTier":"ruin"})
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = updated_recipe
	structures.ordinary_visual_sources[source_id].revision += 1
	var changed_recipe: Dictionary = Adapter.capture_block(structures, world, source_id, cell)
	check("producer_recipe_input_digest_participates_in_geometry_source_revision",
		changed_recipe.get("status") == "ready"
		and changed_recipe.get("sourceRevision", "") != captured.get("sourceRevision", "")
		and changed_recipe.get("sourceInput", {}).get("visualRecipeDigest", "") \
			== updated_recipe.get("digest", "")
		and changed_recipe.get("manifest", {}).get("visualRecipeDigest", "") \
			== updated_recipe.get("digest", ""), changed_recipe)
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = original_recipe
	structures.ordinary_visual_sources[source_id].revision += 1
	var mutable_recipe: Dictionary = updated_recipe.duplicate(true)
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = mutable_recipe
	var mutable_rejected := Adapter.capture_block(structures, world, source_id, cell)
	check("mutable_recipe_manifest_is_rejected_before_capture",
		mutable_rejected.get("status") == "pending"
		and mutable_rejected.get("reason") == "ordinary_geometry_visual_recipe_manifest_stale",
		mutable_rejected)
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[cell] = original_recipe
	structures.ordinary_visual_sources[source_id].revision += 1
	var recipe_material := captured.material as StandardMaterial3D
	var original_color := recipe_material.albedo_color
	recipe_material.albedo_color = Color(0.25, 0.75, 0.5)
	var changed_material: Dictionary = Adapter.capture_block(structures, world, source_id, cell)
	recipe_material.albedo_color = original_color
	check("material_change_fences_the_prepared_revision",
		changed_material.get("status") == "ready"
		and changed_material.get("sourceRevision", "") != captured.get("sourceRevision", "")
		and captured.get("geometry") == null,
		changed_material)
	var static_opaque_types: Array[String] = ["cobblestonePath", "stoneBlock",
		"woodBlock", "workbench", "bed", "traderStall", "spikeTrap",
		"copperVein", "ironVein"]
	var expected_asset_mesh_counts := {"workbench":9, "bed":4,
		"traderStall":11, "spikeTrap":10}
	var family_source_id := "ordinary-family-contract"
	structures.ordinary_visual_sources[family_source_id] = {
		"completed":true, "expected":{}, "visualRecipeInputs":{},
		"omitted":{}, "failed":{}, "revision":1}
	var opaque_family_rows: Array[Dictionary] = []
	var every_opaque_family_ready := true
	for family_index in static_opaque_types.size():
		var family_type := static_opaque_types[family_index]
		var family_cell := Vector3i(12 + family_index, 4, 20)
		var family_body := _make_recipe_body(world, family_source_id,
			family_cell, family_type)
		family_body.position = Vector3(family_cell)
		world.add_child(family_body)
		world.blocks[family_cell] = family_body
		structures.ordinary_visual_sources[family_source_id].expected[family_cell] = family_type
		structures.ordinary_visual_sources[family_source_id].visualRecipeInputs[family_cell] = \
			_visual_recipe_input(family_type, {})
		structures.ordinary_visual_sources[family_source_id].revision += 1
		var family_capture: Dictionary = Adapter.capture_block(structures, world,
			family_source_id, family_cell)
		var family_members: Array = family_capture.get("members", [])
		var family_layers_opaque: bool = family_capture.get("status") == "ready"
		var captured_shadow_policies: Array[bool] = []
		for member_value: Variant in family_members:
			if not member_value is Dictionary:
				family_layers_opaque = false
				continue
			var member: Dictionary = member_value
			var instance_input: Dictionary = {}
			var binding_compatibility: Dictionary = {}
			for input_value: Variant in family_capture.get("sourceInputs", []):
				if input_value is Dictionary and String(input_value.get("segmentId", "")).ends_with(
					":" + String(member.get("segmentId", ""))):
					instance_input = input_value
					break
			for binding_value: Variant in family_capture.get("memberBindings", []):
				if binding_value is Dictionary:
					var binding: Dictionary = binding_value
					var binding_input: Dictionary = binding.get("input", {})
					if String(binding_input.get("segmentId", "")).ends_with(
						":" + String(member.get("segmentId", ""))):
						binding_compatibility = binding.get("compatibility", {})
						break
			var member_casts_shadow := bool(member.get("castShadows", true))
			captured_shadow_policies.append(member_casts_shadow)
			family_layers_opaque = family_layers_opaque \
				and Adapter._material_is_opaque(member.get("material") as Material) \
				and String(instance_input.get("renderLayer", "")) == "opaque" \
				and String(instance_input.get("translucentSortPolicy", "")) == "none" \
				and bool(instance_input.get("castShadows", not member_casts_shadow)) == member_casts_shadow \
				and bool(binding_compatibility.get("castShadows", \
					not member_casts_shadow)) == member_casts_shadow \
				and not String(member.get("segmentId", "")).is_empty()
		var expected_count := int(expected_asset_mesh_counts.get(family_type, -1))
		var expected_asset_count_matches: bool = expected_count < 0 \
			or (asset_registry_ready and asset_registry.has_asset(family_type) \
				and asset_registry.mesh_count(family_type) == expected_count \
				and family_members.size() == expected_count)
		var row_passed: bool = family_capture.get("status") == "ready" \
			and not family_members.is_empty() and family_layers_opaque \
			and expected_asset_count_matches
		var source_shadow_policies: Array[bool] = []
		if expected_count >= 0 and asset_registry_ready \
				and asset_registry.has_asset(family_type):
			var source_asset: Node3D = asset_registry.instantiate_item(family_type)
			_collect_asset_shadow_policies(source_asset, source_shadow_policies)
			source_asset.free()
			row_passed = row_passed and source_shadow_policies == captured_shadow_policies
		if not row_passed:
			every_opaque_family_ready = false
		opaque_family_rows.append({"blockType":family_type, "status":family_capture.get("status", ""),
			"reason":family_capture.get("reason", ""), "memberCount":family_members.size(),
			"assetExpectedMeshCount":expected_count,
			"assetAvailable":asset_registry_ready and asset_registry.has_asset(family_type),
			"sourceShadowPolicies":source_shadow_policies,
			"capturedShadowPolicies":captured_shadow_policies,
			"allOpaqueAndLayered":family_layers_opaque, "passed":row_passed})
	check("every_classified_opaque_static_family_has_complete_opaque_members",
		every_opaque_family_ready,
		{"assetRegistryReady":asset_registry_ready, "families":opaque_family_rows})
	var shadow_cell := Vector3i(28, 4, 20)
	var shadow_body := _make_recipe_body(world, family_source_id, shadow_cell,
		"copperVein")
	shadow_body.position = Vector3(shadow_cell)
	world.add_child(shadow_body)
	world.blocks[shadow_cell] = shadow_body
	structures.ordinary_visual_sources[family_source_id].expected[shadow_cell] = "copperVein"
	structures.ordinary_visual_sources[family_source_id].visualRecipeInputs[shadow_cell] = \
		_visual_recipe_input("copperVein", {})
	structures.ordinary_visual_sources[family_source_id].revision += 1
	var shadow_capture: Dictionary = Adapter.capture_block(structures, world,
		family_source_id, shadow_cell)
	var shadow_members: Array = shadow_capture.get("members", [])
	var on_shadow_count := 0
	var off_shadow_count := 0
	var packet_shadow_matches_recipe := true
	for index in shadow_members.size():
		var member: Dictionary = shadow_members[index]
		var input: Dictionary = shadow_capture.get("sourceInputs", [])[index]
		var casts_shadow := bool(member.get("castShadows", true))
		if casts_shadow:
			on_shadow_count += 1
		else:
			off_shadow_count += 1
		var binding: Dictionary = shadow_capture.get("memberBindings", [])[index]
		packet_shadow_matches_recipe = packet_shadow_matches_recipe \
			and bool(input.get("castShadows", not casts_shadow)) == casts_shadow \
			and bool(binding.get("compatibility", {}).get("castShadows", \
				not casts_shadow)) == casts_shadow
	check("opaque_ore_recipe_preserves_source_shadow_policy_into_packet_and_batch_key",
		shadow_capture.get("status") == "ready" and shadow_members.size() == 6 \
			and on_shadow_count == 4 and off_shadow_count == 2 \
			and packet_shadow_matches_recipe,
		{"status":shadow_capture.get("status", ""), "reason":shadow_capture.get("reason", ""),
			"memberCount":shadow_members.size(), "shadowOnMembers":on_shadow_count,
			"shadowOffMembers":off_shadow_count,
			"packetShadowMatchesRecipe":packet_shadow_matches_recipe})
	var live_visual_parent := Node3D.new()
	root.add_child(live_visual_parent)
	var main_chunk_consumer = MainChunkTerrainScript.new()
	root.add_child(main_chunk_consumer)
	var installed_live_visuals: Array[MeshInstance3D] = \
		main_chunk_consumer.add_ordinary_structure_recipe_visuals(live_visual_parent,
			shadow_capture)
	var live_consumer_shadow_match := installed_live_visuals.size() == shadow_members.size()
	for index in mini(installed_live_visuals.size(), shadow_members.size()):
		var expected_casts_shadow := bool(shadow_capture.sourceInputs[index].get(
			"castShadows", false))
		live_consumer_shadow_match = live_consumer_shadow_match \
			and (installed_live_visuals[index].cast_shadow \
				!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF) == expected_casts_shadow
	check("production_main_recipe_consumer_installs_packet_shadow_policy_exactly",
		live_consumer_shadow_match,
		{"status":"ready", "memberCount":installed_live_visuals.size(),
			"packetMemberCount":shadow_members.size(),
			"shadowOffMemberCount":off_shadow_count,
			"liveConsumerMatchesPacket":live_consumer_shadow_match})
	var prior_shadow_revision := String(shadow_capture.get("sourceRevision", ""))
	var prior_shadow_recipe_digest := String(shadow_capture.get("sourceInput", {}).get(
		"visualRecipeDigest", ""))
	world.shadow_policy_overrides["copperOreGlow"] = \
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var changed_shadow_capture: Dictionary = Adapter.capture_block(structures, world,
		family_source_id, shadow_cell)
	world.shadow_policy_overrides.erase("copperOreGlow")
	var changed_shadow_off_count := 0
	for changed_input_value: Variant in changed_shadow_capture.get("sourceInputs", []):
		if changed_input_value is Dictionary \
				and not bool(changed_input_value.get("castShadows", true)):
			changed_shadow_off_count += 1
	check("shadow_policy_change_fences_recipe_and_packet_receipt_revision",
		changed_shadow_capture.get("status") == "ready" \
			and String(changed_shadow_capture.get("sourceInput", {}).get(
				"visualRecipeDigest", "")) \
			== prior_shadow_recipe_digest \
			and String(changed_shadow_capture.get("sourceRevision", "")) \
			!= prior_shadow_revision \
			and changed_shadow_off_count == 0,
		changed_shadow_capture)
	live_visual_parent.free()
	main_chunk_consumer.free()
	var glass_cell := Vector3i(30, 4, 20)
	var glass_body := _make_body(family_source_id, glass_cell, "glass")
	glass_body.position = Vector3(glass_cell)
	world.add_child(glass_body)
	world.blocks[glass_cell] = glass_body
	structures.ordinary_visual_sources[family_source_id].expected[glass_cell] = "glass"
	structures.ordinary_visual_sources[family_source_id].visualRecipeInputs[glass_cell] = \
		_visual_recipe_input("glass", {})
	structures.ordinary_visual_sources[family_source_id].revision += 1
	var glass_pending := Adapter.capture_block(structures, world,
		family_source_id, glass_cell)
	check("translucent_glass_stays_pending_outside_opaque_slice",
		glass_pending.get("status") == "pending"
		and glass_pending.get("reason") == "ordinary_geometry_block_type_not_migrated",
		glass_pending)
	var dynamic_campfire: Dictionary = VisualRecipe.classify_generated_block_type("campfire")
	check("dynamic_light_and_interaction_families_remain_with_their_gameplay_owner",
		dynamic_campfire.get("family") == "separate_dynamic"
		and not Adapter.ALLOWED_BLOCK_TYPES.has("campfire")
		and not Adapter.ALLOWED_BLOCK_TYPES.has("torch")
		and not Adapter.ALLOWED_BLOCK_TYPES.has("door")
		and not Adapter.ALLOWED_BLOCK_TYPES.has("chest")
		and not Adapter.ALLOWED_BLOCK_TYPES.has("furnace"), dynamic_campfire)
	var building_shader_material := ShaderMaterial.new()
	building_shader_material.shader = load("res://resources/visual/building_material.gdshader") as Shader
	building_shader_material.set_shader_parameter("base_color", Color(0.52, 0.57, 0.54))
	building_shader_material.set_shader_parameter("accent_color", Color(0.33, 0.37, 0.35))
	world.materials["woodBlock"] = building_shader_material
	var shader_cell := Vector3i(-3, 6, 15)
	var shader_body := _make_body(source_id, shader_cell, "woodBlock")
	shader_body.position = Vector3(shader_cell)
	world.add_child(shader_body)
	world.blocks[shader_cell] = shader_body
	structures.ordinary_visual_sources[source_id].expected[shader_cell] = "woodBlock"
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[shader_cell] = \
		_visual_recipe_input("woodBlock", {})
	structures.ordinary_visual_sources[source_id].revision += 1
	var shader_capture: Dictionary = Adapter.capture_block(structures, world, source_id, shader_cell)
	var shader_revision := String(shader_capture.get("sourceRevision", ""))
	building_shader_material.set_shader_parameter("base_color", Color(0.66, 0.42, 0.22))
	var shader_changed: Dictionary = Adapter.capture_block(structures, world, source_id, shader_cell)
	check("opaque_building_shader_enters_packets_and_uniform_changes_fence_revision",
		shader_capture.get("status") == "ready"
		and shader_capture.get("sourceInput", {}).get("renderLayer", "") == "opaque"
		and shader_capture.get("material", null) == building_shader_material
		and not shader_revision.is_empty()
		and shader_changed.get("status") == "ready"
		and String(shader_changed.get("sourceRevision", "")) != shader_revision,
		shader_capture)
	var source_capture: Dictionary = Adapter.capture_source(structures, world, source_id)
	check("source_completion_requires_each_expected_mesh_member",
		source_capture.get("status") == "complete"
		and source_capture.get("coverageScope") == "one_structure_source"
		and int(source_capture.get("expectedCellCount", -1)) == 2
		and int(source_capture.get("memberCount", -1)) == 2, source_capture)
	var inputs: Array[Dictionary] = [captured.sourceInput]
	inputs.make_read_only()
	var partition: Dictionary = Partitioner.partition(inputs)
	check("captured_geometry_enters_existing_section_partitioner",
		partition.get("status") == "ready"
		and int(partition.result.get("inputInstanceCount", 0)) == 1
		and int(partition.result.get("outputInstanceCount", 0)) == 1
		and int(partition.result.get("sectionCount", 0)) == 1, partition)
	var compatibilities: Dictionary = {String(captured.sourceInput.batchKey):captured.compatibility}
	compatibilities.make_read_only()
	var impacted_sections: Array[Vector3i] = []
	for output_value: Variant in partition.result.get("outputs", []):
		var section_key: Variant = output_value.get("sectionKey") if output_value is Dictionary else null
		if section_key is Vector3i and section_key not in impacted_sections:
			impacted_sections.append(section_key)
	impacted_sections.make_read_only()
	var snapshot_replacements: Dictionary = SnapshotBuilder.build_replacements(
		partition.result, compatibilities, impacted_sections, 1,
		"ordinary-adapter-contract-world")
	check("ordinary_geometry_uses_canonical_batch_key_and_shared_section_snapshot",
		snapshot_replacements.get("status")=="ready"
		and snapshot_replacements.get("replacements",[]).size()==1
		and int(snapshot_replacements.replacements[0].snapshot.get("instanceCount",0))==1,
		snapshot_replacements)
	check("collision_owner_remains_installed_after_capture",
		body.get_parent() == world and collider.get_parent() == body
		and body.has_meta("block_type") and world.blocks.get(cell) == body,
		{"status":"ready", "bodyInWorld":body.get_parent() == world,
			"colliderPresent":collider.get_parent() == body})
	var unsupported_cell := Vector3i(-2, 5, 16)
	var unsupported_body := _make_body(source_id, unsupported_cell, "chest")
	unsupported_body.position = Vector3(unsupported_cell)
	world.add_child(unsupported_body)
	world.blocks[unsupported_cell] = unsupported_body
	structures.ordinary_visual_sources[source_id].expected[unsupported_cell] = "chest"
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[unsupported_cell] = \
		_visual_recipe_input("chest", {})
	structures.ordinary_visual_sources[source_id].revision += 1
	var excluded: Dictionary = Adapter.capture_block(structures, world, source_id, unsupported_cell)
	check("interactive_block_stays_pending_for_its_gameplay_owner",
		excluded.get("status") == "pending"
		and excluded.get("reason") == "ordinary_geometry_dynamic_family_requires_separate_owner",
		excluded)
	var incomplete_source: Dictionary = Adapter.capture_source(structures, world, source_id)
	check("whole_source_does_not_claim_coverage_with_excluded_member",
		incomplete_source.get("status") == "pending"
		and incomplete_source.get("reason") == "ordinary_geometry_dynamic_family_requires_separate_owner",
		incomplete_source)
	var missing_cell := Vector3i(-1, 5, 16)
	structures.ordinary_visual_sources[source_id].expected[missing_cell] = "woodBlock"
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[missing_cell] = \
		_visual_recipe_input("woodBlock", {})
	structures.ordinary_visual_sources[source_id].revision += 1
	var missing: Dictionary = Adapter.capture_block(structures, world, source_id, missing_cell)
	check("expected_but_unpublished_member_is_pending_not_empty",
		missing.get("status") == "pending"
		and missing.get("reason") == "ordinary_geometry_live_source_body_unavailable", missing)
	var multi_cell := Vector3i(-3, 6, 16)
	var extra_mesh_body := _make_body(source_id, multi_cell, "woodBlock")
	extra_mesh_body.position = Vector3(multi_cell)
	world.add_child(extra_mesh_body)
	world.blocks[multi_cell] = extra_mesh_body
	structures.ordinary_visual_sources[source_id].expected[multi_cell] = "woodBlock"
	structures.ordinary_visual_sources[source_id].visualRecipeInputs[multi_cell] = \
		_visual_recipe_input("woodBlock", {"roofRole":"ridge", "roofAxis":"x",
			"roofEdgeX":-1, "roofEdgeZ":1, "roofAccent":"chimney"})
	structures.ordinary_visual_sources[source_id].revision += 1
	var multiple: Dictionary = Adapter.capture_block(structures, world, source_id, multi_cell)
	check("roof_recipe_captures_base_ridge_both_eaves_and_chimney_as_segments",
		multiple.get("status") == "ready"
		and multiple.get("sourceInputs", []).size() == 6
		and multiple.get("memberBindings", []).size() == 6
		and multiple.get("sourceInput", {}).get("segmentId", "").ends_with(":roof_base"), multiple)
	structures.generated_visual_block_removed(body)
	var removed: Dictionary = Adapter.capture_block(structures, world, source_id, cell)
	var removed_source: Dictionary = Adapter.capture_source(structures, world, source_id)
	check("durable_tombstone_is_explicit_source_removal_and_dynamic_member_stays_pending",
		removed.get("status") == "empty"
		and removed_source.get("status") == "pending"
		and removed_source.get("reason") == "ordinary_geometry_dynamic_family_requires_separate_owner",
		removed_source)
	var changed_mesh: Dictionary = Adapter.capture_block(structures, world, source_id, multi_cell)
	check("multipart_recipe_does_not_mutate_static_body_collision",
		changed_mesh.get("status") == "ready"
		and collider.get_parent() == body and body.get_parent() == world,
		{"status":changed_mesh.get("status", ""), "colliderPresent":collider.get_parent() == body})
	_run_ecology_structure_dependency_checks()
	var passed := true
	for row: Dictionary in checks:
		if not bool(row.passed): passed = false
	var report := {"schema":"ordinary-structure-section-geometry-adapter-contract/v1",
		"evidenceLevel":"synthetic_producer_value_partition_and_local_structure_dependency_contract",
		"complete":true, "passed":passed, "checkCount":checks.size(), "checks":checks}
	var report_path := OS.get_environment("VOXEL_ORDINARY_SECTION_GEOMETRY_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	world.free()
	quit(0 if passed else 1)


func _run_ecology_structure_dependency_checks() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	world.seed_text = _seed_without_local_citadel_site()
	var structures = StructureSystemScript.new()
	structures.main = world
	structures.regional_source_generation = 7
	var admission := FixtureCitadelAdmission.new()
	admission.main_world = world
	structures.citadel_terrain_admission = admission
	var bounds := Rect2i(Vector2i(64, 64), Vector2i(8, 8))
	var baseline: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("ecology_structure_dependency_capture_is_sealed_and_owned",
		baseline.get("schema") == "ecology-structure-dependency-snapshot/v1"
		and baseline.get("status") == "ready"
		and String(baseline.get("contentDigest", "")).length() == 64
		and baseline.is_read_only()
		and (baseline.get("content", {}) as Dictionary).is_read_only(), baseline)
	structures.generated_structures[Vector2i(300, -200)] = true
	structures.regional_source_revision += 19
	structures.pending_structure_ops.append({"type":"block", "cellX":500000,
		"cellZ":-500000, "visualSourceId":"standalone:distant"})
	structures.ordinary_visual_sources["town:distant"] = {"revision":4096,
		"completed":true, "expected":{}, "failed":{}, "omitted":{}}
	structures.natural_prop_exclusion_records["distant"] = {"id":"distant", "source":"tree",
		"minX":500000, "maxX":500002, "minZ":-500000, "maxZ":-499998}
	var after_distant_work: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("distant_structure_counts_and_queue_work_do_not_change_local_digest",
		after_distant_work.get("contentDigest", "") == baseline.get("contentDigest", "")
		and structures.ecology_structure_dependencies_are_current(baseline), after_distant_work)
	structures.natural_prop_exclusion_records["local"] = {"id":"local", "source":"contract",
		"minX":60, "maxX":61, "minZ":65, "maxZ":66}
	var with_local_exclusion: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("post_draw_margin_captures_neighbor_exclusion_and_same_revision_mutation",
		with_local_exclusion.get("status") == "ready"
		and with_local_exclusion.get("contentDigest", "") != baseline.get("contentDigest", "")
		and not structures.ecology_structure_dependencies_are_current(baseline), with_local_exclusion)
	structures.natural_prop_exclusion_records["local"].maxX = 60
	var same_revision_mutation: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("local_record_mutation_is_detected_without_revision_counter_change",
		same_revision_mutation.get("contentDigest", "") != with_local_exclusion.get("contentDigest", "")
		and not structures.ecology_structure_dependencies_are_current(with_local_exclusion), same_revision_mutation)
	var replacement_world := FixtureWorld.new()
	replacement_world.seed_text = world.seed_text
	structures.main = replacement_world
	check("replacement_world_invalidates_old_structure_lease",
		not structures.ecology_structure_dependencies_are_current(same_revision_mutation), {})
	structures.main = world
	admission.request_status = "pending"
	admission.request_reason = "preparing_contract_site"
	var pending: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("local_citadel_admission_pending_blocks_capture",
		pending.get("status") == "pending" and String(pending.get("reason", "")).contains("preparing"), pending)
	admission.request_status = "failed"
	admission.request_reason = "contract_site_rejected"
	var failed: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("local_citadel_admission_failure_is_not_empty_success",
		failed.get("status") == "failed" and failed.get("reason", "") == "contract_site_rejected", failed)
	structures.natural_prop_exclusion_records["invalid"] = {"id":12, "source":"contract",
		"minX":60, "maxX":61, "minZ":65, "maxZ":66}
	admission.request_status = "ready"
	var malformed: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 4, 6)
	check("malformed_local_authority_record_fails_closed",
		malformed.get("status") == "failed" and malformed.get("reason", "") == "invalid_local_structure_record", malformed)
	var forged: Dictionary = {}
	for key in same_revision_mutation.keys(): forged[key] = same_revision_mutation[key]
	forged["content"] = {"forged":true}
	check("forged_content_or_owner_epoch_cannot_reuse_receipt",
		not structures.ecology_structure_dependencies_are_current(forged), {})
	var forged_epoch: Dictionary = {}
	for key in same_revision_mutation.keys(): forged_epoch[key] = same_revision_mutation[key]
	forged_epoch["ownerGeneration"] = int(forged_epoch.get("ownerGeneration", 0)) + 1
	check("forged_structure_owner_epoch_is_rejected",
		not structures.ecology_structure_dependencies_are_current(forged_epoch), {})
	var forged_owner: Dictionary = {}
	for key in same_revision_mutation.keys(): forged_owner[key] = same_revision_mutation[key]
	forged_owner["worldOwnerInstanceId"] = int(forged_owner.get("worldOwnerInstanceId", 0)) + 1
	check("forged_world_owner_identity_is_rejected",
		not structures.ecology_structure_dependencies_are_current(forged_owner), {})
	_run_local_town_admission_checks()
	structures.main = null
	structures.citadel_terrain_admission = null
	admission.main_world = null
	replacement_world.free()
	world.free()


func _seed_without_local_citadel_site() -> String:
	var bounds := Rect2i(Vector2i(64, 64), Vector2i(8, 8)).grow(6)
	var region := CitadelSiteField.region_for_cell(bounds.position)
	for attempt in range(1000):
		var seed := "ecology-structure-contract-%d" % attempt
		var candidate: Dictionary = CitadelSiteField.candidate_for_region(seed, region)
		if not candidate.is_empty() and CitadelTerrainAdmission.declared_influence(candidate).intersects(bounds):
			continue
		var standalone_clear := true
		for z in range(-1, 2):
			for x in range(-1, 2):
				var standalone := StandaloneCandidate.candidate_for_region(seed,
					Vector2i(x, z), 1000000, 0.0)
				if not standalone.is_empty() \
					and (StandaloneCandidate.terrain_influence_for_candidate(standalone).influenceCells as Rect2i).intersects(bounds):
					standalone_clear = false
		if standalone_clear: return seed
	return "ecology-structure-contract-fallback"


func _run_local_town_admission_checks() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
	world.seed_text = _seed_without_local_citadel_site()
	world.town_region_cache[Vector2i.ZERO] = {"regionX":0, "regionZ":0,
		"centerX":64, "centerZ":64, "radius":24, "level":12.0, "homeExclusionRings":[]}
	var structures = StructureSystemScript.new()
	structures.main = world
	structures.regional_source_generation = 11
	var admission := FixtureCitadelAdmission.new()
	admission.main_world = world
	structures.citadel_terrain_admission = admission
	var bounds := Rect2i(Vector2i(60, 60), Vector2i(10, 10))
	var pending: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	var source_id := "town:64,64"
	check("future_local_town_layout_blocks_its_affected_area",
		pending.get("status") == "pending"
		and String(pending.get("reason", "")).contains("town_operations")
		and not (pending.get("content", {}) as Dictionary).get("townSources", []).is_empty(), pending)
	var old_digest := String(pending.get("contentDigest", ""))
	structures.pending_structure_ops.append({"type":"block", "cellX":500000,
		"cellZ":500000, "townKey":"64,64", "visualSourceId":source_id})
	var with_distant_town_op: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	check("distant_write_in_same_town_does_not_churn_local_pending_digest",
		with_distant_town_op.get("status") == "pending"
		and with_distant_town_op.get("contentDigest", "") == old_digest, with_distant_town_op)
	structures.pending_structure_ops.clear()
	structures.pending_structure_retry_ops.clear()
	structures.pending_structure_op_index = 0
	structures.town_manifest_publish_states["64,64"] = {"status":"building",
		"generationAttempts":1, "desiredHomeCount":4, "builtHomeCount":4, "failureReasons":[]}
	structures.ordinary_visual_sources[source_id]["completed"] = true
	var footprint := {"id":"town_home:65,65:8x8:12", "source":"town_home", "material":"stone",
		"baseX":65, "baseZ":65, "width":8, "depth":8, "level":12.0, "floorY":12,
		"clearanceCells":4, "minCell":Vector3i(64,9,64), "maxCell":Vector3i(74,12,74)}
	structures.terrain_footprint_records[footprint.id] = footprint
	var undeclared_phase: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	check("incomplete_town_without_phase_declaration_remains_pending",
		undeclared_phase.get("status") == "pending"
		and String(undeclared_phase.get("reason", "")).contains("town_operations"), undeclared_phase)
	structures.pending_structure_ops.append({"type":"town_build_phase", "townKey":"64,64",
		"state":{"phase":"publish", "townKey":"64,64", "sites":[], "homeSiteIndex":0,
			"builtHomeCount":4, "desiredHomeCount":4}})
	var local_complete: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	check("known_local_layout_with_nonlocal_publish_tail_is_ready",
		local_complete.get("status") == "ready", local_complete)
	structures.pending_structure_ops.append({"type":"block", "cellX":500001,
		"cellZ":500001, "townKey":"64,64", "visualSourceId":source_id})
	var unrelated_queued: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	check("completed_local_layout_does_not_wait_for_distant_town_tail",
		structures.town_manifest_publish_states["64,64"].get("status") == "building"
		and unrelated_queued.get("status") == "ready"
		and unrelated_queued.get("contentDigest", "") == local_complete.get("contentDigest", ""), unrelated_queued)
	structures.terrain_footprint_records[footprint.id].material = "wood"
	var local_edit: Dictionary = structures.capture_ecology_structure_dependencies(bounds, 2, 3)
	check("intersecting_terrain_footprint_edit_invalidates_local_receipt",
		local_edit.get("contentDigest", "") != unrelated_queued.get("contentDigest", "")
		and not structures.ecology_structure_dependencies_are_current(unrelated_queued), local_edit)
	structures.main = null
	structures.citadel_terrain_admission = null
	admission.main_world = null
	world.free()


func _make_body(source_id: String, cell: Vector3i, block_type: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	body.set_meta("block_type", block_type)
	body.set_meta("generated", true)
	body.set_meta("generated_visual_source_id", source_id)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	visual.material_override = StandardMaterial3D.new()
	body.add_child(visual)
	return body


func _make_recipe_body(world: FixtureWorld, source_id: String, cell: Vector3i,
		block_type: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta("cell", cell)
	body.set_meta("block_type", block_type)
	body.set_meta("generated", true)
	body.set_meta("generated_visual_source_id", source_id)
	var options: Dictionary = StructureSystemScript._sealed_ordinary_visual_value({})
	var recipe: Dictionary = VisualRecipe.resolve_member(world, block_type, cell, options)
	var content_digest := String(recipe.get("contentDigest", ""))
	body.set_meta("ordinary_structure_recipe_content_digest", content_digest)
	for member_value: Variant in recipe.get("members", []):
		if not member_value is Dictionary:
			continue
		var member: Dictionary = member_value
		var visual := MeshInstance3D.new()
		visual.name = String(member.get("visualName", ""))
		visual.mesh = member.get("mesh")
		visual.material_override = member.get("material")
		visual.transform = member.get("meshLocalTransform", Transform3D.IDENTITY)
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if bool(member.get("castShadows", true)) \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		visual.set_meta("ordinary_structure_recipe_segment_id",
			String(member.get("segmentId", "")))
		visual.set_meta("ordinary_structure_recipe_content_digest", content_digest)
		body.add_child(visual)
	return body


func _collect_asset_shadow_policies(node: Node, policies: Array[bool]) -> void:
	if node is MeshInstance3D:
		policies.append((node as MeshInstance3D).cast_shadow \
			!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	for child: Node in node.get_children():
		_collect_asset_shadow_policies(child, policies)


func check(name: String, passed: bool, details: Dictionary) -> void:
	var reported_details := {"status":String(details.get("status", "")),
			"reason":String(details.get("reason", "")),
			"sourcePartId":String(details.get("sourcePartId", "")),
			"memberCount":int(details.get("memberCount", -1)),
			"sectionCount":int(details.get("sectionCount", -1))}
	for detail_key: String in ["assetRegistryReady", "families", "blockType",
		"memberId", "expected", "unknown"]:
		if details.has(detail_key):
			reported_details[detail_key] = details[detail_key]
	checks.append({"name":name, "passed":passed, "details":reported_details})
