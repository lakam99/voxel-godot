extends SceneTree
## Synthetic producer contract: immutable building transform artifacts and the
## legacy visual remain together until the shared section receipt is integrated.

const Publisher := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const InstanceBuffer := preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MaterialCatalog := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const GeometryAdapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const StaticSectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Spatial := preload("res://scripts/buildings/BuildingSpatialDependencies.gd")
const FurnishingPlan := preload("res://scripts/buildings/FurnishingPlan.gd")
const CitadelPlan := preload("res://scripts/world/CitadelPublicationPlan.gd")

class NonPacketPublisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	func static_packet_group_eligible(_group: Dictionary, _parent: Node3D) -> bool:
		return false

class MissingIdentityPendingJob extends RefCounted:
	var advanced := false
	func source_part(): return null
	func advance(_publisher, _budget_usec: int) -> Dictionary:
		advanced = true
		return {"status":"ready"}

var checks: Dictionary = {}
var mixed_group_evidence: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var admission_probe = Publisher.new()
	var admission_part := Part.new({"id":"admission-probe", "kind":"beam",
		"material":"stone_foundation", "position":Vector3.ZERO, "size":Vector3.ONE,
		"collision":true})
	admission_probe._record_completed_source_part(admission_part)
	var admission_boundary: Dictionary = admission_probe._pending_publication_boundary
	var initial_admission: bool = admission_probe._commit_publication_boundary(admission_boundary,{})
	var old_group := {"acceptedRevision":"prior"}
	old_group.make_read_only()
	var old_groups: Array[Dictionary] = [old_group]
	old_groups.make_read_only()
	admission_probe._static_section_transform_artifacts[admission_part.id]=old_groups
	admission_probe._static_section_transform_artifact_revisions[admission_part.id]="prior"
	var old_expected := {"source":"prior"}
	admission_probe._chunk_static_packet_expected[admission_part.id]=old_expected
	var old_metadata := {"sentinel":"prior"}
	admission_probe._static_record_cache=old_metadata
	admission_probe._record_completed_source_part(admission_part)
	var invalid_boundary: Dictionary = admission_probe._pending_publication_boundary
	var invalid_commit: bool = admission_probe._commit_publication_boundary(invalid_boundary,
		{"foreign-source":[]})
	checks["invalid_artifact_commit_preserves_prior_accepted_revision"] = initial_admission \
		and not invalid_commit and admission_probe._publication_epoch==1 \
		and is_same(admission_probe._last_publication_boundary,admission_boundary) \
		and is_same(admission_probe._pending_publication_boundary,invalid_boundary) \
		and not bool(invalid_boundary.get("committed",false)) \
		and is_same(admission_probe._static_section_transform_artifacts[admission_part.id],old_groups) \
		and admission_probe._static_section_transform_artifact_revisions[admission_part.id]=="prior" \
		and is_same(admission_probe._chunk_static_packet_expected[admission_part.id],old_expected) \
		and is_same(admission_probe._static_record_cache,old_metadata) and admission_part.collision_enabled
	var publisher = Publisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "contract-blueprint"
	publisher.publication_site_id = "contract-citadel"
	publisher._scene_parent = weakref(parent)
	var material: Material = MaterialCatalog.create_material("stone_foundation")
	publisher.material_cache = {"stone_foundation":material}
	var part := Part.new({"id":"castle_tower_04_battlement_front_0",
		"kind":"beam", "material":"stone_foundation", "position":Vector3.ZERO,
		"size":Vector3.ONE, "collision":true,
		"recipe":{"visual":true, "semantic":"castle_battlement"}})
	var revision := Preparation.static_record_binding(part.snapshot())
	publisher.static_visual_source_part_id = part.id
	publisher.static_visual_source_revision = revision
	publisher.static_visual_owner_cell = Vector2i.ZERO
	publisher.static_visual_render_chunk_key = Vector2i.ZERO
	publisher.static_visual_part_tier = "structural"
	var transforms: Array[Transform3D] = [
		Transform3D(Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(1.0,18.0,2.0)),
		Transform3D(Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(2.0,18.0,2.0))]
	var custom: Array[Color] = [Color(0.2,0.4,0.6,1.0),Color(0.8,0.3,0.1,1.0)]
	for index in transforms.size():
		publisher.collect_static_visual_transform(transforms[index],material,custom[index])
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent,false)
	var turns := 0
	while publisher.has_pending_static_flush() and turns < 1000:
		publisher.advance_static_flush(parent,1)
		turns += 1
	var capture: Dictionary = publisher.capture_static_section_transform_artifacts(part.id,revision)
	var groups: Array = capture.get("groups",[])
	var artifact: Dictionary = groups[0] if not groups.is_empty() else {}
	var segments: Array = artifact.get("segments",[])
	var segment: Dictionary = segments[0] if not segments.is_empty() else {}
	var expected_buffer: Array = Array(InstanceBuffer.encode(transforms[0],custom[0]))
	checks["publication_boundary_completes_with_artifact"] = turns < 1000 \
		and not publisher.has_pending_static_flush() and capture.get("status")=="ready" \
		and int(capture.get("groupCount",0))==1
	var visual_receipt: Dictionary = publisher.capture_committed_static_visual_source(part.id, revision)
	checks["visual_source_receipt_binds_boundary_owner_and_revision_without_physical_attachment"] = visual_receipt.get("status") == "ready" \
		and publisher._physical_packet_bindings_by_part_id.is_empty() \
		and visual_receipt.visualSourceReceipt.publicationEpoch == 1 \
		and visual_receipt.visualSourceReceipt.publisherInstanceId == publisher.get_instance_id() \
		and visual_receipt.visualSourceReceipt.sourceRevision == revision
	checks["visual_source_receipt_rejects_changed_expected_source"] = publisher.capture_committed_static_visual_source(part.id, "changed").get("status") == "pending"
	checks["committed_boundary_without_transform_artifact_is_not_empty_success"] = admission_probe.capture_committed_static_visual_source(admission_part.id,
		Preparation.static_record_binding(admission_part.snapshot())).get("status") == "pending"
	var prepared_parent := Node3D.new()
	root.add_child(prepared_parent)
	var prepared_publisher = NonPacketPublisher.new()
	prepared_publisher.unit_box = BoxMesh.new()
	prepared_publisher.source_blueprint_id = "contract-prepared-blueprint"
	prepared_publisher.publication_site_id = "contract-prepared-citadel"
	prepared_publisher._scene_parent = weakref(prepared_parent)
	var prepared_material: Material = MaterialCatalog.create_material("stone_foundation")
	prepared_publisher.material_cache = {"stone_foundation":prepared_material}
	var prepared_part := Part.new({"id":"prepared-segment-probe", "kind":"beam",
		"material":"stone_foundation", "position":Vector3.ZERO, "size":Vector3.ONE,
		"collision":false})
	var prepared_revision := Preparation.static_record_binding(prepared_part.snapshot())
	prepared_publisher.static_visual_source_part_id = prepared_part.id
	prepared_publisher.static_visual_source_revision = prepared_revision
	prepared_publisher.static_visual_owner_cell = Vector2i.ZERO
	prepared_publisher.static_visual_render_chunk_key = Vector2i.ZERO
	prepared_publisher.static_visual_part_tier = "structural"
	var prepared_transforms: Array[Transform3D] = [
		Transform3D(Basis.from_scale(Vector3(0.4,0.5,0.6)),Vector3(4.0,2.0,1.0)),
		Transform3D(Basis.from_scale(Vector3(0.7,0.8,0.9)),Vector3(5.0,2.0,1.0))]
	var prepared_custom: Array[Color] = [Color(0.1,0.3,0.5,1.0),Color(0.9,0.7,0.2,1.0)]
	var prepared_compiled: Array = InstanceBuffer.compile(prepared_transforms,
		prepared_custom, Transform3D.IDENTITY, Callable(), "prepared-segment-contract")
	var prepared_segment: Dictionary = prepared_compiled[0] if not prepared_compiled.is_empty() else {}
	prepared_publisher.collect_prepared_static_visual_segment(prepared_segment, prepared_material)
	var prepared_batch: Dictionary = prepared_publisher.static_visual_batches.values()[0] \
		if not prepared_publisher.static_visual_batches.is_empty() else {}
	var prepared_path_retained: bool = prepared_batch.get("preparedSegments", {}).size() == 1
	prepared_publisher._record_completed_source_part(prepared_part)
	prepared_publisher._begin_static_flush(prepared_parent, false)
	var prepared_turns := 0
	while prepared_publisher.has_pending_static_flush() and prepared_turns < 1000:
		prepared_publisher.advance_static_flush(prepared_parent, 1)
		prepared_turns += 1
	var prepared_capture: Dictionary = prepared_publisher.capture_static_section_transform_artifacts(
		prepared_part.id, prepared_revision)
	var prepared_groups: Array = prepared_capture.get("groups", [])
	var prepared_artifact: Dictionary = prepared_groups[0] if not prepared_groups.is_empty() else {}
	var prepared_artifact_segments: Array = prepared_artifact.get("segments", [])
	var prepared_artifact_segment: Dictionary = prepared_artifact_segments[0] \
		if not prepared_artifact_segments.is_empty() else {}
	checks["prepared_segment_source_also_commits_a_section_artifact"] = prepared_path_retained \
		and prepared_turns < 1000 and not prepared_publisher.has_pending_static_flush() \
		and prepared_capture.get("status") == "ready" \
		and String(prepared_artifact.get("sourcePartId", "")) == prepared_part.id \
		and String(prepared_artifact.get("sourceRevision", "")) == prepared_revision
	checks["noncolliding_decorative_source_commits_without_physical_binding"] = not prepared_part.collision_enabled \
		and prepared_publisher._physical_packet_bindings_by_part_id.is_empty() \
		and prepared_publisher.capture_committed_static_visual_source(prepared_part.id, prepared_revision).get("status") == "ready"
	checks["prepared_segment_artifact_preserves_flattened_instance_payload"] = \
		prepared_artifact_segment.get("instanceCount") == prepared_transforms.size() \
		and prepared_artifact_segment.get("instanceCount") == prepared_segment.get("instanceCount") \
		and prepared_artifact_segment.get("buffer") == prepared_segment.get("buffer") \
		and prepared_artifact_segment.get("bounds") == prepared_segment.get("bounds") \
		and prepared_artifact_segment.get("buffer") is Array \
		and prepared_artifact_segment.buffer.slice(0,Attributes.FLOATS_PER_INSTANCE) \
			== Array(InstanceBuffer.encode(prepared_transforms[0],prepared_custom[0])) \
		and prepared_artifact_segment.buffer.slice(Attributes.FLOATS_PER_INSTANCE,
			2 * Attributes.FLOATS_PER_INSTANCE) \
			== Array(InstanceBuffer.encode(prepared_transforms[1],prepared_custom[1]))
	checks["artifact_binds_exact_source_revision_and_owners"] = artifact.get("schema")=="building-static-transform-section-artifact/v1" \
		and String(artifact.get("sourceId","")).begins_with("building-transform:contract-citadel:") \
		and artifact.get("sourcePartId")==part.id and artifact.get("sourceRevision")==revision \
		and artifact.get("ownerCell")==Vector2i.ZERO and artifact.get("renderChunkKey")==Vector2i.ZERO \
		and artifact.get("materialKey")=="stone_foundation" and artifact.get("renderTier")=="structural" \
		and artifact.get("renderLayer")=="opaque" and artifact.get("transparencySortPolicy")=="none"
	checks["artifact_segments_are_readonly_and_exact"] = artifact.is_read_only() \
		and artifact.get("segments") is Array and artifact.segments.is_read_only() \
		and segment.is_read_only() and segment.get("instanceAttributeLayout")==Attributes.LAYOUT_SCHEMA \
		and segment.get("instanceCount")==2 and segment.get("buffer") is Array \
		and segment.buffer.get_typed_builtin()==TYPE_FLOAT and segment.buffer.is_read_only() \
		and segment.buffer.size()==2*Attributes.FLOATS_PER_INSTANCE \
		and segment.buffer.slice(0,Attributes.FLOATS_PER_INSTANCE)==expected_buffer \
		and segment.buffer.slice(Attributes.FLOATS_PER_INSTANCE,2*Attributes.FLOATS_PER_INSTANCE) \
			== Array(InstanceBuffer.encode(transforms[1],custom[1])) \
		and artifact.get("localBounds") is AABB and artifact.get("worldBounds") is AABB
	checks["legacy_multimesh_remains_the_only_visible_source_visual"] = publisher.published_nodes.size()==1 \
		and publisher.published_nodes[0] is MultiMeshInstance3D \
		and (publisher.published_nodes[0] as MultiMeshInstance3D).visible \
		and publisher.static_visual_batches.is_empty() \
		and publisher._chunk_static_packet_expected.is_empty() \
		and publisher._chunk_static_packet_receipts.is_empty()
	checks["stale_and_missing_revisions_fail_closed"] = publisher.capture_static_section_transform_artifacts( \
		part.id,revision+"-stale").get("status")=="pending" \
		and publisher.capture_static_section_transform_artifacts("missing-part",revision).get("status")=="pending"
	checks["target_battlement_uses_real_opaque_building_shader"] = material is ShaderMaterial \
		and publisher.static_visual_layer_policy(material).get("renderLayer")=="opaque" \
		and publisher.static_visual_layer_policy(material).get("transparencySortPolicy")=="none" \
		and String(artifact.get("materialContentDigest", ""))==String(GeometryAdapter._material_identity(material).get("digest", "")) \
		and material.get_shader_parameter("base_color")==Color(0.285,0.300,0.275)
	var changed_material: ShaderMaterial = material as ShaderMaterial
	changed_material.set_shader_parameter("base_color",Color(0.4,0.2,0.1))
	checks["material_parameter_mutation_invalidates_capture"] = publisher.capture_static_section_transform_artifacts( \
		part.id,revision).get("status")=="pending"
	changed_material.set_shader_parameter("base_color",Color(0.285,0.300,0.275))
	var restored_capture: Dictionary = publisher.capture_static_section_transform_artifacts(part.id,revision)
	publisher.unit_box.size=Vector3(2.0,1.0,1.0)
	checks["mesh_resource_mutation_invalidates_capture"] = restored_capture.get("status")=="ready" \
		and publisher.capture_static_section_transform_artifacts(part.id,revision).get("status")=="pending"
	var previous_artifacts: Array = publisher._static_section_transform_artifacts[part.id]
	var previous_artifact_revision: String = publisher._static_section_transform_artifact_revisions[part.id]
	publisher._record_completed_source_part(part)
	var mesh_stale_boundary: Dictionary = publisher._pending_publication_boundary
	var mesh_stale_commit: bool = publisher._commit_publication_boundary(mesh_stale_boundary,
		{part.id:[artifact]})
	checks["mesh_mutation_rejects_commit_without_replacing_prior_artifact"] = not mesh_stale_commit \
		and publisher._publication_epoch==1 \
		and is_same(publisher._static_section_transform_artifacts[part.id],previous_artifacts) \
		and publisher._static_section_transform_artifact_revisions[part.id]==previous_artifact_revision \
		and is_same(publisher._pending_publication_boundary,mesh_stale_boundary) \
		and not bool(mesh_stale_boundary.get("committed",false))
	publisher.unit_box.size=Vector3.ONE
	parent.position=Vector3(1.0,0.0,0.0)
	var moved_owner_capture: Dictionary = publisher.capture_static_section_transform_artifacts(part.id,revision)
	var moved_owner_commit: bool = publisher._commit_publication_boundary(mesh_stale_boundary,
		{part.id:[artifact]})
	checks["same_owner_cell_parent_move_rejects_capture_and_commit"] = moved_owner_capture.get("status")=="pending" \
		and not moved_owner_commit and publisher._publication_epoch==1 \
		and is_same(publisher._static_section_transform_artifacts[part.id],previous_artifacts) \
		and is_same(publisher._pending_publication_boundary,mesh_stale_boundary) \
		and not bool(mesh_stale_boundary.get("committed",false))
	checks["source_part_collision_intent_is_unmodified"] = part.collision_enabled \
		and bool(part.snapshot().get("collision",false))
	var prior_prepared_receipt: Dictionary = prepared_publisher.capture_committed_static_visual_source(prepared_part.id, prepared_revision)
	prepared_publisher._record_completed_source_part(prepared_part)
	checks["pending_visual_boundary_cannot_reuse_previous_committed_receipt"] = \
		prepared_publisher.capture_committed_static_visual_source(prepared_part.id, prepared_revision).get("status") == "pending" \
		and not prepared_publisher._static_section_transform_artifacts.get(prepared_part.id, []).is_empty()
	var empty_artifact_commit: bool = prepared_publisher._commit_publication_boundary(prepared_publisher._pending_publication_boundary, {})
	checks["empty_artifact_boundary_is_pending_not_authoritative_removal"] = empty_artifact_commit \
		and prepared_publisher.committed_static_visual_source_identity(prepared_part.id).get("status") == "ready" \
		and prepared_publisher.capture_committed_static_visual_source(prepared_part.id, prepared_revision).get("status") == "pending"
	prepared_publisher._record_completed_source_part(prepared_part)
	var replay_committed: bool = prepared_publisher._commit_publication_boundary(prepared_publisher._pending_publication_boundary, {prepared_part.id:prepared_groups})
	var replay_receipt: Dictionary = prepared_publisher.capture_committed_static_visual_source(prepared_part.id, prepared_revision)
	checks["same_visual_source_replay_requires_fresh_committed_epoch"] = replay_committed \
		and replay_receipt.get("status") == "ready" \
		and replay_receipt.visualSourceReceipt.publicationEpoch > prior_prepared_receipt.get("visualSourceReceipt", {}).get("publicationEpoch", 0) \
		and replay_receipt.visualSourceReceipt != prior_prepared_receipt.get("visualSourceReceipt", {})
	_mixed_group_completeness_contract()
	_visual_plan_identity_contract()
	var delayed_evidence := _delayed_resumable_prepared_source_contract()
	for check_name: String in delayed_evidence.get("checks", {}):
		checks[check_name] = bool(delayed_evidence.checks[check_name])
	var report := {"evidence":"synthetic_building_static_section_transform_artifact_contract",
		"mixedGroupEvidence":mixed_group_evidence,
		"checks":checks,"artifactCount":groups.size(),
		"delayedResumableSource":delayed_evidence.get("evidence", {}),
		"preparedSegmentEvidence":{"pathRetained":prepared_path_retained,
			"compiledSegmentCount":prepared_compiled.size(),
			"compiledInstanceCount":prepared_segment.get("instanceCount", 0),
			"flushTurns":prepared_turns,
			"flushPending":prepared_publisher.has_pending_static_flush(),
			"captureStatus":prepared_capture.get("status", ""),
			"captureReason":prepared_capture.get("reason", ""),
			"captureGroupCount":prepared_groups.size(),
			"artifactSourcePartId":prepared_artifact.get("sourcePartId", ""),
			"artifactSourceRevision":prepared_artifact.get("sourceRevision", ""),
			"expectedSourceRevision":prepared_revision,
			"diagnostics":prepared_publisher._static_section_transform_artifact_diagnostics.duplicate(true)},
		"diagnostics":publisher._static_section_transform_artifact_diagnostics,
		"passed":not checks.values().has(false),
		"doesNotProve":"Citadel provider integration, shared section installation/retirement, native live rendering, collision traversal, save/load, or performance."}
	var path := OS.get_environment("BUILDING_STATIC_SECTION_TRANSFORM_ARTIFACT_REPORT")
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("BUILDING STATIC SECTION TRANSFORM ARTIFACT ",JSON.stringify(report))
	prepared_parent.queue_free()
	parent.queue_free()
	quit(0 if report.passed else 1)


