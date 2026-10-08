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
const MAX_RETAINED_FLUID_PAYLOADS := 4
const MAX_RETAINED_FLUID_PAYLOAD_BYTES := 512 * 1024
const MAX_RETAINED_CANONICAL_FLUID_BYTES := 32 * 1024 * 1024
const MeshFingerprint = preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SectionGrid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceBuffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const InstanceAttributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const AuthoritativeTerrainSnapshot = preload("res://scripts/terrain/AuthoritativeTerrainSectionSnapshot.gd")

var _runtime
var _next_ticket := 1
var _requests: Array[Dictionary] = []
var _active: Dictionary = {}
var _results: Dictionary = {}
var _contribution_requests: Array[Dictionary] = []
var _active_contribution: Dictionary = {}
var _contributions_by_section: Dictionary = {}
var _blocked_contributions_by_section: Dictionary = {}
var _fluid_payloads_by_section: Dictionary = {}
var _canonical_fluid_by_section: Dictionary = {}
var _fluid_payload_bytes := 0
var _canonical_fluid_bytes := 0
var _terrain_generation_thread: Thread
var _terrain_generation_token: AuthoritativeTerrainSnapshot.CancellationToken
var _terrain_generation_prepared: Dictionary = {}
var _terrain_generation_section := Vector3i.ZERO


func setup(runtime) -> Dictionary:
	if runtime == null or _runtime != null:
		return {"status":"failed", "reason":"terrain_shadow_publisher_owner_invalid"}
	_runtime = runtime
	return {"status":"ready"}


