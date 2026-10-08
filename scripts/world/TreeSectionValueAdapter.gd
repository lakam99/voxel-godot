extends RefCounted
class_name TreeSectionValueAdapter

## Adapts the tree queue's sealed producer output into immutable shared-section
## inputs. The queue remains the recipe/LOD owner; the StaticBody remains the
## collision, interaction, harvest, and save owner. This is not a census of
## trees in a chunk or section.

const QueueScript := preload("res://scripts/environment/TreePublicationQueue.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const MaterialFingerprint := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const BranchShader := preload("res://resources/visual/procedural_tree_branch.gdshader")
const FoliageShader := preload("res://resources/visual/procedural_tree_foliage.gdshader")

const SCHEMA := "tree-section-value-adapter/v1"
const PIPELINE_REVISION := "procedural-tree-runtime-visual/v1"


## Adapt an admitted finite source without rewriting the compiler artifact.
## This is MAIN capture: weak owner fields never enter the returned value inputs.
## The caller binds the alias and census revision to its current admitted job.
static func capture_compiled_contributor(captured: Dictionary, source_id: String,
		source_revision: String, section_key: Vector3i) -> Dictionary:
	if captured.get("status") != "ready" or not captured.is_read_only() \
			or source_id.is_empty() or source_revision.is_empty():
		return _pending("tree_compiled_contributor_identity_missing")
	var producer_id := String(captured.get("producerSourceId", ""))
	var compiled_value: Variant = captured.get("compiledRecord")
	var manifest_value: Variant = captured.get("sourceManifest")
	if producer_id.is_empty() or not compiled_value is Dictionary \
			or not compiled_value.is_read_only() or not manifest_value is Dictionary \
			or not manifest_value.is_read_only():
		return _pending("tree_compiled_contributor_unsealed")
	var compiled: Dictionary = compiled_value
	var manifest: Dictionary = manifest_value
	var artifact: Dictionary = compiled.get("compiled", {})
	var compiler_revision := String(manifest.get("sourceRevision", ""))
	if not artifact.is_read_only() or manifest.get("sourceId") != producer_id \
			or compiler_revision.is_empty() or compiler_revision != captured.get("compiledSourceRevision"):
		return _pending("tree_compiled_contributor_source_mismatch")
	var resources: Dictionary = artifact.get("resourceBindings", {})
	var inputs: Array[Dictionary] = []
	var complete_members: Array[Dictionary] = []
	var supports: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var resource_bindings: Dictionary = {}
	var seen_members: Dictionary = {}
	var ownership_by_member: Dictionary = {}
	for ownership: Variant in manifest.get("geometryOwnership", []):
		if not ownership is Dictionary or not ownership.is_read_only():
			return _pending("tree_compiled_geometry_ownership_unsealed")
		var member_id := String(ownership.get("memberId", ""))
		if member_id.is_empty() or ownership_by_member.has(member_id):
			return _pending("tree_compiled_geometry_ownership_ambiguous")
		ownership_by_member[member_id] = ownership
	for batch_value: Variant in artifact.get("batches", []):
		if not batch_value is Dictionary or not batch_value.is_read_only():
			return _pending("tree_compiled_contributor_batch_unsealed")
		var batch: Dictionary = batch_value
		var owner_section: Variant = batch.get("sectionKey")
		var compatibility: Variant = batch.get("compatibilityKey")
		var batch_key := String(batch.get("batchKey", ""))
		if not owner_section is Vector3i or not compatibility is Dictionary \
				or not compatibility.is_read_only() or batch_key.is_empty() \
				or compatibility.get("batchKey") != batch_key:
			return _pending("tree_compiled_contributor_batch_invalid")
		var mesh: Variant = resources.get(String(batch.get("meshKey", "")))
		var material: Variant = resources.get(String(batch.get("materialKey", "")))
		if not is_instance_valid(mesh) or not mesh is Mesh \
				or not is_instance_valid(material) or not material is Material \
				or MeshFingerprint.inspect(mesh).get("contentDigest", "") != compatibility.get("meshContentDigest") \
				or _material_digest(material) != compatibility.get("materialDigest", compatibility.get("materialContentDigest")):
			return _pending("tree_compiled_contributor_resource_stale")
		var source_to_world := Transform3D(Basis.IDENTITY, Grid.origin_for_key(owner_section))
		for contributor_key: Variant in batch.get("contributors", {}):
			var contributor: Variant = batch.contributors[contributor_key]
			if not contributor is Dictionary or not contributor.is_read_only():
				return _pending("tree_compiled_contributor_member_unsealed")
			if contributor.get("sourceId") != producer_id: continue
			var producer_part := String(contributor.get("sourcePartId", ""))
			var expected_key := "section-part:" + var_to_bytes([producer_id, producer_part]).hex_encode()
			var attributes: Variant = contributor.get("instanceAttributes")
			var count := int(contributor.get("instanceCount", 0))
			if producer_part.is_empty() or contributor_key != expected_key \
					or seen_members.has(producer_part) or not ownership_by_member.has(producer_part) \
					or contributor.get("sourceRevision") != compiler_revision \
					or not attributes is Array or not attributes.is_read_only() \
					or count != 1 \
					or attributes.size() != Attributes.FLOATS_PER_INSTANCE:
				return _pending("tree_compiled_contributor_member_identity_invalid")
			var typed_attributes: Array[float] = []
			for component: Variant in attributes:
				if not component is float or not is_finite(component):
					return _pending("tree_compiled_contributor_attribute_invalid")
				typed_attributes.append(component)
			typed_attributes.make_read_only()
			attributes = typed_attributes
			seen_members[producer_part] = true
			var ownership: Dictionary = ownership_by_member[producer_part]
			if ownership.get("geometryOwnerSectionKey") != owner_section:
				return _pending("tree_compiled_contributor_owner_mismatch")
			var segment_id := "building-tree-member:" + var_to_bytes([
				source_id, producer_id, producer_part, compiler_revision, owner_section, batch_key]).hex_encode().sha256_text()
			var member := OwnerCompletion.capture_member(source_id, source_id,
				source_revision, segment_id, 0, source_to_world,
				compatibility.get("meshLocalBounds", AABB()), attributes, 0, compatibility)
			if member.is_empty() or member.geometryOwnerSection != owner_section:
				return _pending("tree_compiled_contributor_geometry_member_invalid")
			complete_members.append(member)
			if owner_section == section_key:
				if compatibility_by_key.has(batch_key) and compatibility_by_key[batch_key] != compatibility:
					return _pending("tree_compiled_contributor_batch_conflict")
				compatibility_by_key[batch_key] = compatibility
				var bindings := {"mesh":mesh, "material":material,
					"materialDigest":_material_digest(material)}
				bindings.make_read_only()
				resource_bindings[batch_key] = bindings
				var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
					"sourceId":source_id, "sourcePartId":source_id, "sourceRevision":source_revision,
					"ownerCell":batch.get("ownerCell"), "sourceToWorld":source_to_world,
					"meshLocalBounds":compatibility.get("meshLocalBounds", AABB()),
					"batchKey":batch_key, "segmentId":segment_id, "buffer":attributes,
					"instanceCount":count, "compatibility":compatibility}
				input.make_read_only()
				inputs.append(input)
			elif section_key in ownership.get("supportSectionKeys", []):
				var bounds: Variant = ownership.get("conservativeWorldBounds")
				if not bounds is AABB or not _valid_bounds(bounds):
					return _pending("tree_compiled_contributor_support_invalid")
				var dependencies: Array[Vector2i] = SectionSnapshot._stream_chunk_keys_intersecting_bounds(bounds).duplicate()
				var owner_chunk := Grid.chunk_key_for_section(owner_section)
				if owner_chunk not in dependencies: dependencies.append(owner_chunk)
				dependencies.make_read_only()
				var support := {"sourceId":source_id, "sourcePartId":source_id,
					"sourceRevision":source_revision, "memberId":segment_id + ":0",
					"propId":String(captured.get("propId", "")), "sourceSegmentId":segment_id,
					"sourceInstance":0, "ownerCell":batch.get("ownerCell"),
					"sourceOwnerChunk":owner_chunk, "geometryOwnerSection":owner_section,
					"supportSectionKey":section_key, "worldBounds":bounds,
					"streamChunkDependencies":dependencies,
					"ownershipPolicy":"center_geometry_owner/aabb_support_sections_v1",
					"meshContentDigest":String(compatibility.get("meshContentDigest", ""))}
				support.make_read_only()
				supports.append(support)
	if seen_members.size() != ownership_by_member.size() or seen_members.is_empty():
		return _pending("tree_compiled_contributor_roster_incomplete")
	inputs.make_read_only()
	complete_members.make_read_only()
	supports.make_read_only()
	compatibility_by_key.make_read_only()
	resource_bindings.make_read_only()
	return {"status":"ready", "inputs":inputs, "geometryOwnerMembers":complete_members,
		"supportRanges":supports, "compatibilityByKey":compatibility_by_key,
		"resourceBindings":resource_bindings, "producerSourceId":producer_id,
		"compiledSourceRevision":compiler_revision}


