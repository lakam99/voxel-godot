extends Node3D
class_name HorizonEcologyTreeBatch

## Temporary visual-only silhouettes for the exact trees already selected by
## the chunk's seeded prop producer. The bodies keep collision, interaction,
## IDs, and recipe ownership; this node only batches their waiting visuals.
const PAGE_CAPACITY := 32
const PUBLISHER_META := "horizon_visual_publisher"

var _factory: ProceduralTreeVisualFactory
var _chunk: WeakRef
var _chunk_instance_id := 0
var _groups := {}
var _records := {}


func configure(chunk: Node3D, factory: ProceduralTreeVisualFactory) -> void:
	_chunk = weakref(chunk) if is_instance_valid(chunk) else null
	_chunk_instance_id = chunk.get_instance_id() if is_instance_valid(chunk) else 0
	_factory = factory


func add_tree(body: StaticBody3D, request: Dictionary) -> bool:
	if not _valid_body(body) or _factory == null or _factory.is_headless_renderer():
		return false
	var prop_id := String(body.get_meta("prop_id", ""))
	var architecture := String(request.get("architecture", ""))
	var biome := String(request.get("biome", ""))
	var height := float(request.get("visualHeight", 0.0))
	var crown_radius := float(request.get("canopyRadius", 0.0))
	var canopy_density := float(request.get("canopyDensity", 0.78))
	var trunk_radius := float(request.get("trunkRadius", 0.0))
	var visibility_range := float((request.get("biomeParameters", {}) as Dictionary).get("visibilityRange", 0.0))
	if prop_id.is_empty() or architecture.is_empty() or biome.is_empty() \
			or not is_finite(height) or not is_finite(crown_radius) or not is_finite(canopy_density) \
			or not is_finite(trunk_radius) \
			or not is_finite(visibility_range) or height <= 0.0 or crown_radius <= 0.0 \
			or trunk_radius <= 0.0 or visibility_range <= 0.0:
		return false
	var body_id := body.get_instance_id()
	if _records.has(body_id):
		return installed_snapshot(body).get("status") == "ready"
	var group_key := "%s:%s:%s" % [architecture, biome, String.num(visibility_range, 4)]
	var pages: Array = _groups.get(group_key, [])
	var page_index := -1
	for index in range(pages.size()):
		var candidate_page: Dictionary = pages[index]
		if int(candidate_page.get("nextSlot", PAGE_CAPACITY)) < PAGE_CAPACITY \
				or not (candidate_page.get("freeSlots", []) as Array).is_empty():
			page_index = index
			break
	var page: Dictionary = pages[page_index] if page_index >= 0 else {}
	if page.is_empty():
		page = _create_page(architecture, biome, visibility_range, pages.size())
		if page.is_empty():
			return false
		pages.append(page)
		page_index = pages.size() - 1
	var free_slots: Array = page.freeSlots
	var slot := int(free_slots.pop_back()) if not free_slots.is_empty() else int(page.nextSlot)
	page.freeSlots = free_slots
	var world_to_batch := global_transform.affine_inverse() * body.global_transform
	var transforms := _tree_transforms(world_to_batch, architecture, height,
		crown_radius, trunk_radius, canopy_density)
	var meshes: Array = page.meshes
	for index in range(3):
		(meshes[index] as MultiMesh).set_instance_transform(slot, transforms[index])
		(meshes[index] as MultiMesh).visible_instance_count = maxi(
			(meshes[index] as MultiMesh).visible_instance_count, slot + 1)
		(page.instances[index] as MultiMeshInstance3D).visible = true
	page.nextSlot = maxi(int(page.nextSlot), slot + 1)
	page.liveCount = int(page.liveCount) + 1
	pages[page_index] = page
	_groups[group_key] = pages
	_records[body_id] = {"body": weakref(body), "bodyInstanceId": body_id,
		"propId": prop_id, "chunkInstanceId": _chunk_instance_id,
		"groupKey": group_key, "pageIndex": page_index, "slot": slot,
		"bodyGlobalTransform": body.global_transform,
		"batchGlobalTransform": global_transform,
		"visibilityRange": visibility_range,
		"transforms": transforms, "batchInstanceId": get_instance_id(),
		"meshInstanceIds": _instance_ids(page.instances),
		"multimeshIds": _instance_ids(meshes),
		"meshResourceIds": _mesh_ids(meshes),
		"materialIds": _material_ids(page.instances)}
	body.set_meta(PUBLISHER_META, self)
	body.tree_exiting.connect(_body_exiting.bind(body_id), CONNECT_ONE_SHOT)
	return true


