extends SceneTree

const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Roster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const TreeQueue := preload("res://scripts/environment/TreePublicationQueue.gd")

class ProductionAuthority extends Node:
	var seed_text := "ecology-production-contract"
	var seed_hash := 31
	var removed_props_revision := 0
	var removed_props := {}
	var terrain_revision := 0
	var chunks: Dictionary = {}
	var production_mesh: Mesh = BoxMesh.new()
	var production_material: Material = StandardMaterial3D.new()
	var unsupported_flower_material := true
	var tree_publication_queue: Node

	func _init() -> void:
		production_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR

	func detail_mesh(_detail_type: String) -> Mesh:
		return production_mesh

	func detail_material(detail_type: String) -> Material:
		if detail_type == "flowerBloom" and unsupported_flower_material:
			return null
		return production_material

	func _ecology_chunk_source_revision(key: Vector2i) -> String:
		return "ecology-v2:%s:%d,%d:static-props-v1" % [seed_text, key.x, key.y]

	func terrain_volume_chunk_revision(_key: Vector2i, _chunk_size: int) -> int:
		return terrain_revision

var checks := {}

func _init() -> void:
	call_deferred("run")


func check(name: String, condition: bool) -> void:
	checks[name] = condition


func _candidate(source_id: String, x: float, instance_color: Color,
		detail_type := "grass") -> Dictionary:
	var mesh := BoxMesh.new()
	var transform := Transform3D(Basis.IDENTITY, Vector3(x, 1.0, 1.0))
	var material_key := "detailFlower" if detail_type == "flowerBloom" else "detailGrass"
	return {
		"sourceId":source_id,
		"kind":"surface_detail",
		"detailType":detail_type,
		"renderLayers":["alpha_scissor"],
		"materials":[material_key],
		"meshSource":"procedural_detail:%s" % detail_type,
		"transform":transform,
		"instanceColor":instance_color,
		"customData":Color(0.37, 0.0, 0.0, 1.0),
		"localBounds":mesh.get_aabb() * transform,
		"shadowCasting":"off",
		"visibilityRangeEnd":64.0
	}


func _snapshot(rows: Array, seed := "ecology-adapter-contract",
		producer_revision := "detail-producer-revision-1") -> Dictionary:
	var ledger = Ledger.new()
	ledger.configure(seed, Vector2i.ZERO, producer_revision, 0)
	for row: Dictionary in rows:
		if not ledger.record_candidate(row):
			return {}
	return ledger.snapshot()


func _bindings() -> Dictionary:
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.62, 0.78, 0.44, 1.0)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var binding := {"mesh":mesh, "material":material,
		"meshSource":"procedural_detail:grass",
		"meshResourceKey":"environment.detail.grass/v1",
		"materialKey":"detailGrass",
		"materialContentDigest":Adapter._material_digest(material),
		"pipelineRevision":"detail_pipeline_contract/v1",
		"fadeMargin":12.0}
	binding.make_read_only()
	var bindings := {"procedural_detail:grass|detailGrass":binding}
	bindings.make_read_only()
	return bindings


func _flower_surface_bindings() -> Dictionary:
	var grass_mesh := BoxMesh.new()
	var flower_mesh := BoxMesh.new()
	var grass_material := StandardMaterial3D.new()
	var flower_material := StandardMaterial3D.new()
	grass_material.albedo_color = Color(0.24, 0.55, 0.2, 1.0)
	flower_material.albedo_color = Color(0.92, 0.28, 0.52, 1.0)
	grass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	flower_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var grass_binding := {"mesh":grass_mesh, "material":grass_material,
		"meshSource":"procedural_detail:flowerBloom:surface:0",
		"meshResourceKey":"environment.detail.flowerBloom.surface.0/v1",
		"materialKey":"detailGrass",
		"materialContentDigest":Adapter._material_digest(grass_material),
		"pipelineRevision":"detail_pipeline_contract/v1", "fadeMargin":12.0}
	var flower_binding := {"mesh":flower_mesh, "material":flower_material,
		"meshSource":"procedural_detail:flowerBloom:surface:1",
		"meshResourceKey":"environment.detail.flowerBloom.surface.1/v1",
		"materialKey":"detailFlower",
		"materialContentDigest":Adapter._material_digest(flower_material),
		"pipelineRevision":"detail_pipeline_contract/v1", "fadeMargin":12.0}
	grass_binding.make_read_only()
	flower_binding.make_read_only()
	var bindings := {
		"procedural_detail:flowerBloom:surface:0|detailGrass":grass_binding,
		"procedural_detail:flowerBloom:surface:1|detailFlower":flower_binding
	}
	bindings.make_read_only()
	return bindings