## Hash the queue-owned raw member values and the mutable resources they refer
## to. This is intentionally a census-safe operation: it fingerprints resources
## and value arrays, but does not encode instance attributes or partition them.
static func raw_member_content_revision(members: Dictionary) -> String:
	var parts: Array = [SCHEMA, "raw-members/v1"]
	for role: String in ["bole", "branches", "foliage"]:
		var role_members: Variant = members.get(role, null)
		if not role_members is Array:
			return ""
		for member_value: Variant in role_members:
			if not member_value is Dictionary or not member_value.is_read_only():
				return ""
			var member: Dictionary = member_value
			var mesh_value: Variant = member.get("mesh", null)
			var material_value: Variant = member.get("material", null)
			var local_transform: Variant = member.get("localTransform", null)
			var transforms: Variant = member.get("transforms", null)
			var colors: Variant = member.get("colors", null)
			var custom_data: Variant = member.get("customData", null)
			if not mesh_value is Mesh or not material_value is Material \
					or not local_transform is Transform3D \
					or not transforms is Array or not transforms.is_read_only() \
					or not colors is Array or not colors.is_read_only() \
					or not custom_data is Array or not custom_data.is_read_only() \
					or transforms.is_empty() or transforms.size() != colors.size() \
					or transforms.size() != custom_data.size():
				return ""
			var mesh_report: Dictionary = MeshFingerprint.inspect(mesh_value as Mesh)
			if mesh_report.get("status") != "ready":
				return ""
			var material_digest := _material_digest(material_value as Material)
			if material_digest.is_empty():
				return ""
			for index: int in range(transforms.size()):
				if not transforms[index] is Transform3D or not colors[index] is Color \
						or not custom_data[index] is Color:
					return ""
			parts.append([role, String(member.get("schema", "")),
				String(mesh_report.get("contentDigest", "")), material_digest,
				local_transform, transforms, colors, custom_data,
				int(member.get("producerElementCount", -1)),
				float(member.get("visibilityRangeEnd", 0.0)),
				float(member.get("fadeMargin", 0.0)),
				bool(member.get("castShadows", false))])
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(parts)) != OK:
		return ""
	return context.finish().hex_encode()