func installed_snapshot(body: StaticBody3D) -> Dictionary:
	if not _valid_body(body):
		return {"status": "pending", "reason": "horizon_tree_body_not_live"}
	var record: Dictionary = _records.get(body.get_instance_id(), {})
	if record.is_empty() or not _record_installed(record):
		return {"status": "pending", "reason": "horizon_tree_slot_not_installed"}
	return {"status": "ready", "bodyInstanceId": int(record.bodyInstanceId),
		"chunkInstanceId": int(record.chunkInstanceId), "propId": String(record.propId),
		"batchInstanceId": int(record.batchInstanceId),
		"groupKey": String(record.groupKey), "pageIndex": int(record.pageIndex),
		"slot": int(record.slot), "bodyGlobalTransform": record.bodyGlobalTransform,
		"batchGlobalTransform": record.batchGlobalTransform,
		"visibilityRange": float(record.visibilityRange),
		"instanceTransforms": (record.transforms as Array).duplicate(),
		"meshInstanceIds": (record.meshInstanceIds as Array).duplicate(),
		"multimeshIds": (record.multimeshIds as Array).duplicate(),
		"meshResourceIds": (record.meshResourceIds as Array).duplicate(),
		"materialIds": (record.materialIds as Array).duplicate()}


func visual_receipt_installed(_source_identity: String, _source_revision: String,
		_world_revision: String, _view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, tier: String) -> bool:
	if tier != "horizon" or representation_id != "%s:horizon" % candidate_id:
		return false
	var body_id := int(metadata.get("horizonBodyInstanceId", 0))
	var record: Dictionary = _records.get(body_id, {})
	if record.is_empty() or String(record.propId) != candidate_id \
			or int(record.chunkInstanceId) != int(metadata.get("horizonChunkInstanceId", 0)) \
			or int(record.batchInstanceId) != int(metadata.get("horizonBatchInstanceId", 0)) \
			or String(record.groupKey) != String(metadata.get("horizonGroupKey", "")) \
			or int(record.pageIndex) != int(metadata.get("horizonPageIndex", -1)) \
			or int(record.slot) != int(metadata.get("horizonSlot", -1)) \
			or record.bodyGlobalTransform != metadata.get("horizonBodyGlobalTransform") \
			or record.batchGlobalTransform != metadata.get("horizonBatchGlobalTransform") \
			or not is_equal_approx(float(record.visibilityRange),
				float(metadata.get("horizonVisibilityRange", -1.0))) \
			or record.transforms != metadata.get("horizonInstanceTransforms") \
			or record.meshInstanceIds != metadata.get("horizonMeshInstanceIds") \
			or record.multimeshIds != metadata.get("horizonMultimeshIds") \
			or record.meshResourceIds != metadata.get("horizonMeshResourceIds") \
			or record.materialIds != metadata.get("horizonMaterialIds"):
		return false
	return _record_installed(record)


func release_tree(body: StaticBody3D) -> void:
	if not is_instance_valid(body):
		return
	_release_body_id(body.get_instance_id())
	if body.has_meta(PUBLISHER_META) and body.get_meta(PUBLISHER_META) == self:
		body.remove_meta(PUBLISHER_META)


func _body_exiting(body_id: int) -> void:
	_release_body_id(body_id)


func _release_body_id(body_id: int) -> void:
	var record: Dictionary = _records.get(body_id, {})
	if record.is_empty():
		return
	var pages: Array = _groups.get(String(record.groupKey), [])
	var page_index := int(record.pageIndex)
	if page_index >= 0 and page_index < pages.size():
		var page: Dictionary = pages[page_index]
		var slot := int(record.slot)
		if slot >= 0 and slot < PAGE_CAPACITY:
			for mesh_value in page.meshes:
				var mesh := mesh_value as MultiMesh
				if mesh != null and slot < mesh.instance_count:
					mesh.set_instance_transform(slot,
						Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO))
			(page.freeSlots as Array).append(slot)
			page.liveCount = maxi(0, int(page.liveCount) - 1)
			if int(page.liveCount) == 0:
				for instance_value in page.instances:
					(instance_value as MultiMeshInstance3D).visible = false
			pages[page_index] = page
			_groups[String(record.groupKey)] = pages
	_records.erase(body_id)


