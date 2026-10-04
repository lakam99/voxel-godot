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
const SECTION_SIZE := 16
const MAX_PENDING_REQUESTS := 32
const MAX_RETAINED_RESULTS := 32
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const InstanceAttributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

var _runtime
var _next_ticket := 1
var _requests: Array[Dictionary] = []
var _active: Dictionary = {}
var _results: Dictionary = {}
var _contribution_requests: Array[Dictionary] = []
var _active_contribution: Dictionary = {}
var _contributions_by_section: Dictionary = {}
var _blocked_contributions_by_section: Dictionary = {}


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


## Implements the terrain provider's shared-section contribution hook. A call
## admits bounded capture work and returns pending until its sealed mesh value
## is prepared. Exact-fluid census and Transvoxel halo revisions are checked
## before the contribution is returned. Fluid-bearing sections remain pending
## until their translucent layer has a supported ordering implementation.
func capture_contribution(census: Dictionary, section_key: Vector3i) -> Dictionary:
	if _runtime == null or census.get("status") != "complete":
		return _pending("terrain_contribution_census_unavailable")
	var world_id := String(census.get("worldId", ""))
	var provider_revision := String(census.get("providerSnapshotRevisions", {}).get("terrain", ""))
	var provider_coverage: Dictionary = census.get("providerCoverageRevisions", {}).get("terrain", {})
	var coverage_revision := String(provider_coverage.get(section_key, ""))
	var expected_by_section: Dictionary = census.get("expectedContributorsBySection", {})
	var expected: Variant = expected_by_section.get(section_key, null)
	var source_part_id: String = _runtime._terrain_section_source_part_id(section_key)
	if world_id.is_empty() or provider_revision.is_empty() or coverage_revision.is_empty() \
			or source_part_id.is_empty() or not expected is Array \
			or expected.count(source_part_id) != 1:
		return _pending("terrain_contribution_census_incomplete", {"sectionKey":section_key})
	var source_revision := String(census.get("sourceRevisions", {}).get(source_part_id, ""))
	if source_revision.is_empty():
		return _pending("terrain_contribution_source_revision_missing", {"sectionKey":section_key})
	var cache: Dictionary = _contributions_by_section.get(section_key, {})
	if _cached_contribution_is_current(cache, world_id, provider_revision,
			coverage_revision, source_part_id, source_revision):
		return {"status":"ready", "contribution":cache.contribution}
	var blocked: Dictionary = _blocked_contributions_by_section.get(section_key, {})
	if _blocked_contribution_matches(blocked, world_id, provider_revision,
			coverage_revision, source_part_id, source_revision):
		return _pending(String(blocked.get("reason", "terrain_contribution_not_supported")), {
			"sectionKey":section_key})
	_blocked_contributions_by_section.erase(section_key)
	if _active_contribution.get("sectionKey") == section_key:
		return _pending("terrain_contribution_preparation_pending", {
			"sectionKey":section_key, "stage":String(_active_contribution.get("stage", "capture"))})
	for request_value: Dictionary in _contribution_requests:
		if request_value.get("sectionKey") == section_key:
			return _pending("terrain_contribution_preparation_queued", {"sectionKey":section_key,
				"queueDepth":_contribution_requests.size()})
	if _contribution_requests.size() >= MAX_PENDING_REQUESTS:
		return _pending("terrain_contribution_queue_backpressure", {"sectionKey":section_key,
			"queueDepth":_contribution_requests.size()})
	_contribution_requests.append({"sectionKey":section_key, "worldId":world_id,
		"providerRevision":provider_revision, "coverageRevision":coverage_revision,
		"sourcePartId":source_part_id, "sourceRevision":source_revision, "stage":"capture"})
	return _pending("terrain_contribution_preparation_queued", {"sectionKey":section_key,
		"queueDepth":_contribution_requests.size()})


func advance() -> Dictionary:
	if _runtime == null:
		return {"status":"idle"}
	if not _active_contribution.is_empty() or not _contribution_requests.is_empty():
		return _advance_contribution()
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


