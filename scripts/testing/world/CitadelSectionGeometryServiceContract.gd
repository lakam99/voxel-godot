extends SceneTree
## Synthetic service contract. It exercises a real BuildingPartPublisher
## transform artifact through the public provider contribution and shared
## assembler and receipt-gated visual retirement; legacy packet-shaped candidate
## checks remain separate from the production contribution path.

const Service := preload("res://scripts/world/CitadelPublicationService.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const BuildingPublisher := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const BuildingPart := preload("res://scripts/buildings/BuildingPart.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const MaterialCatalog := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const SectionGrid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const PacketOwner := preload("res://scripts/world/ChunkRenderPacketOwner.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const InstallSession := preload("res://scripts/world/NativeStaticSectionInstallSession.gd")
const TreeAdapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const MaterialFingerprint := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const OrdinaryGeometryAdapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const OwnerSectionSlice := preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")
const SourceRoster := preload("res://scripts/world/StaticSectionSourceRoster.gd")
const TreeQueue := preload("res://scripts/environment/TreePublicationQueue.gd")
const CitadelPlan := preload("res://scripts/world/CitadelPublicationPlan.gd")
const LegacyVisualIndex := preload("res://scripts/world/CitadelLegacySectionVisualIndex.gd")
const FurnishingPublisher := preload("res://scripts/buildings/FurnishingPublisher.gd")
const FurnishingPart := preload("res://scripts/buildings/FurnishingPart.gd")
const FurnishingPlan := preload("res://scripts/buildings/FurnishingPlan.gd")
const FurnishingRecipe := preload("res://scripts/buildings/FurnishingVisualRecipe.gd")
const SceneJob := preload("res://scripts/buildings/BuildingScenePublicationJob.gd")

class SyntheticRemovedTreeService extends "res://scripts/world/CitadelPublicationService.gd":
	var absent_authority: Dictionary = {}
	func _current_tree_member_artifact_authority(_site_id: String, _member_id: String) -> Dictionary:
		return absent_authority.duplicate()

class SyntheticPresentationCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	# Explicit synthetic receipt oracle: exercises completion composition only.
	var allow_receipt := true
	func installed_section_receipt_is_current(_section: Vector3i, receipt: Dictionary) -> bool:
		return allow_receipt and receipt.get("syntheticAccepted", false)

class AttachmentScene extends Node3D:
	var world_static_section_coordinator: Object
	var owners: Dictionary = {}
	func get_static_section_render_owner(cell: Vector2i, create_if_missing := true) -> Dictionary:
		if not owners.has(cell):
			if not create_if_missing: return {"status":"pending"}
			var owner := Node3D.new()
			owner.name = "Chunk_%d_%d" % [cell.x,cell.y]
			owner.position = Vector3(cell.x*SectionGrid.STREAM_CHUNK_SIZE_METERS,0,cell.y*SectionGrid.STREAM_CHUNK_SIZE_METERS)
			add_child(owner)
			owners[cell] = owner
		var attached: Dictionary = PacketOwner.attach_to_chunk(owners[cell])
		return {"status":"ready","owner":owners[cell],"backend":attached.get("backend")}

class PacketPublisher extends RefCounted:
	var publication_site_id := "site-a"
	var member_binding := "record-binding-1"
	var receipt_live := true
	var packet_source_id := "building:site-a:part-1:0,0:material-tier-digest:source"
	var packet_material: StandardMaterial3D
	var packet_mesh: BoxMesh
	var segment_record: Dictionary
	var recipe: Dictionary
	var published_nodes: Array = []
	var _physical_packet_bindings_by_part_id := {"part-1":"record-binding-1"}
	var _chunk_static_packet_expected := {}
	var _chunk_static_packet_pending_expected: Dictionary = {}
	var _chunk_static_packet_recipes := {}

	func _init() -> void:
		packet_material = StandardMaterial3D.new()
		packet_material.albedo_color = Color(0.4, 0.3, 0.2, 1.0)
		packet_mesh = BoxMesh.new()
		var buffer: Array[float] = []
		buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
			Color.WHITE, Color.WHITE))
		buffer.make_read_only()
		segment_record = {"segmentId":"segment-0", "buffer":buffer,
			"bounds":AABB(Vector3(1.5, 1.5, 1.5), Vector3.ONE), "instanceCount":1}
		segment_record.make_read_only()
		var segments := {0:segment_record}
		segments.make_read_only()
		recipe = {"sourceId":packet_source_id, "sourcePartId":"part-1",
			"sourceRevision":member_binding, "ownerCell":Vector2i.ZERO,
			"renderChunkKey":Vector2i.ZERO, "materialKey":"stone",
			"material":packet_material, "mesh":packet_mesh,
			"renderTier":"structural", "preparedSegments":segments,
			"packetInstanceCount":1}
		recipe.make_read_only()
		_chunk_static_packet_expected = {"part-1":{packet_source_id:{
			"ownerCell":Vector2i.ZERO, "generation":3,
			"sourceRevision":member_binding,
			"packetDigest":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}}
		_chunk_static_packet_recipes = {packet_source_id:recipe}

	func has_pending_static_flush() -> bool:
		return false

	func chunk_static_packet_receipt_live(part_id: String, source_id: String) -> bool:
		return receipt_live and part_id == "part-1" and source_id == packet_source_id


## Synthetic authority probe: real transaction wrappers, deliberately tiny census.
class SnapshotAdmission extends RefCounted:
	func stats() -> Dictionary:
		return {"generation":1}
	func source_state(_region: Vector2i) -> Dictionary:
		return {"status":"absent"}

class SnapshotScopeService extends "res://scripts/world/CitadelPublicationService.gd":
	var captures := 0
	var member_captures := 0
	func _init() -> void:
		_admission = SnapshotAdmission.new()
	func _capture_static_section_sources_uncached(_world_id: String, _sections: Array) -> Dictionary:
		captures += 1
		_current_member_transform_artifact_authority("site", "building:part")
		return {"status":"complete", "authorityRevision":str(captures)}
	func _capture_member_transform_artifact_authority(_site: String, _member: String) -> Dictionary:
		member_captures += 1
		return {"status":"ready", "artifactAuthorityRevision":str(member_captures)}
	func _capture_geometry_owner_roster_currentness(_source: String, roster: Dictionary, _removal: Dictionary) -> Dictionary:
		capture_static_section_sources("world", [Vector3i.ZERO])
		return {"status":"ready", "roster":roster}
	func presentation_owner_expectation(_source: String, _part: String, _revision: String) -> Dictionary:
		capture_static_section_sources("world", [Vector3i.ZERO])
		return {}

class CensusValidationFenceService extends "res://scripts/world/CitadelPublicationService.gd":
	var identity_epoch := 0
	var mutate_during_validation := false
	func _static_section_source_capture_identity(_world_id: String,
			_sections: Array[Vector3i]) -> String:
		return "fixture-identity-%d" % identity_epoch
	func _capture_static_section_sources_uncached(world_id: String,
			sections: Array) -> Dictionary:
		var job: Dictionary = _section_source_census_capture_jobs[_active_source_census_capture_key]
		var key := var_to_str(["site", "building:part"])
		var authority := {"status":"ready", "artifactAuthorityRevision":"authority-v1"}
		job["memberAuthorities"] = {key:authority}
		job["memberAuthorityCount"] = 1
		_section_source_census_capture_jobs[_active_source_census_capture_key] = job
		return {"status":"complete", "worldId":world_id,
			"sections":{Vector3i.ZERO:{"status":"complete"}}, "sourceRevisions":{}}
	func _capture_member_transform_artifact_authority(_site: String,
			_member: String) -> Dictionary:
		if mutate_during_validation:
			mutate_during_validation = false
			identity_epoch += 1
		return {"status":"ready", "artifactAuthorityRevision":"authority-v1"}
	func _current_census_member_authority_proof(site: String,
			member: String, _cached: Dictionary) -> Dictionary:
		return _capture_member_transform_artifact_authority(site, member)

class CensusEpochReuseService extends "res://scripts/world/CitadelPublicationService.gd":
	var source_epoch := 1
	var cold_census_count := 0
	var full_member_capture_count := 0
	var epoch_proof_count := 0
	const MEMBER_COUNT := 17

	func _static_section_source_capture_identity(_world_id: String,
			_sections: Array[Vector3i]) -> String:
		# Deliberately stable: source_epoch is proved independently through the
		# member's current authority token, not hidden in a test-only identity hash.
		return "stable-census-input"

	func _capture_static_section_sources_uncached(world_id: String,
			_sections: Array) -> Dictionary:
		cold_census_count += 1
		var authorities := {}
		for index in range(MEMBER_COUNT):
			var member := "building:part-%02d" % index
			var key := var_to_str(["site", member])
			authorities[key] = {"status":"ready",
				"artifactAuthorityRevision":"authority-v%d" % source_epoch}
		var job: Dictionary = _section_source_census_capture_jobs[_active_source_census_capture_key]
		job["memberAuthorities"] = authorities
		job["memberAuthorityCount"] = MEMBER_COUNT
		_section_source_census_capture_jobs[_active_source_census_capture_key] = job
		return {"status":"complete", "worldId":world_id,
			"authorityRevision":"provider-authority-v1",
			"sections":{Vector3i.ZERO:{"status":"complete"}}, "sourceRevisions":{}}

	func _capture_member_transform_artifact_authority(_site: String,
			_member: String) -> Dictionary:
		full_member_capture_count += 1
		return {"status":"ready",
			"artifactAuthorityRevision":"authority-v%d" % source_epoch}

	func _current_census_member_authority_proof(_site: String,
			_member: String, _cached: Dictionary) -> Dictionary:
		epoch_proof_count += 1
		return {"status":"ready",
			"artifactAuthorityRevision":"authority-v%d" % source_epoch,
			"epochProof":{"sourceEpoch":source_epoch}}

class SectionSliceExpectationService extends "res://scripts/world/CitadelPublicationService.gd":
	func _geometry_owner_roster_is_current(_source_id: String, _roster: Dictionary,
			_removal: Dictionary) -> Dictionary:
		return {"status":"ready"}
	func _geometry_owner_section_parent_receipt_is_current(_source_id: String,
			_roster: Dictionary) -> bool:
		return true


class FixtureService extends "res://scripts/world/CitadelPublicationService.gd":
	var census_fixture: Dictionary
	var owner_fixture: Dictionary
	var visual_plan
	func _publication_plan_for_binding(binding: Dictionary):
		return visual_plan if visual_plan != null and visual_plan.binding == binding else null

	func capture_static_section_sources(_world_id: String, _section_keys: Array) -> Dictionary:
		return census_fixture

	func _current_packet_publisher_for_site(_site_id: String) -> Dictionary:
		return owner_fixture

class FixtureVisualPlan extends RefCounted:
	var output_signature := "synthetic-visual-plan-v1"
	var binding: Dictionary
	var groups: Dictionary = {}
	var visual_source_revisions: Dictionary
	var member_records: Array[Dictionary] = []
	func matches(expected: Dictionary, expected_groups: Dictionary) -> bool:
		return expected == binding and expected_groups == groups and visual_source_revisions.is_read_only()


class FixtureAdmission extends RefCounted:
	var binding: Dictionary = {}

	func stats() -> Dictionary:
		return {"worldSeed":"seed:citadel-service-contract:1", "generation":0}

	func source_state(_region: Vector2i) -> Dictionary:
		return {"status":"ready", "binding":binding}


class LegacyIndexPublisher extends RefCounted:
	var published_nodes: Array = []
	var source_roots: Dictionary = {}
	var roster_revision := 0

	func published_node_roster_snapshot() -> Array:
		var snapshot := published_nodes.duplicate()
		snapshot.make_read_only()
		return snapshot

	func register_source_root(node: Node, source_part_id: String) -> void:
		published_nodes.append(node)
		if not source_roots.has(source_part_id): source_roots[source_part_id] = []
		source_roots[source_part_id].append(node)
		roster_revision += 1

	func capture_legacy_visual_roots_for_sources(source_part_ids: Array) -> Dictionary:
		var roots: Array[Dictionary] = []
		for part_value: Variant in source_part_ids:
			for node_value: Variant in source_roots.get(String(part_value), []):
				if not is_instance_valid(node_value):
					return {"status":"pending", "reason":"fixture_root_lost"}
				var node := node_value as Node
				roots.append({"node":node, "nodeInstanceId":node.get_instance_id(),
					"sourcePartId":String(part_value)})
		roots.make_read_only()
		return {"status":"ready", "roots":roots, "rosterRevision":roster_revision}

	func capture_legacy_visual_roots_for_section(_section_key: Vector3i,
			source_part_ids: Array) -> Dictionary:
		var tracked_root_count := 0
		for roots_value: Variant in source_roots.values():
			tracked_root_count += roots_value.size()
		if published_nodes.size() != tracked_root_count:
			return {"status":"pending", "reason":"published_node_owner_ledger_size_changed",
				"retryable":true}
		var captured := capture_legacy_visual_roots_for_sources(source_part_ids)
		if captured.get("status") == "ready":
			captured["sourcePartIds"] = source_part_ids.duplicate()
		return captured


class ReceiptValidationCacheProbe extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	var live_check_count := 0

	func _receipt_is_live(_candidate: Dictionary, _receipt: Dictionary) -> bool:
		live_check_count += 1
		return true

class QueuedGeometryCompletionCoordinator extends "res://scripts/world/WorldStaticSectionCoordinator.gd":
	var request_count := 0
	var cursor_advance_count := 0
	var allow_receipt := true
	var queued_result: Dictionary = {}
	var requested_roster: Dictionary = {}
	var requested_priors: Array = []

	func request_geometry_owner_completion(roster: Dictionary,
			prior_rosters: Array = []) -> Dictionary:
		request_count += 1
		requested_roster = roster
		requested_priors = prior_rosters
		return queued_result.duplicate(false)

	func advance_geometry_owner_completion(_roster: Dictionary,
			_prior_rosters: Array = [], _max_work_items := 2,
			_budget_usec := 250) -> Dictionary:
		cursor_advance_count += 1
		return {"status":"pending", "reason":"unexpected_inline_cursor_advance"}

	func installed_section_receipt_is_current(_section: Vector3i,
			_receipt: Dictionary) -> bool:
		return allow_receipt


class RacingBuildingPublisher extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var artifact_capture_call := 0
	var move_parent_after_next_capture := false

	func arm_parent_move_after_next_transform_artifact_capture() -> void:
		move_parent_after_next_capture = true

	func capture_static_section_transform_artifacts(source_part_id: String,
			source_revision: String) -> Dictionary:
		artifact_capture_call += 1
		var captured := super.capture_static_section_transform_artifacts(
			source_part_id, source_revision)
		if move_parent_after_next_capture:
			move_parent_after_next_capture = false
			var parent_ref: WeakRef = _scene_parent
			var parent := parent_ref.get_ref() as Node3D
			if is_instance_valid(parent):
				parent.global_position += Vector3(0.25, 0.0, 0.0)
		return captured


var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


## The production provider now admits one complete source capture per scheduler
## turn. Synthetic service checks drain only that named continuation and keep
## their original content/owner assertions intact.
func _capture_section_contribution(service: Object, census: Dictionary,
		section_key: Vector3i, candidate_generation := 1) -> Dictionary:
	var result: Dictionary = {}
	for _slice in range(128):
		result = service.capture_static_section_contribution(
			census, section_key, candidate_generation)
		var reason := String(result.get("reason", ""))
		if reason not in ["citadel_section_contribution_slice_pending",
				"citadel_contribution_capture_inputs_stale"]:
			return result
		await process_frame
	return {"status":"pending", "reason":"fixture_contribution_slice_limit",
		"retryable":true, "sectionKey":section_key}


func run() -> void:
	_exercise_queued_geometry_owner_proof_request()
	var fence_service := CensusValidationFenceService.new()
	var fence_first: Dictionary = fence_service.capture_static_section_sources(
		"world", [Vector3i.ZERO])
	fence_service.mutate_during_validation = true
	var fence_second: Dictionary = fence_service.capture_static_section_sources(
		"world", [Vector3i.ZERO])
	check("public_census_capture_rejects_identity_change_during_validation",
		fence_first.get("status") == "pending"
		and fence_second.get("status") == "pending"
		and fence_second.get("reason") == "citadel_section_source_census_identity_changed",
		{"first":fence_first, "second":fence_second})
	var epoch_service := CensusEpochReuseService.new()
	var epoch_result: Dictionary = {}
	var validation_cursors: Array[int] = []
	for _slice in range(8):
		epoch_result = epoch_service.capture_static_section_sources(
			"world", [Vector3i.ZERO])
		if epoch_result.get("status") == "complete": break
		var progress: Variant = epoch_result.get("captureProgress", {})
		if progress is Dictionary and progress.has("validatedMemberAuthorityCount"):
			validation_cursors.append(int(progress.validatedMemberAuthorityCount))
		await process_frame
	var cold_count_after_validation := epoch_service.cold_census_count
	var full_capture_count_after_validation := epoch_service.full_member_capture_count
	await process_frame
	var stable_epoch_result: Dictionary = epoch_service.capture_static_section_sources(
		"world", [Vector3i.ZERO])
	check("public_census_epoch_proof_reuses_completed_validation_across_frames",
		epoch_result.get("status") == "complete"
		and stable_epoch_result.get("status") == "complete"
		and validation_cursors.size() >= 2
		and validation_cursors[0] < validation_cursors[1]
		and validation_cursors.back() < CensusEpochReuseService.MEMBER_COUNT
		and epoch_service.cold_census_count == cold_count_after_validation
		and epoch_service.full_member_capture_count == full_capture_count_after_validation
		and epoch_service.epoch_proof_count >= CensusEpochReuseService.MEMBER_COUNT * 2,
		{"initial":epoch_result, "stable":stable_epoch_result,
			"validationCursors":validation_cursors,
			"coldCensusCount":epoch_service.cold_census_count,
			"fullMemberCaptureCount":epoch_service.full_member_capture_count,
			"epochProofCount":epoch_service.epoch_proof_count})
	epoch_service.source_epoch += 1
	await process_frame
	var stale_epoch_result: Dictionary = epoch_service.capture_static_section_sources(
		"world", [Vector3i.ZERO])
	check("public_census_epoch_mutation_invalidates_cached_admission",
		stale_epoch_result.get("status") == "pending"
		and stale_epoch_result.get("reason") == "citadel_section_source_census_member_changed"
		and epoch_service.cold_census_count == cold_count_after_validation,
		{"result":stale_epoch_result,
			"coldCensusCount":epoch_service.cold_census_count,
			"priorColdCensusCount":cold_count_after_validation,
			"epochProofCount":epoch_service.epoch_proof_count})
	var retained_roster_service := Service.new()
	var first_seal_result := OwnerCompletion.seal("retained-world", "retained-source",
		"retained-source", "revision-1", "publisher-1", [], true)
	var first_seal: Dictionary = first_seal_result.roster
	retained_roster_service._retain_geometry_owner_roster("retained-source", first_seal, {})
	var equal_seal_result := OwnerCompletion.seal("retained-world", "retained-source",
		"retained-source", "revision-1", "publisher-1", [], true)
	var equal_seal: Dictionary = equal_seal_result.roster
	retained_roster_service._retain_geometry_owner_roster("retained-source", equal_seal, {})
	var retained_seal: Dictionary = retained_roster_service._geometry_owner_rosters["retained-source"]
	check("equivalent_producer_seal_reuses_exact_roster_object",
		is_same(retained_seal, first_seal) and not is_same(equal_seal, first_seal),
		{"sameDigest":first_seal.digest == equal_seal.digest,
			"retainedSameObject":is_same(retained_seal, first_seal)})
	var replacement_seal_result := OwnerCompletion.seal("retained-world", "retained-source",
		"retained-source", "revision-1", "publisher-2", [], true)
	var replacement_seal: Dictionary = replacement_seal_result.roster
	retained_roster_service._retain_geometry_owner_roster("retained-source", replacement_seal, {})
	check("changed_owner_incarnation_replaces_roster_and_retains_prior_identity",
		is_same(retained_roster_service._geometry_owner_rosters["retained-source"], replacement_seal)
		and retained_roster_service._geometry_owner_prior_rosters.get("retained-source", []).has(first_seal)
		and first_seal.sourceIncarnation != replacement_seal.sourceIncarnation,
		{"priorRosterCount":retained_roster_service._geometry_owner_prior_rosters.get(
			"retained-source", []).size()})
	var scope_service := SnapshotScopeService.new()
	var scope_owner := RefCounted.new()
	var wrong_owner := RefCounted.new()
	var scoped_roster := {"sourceRevision":"revision", "digest":"synthetic-roster"}
	scoped_roster.make_read_only()
	scope_service._geometry_owner_rosters["source"] = scoped_roster
	var first_scope := scope_service.begin_owner_expectation_snapshot(scope_owner)
	scope_service.geometry_owner_expectation("source", "source", "revision")
	scope_service.geometry_owner_prior_expectations("source", "source", "revision")
	scope_service.presentation_owner_expectation("source", "source", "revision")
	var shared := scope_service.capture_static_section_sources("world", [Vector3i.ZERO])
	var denied := scope_service.end_owner_expectation_snapshot(wrong_owner, int(first_scope.token))
	check("synthetic_owner_snapshot_reuses_census_and_source_within_exact_scope",
		scope_service.captures == 1 and scope_service.member_captures == 1 and shared.is_read_only()
		and denied.get("status") == "failed", {"captures":scope_service.captures})
	var ended := scope_service.end_owner_expectation_snapshot(scope_owner, int(first_scope.token))
	var second_scope := scope_service.begin_owner_expectation_snapshot(scope_owner)
	scope_service.geometry_owner_expectation("source", "source", "revision")
	scope_service.presentation_owner_expectation("source", "source", "revision")
	check("synthetic_owner_snapshot_new_token_recaptures_authority",
		ended.get("status") == "released" and first_scope.token != second_scope.token
		and scope_service.captures == 2 and scope_service.member_captures == 2,
		{"ended":ended, "firstToken":first_scope.token,
			"secondToken":second_scope.token, "captures":scope_service.captures,
			"memberCaptures":scope_service.member_captures})
	scope_service.end_owner_expectation_snapshot(scope_owner, int(second_scope.token))
	scope_service.capture_static_section_sources("world", [Vector3i.ZERO])
	scope_service.capture_static_section_sources("world", [Vector3i.ZERO])
	check("synthetic_owner_snapshot_scope_end_drops_all_reuse",
		scope_service.captures == 4 and scope_service.member_captures == 4
		and scope_service._owner_snapshot_values.is_empty(),
		{"captures":scope_service.captures,
			"memberCaptures":scope_service.member_captures,
			"cachedValueCount":scope_service._owner_snapshot_values.size()})
	var slice_service := SectionSliceExpectationService.new()
	var slice_compatibility := {"meshContentDigest":"slice-mesh".sha256_text(),
		"meshResourceKey":"mesh:slice", "materialKey":"material:stone",
		"pipelineRevision":"pipeline:1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "renderTier":"near", "castShadows":true,
		"visibilityRangeEnd":128.0, "fadeMargin":8.0}
	var slice_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var slice_buffer: Array[float] = []
	slice_buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
		Color.WHITE, Color.WHITE))
	slice_buffer.make_read_only()
	var slice_member_a := OwnerCompletion.packed_member("slice-source", "slice-source",
		"slice-revision", "slice-a", 0, Vector3i(2, 0, 0), slice_bounds,
		slice_buffer, 0, slice_compatibility)
	var slice_member_b := OwnerCompletion.packed_member("slice-source", "slice-source",
		"slice-revision", "slice-b", 0, Vector3i(3, 0, 0), slice_bounds,
		slice_buffer, 0, slice_compatibility)
	var slice_roster_result := OwnerCompletion.seal("slice-world", "slice-source",
		"slice-source", "slice-revision", "publisher-incarnation", [slice_member_a, slice_member_b])
	var slice_roster: Dictionary = slice_roster_result.roster
	slice_service._geometry_owner_rosters["slice-source"] = slice_roster
	var slice_expectation: Dictionary = slice_service.geometry_owner_section_expectation(
		"slice-source", "slice-source", "slice-revision", Vector3i(2, 0, 0))
	var empty_expectation: Dictionary = slice_service.geometry_owner_section_expectation(
		"slice-source", "slice-source", "slice-revision", Vector3i(9, 0, 0))
	var first_slice_pending: bool = slice_expectation.get("status") == "pending" \
		and slice_expectation.get("retryable", false)
	for _attempt in range(8):
		if slice_service._geometry_owner_section_slice_jobs.is_empty():
			break
		slice_service.advance(Rect2i(), false, 2500)
	slice_expectation = slice_service.geometry_owner_section_expectation(
		"slice-source", "slice-source", "slice-revision", Vector3i(2, 0, 0))
	empty_expectation = slice_service.geometry_owner_section_expectation(
		"slice-source", "slice-source", "slice-revision", Vector3i(9, 0, 0))
	check("section_owner_slice_cache_miss_is_pending_until_budgeted_advance",
		first_slice_pending and slice_expectation.get("status") == "ready"
		and empty_expectation.get("status") == "ready",
		{"initial":first_slice_pending, "slice":slice_expectation.get("status"),
			"empty":empty_expectation.get("status")})
	check("section_expectation_preserves_parent_and_returns_only_owned_slice",
		slice_expectation.get("status") == "ready"
		and slice_expectation.get("parentRoster") == slice_roster
		and OwnerSectionSlice.validate_slice(slice_roster, slice_expectation.get("slice", {}))
		and slice_expectation.slice.ownerSection == Vector3i(2, 0, 0)
		and slice_expectation.slice.members == [slice_member_a], slice_expectation)
	check("section_expectation_reports_explicit_empty_for_nonowner_section",
		empty_expectation.get("status") == "ready"
		and empty_expectation.slice.sectionEmpty
		and empty_expectation.slice.members.is_empty()
		and empty_expectation.slice.parentRosterDigest == slice_roster.digest, empty_expectation)
	var section := Vector3i.ZERO
	var world_id := "seed:citadel-service-contract:1"
	var source_id := "citadel:site-a:member:building:part-1:section:0,0,0"
	var source_revision := "citadel-census-revision"
	var census := {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{source_id:source_revision},
		"sections":{section:{"status":"complete", "coverageRevision":"coverage-revision",
			"sourcePartIds":[source_id]}}}
	var publisher := PacketPublisher.new()
	var service := FixtureService.new()
	service.census_fixture = census
	service.owner_fixture = {"status":"ready", "publisher":publisher,
		"sourceToWorld":Transform3D(Basis.IDENTITY, Vector3(10, 0, 10))}
	var candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 11)
	check("live_service_bridge_emits_shared_candidate_snapshot_from_packet_recipe",
		candidate.get("status") == "ready"
		and candidate.get("schema") == "citadel-section-geometry-candidate/v1"
		and candidate.get("packetGroupCount") == 1
		and candidate.get("replacements", []).size() == 1
		and candidate.get("replacements", [])[0].get("snapshot", {}).get("instanceCount") == 1
		and candidate.get("resourceBindings", {}).size() == 1,
		candidate)
	check("candidate_explicitly_retains_legacy_render_and_gameplay_owners",
		candidate.get("legacyVisualPolicy") == "retain_until_shared_coordinator_native_receipt_acknowledged"
		and String(candidate.get("evidenceScope", "")).contains("no native install"), candidate)
	var transform_parent := Node3D.new()
	transform_parent.transform = Transform3D(
		Basis.from_euler(Vector3(0.2,0.7,-0.1)).scaled(Vector3(1.2,0.9,1.1)),
		Vector3(10.0,3.0,-4.0))
	get_root().add_child(transform_parent)
	var transform_publisher = RacingBuildingPublisher.new()
	transform_publisher.unit_box = BoxMesh.new()
	transform_publisher.source_blueprint_id = "adapter-contract-blueprint"
	transform_publisher.publication_site_id = "site-transform"
	transform_publisher._scene_parent = weakref(transform_parent)
	var transform_material: Material = MaterialCatalog.create_material("stone_foundation")
	transform_publisher.material_cache = {"stone_foundation":transform_material}
	var transform_part = BuildingPart.new({"id":"castle_tower_04_battlement_front_0",
		"kind":"beam", "material":"stone_foundation", "position":Vector3.ZERO,
		"size":Vector3.ONE, "collision":true,
		"recipe":{"visual":true, "semantic":"castle_battlement",
			"practicalLight":true, "lightEnergy":1.82, "lightRange":4.75}})
	var transform_binding := Preparation.static_record_binding(transform_part.snapshot())
	transform_publisher.static_visual_source_part_id = transform_part.id
	transform_publisher.static_visual_source_revision = transform_binding
	transform_publisher.static_visual_owner_cell = Vector2i.ZERO
	transform_publisher.static_visual_render_chunk_key = Vector2i.ZERO
	transform_publisher.static_visual_part_tier = "structural"
	var transform_local := Transform3D(
		Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(1.0,18.0,2.0))
	var transform_world_bounds: AABB = transform_parent.global_transform * (
		transform_local * transform_publisher.unit_box.get_aabb())
	var transform_world_center := transform_world_bounds.position + transform_world_bounds.size * 0.5
	var transform_section: Vector3i = SectionGrid.key_for_world_position(transform_world_center)
	transform_publisher.collect_static_visual_transform(
		transform_local,
		transform_material, Color(0.2,0.4,0.6,1.0))
	transform_publisher.static_visual_collecting = true
	transform_publisher.static_visual_part_transform = Transform3D(
		Basis.from_euler(transform_part.rotation), transform_part.position)
	transform_publisher.publish_practical_light(transform_part, transform_parent)
	transform_publisher.static_visual_collecting = false
	transform_publisher._record_completed_source_part(transform_part)
	transform_publisher._begin_static_flush(transform_parent,false)
	var transform_flush_steps := 0
	while transform_publisher.has_pending_static_flush() and transform_flush_steps < 1000:
		transform_publisher.advance_static_flush(transform_parent,1)
		transform_flush_steps += 1
	var practical_light_capture: Dictionary = transform_publisher.capture_static_section_transform_artifacts(
		transform_part.id, transform_binding)
	var practical_light_members: Array = practical_light_capture.get("presentationMounts", [])
	var practical_light_bindings: Dictionary = practical_light_capture.get("presentationBindings", {})
	var practical_light_key := "building-practical-light:site-transform:%s" % transform_part.id
	var practical_light_binding: Dictionary = practical_light_bindings.get(practical_light_key, {})
	var practical_light_mount: Node3D = practical_light_binding.mount.get_ref() as Node3D \
		if practical_light_binding.get("mount") is WeakRef else null
	var practical_light_source: OmniLight3D = practical_light_binding.light.get_ref() as OmniLight3D \
		if practical_light_binding.get("light") is WeakRef else null
	check("publisher_captures_real_source_owned_practical_light_and_exact_binding",
		practical_light_capture.get("status") == "ready"
		and practical_light_members.size() == 1
		and String(practical_light_capture.get("presentationDigest", "")).length() == 64
		and practical_light_binding.get("producerSourceRevision") == transform_binding
		and is_instance_valid(practical_light_mount)
		and practical_light_mount.get_parent() == practical_light_binding.body.get_ref()
		and is_instance_valid(practical_light_source)
		and practical_light_source.get_parent() == practical_light_mount
		and is_equal_approx(practical_light_source.light_energy, 1.82)
		and is_equal_approx(practical_light_source.omni_range, 4.75)
		and practical_light_binding.get("legacyVisuals", []).is_empty(),
		{"captureStatus":practical_light_capture.get("status"),
			"memberCount":practical_light_members.size(),
			"presentationDigest":practical_light_capture.get("presentationDigest", ""),
			"reason":practical_light_capture.get("reason", "")})
	var transform_source_id := "citadel:site-transform:member:building:%s:section:%d,%d,%d" % [
		transform_part.id, transform_section.x, transform_section.y, transform_section.z]
	var transform_revision := "service-census-revision"
	var transform_coverage := "service-coverage-revision"
	var transform_provider_revision := "service-authority-revision"
	var transform_identity_key := "section-part:" + var_to_bytes([
		transform_source_id, transform_source_id]).hex_encode()
	var transform_identity := {"sourceId":transform_source_id,
		"sourcePartId":transform_source_id}
	transform_identity.make_read_only()
	var expected_transform_sources: Array[String] = [transform_identity_key]
	expected_transform_sources.make_read_only()
	var transform_sections: Array[Vector3i] = [transform_section]
	transform_sections.make_read_only()
	var transform_expected := {transform_section:expected_transform_sources}
	transform_expected.make_read_only()
	var transform_source_revisions := {transform_identity_key:transform_revision}
	transform_source_revisions.make_read_only()
	var transform_source_providers := {transform_identity_key:"blueprint_buildings"}
	transform_source_providers.make_read_only()
	var transform_source_identities := {transform_identity_key:transform_identity}
	transform_source_identities.make_read_only()
	var transform_coverage_by_section := {transform_section:transform_coverage}
	transform_coverage_by_section.make_read_only()
	var transform_provider_coverage := {"blueprint_buildings":transform_coverage_by_section}
	transform_provider_coverage.make_read_only()
	var transform_provider_revisions := {"blueprint_buildings":transform_provider_revision}
	transform_provider_revisions.make_read_only()
	var roster_census := {"status":"complete", "worldId":world_id,
		"sections":transform_sections,
		"expectedContributorsBySection":transform_expected,
		"sourceRevisions":transform_source_revisions,
		"sourceProviderIds":transform_source_providers,
		"sourceIdentities":transform_source_identities,
		"providerCoverageRevisions":transform_provider_coverage,
		"providerSnapshotRevisions":transform_provider_revisions}
	roster_census.make_read_only()
	service.census_fixture = {"status":"complete", "worldId":world_id,
		"authorityRevision":"service-authority-revision",
		"sourceRevisions":{transform_source_id:transform_revision},
		"sections":{transform_section:{"status":"complete", "coverageRevision":transform_coverage,
			"sourcePartIds":[transform_source_id]}}}
	var transform_site_binding := {"siteId":"site-transform", "generation":1}
	service.visual_plan = FixtureVisualPlan.new()
	service.visual_plan.binding = transform_site_binding
	service.visual_plan.visual_source_revisions = {transform_part.id:transform_binding}
	service.visual_plan.visual_source_revisions.make_read_only()
	var transform_region := Vector2i(4,-2)
	var transform_admission := FixtureAdmission.new()
	transform_admission.binding = transform_site_binding
	service._admission = transform_admission
	service._scenes = {transform_region:{"binding":transform_site_binding,
		"packetMode":false, "phase":"scene_ready",
		"job":{"_building":transform_publisher},
		"profile":{"origin":transform_parent.global_position}}}
	var captured_authority: Dictionary = service._current_member_transform_artifact_authority(
		"site-transform", "building:" + transform_part.id)
	check("committed_visual_authority_does_not_require_physical_packet_attachment",
		captured_authority.get("status") == "ready" and transform_publisher._physical_packet_bindings_by_part_id.is_empty(), captured_authority)
	var replacement_publisher = BuildingPublisher.new()
	replacement_publisher.publication_site_id = "site-transform"
	replacement_publisher._scene_parent = weakref(transform_parent)
	replacement_publisher._physical_packet_bindings_by_part_id = \
		transform_publisher._physical_packet_bindings_by_part_id.duplicate()
	replacement_publisher._static_section_transform_artifacts = \
		transform_publisher._static_section_transform_artifacts.duplicate()
	replacement_publisher._static_section_transform_artifact_revisions = \
		transform_publisher._static_section_transform_artifact_revisions.duplicate()
	replacement_publisher._watch_static_section_transform_resources(transform_part.id,
		transform_binding, replacement_publisher._static_section_transform_artifacts[transform_part.id])
	replacement_publisher._source_part_boundaries = transform_publisher._source_part_boundaries.duplicate()
	var transform_scene_entry: Dictionary = service._scenes[transform_region]
	transform_scene_entry["job"] = {"_building":replacement_publisher}
	service._scenes[transform_region] = transform_scene_entry
	var replacement_authority: Dictionary = service._current_member_transform_artifact_authority(
		"site-transform", "building:" + transform_part.id)
	check("census_artifact_authority_binds_publisher_incarnation",
		captured_authority.get("status") == "ready"
		and replacement_authority.get("status") == "ready"
		and String(captured_authority.get("artifactAuthorityRevision", "")).length() == 64
		and captured_authority.get("artifactAuthorityRevision") \
			!= replacement_authority.get("artifactAuthorityRevision")
		and int(captured_authority.get("publisherInstanceId", 0)) \
			!= int(replacement_authority.get("publisherInstanceId", 0)),
		{"captured":captured_authority, "replacement":replacement_authority})
	transform_scene_entry = service._scenes[transform_region]
	transform_scene_entry["job"] = {"_building":transform_publisher}
	service._scenes[transform_region] = transform_scene_entry
	var saved_parent_transform := transform_parent.global_transform
	transform_parent.global_position += Vector3(0.25,0.0,0.0)
	var moved_authority: Dictionary = service._current_member_transform_artifact_authority(
		"site-transform", "building:" + transform_part.id)
	transform_parent.global_transform = saved_parent_transform
	check("census_artifact_authority_rejects_moved_parent_transform",
		moved_authority.get("status") == "pending"
		and String(moved_authority.get("reason", "")) \
			== "static_transform_owner_transform_stale",
		moved_authority)
	var transform_identity_resolution: Dictionary = service._current_transform_artifact_census(
		roster_census, transform_section)
	check("canonical_roster_identity_resolves_to_producer_source_id",
		transform_identity_resolution.get("status") == "ready"
		and transform_identity_resolution.get("sourceIds", []) == [transform_source_id],
		transform_identity_resolution)
	var mixed_tree_source_id := "citadel:site-transform:member:tree:oak-1:section:%d,%d,%d" % [
		transform_section.x, transform_section.y, transform_section.z]
	var mixed_tree_identity_key := "section-part:" + var_to_bytes([
		mixed_tree_source_id, mixed_tree_source_id]).hex_encode()
	var mixed_tree_identity := {"sourceId":mixed_tree_source_id, "sourcePartId":mixed_tree_source_id}
	mixed_tree_identity.make_read_only()
	var mixed_expected_sources: Array[String] = [transform_identity_key, mixed_tree_identity_key]
	mixed_expected_sources.make_read_only()
	var mixed_expected := {transform_section:mixed_expected_sources}
	mixed_expected.make_read_only()
	var mixed_revisions := transform_source_revisions.duplicate()
	mixed_revisions[mixed_tree_identity_key] = "tree-census-revision"
	mixed_revisions.make_read_only()
	var mixed_providers := transform_source_providers.duplicate()
	mixed_providers[mixed_tree_identity_key] = "blueprint_buildings"
	mixed_providers.make_read_only()
	var mixed_identities := transform_source_identities.duplicate()
	mixed_identities[mixed_tree_identity_key] = mixed_tree_identity
	mixed_identities.make_read_only()
	var mixed_census := roster_census.duplicate()
	mixed_census["expectedContributorsBySection"] = mixed_expected
	mixed_census["sourceRevisions"] = mixed_revisions
	mixed_census["sourceProviderIds"] = mixed_providers
	mixed_census["sourceIdentities"] = mixed_identities
	mixed_census.make_read_only()
	var building_only_census_fixture: Dictionary = service.census_fixture
	var mixed_fixture := building_only_census_fixture.duplicate(true)
	mixed_fixture["sourceRevisions"][mixed_tree_source_id] = "tree-census-revision"
	mixed_fixture["sections"][transform_section]["sourcePartIds"].append(mixed_tree_source_id)
	service.census_fixture = mixed_fixture
	var mixed_resolution: Dictionary = service._current_transform_artifact_census(
		mixed_census, transform_section)
	var mixed_first_slice: Dictionary = service.capture_static_section_contribution(
		mixed_census, transform_section, 77)
	var changed_other_provider_revisions: Dictionary = mixed_census.get(
		"sourceRevisions", {}).duplicate()
	changed_other_provider_revisions["unrelated:terrain:source"] = "advanced-revision"
	changed_other_provider_revisions.make_read_only()
	var newer_mixed_census: Dictionary = mixed_census.duplicate(false)
	newer_mixed_census["sourceRevisions"] = changed_other_provider_revisions
	newer_mixed_census.make_read_only()
	var mixed_contribution: Dictionary = service.capture_static_section_contribution(
		newer_mixed_census, transform_section, 77)
	service.census_fixture = building_only_census_fixture
	check("shared_provider_roster_keeps_tree_for_separate_source_capture",
		mixed_resolution.get("status") == "ready"
		and mixed_resolution.get("sourceIds", []) == [transform_source_id, mixed_tree_source_id]
		and mixed_first_slice.get("reason") == "citadel_section_contribution_slice_pending"
		and mixed_contribution.get("status") == "pending"
		and mixed_contribution.get("reason") == "citadel_tree_scene_source_unavailable",
		{"roster":mixed_resolution, "firstSlice":mixed_first_slice,
			"changedWholeCensus":newer_mixed_census.get("sourceRevisions")
				!= mixed_census.get("sourceRevisions"), "contribution":mixed_contribution})
	var transform_contribution_result: Dictionary = await _capture_section_contribution(
		service, roster_census, transform_section)
	var transform_contribution: Dictionary = transform_contribution_result.get("contribution", {})
	check("transform_artifacts_enter_shared_provider_contribution_with_packet_maps_empty",
		transform_flush_steps < 1000 and not transform_publisher.has_pending_static_flush()
		and transform_contribution_result.get("status") == "ready"
		and transform_contribution.is_read_only()
		and transform_contribution.get("providerId") == "blueprint_buildings"
		and transform_contribution.get("authoritySourceRevisions", {}).get(transform_identity_key, "") == transform_revision
		and transform_contribution.get("inputs", []).size() == 1
		and transform_contribution.get("presentationContributors", []).size() == 1
		and transform_contribution.get("presentationContributors", [])[0].get("presentationMembers", []).size() == 1
		and transform_contribution.get("attachmentBindings", {}).has(practical_light_key)
		and transform_contribution.get("inputs", [])[0].get("sourceToWorld") == transform_parent.global_transform
		and transform_contribution.get("inputs", [])[0].get("producerSourceRevision") == transform_binding
		and transform_contribution.get("attachmentBindings", {}).get(practical_light_key, {}).get("sourceRevision") == transform_revision
		and transform_contribution.get("attachmentBindings", {}).get(practical_light_key, {}).get("producerSourceRevision") == transform_binding
		and transform_contribution.get("resourceBindings", {}).size() == 1
		and transform_publisher._chunk_static_packet_expected.is_empty()
		and transform_publisher._chunk_static_packet_pending_expected.is_empty()
		and transform_publisher._chunk_static_packet_receipts.is_empty(),
		{"capture":transform_contribution_result,
		"inputCount":transform_contribution.get("inputs", []).size()})
	check("candidate_preparation_keeps_old_visual_and_collision_live",
		transform_contribution_result.get("status") == "ready"
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible
		and transform_part.collision_enabled
		and bool(transform_part.snapshot().get("collision", false)),
		{"contribution":transform_contribution_result,
			"legacyVisible":_visible_transform_visual(transform_publisher) != null \
				and _visible_transform_visual(transform_publisher).visible,
			"collisionEnabled":transform_part.collision_enabled})
	var assembled_transform: Dictionary = {"status":"pending",
		"reason":"service_transform_contribution_not_ready"}
	if transform_contribution_result.get("status") == "ready" \
			and transform_contribution.is_read_only():
		var section_contributions: Array = [transform_contribution]
		section_contributions.make_read_only()
		assembled_transform = Assembler.assemble(
			roster_census, transform_section, section_contributions, 21)
	var assembled_candidate: Dictionary = assembled_transform.get("candidate", {})
	var assembled_snapshot: Dictionary = assembled_candidate.get("candidate", {}).get("snapshot", {})
	check("service_contribution_reaches_shared_candidate_assembler",
		assembled_transform.get("status") == "ready"
		and assembled_transform.get("sourceCount") == 1
		and assembled_transform.get("inputCount") == 1
		and assembled_snapshot.get("batches", []).size() == 1
		and assembled_snapshot.get("manifest", []).size() == 1
		and assembled_snapshot.get("manifest", [])[0].get("sourceRevision") == transform_revision
		and assembled_snapshot.get("manifest", [])[0].get("ownerCell") == transform_publisher.static_visual_owner_cell
		and assembled_snapshot.get("presentationMembers", []).size() == 1
		and assembled_snapshot.get("presentationMembers", [])[0].get("sourceRevision") == transform_revision
		and assembled_snapshot.get("presentationMembers", [])[0].get("producerSourceRevision") == transform_binding
		and assembled_candidate.get("evidenceLevel") == "complete_authoritative_section_candidate",
		assembled_transform)
	check("assembled_candidate_keeps_old_visual_and_collision_live",
		assembled_transform.get("status") == "ready"
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible
		and assembled_candidate.get("candidate", {}).get("snapshot", {}).get("presentationMembers", []).size() == 1
		and transform_part.collision_enabled,
		{"assembly":assembled_transform,
			"legacyVisible":_visible_transform_visual(transform_publisher) != null \
				and _visible_transform_visual(transform_publisher).visible,
			"collisionEnabled":transform_part.collision_enabled})
	var live_roster: Dictionary = service._geometry_owner_rosters.get(transform_source_id, {})
	var live_proof: Dictionary = service._geometry_owner_capture_proofs.get(transform_source_id, {})
	var missing_prior_proof := live_proof.duplicate(false)
	missing_prior_proof.erase("visualSourceReceipt")
	service._geometry_owner_capture_proofs[transform_source_id] = missing_prior_proof
	var missing_prior_removal: Dictionary = service._current_roster_removal(world_id, transform_source_id, transform_section)
	check("synthetic_plan_absence_without_prior_visual_receipt_cannot_authorize_empty",
		missing_prior_removal.get("status") == "pending"
		and missing_prior_removal.get("reason") == "citadel_removal_prior_visual_receipt_changed",
		missing_prior_removal)
	service._geometry_owner_capture_proofs[transform_source_id] = live_proof
	var removed_visual: Dictionary = service._current_roster_removal(world_id, transform_source_id, transform_section)
	check("synthetic_complete_plan_absence_retains_prior_visual_receipt_and_owner_roster",
		removed_visual.get("status") == "ready"
		and service._geometry_owner_rosters.get(transform_source_id, {}).get("explicitRemoval", false)
		and live_roster in service._geometry_owner_prior_rosters.get(transform_source_id, [])
		and service._geometry_owner_capture_proofs.get(transform_source_id, {}).get("visualSourceReceipt") == live_proof.get("visualSourceReceipt")
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible,
		removed_visual)
	service._geometry_owner_rosters[transform_source_id] = live_roster
	var accepted_transform_groups: Array = transform_publisher._static_section_transform_artifacts.get(
		transform_part.id, [])
	var accepted_transform_revision := String(transform_publisher._static_section_transform_artifact_revisions.get(
		transform_part.id, ""))
	var accepted_capture: Dictionary = transform_publisher.capture_static_section_transform_artifacts(
		transform_part.id, accepted_transform_revision)
	var changed_capture := accepted_capture.duplicate(false)
	var changed_groups: Array = []
	for group_value: Variant in accepted_capture.get("groups", []):
		var changed_group: Dictionary = group_value.duplicate(false)
		changed_group["contentDigest"] = "f".repeat(64)
		changed_groups.append(changed_group)
	changed_capture["groups"] = changed_groups
	check("artifact_capture_identity_binds_group_content_digest",
		accepted_capture.get("status") == "ready"
		and service._geometry_capture_identity(accepted_capture) \
			!= service._geometry_capture_identity(changed_capture),
		{"groupCount":changed_groups.size()})
	transform_publisher._static_section_transform_artifacts.erase(transform_part.id)
	var missing_transform: Dictionary = service.capture_static_section_contribution(
		roster_census, transform_section)
	check("missing_transform_artifacts_stay_pending_and_keep_legacy_visual_visible",
		missing_transform.get("status") == "pending"
		and String(missing_transform.get("reason", "")) == "static_transform_artifact_roster_unavailable"
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible
		and transform_part.collision_enabled and bool(transform_part.snapshot().get("collision", false)),
		missing_transform)
	transform_publisher._static_section_transform_artifacts[transform_part.id] = accepted_transform_groups
	transform_publisher._static_section_transform_artifact_revisions[transform_part.id] = accepted_transform_revision
	transform_publisher._watch_static_section_transform_resources(transform_part.id,
		accepted_transform_revision, accepted_transform_groups)
	var saved_visual_revisions: Dictionary = service.visual_plan.visual_source_revisions
	service.visual_plan.visual_source_revisions = {transform_part.id:"changed-admitted-source-revision"}
	service.visual_plan.visual_source_revisions.make_read_only()
	var stale_transform: Dictionary = service.capture_static_section_contribution(
		roster_census, transform_section)
	check("stale_member_binding_stays_pending_and_keeps_legacy_visual_visible",
		stale_transform.get("status") == "pending"
		and String(stale_transform.get("reason", "")) == "static_visual_source_revision_stale"
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible
		and transform_part.collision_enabled and bool(transform_part.snapshot().get("collision", false)),
		stale_transform)
	service.visual_plan.visual_source_revisions = saved_visual_revisions
	var legacy_visuals_still_visible := _visible_transform_visual(transform_publisher) != null
	for visual_value: Variant in transform_publisher.published_nodes:
		if visual_value is MultiMeshInstance3D and not (visual_value as MultiMeshInstance3D).visible:
			legacy_visuals_still_visible = false
	check("transform_contribution_never_fabricates_packet_receipts_or_retires_old_visuals",
		transform_publisher._chunk_static_packet_expected.is_empty()
		and transform_publisher._chunk_static_packet_pending_expected.is_empty()
		and transform_publisher._chunk_static_packet_receipts.is_empty()
		and legacy_visuals_still_visible
		and transform_part.collision_enabled and bool(transform_part.snapshot().get("collision", false)),
		{"publishedVisualCount":transform_publisher.published_nodes.filter(
			func(value: Variant) -> bool: return value is MultiMeshInstance3D).size(),
		"visible":legacy_visuals_still_visible,
		"packetExpected":transform_publisher._chunk_static_packet_expected.size(),
		"packetReceipts":transform_publisher._chunk_static_packet_receipts.size()})
	transform_publisher.arm_parent_move_after_next_transform_artifact_capture()
	var moved_during_capture: Dictionary = service.capture_static_section_contribution(
		roster_census, transform_section)
	check("source_parent_move_after_initial_transform_capture_stays_pending",
		moved_during_capture.get("status") == "pending"
		and String(moved_during_capture.get("reason", "")) \
			== "static_visual_source_boundary_changed"
		and _visible_transform_visual(transform_publisher) != null
		and _visible_transform_visual(transform_publisher).visible
		and transform_part.collision_enabled and bool(transform_part.snapshot().get("collision", false)),
		{"capture":moved_during_capture,
		"captureCall":transform_publisher.artifact_capture_call})
	var old_release_receipt := {"status":"installed", "worldId":world_id,
		"sectionKey":transform_section, "generation":44,
		"contentManifestDigest":"a".repeat(64), "backendInstanceId":10,
		"chunkInstanceId":11, "ownerCell":SectionGrid.chunk_key_for_section(transform_section)}
	old_release_receipt.make_read_only()
	var newer_release_receipt := {"status":"installed", "worldId":world_id,
		"sectionKey":transform_section, "generation":45,
		"contentManifestDigest":"b".repeat(64), "backendInstanceId":10,
		"chunkInstanceId":11, "ownerCell":SectionGrid.chunk_key_for_section(transform_section)}
	newer_release_receipt.make_read_only()
	var newer_release_proof := {"receipt":newer_release_receipt,
		"coverageRevision":"new-coverage", "sourceRevisions":{}}
	newer_release_proof.make_read_only()
	service._section_install_acknowledgements[transform_section] = newer_release_proof
	var delayed_release: Dictionary = service.release_section_install(
		transform_section, "old-coverage", old_release_receipt)
	check("delayed_old_receipt_release_preserves_newer_provider_claim",
		delayed_release.get("status") == "acknowledged"
		and delayed_release.get("reason") == "citadel_section_release_claim_replaced"
		and service._section_install_acknowledgements.get(transform_section, {}) \
			== newer_release_proof,
		{"release":delayed_release,
			"retainedGeneration":service._section_install_acknowledgements.get(
				transform_section, {}).get("receipt", {}).get("generation", 0)})
	var exact_old_release_proof := {"receipt":old_release_receipt,
		"coverageRevision":"old-coverage", "sourceRevisions":{}}
	exact_old_release_proof.make_read_only()
	service._section_install_acknowledgements[transform_section] = exact_old_release_proof
	var exact_release: Dictionary = service.release_section_install(
		transform_section, "old-coverage", old_release_receipt)
	check("exact_receipt_release_removes_only_matching_claim",
		exact_release.get("status") == "acknowledged"
		and exact_release.get("reason") == "citadel_section_release_exact_claim_removed"
		and not service._section_install_acknowledgements.has(transform_section),
		exact_release)
	service.census_fixture = census
	publisher.receipt_live = false
	var stale_receipt: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 12)
	check("stale_legacy_packet_receipt_stays_pending",
		stale_receipt.get("status") == "pending"
		and stale_receipt.get("reason") == "citadel_packet_group_revision_or_receipt_stale",
		stale_receipt)
	var tree_source_id := "citadel:site-a:member:tree:oak-1:section:0,0,0"
	service.census_fixture = {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{tree_source_id:"tree-revision"},
		"sections":{section:{"status":"complete", "coverageRevision":"tree-coverage",
			"sourcePartIds":[tree_source_id]}}}
	var tree_candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 13)
	check("tree_member_without_static_packet_adapter_stays_pending",
		tree_candidate.get("status") == "pending"
		and tree_candidate.get("reason") == "citadel_member_kind_has_no_prepared_static_packet",
		tree_candidate)
	service.census_fixture = {"status":"complete", "worldId":world_id,
		"authorityRevision":"authority-revision",
		"sourceRevisions":{},
		"sections":{section:{"status":"empty", "coverageRevision":"empty-coverage",
			"sourcePartIds":[]}}}
	var empty_candidate: Dictionary = service.capture_static_section_geometry_candidate(
		world_id, section, 14)
	check("explicit_empty_census_builds_zero_content_shared_snapshot",
		empty_candidate.get("status") == "ready"
		and empty_candidate.get("replacements", []).size() == 1
		and empty_candidate.get("replacements", [])[0].get("snapshot", {}).get("instanceCount") == 0,
		empty_candidate)
	await _exercise_attachment_replacement_service()
	await _exercise_furnishing_renderer_service()
	_exercise_legacy_visual_section_index()
	_exercise_synthetic_compiled_tree_alias_contract()
	_exercise_synthetic_tree_record_index_contract()
	_exercise_synthetic_presentation_completion_contract()
	_exercise_synthetic_light_source_discovery_contract()
	_exercise_light_only_publisher_capture_contract()
	_exercise_distinct_static_source_batch_compatibility()
	var report := {"schema":"citadel-section-geometry-service-contract/v1",
		"complete":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"passed":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"checkCount":checks.size(),
		"evidenceLevel":"synthetic_admission_with_real_producer_service_assembler; furnishing_rows_use_real_scene_job_native_renderer_frame_callback_and_completion_retirement; legacy_attachment_rows_inject_callback_delivery",
		"checks":checks}
	var report_path := OS.get_environment("VOXEL_CITADEL_SECTION_SERVICE_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_CITADEL_SECTION_SERVICE_REPORT is required")
		quit(2)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write Citadel section service report: " + report_path)
		quit(2)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if report.passed else 1)


