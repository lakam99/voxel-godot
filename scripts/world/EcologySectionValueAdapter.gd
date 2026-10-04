extends RefCounted
class_name EcologySectionValueAdapter

## Converts canonical surface-detail instance values into immutable inputs for
## the shared static-section partitioner. This is intentionally not a complete
## ecology provider: current producer snapshots omit compiled tree geometry,
## natural harvestable props, and underground static props, so the full ecology
## census must remain pending.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")

const REQUIRED_ECOLOGY_CATEGORIES := [
	"trees_foliage_geometry",
	"surface_detail_instances",
	"surface_rocks",
	"ore",
	"forage",
	"underground_props"
]

const SCHEMA := "ecology-section-value-adapter/v1"
const PIPELINE_REVISION := "ecology_static_detail_pipeline/v1"

var _world_id := ""
var _main_authority_ref: WeakRef


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_ecology_provider_world")
	if not _world_id.is_empty() and _world_id != world_id:
		return _failed("ecology_provider_already_bound")
	_world_id = world_id
	return {"status":"ready", "worldId":_world_id}


## Bind the game authority that owns the seeded chunk producer. Membership
## still comes from its finalized value snapshot, not a scene-tree scan.
func bind_main_authority(main: Object) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("detail_mesh") \
			or not main.has_method("detail_material") \
			or not main.has_method("_ecology_chunk_source_revision"):
		return _failed("ecology_main_authority_contract_missing")
	var previous: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if is_instance_valid(previous) and previous.get_instance_id() != main.get_instance_id():
		return _failed("ecology_main_authority_owner_replaced")
	_main_authority_ref = weakref(main)
	return {"status":"ready", "ownerInstanceId":main.get_instance_id()}


## Implements StaticSectionSourceRoster.capture_method exactly. Missing chunk
## owners, incomplete producer categories, or absent prepared geometry are
## pending; this provider never infers empty from an absent ledger entry.
func capture_static_section_sources(world_id: String,
		requested_sections: Array) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty() or requested_sections.is_empty():
		return _pending("ecology_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ecology_section")
		sections.append(value)
	var required_chunks: Dictionary = {}
	for section: Vector3i in sections:
		for chunk: Vector2i in Grid.stream_chunk_keys_intersecting_section(section):
			required_chunks[chunk] = true
	var chunk_keys: Array[Vector2i] = []
	for chunk_value: Variant in required_chunks:
		chunk_keys.append(Vector2i(chunk_value))
	chunk_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	var surface_detail_partitions: Array[Dictionary] = []
	for chunk: Vector2i in chunk_keys:
		var production := _capture_production_chunk(chunk)
		if production.get("status") != "ready":
			return production
		var snapshot: Dictionary = production.snapshot
		var prepared: Dictionary = prepare_surface_detail(snapshot,
			production.bindings, production.chunkToWorld, world_id,
			production.unsupportedDetailTypes)
		if prepared.get("status") not in ["prepared", "prepared_partial"]:
			return prepared
		surface_detail_partitions.append(prepared)
		var missing := _missing_categories(snapshot)
		if not missing.is_empty():
			return _pending("ecology_static_category_coverage_incomplete", {
				"chunk":chunk, "missingCategories":missing,
				"surfaceDetailPrepared":prepared,
				"surfaceDetailPartitions":surface_detail_partitions})
	return _pending("ecology_complete_census_not_yet_authoritative", {
		"chunks":chunk_keys, "requestedSections":sections,
		"surfaceDetailPartitions":surface_detail_partitions})


