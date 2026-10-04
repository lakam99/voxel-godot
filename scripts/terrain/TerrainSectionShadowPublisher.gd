extends RefCounted
class_name TerrainSectionShadowPublisher

## Runtime-owned, retryable terrain-to-section shadow publication.
##
## This is an integration stage, not yet the shared world-section authority:
## candidates are terrain-only and VoxelTerrain remains visible/collidable.
## Capture and source validation stay on the runtime thread. One candidate is
## advanced per runtime frame so queue ownership and renderer installation are
## part of production rather than test-runner orchestration.

const CELL := 1.35
const MAX_PENDING_REQUESTS := 32
const MAX_RETAINED_RESULTS := 32
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const ContributorLedger = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const PacketOwner = preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")

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
			"block":_active.get("block", Vector3i.ZERO)}
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
		var capture: Dictionary = _runtime.capture_resident_terrain_mesh_block(block)
		if capture.get("status") == "pending":
			return {"status":"pending", "stage":"capture", "reason":capture.get("reason", "")}
		if capture.get("status") != "ready":
			return _finish({"status":"failed", "reason":capture.get("reason", "terrain_capture_failed")})
		_active["capture"] = capture
		_active["stage"] = "candidate_build"
		return {"status":"pending", "stage":"candidate_build", "block":block}
	if _active.stage == "candidate_build":
		var capture: Dictionary = _active.capture
		if not _runtime.resident_terrain_capture_is_current(capture):
			return _finish({"status":"failed", "reason":"terrain_capture_stale_before_mesh_build"})
		var candidate_result := _build_candidate(capture)
		if candidate_result.get("status") != "ready":
			return _finish(candidate_result)
		if not _runtime.resident_terrain_capture_is_current(capture):
			return _finish({"status":"failed", "reason":"terrain_capture_stale_before_install"})
		var installation: Dictionary = PacketOwner.begin_static_section_install(
			candidate_result.candidate, candidate_result.materials, candidate_result.meshes)
		if installation.get("status") != "ready":
			if installation.get("status") == "pending":
				return {"status":"pending", "stage":"renderer_owner", "reason":installation.get("reason", "")}
			return _finish({"status":"failed", "reason":"terrain_candidate_install_begin_failed",
				"detail":installation})
		_active["session"] = installation.session
		_active["candidate"] = candidate_result.candidate
		_active["mesh"] = candidate_result.mesh
		_active["meshDigest"] = candidate_result.meshDigest
		_active["meshBuildUsec"] = int(candidate_result.meshBuildUsec)
		_active["stage"] = "renderer_install"
		return {"status":"pending", "stage":"renderer_install", "block":block}
	if _active.stage == "renderer_install":
		var capture: Dictionary = _active.capture
		var session = _active.session
		if not _runtime.resident_terrain_capture_is_current(capture):
			session.cancel()
			return _finish({"status":"failed", "reason":"terrain_capture_stale_during_install"})
		if session.state == "installed":
			return _finish(_install_result(session, "installed"))
		if session.state in ["failed", "cancelled"]:
			return _finish({"status":"failed", "reason":"terrain_candidate_install_ended_early",
				"state":String(session.state)})
		var step: Dictionary = session.advance(4)
		if step.get("status") == "installed":
			return _finish(_install_result(session, "installed", step))
		if step.get("status") == "failed":
			return _finish({"status":"failed", "reason":"terrain_candidate_install_failed",
				"detail":step})
		return {"status":"pending", "stage":String(step.get("stage", "renderer_install")),
			"block":block, "reason":String(step.get("reason", ""))}
	return _finish({"status":"failed", "reason":"terrain_shadow_publisher_unknown_stage"})