func check(name: String, passed: bool, evidence: Dictionary) -> void:
	checks.append({"name":name, "passed":passed, "evidence":evidence})
	if not passed:
		push_error("Citadel section service contract failed: " + name + " " + str(evidence))


func _exercise_publisher_roster_authority() -> void:
	var publisher := BuildingPublisher.new()
	var root := Node3D.new()
	var before_revision := publisher.published_node_roster_revision()
	publisher.register_published_visual(root, "part:roster")
	var captured := publisher.published_node_inventory_snapshot()
	var roots: Array = captured.get("roots", [])
	var read_only_snapshot: Array = publisher.published_node_roster_snapshot()
	var detached: Array = read_only_snapshot.duplicate()
	detached.clear()
	var registration_valid: bool = captured.get("status") == "ready" \
		and int(captured.get("publisherInstanceId", 0)) == publisher.get_instance_id() \
		and int(captured.get("rosterRevision", -1)) == before_revision + 1 \
		and roots.size() == 1 \
		and read_only_snapshot.is_read_only() \
		and int(roots[0].get("nodeInstanceId", 0)) == root.get_instance_id() \
		and String(roots[0].get("sourcePartId", "")) == "part:roster" \
		and publisher.published_node_roster_snapshot().size() == 1
	check("building_publisher_roster_snapshot_has_complete_revisioned_owner_identity",
		registration_valid, {"captured":captured,
			"backingCountAfterDetachedMutation":publisher.published_node_roster_snapshot().size()})
	var duplicate_revision := publisher.published_node_roster_revision()
	publisher.register_published_visual(root, "part:roster")
	var after_duplicate := publisher.published_node_inventory_snapshot()
	check("building_publisher_duplicate_root_registration_is_idempotent",
		publisher.published_node_roster_revision() == duplicate_revision \
			and after_duplicate.get("status") == "ready" \
			and after_duplicate.get("roots", []).size() == 1,
		{"revision":publisher.published_node_roster_revision(),
			"inventory":after_duplicate})
	var remove_revision := publisher.published_node_roster_revision()
	var removed := publisher.remove_published_node(root)
	var after_remove := publisher.published_node_inventory_snapshot()
	check("building_publisher_exact_remove_advances_revision_and_clears_source_identity",
		removed and publisher.published_node_roster_revision() == remove_revision + 1 \
		and after_remove.get("status") == "ready" \
		and after_remove.get("roots", []).is_empty(),
		{"removed":removed,"after":after_remove})
	var retained_node := Node3D.new()
	publisher.register_published_visual(retained_node, "part:clear")
	var clear_revision := publisher.published_node_roster_revision()
	publisher.clear_published_node_roster()
	var after_clear := publisher.published_node_inventory_snapshot()
	check("building_publisher_clear_advances_revision_without_freeing_external_nodes",
		publisher.published_node_roster_revision() == clear_revision + 1 \
		and after_clear.get("status") == "ready" \
		and after_clear.get("roots", []).is_empty() \
		and is_instance_valid(retained_node) and not retained_node.is_queued_for_deletion(),
		{"after":after_clear,"nodeStillValid":is_instance_valid(retained_node)})
	root.free()
	retained_node.free()