func _record_installed(record: Dictionary) -> bool:
	var chunk: Node3D = _chunk.get_ref() as Node3D if _chunk != null else null
	var body: StaticBody3D = (record.body as WeakRef).get_ref() as StaticBody3D
	if not is_instance_valid(chunk) or not chunk.is_inside_tree() or chunk.is_queued_for_deletion() \
			or chunk.get_instance_id() != _chunk_instance_id or not _valid_body(body) \
			or get_parent() != chunk or not is_inside_tree() or is_queued_for_deletion() \
			or not is_visible_in_tree() \
			or global_transform != record.batchGlobalTransform \
			or body.global_transform != record.bodyGlobalTransform \
			or body.get_meta(PUBLISHER_META, null) != self:
		return false
	var pages: Array = _groups.get(String(record.groupKey), [])
	var page_index := int(record.pageIndex)
	if page_index < 0 or page_index >= pages.size():
		return false
	var page: Dictionary = pages[page_index]
	var slot := int(record.slot)
	if slot < 0 or slot >= int(page.nextSlot):
		return false
	var instances: Array = page.instances
	var meshes: Array = page.meshes
	for index in range(3):
		var instance := instances[index] as MultiMeshInstance3D
		var mesh := meshes[index] as MultiMesh
		if not is_instance_valid(instance) or not instance.is_inside_tree() \
				or instance.is_queued_for_deletion() or instance.get_parent() != self \
				or not instance.is_visible_in_tree() \
				or instance.get_instance_id() != int(record.meshInstanceIds[index]) \
				or instance.multimesh != mesh or mesh == null or mesh.mesh == null \
				or mesh.get_instance_id() != int(record.multimeshIds[index]) \
				or mesh.mesh.get_instance_id() != int(record.meshResourceIds[index]) \
				or instance.material_override == null \
				or instance.material_override.get_instance_id() != int(record.materialIds[index]) \
				or not is_equal_approx(instance.visibility_range_end,
					float(record.visibilityRange)) \
				or slot >= mesh.instance_count \
				or (mesh.visible_instance_count >= 0 and slot >= mesh.visible_instance_count) \
				or mesh.get_instance_transform(slot) != record.transforms[index]:
			return false
	return true


func _valid_body(body: StaticBody3D) -> bool:
	var chunk: Node3D = _chunk.get_ref() as Node3D if _chunk != null else null
	return is_instance_valid(chunk) and chunk.get_instance_id() == _chunk_instance_id \
		and is_instance_valid(body) and body.get_parent() == chunk \
		and body.is_inside_tree() and not body.is_queued_for_deletion()


func _create_page(architecture: String, biome: String,
		visibility_range: float, page_index: int) -> Dictionary:
	_factory.ensure_shared_geometry()
	var branch_mesh := _factory.runtime_shared_branch_mesh()
	var crown_mesh := _factory.runtime_shared_horizon_crown_mesh(architecture)
	if branch_mesh == null or crown_mesh == null:
		return {}
	var meshes: Array = []
	var instances: Array = []
	for role in range(3):
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = branch_mesh if role == 0 else crown_mesh
		multimesh.instance_count = PAGE_CAPACITY
		multimesh.visible_instance_count = 0
		var instance := MultiMeshInstance3D.new()
		instance.name = "HorizonTree_%s_%s_%d_%d" % [architecture, biome, page_index, role]
		instance.multimesh = multimesh
		instance.material_override = _factory.branch_material(architecture, biome) if role == 0 \
			else _factory.foliage_material(architecture, biome)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = visibility_range
		instance.visibility_range_end_margin = minf(12.0, visibility_range * 0.12)
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		instance.extra_cull_margin = 1.0
		add_child(instance)
		meshes.append(multimesh)
		instances.append(instance)
	return {"meshes": meshes, "instances": instances,
		"nextSlot": 0, "freeSlots": [], "liveCount": 0}


static func _tree_transforms(body_to_batch: Transform3D, architecture: String,
		height: float, crown_radius: float, trunk_radius: float,
		canopy_density: float) -> Array:
	var trunk := Transform3D(Basis.IDENTITY.scaled(Vector3(trunk_radius,
		height * 0.68, trunk_radius)), Vector3(0.0, height * 0.34, 0.0))
	var fullness := lerpf(0.82, 1.04, clampf(canopy_density, 0.2, 1.0))
	var crown_height := maxf(crown_radius * 1.2, height * 0.42)
	var crown_center_y := height * 0.68
	if architecture == "savanna":
		crown_height *= 0.66
		crown_center_y = height * 0.78
	var crown_scale := Vector3(crown_radius * 2.0 * fullness,
		crown_height, 1.0)
	var first_crown := Transform3D(Basis(Vector3.UP, 0.0).scaled(crown_scale),
		Vector3(0.0, crown_center_y, 0.0))
	var second_crown := Transform3D(Basis(Vector3.UP, PI * 0.5).scaled(crown_scale),
		Vector3(0.0, crown_center_y, 0.0))
	return [body_to_batch * trunk, body_to_batch * first_crown,
		body_to_batch * second_crown]


static func _instance_ids(values: Array) -> Array[int]:
	var ids: Array[int] = []
	for value in values:
		ids.append(value.get_instance_id())
	return ids


static func _mesh_ids(values: Array) -> Array[int]:
	var ids: Array[int] = []
	for value in values:
		ids.append((value as MultiMesh).mesh.get_instance_id())
	return ids


static func _material_ids(values: Array) -> Array[int]:
	var ids: Array[int] = []
	for value in values:
		ids.append((value as MultiMeshInstance3D).material_override.get_instance_id())
	return ids
