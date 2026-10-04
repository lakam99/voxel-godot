extends RefCounted
class_name OrdinaryStructureSectionGeometryAdapter

## Copies one already-published ordinary structure block into the value input
## shape used by ChunkStaticRenderSectionInstancePartitioner. It never creates
## a visual and never changes the source body's collision or gameplay state.
## This is deliberately a partial producer adapter: a caller must keep a
## section pending while any ordinary member is outside the allowlist.

const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

const ALLOWED_BLOCK_TYPES: Array[String] = ["cobblestonePath", "stoneBlock", "woodBlock"]
const SCHEMA := "ordinary-static-geometry-source/v1"
## The section discovery query includes owner cells one cell past each edge.
## Keep the allowlist inside that bound so a source outside the query cannot
## have geometry intersect the requested section.
const MAX_HORIZONTAL_SUPPORT_CELLS := 1.0


static func capture_block(structure_system: Object, main: Object,
		source_id: String, cell: Vector3i) -> Dictionary:
	if not is_instance_valid(structure_system) or not is_instance_valid(main) \
			or source_id.strip_edges().is_empty():
		return _failed("ordinary_geometry_source_owner_missing")
	if not structure_system.get("main") == main:
		return _pending("ordinary_geometry_world_owner_changed")
	var sources_value: Variant = structure_system.get("ordinary_visual_sources")
	var blocks_value: Variant = main.get("blocks")
	var removed_value: Variant = structure_system.get("removed_generated_structure_blocks")
	if not sources_value is Dictionary or not blocks_value is Dictionary \
			or not removed_value is Dictionary:
		return _pending("ordinary_geometry_authority_unavailable")
	var source: Dictionary = sources_value.get(source_id, {})
	if source.is_empty() or not bool(source.get("completed", false)):
		return _pending("ordinary_geometry_source_incomplete")
	var expected_value: Variant = source.get("expected", {})
	if not expected_value is Dictionary or not expected_value.has(cell):
		return _failed("ordinary_geometry_cell_not_in_source_manifest")
	var block_type := String(expected_value[cell])
	var durable_id := String(structure_system.call("_ordinary_visual_block_key", source_id, cell, block_type))
	if removed_value.has(durable_id):
		return {"status":"empty", "reason":"ordinary_geometry_durably_removed",
			"sourcePartId":_source_part_id(source_id, cell)}
	if block_type not in ALLOWED_BLOCK_TYPES:
		return _pending("ordinary_geometry_block_type_not_migrated", {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	var body := blocks_value.get(cell) as Node3D
	if not _valid_body(body, source_id, cell, block_type):
		return _pending("ordinary_geometry_live_source_body_unavailable", {
			"sourceId":source_id, "cell":cell})
	if _has_special_visual_metadata(body):
		return _pending("ordinary_geometry_visual_options_not_migrated", {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	var meshes: Array[MeshInstance3D] = []
	var unsupported_visual := false
	unsupported_visual = _collect_geometry(body, meshes, unsupported_visual)
	if unsupported_visual or meshes.size() != 1:
		return _pending("ordinary_geometry_requires_single_static_mesh", {
			"sourceId":source_id, "cell":cell, "meshCount":meshes.size()})
	var mesh_instance := meshes[0]
	if not mesh_instance.visible or not mesh_instance.is_visible_in_tree() \
			or mesh_instance.mesh == null or mesh_instance.material_override == null:
		return _pending("ordinary_geometry_mesh_or_material_unavailable", {
			"sourceId":source_id, "cell":cell})
	if mesh_instance.mesh.get_surface_count() != 1:
		return _pending("ordinary_geometry_multisurface_material_not_migrated", {
			"sourceId":source_id, "cell":cell,
			"surfaceCount":mesh_instance.mesh.get_surface_count()})
	if not mesh_instance.material_override is StandardMaterial3D:
		return _pending("ordinary_geometry_material_type_not_migrated", {
			"sourceId":source_id, "cell":cell,
			"materialClass":mesh_instance.material_override.get_class()})
	var standard_material := mesh_instance.material_override as StandardMaterial3D
	if standard_material.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED \
			or standard_material.albedo_color.a < 0.999:
		return _pending("ordinary_geometry_nonopaque_material_not_migrated", {
			"sourceId":source_id, "cell":cell})
	var mesh_identity := MeshFingerprint.inspect(mesh_instance.mesh)
	if mesh_identity.get("status") != "ready":
		return _pending("ordinary_geometry_mesh_fingerprint_unavailable", {
			"sourceId":source_id, "cell":cell,
			"reason":String(mesh_identity.get("reason", ""))})
	var material_identity := _material_identity(mesh_instance.material_override)
	if material_identity.is_empty():
		return _pending("ordinary_geometry_material_fingerprint_unavailable", {
			"sourceId":source_id, "cell":cell})
	var mesh_bounds := mesh_instance.mesh.get_aabb()
	if not _valid_bounds(mesh_bounds):
		return _pending("ordinary_geometry_mesh_bounds_invalid", {
			"sourceId":source_id, "cell":cell})
	var cell_size := float(main.get("CELL"))
	var world_bounds: AABB = mesh_instance.global_transform * mesh_bounds
	var cell_origin := Vector3(cell) * cell_size
	var support := Vector3.ONE * (cell_size * MAX_HORIZONTAL_SUPPORT_CELLS)
	if not is_finite(cell_size) or cell_size <= 0.0 \
			or world_bounds.position.x < cell_origin.x - support.x \
			or world_bounds.end.x > cell_origin.x + support.x \
			or world_bounds.position.z < cell_origin.z - support.z \
			or world_bounds.end.z > cell_origin.z + support.z:
		return _pending("ordinary_geometry_horizontal_support_exceeds_section_query", {
			"sourceId":source_id, "cell":cell, "worldBounds":world_bounds,
			"cellOrigin":cell_origin, "maxHorizontalSupport":support.x})
	var part_id := _source_part_id(source_id, cell)
	var source_revision := _revision(source, source_id, cell, block_type,
		body.global_transform, mesh_instance.transform,
		String(mesh_identity.contentDigest), material_identity.digest)
	if source_revision.is_empty():
		return _failed("ordinary_geometry_revision_hash_failed")
	var mesh_key: String = "ordinary-mesh:" + String(mesh_identity.contentDigest)
	var material_key: String = "ordinary-material:" + String(material_identity.digest)
	var pipeline_revision := "ordinary-static-mesh/v1"
	var mesh_pipeline_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh_key, pipeline_revision]
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":"structural",
		"meshResourceKey":mesh_key, "meshContentDigest":String(mesh_identity.contentDigest),
		"meshKey":mesh_pipeline_key, "pipelineRevision":pipeline_revision,
		"renderLayer":"opaque", "translucentSortPolicy":"none",
		"meshLocalBounds":mesh_bounds, "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty():
		return _pending("ordinary_geometry_batch_compatibility_invalid", {
			"sourceId":source_id, "cell":cell})
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	var segment_id := part_id + ":mesh"
	var buffer: Array[float] = []
	for value: float in Attributes.encode(mesh_instance.transform, Color.WHITE, Color.WHITE):
		buffer.append(value)
	buffer.make_read_only()
	var instance_input: Dictionary = {
		"schema":SCHEMA,
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":part_id,
		"sourcePartId":part_id,
		"authoritySourceId":source_id,
		"sourceRevision":source_revision,
		"segmentId":segment_id,
		"ownerCell":Grid.logical_owner_cell_for_world_position(body.global_position),
		"sourceToWorld":body.global_transform,
		"batchKey":batch_key,
		"meshKey":mesh_key,
		"meshContentDigest":String(mesh_identity.contentDigest),
		"materialKey":material_key,
		"meshLocalBounds":mesh_bounds,
		"renderLayer":"opaque",
		"translucentSortPolicy":"none",
		"renderTier":"structural",
		"pipelineRevision":pipeline_revision,
		"compatibilityKey":batch_key,
		"castShadows":true,
		"visibilityRangeEnd":100000.0,
		"fadeMargin":0.0,
		"buffer":buffer,
		"instanceCount":1
	}
	instance_input.make_read_only()
	var manifest_row: Dictionary = {"sourcePartId":part_id,
		"sourceRevision":source_revision, "sourceId":source_id,
		"cell":cell, "blockType":block_type,
		"meshDigest":String(mesh_identity.contentDigest),
		"materialDigest":material_identity.digest}
	manifest_row.make_read_only()
	return {"status":"ready", "sourceInput":instance_input,
		"manifest":manifest_row, "compatibility":compatibility,
		"mesh":mesh_instance.mesh,
		"material":mesh_instance.material_override,
		"body":weakref(body), "geometry":weakref(mesh_instance),
		"sourcePartId":part_id, "sourceRevision":source_revision,
		"meshDigest":String(mesh_identity.contentDigest),
		"materialDigest":material_identity.digest}


## Complete only for the requested generated structure source. This does not
## establish complete ordinary-domain or section coverage; the caller must
## merge every source intersecting a section and keep excluded gameplay types
## pending.
static func capture_source(structure_system: Object, main: Object,
		source_id: String) -> Dictionary:
	if not is_instance_valid(structure_system) or not is_instance_valid(main) \
			or structure_system.get("main") != main:
		return _pending("ordinary_geometry_world_owner_changed")
	var sources_value: Variant = structure_system.get("ordinary_visual_sources")
	if not sources_value is Dictionary:
		return _pending("ordinary_geometry_authority_unavailable")
	var source: Dictionary = sources_value.get(source_id, {})
	if source.is_empty() or not bool(source.get("completed", false)):
		return _pending("ordinary_geometry_source_incomplete")
	var expected_value: Variant = source.get("expected", {})
	var omitted_value: Variant = source.get("omitted", {})
	var failed_value: Variant = source.get("failed", {})
	var removed_value: Variant = structure_system.get("removed_generated_structure_blocks")
	if not expected_value is Dictionary or not omitted_value is Dictionary \
			or not failed_value is Dictionary or not removed_value is Dictionary:
		return _pending("ordinary_geometry_source_manifest_invalid")
	if not failed_value.is_empty():
		return _pending("ordinary_geometry_source_has_failed_outputs", {
			"sourceId":source_id, "failedCount":failed_value.size()})
	if expected_value.is_empty() and omitted_value.is_empty():
		return _pending("ordinary_geometry_source_has_no_emitted_members", {
			"sourceId":source_id})
	for omitted_key_value: Variant in omitted_value:
		var omitted_key := String(omitted_key_value)
		if not removed_value.has(omitted_key):
			return _pending("ordinary_geometry_unexplained_omission", {
				"sourceId":source_id, "omittedKey":omitted_key})
	var cells: Array[Vector3i] = []
	for cell_value: Variant in expected_value:
		if not cell_value is Vector3i:
			return _failed("ordinary_geometry_source_cell_invalid")
		cells.append(cell_value)
	cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.z != b.z: return a.z < b.z
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	var members: Array[Dictionary] = []
	var member_rows: Array = []
	for cell: Vector3i in cells:
		var captured := capture_block(structure_system, main, source_id, cell)
		if captured.get("status") == "empty":
			member_rows.append([_source_part_id(source_id, cell), "removed"])
			continue
		if captured.get("status") != "ready":
			captured["cell"] = cell
			return captured
		members.append(captured)
		member_rows.append([String(captured.sourcePartId), String(captured.sourceRevision)])
	var source_digest := HashingContext.new()
	if source_digest.start(HashingContext.HASH_SHA256) != OK \
			or source_digest.update(var_to_bytes([SCHEMA, source_id,
				int(source.get("revision", -1)), member_rows])) != OK:
		return _failed("ordinary_geometry_source_revision_hash_failed")
	return {"status":"complete", "coverageScope":"one_structure_source",
		"sourceId":source_id, "sourceRevision":source_digest.finish().hex_encode(),
		"members":members, "memberCount":members.size(),
		"expectedCellCount":cells.size(), "removedMemberCount":cells.size() - members.size()}


static func _source_part_id(source_id: String, cell: Vector3i) -> String:
	return "ordinary:%s:cell:%d,%d,%d" % [source_id, cell.x, cell.y, cell.z]


static func _valid_body(body: Node3D, source_id: String, cell: Vector3i,
		block_type: String) -> bool:
	return is_instance_valid(body) and body.is_inside_tree() \
		and not body.is_queued_for_deletion() \
		and bool(body.get_meta("generated", false)) \
		and not bool(body.get_meta("player_placed", false)) \
		and body.get_meta("cell", null) is Vector3i \
		and body.get_meta("cell") == cell \
		and String(body.get_meta("generated_visual_source_id", "")) == source_id \
		and String(body.get_meta("block_type", "")) == block_type


static func _has_special_visual_metadata(body: Node3D) -> bool:
	for key in ["roofRole", "roofAxis", "roofSide", "roofMaterial", "roofTrimMaterial",
			"roofEdgeX", "roofEdgeZ", "roofAccent", "accentRole", "windowAxis",
			"windowSide", "cornerX", "cornerZ", "fenceAxis"]:
		if body.has_meta(key): return true
	return false


static func _collect_geometry(node: Node, meshes: Array[MeshInstance3D],
		unsupported_visual: bool) -> bool:
	for child_value: Variant in node.get_children():
		if not child_value is Node: continue
		var child := child_value as Node
		if child is MeshInstance3D:
			meshes.append(child as MeshInstance3D)
		elif child is GeometryInstance3D or child is Light3D or child is Area3D:
			unsupported_visual = true
		unsupported_visual = _collect_geometry(child, meshes, unsupported_visual)
	return unsupported_visual


static func _revision(source: Dictionary, source_id: String, cell: Vector3i,
		block_type: String, body_transform: Transform3D, mesh_transform: Transform3D,
		mesh_digest: String, material_digest: String) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var payload := [SCHEMA, source_id, int(source.get("revision", -1)), cell, block_type,
		body_transform, mesh_transform, mesh_digest, material_digest]
	if context.update(var_to_bytes(payload)) != OK:
		return ""
	return context.finish().hex_encode()


static func _material_identity(material: Material) -> Dictionary:
	if not is_instance_valid(material): return {}
	var properties: Array = []
	for property: Dictionary in material.get_property_list():
		var name := String(property.get("name", ""))
		if name.is_empty() or name.begins_with("resource_") or name in ["script", "resource_local_to_scene"]:
			continue
		var value: Variant = material.get(name)
		if value is Resource:
			var resource := value as Resource
			value = [resource.get_class(), resource.resource_path]
		elif value is Object or value is Callable:
			return {}
		properties.append([name, value])
	properties.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]) < String(b[0]))
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([material.get_class(), properties])) != OK:
		return {}
	return {"digest":context.finish().hex_encode()}


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 \
		and bounds.size.z > 0.0 and bounds.end.is_finite()


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason, "retryable":false}