## Fluid cell snapshots are larger than the durable proof rows. Keep only a
## small bounded candidate-input cache and bind each payload to exact revisions.
func retain_exact_fluid_payload(section_key: Vector3i, payload_value: Dictionary,
		proof: Dictionary) -> Dictionary:
	if _runtime == null or not bool(payload_value.get("immutable", false)) \
			or not bool(proof.get("hasFluid", false)) \
			or proof.get("sectionKey") != section_key \
			or not _runtime._terrain_section_fluid_proof_is_current(section_key, proof):
		return {"status":"failed", "reason":"exact_fluid_candidate_payload_identity_invalid"}
	var payload := payload_value.duplicate(true)
	var cells_value: Variant = payload.get("cells", null)
	var revisions_value: Variant = payload.get("sectionRevisions", null)
	var schema_value: Variant = payload.get("fluidTypeSchema", null)
	if not cells_value is Dictionary or not revisions_value is Array \
			or not schema_value is Dictionary:
		return {"status":"failed", "reason":"exact_fluid_candidate_payload_shape_invalid"}
	(cells_value as Dictionary).make_read_only()
	for row_value: Variant in revisions_value:
		if not row_value is Dictionary:
			return {"status":"failed", "reason":"exact_fluid_candidate_revision_row_invalid"}
		(row_value as Dictionary).make_read_only()
	(revisions_value as Array).make_read_only()
	(schema_value as Dictionary).make_read_only()
	payload["cells"] = cells_value
	payload["sectionRevisions"] = revisions_value
	payload["fluidTypeSchema"] = schema_value
	payload.make_read_only()
	var payload_bytes := _exact_fluid_payload_bytes(payload)
	if payload_bytes <= 0 or payload_bytes > MAX_RETAINED_FLUID_PAYLOAD_BYTES:
		return {"status":"failed", "reason":"exact_fluid_candidate_payload_size_invalid",
			"payloadBytes":payload_bytes}
	_release_fluid_payload(section_key)
	var retained := {"sectionKey":section_key,
		"volumeRevision":int(proof.get("volumeRevision", -1)),
		"fluidRevision":int(proof.get("fluidRevision", -1)),
		"signature":String(proof.get("signature", "")), "payloadBytes":payload_bytes,
		"payload":payload}
	retained.make_read_only()
	_fluid_payloads_by_section[section_key] = retained
	_fluid_payload_bytes += payload_bytes
	while _fluid_payloads_by_section.size() > MAX_RETAINED_FLUID_PAYLOADS \
			or _fluid_payload_bytes > MAX_RETAINED_FLUID_PAYLOAD_BYTES:
		_release_fluid_payload(_fluid_payloads_by_section.keys()[0])
	return {"status":"ready", "sectionKey":section_key,
		"volumeRevision":int(retained.volumeRevision), "signature":String(retained.signature),
		"retainedFluidPayloadCount":_fluid_payloads_by_section.size(),
		"retainedFluidPayloadBytes":_fluid_payload_bytes,
		"retainedCanonicalFluidBytes":_canonical_fluid_bytes}


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
## before the contribution is returned. Fluid groups are section local and
## camera sorted before snapshot admission; their candidate carries the POV class.
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
	var proof: Dictionary = _runtime.terrain_section_fluid_proofs.get(section_key, {})
	if not _runtime._terrain_section_fluid_proof_is_current(section_key, proof):
		_runtime.request_terrain_section_fluid_probe(section_key)
		return _pending("terrain_exact_fluid_section_probe_pending", {
			"sectionKey":section_key, "stage":"fluid_validation"})
	var pov_revision := 0
	var pov_snapshot: Dictionary = {}
	if bool(proof.get("hasFluid", false)):
		var coordinator = _runtime.main.get("world_static_section_coordinator") \
			if is_instance_valid(_runtime.main) else null
		if coordinator == null or not coordinator.has_method("current_translucent_pov_snapshot"):
			return _pending("section_translucent_pov_snapshot_unavailable", {"sectionKey":section_key})
		pov_snapshot = coordinator.call("current_translucent_pov_snapshot", section_key)
		if not _translucent_pov_snapshot_is_valid(pov_snapshot, section_key):
			return _pending(String(pov_snapshot.get("reason", "section_translucent_pov_snapshot_pending")), {
				"sectionKey":section_key})
		pov_revision = int(pov_snapshot.get("revision", -1))
	var cache: Dictionary = _contributions_by_section.get(section_key, {})
	if _cached_contribution_is_current(cache, world_id, provider_revision,
			coverage_revision, source_part_id, source_revision, pov_revision):
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
		"sourcePartId":source_part_id, "sourceRevision":source_revision,
		"povRevision":pov_revision, "povSnapshot":pov_snapshot, "stage":"capture"})
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
		_release_fluid_payload(section)
		_release_canonical_fluid(section)
		return _discard_active_terrain_generation(
			"terrain_contribution_census_changed_before_capture", {"sectionKey":section})
	var proof: Dictionary = _runtime.terrain_section_fluid_proofs.get(section, {})
	if not _runtime._terrain_section_fluid_proof_is_current(section, proof):
		_release_fluid_payload(section)
		_release_canonical_fluid(section)
		_runtime.request_terrain_section_fluid_probe(section)
		return _defer_active_contribution("terrain_exact_fluid_section_probe_pending", {
			"sectionKey":section, "stage":"fluid_validation"})
	var fluid_payload: Dictionary = {}
	var pov_snapshot: Dictionary = {}
	if bool(proof.get("hasFluid", false)):
		var retained: Dictionary = _fluid_payloads_by_section.get(section, {})
		var canonical: Dictionary = _canonical_fluid_by_section.get(section, {})
		var retained_matches := not retained.is_empty() \
			and String(retained.get("signature", "")) == String(proof.get("signature", "")) \
			and int(retained.get("volumeRevision", -1)) == int(proof.get("volumeRevision", -2)) \
			and int(retained.get("fluidRevision", -1)) == int(proof.get("fluidRevision", -2))
		var canonical_matches := not canonical.is_empty() \
			and String(canonical.get("signature", "")) == String(proof.get("signature", "")) \
			and int(canonical.get("volumeRevision", -1)) == int(proof.get("volumeRevision", -2)) \
			and int(canonical.get("fluidRevision", -1)) == int(proof.get("fluidRevision", -2))
		if not retained_matches and not canonical_matches:
			_runtime.terrain_section_fluid_proofs.erase(section)
			_runtime.request_terrain_section_fluid_probe(section)
			if String(_active_contribution.get("stage", "")) == "worker_generation":
				return _defer_active_contribution("terrain_exact_fluid_candidate_payload_evicted", {
					"sectionKey":section, "stage":"worker_generation"})
			_active_contribution.erase("capture")
			_active_contribution["stage"] = "capture"
			return _defer_active_contribution("terrain_exact_fluid_candidate_payload_evicted", {
				"sectionKey":section, "stage":"fluid_payload"})
		if retained_matches:
			fluid_payload = retained.payload
		var coordinator = _runtime.main.get("world_static_section_coordinator") \
			if is_instance_valid(_runtime.main) else null
		if coordinator == null or not coordinator.has_method("current_translucent_pov_snapshot"):
			return _defer_active_contribution("section_translucent_pov_snapshot_unavailable", {
				"sectionKey":section, "stage":"translucent_pov"})
		pov_snapshot = coordinator.call("current_translucent_pov_snapshot", section)
		if not _translucent_pov_snapshot_is_valid(pov_snapshot, section):
			return _defer_active_contribution(String(pov_snapshot.get("reason",
				"section_translucent_pov_snapshot_pending")), {
				"sectionKey":section, "stage":"translucent_pov"})
		if int(pov_snapshot.get("revision", -1)) != int(_active_contribution.get("povRevision", -1)):
			_active_contribution["povRevision"] = int(pov_snapshot.get("revision", -1))
			if not _active_contribution.has("capture"):
				if String(_active_contribution.get("stage", "")) == "worker_generation":
					return _defer_active_contribution("terrain_translucent_pov_changed_during_generation", {
						"sectionKey":section, "stage":"worker_generation"})
				_active_contribution["stage"] = "capture"
	else:
		_release_fluid_payload(section)
		_release_canonical_fluid(section)
	if String(_active_contribution.get("stage", "capture")) == "capture":
		return _start_authoritative_section_generation(section, proof)
	if String(_active_contribution.get("stage", "")) == "worker_generation":
		return _advance_authoritative_section_generation(section, proof)
	var immutable_capture: Dictionary = _active_contribution.get("capture", {})
	if not _terrain_contribution_capture_is_current(immutable_capture, proof):
		_active_contribution.clear()
		return _pending("terrain_contribution_capture_stale_before_meshing", {
			"sectionKey":section})
	var built := _build_candidate(immutable_capture,
		String(_active_contribution.sourcePartId), String(_active_contribution.sourceRevision),
		fluid_payload, pov_snapshot)
	if built.get("status") not in ["ready", "empty"] \
			or (built.get("status") == "ready" and not built.get("contribution") is Dictionary):
		_active_contribution.clear()
		return built
	if bool(proof.get("hasFluid", false)):
		var coordinator = _runtime.main.get("world_static_section_coordinator") \
			if is_instance_valid(_runtime.main) else null
		if coordinator == null or not coordinator.has_method("current_translucent_pov_snapshot"):
			return _defer_active_contribution("section_translucent_pov_snapshot_unavailable", {
				"sectionKey":section, "stage":"translucent_pov_revalidation"})
		var latest_pov: Dictionary = coordinator.call("current_translucent_pov_snapshot", section)
		if not _translucent_pov_snapshot_is_valid(latest_pov, section):
			return _defer_active_contribution(String(latest_pov.get("reason",
				"section_translucent_pov_snapshot_pending")), {
				"sectionKey":section, "stage":"translucent_pov_revalidation"})
		if int(latest_pov.get("revision", -1)) != int(_active_contribution.get("povRevision", -1)):
			_active_contribution["povRevision"] = int(latest_pov.get("revision", -1))
			return _pending("terrain_translucent_pov_changed_after_mesh_prepare", {
				"sectionKey":section, "stage":"mesh_prepare",
				"povRevision":int(latest_pov.get("revision", -1)), "retryable":true})
	var latest: Dictionary = _runtime.capture_static_section_sources(
		String(_active_contribution.worldId), [section])
	if latest.get("status") != "complete" \
			or String(latest.get("authorityRevision", "")) != String(_active_contribution.providerRevision) \
			or String(latest.get("sections", {}).get(section, {}).get("coverageRevision", "")) \
			!= String(_active_contribution.coverageRevision) \
			or String(latest.get("sourceRevisions", {}).get(_active_contribution.sourcePartId, "")) \
			!= String(_active_contribution.sourceRevision) \
			or not _terrain_contribution_capture_is_current(immutable_capture, proof):
		_release_fluid_payload(section)
		_release_canonical_fluid(section)
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
		"povRevision":int(_active_contribution.get("povRevision", 0)),
		"materialDigest":String(built.get("materialDigest", "")),
		"explicitEmpty":built.get("status") == "empty"}
	sealed.make_read_only()
	_contributions_by_section[section] = sealed
	_release_fluid_payload(section)
	while _contributions_by_section.size() > MAX_RETAINED_RESULTS:
		_contributions_by_section.erase(_contributions_by_section.keys()[0])
	_active_contribution.clear()
	return {"status":"prepared", "sectionKey":section,
		"sourceRevision":String(sealed.sourceRevision),
		"explicitEmpty":bool(sealed.explicitEmpty),
		"meshBuildUsec":int(built.get("meshBuildUsec", 0))}