func _build_candidate(capture: Dictionary) -> Dictionary:
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
	var source_part_id := source_id + ":part"
	var source_revision := String(capture.sourceRevision) + ":" + String(capture.payloadDigest)
	var mesh_key := "resident-transvoxel:" + String(binding.contentDigest)
	var material_key := "production-terrain-shader"
	var segment_id := source_id + ":mesh"
	var mesh_bounds := mesh.get_aabb()
	if not _mesh_bounds_fit_native_block(mesh_bounds):
		return {"status":"failed", "reason":"transvoxel_mesh_origin_outside_native_block",
			"meshLocalBounds":mesh_bounds, "meshBuildUsec":mesh_build_usec}
	var pipeline_revision := "voxel-mesher-transvoxel:s4:no-transitions:v1"
	var declaration_segment: Dictionary = {"segmentId":segment_id,
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
	var removals: Array = []
	removals.make_read_only()
	var ledger = ContributorLedger.new()
	var boundary_id := "terrain-shadow:" + String(capture.payloadDigest).substr(0, 16)
	var begun: Dictionary = ledger.begin_boundary(boundary_id, declarations, removals)
	if begun.get("status") != "ready":
		return {"status":"failed", "reason":"terrain_candidate_boundary_rejected", "detail":begun,
			"meshBuildUsec":mesh_build_usec}
	var transform_buffer: Array[float] = []
	for value: float in InstanceBuffer.encode(Transform3D.IDENTITY, Color.WHITE):
		transform_buffer.append(value)
	transform_buffer.make_read_only()
	var prepared_segment: Dictionary = {"sourcePartId":source_part_id, "sourceId":source_id,
		"sourceRevision":source_revision, "segmentId":segment_id,
		"buffer":transform_buffer, "instanceCount":1, "materialKey":material_key,
		"renderTier":"structural", "meshKey":mesh_key, "meshContentDigest":binding.contentDigest,
		"meshLocalBounds":mesh_bounds, "pipelineRevision":pipeline_revision,
		"renderLayer":"opaque", "translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	prepared_segment.make_read_only()
	if ledger.accept_prepared_segment(boundary_id, prepared_segment).get("status") != "accepted":
		return {"status":"failed", "reason":"terrain_candidate_segment_rejected",
			"meshBuildUsec":mesh_build_usec}
	var revisions: Dictionary = {source_part_id:source_revision}
	revisions.make_read_only()
	var prepared: Dictionary = ledger.prepare_boundary(boundary_id, revisions,
		"resident-terrain-shadow:" + String(capture.seed), 1)
	if prepared.get("status") != "prepared" or prepared.replacements.size() != 1:
		return {"status":"failed", "reason":"terrain_candidate_snapshot_failed", "detail":prepared,
			"meshBuildUsec":mesh_build_usec}
	var candidate: Dictionary = prepared.replacements[0]
	var materials: Dictionary = {material_key:material}
	var meshes: Dictionary = {mesh_key:mesh}
	materials.make_read_only()
	meshes.make_read_only()
	return {"status":"ready", "candidate":candidate, "materials":materials,
		"meshes":meshes, "mesh":mesh, "meshDigest":binding.contentDigest,
		"meshBuildUsec":mesh_build_usec, "meshBounds":mesh_bounds}


func _install_result(session, status: String, step: Dictionary = {}) -> Dictionary:
	var candidate: Dictionary = _active.candidate
	var mesh: Mesh = _active.mesh
	return {"status":status, "sectionKey":candidate.sectionKey,
		"generation":candidate.generation, "meshSurfaceCount":mesh.get_surface_count(),
		"meshContentDigest":String(_active.meshDigest),
		"meshBuildUsec":int(_active.meshBuildUsec), "meshLocalBounds":mesh.get_aabb(),
		"manifestDigest":String(candidate.contentManifestDigest),
		"receipt":step.get("receipt", {}), "terrainOnly":true,
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


func shutdown() -> void:
	if not _active.is_empty():
		var session = _active.get("session")
		if session != null and session.has_method("cancel"):
			session.cancel()
	_active.clear()
	_requests.clear()
	_results.clear()
	_runtime = null