## Bind the same complete producer identity during census and contribution.
## All fields are value data; no geometry encoding or section partitioning is
## performed here.
static func source_revision_from_raw_members(world_id: String, seed: String,
		source_id: String, recipe_signature: String, tier: String,
		owner_cell: Vector2i, body_transform: Transform3D,
		raw_revision: String) -> String:
	if world_id.is_empty() or seed.is_empty() or source_id.is_empty() \
			or recipe_signature.is_empty() or tier.is_empty() or raw_revision.is_empty():
		return ""
	var context := HashingContext.new()
	var values := [SCHEMA, PIPELINE_REVISION, world_id, seed, source_id,
		recipe_signature, tier, owner_cell, body_transform, raw_revision]
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(values)) != OK:
		return ""
	return context.finish().hex_encode()


## Resolve the producer's committed recipe and value geometry from the queue's
## own acknowledgement record. This lets the ecology provider join the normal
## source census without enumerating GeneratedTreeVisual scene children.
static func capture_from_queue_record(queue: Object, main: Object, world_id: String,
		body: StaticBody3D, removed_snapshot: Dictionary) -> Dictionary:
	if not is_instance_valid(queue) or not queue is QueueScript:
		return _pending("tree_capture_authority_missing")
	var record := _published_record(queue, body) if is_instance_valid(body) else {}
	var recipe_value: Variant = record.get("recipeSnapshot", null)
	if not recipe_value is Dictionary or not recipe_value.is_read_only():
		return _pending("tree_queue_recipe_snapshot_missing")
	return _capture_tree_record(queue, main, world_id, body, recipe_value,
		removed_snapshot, record, true)