## Build section-local instance inputs from the surface-detail records already
## emitted by the deterministic chunk detail producer. `binding_by_source`
## maps the record's meshSource + material identity to the actual production
## Mesh, stable mesh key, pipeline revision, and material key. No visual Node is
## scanned and no RNG is consumed.
static func prepare_surface_detail(snapshot: Dictionary, binding_by_source: Dictionary,
		chunk_to_world := Transform3D.IDENTITY, world_id := "",
		unsupported_detail_types: Array[String] = []) -> Dictionary:
	var validation := _validate_snapshot(snapshot)
	if validation.get("status") != "ready":
		return validation
	snapshot = _freeze_value(snapshot)
	if not binding_by_source.is_read_only():
		return _failed("mutable_detail_binding_map")
	if world_id.strip_edges().is_empty():
		return _failed("surface_detail_world_identity_missing")
	var chunk_value: Variant = snapshot.get("chunk")
	if not chunk_value is Vector2i:
		return _failed("invalid_ecology_chunk_key")
	var chunk: Vector2i = chunk_value
	var source_revision := String(snapshot.get("sourceRevision", ""))
	if not _valid_transform(chunk_to_world):
		return _failed("invalid_surface_detail_chunk_transform")
	var source_to_world: Transform3D = chunk_to_world
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var material_resources_by_key: Dictionary = {}
	var mesh_resources_by_key: Dictionary = {}
	var source_revisions: Dictionary = {}
	var candidate_ids: Array[String] = []
	var unsupported_candidate_ids: Array[String] = []
	var candidates: Array = snapshot.get("candidates", [])
	for candidate_value: Variant in candidates:
		if not candidate_value is Dictionary:
			return _failed("invalid_ecology_candidate")
		var candidate: Dictionary = candidate_value
		if String(candidate.get("kind", "")) != "surface_detail":
			continue
		var source_id := String(candidate.get("sourceId", ""))
		var detail_type := String(candidate.get("detailType", ""))
		var mesh_source := String(candidate.get("meshSource", ""))
		var candidate_revision := String(candidate.get("contentRevision", ""))
		var transform_value: Variant = candidate.get("transform")
		var bounds_value: Variant = candidate.get("localBounds")
		var layer_values: Variant = candidate.get("renderLayers")
		var material_values: Variant = candidate.get("materials")
		if source_id.is_empty() or detail_type.is_empty() or mesh_source.is_empty() \
				or candidate_revision.is_empty() or not transform_value is Transform3D \
				or not bounds_value is AABB or not layer_values is Array \
				or layer_values.size() != 1 or not material_values is Array \
				or material_values.size() != 1:
			return _failed("incomplete_surface_detail_source_value")
		var stable_id_prefix := "%s:detail:%d,%d:%s:" % [
			String(snapshot.get("worldSeed", "")), chunk.x, chunk.y, detail_type]
		if not source_id.begins_with(stable_id_prefix) \
				or _candidate_digest(candidate) != candidate_revision:
			return _failed("surface_detail_identity_or_revision_mismatch")
		if candidate_ids.has(source_id):
			return _failed("duplicate_surface_detail_source_id")
		candidate_ids.append(source_id)
		if detail_type in unsupported_detail_types:
			unsupported_candidate_ids.append(source_id)
			continue
		var bound_candidate_revision := _value_digest([
			"ecology-section-member/v1", world_id, source_revision,
			int(snapshot.get("removedPropsRevision", -1)), candidate_revision])
		if bound_candidate_revision.is_empty():
			return _failed("surface_detail_bound_revision_failed")
		var binding_key := _binding_key(mesh_source, String(material_values[0]))
		var binding_value: Variant = binding_by_source.get(binding_key)
		if not binding_value is Dictionary or not binding_value.is_read_only():
			return _pending("surface_detail_mesh_material_binding_missing", {"sourceId":source_id,
				"bindingKey":binding_key})
		var binding: Dictionary = binding_value
		var mesh_value: Variant = binding.get("mesh")
		var material_value: Variant = binding.get("material")
		var mesh_key := String(binding.get("meshResourceKey", ""))
		var material_key := String(binding.get("materialKey", ""))
		var material_digest := String(binding.get("materialContentDigest", ""))
		var pipeline_revision := String(binding.get("pipelineRevision", PIPELINE_REVISION))
		if not mesh_value is Mesh or not material_value is Material \
				or mesh_key.is_empty() or material_key.is_empty() \
				or material_digest.length() != 64 or not material_digest.is_valid_hex_number(false) \
				or pipeline_revision.is_empty() \
				or material_key != String(material_values[0]) \
				or mesh_source != String(binding.get("meshSource", mesh_source)):
			return _failed("surface_detail_binding_identity_mismatch")
		if _material_digest(material_value) != material_digest:
			return _pending("surface_detail_material_resource_changed", {"sourceId":source_id})
		var render_layer := _render_layer(String(layer_values[0]))
		if render_layer.is_empty():
			return _pending("surface_detail_render_layer_not_supported", {"sourceId":source_id,
				"renderLayer":String(layer_values[0])})
		var mesh_bounds: AABB = mesh_value.get_aabb()
		if not _valid_bounds(mesh_bounds) or not _valid_transform(transform_value):
			return _failed("invalid_surface_detail_geometry")
		var captured_bounds: AABB = bounds_value
		if not (mesh_bounds * transform_value).is_equal_approx(captured_bounds):
			return _failed("surface_detail_bounds_disagree_with_mesh")
		var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh_value)
		if mesh_fingerprint.get("status") != "ready":
			return _pending("surface_detail_mesh_fingerprint_unavailable", {"sourceId":source_id,
				"reason":String(mesh_fingerprint.get("reason", "unknown"))})
		var digest := String(mesh_fingerprint.get("contentDigest", ""))
		var visibility_end := float(candidate.get("visibilityRangeEnd", 0.0))
		var fade_margin := float(binding.get("fadeMargin", 12.0))
		var cast_shadows := String(candidate.get("shadowCasting", "off")) != "off"
		var compatibility := _compatibility(String(material_values[0]), material_key,
			material_digest,
			mesh_key, digest, pipeline_revision, render_layer, mesh_bounds,
			cast_shadows, visibility_end, fade_margin)
		if compatibility.is_empty():
			return _failed("surface_detail_compatibility_invalid")
		var batch_key := String(compatibility.batchKey)
		if compatibility_by_key.has(batch_key) and compatibility_by_key[batch_key] != compatibility:
			return _failed("surface_detail_batch_compatibility_conflict")
		compatibility_by_key[batch_key] = compatibility
		material_resources_by_key[String(compatibility.materialKey)] = binding.get("material")
		mesh_resources_by_key[mesh_key] = mesh_value
		var transform: Transform3D = transform_value
		var color_value: Variant = candidate.get("instanceColor")
		var custom_value: Variant = candidate.get("customData")
		if not color_value is Color or not custom_value is Color:
			return _failed("surface_detail_instance_variation_missing")
		var instance_buffer := _encode_instance(transform, custom_value, color_value)
		instance_buffer.make_read_only()
		var instance_input := {
			"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"sourceId":source_id,
			"sourcePartId":source_id,
			"sourceRevision":bound_candidate_revision,
			"ownerCell":chunk,
			"sourceToWorld":source_to_world,
			"meshLocalBounds":mesh_bounds,
			"batchKey":batch_key,
			"segmentId":"ecology-detail:" + (source_id + "\n" + bound_candidate_revision).sha256_text(),
			"buffer":instance_buffer,
			"instanceCount":1
		}
		instance_input.make_read_only()
		inputs.append(instance_input)
		source_revisions[source_id] = bound_candidate_revision
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.sourceId) < String(b.sourceId))
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	material_resources_by_key.make_read_only()
	mesh_resources_by_key.make_read_only()
	source_revisions.make_read_only()
	var partition_result: Dictionary = {}
	if inputs.is_empty():
		partition_result = {"status":"ready", "outputs":[], "sourceRevisions":{},
			"impactedSectionKeys":[], "inputInstanceCount":0, "outputInstanceCount":0}
	else:
		var partition_envelope: Dictionary = Partitioner.partition(inputs)
		if partition_envelope.get("status") != "ready":
			return _failed("surface_detail_partition_failed:" + String(partition_envelope.get("reason", "unknown")))
		partition_result = partition_envelope.get("result", {})
		if not partition_result is Dictionary or not partition_result.is_read_only():
			return _failed("surface_detail_partition_result_invalid")
	var sections := _section_membership(partition_result.get("outputs", []))
	return {
		"status":"prepared" if unsupported_candidate_ids.is_empty() else "prepared_partial",
		"schema":SCHEMA,
		"producerRevision":source_revision,
		"chunk":chunk,
		"candidateIds":candidate_ids,
		"unsupportedCandidateIds":unsupported_candidate_ids,
		"inputs":inputs,
		"partition":partition_result,
		"compatibilityByKey":compatibility_by_key,
		"materialBindings":material_resources_by_key,
		"meshBindings":mesh_resources_by_key,
		"sourceRevisions":source_revisions,
		"sections":sections,
		"censusStatus":"pending",
		"censusReason":"ecology_static_category_coverage_incomplete",
		"missingCategories":_missing_categories(snapshot)
	}