func _cached_contribution_is_current(cache: Dictionary, world_id: String,
		provider_revision: String, coverage_revision: String,
		source_part_id: String, source_revision: String, pov_revision: int) -> bool:
	if cache.is_empty() or not cache.is_read_only() \
			or String(cache.get("worldId", "")) != world_id \
			or String(cache.get("providerRevision", "")) != provider_revision \
			or String(cache.get("coverageRevision", "")) != coverage_revision \
			or String(cache.get("sourcePartId", "")) != source_part_id \
			or String(cache.get("sourceRevision", "")) != source_revision \
			or int(cache.get("povRevision", 0)) != pov_revision:
		return false
	var capture: Dictionary = cache.get("capture", {})
	var proof: Dictionary = _runtime.terrain_section_fluid_proofs.get(
		capture.get("sectionKey", Vector3i.ZERO), {})
	if not _terrain_contribution_capture_is_current(capture, proof):
		return false
	if bool(cache.get("explicitEmpty", false)):
		return true
	var material: Material = _runtime.terrain.material_override if is_instance_valid(_runtime.terrain) else null
	return is_instance_valid(material) and _material_digest(material) == String(cache.get("materialDigest", ""))


func _start_authoritative_section_generation(section_key: Vector3i,
		fluid_proof: Dictionary) -> Dictionary:
	if _terrain_generation_thread != null and _terrain_generation_thread.is_alive():
		return _defer_active_contribution("terrain_section_worker_slot_busy", {
			"sectionKey":section_key, "stage":"worker_generation"})
	var world_id := String(_active_contribution.get("worldId", ""))
	var volume = _runtime.volume_service()
	var prepared_result: Dictionary = AuthoritativeTerrainSnapshot.prepare(
		_runtime.generator, volume, section_key, world_id,
		_runtime._terrain_capture_mesher_material_revision(), fluid_proof)
	if prepared_result.get("status") != "ready":
		return _defer_active_contribution(String(prepared_result.get("reason",
			"terrain_authoritative_section_prepare_pending")), {
			"sectionKey":section_key, "stage":"source_capture"})
	var prepared: Dictionary = prepared_result.get("prepared", {})
	if not prepared.is_read_only():
		_active_contribution.clear()
		return {"status":"failed", "reason":"terrain_authoritative_section_input_not_immutable",
			"retryable":false, "sectionKey":section_key}
	var token := AuthoritativeTerrainSnapshot.CancellationToken.new()
	var thread := Thread.new()
	var start_error := thread.start(Callable(AuthoritativeTerrainSnapshot,
		"generate_prepared").bind(prepared, token))
	if start_error != OK:
		_active_contribution.clear()
		return _pending("terrain_section_worker_start_failed", {
			"sectionKey":section_key, "threadError":start_error})
	_terrain_generation_thread = thread
	_terrain_generation_token = token
	_terrain_generation_prepared = prepared
	_terrain_generation_section = section_key
	_active_contribution["prepared"] = prepared
	_active_contribution["stage"] = "worker_generation"
	_active_contribution["workerStartedUsec"] = Time.get_ticks_usec()
	return _pending("terrain_authoritative_section_worker_started", {
		"sectionKey":section_key, "stage":"worker_generation"})


