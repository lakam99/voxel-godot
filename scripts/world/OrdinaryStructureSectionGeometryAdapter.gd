extends RefCounted
class_name OrdinaryStructureSectionGeometryAdapter

## Resolves a generated ordinary structure block from its sealed producer
## recipe into the value input shape used by ChunkStaticRenderSectionInstancePartitioner.
## The live body remains the gameplay/collision owner and must agree with the
## recipe transform. This is deliberately partial: unsupported visual recipes
## keep the section pending until their complete layer/instance recipes exist.

const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const VisualRecipe := preload("res://scripts/world/OrdinaryStructureBlockVisualRecipe.gd")
const BUILDING_MATERIAL_SHADER_PATH := "res://resources/visual/building_material.gdshader"

const ALLOWED_BLOCK_TYPES: Array[String] = ["cobblestonePath", "stoneBlock",
	"woodBlock", "workbench", "bed", "traderStall", "spikeTrap",
	"copperVein", "ironVein"]
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
	var family := VisualRecipe.classify_generated_block_type(block_type)
	var recipe_inputs_value: Variant = source.get("visualRecipeInputs", {})
	if not recipe_inputs_value is Dictionary:
		return _pending("ordinary_geometry_visual_recipe_manifest_missing")
	var recipe_input: Dictionary = recipe_inputs_value.get(cell, {})
	var recipe_options: Variant = recipe_input.get("options")
	var recipe_digest := String(recipe_input.get("digest", ""))
	if not recipe_input.is_read_only() \
			or recipe_input.get("schema") != "ordinary-structure-visual-recipe-input/v1" \
			or String(recipe_input.get("blockType", "")) != block_type \
			or not recipe_options is Dictionary or not recipe_options.is_read_only() \
			or recipe_digest.is_empty() \
			or recipe_digest != _visual_recipe_digest(block_type, recipe_options):
		return _pending("ordinary_geometry_visual_recipe_manifest_stale", {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	var durable_id := String(structure_system.call("_ordinary_visual_block_key", source_id, cell, block_type))
	if removed_value.has(durable_id):
		return {"status":"empty", "reason":"ordinary_geometry_durably_removed",
			"sourcePartId":_source_part_id(source_id, cell)}
	if family.get("family") == "unknown":
		return _pending("ordinary_geometry_block_family_unknown", {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	if family.get("family") == "separate_dynamic":
		return _pending("ordinary_geometry_dynamic_family_requires_separate_owner", {
			"sourceId":source_id, "cell":cell, "blockType":block_type,
			"owner":String(family.get("owner", ""))})
	if block_type not in ALLOWED_BLOCK_TYPES:
		return _pending("ordinary_geometry_block_type_not_migrated", {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	var body := blocks_value.get(cell) as Node3D
	if not _valid_body(body, source_id, cell, block_type):
		return _pending("ordinary_geometry_live_source_body_unavailable", {
			"sourceId":source_id, "cell":cell})
	var recipe := VisualRecipe.resolve_member(main, block_type, cell, recipe_options)
	if recipe.get("status") != "ready":
		if recipe.get("status") == "failed":
			return _failed(String(recipe.get("reason", "ordinary_geometry_visual_recipe_failed")))
		return _pending(String(recipe.get("reason", "ordinary_geometry_visual_recipe_pending")), {
			"sourceId":source_id, "cell":cell, "blockType":block_type})
	var expected_transform: Transform3D = recipe.sourceToWorld
	if not _transform_matches(body.global_transform, expected_transform):
		return _pending("ordinary_geometry_live_body_transform_disagrees_with_recipe", {
			"sourceId":source_id, "cell":cell})
	var recipe_members: Array = recipe.get("members", [])
	if recipe_members.is_empty():
		return _pending("ordinary_geometry_recipe_member_list_empty", {
			"sourceId":source_id, "cell":cell})
	var cell_size := float(main.get("CELL"))
	var cell_origin := Vector3(cell) * cell_size
	var support := Vector3.ONE * (cell_size * MAX_HORIZONTAL_SUPPORT_CELLS)
	if not is_finite(cell_size) or cell_size <= 0.0:
		return _pending("ordinary_geometry_cell_size_invalid", {"sourceId":source_id})
	var part_id := _source_part_id(source_id, cell)
	var inputs: Array[Dictionary] = []
	var bindings: Array[Dictionary] = []
	var member_rows: Array = []
	var first_mesh: Mesh
	var first_material: Material
	var first_compatibility: Dictionary = {}
	var first_mesh_digest := ""
	var first_material_digest := ""
	for member_value: Variant in recipe_members:
		if not member_value is Dictionary:
			return _pending("ordinary_geometry_recipe_member_invalid", {
				"sourceId":source_id, "cell":cell})
		var member: Dictionary = member_value
		var mesh := member.get("mesh") as Mesh
		var material := member.get("material") as Material
		var segment_suffix := String(member.get("segmentId", ""))
		if segment_suffix.is_empty() or not is_instance_valid(mesh) \
				or not is_instance_valid(material) \
				or not member.get("meshLocalTransform") is Transform3D:
			return _pending("ordinary_geometry_recipe_mesh_or_material_unavailable", {
				"sourceId":source_id, "cell":cell, "segmentId":segment_suffix})
		if mesh.get_surface_count() != 1:
			return _pending("ordinary_geometry_multisurface_material_not_migrated", {
				"sourceId":source_id, "cell":cell, "segmentId":segment_suffix,
				"surfaceCount":mesh.get_surface_count()})
		var material_identity := _material_identity(material)
		if material_identity.is_empty():
			return _pending("ordinary_geometry_material_fingerprint_unavailable", {
				"sourceId":source_id, "cell":cell,
				"materialClass":material.get_class()})
		if not _material_is_opaque(material):
			return _pending("ordinary_geometry_nonopaque_material_not_migrated", {
				"sourceId":source_id, "cell":cell,
				"materialClass":material.get_class()})
		var mesh_identity := MeshFingerprint.inspect(mesh)
		if mesh_identity.get("status") != "ready":
			return _pending("ordinary_geometry_mesh_fingerprint_unavailable", {
				"sourceId":source_id, "cell":cell,
				"reason":String(mesh_identity.get("reason", ""))})
		var mesh_bounds: AABB = member.meshLocalBounds
		var world_bounds: AABB = member.worldBounds
		var cast_shadows := bool(member.get("castShadows", true))
		if not _valid_bounds(mesh_bounds) or not _valid_bounds(world_bounds):
			return _pending("ordinary_geometry_mesh_bounds_invalid", {
				"sourceId":source_id, "cell":cell, "segmentId":segment_suffix})
		if world_bounds.position.x < cell_origin.x - support.x \
				or world_bounds.end.x > cell_origin.x + support.x \
				or world_bounds.position.z < cell_origin.z - support.z \
				or world_bounds.end.z > cell_origin.z + support.z:
			return _pending("ordinary_geometry_horizontal_support_exceeds_section_query", {
				"sourceId":source_id, "cell":cell, "segmentId":segment_suffix,
				"worldBounds":world_bounds, "cellOrigin":cell_origin,
				"maxHorizontalSupport":support.x})
		var source_revision := _revision(source, source_id, cell, block_type,
			expected_transform, member.meshLocalTransform,
			String(mesh_identity.contentDigest), material_identity.digest,
			String(recipe.contentDigest) + recipe_digest + segment_suffix)
		if source_revision.is_empty():
			return _failed("ordinary_geometry_revision_hash_failed")
		var mesh_key: String = "ordinary-mesh:" + String(mesh_identity.contentDigest)
		var material_key: String = "ordinary-material:" + String(material_identity.digest)
		var pipeline_revision := "ordinary-static-mesh/v2"
		var mesh_pipeline_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh_key, pipeline_revision]
		var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"materialKey":material_key, "renderTier":"structural",
			"meshResourceKey":mesh_key, "meshContentDigest":String(mesh_identity.contentDigest),
			"meshKey":mesh_pipeline_key, "pipelineRevision":pipeline_revision,
			"renderLayer":"opaque", "translucentSortPolicy":"none",
			"meshLocalBounds":mesh_bounds, "castShadows":cast_shadows,
			"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
		var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
		if batch_key.is_empty():
			return _pending("ordinary_geometry_batch_compatibility_invalid", {
				"sourceId":source_id, "cell":cell})
		compatibility["batchKey"] = batch_key
		compatibility["compatibilityKey"] = batch_key
		compatibility.make_read_only()
		var buffer: Array[float] = []
		for value: float in Attributes.encode(member.meshLocalTransform, Color.WHITE, Color.WHITE):
			buffer.append(value)
		buffer.make_read_only()
		var instance_input: Dictionary = {
			"schema":SCHEMA,
			"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"sourceId":part_id,
			"sourcePartId":part_id,
			"authoritySourceId":source_id,
			"sourceRevision":source_revision,
			"visualRecipeDigest":recipe_digest,
			"visualRecipeInput":recipe_input,
			"segmentId":part_id + ":" + segment_suffix,
			"ownerCell":Grid.logical_owner_cell_for_world_position(body.global_position),
			"sourceToWorld":expected_transform,
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
			"castShadows":cast_shadows,
			"visibilityRangeEnd":100000.0,
			"fadeMargin":0.0,
			"buffer":buffer,
			"instanceCount":1
		}
		inputs.append(instance_input)
		bindings.append({"input":instance_input, "mesh":mesh,
			"material":material, "compatibility":compatibility,
			"meshDigest":String(mesh_identity.contentDigest),
			"materialDigest":String(material_identity.digest)})
		member_rows.append([segment_suffix, source_revision,
			String(mesh_identity.contentDigest), material_identity.digest,
			cast_shadows])
		if inputs.size() == 1:
			first_mesh = mesh
			first_material = material
			first_compatibility = compatibility
			first_mesh_digest = String(mesh_identity.contentDigest)
			first_material_digest = String(material_identity.digest)
	var combined_context := HashingContext.new()
	if combined_context.start(HashingContext.HASH_SHA256) != OK \
			or combined_context.update(var_to_bytes([SCHEMA, part_id, member_rows])) != OK:
		return _failed("ordinary_geometry_revision_hash_failed")
	var combined_revision := combined_context.finish().hex_encode()
	for index in inputs.size():
		var input: Dictionary = inputs[index]
		input["sourceRevision"] = combined_revision
		input.make_read_only()
		bindings[index]["input"] = input
		bindings[index].make_read_only()
	inputs.make_read_only()
	bindings.make_read_only()
	for row_value: Variant in member_rows:
		if row_value is Array:
			(row_value as Array).make_read_only()
	member_rows.make_read_only()
	var manifest_row: Dictionary = {"sourcePartId":part_id,
		"sourceRevision":combined_revision, "sourceId":source_id,
		"cell":cell, "blockType":block_type,
		"visualRecipeDigest":recipe_digest, "members":member_rows}
	manifest_row.make_read_only()
	return {"status":"ready", "sourceInput":inputs[0], "sourceInputs":inputs,
		"memberBindings":bindings,
		"members":recipe_members, "manifest":manifest_row,
		"compatibility":first_compatibility, "mesh":first_mesh,
		"material":first_material, "body":weakref(body), "geometry":null,
		"sourcePartId":part_id, "sourceRevision":combined_revision,
		"meshDigest":first_mesh_digest,
		"materialDigest":first_material_digest}


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


static func _transform_matches(actual: Transform3D, expected: Transform3D) -> bool:
	return actual.origin.distance_squared_to(expected.origin) <= 0.000001 \
		and actual.basis.x.distance_squared_to(expected.basis.x) <= 0.000001 \
		and actual.basis.y.distance_squared_to(expected.basis.y) <= 0.000001 \
		and actual.basis.z.distance_squared_to(expected.basis.z) <= 0.000001


static func _revision(source: Dictionary, source_id: String, cell: Vector3i,
		block_type: String, body_transform: Transform3D, mesh_transform: Transform3D,
		mesh_digest: String, material_digest: String, recipe_digest: String) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	var payload := [SCHEMA, source_id, int(source.get("revision", -1)), cell, block_type,
		body_transform, mesh_transform, mesh_digest, material_digest, recipe_digest]
	if context.update(var_to_bytes(payload)) != OK:
		return ""
	return context.finish().hex_encode()


static func _visual_recipe_digest(block_type: String, options: Dictionary) -> String:
	if block_type.is_empty() or not options.is_read_only():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([
				"ordinary-structure-visual-recipe-input/v1", block_type, options])) != OK:
		return ""
	return context.finish().hex_encode()


static func _material_identity(material: Material) -> Dictionary:
	if not is_instance_valid(material): return {}
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		if not is_instance_valid(shader) or shader.resource_path != BUILDING_MATERIAL_SHADER_PATH:
			return {}
		var shader_code := shader.code
		if shader_code.is_empty() or shader_code.contains("ALPHA") \
				or shader_code.contains("blend_"):
			return {}
		var uniforms: Array = []
		for uniform_value: Variant in shader.get_shader_uniform_list():
			if not uniform_value is Dictionary:
				return {}
			var uniform: Dictionary = uniform_value
			var name := String(uniform.get("name", ""))
			if name.is_empty(): continue
			var value: Variant = shader_material.get_shader_parameter(name)
			if value is Resource or value is Object or value is Callable:
				return {}
			uniforms.append([name, value])
		uniforms.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		var shader_context := HashingContext.new()
		if shader_context.start(HashingContext.HASH_SHA256) != OK \
				or shader_context.update(var_to_bytes([
					"opaque-building-shader/v1", BUILDING_MATERIAL_SHADER_PATH,
					shader_code, uniforms])) != OK:
			return {}
		return {"digest":shader_context.finish().hex_encode(),
			"materialClass":"ShaderMaterial", "shaderPath":BUILDING_MATERIAL_SHADER_PATH,
			"uniforms":uniforms}
	if not material is StandardMaterial3D:
		return {}
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


static func _material_is_opaque(material: Material) -> bool:
	if material is StandardMaterial3D:
		var standard := material as StandardMaterial3D
		return standard.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
			and standard.albedo_color.a >= 0.999
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if not is_instance_valid(shader) or shader.resource_path != BUILDING_MATERIAL_SHADER_PATH:
			return false
		var code := shader.code
		return not code.is_empty() and not code.contains("ALPHA") \
			and not code.contains("blend_")
	return false


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
