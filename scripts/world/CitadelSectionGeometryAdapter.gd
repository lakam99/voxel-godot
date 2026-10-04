extends RefCounted
class_name CitadelSectionGeometryAdapter

## Adapts already compiled Citadel static-batch segments to the shared section
## instance partitioner. This does not compile recipes, create visuals, or
## replace the live BuildingPartPublisher path. A section remains pending if
## even one census member has no matching, revision-bound packet geometry.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

const SCHEMA := "citadel-section-geometry-adapter/v1"
const PIPELINE_REVISION := "citadel-prepared-static-batch/v1"


## `member_bindings` is copied from the current immutable
## PreparedPhysicalGroupPacket entries, keyed by exact census source ID.
## `packet_groups` are the existing publisher's already prepared static groups;
## their `sourceRevision` must match the corresponding packet entry binding.
## The resource handles are returned separately from the value-only candidate.
static func capture_section(census: Dictionary, section_key: Vector3i,
		candidate_generation: int, packet_groups: Array,
		member_bindings: Dictionary, source_to_world: Transform3D,
		default_mesh: Mesh) -> Dictionary:
	if candidate_generation <= 0 or not _valid_transform(source_to_world):
		return _failed("invalid_citadel_candidate_identity")
	if census.get("status") != "complete" or not census.get("sections") is Dictionary \
			or not census.get("sourceRevisions") is Dictionary:
		return _pending("citadel_member_census_unavailable")
	var section_rows: Dictionary = census.sections
	var census_row: Variant = section_rows.get(section_key)
	if not census_row is Dictionary or census_row.get("status") not in ["complete", "empty"] \
			or not census_row.get("sourcePartIds") is Array:
		return _pending("citadel_section_census_pending", {"section":section_key})
	if census_row.get("status") == "empty":
		var empty_inputs: Array[Dictionary] = []
		empty_inputs.make_read_only()
		var empty_partition_result: Dictionary = Partitioner.partition(empty_inputs)
		if empty_partition_result.get("status") != "ready":
			return _failed("citadel_empty_section_partition_failed")
		var empty_compatibility: Dictionary = {}
		empty_compatibility.make_read_only()
		var empty := {"status":"ready", "schema":SCHEMA,
			"worldId":String(census.get("worldId", "")), "sectionKey":section_key,
			"candidateGeneration":candidate_generation,
			"coverageRevision":String(census_row.get("coverageRevision", "")),
			"authorityRevision":String(census.get("authorityRevision", "")),
			"partition":empty_partition_result.get("result", {}),
			"compatibilityByKey":empty_compatibility, "resourceBindings":{},
			"memberCount":0, "packetGroupCount":0}
		empty.make_read_only()
		return empty
	if String(census.get("worldId", "")).is_empty() \
			or String(census_row.get("coverageRevision", "")).is_empty():
		return _pending("citadel_census_revision_missing")
	if not member_bindings.is_read_only():
		return _pending("citadel_prepared_member_bindings_unsealed")
	if default_mesh == null and not packet_groups.is_empty():
		return _pending("citadel_prepared_static_geometry_missing")

	var groups_by_part: Dictionary = {}
	for group_value: Variant in packet_groups:
		if not group_value is Dictionary:
			return _failed("invalid_citadel_packet_group")
		var group: Dictionary = group_value
		var part_id := String(group.get("sourcePartId", ""))
		var site_id := String(group.get("siteId", ""))
		if site_id.is_empty() or String(group.get("packetSourceId", "")).is_empty() \
				or not group.get("packetGeneration") is int \
				or int(group.get("packetGeneration", 0)) <= 0 \
				or String(group.get("packetDigest", "")).length() != 64 \
				or group.get("packetOwnerCell") != group.get("ownerCell") \
				or part_id.is_empty() or not group.get("ownerCell") is Vector2i \
				or String(group.get("sourceRevision", "")).is_empty() \
				or String(group.get("materialKey", "")).is_empty() \
				or String(group.get("renderTier", "")).is_empty() \
				or not group.get("preparedSegments") is Dictionary \
				or group.preparedSegments.is_empty():
			return _pending("citadel_packet_group_incomplete", {"sourcePartId":part_id})
		var group_key := site_id + "\n" + part_id
		if not groups_by_part.has(group_key):
			groups_by_part[group_key] = []
		groups_by_part[group_key].append(group)

	var member_rows: Array[Dictionary] = []
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var resources_by_key: Dictionary = {}
	var source_revision_map: Dictionary = census.get("sourceRevisions", {})
	var census_ids: Array[String] = []
	for raw_id: Variant in census_row.sourcePartIds:
		if not raw_id is String or String(raw_id).is_empty():
			return _failed("invalid_citadel_census_member_id")
		census_ids.append(String(raw_id))
	census_ids.sort()
	for census_source_id: String in census_ids:
		var member_id := _member_id_from_census_source(census_source_id)
		if member_id.is_empty() or not member_id.begins_with("building:"):
			return _pending("citadel_member_kind_has_no_static_packet_geometry", {
				"sourceId":census_source_id, "memberId":member_id})
		var part_id := member_id.trim_prefix("building:")
		var site_id := _site_id_from_census_source(census_source_id)
		var source_revision := String(source_revision_map.get(census_source_id, ""))
		var member_binding := String(member_bindings.get(census_source_id, ""))
		if source_revision.is_empty() or member_binding.is_empty():
			return _pending("citadel_prepared_member_revision_missing", {
				"sourceId":census_source_id, "memberId":member_id})
		var matching_groups: Array = groups_by_part.get(site_id + "\n" + part_id, [])
		if matching_groups.is_empty():
			return _pending("citadel_member_packet_geometry_missing", {
				"sourceId":census_source_id, "sourcePartId":part_id})
		var normalized_groups: Array[Dictionary] = []
		for group_value: Variant in matching_groups:
			var group: Dictionary = group_value
			if String(group.sourceRevision) != member_binding:
				return _pending("citadel_packet_member_revision_mismatch", {
					"sourceId":census_source_id, "sourcePartId":part_id})
			var group_source_to_world: Transform3D = group.get("sourceToWorld", source_to_world)
			if not _valid_transform(group_source_to_world):
				return _pending("citadel_packet_source_transform_unavailable", {
					"sourceId":census_source_id, "sourcePartId":part_id})
			var prepared := _prepare_group(group, census_source_id, part_id,
				source_revision, member_binding, group_source_to_world, default_mesh)
			if prepared.get("status") != "ready":
				return prepared
			normalized_groups.append(prepared)
		normalized_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("groupKey", "")) < String(b.get("groupKey", "")))
		var revision_payload: Array = [SCHEMA, String(census.worldId),
			section_key, census_source_id, source_revision, member_binding,
			candidate_generation]
		for normalized: Dictionary in normalized_groups:
			revision_payload.append(String(normalized.contentDigest))
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK \
				or digest.update(var_to_bytes(revision_payload)) != OK:
			return _failed("citadel_member_revision_digest_failed")
		var candidate_source_revision := digest.finish().hex_encode()
		var manifest_groups: Array[String] = []
		for normalized: Dictionary in normalized_groups:
			var compatibility: Dictionary = normalized.compatibility
			var batch_key := String(compatibility.batchKey)
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != compatibility:
				return _failed("citadel_batch_compatibility_conflict")
			compatibility_by_key[batch_key] = compatibility
			var resource_binding := {"mesh":normalized.mesh,
				"material":normalized.material,
				"materialDigest":normalized.materialDigest}
			resource_binding.make_read_only()
			resources_by_key[batch_key] = resource_binding
			manifest_groups.append(batch_key)
			for segment: Dictionary in normalized.segments:
				var input: Dictionary = {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
					"sourceId":census_source_id, "sourcePartId":census_source_id,
					"packetMemberId":member_id, "packetPartId":part_id,
					"sourceRevision":candidate_source_revision,
					"ownerCell":normalized.ownerCell,
					"sourceToWorld":normalized.sourceToWorld,
					"meshLocalBounds":normalized.meshLocalBounds,
					"batchKey":batch_key, "segmentId":String(segment.segmentId),
					"buffer":segment.buffer, "instanceCount":int(segment.instanceCount)}
				input.make_read_only()
				inputs.append(input)
		manifest_groups.sort()
		var manifest := {"sourceId":census_source_id,
			"sourcePartId":census_source_id, "packetMemberId":member_id,
			"packetPartId":part_id, "sourceRevision":candidate_source_revision,
			"memberBinding":member_binding,
			"censusRevision":source_revision,
			"groupMembershipRevision":source_revision,
			"packetBatchKeys":manifest_groups,
			"packetSourceIds":_packet_source_ids(normalized_groups),
			"packetDigest":_member_packet_digest(normalized_groups),
			"geometryGroupCount":normalized_groups.size()}
		manifest.packetBatchKeys.make_read_only()
		manifest.packetSourceIds.make_read_only()
		manifest.make_read_only()
		member_rows.append(manifest)
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourceId) != String(b.sourceId):
			return String(a.sourceId) < String(b.sourceId)
		if String(a.batchKey) != String(b.batchKey):
			return String(a.batchKey) < String(b.batchKey)
		return String(a.segmentId) < String(b.segmentId))
	inputs.make_read_only()
	var census_part_ids: Dictionary = {}
	for census_source_id: String in census_ids:
		census_part_ids[_site_id_from_census_source(census_source_id) + "\n" \
			+ _member_id_from_census_source(census_source_id).trim_prefix("building:")] = true
	for group_key: Variant in groups_by_part:
		if not census_part_ids.has(String(group_key)):
			return _pending("citadel_packet_group_not_in_census", {"groupKey":String(group_key)})
	member_rows.make_read_only()
	compatibility_by_key.make_read_only()
	resources_by_key.make_read_only()
	var partition: Dictionary = Partitioner.partition(inputs)
	if partition.get("status") != "ready":
		return _failed("citadel_section_partition_failed:" + String(partition.get("reason", "unknown")))
	var partition_result: Dictionary = partition.get("result", {})
	if not partition_result.is_read_only():
		return _failed("citadel_partition_result_unsealed")
	var candidate := {"status":"ready", "schema":SCHEMA,
		"worldId":String(census.worldId), "sectionKey":section_key,
		"candidateGeneration":candidate_generation,
		"coverageRevision":String(census_row.coverageRevision),
		"authorityRevision":String(census.get("authorityRevision", "")),
		"members":member_rows, "partition":partition_result,
		"compatibilityByKey":compatibility_by_key,
		"resourceBindings":resources_by_key,
		"memberCount":member_rows.size(),
		"packetGroupCount":resources_by_key.size()}
	candidate.make_read_only()
	return candidate