func _advance_contribution() -> Dictionary:
	if _active_contribution.is_empty():
		if _contribution_requests.is_empty():
			return {"status":"idle"}
		_active_contribution = _contribution_requests.pop_front()
	var section: Vector3i = _active_contribution.sectionKey
	var source_snapshot: Dictionary = _runtime.capture_static_section_sources(
		String(_active_contribution.worldId), [section])
	if source_snapshot.get("status") != "complete":
		return _defer_active_contribution(String(source_snapshot.get("reason", "terrain_contribution_source_pending")), {
			"sectionKey":section, "stage":"source_validation"})
	if String(source_snapshot.get("authorityRevision", "")) \
			!= String(_active_contribution.providerRevision) \
			or String(source_snapshot.get("sections", {}).get(section, {}).get("coverageRevision", "")) \
			!= String(_active_contribution.coverageRevision) \
			or String(source_snapshot.get("sourceRevisions", {}).get(
				_active_contribution.sourcePartId, "")) != String(_active_contribution.sourceRevision):
		_active_contribution.clear()
		return _pending("terrain_contribution_census_changed_before_capture", {"sectionKey":section})
	var proof: Dictionary = _runtime.terrain_section_fluid_proofs.get(section, {})
	if not _runtime._terrain_section_fluid_proof_is_current(section, proof):
		_runtime.request_terrain_section_fluid_probe(section)
		return _defer_active_contribution("terrain_exact_fluid_section_probe_pending", {
			"sectionKey":section, "stage":"fluid_validation"})
	if bool(proof.get("hasFluid", false)):
		return _block_active_contribution("terrain_fluid_section_layer_not_supported", {
			"sectionKey":section, "fluidSignature":String(proof.get("signature", ""))})
	if String(_active_contribution.get("stage", "capture")) == "capture":
		var capture: Dictionary = _runtime.capture_resident_terrain_mesh_block(section)
		if capture.get("status") == "pending":
			return _defer_active_contribution(String(capture.get("reason", "terrain_capture_pending")), {
				"sectionKey":section, "stage":"capture"})
		if capture.get("status") != "ready":
			_active_contribution.clear()
			return {"status":"failed", "reason":String(capture.get("reason", "terrain_capture_failed")),
				"retryable":false, "sectionKey":section}
		_active_contribution["capture"] = capture
		_active_contribution["stage"] = "mesh_prepare"
		return _pending("terrain_contribution_mesh_preparation_pending", {
			"sectionKey":section, "stage":"mesh_prepare"})
	var immutable_capture: Dictionary = _active_contribution.get("capture", {})
	if not _runtime.terrain_capture_authority_is_current(immutable_capture):
		_active_contribution.clear()
		return _pending("terrain_contribution_capture_stale_before_meshing", {
			"sectionKey":section})
	var built := _build_candidate(immutable_capture,
		String(_active_contribution.sourcePartId), String(_active_contribution.sourceRevision))
	if built.get("status") not in ["ready", "empty"] \
			or (built.get("status") == "ready" and not built.get("contribution") is Dictionary):
		_active_contribution.clear()
		return built
	var latest: Dictionary = _runtime.capture_static_section_sources(
		String(_active_contribution.worldId), [section])
	if latest.get("status") != "complete" \
			or String(latest.get("authorityRevision", "")) != String(_active_contribution.providerRevision) \
			or String(latest.get("sections", {}).get(section, {}).get("coverageRevision", "")) \
			!= String(_active_contribution.coverageRevision) \
			or String(latest.get("sourceRevisions", {}).get(_active_contribution.sourcePartId, "")) \
			!= String(_active_contribution.sourceRevision) \
			or not _runtime.terrain_capture_authority_is_current(immutable_capture):
		_active_contribution.clear()
		return _pending("terrain_contribution_stale_after_mesh_prepare", {"sectionKey":section})
	var contribution: Dictionary
	if built.get("status") == "empty":
		var source_part_id := String(_active_contribution.sourcePartId)
		var source_revision := String(_active_contribution.sourceRevision)
		var source_id := "resident-terrain:%d,%d,%d" % [section.x, section.y, section.z]
		var section_origin := Vector3(section * SECTION_SIZE) * CELL
		var empty_row := {"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":source_revision,
			"ownerCell":SectionGrid.logical_owner_cell_for_world_position(section_origin),
			"sectionKey":section}
		empty_row.make_read_only()
		var explicit_empty: Array[Dictionary] = [empty_row]
		explicit_empty.make_read_only()
		var no_inputs: Array[Dictionary] = []
		no_inputs.make_read_only()
		var no_compatibility: Dictionary = {}
		no_compatibility.make_read_only()
		var no_bindings: Dictionary = {}
		no_bindings.make_read_only()
		var authority_revisions: Dictionary = {source_part_id:source_revision}
		authority_revisions.make_read_only()
		contribution = {"providerId":"terrain", "sectionKey":section,
			"authoritySourceRevisions":authority_revisions, "inputs":no_inputs,
			"compatibilityByKey":no_compatibility, "materialBindings":no_bindings,
			"meshBindings":no_bindings, "resourceBindings":no_bindings,
			"explicitEmptyContributors":explicit_empty}
	else:
		contribution = built.contribution.duplicate(false)
	contribution["coverageRevision"] = String(_active_contribution.coverageRevision)
	contribution["authorityRevision"] = String(_active_contribution.providerRevision)
	contribution.make_read_only()
	var sealed := {"contribution":contribution, "capture":immutable_capture,
		"worldId":String(_active_contribution.worldId),
		"providerRevision":String(_active_contribution.providerRevision),
		"coverageRevision":String(_active_contribution.coverageRevision),
		"sourcePartId":String(_active_contribution.sourcePartId),
		"sourceRevision":String(_active_contribution.sourceRevision),
		"materialDigest":String(built.get("materialDigest", "")),
		"explicitEmpty":built.get("status") == "empty"}
	sealed.make_read_only()
	_contributions_by_section[section] = sealed
	while _contributions_by_section.size() > MAX_RETAINED_RESULTS:
		_contributions_by_section.erase(_contributions_by_section.keys()[0])
	_active_contribution.clear()
	return {"status":"prepared", "sectionKey":section,
		"sourceRevision":String(sealed.sourceRevision),
		"explicitEmpty":bool(sealed.explicitEmpty),
		"meshBuildUsec":int(built.get("meshBuildUsec", 0))}