func _exercise_legacy_visual_section_index() -> void:
	_exercise_publisher_roster_authority()
	var publisher := LegacyIndexPublisher.new()
	var root := Node3D.new()
	root.name = "LegacyIndexRoot"
	root.position = Vector3(3, 3, 3)
	var visual := MeshInstance3D.new()
	visual.mesh = BoxMesh.new()
	root.add_child(visual)
	get_root().add_child(root)
	publisher.published_nodes.append(root)
	var index := LegacyVisualIndex.new()
	var section := SectionGrid.key_for_world_position(root.global_position)
	var wrong_section := section + Vector3i(1, 0, 0)
	var initial := index.request_section(publisher, section)
	check("legacy_visual_index_requires_incremental_inventory_before_empty_or_nonempty_ack",
		initial.get("status") == "pending"
		and initial.get("reason") == "legacy_visual_index_preparing", initial)
	for _step in range(8):
		index.advance(96, 1000)
		if index.request_section(publisher, section).get("status") == "ready":
			break
	var ready: Dictionary = index.request_section(publisher, section)
	var outside: Dictionary = index.request_section(publisher, wrong_section)
	check("legacy_visual_index_returns_exact_live_intersecting_visuals",
		ready.get("status") == "ready" and ready.get("visuals", []).size() == 1
		and outside.get("status") == "ready" and outside.get("visuals", []).is_empty(),
		{"inside":ready,"outside":outside,"stats":index.stats()})
	var late_visual := MeshInstance3D.new()
	late_visual.mesh = BoxMesh.new()
	late_visual.position = Vector3(0.5, 0.0, 0.0)
	root.add_child(late_visual)
	var late_pending: Dictionary = index.request_section(publisher, section)
	for _step in range(8):
		index.advance(96, 1000)
		if index.request_section(publisher, section).get("status") == "ready":
			break
	var late_ready: Dictionary = index.request_section(publisher, section)
	check("legacy_visual_index_watches_new_children_and_reopens_section_inventory",
		late_pending.get("status") == "pending"
		and late_ready.get("status") == "ready"
		and late_ready.get("visuals", []).size() == 2,
		{"pending":late_pending,"ready":late_ready,"stats":index.stats()})
	root.position.x += SectionGrid.SECTION_SIZE_METERS * 2.0
	var moved_stale_section: Dictionary = index.request_section(publisher, section)
	var moved_section := SectionGrid.key_for_world_position(root.global_position)
	var moved_visuals: Dictionary = index.request_section(publisher, moved_section)
	check("legacy_visual_index_invalidates_moved_visual_before_section_ack",
		moved_stale_section.get("status") == "pending"
		and moved_stale_section.get("reason") == "legacy_visual_index_entry_changed"
		and moved_visuals.get("status") == "ready"
		and moved_visuals.get("visuals", []).size() == 1,
		{"oldSection":moved_stale_section,"newSection":moved_visuals})
	index.clear()
	root.free()
	_exercise_scoped_legacy_visual_inventory()
	_exercise_owner_receipt_validation_scope()
	_exercise_resumable_geometry_owner_completion()
	_exercise_section_ack_currentness_scope()