## The complete domain provider must account for all deterministic static
## ecology sources, including explicit empties. Current producer snapshots are
## partial, so this response fails closed even when surface detail is compiled.
static func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	if String(snapshot.get("schema", "")) != "ecology-source-values/v1" \
			or String(snapshot.get("worldSeed", "")).is_empty() \
			or not snapshot.get("chunk") is Vector2i \
			or String(snapshot.get("sourceRevision", "")).is_empty() \
			or String(snapshot.get("contentRevision", "")).is_empty() \
			or not snapshot.get("candidates") is Array:
		return _failed("invalid_or_mutable_ecology_source_snapshot")
	for candidate_value: Variant in snapshot.candidates:
		if not candidate_value is Dictionary:
			return _failed("mutable_or_invalid_ecology_candidate")
		if String(candidate_value.get("contentRevision", "")) != _candidate_digest(candidate_value):
			return _failed("ecology_candidate_revision_mismatch")
	var snapshot_copy := snapshot.duplicate(true)
	var expected_snapshot_revision := String(snapshot_copy.get("contentRevision", ""))
	snapshot_copy.erase("contentRevision")
	# MainPlaytestTools adds this lifecycle field after the producer ledger has
	# sealed its digest. Freshness is checked against the live source authority,
	# never accepted from this advisory marker.
	snapshot_copy.erase("status")
	if expected_snapshot_revision != _value_digest(snapshot_copy):
		return _failed("ecology_snapshot_revision_mismatch")
	return {"status":"ready"}


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value:
			frozen[key] = _freeze_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_value(item))
		frozen.make_read_only()
		return frozen
	return value