func _run_realized_prop_assembler_contract() -> Dictionary:
	var section_key := Vector3i.ZERO
	var interleaved_section_key := Vector3i(1, 0, 0)
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-realized-assembler-contract"
	main.seed_hash = 83
	root.add_child(main)
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.5, 0.72, 0.42, 1.0)
	var source_id := "%s:forage:adapter-prop" % main.seed_text
	var prop_ledger: Object = null
	var prop_chunk: Node3D = null
	var setup_chunk_keys: Dictionary = {}
	for requested_section: Vector3i in [section_key, interleaved_section_key]:
		for chunk_key: Vector2i in provider._chunks_for_section(requested_section):
			setup_chunk_keys[chunk_key] = true
	for chunk_value: Variant in setup_chunk_keys:
		var chunk_key := Vector2i(chunk_value)
		var chunk_owner := Node3D.new()
		chunk_owner.position = Vector3(chunk_key.x * 32, 0, chunk_key.y * 32)
		main.add_child(chunk_owner)
		main.chunks[chunk_key] = chunk_owner
		var source_revision := main._ecology_chunk_source_revision(chunk_key)
		var ledger = Ledger.new()
		ledger.configure(main.seed_text, chunk_key, source_revision, 0, 0)
		if chunk_key == Vector2i.ZERO:
			prop_ledger = ledger
			prop_chunk = chunk_owner
			var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
			var material_digest := Adapter._material_digest(material)
			var candidate := {"sourceId":source_id, "propId":"adapter-prop",
				"kind":"realized_static_prop", "category":"forage", "sourceKind":"forage",
				"transform":Transform3D(Basis.IDENTITY, Vector3(2, 0, 2)),
				"renderStatus":"ready", "renderMembers":[{"memberId":"mushroom_cap",
					"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
					"transform":Transform3D.IDENTITY, "localBounds":mesh.get_aabb(),
					"materialKey":"forage", "renderLayer":"opaque"}],
				"provenance":{"producer":"surface_spawn", "chunk":chunk_key,
					"sourceRevision":source_revision, "terrainRevision":0,
					"creatorOutputComplete":true}}
			ledger.record_candidate(candidate)
			ledger.record_candidate(_candidate(
				"%s:detail:0,0:grass:0" % main.seed_text, 3.0, Color.WHITE, "grass"))
			ledger.record_candidate(_candidate(
				"%s:detail:0,0:flowerBloom:0" % main.seed_text, 4.0, Color.WHITE,
				"flowerBloom"))
		for category: String in ["surface_rocks", "ore", "forage"]:
			ledger.mark_category_complete(category, {"producer":"surface_spawn",
				"chunk":chunk_key, "sourceRevision":source_revision,
				"terrainRevision":0, "producerComplete":true})
		ledger.mark_category_complete("underground_props", {
			"producer":"underground_exposed_floor_scan", "chunk":chunk_key,
			"sourceRevision":source_revision, "terrainRevision":0,
			"scanRevision":"fixture-floor-scan:%d,%d" % [chunk_key.x, chunk_key.y],
			"producerComplete":true})
		var snapshot: Dictionary = ledger.snapshot()
		snapshot["status"] = "ready"
		snapshot["producerOwnerInstanceId"] = chunk_owner.get_instance_id()
		chunk_owner.set_meta("static_ecology_source_value_snapshot", snapshot)
		var resource_map: Dictionary = {}
		if chunk_key == Vector2i.ZERO:
			var resource_binding := {"mesh":mesh, "material":material,
				"meshContentDigest":String(MeshFingerprint.inspect(mesh).get("contentDigest", "")),
				"materialContentDigest":Adapter._material_digest(material),
				"materialKey":"forage", "renderLayer":"opaque"}
			resource_binding.make_read_only()
			resource_map[source_id + "|mushroom_cap"] = resource_binding
		resource_map.make_read_only()
		chunk_owner.set_meta("static_ecology_render_resource_bindings", resource_map)
	var roster := Roster.new()
	roster.bind_world(world_id, [Adapter.PROVIDER_ID])
	roster.register_provider(Adapter.PROVIDER_ID, provider, "capture_static_section_sources")
	var unsupported_census: Dictionary = roster.capture_sections([section_key])
	var unsupported_provider_census: Dictionary = provider.capture_static_section_sources(
		world_id, [section_key])
	var unsupported_detail_ids: Array[String] = [
		"%s:detail:0,0:flowerBloom:0" % main.seed_text]
	var unsupported_census_error_ids: Array[String] = []
	for source_id_value: Variant in unsupported_provider_census.get("unsupportedCandidateIds", []):
		unsupported_census_error_ids.append(String(source_id_value))
	main.unsupported_flower_material = false
	var census: Dictionary = roster.capture_sections([section_key, interleaved_section_key])
	var initial_interleaved_ids: Array = census.get("expectedContributorsBySection", {}) \
		.get(interleaved_section_key, [])
	var interleaved_census: Dictionary = roster.capture_sections([interleaved_section_key])
	var expected_sources: Array = census.get("expectedContributorsBySection", {}) \
		.get(section_key, [])
	var contribution_result: Dictionary = provider.capture_static_section_contribution(
		census, section_key) if census.get("status") == "complete" else {}
	var contributions: Array = []
	if contribution_result.get("status") == "ready":
		contributions.append(contribution_result.contribution)
	contributions.make_read_only()
	var assembled: Dictionary = Assembler.assemble(census, section_key, contributions, 1) \
		if contribution_result.get("status") == "ready" else {}
	var manifest_ids: Array[String] = []
	for row_value: Variant in assembled.get("candidate", {}).get("candidate", {}) \
			.get("snapshot", {}).get("manifest", []):
		if row_value is Dictionary:
			manifest_ids.append(String(row_value.get("sourcePartId", "")))
	var exact_manifest_ids := manifest_ids.duplicate()
	exact_manifest_ids.sort()
	var exact_expected_ids: Array[String] = []
	for expected_value: Variant in expected_sources:
		exact_expected_ids.append(String(expected_value))
	exact_expected_ids.sort()
	var conflict_members: Dictionary = {}
	var conflict_revisions: Dictionary = {}
	var first_member_accepted := Adapter._append_section_member(conflict_members,
		conflict_revisions, section_key, "conflicting-source", "revision-a")
	var conflicting_revision_rejected := not Adapter._append_section_member(
		conflict_members, conflict_revisions, section_key, "conflicting-source", "revision-b")
	mesh.size = Vector3(2.0, 2.0, 2.0)
	var stale_resource_contribution: Dictionary = provider.capture_static_section_contribution(
		census, section_key)
	mesh.size = Vector3.ONE
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var translucent_census: Dictionary = roster.capture_sections([section_key])
	var translucent_layer_fails_closed := Adapter._supported_ecology_layer(material, "opaque").is_empty()
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	main.removed_props_revision = 1
	prop_ledger = Ledger.new()
	prop_ledger.configure(main.seed_text, Vector2i.ZERO,
		main._ecology_chunk_source_revision(Vector2i.ZERO), 1, 0)
	prop_ledger.record_candidate(_candidate(
		"%s:detail:0,0:grass:0" % main.seed_text, 3.0, Color.WHITE, "grass"))
	prop_ledger.record_candidate(_candidate(
		"%s:detail:0,0:flowerBloom:0" % main.seed_text, 4.0, Color.WHITE,
		"flowerBloom"))
	prop_ledger.record_tombstone(source_id, "removed_props")
	for category: String in ["surface_rocks", "ore", "forage"]:
		prop_ledger.mark_category_complete(category, {"producer":"surface_spawn",
			"chunk":Vector2i.ZERO,
			"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
			"terrainRevision":0, "producerComplete":true})
	prop_ledger.mark_category_complete("underground_props", {
		"producer":"underground_exposed_floor_scan", "chunk":Vector2i.ZERO,
		"sourceRevision":main._ecology_chunk_source_revision(Vector2i.ZERO),
		"terrainRevision":0, "scanRevision":"fixture-floor-scan:0,0",
		"producerComplete":true})
	var tombstone_snapshot: Dictionary = prop_ledger.snapshot()
	tombstone_snapshot["status"] = "ready"
	tombstone_snapshot["producerOwnerInstanceId"] = prop_chunk.get_instance_id()
	prop_chunk.set_meta("static_ecology_source_value_snapshot", tombstone_snapshot)
	for key_value: Variant in main.chunks:
		var owner: Node3D = main.chunks[key_value]
		if owner == prop_chunk:
			continue
		var other_snapshot: Dictionary = owner.get_meta("static_ecology_source_value_snapshot", {})
		other_snapshot["removedPropsRevision"] = 1
		other_snapshot.erase("contentRevision")
		other_snapshot["contentRevision"] = Adapter._value_digest(other_snapshot)
		owner.set_meta("static_ecology_source_value_snapshot", other_snapshot)
	var tombstone_census: Dictionary = roster.capture_sections([section_key])
	var section_removals: Array = tombstone_census.get("removalsBySection", {}) \
		.get(section_key, [])
	main.free()
	return {"census":census, "expectedSources":expected_sources,
		"interleavedSectionKey":interleaved_section_key,
		"initialInterleavedIds":initial_interleaved_ids,
		"interleavedCensus":interleaved_census,
		"unsupportedCensus":unsupported_census,
		"unsupportedProviderCensus":unsupported_provider_census,
		"unsupportedDetailIds":unsupported_detail_ids,
		"unsupportedCensusErrorIds":unsupported_census_error_ids,
		"contribution":contribution_result, "assembled":assembled,
		"sourceId":source_id, "manifestIds":manifest_ids,
		"exactExpectedIds":exact_expected_ids, "exactManifestIds":exact_manifest_ids,
		"firstConflictMemberAccepted":first_member_accepted,
		"conflictingRevisionRejected":conflicting_revision_rejected,
		"staleResourceContribution":stale_resource_contribution,
		"translucentCensus":translucent_census,
		"translucentLayerFailsClosed":translucent_layer_fails_closed,
		"tombstoneCensus":tombstone_census, "sectionRemovals":section_removals,
		"tombstoneReason":String(tombstone_census.get("reason", ""))}