func _advance_authoritative_section_generation(section_key: Vector3i,
		fluid_proof: Dictionary) -> Dictionary:
	if _terrain_generation_thread == null \
			or _terrain_generation_section != section_key \
			or _terrain_generation_prepared.is_empty():
		_active_contribution.clear()
		return _pending("terrain_authoritative_section_worker_identity_lost", {
			"sectionKey":section_key})
	var prepared: Dictionary = _terrain_generation_prepared
	var volume = _runtime.volume_service()
	var world_id := String(_active_contribution.get("worldId", ""))
	if not AuthoritativeTerrainSnapshot.prepared_is_current(prepared,
			_runtime.generator, volume, world_id,
			_runtime._terrain_capture_mesher_material_revision(), fluid_proof):
		_terrain_generation_token.cancel()
		if _terrain_generation_thread.is_alive():
			return _pending("terrain_authoritative_section_worker_cancel_pending", {
				"sectionKey":section_key, "stage":"worker_generation"})
		_terrain_generation_thread.wait_to_finish()
		_clear_terrain_generation_owner()
		_active_contribution.clear()
		return _pending("terrain_authoritative_section_worker_stale_discarded", {
			"sectionKey":section_key})
	if _terrain_generation_thread.is_alive():
		return _pending("terrain_authoritative_section_worker_running", {
			"sectionKey":section_key, "stage":"worker_generation"})
	var generated_value: Variant = _terrain_generation_thread.wait_to_finish()
	var generated_result: Dictionary = generated_value if generated_value is Dictionary else {}
	if generated_result.get("status") == "cancelled":
		_clear_terrain_generation_owner()
		_active_contribution.clear()
		return _pending("terrain_authoritative_section_worker_cancelled", {
			"sectionKey":section_key})
	if generated_result.get("status") != "ready":
		_clear_terrain_generation_owner()
		_active_contribution.clear()
		return {"status":"failed", "reason":String(generated_result.get("reason",
			"terrain_authoritative_section_worker_failed")),
			"detail":generated_result, "sectionKey":section_key}
	var sealed: Dictionary = AuthoritativeTerrainSnapshot.seal(prepared,
		generated_result, _runtime.generator, volume, world_id,
		_runtime._terrain_capture_mesher_material_revision(), fluid_proof)
	_clear_terrain_generation_owner()
	if sealed.get("status") != "ready":
		_active_contribution.clear()
		return _pending(String(sealed.get("reason",
			"terrain_authoritative_section_seal_pending")), {"sectionKey":section_key})
	var capture: Dictionary = sealed.capture
	var census_revision := String(_active_contribution.get("sourceRevision", ""))
	if String(capture.get("sourceRevision", "")) != census_revision:
		_active_contribution.clear()
		return _pending("terrain_authoritative_section_census_revision_mismatch", {
			"sectionKey":section_key,
			"candidateSourceRevision":String(capture.get("sourceRevision", "")),
			"censusSourceRevision":census_revision})
	_active_contribution["capture"] = capture
	_active_contribution["generationUsec"] = int(capture.get("generationUsec", 0))
	_active_contribution["stage"] = "mesh_prepare"
	return _pending("terrain_authoritative_section_worker_sealed", {
		"sectionKey":section_key, "stage":"mesh_prepare",
		"generationUsec":int(capture.get("generationUsec", 0))})


func _terrain_contribution_capture_is_current(capture: Dictionary,
		fluid_proof: Dictionary) -> bool:
	if String(capture.get("schema", "")) == "authoritative-terrain-section/v1":
		return _runtime.authoritative_terrain_section_capture_is_current(capture)
	return _runtime.terrain_capture_authority_is_current(capture)


func _clear_terrain_generation_owner() -> void:
	_terrain_generation_thread = null
	_terrain_generation_token = null
	_terrain_generation_prepared = {}
	_terrain_generation_section = Vector3i.ZERO