static func capture_from_prepared_record(queue: Object, main: Object,
		world_id: String, body: StaticBody3D, record: Dictionary,
		removed_snapshot: Dictionary) -> Dictionary:
	if not is_instance_valid(queue) or not queue is QueueScript \
			or not record.is_read_only() \
			or String(record.get("schema", "")) != "prepared-tree-section-artifact/v1":
		return _pending("tree_prepared_section_artifact_missing")
	var recipe_value: Variant = record.get("recipeSnapshot", null)
	if not recipe_value is Dictionary or not recipe_value.is_read_only():
		return _pending("tree_prepared_recipe_snapshot_missing")
	return _capture_tree_record(queue, main, world_id, body, recipe_value,
		removed_snapshot, record, false)


## Capture is fail-closed: it accepts only the exact body instance and recipe
## acknowledged by TreePublicationQueue, with a complete currently installed
## non-impostor visual. An authoritative removedProps snapshot can prove the
## one-tree tombstone; an absent body or queue record is always pending.
static func capture_published_tree(queue: Object, main: Object, world_id: String,
		body: StaticBody3D, recipe: Dictionary, removed_snapshot: Dictionary) -> Dictionary:
	if not is_instance_valid(queue) or not queue is QueueScript \
			or not is_instance_valid(main) or not is_instance_valid(body):
		return _pending("tree_capture_authority_missing")
	var queue_record := _published_record(queue, body)
	return _capture_tree_record(queue, main, world_id, body, recipe,
		removed_snapshot, queue_record, true)