static func _missing_categories(snapshot: Dictionary) -> Array[String]:
	var available: Array = snapshot.get("coverage", [])
	var complete: Variant = snapshot.get("completeCategories", [])
	var missing: Array[String] = []
	for category: String in REQUIRED_ECOLOGY_CATEGORIES:
		if category not in available and category not in complete:
			missing.append(category)
	return missing


static func _section_membership(outputs: Array) -> Dictionary:
	var members: Dictionary = {}
	var revisions: Dictionary = {}
	for output_value: Variant in outputs:
		if not output_value is Dictionary:
			continue
		var output: Dictionary = output_value
		var key: Variant = output.get("sectionKey")
		var source_id := String(output.get("sourceId", ""))
		if not key is Vector3i or source_id.is_empty():
			continue
		if not members.has(key):
			members[key] = []
		members[key].append(source_id)
		revisions[source_id] = String(output.get("sourceRevision", ""))
	var keys: Array = members.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var sealed: Dictionary = {}
	for key: Vector3i in keys:
		var ids: Array = members[key]
		ids.sort()
		ids.make_read_only()
		var digest_rows: Array = []
		for source_id: String in ids:
			digest_rows.append([source_id, String(revisions[source_id])])
		sealed[key] = {"status":"complete", "sourcePartIds":ids,
			"coverageRevision":JSON.stringify([key.x, key.y, key.z, digest_rows]).sha256_text()}
		sealed[key].make_read_only()
	sealed.make_read_only()
	return sealed