func _cancel_active_terrain_generation(wait_for_completion := false) -> bool:
	if _terrain_generation_thread == null:
		return true
	if is_instance_valid(_terrain_generation_token):
		_terrain_generation_token.cancel()
	if _terrain_generation_thread.is_alive():
		if not wait_for_completion:
			return false
	_terrain_generation_thread.wait_to_finish()
	_clear_terrain_generation_owner()
	return true


func _discard_active_terrain_generation(reason: String, detail := {}) -> Dictionary:
	if String(_active_contribution.get("stage", "")) == "worker_generation" \
			and not _cancel_active_terrain_generation():
		var waiting := detail.duplicate(true) if detail is Dictionary else {}
		waiting["workerCancellationPending"] = true
		return _pending(reason, waiting)
	_active_contribution.clear()
	return _pending(reason, detail)


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
		if String(_active_contribution.get("stage", "")) == "worker_generation" \
				and not _cancel_active_terrain_generation():
			var waiting := detail.duplicate(true) if detail is Dictionary else {}
			waiting["workerCancellationPending"] = true
			return _pending(reason, waiting)
		# Dictionaries are reference values. Preserve an independent retry record
		# before clearing the active work item, or the queued row is cleared too.
		var retry := _active_contribution.duplicate()
		retry.erase("prepared")
		retry.erase("capture")
		retry["stage"] = "capture"
		_contribution_requests.append(retry)
	_active_contribution.clear()
	return _pending(reason, detail)


func _translucent_pov_snapshot_is_valid(snapshot: Dictionary,
		section_key: Vector3i) -> bool:
	var camera_value: Variant = snapshot.get("cameraPosition", null)
	var revision_value: Variant = snapshot.get("revision", null)
	return snapshot.get("status") == "ready" \
		and snapshot.get("sectionKey") == section_key \
		and camera_value is Vector3 and camera_value.is_finite() \
		and revision_value is int and revision_value > 0


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
		source_revision: String, fluid_payload: Dictionary = {},
		pov_snapshot: Dictionary = {}) -> Dictionary:
	var size: Vector3i = capture.get("size", Vector3i.ZERO)
	var sdf_bytes: PackedByteArray
	var indices_bytes: PackedByteArray
	var data5_bytes: PackedByteArray
	if String(capture.get("schema", "")) == "authoritative-terrain-section/v1":
		sdf_bytes = Marshalls.base64_to_raw(String(capture.get("sdf16LeBase64", "")))
		indices_bytes = Marshalls.base64_to_raw(String(capture.get("indices8Base64", "")))
		data5_bytes = Marshalls.base64_to_raw(String(capture.get("data5_8Base64", "")))
	else:
		sdf_bytes = capture.get("sdf16Le", PackedByteArray())
		indices_bytes = capture.get("indices8", PackedByteArray())
		data5_bytes = capture.get("data5_8", PackedByteArray())
	var sample_count := size.x * size.y * size.z
	if sdf_bytes.size() != sample_count * 2 or indices_bytes.size() != sample_count \
			or data5_bytes.size() != sample_count:
		return {"status":"failed", "reason":"terrain_section_capture_channel_size_invalid",
			"sectionKey":capture.get("sectionKey", capture.get("block", Vector3i.ZERO)),
			"sdfBytes":sdf_bytes.size(), "indicesBytes":indices_bytes.size(),
			"data5Bytes":data5_bytes.size()}
	var voxel_buffer := VoxelBuffer.new()
	voxel_buffer.create(size.x, size.y, size.z)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	voxel_buffer.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, sdf_bytes)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, indices_bytes)
	voxel_buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, data5_bytes)
	var terrain = _runtime.terrain
	var mesh_started_usec := Time.get_ticks_usec()
	var mesh: Mesh = terrain.mesher.build_mesh(voxel_buffer, [])
	var mesh_build_usec := Time.get_ticks_usec() - mesh_started_usec
	if mesh == null or mesh.get_surface_count() == 0:
		if bool(fluid_payload.get("immutable", false)):
			return _build_fluid_only_contribution(capture, source_part_id,
				source_revision, fluid_payload, pov_snapshot, mesh_build_usec)
		return {"status":"empty", "reason":"authoritative_transvoxel_candidate_has_no_surfaces",
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
	var compatibility_by_key: Dictionary = {batch_key:compatibility}
	var materials: Dictionary = {material_key:material}
	var meshes: Dictionary = {mesh_resource_key:mesh, mesh_key:mesh}
	var resource: Dictionary = {"material":material, "mesh":mesh}
	resource.make_read_only()
	var resources: Dictionary = {batch_key:resource}
	var fluid_mesh_build_usec := 0
	if bool(fluid_payload.get("immutable", false)):
		var fluid_prepared := _append_fluid_candidate_inputs(fluid_payload, pov_snapshot,
			block, source_id, source_part_id, source_revision,
			Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * CELL), section_origin),
			SectionGrid.logical_owner_cell_for_world_position(section_origin),
			inputs, compatibility_by_key, materials, meshes, resources)
		if fluid_prepared.get("status") != "ready":
			return fluid_prepared
		fluid_mesh_build_usec = int(fluid_prepared.get("meshBuildUsec", 0))
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
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
		"translucentMeshBuildUsec":fluid_mesh_build_usec,
		"meshBuildUsec":mesh_build_usec,
		"generationUsec":int(capture.get("generationUsec", 0)),
		"payloadDigest":String(capture.get("payloadDigest", "")),
		"meshBounds":mesh_bounds}