static func _capture_tree_record(queue: Object, main: Object, world_id: String,
		body: StaticBody3D, recipe: Dictionary, removed_snapshot: Dictionary,
		queue_record: Dictionary, require_published: bool) -> Dictionary:
	if not is_instance_valid(queue) or not queue is QueueScript \
			or not is_instance_valid(main) or not is_instance_valid(body):
		return _pending("tree_capture_authority_missing")
	var prop_id := String(body.get_meta("prop_id", ""))
	if world_id.strip_edges().is_empty() or prop_id.is_empty() \
			or not bool(removed_snapshot.get("ok", false)) \
			or not RemovedProps.is_current_for_ids(main, removed_snapshot, [prop_id]):
		return _pending("tree_removed_props_snapshot_stale")
	var seed := String(removed_snapshot.get("seed", ""))
	if prop_id.is_empty() or seed.is_empty():
		return _pending("tree_stable_identity_missing")
	var source_id := "%s:tree:%s" % [seed, prop_id]
	var removed_ids: Array = removed_snapshot.get("ids", [])
	if removed_ids.has(prop_id):
		return {"status":"empty", "reason":"tree_authoritative_tombstone",
			"schema":SCHEMA, "worldId":world_id, "sourceId":source_id,
			"sourcePartId":source_id, "sourceRevision":_tombstone_revision(
				world_id, source_id, prop_id), "propId":prop_id}
	var prepared_transform: Variant = queue_record.get("bodyGlobalTransform", null)
	var prepared_for_current_body := prepared_transform is Transform3D \
		and (prepared_transform as Transform3D).is_equal_approx(body.global_transform)
	if not body.is_inside_tree() or body.is_queued_for_deletion() \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or not prepared_for_current_body \
			or int(queue_record.get("bodyInstanceId", 0)) != body.get_instance_id():
		return _pending("tree_body_not_currently_publishable", {"sourceId":source_id})
	if queue_record.is_empty():
		return _pending("tree_queue_prepared_record_missing" if not require_published \
			else "tree_queue_acknowledgement_missing", {"sourceId":source_id})
	if bool(queue_record.get("rebuildPending", false)):
		return _pending("tree_lod_replacement_pending", {"sourceId":source_id})
	var request_value: Variant = queue_record.get("request", {})
	if not request_value is Dictionary:
		return _pending("tree_queue_request_missing", {"sourceId":source_id})
	var request: Dictionary = request_value
	var tier := String(queue_record.get("tier", ""))
	var recipe_lod: Variant = recipe.get("renderLod", {})
	if tier.is_empty() or tier != String(request.get("renderLodTier", "")) \
			or not recipe_lod is Dictionary or tier != String(recipe_lod.get("tier", "")):
		return _pending("tree_queue_recipe_lod_disagrees", {"sourceId":source_id})
	if String(queue_record.get("propId", "")) != prop_id \
			or String(queue_record.get("worldSeed", "")) != seed \
			or not request.get("treeWorldPosition") is Vector3 \
			or not (request.get("treeWorldPosition") as Vector3).is_equal_approx(body.global_position):
		return _pending("tree_queue_request_identity_stale", {"sourceId":source_id})
	var service_value: Variant = queue.get("publication_service")
	if service_value == null or not service_value.has_method("runtime_recipe_signature") \
			or not service_value.has_method("normalize_request") \
			or not service_value.has_method("request_key"):
		return _pending("tree_recipe_authority_missing", {"sourceId":source_id})
	var normalized_request_value: Variant = service_value.call("normalize_request", request)
	if not normalized_request_value is Dictionary or normalized_request_value.is_empty():
		return _pending("tree_recipe_request_normalization_unavailable", {"sourceId":source_id})
	var normalized_request: Dictionary = normalized_request_value
	var expected_signature := String(service_value.call(
		"runtime_recipe_signature", recipe, normalized_request))
	if expected_signature.is_empty() or expected_signature != String(recipe.get("signature", "")) \
			or (require_published and expected_signature != String(body.get_meta("tree_recipe_signature", ""))) \
			or (require_published and String(body.get_meta("tree_render_lod_tier", "")) != tier) \
			or (not require_published and expected_signature != String(queue_record.get("recipeSignature", ""))):
		return _pending("tree_recipe_revision_not_current", {
			"sourceId":source_id,
			"queueRequestKey":String(service_value.call("request_key", normalized_request)),
			"expectedRecipeSignature":expected_signature,
			"capturedRecipeSignature":String(recipe.get("signature", "")),
			"bodyRecipeSignature":String(body.get_meta("tree_recipe_signature", "")),
			"queueTier":tier,
			"recipeTier":String(recipe_lod.get("tier", "")) if recipe_lod is Dictionary else "",
			"bodyTier":String(body.get_meta("tree_render_lod_tier", "")),
			"topologySignature":String(recipe.get("topologySignature", "")),
			"branchCount":int(recipe.get("branchCount", 0))})
	if bool(recipe.get("runtimeImpostor", false)) \
			or String(body.get_meta("visual_source", "")) == "chunk_tree_impostor":
		return _pending("tree_impostor_installation_not_enumerable", {"sourceId":source_id})
	var member_values: Variant = queue_record.get("sectionValueMembers", null)
	if bool(queue_record.get("sectionValueCapturePending", false)) \
			or not member_values is Array or not member_values.is_read_only():
		return _pending("tree_queue_section_value_snapshot_missing_or_stale", {
			"sourceId":source_id,
			"reason":String(queue_record.get("sectionValueCapturePending", ""))})
	var members := _members_by_role(member_values)
	if members.get("status") != "ready":
		return _pending(String(members.get("reason", "tree_queue_section_value_snapshot_invalid")), {
			"sourceId":source_id})
	members = members.members
	var recipe_check := _validate_recipe_members(recipe, members)
	if recipe_check.get("status") != "ready":
		return _pending(String(recipe_check.get("reason", "tree_recipe_visual_members_disagree")),
			{"sourceId":source_id})
	var owner_cell := Grid.logical_owner_cell_for_world_position(body.global_position)
	var captured := _prepare_members(body, source_id, world_id, seed, expected_signature,
		owner_cell, tier, members)
	if captured.get("status") != "ready":
		return captured
	return captured


static func _published_record(queue: Object, body: StaticBody3D) -> Dictionary:
	var records_value: Variant = queue.get("published_lod_records")
	if not records_value is Array:
		return {}
	for record_value: Variant in records_value:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var reference := record.get("body") as WeakRef
		if reference != null and reference.get_ref() == body \
				and int(record.get("bodyInstanceId", 0)) == body.get_instance_id():
			return record
	return {}


