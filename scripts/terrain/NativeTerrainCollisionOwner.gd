extends StaticBody3D

const AdmissionBarrier = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")

## Sole project-owned physics body for one native terrain collision stream. The
## caller owns the source and supplies a real physics probe for acknowledgement.
const MAX_SHAPES := 64
const MAX_VERTEX_BYTES := 4 * 1024 * 1024
const MAX_ACK_FRAMES := 6

var authority: Dictionary = {}
var installed_shapes: Array[CollisionShape3D] = []
var installed_provenance: Dictionary = {}
var acknowledged_physics_frame := -1
var retired_shape_sets := 0
var peak_retired_shape_sets := 0
var _stopped := false
var _installing := false
var _pending_shapes: Array[CollisionShape3D] = []
var _rejected_before_install_identity := {}


## A receipt is usable only after the physics probe has acknowledged the exact
## installed revision. A queued replacement never makes its candidate ready.
func physical_receipt(identity: Dictionary) -> Dictionary:
	if _stopped or _installing or not _identity_valid(identity) or authority != identity \
			or installed_provenance.get("requestIdentity") != identity \
			or acknowledged_physics_frame < 0 or installed_shapes.is_empty():
		return {"ready": false}
	for shape in installed_shapes:
		if not is_instance_valid(shape) or shape.is_queued_for_deletion() or shape.disabled:
			return {"ready": false}
	return {"ready": true, "physicsFrame": acknowledged_physics_frame,
		"provenance": installed_provenance.duplicate(true)}


func preinstall_rejection_receipt(identity: Dictionary) -> Dictionary:
	if _stopped or _installing or identity != _rejected_before_install_identity \
			or authority != identity or not is_inside_tree() or collision_layer == 0 \
			or installed_shapes.is_empty() or installed_provenance.get("requestIdentity") == identity \
			or not _nonempty_string(installed_provenance.get("snapshotDigest")) \
			or not _nonempty_string(installed_provenance.get("collisionArtifactKey")) \
			or acknowledged_physics_frame < 0:
		return {"safe": false}
	for shape in installed_shapes:
		if not is_instance_valid(shape) or not shape.is_inside_tree() \
				or shape.is_queued_for_deletion() or shape.disabled or shape.shape == null:
			return {"safe": false}
	_rejected_before_install_identity.clear()
	return {"safe": true, "rejectedIdentity": identity.duplicate(true),
		"retainedProvenance": installed_provenance.duplicate(true),
		"oldPhysicsFrame": acknowledged_physics_frame}


func set_authority(identity: Dictionary) -> void:
	_rejected_before_install_identity.clear()
	authority = identity.duplicate(true)


func stop_and_drain() -> void:
	_stopped = true
	_rejected_before_install_identity.clear()
	authority.clear()
	for shape in installed_shapes:
		shape.disabled = true
		if not shape.is_queued_for_deletion():
			shape.queue_free()
	for shape in _pending_shapes:
		shape.disabled = true
	installed_shapes.clear()
	installed_provenance.clear()
	acknowledged_physics_frame = -1
	while _installing:
		await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().process_frame