func _build_fluid_only_contribution(capture: Dictionary, source_part_id: String,
		source_revision: String, fluid_payload: Dictionary, pov_snapshot: Dictionary,
		mesh_build_usec: int) -> Dictionary:
	var section_key: Vector3i = capture.get("block", Vector3i.ZERO)
	var source_id := "resident-terrain:%d,%d,%d" % [section_key.x, section_key.y, section_key.z]
	var section_origin := Vector3(section_key * SECTION_SIZE) * CELL
	var source_to_world := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * CELL), section_origin)
	var owner_cell := SectionGrid.logical_owner_cell_for_world_position(section_origin)
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var materials: Dictionary = {}
	var meshes: Dictionary = {}
	var resources: Dictionary = {}
	var fluid_prepared := _append_fluid_candidate_inputs(fluid_payload, pov_snapshot,
		section_key, source_id, source_part_id, source_revision, source_to_world,
		owner_cell, inputs, compatibility_by_key, materials, meshes, resources)
	if fluid_prepared.get("status") != "ready":
		return fluid_prepared
	if inputs.is_empty():
		return {"status":"empty", "reason":"terrain_section_has_no_renderable_opaque_or_fluid_surfaces",
			"meshBuildUsec":mesh_build_usec,
			"translucentMeshBuildUsec":int(fluid_prepared.get("meshBuildUsec", 0))}
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	materials.make_read_only()
	meshes.make_read_only()
	resources.make_read_only()
	var source_revisions := {source_part_id:source_revision}
	source_revisions.make_read_only()
	var contribution := {"providerId":"terrain", "sectionKey":section_key,
		"authoritySourceRevisions":source_revisions, "inputs":inputs,
		"compatibilityByKey":compatibility_by_key, "materialBindings":materials,
		"meshBindings":meshes, "resourceBindings":resources}
	contribution.make_read_only()
	return {"status":"ready", "contribution":contribution,
		"declarations":[], "removals":[], "preparedSegment":{},
		"materials":materials, "meshes":meshes, "mesh":null, "meshDigest":"",
		"materialDigest":_material_digest(_runtime.terrain.material_override),
		"translucentMeshBuildUsec":int(fluid_prepared.get("meshBuildUsec", 0)),
		"meshBuildUsec":mesh_build_usec, "meshBounds":AABB()}