func _exercise_section_ack_currentness_scope() -> void:
	var service := FixtureService.new()
	service._generation = 7
	var source_id := "citadel:site:member:building:part"
	var section := Vector3i(2, 1, -3)
	var roster := {"worldId":"seed:scope:7", "sourceRevision":"revision-current"}
	var row := {"sourcePartIds":[source_id]}
	var current := {"status":"complete", "worldId":"seed:scope:7",
		"sourceRevisions":{source_id:"revision-current"},
		"sections":{section:row}}
	service._section_ack_currentness_scope = {"current":current,
		"sectionKey":section, "generation":7}
	var exact_current := service._section_ack_census_proves_source_current(source_id, roster)
	var wrong_revision_current := current.duplicate(true)
	wrong_revision_current.sourceRevisions[source_id] = "revision-stale"
	service._section_ack_currentness_scope.current = wrong_revision_current
	var wrong_revision_rejected := not service._section_ack_census_proves_source_current(source_id, roster)
	service._section_ack_currentness_scope.current = current
	var absent_source_row := current.duplicate(true)
	absent_source_row.sections[section].sourcePartIds = []
	service._section_ack_currentness_scope.current = absent_source_row
	var absent_source_rejected := not service._section_ack_census_proves_source_current(source_id, roster)
	service._section_ack_currentness_scope.current = current
	service._section_ack_currentness_scope.generation = 6
	var replaced_generation_rejected := not service._section_ack_census_proves_source_current(source_id, roster)
	check("section_ack_currentness_fast_path_requires_exact_section_source_and_generation",
		exact_current and wrong_revision_rejected and absent_source_rejected
		and replaced_generation_rejected,
		{"exact":exact_current, "wrongRevisionRejected":wrong_revision_rejected,
		"absentSourceRejected":absent_source_rejected,
		"replacedGenerationRejected":replaced_generation_rejected})
	service._section_ack_currentness_scope = {}


func _exercise_scoped_legacy_visual_inventory() -> void:
	var publisher := LegacyIndexPublisher.new()
	var source_root := Node3D.new()
	var source_visual := MeshInstance3D.new()
	source_visual.mesh = BoxMesh.new()
	source_root.add_child(source_visual)
	var unrelated_root := Node3D.new()
	var unrelated_visual := MeshInstance3D.new()
	unrelated_visual.mesh = BoxMesh.new()
	unrelated_root.add_child(unrelated_visual)
	get_root().add_child(source_root)
	get_root().add_child(unrelated_root)
	publisher.register_source_root(source_root, "part:section")
	publisher.register_source_root(unrelated_root, "part:other")
	var index := LegacyVisualIndex.new()
	var section := SectionGrid.key_for_world_position(source_root.global_position)
	var initial := index.request_section_sources(publisher, section, ["part:section"])
	for _step in range(8):
		index.advance(96, 1000)
		if index.request_section_sources(publisher, section, ["part:section"]).get("status") == "ready":
			break
	var ready: Dictionary = index.request_section_sources(publisher, section, ["part:section"])
	check("legacy_visual_scoped_inventory_visits_only_sealed_source_roots",
		initial.get("status") == "pending" and ready.get("status") == "ready"
		and ready.get("visuals", []).size() == 1
		and int(ready.get("indexedNodeCount", 0)) == 2,
		{"initial":initial,"ready":ready,"stats":index.stats()})
	var late_visual := MeshInstance3D.new()
	late_visual.mesh = BoxMesh.new()
	source_root.add_child(late_visual)
	var reopened := index.request_section_sources(publisher, section, ["part:section"])
	for _step in range(8):
		index.advance(96, 1000)
		if index.request_section_sources(publisher, section, ["part:section"]).get("status") == "ready":
			break
	var after_child: Dictionary = index.request_section_sources(publisher, section, ["part:section"])
	check("legacy_visual_scoped_inventory_reopens_on_child_publication",
		reopened.get("status") == "pending" and after_child.get("status") == "ready"
		and after_child.get("visuals", []).size() == 2, {"pending":reopened,"ready":after_child})
	var untracked_root := Node3D.new()
	publisher.published_nodes.append(untracked_root)
	var untracked: Dictionary = index.request_section_sources(publisher, section, ["part:section"])
	check("legacy_visual_scoped_inventory_fails_closed_on_untracked_root",
		untracked.get("status") == "pending"
		and untracked.get("reason") == "published_node_owner_ledger_size_changed", untracked)
	index.clear()
	source_root.free()
	unrelated_root.free()
	untracked_root.free()


func _exercise_owner_receipt_validation_scope() -> void:
	var coordinator := ReceiptValidationCacheProbe.new()
	var section := Vector3i(4, 2, -3)
	var receipt := {"worldId":"world", "sectionKey":section, "generation":0,
		"censusDigest":"census", "contentManifestDigest":"manifest",
		"sourceRevision":"source", "translucentPovRevision":"pov",
		"backendInstanceId":11, "chunkInstanceId":12, "ownerCell":Vector2i(4, -3)}
	receipt.make_read_only()
	var candidate := {"generation":0}
	coordinator._production_candidates_by_section[section] = candidate
	coordinator._production_candidate_receipts[section] = receipt
	var scope_owner := RefCounted.new()
	var scope: Dictionary = coordinator.begin_geometry_owner_receipt_validation_scope(scope_owner)
	var first := coordinator.installed_section_receipt_is_current(section, receipt)
	var second := coordinator.installed_section_receipt_is_current(section, receipt)
	var ended: Dictionary = coordinator.end_geometry_owner_receipt_validation_scope(
		scope_owner, int(scope.get("token", 0)))
	check("geometry_owner_ack_scope_reuses_exact_section_receipt_liveness",
		scope.get("status") == "ready" and first and second
		and ended.get("status") == "released"
		and ended.get("livenessChecks") == 1 and ended.get("cacheHits") == 1
		and coordinator.live_check_count == 1,
		{"scope":scope,"first":first,"second":second,"ended":ended,
			"liveCheckCount":coordinator.live_check_count})
	var after_scope := coordinator.installed_section_receipt_is_current(section, receipt)
	check("geometry_owner_ack_scope_does_not_reuse_liveness_after_release",
		after_scope and coordinator.live_check_count == 2,
		{"afterScope":after_scope,"liveCheckCount":coordinator.live_check_count})


func _exercise_queued_geometry_owner_proof_request() -> void:
	var sealed := OwnerCompletion.seal("queued-world", "queued-source",
		"queued-source", "queued-revision", "queued-incarnation", [], true)
	var roster: Dictionary = sealed.get("roster", {})
	var coordinator := QueuedGeometryCompletionCoordinator.new()
	var service := Service.new()
	var pending_request := {"status":"pending", "reason":"geometry_owner_completion_queued",
		"retryable":true, "requestKey":"queued-proof-key"}
	coordinator.queued_result = pending_request
	var pending := service._request_citadel_geometry_owner_completion(
		coordinator, roster, [])
	var queued_without_inline_work: bool = pending.get("status") == "pending" \
		and pending.get("reason") == "citadel_section_ack_source_slice_pending" \
		and coordinator.request_count == 1 and coordinator.cursor_advance_count == 0 \
		and is_same(coordinator.requested_roster, roster)
	check("citadel_ack_queues_geometry_owner_proof_without_advancing_cursor",
		queued_without_inline_work, {"result":pending,
			"requestCount":coordinator.request_count,
			"inlineCursorAdvances":coordinator.cursor_advance_count})

	var section := Vector3i(4, 0, 2)
	var identity_key := SourceRoster._source_part_identity_key(
		"queued-source", "queued-source")
	var receipt := {"removalRevisions":{identity_key:"queued-revision"}}
	receipt.make_read_only()
	var sections: Array[Vector3i] = [section]
	sections.make_read_only()
	var completion := {"status":"ready", "ownerSections":sections,
		"receiptsBySection":{section:receipt}}
	coordinator.queued_result = completion
	var ready := service._request_citadel_geometry_owner_completion(
		coordinator, roster, [])
	var exact_receipt_accepted: bool = ready.get("status") == "ready" \
		and coordinator.cursor_advance_count == 0
	check("citadel_completion_token_requires_current_exact_section_receipts",
		exact_receipt_accepted, {"result":ready,
			"inlineCursorAdvances":coordinator.cursor_advance_count})
	coordinator.allow_receipt = false
	var stale := service._geometry_owner_completion_receipts_are_current(
		coordinator, roster, completion)
	check("citadel_completion_token_rejects_replaced_native_receipt",
		stale.get("status") == "pending"
		and stale.get("reason") == "citadel_geometry_owner_completion_receipt_stale",
		stale)