static func _binding_key(mesh_source: String, material_id: String) -> String:
	return mesh_source + "|" + material_id


static func _render_layer(producer_layer: String) -> String:
	if producer_layer == "alpha_scissor":
		return "cutout"
	if producer_layer == "opaque":
		return "opaque"
	return ""


static func _encode_instance(transform: Transform3D, custom: Color, color: Color) -> Array[float]:
	var encoded: PackedFloat32Array = InstanceAttributes.encode(transform, custom, color)
	var result: Array[float] = []
	for value: float in encoded:
		result.append(value)
	return result


static func _compatibility(producer_material: String, material_key: String,
		material_content_digest: String, mesh_resource_key: String,
		mesh_digest: String, pipeline_revision: String,
		render_layer: String, mesh_bounds: AABB, cast_shadows: bool,
		visibility_end: float, fade_margin: float) -> Dictionary:
	if producer_material.is_empty() or material_key.is_empty() \
			or material_content_digest.length() != 64 \
			or not material_content_digest.is_valid_hex_number(false) \
			or mesh_resource_key.is_empty() \
			or mesh_digest.length() != 64 or pipeline_revision.is_empty() \
			or render_layer not in ["opaque", "cutout"] or not _valid_bounds(mesh_bounds) \
			or visibility_end < 0.0 or fade_margin < 0.0:
		return {}
	var mesh_key := "%s|pipeline=%s|layer=%s|sort=none" % [
		mesh_resource_key, pipeline_revision, render_layer]
	var result := {"materialKey":material_key + "|sha256=" + material_content_digest,
		# Native section backend tiers are silhouette/structural/detail/horizon.
		# Surface-detail meshes use the shared detail budget even though their
		# source authority is environment ecology.
		"renderTier":"detail",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"meshResourceKey":mesh_resource_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "meshLocalBounds":mesh_bounds,
		"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
		"translucentSortPolicy":"none", "castShadows":cast_shadows,
		"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
		"batchKey":"", "compatibilityKey":""}
	var batch_key := SnapshotBuilder.batch_compatibility_key(result)
	if batch_key.is_empty():
		return {}
	result["batchKey"] = batch_key
	result["compatibilityKey"] = batch_key
	result.make_read_only()
	return result


