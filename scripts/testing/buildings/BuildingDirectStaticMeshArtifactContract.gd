extends SceneTree

const Publisher := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Adapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var publisher = Publisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "direct-static-mesh-contract-blueprint"
	publisher.publication_site_id = "direct-static-mesh-contract-site"
	publisher._scene_parent = weakref(parent)
	publisher.batch_static_parts = true
	var parts: Array = [
		Part.new({"id":"ground-patch", "kind":"ground_patch", "material":"stone_foundation",
			"position":Vector3(130000.123,0.0,-170000.375),
			"size":Vector3(2.4,0.08,2.0), "collision":true}),
		Part.new({"id":"cloth-pennant", "kind":"pennant", "material":"linen",
			"position":Vector3(-2.0,2.0,1.0), "size":Vector3(1.2,1.6,0.12), "collision":false}),
		Part.new({"id":"cloth-sack", "kind":"sack", "material":"linen",
			"position":Vector3(0.0,0.6,-2.0), "size":Vector3(0.9,0.9,0.9), "collision":false})
	]
	for part: Variant in parts:
		publisher.publish_static_part(part, parent)
		publisher._record_completed_source_part(part)
	var direct_nodes: Dictionary = {}
	for value: Variant in publisher.published_nodes:
		if value is MeshInstance3D and String(value.name) in ["IrregularGroundPatch", "ClothPennant", "ClothSackBody", "ClothSackShoulder"]:
			direct_nodes[String(value.get_meta("building_source_part_id", "")) + ":" + String(value.name)] = value
	var nodes_before_flush := direct_nodes.size()
	publisher._begin_static_flush(parent, false)
	var turns := 0
	while publisher.has_pending_static_flush() and turns < 2000:
		publisher.advance_static_flush(parent, 1)
		turns += 1
	var expected_direct_by_part := {"ground-patch":"IrregularGroundPatch",
		"cloth-pennant":"ClothPennant", "cloth-sack":"ClothSackBody"}
	var ready_sources := 0
	var exact_resources := true
	var visible_legacy := true
	var section_only_groups := 0
	var no_packet_receipts: bool = publisher._chunk_static_packet_receipts.is_empty()
	var far_planar_adapter_ready := false
	var report_sources: Dictionary = {}
	for part: Variant in parts:
		var revision := Preparation.static_record_binding(part.snapshot())
		var capture: Dictionary = publisher.capture_committed_static_visual_source(part.id, revision)
		var source_groups: Array = capture.get("groups", [])
		for group_value: Variant in source_groups:
			if group_value is Dictionary:
				var group: Dictionary = group_value
				var resources: Dictionary = group_value.get("resourceBindings", {})
				var mesh: Mesh = resources.get("mesh") as Mesh
				var fingerprint := MeshFingerprint.inspect(mesh)
				exact_resources = exact_resources and mesh != null \
					and String(fingerprint.get("contentDigest", "")) == String(group_value.get("meshContentDigest", "")) \
					and resources.get("material") is Material \
					and String(group_value.get("sourceRevision", "")) == revision \
					and group_value.get("ownerCell") is Vector2i \
					and group_value.get("renderChunkKey") is Vector2i
				for segment_value: Variant in group_value.get("segments", []):
					var segment: Dictionary = segment_value
					var expected_bounds: AABB = mesh.get_aabb()
					var decoded := Attributes.decode_transform(segment.buffer, 0)
					if segment.get("instanceCount", 0) == 1:
						var actual_bounds: AABB = decoded * expected_bounds
						exact_resources = exact_resources and _bounds_close(segment.get("bounds"), actual_bounds)
				var layer_policy: Dictionary = publisher.static_visual_layer_policy(resources.get("material") as Material)
				exact_resources = exact_resources and group_value.get("renderLayer") == layer_policy.get("renderLayer") \
					and group_value.get("transparencySortPolicy") == layer_policy.get("transparencySortPolicy")
				if part.id == "ground-patch":
					var source_id := "citadel:direct-static-mesh-contract-site:member:building:ground-patch"
					var owner_section := Grid.key_for_world_position(group.worldBounds.get_center())
					var adapted: Dictionary = Adapter._prepare_transform_artifact_group(group,
						source_id, part.id, "census-direct-static-mesh", revision, owner_section)
					far_planar_adapter_ready = adapted.get("status") == "ready" \
						and adapted.get("meshLocalBounds") == group.get("meshSupportBounds")
				if not is_same(resources.get("mesh"), publisher.unit_box):
					section_only_groups += 1
		var visual_name := String(expected_direct_by_part.get(part.id, ""))
		var visual: MeshInstance3D = direct_nodes.get(part.id + ":" + visual_name) as MeshInstance3D
		visible_legacy = visible_legacy and is_instance_valid(visual) and visual.visible \
			and publisher.published_nodes.has(visual) \
			and String(visual.get_meta("building_source_revision", "")) == revision \
			and String(visual.get_meta("section_source_member_id", "")) == "building:" + part.id
		if capture.get("status") == "ready" and not source_groups.is_empty():
			ready_sources += 1
		report_sources[part.id] = {"status":String(capture.get("status", "")),
			"groupCount":source_groups.size(), "meshDigests":_mesh_digests(source_groups)}
	var ground_visual: MeshInstance3D = direct_nodes.get("ground-patch:IrregularGroundPatch") as MeshInstance3D
	var ground_support: AABB = ground_visual.mesh.custom_aabb if is_instance_valid(ground_visual) else AABB()
	var collision_preserved: bool = is_instance_valid(publisher.static_collision_body) \
		and publisher.static_collision_body.get_parent() == parent \
		and publisher.static_collision_body.get_child_count() >= 1 \
		and publisher.static_part_records.has("ground-patch")
	checks = {
		"bounded_flush_completed": turns < 2000 and not publisher.has_pending_static_flush(),
		"all_direct_mesh_sources_have_committed_artifacts": ready_sources == parts.size(),
		"exact_mesh_material_transform_revision_and_render_policy": exact_resources,
		"legacy_direct_meshes_remain_visible_and_ack_addressable": visible_legacy and nodes_before_flush >= 4,
		"artifact_only_groups_do_not_create_packet_receipts": no_packet_receipts,
		"planar_ground_mesh_has_finite_render_support": is_instance_valid(ground_visual) \
			and ground_support.size.y >= 0.002 \
			and ground_support.encloses(ground_visual.mesh.get_aabb()),
		"far_planar_mesh_adapts_from_encoded_segment_bounds": far_planar_adapter_ready,
		"collision_metadata_survives_visual_staging": collision_preserved,
		"goods_non_box_meshes_are_included": report_sources.get("cloth-sack", {}).get("groupCount", 0) >= 2,
		"artifact_only_flush_group_count": section_only_groups >= 4
	}
	var report := {"evidence":"synthetic_direct_static_mesh_artifact_contract",
		"passed":checks.values().all(func(value: Variant) -> bool: return value == true),
		"checks":checks,"sources":report_sources,
		"turns":turns,"directLegacyNodeCountBeforeFlush":nodes_before_flush,
		"doesNotProve":"No native section installation or ACK, GPU rendering, collision movement, or headed gameplay. It proves producer capture, immutable mesh artifact admission, section support bounds, and legacy-node retention before ACK."}
	var report_path := OS.get_environment("BUILDING_DIRECT_STATIC_MESH_ARTIFACT_REPORT")
	if report_path.is_empty():
		push_error("BUILDING_DIRECT_STATIC_MESH_ARTIFACT_REPORT is required")
	else:
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	if not report.passed:
		push_error("Direct static mesh artifact contract failed: %s" % JSON.stringify(checks))
	quit(0 if report.passed else 1)


func _mesh_digests(groups: Array) -> Array[String]:
	var result: Array[String] = []
	for group_value: Variant in groups:
		if group_value is Dictionary:
			result.append(String(group_value.get("meshContentDigest", "")))
	result.sort()
	return result


func _bounds_close(left_value: Variant, right: AABB) -> bool:
	if not left_value is AABB:
		return false
	var left: AABB = left_value
	return left.position.distance_to(right.position) <= 0.002 \
		and left.end.distance_to(right.end) <= 0.002