func _exercise_resumable_geometry_owner_completion() -> void:
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("slice-owner-world")
	var source_id := "building:site:owner-proof"
	var part_id := "site:owner-proof"
	var revision := "owner-revision-1"
	var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var members: Array[Dictionary] = []
	var section_keys: Array[Vector3i] = []
	for index in range(3):
		var section := Vector3i(index + 2, 0, 0)
		section_keys.append(section)
		var buffer: Array[float] = []
		buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY,
			Vector3(1, 1, 1)),
			Color.WHITE, Color.WHITE))
		buffer.make_read_only()
		members.append(OwnerCompletion.packed_member(source_id, part_id, revision,
			"owner-segment-%d" % index, 0, section, bounds, buffer, 0,
			{"meshContentDigest":"owner-mesh".sha256_text()}))
	var sealed := OwnerCompletion.seal("slice-owner-world", source_id, part_id,
		revision, "owner-incarnation", members)
	var roster: Dictionary = sealed.get("roster", {})
	var identity := Coordinator._source_part_identity_key(source_id, part_id)
	for index in range(section_keys.size()):
		var section: Vector3i = section_keys[index]
		var receipt := {"status":"installed", "syntheticAccepted":true,
			"sourceRevisions":{identity:revision}}
		receipt.make_read_only()
		var manifest_entry := {"sourceId":source_id, "sourcePartId":part_id,
			"geometrySourceRanges":[members[index]]}
		var candidate := {"candidate":{"snapshot":{"manifest":[manifest_entry]}}}
		coordinator._production_candidates_by_section[section] = candidate
		coordinator._production_candidate_receipts[section] = receipt
	coordinator._visible_sections_by_source_id[source_id] = {
		section_keys[0]:revision, section_keys[1]:revision, section_keys[2]:revision}
	var visible_sections := section_keys.duplicate()
	visible_sections.make_read_only()
	coordinator._visible_section_keys_by_source_id[source_id] = visible_sections
	var max_work := 0
	var max_elapsed := 0
	var pending_calls := 0
	var result: Dictionary = {}
	var session_key := ""
	var cumulative_progress: Array[int] = []
	var unrelated_install_preserved_session := false
	var same_source_replacement_preserved_expected_cursor := false
	var same_source_replacement_rebuilt_closure := false
	var status_reports_progress := false
	var status_summary: Dictionary = {}
	for advance_index in range(100):
		result = coordinator.advance_geometry_owner_completion(roster, [], 2)
		max_work = maxi(max_work, int(result.get("workItems", 0)))
		max_elapsed = maxi(max_elapsed, int(result.get("elapsedUsec", 0)))
		if result.get("status") == "pending": pending_calls += 1
		session_key = String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
		var active_session: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
		if not active_session.is_empty():
			cumulative_progress.append(int(active_session.get("workItems", 0)))
		if advance_index == 0:
			var work_before_unrelated := int(active_session.get("workItems", 0))
			var unrelated_section := Vector3i(90, 0, 0)
			var unrelated_candidate := {"candidate":{"snapshot":{"manifest":[{
				"sourceId":"unrelated-source", "sourcePartId":"unrelated-part",
				"geometrySourceRanges":[]}]}}}
			var unrelated_receipt := {"status":"installed", "syntheticAccepted":true}
			unrelated_receipt.make_read_only()
			coordinator._advance_geometry_owner_dependency_revision_for_candidate(unrelated_candidate)
			coordinator._production_candidates_by_section[unrelated_section] = unrelated_candidate
			coordinator._production_candidate_receipts[unrelated_section] = unrelated_receipt
			var after_unrelated: Dictionary = coordinator.advance_geometry_owner_completion(roster, [], 2)
			var session_after_unrelated: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
			status_summary = coordinator.status().get("geometryOwnerCompletionSessions", {})
			var status_sample: Array = status_summary.get("sample", [])
			var status_row: Dictionary = {}
			for status_row_value: Variant in status_sample:
				if status_row_value is Dictionary and status_row_value.get("sourceId") == source_id:
					status_row = status_row_value
					break
			status_reports_progress = status_summary.get("active", 0) > 0 \
				and not status_row.is_empty() \
				and status_row.get("stage") == session_after_unrelated.get("stage") \
				and int(status_row.get("cumulativeWork", -1)) \
					== int(session_after_unrelated.get("workItems", 0)) \
				and int(status_row.get("cumulativeWork", -1)) > work_before_unrelated
			unrelated_install_preserved_session = not session_after_unrelated.is_empty() \
				and is_same(active_session, session_after_unrelated) \
				and after_unrelated.get("status") == "pending" \
				and int(session_after_unrelated.get("workItems", 0)) > work_before_unrelated \
				and status_reports_progress
			var expected_cursor_before_replacement := int(session_after_unrelated.get("memberCursor", 0))
			var target_section: Vector3i = section_keys[0]
			var replacement_candidate := {"candidate":{"snapshot":{"manifest":[{
				"sourceId":source_id, "sourcePartId":part_id,
				"geometrySourceRanges":[members[0]]}]}}}
			var replacement_receipt := {"status":"installed", "syntheticAccepted":true,
				"sourceRevisions":{identity:revision}, "generation":2}
			replacement_receipt.make_read_only()
			coordinator._advance_geometry_owner_dependency_revision_for_candidate(replacement_candidate)
			coordinator._production_candidates_by_section[target_section] = replacement_candidate
			coordinator._production_candidate_receipts[target_section] = replacement_receipt
			var added_section := Vector3i(9, 0, 0)
			var added_candidate := {"candidate":{"snapshot":{"manifest":[{
				"sourceId":source_id, "sourcePartId":part_id,
				"geometrySourceRanges":[]}]}}}
			var added_receipt := {"status":"installed", "syntheticAccepted":true,
				"sourceRevisions":{identity:revision}, "generation":1}
			added_receipt.make_read_only()
			coordinator._advance_geometry_owner_dependency_revision_for_candidate(added_candidate)
			coordinator._production_candidates_by_section[added_section] = added_candidate
			coordinator._production_candidate_receipts[added_section] = added_receipt
			coordinator._visible_sections_by_source_id[source_id][added_section] = revision
			var expanded_visible_sections := visible_sections.duplicate()
			expanded_visible_sections.append(added_section)
			expanded_visible_sections.make_read_only()
			coordinator._visible_section_keys_by_source_id[source_id] = expanded_visible_sections
			coordinator._advance_geometry_owner_visible_membership_revision(source_id)
			var after_replacement: Dictionary = coordinator.advance_geometry_owner_completion(roster, [], 2)
			var session_after_replacement: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
			same_source_replacement_preserved_expected_cursor = \
				not session_after_replacement.is_empty() \
				and is_same(active_session, session_after_replacement) \
				and int(session_after_replacement.get("memberCursor", 0)) >= expected_cursor_before_replacement \
				and int(session_after_replacement.get("closureResetCount", 0)) == 1
			same_source_replacement_rebuilt_closure = \
				int(session_after_replacement.get("dependencyRevision", -1)) \
				== int(coordinator._geometry_owner_dependency_revision_by_source[source_id]) \
				and int(session_after_replacement.get("membershipRevision", -1)) \
				== int(coordinator._geometry_owner_visible_membership_revision_by_source[source_id]) \
				and session_after_replacement.get("visibleSections", []).has(added_section) \
				and session_after_replacement.get("sectionTokens", {}).is_empty() \
				and after_replacement.get("status") == "pending"
		if result.get("status") == "ready": break
	var monotonic_progress := cumulative_progress.size() > 1
	for progress_index in range(1, cumulative_progress.size()):
		if cumulative_progress[progress_index] < cumulative_progress[progress_index - 1]:
			monotonic_progress = false
	check("geometry_owner_completion_advances_with_bounded_partial_progress",
		result.get("status") == "ready" and pending_calls > 1
		and max_work <= 2 and result.get("memberCount") == 3
		and result.get("receiptCount") == 4 and unrelated_install_preserved_session
		and monotonic_progress and same_source_replacement_preserved_expected_cursor \
		and same_source_replacement_rebuilt_closure,
		{"result":result,"pendingCalls":pending_calls,
			"sealStatus":sealed.get("status"), "sealReason":sealed.get("reason", ""),
			"world":coordinator.world_identity(), "rosterReadOnly":roster.is_read_only(),
			"membersReadOnly":roster.get("members", []).is_read_only() if roster.has("members") else false,
			"maxWorkItemsPerCall":max_work,"maxElapsedUsecPerCall":max_elapsed,
			"cumulativeWorkByCall":cumulative_progress,
			"monotonicProgress":monotonic_progress,
			"unrelatedInstallPreservedSession":unrelated_install_preserved_session,
			"sameSourceReplacementPreservedExpectedCursor":same_source_replacement_preserved_expected_cursor,
			"sameSourceReplacementRebuiltClosure":same_source_replacement_rebuilt_closure,
			"statusReportsProgressAfterUnrelatedInstall":status_reports_progress,
			"statusSummary":status_summary})
	var stale_coordinator := SyntheticPresentationCoordinator.new()
	stale_coordinator.configure("slice-owner-world")
	for section: Vector3i in section_keys:
		var receipt := {"status":"installed", "syntheticAccepted":true,
			"sourceRevisions":{identity:revision}}
		receipt.make_read_only()
		stale_coordinator._production_candidates_by_section[section] = \
			coordinator._production_candidates_by_section[section]
		stale_coordinator._production_candidate_receipts[section] = receipt
	stale_coordinator._visible_sections_by_source_id[source_id] = \
		coordinator._visible_sections_by_source_id[source_id].duplicate()
	var stale_visible_sections := section_keys.duplicate()
	stale_visible_sections.make_read_only()
	stale_coordinator._visible_section_keys_by_source_id[source_id] = stale_visible_sections
	var first_section: Vector3i = section_keys[0]
	var before_replacement: Dictionary = {}
	var old_section_token: Dictionary = {}
	for _advance in range(100):
		before_replacement = stale_coordinator.advance_geometry_owner_completion(roster, [], 2)
		var active_key := String(stale_coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
		var active: Dictionary = stale_coordinator._geometry_owner_completion_sessions.get(active_key, {})
		if active.get("sectionTokens", {}).has(first_section):
			old_section_token = active.sectionTokens[first_section]
			break
	var replacement_receipt := {"status":"installed", "syntheticAccepted":false,
		"sourceRevisions":{identity:revision}}
	replacement_receipt.make_read_only()
	var first_candidate: Dictionary = stale_coordinator._production_candidates_by_section[first_section]
	var replaced_candidate := first_candidate.duplicate(true)
	stale_coordinator._advance_geometry_owner_dependency_revision_for_candidate(replaced_candidate)
	stale_coordinator._production_candidates_by_section[first_section] = replaced_candidate
	stale_coordinator._production_candidate_receipts[first_section] = replacement_receipt
	var after_replacement: Dictionary = stale_coordinator.advance_geometry_owner_completion(roster, [], 2)
	var active_key := String(stale_coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var active: Dictionary = stale_coordinator._geometry_owner_completion_sessions.get(active_key, {})
	var old_token_discarded: bool = not active.get("sectionTokens", {}).has(first_section) \
		or not is_same(active.get("sectionTokens", {}).get(first_section, {}).get("receipt", {}),
			old_section_token.get("receipt", {}))
	var stale_result: Dictionary = {}
	for _advance in range(100):
		stale_result = stale_coordinator.advance_geometry_owner_completion(roster, [], 2)
		if stale_result.get("reason") == "geometry_owner_native_receipt_missing_or_stale":
			break
	var current_candidate := first_candidate.duplicate(true)
	var current_receipt := {"status":"installed", "syntheticAccepted":true,
		"sourceRevisions":{identity:revision}, "generation":3}
	current_receipt.make_read_only()
	stale_coordinator._advance_geometry_owner_dependency_revision_for_candidate(current_candidate)
	stale_coordinator._production_candidates_by_section[first_section] = current_candidate
	stale_coordinator._production_candidate_receipts[first_section] = current_receipt
	var current_result: Dictionary = {}
	for _advance in range(100):
		current_result = stale_coordinator.advance_geometry_owner_completion(roster, [], 2)
		if current_result.get("status") == "ready":
			break
	check("geometry_owner_completion_discards_progress_after_receipt_replacement",
		before_replacement.get("status") == "pending"
		and not old_section_token.is_empty() and old_token_discarded
		and stale_result.get("status") == "pending"
		and stale_result.get("reason") == "geometry_owner_native_receipt_missing_or_stale"
		and current_result.get("status") == "ready"
		and is_same(current_result.get("receiptsBySection", {}).get(first_section, {}), current_receipt),
		{"beforeReplacement":before_replacement,"afterReplacement":after_replacement,
			"staleReceiptResult":stale_result,"currentReceiptResult":current_result,
			"oldTokenDiscarded":old_token_discarded})
	var changed_members: Array[Dictionary] = members.duplicate()
	var changed_member: Dictionary = {}
	for member_key_value: Variant in members[0]:
		changed_member[member_key_value] = members[0][member_key_value]
	changed_member["sourceSegmentId"] = "changed-owner-segment"
	changed_member.make_read_only()
	changed_members[0] = changed_member
	var changed_roster_result := OwnerCompletion.seal("slice-owner-world", source_id,
		part_id, revision, "owner-incarnation", changed_members)
	var changed_roster: Dictionary = changed_roster_result.get("roster", {})
	var prior_roster_result := OwnerCompletion.seal("slice-owner-world", source_id,
		part_id, "owner-revision-prior", "prior-owner-incarnation", [], true)
	var prior_roster: Dictionary = prior_roster_result.get("roster", {})
	var changed_prior_inputs: Array = [prior_roster]
	var roster_change_start := stale_coordinator.advance_geometry_owner_completion(roster, [], 2)
	var roster_change_key := String(stale_coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var roster_change_old_session: Dictionary = stale_coordinator._geometry_owner_completion_sessions.get(roster_change_key, {})
	var changed_roster_advance := stale_coordinator.advance_geometry_owner_completion(changed_roster, [], 2)
	var changed_roster_key := String(stale_coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var changed_roster_session: Dictionary = stale_coordinator._geometry_owner_completion_sessions.get(changed_roster_key, {})
	var changed_prior_advance := stale_coordinator.advance_geometry_owner_completion(
		changed_roster, changed_prior_inputs.duplicate(), 2)
	var changed_prior_key := String(stale_coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	changed_prior_advance = stale_coordinator.advance_geometry_owner_completion(
		changed_roster, changed_prior_inputs.duplicate(), 2)
	var owner_reset_after_retry := int(stale_coordinator._geometry_owner_completion_sessions.get(
		changed_prior_key, {}).get("ownerInputResetCount", 0))
	changed_prior_advance = stale_coordinator.advance_geometry_owner_completion(
		changed_roster, changed_prior_inputs.duplicate(), 2)
	var changed_prior_session: Dictionary = stale_coordinator._geometry_owner_completion_sessions.get(changed_prior_key, {})
	check("geometry_owner_completion_restarts_for_changed_roster_or_prior_digest",
		roster_change_start.get("status") == "ready"
		and changed_roster_result.get("status") == "ready"
		and changed_roster_advance.get("status") == "pending"
		and changed_roster_key != roster_change_key
		and not is_same(changed_roster_session, roster_change_old_session)
		and changed_roster_session.get("roster") == changed_roster
		and changed_prior_advance.get("status") == "pending"
		and changed_prior_key != changed_roster_key
		and changed_prior_session.get("ownerInputResetCount", 0) == owner_reset_after_retry
		and changed_prior_session.get("digestUnitsProcessed", 0) >= 4
		and String(changed_prior_session.get("priorIdentities", [""])[0]).contains(
			String(prior_roster.get("digest", ""))),
		{"rosterStart":roster_change_start,"changedRoster":changed_roster_advance,
			"changedPrior":changed_prior_advance,"oldKey":roster_change_key,
			"newRosterKey":changed_roster_key,"newPriorKey":changed_prior_key})
	_exercise_large_geometry_owner_validation()
	_exercise_large_prior_geometry_owner_validation()
	_exercise_same_token_prior_replacement_rejected()
	_exercise_maximum_prior_identity_work()
	_exercise_malformed_geometry_owner_validation()


func _exercise_large_geometry_owner_validation() -> void:
	const MEMBER_COUNT := 8192
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("large-slice-owner-world")
	var source_id := "building:site:large-owner-proof"
	var part_id := "site:large-owner-proof"
	var revision := "large-owner-revision"
	var section := Vector3i(10, 0, 0)
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	var members: Array[Dictionary] = []
	for index in range(MEMBER_COUNT):
		members.append(OwnerCompletion.packed_member(source_id, part_id, revision,
			"large-owner-segment-%05d" % index, 0, section,
			AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
			{"meshContentDigest":"large-owner-mesh".sha256_text()}))
	var sealed := OwnerCompletion.seal("large-slice-owner-world", source_id,
		part_id, revision, "large-owner-incarnation", members)
	var roster: Dictionary = sealed.get("roster", {})
	var identity := Coordinator._source_part_identity_key(source_id, part_id)
	var receipt := {"status":"installed", "syntheticAccepted":true,
		"sourceRevisions":{identity:revision}}
	receipt.make_read_only()
	var candidate := {"candidate":{"snapshot":{"manifest":[{
		"sourceId":source_id, "sourcePartId":part_id,
		"geometrySourceRanges":members}]}}}
	coordinator._production_candidates_by_section[section] = candidate
	coordinator._production_candidate_receipts[section] = receipt
	coordinator._visible_sections_by_source_id[source_id] = {section:revision}
	var visible: Array[Vector3i] = [section]
	visible.make_read_only()
	coordinator._visible_section_keys_by_source_id[source_id] = visible
	var expected_cursor := 0
	var expected_digest_units := 0
	var max_work := 0
	var max_elapsed := 0
	var bounded_progress: bool = sealed.get("status") == "ready" \
		and roster.get("members", []).size() == MEMBER_COUNT
	for _call in range(8):
		var result: Dictionary = coordinator.advance_geometry_owner_completion(roster, [], 2, 250)
		max_work = maxi(max_work, int(result.get("workItems", 0)))
		max_elapsed = maxi(max_elapsed, int(result.get("elapsedUsec", 0)))
		var session_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
		var session: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
		var cursor := int(session.get("memberCursor", 0))
		var digest_units := int(result.get("digestUnitsProcessed", 0))
		bounded_progress = bounded_progress and result.get("status") == "pending" \
			and result.get("stage") == "expected_members" \
			and int(result.get("workItems", 0)) <= 2 \
			and digest_units == 1 \
			and cursor == expected_cursor + int(result.get("workItems", 0)) \
				- (digest_units - expected_digest_units) \
			and int(session.get("rosterValidationRowsProcessed", -1)) == cursor
		expected_cursor = cursor
		expected_digest_units = digest_units
	check("geometry_owner_large_roster_validation_is_slice_bounded",
		bounded_progress and expected_cursor == 15 and max_work <= 2 and max_elapsed < 5000,
		{"memberCount":MEMBER_COUNT,"cursorAfterEightCalls":expected_cursor,
			"maxWorkItemsPerCall":max_work,"maxElapsedUsecPerCall":max_elapsed,
			"boundedProgress":bounded_progress,"rosterDigest":roster.get("digest", "")})


func _exercise_malformed_geometry_owner_validation() -> void:
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("malformed-slice-owner-world")
	var source_id := "building:site:malformed-owner-proof"
	var part_id := "site:malformed-owner-proof"
	var revision := "malformed-owner-revision"
	var section := Vector3i(12, 0, 0)
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	var member := OwnerCompletion.packed_member(source_id, part_id, revision,
		"malformed-owner-segment", 0, section,
		AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
		{"meshContentDigest":"malformed-owner-mesh".sha256_text()})
	var sealed := OwnerCompletion.seal("malformed-slice-owner-world", source_id,
		part_id, revision, "malformed-owner-incarnation", [member])
	var valid_roster: Dictionary = sealed.get("roster", {})
	var malformed_roster := _forged_owner_roster_member(valid_roster, 0, "attributesDigest", "bad")
	var malformed_current := coordinator.advance_geometry_owner_completion(
		malformed_roster, [], 2)
	var prior_sealed := OwnerCompletion.seal("malformed-slice-owner-world", source_id,
		part_id, "prior-malformed-owner-revision", "prior-malformed-owner-incarnation", [
		OwnerCompletion.packed_member(source_id, part_id, "prior-malformed-owner-revision",
			"prior-malformed-owner-segment", 0, section,
			AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
			{"meshContentDigest":"prior-malformed-owner-mesh".sha256_text()})])
	var malformed_prior := _forged_owner_roster_member(
		prior_sealed.get("roster", {}), 0, "attributesDigest", "bad")
	var malformed_prior_inputs: Array = [malformed_prior]
	malformed_prior_inputs.make_read_only()
	var prior_result: Dictionary = coordinator.advance_geometry_owner_completion(
		valid_roster, malformed_prior_inputs, 2)
	if prior_result.get("stage") != "prior_sections" and prior_result.get("reason") != "geometry_owner_prior_member_invalid":
		prior_result = coordinator.advance_geometry_owner_completion(valid_roster,
			malformed_prior_inputs, 2)
	check("geometry_owner_incremental_validation_rejects_malformed_rows_and_priors",
		malformed_roster.is_read_only()
		and malformed_current.get("status") == "pending"
		and malformed_current.get("reason") == "geometry_owner_roster_member_invalid"
		and malformed_prior.get("members", []).is_read_only()
		and prior_result.get("status") == "pending"
		and prior_result.get("reason") == "geometry_owner_prior_member_invalid",
		{"malformedCurrent":malformed_current,"malformedPrior":prior_result,
			"forgedRosterReadOnly":malformed_roster.is_read_only(),
			"forgedPriorStatus":malformed_prior.get("status")})


func _exercise_large_prior_geometry_owner_validation() -> void:
	const MEMBER_COUNT := 8192
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("large-prior-owner-world")
	var source_id := "building:site:large-prior-proof"
	var part_id := "site:large-prior-proof"
	var section := Vector3i(20, 0, 0)
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	var members: Array[Dictionary] = []
	for index in range(MEMBER_COUNT):
		members.append(OwnerCompletion.packed_member(source_id, part_id,
			"large-prior-revision", "large-prior-segment-%05d" % index, 0,
			section, AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
			{"meshContentDigest":"large-prior-mesh".sha256_text()}))
	var prior_result := OwnerCompletion.seal("large-prior-owner-world", source_id,
		part_id, "large-prior-revision", "large-prior-incarnation", members)
	var prior: Dictionary = prior_result.get("roster", {})
	var current_result := OwnerCompletion.seal("large-prior-owner-world", source_id,
		part_id, "large-current-revision", "large-current-incarnation", [], true)
	var current: Dictionary = current_result.get("roster", {})
	var expected_cursor := 0
	var max_work := 0
	var max_elapsed := 0
	var stable: bool = prior_result.get("status") == "ready" and current_result.get("status") == "ready"
	for _call in range(8):
		# Match Citadel: mutable `.duplicate()` wrapper rebuilt for each retry.
		var fresh_prior_list: Array = [prior].duplicate()
		var result: Dictionary = coordinator.advance_geometry_owner_completion(
			current, fresh_prior_list, 2, 250)
		max_work = maxi(max_work, int(result.get("workItems", 0)))
		max_elapsed = maxi(max_elapsed, int(result.get("elapsedUsec", 0)))
		var session_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
		var session: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
		var cursor := int(session.get("priorMemberCursor", 0))
		stable = stable and result.get("status") == "pending" \
			and int(result.get("totalWorkItems", 0)) <= 3 \
			and int(result.get("totalWorkItems", 0)) == int(result.get("identityWorkItems", 0)) \
				+ int(result.get("cursorWorkItems", 0)) \
			and cursor >= expected_cursor and cursor - expected_cursor <= 2 \
			and session.get("priorRosters", []).size() == 1 \
			and is_same(session.get("priorRosters", [])[0], prior)
		expected_cursor = cursor
	check("geometry_owner_large_prior_roster_resumes_across_fresh_mutable_arrays",
		stable and expected_cursor == 15 and max_work <= 3 and max_elapsed < 5000,
		{"priorMemberCount":MEMBER_COUNT,"priorCursorAfterEightCalls":expected_cursor,
			"maxTotalWorkItemsIncludingPriorIdentity":max_work,
			"maxElapsedUsecPerCall":max_elapsed,"stableContinuation":stable})


func _exercise_same_token_prior_replacement_rejected() -> void:
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("same-token-prior-replacement-world")
	var source_id := "building:site:same-token-prior"
	var part_id := "site:same-token-prior"
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	var first_section := Vector3i(30, 0, 0)
	var alternate_section := Vector3i(31, 0, 0)
	var original_member := OwnerCompletion.packed_member(source_id, part_id,
		"same-token-revision", "captured-member", 0, first_section,
		AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
		{"meshContentDigest":"captured-prior-mesh".sha256_text()})
	var alternate_member := OwnerCompletion.packed_member(source_id, part_id,
		"same-token-revision", "replacement-member", 0, alternate_section,
		AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE), buffer, 0,
		{"meshContentDigest":"replacement-prior-mesh".sha256_text()})
	var original_result := OwnerCompletion.seal("same-token-prior-replacement-world",
		source_id, part_id, "same-token-revision", "same-token-incarnation", [original_member])
	var alternate_result := OwnerCompletion.seal("same-token-prior-replacement-world",
		source_id, part_id, "same-token-revision", "same-token-incarnation", [alternate_member])
	var original: Dictionary = original_result.get("roster", {})
	var alternate: Dictionary = alternate_result.get("roster", {}).duplicate(false)
	# Simulate a copied token on different valid contents. The coordinator must
	# reject the object substitution and keep traversing its captured roster.
	alternate["digest"] = original.get("digest", "")
	alternate.make_read_only()
	var current_result := OwnerCompletion.seal("same-token-prior-replacement-world",
		source_id, part_id, "current-revision", "current-incarnation", [], true)
	var current: Dictionary = current_result.get("roster", {})
	var first_inputs: Array = [original]
	var first := coordinator.advance_geometry_owner_completion(current, first_inputs, 1)
	var replaced_inputs: Array = [alternate]
	var rejected := coordinator.advance_geometry_owner_completion(current, replaced_inputs, 1)
	var session_key := String(coordinator._geometry_owner_completion_session_key_by_source.get(source_id, ""))
	var session: Dictionary = coordinator._geometry_owner_completion_sessions.get(session_key, {})
	var accepted_inputs: Array = [original]
	var continued := coordinator.advance_geometry_owner_completion(current, accepted_inputs, 1)
	var expected_owner_sections: Dictionary = session.get("ownerRequiredSections", {})
	check("geometry_owner_prior_same_token_object_replacement_cannot_change_captured_proof",
		first.get("status") == "pending"
		and rejected.get("status") == "pending"
		and rejected.get("reason") == "geometry_owner_prior_roster_object_replaced_same_identity"
		and is_same(session.get("priorRosters", [])[0], original)
		and continued.get("status") == "pending"
		and expected_owner_sections.has(first_section)
		and not expected_owner_sections.has(alternate_section),
		{"first":first,"rejectedReplacement":rejected,"continued":continued,
			"capturedSection":first_section,"alternateSection":alternate_section,
			"ownerRequiredSections":expected_owner_sections})


func _exercise_maximum_prior_identity_work() -> void:
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("maximum-prior-identity-world")
	var source_id := "building:site:maximum-prior-identity"
	var part_id := "site:maximum-prior-identity"
	var current_result := OwnerCompletion.seal("maximum-prior-identity-world",
		source_id, part_id, "current-revision", "current-incarnation", [], true)
	var current: Dictionary = current_result.get("roster", {})
	var priors: Array = []
	for index in range(64):
		var prior_result := OwnerCompletion.seal("maximum-prior-identity-world",
			source_id, part_id, "prior-revision-%02d" % index,
			"prior-incarnation-%02d" % index, [], true)
		priors.append(prior_result.get("roster", {}))
	var result: Dictionary = coordinator.advance_geometry_owner_completion(
		current, priors.duplicate(), 2, 1000)
	check("geometry_owner_maximum_prior_identity_work_is_reported_and_bounded",
		result.get("status") == "pending"
		and int(result.get("identityWorkItems", 0)) == 65
		and int(result.get("cursorWorkItems", 0)) == 1
		and int(result.get("totalWorkItems", 0)) == 66
		and int(result.get("workItems", 0)) == int(result.get("totalWorkItems", 0))
		and int(result.get("elapsedUsec", 0)) < 5000,
		{"result":result,"priorCount":priors.size()})


func _forged_owner_roster_member(roster: Dictionary, member_index: int,
		field: String, value: Variant) -> Dictionary:
	if roster.is_empty() or not roster.is_read_only() or not roster.get("members") is Array:
		return {"status":"failed", "reason":"source_roster_unavailable"}
	var members: Array = roster.members.duplicate()
	var row: Dictionary = {}
	for key: Variant in members[member_index]:
		row[key] = members[member_index][key]
	row[field] = value
	row.make_read_only()
	members[member_index] = row
	members.make_read_only()
	var forged := roster.duplicate(false)
	forged["members"] = members
	forged.make_read_only()
	return forged


func _visible_transform_visual(publisher: Object) -> MultiMeshInstance3D:
	if publisher == null or not publisher.get("published_nodes") is Array: return null
	for value: Variant in publisher.get("published_nodes"):
		if value is MultiMeshInstance3D and is_instance_valid(value) \
				and not value.is_queued_for_deletion():
			return value as MultiMeshInstance3D
	return null


## Synthetic lifetime integration: real publisher/provider/assembler/wrapper/
## session/native backend. Manual frame acknowledgement is not live draw proof.
func _exercise_distinct_static_source_batch_compatibility() -> void:
	var parent := Node3D.new()
	get_root().add_child(parent)
	var publisher := BuildingPublisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.publication_site_id = "batch-sharing"
	publisher.source_blueprint_id = "batch-sharing"
	publisher._scene_parent = weakref(parent)
	var material := MaterialCatalog.create_material("stone_foundation")
	publisher.material_cache = {"stone_foundation":material}
	var parts: Array = []
	var revisions: Array[String] = []
	for index in range(2):
		var part := BuildingPart.new({"id":"part-%d" % index, "kind":"beam",
			"material":"stone_foundation", "position":Vector3(2 + index * 2, 2, 2),
			"size":Vector3.ONE, "recipe":{"visual":true}})
		var revision := Preparation.static_record_binding(part.snapshot())
		parts.append(part)
		revisions.append(revision)
		publisher.static_visual_source_part_id = part.id
		publisher.static_visual_source_revision = revision
		publisher.static_visual_part_tier = "structural"
		publisher.collect_static_visual_transform(Transform3D(Basis.IDENTITY, part.position),
			material, Color.WHITE)
		publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent, false)
	var steps := 0
	while publisher.has_pending_static_flush() and steps < 1000:
		publisher.advance_static_flush(parent, 1)
		steps += 1
	var normalized: Array[Dictionary] = []
	var captures: Array[Dictionary] = []
	var adapter = load("res://scripts/world/CitadelSectionGeometryAdapter.gd")
	for index in range(2):
		var capture: Dictionary = publisher.capture_static_section_transform_artifacts(
			parts[index].id, revisions[index])
		captures.append(capture)
		for group: Dictionary in capture.get("groups", []):
			normalized.append(adapter._prepare_transform_artifact_group(group,
				"citadel:batch-sharing:member:building:" + parts[index].id,
				parts[index].id, "census-%d" % index, revisions[index], Vector3i.ZERO))
	check("real_distinct_static_sources_share_draw_compatibility_and_keep_raw_revisions",
		normalized.size() == 2 and normalized[0].get("status") == "ready"
		and normalized[1].get("status") == "ready"
		and revisions[0] != revisions[1]
		and normalized[0].compatibility == normalized[1].compatibility
		and not normalized[0].compatibility.has("producerSourceRevision")
		and normalized[0].producerSourceRevision == revisions[0]
		and normalized[1].producerSourceRevision == revisions[1],
		{"groups":normalized, "captures":captures, "flushSteps":steps})
	parent.free()


func _exercise_light_only_publisher_capture_contract() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var publisher := BuildingPublisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "light-only-service"
	publisher.publication_site_id = "light-only-site"
	publisher._scene_parent = weakref(parent)
	var part := BuildingPart.new({"id":"lamp", "kind":"decor", "material":"candle_flame",
		"position":Vector3(7,3,2), "rotation":Vector3(0,0.7,0), "size":Vector3.ONE,
		"collision":false, "recipe":{"visual":false, "practicalLight":true, "lightRange":6.0}})
	var revision := Preparation.static_record_binding(part.snapshot())
	publisher.static_visual_source_part_id = part.id
	publisher.static_visual_source_revision = revision
	publisher.static_visual_collecting = true
	publisher.static_visual_part_transform = Transform3D(Basis.from_euler(part.rotation),part.position)
	publisher.publish_practical_light(part,parent)
	publisher.static_visual_collecting = false
	publisher._record_completed_source_part(part)
	# A zero-geometry direct-node source still needs the normal explicit source
	# boundary commit; there is no static batch upload to trigger it implicitly.
	publisher._begin_static_flush(parent,false,true)
	var steps := 0
	while publisher.has_pending_static_flush() and steps < 100:
		publisher.advance_static_flush(parent,1)
		steps += 1
	var captured: Dictionary = publisher.capture_committed_static_visual_source(part.id,revision)
	check("real_light_only_publisher_seals_presentation_without_fake_geometry", captured.get("status") == "ready" \
		and captured.get("groups", [null]).is_empty() and captured.get("presentationMounts", []).size() == 1 \
		and captured.presentationMounts[0].sweptWorldBounds == AABB(Vector3(1,-3,-4),Vector3(12,12,12)),
		{"status":captured.get("status"), "reason":captured.get("reason"), "steps":steps})
	parent.free()

func _exercise_synthetic_light_source_discovery_contract() -> void:
	var source := {"position":Vector3(31, 4, 31), "rotation":Vector3(0.2, 1.2, 0.1),
		"recipe":{"visual":false, "practicalLight":true, "lightRange":5.5}}
	var support := CitadelPlan._practical_light_support(source, Vector3(32,0,32))
	var expected := AABB(Vector3(57.5,-1.5,57.5), Vector3(11,11,11))
	check("synthetic_light_only_recipe_has_exact_world_range_support", support.get("status") == "ready" \
		and support.get("bounds") == expected and not source.recipe.visual, {})
	var plan := CitadelPlan.new()
	if support.get("status") == "ready":
		CitadelPlan._add_member_record(plan, "building:light-only", "group", AABB(Vector3(62.9,3.9,62.9),Vector3.ONE * 0.2),
			true, "source-revision", support.bounds)
	var nonanchor := plan.visual_members_intersecting_bounds(AABB(Vector3(64,0,64),Vector3(2,8,2)))
	check("synthetic_light_only_source_discovered_across_section_before_render_capture", nonanchor.get("status") == "described" \
		and nonanchor.get("members", []).size() == 1 and nonanchor.members[0].memberId == "building:light-only", {})
	source.recipe.erase("lightRange")
	check("synthetic_light_recipe_uses_actual_publisher_default_range", CitadelPlan._practical_light_support(source,
		Vector3.ZERO).get("bounds") == AABB(source.position - Vector3.ONE * 5.0, Vector3.ONE * 10.0), {})
	source.recipe.lightRange = INF
	check("synthetic_light_recipe_rejects_nonfinite_range", CitadelPlan._practical_light_support(source,
		Vector3.ZERO).get("status") != "ready", {})

func _exercise_synthetic_presentation_completion_contract() -> void:
	var coordinator := SyntheticPresentationCoordinator.new()
	coordinator.configure("synthetic-presentation-world")
	var source_id := "citadel:synthetic:member:building:light"
	var pair := "section-part:" + var_to_bytes([source_id, source_id]).hex_encode()
	var member := {"schema":"static-section-presentation-member/v2", "sourceId":source_id,
		"sourcePartId":source_id, "sourceRevision":"r1", "producerSourceRevision":"raw-r1",
		"presentationMemberId":"light", "attachmentKey":"light-key", "ownershipKind":"borrowed_presentation",
		"intendedVisible":true, "neutralParentToWorld":Transform3D.IDENTITY,
		"sweptWorldBounds":AABB(Vector3(-2,-2,-2), Vector3(4,4,4)),
		"motion":{"kind":"static", "closedParentToBody":Transform3D.IDENTITY, "raiseOffset":Vector3.ZERO, "swing":0.0}}
	_seal_attachment_values(member)
	coordinator._production_candidates_by_section[Vector3i.ZERO] = {"candidate":{"snapshot":{"presentationMembers":[member]}}}
	coordinator._production_candidate_receipts[Vector3i.ZERO] = {"syntheticAccepted":true, "sourceRevisions":{pair:"r1"}}
	check("synthetic_presentation_completion_accepts_exact_current_native_oracle", coordinator.validate_presentation_owner_completion(
		"synthetic-presentation-world", source_id, source_id, "r1", [member]).get("status") == "ready", {})
	coordinator.allow_receipt = false
	check("synthetic_presentation_completion_rejects_stale_native_oracle", coordinator.validate_presentation_owner_completion(
		"synthetic-presentation-world", source_id, source_id, "r1", [member]).get("status") != "ready", {})
	coordinator.allow_receipt = true
	var changed := member.duplicate(true)
	changed.producerSourceRevision = "raw-r2"
	_seal_attachment_values(changed)
	check("synthetic_presentation_completion_checks_full_member_value", coordinator.validate_presentation_owner_completion(
		"synthetic-presentation-world", source_id, source_id, "r1", [changed]).get("status") != "ready", {})
	coordinator._production_candidates_by_section[Vector3i.ZERO] = {"candidate":{"snapshot":{"presentationMembers":[]}}}
	check("synthetic_presentation_departure_rejects_unaccepted_absence", coordinator.validate_presentation_owner_completion(
		"synthetic-presentation-world", source_id, source_id, "removed-r2", [], [member]).get("status") != "ready", {})
	coordinator._production_candidate_receipts[Vector3i.ZERO] = {"syntheticAccepted":true, "removalRevisions":{pair:"removed-r2"}}
	check("synthetic_presentation_departure_requires_exact_tombstone", coordinator.validate_presentation_owner_completion(
		"synthetic-presentation-world", source_id, source_id, "removed-r2", [], [member]).get("status") == "ready", {})

func _exercise_synthetic_tree_record_index_contract() -> void:
	# Index/lifetime contract only: these retained records are synthetic and do
	# not claim recipe compilation, native installation, or visible gameplay.
	var queue := TreeQueue.new()
	var bodies: Array[StaticBody3D] = []
	for index in range(3):
		var body := StaticBody3D.new()
		root.add_child(body)
		body.set_meta("prop_id", "synthetic-index-%d" % index)
		body.set_meta("static_ecology_source_id", "seed:tree:synthetic-index-%d" % index)
		body.set_meta("tree_publication_owner", weakref(queue))
		body.set_meta("tree_section_recipe_input_expected_generation", 1)
		queue.remember_published_lod(body, {"treeId":body.get_meta("prop_id"), "worldSeed":"seed", "renderLodTier":"near"},
			[], {"signature":"synthetic-r1"}, false, "legacy_mesh")
		bodies.append(body)
	var first := queue._published_record_for_body_id(bodies[0].get_instance_id())
	queue.cancel_body_publication(bodies[1])
	check("synthetic_tree_record_index_survives_middle_retirement", queue.published_lod_records.size() == 2 \
		and queue._published_record_for_body_id(bodies[1].get_instance_id()).is_empty() \
		and queue._published_record_for_body_id(bodies[2].get_instance_id()).bodyInstanceId == bodies[2].get_instance_id() \
		and is_same(first, queue._published_record_for_body_id(bodies[0].get_instance_id())), {})
	bodies[0].set_meta("tree_section_recipe_input_expected_generation", 2)
	var old_generation_proof := queue.tree_publication_proof(bodies[0], false)
	check("synthetic_tree_prior_lod_source_survives_new_generation", bool(old_generation_proof.get("sourcePrepared", false)) \
		and not bool(old_generation_proof.get("installed", true)) and first.producerGeneration == 1, {})
	first["expectedRecipeIdentityKey"] = "different-recipe"
	check("synthetic_tree_changed_recipe_invalidates_prior_source", not bool(queue.tree_publication_proof(
		bodies[0], false).get("sourcePrepared", true)), {})
	queue.remember_published_lod(bodies[0], {"treeId":bodies[0].get_meta("prop_id"), "worldSeed":"seed", "renderLodTier":"mid"},
		[], {"signature":"synthetic-r2"}, false, "legacy_mesh")
	check("synthetic_tree_replacement_updates_index_and_generation", queue.published_lod_records.size() == 2 \
		and queue._published_record_for_body_id(bodies[0].get_instance_id()).producerGeneration == 2 \
		and queue._published_record_for_body_id(bodies[0].get_instance_id()).recipeSignature == "synthetic-r2", {})
	var old := {"body":weakref(bodies[0]), "bodyInstanceId":bodies[0].get_instance_id(), "contentRevision":"old"}
	var current := {"body":weakref(bodies[0]), "bodyInstanceId":bodies[0].get_instance_id(), "contentRevision":"current"}
	queue._index_source_record("compiled", old)
	queue._index_source_record("compiled", current)
	queue._unindex_source_record("compiled", old)
	check("synthetic_tree_old_cache_retirement_preserves_current_record", is_same(current,
		queue._source_record_for_body("compiled", bodies[0])), {})
	queue._unindex_source_record("compiled", current)
	check("synthetic_tree_cache_eviction_keeps_accepted_source_record", queue._source_record_for_body("compiled", bodies[0]).is_empty() \
		and bool(queue.tree_publication_proof(bodies[0], false).get("sourcePrepared", false)), {})
	for body: StaticBody3D in bodies:
		queue.cancel_body_publication(body)
		body.free()
	queue.free()

func _exercise_synthetic_compiled_tree_alias_contract() -> void:
	# Explicit compiler-shaped synthetic input; the headed finite fixture owns
	# real recipe compilation and renderer acceptance evidence.
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	var mesh_digest := String(MeshFingerprint.inspect(mesh).get("contentDigest", ""))
	var material_digest := String(MaterialFingerprint.inspect(material).get("contentDigest", ""))
	var producer_id := "seed:tree:site-tree:6:site-a:1:a"
	var alias := "citadel:site-a:member:tree:a"
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"meshResourceKey":"mesh", "meshKey":"mesh|pipeline=synthetic-tree/v1|layer=opaque|sort=none", "meshContentDigest":mesh_digest,
		"meshLocalBounds":mesh.get_aabb(), "materialKey":"material", "materialDigest":material_digest,
		"pipelineRevision":"synthetic-tree/v1", "renderLayer":"opaque", "translucentSortPolicy":"none",
		"renderTier":"near", "castShadows":true, "visibilityRangeEnd":0.0, "fadeMargin":0.0}
	compatibility["batchKey"] = SnapshotBuilder.batch_compatibility_key(compatibility)
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2,2,2)), Color.WHITE, Color.WHITE))
	var member_key := "section-part:" + var_to_bytes([producer_id, "bole:0"]).hex_encode()
	var manifest := {"sourceId":producer_id, "sourceRevision":"compiled-r1", "ownedSectionKeys":[Vector3i.ZERO],
		"geometryOwnership":[{"memberId":"bole:0", "geometryOwnerSectionKey":Vector3i.ZERO,
			"supportSectionKeys":[Vector3i.ZERO], "conservativeWorldBounds":AABB(Vector3(1.5,1.5,1.5), Vector3.ONE)}]}
	var batch := {"sectionKey":Vector3i.ZERO, "batchKey":compatibility.batchKey, "compatibilityKey":compatibility,
		"meshKey":"mesh", "materialKey":"material", "ownerCell":Vector2i.ZERO,
		"contributors":{member_key:{"sourceId":producer_id, "sourcePartId":"bole:0", "sourceRevision":"compiled-r1",
			"instanceCount":1, "instanceAttributes":buffer}}}
	var captured := {"status":"ready", "producerSourceId":producer_id, "compiledSourceRevision":"compiled-r1",
		"propId":"site-tree:6:site-a:1:a", "sourceManifest":manifest,
		"compiledRecord":{"compiled":{"sources":[manifest], "batches":[batch],
			"resourceBindings":{"mesh":mesh, "material":material}}}}
	_seal_attachment_values(captured)
	var adapted := TreeAdapter.capture_compiled_contributor(captured, alias, "provider-r1", Vector3i.ZERO)
	check("synthetic_tree_alias_preserves_compiler_identity", adapted.get("status") == "ready" \
		and adapted.get("inputs", []).size() == 1 and adapted.inputs[0].sourceId == alias \
		and adapted.inputs[0].sourceRevision == "provider-r1" and captured.sourceManifest.sourceId == producer_id \
		and captured.sourceManifest.sourceRevision == "compiled-r1", {"result":adapted.get("status")})
	var stale := captured.duplicate(true)
	stale["compiledSourceRevision"] = "stale"
	_seal_attachment_values(stale)
	check("synthetic_tree_alias_rejects_compiler_revision_mismatch", TreeAdapter.capture_compiled_contributor(
		stale, alias, "provider-r1", Vector3i.ZERO).get("status") != "ready", {})
	var service := SyntheticRemovedTreeService.new()
	var binding := {"siteId":"site-a", "sourceKey":"synthetic", "generation":1}
	var proof := {"kind":"tree", "siteId":"site-a", "memberId":"tree:a", "binding":binding,
		"jobInstanceId":42, "authorityRevision":"authority-r1"}
	service.absent_authority = {"status":"absent", "reason":"removed_prop", "propId":captured.propId,
		"binding":binding, "jobInstanceId":42}
	var sealed := OwnerCompletion.seal("world", alias, alias, "provider-r1", "synthetic-owner",
		adapted.get("geometryOwnerMembers", []))
	if adapted.get("status") == "ready" and sealed.get("status") == "ready":
		service._retain_geometry_owner_roster(alias, sealed.roster, proof)
	var removed := service._current_roster_removal("world", alias, Vector3i.ZERO)
	var repeated := service._current_roster_removal("world", alias, Vector3i.ZERO)
	check("synthetic_tree_tombstone_retains_prior_owner_and_is_idempotent", removed.get("status") == "ready" \
		and removed == repeated and bool(service._geometry_owner_rosters.get(alias, {}).get("explicitRemoval", false)) \
		and service._geometry_owner_prior_rosters.get(alias, []).size() == 1, {"status":removed.get("status")})
	service.absent_authority.jobInstanceId = 43
	check("synthetic_tree_tombstone_rejects_replacement_owner", service._current_roster_removal(
		"world", alias, Vector3i.ZERO).get("status") != "ready", {})
	mesh.size = Vector3(2,2,2)
	check("synthetic_tree_alias_rejects_mutated_resource", TreeAdapter.capture_compiled_contributor(
		captured, alias, "provider-r1", Vector3i.ZERO).get("status") != "ready", {})