static func _prepare_group(group: Dictionary, source_id: String, part_id: String,
		census_revision: String, member_binding: String,
		source_to_world: Transform3D, default_mesh: Mesh) -> Dictionary:
	var material: Variant = group.get("material")
	if not material is Material:
		return _pending("citadel_packet_material_unavailable", {"sourcePartId":part_id})
	var layer := _opaque_layer(material)
	if layer.is_empty():
		return _pending("citadel_packet_material_layer_not_supported", {
			"sourceId":source_id, "materialClass":material.get_class()})
	var mesh: Mesh = group.get("mesh", default_mesh) as Mesh
	if mesh == null:
		return _pending("citadel_packet_mesh_unavailable", {"sourcePartId":part_id})
	var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
	if mesh_fingerprint.get("status") != "ready":
		return _pending("citadel_packet_mesh_digest_unavailable", {
			"reason":String(mesh_fingerprint.get("reason", ""))})
	var material_fingerprint := _material_identity(material)
	if material_fingerprint.is_empty():
		return _pending("citadel_packet_material_digest_unavailable", {"sourcePartId":part_id})
	var material_key := String(group.get("materialKey", "")) + "|" + String(material_fingerprint.get("digest", ""))
	var mesh_digest := String(mesh_fingerprint.contentDigest)
	var mesh_key := "citadel-packet-mesh:" + mesh_digest
	var tier := String(group.get("renderTier", ""))
	var policy := _render_policy(tier)
	if policy.is_empty():
		return _pending("citadel_packet_render_tier_not_supported", {"renderTier":tier})
	var mesh_bounds := mesh.get_aabb()
	if not _valid_bounds(mesh_bounds):
		return _failed("citadel_packet_mesh_bounds_invalid")
	var pipeline_revision := PIPELINE_REVISION + "/" + layer
	var sort_policy := "none"
	var mesh_resource_key := mesh_key
	var mesh_pipeline_key := "%s|pipeline=%s|layer=%s|sort=%s" % [
		mesh_resource_key, pipeline_revision, layer, sort_policy]
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":tier,
		"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
		"meshKey":mesh_pipeline_key, "pipelineRevision":pipeline_revision,
		"renderLayer":layer, "translucentSortPolicy":sort_policy,
		"meshLocalBounds":mesh_bounds, "castShadows":bool(policy.castShadows),
		"visibilityRangeEnd":float(policy.visibilityRangeEnd),
		"fadeMargin":float(policy.fadeMargin)}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty():
		return _pending("citadel_packet_batch_compatibility_invalid", {"sourcePartId":part_id})
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	var segments: Array[Dictionary] = []
	var segment_keys: Array = group.preparedSegments.keys()
	segment_keys.sort()
	for segment_key: Variant in segment_keys:
		var source: Variant = group.preparedSegments[segment_key]
		if not source is Dictionary or not source.is_read_only() \
				or not source.get("buffer") is Array \
				or source.buffer.get_typed_builtin() != TYPE_FLOAT \
				or not source.buffer.is_read_only() \
				or not source.get("bounds") is AABB \
				or not source.get("instanceCount") is int:
			return _pending("citadel_packet_segment_value_unsealed", {"sourcePartId":part_id})
		var count := int(source.instanceCount)
		if count < 1 or source.buffer.size() != count * Attributes.FLOATS_PER_INSTANCE \
				or not _valid_bounds(source.bounds):
			return _failed("citadel_packet_segment_layout_invalid")
		for component: Variant in source.buffer:
			if not is_finite(float(component)):
				return _failed("citadel_packet_segment_nonfinite_attribute")
		var segment_copy: Array[float] = []
		segment_copy.assign(source.buffer)
		segment_copy.make_read_only()
		var actual_bounds := AABB()
		for instance_index in range(count):
			var instance_transform := Attributes.decode_transform(segment_copy,
				instance_index * Attributes.FLOATS_PER_INSTANCE)
			var instance_bounds := instance_transform * mesh_bounds
			actual_bounds = instance_bounds if instance_index == 0 \
				else actual_bounds.merge(instance_bounds)
		if not _bounds_approx(actual_bounds, source.bounds):
			return _pending("citadel_packet_segment_bounds_disagree_with_instances", {
				"sourcePartId":part_id, "segmentIndex":segment_key})
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK \
				or digest.update(var_to_bytes([source.bounds, count, segment_copy])) != OK:
			return _failed("citadel_packet_segment_digest_failed")
		var segment := {"segmentId":"citadel:%s:%s:%s" % [part_id,
			batch_key, String(source.get("segmentId", str(segment_key)))],
			"buffer":segment_copy, "bounds":source.bounds, "instanceCount":count,
			"contentDigest":digest.finish().hex_encode()}
		segment.make_read_only()
		segments.append(segment)
	segments.make_read_only()
	var group_digest := HashingContext.new()
	var group_payload: Array = [SCHEMA, source_id, part_id, census_revision,
		member_binding, String(group.sourceRevision), batch_key,
		String(group.get("packetSourceId", "")),
		int(group.get("packetGeneration", 0)), String(group.get("packetDigest", "")),
		String(mesh_fingerprint.contentDigest), material_fingerprint.digest,
		source_to_world]
	for segment: Dictionary in segments:
		group_payload.append([segment.segmentId, segment.contentDigest])
	if group_digest.start(HashingContext.HASH_SHA256) != OK \
			or group_digest.update(var_to_bytes(group_payload)) != OK:
		return _failed("citadel_packet_group_digest_failed")
	return {"status":"ready", "groupKey":batch_key,
		"contentDigest":group_digest.finish().hex_encode(),
		"compatibility":compatibility, "segments":segments,
		"ownerCell":Vector2i(group.ownerCell), "meshLocalBounds":mesh_bounds,
		"mesh":mesh, "material":material, "sourceToWorld":source_to_world,
		"packetSourceId":String(group.get("packetSourceId", "")),
		"materialDigest":material_fingerprint.digest}