func _cached_contribution_is_current(cache: Dictionary, world_id: String,
		provider_revision: String, coverage_revision: String,
		source_part_id: String, source_revision: String) -> bool:
	if cache.is_empty() or not cache.is_read_only() \
			or String(cache.get("worldId", "")) != world_id \
			or String(cache.get("providerRevision", "")) != provider_revision \
			or String(cache.get("coverageRevision", "")) != coverage_revision \
			or String(cache.get("sourcePartId", "")) != source_part_id \
			or String(cache.get("sourceRevision", "")) != source_revision:
		return false
	var capture: Dictionary = cache.get("capture", {})
	if not _runtime.terrain_capture_authority_is_current(capture):
		return false
	if bool(cache.get("explicitEmpty", false)):
		return true
	var material: Material = _runtime.terrain.material_override if is_instance_valid(_runtime.terrain) else null
	return is_instance_valid(material) and _material_digest(material) == String(cache.get("materialDigest", ""))


func _blocked_contribution_matches(blocked: Dictionary, world_id: String,
		provider_revision: String, coverage_revision: String,
		source_part_id: String, source_revision: String) -> bool:
	return not blocked.is_empty() \
		and String(blocked.get("worldId", "")) == world_id \
		and String(blocked.get("providerRevision", "")) == provider_revision \
		and String(blocked.get("coverageRevision", "")) == coverage_revision \
		and String(blocked.get("sourcePartId", "")) == source_part_id \
		and String(blocked.get("sourceRevision", "")) == source_revision


func _defer_active_contribution(reason: String, detail := {}) -> Dictionary:
	if not _active_contribution.is_empty():
		# Dictionaries are reference values. Preserve an independent retry record
		# before clearing the active work item, or the queued row is cleared too.
		_contribution_requests.append(_active_contribution.duplicate())
	_active_contribution.clear()
	return _pending(reason, detail)


func _block_active_contribution(reason: String, detail := {}) -> Dictionary:
	if not _active_contribution.is_empty():
		var blocked := {"worldId":String(_active_contribution.get("worldId", "")),
			"providerRevision":String(_active_contribution.get("providerRevision", "")),
			"coverageRevision":String(_active_contribution.get("coverageRevision", "")),
			"sourcePartId":String(_active_contribution.get("sourcePartId", "")),
			"sourceRevision":String(_active_contribution.get("sourceRevision", "")),
			"reason":reason}
		blocked.make_read_only()
		_blocked_contributions_by_section[_active_contribution.sectionKey] = blocked
		while _blocked_contributions_by_section.size() > MAX_RETAINED_RESULTS:
			_blocked_contributions_by_section.erase(_blocked_contributions_by_section.keys()[0])
	_active_contribution.clear()
	return _pending(reason, detail)