static func _members_by_role(member_values: Array) -> Dictionary:
	var members := {"bole":[], "branches":[], "foliage":[]}
	for member_value: Variant in member_values:
		if not member_value is Dictionary or not member_value.is_read_only():
			return _pending("tree_queue_member_value_unsealed")
		var member: Dictionary = member_value
		var role := String(member.get("role", ""))
		if String(member.get("schema", "")) != "tree-section-render-member/v1" \
				or role not in members or not member.get("mesh") is Mesh \
				or not member.get("material") is Material \
				or not member.get("transforms") is Array \
				or not member.get("colors") is Array \
				or not member.get("customData") is Array:
			return _pending("tree_queue_member_value_invalid")
		members[role].append(member)
	if members.bole.size() != 1 or members.branches.size() > 1 \
			or members.foliage.size() > 1:
		return _pending("tree_queue_member_topology_not_supported", {
			"boleCount":members.bole.size(), "branchBatchCount":members.branches.size(),
			"foliageBatchCount":members.foliage.size()})
	return {"status":"ready", "members":members}


static func _validate_recipe_members(recipe: Dictionary, members: Dictionary) -> Dictionary:
	var recipe_branches_value: Variant = recipe.get("branches", [])
	var recipe_foliage_value: Variant = recipe.get("foliage", [])
	if not recipe_branches_value is Array or not recipe_foliage_value is Array:
		return _pending("tree_recipe_geometry_arrays_missing")
	var bole_count := 0
	var distal_count := 0
	for branch_value: Variant in recipe_branches_value:
		if not branch_value is Dictionary:
			return _pending("tree_recipe_branch_record_invalid")
		if int(branch_value.get("order", 1)) == 0:
			bole_count += 1
		else:
			distal_count += 1
	if bole_count < 1 or members.bole.size() != 1 \
			or int(members.bole[0].get("producerElementCount", -1)) != bole_count:
		return _pending("tree_bole_geometry_membership_mismatch", {
			"recipeBoleCount":bole_count})
	var actual_distal := 0
	if not members.branches.is_empty():
		actual_distal = (members.branches[0].transforms as Array).size()
	if actual_distal != distal_count or (distal_count > 0) != (members.branches.size() == 1):
		return _pending("tree_branch_geometry_membership_mismatch", {
			"recipeDistalCount":distal_count, "actualDistalCount":actual_distal})
	var actual_foliage := 0
	if not members.foliage.is_empty():
		actual_foliage = (members.foliage[0].transforms as Array).size()
	if actual_foliage != recipe_foliage_value.size() \
			or (actual_foliage > 0) != (members.foliage.size() == 1):
		return _pending("tree_foliage_geometry_membership_mismatch", {
			"recipeFoliageCount":recipe_foliage_value.size(), "actualFoliageCount":actual_foliage})
	return {"status":"ready", "boleInstances":1, "branchInstances":actual_distal,
		"foliageInstances":actual_foliage}