func _visual_plan_identity_contract() -> void:
	# Self-contained synthetic source; the production Part/spatial/Plan path
	# proves identity rules without depending on an archived full-Citadel blob.
	var blueprint := Blueprint.new("visual-plan-contract", 719, "timber")
	blueprint.add_part({"id":"solid", "kind":"beam", "material":"stone_foundation",
		"position":Vector3.ZERO, "size":Vector3.ONE, "collision":true})
	blueprint.add_part({"id":"decoration", "kind":"beam", "material":"stone_foundation",
		"position":Vector3(2, 0, 0), "size":Vector3.ONE, "collision":false})
	blueprint.add_part({"id":"door", "kind":"door", "material":"painted_door",
		"position":Vector3(4, 0, 0), "size":Vector3.ONE, "collision":true})
	var furniture := FurnishingPlan.new("visual-plan-furniture", 719, blueprint.id)
	var binding := {"siteId":"visual-plan-site", "sourceKey":"visual-plan-source", "generation":1}
	var description = Spatial.compile_description(blueprint, furniture, binding, Vector3.ZERO, Callable())
	var building_source: Dictionary = Preparation._freeze_value(blueprint.snapshot())
	var furnishing_source: Dictionary = Preparation._freeze_value(furniture.snapshot())
	var eligibility := Preparation.classify_physical_group_packet_eligibility(
		description.publication_groups, building_source, furnishing_source)
	var result := CitadelPlan.build(description, building_source, furnishing_source, eligibility)
	var revisions: Dictionary = result.get("plan").visual_source_revisions if result.get("ready", false) else {}
	var exact: bool = result.get("ready", false) and revisions.is_read_only() and revisions.size() == 3
	var encoder_parity := true
	for record: Dictionary in building_source.parts:
		# Exact algorithm before helper extraction, including padding zeroing.
		var prior_bytes := var_to_bytes(record)
		prior_bytes.fill(0)
		encoder_parity = encoder_parity and prior_bytes.encode_var(0, record) == prior_bytes.size() \
			and prior_bytes.hex_encode() == Preparation.static_record_binding(record)
		exact = exact and revisions.get(String(record.id), "") == Preparation.static_record_binding(record)
	checks["record_binding_extraction_preserves_exact_serialization_bytes"] = encoder_parity
	checks["plan_expected_revisions_include_noncolliding_and_direct_door_sources"] = exact
	var changed_source := building_source.duplicate(false)
	var changed_parts: Array = building_source.parts.duplicate(false)
	var changed_part: Dictionary = changed_parts[1].duplicate(false)
	changed_part["position"] = Vector3(2.125, 0, 0)
	changed_part.make_read_only()
	changed_parts[1] = changed_part
	changed_parts.make_read_only()
	changed_source["parts"] = changed_parts
	changed_source.make_read_only()
	var changed := CitadelPlan.build(description, changed_source, furnishing_source, eligibility)
	checks["plan_signature_binds_noncolliding_source_transform"] = exact and changed.get("ready", false) \
		and changed.outputSignature != result.outputSignature \
		and changed.plan.visual_source_revisions.decoration != revisions.decoration
	var replay := CitadelPlan.build(description, building_source, furnishing_source, eligibility)
	checks["plan_visual_identity_replays_deterministically"] = exact and replay.get("ready", false) \
		and replay.outputSignature == result.outputSignature