func replace(result: Dictionary, identity: Dictionary, acknowledgement_probe: Callable,
		before_ack: Callable = Callable(), admission_barrier: RefCounted = null) -> Dictionary:
	var started := Time.get_ticks_usec()
	_rejected_before_install_identity.clear()
	if not _identity_valid(identity):
		return {"ok": false, "reason": "collision_identity_invalid"}
	var source: Variant = result.get("source")
	var collision: Variant = result.get("collision")
	if not source is Dictionary or not collision is Dictionary \
			or not _nonempty_string(source.get("snapshotDigest")) \
			or not _nonempty_string(collision.get("artifactKey")):
		return {"ok": false, "reason": "collision_provenance_invalid"}
	if _stopped or _installing or not _current(result, identity):
		return {"ok": false, "reason": "stale_before_install" if not _current(result, identity) else "collision_owner_unavailable"}
	if not acknowledgement_probe.is_valid():
		return {"ok": false, "reason": "acknowledgement_probe_required"}
	if not installed_shapes.is_empty() and not admission_barrier is AdmissionBarrier:
		return {"ok": false, "reason": "replacement_admission_barrier_required"}
	if admission_barrier is AdmissionBarrier:
		var clearance: Dictionary = admission_barrier.clearance(identity)
		if not bool(clearance.get("clear", false)):
			_rejected_before_install_identity = identity.duplicate(true)
			return {"ok": false, "reason": "replacement_occupied_before_install",
				"guardReason": clearance.get("reason", "unknown")}
	var payload := _prepare_shapes(result, identity)
	if not payload.ok:
		return payload
	_rejected_before_install_identity.clear()
	_installing = true
	var previous := installed_shapes.duplicate()
	var replacements: Array[CollisionShape3D] = payload.shapes
	_pending_shapes = replacements.duplicate()
	for node in replacements:
		add_child(node)
	for node in previous:
		node.disabled = true
	var installed_usec := Time.get_ticks_usec()
	if before_ack.is_valid():
		before_ack.call()
	var acknowledgement := {}
	var occupied_during_ack := false
	for attempt in range(MAX_ACK_FRAMES):
		await get_tree().physics_frame
		if not _current(result, identity):
			break
		if admission_barrier is AdmissionBarrier \
				and not bool(admission_barrier.clearance(identity).get("clear", false)):
			occupied_during_ack = true
			break
		var observed: Variant = acknowledgement_probe.call(self, identity)
		if observed is Dictionary and bool(observed.get("ok", false)) \
				and observed.get("provenance") is Dictionary:
			var provenance: Dictionary = observed.provenance
			if provenance.get("requestIdentity") != identity \
					or provenance.get("snapshotDigest") != source.snapshotDigest \
					or provenance.get("artifactKey") != collision.artifactKey:
				continue
			acknowledgement = {"physicsFrame": Engine.get_physics_frames(), "provenance": provenance}
			break
	if acknowledgement.is_empty() or not _current(result, identity):
		for node in replacements:
			node.disabled = true
			if not node.is_queued_for_deletion():
				node.queue_free()
		if not _stopped:
			for node in previous:
				node.disabled = false
		await get_tree().physics_frame
		_pending_shapes.clear()
		_installing = false
		return {"ok": false, "reason": "stale_before_acknowledgement" if not _current(result, identity) \
			else "replacement_occupied_during_acknowledgement" if occupied_during_ack \
			else "replacement_not_acknowledged_within_six_physics_frames"}
	acknowledged_physics_frame = int(acknowledgement.physicsFrame)
	installed_shapes = replacements
	_pending_shapes.clear()
	installed_provenance = {"snapshotDigest": result.source.snapshotDigest,
		"collisionArtifactKey": result.collision.artifactKey, "requestIdentity": identity.duplicate(true)}
	var acknowledged_usec := Time.get_ticks_usec()
	if not previous.is_empty():
		retired_shape_sets += 1
		peak_retired_shape_sets = max(peak_retired_shape_sets, retired_shape_sets)
	for node in previous:
		if not node.is_queued_for_deletion():
			node.queue_free()
	await get_tree().physics_frame
	if not previous.is_empty():
		retired_shape_sets -= 1
	_installing = false
	if _stopped:
		return {"ok": false, "reason": "stopped_during_retirement"}
	return {"ok": true, "acknowledgedPhysicsFrame": acknowledged_physics_frame,
		"acknowledgement": acknowledgement, "retiredShapeCount": previous.size(),
		"currentShapeCount": replacements.size(), "vertexBytes": payload.vertexBytes,
		"installMilliseconds": float(installed_usec - started) / 1000.0,
		"acknowledgementMilliseconds": float(acknowledged_usec - installed_usec) / 1000.0}


func _current(result: Dictionary, identity: Dictionary) -> bool:
	return not _stopped and result.get("requestIdentity") == identity and authority == identity