func _append_fluid_candidate_inputs(payload: Dictionary, pov_snapshot: Dictionary,
		section_key: Vector3i, source_id: String, source_part_id: String,
		source_revision: String, source_to_world: Transform3D, owner_cell: Vector2i,
		inputs: Array[Dictionary], compatibility_by_key: Dictionary,
		materials: Dictionary, meshes: Dictionary, resources: Dictionary) -> Dictionary:
	var world_camera: Variant = pov_snapshot.get("cameraPosition")
	var pov_revision: Variant = pov_snapshot.get("revision")
	if not _translucent_pov_snapshot_is_valid(pov_snapshot, section_key) \
			or not world_camera is Vector3 \
		or not world_camera.is_finite() or not pov_revision is int or pov_revision <= 0:
		return {"status":"pending", "reason":"section_translucent_pov_snapshot_unavailable",
			"retryable":true}
	var section_origin_meters := Vector3(section_key * SECTION_SIZE) * CELL
	var camera_local_meters: Vector3 = world_camera - section_origin_meters
	var main = _runtime.main
	var service = main.get("terrain_meshing_service") if is_instance_valid(main) else null
	if service == null or not service.has_method("build_section_fluid_surface_data") \
			or not service.has_method("section_fluid_mesh_from_surface_data"):
		return {"status":"pending", "reason":"section_fluid_mesh_service_unavailable",
			"retryable":true}
	var started_usec := Time.get_ticks_usec()
	var sorted_data: Dictionary
	var proof: Dictionary = _runtime.terrain_section_fluid_proofs.get(section_key, {})
	var retained_canonical: Dictionary = _canonical_fluid_by_section.get(section_key, {})
	if payload.is_empty() and not retained_canonical.is_empty() \
			and String(retained_canonical.get("signature", "")) == String(proof.get("signature", "")) \
			and int(retained_canonical.get("volumeRevision", -1)) == int(proof.get("volumeRevision", -2)) \
			and int(retained_canonical.get("fluidRevision", -1)) == int(proof.get("fluidRevision", -2)):
		sorted_data = service.call("sort_section_fluid_surface_data",
			retained_canonical.get("canonicalData", {}), camera_local_meters)
	else:
		if payload.is_empty():
			return {"status":"pending", "reason":"section_fluid_canonical_cache_unavailable",
				"retryable":true}
		sorted_data = service.call("build_section_fluid_surface_data",
			payload, section_key, camera_local_meters)
	if String(sorted_data.get("status", "")) != "ready":
		if String(sorted_data.get("status", "")) == "pending":
			return {"status":"pending", "reason":String(sorted_data.get("reason", "section_fluid_meshing_pending")),
				"retryable":true}
		return {"status":"failed", "reason":"section_fluid_meshing_rejected",
			"detail":sorted_data}
	if not payload.is_empty():
		var canonical_data := sorted_data.duplicate(false)
		for key in ["waterVertices", "waterNormals", "waterColors", "waterFaceGroups",
				"lavaVertices", "lavaNormals", "lavaColors", "lavaFaceGroups",
				"sortCameraPositionLocal"]:
			canonical_data.erase(key)
		canonical_data["status"] = "ready"
		canonical_data.make_read_only()
		var canonical_bytes := _canonical_fluid_data_bytes(canonical_data)
		if canonical_bytes <= 0 or canonical_bytes > MAX_RETAINED_CANONICAL_FLUID_BYTES:
			return {"status":"pending", "reason":"section_fluid_canonical_cache_size_exceeded",
				"retryable":true, "canonicalBytes":canonical_bytes}
		_release_canonical_fluid(section_key)
		var retained := {"signature":String(proof.get("signature", "")),
			"volumeRevision":int(proof.get("volumeRevision", -1)),
			"fluidRevision":int(proof.get("fluidRevision", -1)),
			"canonicalBytes":canonical_bytes, "canonicalData":canonical_data}
		retained.make_read_only()
		_canonical_fluid_by_section[section_key] = retained
		_canonical_fluid_bytes += canonical_bytes
		while _canonical_fluid_by_section.size() > MAX_RETAINED_FLUID_PAYLOADS:
			_release_canonical_fluid(_canonical_fluid_by_section.keys()[0])
		while _canonical_fluid_bytes > MAX_RETAINED_CANONICAL_FLUID_BYTES \
				and not _canonical_fluid_by_section.is_empty():
			_release_canonical_fluid(_canonical_fluid_by_section.keys()[0])
	var camera_local_cells := camera_local_meters / CELL
	for fluid_kind in ["water", "lava"]:
		var face_groups_value: Variant = sorted_data.get("%sFaceGroups" % fluid_kind, null)
		if not face_groups_value is Array:
			return {"status":"failed", "reason":"section_fluid_face_groups_missing"}
		if (face_groups_value as Array).is_empty():
			continue
		var mesh_value: Variant = service.call("section_fluid_mesh_from_surface_data",
			sorted_data, fluid_kind)
		if not mesh_value is ArrayMesh:
			return {"status":"failed", "reason":"section_fluid_array_mesh_creation_failed",
				"fluidKind":fluid_kind}
		var fluid_mesh := mesh_value as ArrayMesh
		var arrays: Array = fluid_mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex_index in range(vertices.size()):
			vertices[vertex_index] /= CELL
		arrays[Mesh.ARRAY_VERTEX] = vertices
		fluid_mesh.clear_surfaces()
		fluid_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		service.call("apply_fluid_materials", fluid_mesh)
		var fingerprint: Dictionary = MeshFingerprint.inspect(fluid_mesh)
		if fingerprint.get("status") != "ready":
			return {"status":"failed", "reason":"section_fluid_mesh_fingerprint_failed",
				"fluidKind":fluid_kind, "fingerprint":fingerprint}
		var mesh_digest := String(fingerprint.contentDigest)
		var mesh_resource_key := "resident-fluid:%d,%d,%d:%s:%s" % [
			section_key.x, section_key.y, section_key.z, fluid_kind, mesh_digest]
		var material_key := "production-fluid:%s" % fluid_kind
		var pipeline_revision := "exact-fluid-cell-surface:v1"
		var mesh_bounds := fluid_mesh.get_aabb()
		if not _mesh_bounds_fit_native_block(mesh_bounds):
			return {"status":"failed", "reason":"section_fluid_mesh_outside_section_bounds",
				"fluidKind":fluid_kind, "meshLocalBounds":mesh_bounds}
		var descriptor_groups: Array[Dictionary] = []
		for group_value: Variant in face_groups_value:
			if not group_value is Dictionary:
				return {"status":"failed", "reason":"section_fluid_face_group_invalid"}
			var group: Dictionary = group_value.duplicate(false)
			var centroid_value: Variant = group.get("centroid")
			if not centroid_value is Vector3:
				return {"status":"failed", "reason":"section_fluid_face_group_centroid_missing"}
			group["centroid"] = (centroid_value as Vector3) / CELL
			group.make_read_only()
			descriptor_groups.append(group)
		descriptor_groups.make_read_only()
		var surface_row := {"surfaceIndex":0, "faceGroups":descriptor_groups}
		surface_row.make_read_only()
		var surfaces: Array[Dictionary] = [surface_row]
		surfaces.make_read_only()
		var descriptor := {"schema":"section-translucent-face-groups/v1",
			"sectionKey":section_key, "sectionGeneration":-1,
			"povRevision":int(pov_revision), "cameraPosition":camera_local_cells,
			"meshContentDigest":mesh_digest, "surfaces":surfaces}
		descriptor.make_read_only()
		var sort_policy := "camera_depth"
		var mesh_key := "%s|pipeline=%s|layer=translucent|sort=%s" % [
			mesh_resource_key, pipeline_revision, sort_policy]
		var compatibility := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"materialKey":material_key, "renderTier":"structural",
			"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
			"meshKey":mesh_key, "pipelineRevision":pipeline_revision,
			"renderLayer":"translucent", "translucentSortPolicy":sort_policy,
			"translucentSortDescriptor":descriptor, "meshLocalBounds":mesh_bounds,
			"castShadows":false, "visibilityRangeEnd":100000.0, "fadeMargin":0.0}
		var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
		if batch_key.is_empty():
			return {"status":"failed", "reason":"section_fluid_batch_compatibility_invalid"}
		compatibility["batchKey"] = batch_key
		compatibility["compatibilityKey"] = batch_key
		compatibility.make_read_only()
		var segment_id := "%s:%s" % [source_id, fluid_kind]
		var buffer: Array[float] = []
		for component: float in InstanceAttributes.encode(Transform3D.IDENTITY,
				Color.WHITE, Color.WHITE):
			buffer.append(component)
		buffer.make_read_only()
		var input := {"schema":"terrain-static-section-input/v1",
			"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":source_revision, "segmentId":segment_id,
			"ownerCell":owner_cell, "sourceToWorld":source_to_world,
			"meshLocalBounds":mesh_bounds, "batchKey":batch_key,
			"meshKey":mesh_resource_key, "meshContentDigest":mesh_digest,
			"materialKey":material_key, "renderLayer":"translucent",
			"translucentSortPolicy":sort_policy, "renderTier":"structural",
			"pipelineRevision":pipeline_revision, "compatibilityKey":batch_key,
			"castShadows":false, "visibilityRangeEnd":100000.0,
			"fadeMargin":0.0, "buffer":buffer, "instanceCount":1}
		input.make_read_only()
		inputs.append(input)
		compatibility_by_key[batch_key] = compatibility
		var material: Material = null
		var material_map: Variant = main.get("materials") if is_instance_valid(main) else null
		if material_map is Dictionary:
			material = (material_map as Dictionary).get(fluid_kind, null) as Material
		if material == null and is_instance_valid(main):
			material = main.get("terrain_material") as Material
		if material == null:
			return {"status":"pending", "reason":"production_fluid_material_missing",
				"retryable":true, "fluidKind":fluid_kind}
		var resource := {"material":material, "mesh":fluid_mesh}
		resource.make_read_only()
		materials[material_key] = material
		meshes[mesh_resource_key] = fluid_mesh
		meshes[mesh_key] = fluid_mesh
		resources[batch_key] = resource
	return {"status":"ready", "meshBuildUsec":Time.get_ticks_usec() - started_usec}


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