func _exercise_attachment_replacement_service() -> void:
	var base_transform := Transform3D.IDENTITY
	var base_digest := SnapshotBuilder._snapshot_digest({"neutral":base_transform},"transform-contract",1,Vector3i.ZERO)
	check("attachment_transform_digest_repeat_is_deterministic",not base_digest.is_empty() and base_digest == SnapshotBuilder._snapshot_digest(
		{"neutral":base_transform},"transform-contract",1,Vector3i.ZERO),{})
	var every_scalar_bound := not base_digest.is_empty()
	var every_nonfinite_rejected := true
	for column in range(4):
		for axis in range(3):
			var columns: Array[Vector3] = [base_transform.basis.x,base_transform.basis.y,base_transform.basis.z,base_transform.origin]
			var changed := columns[column]
			changed[axis] += 0.000001
			columns[column] = changed
			var mutated := Transform3D(Basis(columns[0],columns[1],columns[2]),columns[3])
			var digest := SnapshotBuilder._snapshot_digest({"neutral":mutated},"transform-contract",1,Vector3i.ZERO)
			every_scalar_bound = every_scalar_bound and not digest.is_empty() and digest != base_digest
			for invalid: float in [NAN,INF,-INF]:
				changed[axis] = invalid
				columns[column] = changed
				var invalid_transform := Transform3D(Basis(columns[0],columns[1],columns[2]),columns[3])
				every_nonfinite_rejected = every_nonfinite_rejected and SnapshotBuilder._snapshot_digest(
					{"neutral":invalid_transform},"transform-contract",1,Vector3i.ZERO).is_empty()
	check("attachment_transform_digest_binds_all_twelve_scalars",every_scalar_bound,{})
	check("attachment_transform_digest_rejects_all_nonfinite_scalars",every_nonfinite_rejected,{})
	var anchor := {"key":"fixture-compound","worldPosition":Vector3.ONE}
	anchor.make_read_only()
	check("compound_policy_rejects_anchor_under_legacy_policy",
		not SectionSnapshot.valid_geometry_ownership_descriptor({"compoundAnchor":anchor}), {})
	check("compound_policy_rejects_missing_anchor",
		not SectionSnapshot.valid_geometry_ownership_descriptor({"ownershipPolicy":"compound_attachment_anchor/v1"}), {})
	check("compound_policy_accepts_exact_anchor_contract",
		SectionSnapshot.valid_geometry_ownership_descriptor({"ownershipPolicy":"compound_attachment_anchor/v1","compoundAnchor":anchor}), {})
	check("compound_support_policy_rejects_anchor_under_legacy_policy",
		not SectionSnapshot.valid_support_ownership_descriptor({"ownershipPolicy":"citadel_center_geometry_owner/aabb_support_sections_v1","compoundAnchor":anchor}), {})
	check("compound_support_policy_rejects_missing_anchor",
		not SectionSnapshot.valid_support_ownership_descriptor({"ownershipPolicy":"compound_anchor_geometry_owner/swept_support_sections_v1"}), {})
	check("compound_support_policy_accepts_exact_anchor_contract",
		SectionSnapshot.valid_support_ownership_descriptor({"ownershipPolicy":"compound_anchor_geometry_owner/swept_support_sections_v1","compoundAnchor":anchor}), {})
	if not ClassDB.class_exists("ChunkRenderPacketBackend"):
		check("attachment_service_native_backend_available",false,{})
		return
	for motion: String in ["swing","raise"]:
		var scene := AttachmentScene.new()
		root.add_child(scene)
		var previous_scene := current_scene
		current_scene = scene
		scene.world_static_section_coordinator = Coordinator.new()
		scene.world_static_section_coordinator.configure("attachment-service-"+motion)
		var service := FixtureService.new()
		var first := _build_attachment_service_candidate(scene,service,motion,1)
		check(motion+"_initial_candidate_prepared", first.get("status") == "ready", first)
		if first.get("status") != "ready":
			check(motion+"_provider_wrapper_initial_install", false, first)
			current_scene = previous_scene
			scene.free()
			continue
		if first.get("status") == "ready":
			var compatibility: Dictionary = first.contribution.compatibilityByKey.values()[0].duplicate(false)
			compatibility["ownershipPolicy"] = "transformed_mesh_aabb_center/v1"
			check(motion+"_actual_batch_rejects_anchor_policy_mismatch",SnapshotBuilder.batch_compatibility_key(compatibility).is_empty(),{})
			var segment: Dictionary = first.candidate.candidate.snapshot.batches.values()[0].segments[0].duplicate(false)
			segment["ownershipPolicy"] = "transformed_mesh_aabb_center/v1"
			check(motion+"_actual_segment_rejects_anchor_policy_mismatch",
				not SectionSnapshot._has_valid_center_ownership(segment,first.candidate.sectionKey),{})
		var cached_replay: Dictionary = await _capture_section_contribution(
			service, first.census, first.section, 99)
		check(motion+"_same_current_source_reuses_immutable_artifact_capture",
			cached_replay.get("status") == "ready"
			and int(cached_replay.get("sourceArtifactCacheHitCount", 0)) == 1,
			{"capture":cached_replay,
				"presentationMountCount":first.publisher.capture_static_section_transform_artifacts(
					String(first.partId), String(first.memberBinding)).get("presentationMounts", []).size()})
		var installed := _install_attachment_service_candidate(first,true)
		check(motion+"_refcounted_publisher_identity_preserved",first.publisher.get_instance_id()<0 \
			and first.body.get_meta("section_attachment_publisher_instance_id",0)==first.publisher.get_instance_id(),{})
		check(motion+"_provider_wrapper_initial_install",installed.get("status")=="installed",installed)
		if installed.get("status") != "installed":
			current_scene = previous_scene; scene.free(); continue
		var second := _build_attachment_service_candidate(scene,service,motion,2)
		var pending := _install_attachment_service_candidate(second,false)
		check(motion+"_new_owner_replacement_awaits_frame",pending.get("status")=="pending_presentation",pending)
		if pending.get("status") != "pending_presentation":
			current_scene = previous_scene; scene.free(); continue
		var old_visuals: Array = Service._published_legacy_geometry(first.publisher)
		var old_hidden := not old_visuals.is_empty()
		for visual: GeometryInstance3D in old_visuals:
			Service._restore_legacy_visual_if_unclaimed(visual)
			old_hidden = old_hidden and not visual.visible
		check(motion+"_previous_claim_provider_cannot_restore_overlap",old_hidden,{})
		if motion == "swing": first.body.free()
		else: first.body.get_node("DoorPivot").free()
		var second_session: RefCounted = second.session
		scene.world_static_section_coordinator._on_section_frame_drawn(String(pending.presentationToken))
		var second_ack: Dictionary = second_session.finalize_presentation(String(pending.presentationToken))
		check(motion+"_previous_owner_exit_preserves_replacement_ack",second_ack.get("status")=="installed" \
			and second_ack.get("callbackCompletion",{}).get("status")=="completed",second_ack)
		var third := _build_attachment_service_candidate(scene,service,motion,3)
		var third_pending := _install_attachment_service_candidate(third,false)
		if third_pending.get("status") != "pending_presentation":
			check(motion+"_replacement_loss_recaptures_through_provider",false,third_pending)
			current_scene = previous_scene; scene.free(); continue
		if motion == "swing": third.body.free()
		else: third.body.get_node("DoorPivot").free()
		var reconciled := 0
		for visual: GeometryInstance3D in Service._published_legacy_geometry(third.publisher):
			Service._restore_legacy_visual_if_unclaimed(visual)
			reconciled += 1
		var stale: Dictionary = third.session.advance(8)
		scene.world_static_section_coordinator._on_section_frame_drawn(String(third_pending.presentationToken))
		check(motion+"_replacement_owner_loss_settles_before_recapture",
			stale.get("status")=="failed" and bool(stale.get("requiresAuthoritativeReassembly",false)) \
			and (motion!="raise" or reconciled>0),stale)
		var fourth := _build_attachment_service_candidate(scene,service,motion,4)
		var recaptured := _install_attachment_service_candidate(fourth,true)
		check(motion+"_replacement_loss_recaptures_through_provider",
			recaptured.get("status")=="installed",recaptured)
		var fifth := _build_attachment_service_candidate(scene,service,motion,5)
		var invalidated_pending := _install_attachment_service_candidate(fifth,false)
		if invalidated_pending.get("status") == "pending_presentation":
			fifth.body.set_meta("section_attachment_source_revision","invalidated-before-provider-reconcile")
			var invalidated_visuals: Array = Service._published_legacy_geometry(fifth.publisher)
			for visual: GeometryInstance3D in invalidated_visuals:
				Service._restore_legacy_visual_if_unclaimed(visual)
			var invalidated: Dictionary = fifth.session.advance(8)
			scene.world_static_section_coordinator._on_section_frame_drawn(String(invalidated_pending.presentationToken))
			check(motion+"_binding_invalidation_provider_first_settles_exact_token",
				not invalidated_visuals.is_empty() and invalidated.get("status")=="failed" \
				and bool(invalidated.get("requiresAuthoritativeReassembly",false)) \
				and invalidated.get("ownershipCleanup",{}).get("cancellationSettlement",{}).get("presentationToken")==invalidated_pending.presentationToken,
				invalidated)
			var sixth := _build_attachment_service_candidate(scene,service,motion,6)
			var revision_recapture := _install_attachment_service_candidate(sixth,true)
			check(motion+"_provider_first_cancellation_reentry_installs",revision_recapture.get("status")=="installed",revision_recapture)
		else:
			check(motion+"_binding_invalidation_provider_first_settles_exact_token",false,invalidated_pending)
			check(motion+"_provider_first_cancellation_reentry_installs",false,invalidated_pending)
		var seventh := _build_attachment_service_candidate(scene,service,motion,7)
		var original_visibility: Dictionary = {}
		if seventh.get("status") == "ready":
			var final_visuals: Array = Service._published_legacy_geometry(seventh.publisher)
			for index in range(final_visuals.size()):
				var visual: GeometryInstance3D = final_visuals[index]
				visual.visible = index != 0
				visual.set_meta("citadel_section_owned",true)
				original_visibility[visual.get_instance_id()] = visual.visible
		var final_installed := _install_attachment_service_candidate(seventh,true)
		var visibility_restored: bool = final_installed.get("status")=="installed" and original_visibility.size()>1
		if visibility_restored:
			var candidate: Dictionary = seventh.candidate
			var released: Dictionary = seventh.backend.call("release_packet",
				InstallSession.slot_id(candidate.worldId,candidate.sectionKey),candidate.generation)
			visibility_restored = released.get("status")=="released"
			for visual: GeometryInstance3D in Service._published_legacy_geometry(seventh.publisher):
				Service._restore_legacy_visual_if_unclaimed(visual)
				visibility_restored = visibility_restored and visual.visible==original_visibility.get(visual.get_instance_id()) \
					and Service._native_restoration_receipt_is_current(visual)
		check(motion+"_final_withdraw_provider_preserves_true_false_originals",visibility_restored,final_installed)
		var stale_restoration_rejected: bool = visibility_restored
		if visibility_restored:
			seventh.body.set_meta("section_attachment_source_revision","new-source-after-restoration")
			for visual: GeometryInstance3D in Service._published_legacy_geometry(seventh.publisher):
				stale_restoration_rejected = stale_restoration_rejected and not Service._native_restoration_receipt_is_current(visual)
		check(motion+"_restoration_receipt_is_not_new_source_authority",stale_restoration_rejected,{})
		for intent: String in ["direct_rollback","coordinator_drain"]:
			var generation := 8 if intent=="direct_rollback" else 10
			var prior := _build_attachment_service_candidate(scene,service,motion,generation)
			var prior_installed := _install_attachment_service_candidate(prior,true)
			var replacement := _build_attachment_service_candidate(scene,service,motion,generation+1)
			var replacement_pending := _install_attachment_service_candidate(replacement,false)
			if prior_installed.get("status")!="installed" or replacement_pending.get("status")!="pending_presentation":
				check(motion+"_previous_loss_"+intent+"_settles",false,replacement_pending)
				continue
			if motion=="swing": prior.body.free()
			else: prior.body.get_node("DoorPivot").free()
			var token := String(replacement_pending.presentationToken)
			var cancellation: Dictionary
			if intent=="direct_rollback":
				cancellation = replacement.session.rollback_presentation(token)
				scene.world_static_section_coordinator._on_section_frame_drawn(token)
			else:
				# Synthetic callback delivery is deferred until real drain invokes
				# Session.rollback_presentation while the backend is still alive.
				scene.world_static_section_coordinator.call_deferred("_on_section_frame_drawn",token)
				cancellation = await scene.world_static_section_coordinator.drain_pending_frame_presentations()
			var diagnostics: Dictionary = scene.world_static_section_coordinator.frame_presentation_callback_diagnostics()
			var cancelled: bool = replacement.session.state=="cancelled" and diagnostics.get("awaitingPresentationCount",-1)==0
			if intent=="direct_rollback":
				var proof: Dictionary = cancellation.get("cancellationSettlement",{})
				cancelled = cancelled and cancellation.get("status")=="cancelled" \
					and proof.get("presentationToken")==token and not bool(proof.get("previousRestored",true)) \
					and bool(proof.get("previousUnavailable",false))
			else: cancelled = cancelled and cancellation.get("status")=="drained"
			check(motion+"_previous_loss_"+intent+"_settles",cancelled,cancellation)
		# These older rows intentionally inject callback delivery. The real
		# RenderingServer still owns queued callback targets until a frame ends.
		await RenderingServer.frame_post_draw
		var callback_drain: Dictionary = await scene.world_static_section_coordinator.drain_pending_frame_presentations()
		if callback_drain.get("status") != "drained":
			check(motion+"_fixture_callbacks_drained",false,callback_drain)
			return
		var mesh_mutation := _verify_silent_array_mesh_clear_invalidates_artifact_gate(scene)
		check(motion+"_silent_array_mesh_clear_invalidates_retained_artifact_receipt",
			bool(mesh_mutation.get("passed", false)), mesh_mutation)
		current_scene = previous_scene
		scene.free()


