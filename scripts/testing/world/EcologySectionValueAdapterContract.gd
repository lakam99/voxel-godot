extends SceneTree

const Adapter := preload("res://scripts/world/EcologySectionValueAdapter.gd")
const Ledger := preload("res://scripts/world/EcologySourceValueLedger.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")

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


func run() -> void:
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
	var changed_producer_revision: Dictionary = Adapter.prepare_surface_detail(
		_snapshot(rows, "ecology-adapter-contract", "detail-producer-revision-2"),
		_bindings(), Transform3D.IDENTITY, world_id)
	check("section_member_revision_binds_world_and_chunk_producer_revision",
		changed_producer_revision.get("status") == "prepared" \
		and changed_producer_revision.get("sourceRevisions", {}).values()[0] \
			!= prepared.get("sourceRevisions", {}).values()[0])
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
		and prepared.get("missingCategories", []).has("trees_foliage_geometry") \
		and prepared.get("missingCategories", []).has("surface_rocks") \
		and prepared.get("missingCategories", []).has("ore") \
		and prepared.get("missingCategories", []).has("forage") \
		and prepared.get("missingCategories", []).has("underground_props"))
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
		and empty_detail_prepared.get("missingCategories", []).has("trees_foliage_geometry"))
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
	var report := {"schema":"ecology-section-value-adapter-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"surfaceDetailPartitionOutputs":prepared.get("partition", {}).get("outputInstanceCount", 0),
		"preparedStatus":prepared.get("status", "missing"),
		"preparedReason":prepared.get("reason", ""),
		"tintedStatus":tinted.get("status", "missing"),
		"tintedReason":tinted.get("reason", ""),
		"evidence":"synthetic immutable producer-value contract; prepared detail partition only; no production registration, native renderer install, complete ecology census, gameplay, save/replay, or performance acceptance"}
	var report_path := OS.get_environment("ECOLOGY_SECTION_VALUE_ADAPTER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("ECOLOGY SECTION VALUE ADAPTER ", JSON.stringify(report))
	quit(0 if report.passed else 1)
