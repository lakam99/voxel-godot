extends RefCounted
## Capture once, while the producer still owns the canonical closed geometry.
## Live door state remains exclusively owned by the existing controller.
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const MeshIdentity = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const MaterialIdentity = preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")

static func capture(publisher: Object, body: StaticBody3D, source_parent: Node3D,
		part_id: String, revision: String) -> Dictionary:
	var pivot := body.get_node_or_null("DoorPivot") as Node3D
	if pivot == null or not body.is_inside_tree() or not source_parent.is_ancestor_of(body):
		return _pending("door_attachment_source_missing")
	var site_id := String(publisher.publication_site_id)
	if site_id.is_empty(): site_id = String(publisher.source_blueprint_id)
	var key := "building-door:%s:%s:leaf" % [site_id, part_id]
	var anchor := {"key":"building-door:%s:%s:bundle" % [site_id,part_id], "worldPosition":body.global_position}
	anchor.make_read_only()
	var neutral := pivot.global_transform
	var motion_kind := String(body.get_meta("door_motion", "swing"))
	var motion := {"kind":motion_kind,
		"closedParentToBody":body.global_transform.affine_inverse() * neutral,
		"raiseOffset":body.get_meta("open_visual_offset", Vector3.ZERO) if motion_kind == "raise" else Vector3.ZERO,
		"swing":float(body.get_meta("open_swing", DoorGeometry.DEFAULT_OPEN_SWING)) if motion_kind == "swing" else 0.0}
	motion.make_read_only()
	var binding := {"parent":weakref(pivot), "parentInstanceId":pivot.get_instance_id(),
		"body":weakref(body), "bodyInstanceId":body.get_instance_id(),
		"bodyToWorld":body.global_transform, "neutralParentToWorld":neutral,
		"sourceRevision":revision, "publisherInstanceId":publisher.get_instance_id(),
		"publicationEpoch":int(publisher.get("_publication_epoch")) + 1, "motion":motion}
	var legacy_visuals: Array[WeakRef] = []
	var groups: Array[Dictionary] = []
	var visual_proofs: Array[Dictionary] = []
	var stack: Array[Node] = [body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children(): stack.append(child)
		if not node is GeometryInstance3D: continue
		var visual := node as GeometryInstance3D
		# Capture source policy before section suppression. Do not use
		# is_visible_in_tree(): loading/scenario ancestors may be gated externally.
		var intended_visible := true
		var visibility_owner: Node = visual
		while visibility_owner != source_parent and visibility_owner != null:
			if visibility_owner is Node3D and not (visibility_owner as Node3D).visible:
				intended_visible = false
			visibility_owner = visibility_owner.get_parent()
		legacy_visuals.append(weakref(visual))
		visual.set_meta("building_source_part_id", part_id)
		if not visual is MeshInstance3D and not visual is MultiMeshInstance3D:
			return _pending("door_attachment_unknown_geometry")
		var moving := pivot.is_ancestor_of(visual)
		var visual_binding_parent: Node3D = pivot if moving else body
		var local_to_binding := visual_binding_parent.global_transform.affine_inverse() * visual.global_transform
		var source_transform := source_parent.global_transform.affine_inverse() * visual.global_transform
		var mesh: Mesh
		var count := 1
		var multi: MultiMesh
		if visual is MultiMeshInstance3D:
			multi = (visual as MultiMeshInstance3D).multimesh
			if multi == null or multi.visible_instance_count not in [-1, multi.instance_count]:
				return _pending("door_attachment_partial_multimesh")
			mesh = multi.mesh
			count = multi.instance_count
		else: mesh = (visual as MeshInstance3D).mesh
		var material := visual.material_override
		if mesh == null or material == null or count <= 0:
			return _pending("door_attachment_geometry_resources_missing")
		var mesh_identity := MeshIdentity.inspect(mesh)
		var material_identity := MaterialIdentity._material_identity(material)
		var layer: Dictionary = publisher.static_visual_layer_policy(material)
		if mesh_identity.get("status") != "ready" or material_identity.is_empty() or layer.get("status") != "ready":
			return _pending("door_attachment_resource_identity_missing")
		var material_key: String = publisher.stable_static_material_key(material)
		if material_key.is_empty(): return _pending("door_attachment_material_key_missing")
		# Source construction order is deterministic. Godot's auto-generated
		# duplicate node names and ObjectIDs are deliberately absent from geometry identity.
		var visual_id := "geometry:%d" % groups.size()
		var segments: Array[Dictionary] = []
		var bounds := AABB()
		var pivot_bounds := AABB()
		for first in range(0, count, 256):
			var buffer: Array[float] = []
			var segment_bounds := AABB()
			var segment_count := mini(256, count-first)
			for index in range(first, first+segment_count):
				var transform := multi.get_instance_transform(index) if multi != null else Transform3D.IDENTITY
				var custom := multi.get_instance_custom_data(index) if multi != null and multi.use_custom_data else Color(0,0,0,0)
				var color := multi.get_instance_color(index) if multi != null and multi.use_colors else Color.WHITE
				buffer.append_array(Attributes.encode(source_transform * transform, custom, color))
				var instance_bounds: AABB = source_transform * transform * mesh.get_aabb()
				segment_bounds = instance_bounds if index == first else segment_bounds.merge(instance_bounds)
				var local_bounds: AABB = local_to_binding * transform * mesh.get_aabb()
				pivot_bounds = local_bounds if index == 0 else pivot_bounds.merge(local_bounds)
			buffer.make_read_only()
			var segment_id := "door:%s:%d" % [visual_id, first]
			var segment := {"segmentId":segment_id, "bounds":segment_bounds,
				"instanceCount":segment_count, "buffer":buffer,
				"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
				"contentDigest":_digest([segment_id, segment_count, segment_bounds, buffer])}
			segment.make_read_only()
			segments.append(segment)
			bounds = segment_bounds if first == 0 else bounds.merge(segment_bounds)
		segments.make_read_only()
		var resources := {"mesh":mesh, "material":material}
		resources.make_read_only()
		var world_bounds := source_parent.global_transform * bounds
		var owner := Grid.chunk_key_for_section(Grid.key_for_world_position(body.global_position))
		var group := {"schema":"building-static-transform-section-artifact/v1",
			"sourcePartId":part_id, "sourceRevision":revision, "ownerCell":owner,
			"renderChunkKey":owner, "materialKey":material_key,
			"materialContentDigest":String(material_identity.digest),
			"meshKey":"building-mesh:" + String(mesh_identity.contentDigest),
			"meshContentDigest":String(mesh_identity.contentDigest), "renderTier":"structural",
			"renderLayer":String(layer.renderLayer), "transparencySortPolicy":String(layer.transparencySortPolicy),
			"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA, "sourceToWorld":source_parent.global_transform,
			"localBounds":bounds, "worldBounds":world_bounds, "instanceCount":count,
			"segments":segments, "resourceBindings":resources, "compoundAnchor":anchor,
			"intendedVisible":intended_visible}
		if moving:
			group["attachmentKey"] = key
			group["neutralParentToWorld"] = neutral
			group["sweptWorldBounds"] = swept_bounds(pivot_bounds, neutral, body)
			group["attachmentBinding"] = binding
			group["motion"] = motion
		var content := content_digest(group)
		group["contentDigest"] = content
		group["sourceId"] = "building-transform:%s:%s:%s" % [site_id,part_id,content.substr(0,24)]
		group.make_read_only()
		groups.append(group)
		var proof := {"visual":weakref(visual), "instanceId":visual.get_instance_id(),
			"parent":weakref(visual_binding_parent), "localToParent":local_to_binding,
			"mesh":mesh, "material":material, "group":group,
			"instanceBufferDigest":_digest(multi.buffer) if multi != null else ""}
		proof.make_read_only()
		visual_proofs.append(proof)
	if groups.is_empty(): return _pending("door_attachment_empty_geometry")
	legacy_visuals.make_read_only()
	binding["legacyVisuals"] = legacy_visuals
	# A moving compound door has one attachment key even when its visual is split
	# across several meshes, materials or render layers. Every batch for that key
	# must therefore carry the same complete swept envelope and binding. Build the
	# envelope from all moving groups before sealing their content identities.
	var shared_swept_bounds := AABB()
	var has_moving_group := false
	for group_value: Dictionary in groups:
		if String(group_value.get("attachmentKey", "")) != key: continue
		var group_bounds: Variant = group_value.get("sweptWorldBounds", null)
		if not group_bounds is AABB or not group_bounds.position.is_finite() \
				or not group_bounds.end.is_finite() or group_bounds.size.x <= 0.0 \
				or group_bounds.size.y <= 0.0 or group_bounds.size.z <= 0.0:
			return _pending("door_attachment_group_sweep_invalid")
		shared_swept_bounds = group_bounds if not has_moving_group \
			else shared_swept_bounds.merge(group_bounds)
		has_moving_group = true
	if has_moving_group:
		binding["sweptWorldBounds"] = shared_swept_bounds
		binding.make_read_only()
		var revised_groups: Array[Dictionary] = []
		var revised_by_source_id: Dictionary = {}
		for group_value: Dictionary in groups:
			var group: Dictionary = group_value
			if String(group.get("attachmentKey", "")) == key:
				var revised: Dictionary = group.duplicate(false)
				revised["sweptWorldBounds"] = shared_swept_bounds
				revised["attachmentBinding"] = binding
				revised["contentDigest"] = content_digest(revised)
				var content := String(revised.get("contentDigest", ""))
				if content.length() != 64:
					return _pending("door_attachment_shared_content_digest_failed")
				var source_id := "building-transform:%s:%s:%s" % [site_id,
					part_id, content.substr(0, 24)]
				revised["sourceId"] = source_id
				revised.make_read_only()
				revised_by_source_id[String(group.sourceId)] = revised
				group = revised
			revised_groups.append(group)
		groups = revised_groups
		var revised_proofs: Array[Dictionary] = []
		for proof_value: Dictionary in visual_proofs:
			var revised_proof: Dictionary = proof_value.duplicate(false)
			var old_group: Dictionary = proof_value.get("group", {})
			var replacement: Variant = revised_by_source_id.get(
				String(old_group.get("sourceId", "")), null)
			if replacement is Dictionary:
				revised_proof["group"] = replacement
			revised_proof.make_read_only()
			revised_proofs.append(revised_proof)
		visual_proofs = revised_proofs
	else:
		binding.make_read_only()
	groups.make_read_only()
	visual_proofs.make_read_only()
	return {"status":"ready", "groups":groups, "proofs":visual_proofs,
		"binding":binding, "body":weakref(body), "partId":part_id, "revision":revision}

static func swept_bounds(bounds: AABB, neutral: Transform3D, body: Node3D) -> AABB:
	var record: Dictionary = body.get_meta("building_part_record", {})
	var size: Vector3 = record.get("size", Vector3.ZERO)
	var result := neutral * bounds
	if String(body.get_meta("door_motion", "swing")) == "raise":
		for swept: AABB in DoorGeometry.portcullis_sweep_bounds(size, body.global_transform):
			result = result.merge(swept)
	else:
		for row: Dictionary in DoorGeometry.ordinary_sweep_bounds(size, body.global_transform,
				float(body.get_meta("open_swing", DoorGeometry.DEFAULT_OPEN_SWING))):
			result = result.merge(row.bounds)
	return result

static func is_current(capture: Dictionary) -> bool:
	if capture.get("status") != "ready": return false
	var binding: Dictionary = capture.binding
	var body: Node3D = binding.body.get_ref() as Node3D
	var pivot: Node3D = binding.parent.get_ref() as Node3D
	if not is_instance_valid(body) or not is_instance_valid(pivot) \
			or body.is_queued_for_deletion() or pivot.is_queued_for_deletion() \
			or not body.is_inside_tree() or not body.is_ancestor_of(pivot) \
			or body.global_transform != binding.bodyToWorld:
		return false
	if not motion_is_current(binding): return false
	var expected: Dictionary = {}
	for proof: Dictionary in capture.proofs:
		var visual: GeometryInstance3D = proof.visual.get_ref() as GeometryInstance3D
		var parent: Node3D = proof.parent.get_ref() as Node3D
		if not is_instance_valid(visual) or not is_instance_valid(parent) \
				or visual.is_queued_for_deletion() or not parent.is_ancestor_of(visual) \
				or visual.get_instance_id() != int(proof.instanceId) \
				or not (parent.global_transform.affine_inverse() * visual.global_transform).is_equal_approx(proof.localToParent) \
				or visual.material_override != proof.material:
			return false
		if visual is MultiMeshInstance3D:
			var multi := (visual as MultiMeshInstance3D).multimesh
			if multi == null or multi.mesh != proof.mesh or _digest(multi.buffer) != proof.instanceBufferDigest:
				return false
		elif visual is MeshInstance3D:
			if (visual as MeshInstance3D).mesh != proof.mesh: return false
		else: return false
		expected[visual.get_instance_id()] = true
	var stack: Array[Node] = [body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		# Native renderer owns roots marked at registration. Their identity is
		# independently validated by packet receipts, never admitted as legacy.
		if node != body and bool(node.get_meta("section_attachment_native_root", false)): continue
		if node is GeometryInstance3D and not expected.has(node.get_instance_id()): return false
		for child: Node in node.get_children(): stack.append(child)
	return true

static func motion_is_current(binding: Dictionary) -> bool:
	var motion: Dictionary = binding.get("motion", {})
	var body: Node3D = binding.body.get_ref() as Node3D
	var pivot: Node3D = binding.parent.get_ref() as Node3D
	if not is_instance_valid(body) or not is_instance_valid(pivot) \
			or not motion.get("closedParentToBody") is Transform3D \
			or not motion.get("raiseOffset") is Vector3: return false
	var actual := body.global_transform.affine_inverse() * pivot.global_transform
	var closed: Transform3D = motion.closedParentToBody
	if not actual.is_finite() or not closed.is_finite(): return false
	if motion.kind == "raise":
		var offset: Vector3 = motion.raiseOffset
		if offset.length_squared() <= 0.000001: return false
		var amount := (actual.origin - closed.origin).dot(offset) / offset.length_squared()
		return amount >= -0.00001 and amount <= 1.00001 \
			and actual.origin.is_equal_approx(closed.origin + offset * amount) \
			and actual.basis.is_equal_approx(closed.basis)
	if motion.kind != "swing" or not is_finite(float(motion.swing)): return false
	var rotation := closed.basis.inverse() * actual.basis
	var angle := atan2(-rotation.x.z, rotation.x.x)
	return absf(float(motion.swing)) <= PI and angle >= minf(0.0, motion.swing) - 0.00001 \
		and angle <= maxf(0.0, motion.swing) + 0.00001 \
		and rotation.is_equal_approx(Basis(Vector3.UP, angle)) \
		and actual.origin.is_equal_approx(closed.origin)

static func content_digest(group: Dictionary) -> String:
	var payload: Array = [group.sourcePartId,group.sourceRevision,group.ownerCell,group.renderChunkKey,
		group.materialKey,group.renderTier,group.renderLayer,group.transparencySortPolicy,
		group.meshContentDigest,group.materialContentDigest,group.sourceToWorld,group.instanceCount]
	if group.has("intendedVisible"): payload.append(group.intendedVisible)
	if not String(group.get("attachmentKey", "")).is_empty():
		payload.append([group.attachmentKey,group.neutralParentToWorld,group.sweptWorldBounds,group.motion])
	var hash := HashingContext.new()
	if group.has("compoundAnchor"): payload.append(group.compoundAnchor)
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(payload))
	for segment: Dictionary in group.segments:
		hash.update(var_to_bytes([segment.segmentId,segment.bounds,segment.instanceCount,segment.contentDigest]))
	return hash.finish().hex_encode()

static func _digest(value: Variant) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(value))
	return hash.finish().hex_encode()

static func _pending(reason: String) -> Dictionary:
	return {"status":"pending", "reason":reason, "retryable":true}