static func _member_packet_digest(groups: Array[Dictionary]) -> String:
	var rows: Array = []
	for group: Dictionary in groups:
		rows.append([String(group.groupKey), String(group.contentDigest)])
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(rows)) != OK:
		return ""
	return context.finish().hex_encode()


static func _packet_source_ids(groups: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for group: Dictionary in groups:
		var source_id := String(group.get("packetSourceId", ""))
		if not source_id.is_empty() and source_id not in result:
			result.append(source_id)
	result.sort()
	return result


static func _member_id_from_census_source(source_id: String) -> String:
	var marker := ":member:"
	var start := source_id.find(marker)
	var end := source_id.find(":section:", start + marker.length())
	if start < 0 or end <= start + marker.length():
		return ""
	return source_id.substr(start + marker.length(), end - start - marker.length())


static func _site_id_from_census_source(source_id: String) -> String:
	if not source_id.begins_with("citadel:"):
		return ""
	var marker := source_id.find(":member:")
	return "" if marker <= "citadel:".length() else source_id.substr("citadel:".length(),
		marker - "citadel:".length())


static func _opaque_layer(material: Material) -> String:
	if material is StandardMaterial3D:
		var standard := material as StandardMaterial3D
		if standard.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
				and standard.albedo_color.a >= 0.999:
			return "opaque"
	return ""


static func _material_identity(material: Material) -> Dictionary:
	if not is_instance_valid(material):
		return {}
	var properties: Array = []
	for property: Dictionary in material.get_property_list():
		var name := String(property.get("name", ""))
		if name.is_empty() or name.begins_with("resource_") \
				or name in ["script", "resource_local_to_scene"]:
			continue
		var value: Variant = material.get(name)
		if value is Resource:
			# Resource paths identify references, not their current contents. This
			# adapter has no canonical texture/shader asset digest yet, so fail closed.
			return {}
		elif value is Object or value is Callable:
			return {}
		properties.append([name, value])
	properties.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([material.get_class(), properties])) != OK:
		return {}
	return {"digest":context.finish().hex_encode()}


static func _render_policy(tier: String) -> Dictionary:
	match tier:
		"silhouette": return {"visibilityRangeEnd":360.0, "fadeMargin":24.0, "castShadows":true}
		"detail": return {"visibilityRangeEnd":140.0, "fadeMargin":14.0, "castShadows":false}
		"structural": return {"visibilityRangeEnd":240.0, "fadeMargin":18.0, "castShadows":true}
	return {}


static func _valid_transform(value: Transform3D) -> bool:
	return value.origin.is_finite() and value.basis.x.is_finite() \
		and value.basis.y.is_finite() and value.basis.z.is_finite()


static func _valid_bounds(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() \
		and value.size.x > 0.0 and value.size.y > 0.0 \
		and value.size.z > 0.0 and value.end.is_finite()


static func _bounds_approx(a: AABB, b: AABB) -> bool:
	const EPSILON := 0.001
	return a.position.distance_to(b.position) <= EPSILON \
		and a.size.distance_to(b.size) <= EPSILON


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason, "retryable":false}
