extends RefCounted
class_name TerrainSectionShadowPublisher

## Runtime-owned, retryable terrain producer handoff to shared section slots.
##
## Terrain declarations and immutable mesh segments enter
## WorldStaticSectionCoordinator; complete all-domain census admission is
## still required before native installation. VoxelTerrain remains the visible
## and collision authority until a shared slot receipt. Capture and source
## validation stay on the runtime thread, and one candidate advances per frame.

const CELL := 1.35
const MAX_PENDING_REQUESTS := 32
const MAX_RETAINED_RESULTS := 32
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const InstanceAttributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

var _runtime
var _next_ticket := 1
var _requests: Array[Dictionary] = []
var _active: Dictionary = {}
var _results: Dictionary = {}


func setup(runtime) -> Dictionary:
	if runtime == null or _runtime != null:
		return {"status":"failed", "reason":"terrain_shadow_publisher_owner_invalid"}
	_runtime = runtime
	return {"status":"ready"}


func request(block: Vector3i) -> Dictionary:
	if _runtime == null:
		return {"status":"failed", "reason":"terrain_shadow_publisher_unbound"}
	if _requests.size() >= MAX_PENDING_REQUESTS:
		return {"status":"pending", "reason":"terrain_shadow_queue_backpressure",
			"retryable":true, "queueDepth":_requests.size()}
	var ticket := _next_ticket
	_next_ticket += 1
	_requests.append({"ticket":ticket, "block":block})
	return {"status":"queued", "ticket":ticket, "block":block,
		"queueDepth":_requests.size() + (1 if not _active.is_empty() else 0)}


func poll(ticket: int) -> Dictionary:
	if _results.has(ticket):
		var result: Dictionary = _results[ticket]
		_results.erase(ticket)
		return {"status":"ready", "result":result}
	if int(_active.get("ticket", 0)) == ticket:
		return {"status":"pending", "stage":String(_active.get("stage", "capture")),
			"block":_active.get("block", Vector3i.ZERO),
			"coordinatorSubmitted":bool(_active.get("coordinatorSubmitted", false)),
			"coordinatorBoundaryId":String(_active.get("boundaryId", "")),
			"lastReason":String(_active.get("lastReason", "")),
			"lastCoordinatorStatus":String(_active.get("lastCoordinatorStatus", "")),
			"lastProviderId":String(_active.get("lastProviderId", ""))}
	for request_value: Dictionary in _requests:
		if int(request_value.get("ticket", 0)) == ticket:
			return {"status":"pending", "stage":"queued",
				"queueDepth":_requests.size()}
	return {"status":"failed", "reason":"terrain_shadow_ticket_unknown"}


