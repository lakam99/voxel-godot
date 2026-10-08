extends RefCounted
class_name FurnishingPublisher

## Publishes one collision body per furnishing record. Fine visual pieces are
## intentionally children of that record: a chair's legs or a bed's pillows
## never become separate collision, save, or placement authorities.

const Recipe = preload("res://scripts/buildings/FurnishingVisualRecipe.gd")
const Binding = preload("res://scripts/buildings/BuildingSourceRecordBinding.gd")
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const GeometryAdapter = preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const SectionAdapter = preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
var publication_site_id := ""
var source_blueprint_id := ""
var _scene_parent: WeakRef
var _sources: Dictionary = {}
var _publication_epoch := 0
var published_nodes: Array:
	get: return published_parts

const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")

var unit_box: BoxMesh
var unit_cylinder: CylinderMesh
var unit_sphere: SphereMesh
var material_cache: Dictionary = {}
var published_parts: Array = []
var _section_lifetime_owner: WeakRef
var collision_count := 0
var visual_piece_count := 0
var publication_usec := 0
var active_publication_started_usec := 0


func _init() -> void:
	unit_box = BoxMesh.new()
	unit_box.size = Vector3.ONE
	unit_cylinder = CylinderMesh.new()
	unit_cylinder.top_radius = 0.5
	unit_cylinder.bottom_radius = 0.5
	unit_cylinder.height = 1.0
	unit_cylinder.radial_segments = 8
	unit_sphere = SphereMesh.new()
	unit_sphere.radius = 0.5
	unit_sphere.height = 1.0
	unit_sphere.radial_segments = 8
	unit_sphere.rings = 4


func publish(plan, parent: Node3D) -> Dictionary:
	if not begin_publication(plan, parent):
		return summary()
	publish_part_batch(plan, parent, 0, plan.parts.size())
	return finish_publication(plan, parent)


func publish_incremental(plan, parent: Node3D, parts_per_frame := 5) -> Dictionary:
	# Matches publish() exactly, but yields between bounded record batches. A
	# loading UI can therefore continue presenting frames while real furnishing
	# visuals and their collision bodies publish from the shared plan.
	if not begin_publication(plan, parent):
		return summary()
	var frame_budget := maxi(1, parts_per_frame)
	var part_index := 0
	while part_index < plan.parts.size():
		part_index = publish_part_batch(plan, parent, part_index, frame_budget)
		if part_index < plan.parts.size():
			await parent.get_tree().process_frame
	return finish_publication(plan, parent)


func begin_publication(plan, parent: Node3D) -> bool:
	if _has_retained_section_sources(): return false
	clear_published()
	if plan == null or parent == null:
		return false
	if source_blueprint_id.is_empty():
		source_blueprint_id = String(plan.id)
	_scene_parent = weakref(parent)
	active_publication_started_usec = Time.get_ticks_usec()
	return true


func publish_part_batch(plan, parent: Node3D, start_index: int, max_parts: int) -> int:
	if plan == null or parent == null:
		return start_index
	var part_index := clampi(start_index, 0, plan.parts.size())
	var processed := 0
	while part_index < plan.parts.size() and processed < maxi(1, max_parts):
		var part = plan.parts[part_index]
		part_index += 1
		processed += 1
		if part != null:
			publish_part(part, parent)
	return part_index


func finish_publication(plan, parent: Node3D) -> Dictionary:
	if plan == null or parent == null:
		return summary()
	publication_usec = Time.get_ticks_usec() - active_publication_started_usec if active_publication_started_usec > 0 else 0
	active_publication_started_usec = 0
	return summary()


func clear_published() -> void:
	if _has_retained_section_sources(): return
	for node in published_parts:
		if node != null and is_instance_valid(node):
			node.queue_free()
	published_parts.clear()
	_sources.clear()
	collision_count = 0
	visual_piece_count = 0
	publication_usec = 0
	active_publication_started_usec = 0


func bind_section_lifetime_owner(owner: Object) -> void:
	_section_lifetime_owner = weakref(owner)


func _has_retained_section_sources() -> bool:
	if _section_lifetime_owner == null: return false
	var owner: Variant = _section_lifetime_owner.get_ref()
	# Losing an admitted lifetime owner cannot grant permission to clear its
	# source bodies. The scene job still owns the normal retirement path.
	return not is_instance_valid(owner) or bool(owner.call("furnishing_publisher_has_retained_sources", get_instance_id()))