static func _prepare_members(body: StaticBody3D, source_id: String, world_id: String,
		seed: String, recipe_signature: String, owner_cell: Vector2i,
		tier: String, members: Dictionary) -> Dictionary:
	var member_rows: Array[Dictionary] = []
	var compatibility_by_key := {}
	var mesh_bindings := {}
	var material_bindings := {}
	for role: String in ["bole", "branches", "foliage"]:
		for member_value: Variant in members.get(role, []):
			var member: Dictionary = member_value
			var mesh := member.get("mesh") as Mesh
			var material := member.get("material") as Material
			var local_transform: Variant = member.get("localTransform")
			var raw_transforms: Variant = member.get("transforms")
			var raw_colors: Variant = member.get("colors")
			var raw_custom: Variant = member.get("customData")
			if not is_instance_valid(mesh) or material == null \
					or not local_transform is Transform3D \
					or not raw_transforms is Array or not raw_colors is Array \
					or not raw_custom is Array \
					or raw_transforms.size() == 0 \
					or raw_transforms.size() != raw_colors.size() \
					or raw_transforms.size() != raw_custom.size():
				return _pending("tree_geometry_mesh_or_material_missing", {"sourceId":source_id, "role":role})
			var instance_transforms: Array[Transform3D] = []
			var instance_colors: Array[Color] = []
			var custom_data: Array[Color] = []
			for index: int in range(raw_transforms.size()):
				var member_transform: Variant = raw_transforms[index]
				var member_color: Variant = raw_colors[index]
				var member_custom: Variant = raw_custom[index]
				if not member_transform is Transform3D or not member_color is Color \
						or not member_custom is Color:
					return _pending("tree_queue_instance_value_invalid", {"sourceId":source_id, "role":role})
				instance_transforms.append(local_transform * member_transform)
				instance_colors.append(member_color)
				custom_data.append(member_custom)
			var layer := _supported_opaque_layer(material, role)
			if layer.is_empty():
				return _pending("tree_material_render_layer_unsupported", {"sourceId":source_id, "role":role})
			var mesh_report: Dictionary = MeshFingerprint.inspect(mesh)
			if mesh_report.get("status") != "ready":
				return _pending("tree_mesh_fingerprint_unavailable", {"sourceId":source_id, "role":role})
			var mesh_digest := String(mesh_report.get("contentDigest", ""))
			var material_digest := _material_digest(material)
			if mesh_digest.is_empty() or material_digest.is_empty():
				return _pending("tree_resource_digest_unavailable", {"sourceId":source_id, "role":role})
			var mesh_bounds: AABB = mesh.get_aabb()
			if not _valid_bounds(mesh_bounds):
				return _pending("tree_mesh_bounds_invalid", {"sourceId":source_id, "role":role})
			var visibility_end := float(member.get("visibilityRangeEnd", 0.0))
			var fade_margin := float(member.get("fadeMargin", 0.0))
			var cast_shadows := bool(member.get("castShadows", false))
			var mesh_resource_key := "tree.runtime.%s:%s/v1" % [role, mesh_digest]
			var mesh_key := "%s|pipeline=%s|layer=%s|sort=none" % [mesh_resource_key, PIPELINE_REVISION, layer]
			var material_key := "tree.material.%s:%s" % [role, material_digest]
			var renderer_tier := _renderer_tier_for_role(role)
			var compatibility_value := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
				"materialKey":material_key, "renderTier":renderer_tier,
				"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
				"meshKey":mesh_key, "pipelineRevision":PIPELINE_REVISION,
				"renderLayer":layer, "translucentSortPolicy":"none",
				"meshLocalBounds":mesh_bounds, "castShadows":cast_shadows,
				"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin}
			var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility_value)
			if batch_key.is_empty():
				return _pending("tree_batch_compatibility_invalid", {"sourceId":source_id, "role":role})
			compatibility_value["batchKey"] = batch_key
			compatibility_value["compatibilityKey"] = batch_key
			compatibility_value.make_read_only()
			compatibility_by_key[batch_key] = compatibility_value
			mesh_bindings[mesh_resource_key] = mesh
			material_bindings[material_key] = material
			var buffer: Array[float] = []
			for index: int in range(instance_transforms.size()):
				if not _valid_transform(instance_transforms[index]) \
						or not Attributes.is_finite_color(instance_colors[index]) \
						or not Attributes.is_finite_color(custom_data[index]):
					return _pending("tree_instance_attribute_invalid", {"sourceId":source_id, "role":role})
				buffer.append_array(Attributes.encode(instance_transforms[index], custom_data[index], instance_colors[index]))
			buffer.make_read_only()
			var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
				"sourceId":source_id, "sourcePartId":source_id,
				"ownerCell":owner_cell,
				"sourceToWorld":body.global_transform, "meshLocalBounds":mesh_bounds,
				"batchKey":batch_key,
				"buffer":buffer, "instanceCount":instance_transforms.size()}
			member_rows.append({"role":role, "input":input,
				"meshResourceKey":mesh_resource_key, "materialKey":material_key,
				"meshContentDigest":mesh_digest, "materialContentDigest":material_digest,
				"compatibilityKey":batch_key, "rendererTier":renderer_tier,
				"instanceCount":instance_transforms.size()})
	member_rows.make_read_only()
	compatibility_by_key.make_read_only()
	mesh_bindings.make_read_only()
	material_bindings.make_read_only()
	var inputs: Array[Dictionary] = []
	var raw_member_revision := raw_member_content_revision(members)
	if raw_member_revision.is_empty():
		return _pending("tree_raw_member_content_revision_failed", {"sourceId":source_id})
	var source_revision := source_revision_from_raw_members(world_id, seed,
		source_id, recipe_signature, tier, owner_cell, body.global_transform,
		raw_member_revision)
	if source_revision.is_empty():
		return _pending("tree_source_revision_failed", {"sourceId":source_id})
	for row_value: Variant in member_rows:
		var row: Dictionary = row_value
		var input: Dictionary = row.input.duplicate()
		input["sourceRevision"] = source_revision
		input["segmentId"] = "tree:%s:%s" % [String(row.role), source_revision]
		input.make_read_only()
		row["sourceRevision"] = source_revision
		row["input"] = input
		row.make_read_only()
	member_rows.make_read_only()
	for row: Dictionary in member_rows:
		inputs.append(row.input)
	inputs.make_read_only()
	var partition: Dictionary = {"status":"ready", "outputs":[], "inputInstanceCount":0,
		"outputInstanceCount":0, "sectionCount":0}
	if not inputs.is_empty():
		var partition_envelope: Dictionary = Partitioner.partition(inputs)
		if partition_envelope.get("status") != "ready":
			return _pending("tree_section_partition_failed", {
				"sourceId":source_id, "reason":String(partition_envelope.get("reason", "unknown"))})
		partition = partition_envelope.get("result", {})
	var section_keys: Array[Vector3i] = []
	for output_value: Variant in partition.get("outputs", []):
		var section_key := Vector3i(output_value.get("sectionKey", Vector3i.ZERO))
		if not section_keys.has(section_key): section_keys.append(section_key)
	section_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	section_keys.make_read_only()
	return {"status":"ready", "schema":SCHEMA, "worldId":world_id,
		"sourceId":source_id, "sourcePartId":source_id,
		"sourceRevision":source_revision, "producerRevision":recipe_signature,
		"rawMemberContentRevision":raw_member_revision,
		"bodyGlobalTransform":body.global_transform,
		"seed":seed,
		"ownerCell":owner_cell,
		"bodyInstanceId":body.get_instance_id(), "renderLodTier":tier,
		"memberRows":member_rows, "inputs":inputs, "partition":partition,
		"sectionKeys":section_keys, "compatibilityByKey":compatibility_by_key,
		"meshBindings":mesh_bindings, "materialBindings":material_bindings,
		"censusStatus":"pending", "censusScope":"one_published_tree",
		"collisionOwner":"tree_static_body", "gameplayOwner":"tree_prop_authority"}