func _verify_silent_array_mesh_clear_invalidates_artifact_gate(scene: Node3D) -> Dictionary:
	var parent := Node3D.new()
	scene.add_child(parent)
	var publisher := BuildingPublisher.new()
	publisher._scene_parent = weakref(parent)
	var box := BoxMesh.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.surface_get_arrays(0))
	var material := StandardMaterial3D.new()
	var mesh_identity := MeshFingerprint.inspect(mesh)
	var material_identity: Dictionary = OrdinaryGeometryAdapter._material_identity(material)
	if mesh_identity.get("status") != "ready" \
			or String(material_identity.get("digest", "")).length() != 64:
		parent.free()
		return {"passed":false, "reason":"fixture_resource_fingerprint_unavailable",
			"mesh":mesh_identity, "material":material_identity}
	var resources := {"mesh":mesh, "material":material}
	resources.make_read_only()
	var bounds: AABB = mesh.get_aabb()
	var group := {"resourceBindings":resources,
		"meshContentDigest":String(mesh_identity.contentDigest),
		"materialContentDigest":String(material_identity.digest),
		"sourceToWorld":parent.global_transform,
		"localBounds":bounds,
		"worldBounds":parent.global_transform * bounds}
	group.make_read_only()
	var groups: Array[Dictionary] = [group]
	groups.make_read_only()
	var source_part_id := "silent-mesh-clear"
	var source_revision := "fixture-revision"
	publisher._static_section_transform_artifacts[source_part_id] = groups
	publisher._static_section_transform_artifact_revisions[source_part_id] = source_revision
	publisher._static_section_transform_artifact_watch_revisions[source_part_id] = source_revision
	var current_before: bool = publisher.static_section_transform_artifact_receipt_is_current(
		source_part_id, source_revision, groups)
	mesh.clear_surfaces()
	var current_after: bool = publisher.static_section_transform_artifact_receipt_is_current(
		source_part_id, source_revision, groups)
	parent.free()
	return {"passed":current_before and not current_after,
		"currentBeforeMutation":current_before, "currentAfterClearSurfaces":current_after,
		"meshType":"ArrayMesh"}