func advance() -> Dictionary:
	if _runtime == null:
		return {"status":"idle"}
	if _active.is_empty():
		if _requests.is_empty():
			return {"status":"idle"}
		_active = _requests.pop_front()
		_active["stage"] = "capture"
	var block: Vector3i = _active.block
	if _active.stage == "capture":
		if not bool(_active.get("fluidProbeRequested", false)):
			var fluid_probe: Dictionary = _runtime.request_terrain_section_fluid_probe(block)
			_active["fluidProbeRequested"] = true
			if fluid_probe.get("status") == "failed":
				return _finish({"status":"failed", "reason":String(fluid_probe.get("reason", "exact_fluid_probe_failed"))})
		var capture: Dictionary = _runtime.capture_resident_terrain_mesh_block(block)
		if capture.get("status") == "pending":
			_active["lastReason"] = String(capture.get("reason", ""))
			return {"status":"pending", "stage":"capture", "reason":capture.get("reason", "")}
		if capture.get("status") != "ready":
			return _finish({"status":"failed", "reason":capture.get("reason", "terrain_capture_failed")})
		_active["capture"] = capture
		_active["stage"] = "candidate_build"
		return {"status":"pending", "stage":"candidate_build", "block":block}
	if _active.stage == "candidate_build":
		var capture: Dictionary = _active.capture
		if not _runtime.terrain_capture_authority_is_current(capture):
			return _finish({"status":"failed", "reason":"terrain_capture_stale_before_mesh_build"})
		var fluid_probe: Dictionary = _runtime.request_terrain_section_fluid_probe(block)
		if fluid_probe.get("status") != "ready":
			_active["lastReason"] = String(fluid_probe.get("reason", "terrain_exact_fluid_section_probe_pending"))
			return {"status":"pending", "stage":"source_admission",
				"reason":String(_active.lastReason), "section":block}
		var main = _runtime.main
		var world_id := "seed:%s:%d" % [String(main.get("seed_text")), int(main.get("seed_hash"))]
		var source_snapshot: Dictionary = _runtime.capture_static_section_sources(world_id, [block])
		if source_snapshot.get("status") == "pending":
			_active["lastReason"] = String(source_snapshot.get("reason", "terrain_source_admission_pending"))
			return {"status":"pending", "stage":"source_admission",
				"reason":String(_active.lastReason)}
		if source_snapshot.get("status") != "complete":
			return _finish({"status":"failed", "reason":"terrain_source_census_failed",
				"detail":source_snapshot})
		var source_part_id: String = _runtime._terrain_section_source_part_id(block)
		var source_revision: String = String(source_snapshot.sourceRevisions.get(source_part_id, ""))
		if source_revision.is_empty():
			return _finish({"status":"failed", "reason":"terrain_section_source_revision_missing"})
		var candidate_result := _build_candidate(capture, source_part_id, source_revision)
		if candidate_result.get("status") != "ready":
			return _finish(candidate_result)
		if not _runtime.terrain_capture_authority_is_current(capture):
			return _finish({"status":"failed", "reason":"terrain_capture_stale_before_coordinator_handoff"})
		var coordinator = main.get("world_static_section_coordinator")
		if coordinator == null:
			return {"status":"pending", "stage":"coordinator_unavailable",
				"reason":"world_static_section_coordinator_unavailable"}
		var boundary_id := "terrain-section:%d:%d,%d,%d:%s" % [int(_active.ticket),
			block.x, block.y, block.z, String(capture.payloadDigest).substr(0, 16)]
		var queued: Dictionary = coordinator.enqueue_boundary(boundary_id,
			candidate_result.declarations, candidate_result.removals)
		if queued.get("status") != "queued":
			return _finish({"status":"failed", "reason":"terrain_coordinator_boundary_rejected",
				"detail":queued})
		var submitted: Dictionary = coordinator.submit_prepared_segment(boundary_id,
			candidate_result.preparedSegment)
		if submitted.get("status") not in ["queued", "accepted"]:
			coordinator.cancel_boundary(boundary_id)
			return _finish({"status":"failed", "reason":"terrain_coordinator_segment_rejected",
				"detail":submitted})
		_active["boundaryId"] = boundary_id
		_active["sectionKey"] = block
		_active["materials"] = candidate_result.materials
		_active["meshes"] = candidate_result.meshes
		_active["mesh"] = candidate_result.mesh
		_active["meshDigest"] = candidate_result.meshDigest
		_active["meshBuildUsec"] = int(candidate_result.meshBuildUsec)
		_active["sourceRevision"] = source_revision
		_active["coordinatorSubmitted"] = true
		_active["lastCoordinatorStatus"] = "queued"
		_active["lastReason"] = ""
		_active["stage"] = "coordinator_install"
		return {"status":"pending", "stage":"coordinator_admission", "block":block}
	if _active.stage == "coordinator_install":
		var capture: Dictionary = _active.capture
		if not _runtime.terrain_capture_authority_is_current(capture):
			_cancel_active_boundary()
			return _finish({"status":"failed", "reason":"terrain_capture_stale_during_coordinator_install"})
		var main = _runtime.main
		var coordinator = main.get("world_static_section_coordinator") if is_instance_valid(main) else null
		if coordinator == null:
			return {"status":"pending", "stage":"coordinator_unavailable",
				"reason":"world_static_section_coordinator_unavailable"}
		var step: Dictionary = coordinator.advance_boundary_from_roster(
			[_active.sectionKey], _active.materials, _active.meshes, 4)
		_active["lastCoordinatorStatus"] = String(step.get("status", ""))
		_active["lastReason"] = String(step.get("reason", ""))
		_active["lastProviderId"] = String(step.get("providerId", ""))
		if step.get("status") == "committed":
			return _finish(_install_result(step))
		if step.get("status") in ["failed", "unsupported", "cancelled"]:
			return _finish({"status":"failed", "reason":"terrain_coordinator_boundary_ended",
				"detail":step})
		return {"status":"pending", "stage":String(step.get("stage", "coordinator_admission")),
			"block":block, "reason":String(step.get("reason", "")),
			"providerId":String(step.get("providerId", "")),
			"requiresResubmit":bool(step.get("requiresResubmit", false))}
	return _finish({"status":"failed", "reason":"terrain_shadow_publisher_unknown_stage"})