func _build_candidate(capture: Dictionary, source_part_id: String,
		source_revision: String) -> Dictionary:
	var size: Vector3i = capture.get("size", Vector3i.ZERO)
	var voxel_buffer := VoxelBuffer.new()
	voxel_buffer.create(size.x, size.y, size.z)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, capture.sdf16Le)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, capture.indices8)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, capture.data5_8)
	var terrain = _runtime.terrain
	var mesh_started_usec := Time.get_ticks_usec()
	var mesh: Mesh = terrain.mesher.build_mesh(voxel_buffer, [])
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
	var mesh_resource_key := "resident-transvoxel:" + String(binding.contentDigest)
	var material_digest := _material_digest(material)
	if material_digest.is_empty():
		return {"status":"pending", "reason":"production_terrain_material_digest_unavailable",
			"retryable":true, "meshBuildUsec":mesh_build_usec}
	var material_key := "production-terrain-shader|sha256=" + material_digest
	var segment_id := source_id + ":mesh"
	var mesh_bounds := mesh.get_aabb()
	if not _mesh_bounds_fit_native_block(mesh_bounds):
		return {"status":"failed", "reason":"transvoxel_mesh_origin_outside_native_block",
			"meshLocalBounds":mesh_bounds, "meshBuildUsec":mesh_build_usec}
	var pipeline_revision := "voxel-mesher-transvoxel:s4:no-transitions:v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [
		mesh_resource_key, pipeline_revision]
	var declaration_segment: Dictionary = {"segmentId":segment_id,
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":"structural", "meshKey":mesh_resource_key,
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
		"renderTier":"structural", "meshKey":mesh_resource_key, "meshContentDigest":binding.contentDigest,
		"meshLocalBounds":mesh_bounds, "pipelineRevision":pipeline_revision,
		"renderLayer":"opaque", "translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	prepared_segment.make_read_only()
	var compatibility := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":"structural",
		"meshResourceKey":mesh_resource_key, "meshContentDigest":String(binding.contentDigest),
		"meshKey":mesh_key, "pipelineRevision":pipeline_revision,
		"renderLayer":"opaque", "translucentSortPolicy":"none",
		"meshLocalBounds":mesh_bounds, "castShadows":true,
		"visibilityRangeEnd":100000.0, "fadeMargin":0.0}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty():
		return {"status":"failed", "reason":"terrain_section_batch_compatibility_invalid",
			"meshBuildUsec":mesh_build_usec}
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	var buffer: Array[float] = []
	for value: float in InstanceAttributes.encode(Transform3D.IDENTITY,
		Color.WHITE, Color.WHITE):
		buffer.append(value)
	buffer.make_read_only()
	var section_origin := Vector3(block * SECTION_SIZE) * CELL
	var input := {"schema":"terrain-static-section-input/v1",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":source_revision, "segmentId":segment_id,
		"ownerCell":SectionGrid.logical_owner_cell_for_world_position(section_origin),
		"sourceToWorld":Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * CELL), section_origin),
		"batchKey":batch_key, "meshKey":mesh_resource_key,
		"meshContentDigest":String(binding.contentDigest), "materialKey":material_key,
		"meshLocalBounds":mesh_bounds, "renderLayer":"opaque",
		"translucentSortPolicy":"none", "renderTier":"structural",
		"pipelineRevision":pipeline_revision, "compatibilityKey":batch_key,
		"castShadows":true, "visibilityRangeEnd":100000.0, "fadeMargin":0.0,
		"buffer":buffer, "instanceCount":1}
	input.make_read_only()
	var inputs: Array[Dictionary] = [input]
	inputs.make_read_only()
	var compatibility_by_key: Dictionary = {batch_key:compatibility}
	compatibility_by_key.make_read_only()
	var materials: Dictionary = {material_key:material}
	var meshes: Dictionary = {mesh_resource_key:mesh, mesh_key:mesh}
	var resource: Dictionary = {"material":material, "mesh":mesh}
	resource.make_read_only()
	var resources: Dictionary = {batch_key:resource}
	materials.make_read_only()
	meshes.make_read_only()
	resources.make_read_only()
	var contribution := {"providerId":"terrain", "sectionKey":block,
		"authoritySourceRevisions":{source_part_id:source_revision},
		"inputs":inputs, "compatibilityByKey":compatibility_by_key,
		"materialBindings":materials, "meshBindings":meshes,
		"resourceBindings":resources}
	contribution.authoritySourceRevisions.make_read_only()
	contribution.make_read_only()
	return {"status":"ready", "declarations":declarations, "removals":removals,
		"preparedSegment":prepared_segment, "materials":materials,
		"meshes":meshes, "mesh":mesh, "meshDigest":binding.contentDigest,
		"materialDigest":material_digest, "contribution":contribution,
		"meshBuildUsec":mesh_build_usec, "meshBounds":mesh_bounds}


func _material_digest(material: Material) -> String:
	if not is_instance_valid(material):
		return ""
	var properties: Array = []
	for property: Dictionary in material.get_property_list():
		var name := String(property.get("name", ""))
		if name.is_empty() or name.begins_with("resource_") \
				or name in ["script", "resource_local_to_scene"]:
			continue
		var value: Variant = material.get(name)
		if value is Shader:
			value = ["Shader", String(value.code)]
		elif value is Resource:
			var resource := value as Resource
			value = [resource.get_class(), resource.resource_path]
		elif value is Object or value is Callable:
			return ""
		properties.append([name, value])
	properties.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([material.get_class(), properties])) != OK:
		return ""
	return context.finish().hex_encode()


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


func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


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
	_active_contribution.clear()
	_contribution_requests.clear()
	_contributions_by_section.clear()
	_blocked_contributions_by_section.clear()


func shutdown() -> void:
	_cancel_active_boundary()
	_active.clear()
	_requests.clear()
	_results.clear()
	_active_contribution.clear()
	_contribution_requests.clear()
	_contributions_by_section.clear()
	_blocked_contributions_by_section.clear()
	_runtime = null