func publish_part(part, parent: Node3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Furnishing_%s" % String(part.id)
	body.position = part.position
	body.rotation = part.rotation
	body.set_meta("furnishing_part_id", part.id)
	body.set_meta("furnishing_room_id", part.room_id)
	body.set_meta("furnishing_archetype", part.archetype)
	body.set_meta("furnishing_material", part.material_id)
	body.set_meta("furnishing_semantic", part.semantic)
	body.set_meta("furnishing_part_record", part.snapshot())
	parent.add_child(body)
	published_parts.append(body)
	if part.collision_enabled:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = part.occupied_size
		collision.shape = shape
		collision.position = Vector3(0.0, part.occupied_size.y * 0.5, 0.0)
		body.add_child(collision)
		collision_count += 1
	_scene_parent = weakref(parent)
	_publication_epoch += 1
	publish_visual(part, body)
	_seal_source(part, body, parent)
	return body


func publish_visual(part, parent: Node3D) -> void:
	var recipe: Dictionary = Recipe.build(part)
	for piece: Dictionary in recipe.pieces:
		var visual := MeshInstance3D.new()
		visual.name = piece.name
		visual.mesh = {"box":unit_box,"cylinder":unit_cylinder,"sphere":unit_sphere}[piece.primitive]
		visual.transform = piece.transform
		visual.material_override = material_for(piece.materialId,part)
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		visual.set_meta("section_source_member_id","furnishing:"+String(part.id))
		visual.set_meta("building_source_part_id",String(part.id))
		parent.add_child(visual)
		visual_piece_count += 1
	for value: Dictionary in recipe.lights:
		var mount := Node3D.new()
		mount.name = "FurnishingPracticalLightMount"
		mount.position = value.position
		parent.add_child(mount)
		var light := OmniLight3D.new()
		light.light_color = value.color
		light.light_energy = value.energy
		light.omni_range = value.range
		light.shadow_enabled = false
		mount.add_child(light)


func _seal_source(part, body: StaticBody3D, parent: Node3D) -> void:
	var id := String(part.id)
	var revision := Binding.encode(part.snapshot())
	var groups: Array[Dictionary] = []
	var mounts: Array[Dictionary] = []
	var bindings: Dictionary = {}
	var site := publication_site_id if not publication_site_id.is_empty() else source_blueprint_id
	body.set_meta("section_source_member_id","furnishing:"+id)
	body.set_meta("section_attachment_source_revision",revision)
	body.set_meta("section_attachment_publication_epoch",_publication_epoch)
	body.set_meta("section_attachment_publisher_instance_id",get_instance_id())
	for child: Node in body.get_children():
		if child is MeshInstance3D:
			var visual := child as MeshInstance3D
			var transform := body.transform * visual.transform
			var local_bounds := transform * visual.mesh.get_aabb()
			var values: Array[float] = []
			values.assign(Attributes.encode(transform,Color(0,0,0,0)))
			values.make_read_only()
			var segment := {"segmentId":"segment:000000","instanceCount":1,
				"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,"bounds":local_bounds,"buffer":values}
			segment["contentDigest"] = _digest([segment.segmentId,1,local_bounds,values])
			segment.make_read_only()
			var segments: Array[Dictionary] = [segment]
			segments.make_read_only()
			var mesh_identity: Dictionary = MeshFingerprint.inspect(visual.mesh)
			var material_identity: Dictionary = GeometryAdapter._material_identity(visual.material_override)
			var resources := {"mesh":visual.mesh,"material":visual.material_override}
			resources.make_read_only()
			var layer := "opaque"
			var sort_policy := "none"
			if visual.material_override is BaseMaterial3D:
				var transparency := (visual.material_override as BaseMaterial3D).transparency
				if transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
					layer = "cutout"
				elif transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					layer = "translucent"
					sort_policy = "camera_depth"
			var cell := Vector2i(floori(body.global_position.x/43.2),floori(body.global_position.z/43.2))
			var group := {"schema":"building-static-transform-section-artifact/v1",
				"sourcePartId":id,"sourceRevision":revision,"ownerCell":cell,"renderChunkKey":cell,
				"renderTier":"detail","materialKey":_material_key(visual.material_override),
				"renderLayer":layer,"transparencySortPolicy":sort_policy,
				"materialContentDigest":String(material_identity.get("digest","")),
				"meshKey":"building-mesh:"+String(mesh_identity.get("contentDigest","")),
				"meshContentDigest":String(mesh_identity.get("contentDigest","")),
				"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,"localBounds":local_bounds,
				"worldBounds":parent.global_transform*local_bounds,"sourceToWorld":parent.global_transform,
				"instanceCount":1,"segments":segments,"resourceBindings":resources}
			group["contentDigest"] = SectionAdapter._transform_artifact_content_digest(group)
			group["sourceId"] = "furnishing-transform:%s:%s:%s" % [site,id,String(group.contentDigest).substr(0,24)]
			group.make_read_only()
			groups.append(group)
		elif child is Node3D and child.get_child_count()==1 and child.get_child(0) is OmniLight3D:
			var mount := child as Node3D
			var light := mount.get_child(0) as OmniLight3D
			var key := "furnishing-practical-light:%s:%s" % [site,id]
			var member_id := "furnishing-light:%s:%s" % [site,id]
			mount.set_meta("section_attachment_presentation_member_id",member_id)
			var motion := {"kind":"static","closedParentToBody":Transform3D.IDENTITY,"raiseOffset":Vector3.ZERO,"swing":0.0}
			motion.make_read_only()
			var bounds := AABB(light.global_position-Vector3.ONE*light.omni_range,Vector3.ONE*light.omni_range*2.0)
			var row := {"sourcePartId":id,"sourceRevision":revision,"producerSourceRevision":revision,
				"presentationMemberId":member_id,"attachmentKey":key,"ownershipKind":"borrowed_presentation",
				"intendedVisible":true,"neutralParentToWorld":body.global_transform,"sweptWorldBounds":bounds,"motion":motion}
			row.make_read_only()
			mounts.append(row)
			var empty: Array = []
			empty.make_read_only()
			var binding := row.duplicate(false)
			binding.merge({"mount":weakref(mount),"mountInstanceId":mount.get_instance_id(),
				"parent":weakref(body),"parentInstanceId":body.get_instance_id(),"body":weakref(body),
				"bodyInstanceId":body.get_instance_id(),"mountLocalTransform":mount.transform,
				"bodyToWorld":body.global_transform,"legacyVisuals":empty,"publisherInstanceId":get_instance_id(),
				"publicationEpoch":_publication_epoch,"light":weakref(light),"lightInstanceId":light.get_instance_id(),
				"lightEnergy":light.light_energy,"lightRange":light.omni_range,
				"lightColor":light.light_color,"shadowEnabled":light.shadow_enabled})
			binding.make_read_only()
			bindings[key] = binding
	groups.make_read_only()
	mounts.make_read_only()
	bindings.make_read_only()
	var source := {"body":weakref(body),"parent":weakref(parent),"bodyTransform":body.transform,
		"sourceToWorld":parent.global_transform,"revision":revision,"epoch":_publication_epoch,
		"groups":groups,"mounts":mounts,"bindings":bindings,
		"bodyInstanceId":body.get_instance_id(),"parentInstanceId":parent.get_instance_id()}
	source.make_read_only()
	_sources[id] = source


func _material_key(material: Material) -> String:
	for key: String in material_cache:
		if material_cache[key]==material: return key
	return ""


static func _digest(value: Variant) -> String:
	var hash := HashingContext.new()
	if hash.start(HashingContext.HASH_SHA256)!=OK or hash.update(var_to_bytes(value))!=OK: return ""
	return hash.finish().hex_encode()


func has_pending_static_flush() -> bool:
	return false


func source_part_publication_epoch(id: String) -> int:
	return int(_sources.get(id,{}).get("epoch",0))


func committed_static_visual_source_identity(id: String) -> Dictionary:
	var source: Dictionary = _sources.get(id,{})
	if source.is_empty(): return _pending("furnishing_source_unavailable")
	if id.is_empty() or String(source.revision).is_empty() or (publication_site_id.is_empty() and source_blueprint_id.is_empty()):
		return _pending("furnishing_source_identity_missing")
	var body_value: Variant = source.body.get_ref()
	var parent_value: Variant = source.parent.get_ref()
	if not is_instance_valid(body_value) or not is_instance_valid(parent_value):
		return _pending("furnishing_source_owner_gone")
	var body := body_value as Node3D
	var parent := parent_value as Node3D
	if body == null or parent == null or body.is_queued_for_deletion() \
			or parent.is_queued_for_deletion() or not body.is_inside_tree() or body.get_parent()!=parent \
			or body.get_instance_id()!=source.bodyInstanceId or parent.get_instance_id()!=source.parentInstanceId \
			or body.transform!=source.bodyTransform or parent.global_transform!=source.sourceToWorld \
			or Binding.encode(body.get_meta("furnishing_part_record",{}))!=source.revision \
			or int(body.get_meta("section_attachment_publisher_instance_id",0))!=get_instance_id() \
			or String(body.get_meta("section_attachment_source_revision",""))!=source.revision \
			or int(body.get_meta("section_attachment_publication_epoch",-1))!=source.epoch:
		return _pending("furnishing_source_owner_stale")
	var result := {"status":"ready","sourcePartId":id,"sourceRevision":source.revision,
		"publicationEpoch":source.epoch,"publisherInstanceId":get_instance_id(),
		"parentInstanceId":parent.get_instance_id(),"bodyInstanceId":body.get_instance_id(),
		"siteId":publication_site_id,"sourceBlueprintId":source_blueprint_id,"sourceToWorld":source.sourceToWorld}
	result.make_read_only()
	return result


func capture_static_section_transform_artifacts(id: String, revision: String) -> Dictionary:
	var identity := committed_static_visual_source_identity(id)
	if identity.get("status")!="ready": return identity
	if identity.sourceRevision!=revision: return _pending("furnishing_source_revision_stale")
	var source: Dictionary = _sources[id]
	for group: Dictionary in source.groups:
		var resources: Dictionary = group.resourceBindings
		if String(MeshFingerprint.inspect(resources.mesh).get("contentDigest",""))!=group.meshContentDigest \
				or String(GeometryAdapter._material_identity(resources.material).get("digest",""))!=group.materialContentDigest:
			return _pending("furnishing_source_resource_stale")
	for binding: Dictionary in source.bindings.values():
		var mount_value: Variant = binding.mount.get_ref()
		var light_value: Variant = binding.light.get_ref()
		var body_value: Variant = source.body.get_ref()
		if not is_instance_valid(mount_value) or not is_instance_valid(light_value) or not is_instance_valid(body_value):
			return _pending("furnishing_light_owner_gone")
		var mount := mount_value as Node3D
		var light := light_value as OmniLight3D
		var body := body_value as Node3D
		if mount == null or light == null or body == null \
				or mount.is_queued_for_deletion() or light.is_queued_for_deletion() \
				or mount.get_parent()!=body or light.get_parent()!=mount \
				or mount.transform!=binding.mountLocalTransform or light.transform!=Transform3D.IDENTITY \
				or light.light_color!=binding.lightColor or light.light_energy!=binding.lightEnergy \
				or light.omni_range!=binding.lightRange or light.shadow_enabled!=binding.shadowEnabled:
			return _pending("furnishing_light_source_stale")
	return {"status":"ready","sourcePartId":id,"sourceRevision":revision,"groups":source.groups,
		"groupCount":source.groups.size(),"presentationMounts":source.mounts,"presentationBindings":source.bindings,
		"presentationDigest":_digest(["building-practical-light-presentation/v1",source.mounts])}


func capture_committed_static_visual_source(id: String, revision: String) -> Dictionary:
	var identity := committed_static_visual_source_identity(id)
	if identity.get("status")!="ready": return identity
	var capture := capture_static_section_transform_artifacts(id,revision)
	if capture.get("status")!="ready": return capture
	if identity!=committed_static_visual_source_identity(id): return _pending("furnishing_source_changed")
	capture["visualSourceReceipt"] = identity
	capture.make_read_only()
	return capture


static func _pending(reason: String) -> Dictionary:
	return {"status":"pending","reason":reason,"retryable":true}


func material_for(material_id: String, part) -> Material:
	var variation := float(part.recipe.get("variation", 0.0))
	var key := "%s:%0.3f" % [material_id, variation]
	if material_cache.has(key):
		return material_cache[key] as Material
	var material: Material = ConstructionMaterialCatalogScript.create_material(material_id, variation)
	material_cache[key] = material
	return material


func summary() -> Dictionary:
	return {
		"publishedPartCount": published_parts.size(),
		"collisionPartCount": collision_count,
		"visualPieceCount": visual_piece_count,
		"publicationUsec": publication_usec
	}