func _build_candidate(capture: Dictionary, source_part_id: String,
		source_revision: String) -> Dictionary:
	var size: Vector3i = capture.get("size", Vector3i.ZERO)
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, capture.sdf16Le)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, capture.indices8)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, capture.data5_8)
	var terrain = _runtime.terrain
	var mesh_started_usec := Time.get_ticks_usec()
	var mesh: Mesh = terrain.mesher.build_mesh(buffer, [])
	var mesh_build_usec := Time.get_ticks_usec() - mesh_started_usec
	if mesh == null or mesh.get_surface_count() == 0:
		return {"status":"empty", "reason":"resident_transvoxel_candidate_has_no_surfaces",
			"meshBuildUsec":mesh_build_usec}
	var binding: Dictionary = MeshFingerprint.inspect(mesh)
	if binding.get("status") != "ready":
		return {"status":"failed", "reason":"resident_transvoxel_mesh_fingerprint_failed",
			"fingerprint":binding, "meshBuildUsec":mesh_build_usec}
	var material: Material = terrain.material_override
	if material == null:
		return {"status":"failed", "reason":"production_terrain_material_missing",
			"meshBuildUsec":mesh_build_usec}
	var block: Vector3i = capture.block
	var source_id := "resident-terrain:%d,%d,%d" % [block.x, block.y, block.z]
	var mesh_key := "resident-transvoxel:" + String(binding.contentDigest)
	var material_key := "production-terrain-shader"
	var segment_id := source_id + ":mesh"
	var mesh_bounds := mesh.get_aabb()
	if not _mesh_bounds_fit_native_block(mesh_bounds):
		return {"status":"failed", "reason":"transvoxel_mesh_origin_outside_native_block",
			"meshLocalBounds":mesh_bounds, "meshBuildUsec":mesh_build_usec}
	var pipeline_revision := "voxel-mesher-transvoxel:s4:no-transitions:v1"
	var declaration_segment: Dictionary = {"segmentId":segment_id,
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":"structural", "meshKey":mesh_key,
		"meshContentDigest":binding.contentDigest, "meshLocalBounds":mesh_bounds,
		"pipelineRevision":pipeline_revision, "renderLayer":"opaque",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	declaration_segment.make_read_only()
	var declaration_segments: Array[Dictionary] = [declaration_segment]
	declaration_segments.make_read_only()
	var world_origin := Vector3(block * 16) * CELL
	var declaration: Dictionary = {"sourcePartId":source_part_id, "sourceId":source_id,
		"sourceRevision":source_revision,
		"sourceToWorld":Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * CELL), world_origin),
		"ownerCell":SectionGrid.logical_owner_cell_for_world_position(world_origin),
		"segments":declaration_segments}
	declaration.make_read_only()
	var declarations: Array[Dictionary] = [declaration]
	declarations.make_read_only()
	var removals: Array[Dictionary] = []
	removals.make_read_only()
	var transform_buffer: Array[float] = []
	for value: float in InstanceBuffer.encode(Transform3D.IDENTITY, Color.WHITE):
		transform_buffer.append(value)
	transform_buffer.make_read_only()
	var prepared_segment: Dictionary = {"sourcePartId":source_part_id, "sourceId":source_id,
		"sourceRevision":source_revision, "segmentId":segment_id,
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"buffer":transform_buffer, "instanceCount":1, "materialKey":material_key,
		"renderTier":"structural", "meshKey":mesh_key, "meshContentDigest":binding.contentDigest,
		"meshLocalBounds":mesh_bounds, "pipelineRevision":pipeline_revision,
		"renderLayer":"opaque", "translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	prepared_segment.make_read_only()
	var materials: Dictionary = {material_key:material}
	var meshes: Dictionary = {mesh_key:mesh}
	materials.make_read_only()
	meshes.make_read_only()
	return {"status":"ready", "declarations":declarations, "removals":removals,
		"preparedSegment":prepared_segment, "materials":materials,
		"meshes":meshes, "mesh":mesh, "meshDigest":binding.contentDigest,
		"meshBuildUsec":mesh_build_usec, "meshBounds":mesh_bounds}


func _cancel_active_boundary() -> void:
	if _runtime == null or String(_active.get("boundaryId", "")).is_empty():
		return
	var main = _runtime.main
	var coordinator = main.get("world_static_section_coordinator") if is_instance_valid(main) else null
	if coordinator != null:
		coordinator.cancel_boundary(String(_active.boundaryId))


func _install_result(step: Dictionary = {}) -> Dictionary:
	var mesh: Mesh = _active.mesh
	return {"status":"installed", "sectionKey":_active.sectionKey,
		"generation":int(step.get("generation", 0)), "meshSurfaceCount":mesh.get_surface_count(),
		"meshContentDigest":String(_active.meshDigest),
		"meshBuildUsec":int(_active.meshBuildUsec), "meshLocalBounds":mesh.get_aabb(),
		"manifestDigest":String(step.get("manifestDigest", "")),
		"receipt":step.get("receipts", []), "terrainOnly":true,
		"coordinatorBoundaryId":String(_active.get("boundaryId", "")),
		"previousVoxelTerrainVisualRetained":true}


func _mesh_bounds_fit_native_block(bounds: AABB) -> bool:
	const EPSILON := 0.05
	var block_bounds := AABB(Vector3.ZERO, Vector3.ONE * 16.0)
	return bounds.has_volume() \
		and bounds.position.x >= block_bounds.position.x - EPSILON \
		and bounds.position.y >= block_bounds.position.y - EPSILON \
		and bounds.position.z >= block_bounds.position.z - EPSILON \
		and bounds.end.x <= block_bounds.end.x + EPSILON \
		and bounds.end.y <= block_bounds.end.y + EPSILON \
		and bounds.end.z <= block_bounds.end.z + EPSILON


func _finish(result: Dictionary) -> Dictionary:
	var ticket := int(_active.get("ticket", 0))
	if ticket > 0:
		_results[ticket] = result.duplicate(true)
		while _results.size() > MAX_RETAINED_RESULTS:
			_results.erase(_results.keys()[0])
	_active.clear()
	return result


func cancel_pending() -> void:
	_cancel_active_boundary()
	_active.clear()
	_requests.clear()
	_results.clear()


func shutdown() -> void:
	_cancel_active_boundary()
	_active.clear()
	_requests.clear()
	_results.clear()
	_runtime = null