func _build_attachment_service_candidate(scene: Node3D, service: FixtureService,
		motion: String, generation: int) -> Dictionary:
	var parent := Node3D.new()
	scene.add_child(parent)
	var publisher := BuildingPublisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "attachment-service"
	publisher.publication_site_id = "attachment-service"
	publisher._scene_parent = weakref(parent)
	var part := BuildingPart.new({"id":"moving-part","kind":"door","material":"painted_door",
		"position":Vector3(2,2,2),"size":Vector3(1.1,2.4,0.22),"collision":true,
		"recipe":{"doorMotion":motion,"doorPresentation":"portcullis" if motion=="raise" else "door"}})
	var body := publisher.publish_part(part,parent)
	publisher._record_completed_source_part(part)
	if not publisher._commit_publication_boundary(publisher._pending_publication_boundary,{}):
		return {"status":"failed","reason":"fixture_producer_boundary_failed"}
	var world_id := "attachment-service-"+motion
	var section := SectionGrid.key_for_world_position(body.global_position)
	var source := "citadel:attachment-service:member:building:moving-part:section:%d,%d,%d" % [section.x,section.y,section.z]
	var identity := "section-part:"+var_to_bytes([source,source]).hex_encode()
	var revision := "fixture-incarnation-%d" % generation
	var census: Dictionary = _seal_attachment_values({"status":"complete","worldId":world_id,
		"censusDigest":var_to_bytes([world_id,source,revision,generation]).hex_encode().sha256_text(),
		"sections":[section],"expectedContributorsBySection":{section:[identity]},
		"sourceRevisions":{identity:revision},"sourceProviderIds":{identity:"blueprint_buildings"},
		"sourceIdentities":{identity:{"sourceId":source,"sourcePartId":source}},
		"providerCoverageRevisions":{"blueprint_buildings":{section:revision}},
		"providerSnapshotRevisions":{"blueprint_buildings":revision}})
	service.census_fixture = {"status":"complete","worldId":world_id,"authorityRevision":revision,
		"sourceRevisions":{source:revision},"sections":{section:{"status":"complete",
			"coverageRevision":revision,"sourcePartIds":[source]}}}
	var binding := {"siteId":"attachment-service","generation":generation}
	service.visual_plan = FixtureVisualPlan.new()
	service.visual_plan.binding = binding
	service.visual_plan.visual_source_revisions = {part.id:Preparation.static_record_binding(part.snapshot())}
	service.visual_plan.visual_source_revisions.make_read_only()
	var admission := FixtureAdmission.new()
	admission.binding = binding
	service._admission = admission
	service._scenes = {Vector2i.ZERO:{"binding":binding,"packetMode":false,"phase":"scene_ready",
		"job":{"_building":publisher},"profile":{"origin":parent.global_position}}}
	var contribution: Dictionary = service.capture_static_section_contribution(census,section)
	if contribution.get("status") != "ready": return contribution
	var contributions: Array = [contribution.contribution]
	contributions.make_read_only()
	var assembled: Dictionary = Assembler.assemble(census,section,contributions,generation)
	if assembled.get("status") != "ready": return assembled
	return {"status":"ready","candidate":assembled.candidate,"contribution":contribution.contribution,
		"sourceArtifactCacheHitCount":int(contribution.get("sourceArtifactCacheHitCount", 0)),
		"census":census,"section":section,"partId":part.id,
		"memberBinding":Preparation.static_record_binding(part.snapshot()),
		"publisher":publisher,"body":body,"parent":parent}


func _install_attachment_service_candidate(context: Dictionary, acknowledge: bool) -> Dictionary:
	if context.get("status") != "ready": return context
	var candidate: Dictionary = context.candidate
	var begun := PacketOwner.begin_static_section_install(candidate,candidate.materialBindings,candidate.meshBindings)
	if begun.get("status") != "ready": return begun
	var session: RefCounted = begun.session
	context["session"] = session
	context["backend"] = begun.backend
	var step: Dictionary = {}
	for turn in range(256):
		step = session.advance(8)
		if step.get("status") not in ["pending","begun"]: break
	if step.get("status") != "pending_presentation" or not acknowledge: return step
	var callback_owner: Object = current_scene.get("world_static_section_coordinator")
	callback_owner.call("_on_section_frame_drawn",String(step.presentationToken))
	var finalized: Dictionary = session.finalize_presentation(String(step.presentationToken))
	if finalized.get("status")=="installed" and finalized.get("callbackCompletion",{}).get("status")!="completed":
		return {"status":"failed","reason":"fixture_callback_owner_not_drained","nativeResult":finalized}
	return finalized


## Synthetic admitted source/plan; actual furnishing publisher, SceneJob owner
## lookup, service, roster, assembler, renderer and real frame callbacks.
func _exercise_furnishing_renderer_service() -> void:
	for archetype: String in ["candle","hearth"]:
		var scene := AttachmentScene.new()
		root.add_child(scene)
		var previous_scene := current_scene
		current_scene = scene
		var camera := Camera3D.new()
		scene.add_child(camera)
		camera.position = Vector3(12,12,17)
		camera.look_at(Vector3(10,10,10))
		camera.current = true
		var coordinator := Coordinator.new()
		scene.world_static_section_coordinator = coordinator
		coordinator.configure("furnishing-renderer-"+archetype)
		coordinator.configure_source_roster(["blueprint_buildings"])
		var service := FixtureService.new()
		var context := _build_furnishing_service_source(scene,service,archetype,1)
		coordinator.register_source_provider("blueprint_buildings",service,"capture_static_section_sources")
		var section: Vector3i = context.section
		var census: Dictionary = coordinator.capture_authoritative_source_census([section])
		var contribution: Dictionary = await _capture_section_contribution(service,census,section)
		check(archetype+"_actual_furnishing_service_contribution",contribution.get("status")=="ready",contribution)
		var job_proof: Dictionary = context.job.furnishing_section_publisher(context.member,context.binding)
		check(archetype+"_actual_scene_job_furnishing_owner",job_proof.get("status")=="ready"
			and job_proof.get("publisher")==context.publisher,job_proof)
		var begin_rejected: bool = not context.publisher.begin_publication(context.job._plan,context.body.get_parent())
		context.publisher.clear_published()
		check(archetype+"_capture_lease_preserves_owner_against_rebegin_clear",begin_rejected
			and is_instance_valid(context.body) and not context.body.is_queued_for_deletion()
			and context.body.get_child(0) is CollisionShape3D,{})
		if contribution.get("status")!="ready":
			current_scene = previous_scene
			scene.free()
			continue
		var legacy: Array = Service._published_legacy_geometry(context.publisher)
		var retained := not legacy.is_empty()
		for visual: GeometryInstance3D in legacy: retained = retained and visual.visible
		check(archetype+"_legacy_retained_before_native_ack",retained,{})
		var original: Transform3D = context.body.transform
		context.body.position.x += 0.125
		var moved: Dictionary = service.capture_static_section_contribution(census,section)
		context.body.transform = original
		var epoch: int = context.body.get_meta("section_attachment_publication_epoch")
		context.body.set_meta("section_attachment_publication_epoch",epoch+1)
		var stale_epoch: Dictionary = service.capture_static_section_contribution(census,section)
		context.body.set_meta("section_attachment_publication_epoch",epoch)
		var mesh_size: Vector3 = context.publisher.unit_box.size
		if archetype=="hearth": context.publisher.unit_box.size = mesh_size*1.1
		else: context.publisher.unit_cylinder.height = 1.1
		var stale_mesh: Dictionary = service.capture_static_section_contribution(census,section)
		context.publisher.unit_box.size = mesh_size
		context.publisher.unit_cylinder.height = 1.0
		check(archetype+"_service_rejects_stale_body_epoch_resource",moved.get("status")=="pending"
			and stale_epoch.get("status")=="pending" and stale_mesh.get("status")=="pending",
			{"body":moved.get("reason"),"epoch":stale_epoch.get("reason"),"resource":stale_mesh.get("reason")})
		# Re-capture after the negative acts through the real provider.
		contribution = await _capture_section_contribution(service,census,section)
		var contributions: Array = [contribution.get("contribution",{})]
		contributions.make_read_only()
		var assembled := Assembler.assemble(census,section,contributions,1)
		var submitted: Dictionary = coordinator.submit_complete_section_candidate(assembled.get("candidate",{})) if assembled.get("status")=="ready" else assembled
		var outcome: Dictionary = submitted
		var pending_seen := false
		var retained_while_pending := retained
		if submitted.get("status")=="queued":
			for frame in range(180):
				outcome = coordinator.advance_complete_section_candidate(section,8)
				if outcome.get("stage")=="awaiting_frame":
					pending_seen = true
					for visual: GeometryInstance3D in legacy: retained_while_pending = retained_while_pending and visual.visible
				if outcome.get("status") in ["installed","failed","rollback_failed"]: break
				await process_frame
		check(archetype+"_real_frame_callback_native_install",outcome.get("status")=="installed"
			and pending_seen and retained_while_pending,{"result":outcome,"callbacks":coordinator.frame_presentation_callback_diagnostics()})
		var receipt: Dictionary = coordinator._production_candidate_receipts.get(section,{})
		var retained_after_install := not legacy.is_empty()
		for visual: GeometryInstance3D in legacy:
			retained_after_install = retained_after_install and visual.visible
		check(archetype+"_queued_owner_proof_keeps_legacy_visible_after_native_install",
			outcome.get("status")=="installed" and retained_after_install,
			{"installStatus":outcome.get("status"),"legacyRetained":retained_after_install})
		var acknowledged: Dictionary = coordinator.source_install_acknowledgement_proof(section,receipt)
		for attempt in range(48):
			if acknowledged.get("status")=="ready": break
			coordinator.advance_queued_complete_section_candidates(1,8)
			# The production provider incrementally prepares its live visual
			# section inventory from the ordinary service advance path.
			service.advance_legacy_visual_inventory(96, 350)
			acknowledged = coordinator.source_install_acknowledgement_proof(section,receipt)
			await process_frame
		var retired := not legacy.is_empty()
		for visual: GeometryInstance3D in legacy: retired = retired and not visual.visible
		var light: OmniLight3D = context.light
		check(archetype+"_completion_authorizes_only_visual_retirement",acknowledged.get("status")=="ready"
			and retired and is_instance_valid(context.body) and context.body.get_child(0) is CollisionShape3D
			and not context.body.get_child(0).disabled and light.get_parent()==context.mount
			and context.mount.get_parent()==context.body and light.is_visible_in_tree(),
			{"acknowledgement":acknowledged,"retired":retired})
		var installed_body: StaticBody3D = context.body
		# Identical body/recipe/publisher in a replacement scene job still has a
		# new owner incarnation; the prior section receipt cannot bless it.
		var replacement_job := SceneJob.new()
		replacement_job._root = context.job._root
		replacement_job._parent = context.job._parent
		replacement_job._binding = context.job._binding
		replacement_job._spatial = context.job._spatial
		replacement_job._furniture = context.job._furniture
		replacement_job._building = context.job._building
		replacement_job._plan = context.job._plan
		replacement_job._member_witnesses = context.job._member_witnesses.duplicate()
		service._scenes[Vector2i.ZERO]["job"] = replacement_job
		check(archetype+"_same_body_replacement_job_rejects_previous_install",
			not service.furnishing_section_visual_installed("furnishing-service",context.member,installed_body),{})
		service._scenes[Vector2i.ZERO]["job"] = context.job
		installed_body.free()
		var unloaded: Dictionary = context.job.furnishing_section_publisher(context.member,context.binding)
		check(archetype+"_unloaded_scene_owner_rejects_old_receipt",unloaded.get("status")=="pending"
			and context.publisher.committed_static_visual_source_identity("fixture-"+archetype).get("status")=="pending",unloaded)
		var replay := _build_furnishing_service_source(scene,service,archetype,2)
		var replay_census: Dictionary = coordinator.capture_authoritative_source_census([section])
		var replay_capture: Dictionary = await _capture_section_contribution(
			service,replay_census,section,2)
		check(archetype+"_replay_requires_new_body_capture",replay_capture.get("status")=="ready"
			and replay.body.get_instance_id()!=context.bodyInstanceId
			and not service.furnishing_section_visual_installed("furnishing-service",replay.member,replay.body),replay_capture)
		if replay_capture.get("status")=="ready":
			var replay_contributions: Array = [replay_capture.contribution]
			replay_contributions.make_read_only()
			var replay_assembled := Assembler.assemble(replay_census,section,replay_contributions,2)
			var replay_result: Dictionary = coordinator.submit_complete_section_candidate(replay_assembled.get("candidate",{})) if replay_assembled.get("status")=="ready" else replay_assembled
			if replay_result.get("status")=="queued":
				for frame in range(180):
					replay_result = coordinator.advance_complete_section_candidate(section,8)
					if replay_result.get("status") in ["installed","failed","rollback_failed"]: break
					await process_frame
			check(archetype+"_replayed_source_installs_new_native_receipt",replay_result.get("status")=="installed"
				and replay_result.get("receipt",{}).get("generation")==2,replay_result)
		var compile_drain: Dictionary = coordinator.drain_section_compiles()
		var install_drain: Dictionary = await coordinator.drain_pending_frame_presentations()
		check(archetype+"_owned_compile_install_callbacks_drained",compile_drain.get("status")=="drained"
			and install_drain.get("status")=="drained",{"compile":compile_drain,"install":install_drain})
		if compile_drain.get("status")!="drained" or install_drain.get("status")!="drained":
			return # Retain scene/backend ownership on failed cancellation.
		current_scene = previous_scene
		scene.free()


func _build_furnishing_service_source(scene: Node3D, service: FixtureService, archetype: String, generation: int) -> Dictionary:
	var parent := Node3D.new()
	scene.add_child(parent)
	var publisher := FurnishingPublisher.new()
	publisher.publication_site_id = "furnishing-service"
	publisher.source_blueprint_id = "furnishing-plan"
	var part := FurnishingPart.new({"id":"fixture-"+archetype,"archetype":archetype,
		"position":Vector3(10,10,10),"occupiedSize":Vector3(2,2,1),"collision":true})
	var body := publisher.publish_part(part,parent)
	var plan := FurnishingPlan.new("furnishing-plan")
	plan.parts.append(part)
	var member := "furnishing:"+part.id
	var source := "citadel:furnishing-service:member:"+member
	var section := SectionGrid.key_for_world_position(body.global_position)
	var revision := ("fixture-incarnation-%d" % generation).sha256_text()
	var world_id := "furnishing-renderer-"+archetype
	service.census_fixture = {"status":"complete","worldId":world_id,"authorityRevision":revision,
		"sourceRevisions":{source:revision},"sections":{section:{"status":"complete",
		"coverageRevision":revision,"sourcePartIds":[source]}}}
	var binding := {"siteId":"furnishing-service","generation":generation}
	service.visual_plan = FixtureVisualPlan.new()
	service.visual_plan.binding = binding
	service.visual_plan.visual_source_revisions = {member:Preparation.static_record_binding(part.snapshot())}
	service.visual_plan.visual_source_revisions.make_read_only()
	var admission := FixtureAdmission.new()
	admission.binding = binding
	service._admission = admission
	var job := SceneJob.new()
	job._root = parent
	job._parent = weakref(scene)
	job._binding = binding
	job._spatial = {"origin":parent.global_position}
	job._furniture = publisher
	job._plan = plan
	var building := BuildingPublisher.new()
	building.publication_site_id = "furnishing-service"
	building._scene_parent = weakref(parent)
	job._building = building
	job._member_witnesses[member] = {"body":weakref(body),"source":part,"sourceIndex":0,
		"sourceRevision":Preparation.static_record_binding(part.snapshot()),
		"publicationEpoch":publisher.source_part_publication_epoch(part.id)}
	service._scenes = {Vector2i.ZERO:{"binding":binding,"packetMode":false,"phase":"scene_ready",
		"job":job,"profile":{"origin":parent.global_position}}}
	var capture := publisher.capture_committed_static_visual_source(part.id,Preparation.static_record_binding(part.snapshot()))
	var light_binding: Dictionary = capture.presentationBindings.values()[0]
	return {"publisher":publisher,"body":body,"bodyInstanceId":body.get_instance_id(),
		"job":job,"member":member,"binding":binding,"section":section,
		"light":light_binding.light.get_ref(),"mount":light_binding.mount.get_ref()}


func _seal_attachment_values(value: Variant) -> Variant:
	if value is Dictionary:
		for key: Variant in value: _seal_attachment_values(value[key])
		if not value.is_read_only(): value.make_read_only()
	elif value is Array:
		for member: Variant in value: _seal_attachment_values(member)
		if not value.is_read_only(): value.make_read_only()
	return value