static func _renderer_tier_for_role(role: String) -> String:
	# Recipe LOD (near/mid/far) changes the produced geometry and visibility;
	# renderer category is the independent native packet classification.
	return "detail" if role == "foliage" else "structural"


static func _supported_opaque_layer(material: Material, role: String) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null or shader.code.is_empty() or shader.code.contains("ALPHA") \
				or shader.code.contains("discard") or shader.code.contains("blend_"):
			return ""
		var expected_shader: Shader = FoliageShader if role == "foliage" else BranchShader
		if shader.code != expected_shader.code:
			return ""
		return "opaque"
	if material is StandardMaterial3D:
		var standard := material as StandardMaterial3D
		if standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED \
				or standard.albedo_color.a < 0.999:
			return ""
		return "opaque"
	return ""


static func _material_digest(material: Material) -> String:
	var fingerprint: Dictionary = MaterialFingerprint.inspect(material)
	return String(fingerprint.get("contentDigest", "")) \
		if String(fingerprint.get("status", "")) == "ready" else ""


static func _tombstone_revision(world_id: String, source_id: String, prop_id: String) -> String:
	return Marshalls.raw_to_base64(var_to_bytes([SCHEMA, world_id, source_id,
		prop_id, "removed"])).sha256_text()


static func _valid_transform(value: Transform3D) -> bool:
	return value.origin.is_finite() and value.basis.x.is_finite() \
		and value.basis.y.is_finite() and value.basis.z.is_finite() \
		and absf(value.basis.determinant()) > 0.000001


static func _valid_bounds(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() \
		and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0 \
		and value.end.is_finite()


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result