func _exact_fluid_payload_bytes(payload: Dictionary) -> int:
	return JSON.stringify(payload).to_utf8_buffer().size()


func _canonical_fluid_data_bytes(data: Dictionary) -> int:
	var total := 0
	for key in ["canonicalWaterVertices", "canonicalWaterNormals", "canonicalWaterColors",
			"canonicalLavaVertices", "canonicalLavaNormals", "canonicalLavaColors"]:
		var value: Variant = data.get(key, null)
		if value is PackedVector3Array:
			total += (value as PackedVector3Array).size() * 12
		elif value is PackedColorArray:
			total += (value as PackedColorArray).size() * 16
	for key in ["waterFaceGroups", "lavaFaceGroups"]:
		var groups: Variant = data.get(key, null)
		if groups is Array:
			total += JSON.stringify(groups).to_utf8_buffer().size()
	return total


func _release_fluid_payload(section_key: Vector3i) -> void:
	var retained: Dictionary = _fluid_payloads_by_section.get(section_key, {})
	if retained.is_empty():
		return
	_fluid_payload_bytes = maxi(0, _fluid_payload_bytes - int(retained.get("payloadBytes", 0)))
	_fluid_payloads_by_section.erase(section_key)


func _release_canonical_fluid(section_key: Vector3i) -> void:
	var retained: Dictionary = _canonical_fluid_by_section.get(section_key, {})
	if retained.is_empty():
		return
	_canonical_fluid_bytes = maxi(0, _canonical_fluid_bytes - int(retained.get("canonicalBytes", 0)))
	_canonical_fluid_by_section.erase(section_key)


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
	_cancel_active_terrain_generation(true)
	_active.clear()
	_requests.clear()
	_results.clear()
	_active_contribution.clear()
	_contribution_requests.clear()
	_contributions_by_section.clear()
	_blocked_contributions_by_section.clear()
	_fluid_payloads_by_section.clear()
	_canonical_fluid_by_section.clear()
	_fluid_payload_bytes = 0
	_canonical_fluid_bytes = 0


func shutdown() -> void:
	_cancel_active_boundary()
	_cancel_active_terrain_generation(true)
	_active.clear()
	_requests.clear()
	_results.clear()
	_active_contribution.clear()
	_contribution_requests.clear()
	_contributions_by_section.clear()
	_blocked_contributions_by_section.clear()
	_fluid_payloads_by_section.clear()
	_canonical_fluid_by_section.clear()
	_fluid_payload_bytes = 0
	_canonical_fluid_bytes = 0
	_runtime = null
