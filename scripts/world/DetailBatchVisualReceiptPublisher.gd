extends RefCounted
class_name DetailBatchVisualReceiptPublisher

## Validates a receipt against the installed MultiMesh instance. The batch
## node retains this publisher; the publisher holds only a weak batch reference.
var _batch: WeakRef
var _batch_instance_id := 0
var _detail_type := ""
var _multimesh_instance_id := 0
var _mesh_instance_id := 0
var _visibility_end := 0.0
var _uses_colors := false
var _uses_custom_data := false
var _instances: Array[Dictionary] = []


func configure(batch: MultiMeshInstance3D, detail_type: String) -> void:
	_batch = weakref(batch) if is_instance_valid(batch) else null
	_batch_instance_id = batch.get_instance_id() if is_instance_valid(batch) else 0
	_detail_type = detail_type
	_instances.clear()
	if not is_instance_valid(batch) or batch.multimesh == null or batch.multimesh.mesh == null:
		return
	var multimesh := batch.multimesh
	_multimesh_instance_id = multimesh.get_instance_id()
	_mesh_instance_id = multimesh.mesh.get_instance_id()
	_visibility_end = batch.visibility_range_end
	_uses_colors = multimesh.use_colors
	_uses_custom_data = multimesh.use_custom_data
	for index in range(multimesh.instance_count):
		_instances.append({"instanceIndex": index,
			"instanceTransform": multimesh.get_instance_transform(index),
			"instanceColor": multimesh.get_instance_color(index) if multimesh.use_colors else Color.WHITE,
			"instanceCustomData": multimesh.get_instance_custom_data(index)
				if multimesh.use_custom_data else Color.WHITE})


func candidate_snapshot() -> Array[Dictionary]:
	return _instances.duplicate(true)


func candidate_count() -> int:
	return _instances.size()


func candidate_at(index: int) -> Dictionary:
	if index < 0 or index >= _instances.size():
		return {}
	return _instances[index].duplicate(true)


func source_identity() -> Dictionary:
	return {"batchInstanceId": _batch_instance_id,
		"multimeshInstanceId": _multimesh_instance_id,
		"meshInstanceId": _mesh_instance_id,
		"detailType": _detail_type, "detailVisibilityEnd": _visibility_end}


func visual_receipt_installed(_source_identity: String, _source_revision: String,
		_world_revision: String, _view_revision: int, candidate_id: String,
		metadata: Dictionary, representation_id: String, _tier: String) -> bool:
	var batch: MultiMeshInstance3D = _batch.get_ref() as MultiMeshInstance3D if _batch != null else null
	if not is_instance_valid(batch) or batch.get_instance_id() != _batch_instance_id \
			or not batch.is_inside_tree() or batch.is_queued_for_deletion() \
			or not batch.visible or not batch.is_visible_in_tree():
		return false
	if candidate_id.is_empty() or representation_id != "%s:installed" % candidate_id \
			or String(metadata.get("detailType", "")) != _detail_type \
			or int(metadata.get("batchInstanceId", 0)) != _batch_instance_id \
			or batch.global_transform != metadata.get("batchGlobalTransform"):
		return false
	var chunk_instance_id := int(metadata.get("chunkInstanceId", 0))
	var ancestor: Node = batch
	var belongs_to_chunk := false
	while ancestor != null:
		if ancestor.get_instance_id() == chunk_instance_id:
			belongs_to_chunk = true
			break
		ancestor = ancestor.get_parent()
	if not belongs_to_chunk:
		return false
	var multimesh := batch.multimesh
	if multimesh == null or multimesh.mesh == null \
			or multimesh.get_instance_id() != _multimesh_instance_id \
			or multimesh.mesh.get_instance_id() != _mesh_instance_id \
			or multimesh.instance_count != _instances.size() \
			or multimesh.use_colors != _uses_colors \
			or multimesh.use_custom_data != _uses_custom_data \
			or _multimesh_instance_id != int(metadata.get("multimeshInstanceId", 0)) \
			or _mesh_instance_id != int(metadata.get("meshInstanceId", 0)):
		return false
	var index := int(metadata.get("instanceIndex", -1))
	if index < 0 or index >= _instances.size() or index >= multimesh.instance_count \
			or (multimesh.visible_instance_count >= 0 and index >= multimesh.visible_instance_count):
		return false
	var expected: Dictionary = _instances[index]
	if expected != {"instanceIndex": index,
			"instanceTransform": metadata.get("instanceTransform"),
			"instanceColor": metadata.get("instanceColor"),
			"instanceCustomData": metadata.get("instanceCustomData")}:
		return false
	if multimesh.get_instance_transform(index) != expected.instanceTransform:
		return false
	if multimesh.use_colors and multimesh.get_instance_color(index) != expected.instanceColor:
		return false
	if multimesh.use_custom_data \
			and multimesh.get_instance_custom_data(index) != expected.instanceCustomData:
		return false
	return is_equal_approx(batch.visibility_range_end, _visibility_end) \
		and is_equal_approx(_visibility_end, float(metadata.get("detailVisibilityEnd", -1.0)))