func _capture_production_chunk(chunk_key: Vector2i) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable", {"chunk":chunk_key})
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return _pending("ecology_chunk_owner_map_unavailable", {"chunk":chunk_key})
	var chunk_node: Node3D = chunks_value.get(chunk_key) as Node3D
	if not is_instance_valid(chunk_node):
		return _pending("ecology_chunk_owner_unavailable", {"chunk":chunk_key})
	var snapshot_value: Variant = chunk_node.get_meta("static_ecology_source_value_snapshot", {})
	if not snapshot_value is Dictionary:
		return _pending("ecology_chunk_source_snapshot_missing_or_stale", {"chunk":chunk_key})
	var snapshot: Dictionary = snapshot_value
	var expected_world_id := "seed:%s:%d" % [String(main.get("seed_text")),
		int(main.get("seed_hash"))]
	if _validate_snapshot(snapshot).get("status") != "ready" \
			or _world_id != expected_world_id \
			or snapshot.get("chunk") != chunk_key \
			or String(snapshot.get("worldSeed", "")) != String(main.get("seed_text")) \
			or String(snapshot.get("sourceRevision", "")) != String(main.call(
				"_ecology_chunk_source_revision", chunk_key)) \
			or int(snapshot.get("removedPropsRevision", -1)) != int(main.get("removed_props_revision")):
		return _pending("ecology_chunk_source_snapshot_revision_stale", {"chunk":chunk_key})
	var bindings: Dictionary = {}
	var detail_types: Dictionary = {}
	var unsupported_detail_types: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "surface_detail":
			detail_types[String(candidate_value.get("detailType", ""))] = true
	for detail_type_value: Variant in detail_types:
		var detail_type := String(detail_type_value)
		var mesh: Variant = main.call("detail_mesh", detail_type)
		if not mesh is Mesh:
			return _pending("surface_detail_production_mesh_unavailable", {
				"chunk":chunk_key, "detailType":detail_type})
		var material_value: Variant = main.call("detail_material", detail_type)
		if material_value == null:
			# Flower batches rely on mesh-owned per-surface materials. The shared
			# section ABI currently accepts one material per batch.
			unsupported_detail_types.append(detail_type)
			continue
		if not material_value is Material:
			unsupported_detail_types.append(detail_type)
			continue
		var material_digest := _material_digest(material_value)
		if material_digest.is_empty():
			unsupported_detail_types.append(detail_type)
			continue
		var material_keys: Array = []
		for candidate_value: Variant in snapshot.candidates:
			if candidate_value is Dictionary \
					and String(candidate_value.get("detailType", "")) == detail_type:
				for key_value: Variant in candidate_value.get("materials", []):
					if String(key_value) not in material_keys:
						material_keys.append(String(key_value))
		if material_keys.size() != 1:
			unsupported_detail_types.append(detail_type)
			continue
		var material_key := String(material_keys[0])
		var binding := {"mesh":mesh, "material":material_value,
			"meshSource":"procedural_detail:%s" % detail_type,
			"meshResourceKey":"environment.detail.%s/v1" % detail_type,
			"materialKey":material_key, "materialContentDigest":material_digest,
			"pipelineRevision":PIPELINE_REVISION, "fadeMargin":12.0}
		binding.make_read_only()
		bindings["procedural_detail:%s|%s" % [detail_type, material_key]] = binding
	bindings.make_read_only()
	unsupported_detail_types.sort()
	return {"status":"ready", "snapshot":snapshot, "bindings":bindings,
		"chunkToWorld":chunk_node.global_transform,
		"unsupportedDetailTypes":unsupported_detail_types,
		"chunkOwnerInstanceId":chunk_node.get_instance_id()}


static func _material_digest(material: Material) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null or shader.code.is_empty(): return ""
		var uniform_rows: Array = []
		for uniform_value: Variant in shader.get_shader_uniform_list():
			if not uniform_value is Dictionary: return ""
			var uniform_name := String(uniform_value.get("name", ""))
			if uniform_name.begins_with("global_"): continue
			uniform_rows.append([uniform_name,
				(material as ShaderMaterial).get_shader_parameter(uniform_name)])
		uniform_rows.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]) < String(b[0]))
		return Marshalls.raw_to_base64(var_to_bytes([shader.code, uniform_rows])).sha256_text()
	if material is StandardMaterial3D:
		var properties: Array[String] = ["albedo_color", "metallic", "roughness", "emission_enabled",
			"emission", "transparency", "cull_mode", "shading_mode"]
		var values: Array = []
		for property_name: String in properties:
			values.append([property_name, material.get(property_name)])
		return Marshalls.raw_to_base64(var_to_bytes([material.get_class(), values])).sha256_text()
	return ""


static func _candidate_digest(candidate: Dictionary) -> String:
	var value := candidate.duplicate(true)
	value.erase("contentRevision")
	return _value_digest(value)


static func _value_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(JSON.stringify(_canonical(value)).to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var entries: Array = []
		for key: Variant in keys:
			entries.append([String(key), _canonical(value[key])])
		return entries
	if value is Array:
		var entries: Array = []
		for item: Variant in value:
			entries.append(_canonical(item))
		return entries
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
			value.basis.y.x, value.basis.y.y, value.basis.y.z,
			value.basis.z.x, value.basis.z.y, value.basis.z.z,
			value.origin.x, value.origin.y, value.origin.z]
	if value is AABB:
		return [_canonical(value.position), _canonical(value.size)]
	return value


static func _valid_transform(transform: Transform3D) -> bool:
	return transform.origin.is_finite() and transform.basis.x.is_finite() \
		and transform.basis.y.is_finite() and transform.basis.z.is_finite() \
		and absf(transform.basis.determinant()) > 0.000001


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"failed", "reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