func _mixed_group_completeness_contract() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var publisher := NonPacketPublisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher._scene_parent = weakref(parent)
	publisher.publication_site_id = "mixed-group-contract"
	publisher.source_blueprint_id = "mixed-group-blueprint"
	var part := Part.new({"id":"mixed-source", "kind":"beam", "material":"stone_foundation",
		"position":Vector3.ZERO, "size":Vector3.ONE, "collision":false})
	var revision := Preparation.static_record_binding(part.snapshot())
	var material := StandardMaterial3D.new()
	publisher.material_cache = {"stone_foundation":material}
	publisher.static_visual_source_part_id = part.id
	publisher.static_visual_source_revision = revision
	publisher.collect_static_visual_transform(Transform3D.IDENTITY, material, Color.WHITE)
	var valid_group: Dictionary = publisher.static_visual_batches.values()[0]
	var rejected_group := valid_group.duplicate(false)
	rejected_group["renderLayer"] = "unsupported-layer"
	publisher.static_visual_batches = {"accepted":valid_group, "rejected":rejected_group}
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent, false)
	var turns := 0
	while publisher.has_pending_static_flush() and turns < 1000:
		publisher.advance_static_flush(parent, 4000)
		turns += 1
	var mixed_capture := publisher.capture_committed_static_visual_source(part.id, revision)
	mixed_group_evidence["first"] = {"turns":turns, "capture":mixed_capture,
		"boundary":publisher._last_publication_boundary,
		"storedGroupCount":publisher._static_section_transform_artifacts.get(part.id, []).size(),
		"diagnostics":publisher._static_section_transform_artifact_diagnostics.duplicate(true)}
	checks["mixed_good_and_rejected_groups_never_form_complete_source"] = turns < 1000 \
		and publisher._last_publication_boundary.get("committed", false) \
		and publisher._static_section_transform_artifacts.get(part.id, []).size() == 1 \
		and mixed_capture.get("status") == "pending" \
		and mixed_capture.get("reason") == "static_transform_artifact_source_incomplete"
	checks["mixed_group_rejection_retains_legacy_visuals"] = publisher.published_nodes.size() == 2 \
		and (publisher.published_nodes[0] as Node3D).visible \
		and (publisher.published_nodes[1] as Node3D).visible
	# A new boundary retries the full source; old diagnostic counters cannot poison it.
	publisher.static_visual_batches = {"accepted":valid_group, "corrected":valid_group.duplicate(false)}
	# Distinct geometry also yields distinct artifact IDs in the corrected roster.
	publisher.static_visual_batches.corrected["transforms"] = [Transform3D(Basis.IDENTITY, Vector3(2, 0, 0))]
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent, false)
	turns = 0
	while publisher.has_pending_static_flush() and turns < 1000:
		publisher.advance_static_flush(parent, 4000)
		turns += 1
	var retry := publisher.capture_committed_static_visual_source(part.id, revision)
	mixed_group_evidence["retry"] = {"turns":turns, "status":retry.get("status"), "reason":retry.get("reason"),
		"groupCount":retry.get("groupCount", 0), "boundary":publisher._last_publication_boundary,
		"diagnostics":publisher._static_section_transform_artifact_diagnostics.duplicate(true)}
	checks["corrected_source_retries_under_fresh_complete_boundary"] = turns < 1000 \
		and retry.get("status") == "ready" and retry.get("groupCount", 0) == 2 \
		and int(publisher._static_section_transform_artifact_diagnostics.get("rejectedGroups", 0)) > 0
	var door := Part.new({"id":"direct-door", "kind":"door", "material":"wood",
		"position":Vector3.ZERO, "size":Vector3.ONE, "collision":true})
	publisher._record_completed_source_part(door)
	var door_committed := publisher._commit_publication_boundary(publisher._pending_publication_boundary, {})
	var door_capture := publisher.capture_committed_static_visual_source(door.id,
		Preparation.static_record_binding(door.snapshot()))
	checks["direct_door_visual_is_explicit_pending_dependency_not_empty"] = door_committed \
		and door_capture.get("status") == "pending" \
		and door_capture.get("reason") == "direct_door_visual_section_attachment_pending" \
		and door.collision_enabled
	publisher.clear_published()
	parent.queue_free()