func run() -> void:
	var production_detail_shader := load("res://resources/visual/detail_material.gdshader") as Shader
	var production_detail_material := ShaderMaterial.new()
	production_detail_material.shader = production_detail_shader
	production_detail_material.set_shader_parameter("base_color", Color(0.8, 0.3, 0.5, 1.0))
	var production_material_digest := Adapter._material_digest(production_detail_material)
	var stable_production_material_digest := Adapter._material_digest(production_detail_material)
	production_detail_material.set_shader_parameter("base_color", Color(0.3, 0.8, 0.5, 1.0))
	var changed_production_material_digest := Adapter._material_digest(production_detail_material)
	check("production_detail_shader_is_classified_by_its_opaque_fragment_contract",
		Adapter._supported_surface_detail_layer(production_detail_material, "opaque") == "opaque" \
		and Adapter._supported_surface_detail_layer(production_detail_material,
			"alpha_scissor").is_empty())
	check("shader_material_digest_binds_code_and_supported_uniform_values",
		production_material_digest.length() == 64 \
		and production_material_digest == stable_production_material_digest \
		and production_material_digest != changed_production_material_digest)
	var texture_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	texture_image.fill(Color(0.8, 0.2, 0.1, 1.0))
	var textured_material := StandardMaterial3D.new()
	textured_material.albedo_texture = ImageTexture.create_from_image(texture_image)
	var texture_material_digest := Adapter._material_digest(textured_material)
	texture_image.fill(Color(0.1, 0.2, 0.8, 1.0))
	textured_material.albedo_texture = ImageTexture.create_from_image(texture_image)
	var changed_texture_material_digest := Adapter._material_digest(textured_material)
	check("standard_material_digest_binds_referenced_texture_content",
		texture_material_digest.length() == 64 \
		and texture_material_digest != changed_texture_material_digest)
	var rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:0", 21.0, Color.WHITE),
		_candidate("ecology-adapter-contract:detail:0,0:grass:1", 22.2, Color.WHITE)
	]
	var snapshot := _snapshot(rows)
	var world_id := "world:ecology-adapter-contract"
	var prepared: Dictionary = Adapter.prepare_surface_detail(snapshot, _bindings(),
		Transform3D.IDENTITY, world_id)
	check("canonical_detail_values_partition_to_exact_16_cell_sections",
		prepared.get("status") == "prepared" \
		and prepared.get("partition", {}).get("outputInstanceCount", -1) == 2 \
		and prepared.get("sections", {}).size() == 2)
	var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(_bindings().values()[0].mesh)
	check("shared_mesh_fingerprint_binds_actual_mesh_arrays",
		mesh_fingerprint.get("status") == "ready" \
		and String(mesh_fingerprint.get("contentDigest", "")).length() == 64)
	check("source_ids_and_content_revisions_are_retained",
		prepared.get("candidateIds", []).size() == 2 \
		and prepared.get("sourceRevisions", {}).size() == 2)
	var stable_producer_revision := "ecology-v2:reload-contract:0,0:static-props-v1"
	var initial_owner_ledger = Ledger.new()
	initial_owner_ledger.configure("reload-contract", Vector2i.ZERO,
		stable_producer_revision, 0, 0)
	initial_owner_ledger.record_candidate(_candidate(
		"reload-contract:detail:0,0:grass:0", 1.0, Color.WHITE))
	var initial_owner_snapshot: Dictionary = initial_owner_ledger.snapshot()
	var reloaded_owner_ledger = Ledger.new()
	reloaded_owner_ledger.configure("reload-contract", Vector2i.ZERO,
		stable_producer_revision, 0, 1)
	reloaded_owner_ledger.record_candidate(_candidate(
		"reload-contract:detail:0,0:grass:0", 2.0, Color.WHITE))
	var reloaded_owner_snapshot: Dictionary = reloaded_owner_ledger.snapshot()
	check("stable_producer_identity_allows_changed_reloaded_content_revision",
		initial_owner_snapshot.get("sourceRevision", "") == \
			reloaded_owner_snapshot.get("sourceRevision", "") \
		and initial_owner_snapshot.get("terrainRevision", -1) != \
			reloaded_owner_snapshot.get("terrainRevision", -1) \
		and initial_owner_snapshot.get("contentRevision", "") != \
			reloaded_owner_snapshot.get("contentRevision", ""))
	var tombstone_ledger = Ledger.new()
	tombstone_ledger.configure("ecology-tombstone-contract", Vector2i.ZERO,
		"ecology-source-r1", 6)
	var tombstone_candidate := _candidate(
		"ecology-tombstone-contract:detail:0,0:grass:harvested", 1.0, Color.WHITE)
	tombstone_candidate["propId"] = "harvested-prop"
	var candidate_recorded := tombstone_ledger.record_candidate(tombstone_candidate)
	var explicit_tombstone := tombstone_ledger.record_tombstone(
		String(tombstone_candidate.sourceId), "harvested")
	var tombstone_snapshot: Dictionary = tombstone_ledger.snapshot()
	check("producer_tombstone_replaces_current_member_with_exact_removal_revision",
		candidate_recorded and explicit_tombstone \
		and tombstone_snapshot.get("candidates", []).is_empty() \
		and tombstone_snapshot.get("removedPropsRevision", -1) == 6 \
		and tombstone_snapshot.get("tombstones", []).size() == 1 \
		and tombstone_snapshot.tombstones[0].sourceId == tombstone_candidate.sourceId)
	var durable_removal_ledger = Ledger.new()
	durable_removal_ledger.configure("ecology-durable-removal-contract", Vector2i.ZERO,
		"ecology-source-r1", 7)
	var durable_candidate := _candidate(
		"ecology-durable-removal-contract:detail:0,0:grass:removed", 1.0, Color.WHITE)
	durable_candidate["propId"] = "durable-removal"
	durable_removal_ledger.record_candidate(durable_candidate)
	durable_removal_ledger.apply_removed_props({"durable-removal":true}, 8)
	var durable_snapshot: Dictionary = durable_removal_ledger.snapshot()
	check("durable_harvest_snapshot_emits_tombstone_and_advances_removed_revision",
		durable_snapshot.get("removedPropsRevision", -1) == 8 \
		and durable_snapshot.get("candidates", []).is_empty() \
		and durable_snapshot.get("tombstones", []).size() == 1 \
		and durable_snapshot.tombstones[0].reason == "removed_props")
	var changed_producer_revision: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(rows, "ecology-adapter-contract", "detail-producer-revision-2"),
		_bindings(), Transform3D.IDENTITY, world_id)
	check("section_member_revision_binds_world_and_chunk_producer_revision",
		changed_producer_revision.get("status") == "prepared" \
		and changed_producer_revision.get("sourceRevisions", {}).values()[0] \
			!= prepared.get("sourceRevisions", {}).values()[0])
	var flower_surface_0 := _candidate(
		"ecology-adapter-contract:detail:0,0:flowerBloom:0:surface:0", 10.0,
		Color.WHITE, "flowerBloom")
	flower_surface_0["meshSource"] = "procedural_detail:flowerBloom:surface:0"
	flower_surface_0["materials"] = ["detailGrass"]
	var flower_surface_1 := _candidate(
		"ecology-adapter-contract:detail:0,0:flowerBloom:0:surface:1", 10.0,
	Color.WHITE, "flowerBloom")
	flower_surface_1["meshSource"] = "procedural_detail:flowerBloom:surface:1"
	flower_surface_1["materials"] = ["detailFlower"]
	var flower_surface_prepared := Adapter.prepare_surface_detail(
		_snapshot([flower_surface_0, flower_surface_1]), _flower_surface_bindings(),
		Transform3D.IDENTITY, world_id)
	var flower_mesh_keys: Array = flower_surface_prepared.get("meshBindings", {}).keys()
	var flower_material_keys: Array = flower_surface_prepared.get("materialBindings", {}).keys()
	check("multi_surface_flower_keeps_each_surface_material_and_source_identity",
		flower_surface_prepared.get("status") == "prepared" \
		and flower_surface_prepared.get("inputs", []).size() == 2 \
		and flower_surface_prepared.get("candidateIds", []).has(flower_surface_0.sourceId) \
		and flower_surface_prepared.get("candidateIds", []).has(flower_surface_1.sourceId) \
		and flower_mesh_keys.size() == 2 and flower_material_keys.size() == 2 \
		and flower_surface_prepared.get("partition", {}).get("outputInstanceCount", -1) == 2)
	var mixed_detail_rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:3", 9.0, Color.WHITE),
		_candidate("ecology-adapter-contract:detail:0,0:flowerBloom:0", 10.0,
			Color.WHITE, "flowerBloom")]
	var partial_detail: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(mixed_detail_rows), _bindings(), Transform3D.IDENTITY, world_id,
		["flowerBloom"])
	check("unsupported_mesh_owned_flower_materials_are_named_while_other_detail_prepares",
		partial_detail.get("status") == "prepared_partial" \
		and partial_detail.get("partition", {}).get("outputInstanceCount", -1) == 1 \
		and partial_detail.get("unsupportedCandidateIds", []).size() == 1 \
		and partial_detail.get("censusStatus", "") == "pending")
	check("prepared_instance_inputs_are_read_only_and_cutout_layered",
		prepared.get("inputs", []).is_read_only() \
		and prepared.get("inputs", [])[0].get("buffer", []).is_read_only() \
		and prepared.get("compatibilityByKey", {}).values()[0].get("renderLayer", "") == "cutout")
	check("prepared_resources_bind_through_compatibility_keys",
		prepared.get("materialBindings", {}).is_read_only() \
		and prepared.get("meshBindings", {}).is_read_only() \
		and prepared.get("materialBindings", {}).values()[0] is Material \
		and prepared.get("meshBindings", {}).values()[0] is Mesh)
	check("full_ecology_census_stays_pending_for_uncovered_categories",
		prepared.get("censusStatus") == "pending" \
		and prepared.get("missingCategories", []).has("surface_rocks") \
		and prepared.get("missingCategories", []).has("ore") \
		and prepared.get("missingCategories", []).has("forage") \
		and prepared.get("missingCategories", []).has("underground_props"))
	var production_authority := ProductionAuthority.new()
	production_authority.production_material.albedo_color = Color(0.62, 0.78, 0.44, 1.0)
	var chunk_owner := Node3D.new()
	production_authority.add_child(chunk_owner)
	production_authority.chunks[Vector2i.ZERO] = chunk_owner
	var production_snapshot := _snapshot([
		_candidate("ecology-production-contract:detail:0,0:grass:0", 2.0, Color.WHITE),
	], production_authority.seed_text,
	production_authority._ecology_chunk_source_revision(Vector2i.ZERO))
	production_snapshot["removedPropsRevision"] = production_authority.removed_props_revision
	production_snapshot["contentRevision"] = ""
	production_snapshot.erase("contentRevision")
	production_snapshot["contentRevision"] = Adapter._value_digest(production_snapshot)
	production_snapshot["producerOwnerInstanceId"] = chunk_owner.get_instance_id()
	chunk_owner.set_meta("static_ecology_source_value_snapshot", production_snapshot)
	root.add_child(production_authority)
	var production_provider = Adapter.new()
	var production_world_id := "seed:%s:%d" % [production_authority.seed_text,
		production_authority.seed_hash]
	production_provider.configure(production_world_id)
	production_provider.bind_main_authority(production_authority)
	var detail_source_id := String(production_snapshot.candidates[0].sourceId)
	var synthetic_complete_census := {"status":"complete", "worldId":production_world_id,
		"sections":[Vector3i.ZERO],
		"expectedContributorsBySection":{Vector3i.ZERO:[detail_source_id]},
		"sourceProviderIds":{detail_source_id:Adapter.PROVIDER_ID},
		"sourceRevisions":{detail_source_id:"source-revision"},
		"providerCoverageRevisions":{Adapter.PROVIDER_ID:{Vector3i.ZERO:"coverage-r1"}},
		"providerSnapshotRevisions":{Adapter.PROVIDER_ID:"provider-r1"}}
	synthetic_complete_census.make_read_only()
	var incomplete_contribution: Dictionary = production_provider.capture_static_section_contribution(
		synthetic_complete_census, Vector3i.ZERO)
	check("missing_tree_and_static_prop_categories_keep_common_contribution_retryable",
		incomplete_contribution.get("status") == "pending" \
		and incomplete_contribution.get("reason") == "ecology_static_category_coverage_incomplete" \
		and incomplete_contribution.get("missingCategories", []).has("surface_rocks") \
		and incomplete_contribution.get("missingCategories", []).has("ore") \
		and incomplete_contribution.get("missingCategories", []).has("forage") \
		and incomplete_contribution.get("missingCategories", []).has("underground_props"))
	var original_content_revision := String(production_snapshot.get("contentRevision", ""))
	production_authority.terrain_revision += 1
	var terrain_edit_capture: Dictionary = production_provider._capture_production_chunk(Vector2i.ZERO)
	check("terrain_edit_keeps_installed_physical_ecology_snapshot_current",
		production_authority.terrain_volume_chunk_revision(Vector2i.ZERO, 28) == 1 \
		and terrain_edit_capture.get("status") == "ready" \
		and String(terrain_edit_capture.get("snapshot", {}).get("contentRevision", "")) == original_content_revision \
		and production_authority._ecology_chunk_source_revision(Vector2i.ZERO) == \
			String(production_snapshot.get("sourceRevision", "")))
	var replacement_owner := Node3D.new()
	production_authority.add_child(replacement_owner)
	replacement_owner.set_meta("static_ecology_source_value_snapshot", production_snapshot.duplicate(true))
	production_authority.chunks[Vector2i.ZERO] = replacement_owner
	var replaced_owner_capture: Dictionary = production_provider._capture_production_chunk(Vector2i.ZERO)
	check("copied_ecology_snapshot_is_rejected_for_replacement_chunk_owner",
		replaced_owner_capture.get("status") == "pending" \
		and int(replaced_owner_capture.get("snapshotProducerOwnerInstanceId", 0)) == \
			chunk_owner.get_instance_id() \
		and int(replaced_owner_capture.get("currentProducerOwnerInstanceId", 0)) == \
			replacement_owner.get_instance_id())
	production_authority.chunks[Vector2i.ZERO] = chunk_owner
	replacement_owner.free()
	production_authority.removed_props_revision += 1
	var stale_retry := production_provider.capture_static_section_contribution(
		synthetic_complete_census, Vector3i.ZERO)
	check("source_revision_change_keeps_contribution_retryable_until_recaptured",
		stale_retry.get("status") == "pending" \
		and stale_retry.get("reason") == "ecology_chunk_source_snapshot_revision_stale")
	production_authority.queue_free()
	var provider = Adapter.new()
	provider.configure("world:ecology-adapter-contract")
	var roster_answer: Dictionary = provider.capture_static_section_sources(
		"world:ecology-adapter-contract", [Vector3i.ZERO])
	check("provider_matches_shared_roster_capture_method",
		provider.has_method("capture_static_section_sources"))
	check("partial_ledger_cannot_claim_explicit_empty_or_complete_census",
		roster_answer.get("status") == "pending" \
		and roster_answer.get("reason") == "ecology_main_authority_unavailable")
	var empty_detail_bindings: Dictionary = {}
	empty_detail_bindings.make_read_only()
	var empty_detail_snapshot := _snapshot([])
	var empty_detail_prepared: Dictionary = Adapter.prepare_surface_detail(
		empty_detail_snapshot, empty_detail_bindings, Transform3D.IDENTITY, world_id)
	check("producer_explicit_detail_empty_remains_only_detail_scope",
		empty_detail_prepared.get("status") == "prepared" \
		and empty_detail_prepared.get("partition", {}).get("inputInstanceCount", -1) == 0 \
		and empty_detail_prepared.get("censusStatus", "") == "pending" \
		and not empty_detail_prepared.get("missingCategories", []).has("trees_foliage_geometry") \
		and empty_detail_prepared.get("missingCategories", []).has("surface_rocks"))
	roster_answer = provider.capture_static_section_sources(
		"world:ecology-adapter-contract", [Vector3i.ZERO])
	check("immutable_values_without_live_production_authority_stay_pending",
		roster_answer.get("status") == "pending" \
		and roster_answer.get("reason") == "ecology_main_authority_unavailable")
	var producer_snapshot_with_lifecycle_marker := snapshot.duplicate(true)
	producer_snapshot_with_lifecycle_marker["status"] = "ready"
	check("producer_snapshot_digest_ignores_only_postseal_lifecycle_marker",
		Adapter._validate_snapshot(producer_snapshot_with_lifecycle_marker).get("status") == "ready")
	var tinted_rows: Array = [
		_candidate("ecology-adapter-contract:detail:0,0:grass:2", 5.0, Color(0.9, 0.96, 0.82, 1.0))
	]
	var tinted: Dictionary = Adapter.prepare_surface_detail(_snapshot(tinted_rows),
		_bindings(), Transform3D.IDENTITY, world_id)
	var tinted_buffer: Array = tinted.get("inputs", [])[0].get("buffer", []) \
		if tinted.get("status") == "prepared" and not tinted.get("inputs", []).is_empty() else []
	check("shared_instance_abi_preserves_live_multimesh_tint_and_custom_data",
		tinted.get("status") == "prepared" and tinted_buffer.size()==InstanceAttributes.FLOATS_PER_INSTANCE \
		and Color(tinted_buffer[InstanceAttributes.COLOR_OFFSET],tinted_buffer[InstanceAttributes.COLOR_OFFSET+1],
			tinted_buffer[InstanceAttributes.COLOR_OFFSET+2],tinted_buffer[InstanceAttributes.COLOR_OFFSET+3]) \
			.is_equal_approx(Color(0.9,0.96,0.82,1.0)) \
		and Color(tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET],tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+1],
			tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+2],tinted_buffer[InstanceAttributes.CUSTOM_DATA_OFFSET+3]) \
			.is_equal_approx(Color(0.37,0.0,0.0,1.0)))
	var empty_bindings: Dictionary = {}
	empty_bindings.make_read_only()
	var missing_binding: Dictionary = Adapter.prepare_surface_detail(snapshot, empty_bindings,
		Transform3D.IDENTITY, world_id)
	check("missing_mesh_material_binding_stays_pending",
		missing_binding.get("status") == "pending" \
		and missing_binding.get("reason") == "surface_detail_mesh_material_binding_missing")
	var mutated_snapshot := snapshot.duplicate(true)
	var mutated_candidate: Dictionary = mutated_snapshot.candidates[0]
	mutated_candidate["transform"] = Transform3D(Basis.IDENTITY, Vector3(16.0, 1.0, 1.0))
	var stale: Dictionary = Adapter.prepare_surface_detail(mutated_snapshot, _bindings(),
		Transform3D.IDENTITY, world_id)
	check("mutated_capture_without_revision_update_is_rejected",
		stale.get("status") == "failed")
	var empty_provider = Adapter.new()
	empty_provider.configure(world_id)
	var empty_answer: Dictionary = empty_provider.capture_static_section_sources(
		world_id, [Vector3i.ZERO])
	check("provider_without_live_authority_cannot_accept_empty_domain",
		empty_answer.get("status") == "pending")
	var realized_assembler_result := _run_realized_prop_assembler_contract()
	var uncommitted_tree_result := _tree_without_committed_queue_geometry_stays_pending()
	check("enumerated_tree_without_committed_queue_geometry_stays_pending",
		uncommitted_tree_result.get("status") == "pending" \
		and uncommitted_tree_result.get("reason") == "ecology_tree_queue_geometry_not_committed" \
		and uncommitted_tree_result.get("sourceId", "").ends_with(":tree:uncommitted-tree"))
	check("realized_prop_ids_are_enumerated_into_exact_completed_section_roster",
		realized_assembler_result.get("census", {}).get("status") == "complete" \
		and realized_assembler_result.get("initialInterleavedIds", []).is_empty() \
		and realized_assembler_result.get("exactExpectedIds", []) == \
			realized_assembler_result.get("exactManifestIds", []) \
		and realized_assembler_result.get("expectedSources", []).has(
			String(realized_assembler_result.get("sourceId", ""))))
	check("unsupported_flower_keeps_mixed_grass_flower_roster_pending_with_exact_id",
		realized_assembler_result.get("unsupportedCensus", {}).get("status") == "pending" \
		and realized_assembler_result.get("unsupportedDetailIds", []) == \
			realized_assembler_result.get("unsupportedCensusErrorIds", []) \
		and realized_assembler_result.get("unsupportedProviderCensus", {}).get(
			"unsupportedCandidateIds", []) == realized_assembler_result.get("unsupportedDetailIds", []))
	check("conflicting_source_revision_cannot_be_silently_omitted_from_census",
		realized_assembler_result.get("firstConflictMemberAccepted", false) \
		and realized_assembler_result.get("conflictingRevisionRejected", false))
	check("realized_prop_resources_reach_shared_section_candidate",
		realized_assembler_result.get("contribution", {}).get("status") == "ready" \
		and realized_assembler_result.get("assembled", {}).get("status") == "ready" \
		and realized_assembler_result.get("manifestIds", []).has(
			String(realized_assembler_result.get("sourceId", ""))))
	check("adapter_rechecks_mesh_fingerprint_before_candidate_contribution",
		realized_assembler_result.get("staleResourceContribution", {}).get("status") == "pending" \
		and realized_assembler_result.get("staleResourceContribution", {}).get("reason") \
			== "ecology_static_prop_resource_fingerprint_stale")
	check("translucent_material_semantics_remain_pending",
		realized_assembler_result.get("translucentCensus", {}).get("status") == "pending" \
		and realized_assembler_result.get("translucentLayerFailsClosed", false))
	check("durable_prop_tombstone_becomes_exact_section_removal",
		realized_assembler_result.get("tombstoneCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("sectionRemovals", []).size() == 1 \
		and realized_assembler_result.get("sectionRemovals", [])[0].get("sourcePartId") \
			== String(realized_assembler_result.get("sourceId", "")))
	check("section_removal_history_survives_interleaved_partial_census",
		realized_assembler_result.get("interleavedCensus", {}).get("status") == "complete" \
		and realized_assembler_result.get("interleavedCensus", {}).get(
			"expectedContributorsBySection", {}).get(
			realized_assembler_result.get("interleavedSectionKey"), []).is_empty() \
		and realized_assembler_result.get("sectionRemovals", []).size() == 1 \
		and realized_assembler_result.get("sectionRemovals", [])[0].get("sourcePartId") \
			== String(realized_assembler_result.get("sourceId", "")))
	var report := {"schema":"ecology-section-value-adapter-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"surfaceDetailPartitionOutputs":prepared.get("partition", {}).get("outputInstanceCount", 0),
		"tombstoneCensusStatus":realized_assembler_result.get("tombstoneCensus", {}).get("status", ""),
		"tombstoneCensusReason":realized_assembler_result.get("tombstoneCensus", {}).get("reason", ""),
		"successfulCensusReason":realized_assembler_result.get("census", {}).get("reason", ""),
		"successfulCensusStatus":realized_assembler_result.get("census", {}).get("status", ""),
		"tombstoneCensusDetails":realized_assembler_result.get("tombstoneCensus", {}).get("details", {}),
		"tombstoneRemovals":realized_assembler_result.get("sectionRemovals", []),
		"uncommittedTreeStatus":uncommitted_tree_result.get("status", ""),
		"uncommittedTreeReason":uncommitted_tree_result.get("reason", ""),
		"uncommittedTreeSourceId":uncommitted_tree_result.get("sourceId", ""),
		"unsupportedDetailIds":realized_assembler_result.get("unsupportedDetailIds", []),
		"unsupportedCensusErrorIds":realized_assembler_result.get("unsupportedCensusErrorIds", []),
		"unsupportedCensusReason":realized_assembler_result.get("unsupportedCensus", {}).get("reason", ""),
		"exactExpectedIds":realized_assembler_result.get("exactExpectedIds", []),
		"exactManifestIds":realized_assembler_result.get("exactManifestIds", []),
		"preparedStatus":prepared.get("status", "missing"),
		"preparedReason":prepared.get("reason", ""),
		"tintedStatus":tinted.get("status", "missing"),
		"tintedReason":tinted.get("reason", ""),
		"evidence":"synthetic immutable producer-value contract plus realized static prop census-to-assembler; no production native install, gameplay, save/replay, or performance acceptance"}
	var report_path := OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("ECOLOGY SECTION VALUE ADAPTER ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _tree_without_committed_queue_geometry_stays_pending() -> Dictionary:
	var section_key := Vector3i.ZERO
	var main := ProductionAuthority.new()
	main.seed_text = "ecology-uncommitted-tree-contract"
	main.seed_hash = 89
	root.add_child(main)
	main.tree_publication_queue = TreeQueue.new()
	main.add_child(main.tree_publication_queue)
	var provider = Adapter.new()
	var world_id := "seed:%s:%d" % [main.seed_text, main.seed_hash]
	provider.configure(world_id)
	provider.bind_main_authority(main)
	var result := {}
	for chunk_key: Vector2i in provider._chunks_for_section(section_key):
		var owner := Node3D.new()
		owner.position = Vector3(chunk_key.x * 32, 0, chunk_key.y * 32)
		main.add_child(owner)
		main.chunks[chunk_key] = owner
		var source_revision := main._ecology_chunk_source_revision(chunk_key)
		var ledger = Ledger.new()
		ledger.configure(main.seed_text, chunk_key, source_revision, 0, 0)
		if chunk_key == Vector2i.ZERO:
			var tree_source_id := "%s:tree:uncommitted-tree" % main.seed_text
			var tree_candidate := {"sourceId":tree_source_id,
				"propId":"uncommitted-tree", "kind":"trees_foliage",
				"renderLayers":["opaque"], "materials":["tree"],
				"transform":Transform3D.IDENTITY, "localBounds":AABB(Vector3.ZERO, Vector3.ONE)}
			ledger.record_candidate(tree_candidate)
		for category: String in ["surface_rocks", "ore", "forage"]:
			ledger.mark_category_complete(category, {"producer":"surface_spawn",
				"chunk":chunk_key, "sourceRevision":source_revision,
				"terrainRevision":0, "producerComplete":true})
		ledger.mark_category_complete("underground_props", {
			"producer":"underground_exposed_floor_scan", "chunk":chunk_key,
			"sourceRevision":source_revision, "terrainRevision":0,
			"scanRevision":"fixture-floor-scan:%d,%d" % [chunk_key.x, chunk_key.y],
			"producerComplete":true})
		var snapshot: Dictionary = ledger.snapshot()
		snapshot["status"] = "ready"
		snapshot["producerOwnerInstanceId"] = owner.get_instance_id()
		owner.set_meta("static_ecology_source_value_snapshot", snapshot)
		var resource_bindings := {}
		resource_bindings.make_read_only()
		owner.set_meta("static_ecology_render_resource_bindings", resource_bindings)
	var roster := Roster.new()
	roster.bind_world(world_id, [Adapter.PROVIDER_ID])
	roster.register_provider(Adapter.PROVIDER_ID, provider, "capture_static_section_sources")
	result = provider.capture_static_section_sources(world_id, [section_key])
	main.free()
	return result