func _identity_valid(identity: Dictionary) -> bool:
	for field in ["ownerGeneration", "sourceRevision", "cancellationEpoch"]:
		if not identity.has(field) or not identity[field] is int:
			return false
	return int(identity.ownerGeneration) > 0 and int(identity.sourceRevision) >= 0 \
		and int(identity.cancellationEpoch) > 0


func _nonempty_string(value: Variant) -> bool:
	return value is String and not String(value).strip_edges().is_empty()


func _prepare_shapes(result: Dictionary, identity: Dictionary) -> Dictionary:
	var collision: Dictionary = result.get("collision", {})
	var source: Dictionary = result.get("source", {})
	var tiles: Variant = collision.get("tileTriangles")
	var blockers: Variant = collision.get("blockers")
	if not tiles is Array or not blockers is Array or tiles.size() + blockers.size() > MAX_SHAPES:
		return {"ok": false, "reason": "collision_shape_capacity_exceeded_or_missing"}
	var shapes: Array[CollisionShape3D] = []
	var vertex_bytes := 0
	for tile in tiles:
		if not tile is Dictionary or tile.get("coordinateFrame") != "world" or bool(tile.get("includesDeclaredBlockers", true)):
			return {"ok": false, "reason": "tile_collision_not_world_frame_or_contains_blocker"}
		var vertices := _vertices(tile.get("vertices"))
		if not vertices.ok:
			return vertices
		vertex_bytes += vertices.vertices.size() * 12
		if vertex_bytes > MAX_VERTEX_BYTES:
			return {"ok": false, "reason": "collision_vertex_capacity_exceeded"}
		var shape := ConcavePolygonShape3D.new()
		shape.data = vertices.vertices
		var node := CollisionShape3D.new()
		node.shape = shape
		node.set_meta("provenance", {"snapshotDigest": source.get("snapshotDigest"),
			"artifactKey": collision.get("artifactKey"), "requestIdentity": identity.duplicate(true),
			"tileKey": tile.get("tileKey")})
		shapes.append(node)
	for blocker in blockers:
		if not blocker is Dictionary:
			return {"ok": false, "reason": "native_blocker_geometry_invalid"}
		var center := _vector(blocker.get("center"))
		var size := _vector(blocker.get("size"))
		if not center.ok or not size.ok or size.value.x <= 0.0 or size.value.y <= 0.0 or size.value.z <= 0.0:
			return {"ok": false, "reason": "native_blocker_geometry_invalid"}
		var shape := BoxShape3D.new()
		shape.size = size.value
		var node := CollisionShape3D.new()
		node.shape = shape
		node.position = center.value
		node.set_meta("provenance", {"snapshotDigest": source.get("snapshotDigest"),
			"artifactKey": collision.get("artifactKey"), "requestIdentity": identity.duplicate(true),
			"featureId": blocker.get("id"), "semanticClass": blocker.get("semanticClass"),
			"physicalIntent": blocker.get("physicalIntent")})
		shapes.append(node)
	return {"ok": true, "shapes": shapes, "vertexBytes": vertex_bytes}


func _vertices(value: Variant) -> Dictionary:
	var vertices := PackedVector3Array()
	if value is PackedVector3Array:
		vertices = value
	elif value is Array:
		for row in value:
			var vector := _vector(row)
			if not vector.ok:
				return {"ok": false, "reason": "collision_vertex_invalid"}
			vertices.append(vector.value)
	if vertices.is_empty() or vertices.size() % 3 != 0:
		return {"ok": false, "reason": "collision_vertices_not_triangle_soup"}
	for vertex in vertices:
		if not vertex.is_finite():
			return {"ok": false, "reason": "collision_vertex_nonfinite"}
	return {"ok": true, "vertices": vertices}


func _vector(value: Variant) -> Dictionary:
	if not value is Array or value.size() != 3:
		return {"ok": false}
	var vector := Vector3(float(value[0]), float(value[1]), float(value[2]))
	return {"ok": vector.is_finite(), "value": vector}