func _delayed_resumable_prepared_source_contract() -> Dictionary:
	var target_parent := Node3D.new()
	target_parent.position = Vector3(421.0, 0.0, -257.0)
	root.add_child(target_parent)
	var blueprint := Blueprint.new("pending-source-identity-contract", 41, "stone")
	var source_part := blueprint.add_part({"id":"delayed_masonry_wall", "kind":"wall",
		"material":"stone_foundation", "position":Vector3(8.0, 2.0, -5.0),
		"size":Vector3(3.6, 2.4, 0.42), "collision":true,
		"recipe":{"visual":true, "semantic":"castle_wall"}})
	blueprint.set_recipe({"routeCorridors":[], "pavingTreatments":[],
		"landscapeTrees":[], "urbanPoc":{"treePlacements":[]}})
	var current := NonPacketPublisher.new()
	current.unit_box = BoxMesh.new()
	var begun: bool = current.begin_publication(blueprint, target_parent,
		{"batchStaticParts":true, "resumableScenePublication":true,
			"publicationSiteId":"pending-source-identity-contract-site"})
	var history_result: Dictionary = Preparation._compile_history(blueprint)
	var masonry_result: Dictionary = Preparation._compile_masonry(blueprint,
		history_result.get("preparedHistory"), Callable(), true) if history_result.get("ready", false) else {"ready":false}
	var prepared_geometry_admitted: bool = begun and history_result.get("ready", false) \
		and history_result.get("preparedHistory") != null and masonry_result.get("ready", false) \
		and masonry_result.get("preparedMasonry") != null
	if prepared_geometry_admitted:
		current._prepared_history = history_result.preparedHistory
		current._prepared_masonry = masonry_result.preparedMasonry
		current._prepared_masonry_identity = current._prepared_masonry
		current.surface_history = current._prepared_history.history
	var missing_identity_job := MissingIdentityPendingJob.new()
	var missing_identity_result: Dictionary = current._advance_pending_publication_job(
		missing_identity_job, target_parent, 1)
	var sentinel_owner := Vector2i(-73, 81)
	var sentinel_chunk := Vector2i(44, -39)
	var sentinel_source_id := "ambient-source-sentinel"
	var sentinel_revision := "ambient-revision-sentinel"
	var sentinel_tier := "silhouette"
	var restored_after_every_slice := true
	var prepared_job_seen := false
	var pending_advance_count := 0
	var pending_context_restore_failure_count := 0
	var prepared_packet_advance_count := 0
	var matching_batch_evidence: Array[Dictionary] = []
	var cursor := 0
	var turns := 0
	while begun and cursor < blueprint.parts.size() and turns < 20000:
		current.static_visual_owner_cell = sentinel_owner
		current.static_visual_render_chunk_key = sentinel_chunk
		current.static_visual_source_part_id = sentinel_source_id
		current.static_visual_source_revision = sentinel_revision
		current.static_visual_part_tier = sentinel_tier
		var had_pending_job := current._pending_paving != null \
			or current._pending_masonry != null or current._pending_roof != null
		var job_before = current._pending_masonry if current._pending_masonry != null else (current._pending_paving if current._pending_paving != null else current._pending_roof)
		var packet_before_advance := job_before != null and job_before.get("_packet") != null
		var next_cursor: int = current.publish_part_batch(blueprint, target_parent,
			cursor, 1, 1)
		if had_pending_job:
			pending_advance_count += 1
			if packet_before_advance:
				prepared_packet_advance_count += 1
			if job_before != null and job_before.get("_packet") != null:
				prepared_job_seen = true
			var slice_context_restored := current.static_visual_owner_cell == sentinel_owner \
			and current.static_visual_render_chunk_key == sentinel_chunk \
			and current.static_visual_source_part_id == sentinel_source_id \
			and current.static_visual_source_revision == sentinel_revision \
			and current.static_visual_part_tier == sentinel_tier
			if not slice_context_restored: pending_context_restore_failure_count += 1
			restored_after_every_slice = restored_after_every_slice and slice_context_restored
		cursor = next_cursor
		turns += 1
		if current._publication_failed(): break
	var expected_anchor: Vector3 = target_parent.global_transform * source_part.position
	var expected_owner_cell: Vector2i = current._owner_cell_for_anchor(expected_anchor)
	var expected_render_chunk := StaticSectionGrid.chunk_key_for_world_position(expected_anchor)
	var expected_tier := current.static_render_tier_for_part(source_part)
	var expected_revision := Preparation.static_record_binding(source_part.snapshot())
	var matching_batches: Array[Dictionary] = []
	for key_value: Variant in current.static_visual_batches:
		var group_value: Variant = current.static_visual_batches[key_value]
		if group_value is Dictionary and String(group_value.get("sourcePartId", "")) == source_part.id:
			matching_batches.append(group_value)
	var every_batch_matches := not matching_batches.is_empty()
	for group: Dictionary in matching_batches:
		if matching_batch_evidence.size() < 8:
			matching_batch_evidence.append({"sourcePartId":group.get("sourcePartId", ""),
				"sourceRevision":group.get("sourceRevision", ""),
				"ownerCell":group.get("ownerCell", Vector2i.ZERO),
				"renderChunkKey":group.get("renderChunkKey", Vector2i.ZERO),
				"renderTier":group.get("renderTier", ""),
				"transformCount":group.get("transforms", []).size(),
				"preparedSegmentCount":group.get("preparedSegments", {}).size()})
		every_batch_matches = every_batch_matches \
			and String(group.get("sourceRevision", "")) == expected_revision \
			and group.get("ownerCell") == expected_owner_cell \
			and group.get("renderChunkKey") == expected_render_chunk \
			and String(group.get("renderTier", "")) == expected_tier \
			and not group.get("transforms", []).is_empty() \
			and not group.get("preparedSegments", {}).is_empty()
	var finished := {"status":"pending_budget"}
	var finish_turns := 0
	while begun and cursor >= blueprint.parts.size() and finished.get("status") == "pending_budget" \
			and finish_turns < 10000:
		finished = current.finish_scene_publication(blueprint, target_parent, 4000)
		finish_turns += 1
		if finished.get("status") == "failed": break
	var captured: Dictionary = current.capture_static_section_transform_artifacts(
		source_part.id, expected_revision)
	var artifact_groups: Array = captured.get("groups", [])
	var artifact_identity_matches := not artifact_groups.is_empty()
	for group_value: Variant in artifact_groups:
		artifact_identity_matches = artifact_identity_matches \
			and group_value.get("sourcePartId") == source_part.id \
			and String(group_value.get("sourceRevision", "")) == expected_revision
	var results := {"real_resumable_publish_part_batch_admitted":begun,
		"real_resumable_prepared_geometry_job_advanced_under_source_context":
			prepared_geometry_admitted and pending_advance_count > 0 \
			and prepared_packet_advance_count > 0 and prepared_job_seen,
		"real_resumable_pending_context_restored_after_every_slice":
			restored_after_every_slice,
		"real_resumable_static_batch_has_exact_source_identity":
			cursor == blueprint.parts.size() and every_batch_matches,
		"real_resumable_publication_commits_matching_artifact_identity":
			finished.get("status") == "ready" and captured.get("status") == "ready" \
			and artifact_identity_matches and current._last_publication_boundary.get(
				"sourcePartIds", []).has(source_part.id),
		"real_resumable_pending_job_collision_authority_preserved":
			source_part.collision_enabled and current.collision_count == 1,
		"pending_job_missing_identity_fails_closed":
			missing_identity_result.get("status") == "failed" \
			and missing_identity_result.get("reason") == "pending_source_identity_unavailable" \
			and not missing_identity_job.advanced}
	var evidence := {"beginStatus":"ready" if begun else "failed",
		"cursor":cursor,"turns":turns,"pendingAdvanceCount":pending_advance_count,
		"preparedJobSeen":prepared_job_seen,
		"preparedGeometryAdmitted":prepared_geometry_admitted,
		"preparedGeometryReason":masonry_result.get("reason", ""),
		"preparedPacketAdvanceCount":prepared_packet_advance_count,
		"pendingContextRestoreFailureCount":pending_context_restore_failure_count,
		"matchingBatchEvidence":matching_batch_evidence,
		"finishStatus":finished.get("status", ""),
		"finishTurns":finish_turns,"partId":source_part.id,
		"sourceRevision":expected_revision,"ownerCell":expected_owner_cell,
		"renderChunkKey":expected_render_chunk,"renderTier":expected_tier,
		"batchCount":matching_batches.size(),
		"artifactStatus":captured.get("status", ""),
		"artifactGroupCount":artifact_groups.size(),"checks":results}
	current.clear_published()
	target_parent.queue_free()
	return {"checks":results,"evidence":evidence}
