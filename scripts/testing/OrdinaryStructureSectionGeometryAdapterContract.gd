extends SceneTree

const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const Adapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")


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
	var block_root: Node3D
	var meshes: Dictionary = {}
	var materials: Dictionary = {}

	func _init() -> void:
		block_root = self
		materials = {"stoneBlock":StandardMaterial3D.new(),
			"woodBlock":StandardMaterial3D.new(), "cobblestonePath":StandardMaterial3D.new()}

	func block_visual_mesh(_key: String) -> Mesh:
		if not meshes.has("base"):
			meshes.base = BoxMesh.new()
		return meshes.base

	func block_visual_material(key: String) -> Material:
		return materials.get(key, materials.stoneBlock)

	func block_collision_profile(_block_type: String) -> Dictionary:
		return {"size":Vector3.ONE * CELL * 0.96, "offset":Vector3.ZERO}

var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var world := FixtureWorld.new()
	root.add_child(world)
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
		and excluded.get("reason") == "ordinary_geometry_block_type_not_migrated",
		excluded)
	var incomplete_source: Dictionary = Adapter.capture_source(structures, world, source_id)
	check("whole_source_does_not_claim_coverage_with_excluded_member",
		incomplete_source.get("status") == "pending"
		and incomplete_source.get("reason") == "ordinary_geometry_block_type_not_migrated",
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
	check("durable_tombstone_is_explicit_source_removal_and_other_unsupported_member_stays_pending",
		removed.get("status") == "empty"
		and removed_source.get("status") == "pending"
		and removed_source.get("reason") == "ordinary_geometry_block_type_not_migrated",
		removed_source)
	var changed_mesh: Dictionary = Adapter.capture_block(structures, world, source_id, multi_cell)
	check("multipart_recipe_does_not_mutate_static_body_collision",
		changed_mesh.get("status") == "ready"
		and collider.get_parent() == body and body.get_parent() == world,
		{"status":changed_mesh.get("status", ""), "colliderPresent":collider.get_parent() == body})
	var passed := true
	for row: Dictionary in checks:
		if not bool(row.passed): passed = false
	var report := {"schema":"ordinary-structure-section-geometry-adapter-contract/v1",
		"evidenceLevel":"synthetic_producer_value_and_partition_contract",
		"complete":true, "passed":passed, "checkCount":checks.size(), "checks":checks}
	var report_path := OS.get_environment("VOXEL_ORDINARY_SECTION_GEOMETRY_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	world.queue_free()
	quit(0 if passed else 1)


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


func check(name: String, passed: bool, details: Dictionary) -> void:
	checks.append({"name":name, "passed":passed,
		"details":{"status":String(details.get("status", "")),
			"reason":String(details.get("reason", "")),
			"sourcePartId":String(details.get("sourcePartId", "")),
			"memberCount":int(details.get("memberCount", -1)),
			"sectionCount":int(details.get("sectionCount", -1))}})
