extends RefCounted
class_name EcologySectionValueAdapter

## Converts realized ecology values into immutable section inputs. Trees and
## static props retain gameplay ownership while render members enter candidates
## with revisioned geometry and support-section ownership.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const InstanceAttributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const MaterialFingerprint := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const TreeAdapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const RemovedProps := preload("res://scripts/world/ActiveRemovedPropsSnapshot.gd")
const CitadelGeometryAdapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const SupportIndexScript := preload("res://scripts/world/EcologyWorldSupportIndex.gd")
const ProducerDomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")

const REQUIRED_ECOLOGY_CATEGORIES := [
	"trees_foliage_geometry",
	"surface_detail_instances",
	"surface_rocks",
	"ore",
	"forage",
	"underground_props"
]
const STATIC_PROP_CATEGORIES := ["surface_rocks", "ore", "forage", "underground_props"]
const TREE_SECTION_SOURCE_REVISION_SCHEMA := "ecology-tree-section-source/v1"
const STATIC_PROP_SUPPORT_POLICY := "center_geometry_owner/aabb_support_sections_v1"
const MAX_SOURCE_OWNER_DISCOVERY_CHUNKS := 512
const STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS := 5.0
const MAX_IDLE_READY_SOURCE_CAPTURE_JOBS := 128
const MAX_ACTIVE_SOURCE_CAPTURE_COHORTS := 2
const SOURCE_CAPTURE_FAIR_AGE_OPPORTUNITIES := 8
const SOURCE_CAPTURE_BLOCKED_RETRY_OPPORTUNITIES := 4
const STATIC_CENSUS_PROFILE_PHASES := [
	"closure_policy",
	"source_lookup",
	"source_conversion",
	"support_band_registration",
	"query_sealing"
]

const SCHEMA := "ecology-section-value-adapter/v1"
const PIPELINE_REVISION := "ecology_static_detail_pipeline/v1"
const PROVIDER_ID := "ecology_and_static_props"

var _world_id := ""
var _support_index: EcologyWorldSupportIndex
var _main_authority_ref: WeakRef
var _latest_by_section: Dictionary = {}
var _latest_coverage_by_section: Dictionary = {}
var _latest_support_ranges_by_section: Dictionary = {}
var _pending_legacy_removal_revisions_by_section: Dictionary = {}
var _tree_install_receipts_by_source: Dictionary = {}
var _latest_tree_candidate_by_source: Dictionary = {}
var _latest_legacy_visual_units: Dictionary = {}
var _legacy_visual_install_receipts_by_unit: Dictionary = {}
var _canonical_tree_compile_by_domain: Dictionary = {}
var _canonical_source_rows_by_domain: Dictionary = {}
var _canonical_tree_compile_job_by_domain: Dictionary = {}
var _canonical_tree_artifact_by_member: Dictionary = {}
var _canonical_tree_band_artifact_by_member_section: Dictionary = {}
var _canonical_static_artifact_by_member: Dictionary = {}
var _source_publication_member_keys: Dictionary = {} # publication ID -> adapter member keys
var _source_capture_jobs: Dictionary = {}
var _source_capture_jobs_by_section: Dictionary = {}
var _source_capture_latest_by_chunk: Dictionary = {}
var _source_capture_queue: Array[String] = []
var _source_capture_queued: Dictionary = {}
var _source_capture_idle_ready_order: Array[String] = []
var _source_capture_dispatch_sequence := 0
var _source_capture_cohorts: Dictionary = {}
var _source_capture_active_cohort_count := 0
var _source_capture_cohort_sequence := 0
var _source_capture_service_opportunities := 0
var _source_capture_cohort_admissions := 0
var _source_capture_cohort_completions := 0
var _source_capture_cohort_yields := 0
## Retained preparation state belongs to the existing source-capture cohort
## authority. It keeps the exact closure and family cursor between provider
## calls, so async source work does not require rebuilding the whole census.
var _source_section_preparations: Dictionary = {}
var _source_section_preparation_order: Array[String] = []
var _source_section_preparation_sequence := 0
var _source_section_preparation_units := 0
var _source_section_preparation_cache_hit_rows := 0
var _source_section_preparation_completions := 0
var _source_section_preparation_stale_count := 0
var _static_census_profile_calls := 0
var _static_census_profile_last_usec := 0
var _static_census_profile_max_usec := 0
var _static_census_profile_last_phase_usec: Dictionary = {}
var _static_census_profile_max_phase_usec: Dictionary = {}
var _static_census_profile_last_counts: Dictionary = {}
var _static_census_profile_max_provider_phase_usec: Dictionary = {}
var _static_census_profile_max_provider_counts: Dictionary = {}


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return _failed("invalid_ecology_provider_world")
	if not _world_id.is_empty() and _world_id != world_id:
		return _failed("ecology_provider_already_bound")
	if _world_id.is_empty():
		_support_index = SupportIndexScript.new()
		var support_configure: Dictionary = _support_index.configure(world_id)
		if support_configure.get("status") != "ready":
			return _failed(String(support_configure.get("reason", "ecology_support_index_configure_failed")))
		_latest_by_section.clear()
		_latest_coverage_by_section.clear()
		_latest_support_ranges_by_section.clear()
		_pending_legacy_removal_revisions_by_section.clear()
		_latest_legacy_visual_units.clear()
		_legacy_visual_install_receipts_by_unit.clear()
		_source_capture_jobs.clear()
		_source_capture_jobs_by_section.clear()
		_source_capture_latest_by_chunk.clear()
		_source_capture_queue.clear()
		_source_capture_queued.clear()
		_source_capture_idle_ready_order.clear()
		_source_capture_dispatch_sequence = 0
		_source_capture_cohorts.clear()
		_source_capture_active_cohort_count = 0
		_source_capture_cohort_sequence = 0
		_source_capture_service_opportunities = 0
		_source_capture_cohort_admissions = 0
		_source_capture_cohort_completions = 0
		_source_capture_cohort_yields = 0
		_source_section_preparations.clear()
		_source_section_preparation_order.clear()
		_source_section_preparation_sequence = 0
		_source_section_preparation_units = 0
		_source_section_preparation_cache_hit_rows = 0
		_source_section_preparation_completions = 0
		_source_section_preparation_stale_count = 0
		_reset_static_census_profile()
	_world_id = world_id
	return {"status":"ready", "worldId":_world_id}


## Per-section source-domain query exposed to the native demand/lease bridge.
## No producer census or missing source snapshot is interpreted as empty.
func query_section(world_id: String, section_key: Vector3i) -> Dictionary:
	if _support_index == null or world_id != _world_id:
		return _pending("ecology_support_query_world_stale")
	return _support_index.query_section(world_id, section_key)


func validate_coverage_certificate(certificate: Dictionary, world_id: String,
		section_key: Vector3i) -> Dictionary:
	if _support_index == null or world_id != _world_id:
		return _pending("ecology_support_query_world_stale")
	return _support_index.validate_coverage_certificate(certificate, world_id,
		section_key)


func acknowledge_section_receipt(section_key: Vector3i,
		source_index_revision: int, installed_receipt: Dictionary) -> Dictionary:
	if _support_index == null:
		return _pending("ecology_support_index_unavailable")
	return _support_index.acknowledge_section_receipt(section_key,
		source_index_revision, installed_receipt)


## Explicit producer-side hooks. A ready query is possible only after callers
## provide a complete certified inverse-domain census and deterministic value
## snapshot for each required source chunk.
func set_support_source_domains(section_key: Vector3i,
		source_chunk_keys: Array, census_certificate: Dictionary) -> Dictionary:
	if _support_index == null:
		return _pending("ecology_support_index_unavailable")
	return _support_index.set_required_source_domains(section_key,
		source_chunk_keys, census_certificate)


func set_support_source_domains_by_family(section_key: Vector3i,
		source_chunk_keys_by_family: Dictionary, census_certificate: Dictionary) -> Dictionary:
	if _support_index == null:
		return _pending("ecology_support_index_unavailable")
	return _support_index.set_required_source_domains_by_family(section_key,
		source_chunk_keys_by_family, census_certificate)


func publish_support_source_domain(world_id: String, source_chunk_key: Vector2i,
		snapshot: Dictionary, rows: Array) -> Dictionary:
	if _support_index == null or world_id != _world_id:
		return _pending("ecology_support_query_world_stale")
	return _support_index.publish_source_domain(world_id, source_chunk_key,
		snapshot, rows)


func publish_support_source_domain_families(world_id: String,
		source_chunk_key: Vector2i, family_bundle: Dictionary,
		rows_by_family: Dictionary, publication_view: Dictionary = {},
		publication_lease_token := "") -> Dictionary:
	if _support_index == null or world_id != _world_id:
		return _pending("ecology_support_query_world_stale")
	return _support_index.publish_source_domain_family_bundle(world_id,
		source_chunk_key, family_bundle, rows_by_family, publication_view,
		publication_lease_token)


## Publish only the selected legacy family domains while preserving the one
## complete source bundle/publication that also authorizes section tree overlays.
func publish_support_source_domain_family_projection(world_id: String,
		source_chunk_key: Vector2i, family_bundle: Dictionary,
		rows_by_family: Dictionary, publication_view: Dictionary,
		publication_lease_token: String, selected_families: Array[String]) -> Dictionary:
	if _support_index == null or world_id != _world_id:
		return _pending("ecology_support_query_world_stale")
	if not _support_index.has_method("publish_source_domain_family_projection"):
		return _pending("ecology_source_family_projection_api_unavailable", {
			"sourceChunkKey":source_chunk_key, "selectedFamilies":selected_families})
	return _support_index.call("publish_source_domain_family_projection",
		world_id, source_chunk_key, family_bundle, rows_by_family,
		publication_view, publication_lease_token, selected_families)


func capture_and_publish_support_source_domain(world_id: String,
		source_chunk_key: Vector2i, world_seed: String, source_inputs: Dictionary,
		removed_props_snapshot: Dictionary, rows: Array) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not main.has_method("capture_ecology_source_domain"):
		return _pending("ecology_nonresident_source_domain_capture_unavailable", {
			"sourceChunkKey":source_chunk_key})
	if not main.has_method("begin_ecology_source_catalog_context_scope") \
			or not main.has_method("end_ecology_source_catalog_context_scope"):
		return _pending("ecology_source_catalog_scope_protocol_unavailable")
	var scope: Dictionary = main.call("begin_ecology_source_catalog_context_scope")
	if String(scope.get("status", "")) != "ready": return scope
	var policy_inputs: Dictionary = main.call("ecology_source_support_policy_inputs",
		world_id, source_chunk_key, world_seed, source_inputs)
	if String(policy_inputs.get("status", "")) != "ready":
		main.call("end_ecology_source_catalog_context_scope", scope)
		return policy_inputs
	var canonical_inputs: Dictionary = policy_inputs.get("sourceInputs", {})
	if String(source_inputs.get("catalogArtifactId", "")) != String(
			canonical_inputs.get("catalogArtifactId", "")):
		main.call("end_ecology_source_catalog_context_scope", scope)
		return _pending("ecology_source_catalog_artifact_stale")
	var capture_value: Variant = main.call("capture_ecology_source_domain", world_id,
		source_chunk_key, world_seed, canonical_inputs, removed_props_snapshot,
		String(scope.get("leaseToken", "")))
	var ended: Dictionary = main.call("end_ecology_source_catalog_context_scope", scope)
	var capture_result: Dictionary = capture_value if capture_value is Dictionary else {}
	var publication_token := String(capture_result.get("sourcePublicationLeaseToken", ""))
	if String(ended.get("status", "")) != "ready":
		if not publication_token.is_empty() and main.has_method(
				"release_ecology_source_publication"):
			main.call("release_ecology_source_publication", publication_token)
		return ended
	if not capture_value is Dictionary:
		return _pending("ecology_nonresident_source_domain_pending", {
			"sourceChunkKey":source_chunk_key, "capture":capture_value})
	if capture_result.get("status", "") == "failed":
		return {"status":"failed",
			"reason":String(capture_result.get("reason", capture_result.get("failureReason",
				"ecology_nonresident_source_domain_failed"))),
			"sourceChunkKey":source_chunk_key,
			"unsupportedCategories":capture_result.get("unsupportedCategories", []),
			"capture":capture_result}
	if capture_result.get("status", "") != "ready":
		return _pending("ecology_nonresident_source_domain_pending", {
			"sourceChunkKey":source_chunk_key, "capture":capture_result})
	var snapshot_value: Variant = capture_result.get("snapshot", null)
	var publication_view_value: Variant = capture_result.get("sourcePublicationView", null)
	if not snapshot_value is Dictionary or not publication_view_value is Dictionary \
			or publication_token.is_empty():
		if not publication_token.is_empty() and main.has_method(
				"release_ecology_source_publication"):
			main.call("release_ecology_source_publication", publication_token)
		return _pending("ecology_source_publication_capture_incomplete", {
			"sourceChunkKey":source_chunk_key})
	var rows_by_family: Dictionary = {}
	for family_value: Variant in ProducerDomainScript.REQUIRED_CATEGORIES:
		rows_by_family[String(family_value)] = []
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			main.call("release_ecology_source_publication", publication_token)
			return _pending("ecology_support_source_row_invalid")
		var family := String(row_value.get("family", ""))
		if not rows_by_family.has(family):
			main.call("release_ecology_source_publication", publication_token)
			return _pending("ecology_support_source_family_invalid", {"family":family})
		(rows_by_family[family] as Array).append(row_value)
	var published := publish_support_source_domain_families(world_id,
		source_chunk_key, snapshot_value, rows_by_family,
		publication_view_value, publication_token)
	main.call("release_ecology_source_publication", publication_token)
	return published


## Project the tree compiler's per-role-instance manifest into support-index
## postings. The compiler has already checked each actual transformed primitive
## AABB against the recipe support envelope and bound its mesh digest.
func tree_support_rows_from_manifest(source_manifest: Dictionary) -> Dictionary:
	if _support_index == null or source_manifest.is_empty():
		return _pending("ecology_tree_support_manifest_unavailable")
	var source_id := String(source_manifest.get("sourceId", ""))
	var source_revision := String(source_manifest.get("sourceRevision", ""))
	var recipe_signature := String(source_manifest.get("recipeSignature", ""))
	var artifact_generation := int(source_manifest.get("artifactGeneration", 0))
	var family_revision := String(source_manifest.get("familyRevision", ""))
	var family_policy_revision := String(source_manifest.get("familyPolicyRevision", ""))
	var family_policy_digest := String(source_manifest.get("familyPolicyDigest", ""))
	var family_manifest_digest := String(source_manifest.get("familyManifestDigest", ""))
	var ownership: Variant = source_manifest.get("geometryOwnership", null)
	if String(source_manifest.get("family", "")) != "trees" \
			or source_id.is_empty() or source_revision.is_empty() or recipe_signature.is_empty() \
			or artifact_generation <= 0 or family_revision.length() != 64 \
			or family_policy_revision.is_empty() or family_policy_digest.length() != 64 \
			or family_manifest_digest.length() != 64 \
			or not ownership is Array or ownership.is_empty():
		return _pending("ecology_tree_support_manifest_incomplete", {
			"sourceId":source_id})
	var rows: Array[Dictionary] = []
	for value: Variant in ownership:
		if not value is Dictionary:
			return _pending("ecology_tree_support_member_manifest_invalid", {
				"sourceId":source_id})
		var member: Dictionary = value
		var member_id := String(member.get("memberId", ""))
		var bounds: Variant = member.get("conservativeWorldBounds", null)
		var owner: Variant = member.get("geometryOwnerSectionKey", null)
		var support: Variant = member.get("supportSectionKeys", null)
		var mesh_digest := String(member.get("meshContentDigest", ""))
		var proof_value: Variant = member.get("certifiedEnvelopeProof", null)
		if member_id.is_empty() or not bounds is AABB or not _valid_bounds(bounds) \
				or not owner is Vector3i or not support is Array or support.is_empty() \
				or mesh_digest.length() != 64 or not proof_value is Dictionary:
			return _pending("ecology_tree_support_member_uncertified", {
				"sourceId":source_id, "memberId":member_id})
		rows.append({"sourceId":source_id, "sourcePartId":member_id,
			"sourceRevision":source_revision,
			"producerSnapshotRevision":family_revision,
			"family":"trees", "familyRevision":family_revision,
			"familyPolicyRevision":family_policy_revision,
			"familyPolicyDigest":family_policy_digest,
			"familyManifestDigest":family_manifest_digest,
			"kind":"tree", "sourceOrigin":
				(source_manifest.get("bodyGlobalTransform", Transform3D.IDENTITY) as Transform3D).origin,
			"state":"compiled",
			"conservativeWorldBounds":bounds,
			"geometryOwnerSection":owner,
			"conservativeSupportSectionKeys":support.duplicate(),
			"recipeSignature":recipe_signature,
			"artifactGeneration":artifact_generation,
			"meshContentDigest":mesh_digest,
			"certifiedEnvelopeProof":proof_value.duplicate(true),
			"certifiedEnvelopeDigest":String(member.get("certifiedEnvelopeDigest", "")),
			"memberId":member_id,
			"instanceIndex":int(member.get("instanceIndex", -1)),
			"sourceSegmentId":"ecology-static:%s:%s" % [member_id, source_revision],
			"sourceOwnerChunk":source_manifest.get("sourceChunkKey",
				Grid.chunk_key_for_world_position((source_manifest.get("bodyGlobalTransform",
					Transform3D.IDENTITY) as Transform3D).origin)),
			"propId":String(source_manifest.get("propId", source_id))})
	return {"status":"ready", "sourceId":source_id,
		"sourceRevision":source_revision, "rows":rows}


func _bind_tree_compiler_manifest_to_source(manifest: Dictionary,
		producer_row: Dictionary, source_chunk: Vector2i, snapshot: Dictionary,
		tree_family_result: Dictionary) -> Dictionary:
	var compiled_body_value: Variant = manifest.get("bodyGlobalTransform", null)
	var producer_transform_value: Variant = producer_row.get("transform", null)
	var producer_origin_value: Variant = producer_row.get("sourceOrigin", null)
	var manifest_chunk_value: Variant = manifest.get("sourceChunkKey", null)
	var snapshot_chunk_value: Variant = snapshot.get("sourceChunkKey", null)
	if not compiled_body_value is Transform3D or not producer_transform_value is Transform3D \
			or not producer_origin_value is Vector3 or not manifest_chunk_value is Vector2i \
			or not snapshot_chunk_value is Vector2i \
			or manifest_chunk_value != source_chunk \
			or snapshot_chunk_value != source_chunk:
		return _pending("ecology_tree_compile_source_transform_values_missing", {
			"sourceId":String(producer_row.get("sourceId", "")),
			"sourceChunkKey":source_chunk})
	var compiled_body_transform: Transform3D = compiled_body_value
	var producer_transform: Transform3D = producer_transform_value
	var producer_source_origin: Vector3 = producer_origin_value
	if not compiled_body_transform.is_finite() or not producer_transform.is_finite() \
			or not producer_source_origin.is_finite():
		return _pending("ecology_tree_compile_source_transform_invalid", {
			"sourceId":String(producer_row.get("sourceId", "")),
			"sourceChunkKey":source_chunk})
	var chunk_origin := Vector3(float(source_chunk.x) * Grid.STREAM_CHUNK_SIZE_METERS,
		0.0, float(source_chunk.y) * Grid.STREAM_CHUNK_SIZE_METERS)
	var chunk_to_world := Transform3D(Basis.IDENTITY, chunk_origin)
	var expected_body_transform: Transform3D = chunk_to_world * producer_transform
	if not compiled_body_transform.is_equal_approx(expected_body_transform) \
			or not compiled_body_transform.origin.is_equal_approx(producer_source_origin):
		return _pending("ecology_tree_compile_body_transform_mismatch", {
			"sourceId":String(producer_row.get("sourceId", "")),
			"sourceChunkKey":source_chunk})
	var bound_manifest: Dictionary = manifest.duplicate(true)
	bound_manifest["propId"] = String(producer_row.get("propId", producer_row.get("sourceId", "")))
	bound_manifest["family"] = "trees"
	bound_manifest["familyRevision"] = String(tree_family_result.get("familyRevision", ""))
	bound_manifest["familyPolicyRevision"] = String(tree_family_result.get(
		"familyPolicyRevision", ""))
	bound_manifest["familyPolicyDigest"] = String(tree_family_result.get(
		"familyPolicyDigest", ""))
	bound_manifest["familyManifestDigest"] = String(tree_family_result.get(
		"sourceManifestDigest", ""))
	bound_manifest["sourceOrigin"] = producer_source_origin
	bound_manifest["sourceChunkKey"] = source_chunk
	# Keep the compiler's world-space transform after proving it matches the
	# chunk origin composed with the immutable producer-local placement.
	bound_manifest["sourceDomainRevision"] = String(snapshot.get("sourceDomainRevision", ""))
	bound_manifest["producerSnapshotRevision"] = String(tree_family_result.get(
		"familyRevision", ""))
	bound_manifest["terrainVolumeChunkRevision"] = String(snapshot.get(
		"terrainVolumeChunkRevision", ""))
	bound_manifest["structureAdmissionRevision"] = String(snapshot.get(
		"structureAdmissionRevision", ""))
	bound_manifest["removedSourceProjectionDigest"] = String(snapshot.get(
		"removedSourceProjectionDigest", ""))
	bound_manifest["influencePolicyRevision"] = String(snapshot.get(
		"influencePolicyRevision", ""))
	bound_manifest["influencePolicyDigest"] = String(snapshot.get(
		"influencePolicyDigest", ""))
	return {"status":"ready", "manifest":bound_manifest}


## Bind the game authority that owns the seeded chunk producer. Membership
## still comes from its finalized value snapshot, not a scene-tree scan.
func bind_main_authority(main: Object) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("detail_mesh") \
			or not main.has_method("detail_material") \
			or not main.has_method("_ecology_chunk_source_revision"):
		return _failed("ecology_main_authority_contract_missing")
	var previous: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not main.has_method("acquire_ecology_catalog_artifact_lease") \
			or not main.has_method("resolve_ecology_catalog_artifact") \
			or not main.has_method("release_ecology_catalog_artifact_lease") \
			or not main.has_method("admit_ecology_source_publication") \
			or not main.has_method("acquire_ecology_source_publication") \
			or not main.has_method("resolve_ecology_source_publication") \
			or not main.has_method("ecology_source_publication_is_current") \
			or not main.has_method("ecology_source_publication_local_is_current") \
			or not main.has_method("ecology_source_publication_record_is_current") \
			or not main.has_method("release_ecology_source_publication") \
			or not main.get("ecology_world_epoch") is int:
		return _failed("ecology_catalog_resolver_contract_missing")
	var world_epoch := int(main.get("ecology_world_epoch"))
	var had_previous_binding := _main_authority_ref != null
	var previous_binding_changed := had_previous_binding and (
		not is_instance_valid(previous) or previous.get_instance_id() != main.get_instance_id() \
		or int(previous.get("ecology_world_epoch")) != world_epoch)
	if previous_binding_changed:
		# Release jobs through their original Main/store while that resolver is
		# still bound when it is alive. The support index releases retained leases
		# when rebound; do not reset its queue while source-capture sessions still
		# hold catalog leases or private producer payloads.
		if is_instance_valid(previous):
			if not previous.has_method("reset_ecology_source_capture_sessions"):
				return _failed("ecology_previous_source_session_reset_missing")
			var session_reset_value: Variant = previous.call(
				"reset_ecology_source_capture_sessions")
			if not session_reset_value is Dictionary:
				return _failed("ecology_previous_source_session_reset_result_invalid")
			var session_reset: Dictionary = session_reset_value
			if String(session_reset.get("status", "")) != "ready":
				return session_reset
			var previous_tree_queue: Variant = previous.get("tree_publication_queue")
			if is_instance_valid(previous_tree_queue) and previous_tree_queue.has_method(
					"reset_ecology_source_compilers"):
				var queue_reset_value: Variant = previous_tree_queue.call(
					"reset_ecology_source_compilers")
				if not queue_reset_value is Dictionary:
					return _failed("ecology_previous_source_queue_reset_result_invalid")
				var queue_reset: Dictionary = queue_reset_value
				if String(queue_reset.get("status", "")) != "ready":
					return queue_reset
		var capture_reset: Dictionary = reset_source_domain_captures()
		if String(capture_reset.get("status", "")) not in ["reset", "ready"]:
			return capture_reset
	var resolver_result: Dictionary = _support_index.bind_catalog_artifact_resolver(
		main, world_epoch)
	if resolver_result.get("status") != "ready": return resolver_result
	_main_authority_ref = weakref(main)
	return {"status":"ready", "ownerInstanceId":main.get_instance_id(),
		"worldEpoch":world_epoch}


## Implements StaticSectionSourceRoster.capture_method exactly. Missing chunk
## owners, incomplete producer categories, or absent prepared geometry are
## pending; this provider never infers empty from an absent ledger entry.
func capture_static_section_sources(world_id: String,
		requested_sections: Array) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var metrics := _new_static_census_capture_metrics(requested_sections.size())
	var result := _capture_nonresident_static_section_sources(world_id,
		requested_sections, metrics)
	_finish_static_census_capture_phase(metrics)
	_record_static_census_profile(metrics, maxi(0, Time.get_ticks_usec() - started_usec))
	return result


func _new_static_census_capture_metrics(requested_section_count: int) -> Dictionary:
	var phase_usec := {}
	for phase: String in STATIC_CENSUS_PROFILE_PHASES:
		phase_usec[phase] = 0
	return {"phaseUsec":phase_usec, "counts":{
		"requestedSectionCount":requested_section_count,
		"sectionPolicyInputCount":0,
		"sourceChunkClosureCount":0,
		"sourceChunkLookupCount":0,
		"sourceFamilyChunkPairCount":0,
		"undergroundSourceChunkPairCount":0,
		"sourceFamilyChunkPairCountByFamily":{},
		"sourceCaptureRequestCount":0,
		"sourceCaptureReadyCount":0,
		"sourceCapturePendingCount":0,
		"sourceCaptureFailedCount":0,
		"producerSourceRowCount":0,
		"nonTreeConversionCount":0,
		"convertedMemberArtifactCount":0,
		"convertedSupportRowCount":0,
		"supportProjectionCount":0,
		"bandRegistrationCount":0,
		"treeBandAdmissionAttemptCount":0,
		"supportSectionQueryCount":0,
		"supportContributorCount":0,
		"censusSourceRevisionCount":0
	}, "activePhase":"", "activePhaseStartedUsec":0}


func _set_static_census_capture_phase(metrics: Dictionary, phase: String) -> void:
	_finish_static_census_capture_phase(metrics)
	if phase not in STATIC_CENSUS_PROFILE_PHASES:
		return
	metrics["activePhase"] = phase
	metrics["activePhaseStartedUsec"] = Time.get_ticks_usec()


func _finish_static_census_capture_phase(metrics: Dictionary) -> void:
	var phase := String(metrics.get("activePhase", ""))
	if phase not in STATIC_CENSUS_PROFILE_PHASES:
		return
	var phase_usec: Dictionary = metrics.get("phaseUsec", {})
	phase_usec[phase] = int(phase_usec.get(phase, 0)) + maxi(0,
		Time.get_ticks_usec() - int(metrics.get("activePhaseStartedUsec", 0)))
	metrics["phaseUsec"] = phase_usec
	metrics["activePhase"] = ""


func _add_static_census_capture_count(metrics: Dictionary, key: String,
		amount := 1) -> void:
	var counts: Dictionary = metrics.get("counts", {})
	counts[key] = int(counts.get(key, 0)) + amount
	metrics["counts"] = counts


func _record_static_census_profile(metrics: Dictionary, elapsed_usec: int) -> void:
	_static_census_profile_calls += 1
	_static_census_profile_last_usec = elapsed_usec
	var is_new_max_provider_call := elapsed_usec >= _static_census_profile_max_usec
	var phase_usec: Dictionary = metrics.get("phaseUsec", {})
	var last_phase_usec := {}
	for phase: String in STATIC_CENSUS_PROFILE_PHASES:
		var duration := int(phase_usec.get(phase, 0))
		last_phase_usec[phase] = duration
		_static_census_profile_max_phase_usec[phase] = maxi(
			int(_static_census_profile_max_phase_usec.get(phase, 0)), duration)
	_static_census_profile_last_phase_usec = last_phase_usec
	_static_census_profile_last_counts = (metrics.get("counts", {}) as Dictionary).duplicate(false)
	if is_new_max_provider_call:
		_static_census_profile_max_usec = elapsed_usec
		_static_census_profile_max_provider_phase_usec = last_phase_usec.duplicate(false)
		_static_census_profile_max_provider_counts = _static_census_profile_last_counts.duplicate(false)


func _reset_static_census_profile() -> void:
	_static_census_profile_calls = 0
	_static_census_profile_last_usec = 0
	_static_census_profile_max_usec = 0
	_static_census_profile_last_phase_usec.clear()
	_static_census_profile_max_phase_usec.clear()
	_static_census_profile_last_counts.clear()
	_static_census_profile_max_provider_phase_usec.clear()
	_static_census_profile_max_provider_counts.clear()
	for phase: String in STATIC_CENSUS_PROFILE_PHASES:
		_static_census_profile_last_phase_usec[phase] = 0
		_static_census_profile_max_phase_usec[phase] = 0


func _static_census_profile_snapshot() -> Dictionary:
	return {"schema":"ecology-static-census-profile/v1",
		"retention":"last_and_max_aggregate_only",
		"calls":_static_census_profile_calls,
		"lastProviderUsec":_static_census_profile_last_usec,
		"maxProviderUsec":_static_census_profile_max_usec,
		"lastPhaseUsec":_static_census_profile_last_phase_usec.duplicate(false),
		"maxPhaseUsec":_static_census_profile_max_phase_usec.duplicate(false),
		"lastCounts":_static_census_profile_last_counts.duplicate(false),
		"maxProviderPhaseUsec":_static_census_profile_max_provider_phase_usec.duplicate(false),
		"maxProviderCounts":_static_census_profile_max_provider_counts.duplicate(false)}


func _current_capture_camera_position(main: Object) -> Vector3:
	var player_value: Variant = main.get("player") if is_instance_valid(main) else null
	if not is_instance_valid(player_value) or not player_value is Node3D:
		return Vector3.ZERO
	var player := player_value as Node3D
	var camera_value: Variant = player.get("camera")
	return (camera_value as Node3D).global_position if is_instance_valid(camera_value) \
		and camera_value is Node3D else player.global_position


func _capture_cohort_camera_priority(section_key: Vector3i,
		camera_position: Vector3) -> float:
	var center := Grid.origin_for_key(section_key) \
		+ Vector3.ONE * (Grid.SECTION_SIZE_METERS * 0.5)
	return center.distance_squared_to(camera_position)


func _upsert_source_capture_cohort(section_key: Vector3i,
		priority: float) -> void:
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if cohort.is_empty():
		_source_capture_cohort_sequence += 1
		cohort = {"sectionKey":section_key,
			"cohortId":"%s|section:%d,%d,%d|%d" % [_world_id,
				section_key.x, section_key.y, section_key.z, _source_capture_cohort_sequence],
			"createdSequence":_source_capture_cohort_sequence,
			"createdOpportunity":_source_capture_service_opportunities,
			"priority":priority, "status":"deferred", "closureSealed":false,
			"waitOpportunities":0, "blockedUntilOpportunity":-1,
			"blockedReason":"", "completedSequence":-1}
	else:
		# Arrival age is immutable; recensus refreshes only current camera urgency.
		cohort["priority"] = priority
		# A failed cohort must be observable again on a later census. That lets
		# the producer return the retained failure for the same identity or admit
		# a changed authoritative input under its new identity. It does not clear
		# a failed source job or treat it as complete.
		if String(cohort.get("status", "")) == "failed":
			cohort["cachedFailureReason"] = String(cohort.get("blockedReason",
				"source_capture_terminal_failure"))
			cohort["status"] = "deferred"
	_source_capture_cohorts[section_key] = cohort


func _active_source_capture_cohort_count() -> int:
	return _source_capture_active_cohort_count


func _cached_source_capture_failure(section_keys: Array[Vector3i]) -> Dictionary:
	for section_key: Vector3i in section_keys:
		var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		var reason := String(cohort.get("cachedFailureReason", ""))
		if not reason.is_empty():
			var details: Dictionary = cohort.get("cachedFailureDetails", {}).duplicate(true)
			details.merge({"sectionKey":section_key,
				"cachedSourceCaptureFailure":true,
				"producerStatus":"failed",
				"cohortStatus":String(cohort.get("status", ""))}, true)
			return _pending(reason, details)
	return {}


func _retryable_source_capture_failure(failure: Dictionary,
		section_key: Vector3i) -> Dictionary:
	var reason := String(failure.get("reason", "source_capture_terminal_failure"))
	var details := failure.duplicate(true)
	details.erase("status")
	details.erase("retryable")
	details["sectionKey"] = section_key
	details["producerStatus"] = "failed"
	details["cachedSourceCaptureFailure"] = true
	return _pending(reason, details)


func _record_source_capture_service_opportunity() -> void:
	_source_capture_service_opportunities += 1
	for section_value: Variant in _source_capture_cohorts:
		var cohort: Dictionary = _source_capture_cohorts[section_value]
		if String(cohort.get("status", "")) == "deferred":
			cohort["waitOpportunities"] = int(cohort.get("waitOpportunities", 0)) + 1
	_promote_source_capture_cohorts()


func _set_source_capture_cohort_status(section_key: Vector3i,
		cohort: Dictionary, new_status: String) -> void:
	var was_active := String(cohort.get("status", "")) == "active"
	var is_active := new_status == "active"
	if was_active != is_active:
		_source_capture_active_cohort_count += 1 if is_active else -1
		_source_capture_active_cohort_count = maxi(0, _source_capture_active_cohort_count)
	cohort["status"] = new_status
	_source_capture_cohorts[section_key] = cohort


func _promote_source_capture_cohorts() -> void:
	while _active_source_capture_cohort_count() < MAX_ACTIVE_SOURCE_CAPTURE_COHORTS:
		var selected_key: Variant = null
		var selected: Dictionary = {}
		var selected_is_aged := false
		for section_value: Variant in _source_capture_cohorts:
			var cohort: Dictionary = _source_capture_cohorts[section_value]
			var status := String(cohort.get("status", ""))
			if status == "blocked" and int(cohort.get("blockedUntilOpportunity", -1)) \
					<= _source_capture_service_opportunities:
				_set_source_capture_cohort_status(Vector3i(section_value), cohort, "deferred")
				status = "deferred"
			if status != "deferred":
				continue
			var aged := int(cohort.get("waitOpportunities", 0)) \
				>= SOURCE_CAPTURE_FAIR_AGE_OPPORTUNITIES
			if selected_key == null:
				selected_key = section_value
				selected = cohort
				selected_is_aged = aged
				continue
			var candidate_priority := float(cohort.get("priority", INF))
			var selected_priority := float(selected.get("priority", INF))
			var earlier := int(cohort.get("createdSequence", 0)) \
				< int(selected.get("createdSequence", 0))
			if (aged and not selected_is_aged) or (aged == selected_is_aged \
					and ((aged and earlier) or (not aged and candidate_priority < selected_priority) \
					or (not aged and is_equal_approx(candidate_priority, selected_priority) \
					and earlier))):
				selected_key = section_value
				selected = cohort
				selected_is_aged = aged
		if selected_key == null:
			return
		_set_source_capture_cohort_status(Vector3i(selected_key), selected, "active")
		selected["admittedSequence"] = _source_capture_service_opportunities
		selected["blockedReason"] = ""
		selected["cachedFailureReason"] = ""
		selected["cachedFailureDetails"] = {}
		_source_capture_cohorts[selected_key] = selected
		_source_capture_cohort_admissions += 1
		for identity_value: Variant in _source_capture_jobs_by_section.get(selected_key, {}).keys():
			_enqueue_source_capture_job(String(identity_value))


func _section_has_active_capture_cohort(section_key: Vector3i) -> bool:
	return String(_source_capture_cohorts.get(section_key, {}).get("status", "")) == "active"


func _job_has_active_capture_cohort_subscriber(job: Dictionary) -> bool:
	for section_value: Variant in job.get("sections", {}).keys():
		if section_value is Vector3i and _section_has_active_capture_cohort(section_value):
			return true
	return false


func _seal_source_capture_cohort_closures(section_keys: Array[Vector3i]) -> void:
	for section_key: Vector3i in section_keys:
		var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		if cohort.is_empty():
			continue
		cohort["closureSealed"] = true
		var closure_identities: Dictionary = _source_capture_jobs_by_section.get(
			section_key, {})
		cohort["closureDisposition"] = "complete_empty" \
			if closure_identities.is_empty() else "complete_nonempty"
		_source_capture_cohorts[section_key] = cohort
		_reconcile_source_capture_cohort(section_key)


func _reconcile_source_capture_cohort(section_key: Vector3i) -> void:
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if cohort.is_empty() or not bool(cohort.get("closureSealed", false)):
		return
	var identities: Dictionary = _source_capture_jobs_by_section.get(section_key, {})
	if identities.is_empty():
		# The caller seals this only after the authoritative support certificate
		# and complete inverse source set have been admitted. Empty closure is a
		# terminal result, rather than a missing capture job that occupies a slot.
		if String(cohort.get("closureDisposition", "")) == "complete_empty":
			if String(cohort.get("status", "")) != "complete":
				_source_capture_cohort_completions += 1
			_set_source_capture_cohort_status(section_key, cohort, "complete")
			cohort["completedSequence"] = _source_capture_service_opportunities
			cohort["blockedReason"] = ""
			_source_capture_cohorts[section_key] = cohort
		return
	var ready_count := 0
	var failed_count := 0
	for identity_value: Variant in identities:
		var job: Dictionary = _source_capture_jobs.get(String(identity_value), {})
		match String(job.get("status", "")):
			"ready": ready_count += 1
			"failed": failed_count += 1
			_: pass
	if failed_count > 0:
		_set_source_capture_cohort_status(section_key, cohort, "failed")
		var failure_reason := "source_capture_terminal_failure"
		for identity_value: Variant in identities:
			var failed_job: Dictionary = _source_capture_jobs.get(String(identity_value), {})
			if String(failed_job.get("status", "")) != "failed":
				continue
			var failure: Dictionary = failed_job.get("failure", {})
			failure_reason = String(failure.get("reason", failure_reason))
			cohort["cachedFailureDetails"] = failure.duplicate(true)
			break
		cohort["blockedReason"] = failure_reason
		cohort["cachedFailureReason"] = failure_reason
		_source_capture_cohorts[section_key] = cohort
	elif ready_count == identities.size():
		if String(cohort.get("status", "")) != "complete":
			_source_capture_cohort_completions += 1
		_set_source_capture_cohort_status(section_key, cohort, "complete")
		cohort["completedSequence"] = _source_capture_service_opportunities
		_source_capture_cohorts[section_key] = cohort


func _yield_source_capture_cohort(section_key: Vector3i, reason: String) -> void:
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if cohort.is_empty() or String(cohort.get("status", "")) != "active":
		return
	_set_source_capture_cohort_status(section_key, cohort, "blocked")
	cohort["blockedUntilOpportunity"] = _source_capture_service_opportunities \
		+ SOURCE_CAPTURE_BLOCKED_RETRY_OPPORTUNITIES
	cohort["blockedReason"] = reason
	_source_capture_cohort_yields += 1
	# Main owns mutable continuation buffers. Release those on a dependency yield,
	# retaining the exact immutable job identity and lease for retry.
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if is_instance_valid(main):
		for identity_value: Variant in _source_capture_jobs_by_section.get(section_key, {}).keys():
			var job: Dictionary = _source_capture_jobs.get(String(identity_value), {})
			var cache_identity := String(job.get("captureCacheIdentity", ""))
			if String(job.get("status", "")) == "pending" \
					and not _job_has_active_capture_cohort_subscriber(job) \
					and not cache_identity.is_empty() and main.has_method(
					"cancel_ecology_source_domain_capture"):
				main.call("cancel_ecology_source_domain_capture", cache_identity,
					String(job.get("catalogLeaseToken", "")))


func source_capture_scheduler_snapshot() -> Dictionary:
	var active_rows: Array[Dictionary] = []
	var deferred_rows: Array[Dictionary] = []
	var blocked_rows: Array[Dictionary] = []
	var preparation_rows: Array[Dictionary] = []
	var completed_count := 0
	var failed_count := 0
	var active_job_count := 0
	var deferred_job_count := 0
	var completed_job_count := 0
	for section_value: Variant in _source_capture_cohorts:
		var cohort: Dictionary = _source_capture_cohorts[section_value]
		var preparation_value: Variant = cohort.get("sectionPreparation", null)
		var preparation: Dictionary = preparation_value if preparation_value is Dictionary else {}
		var active_family_value: Variant = preparation.get("activeFamily", null)
		var active_family: Dictionary = active_family_value \
			if active_family_value is Dictionary else {}
		var plans_value: Variant = preparation.get("sourcePlans", [])
		var plans: Array = plans_value if plans_value is Array else []
		var source_cursor := int(preparation.get("sourceChunkCursor", 0))
		var current_plan: Dictionary = plans[source_cursor] \
			if source_cursor >= 0 and source_cursor < plans.size() \
			and plans[source_cursor] is Dictionary else {}
		var families_value: Variant = current_plan.get("requestedFamilies", [])
		var current_families: Array = families_value \
			if families_value is Array else []
		var family_cursor := int(preparation.get("familyCursor", 0))
		var row := {"sectionKey":section_value,
			"cohortId":String(cohort.get("cohortId", "")),
			"status":String(cohort.get("status", "")),
			"ageOpportunities":maxi(0, _source_capture_service_opportunities \
				- int(cohort.get("createdOpportunity", 0))),
			"waitOpportunities":int(cohort.get("waitOpportunities", 0)),
			"priority":float(cohort.get("priority", INF)),
			"blockedReason":String(cohort.get("blockedReason", "")),
			"closureSealed":bool(cohort.get("closureSealed", false)),
			"closureDisposition":String(cohort.get("closureDisposition", "missing")),
			"preparationKey":String(cohort.get("preparationKey", "")),
			"preparationStatus":String(preparation.get("status", "missing")),
			"preparationStage":String(preparation.get("stage", "")),
			"preparationFamilyCursor":int(preparation.get("familyCursor", 0)),
			"preparationSourceChunkCursor":int(preparation.get("sourceChunkCursor", 0)),
			"preparationSourceChunkCount":(preparation.get("sourcePlans", []) as Array).size(),
			"preparationActiveFamily":String(active_family.get("family", "")),
			"preparationSourceRecordCursor":int(active_family.get("sourceCursor", 0)),
			"preparationSourceRecordCount":(active_family.get("sourceRows", []) as Array).size(),
			"preparationCurrentSourceChunkKey":current_plan.get("sourceChunkKey", Vector2i.ZERO),
			"preparationCurrentCaptureIdentity":String(current_plan.get("captureIdentity", "")),
			"preparationCurrentFamily":String(current_families[family_cursor]) \
				if family_cursor >= 0 and family_cursor < current_families.size() else "",
			"preparationUnitCount":int(preparation.get("unitCount", 0)),
			"preparationPendingReason":String(preparation.get("pendingReason", "")),
			"sourceJobCount":(_source_capture_jobs_by_section.get(section_value, {}) as Dictionary).size()}
		if not preparation.is_empty() and String(preparation.get("status", "")) == "pending":
			preparation_rows.append(row.duplicate(false))
		match String(cohort.get("status", "")):
			"active": active_rows.append({
				"sectionKey":section_value,
				"status":String(cohort.get("status", "")),
				"preparationKey":String(cohort.get("preparationKey", "")),
				"preparationStatus":String(preparation.get("status", "missing")),
				"preparationStage":String(preparation.get("stage", "")),
				"preparationFamilyCursor":int(preparation.get("familyCursor", 0)),
				"preparationSourceChunkCursor":int(preparation.get("sourceChunkCursor", 0)),
				"preparationSourceChunkCount":plans.size(),
				"preparationCurrentSourceChunkKey":current_plan.get(
					"sourceChunkKey", Vector2i.ZERO),
				"preparationCurrentCaptureIdentity":String(current_plan.get(
					"captureIdentity", "")),
				"preparationCurrentFamily":String(current_families[family_cursor]) \
					if family_cursor >= 0 and family_cursor < current_families.size() else "",
				"preparationUnitCount":int(preparation.get("unitCount", 0)),
				"preparationPendingReason":String(preparation.get("pendingReason", ""))})
			"deferred": deferred_rows.append(row)
			"blocked": blocked_rows.append(row)
			"complete": completed_count += 1
			"failed": failed_count += 1
	for job_value: Variant in _source_capture_jobs.values():
		if not job_value is Dictionary:
			continue
		var job: Dictionary = job_value
		var status := String(job.get("status", ""))
		if status == "ready":
			completed_job_count += 1
		elif status == "pending":
			if _job_has_active_capture_cohort_subscriber(job):
				active_job_count += 1
			else:
				deferred_job_count += 1
	active_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("preparationKey", a.get("sectionKey", ""))) \
			< String(b.get("preparationKey", b.get("sectionKey", ""))))
	deferred_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.get("waitOpportunities", 0)) != int(b.get("waitOpportunities", 0)):
			return int(a.get("waitOpportunities", 0)) > int(b.get("waitOpportunities", 0))
		return float(a.get("priority", INF)) < float(b.get("priority", INF)))
	blocked_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("priority", INF)) < float(b.get("priority", INF)))
	preparation_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("priority", INF)) < float(b.get("priority", INF)))
	return {"schema":"ecology-section-capture-scheduler/v1",
		"activeCohortCount":active_rows.size(),
		"deferredCohortCount":deferred_rows.size(),
		"blockedCohortCount":blocked_rows.size(),
		"completedCohortCount":completed_count,
		"failedCohortCount":failed_count,
		"pendingSourceJobCount":_source_capture_pending_count(),
		"queuedSourceJobCount":_source_capture_queue.size(),
		"activeSourceJobCount":active_job_count,
		"deferredSourceJobCount":deferred_job_count,
		"completedSourceJobCount":completed_job_count,
		"admittedWorkCount":_source_capture_cohort_admissions,
		"cohortCompletionCount":_source_capture_cohort_completions,
		"cohortYieldCount":_source_capture_cohort_yields,
		"sectionPreparationCount":_source_section_preparations.size(),
		"sectionPreparationActiveCount":preparation_rows.size(),
		"sectionPreparationQueuedCount":_source_section_preparation_order.size(),
		"sectionPreparationUnits":_source_section_preparation_units,
		"sectionPreparationCacheHitRows":_source_section_preparation_cache_hit_rows,
		"sectionPreparationCompletions":_source_section_preparation_completions,
		"sectionPreparationStaleCount":_source_section_preparation_stale_count,
		"serviceOpportunities":_source_capture_service_opportunities,
		"oldestDeferredWaitOpportunities":int(deferred_rows[0].get("waitOpportunities", 0)) \
			if not deferred_rows.is_empty() else 0,
		"staticCensusProfile":_static_census_profile_snapshot(),
		"active":active_rows.slice(0, MAX_ACTIVE_SOURCE_CAPTURE_COHORTS),
		"preparing":preparation_rows.slice(0, MAX_ACTIVE_SOURCE_CAPTURE_COHORTS),
		"deferred":deferred_rows.slice(0, 8), "blocked":blocked_rows.slice(0, 8)}


## Register one shared deterministic source-domain job. Section census calls
## only subscribe; producer work is advanced independently by Main's loading
## and gameplay publication lanes.
func request_source_domain_capture(world_id: String, source_chunk: Vector2i,
		world_seed: String, source_inputs: Dictionary, removed_snapshot: Dictionary,
		removed_projection: Dictionary, section_key: Vector3i, priority: float,
		requested_families: Array = []) -> Dictionary:
	if world_id != _world_id or world_seed.is_empty() or not is_finite(priority):
		return _failed("invalid_ecology_source_capture_request")
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not main.has_method("acquire_ecology_catalog_artifact_lease") \
			or not main.has_method("resolve_ecology_catalog_artifact"):
		return _pending("ecology_catalog_resolver_unavailable")
	var artifact_id := String(source_inputs.get("catalogArtifactId", ""))
	var catalog_digest := String(source_inputs.get("catalogContentDigest", ""))
	var world_epoch := int(source_inputs.get("worldEpoch", -1))
	if String(source_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or artifact_id.is_empty() or catalog_digest.length() != 64 \
			or world_epoch != int(main.get("ecology_world_epoch")):
		return _pending("ecology_source_catalog_identity_missing")
	var source_input_identity := ProducerDomainScript.digest_value(source_inputs)
	var removed_identity := String(removed_projection.get("digest", ""))
	var canonical_families: Array[String] = []
	var input_families: Array = requested_families
	if input_families.is_empty():
		input_families = ProducerDomainScript.REQUIRED_CATEGORIES
	for family_value: Variant in input_families:
		var family := String(family_value)
		if family not in ProducerDomainScript.REQUIRED_CATEGORIES \
				or family in canonical_families:
			return _failed("ecology_source_capture_family_request_invalid", {
				"family":family})
		canonical_families.append(family)
	canonical_families.sort()
	var lease_owner_identity := ProducerDomainScript.digest_value({
		"schema":"ecology-source-capture-lease/v1", "worldId":world_id,
		"worldSeed":world_seed, "sourceChunkKey":source_chunk,
		"sourceInputsDigest":source_input_identity,
		"removedSourceProjectionDigest":removed_identity,
		"requestedFamilies":canonical_families})
	var lease_result: Dictionary = main.call("acquire_ecology_catalog_artifact_lease",
		artifact_id, "source_capture_job", lease_owner_identity, world_id, world_epoch)
	if String(lease_result.get("status", "")) != "ready": return lease_result
	var catalog_lease_token := String(lease_result.get("leaseToken", ""))
	var lease_reused := bool(lease_result.get("reused", false))
	var resolved: Dictionary = main.call("resolve_ecology_catalog_artifact",
		catalog_lease_token, world_id, world_epoch)
	var artifact_value: Variant = resolved.get("artifact", null)
	if String(resolved.get("status", "")) != "ready" or not artifact_value is Dictionary \
			or String(artifact_value.get("artifactId", "")) != artifact_id \
			or String(artifact_value.get("catalogContentDigest", "")) != catalog_digest:
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending("ecology_source_catalog_artifact_stale")
	var catalog_artifact: Dictionary = artifact_value
	var policy := ProducerDomainScript.support_policy(source_inputs, catalog_artifact)
	if not ProducerDomainScript.validate_support_policy_certificate(policy):
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending(String(policy.get("runtimePolicyReason",
			"ecology_source_capture_policy_pending")))
	for family: String in canonical_families:
		var family_policy := ProducerDomainScript.family_support_policy(
			source_inputs, catalog_artifact, family)
		if String(family_policy.get("status", "")) != "ready":
			if not lease_reused:
				main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
			return _pending(String(family_policy.get("reason",
				"ecology_requested_family_policy_pending")), {"family":family})
	var removed_ids: Variant = removed_projection.get("removedIds", null)
	if not bool(removed_snapshot.get("ok", false)) \
			or String(removed_projection.get("status", "")) != "ready" \
			or not removed_ids is Array or removed_identity.length() != 64:
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _pending("ecology_source_capture_removal_projection_pending")
	var family_request := ProducerDomainScript.build_source_family_request(
		canonical_families, world_id, world_seed, source_chunk, source_inputs,
		removed_identity, catalog_artifact, catalog_lease_token)
	if String(family_request.get("status", "")) != "ready":
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return family_request
	var family_request_digest := String(family_request.get("requestDigest", ""))
	if family_request_digest.length() != 64:
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _failed("ecology_source_capture_family_request_digest_invalid")
	var job_identity := ProducerDomainScript.digest_value({
		"schema":"ecology-source-capture-job/v3", "worldId":world_id,
		"worldSeed":world_seed, "sourceChunkKey":source_chunk,
		"sourceInputsDigest":source_input_identity,
		"removedSourceProjectionDigest":removed_identity,
		"familyRequestDigest":family_request_digest})
	# Subscription identity names the scope that can supersede another demand.
	# Keep versioned source/catalog/removal inputs in job_identity above, but do not
	# include them here: a changed source revision must find and retire the prior
	# continuation for the same family selection. Narrow and wide family requests
	# remain independent subscriptions.
	var family_selection_key := ",".join(PackedStringArray(canonical_families))
	var latest_identity_key := "%s|%d,%d|families:%s" % [world_id,
		source_chunk.x, source_chunk.y, family_selection_key]
	var cohort_priority := _capture_cohort_camera_priority(section_key,
		_current_capture_camera_position(main))
	var cohort_was_known := _source_capture_cohorts.has(section_key)
	_upsert_source_capture_cohort(section_key, cohort_priority)
	var prior_identity := String(_source_capture_latest_by_chunk.get(latest_identity_key, ""))
	if not prior_identity.is_empty() and prior_identity != job_identity:
		var prior: Dictionary = _source_capture_jobs.get(prior_identity, {})
		if not prior.is_empty():
			prior["status"] = "superseded"
			_wake_source_capture_subscribers(prior,
				"ecology_source_capture_superseded", prior_identity + "|superseded")
			# This snapshot can no longer satisfy the current source identity. Wake
			# its dependents, then release the complete obsolete payload immediately.
			_discard_source_capture_job(prior_identity)
	var frozen_inputs: Variant = ProducerDomainScript.freeze_value(source_inputs)
	var frozen_removed: Variant = ProducerDomainScript.freeze_value(removed_snapshot)
	if not frozen_inputs is Dictionary or not frozen_inputs.is_read_only() \
			or not frozen_removed is Dictionary or not frozen_removed.is_read_only():
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		return _failed("ecology_source_capture_request_freeze_failed")
	var job: Dictionary = _source_capture_jobs.get(job_identity, {})
	# A reversible edit may return to a previously superseded content identity.
	# Readmit it through the authority so its lease and capture become current.
	if job.is_empty() or String(job.get("status", "")) == "superseded":
		job = {"identity":job_identity, "worldId":world_id,
			"worldSeed":world_seed, "sourceChunkKey":source_chunk,
			"sourceInputs":frozen_inputs, "removedPropsSnapshot":frozen_removed,
			"familyRequest":family_request,
			"requestedFamilies":canonical_families.duplicate(),
			"familyRequestDigest":family_request_digest,
			"latestIdentityKey":latest_identity_key,
			"catalogArtifactId":artifact_id, "catalogContentDigest":catalog_digest,
			"worldEpoch":world_epoch, "catalogLeaseToken":catalog_lease_token,
			"catalogLeaseReleased":false,
			"captureCacheIdentity":ProducerDomainScript.snapshot_cache_identity(
				world_id, source_chunk, source_inputs, removed_identity, catalog_artifact),
			"status":"pending", "attempts":0, "priority":priority,
			"sections":{}}
		_source_capture_jobs[job_identity] = job
	else:
		# The deterministic lease owner is the job identity; retain the store's
		# original token for the existing job and release this duplicate result.
		if not lease_reused:
			main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		catalog_lease_token = String(job.get("catalogLeaseToken", ""))
	_source_capture_latest_by_chunk[latest_identity_key] = job_identity
	job = _source_capture_jobs.get(job_identity, job)
	var subscribers: Dictionary = job.get("sections", {})
	var was_subscribed := subscribers.has(section_key)
	subscribers[section_key] = true
	job["sections"] = subscribers
	job["priority"] = minf(float(job.get("priority", priority)), priority)
	job["lastDispatchSequence"] = int(job.get("lastDispatchSequence",
		_source_capture_dispatch_sequence))
	_source_capture_jobs[job_identity] = job
	if not was_subscribed:
		var section_jobs: Dictionary = _source_capture_jobs_by_section.get(section_key, {})
		section_jobs[job_identity] = true
		_source_capture_jobs_by_section[section_key] = section_jobs
		var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		var cohort_status := String(cohort.get("status", ""))
		cohort["closureSealed"] = false
		if cohort_status in ["complete", "failed"]:
			_set_source_capture_cohort_status(section_key, cohort, "deferred")
			cohort["completedSequence"] = -1
		_source_capture_cohorts[section_key] = cohort
		if not cohort_was_known or cohort_status in ["complete", "failed"]:
			_promote_source_capture_cohorts()
	_source_capture_idle_ready_order.erase(job_identity)
	if String(job.get("status", "")) == "pending":
		_enqueue_source_capture_job(job_identity)
	if String(job.get("status", "")) == "ready":
		return {"status":"ready", "identity":job_identity,
			"snapshot":job.get("snapshot", {}),
			"sourcePublicationId":String(job.get("sourcePublicationId", "")),
			"sourcePublicationLeaseToken":String(job.get("sourcePublicationLeaseToken", "")),
			"sourcePublicationView":job.get("sourcePublicationView", {})}
	if String(job.get("status", "")) == "failed":
		return job.get("failure", _failed("ecology_source_capture_job_failed"))
	return {"status":"pending", "reason":"ecology_source_capture_queued",
		"identity":job_identity, "sourceChunkKey":source_chunk,
		"attempts":int(job.get("attempts", 0)),
		"subscriberCount":subscribers.size(),
		"captureProgress":job.get("captureProgress", {})}


## Advance distinct source jobs fairly. The caller selects a larger count while
## the loading screen is active and a smaller count during ordinary gameplay.
func advance_source_domain_captures(max_jobs := 1,
		camera_position: Vector3 = Vector3.ZERO) -> Dictionary:
	if not Thread.is_main_thread(): return _failed("ecology_source_capture_requires_main_thread")
	if max_jobs < 1 or max_jobs > 8: return _failed("invalid_ecology_source_capture_budget")
	if not camera_position.is_finite(): return _failed("invalid_ecology_source_capture_camera")
	_record_source_capture_service_opportunity()
	if _source_capture_queue.is_empty() and _source_section_preparation_order.is_empty():
		return {"status":"idle", "advancedCount":0,
			"pendingJobCount":_source_capture_pending_count(), "results":[]}
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	# Source capture is independent from tree section compilation. The latter is
	# admitted only after the exact section-band authority and projection exist.
	var scope: Dictionary = {}
	if not is_instance_valid(main) or not main.has_method("begin_ecology_source_catalog_context_scope") \
			or not main.has_method("end_ecology_source_catalog_context_scope"):
		return _pending("ecology_source_catalog_scope_protocol_unavailable")
	scope = main.call("begin_ecology_source_catalog_context_scope")
	if scope.get("status") != "ready": return scope
	var result := _advance_source_domain_captures_in_scope(max_jobs, camera_position)
	if not scope.is_empty():
		var ended: Dictionary = main.call("end_ecology_source_catalog_context_scope", scope)
		if ended.get("status") != "ready": return ended
	return result


func _advance_source_domain_captures_in_scope(max_jobs: int,
		camera_position: Vector3) -> Dictionary:
	if max_jobs < 1 or max_jobs > 8:
		return _failed("invalid_ecology_source_capture_budget")
	if not camera_position.is_finite():
		return _failed("invalid_ecology_source_capture_camera")
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not main.has_method("capture_ecology_source_domain"):
		return _pending("ecology_source_capture_authority_unavailable")
	if not Thread.is_main_thread():
		return _failed("ecology_source_capture_requires_main_thread")
	var advanced: Array[Dictionary] = []
	var retry_jobs: Array[String] = []
	var capture_budget := max_jobs
	if not _source_section_preparation_order.is_empty():
		capture_budget = maxi(0, max_jobs - 1)
		if max_jobs == 1 and _source_capture_service_opportunities % 2 == 1:
			capture_budget = 1
	while advanced.size() < capture_budget:
		var identity := _take_next_source_capture_job(camera_position)
		if identity.is_empty():
			break
		var job: Dictionary = _source_capture_jobs.get(identity, {})
		if job.is_empty() or String(job.get("status", "")) != "pending":
			continue
		var capture_result_value: Variant = main.call("capture_ecology_source_domain",
			String(job.worldId), Vector2i(job.sourceChunkKey), String(job.worldSeed),
			job.sourceInputs, job.removedPropsSnapshot,
			String(job.get("catalogLeaseToken", "")), job.get("familyRequest", {}))
		job["attempts"] = int(job.get("attempts", 0)) + 1
		var capture_result: Dictionary = capture_result_value \
			if capture_result_value is Dictionary else {}
		if bool(capture_result.get("requiresRecapture", false)):
			# A completed capture for an obsolete region is unusable, but retained
			# demand still needs the current region. Never retry its frozen inputs.
			var current_revision := String(capture_result.get("currentRevision", ""))
			_wake_source_capture_subscribers(job, "ecology_source_capture_superseded",
				identity + "|recapture|" + current_revision.sha256_text())
			_discard_source_capture_job(identity)
			advanced.append({"identity":identity, "status":"pending",
				"reason":String(capture_result.get("reason", "ecology_source_capture_stale")),
				"requiresRecapture":true, "sourceChunkKey":job.sourceChunkKey,
				"capturedRevision":String(capture_result.get("capturedRevision", "")),
				"currentRevision":current_revision})
			continue
		if String(capture_result.get("status", "")) == "pending":
			var progress: Variant = capture_result.get("captureProgress", {})
			var reason := String(capture_result.get("reason", "ecology_source_capture_pending"))
			var progress_summary: Dictionary = {}
			if progress is Dictionary:
				for progress_key: String in ["phase", "surfaceAttempt", "detailAttempt",
						"detailAttempts", "detailAttemptPhase", "detailBatchIndex",
						"detailBatchCount", "detailSourceRowCount", "undergroundColumn",
						"undergroundScanY", "undergroundScanComplete",
						"undergroundCellsScanned", "undergroundScanRestarts",
						"undergroundCandidateCount", "undergroundAttempt", "sourceCount",
						"sourceCaptureBlockedReason", "sourceCaptureBlockedFamily",
						"sourceCaptureBlockedCategory", "sourceCaptureBlockedProducer",
						"sourceFamilyScoped", "requestedSourceFamilies", "completedCategories"]:
					if progress.has(progress_key):
						progress_summary[progress_key] = progress[progress_key]
			var progress_fingerprint := ProducerDomainScript.digest_value([reason, progress])
			var prior_fingerprint := String(job.get("lastProgressFingerprint", ""))
			# The public progress summary omits some private pass cursors. Repeated
			# summaries are telemetry only; they never justify cancelling useful work.
			var stalled_attempts := int(job.get("stalledAttempts", 0)) + 1 \
				if not prior_fingerprint.is_empty() and prior_fingerprint == progress_fingerprint else 0
			job["captureProgress"] = progress
			job["lastReason"] = reason
			job["lastProgressFingerprint"] = progress_fingerprint
			job["stalledAttempts"] = stalled_attempts
			_source_capture_jobs[identity] = job
			if String(capture_result.get("captureDisposition", "progress")) == "dependency_blocked":
				for section_value: Variant in job.get("sections", {}).keys():
					if section_value is Vector3i:
						_yield_source_capture_cohort(section_value, reason)
			else:
				retry_jobs.append(identity)
			advanced.append({"identity":identity, "status":"pending",
				"reason":reason, "attempts":int(job.attempts),
				"captureDisposition":String(capture_result.get("captureDisposition", "progress")),
				"stalledAttempts":stalled_attempts,
				"sourceChunkKey":job.get("sourceChunkKey", Vector2i.ZERO),
				"captureProgress":progress_summary})
			continue
		var publication_payload_value: Variant = capture_result.get("snapshot", null)
		var publication_view_value: Variant = capture_result.get("sourcePublicationView", null)
		var publication_token := String(capture_result.get("sourcePublicationLeaseToken", ""))
		var publication_id := String(capture_result.get("sourcePublicationId", ""))
		var publication_admission_valid := publication_payload_value is Dictionary \
				and publication_view_value is Dictionary \
				and not publication_token.is_empty() and not publication_id.is_empty() \
				and String(capture_result.get("status", "")) == "ready"
		var publication_view: Dictionary = publication_view_value \
			if publication_view_value is Dictionary else {}
		var admitted_snapshot: Dictionary = publication_payload_value \
			if publication_payload_value is Dictionary else {}
		if publication_admission_valid:
			var resolved_publication: Variant = main.call(
				"resolve_ecology_source_publication", publication_token,
				String(job.worldId), int(job.get("worldEpoch", -1))) \
				if main.has_method("resolve_ecology_source_publication") else null
			publication_admission_valid = resolved_publication is Dictionary \
				and String(resolved_publication.get("status", "")) == "ready" \
				and String(resolved_publication.get("publicationId", "")) == publication_id \
				and is_same(resolved_publication.get("view", {}), publication_view) \
				and String(publication_view.get("schema", "")) \
					== "ecology-source-publication-view/v1" \
				and is_same(publication_view.get("payload", {}), admitted_snapshot) \
				and String(publication_view.get("sourceDomainRevision", "")) \
					== String(admitted_snapshot.get("sourceRevision", ""))
		var local_current: Dictionary = {}
		if publication_admission_valid:
			var local_current_value: Variant = main.call(
				"ecology_source_publication_local_is_current",
				publication_view, publication_token) \
				if main.has_method("ecology_source_publication_local_is_current") else null
			local_current = local_current_value if local_current_value is Dictionary else {}
			if String(local_current.get("status", "")) == "pending":
				job["status"] = "pending"
				job["lastReason"] = String(local_current.get("reason",
					"ecology_source_publication_local_currentness_pending"))
				_source_capture_jobs[identity] = job
				if not publication_token.is_empty():
					main.call("release_ecology_source_publication", publication_token)
				retry_jobs.append(identity)
				advanced.append({"identity":identity, "status":"pending",
					"reason":String(job.get("lastReason", "")),
					"currentness":local_current})
				continue
			publication_admission_valid = String(local_current.get("status", "")) == "ready"
		if not publication_admission_valid:
			job["status"] = "failed"
			var snapshot_failure_reason := String(capture_result.get("reason", ""))
			if snapshot_failure_reason.is_empty():
				snapshot_failure_reason = String(capture_result.get("failureReason", ""))
			if snapshot_failure_reason.is_empty():
				snapshot_failure_reason = "ecology_source_publication_admission_invalid"
			if not publication_token.is_empty() and main.has_method(
					"release_ecology_source_publication"):
				main.call("release_ecology_source_publication", publication_token)
			job["failure"] = _failed(snapshot_failure_reason, {
				"sourceChunkKey":job.sourceChunkKey,
				"unsupportedCategories":capture_result.get("unsupportedCategories", []),
				"failureDetails":capture_result.get("failureDetails", {})})
			_source_capture_jobs[identity] = job
			for section_value: Variant in job.get("sections", {}).keys():
				if section_value is Vector3i:
					_reconcile_source_capture_cohort(section_value)
			_wake_source_capture_subscribers(job,
				"ecology_source_capture_failed", identity + "|failed")
			_retire_source_capture_if_unsubscribed(identity)
			advanced.append({"identity":identity, "status":"failed"})
			continue
		job["status"] = "ready"
		job["snapshot"] = admitted_snapshot
		job["sourcePublicationId"] = publication_id
		job["sourcePublicationLeaseToken"] = publication_token
		job["sourcePublicationView"] = publication_view
		job["captureProgress"] = capture_result.get("captureProgress", {})
		job["stalledAttempts"] = 0
		job["lastProgressFingerprint"] = ""
		_source_capture_jobs[identity] = job
		for section_value: Variant in job.get("sections", {}).keys():
			if section_value is Vector3i:
				_reconcile_source_capture_cohort(section_value)
		_wake_source_capture_subscribers(job,
			"ecology_source_domain_snapshot_ready", identity + "|ready")
		_retire_source_capture_if_unsubscribed(identity)
		advanced.append({"identity":identity, "status":"ready",
			"sourceChunkKey":job.sourceChunkKey,
			"sourcePublicationId":publication_id,
			"subscriberCount":job.get("sections", {}).size()})
	for retry_identity: String in retry_jobs:
		_enqueue_source_capture_job(retry_identity)
	var preparation_results: Array[Dictionary] = []
	var preparation_attempts := _source_section_preparation_order.size()
	var preparation_failure: Dictionary = {}
	while advanced.size() + preparation_results.size() < max_jobs \
			and preparation_attempts > 0:
		preparation_attempts -= 1
		var preparation_step := _advance_next_source_section_preparation(main)
		if String(preparation_step.get("status", "idle")) == "idle":
			continue
		preparation_results.append(preparation_step)
		if String(preparation_step.get("status", "")) == "failed":
			preparation_failure = preparation_step
			break
	var all_results: Array[Dictionary] = advanced.duplicate()
	all_results.append_array(preparation_results)
	return {"status":"failed" if not preparation_failure.is_empty() else \
		("advanced" if not all_results.is_empty() else "idle"),
		"reason":String(preparation_failure.get("reason", "")),
		"advancedCount":all_results.size(), "pendingJobCount":_source_capture_pending_count(),
		"sourceCaptureAdvancedCount":advanced.size(),
		"sectionPreparationAdvancedCount":preparation_results.size(),
		"results":all_results}


func _advance_next_source_section_preparation(main: Object) -> Dictionary:
	var preparation_key := String(_source_section_preparation_order[0]) \
		if not _source_section_preparation_order.is_empty() else ""
	var preparation_value: Variant = _source_section_preparations.get(
		preparation_key, null)
	var preparation: Dictionary = preparation_value \
		if preparation_value is Dictionary else {}
	var step_result: Dictionary = _advance_next_source_section_preparation_step(main)
	var outcome := _classify_retained_preparation_outcome(step_result)
	var outcome_status := String(outcome.get("status", "failed"))
	var outcome_reason := String(outcome.get("reason", ""))
	if outcome_status == "stale":
		if not preparation.is_empty():
			_invalidate_stale_source_section_preparation(
				Vector3i(preparation.get("sectionKey", Vector3i.ZERO)),
				preparation, outcome_reason if not outcome_reason.is_empty() else \
				"ecology_section_preparation_source_stale")
		return _pending("ecology_section_preparation_stale_requeued", {
			"sectionKey":preparation.get("sectionKey", Vector3i.ZERO),
			"staleReason":outcome_reason})
	if outcome_status == "failed":
		var terminal_reason := outcome_reason if not outcome_reason.is_empty() else \
			"ecology_section_preparation_terminal_failure"
		if not preparation.is_empty() \
				and String(preparation.get("status", "")) != "failed":
			return _fail_source_section_preparation(
				Vector3i(preparation.get("sectionKey", Vector3i.ZERO)),
				preparation, terminal_reason, outcome.get("details", step_result))
		return _failed(terminal_reason, outcome.get("details", step_result))
	if outcome_status not in ["ready", "advanced", "pending", "idle"]:
		return _fail_source_section_preparation(
			Vector3i(preparation.get("sectionKey", Vector3i.ZERO)),
			preparation, "ecology_section_preparation_step_result_invalid", step_result)
	if outcome_status == "pending" and not preparation.is_empty():
		var retained_value: Variant = _source_section_preparations.get(
			preparation_key, null)
		var retained: Dictionary = retained_value \
			if retained_value is Dictionary else {}
		var section_key := Vector3i(preparation.get("sectionKey", Vector3i.ZERO))
		var retained_cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		if not retained.is_empty() and is_same(retained, preparation) \
				and String(retained_cohort.get("preparationKey", "")) == preparation_key \
				and String(retained.get("status", "pending")) == "pending":
			var plans: Array = retained.get("sourcePlans", [])
			var source_cursor := int(retained.get("sourceChunkCursor", 0))
			var source_chunk := Vector2i.ZERO
			var source_plan: Dictionary = {}
			if source_cursor >= 0 and source_cursor < plans.size() \
					and plans[source_cursor] is Dictionary:
				source_plan = plans[source_cursor]
				source_chunk = Vector2i(source_plan.get(
					"sourceChunkKey", Vector2i.ZERO))
			var family := String(step_result.get("family", ""))
			if family.is_empty():
				var families: Array = source_plan.get("requestedFamilies", [])
				var family_cursor := int(retained.get("familyCursor", 0))
				if family_cursor >= 0 and family_cursor < families.size():
					family = String(families[family_cursor])
			var pending_details := _bounded_preparation_pending_details(
				step_result, family, source_chunk)
			var pending_reason := String(step_result.get("reason",
				outcome.get("reason", "ecology_section_preparation_pending")))
			if pending_reason.is_empty():
				pending_reason = "ecology_section_preparation_pending"
			pending_details["reason"] = pending_reason
			retained["pendingReason"] = pending_reason
			retained["pendingDetails"] = pending_details
			if step_result.has("stage"):
				retained["stage"] = String(step_result.get("stage", ""))
			retained_cohort["sectionPreparation"] = retained
			_source_capture_cohorts[section_key] = retained_cohort
			_source_section_preparations[preparation_key] = retained
			var projected := {"status":"pending", "reason":pending_reason,
				"sectionKey":section_key, "pendingDetails":pending_details}
			for key: String in ["sourceId", "sourcePartId", "family", "sourceChunkKey",
					"dependency"]:
				if pending_details.has(key): projected[key] = pending_details[key]
			return projected
	return step_result


func _classify_retained_preparation_outcome(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"status":"failed", "reason":
			"ecology_section_preparation_step_result_invalid", "details":{}}
	var result: Dictionary = value
	var status := String(result.get("status", ""))
	var reason := String(result.get("reason", ""))
	if status == "stale" or _source_currentness_reason_is_stale(reason):
		return {"status":"stale", "reason":reason, "details":result}
	for nested_key: String in ["registration", "result"]:
		var nested_value: Variant = result.get(nested_key, null)
		if nested_value is Dictionary:
			var nested := _classify_retained_preparation_outcome(nested_value)
			if String(nested.get("status", "")) in ["failed", "stale"]:
				return nested
	if status == "failed" or String(result.get("disposition", "")) == "terminal" \
			or (status == "pending" and (bool(result.get("terminalFailure", false)) \
				or not bool(result.get("retryable", true)))):
		return {"status":"failed", "reason":reason, "details":result}
	if status in ["ready", "advanced", "pending", "idle"]:
		return {"status":status, "reason":reason, "details":result}
	return {"status":"failed", "reason":reason if not reason.is_empty() else \
		"ecology_section_preparation_step_result_invalid", "details":result}


func _advance_next_source_section_preparation_step(main: Object) -> Dictionary:
	if _source_section_preparation_order.is_empty(): return {"status":"idle"}
	var preparation_key := String(_source_section_preparation_order.pop_front())
	if preparation_key.is_empty():
		return {"status":"idle", "reason":"ecology_section_preparation_missing"}
	var preparation: Dictionary = _source_section_preparations[preparation_key]
	# Rotate before doing any work so a blocked source family cannot monopolize
	# the bounded scheduler or prevent another retained section from completing.
	_source_section_preparation_order.append(preparation_key)
	var section_key := Vector3i(preparation.get("sectionKey", Vector3i.ZERO))
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if cohort.is_empty() or String(cohort.get("preparationKey", "")) != preparation_key:
		_source_section_preparations.erase(preparation_key)
		_source_section_preparation_order.erase(preparation_key)
		return {"status":"idle", "reason":"ecology_section_preparation_owner_stale"}
	if String(preparation.get("status", "pending")) == "failed":
		return _failed(String(preparation.get("failureReason",
			"ecology_section_preparation_terminal_failure")), {
			"sectionKey":section_key, "preparationKey":preparation_key})
	var plans: Array = preparation.get("sourcePlans", [])
	var source_cursor := int(preparation.get("sourceChunkCursor", 0))
	var family_cursor := int(preparation.get("familyCursor", 0))
	if source_cursor >= plans.size():
		var census := _seal_retained_section_preparation(main, preparation)
		if String(census.get("status", "")) != "complete":
			if String(census.get("status", "")) == "failed":
				return _fail_source_section_preparation(section_key, preparation,
					String(census.get("reason", "ecology_section_preparation_census_failed")),
					census)
			preparation["pendingReason"] = String(census.get("reason",
				"ecology_section_preparation_census_pending"))
			cohort["sectionPreparation"] = preparation
			_source_capture_cohorts[section_key] = cohort
			_source_section_preparations[preparation_key] = preparation
			return {"status":"pending", "reason":String(preparation.pendingReason),
				"stage":"census_seal", "sectionKey":section_key}
		preparation["status"] = "complete"
		preparation["stage"] = "complete"
		preparation["census"] = census
		preparation["completedOpportunity"] = _source_capture_service_opportunities
		cohort["sectionPreparation"] = preparation
		_source_capture_cohorts[section_key] = cohort
		_source_section_preparations.erase(preparation_key)
		_source_section_preparation_order.erase(preparation_key)
		_source_section_preparation_completions += 1
		_wake_source_section_preparation(section_key,
			"ecology_section_preparation_complete", preparation_key + "|complete")
		return {"status":"ready", "stage":"complete", "sectionKey":section_key,
			"unitCount":int(preparation.get("unitCount", 0))}
	if source_cursor >= plans.size() or not plans[source_cursor] is Dictionary:
		return _fail_source_section_preparation(section_key, preparation,
			"ecology_section_preparation_source_plan_invalid", {
			"sourceCursor":source_cursor, "sourcePlanCount":plans.size()})
	var plan: Dictionary = plans[source_cursor]
	var capture_identity := String(plan.get("captureIdentity", ""))
	var capture_job: Dictionary = _source_capture_jobs.get(capture_identity, {})
	if capture_job.is_empty():
		_invalidate_stale_source_section_preparation(section_key, preparation,
			"ecology_section_preparation_capture_missing")
		return _pending("ecology_section_preparation_stale_requeued", {
			"sectionKey":section_key, "captureIdentity":capture_identity})
	if String(capture_job.get("status", "")) == "failed":
		var capture_failure: Dictionary = capture_job.get("failure", {})
		return _fail_source_section_preparation(section_key, preparation,
			String(capture_failure.get("reason",
			"ecology_section_preparation_capture_failed")), {
			"sectionKey":section_key, "captureIdentity":capture_identity})
	if String(capture_job.get("status", "")) in ["superseded", "cancelled"]:
		_invalidate_stale_source_section_preparation(section_key, preparation,
			"ecology_section_preparation_source_capture_superseded")
		return _pending("ecology_section_preparation_stale_requeued", {
			"sectionKey":section_key, "captureIdentity":capture_identity})
	if String(capture_job.get("status", "")) != "ready":
		if String(capture_job.get("status", "")) != "pending":
			return _fail_source_section_preparation(section_key, preparation,
				"ecology_section_preparation_capture_state_invalid", {
				"captureIdentity":capture_identity,
				"captureStatus":String(capture_job.get("status", ""))})
		preparation["stage"] = "source_capture"
		preparation["pendingReason"] = "ecology_section_preparation_source_capture_pending"
		cohort["sectionPreparation"] = preparation
		_source_capture_cohorts[section_key] = cohort
		_source_section_preparations[preparation_key] = preparation
		return {"status":"idle", "reason":"ecology_section_preparation_source_capture_pending",
			"sectionKey":section_key, "captureIdentity":capture_identity}
	var snapshot_value: Variant = capture_job.get("snapshot", null)
	var view_value: Variant = capture_job.get("sourcePublicationView", null)
	if not snapshot_value is Dictionary or not view_value is Dictionary:
		return _pending("ecology_section_preparation_source_proof_missing", {
			"sectionKey":section_key, "captureIdentity":capture_identity})
	var snapshot: Dictionary = snapshot_value
	var publication_view: Dictionary = view_value
	var publication_id := String(capture_job.get("sourcePublicationId", ""))
	var lease_token := String(capture_job.get("sourcePublicationLeaseToken", ""))
	if publication_id.is_empty() or publication_id != String(
			publication_view.get("publicationId", "")) \
			or lease_token.is_empty() or not _publication_view_matches_snapshot(publication_view,
			snapshot):
		_invalidate_stale_source_section_preparation(section_key, preparation,
			"ecology_section_preparation_publication_identity_stale")
		return _pending("ecology_section_preparation_stale_requeued", {
			"sectionKey":section_key, "captureIdentity":capture_identity})
	var admitted_publication_id := String(plan.get("sourcePublicationId", ""))
	if admitted_publication_id.is_empty():
		plan["sourcePublicationId"] = publication_id
		plan["sourcePublicationLeaseToken"] = lease_token
		plans[source_cursor] = plan
		preparation["sourcePlans"] = plans
	elif admitted_publication_id != publication_id \
			or String(plan.get("sourcePublicationLeaseToken", "")) != lease_token:
		_invalidate_stale_source_section_preparation(section_key, preparation,
			"ecology_section_preparation_capture_incarnation_changed")
		return _pending("ecology_section_preparation_stale_requeued", {
			"sectionKey":section_key, "captureIdentity":capture_identity,
			"expectedPublicationId":admitted_publication_id,
			"actualPublicationId":publication_id})
	var current_value: Variant = main.call("ecology_source_publication_local_is_current",
		publication_view, lease_token) \
		if is_instance_valid(main) and main.has_method(
			"ecology_source_publication_local_is_current") else null
	if not current_value is Dictionary or String(current_value.get("status", "")) != "ready":
		var current_reason := String(current_value.get("reason",
			"ecology_section_preparation_source_currentness_pending")) \
			if current_value is Dictionary else \
			"ecology_section_preparation_source_currentness_unavailable"
		if current_value is Dictionary and String(current_value.get("status", "")) \
				in ["failed", "stale"]:
			if String(current_value.get("status", "")) == "stale" \
					or _source_currentness_reason_is_stale(current_reason):
				_invalidate_stale_source_section_preparation(section_key,
					preparation, current_reason)
				return _pending("ecology_section_preparation_stale_requeued", {
					"sectionKey":section_key, "captureIdentity":capture_identity,
					"staleReason":current_reason})
			return _fail_source_section_preparation(section_key, preparation,
				current_reason, {"captureIdentity":capture_identity})
		if current_value is Dictionary and String(current_value.get("status", "")) \
				not in ["pending", "ready"]:
			return _fail_source_section_preparation(section_key, preparation,
				current_reason, {"captureIdentity":capture_identity})
		preparation["stage"] = "source_currentness"
		preparation["pendingReason"] = current_reason
		cohort["sectionPreparation"] = preparation
		_source_capture_cohorts[section_key] = cohort
		_source_section_preparations[preparation_key] = preparation
		return _pending(current_reason, {"sectionKey":section_key,
			"captureIdentity":capture_identity})
	var families: Array = plan.get("requestedFamilies", [])
	# Certified empty families already carry a sealed, current disposition in
	# the admitted publication view. Reuse that proof without scheduling a
	# conversion unit or manufacturing an empty-success result from missing data.
	while family_cursor < families.size():
		var empty_family := String(families[family_cursor])
		var empty_result: Dictionary = publication_view.get(
			"familyResultsById", {}).get(empty_family, {})
		var validated_empty_result: Dictionary = _validate_retained_family_receipt(
			empty_result, empty_family, Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)))
		if String(validated_empty_result.get("status", "")) == "failed" \
				or String(validated_empty_result.get("status", "")) == "stale":
			return validated_empty_result
		if String(validated_empty_result.get("status", "")) != "ready" \
				or String(validated_empty_result.get("disposition", "")) != "complete_empty":
			break
		var empty_rows: Array = validated_empty_result.get("sourceRows", [])
		var empty_state_value: Variant = preparation.get("activeSource", null)
		var empty_state: Dictionary = empty_state_value \
			if empty_state_value is Dictionary else {}
		if String(empty_state.get("captureIdentity", "")) != capture_identity:
			empty_state = {"captureIdentity":capture_identity,
				"supportRowsByFamily":{}, "identityRows":[],
				"preparedBandSlicesByKey":{}, "supportFamiliesPublished":false,
				"legacyRegistered":false}
		var empty_support_rows: Dictionary = empty_state.get("supportRowsByFamily", {})
		empty_support_rows[empty_family] = []
		empty_state["supportRowsByFamily"] = empty_support_rows
		empty_state["identityRows"] = (empty_state.get("identityRows", []) as Array) \
			+ [[plan.get("sourceChunkKey", Vector2i.ZERO), empty_family,
				String(snapshot.get("sourceRevision", "")),
				String(empty_result.get("familyRevision", "")),
				String(empty_result.get("familyPolicyRevision", "")),
				String(empty_result.get("familyPolicyDigest", "")),
				String(empty_result.get("sourceManifestDigest", ""))]]
		preparation["activeSource"] = empty_state
		preparation["pendingDetails"] = {}
		var identity_rows: Array = preparation.get("domainIdentityRows", [])
		identity_rows.append_array(empty_state.get("identityRows", []).slice(
			maxi(0, (empty_state.get("identityRows", []) as Array).size() - 1)))
		preparation["domainIdentityRows"] = identity_rows
		family_cursor += 1
		preparation["familyCursor"] = family_cursor
	if family_cursor >= families.size():
		var source_state_value: Variant = preparation.get("activeSource", null)
		var source_state: Dictionary = source_state_value if source_state_value is Dictionary else {}
		if String(source_state.get("captureIdentity", "")) != capture_identity:
			source_state = {"captureIdentity":capture_identity,
				"supportRowsByFamily":{}, "identityRows":[],
				"preparedBandSlicesByKey":{}, "supportFamiliesPublished":false,
				"legacyRegistered":false}
			preparation["activeSource"] = source_state
		if (source_state.get("preparedBandSlicesByKey", {}) as Dictionary).is_empty():
			if not main.has_method("prepare_ecology_source_publication_section_band_slices"):
				return _pending("ecology_source_publication_band_slice_owner_unavailable", {
					"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
					"sectionKey":section_key})
			var prepared_slice_result: Variant = main.call(
				"prepare_ecology_source_publication_section_band_slices",
				publication_view, lease_token, [section_key])
			if not prepared_slice_result is Dictionary \
					or String(prepared_slice_result.get("status", "")) != "ready":
				return prepared_slice_result if prepared_slice_result is Dictionary else \
					_pending("ecology_source_publication_band_slice_prepare_invalid")
			var prepared_slices_value: Variant = prepared_slice_result.get(
				"sectionBandSlicesByKey", null)
			if not prepared_slices_value is Dictionary \
					or not prepared_slices_value.has(section_key):
				return _pending("ecology_source_publication_band_slice_missing", {
					"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
					"sectionKey":section_key})
			source_state["preparedBandSlicesByKey"] = prepared_slices_value
			source_state["stage"] = "section_band_registration"
			preparation["activeSource"] = source_state
			preparation["stage"] = "section_band_slice"
			preparation["unitCount"] = int(preparation.get("unitCount", 0)) + 1
			preparation["lastAdvancedOpportunity"] = _source_capture_service_opportunities
			_source_section_preparation_units += 1
			cohort["sectionPreparation"] = preparation
			_source_capture_cohorts[section_key] = cohort
			_source_section_preparations[preparation_key] = preparation
			return {"status":"advanced", "stage":"section_band_slice_prepared",
				"sectionKey":section_key,
				"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
				"unitCount":int(preparation.unitCount)}
		if not bool(source_state.get("supportFamiliesPublished", false)):
			var all_support_rows: Dictionary = source_state.get("supportRowsByFamily", {})
			var non_tree_families: Array[String] = []
			for family_value: Variant in families:
				var family_name := String(family_value)
				if family_name == "trees": continue
				if not all_support_rows.has(family_name) \
						or not all_support_rows[family_name] is Array:
					return _pending("ecology_section_preparation_family_rows_missing", {
						"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
						"family":family_name})
				non_tree_families.append(family_name)
			if not non_tree_families.is_empty():
				var selected_rows_by_family: Dictionary = {}
				for family: String in non_tree_families:
					selected_rows_by_family[family] = all_support_rows[family]
				var published := publish_support_source_domain_family_projection(
					String(preparation.get("worldId", "")),
					Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)), snapshot,
					selected_rows_by_family, publication_view, lease_token,
					non_tree_families)
				if String(published.get("status", "")) != "ready":
					return published
			source_state["supportFamiliesPublished"] = true
			preparation["activeSource"] = source_state
		var expected_families: Array[String] = []
		for family_value: Variant in families: expected_families.append(String(family_value))
		if not bool(source_state.get("legacyRegistered", false)):
			var legacy_registration := _register_source_family_section_band_projections(
				main, String(preparation.get("worldId", "")),
				Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)), [section_key], snapshot,
				preparation.get("catalogArtifact", {}), publication_view, lease_token,
				expected_families, capture_identity, [], "",
				source_state.get("preparedBandSlicesByKey", {}), true)
			if String(legacy_registration.get("status", "")) != "ready":
				preparation["stage"] = "section_band_registration"
				preparation["activeSource"] = source_state
				cohort["sectionPreparation"] = preparation
				_source_capture_cohorts[section_key] = cohort
				_source_section_preparations[preparation_key] = preparation
				return legacy_registration
			source_state["legacyRegistered"] = true
			preparation["activeSource"] = source_state
			preparation["pendingDetails"] = {}
			preparation["unitCount"] = int(preparation.get("unitCount", 0)) + 1
			preparation["lastAdvancedOpportunity"] = _source_capture_service_opportunities
			_source_section_preparation_units += 1
			cohort["sectionPreparation"] = preparation
			_source_capture_cohorts[section_key] = cohort
			_source_section_preparations[preparation_key] = preparation
			return {"status":"advanced", "stage":"family_bands_registered",
				"sectionKey":section_key,
				"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
				"unitCount":int(preparation.unitCount)}
		var tree_registration := _register_source_family_section_band_projections(main,
			String(preparation.get("worldId", "")),
			Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)), [section_key], snapshot,
			preparation.get("catalogArtifact", {}), publication_view, lease_token,
			expected_families, capture_identity, plan.get("treeSections", []), "",
			source_state.get("preparedBandSlicesByKey", {}), false)
		if String(tree_registration.get("status", "")) != "ready":
			preparation["stage"] = "tree_band_admission"
			cohort["sectionPreparation"] = preparation
			_source_capture_cohorts[section_key] = cohort
			_source_section_preparations[preparation_key] = preparation
			return tree_registration
		preparation["sourceChunkCursor"] = source_cursor + 1
		preparation["familyCursor"] = 0
		preparation["activeFamily"] = {}
		preparation["activeSource"] = {}
		preparation["pendingReason"] = ""
		preparation["pendingDetails"] = {}
		preparation["stage"] = "source_families"
		preparation["unitCount"] = int(preparation.get("unitCount", 0)) + 1
		preparation["lastAdvancedOpportunity"] = _source_capture_service_opportunities
		_source_section_preparation_units += 1
		cohort["sectionPreparation"] = preparation
		_source_capture_cohorts[section_key] = cohort
		_source_section_preparations[preparation_key] = preparation
		return {"status":"advanced", "stage":"source_complete",
			"sectionKey":section_key,
			"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
			"unitCount":int(preparation.unitCount)}
	var family := String(families[family_cursor])
	var active_value: Variant = preparation.get("activeFamily", null)
	var active: Dictionary = active_value if active_value is Dictionary else {}
	if String(active.get("family", "")) != family \
			or String(active.get("captureIdentity", "")) != capture_identity:
		var family_result: Dictionary = publication_view.get("familyResultsById", {}).get(
			family, {})
		var validated_family_result: Dictionary = _validate_retained_family_receipt(
			family_result, family, Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)))
		if String(validated_family_result.get("status", "")) != "ready":
			return validated_family_result
		var family_rows_value: Array = validated_family_result.get("sourceRows", [])
		if String(family_result.get("disposition", "")) == "complete_nonempty" \
				and family_rows_value.is_empty():
			return _failed("ecology_section_preparation_nonempty_family_has_no_rows", {
				"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
				"family":family})
		active = {"family":family, "captureIdentity":capture_identity,
			"sourceRows":family_rows_value, "sourceCursor":0, "supportRows":[]}
		preparation["pendingDetails"] = {}
	if family != "trees":
		var source_rows: Array = active.get("sourceRows", [])
		var source_cursor_for_family := int(active.get("sourceCursor", 0))
		var cache_scan_count := 0
		while source_cursor_for_family < source_rows.size():
			var source_row_value: Variant = source_rows[source_cursor_for_family]
			if not source_row_value is Dictionary:
				return _failed("ecology_source_domain_row_invalid", {"family":family})
			var member_result := _prepare_retained_source_family(main, preparation,
				plan, snapshot, publication_view, lease_token, family, source_row_value)
			if String(member_result.get("status", "")) != "ready":
				active["lastReason"] = String(member_result.get("reason", ""))
				var pending_details: Dictionary = _bounded_preparation_pending_details(
					member_result, family, Vector2i(plan.get(
						"sourceChunkKey", Vector2i.ZERO)))
				preparation["pendingDetails"] = pending_details
				preparation["activeFamily"] = active
				preparation["pendingReason"] = String(member_result.get("reason", ""))
				cohort["sectionPreparation"] = preparation
				_source_capture_cohorts[section_key] = cohort
				_source_section_preparations[preparation_key] = preparation
				return member_result
			var family_support_rows: Array = active.get("supportRows", [])
			family_support_rows.append_array(member_result.get("supportRows", []))
			active["supportRows"] = family_support_rows
			active["sourceCursor"] = source_cursor_for_family + 1
			preparation["activeFamily"] = active
			preparation["pendingDetails"] = {}
			source_cursor_for_family += 1
			preparation["pendingReason"] = ""
			preparation["pendingDetails"] = {}
			if bool(member_result.get("cacheHit", false)):
				cache_scan_count += 1
				_source_section_preparation_cache_hit_rows += 1
				if cache_scan_count >= 16 and source_cursor_for_family < source_rows.size():
					preparation["lastAdvancedOpportunity"] = _source_capture_service_opportunities
					cohort["sectionPreparation"] = preparation
					_source_capture_cohorts[section_key] = cohort
					_source_section_preparations[preparation_key] = preparation
					return {"status":"advanced", "stage":"cached_source_rows_scanned",
						"sectionKey":section_key,
						"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
						"family":family, "sourceCursor":source_cursor_for_family,
						"sourceCount":source_rows.size(),
						"cacheHitRows":cache_scan_count,
						"unitCount":int(preparation.get("unitCount", 0))}
				continue
			preparation["unitCount"] = int(preparation.get("unitCount", 0)) + 1
			preparation["lastAdvancedOpportunity"] = _source_capture_service_opportunities
			_source_section_preparation_units += 1
			cohort["sectionPreparation"] = preparation
			_source_capture_cohorts[section_key] = cohort
			_source_section_preparations[preparation_key] = preparation
			return {"status":"advanced", "stage":"source_member_converted",
				"sectionKey":section_key,
				"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
				"family":family,
				"sourceCursor":source_cursor_for_family,
				"sourceCount":source_rows.size(),
				"unitCount":int(preparation.unitCount)}
	var family_result: Dictionary = publication_view.get("familyResultsById", {}).get(
		family, {})
	var identity_rows: Array = preparation.get("domainIdentityRows", [])
	identity_rows.append([plan.get("sourceChunkKey", Vector2i.ZERO), family,
		String(snapshot.get("sourceRevision", "")),
		String(family_result.get("familyRevision", "")),
		String(family_result.get("familyPolicyRevision", "")),
		String(family_result.get("familyPolicyDigest", "")),
		String(family_result.get("sourceManifestDigest", ""))])
	preparation["domainIdentityRows"] = identity_rows
	var source_state_value: Variant = preparation.get("activeSource", null)
	var source_state: Dictionary = source_state_value if source_state_value is Dictionary else {}
	if String(source_state.get("captureIdentity", "")) != capture_identity:
		source_state = {"captureIdentity":capture_identity,
			"supportRowsByFamily":{}, "identityRows":[],
			"preparedBandSlicesByKey":{}, "supportFamiliesPublished":false,
			"legacyRegistered":false}
	var support_rows_by_family: Dictionary = source_state.get("supportRowsByFamily", {})
	support_rows_by_family[family] = active.get("supportRows", [])
	source_state["supportRowsByFamily"] = support_rows_by_family
	preparation["activeSource"] = source_state
	preparation["familyCursor"] = family_cursor + 1
	preparation["activeFamily"] = {}
	preparation["pendingReason"] = ""
	preparation["pendingDetails"] = {}
	preparation["stage"] = "source_families"
	cohort["sectionPreparation"] = preparation
	_source_capture_cohorts[section_key] = cohort
	_source_section_preparations[preparation_key] = preparation
	return {"status":"advanced", "stage":"family_complete",
		"sectionKey":section_key, "sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
		"family":family, "unitCount":int(preparation.get("unitCount", 0))}


func _prepare_retained_source_family(main: Object, preparation: Dictionary,
		plan: Dictionary, snapshot: Dictionary, publication_view: Dictionary,
		publication_lease_token: String, family: String,
		source_row: Dictionary) -> Dictionary:
	var family_result: Dictionary = publication_view.get("familyResultsById", {}).get(
		family, {})
	var validated_family_result: Dictionary = _validate_retained_family_receipt(
		family_result, family, Vector2i(plan.get("sourceChunkKey", Vector2i.ZERO)))
	if String(validated_family_result.get("status", "")) != "ready":
		return validated_family_result
	if String(family_result.get("disposition", "")) \
			!= "complete_nonempty":
		return _failed("ecology_source_family_result_incomplete", {
			"family":family, "sourceId":String(source_row.get("sourceId", "")),
			"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
			"familyResult":family_result,
			"disposition":String(family_result.get("disposition", ""))})
	var source_id := String(source_row.get("sourceId", ""))
	if source_id.is_empty() or String(source_row.get("producerFamily", "")) != family:
		return _failed("ecology_source_domain_source_identity_invalid", {
			"family":family, "sourceId":source_id})
	var cached_row := _cached_retained_static_source_row(source_row, snapshot,
		publication_view, publication_lease_token)
	if String(cached_row.get("status", "")) == "ready":
		return cached_row
	var fingerprint_cache: Dictionary = preparation.get("fingerprintCache", {})
	var converted := _compile_non_tree_source_row(main, snapshot, source_row,
		publication_view, publication_lease_token, fingerprint_cache)
	if String(converted.get("status", "")) != "ready": return converted
	var support_rows: Array[Dictionary] = []
	for row_value: Variant in converted.get("supportRows", []):
		if not row_value is Dictionary:
			return _failed("ecology_static_source_support_row_invalid", {
				"family":family, "sourceId":source_id})
		support_rows.append(row_value)
	for artifact_value: Variant in converted.get("memberArtifacts", []):
		if not artifact_value is Dictionary:
			return _failed("ecology_static_source_member_artifact_invalid", {
				"family":family, "sourceId":source_id})
		var artifact: Dictionary = artifact_value
		var member_key := _source_part_identity_key(source_id,
			String(artifact.get("sourcePartId", "")))
		if member_key.is_empty():
			return _failed("ecology_static_source_member_identity_invalid", {
				"family":family, "sourceId":source_id})
		_canonical_static_artifact_by_member[member_key] = artifact
		_track_source_publication_member(String(publication_view.get("publicationId", "")),
			member_key)
	preparation["fingerprintCache"] = fingerprint_cache
	return {"status":"ready", "supportRows":support_rows,
		"memberArtifacts":converted.get("memberArtifacts", [])}


func _validate_retained_family_receipt(family_result: Dictionary, family: String,
		source_chunk: Vector2i) -> Dictionary:
	if String(family_result.get("status", "")) != "ready":
		return family_result
	var disposition := String(family_result.get("disposition", ""))
	var rows_value: Variant = family_result.get("sourceRows", null)
	if disposition not in ["complete_nonempty", "complete_empty"] \
			or not rows_value is Array:
		return _failed("ecology_section_preparation_family_receipt_invalid", {
			"family":family, "sourceChunkKey":source_chunk,
			"familyResult":family_result})
	if (disposition == "complete_empty" and not rows_value.is_empty()) \
			or (disposition == "complete_nonempty" and rows_value.is_empty()):
		return _failed("ecology_section_preparation_family_receipt_rows_disagree", {
			"family":family, "sourceChunkKey":source_chunk,
			"disposition":disposition, "sourceRowCount":rows_value.size()})
	return {"status":"ready", "disposition":disposition,
		"sourceRows":rows_value}


func _cached_retained_static_source_row(source_row: Dictionary,
		snapshot: Dictionary, publication_view: Dictionary,
		publication_lease_token: String) -> Dictionary:
	var source_id := String(source_row.get("sourceId", ""))
	var family := String(source_row.get("producerFamily", ""))
	var part_ids: Array[String] = []
	if family == "details":
		part_ids.append("surface:%d" % int(source_row.get("surfaceIndex", -1)))
	else:
		var render_members: Variant = source_row.get("renderMembers", null)
		if not render_members is Array: return {"status":"miss"}
		for member_value: Variant in render_members:
			if not member_value is Dictionary: return {"status":"miss"}
			part_ids.append(String(member_value.get("memberId", "")))
	if part_ids.is_empty() or part_ids.has(""):
		return {"status":"miss"}
	var support_rows: Array[Dictionary] = []
	var artifacts: Array[Dictionary] = []
	for part_id: String in part_ids:
		var member_key := _source_part_identity_key(source_id, part_id)
		var artifact_value: Variant = _canonical_static_artifact_by_member.get(member_key, null)
		if not artifact_value is Dictionary: return {"status":"miss"}
		var artifact: Dictionary = artifact_value
		var support_value: Variant = artifact.get("supportRow", null)
		var input_value: Variant = artifact.get("input", null)
		if String(artifact.get("sourceId", "")) != source_id \
				or String(artifact.get("sourcePartId", "")) != part_id \
				or not is_same(artifact.get("producerRow", null), source_row) \
				or not is_same(artifact.get("snapshot", null), snapshot) \
				or not is_same(artifact.get("publicationView", null), publication_view) \
				or String(artifact.get("publicationLeaseToken", "")) \
				!= publication_lease_token \
				or String(artifact.get("sourceDomainRevision", "")) \
				!= String(snapshot.get("sourceDomainRevision", "")) \
				or String(artifact.get("producerSnapshotRevision", "")) \
				!= String(source_row.get("producerSnapshotRevision", "")) \
				or not support_value is Dictionary or not support_value.is_read_only() \
				or String(support_value.get("sourceDomainRevision", "")) \
				!= String(snapshot.get("sourceDomainRevision", "")) \
				or String(support_value.get("producerSnapshotRevision", "")) \
				!= String(source_row.get("producerSnapshotRevision", "")) \
				or not input_value is Dictionary or not input_value.is_read_only():
			return {"status":"miss"}
		support_rows.append(support_value)
		artifacts.append(artifact)
	return {"status":"ready", "sourceId":source_id,
		"supportRows":support_rows, "memberArtifacts":artifacts,
		"cacheHit":true}


func _source_section_preparation_key(world_id: String,
		section_key: Vector3i) -> String:
	_source_section_preparation_sequence += 1
	return "%s|section:%d,%d,%d|prep:%d" % [world_id,
		section_key.x, section_key.y, section_key.z,
		_source_section_preparation_sequence]


func _wake_source_section_preparation(section_key: Vector3i,
		reason: String, wake_token: String) -> void:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	var coordinator: Object = main.get("world_static_section_coordinator") as Object \
		if is_instance_valid(main) else null
	if is_instance_valid(coordinator) and coordinator.has_method("wake_visible_section_demand"):
		coordinator.call("wake_visible_section_demand", section_key, reason, wake_token)


func _source_section_preparation_is_current(main: Object,
		preparation: Dictionary) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method(
			"ecology_source_publication_local_is_current"):
		return _pending("ecology_section_preparation_currentness_unavailable")
	if String(preparation.get("worldId", "")) != _world_id \
			or String(preparation.get("worldSeed", "")) != String(main.get("seed_text")):
		return {"status":"stale", "reason":"ecology_section_preparation_world_identity_stale",
			"retryable":true}
	var plans_value: Variant = preparation.get("sourcePlans", [])
	if not plans_value is Array:
		return _failed("ecology_section_preparation_source_plans_invalid")
	var plans: Array = plans_value
	for plan_index: int in range(plans.size()):
		var plan_value: Variant = plans[plan_index]
		if not plan_value is Dictionary:
			return _failed("ecology_section_preparation_source_plan_invalid")
		var plan: Dictionary = plan_value
		var capture_identity := String(plan.get("captureIdentity", ""))
		if capture_identity.is_empty():
			return _failed("ecology_section_preparation_capture_identity_missing")
		var job: Dictionary = _source_capture_jobs.get(capture_identity, {})
		var job_status := String(job.get("status", ""))
		if job.is_empty() or job_status in ["superseded", "cancelled"]:
			return {"status":"stale", "reason":"ecology_section_preparation_source_missing",
				"captureIdentity":capture_identity, "retryable":true}
		if job_status == "failed":
			var capture_failure: Dictionary = job.get("failure", {})
			return _failed(String(capture_failure.get("reason",
				"ecology_section_preparation_capture_failed")), {
				"captureIdentity":capture_identity})
		if job_status == "pending":
			return _pending(String(job.get("lastReason",
				"ecology_section_preparation_source_capture_pending")), {
				"captureIdentity":capture_identity,
				"sourceChunkKey":job.get("sourceChunkKey", Vector2i.ZERO)})
		if job_status != "ready":
			return _failed("ecology_section_preparation_capture_state_invalid", {
				"captureIdentity":capture_identity, "captureStatus":job_status})
		var view: Variant = job.get("sourcePublicationView", null)
		var snapshot: Variant = job.get("snapshot", null)
		if not view is Dictionary \
				or not snapshot is Dictionary \
				or job.get("sourceChunkKey", null) != plan.get("sourceChunkKey", null):
			return {"status":"stale", "reason":"ecology_section_preparation_source_missing",
				"captureIdentity":capture_identity, "retryable":true}
		var admitted_view: Dictionary = view
		var admitted_snapshot: Dictionary = snapshot
		var expected_publication_id := String(plan.get("sourcePublicationId", ""))
		var expected_lease_token := String(plan.get("sourcePublicationLeaseToken", ""))
		var actual_publication_id := String(job.get("sourcePublicationId", ""))
		var actual_lease_token := String(job.get("sourcePublicationLeaseToken", ""))
		if actual_publication_id.is_empty() or actual_lease_token.is_empty():
			return {"status":"stale",
				"reason":"ecology_section_preparation_source_publication_identity_missing",
				"captureIdentity":capture_identity, "retryable":true}
		if expected_publication_id.is_empty() and expected_lease_token.is_empty():
			plan["sourcePublicationId"] = actual_publication_id
			plan["sourcePublicationLeaseToken"] = actual_lease_token
			plans[plan_index] = plan
			preparation["sourcePlans"] = plans
		elif expected_publication_id != actual_publication_id \
				or expected_lease_token != actual_lease_token:
			return {"status":"stale",
				"reason":"ecology_section_preparation_capture_incarnation_changed",
				"captureIdentity":capture_identity,
				"expectedPublicationId":expected_publication_id,
				"actualPublicationId":actual_publication_id,
				"retryable":true}
		if not _publication_view_matches_snapshot(admitted_view, admitted_snapshot):
			return {"status":"stale",
				"reason":"ecology_section_preparation_source_identity_stale",
				"captureIdentity":capture_identity, "retryable":true}
		var token := String(job.get("sourcePublicationLeaseToken", ""))
		if token.is_empty():
			return {"status":"stale",
				"reason":"ecology_section_preparation_source_lease_missing",
				"captureIdentity":capture_identity, "retryable":true}
		var current: Variant = main.call("ecology_source_publication_local_is_current",
			admitted_view, token)
		if not current is Dictionary:
			return _pending("ecology_section_preparation_currentness_unavailable", {
				"captureIdentity":capture_identity})
		var current_status := String(current.get("status", ""))
		if current_status == "pending":
			return _pending(String(current.get("reason",
				"ecology_section_preparation_source_currentness_pending")), {
				"captureIdentity":capture_identity})
		if current_status == "failed":
			var current_reason := String(current.get("reason",
				"ecology_section_preparation_source_currentness_failed"))
			if _source_currentness_reason_is_stale(current_reason):
				return {"status":"stale", "reason":current_reason,
					"captureIdentity":capture_identity, "retryable":true}
			return _failed(current_reason, {"captureIdentity":capture_identity})
		if current_status != "ready":
			return _failed("ecology_section_preparation_currentness_result_invalid", {
				"captureIdentity":capture_identity, "currentStatus":current_status})
		var family_results: Dictionary = admitted_view.get("familyResultsById", {})
		for family_value: Variant in plan.get("requestedFamilies", []):
			var family := String(family_value)
			var family_result: Dictionary = family_results.get(family, {})
			if String(family_result.get("status", "")) != "ready" \
					or String(family_result.get("disposition", "")) \
					not in ["complete_nonempty", "complete_empty"]:
				return _failed("ecology_section_preparation_family_receipt_invalid", {
					"sourceChunkKey":plan.get("sourceChunkKey", Vector2i.ZERO),
					"family":family})
	return {"status":"ready"}


func _failed_source_section_preparation_identity_is_current(main: Object,
		preparation: Dictionary) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method(
			"ecology_source_support_policy_inputs"):
		return _pending("ecology_section_preparation_failed_identity_authority_unavailable")
	var seed := String(main.get("seed_text"))
	if seed.is_empty() or String(preparation.get("worldId", "")) != _world_id \
			or String(preparation.get("worldSeed", "")) != seed:
		return {"status":"stale",
			"reason":"ecology_section_preparation_failed_world_identity_changed",
			"retryable":true}
	var world_generation: Object = main.get("world_generation_system") as Object
	if not is_instance_valid(world_generation) or not world_generation.has_method(
			"terrain_volume_chunk_revision"):
		return _pending("ecology_section_preparation_failed_revision_authority_unavailable")
	var removed_snapshot := RemovedProps.capture(main)
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("ecology_section_preparation_failed_removal_snapshot_unavailable")
	var plans_value: Variant = preparation.get("sourcePlans", null)
	if not plans_value is Array or plans_value.is_empty():
		return _failed("ecology_section_preparation_source_plans_invalid")
	var stale_reason := ""
	var stale_capture_identity := ""
	var stale_source_chunk: Vector2i = Vector2i.ZERO
	var pending_result: Dictionary = {}
	for plan_value: Variant in plans_value:
		if not plan_value is Dictionary:
			return _failed("ecology_section_preparation_source_plan_invalid")
		var plan: Dictionary = plan_value
		var capture_identity := String(plan.get("captureIdentity", ""))
		if capture_identity.is_empty():
			return _failed("ecology_section_preparation_source_plan_invalid")
		var job: Dictionary = _source_capture_jobs.get(capture_identity, {})
		if job.is_empty() \
				or String(job.get("status", "")) in ["superseded", "cancelled"]:
			if stale_reason.is_empty():
				stale_reason = "ecology_section_preparation_failed_capture_replaced"
				stale_capture_identity = capture_identity
			continue
		var capture_status := String(job.get("status", ""))
		if capture_status not in ["pending", "ready", "failed"]:
			return _failed("ecology_section_preparation_failed_capture_state_invalid", {
				"captureIdentity":capture_identity, "captureStatus":capture_status})
		var source_chunk_value: Variant = plan.get("sourceChunkKey", null)
		if not source_chunk_value is Vector2i:
			return _failed("ecology_section_preparation_source_plan_invalid")
		var source_chunk: Vector2i = source_chunk_value
		var terrain_revision := String(world_generation.call(
			"terrain_volume_chunk_revision", source_chunk,
			Grid.STREAM_CHUNK_SIZE_CELLS))
		if terrain_revision.is_empty():
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_terrain_revision_pending", {
					"sourceChunkKey":source_chunk})
			continue
		var policy_input_result := _canonical_support_policy_inputs(main, _world_id,
			source_chunk, seed, {"terrainVolumeChunkRevision":terrain_revision})
		if String(policy_input_result.get("status", "")) != "ready":
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_policy_inputs_pending", {
					"sourceChunkKey":source_chunk,
					"diagnostic":policy_input_result.get("diagnostic", {})})
			continue
		var source_inputs: Dictionary = policy_input_result.get("sourceInputs", {})
		var catalog_value: Variant = policy_input_result.get("catalogArtifact", null)
		if not catalog_value is Dictionary or not catalog_value.is_read_only():
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_catalog_pending", {
					"sourceChunkKey":source_chunk})
			continue
		if not main.has_method("_removed_props_projection_for_source_chunk"):
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_removal_projection_unavailable", {
					"sourceChunkKey":source_chunk})
			continue
		var removal_value: Variant = main.call(
			"_removed_props_projection_for_source_chunk", source_chunk, removed_snapshot)
		if not removal_value is Dictionary \
				or String(removal_value.get("status", "")) != "ready":
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_removal_projection_pending", {
					"sourceChunkKey":source_chunk})
			continue
		var removal: Dictionary = removal_value
		var current_cache_identity := ProducerDomainScript.snapshot_cache_identity(
			_world_id, source_chunk, source_inputs,
			String(removal.get("digest", "")), catalog_value)
		var captured_cache_identity := String(job.get("captureCacheIdentity", ""))
		if current_cache_identity.is_empty():
			if pending_result.is_empty():
				pending_result = _pending("ecology_section_preparation_failed_cache_identity_unavailable", {
					"sourceChunkKey":source_chunk})
			continue
		if captured_cache_identity.is_empty():
			if capture_status == "pending":
				if pending_result.is_empty():
					pending_result = _pending("ecology_section_preparation_failed_capture_identity_pending", {
						"sourceChunkKey":source_chunk,
						"captureIdentity":capture_identity})
				continue
			if stale_reason.is_empty():
				stale_reason = "ecology_section_preparation_failed_cache_identity_unavailable"
				stale_capture_identity = capture_identity
				stale_source_chunk = source_chunk
		elif current_cache_identity != captured_cache_identity:
			if stale_reason.is_empty():
				stale_reason = "ecology_section_preparation_failed_source_identity_changed"
				stale_capture_identity = capture_identity
				stale_source_chunk = source_chunk
		var expected_families: Array = plan.get("requestedFamilies", [])
		var captured_families: Array = job.get("requestedFamilies", [])
		if expected_families != captured_families:
			if stale_reason.is_empty():
				stale_reason = "ecology_section_preparation_failed_family_selection_changed"
				stale_capture_identity = capture_identity
				stale_source_chunk = source_chunk
	if not stale_reason.is_empty():
		return {"status":"stale", "reason":stale_reason,
			"captureIdentity":stale_capture_identity,
			"sourceChunkKey":stale_source_chunk, "retryable":true}
	if not pending_result.is_empty():
		return pending_result
	return {"status":"ready", "unchangedFailure":true}


func _source_currentness_reason_is_stale(reason: String) -> bool:
	return reason.contains("_stale") or reason.contains("_not_admitted") \
		or reason in ["ecology_source_publication_view_not_admitted",
			"ecology_source_publication_member_absent",
			"ecology_source_publication_member_alias_mismatch",
			"ecology_band_slice_catalog_lease_stale",
			"ecology_band_slice_view_not_admitted"]


func _fail_source_section_preparation(section_key: Vector3i,
		preparation: Dictionary, reason: String, details: Dictionary = {}) -> Dictionary:
	var preparation_key := String(preparation.get("preparationKey", ""))
	preparation["status"] = "failed"
	preparation["stage"] = "failed"
	preparation["failureReason"] = reason
	preparation["failureDetails"] = details.duplicate(true)
	preparation["pendingReason"] = reason
	_source_section_preparations[preparation_key] = preparation
	_source_section_preparation_order.erase(preparation_key)
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if not cohort.is_empty():
		cohort["sectionPreparation"] = preparation
		cohort["blockedReason"] = reason
		_set_source_capture_cohort_status(section_key, cohort, "failed")
	_wake_source_section_preparation(section_key, reason,
		preparation_key + "|failed|" + reason.sha256_text())
	return _failed(reason, {"sectionKey":section_key,
		"preparationKey":preparation_key, "failureDetails":details})


func _invalidate_stale_source_section_preparation(section_key: Vector3i,
		preparation: Dictionary, reason: String) -> void:
	var preparation_key := String(preparation.get("preparationKey", ""))
	var capture_identities: Dictionary = {}
	for plan_value: Variant in preparation.get("sourcePlans", []):
		if plan_value is Dictionary:
			var capture_identity := String(plan_value.get("captureIdentity", ""))
			if not capture_identity.is_empty():
				capture_identities[capture_identity] = true
	for capture_identity_value: Variant in capture_identities:
		var capture_identity := String(capture_identity_value)
		var job: Dictionary = _source_capture_jobs.get(capture_identity, {})
		if not job.is_empty():
			_wake_source_capture_subscribers(job,
				"ecology_section_preparation_source_stale",
				capture_identity + "|stale|" + reason.sha256_text())
			_discard_source_capture_job(capture_identity)
	_source_section_preparations.erase(preparation_key)
	_source_section_preparation_order.erase(preparation_key)
	var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	if not cohort.is_empty():
		if cohort.get("sectionPreparation", {}) == preparation:
			cohort.erase("sectionPreparation")
		if String(cohort.get("preparationKey", "")) == preparation_key:
			cohort.erase("preparationKey")
		cohort["closureSealed"] = false
		cohort["closureDisposition"] = "missing"
		cohort["blockedReason"] = reason
		if String(cohort.get("status", "")) in ["complete", "failed", "blocked"]:
			_set_source_capture_cohort_status(section_key, cohort, "deferred")
		else:
			_source_capture_cohorts[section_key] = cohort
	_source_section_preparation_stale_count += 1
	_wake_source_section_preparation(section_key,
		"ecology_section_preparation_stale", preparation_key + "|stale")


func _seal_retained_section_preparation(main: Object,
		preparation: Dictionary) -> Dictionary:
	var world_id := String(preparation.get("worldId", ""))
	var section_key := Vector3i(preparation.get("sectionKey", Vector3i.ZERO))
	var query := query_section(world_id, section_key)
	if String(query.get("status", "")) != "ready": return query
	var source_revisions: Dictionary = {}
	var source_revision_first_section: Dictionary = {}
	var source_identities: Dictionary = {}
	var ids: Array[String] = []
	var section_parts: Array[Dictionary] = []
	var historical_tombstones_by_pair: Dictionary = {}
	var compiled_pairs: Dictionary = {}
	var ranges: Dictionary = {}
	for contributor_value: Variant in query.get("contributors", []):
		if not contributor_value is Dictionary:
			return _pending("ecology_support_contributor_invalid")
		var contributor: Dictionary = contributor_value
		if String(contributor.get("state", "")) != "compiled": continue
		var source_id := String(contributor.get("sourceId", ""))
		var part_id := String(contributor.get("sourcePartId", ""))
		var pair_key := _source_part_identity_key(source_id, part_id)
		if pair_key.is_empty() or compiled_pairs.has(pair_key):
			return _pending("ecology_support_compiled_member_identity_duplicated")
		compiled_pairs[pair_key] = true
	for contributor_value: Variant in query.get("contributors", []):
		if not contributor_value is Dictionary:
			return _pending("ecology_support_contributor_invalid")
		var contributor: Dictionary = contributor_value
		var source_id := String(contributor.get("sourceId", ""))
		var part_id := String(contributor.get("sourcePartId", ""))
		var pair_key := _source_part_identity_key(source_id, part_id)
		if pair_key.is_empty():
			return _pending("ecology_support_contributor_identity_invalid")
		if String(contributor.get("state", "")) == "tombstoned":
			if not historical_tombstones_by_pair.has(pair_key):
				historical_tombstones_by_pair[pair_key] = []
			var history: Array = historical_tombstones_by_pair[pair_key]
			history.append({"sourceId":source_id, "sourcePartId":part_id,
				"sourceRevision":String(contributor.get("sourceRevision", "")),
				"tombstoneRevision":String(contributor.get("tombstoneRevision", ""))})
			continue
		if String(contributor.get("state", "")) != "compiled":
			return _pending("ecology_support_member_recipe_pending", {
				"sourceId":source_id, "sourcePartId":part_id})
		var revision := String(contributor.get("sourceRevision", ""))
		var conflict := _source_revision_conflict_details(source_id, part_id,
			pair_key, revision, section_key, source_revisions,
			source_revision_first_section)
		if not conflict.is_empty():
			return _pending(String(conflict.get("reason",
				"ecology_support_source_revision_conflict")), conflict)
		ids.append(pair_key)
		if not source_revisions.has(pair_key):
			source_revisions[pair_key] = revision
			source_revision_first_section[pair_key] = section_key
		var identity := {"sourceId":source_id, "sourcePartId":part_id}
		identity.make_read_only()
		source_identities[pair_key] = identity
		section_parts.append(identity)
		var range := _canonical_support_range(contributor, section_key)
		if range.is_empty():
			return _pending("ecology_source_member_support_range_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
		if not ranges.has(pair_key): ranges[pair_key] = []
		var pair_ranges: Array = ranges[pair_key]
		pair_ranges.append(range)
	var removal_rows: Array[Dictionary] = []
	var history_keys: Array = historical_tombstones_by_pair.keys()
	history_keys.sort()
	for history_key_value: Variant in history_keys:
		var history_key := String(history_key_value)
		if compiled_pairs.has(history_key): continue
		var history_rows: Array = historical_tombstones_by_pair[history_key].duplicate(false)
		history_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_source_revision := String(a.get("sourceRevision", ""))
			var b_source_revision := String(b.get("sourceRevision", ""))
			if a_source_revision != b_source_revision:
				return a_source_revision < b_source_revision
			return String(a.get("tombstoneRevision", "")) \
				< String(b.get("tombstoneRevision", "")))
		if history_rows.is_empty():
			return _pending("ecology_support_tombstone_history_invalid")
		var historical_identity: Dictionary = history_rows[0]
		var removed_source_id := String(historical_identity.get("sourceId", ""))
		var removed_part_id := String(historical_identity.get("sourcePartId", ""))
		if removed_source_id.is_empty() or removed_part_id.is_empty():
			return _pending("ecology_support_tombstone_history_invalid")
		var removal_revision := _value_digest([
			"ecology-section-source-removal-history/v1", world_id,
			[section_key.x, section_key.y, section_key.z], removed_source_id,
			removed_part_id, history_rows])
		if removal_revision.is_empty():
			return _pending("ecology_support_tombstone_history_digest_failed")
		removal_rows.append({"sourceId":removed_source_id,
			"sourcePartId":removed_part_id, "sectionKey":section_key,
			"sourceRevision":removal_revision})
	ids.sort()
	section_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _source_part_identity_key(String(a.sourceId), String(a.sourcePartId)) \
			< _source_part_identity_key(String(b.sourceId), String(b.sourcePartId)))
	for range_rows: Array in ranges.values(): range_rows.make_read_only()
	ranges.make_read_only()
	removal_rows.make_read_only()
	var coverage_certificate: Dictionary = query.get("coverageCertificate", {})
	var coverage := String(coverage_certificate.get("coverageDigest", ""))
	if coverage.length() != 64:
		return _pending("ecology_section_preparation_coverage_missing")
	var section_rows := {section_key:{
		"status":"empty" if ids.is_empty() else "complete",
		"sourcePartIds":ids, "sourceParts":section_parts,
		"coverageRevision":coverage}}
	var source_plan_rows: Array = preparation.get("domainIdentityRows", [])
	source_plan_rows.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0].x != b[0].x: return a[0].x < b[0].x
		if a[0].y != b[0].y: return a[0].y < b[0].y
		return String(a[1]) < String(b[1]))
	var catalog_value: Variant = preparation.get("catalogArtifact", null)
	if not catalog_value is Dictionary:
		return _pending("ecology_catalog_artifact_identity_missing")
	var catalog_artifact: Dictionary = catalog_value
	var catalog_id := String(catalog_artifact.get("artifactId", ""))
	if catalog_id.is_empty():
		return _pending("ecology_catalog_artifact_identity_missing")
	section_rows.make_read_only()
	source_revisions.make_read_only()
	source_identities.make_read_only()
	var support_ranges_by_section := {section_key:ranges}
	var tombstones_by_section := {section_key:removal_rows}
	support_ranges_by_section.make_read_only()
	tombstones_by_section.make_read_only()
	_latest_by_section[section_key] = source_revisions.duplicate(false)
	_latest_coverage_by_section[section_key] = coverage
	_latest_support_ranges_by_section[section_key] = ranges
	var pending_removals: Dictionary = {}
	for removal_value: Variant in removal_rows:
		if removal_value is Dictionary:
			pending_removals[String(removal_value.get("sourceId", ""))] = \
				String(removal_value.get("sourceRevision", ""))
	_pending_legacy_removal_revisions_by_section[section_key] = pending_removals
	var authority_revision := _value_digest([SCHEMA, world_id, catalog_id,
		source_plan_rows, section_rows, source_revisions, source_identities])
	if authority_revision.is_empty():
		return _pending("ecology_section_preparation_authority_digest_failed")
	var result := {"status":"complete", "schema":SCHEMA, "providerId":PROVIDER_ID,
		"worldId":world_id, "authorityRevision":authority_revision,
		"catalogArtifactId":catalog_id, "sections":section_rows,
		"sourceRevisions":source_revisions, "sourceIdentities":source_identities,
		"preparedSections":{}, "removalsBySection":tombstones_by_section,
		"supportRangesBySection":support_ranges_by_section,
		"diagnostics":{"sectionPreparationUnits":int(preparation.get("unitCount", 0)),
			"sourceRecordCount":preparation.get("sourcePlans", []).size()}}
	result.make_read_only()
	return result


func _wake_source_capture_subscribers(job: Dictionary, reason: String,
		wake_token: String) -> void:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	var coordinator: Object = main.get("world_static_section_coordinator") as Object \
		if is_instance_valid(main) else null
	if not is_instance_valid(coordinator) \
			or not coordinator.has_method("wake_visible_section_demand"):
		return
	for section_value: Variant in job.get("sections", {}).keys():
		if section_value is Vector3i:
			coordinator.call("wake_visible_section_demand", section_value,
				reason, wake_token)


func _enqueue_source_capture_job(identity: String) -> void:
	if identity.is_empty() or _source_capture_queued.has(identity):
		return
	var job: Dictionary = _source_capture_jobs.get(identity, {})
	if job.is_empty() or String(job.get("status", "")) != "pending" \
			or (job.get("sections", {}) as Dictionary).is_empty() \
			or not _job_has_active_capture_cohort_subscriber(job):
		return
	_source_capture_queue.append(identity)
	_source_capture_queued[identity] = true


func _take_next_source_capture_job(camera_position: Vector3) -> String:
	_promote_source_capture_cohorts()
	# Retire cancelled entries before choosing an index; removals below a
	# selected entry would otherwise shift the selected slot.
	for index in range(_source_capture_queue.size() - 1, -1, -1):
		var identity := _source_capture_queue[index]
		var job: Dictionary = _source_capture_jobs.get(identity, {})
		var latest_identity_key := String(job.get("latestIdentityKey", ""))
		if job.is_empty() or String(job.get("status", "")) != "pending" \
				or (job.get("sections", {}) as Dictionary).is_empty() \
				or String(_source_capture_latest_by_chunk.get(latest_identity_key, "")) != identity \
				or not _job_has_active_capture_cohort_subscriber(job):
			_source_capture_queue.remove_at(index)
			_source_capture_queued.erase(identity)
	var best_index := -1
	var best_distance := INF
	var best_dispatch_sequence := 0
	# Camera distance breaks ties between equally serviced jobs. The least-recent
	# dispatch sequence wins first, so a nearby job that stays pending cannot
	# monopolize every frame's capture budget.
	for index in range(_source_capture_queue.size()):
		var job: Dictionary = _source_capture_jobs[_source_capture_queue[index]]
		var dispatch_sequence := int(job.get("lastDispatchSequence", 0))
		var distance := INF
		for section_value: Variant in job.get("sections", {}).keys():
			if section_value is Vector3i:
				var center := Grid.origin_for_key(section_value) \
					+ Vector3.ONE * (Grid.SECTION_SIZE_METERS * 0.5)
				distance = minf(distance, center.distance_squared_to(camera_position))
		if best_index < 0 or dispatch_sequence < best_dispatch_sequence \
				or (dispatch_sequence == best_dispatch_sequence \
				and distance < best_distance):
			best_dispatch_sequence = dispatch_sequence
			best_distance = distance
			best_index = index
	if best_index < 0:
		return ""
	var selected := _source_capture_queue[best_index]
	_source_capture_queue.remove_at(best_index)
	_source_capture_queued.erase(selected)
	_source_capture_dispatch_sequence += 1
	var selected_job: Dictionary = _source_capture_jobs.get(selected, {})
	selected_job["lastDispatchSequence"] = _source_capture_dispatch_sequence
	_source_capture_jobs[selected] = selected_job
	return selected


## Drop one section's subscription after its visible demand is retired. Pending
## work with no subscribers is discarded; completed values enter a bounded idle
## cache so a nearby section can reuse them without retaining every explored area.
func release_section_capture_demand(section_key: Vector3i) -> Dictionary:
	if not Thread.is_main_thread():
		return _failed("ecology_source_capture_release_requires_main_thread")
	var detached := 0
	var retired := 0
	var section_jobs: Dictionary = _source_capture_jobs_by_section.get(section_key, {})
	var identities: Array = section_jobs.keys()
	_source_capture_jobs_by_section.erase(section_key)
	var released_cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
	var preparation_key := String(released_cohort.get("preparationKey", ""))
	if not preparation_key.is_empty():
		_source_section_preparations.erase(preparation_key)
		_source_section_preparation_order.erase(preparation_key)
	if String(released_cohort.get("status", "")) == "active":
		_source_capture_active_cohort_count = maxi(0,
			_source_capture_active_cohort_count - 1)
	_source_capture_cohorts.erase(section_key)
	for identity_value: Variant in identities:
		var identity := String(identity_value)
		var job: Dictionary = _source_capture_jobs.get(identity, {})
		var subscribers: Dictionary = job.get("sections", {})
		if job.is_empty() or not subscribers.has(section_key):
			continue
		_detach_tree_compile_demand_for_section(job, section_key)
		subscribers.erase(section_key)
		job["sections"] = subscribers
		_source_capture_jobs[identity] = job
		detached += 1
		if subscribers.is_empty():
			var before_count := _source_capture_jobs.size()
			_retire_source_capture_if_unsubscribed(identity)
			if _source_capture_jobs.size() < before_count:
				retired += 1
	var support_demand_released := false
	if _support_index != null and _support_index.has_method("release_section_demand"):
		_support_index.call("release_section_demand", section_key)
		support_demand_released = true
	_promote_source_capture_cohorts()
	return {"status":"released", "sectionKey":section_key,
		"detachedJobCount":detached, "retiredJobCount":retired,
		"releasedCohortId":String(released_cohort.get("cohortId", "")),
		"idleReadyCount":_source_capture_idle_ready_order.size(),
		"supportDemandReleased":support_demand_released}


## Tear down source capture payloads before world reset/owner destruction. There
## is no worker-side capture to join: capture advancement is main-thread only.
func reset_source_domain_captures() -> Dictionary:
	if not Thread.is_main_thread():
		return _failed("ecology_source_capture_reset_requires_main_thread")
	var removed_jobs := _source_capture_jobs.size()
	var removed_queue_entries := _source_capture_queue.size()
	for identity_value: Variant in _source_capture_jobs.keys():
		_discard_source_capture_job(String(identity_value))
	_source_capture_jobs.clear()
	_source_capture_jobs_by_section.clear()
	_source_capture_latest_by_chunk.clear()
	_source_capture_queue.clear()
	_source_capture_queued.clear()
	_source_capture_idle_ready_order.clear()
	_source_capture_dispatch_sequence = 0
	_source_capture_cohorts.clear()
	_source_capture_active_cohort_count = 0
	_source_capture_cohort_sequence = 0
	_source_capture_service_opportunities = 0
	_source_section_preparations.clear()
	_source_section_preparation_order.clear()
	_source_section_preparation_sequence = 0
	_source_section_preparation_units = 0
	_source_section_preparation_cache_hit_rows = 0
	_source_section_preparation_completions = 0
	_source_section_preparation_stale_count = 0
	_source_capture_cohort_admissions = 0
	_source_capture_cohort_completions = 0
	_source_capture_cohort_yields = 0
	return {"status":"reset", "worldId":_world_id,
		"removedJobCount":removed_jobs,
		"removedQueueEntryCount":removed_queue_entries}


func _retire_source_capture_if_unsubscribed(identity: String) -> void:
	var job: Dictionary = _source_capture_jobs.get(identity, {})
	if job.is_empty() or not (job.get("sections", {}) as Dictionary).is_empty():
		return
	var status := String(job.get("status", ""))
	if status == "ready":
		_source_capture_idle_ready_order.erase(identity)
		_source_capture_idle_ready_order.append(identity)
		while _source_capture_idle_ready_order.size() > MAX_IDLE_READY_SOURCE_CAPTURE_JOBS:
			var retired_identity: String = _source_capture_idle_ready_order.pop_front()
			_discard_source_capture_job(retired_identity)
	elif status != "pending":
		_discard_source_capture_job(identity)
	else:
		_discard_source_capture_job(identity)


func _track_source_publication_member(publication_id: String,
		member_key: String) -> void:
	if publication_id.is_empty() or member_key.is_empty():
		return
	var members: Dictionary = _source_publication_member_keys.get(publication_id, {})
	members[member_key] = true
	_source_publication_member_keys[publication_id] = members


func _retire_source_publication_member_artifacts(publication_id: String) -> void:
	if publication_id.is_empty():
		return
	var members: Dictionary = _source_publication_member_keys.get(publication_id, {})
	for member_key_value: Variant in members:
		var member_key := String(member_key_value)
		var static_value: Variant = _canonical_static_artifact_by_member.get(member_key, null)
		if static_value is Dictionary \
				and String(static_value.get("sourcePublicationId", "")) == publication_id:
			_canonical_static_artifact_by_member.erase(member_key)
		var tree_value: Variant = _canonical_tree_artifact_by_member.get(member_key, null)
		if tree_value is Dictionary \
				and String(tree_value.get("sourcePublicationId", "")) == publication_id:
			_canonical_tree_artifact_by_member.erase(member_key)
	for band_key_value: Variant in _canonical_tree_band_artifact_by_member_section.keys():
		var band_key := String(band_key_value)
		var band_value: Variant = _canonical_tree_band_artifact_by_member_section.get(
			band_key, null)
		if band_value is Dictionary \
				and String(band_value.get("sourcePublicationId", "")) == publication_id:
			_canonical_tree_band_artifact_by_member_section.erase(band_key)
	_source_publication_member_keys.erase(publication_id)


func _discard_source_capture_job(identity: String) -> void:
	if identity.is_empty():
		return
	var job: Dictionary = _source_capture_jobs.get(identity, {})
	_invalidate_preparations_for_discarded_capture(identity, job)
	var tree_demands_value: Variant = job.get("treeCompileDemands", {})
	if tree_demands_value is Dictionary:
		for demand_value: Variant in (tree_demands_value as Dictionary).values():
			if demand_value is Dictionary:
				_cancel_tree_compile_demand(demand_value)
		job["treeCompileDemands"] = {}
	var capture_identity := String(job.get("captureCacheIdentity", ""))
	var shared_capture_exists := false
	if not capture_identity.is_empty():
		for other_identity_value: Variant in _source_capture_jobs.keys():
			var other_identity := String(other_identity_value)
			if other_identity == identity:
				continue
			var other_job: Dictionary = _source_capture_jobs.get(other_identity, {})
			if String(other_job.get("captureCacheIdentity", "")) == capture_identity \
					and String(other_job.get("status", "")) in ["pending", "ready"]:
				shared_capture_exists = true
				break
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not capture_identity.is_empty() and is_instance_valid(main) \
			and main.has_method("cancel_ecology_source_domain_capture"):
		var owner_lease_token := String(job.get("catalogLeaseToken", ""))
		if not owner_lease_token.is_empty():
			main.call("cancel_ecology_source_domain_capture", capture_identity,
				owner_lease_token)
		elif not shared_capture_exists:
			main.call("cancel_ecology_source_domain_capture", capture_identity)
	var source_publication_id := String(job.get("sourcePublicationId", ""))
	_retire_source_publication_member_artifacts(source_publication_id)
	var catalog_lease_token := String(job.get("catalogLeaseToken", ""))
	if not catalog_lease_token.is_empty() and is_instance_valid(main) \
			and main.has_method("release_ecology_catalog_artifact_lease") \
			and not bool(job.get("catalogLeaseReleased", true)):
		main.call("release_ecology_catalog_artifact_lease", catalog_lease_token)
		job["catalogLeaseReleased"] = true
	var publication_lease_token := String(job.get("sourcePublicationLeaseToken", ""))
	if not publication_lease_token.is_empty() and is_instance_valid(main) \
			and main.has_method("release_ecology_source_publication"):
		main.call("release_ecology_source_publication", publication_lease_token)
		job["sourcePublicationLeaseToken"] = ""
	for section_value: Variant in job.get("sections", {}).keys():
		var section_jobs: Dictionary = _source_capture_jobs_by_section.get(section_value, {})
		section_jobs.erase(identity)
		if section_jobs.is_empty():
			_source_capture_jobs_by_section.erase(section_value)
		else:
			_source_capture_jobs_by_section[section_value] = section_jobs
		var cohort: Dictionary = _source_capture_cohorts.get(section_value, {})
		if not cohort.is_empty():
			if String(cohort.get("status", "")) in ["complete", "failed"]:
				_set_source_capture_cohort_status(Vector3i(section_value), cohort, "deferred")
				cohort["completedSequence"] = -1
			cohort["closureSealed"] = false
			_source_capture_cohorts[section_value] = cohort
	var latest_identity_key := String(job.get("latestIdentityKey", ""))
	if not latest_identity_key.is_empty() \
			and String(_source_capture_latest_by_chunk.get(latest_identity_key, "")) == identity:
		_source_capture_latest_by_chunk.erase(latest_identity_key)
	_source_capture_jobs.erase(identity)
	_source_capture_idle_ready_order.erase(identity)
	_source_capture_queued.erase(identity)
	_source_capture_queue.erase(identity)


func _invalidate_preparations_for_discarded_capture(identity: String,
		job: Dictionary) -> void:
	if identity.is_empty():
		return
	var affected_sections: Dictionary = {}
	for section_value: Variant in job.get("sections", {}).keys():
		affected_sections[section_value] = true
	for preparation_key_value: Variant in _source_section_preparations.keys():
		var preparation_key := String(preparation_key_value)
		var preparation: Dictionary = _source_section_preparations.get(
			preparation_key, {})
		var references_capture := false
		for plan_value: Variant in preparation.get("sourcePlans", []):
			if plan_value is Dictionary and String(plan_value.get(
					"captureIdentity", "")) == identity:
				references_capture = true
				break
		if references_capture:
			affected_sections[Vector3i(preparation.get("sectionKey", Vector3i.ZERO))] = true
			_source_section_preparations.erase(preparation_key)
			_source_section_preparation_order.erase(preparation_key)
	for section_value: Variant in affected_sections:
		if not section_value is Vector3i:
			continue
		var section_key := Vector3i(section_value)
		var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		if cohort.is_empty():
			continue
		var preparation_value: Variant = cohort.get("sectionPreparation", null)
		var references_capture := false
		if preparation_value is Dictionary:
			for plan_value: Variant in preparation_value.get("sourcePlans", []):
				if plan_value is Dictionary and String(plan_value.get(
						"captureIdentity", "")) == identity:
					references_capture = true
					break
		if not references_capture and not (job.get("sections", {}) as Dictionary).has(section_key):
			continue
		cohort.erase("sectionPreparation")
		cohort.erase("preparationKey")
		cohort["closureSealed"] = false
		cohort["closureDisposition"] = "missing"
		cohort["completedSequence"] = -1
		cohort["blockedReason"] = "ecology_source_capture_incarnation_discarded"
		var cohort_status := String(cohort.get("status", ""))
		if cohort_status in ["complete", "failed", "blocked"]:
			_set_source_capture_cohort_status(section_key, cohort, "deferred")
		else:
			_source_capture_cohorts[section_key] = cohort


func _source_capture_pending_count() -> int:
	var count := 0
	for identity_value: Variant in _source_capture_latest_by_chunk.values():
		var job: Dictionary = _source_capture_jobs.get(String(identity_value), {})
		if String(job.get("status", "")) == "pending":
			count += 1
	return count


func _queued_source_capture_requires_tree_queue() -> bool:
	for identity_value: Variant in _source_capture_latest_by_chunk.values():
		var job: Dictionary = _source_capture_jobs.get(String(identity_value), {})
		if String(job.get("status", "")) == "pending" \
				and "trees" in job.get("requestedFamilies", []):
			return true
	return false


func source_domain_capture_pending_count() -> int:
	return _source_capture_pending_count()


func _publication_view_matches_snapshot(publication_view: Dictionary,
		snapshot: Dictionary) -> bool:
	return publication_view.is_read_only() \
		and String(publication_view.get("schema", "")) \
			== "ecology-source-publication-view/v1" \
		and is_same(publication_view.get("payload", {}), snapshot) \
		and String(publication_view.get("sourceDomainRevision", "")) \
			== String(snapshot.get("sourceRevision", "")) \
		and String(publication_view.get("contentDigest", "")).length() == 64 \
		and not String(publication_view.get("publicationId", "")).is_empty()


## Compile a non-tree producer row without a gameplay chunk owner. The returned
## member artifacts retain the exact `(sourceId, sourcePartId)` identity used by
## the support index and section candidate.
func _compile_non_tree_source_row(main: Object, snapshot: Dictionary,
		source_row: Dictionary, publication_view: Dictionary,
		publication_lease_token: String,
		fingerprint_cache: Dictionary = {}) -> Dictionary:
	var family := String(source_row.get("producerFamily", ""))
	var is_detail := family == "details"
	if not is_detail and family not in ["surface_rocks", "ore", "forage", "underground_props"]:
		return _pending("ecology_static_source_family_unknown", {"family":family})
	var source_id := String(source_row.get("sourceId", ""))
	var source_chunk_value: Variant = snapshot.get("sourceChunkKey", null)
	var source_domain_revision := String(snapshot.get("sourceDomainRevision", ""))
	var producer_snapshot_revision := String(source_row.get("producerSnapshotRevision", ""))
	var source_inputs_value: Variant = snapshot.get("sourceInputs", null)
	if source_id.is_empty() or not source_chunk_value is Vector2i \
			or source_domain_revision.is_empty() or producer_snapshot_revision.is_empty() \
			or not source_inputs_value is Dictionary:
		return _pending("ecology_static_source_provenance_missing", {"sourceId":source_id})
	var source_chunk: Vector2i = source_chunk_value
	var chunk_origin := Vector3(float(source_chunk.x) * Grid.STREAM_CHUNK_SIZE_METERS, 0.0,
		float(source_chunk.y) * Grid.STREAM_CHUNK_SIZE_METERS)
	var policy: Dictionary = publication_view.get("supportPolicy", {})
	var family_result: Dictionary = publication_view.get("familyResultsById", {}).get(
		family, {})
	var family_policy: Variant = publication_view.get("familySupportPoliciesById", {}).get(
		family, null)
	if not _publication_view_matches_snapshot(publication_view, snapshot) \
			or not ProducerDomainScript.validate_support_policy_certificate(policy) \
			or String(family_result.get("status", "")) != "ready" \
			or String(family_result.get("disposition", "")) \
				not in ["complete_nonempty", "complete_empty"] \
			or not family_policy is Dictionary \
			or String(family_policy.get("status", "")) != "ready":
		return _pending("ecology_static_source_family_policy_pending", {
			"sourceId":source_id, "family":family,
			"policyReason":String(policy.get("runtimePolicyReason", ""))})
	var snapshot_policy_revision := String(snapshot.get("influencePolicyRevision", ""))
	var snapshot_policy_digest := String(snapshot.get("influencePolicyDigest", ""))
	var family_revision := String(family_result.get("familyRevision", ""))
	var family_policy_revision := String(family_result.get("familyPolicyRevision", ""))
	var family_policy_digest := String(family_result.get("familyPolicyDigest", ""))
	var family_manifest_digest := String(family_result.get("sourceManifestDigest", ""))
	var family_policy_horizontal := float(family_policy.get(
		"maxHorizontalSupportMeters", -1.0))
	var family_policy_vertical := float(family_policy.get(
		"maxVerticalSupportMeters", -1.0))
	if snapshot_policy_revision.is_empty() or snapshot_policy_revision != String(policy.get("revision", "")) \
			or snapshot_policy_digest.length() != 64 \
			or snapshot_policy_digest != String(policy.get("digest", "")) \
			or family_revision.length() != 64 or producer_snapshot_revision != family_revision \
			or family_policy_revision.is_empty() \
			or family_policy_revision != String(family_policy.get("familyPolicyRevision", "")) \
			or family_policy_digest.length() != 64 \
			or family_policy_digest != String(family_policy.get("familyPolicyDigest", "")) \
			or not is_finite(family_policy_horizontal) or family_policy_horizontal < 0.0 \
			or not is_finite(family_policy_vertical) or family_policy_vertical < 0.0 \
			or family_manifest_digest.length() != 64:
		return _pending("ecology_static_source_policy_provenance_mismatch", {
			"sourceId":source_id, "family":family,
			"snapshotPolicyRevision":snapshot_policy_revision,
			"policyRevision":String(policy.get("revision", "")),
			"snapshotPolicyDigest":snapshot_policy_digest,
			"policyDigest":String(policy.get("digest", ""))})
	var producer_record_current: Variant = main.call(
		"ecology_source_publication_record_is_current", publication_view,
		publication_lease_token, source_row) \
		if main.has_method("ecology_source_publication_record_is_current") else null
	if not producer_record_current is Dictionary \
			or String(producer_record_current.get("status", "")) != "ready":
		if producer_record_current is Dictionary:
			var producer_current_reason := String(producer_record_current.get("reason", ""))
			if _source_currentness_reason_is_stale(producer_current_reason) \
					or String(producer_record_current.get("status", "")) in ["failed", "stale"]:
				return producer_record_current
			var current_pending: Dictionary = producer_record_current.duplicate(false)
			current_pending["sourceId"] = source_id
			current_pending["family"] = family
			return current_pending
		return _pending("ecology_static_source_currentness_unavailable", {
			"sourceId":source_id, "family":family})
	var body_transform := Transform3D.IDENTITY
	var members: Array = []
	if is_detail:
		var detail_transform: Variant = source_row.get("transform", null)
		var source_mesh_bounds: Variant = source_row.get("meshBounds", null)
		var bounds_value: Variant = source_row.get("localBounds", null)
		if not detail_transform is Transform3D or not source_mesh_bounds is AABB \
				or not bounds_value is AABB \
				or not _valid_transform(detail_transform) or not _valid_bounds(bounds_value):
			return _pending("ecology_detail_source_geometry_invalid", {"sourceId":source_id})
		var surface_index := int(source_row.get("surfaceIndex", -1))
		var detail_type := String(source_row.get("detailType", ""))
		var material_values: Variant = source_row.get("materials", null)
		if detail_type.is_empty() or not material_values is Array or material_values.size() != 1:
			return _pending("ecology_detail_source_material_identity_invalid", {"sourceId":source_id})
		var mesh_value: Variant
		var material_value: Variant
		if surface_index >= 0:
			mesh_value = main.call("detail_mesh_surface", detail_type, surface_index) \
				if main.has_method("detail_mesh_surface") else null
			material_value = main.call("detail_surface_material", detail_type, surface_index) \
				if main.has_method("detail_surface_material") else null
		else:
			mesh_value = main.call("detail_mesh", detail_type) \
				if main.has_method("detail_mesh") else null
			material_value = main.call("detail_material", detail_type) \
				if main.has_method("detail_material") else null
		if not mesh_value is Mesh or not material_value is Material \
				or String(material_values[0]) != _detail_material_key(main, detail_type, surface_index):
			return _pending("ecology_detail_source_resource_unavailable", {"sourceId":source_id})
		var mesh: Mesh = mesh_value
		var mesh_bounds := mesh.get_aabb()
		if not _valid_bounds(source_mesh_bounds) \
				or not mesh_bounds.is_equal_approx(source_mesh_bounds) \
				or not (detail_transform * source_mesh_bounds).is_equal_approx(bounds_value):
			return _failed("ecology_detail_source_bounds_disagree", {"sourceId":source_id})
		members.append({"memberId":"surface:%d" % surface_index,
			"mesh":mesh, "material":material_value,
			"meshBounds":mesh_bounds, "localBounds":bounds_value,
			"materialKey":String(material_values[0]),
			"sourceMeshContentDigest":String(source_row.get("meshContentDigest", "")),
			"sourceMaterialContentDigest":String(source_row.get("materialContentDigest", "")),
			"renderLayer":String(source_row.get("renderLayers", ["opaque"])[0]),
			"transform":detail_transform, "instanceTransform":detail_transform,
			"customData":source_row.get("customData", Color.TRANSPARENT),
			"instanceColor":source_row.get("instanceColor", Color.WHITE),
			"resourceDescriptorRevision":ProducerDomainScript.digest_value([
				"detail-resource/v1", detail_type, surface_index,
				String(source_row.get("meshSource", "")),
				String(material_values[0])])})
	else:
		var position_value: Variant = source_row.get("position", null)
		var rotation_value: Variant = source_row.get("bodyRotation", Vector3.ZERO)
		if not position_value is Vector3 or not rotation_value is Vector3:
			return _pending("ecology_static_source_transform_missing", {"sourceId":source_id})
		body_transform = Transform3D(Basis.from_euler(rotation_value), position_value)
		var member_values: Variant = source_row.get("renderMembers", null)
		if not member_values is Array or member_values.is_empty():
			return _pending("ecology_static_source_member_roster_missing", {
				"sourceId":source_id, "family":family})
		var asset_members_by_id := _current_rock_descriptor_members(main, source_row) \
			if family in ["surface_rocks", "underground_props"] \
					and not String(source_row.get("assetId", "")).is_empty() else {}
		for member_value: Variant in member_values:
			if not member_value is Dictionary:
				return _pending("ecology_static_source_member_invalid", {"sourceId":source_id})
			var source_member: Dictionary = member_value
			var member_id := String(source_member.get("memberId", ""))
			var mesh_result := _resolve_static_source_mesh(main, source_row,
				source_member, asset_members_by_id)
			if String(mesh_result.get("status", "")) != "ready": return mesh_result
			var material_value: Variant = mesh_result.get("material", null)
			var mesh_value: Variant = mesh_result.get("mesh", null)
			if member_id.is_empty() or not mesh_value is Mesh or not material_value is Material:
				return _pending("ecology_static_source_member_resource_invalid", {
					"sourceId":source_id, "sourcePartId":member_id})
			members.append({"memberId":member_id, "mesh":mesh_value,
				"material":material_value,
				"meshBounds":source_member.get("meshBounds", null),
				"localBounds":source_member.get("localBounds", null),
				"materialKey":String(mesh_result.get("materialKey",
					source_member.get("materialKey", ""))),
				"sourceMeshContentDigest":String(mesh_result.get("sourceMeshContentDigest", "")),
				"sourceMaterialContentDigest":String(mesh_result.get("sourceMaterialContentDigest", "")),
				"renderLayer":String(source_member.get("renderLayer", "")),
				"transform":source_member.get("transform", null),
				"instanceTransform":source_member.get("transform", null),
				"customData":Color.TRANSPARENT, "instanceColor":Color.WHITE,
				"resourceDescriptorRevision":String(mesh_result.get(
					"resourceDescriptorRevision", ""))})
	var artifacts: Array[Dictionary] = []
	var support_rows: Array[Dictionary] = []
	var seen_parts: Dictionary = {}
	for member in members:
		var part_id := String(member.get("memberId", ""))
		var mesh: Mesh = member.mesh
		var material: Material = member.material
		var member_transform_value: Variant = member.get("transform", null)
		if part_id.is_empty() or seen_parts.has(part_id) or not member_transform_value is Transform3D \
				or not _valid_transform(member_transform_value):
			return _pending("ecology_static_source_member_identity_or_transform_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
		seen_parts[part_id] = true
		var mesh_bounds := mesh.get_aabb()
		if not _valid_bounds(mesh_bounds):
			return _pending("ecology_static_source_mesh_bounds_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
		var mesh_fingerprint: Dictionary = _resource_fingerprint_for_census(
			mesh, fingerprint_cache, "mesh")
		var material_fingerprint: Dictionary = _resource_fingerprint_for_census(
			material, fingerprint_cache, "material")
		var material_digest := String(material_fingerprint.get("contentDigest", ""))
		var fingerprint := mesh_fingerprint
		var mesh_digest := String(fingerprint.get("contentDigest", ""))
		var declared_mesh_digest := String(member.get("sourceMeshContentDigest", ""))
		var declared_material_digest := String(member.get("sourceMaterialContentDigest", ""))
		var resource_revision := String(member.get("resourceDescriptorRevision", ""))
		if mesh_digest.length() != 64 or material_digest.length() != 64 \
				or resource_revision.length() != 64 \
				or declared_mesh_digest.length() != 64 \
				or declared_material_digest.length() != 64 \
				or mesh_digest != declared_mesh_digest \
				or material_digest != declared_material_digest:
			return _pending("ecology_static_source_resource_digest_unavailable", {
				"sourceId":source_id, "sourcePartId":part_id, "family":family,
				"materialClass":material.get_class(),
				"meshFingerprintStatus":String(fingerprint.get("status", "")),
				"meshContentDigest":mesh_digest,
				"declaredMeshContentDigest":declared_mesh_digest,
				"meshDigestLength":mesh_digest.length(),
				"declaredMeshDigestLength":declared_mesh_digest.length(),
				"meshDigestMatches":mesh_digest == declared_mesh_digest,
				"materialContentDigest":material_digest,
				"declaredMaterialContentDigest":declared_material_digest,
				"materialDigestLength":material_digest.length(),
				"declaredMaterialDigestLength":declared_material_digest.length(),
				"materialDigestMatches":material_digest == declared_material_digest,
				"resourceDescriptorRevisionLength":resource_revision.length()})
		var layer := _supported_ecology_layer(material, String(member.get("renderLayer", "")))
		if layer.is_empty():
			return _pending("ecology_static_source_render_layer_unsupported", {
				"sourceId":source_id, "sourcePartId":part_id})
		var world_transform := Transform3D.IDENTITY
		var instance_transform: Transform3D
		if is_detail:
			instance_transform = member_transform_value
			world_transform = Transform3D(Basis.IDENTITY, chunk_origin) * instance_transform
		else:
			instance_transform = body_transform * (member_transform_value as Transform3D)
			world_transform = Transform3D(Basis.IDENTITY, chunk_origin) * instance_transform
		var world_bounds := world_transform * mesh_bounds
		var source_origin_value: Variant = source_row.get("sourceOrigin", chunk_origin)
		if not source_origin_value is Vector3:
			return _pending("ecology_static_source_origin_invalid", {"sourceId":source_id})
		var bound_proof := ProducerDomainScript.validate_source_bounds(family,
			source_origin_value, world_bounds, policy)
		if String(bound_proof.get("status", "")) != "ready":
			return _pending("ecology_static_source_member_outside_policy", {
				"sourceId":source_id, "sourcePartId":part_id,
				"policyEvidence":bound_proof})
		var policy_revision := String(policy.get("revision", ""))
		var policy_digest := String(policy.get("digest", ""))
		var proof_digest := ProducerDomainScript.static_member_envelope_digest(_world_id,
			source_id, part_id, family, world_bounds, mesh_digest, policy_revision,
			policy_digest, source_domain_revision, producer_snapshot_revision,
			resource_revision)
		if proof_digest.length() != 64:
			return _pending("ecology_static_source_member_proof_digest_failed", {
				"sourceId":source_id, "sourcePartId":part_id})
		var custom_data: Variant = member.get("customData", Color.TRANSPARENT)
		var instance_color: Variant = member.get("instanceColor", Color.WHITE)
		if not custom_data is Color or not instance_color is Color:
			return _pending("ecology_static_source_instance_attributes_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
		var material_key := String(member.get("materialKey", ""))
		var member_content_revision := ProducerDomainScript.static_member_content_revision(
			_world_id, source_id, part_id, family, {
				"sourceChunkKey":source_chunk, "worldTransform":world_transform,
				"meshLocalBounds":mesh_bounds, "worldBounds":world_bounds,
				"meshContentDigest":mesh_digest,
				"materialContentDigest":material_digest,
				"materialKey":material_key, "renderLayer":layer,
				"resourceDescriptorRevision":resource_revision,
				"customData":custom_data, "instanceColor":instance_color,
				"visibilityRangeEnd":float(source_row.get("visibilityRangeEnd", 0.0))})
		if member_content_revision.length() != 64:
			return _pending("ecology_static_source_member_content_revision_failed", {
				"sourceId":source_id, "sourcePartId":part_id})
		var owner_section := Grid.key_for_world_position(world_bounds.get_center())
		var support_sections := Grid.keys_intersecting_bounds(world_bounds)
		support_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			if a.x != b.x: return a.x < b.x
			if a.y != b.y: return a.y < b.y
			return a.z < b.z)
		var proof := {"schema":SupportIndexScript.STATIC_MEMBER_ENVELOPE_SCHEMA,
			"status":"ready", "worldId":_world_id, "sourceId":source_id,
			"sourcePartId":part_id, "family":family,
			"familyRevision":family_revision,
			"familyPolicyRevision":family_policy_revision,
			"familyPolicyDigest":family_policy_digest,
			"familyManifestDigest":family_manifest_digest,
			"worldBounds":world_bounds, "meshContentDigest":mesh_digest,
			"policyRevision":policy_revision, "policyDigest":policy_digest,
			"sourceDomainRevision":source_domain_revision,
			"producerSnapshotRevision":producer_snapshot_revision,
			"resourceDescriptorRevision":resource_revision,
			"digest":proof_digest}
		var support_row := {"sourceId":source_id, "sourcePartId":part_id,
			"sourceRevision":member_content_revision,
			"memberContentRevision":member_content_revision,
			"memberId":part_id, "instanceIndex":0, "sourceInstance":0,
			"propId":String(source_row.get("propId", source_id)),
			"sourceSegmentId":"ecology-static:%s:%s" % [part_id, member_content_revision],
			"sourceOwnerChunk":source_chunk,
			"kind":"surface_detail" if is_detail else "static_prop",
			"family":family, "state":"compiled",
			"familyRevision":family_revision,
			"familyPolicyRevision":family_policy_revision,
			"familyPolicyDigest":family_policy_digest,
			"familyManifestDigest":family_manifest_digest,
			"sourceOrigin":source_origin_value,
			"conservativeWorldBounds":world_bounds,
			"geometryOwnerSection":owner_section,
			"conservativeSupportSectionKeys":support_sections,
			"meshContentDigest":mesh_digest,
			"resourceDescriptorRevision":resource_revision,
			"certifiedEnvelopeProof":proof,
			"certifiedEnvelopeDigest":proof_digest,
			"sourceDomainRevision":source_domain_revision,
			"producerSnapshotRevision":producer_snapshot_revision}
		support_row.make_read_only()
		support_rows.append(support_row)
		var compatibility := _compatibility(material_key, material_key,
			material_digest, "ecology.runtime.%s/v1" % mesh_digest, mesh_digest,
			PIPELINE_REVISION, layer, mesh_bounds, true,
			float(source_row.get("visibilityRangeEnd", 0.0)), 0.0)
		if compatibility.is_empty():
			return _pending("ecology_static_source_compatibility_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
		var input_transform := instance_transform
		var attribute_buffer := _encode_instance(input_transform,
			custom_data, instance_color)
		attribute_buffer.make_read_only()
		var member_input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"sourceId":source_id, "sourcePartId":part_id,
			"sourceRevision":member_content_revision,
			"sourceDomainRevision":source_domain_revision,
			"producerSnapshotRevision":producer_snapshot_revision,
			"ownerCell":source_chunk,
			"sourceToWorld":Transform3D(Basis.IDENTITY, chunk_origin),
			"meshLocalBounds":mesh_bounds,
			"batchKey":String(compatibility.get("batchKey", "")),
			"segmentId":"ecology-static-member:" + _value_digest([
				source_id, part_id, member_content_revision, compatibility.batchKey]),
			"buffer":attribute_buffer, "instanceCount":1,
			"sectionKey":owner_section, "compatibility":compatibility}
		member_input.make_read_only()
		var mesh_key := String(compatibility.meshResourceKey)
		var mat_key := String(compatibility.materialKey)
		var artifact := {"sourceId":source_id, "sourcePartId":part_id,
			"sourceRevision":member_content_revision,
			"memberContentRevision":member_content_revision,
			"sourceDomainRevision":source_domain_revision,
			"producerSnapshotRevision":producer_snapshot_revision,
			"sourceChunkKey":source_chunk, "producerRow":source_row,
			"snapshot":snapshot, "publicationView":publication_view,
			"publicationLeaseToken":publication_lease_token,
			"sourcePublicationId":String(publication_view.get("publicationId", "")),
			"supportRow":support_row,
			"geometryOwnerSection":owner_section, "input":member_input,
			"compatibility":compatibility, "meshKey":mesh_key, "materialKey":mat_key,
			"mesh":mesh, "material":material,
			"meshDigest":mesh_digest, "materialDigest":material_digest,
			"resourceDescriptorRevision":resource_revision,
			"assetId":String(source_row.get("assetId", ""))}
		artifacts.append(artifact)
	return {"status":"ready", "sourceId":source_id,
		"supportRows":support_rows, "memberArtifacts":artifacts}


func _detail_material_key(main: Object, detail_type: String, surface_index: int) -> String:
	if surface_index >= 0 and main.has_method("detail_surface_material_key"):
		return String(main.call("detail_surface_material_key", detail_type, surface_index))
	if main.has_method("detail_type_material_key"):
		return String(main.call("detail_type_material_key", detail_type))
	return ""


func _current_rock_descriptor_members(main: Object, source_row: Dictionary) -> Dictionary:
	var asset_id := String(source_row.get("assetId", ""))
	if asset_id.is_empty(): return {}
	var registry: Variant = main.get("visual_asset_registry")
	if not is_instance_valid(registry) or not registry.has_method(
			"describe_static_asset_without_instantiation") \
			or not registry.has_method("static_asset_descriptor_is_current"):
		return {}
	var descriptor: Dictionary = registry.call("describe_static_asset_without_instantiation", asset_id)
	if String(descriptor.get("status", "")) != "ready" \
			or not bool(registry.call("static_asset_descriptor_is_current", descriptor)):
		return {}
	var expected: Dictionary = source_row.get("assetDescriptorIdentity", {})
	var receipt: Dictionary = descriptor.get("registryReceipt", {})
	if String(expected.get("catalogContentDigest", "")) != String(descriptor.get("catalogContentDigest", "")) \
			or String(expected.get("sceneContentDigest", "")) != String(descriptor.get("sceneContentDigest", "")) \
			or String(expected.get("registryRevision", "")) != String(receipt.get("revision", "")):
		return {}
	var result: Dictionary = {}
	for value: Variant in descriptor.get("renderMembers", []):
		if value is Dictionary:
			result[String(value.get("memberId", ""))] = value
	return result


func _resolve_static_source_mesh(main: Object, source_row: Dictionary,
			source_member: Dictionary, rock_descriptor_members: Dictionary) -> Dictionary:
	var family := String(source_row.get("producerFamily", ""))
	var member_id := String(source_member.get("memberId", ""))
	var uses_rock_resource := family == "surface_rocks" \
		or (family == "underground_props" and (
			not String(source_row.get("assetId", "")).is_empty() \
			or String(source_member.get("primitive", "")) == "sphere"))
	if uses_rock_resource:
		if not String(source_row.get("assetId", "")).is_empty():
			var descriptor_member: Dictionary = rock_descriptor_members.get(member_id, {})
			if descriptor_member.is_empty() \
					or String(descriptor_member.get("meshContentDigest", "")) \
					!= String(source_member.get("meshContentDigest", "")) \
					or String(descriptor_member.get("materialContentDigest", "")) \
					!= String(source_member.get("materialContentDigest", "")):
				return _pending("ecology_rock_descriptor_member_stale", {
					"sourceId":String(source_row.get("sourceId", "")),
					"sourcePartId":member_id})
			return {"status":"ready", "mesh":descriptor_member.get("mesh"),
				"material":descriptor_member.get("material"),
				"materialKey":String(descriptor_member.get("materialKey", "")),
				"sourceMeshContentDigest":String(descriptor_member.get("meshContentDigest", "")),
				"sourceMaterialContentDigest":String(descriptor_member.get("materialContentDigest", "")),
				"resourceDescriptorRevision":ProducerDomainScript.digest_value([
					"static-asset-member/v1", source_row.get("assetDescriptorIdentity", {}),
					descriptor_member.get("meshContentDigest", ""),
					descriptor_member.get("materialContentDigest", "")])}
		if String(source_member.get("primitive", "")) == "sphere":
			var mesh := SphereMesh.new()
			mesh.radius = float(source_member.get("radius", 0.5))
			mesh.height = float(source_member.get("height", mesh.radius * 2.0))
			mesh.radial_segments = int(source_member.get("radialSegments", 18))
			mesh.rings = int(source_member.get("rings", 8))
			var materials_value: Variant = main.get("materials")
			var mats: Dictionary = materials_value if materials_value is Dictionary else {}
			return {"status":"ready", "mesh":mesh,
				"material":mats.get(String(source_member.get("materialKey", "rock"))),
				"materialKey":String(source_member.get("materialKey", "rock")),
				"sourceMeshContentDigest":String(source_member.get("meshContentDigest", "")),
				"sourceMaterialContentDigest":String(source_member.get("materialContentDigest", "")),
				"resourceDescriptorRevision":ProducerDomainScript.digest_value([
					"primitive-rock/v1", source_member.get("primitive", ""),
					source_member.get("radius", 0.0), source_member.get("height", 0.0),
					source_member.get("radialSegments", 0), source_member.get("rings", 0)])}
		return _pending("ecology_rock_asset_identity_unavailable", {
			"sourceId":String(source_row.get("sourceId", ""))})
	var recipe_value: Variant = source_member.get("meshRecipe", null)
	if not recipe_value is Dictionary or not main.has_method("_materialize_source_mesh"):
		return _pending("ecology_source_mesh_recipe_unavailable", {
			"sourceId":String(source_row.get("sourceId", "")), "sourcePartId":member_id})
	var mesh_value: Variant = main.call("_materialize_source_mesh", recipe_value)
	var materials_value: Variant = main.get("materials")
	var materials: Dictionary = materials_value if materials_value is Dictionary else {}
	var material_key := String(source_member.get("materialKey", ""))
	var material_value: Variant = materials.get(material_key, null)
	if not material_value is Material:
		for fallback_value: Variant in source_member.get("fallbackMaterialKeys", []):
			var fallback: Variant = materials.get(String(fallback_value), null)
			if fallback is Material:
				material_value = fallback
				material_key = String(fallback_value)
				break
	if not mesh_value is Mesh or not material_value is Material:
		return _pending("ecology_source_recipe_resource_unavailable", {
			"sourceId":String(source_row.get("sourceId", "")), "sourcePartId":member_id})
	return {"status":"ready", "mesh":mesh_value, "material":material_value,
		"materialKey":material_key,
		"sourceMeshContentDigest":String(source_member.get("meshContentDigest", "")),
		"sourceMaterialContentDigest":String(source_member.get("materialContentDigest", "")),
		"resourceDescriptorRevision":ProducerDomainScript.digest_value([
			"ecology-source-recipe-resource/v1", recipe_value, material_key,
			PIPELINE_REVISION])}


## Retained only while old authored/resident producers are being removed. The
## production roster no longer calls this resident-owner discovery path.
func _capture_resident_static_section_sources_legacy(world_id: String,
		requested_sections: Array) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty() or requested_sections.is_empty():
		return _pending("ecology_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ecology_section")
		sections.append(value)
	var required_chunks: Dictionary = {}
	for section: Vector3i in sections:
		for chunk: Vector2i in Grid.stream_chunk_keys_intersecting_section(section):
			required_chunks[chunk] = true
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable")
	var owner_discovery := _discover_static_prop_source_chunks(main, sections)
	if owner_discovery.get("status") != "ready":
		return owner_discovery
	for source_chunk: Vector2i in owner_discovery.get("sourceChunks", []):
		required_chunks[source_chunk] = true
	var chunk_keys: Array[Vector2i] = []
	for chunk_value: Variant in required_chunks:
		chunk_keys.append(Vector2i(chunk_value))
	chunk_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	var source_revisions: Dictionary = {}
	var members_by_section: Dictionary = {}
	var tombstone_revision_by_source: Dictionary = {}
	var current_static_prop_revision_by_source: Dictionary = {}
	var current_static_prop_source_by_prop_id: Dictionary = {}
	var authority_rows: Array = []
	var legacy_visual_units: Dictionary = {}
	var support_ranges_by_section: Dictionary = {}
	var trees_by_prop_id := _current_tree_publications(main)
	for chunk: Vector2i in chunk_keys:
		var production := _capture_production_chunk(chunk, false)
		if production.get("status") != "ready":
			return production
		var snapshot: Dictionary = production.snapshot
		var chunk_owner_ref := production.get("chunkOwner") as WeakRef
		var chunk_owner := chunk_owner_ref.get_ref() as Node3D \
			if chunk_owner_ref != null else null
		var removed_ids: Dictionary = production.get("removedPropIds", {})
		var chunk_owner_instance_id := int(production.get("chunkOwnerInstanceId", 0))
		var chunk_to_world: Transform3D = production.get("chunkToWorld", Transform3D.IDENTITY)
		var chunk_candidates: Variant = snapshot.get("candidates", null)
		if not chunk_candidates is Array:
			return _pending("ecology_candidate_membership_snapshot_missing", {"chunk":chunk})
		var category_missing := _missing_categories(snapshot,
			bool(production.get("undergroundRequired", true)))
		if not category_missing.is_empty():
			return _pending("ecology_static_category_coverage_incomplete", {
				"chunk":chunk, "missingCategories":category_missing,
				"categoryEvidence":_missing_category_evidence(snapshot, category_missing)})
		var scoped_removal_snapshot: Dictionary = production.get("removedSnapshot", {})
		var removal_identity := String(scoped_removal_snapshot.get("contentIdentity", ""))
		if removal_identity.is_empty():
			return _pending("ecology_removed_props_snapshot_identity_missing", {"chunk":chunk})
		authority_rows.append([[chunk.x, chunk.y], chunk_owner_instance_id,
			String(snapshot.get("contentRevision", "")),
			String(snapshot.get("sourceRevision", "")), removal_identity])
		for candidate_value: Variant in snapshot.get("candidates", []):
			if not candidate_value is Dictionary:
				return _pending("ecology_candidate_record_invalid", {"chunk":chunk})
			var candidate: Dictionary = candidate_value
			var candidate_kind := String(candidate.get("kind", ""))
			if candidate_kind == "realized_static_prop" \
					and String(candidate.get("category", "")) == "underground_props" \
					and not bool(production.get("undergroundRequired", true)):
				continue
			var source_id := String(candidate.get("sourceId", ""))
			var prop_id := String(candidate.get("propId", ""))
			# _capture_production_chunk validated every candidate digest before
			# returning this immutable source snapshot. Do not canonicalize/hash
			# the same records again while assigning them to section owners.
			if source_id.is_empty() or String(candidate.get("contentRevision", "")).is_empty():
				return _pending("ecology_candidate_membership_revision_invalid", {
					"chunk":chunk, "sourceId":source_id})
			if not prop_id.is_empty() and removed_ids.has(prop_id):
				tombstone_revision_by_source[source_id] = _value_digest([
					"ecology-removed-source/v1", world_id, source_id, prop_id])
				continue
			var candidate_revision := ""
			var candidate_sections: Array[Vector3i] = []
			var candidate_support_ranges: Dictionary = {}
			match candidate_kind:
				"surface_detail":
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					var detail_mesh_value: Variant = _detail_candidate_mesh_if_current(main, candidate)
					if not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value) \
							or not detail_mesh_value is Mesh:
						return _pending("ecology_surface_detail_candidate_uncompiled", {
							"chunk":chunk, "sourceId":source_id})
					# Match partition ownership from the exact source mesh bounds.
					# Reversing the producer's transformed AABB is lossy for transformed bounds.
					candidate_sections.append(_surface_detail_census_section_key(
						detail_mesh_value as Mesh, chunk_to_world, transform_value))
					candidate_revision = _value_digest([
						"ecology-section-member/v1", world_id,
						String(snapshot.get("sourceRevision", "")),
						String(candidate.get("contentRevision", ""))])
				"realized_static_prop":
					var status := String(candidate.get("renderStatus", ""))
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					var category := String(candidate.get("category", ""))
					if status != "ready" or category not in STATIC_PROP_CATEGORIES \
							or not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value) \
							or not _static_prop_member_values_valid(candidate) \
							or not _static_prop_resources_are_renderable(
								production.get("resourceBindings", {}), candidate):
						return _pending("ecology_static_prop_candidate_incomplete", {
							"chunk":chunk, "sourceId":source_id})
					var support_capture := _static_prop_support_ranges(snapshot, candidate,
						chunk_to_world, production.get("resourceBindings", {}), world_id)
					if support_capture.get("status") != "ready":
						return support_capture
					candidate_support_ranges = support_capture.get("supportRangesBySection", {})
					for support_section_value: Variant in candidate_support_ranges:
						var support_section: Vector3i = support_section_value
						if support_section not in candidate_sections:
							candidate_sections.append(support_section)
					candidate_revision = _static_prop_source_revision(world_id, snapshot,
						candidate)
				"trees_foliage":
					if not _tree_family_proof_valid(snapshot):
						return _pending("ecology_tree_family_membership_proof_unavailable", {"chunk":chunk})
					var transform_value: Variant = candidate.get("transform", null)
					var bounds_value: Variant = candidate.get("localBounds", null)
					if not transform_value is Transform3D or not _valid_transform(transform_value) \
							or not bounds_value is AABB or not _valid_bounds(bounds_value):
						return _pending("ecology_tree_membership_bounds_unavailable", {
							"chunk":chunk, "sourceId":source_id})
					var candidate_world_bounds: AABB = chunk_to_world \
						* (transform_value as Transform3D) * (bounds_value as AABB)
					if not _tree_candidate_bounds_intersect_sections(candidate_world_bounds, sections):
						continue
					var tree_prop_id := String(candidate.get("propId", ""))
					var tree_publication: Dictionary = trees_by_prop_id.get(tree_prop_id, {})
					var tree_revision := _tree_census_source_revision(candidate,
						tree_publication)
					if tree_revision.is_empty():
						return _pending("ecology_tree_queue_geometry_not_committed", {
							"chunk":chunk, "sourceId":source_id,
							"candidateWorldBounds":candidate_world_bounds,
							"requestedSections":sections.duplicate()})
					candidate_sections = _tree_census_section_keys(tree_publication)
					if candidate_sections.is_empty():
						return _pending("ecology_tree_queue_geometry_not_committed", {
							"chunk":chunk, "sourceId":source_id})
					var tree_support_capture := _compiled_tree_support_ranges(
						tree_publication, source_id, tree_revision)
					if tree_support_capture.get("status") != "ready":
						return tree_support_capture
					candidate_support_ranges = tree_support_capture.get(
						"supportRangesBySection", {})
					candidate_revision = tree_revision
					_latest_tree_candidate_by_source[source_id] = candidate
				"_":
					return _pending("ecology_candidate_kind_not_censusable", {
						"chunk":chunk, "sourceId":source_id, "kind":candidate_kind})
			if candidate_sections.is_empty():
				return _pending("ecology_candidate_membership_bounds_empty", {
					"chunk":chunk, "sourceId":source_id})
			if candidate_kind == "realized_static_prop":
				if current_static_prop_revision_by_source.has(source_id) \
						and String(current_static_prop_revision_by_source[source_id]) != candidate_revision:
					return _pending("ecology_static_prop_source_revision_ambiguous", {
						"sourceId":source_id})
				current_static_prop_revision_by_source[source_id] = candidate_revision
				var candidate_prop_id := String(candidate.get("propId", ""))
				var prior_prop_identity: Dictionary = current_static_prop_source_by_prop_id.get(
					candidate_prop_id, {})
				if candidate_prop_id.is_empty() or not prior_prop_identity.is_empty() \
						and (String(prior_prop_identity.get("sourceId", "")) != source_id \
						or String(prior_prop_identity.get("sourceRevision", "")) != candidate_revision):
					return _pending("ecology_static_prop_prop_identity_ambiguous", {
						"propId":candidate_prop_id, "sourceId":source_id})
				current_static_prop_source_by_prop_id[candidate_prop_id] = {
					"sourceId":source_id, "sourceRevision":candidate_revision}
			if candidate_kind in ["realized_static_prop", "trees_foliage"]:
				for support_section_value: Variant in candidate_support_ranges:
					var support_section: Vector3i = support_section_value
					if support_section not in sections:
						continue
					if not support_ranges_by_section.has(support_section):
						support_ranges_by_section[support_section] = {}
					var section_supports: Dictionary = support_ranges_by_section[support_section]
					var source_supports: Array = section_supports.get(source_id, [])
					for support_row_value: Variant in candidate_support_ranges[support_section]:
						var support_row: Dictionary = support_row_value.duplicate(false)
						support_row["sourceRevision"] = candidate_revision
						support_row.make_read_only()
						source_supports.append(support_row)
					section_supports[source_id] = source_supports
			if candidate_kind == "surface_detail":
				var detail_type := String(candidate.get("detailType", ""))
				var detail_unit_id := "decor:%d,%d:%s" % [chunk.x, chunk.y, detail_type]
				var detail_target := _find_detail_batch_target(chunk_owner, detail_type)
				if is_instance_valid(detail_target):
					for detail_section: Vector3i in candidate_sections:
						_record_legacy_visual_unit(legacy_visual_units, detail_unit_id,
							"decorative_detail", source_id, candidate_revision,
							detail_section, detail_target, chunk, chunk_owner)
			elif candidate_kind == "realized_static_prop":
				var prop_unit_id := "prop:%s" % source_id
				var prop_targets := _find_static_prop_visual_targets(chunk_owner, source_id)
				if not prop_targets.is_empty():
					for prop_section: Vector3i in candidate_sections:
						_record_legacy_visual_unit(legacy_visual_units, prop_unit_id,
							"static_prop", source_id, candidate_revision,
							prop_section, prop_targets, chunk, chunk_owner)
			for section_key: Vector3i in candidate_sections:
				if section_key in sections:
					if not _append_section_member(members_by_section, source_revisions,
						section_key, source_id, candidate_revision):
						return _failed("ecology_section_source_revision_conflict")
		for tombstone_value: Variant in snapshot.get("tombstones", []):
			if tombstone_value is Dictionary:
				var tombstone_source_id := String(tombstone_value.get("sourceId", ""))
				if not tombstone_source_id.is_empty():
					tombstone_revision_by_source[tombstone_source_id] = _value_digest([
						"ecology-tombstone/v1", world_id, tombstone_source_id,
						String(tombstone_value.get("reason", ""))])
		if not _production_chunk_owner_is_current(main, chunk, production):
			return _pending("ecology_chunk_owner_changed_during_census", {"chunk":chunk})
	var section_rows: Dictionary = {}
	var removals_by_section: Dictionary = {}
	var removal_revisions_by_section: Dictionary = {}
	var support_footprint_removal_revisions_by_section: Dictionary = {}
	var current_by_section: Dictionary = {}
	for section: Vector3i in sections:
		var prior_support_value: Variant = _latest_support_ranges_by_section.get(section, {})
		var current_removed_props: Variant = main.get("removed_props")
		if not prior_support_value is Dictionary or not current_removed_props is Dictionary:
			return _pending("ecology_support_source_replay_authority_unavailable", {
				"section":section})
		for prior_source_value: Variant in prior_support_value:
			var prior_source_id := String(prior_source_value)
			if members_by_section.get(section, []).has(prior_source_id) \
					or tombstone_revision_by_source.has(prior_source_id):
				continue
			var prior_rows: Variant = prior_support_value[prior_source_value]
			if not prior_rows is Array or prior_rows.is_empty():
				return _pending("ecology_support_source_replay_proof_invalid", {
					"section":section, "sourceId":prior_source_id})
			var prior_prop_id := String(prior_rows[0].get("propId", ""))
			var replacement_source: Dictionary = current_static_prop_source_by_prop_id.get(
				prior_prop_id, {})
			var replacement_source_id := String(replacement_source.get("sourceId", ""))
			var replacement_source_revision := String(replacement_source.get("sourceRevision", ""))
			if not replacement_source_id.is_empty() and not replacement_source_revision.is_empty():
				var replacement_support_by_source: Dictionary = support_ranges_by_section.get(
					section, {})
				var replacement_rows: Array = replacement_support_by_source.get(
					replacement_source_id, [])
				var footprint_removal_revision := _support_footprint_removal_revision(
					world_id, section, prior_source_id, prior_rows,
					replacement_source_id, replacement_rows,
					replacement_source_revision)
				if footprint_removal_revision.is_empty():
					return _pending("ecology_support_footprint_diff_proof_invalid", {
						"section":section, "sourceId":prior_source_id})
				if not support_footprint_removal_revisions_by_section.has(section):
					support_footprint_removal_revisions_by_section[section] = {}
				support_footprint_removal_revisions_by_section[section][prior_source_id] = \
					footprint_removal_revision
				continue
			var prop_id := prior_prop_id
			if prop_id.is_empty() or not current_removed_props.has(prop_id):
				return _pending("ecology_support_source_owner_unavailable", {
					"section":section, "sourceId":prior_source_id,
					"propId":prop_id})
			tombstone_revision_by_source[prior_source_id] = _value_digest([
				"ecology-removed-source/v1", world_id, prior_source_id, prop_id,
				int(main.get("removed_props_revision"))])
		var ids: Array = members_by_section.get(section, []).duplicate()
		ids.sort()
		ids.make_read_only()
		var digest_rows: Array = []
		for source_id: String in ids:
			digest_rows.append([source_id, String(source_revisions.get(source_id, ""))])
		var section_support_value: Variant = support_ranges_by_section.get(section, {})
		if not section_support_value is Dictionary:
			return _failed("ecology_support_section_map_invalid")
		var section_supports: Dictionary = section_support_value
		var ordered_support_ids: Array[String] = []
		for support_source_value: Variant in section_supports:
			ordered_support_ids.append(String(support_source_value))
		ordered_support_ids.sort()
		for support_source_id: String in ordered_support_ids:
			var support_rows: Array = section_supports[support_source_id]
			support_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if String(a.get("memberId", "")) != String(b.get("memberId", "")):
					return String(a.get("memberId", "")) < String(b.get("memberId", ""))
				return String(a.get("sourceSegmentId", "")) < String(b.get("sourceSegmentId", "")))
			support_rows.make_read_only()
			digest_rows.append(["support", support_source_id, support_rows])
		section_supports.make_read_only()
		var coverage_revision := _value_digest([SCHEMA, world_id, section, digest_rows, authority_rows])
		section_rows[section] = {"status":"empty" if ids.is_empty() else "complete",
			"sourcePartIds":ids, "coverageRevision":coverage_revision}
		current_by_section[section] = source_revisions_for_ids(ids, source_revisions)
		var pending_removals: Dictionary = _pending_legacy_removal_revisions_by_section.get(
			section, {}).duplicate(false)
		for source_id_value: Variant in ids:
			pending_removals.erase(String(source_id_value))
		var previous: Dictionary = _latest_by_section.get(section, {})
		for old_source_id_value: Variant in previous.keys():
			var old_source_id := String(old_source_id_value)
			if ids.has(old_source_id):
				continue
			var removal_revision := String(tombstone_revision_by_source.get(old_source_id, ""))
			if removal_revision.is_empty():
				removal_revision = String(support_footprint_removal_revisions_by_section
					.get(section, {}).get(old_source_id, ""))
			if removal_revision.is_empty():
				removal_revision = _authoritative_section_removal_revision(world_id,
					section, old_source_id, String(previous.get(old_source_id, "")),
					String(source_revisions.get(old_source_id, "")), authority_rows)
			pending_removals[old_source_id] = removal_revision
		# A visual unit may cover sections outside the last requested census. Its
		# immutable prior membership is sufficient to know those sections need an
		# explicit current removal receipt; absence of a live node is never used.
		for prior_unit_value: Variant in _latest_legacy_visual_units.values():
			if not prior_unit_value is Dictionary:
				continue
			var prior_unit: Dictionary = prior_unit_value
			var prior_section_sources: Dictionary = prior_unit.get(
				"sourceRevisionsBySection", {}).get(section, {})
			for source_id_value: Variant in prior_section_sources:
				var prior_source_id := String(source_id_value)
				if ids.has(prior_source_id) or pending_removals.has(prior_source_id):
					continue
				var prior_source_revision := String(prior_section_sources.get(
					prior_source_id, ""))
				var removal_revision := String(tombstone_revision_by_source.get(
					prior_source_id, ""))
				if removal_revision.is_empty():
					removal_revision = String(support_footprint_removal_revisions_by_section
						.get(section, {}).get(prior_source_id, ""))
				if removal_revision.is_empty():
					removal_revision = _authoritative_section_removal_revision(world_id,
						section, prior_source_id, prior_source_revision,
						String(source_revisions.get(prior_source_id, "")), authority_rows)
				pending_removals[prior_source_id] = removal_revision
		var removals: Array[Dictionary] = []
		var ordered_removal_ids: Array[String] = []
		for source_id_value: Variant in pending_removals:
			ordered_removal_ids.append(String(source_id_value))
		ordered_removal_ids.sort()
		for old_source_id: String in ordered_removal_ids:
			return _pending("ecology_legacy_tombstone_member_identity_unproven", {
				"sourceId":old_source_id, "sectionKey":section,
				"removalRevision":String(pending_removals[old_source_id])})
		removal_revisions_by_section[section] = pending_removals
		removals_by_section[section] = removals
	var authority_revision := _value_digest([SCHEMA, world_id, authority_rows, section_rows])
	# Join removals to the last captured visual unit. The old unit's render targets
	# remain owned until an explicit replacement receipt arrives for each section
	# it previously contributed to.
	for unit_id_value: Variant in _latest_legacy_visual_units:
		var unit_id := String(unit_id_value)
		var prior_unit: Dictionary = _latest_legacy_visual_units[unit_id]
		var unit: Dictionary = legacy_visual_units.get(unit_id, {})
		var prior_removed: Dictionary = prior_unit.get("removalRevisionsBySection", {})
		var removed_by_section: Dictionary = unit.get("removalRevisionsBySection", {})
		var prior_owner_is_current := _legacy_visual_unit_owner_is_current(prior_unit, main)
		var current_owner_id := int(unit.get("chunkOwnerInstanceId", 0))
		var prior_owner_id := int(prior_unit.get("chunkOwnerInstanceId", 0))
		var owner_matches := prior_owner_is_current and (current_owner_id == 0 \
			or current_owner_id == prior_owner_id)
		if not owner_matches:
			continue
		for prior_section_value: Variant in prior_removed:
			var prior_section := Vector3i(prior_section_value)
			# A partial capture says nothing about sections it did not census.
			# Keep their previously authenticated removal rows until that exact
			# section is captured again and can confirm or invalidate the revision.
			if not removal_revisions_by_section.has(prior_section):
				removed_by_section[prior_section] = prior_removed[prior_section_value].duplicate(false)
				continue
			var active_removals: Dictionary = removal_revisions_by_section.get(prior_section, {})
			var known_sources: Dictionary = current_by_section.get(prior_section,
				_latest_by_section.get(prior_section, {}))
			var current_unit_sources: Dictionary = unit.get(
				"sourceRevisionsBySection", {}).get(prior_section, {})
			var retained: Dictionary = {}
			var prior_row: Dictionary = prior_removed[prior_section_value]
			for source_id_value: Variant in prior_row:
				var source_id := String(source_id_value)
				var prior_removal_revision := String(prior_row[source_id])
				if known_sources.has(source_id) or current_unit_sources.has(source_id) \
						or String(active_removals.get(source_id, "")) != prior_removal_revision:
					continue
				retained[source_id] = prior_removal_revision
			if not retained.is_empty():
				removed_by_section[prior_section] = retained
		for section_value: Variant in removal_revisions_by_section:
			var removal_section := Vector3i(section_value)
			var section_removals: Dictionary = removal_revisions_by_section[section_value]
			var prior_sources: Dictionary = prior_unit.get("sourceRevisionsBySection", {}).get(
				removal_section, {})
			var retained_prior_row: Dictionary = prior_removed.get(removal_section, {})
			for source_id_value: Variant in section_removals:
				var source_id := String(source_id_value)
				if not prior_sources.has(source_id) and not retained_prior_row.has(source_id):
					continue
				var updated_row: Dictionary = removed_by_section.get(removal_section, {})
				updated_row[source_id] = String(section_removals[source_id])
				removed_by_section[removal_section] = updated_row
		if removed_by_section.is_empty():
			continue
		if unit.is_empty():
			unit = _duplicate_legacy_visual_unit(prior_unit)
			var current_unit_sources: Dictionary = unit.get("sourceRevisions", {})
			var current_unit_sections: Dictionary = unit.get("sourceRevisionsBySection", {})
			for removed_section_value: Variant in removed_by_section:
				var removed_section := Vector3i(removed_section_value)
				var removed_row: Dictionary = removed_by_section[removed_section_value]
				var section_row: Dictionary = current_unit_sections.get(removed_section, {})
				for removed_source_value: Variant in removed_row:
					var removed_source_id := String(removed_source_value)
					section_row.erase(removed_source_id)
					current_unit_sources.erase(removed_source_id)
				current_unit_sections[removed_section] = section_row
			unit["sourceRevisions"] = current_unit_sources
			unit["sourceRevisionsBySection"] = current_unit_sections
		var required: Array = unit.get("requiredSections", [])
		for prior_section_value: Variant in prior_unit.get("requiredSections", []):
			if prior_section_value is Vector3i and not required.has(prior_section_value):
				required.append(prior_section_value)
		unit["requiredSections"] = required
		unit["removalRevisionsBySection"] = removed_by_section
		var base_revision := String(prior_unit.get("baseUnitRevision", ""))
		if base_revision.is_empty():
			base_revision = String(prior_unit.get("unitRevision", ""))
		unit["baseUnitRevision"] = base_revision
		unit["unitRevision"] = _legacy_visual_unit_revision(unit_id,
			String(unit.get("kind", "")), unit.get("sourceRevisions", {}),
			required, int(unit.get("chunkOwnerInstanceId", 0)),
			removed_by_section, base_revision)
		legacy_visual_units[unit_id] = unit
	for unit_id_value: Variant in legacy_visual_units:
		var unit: Dictionary = legacy_visual_units[String(unit_id_value)]
		_seal_legacy_visual_unit(unit)
	var requested_source_revisions: Dictionary = {}
	for section: Vector3i in sections:
		for source_id_value: Variant in members_by_section.get(section, []):
			var source_id := String(source_id_value)
			if source_revisions.has(source_id):
				requested_source_revisions[source_id] = source_revisions[source_id]
	for section: Vector3i in sections:
		_latest_by_section[section] = current_by_section.get(section, {})
		_latest_coverage_by_section[section] = String(section_rows[section].get(
			"coverageRevision", ""))
		_latest_support_ranges_by_section[section] = support_ranges_by_section.get(section, {})
		_pending_legacy_removal_revisions_by_section[section] = removal_revisions_by_section.get(
			section, {}).duplicate(false)
	for unit_id_value: Variant in legacy_visual_units:
		var unit_id := String(unit_id_value)
		var unit: Dictionary = legacy_visual_units[unit_id]
		var prior: Dictionary = _latest_legacy_visual_units.get(unit_id, {})
		if String(prior.get("unitRevision", "")) != String(unit.get("unitRevision", "")):
			_legacy_visual_install_receipts_by_unit.erase(unit_id)
		_latest_legacy_visual_units[unit_id] = unit
	section_rows.make_read_only()
	requested_source_revisions.make_read_only()
	removals_by_section.make_read_only()
	support_ranges_by_section.make_read_only()
	return {"status":"complete", "schema":SCHEMA, "providerId":PROVIDER_ID,
		"worldId":world_id, "authorityRevision":authority_revision,
		"sections":section_rows, "sourceRevisions":requested_source_revisions,
		"preparedSections":{}, "removalsBySection":removals_by_section,
		"supportRangesBySection":support_ranges_by_section}


func _capture_nonresident_static_section_sources(world_id: String,
		requested_sections: Array, metrics: Dictionary) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty() or requested_sections.is_empty():
		return _pending("ecology_provider_world_or_query_invalid")
	var seen: Dictionary = {}
	for section_value: Variant in requested_sections:
		if not section_value is Vector3i or seen.has(section_value):
			return _failed("invalid_or_duplicate_ecology_section")
		seen[section_value] = true
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not main.has_method("capture_ecology_source_domain"):
		return _pending("ecology_nonresident_source_domain_capture_unavailable")
	var camera_position := _current_capture_camera_position(main)
	var all_sections: Array[Vector3i] = []
	for section_value: Variant in requested_sections:
		var section_key := Vector3i(section_value)
		all_sections.append(section_key)
		_upsert_source_capture_cohort(section_key,
			_capture_cohort_camera_priority(section_key, camera_position))
	_promote_source_capture_cohorts()
	var has_active_cohort := false
	var all_source_cohorts_complete := true
	var active_sections: Array[Vector3i] = []
	for section_key: Vector3i in all_sections:
		var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
		var status := String(cohort.get("status", ""))
		if status == "active":
			has_active_cohort = true
			active_sections.append(section_key)
		elif status != "complete":
			all_source_cohorts_complete = false
	if not has_active_cohort and not all_source_cohorts_complete:
		var cached_failure := _cached_source_capture_failure(all_sections)
		if not cached_failure.is_empty():
			cached_failure["requestedSectionCount"] = all_sections.size()
			cached_failure["activeCohortCount"] = _source_capture_active_cohort_count
			cached_failure["serviceOpportunities"] = _source_capture_service_opportunities
			return cached_failure
		return _pending("ecology_section_capture_cohort_deferred", {
			"requestedSectionCount":all_sections.size(),
			"activeCohortCount":_source_capture_active_cohort_count,
			"serviceOpportunities":_source_capture_service_opportunities})
	if String(main.get("seed_text")) == "":
		return _pending("ecology_source_seed_unavailable")
	var scope: Dictionary = {}
	if not is_instance_valid(main) or not main.has_method("begin_ecology_source_catalog_context_scope") \
			or not main.has_method("end_ecology_source_catalog_context_scope"):
		for section_key: Vector3i in active_sections:
			_yield_source_capture_cohort(section_key,
				"ecology_source_catalog_scope_protocol_unavailable")
		return _pending("ecology_source_catalog_scope_protocol_unavailable")
	scope = main.call("begin_ecology_source_catalog_context_scope")
	if scope.get("status") != "ready":
		for section_key: Vector3i in active_sections:
			_yield_source_capture_cohort(section_key,
				String(scope.get("reason", "ecology_source_catalog_scope_pending")))
		return scope
	var result := _capture_nonresident_static_section_sources_in_scope(world_id,
		requested_sections, metrics)
	if not scope.is_empty():
		var ended: Dictionary = main.call("end_ecology_source_catalog_context_scope", scope)
		if ended.get("status") != "ready": return ended
	if String(result.get("status", "")) == "pending" \
			and String(result.get("reason", "")) not in [
				"ecology_source_capture_queued", "ecology_section_preparation_pending",
				"ecology_section_preparation_stale_requeued"]:
		for section_key: Vector3i in active_sections:
			_yield_source_capture_cohort(section_key,
				String(result.get("reason", "ecology_source_dependency_pending")))
	elif String(result.get("status", "")) == "failed":
		for section_key: Vector3i in active_sections:
			var cohort: Dictionary = _source_capture_cohorts.get(section_key, {})
			_set_source_capture_cohort_status(section_key, cohort, "failed")
			cohort["blockedReason"] = String(result.get("reason", "source_capture_failed"))
			cohort["cachedFailureReason"] = String(result.get("reason",
				"source_capture_failed"))
			cohort["cachedFailureDetails"] = result.duplicate(true)
			_source_capture_cohorts[section_key] = cohort
		_promote_source_capture_cohorts()
		if not active_sections.is_empty():
			return _retryable_source_capture_failure(result, active_sections[0])
	return result


func _tree_compile_consumer_token(capture_identity: String,
		section_key: Vector3i) -> String:
	return "ecology-tree-section-demand|%d|%s|%d,%d,%d" % [get_instance_id(),
		capture_identity, section_key.x, section_key.y, section_key.z]


func _cancel_tree_compile_demand(demand: Dictionary) -> void:
	var job_key := String(demand.get("jobKey", ""))
	var consumer_token := String(demand.get("consumerToken", ""))
	if job_key.is_empty() or consumer_token.is_empty():
		return
	var queue: Variant = null
	var queue_ref: Variant = demand.get("queueRef", null)
	if queue_ref is WeakRef:
		queue = queue_ref.get_ref()
	if not is_instance_valid(queue):
		var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
		queue = main.get("tree_publication_queue") if is_instance_valid(main) else null
	if not is_instance_valid(queue):
		return
	if String(demand.get("compileKind", "")) == "tree_band":
		if queue.has_method("cancel_ecology_tree_source_band_compile"):
			queue.call("cancel_ecology_tree_source_band_compile", job_key,
				consumer_token)
	elif queue.has_method("cancel_ecology_tree_source_compile"):
		queue.call("cancel_ecology_tree_source_compile", job_key, consumer_token)


func _detach_tree_compile_demand_for_section(job: Dictionary,
		section_key: Vector3i) -> void:
	var demands_value: Variant = job.get("treeCompileDemands", {})
	if not demands_value is Dictionary:
		return
	var demands: Dictionary = demands_value
	for demand_key_value: Variant in demands.keys():
		var demand_key := String(demand_key_value) \
			if demand_key_value is String else ""
		var demand_value: Variant = demands.get(demand_key_value, null)
		if not demand_value is Dictionary:
			continue
		var demand_section_value: Variant = demand_value.get(
			"sectionKey", demand_key_value)
		if not demand_section_value is Vector3i \
				or demand_section_value != section_key:
			continue
		_cancel_tree_compile_demand(demand_value)
		demands.erase(demand_key_value)
	job["treeCompileDemands"] = demands


func _tree_compile_demand_for_capture(capture_identity: String,
		section_keys: Array) -> Dictionary:
	var job: Dictionary = _source_capture_jobs.get(capture_identity, {})
	if job.is_empty() or String(job.get("status", "")) != "ready":
		return {}
	var snapshot_value: Variant = job.get("snapshot", null)
	var view_value: Variant = job.get("sourcePublicationView", null)
	if not snapshot_value is Dictionary or not view_value is Dictionary \
			or not _publication_view_matches_snapshot(view_value, snapshot_value):
		return {}
	var expected_tree: Dictionary = view_value.get("familyResultsById", {}).get("trees", {})
	var demands_value: Variant = job.get("treeCompileDemands", {})
	if not demands_value is Dictionary:
		return {}
	var demands: Dictionary = demands_value
	for section_value: Variant in section_keys:
		if not section_value is Vector3i:
			continue
		var section_key: Vector3i = section_value
		if not (job.get("sections", {}) as Dictionary).has(section_key):
			continue
		var demand_value: Variant = demands.get(section_key, null)
		if demand_value is Dictionary \
				and not String(demand_value.get("jobKey", "")).is_empty() \
				and not String(demand_value.get("consumerToken", "")).is_empty() \
				and String(demand_value.get("treeFamilyRevision", "")) \
					== String(expected_tree.get("familyRevision", "")) \
				and String(demand_value.get("treeFamilyManifestDigest", "")) \
					== String(expected_tree.get("sourceManifestDigest", "")) \
				and String(demand_value.get("sourcePublicationId", "")) \
					== String(view_value.get("publicationId", "")):
			return demand_value
	return {}


func _poll_tree_compile_demand(queue: Object, demand: Dictionary) -> Dictionary:
	var job_key := String(demand.get("jobKey", ""))
	var consumer_token := String(demand.get("consumerToken", ""))
	var demand_queue: Variant = queue
	var queue_ref: Variant = demand.get("queueRef", null)
	if queue_ref is WeakRef:
		demand_queue = queue_ref.get_ref()
		if not is_instance_valid(demand_queue):
			return _pending("ecology_source_compile_job_missing", {"jobKey":job_key})
		if not is_same(demand_queue, queue):
			return _pending("ecology_source_compile_queue_replaced", {"jobKey":job_key})
	if job_key.is_empty() or consumer_token.is_empty() \
			or not is_instance_valid(demand_queue) \
			or not demand_queue.has_method("poll_ecology_tree_source_compile"):
		return _pending("ecology_tree_source_compile_demand_invalid")
	var compiled_value: Variant = demand_queue.call("poll_ecology_tree_source_compile",
		job_key, consumer_token)
	if not compiled_value is Dictionary:
		return _pending("ecology_tree_source_compile_poll_invalid", {
			"jobKey":job_key})
	var compiled: Dictionary = compiled_value
	if String(compiled.get("status", "")) == "failed":
		return _failed(String(compiled.get("reason",
			"ecology_tree_source_compile_failed")), {"jobKey":job_key})
	if String(compiled.get("status", "")) != "ready":
		return _pending(String(compiled.get("reason",
			"ecology_tree_source_compile_pending")), {"jobKey":job_key,
			"retryable":bool(compiled.get("retryable", true))})
	var artifact_value: Variant = compiled.get("artifact", null)
	if not artifact_value is Dictionary or not artifact_value.is_read_only():
		return _failed("ecology_tree_source_compile_artifact_unsealed", {
			"jobKey":job_key})
	return {"status":"ready", "jobKey":job_key, "artifact":artifact_value}


func _prime_ready_tree_source_compiles(main: Object, queue: Variant,
		capture_by_chunk: Dictionary, demand_sections_by_chunk: Dictionary) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(queue) \
			or not queue.has_method("request_ecology_tree_source_compile"):
		return {"status":"ready", "primedCount":0,
			"reason":"ecology_tree_source_compiler_queue_unavailable"}
	var primed_count := 0
	for chunk_value: Variant in capture_by_chunk.keys():
		if not chunk_value is Vector2i:
			continue
		var source_chunk: Vector2i = chunk_value
		var sections_value: Variant = demand_sections_by_chunk.get(source_chunk, [])
		if not sections_value is Array or (sections_value as Array).is_empty():
			continue
		var capture_value: Variant = capture_by_chunk.get(source_chunk, null)
		if not capture_value is Dictionary:
			continue
		var capture: Dictionary = capture_value
		if String(capture.get("status", "")) != "ready":
			continue
		var capture_identity := String(capture.get("identity", ""))
		var snapshot_value: Variant = capture.get("snapshot", null)
		var view_value: Variant = capture.get("sourcePublicationView", null)
		if capture_identity.is_empty() or not snapshot_value is Dictionary \
				or not view_value is Dictionary \
				or String(capture.get("sourcePublicationId", "")).is_empty() \
				or String(capture.get("sourcePublicationLeaseToken", "")).is_empty():
			continue
		var snapshot: Dictionary = snapshot_value
		var view: Dictionary = view_value
		if not _publication_view_matches_snapshot(view, snapshot) \
				or String(capture.get("sourcePublicationId", "")) \
				!= String(view.get("publicationId", "")):
			continue
		var tree_result: Variant = view.get("familyResultsById", {}).get("trees", null)
		if not tree_result is Dictionary \
				or String(tree_result.get("status", "")) != "ready" \
				or String(tree_result.get("disposition", "")) \
				not in ["complete_nonempty", "complete_empty"]:
			continue
		var job: Dictionary = _source_capture_jobs.get(capture_identity, {})
		if job.is_empty() or String(job.get("status", "")) != "ready":
			continue
		var demands_value: Variant = job.get("treeCompileDemands", {})
		var demands: Dictionary = demands_value if demands_value is Dictionary else {}
		job["treeCompileDemands"] = demands
		_source_capture_jobs[capture_identity] = job
		for section_value: Variant in sections_value:
			if not section_value is Vector3i:
				continue
			var section_key: Vector3i = section_value
			if not (job.get("sections", {}) as Dictionary).has(section_key):
				continue
			var consumer_token := _tree_compile_consumer_token(capture_identity,
				section_key)
			var existing_value: Variant = demands.get(section_key, null)
			if existing_value is Dictionary \
					and String(existing_value.get("consumerToken", "")) == consumer_token \
					and not String(existing_value.get("jobKey", "")).is_empty():
				var probe := _poll_tree_compile_demand(queue, existing_value)
				if String(probe.get("status", "")) == "failed":
					return probe
				if String(probe.get("reason", "")) not in [
						"ecology_source_compile_job_missing",
						"ecology_source_compile_queue_replaced"]:
					continue
			if existing_value is Dictionary:
				_cancel_tree_compile_demand(existing_value)
				demands.erase(section_key)
			var admission: Dictionary = queue.call(
				"request_ecology_tree_source_compile", main, snapshot,
				consumer_token, view)
			if String(admission.get("status", "")) == "failed":
				return admission
			var job_key := String(admission.get("jobKey", ""))
			if job_key.is_empty():
				# Backpressure remains retryable. The source bundle and section gate
				# stay pending; the next census retries admission.
				continue
			demands[section_key] = {"jobKey":job_key,
				"consumerToken":consumer_token,
				"queueRef":weakref(queue),
				"treeFamilyRevision":String(tree_result.get("familyRevision", "")),
				"treeFamilyManifestDigest":String(tree_result.get(
					"sourceManifestDigest", "")),
				"sourcePublicationId":String(view.get("publicationId", ""))}
			job["treeCompileDemands"] = demands
			_source_capture_jobs[capture_identity] = job
			primed_count += 1
	return {"status":"ready", "primedCount":primed_count}


func _register_source_family_section_band_projections(main: Object,
		 world_id: String, source_chunk: Vector2i, section_keys: Array,
		 source_snapshot: Dictionary, catalog_artifact: Dictionary,
		 publication_view: Dictionary, publication_lease_token: String,
		expected_families: Array[String], capture_identity := "",
		tree_section_keys: Array = [], selected_family := "",
		prepared_section_slices: Dictionary = {},
		register_legacy := true) -> Dictionary:
	if _support_index == null or not is_instance_valid(main) \
			or not _support_index.has_method(
			"expected_source_family_section_band_projection") \
			or not _support_index.has_method(
			"register_source_family_section_band_projection"):
		return _pending("ecology_source_band_projection_index_unavailable", {
			"sourceChunkKey":source_chunk})
	var source_status := String(source_snapshot.get("status", ""))
	if source_status != "ready" \
			or source_snapshot.get("sourceChunkKey", null) != source_chunk \
			or String(source_snapshot.get("sourceRevision", "")).is_empty():
		return _pending("ecology_source_band_projection_source_pending", {
			"sourceChunkKey":source_chunk})
	var requested_value: Variant = source_snapshot.get("requestedFamilies", null)
	if not requested_value is Array:
		return _pending("ecology_source_band_projection_families_missing", {
			"sourceChunkKey":source_chunk})
	var requested: Array[String] = []
	for family_value: Variant in requested_value:
		var family := String(family_value)
		if family not in ProducerDomainScript.REQUIRED_CATEGORIES or family in requested:
			return _failed("ecology_source_band_projection_family_request_invalid", {
				"sourceChunkKey":source_chunk, "family":family})
		requested.append(family)
	requested.sort()
	var expected_sorted := expected_families.duplicate()
	expected_sorted.sort()
	for expected_family: String in expected_sorted:
		if expected_family not in requested:
			return _pending("ecology_source_band_projection_family_request_stale", {
				"sourceChunkKey":source_chunk, "requestedFamilies":requested,
				"expectedFamilies":expected_sorted})
	if not selected_family.is_empty() and selected_family not in expected_sorted:
		return _failed("ecology_source_band_projection_selected_family_invalid", {
			"sourceChunkKey":source_chunk, "family":selected_family})
	var inputs: Variant = source_snapshot.get("sourceInputs", null)
	if not inputs is Dictionary \
			or String(source_snapshot.get("removedSourceProjectionDigest", "")).length() != 64:
		return _pending("ecology_source_band_projection_source_identity_missing", {
			"sourceChunkKey":source_chunk})
	var published_sections := 0
	var ordered_sections: Array[Vector3i] = []
	for section_value: Variant in section_keys:
		if not section_value is Vector3i:
			return _failed("ecology_source_band_projection_section_invalid", {
				"sourceChunkKey":source_chunk})
		var section_key: Vector3i = section_value
		if section_key not in ordered_sections:
			ordered_sections.append(section_key)
	ordered_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	if ordered_sections.is_empty():
		return {"status":"ready", "sourceChunkKey":source_chunk,
			"publishedBandCount":0}
	if not main.has_method("prepare_ecology_source_publication_section_band_slices"):
		return _pending("ecology_source_publication_band_slice_owner_unavailable", {
			"sourceChunkKey":source_chunk})
	var prepared_slices_value: Variant
	if prepared_section_slices.is_empty():
		prepared_slices_value = main.call(
			"prepare_ecology_source_publication_section_band_slices",
			publication_view, publication_lease_token, ordered_sections)
	else:
		prepared_slices_value = {"status":"ready",
			"sectionBandSlicesByKey":prepared_section_slices}
	if not prepared_slices_value is Dictionary \
			or String(prepared_slices_value.get("status", "")) != "ready":
		return prepared_slices_value if prepared_slices_value is Dictionary else \
			_pending("ecology_source_publication_band_slice_prepare_invalid", {
				"sourceChunkKey":source_chunk})
	var prepared_slices: Dictionary = prepared_slices_value.get(
		"sectionBandSlicesByKey", {})
	for section_key: Vector3i in ordered_sections:
		var band_bounds := ProducerDomainScript.section_bounds(section_key)
		var band_slice_value: Variant = prepared_slices.get(section_key, null)
		if not band_slice_value is Dictionary:
			return _pending("ecology_source_publication_band_slice_missing", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		var band_slice: Dictionary = band_slice_value
		var projected_value: Variant = band_slice.get("bundle", null)
		if not projected_value is Dictionary or not projected_value.is_read_only():
			return _pending("ecology_source_publication_band_bundle_unsealed", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		var projected: Dictionary = projected_value
		if String(projected.get("status", "")) != "ready":
			var failed_source_id := String(projected.get("sourceId", ""))
			var failed_family := String(projected.get("family", ""))
			var failed_source_proof: Dictionary = {}
			for source_coverage_value: Variant in source_snapshot.get("familyCoverage", []):
				if not source_coverage_value is Dictionary \
						or String(source_coverage_value.get("family", "")) != failed_family:
					continue
				for source_row_value: Variant in source_coverage_value.get("sourceRows", []):
					if source_row_value is Dictionary \
							and String(source_row_value.get("sourceId", "")) == failed_source_id:
						var proof_value: Variant = source_row_value.get("supportProof", {})
						if proof_value is Dictionary:
							failed_source_proof = proof_value.duplicate(false)
					break
			return _pending(String(projected.get("reason",
				"ecology_source_band_projection_pending")), {
				"sourceChunkKey":source_chunk, "sectionKey":section_key,
				"family":failed_family,
				"sourceId":failed_source_id,
				"sourceProof":failed_source_proof,
				"projection":projected})
		if projected.get("sourceChunkKey", null) != source_chunk \
				or projected.get("bandKey", null) != section_key \
				or projected.get("bandBounds", null) != band_bounds \
				or String(projected.get("sourceRevision", "")) != String(
					source_snapshot.get("sourceRevision", "")) \
				or String(projected.get("sourceBundleDigest", "")).length() != 64:
			return _pending("ecology_source_band_projection_identity_mismatch", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		var coverage_values: Variant = projected.get("familyCoverage", null)
		if not coverage_values is Array:
			return _pending("ecology_source_band_projection_coverage_missing", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		var coverage_by_family: Dictionary = {}
		for coverage_value: Variant in coverage_values:
			if not coverage_value is Dictionary:
				return _pending("ecology_source_band_projection_family_receipt_invalid", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key})
			var coverage: Dictionary = coverage_value
			var family := String(coverage.get("family", ""))
			if family not in requested or coverage_by_family.has(family):
				return _pending("ecology_source_band_projection_family_receipt_invalid", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key,
					"family":family})
			coverage_by_family[family] = coverage
		if coverage_by_family.size() != requested.size():
			return _pending("ecology_source_band_projection_family_receipt_missing", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		var selected_legacy_families: Array[String] = []
		for family: String in requested:
			var coverage: Dictionary = coverage_by_family[family]
			var disposition := String(coverage.get("disposition", ""))
			var projected_ids: Variant = coverage.get("sourceIds", null)
			var projected_ids_digest := String(coverage.get("sourceIdsDigest", ""))
			if disposition not in ["complete_empty", "complete_nonempty"] \
					or not projected_ids is Array \
					or (disposition == "complete_empty" and (not projected_ids.is_empty() \
						or int(coverage.get("memberCount", -1)) != 0)) \
					or (disposition == "complete_nonempty" and (projected_ids.is_empty() \
						or int(coverage.get("memberCount", -1)) <= 0)) \
					or projected_ids_digest.length() != 64:
				return _pending("ecology_source_band_projection_family_incomplete", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key,
					"family":family, "disposition":disposition})
			if family == "trees":
				# The complete projected tree receipt is consumed by
				# admit_tree_source_family_section_band below. Trees deliberately
				# have no legacy family-domain publication on this path.
				continue
			if family not in expected_sorted:
				continue
			if not selected_family.is_empty() and family != selected_family:
				continue
			selected_legacy_families.append(family)
			var expected_value: Variant = _support_index.call(
				"expected_source_family_section_band_projection", world_id,
				source_chunk, section_key, family)
			if not expected_value is Dictionary \
					or String(expected_value.get("status", "")) != "ready":
				return _pending(String(expected_value.get("reason",
					"ecology_source_band_support_expectation_pending")) \
					if expected_value is Dictionary else \
					"ecology_source_band_support_expectation_pending", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key,
					"family":family})
			var expected: Dictionary = expected_value
			if expected.get("sourceChunkKey", null) != source_chunk \
					or expected.get("sectionKey", null) != section_key \
					or expected.get("bandBounds", null) != band_bounds \
					or String(expected.get("sourceDomainRevision", "")) != String(
						projected.get("sourceRevision", "")) \
					or String(expected.get("sourceFamilyRevision", "")) != String(
						coverage.get("sourceFamilyRevision", "")) \
					or String(expected.get("sourceFamilyManifestDigest", "")) != String(
						coverage.get("sourceFamilyManifestDigest", "")) \
					or String(expected.get("familyPolicyRevision", "")) != String(
						coverage.get("familyPolicyRevision", "")) \
					or String(expected.get("familyPolicyDigest", "")) != String(
						coverage.get("familyPolicyDigest", "")) \
					or String(expected.get("catalogArtifactId", "")) != String(
						projected.get("catalogArtifactId", "")) \
					or String(expected.get("catalogContentDigest", "")) != String(
						projected.get("catalogContentDigest", "")) \
					or int(expected.get("worldEpoch", -1)) != int(projected.get("worldEpoch", -2)) \
					or String(expected.get("removedSourceProjectionDigest", "")) != String(
						projected.get("removedSourceProjectionDigest", "")) \
					or projected_ids != expected.get("expectedSourceIds", null) \
					or projected_ids_digest != String(expected.get("expectedSourceIdsDigest", "")) \
					or int(expected.get("expectedSupportMemberCount", -1)) < 0 \
					or String(expected.get("expectedSupportMemberDigest", "")).length() != 64:
				return _pending("ecology_source_band_projection_support_mismatch", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key,
					"family":family, "expectedSourceIds":expected.get("expectedSourceIds", []),
					"projectedSourceIds":projected_ids})
		var publication_current: Variant = main.call(
			"ecology_source_publication_local_is_current", publication_view,
			publication_lease_token) \
			if main.has_method("ecology_source_publication_local_is_current") else null
		if not publication_current is Dictionary \
				or String(publication_current.get("status", "")) != "ready":
			return _pending(String(publication_current.get("reason",
				"ecology_source_publication_stale")) \
				if publication_current is Dictionary else \
				"ecology_source_publication_stale", {
				"sourceChunkKey":source_chunk, "sectionKey":section_key})
		if register_legacy and not selected_legacy_families.is_empty():
			var registered: Variant = _support_index.call(
				"register_source_family_section_band_projection", world_id,
				source_chunk, section_key, source_snapshot, band_slice,
				selected_legacy_families, publication_view, publication_lease_token)
			if not registered is Dictionary \
					or String(registered.get("status", "")) != "ready":
				return registered if registered is Dictionary else \
					_pending("ecology_source_band_projection_registration_pending", {
						"sourceChunkKey":source_chunk, "sectionKey":section_key})
		if "trees" in expected_sorted and section_key in tree_section_keys \
				and (selected_family.is_empty() or selected_family == "trees"):
			var tree_band := _admit_compile_register_tree_band(main, world_id,
				capture_identity, source_chunk, section_key, source_snapshot,
				band_slice, publication_view, publication_lease_token)
			if String(tree_band.get("status", "")) != "ready":
				return tree_band
		published_sections += 1
	return {"status":"ready", "sourceChunkKey":source_chunk,
		"publishedBandCount":published_sections}


func _admit_compile_register_tree_band(main: Object, world_id: String,
		capture_identity: String, source_chunk: Vector2i, section_key: Vector3i,
		source_snapshot: Dictionary, projected_bundle: Dictionary,
		publication_view: Dictionary, publication_lease_token: String) -> Dictionary:
	if _support_index == null or not _support_index.has_method(
			"admit_tree_source_family_section_band") \
			or not _support_index.has_method("register_tree_section_geometry_overlay"):
		return _pending("ecology_tree_band_index_api_unavailable", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key})
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue) or not queue.has_method(
			"request_ecology_tree_source_band_compile") \
			or not queue.has_method("poll_ecology_tree_source_band_compile"):
		return _pending("ecology_tree_band_compile_queue_unavailable", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key})
	var admitted: Dictionary = _support_index.call(
		"admit_tree_source_family_section_band", world_id, source_chunk, section_key,
		source_snapshot, projected_bundle,
		publication_view, publication_lease_token)
	if String(admitted.get("status", "")) != "ready":
		return admitted
	var authority: Dictionary = admitted.get("authority", {})
	if authority.is_empty() or not authority.is_read_only():
		return _pending("ecology_tree_band_authority_unsealed", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key})
	var tree_family: Dictionary = publication_view.get("familyResultsById", {}).get("trees", {})
	var expected_ids: Variant = authority.get("producerSourceIds", null)
	if String(tree_family.get("status", "")) != "ready":
		return tree_family
	if not expected_ids is Array:
		return _failed("ecology_tree_band_family_coverage_unavailable", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key})
	var stable_capture_identity := capture_identity
	if stable_capture_identity.is_empty():
		stable_capture_identity = String(publication_view.get("publicationId", ""))
	var consumer_token := _tree_compile_consumer_token(stable_capture_identity,
		section_key) + "|source:%d,%d|band:%s" % [source_chunk.x, source_chunk.y,
		String(authority.get("authorityDigest", ""))]
	var job: Dictionary = _source_capture_jobs.get(stable_capture_identity, {})
	var demands_value: Variant = job.get("treeCompileDemands", {})
	var demands: Dictionary = demands_value if demands_value is Dictionary else {}
	var demand_key := "band:%d,%d:%d,%d,%d" % [source_chunk.x, source_chunk.y,
		section_key.x, section_key.y, section_key.z]
	var existing: Dictionary = demands.get(demand_key, {})
	if not existing.is_empty():
		var existing_result := _resolve_existing_tree_band_demand(queue, existing,
			String(authority.get("authorityDigest", "")), consumer_token,
			source_chunk, section_key)
		var existing_disposition := String(existing_result.get("disposition", ""))
		if existing_disposition == "ready":
			var polled: Dictionary = existing_result.get("poll", {})
			return _register_tree_band_overlay_result(main, source_chunk,
				section_key, authority, tree_family, polled.get("artifact", {}),
				publication_view, publication_lease_token, existing, queue)
		if existing_disposition in ["wait", "terminal"]:
			return existing_result.get("result", _pending(
				"ecology_tree_band_compile_pending"))
		# Missing jobs, detached consumers, changed authorities, and invalid poll
		# responses are retryable. Detach the old token before replacing it.
		demands.erase(demand_key)
		job["treeCompileDemands"] = demands
		_source_capture_jobs[stable_capture_identity] = job
	var admission: Dictionary = queue.call(
		"request_ecology_tree_source_band_compile", main, source_snapshot,
		section_key, authority, publication_view, consumer_token,
		_capture_cohort_camera_priority(section_key, _current_capture_camera_position(main)))
	var admission_status := String(admission.get("status", ""))
	var admission_job_key := String(admission.get("jobKey", ""))
	var admission_consumer := String(admission.get("consumerToken", ""))
	var admission_attached := not admission_job_key.is_empty() \
		and not admission_consumer.is_empty()
	var admission_outcome := _classify_retained_preparation_outcome(admission)
	var admission_outcome_status := String(admission_outcome.get("status", "failed"))
	if admission_outcome_status in ["failed", "stale"]:
		# A terminal queue reply may still represent an attached consumer (for
		# example, a record compile failed after this band job was admitted).
		# Classify before polling so pending-with-terminalFailure and stale replies
		# keep their original owner outcome. Release an attached token first.
		if admission_attached:
			_cancel_tree_compile_demand({"compileKind":"tree_band",
				"jobKey":admission_job_key, "consumerToken":admission_consumer,
				"queueRef":weakref(queue)})
		if admission_status in ["failed", "stale", "pending"]:
			return admission
		return _failed("ecology_tree_band_compile_admission_status_invalid", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"admission":admission})
	if admission_status == "pending":
		# The queue uses pending both for a real attached in-flight demand and for
		# backpressure before a job exists. Only the exact consumer token proves
		# that this request owns a cancellable queue attachment. In particular,
		# queue-full replies include a prospective jobKey but no consumerToken.
		if not admission_attached:
			return admission
	elif admission_status != "ready":
		if admission_attached:
			_cancel_tree_compile_demand({"compileKind":"tree_band",
				"jobKey":admission_job_key, "consumerToken":admission_consumer,
				"queueRef":weakref(queue)})
		return _failed("ecology_tree_band_compile_admission_status_invalid", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"admission":admission})
	if admission_attached and admission_consumer != consumer_token:
		_cancel_tree_compile_demand({"compileKind":"tree_band",
			"jobKey":admission_job_key, "consumerToken":admission_consumer,
			"queueRef":weakref(queue)})
		return _failed("ecology_tree_band_compile_admission_consumer_mismatch", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"admission":admission})
	var job_key := admission_job_key
	if job_key.is_empty():
		return _failed("ecology_tree_band_compile_admission_missing_job", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"admission":admission})
	if not admission_attached:
		return _failed("ecology_tree_band_compile_admission_consumer_mismatch", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"admission":admission})
	var demand := {"compileKind":"tree_band", "jobKey":job_key,
		"consumerToken":consumer_token, "queueRef":weakref(queue),
		"captureIdentity":stable_capture_identity,
		"authorityDigest":String(authority.get("authorityDigest", "")),
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"treeFamilyRevision":String(tree_family.get("familyRevision", "")),
		"treeFamilyManifestDigest":String(tree_family.get("sourceManifestDigest", "")),
		"bandAuthority":authority, "sourceChunkKey":source_chunk,
		"sectionKey":section_key}
	demands[demand_key] = demand
	job["treeCompileDemands"] = demands
	if not job.is_empty(): _source_capture_jobs[stable_capture_identity] = job
	var polled: Variant = queue.call("poll_ecology_tree_source_band_compile", job_key,
		consumer_token)
	if not polled is Dictionary:
		return _failed("ecology_tree_band_compile_poll_invalid", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key})
	if String(polled.get("status", "")) != "ready": return polled
	return _register_tree_band_overlay_result(main, source_chunk, section_key,
		authority, tree_family, polled.get("artifact", {}), publication_view,
		publication_lease_token, demand, queue)


func _resolve_existing_tree_band_demand(queue: Object, existing: Dictionary,
		current_authority_digest: String, current_consumer_token: String,
		source_chunk: Vector2i, section_key: Vector3i) -> Dictionary:
	var same_authority := String(existing.get("authorityDigest", "")) \
		== current_authority_digest
	var same_consumer := String(existing.get("consumerToken", "")) \
		== current_consumer_token
	if same_authority and same_consumer and is_instance_valid(queue) \
			and queue.has_method("poll_ecology_tree_source_band_compile"):
		var job_key := String(existing.get("jobKey", ""))
		var polled: Variant = queue.call("poll_ecology_tree_source_band_compile",
			job_key, current_consumer_token)
		if not polled is Dictionary:
			_cancel_tree_compile_demand(existing)
			return {"disposition":"terminal", "result":_failed(
				"ecology_tree_band_compile_poll_invalid", {
					"sourceChunkKey":source_chunk, "sectionKey":section_key})}
		var result: Dictionary = polled
		var poll_status := String(result.get("status", ""))
		var poll_reason := String(result.get("reason", ""))
		if poll_status == "failed" and poll_reason == \
				"tree_source_band_consumer_not_attached":
			_cancel_tree_compile_demand(existing)
			return {"disposition":"retry", "result":result}
		var poll_outcome: Dictionary = _classify_retained_preparation_outcome(result)
		var outcome_status := String(poll_outcome.get("status", "failed"))
		if outcome_status == "stale":
			_cancel_tree_compile_demand(existing)
			return {"disposition":"retry", "result":result}
		if outcome_status == "failed":
			return {"disposition":"terminal", "result":result}
		if poll_status == "ready":
			return {"disposition":"ready", "poll":result}
		if poll_status == "pending" and poll_reason not in [
				"tree_source_band_compile_job_missing",
				"tree_source_band_consumer_not_attached"]:
			return {"disposition":"wait", "result":result}
	_cancel_tree_compile_demand(existing)
	return {"disposition":"retry", "result":_pending(
		"tree_source_band_compile_demand_replaced", {
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"retryable":true})}


func _register_tree_band_overlay_result(main: Object, source_chunk: Vector2i,
		section_key: Vector3i, authority: Dictionary, tree_family: Dictionary,
		artifact_value: Variant, publication_view: Dictionary,
		publication_lease_token: String, demand: Dictionary, queue: Object) -> Dictionary:
	if not artifact_value is Dictionary or not artifact_value.is_read_only():
		return _pending("ecology_tree_band_artifact_unsealed")
	var artifact: Dictionary = artifact_value
	if artifact.get("sectionKey", null) != section_key \
			or artifact.get("sourceChunkKey", null) != source_chunk \
			or String(artifact.get("authorityDigest", "")) != String(
				authority.get("authorityDigest", "")) \
			or String(artifact.get("sourceRevision", "")) != String(
				authority.get("sourceRevision", "")) \
			or String(artifact.get("treeFamilyRevision", "")) != String(
				tree_family.get("familyRevision", "")) \
			or String(artifact.get("treeFamilyManifestDigest", "")) != String(
				tree_family.get("sourceManifestDigest", "")):
		return _pending("ecology_tree_band_artifact_authority_mismatch")
	var support_rows: Array[Dictionary] = []
	var source_manifests: Dictionary = {}
	var source_snapshot: Dictionary = publication_view.get("payload", {})
	if source_snapshot.is_empty() or not _publication_view_matches_snapshot(
			publication_view, source_snapshot):
		return _pending("ecology_tree_band_source_snapshot_missing")
	var producer_rows_by_id: Dictionary = {}
	for row_value: Variant in tree_family.get("sourceRows", []):
		if not row_value is Dictionary:
			return _pending("ecology_tree_band_producer_row_invalid")
		var producer_row: Dictionary = row_value
		var producer_id := String(producer_row.get("sourceId", ""))
		if producer_id.is_empty() or producer_rows_by_id.has(producer_id):
			return _pending("ecology_tree_band_producer_identity_invalid")
		producer_rows_by_id[producer_id] = producer_row
	for source_value: Variant in artifact.get("sources", []):
		if not source_value is Dictionary:
			return _pending("ecology_tree_band_source_manifest_invalid")
		var source_manifest: Dictionary = source_value.duplicate(true)
		var source_id := String(source_manifest.get("sourceId", ""))
		if source_id.is_empty() or source_manifests.has(source_id):
			return _pending("ecology_tree_band_source_manifest_duplicate")
		var producer_row: Dictionary = producer_rows_by_id.get(source_id, {})
		if producer_row.is_empty():
			return _pending("ecology_tree_band_producer_source_missing", {
				"sourceId":source_id})
		var bound: Dictionary = _bind_tree_compiler_manifest_to_source(
			source_manifest, producer_row, source_chunk, source_snapshot, tree_family)
		if String(bound.get("status", "")) != "ready":
			return bound
		source_manifest = bound.get("manifest", {})
		if source_manifest.is_empty():
			return _pending("ecology_tree_band_source_manifest_binding_missing", {
				"sourceId":source_id})
		source_manifests[source_id] = source_manifest
		var projected_rows := tree_support_rows_from_manifest(source_manifest)
		if String(projected_rows.get("status", "")) != "ready":
			return projected_rows
		for row_value: Variant in projected_rows.get("rows", []):
			if row_value is Dictionary and section_key in row_value.get(
					"conservativeSupportSectionKeys", []):
				support_rows.append(row_value)
	var expected_ids: Array = authority.get("producerSourceIds", [])
	var actual_ids: Array[String] = []
	for source_id_value: Variant in source_manifests.keys():
		actual_ids.append(String(source_id_value))
	actual_ids.sort()
	if actual_ids != expected_ids:
		return _pending("ecology_tree_band_source_completion_set_mismatch", {
			"expectedSourceIds":expected_ids, "actualSourceIds":actual_ids})
	var registered: Dictionary = _support_index.call(
		"register_tree_section_geometry_overlay", String(authority.get("worldId", "")),
		source_chunk, section_key, expected_ids, artifact, support_rows)
	if String(registered.get("status", "")) != "ready": return registered
	var capture_identity := String(demand.get("captureIdentity", ""))
	for row_value: Variant in support_rows:
		if not row_value is Dictionary: continue
		var row: Dictionary = row_value
		var source_id := String(row.get("sourceId", ""))
		var part_id := String(row.get("sourcePartId", ""))
		var member_key := _source_part_identity_key(source_id, part_id)
		var source_manifest: Dictionary = source_manifests.get(source_id, {})
		var record: Dictionary = producer_rows_by_id.get(source_id, {})
		if member_key.is_empty() or source_manifest.is_empty() or record.is_empty():
			return _pending("ecology_tree_band_cache_identity_missing")
		_canonical_tree_band_artifact_by_member_section[
			member_key + "|%d,%d,%d" % [section_key.x, section_key.y, section_key.z]] = {
			"sourceId":source_id, "sourcePartId":part_id,
			"compileKind":"tree_band",
			"sourceRevision":String(row.get("sourceRevision", "")),
			"sourcePublicationId":String(publication_view.get("publicationId", "")),
			"sourceChunkKey":source_chunk, "sectionKey":section_key,
			"artifact":artifact, "sourceManifest":source_manifest,
			"producerRow":record, "publicationView":publication_view,
			"publicationLeaseToken":publication_lease_token,
			"jobKey":String(demand.get("jobKey", "")),
			"consumerToken":String(demand.get("consumerToken", "")),
			"captureIdentity":capture_identity, "queueRef":weakref(queue),
			"bandAuthority":authority,
			"overlayReceipt":registered.get("overlay", {})}
		_track_source_publication_member(String(publication_view.get(
			"publicationId", "")), member_key)
	return {"status":"ready", "sectionKey":section_key,
		"sourceChunkKey":source_chunk,
		"sourceCompletionCount":artifact.get("sourceCompletionManifest", []).size(),
		"ownerMemberCount":registered.get("ownerMemberCount", 0),
		"supportMemberCount":registered.get("supportMemberCount", 0),
		"sourceIndexRevision":registered.get("sourceIndexRevision", -1)}


func _capture_nonresident_static_section_sources_in_scope(world_id: String,
		requested_sections: Array, metrics: Dictionary) -> Dictionary:
	if world_id != _world_id or _world_id.is_empty() or requested_sections.is_empty():
		return _pending("ecology_provider_world_or_query_invalid")
	var sections: Array[Vector3i] = []
	for value: Variant in requested_sections:
		if not value is Vector3i or value in sections:
			return _failed("invalid_or_duplicate_ecology_section")
		sections.append(value)
	sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if sections.size() == 1:
		var retained_cohort: Dictionary = _source_capture_cohorts.get(sections[0], {})
		var retained_value: Variant = retained_cohort.get("sectionPreparation", null)
		if retained_value is Dictionary:
			var retained: Dictionary = retained_value
			var retained_status := String(retained.get("status", ""))
			if retained_status == "failed":
				var failed_current := _failed_source_section_preparation_identity_is_current(
					main, retained)
				var failed_current_status := String(failed_current.get("status", ""))
				if failed_current_status == "stale":
					_invalidate_stale_source_section_preparation(sections[0], retained,
						String(failed_current.get("reason",
						"ecology_section_preparation_failed_identity_changed")))
					return _pending("ecology_section_preparation_stale_requeued", {
						"sectionKey":sections[0],
						"staleReason":String(failed_current.get("reason", ""))})
				if failed_current_status == "pending" or failed_current_status == "failed":
					return failed_current
				return _failed(String(retained.get("failureReason",
					"ecology_section_preparation_terminal_failure")), {
					"sectionKey":sections[0],
					"failureDetails":retained.get("failureDetails", {})})
			if retained_status in ["complete", "pending"]:
				var retained_current := _source_section_preparation_is_current(
					main, retained)
				var current_status := String(retained_current.get("status", ""))
				if retained_status == "complete" and current_status == "ready":
					return retained.get("census", _pending(
						"ecology_section_preparation_result_missing"))
				if current_status == "pending":
					return retained_current
				if current_status == "stale":
					_invalidate_stale_source_section_preparation(sections[0], retained,
						String(retained_current.get("reason",
						"ecology_section_preparation_source_stale")))
					return _pending("ecology_section_preparation_stale_requeued", {
						"sectionKey":sections[0],
						"staleReason":String(retained_current.get("reason", ""))})
				if current_status == "failed":
					return _fail_source_section_preparation(sections[0], retained,
						String(retained_current.get("reason",
						"ecology_section_preparation_currentness_failed")),
						retained_current)
			return _pending("ecology_section_preparation_pending", {
				"sectionKey":sections[0],
				"stage":String(retained.get("stage", "unknown")),
				"dependency":String(retained.get("pendingReason", "")),
				"pendingDetails":retained.get("pendingDetails", {}),
				"sourceId":String(retained.get("pendingDetails", {}).get("sourceId", "")),
				"sourcePartId":String(retained.get("pendingDetails", {}).get(
					"sourcePartId", "")),
				"family":String(retained.get("pendingDetails", {}).get("family", "")),
				"sourceChunkKey":retained.get("pendingDetails", {}).get(
					"sourceChunkKey", Vector2i.ZERO),
				"sourceFamilyCursor":int(retained.get("familyCursor", 0)),
				"sourceChunkCursor":int(retained.get("sourceChunkCursor", 0))})
	if not is_instance_valid(main) or not main.has_method("capture_ecology_source_domain"):
		return _pending("ecology_nonresident_source_domain_capture_unavailable")
	var queue: Variant = main.get("tree_publication_queue")
	var seed := String(main.get("seed_text"))
	if seed.is_empty(): return _pending("ecology_source_seed_unavailable")
	var removed := RemovedProps.capture(main)
	if not bool(removed.get("ok", false)):
		return _pending("ecology_removed_props_snapshot_unavailable")
	var source_keys_by_section: Dictionary = {}
	var source_keys_by_family_by_section: Dictionary = {}
	var all_source_keys: Dictionary = {}
	var support_policy_by_section: Dictionary = {}
	var catalog_artifact: Dictionary = {}
	_set_static_census_capture_phase(metrics, "closure_policy")
	for section: Vector3i in sections:
		_add_static_census_capture_count(metrics, "sectionPolicyInputCount")
		var policy_input_result := _canonical_support_policy_inputs(main,
			world_id, Grid.chunk_key_for_section(section), seed, {})
		if String(policy_input_result.get("status", "")) != "ready":
			return _pending("ecology_runtime_support_policy_inputs_pending", {
				"sectionKey":section,
				"supportPolicyDiagnostic":policy_input_result.get("diagnostic", {})})
		var support_inputs: Dictionary = policy_input_result.get("sourceInputs", {})
		var section_artifact: Variant = policy_input_result.get("catalogArtifact", null)
		if not section_artifact is Dictionary or not section_artifact.is_read_only():
			return _pending("ecology_catalog_artifact_unavailable", {"sectionKey":section})
		if catalog_artifact.is_empty():
			catalog_artifact = section_artifact
		elif String(catalog_artifact.get("artifactId", "")) != String(
				section_artifact.get("artifactId", "")):
			return _pending("ecology_catalog_artifact_changed_during_census", {
				"sectionKey":section})
		var certificate := ProducerDomainScript.source_domain_census_certificate(
			section, support_inputs, catalog_artifact)
		if String(certificate.get("status", "")) != "ready":
			return _pending(String(certificate.get("reason",
				"ecology_source_domain_census_unproven")), {
				"sectionKey":section,
				"influencePolicyRevision":String(certificate.get("influencePolicyRevision", "")),
				"influencePolicyDigest":String(certificate.get("influencePolicyDigest", "")),
				"requiredFamilyBounds":ProducerDomainScript.support_policy(
					support_inputs, catalog_artifact).get("families", {})})
		var source_keys: Array = certificate.get("sourceChunkKeys", [])
		var keys_by_family_value: Variant = certificate.get("sourceChunkKeysByFamily", null)
		if not keys_by_family_value is Dictionary:
			return _pending("ecology_family_source_closure_missing", {"sectionKey":section})
		var keys_by_family: Dictionary = keys_by_family_value
		var declared := set_support_source_domains_by_family(section,
			keys_by_family, certificate)
		if String(declared.get("status", "")) != "ready": return declared
		source_keys_by_section[section] = source_keys
		source_keys_by_family_by_section[section] = keys_by_family
		support_policy_by_section[section] = certificate
		for key_value: Variant in source_keys:
			all_source_keys[Vector2i(key_value)] = true
	var ordered_source_keys: Array[Vector2i] = []
	for key_value: Variant in all_source_keys:
		ordered_source_keys.append(Vector2i(key_value))
	ordered_source_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	_add_static_census_capture_count(metrics, "sourceChunkClosureCount",
		ordered_source_keys.size())
	var world_generation: Object = main.get("world_generation_system") as Object
	if not is_instance_valid(world_generation) or not world_generation.has_method(
			"terrain_volume_chunk_revision"):
		return _pending("ecology_source_revision_authorities_unavailable")
	var source_inputs_by_chunk: Dictionary = {}
	var source_capture_by_chunk: Dictionary = {}
	var source_capture_by_family_chunk: Dictionary = {}
	var requested_families_by_chunk: Dictionary = {}
	var requested_families_by_section_chunk: Dictionary = {}
	var dependent_sections_by_chunk: Dictionary = {}
	var tree_demand_sections_by_chunk: Dictionary = {}
	var first_pending_capture: Dictionary = {}
	var first_failed_capture: Dictionary = {}
	var camera_position := Vector3.ZERO
	var player_value: Variant = main.get("player")
	if is_instance_valid(player_value) and player_value is Node3D:
		camera_position = (player_value as Node3D).global_position
		var camera_value: Variant = player_value.get("camera")
		if is_instance_valid(camera_value) and camera_value is Node3D:
			camera_position = (camera_value as Node3D).global_position
	# Register the complete inverse-source set before returning pending. This
	# lets one source job serve every section in the current query and lets the
	# independent dispatcher advance all newly discovered jobs fairly.
	_set_static_census_capture_phase(metrics, "source_lookup")
	for source_chunk: Vector2i in ordered_source_keys:
		_add_static_census_capture_count(metrics, "sourceChunkLookupCount")
		var terrain_revision := str(world_generation.call("terrain_volume_chunk_revision",
			source_chunk, Grid.STREAM_CHUNK_SIZE_CELLS))
		if terrain_revision.is_empty():
			return _pending("ecology_source_authority_revision_pending", {
				"sourceChunkKey":source_chunk})
		var base_inputs := {"terrainVolumeChunkRevision":terrain_revision}
		var policy_input_result := _canonical_support_policy_inputs(main, world_id,
			source_chunk, seed, base_inputs)
		if String(policy_input_result.get("status", "")) != "ready":
			return _pending("ecology_runtime_support_policy_inputs_pending", {
				"sourceChunkKey":source_chunk,
				"supportPolicyDiagnostic":policy_input_result.get("diagnostic", {})})
		var support_inputs: Dictionary = policy_input_result.get("sourceInputs", {})
		var source_artifact: Variant = policy_input_result.get("catalogArtifact", null)
		if not source_artifact is Dictionary or String(source_artifact.get("artifactId", "")) \
				!= String(catalog_artifact.get("artifactId", "")):
			return _pending("ecology_catalog_artifact_changed_during_census", {
				"sourceChunkKey":source_chunk})
		var runtime_policy := ProducerDomainScript.support_policy(support_inputs,
			catalog_artifact)
		var dependent_sections: Array[Vector3i] = []
		var source_priority := INF
		for section: Vector3i in sections:
			if source_chunk not in source_keys_by_section.get(section, []):
				continue
			var family_map: Dictionary = source_keys_by_family_by_section.get(section, {})
			if source_chunk in family_map.get("trees", []):
				var tree_sections: Array = tree_demand_sections_by_chunk.get(source_chunk, [])
				if section not in tree_sections:
					tree_sections.append(section)
				tree_demand_sections_by_chunk[source_chunk] = tree_sections
			var certificate: Dictionary = support_policy_by_section.get(section, {})
			if String(certificate.get("influencePolicyDigest", "")) \
					!= String(runtime_policy.get("digest", "")):
				return _pending("ecology_runtime_support_policy_changed_during_capture", {
					"sourceChunkKey":source_chunk, "sectionKey":section})
			dependent_sections.append(section)
			var center := Grid.origin_for_key(section) \
				+ Vector3.ONE * (Grid.SECTION_SIZE_METERS * 0.5)
			source_priority = minf(source_priority,
				camera_position.distance_squared_to(center))
		if dependent_sections.is_empty():
			continue
		# The final section receipt remains complete, but source work is admitted
		# only for the exact family/source pairs in each section certificate.
		# Multi-section cohorts use the union once per source chunk, then register
		# each section's own family subset against that family-scoped publication.
		var requested_families: Array[String] = []
		for dependent_section: Vector3i in dependent_sections:
			var family_map: Dictionary = source_keys_by_family_by_section.get(
				dependent_section, {})
			var section_families: Array[String] = []
			for family_value: Variant in ProducerDomainScript.REQUIRED_CATEGORIES:
				var family := String(family_value)
				var family_source_keys: Array = family_map.get(family, [])
				if source_chunk in family_source_keys:
					section_families.append(family)
			section_families.sort()
			if section_families.is_empty():
				return _failed("ecology_family_source_pair_missing", {
					"sourceChunkKey":source_chunk, "sectionKey":dependent_section})
			requested_families_by_section_chunk[
				"%d,%d|%d,%d,%d" % [source_chunk.x, source_chunk.y,
				dependent_section.x, dependent_section.y, dependent_section.z]] = \
				section_families.duplicate()
			for family: String in section_families:
				if family not in requested_families:
					requested_families.append(family)
		requested_families.sort()
		if requested_families.is_empty():
			return _failed("ecology_source_chunk_has_no_family_pairs", {
				"sourceChunkKey":source_chunk})
		for family: String in requested_families:
			_add_static_census_capture_count(metrics, "sourceFamilyChunkPairCount")
			var pair_counts_value: Variant = metrics.get("counts", {}).get(
				"sourceFamilyChunkPairCountByFamily", {})
			var pair_counts: Dictionary = pair_counts_value \
				if pair_counts_value is Dictionary else {}
			pair_counts[family] = int(pair_counts.get(family, 0)) + 1
			metrics["counts"]["sourceFamilyChunkPairCountByFamily"] = pair_counts
			if family == "underground_props":
				_add_static_census_capture_count(metrics,
					"undergroundSourceChunkPairCount")
		dependent_sections_by_chunk[source_chunk] = dependent_sections.duplicate()
		if not main.has_method("_removed_props_projection_for_source_chunk"):
			return _pending("ecology_source_removal_projection_authority_unavailable", {
				"sourceChunkKey":source_chunk})
		var removed_projection_value: Variant = main.call(
			"_removed_props_projection_for_source_chunk", source_chunk, removed)
		if not removed_projection_value is Dictionary \
				or String(removed_projection_value.get("status", "")) != "ready":
			return _pending("ecology_source_removal_projection_pending", {
				"sourceChunkKey":source_chunk,
				"projection":removed_projection_value})
		var removed_projection: Dictionary = removed_projection_value
		requested_families_by_chunk[source_chunk] = requested_families.duplicate()
		if sections.size() == 1:
			# Each source/family pair has an independently retryable queue job and
			# receipt. All jobs still share Main's chunk/revision source-pass session.
			for family: String in requested_families:
				var pair_capture_request := request_source_domain_capture(world_id,
					source_chunk, seed, support_inputs, removed, removed_projection,
					dependent_sections[0], source_priority, [family])
				_add_static_census_capture_count(metrics, "sourceCaptureRequestCount")
				var pair_key := "%d,%d|%s" % [source_chunk.x, source_chunk.y, family]
				source_capture_by_family_chunk[pair_key] = pair_capture_request
				var capture_status := String(pair_capture_request.get("status", ""))
				if capture_status == "pending":
					_add_static_census_capture_count(metrics, "sourceCapturePendingCount")
					if first_pending_capture.is_empty():
						first_pending_capture = pair_capture_request.duplicate(false)
				elif capture_status != "ready":
					_add_static_census_capture_count(metrics, "sourceCaptureFailedCount")
					if first_failed_capture.is_empty():
						first_failed_capture = pair_capture_request.duplicate(false)
				else:
					source_inputs_by_chunk[source_chunk] = support_inputs
					_add_static_census_capture_count(metrics, "sourceCaptureReadyCount")
		else:
			var union_capture_request := request_source_domain_capture(world_id,
				source_chunk, seed, support_inputs, removed, removed_projection,
				dependent_sections[0], source_priority, requested_families)
			_add_static_census_capture_count(metrics, "sourceCaptureRequestCount")
			for dependent_section: Vector3i in dependent_sections.slice(1):
				request_source_domain_capture(world_id, source_chunk, seed,
					support_inputs, removed, removed_projection,
					dependent_section, source_priority, requested_families)
			source_capture_by_chunk[source_chunk] = union_capture_request
			var capture_status := String(union_capture_request.get("status", ""))
			if capture_status == "pending":
				_add_static_census_capture_count(metrics, "sourceCapturePendingCount")
				if first_pending_capture.is_empty():
					first_pending_capture = union_capture_request.duplicate(false)
			elif capture_status != "ready":
				_add_static_census_capture_count(metrics, "sourceCaptureFailedCount")
				if first_failed_capture.is_empty():
					first_failed_capture = union_capture_request.duplicate(false)
			else:
				source_inputs_by_chunk[source_chunk] = support_inputs
				_add_static_census_capture_count(metrics, "sourceCaptureReadyCount")
	_set_static_census_capture_phase(metrics, "query_sealing")
	_seal_source_capture_cohort_closures(sections)
	if sections.size() == 1:
		if not first_failed_capture.is_empty():
			return _failed(String(first_failed_capture.get("reason",
				"ecology_source_capture_failed")), {
				"sourceChunkKey":first_failed_capture.get("sourceChunkKey", Vector2i.ZERO),
				"capture":first_failed_capture})
		var source_plans: Array[Dictionary] = []
		for source_chunk: Vector2i in ordered_source_keys:
			var section_family_key := "%d,%d|%d,%d,%d" % [source_chunk.x,
				source_chunk.y, sections[0].x, sections[0].y, sections[0].z]
			var section_families: Array = requested_families_by_section_chunk.get(
				section_family_key, [])
			for family_value: Variant in section_families:
				var family := String(family_value)
				var pair_key := "%d,%d|%s" % [source_chunk.x, source_chunk.y, family]
				var pair_capture: Dictionary = source_capture_by_family_chunk.get(
					pair_key, {})
				var capture_identity := String(pair_capture.get("identity", ""))
				if capture_identity.is_empty():
					return _pending("ecology_section_preparation_capture_identity_missing", {
						"sectionKey":sections[0], "sourceChunkKey":source_chunk,
						"family":family})
				var plan_tree_sections: Array = []
				if family == "trees": plan_tree_sections.append(sections[0])
				var plan := {"sourceChunkKey":source_chunk,
					"captureIdentity":capture_identity,
					"requestedFamilies":[family],
					"family":family,
					"treeSections":plan_tree_sections}
				source_plans.append(plan)
		var preparation_key := _source_section_preparation_key(world_id, sections[0])
		var preparation := {"schema":"ecology-retained-section-preparation/v1",
			"preparationKey":preparation_key, "worldId":world_id,
			"worldSeed":seed, "sectionKey":sections[0],
			"status":"pending", "stage":"source_families",
			"pendingReason":"ecology_section_preparation_queued",
			"catalogArtifact":catalog_artifact,
			"sourcePlans":source_plans,
			"sourceChunkCursor":0, "familyCursor":0,
			"domainIdentityRows":[],
			"fingerprintCache":{
				"resources":{"mesh":{}, "material":{}},
				"stats":{"meshHits":0, "meshMisses":0,
					"materialHits":0, "materialMisses":0}},
			"createdOpportunity":_source_capture_service_opportunities,
			"lastAdvancedOpportunity":-1, "unitCount":0}
		var prep_cohort: Dictionary = _source_capture_cohorts.get(sections[0], {})
		prep_cohort["preparationKey"] = preparation_key
		prep_cohort["sectionPreparation"] = preparation
		_source_capture_cohorts[sections[0]] = prep_cohort
		_source_section_preparations[preparation_key] = preparation
		if preparation_key not in _source_section_preparation_order:
			_source_section_preparation_order.append(preparation_key)
		return _pending("ecology_section_preparation_pending", {
			"sectionKey":sections[0], "stage":"source_families",
			"sourceChunkCount":source_plans.size(),
			"sourceReadyCount":0})
	_set_static_census_capture_phase(metrics, "source_conversion")
	var fingerprint_cache := {"resources":{"mesh":{}, "material":{}},
		"stats":{"meshHits":0, "meshMisses":0,
			"materialHits":0, "materialMisses":0}}
	var source_rows_by_chunk: Dictionary = {}
	var domain_identity_rows: Array = []
	for source_chunk: Vector2i in ordered_source_keys:
		_set_static_census_capture_phase(metrics, "source_conversion")
		var support_inputs: Dictionary = source_inputs_by_chunk.get(source_chunk, {})
		var capture_request: Dictionary = source_capture_by_chunk.get(source_chunk, {})
		var snapshot_value: Variant = capture_request.get("snapshot", null)
		if not snapshot_value is Dictionary:
			continue
		var snapshot: Dictionary = snapshot_value
		var requested_families: Array = requested_families_by_chunk.get(source_chunk, [])
		var publication_view: Dictionary = capture_request.get("sourcePublicationView", {})
		var publication_lease_token := String(capture_request.get(
			"sourcePublicationLeaseToken", ""))
		if not _publication_view_matches_snapshot(publication_view, snapshot) \
				or String(snapshot.get("status", "")) != "ready" \
				or publication_lease_token.is_empty():
			return _pending("ecology_source_publication_view_missing", {
				"sourceChunkKey":source_chunk})
		var publication_current: Variant = main.call(
			"ecology_source_publication_local_is_current",
			publication_view, publication_lease_token) \
			if main.has_method("ecology_source_publication_local_is_current") else null
		if not publication_current is Dictionary \
				or String(publication_current.get("status", "")) != "ready":
			return _pending(String(publication_current.get("reason",
				"ecology_source_publication_stale")) \
				if publication_current is Dictionary else "ecology_source_publication_stale",
				{"sourceChunkKey":source_chunk})
		var producer_row_by_id: Dictionary = {}
		var support_rows_by_family: Dictionary = {}
		var family_results: Dictionary = {}
		for family_value: Variant in requested_families:
			var family := String(family_value)
			var family_result: Dictionary = publication_view.get(
				"familyResultsById", {}).get(family, {})
			if String(family_result.get("status", "")) != "ready" \
					or String(family_result.get("disposition", "")) \
					not in ["complete_nonempty", "complete_empty"]:
				return _pending(String(family_result.get("reason",
					"ecology_source_family_result_incomplete")), {
					"sourceChunkKey":source_chunk, "family":family,
					"disposition":String(family_result.get("disposition", ""))})
			family_results[family] = family_result
			var rows_for_family: Array[Dictionary] = []
			for source_value: Variant in family_result.get("sourceRows", []):
				if not source_value is Dictionary:
					return _pending("ecology_source_domain_row_invalid", {
						"sourceChunkKey":source_chunk, "family":family})
				var producer_row: Dictionary = source_value
				_add_static_census_capture_count(metrics, "producerSourceRowCount")
				var source_family := String(producer_row.get("producerFamily", ""))
				var source_id := String(producer_row.get("sourceId", ""))
				if source_family != family or source_id.is_empty():
					return _pending("ecology_source_domain_source_identity_invalid", {
						"sourceChunkKey":source_chunk, "family":family,
						"sourceId":source_id, "producerFamily":source_family})
				var row_identity := family + "|" + source_id
				if producer_row_by_id.has(row_identity):
					return _pending("ecology_source_domain_source_identity_duplicated", {
						"sourceChunkKey":source_chunk, "family":family,
						"sourceId":source_id})
				producer_row_by_id[row_identity] = producer_row
				if family == "trees":
					continue
				_add_static_census_capture_count(metrics, "nonTreeConversionCount")
				var static_result := _compile_non_tree_source_row(main, snapshot,
					producer_row, publication_view, publication_lease_token,
					fingerprint_cache)
				if String(static_result.get("status", "")) != "ready":
					return static_result
				for support_row_value: Variant in static_result.get("supportRows", []):
					if not support_row_value is Dictionary:
						return _pending("ecology_static_source_support_row_invalid", {
							"sourceChunkKey":source_chunk, "family":family,
							"sourceId":source_id})
					rows_for_family.append(support_row_value)
					_add_static_census_capture_count(metrics, "convertedSupportRowCount")
				for artifact_value: Variant in static_result.get("memberArtifacts", []):
					if not artifact_value is Dictionary:
						return _pending("ecology_static_source_member_artifact_invalid", {
							"sourceChunkKey":source_chunk, "family":family,
							"sourceId":source_id})
					var member_artifact: Dictionary = artifact_value
					_add_static_census_capture_count(metrics, "convertedMemberArtifactCount")
					var member_key := _source_part_identity_key(source_id,
						String(member_artifact.get("sourcePartId", "")))
					if member_key.is_empty():
						return _pending("ecology_static_source_member_identity_invalid", {
							"sourceChunkKey":source_chunk, "family":family,
							"sourceId":source_id})
					_canonical_static_artifact_by_member[member_key] = member_artifact
					_track_source_publication_member(String(publication_view.get(
						"publicationId", "")), member_key)
			support_rows_by_family[family] = rows_for_family
		var selected_non_tree_families: Array[String] = []
		for family_value: Variant in requested_families:
			var family := String(family_value)
			if family != "trees":
				selected_non_tree_families.append(family)
		var published: Dictionary = {"status":"ready"}
		if not selected_non_tree_families.is_empty():
			_set_static_census_capture_phase(metrics, "support_band_registration")
			_add_static_census_capture_count(metrics, "supportProjectionCount")
			if "trees" in requested_families:
				var selected_rows_by_family: Dictionary = {}
				for family: String in selected_non_tree_families:
					if not support_rows_by_family.has(family) \
							or not support_rows_by_family[family] is Array:
						return _pending("ecology_source_family_rows_missing", {
							"sourceChunkKey":source_chunk, "family":family})
					selected_rows_by_family[family] = support_rows_by_family[family]
				published = publish_support_source_domain_family_projection(
					world_id, source_chunk, snapshot, selected_rows_by_family,
					publication_view, publication_lease_token,
					selected_non_tree_families)
			else:
				published = publish_support_source_domain_families(world_id,
					source_chunk, snapshot, support_rows_by_family,
					publication_view, publication_lease_token)
			if String(published.get("status", "")) != "ready": return published
		var dependent_sections: Array = dependent_sections_by_chunk.get(source_chunk, [])
		var capture_identity := String(capture_request.get("identity", ""))
		var tree_sections: Array = tree_demand_sections_by_chunk.get(source_chunk, [])
		_set_static_census_capture_phase(metrics, "support_band_registration")
		_add_static_census_capture_count(metrics, "bandRegistrationCount")
		if "trees" in requested_families and not tree_sections.is_empty():
			_add_static_census_capture_count(metrics, "treeBandAdmissionAttemptCount")
		for dependent_section: Vector3i in dependent_sections:
			var section_family_key := "%d,%d|%d,%d,%d" % [source_chunk.x,
				source_chunk.y, dependent_section.x, dependent_section.y,
				dependent_section.z]
			var section_families: Array[String] = []
			for family_value: Variant in requested_families_by_section_chunk.get(
					section_family_key, []):
				section_families.append(String(family_value))
			var section_tree_keys: Array = []
			if "trees" in section_families:
				section_tree_keys.append(dependent_section)
			var band_publication := _register_source_family_section_band_projections(
				main, world_id, source_chunk, [dependent_section], snapshot,
				catalog_artifact, publication_view, publication_lease_token,
				section_families, capture_identity, section_tree_keys)
			if String(band_publication.get("status", "")) != "ready":
				return band_publication
		source_rows_by_chunk[source_chunk] = snapshot
		for family: String in requested_families:
			var family_result: Dictionary = family_results.get(family, {})
			domain_identity_rows.append([source_chunk, family,
				String(snapshot.get("sourceRevision", "")),
				String(family_result.get("familyRevision", "")),
				String(family_result.get("familyPolicyRevision", "")),
				String(family_result.get("familyPolicyDigest", "")),
				String(family_result.get("sourceManifestDigest", ""))])
	if not first_failed_capture.is_empty():
		return _failed(String(first_failed_capture.get("reason",
			"ecology_source_capture_failed")), {
			"sourceChunkKey":first_failed_capture.get("sourceChunkKey", Vector2i.ZERO),
			"capture":first_failed_capture})
	if not first_pending_capture.is_empty():
		return _pending(String(first_pending_capture.get("reason",
			"ecology_source_capture_pending")), {
			"sourceChunkKey":first_pending_capture.get("sourceChunkKey", Vector2i.ZERO),
			"capture":first_pending_capture, "retryable":true})
	_set_static_census_capture_phase(metrics, "query_sealing")
	var section_rows: Dictionary = {}
	var source_revisions: Dictionary = {}
	var source_revision_first_section: Dictionary = {}
	var source_identities: Dictionary = {}
	var support_ranges_by_section: Dictionary = {}
	var tombstones_by_section: Dictionary = {}
	for section: Vector3i in sections:
		_add_static_census_capture_count(metrics, "supportSectionQueryCount")
		var query := query_section(world_id, section)
		if String(query.get("status", "")) != "ready": return query
		var ids: Array[String] = []
		_add_static_census_capture_count(metrics, "supportContributorCount",
			(query.get("contributors", []) as Array).size())
		var section_parts: Array[Dictionary] = []
		var historical_tombstones_by_pair: Dictionary = {}
		var compiled_pairs: Dictionary = {}
		var ranges: Dictionary = {}
		for contributor_value: Variant in query.get("contributors", []):
			if not contributor_value is Dictionary:
				return _pending("ecology_support_contributor_invalid")
			var current_contributor: Dictionary = contributor_value
			if String(current_contributor.get("state", "")) != "compiled":
				continue
			var current_source_id := String(current_contributor.get("sourceId", ""))
			var current_part_id := String(current_contributor.get("sourcePartId", ""))
			var current_pair_key := _source_part_identity_key(current_source_id,
				current_part_id)
			if current_source_id.is_empty() or current_part_id.is_empty() \
					or current_pair_key.is_empty():
				return _pending("ecology_support_contributor_identity_invalid")
			if compiled_pairs.has(current_pair_key):
				return _pending("ecology_support_compiled_member_identity_duplicated")
			compiled_pairs[current_pair_key] = true
		for contributor_value: Variant in query.get("contributors", []):
			if not contributor_value is Dictionary:
				return _pending("ecology_support_contributor_invalid")
			var contributor: Dictionary = contributor_value
			var source_id := String(contributor.get("sourceId", ""))
			var part_id := String(contributor.get("sourcePartId", ""))
			var pair_key := _source_part_identity_key(source_id, part_id)
			if source_id.is_empty() or part_id.is_empty() or pair_key.is_empty():
				return _pending("ecology_support_contributor_identity_invalid")
			if String(contributor.get("state", "")) == "tombstoned":
				if not historical_tombstones_by_pair.has(pair_key):
					historical_tombstones_by_pair[pair_key] = []
				var history_rows: Array = historical_tombstones_by_pair[pair_key]
				history_rows.append({
					"sourceId":source_id, "sourcePartId":part_id,
					"sourceRevision":String(contributor.get("sourceRevision", "")),
					"tombstoneRevision":String(contributor.get("tombstoneRevision", ""))})
				continue
			if String(contributor.get("state", "")) != "compiled":
				return _pending("ecology_support_member_recipe_pending", {
					"sourceId":source_id, "sourcePartId":part_id})
			var source_revision := String(contributor.get("sourceRevision", ""))
			var revision_conflict := _source_revision_conflict_details(source_id,
				part_id, pair_key, source_revision, section, source_revisions,
				source_revision_first_section)
			if not revision_conflict.is_empty():
				return _pending(String(revision_conflict.get("reason",
					"ecology_support_source_revision_conflict")), revision_conflict)
			ids.append(pair_key)
			if not source_revisions.has(pair_key):
				source_revisions[pair_key] = source_revision
				source_revision_first_section[pair_key] = section
			var identity := {"sourceId":source_id, "sourcePartId":part_id}
			identity.make_read_only()
			source_identities[pair_key] = identity
			section_parts.append(identity)
			var range := _canonical_support_range(contributor, section)
			if range.is_empty(): return _pending("ecology_source_member_support_range_invalid", {
				"sourceId":source_id, "sourcePartId":part_id})
			if not ranges.has(pair_key): ranges[pair_key] = []
			ranges[pair_key].append(range)
		var historical_pair_keys: Array = historical_tombstones_by_pair.keys()
		historical_pair_keys.sort()
		var removal_rows: Array[Dictionary] = []
		for historical_pair_key_value: Variant in historical_pair_keys:
			var historical_pair_key := String(historical_pair_key_value)
			if compiled_pairs.has(historical_pair_key):
				continue
			var history_rows: Array = historical_tombstones_by_pair[historical_pair_key]
			history_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				var a_revision := String(a.get("sourceRevision", ""))
				var b_revision := String(b.get("sourceRevision", ""))
				if a_revision != b_revision: return a_revision < b_revision
				return String(a.get("tombstoneRevision", "")) \
					< String(b.get("tombstoneRevision", "")))
			if history_rows.is_empty():
				return _pending("ecology_support_tombstone_history_invalid")
			var history_identity: Dictionary = history_rows[0]
			var removal_source_id := String(history_identity.get("sourceId", ""))
			var removal_part_id := String(history_identity.get("sourcePartId", ""))
			if removal_source_id.is_empty() or removal_part_id.is_empty():
				return _pending("ecology_support_tombstone_history_invalid")
			var removal_revision := _value_digest([
				"ecology-section-source-removal-history/v1", world_id,
				[section.x, section.y, section.z], removal_source_id,
				removal_part_id, history_rows])
			if removal_revision.is_empty():
				return _pending("ecology_support_tombstone_history_digest_failed")
			removal_rows.append({"sourceId":removal_source_id,
				"sourcePartId":removal_part_id,
				"sectionKey":section, "sourceRevision":removal_revision})
		ids.sort()
		section_parts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _source_part_identity_key(String(a.sourceId), String(a.sourcePartId)) \
				< _source_part_identity_key(String(b.sourceId), String(b.sourcePartId)))
		for range_rows: Array in ranges.values(): range_rows.make_read_only()
		ranges.make_read_only()
		removal_rows.make_read_only()
		var coverage := String(query.coverageCertificate.coverageDigest)
		section_rows[section] = {"status":"empty" if ids.is_empty() else "complete",
			"sourcePartIds":ids, "sourceParts":section_parts,
			"coverageRevision":coverage}
		support_ranges_by_section[section] = ranges
		tombstones_by_section[section] = removal_rows
		_latest_by_section[section] = source_revisions.duplicate(false)
		_latest_coverage_by_section[section] = coverage
		_latest_support_ranges_by_section[section] = ranges
	section_rows.make_read_only()
	source_revisions.make_read_only()
	source_identities.make_read_only()
	support_ranges_by_section.make_read_only()
	tombstones_by_section.make_read_only()
	domain_identity_rows.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0].x != b[0].x: return a[0].x < b[0].x
		if a[0].y != b[0].y: return a[0].y < b[0].y
		return String(a[1]) < String(b[1]))
	var catalog_artifact_id := String(catalog_artifact.get("artifactId", ""))
	if catalog_artifact_id.is_empty():
		return _pending("ecology_catalog_artifact_identity_missing")
	var authority_revision := _value_digest([SCHEMA, world_id, catalog_artifact_id,
		domain_identity_rows, section_rows, source_revisions, source_identities])
	_add_static_census_capture_count(metrics, "censusSourceRevisionCount",
		source_revisions.size())
	return {"status":"complete", "schema":SCHEMA, "providerId":PROVIDER_ID,
		"worldId":world_id,
		"authorityRevision":authority_revision,
		"catalogArtifactId":catalog_artifact_id,
		"sections":section_rows, "sourceRevisions":source_revisions,
		"sourceIdentities":source_identities,
		"preparedSections":{}, "removalsBySection":tombstones_by_section,
		"supportRangesBySection":support_ranges_by_section,
		"diagnostics":{"resourceFingerprintCache":fingerprint_cache.get("stats", {})}}


func _source_revision_conflict_details(source_id: String, source_part_id: String,
		pair_key: String, source_revision: String, section_key: Vector3i,
		source_revisions: Dictionary, first_sections: Dictionary) -> Dictionary:
	if not source_revisions.has(pair_key) \
			or String(source_revisions[pair_key]) == source_revision:
		return {}
	return {"reason":"ecology_support_source_revision_conflict",
		"sourceId":source_id, "sourcePartId":source_part_id,
		"firstSectionKey":first_sections.get(pair_key, null),
		"firstSourceRevision":String(source_revisions[pair_key]),
		"conflictingSectionKey":section_key,
		"conflictingSourceRevision":source_revision}


func _resource_fingerprint_for_census(resource: Resource,
		fingerprint_cache: Dictionary, kind: String) -> Dictionary:
	# This cache is born and consumed in one synchronous census call. Asset
	# resources are admitted by their current descriptor lease; a Resource.changed
	# signal invalidates that lease before another member can reuse the digest.
	# Procedural render resources follow the same immutable-after-admission rule.
	var caches: Dictionary = fingerprint_cache.get("resources", {})
	var stats: Dictionary = fingerprint_cache.get("stats", {})
	var entries: Dictionary = caches.get(kind, {})
	var instance_id := resource.get_instance_id() if is_instance_valid(resource) else 0
	var cached_value: Variant = entries.get(instance_id, null)
	if cached_value is Dictionary and cached_value.get("resource", null) == resource:
		stats[kind + "Hits"] = int(stats.get(kind + "Hits", 0)) + 1
		return cached_value.get("fingerprint", {})
	var fingerprint: Dictionary
	if kind == "mesh" and resource is Mesh:
		fingerprint = MeshFingerprint.inspect(resource as Mesh)
	elif kind == "material" and resource is Material:
		var material_fingerprint: Dictionary = MaterialFingerprint.inspect(resource as Material)
		fingerprint = material_fingerprint if String(material_fingerprint.get("status", "")) == "ready" \
			else {"status":"failed", "reason":String(material_fingerprint.get("reason", "material_fingerprint_failed"))}
	else:
		fingerprint = {"status":"failed", "reason":"census_fingerprint_resource_invalid"}
	stats[kind + "Misses"] = int(stats.get(kind + "Misses", 0)) + 1
	if instance_id != 0:
		entries[instance_id] = {"resource":resource, "fingerprint":fingerprint}
		caches[kind] = entries
		fingerprint_cache["resources"] = caches
	fingerprint_cache["stats"] = stats
	return fingerprint


func _canonical_support_range(row: Dictionary, section_key: Vector3i) -> Dictionary:
	var bounds: Variant = row.get("conservativeWorldBounds", null)
	var source_id := String(row.get("sourceId", ""))
	var part_id := String(row.get("sourcePartId", ""))
	var revision := String(row.get("sourceRevision", ""))
	var owner: Variant = row.get("geometryOwnerSection", null)
	var owner_chunk: Variant = row.get("sourceOwnerChunk", null)
	var member_id := String(row.get("memberId", part_id))
	var instance_index := int(row.get("instanceIndex", -1))
	var ownership_policy := String(row.get("ownershipPolicy", STATIC_PROP_SUPPORT_POLICY))
	if not bounds is AABB or source_id.is_empty() or part_id.is_empty() \
			or revision.is_empty() or not owner is Vector3i \
			or not owner_chunk is Vector2i or member_id != part_id \
			or instance_index < 0 or ownership_policy.is_empty() or section_key not in row.get(
			"conservativeSupportSectionKeys", []):
		return {}
	var dependencies: Array[Vector2i] = _stream_chunk_keys_intersecting_bounds(bounds).duplicate()
	if owner_chunk not in dependencies: dependencies.append(owner_chunk)
	dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y)
	dependencies.make_read_only()
	var support := {"sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision, "memberId":member_id,
		"propId":String(row.get("propId", "")),
		"sourceSegmentId":String(row.get("sourceSegmentId", "")),
		"sourceInstance":instance_index, "ownerCell":owner_chunk,
		"sourceOwnerChunk":owner_chunk, "geometryOwnerSection":owner,
		"supportSectionKey":section_key, "worldBounds":bounds,
		"streamChunkDependencies":dependencies,
		"ownershipPolicy":ownership_policy,
		"certifiedEnvelopeDigest":String(row.get("certifiedEnvelopeDigest", "")),
		"meshContentDigest":String(row.get("meshContentDigest", "")),
		"recipeSignature":String(row.get("recipeSignature", "")),
		"artifactGeneration":int(row.get("artifactGeneration", 0)),
		"certifiedEnvelopeProof":row.get("certifiedEnvelopeProof", {}),
		"sourceDomainRevision":String(row.get("sourceDomainRevision", "")),
		"producerSnapshotRevision":String(row.get("producerSnapshotRevision", "")),
		"terrainVolumeChunkRevision":String(row.get("terrainVolumeChunkRevision", "")),
		"structureAdmissionRevision":String(row.get("structureAdmissionRevision", "")),
		"removedSourceProjectionDigest":String(row.get("removedSourceProjectionDigest", "")),
		"influencePolicyRevision":String(row.get("influencePolicyRevision", "")),
		"influencePolicyDigest":String(row.get("influencePolicyDigest", ""))}
	support.make_read_only()
	return support


func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


func _canonical_support_policy_inputs(main: Object, world_id: String,
		source_chunk: Vector2i, seed: String, base_inputs: Dictionary) -> Dictionary:
	if not is_instance_valid(main) or not main.has_method("ecology_source_support_policy_inputs"):
		return {"status":"pending", "diagnostic":{"reason":"support_policy_provider_unavailable"}}
	var result_value: Variant = main.call("ecology_source_support_policy_inputs",
		world_id, source_chunk, seed, base_inputs)
	if not result_value is Dictionary:
		return {"status":"pending", "diagnostic":{"reason":"support_policy_provider_result_invalid"}}
	var provider_result: Dictionary = result_value
	var provider_policy: Variant = provider_result.get("supportPolicy", {})
	var provider_diagnostic := {
		"providerStatus":String(provider_result.get("status", "")),
		"providerReason":String(provider_result.get("reason", "")),
		"providerSchema":String(provider_result.get("schema", "")),
		"policyStatus":String(provider_policy.get("status", "")) \
			if provider_policy is Dictionary else "",
		"policyReason":String(provider_policy.get("runtimePolicyReason", "")) \
			if provider_policy is Dictionary else "",
		"policyRuntimeStatus":String(provider_policy.get("runtimePolicyStatus", "")) \
			if provider_policy is Dictionary else ""}
	if String(provider_result.get("status", "")) != "ready" \
			or String(provider_result.get("schema", "")) != "ecology-source-support-policy-inputs/v2" \
			or String(provider_result.get("worldId", "")) != world_id \
			or provider_result.get("sourceChunkKey", null) != source_chunk \
			or String(provider_result.get("worldSeed", "")) != seed:
		provider_diagnostic["reason"] = "support_policy_provider_identity_or_status_invalid"
		return {"status":"pending", "diagnostic":provider_diagnostic}
	var source_inputs_value: Variant = result_value.get("sourceInputs", null)
	var policy_value: Variant = result_value.get("supportPolicy", null)
	if not source_inputs_value is Dictionary or not source_inputs_value.is_read_only() \
			or not policy_value is Dictionary \
			or String(policy_value.get("status", "")) != "ready":
		provider_diagnostic["reason"] = "support_policy_values_not_ready_or_immutable"
		return {"status":"pending", "diagnostic":provider_diagnostic}
	var source_inputs: Dictionary = source_inputs_value
	var catalog_artifact: Variant = provider_result.get("catalogArtifact", null)
	if not catalog_artifact is Dictionary or not catalog_artifact.is_read_only() \
			or String(catalog_artifact.get("artifactId", "")) != String(
				provider_result.get("catalogArtifactId", "")) \
			or String(catalog_artifact.get("catalogContentDigest", "")) != String(
				provider_result.get("catalogContentDigest", "")):
		provider_diagnostic["reason"] = "support_policy_catalog_artifact_invalid"
		return {"status":"pending", "diagnostic":provider_diagnostic}
	var policy := ProducerDomainScript.support_policy(source_inputs, catalog_artifact)
	if String(policy.get("digest", "")) != String(result_value.get("influencePolicyDigest", "")) \
			or String(policy.get("revision", "")) != String(result_value.get("influencePolicyRevision", "")) \
			or policy != policy_value:
		provider_diagnostic["reason"] = "support_policy_recomputation_mismatch"
		provider_diagnostic["recomputedStatus"] = String(policy.get("status", ""))
		provider_diagnostic["recomputedReason"] = String(policy.get("runtimePolicyReason", ""))
		return {"status":"pending", "diagnostic":provider_diagnostic}
	return {"status":"ready", "sourceInputs":source_inputs,
		"catalogArtifact":catalog_artifact}


func _domain_cache_key(snapshot: Dictionary, tree_family_result: Dictionary = {}) -> String:
	var chunk: Variant = snapshot.get("sourceChunkKey", null)
	if not chunk is Vector2i: return ""
	var family_revision := String(tree_family_result.get("familyRevision", ""))
	var family_manifest_digest := String(tree_family_result.get("sourceManifestDigest", ""))
	if family_revision.length() != 64 or family_manifest_digest.length() != 64:
		return ""
	var source_inputs: Dictionary = snapshot.get("sourceInputs", {})
	return "%s|%d,%d|%s|trees|%s|%s|%s|%s" % [String(snapshot.get("worldId", "")),
		chunk.x, chunk.y, String(snapshot.get("sourceRevision", "")),
		family_revision, family_manifest_digest,
		String(source_inputs.get("catalogArtifactId", "")),
		String(snapshot.get("influencePolicyDigest", ""))]


## Retire a prepared per-tree scene visual only after every section that owns
## one of its mesh members has a current native install receipt. This mirrors
## Minecraft's section swap boundary: source acknowledgements follow accepted
## installation, never compilation or upload admission.
func acknowledge_section_install(section_key: Vector3i,
		coverage_revision: String, receipt: Dictionary) -> Dictionary:
	var current_coverage := String(_latest_coverage_by_section.get(section_key, ""))
	var current_revisions: Dictionary = _latest_by_section.get(section_key, {})
	if coverage_revision.is_empty() or current_coverage != coverage_revision \
			or not receipt.is_read_only() or receipt.get("status") != "installed" \
			or receipt.get("sectionKey") != section_key:
		return _pending("ecology_section_install_acknowledgement_stale", {
			"section":section_key})
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable")
	var queue: Variant = main.get("tree_publication_queue")
	var publications := _current_tree_publications(main)
	var acknowledged_sources: Array[String] = []
	var pending_sources: Array[String] = []
	for source_id_value: Variant in current_revisions:
		var source_id := String(source_id_value)
		var publication := _prepared_tree_publication_for_source(publications, source_id)
		if publication.is_empty() or (not bool(publication.get("prepared", false)) and not publication.has("compiled")):
			continue
		var body_value: Variant = publication.get("body", null)
		var record_value: Variant = publication.get("record", null)
		if not body_value is StaticBody3D or not record_value is Dictionary:
			pending_sources.append(source_id)
			continue
		var body: StaticBody3D = body_value
		var record: Dictionary = record_value
		var source_revision := String(current_revisions.get(source_id, ""))
		var candidate: Variant = _latest_tree_candidate_by_source.get(source_id, null)
		if not candidate is Dictionary or source_revision.is_empty() \
				or source_revision != _tree_census_source_revision(candidate, publication):
			pending_sources.append(source_id)
			continue
		var required_sections := _tree_census_section_keys(publication)
		if required_sections.is_empty():
			pending_sources.append(source_id)
			continue
		required_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			if a.x != b.x: return a.x < b.x
			if a.y != b.y: return a.y < b.y
			return a.z < b.z)
		var key := String(source_id)
		var ack: Dictionary = _tree_install_receipts_by_source.get(key, {})
		if ack.is_empty() or String(ack.get("sourceRevision", "")) != source_revision \
				or ack.get("requiredSections", []) != required_sections:
			ack = {"sourceRevision":source_revision,
				"requiredSections":required_sections.duplicate(), "receipts":{}}
		var receipts: Dictionary = ack.get("receipts", {})
		receipts[section_key] = receipt.duplicate(false)
		ack["receipts"] = receipts
		_tree_install_receipts_by_source[key] = ack
		var all_current := true
		for required: Vector3i in required_sections:
			if not receipts.has(required) or not _installed_tree_section_receipt_is_current(
					required, receipts[required]):
				all_current = false
				break
		if not all_current:
			pending_sources.append(source_id)
			continue
		if not is_instance_valid(queue) or not queue.has_method(
				"acknowledge_prepared_tree_section_install"):
			pending_sources.append(source_id)
			continue
		var result: Dictionary = queue.call(
			"acknowledge_prepared_tree_section_install", source_id,
			source_revision, required_sections, receipts)
		if result.get("status") == "acknowledged":
			_tree_install_receipts_by_source.erase(key)
			acknowledged_sources.append(source_id)
		elif String(result.get("reason", "")) == "prepared_tree_section_receipts_incomplete":
			pending_sources.append(source_id)
		else:
			return _pending("ecology_prepared_tree_install_not_acknowledged", {
				"sourceId":source_id, "detail":result})
	var visual_result := _acknowledge_legacy_visual_units(section_key,
		coverage_revision, current_revisions, receipt)
	if visual_result.get("status") not in ["acknowledged", "pending"]:
		return visual_result
	var pending_unit_ids: Variant = visual_result.get("pendingUnitIds", [])
	var has_pending: bool = not pending_sources.is_empty() \
		or (pending_unit_ids is Array and not pending_unit_ids.is_empty())
	return {"status":"pending" if has_pending else "acknowledged",
		"retryable":has_pending,
		"reason":"ecology_section_source_retirement_pending" if has_pending else "",
		"section":section_key,
		"acknowledgedTreeCount":acknowledged_sources.size(),
		"pendingTreeCount":pending_sources.size(),
		"acknowledgedSourceIds":acknowledged_sources,
		"pendingSourceIds":pending_sources,
		"legacyVisualRetirement":visual_result}


func _acknowledge_legacy_visual_units(section_key: Vector3i,
		coverage_revision: String, current_revisions: Dictionary,
		receipt: Dictionary) -> Dictionary:
	if not _installed_tree_section_receipt_is_current(section_key, receipt) \
			or not _installed_receipt_covers_provider_revision(receipt, coverage_revision):
		return _pending("ecology_legacy_visual_receipt_not_current", {"section":section_key})
	var acknowledged: Array[String] = []
	var pending: Array[String] = []
	for unit_id_value: Variant in _latest_legacy_visual_units:
		var unit_id := String(unit_id_value)
		var unit: Dictionary = _latest_legacy_visual_units[unit_id]
		var required_sections: Array = unit.get("requiredSections", [])
		if not required_sections.has(section_key):
			continue
		if not _legacy_visual_unit_section_is_current(unit, section_key,
				current_revisions) or coverage_revision != String(
				_latest_coverage_by_section.get(section_key, "")):
			pending.append(unit_id)
			continue
		var ack: Dictionary = _legacy_visual_install_receipts_by_unit.get(unit_id, {})
		if String(ack.get("unitRevision", "")) != String(unit.get("unitRevision", "")):
			ack = {"unitRevision":String(unit.get("unitRevision", "")),
				"receipts":{}, "coverageRevisions":{}}
		var receipts: Dictionary = ack.get("receipts", {})
		var coverage_revisions: Dictionary = ack.get("coverageRevisions", {})
		receipts[section_key] = receipt.duplicate(false)
		coverage_revisions[section_key] = coverage_revision
		ack["receipts"] = receipts
		ack["coverageRevisions"] = coverage_revisions
		_legacy_visual_install_receipts_by_unit[unit_id] = ack
		if not _legacy_visual_unit_receipts_are_current(unit, receipts):
			pending.append(unit_id)
			continue
		# Recensus all intersecting sections immediately before retiring the old
		# representation. A source edit between the first receipt and the last one
		# changes the descriptor revision and leaves the legacy nodes visible.
		var all_coverage_current := true
		var fresh_unit: Dictionary = {}
		for required_value: Variant in required_sections:
			var required := Vector3i(required_value)
			# Re-capture each section with the same query scope that admitted its
			# receipt. The provider's coverage digest intentionally includes all
			# authority chunks in that query, so a combined query can hash a wider
			# (but otherwise unchanged) chunk set.
			var fresh := capture_static_section_sources(_world_id, [required])
			fresh_unit = _latest_legacy_visual_units.get(unit_id, {})
			if fresh.get("status") != "complete" \
					or String(fresh_unit.get("unitRevision", "")) \
					!= String(unit.get("unitRevision", "")) \
				or not _legacy_visual_unit_section_is_current(unit, required,
						_latest_by_section.get(required, {})):
				all_coverage_current = false
				break
			if String(coverage_revisions.get(required, "")) != String(
					_latest_coverage_by_section.get(required, "")):
				all_coverage_current = false
				break
		if not all_coverage_current:
			_legacy_visual_install_receipts_by_unit.erase(unit_id)
			pending.append(unit_id)
			continue
		if not _legacy_visual_unit_receipts_are_current(unit, receipts) \
				or not _retire_legacy_visual_unit(fresh_unit):
			pending.append(unit_id)
			continue
		_legacy_visual_install_receipts_by_unit.erase(unit_id)
		_clear_legacy_visual_unit_removals(unit)
		_latest_legacy_visual_units.erase(unit_id)
		acknowledged.append(unit_id)
	return {"status":"acknowledged", "acknowledgedUnitIds":acknowledged,
		"pendingUnitIds":pending}


func _legacy_visual_unit_receipts_are_current(unit: Dictionary,
		receipts: Dictionary) -> bool:
	var required_sections: Variant = unit.get("requiredSections", null)
	if not required_sections is Array or required_sections.is_empty():
		return false
	for section_value: Variant in required_sections:
		if not section_value is Vector3i or not receipts.has(section_value) \
				or not _installed_tree_section_receipt_is_current(
					Vector3i(section_value), receipts[section_value]):
			return false
	return true


func _installed_receipt_covers_provider_revision(receipt: Dictionary,
		coverage_revision: String) -> bool:
	if coverage_revision.is_empty():
		return false
	var provider_coverage: Variant = receipt.get("providerCoverage", null)
	if not provider_coverage is Array:
		return false
	for row_value: Variant in provider_coverage:
		if row_value is Array and row_value.size() >= 2 \
				and String(row_value[0]) == PROVIDER_ID:
			return String(row_value[1]) == coverage_revision
	return false


func _legacy_visual_unit_section_is_current(unit: Dictionary,
		section_key: Vector3i, current_revisions: Dictionary) -> bool:
	if not current_revisions is Dictionary:
		return false
	var section_sources: Dictionary = unit.get("sourceRevisionsBySection", {}).get(section_key, {})
	var removed: Dictionary = unit.get("removalRevisionsBySection", {}).get(section_key, {})
	if section_sources.is_empty() and removed.is_empty():
		return false
	for source_id_value: Variant in section_sources:
		var source_id := String(source_id_value)
		if not current_revisions.has(source_id) \
				or String(current_revisions.get(source_id, "")) \
				!= String(section_sources.get(source_id, "")):
			return false
	var current_removals: Dictionary = _pending_legacy_removal_revisions_by_section.get(
		section_key, {})
	for source_id_value: Variant in removed:
		var source_id := String(source_id_value)
		if current_revisions.has(source_id) \
				or String(current_removals.get(source_id, "")) \
				!= String(removed.get(source_id, "")):
			return false
	return true


func _authoritative_section_removal_revision(world_id: String,
		section_key: Vector3i, source_id: String, prior_source_revision: String,
		current_source_revision: String, authority_rows: Array) -> String:
	return _value_digest(["ecology-authoritative-section-removal/v1", world_id,
		[section_key.x, section_key.y, section_key.z], source_id,
		prior_source_revision, current_source_revision, authority_rows])


func _clear_legacy_visual_unit_removals(unit: Dictionary) -> void:
	var removed_by_section: Dictionary = unit.get("removalRevisionsBySection", {})
	for section_value: Variant in removed_by_section:
		var section := Vector3i(section_value)
		var pending: Dictionary = _pending_legacy_removal_revisions_by_section.get(
			section, {}).duplicate(false)
		for source_id_value: Variant in removed_by_section[section_value]:
			var source_id := String(source_id_value)
			if String(pending.get(source_id, "")) == String(
					removed_by_section[section_value].get(source_id, "")):
				pending.erase(source_id)
		_pending_legacy_removal_revisions_by_section[section] = pending


func _retire_legacy_visual_unit(unit: Dictionary) -> bool:
	var owner_ref := unit.get("chunkOwner") as WeakRef
	var chunk_owner := owner_ref.get_ref() as Node3D if owner_ref != null else null
	if not is_instance_valid(chunk_owner) or not chunk_owner.is_inside_tree() \
			or chunk_owner.is_queued_for_deletion() \
			or chunk_owner.get_instance_id() != int(unit.get("chunkOwnerInstanceId", 0)):
		return false
	var targets: Variant = unit.get("targets", [])
	if not targets is Array or not targets.is_read_only() or targets.is_empty():
		return false
	var live_targets: Array[GeometryInstance3D] = []
	for target_value: Variant in targets:
		var target_ref := target_value as WeakRef
		var target := target_ref.get_ref() as GeometryInstance3D if target_ref != null else null
		if not is_instance_valid(target):
			continue
		if target.is_queued_for_deletion():
			continue
		if not target.is_inside_tree() or not chunk_owner.is_ancestor_of(target):
			return false
		if String(unit.get("kind", "")) == "decorative_detail" \
				and not target is MultiMeshInstance3D:
			return false
		if String(unit.get("kind", "")) == "static_prop":
			var prop_owner := _ancestor_with_ecology_source_id(target, chunk_owner,
				String(unit.get("sourceId", "")))
			if not is_instance_valid(prop_owner):
				return false
		live_targets.append(target)
	if live_targets.is_empty():
		# Harvest queues the entire static-prop body (and its visual children) for
		# deletion before the replacement section is installed. An empty weak-target
		# set is therefore acceptable only for an explicitly removed prop whose
		# tombstone is still the current authority revision in every old section.
		return _legacy_visual_unit_is_fully_tombstoned(unit)
	for target: GeometryInstance3D in live_targets:
		target.visible = false
		target.set_meta("ecology_section_owned", true)
		target.set_meta("ecology_retired_source_revision", String(unit.get("unitRevision", "")))
	return true


func _legacy_visual_unit_is_fully_tombstoned(unit: Dictionary) -> bool:
	if String(unit.get("kind", "")) != "static_prop":
		return false
	var source_id := String(unit.get("sourceId", ""))
	var source_revisions: Variant = unit.get("sourceRevisions", null)
	var source_revisions_by_section: Variant = unit.get("sourceRevisionsBySection", null)
	var required_sections: Variant = unit.get("requiredSections", null)
	var removals_by_section: Variant = unit.get("removalRevisionsBySection", null)
	if source_id.is_empty() or not source_revisions is Dictionary \
			or not source_revisions_by_section is Dictionary \
			or not required_sections is Array or required_sections.is_empty() \
			or not removals_by_section is Dictionary \
			or source_revisions.has(source_id):
		return false
	for section_value: Variant in required_sections:
		if not section_value is Vector3i:
			return false
		var section := Vector3i(section_value)
		var old_sources: Dictionary = source_revisions_by_section.get(section, {})
		var removals: Dictionary = removals_by_section.get(section, {})
		var pending: Dictionary = _pending_legacy_removal_revisions_by_section.get(section, {})
		var current_sources: Dictionary = _latest_by_section.get(section, {})
		var removal_revision := String(removals.get(source_id, ""))
		if old_sources.has(source_id) or current_sources.has(source_id) \
				or removal_revision.is_empty() \
				or String(pending.get(source_id, "")) != removal_revision:
			return false
	return true


func _ancestor_with_ecology_source_id(node: Node, stop: Node,
		source_id: String) -> Node:
	var cursor: Node = node
	while is_instance_valid(cursor) and cursor != stop:
		if String(cursor.get_meta("static_ecology_source_id", "")) == source_id:
			return cursor
		cursor = cursor.get_parent()
	return null


func _record_legacy_visual_unit(units: Dictionary, unit_id: String,
		kind: String, source_id: String, source_revision: String,
		section_key: Vector3i, target_value: Variant, chunk_key: Vector2i,
		chunk_owner: Node3D) -> void:
	if unit_id.is_empty() or source_id.is_empty() or source_revision.is_empty() \
			or not is_instance_valid(chunk_owner):
		return
	var unit: Dictionary = units.get(unit_id, {"kind":kind, "sourceId":source_id,
		"chunkOwner":weakref(chunk_owner), "chunkOwnerInstanceId":chunk_owner.get_instance_id(),
		"chunkOwnerKey":chunk_key,
		"sourceRevisions":{}, "sourceRevisionsBySection":{},
		"removalRevisionsBySection":{}, "requiredSections":[], "targets":[]})
	if String(unit.get("kind", "")) != kind:
		return
	var revisions: Dictionary = unit.get("sourceRevisions", {})
	if revisions.has(source_id) and String(revisions[source_id]) != source_revision:
		return
	revisions[source_id] = source_revision
	unit["sourceRevisions"] = revisions
	var section_revisions: Dictionary = unit.get("sourceRevisionsBySection", {})
	var row: Dictionary = section_revisions.get(section_key, {})
	row[source_id] = source_revision
	section_revisions[section_key] = row
	unit["sourceRevisionsBySection"] = section_revisions
	var required: Array = unit.get("requiredSections", [])
	if not required.has(section_key):
		required.append(section_key)
	unit["requiredSections"] = required
	var targets: Array = unit.get("targets", [])
	var candidate_targets: Array = target_value if target_value is Array else [target_value]
	for target_candidate: Variant in candidate_targets:
		if target_candidate is GeometryInstance3D and is_instance_valid(target_candidate):
			var already_present := false
			for target_ref_value: Variant in targets:
				var target_ref := target_ref_value as WeakRef
				if target_ref != null and target_ref.get_ref() == target_candidate:
					already_present = true
					break
			if not already_present:
				targets.append(weakref(target_candidate))
	unit["targets"] = targets
	unit["unitRevision"] = _legacy_visual_unit_revision(unit_id, kind, revisions,
		required, chunk_owner.get_instance_id(), unit.get("removalRevisionsBySection", {}),
		String(unit.get("baseUnitRevision", "")))
	units[unit_id] = unit


func _seal_legacy_visual_unit(unit: Dictionary) -> void:
	var source_revisions: Dictionary = unit.get("sourceRevisions", {})
	if not source_revisions.is_read_only():
		source_revisions.make_read_only()
	var section_revisions: Dictionary = unit.get("sourceRevisionsBySection", {})
	for section_value: Variant in section_revisions:
		var row: Dictionary = section_revisions[section_value]
		if not row.is_read_only():
			row.make_read_only()
	if not section_revisions.is_read_only():
		section_revisions.make_read_only()
	var required: Array = unit.get("requiredSections", [])
	if not required.is_read_only():
		required.make_read_only()
	var targets: Array = unit.get("targets", [])
	if not targets.is_read_only():
		targets.make_read_only()
	var removal_revisions: Dictionary = unit.get("removalRevisionsBySection", {})
	for section_value: Variant in removal_revisions:
		var row: Dictionary = removal_revisions[section_value]
		if not row.is_read_only():
			row.make_read_only()
	if not removal_revisions.is_read_only():
		removal_revisions.make_read_only()
	if not unit.is_read_only():
		unit.make_read_only()


func _legacy_visual_unit_revision(unit_id: String, kind: String,
		source_revisions: Dictionary, required_sections: Array,
		owner_instance_id: int, removal_revisions_by_section: Dictionary = {},
		base_unit_revision := "") -> String:
	var source_rows: Array = []
	for source_id_value: Variant in source_revisions:
		source_rows.append([String(source_id_value), String(source_revisions[source_id_value])])
	source_rows.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]) < String(b[0]))
	var section_rows: Array = []
	for section_value: Variant in required_sections:
		var section := Vector3i(section_value)
		section_rows.append([section.x, section.y, section.z])
	section_rows.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]: return a[0] < b[0]
		if a[1] != b[1]: return a[1] < b[1]
		return a[2] < b[2])
	var removal_rows: Array = []
	for section_value: Variant in removal_revisions_by_section:
		var section := Vector3i(section_value)
		var row: Dictionary = removal_revisions_by_section[section_value]
		var source_rows_for_section: Array = []
		for source_id_value: Variant in row:
			source_rows_for_section.append([String(source_id_value), String(row[source_id_value])])
		source_rows_for_section.sort_custom(func(a: Array, b: Array) -> bool:
			return String(a[0]) < String(b[0]))
		removal_rows.append([[section.x, section.y, section.z], source_rows_for_section])
	removal_rows.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0][0] != b[0][0]: return a[0][0] < b[0][0]
		if a[0][1] != b[0][1]: return a[0][1] < b[0][1]
		return a[0][2] < b[0][2])
	return _value_digest(["ecology-legacy-visual-unit/v2", _world_id, unit_id,
		kind, source_rows, section_rows, removal_rows, base_unit_revision,
		owner_instance_id])


func _duplicate_legacy_visual_unit(source: Dictionary) -> Dictionary:
	var duplicate := source.duplicate(false)
	duplicate["sourceRevisions"] = source.get("sourceRevisions", {}).duplicate(false)
	var section_revisions: Dictionary = {}
	for section_value: Variant in source.get("sourceRevisionsBySection", {}):
		section_revisions[section_value] = source.sourceRevisionsBySection[section_value].duplicate(false)
	duplicate["sourceRevisionsBySection"] = section_revisions
	var removal_revisions: Dictionary = {}
	for section_value: Variant in source.get("removalRevisionsBySection", {}):
		removal_revisions[section_value] = source.removalRevisionsBySection[section_value].duplicate(false)
	duplicate["removalRevisionsBySection"] = removal_revisions
	duplicate["requiredSections"] = source.get("requiredSections", []).duplicate()
	duplicate["targets"] = source.get("targets", []).duplicate()
	return duplicate


func _find_detail_batch_target(chunk_owner: Node3D, detail_type: String) -> Node3D:
	if not is_instance_valid(chunk_owner) or detail_type.is_empty():
		return null
	var decor := chunk_owner.get_node_or_null("DecorBatches")
	if not is_instance_valid(decor):
		return null
	for child: Node in decor.get_children():
		if child is MultiMeshInstance3D \
				and String(child.get_meta("detail_type", "")) == detail_type \
				and not bool(child.get_meta("ecology_section_owned", false)):
			return child as Node3D
	return null


func _find_static_prop_visual_targets(chunk_owner: Node3D,
		source_id: String) -> Array[GeometryInstance3D]:
	var output: Array[GeometryInstance3D] = []
	if not is_instance_valid(chunk_owner) or source_id.is_empty():
		return output
	var stack: Array[Node] = [chunk_owner]
	var owner_found := false
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != chunk_owner and String(node.get_meta("static_ecology_source_id", "")) == source_id:
			owner_found = true
			stack.append_array(node.get_children())
			continue
		if node != chunk_owner and String(node.get_meta("static_ecology_source_id", "")) != "":
			continue
		stack.append_array(node.get_children())
	if not owner_found:
		return output
	var visual_stack: Array[Node] = []
	for child: Node in chunk_owner.get_children():
		if String(child.get_meta("static_ecology_source_id", "")) == source_id:
			visual_stack.append(child)
	while not visual_stack.is_empty():
		var node: Node = visual_stack.pop_back()
		if node is GeometryInstance3D:
			if not bool(node.get_meta("ecology_section_owned", false)):
				output.append(node as GeometryInstance3D)
		visual_stack.append_array(node.get_children())
	return output


func _prepared_tree_publication_for_source(publications: Dictionary,
		source_id: String) -> Dictionary:
	for publication_value: Variant in publications.values():
		if not publication_value is Dictionary:
			continue
		var publication: Dictionary = publication_value
		var record_value: Variant = publication.get("record", null)
		if record_value is Dictionary and String(record_value.get("sourceId", "")) == source_id:
			return publication
	return {}
func _installed_tree_section_receipt_is_current(section_key: Vector3i,
		receipt: Dictionary) -> bool:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return false
	var coordinator: Variant = main.get("world_static_section_coordinator")
	return is_instance_valid(coordinator) and coordinator.has_method(
		"installed_section_receipt_is_current") and bool(coordinator.call(
		"installed_section_receipt_is_current", section_key, receipt))


## Common-provider contribution for the source values this adapter can render.
## It is usable only after the provider's full static ecology census is complete;
## support-only members carry exact source revisions and bounds into the same
## candidate manifest without duplicating their geometry.
func capture_static_section_contribution(census: Dictionary,
		section_key: Vector3i) -> Dictionary:
	if census.get("status") != "complete" or census.get("worldId") != _world_id \
			or not census.get("sections", []).has(section_key) \
			or not census.get("sourceProviderIds") is Dictionary \
			or not census.get("sourceRevisions") is Dictionary \
			or not census.get("expectedContributorsBySection") is Dictionary \
			or not census.get("providerCoverageRevisions") is Dictionary \
			or not census.get("providerSnapshotRevisions") is Dictionary:
		return _pending("ecology_contribution_census_unavailable")
	var provider_sources: Array[String] = []
	var expected_values: Variant = census.expectedContributorsBySection.get(section_key, null)
	if not expected_values is Array:
		return _pending("ecology_contribution_section_roster_missing")
	for source_id_value: Variant in expected_values:
		if not source_id_value is String:
			return {"status":"failed", "reason":"ecology_contribution_source_id_invalid"}
		var source_id := String(source_id_value)
		if String(census.sourceProviderIds.get(source_id, "")) == PROVIDER_ID:
			provider_sources.append(source_id)
	provider_sources.sort()
	var coverage_by_provider: Variant = census.providerCoverageRevisions.get(PROVIDER_ID, null)
	if not coverage_by_provider is Dictionary:
		return _pending("ecology_contribution_coverage_revision_missing")
	var coverage_revision := String(coverage_by_provider.get(section_key, ""))
	var authority_revision := String(census.providerSnapshotRevisions.get(PROVIDER_ID, ""))
	if coverage_revision.is_empty() or authority_revision.is_empty():
		return _pending("ecology_contribution_coverage_revision_missing")
	return _capture_nonresident_tree_section_contribution(census, section_key,
		provider_sources, coverage_revision, authority_revision)


func _capture_nonresident_tree_section_contribution(census: Dictionary,
		section_key: Vector3i, provider_sources: Array[String],
		coverage_revision: String, authority_revision: String) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main): return _pending("ecology_main_authority_unavailable")
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue) or not queue.has_method("poll_ecology_tree_source_compile"):
		return _pending("ecology_tree_source_compiler_queue_unavailable")
	var current_support: Variant = _latest_support_ranges_by_section.get(section_key, null)
	if not current_support is Dictionary:
		return _pending("ecology_contribution_support_map_missing")
	var live_support_query := _support_index.query_section(_world_id, section_key)
	if String(live_support_query.get("status", "")) != "ready" \
			or String(live_support_query.get("coverageCertificate", {}).get("coverageDigest", "")) \
			!= coverage_revision:
		return _pending("ecology_contribution_support_certificate_stale", {
			"sectionKey":section_key})
	var live_certificate: Dictionary = live_support_query.get("coverageCertificate", {})
	var support_coverage_identity := {"schema":"ecology-support-coverage-identity/v1",
		"providerId":PROVIDER_ID, "sectionKey":section_key,
		"sourceIndexRevision":int(live_support_query.get("sourceIndexRevision", -1)),
		"coverageDigest":String(live_certificate.get("coverageDigest", ""))}
	if support_coverage_identity.sourceIndexRevision < 0 \
			or support_coverage_identity.coverageDigest.length() != 64 \
			or int(live_certificate.get("sourceIndexRevision", -2)) \
			!= support_coverage_identity.sourceIndexRevision:
		return _pending("ecology_contribution_support_certificate_invalid", {
			"sectionKey":section_key})
	support_coverage_identity.make_read_only()
	var expected_by_section: Variant = census.get("expectedContributorsBySection", {})
	var expected_values: Variant = expected_by_section.get(section_key, null) \
		if expected_by_section is Dictionary else null
	if not expected_values is Array:
		return _pending("ecology_contribution_section_roster_missing")
	var expected_provider_members: Dictionary = {}
	var source_provider_ids: Dictionary = census.get("sourceProviderIds", {})
	for identity_value: Variant in expected_values:
		var identity_key := String(identity_value)
		if String(source_provider_ids.get(identity_key, "")) == PROVIDER_ID:
			expected_provider_members[identity_key] = true
	var expected_source_revisions: Dictionary = census.get("sourceRevisions", {})
	var source_identities: Dictionary = census.get("sourceIdentities", {})
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var mesh_bindings: Dictionary = {}
	var material_bindings: Dictionary = {}
	var support_ranges_by_source: Dictionary = {}
	var authority_source_revisions: Dictionary = {}
	var locally_current_publications: Dictionary = {}
	var tree_demands_by_capture: Dictionary = {}
	for identity_key: String in provider_sources:
		if not expected_provider_members.has(identity_key):
			return {"status":"failed", "reason":"ecology_contribution_unexpected_member"}
		var identity: Dictionary = source_identities.get(identity_key, {})
		var source_id := String(identity.get("sourceId", ""))
		var source_part_id := String(identity.get("sourcePartId", ""))
		if _source_part_identity_key(source_id, source_part_id) != identity_key:
			return _pending("ecology_contribution_source_identity_invalid")
		var source_revision := String(expected_source_revisions.get(identity_key, ""))
		if source_revision.is_empty():
			return _pending("ecology_contribution_source_revision_missing", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		var support_value: Variant = current_support.get(identity_key, null)
		if not support_value is Array or support_value.is_empty() or not support_value.is_read_only():
			return _pending("ecology_contribution_member_support_missing", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		for support_row_value: Variant in support_value:
			if not support_row_value is Dictionary or not support_row_value.is_read_only() \
					or String(support_row_value.get("sourceId", "")) != source_id \
					or String(support_row_value.get("sourcePartId", "")) != source_part_id \
					or String(support_row_value.get("sourceRevision", "")) != source_revision:
				return _pending("ecology_contribution_member_support_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id})
		support_ranges_by_source[identity_key] = support_value
		authority_source_revisions[identity_key] = source_revision
		var static_compiled_value: Variant = _canonical_static_artifact_by_member.get(
			identity_key, null)
		if static_compiled_value is Dictionary:
			var static_compiled: Dictionary = static_compiled_value
			if String(static_compiled.get("sourceRevision", "")) != source_revision \
					or String(static_compiled.get("sourceId", "")) != source_id \
					or String(static_compiled.get("sourcePartId", "")) != source_part_id \
					or static_compiled.get("sourceChunkKey", null) \
					!= static_compiled.get("snapshot", {}).get("sourceChunkKey", null):
				return _pending("ecology_contribution_static_artifact_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var static_snapshot: Dictionary = static_compiled.get("snapshot", {})
			var static_producer_row: Dictionary = static_compiled.get("producerRow", {})
			var static_view: Dictionary = static_compiled.get("publicationView", {})
			var static_publication_current := _candidate_publication_local_current(
				main, static_view, String(static_compiled.get("publicationLeaseToken", "")),
				locally_current_publications)
			if String(static_publication_current.get("status", "")) != "ready":
				return static_publication_current
			var current_value: Variant = main.call(
				"ecology_source_publication_record_is_current", static_view,
				String(static_compiled.get("publicationLeaseToken", "")),
				static_producer_row) \
				if main.has_method("ecology_source_publication_record_is_current") else null
			if not current_value is Dictionary or String(current_value.get("status", "")) != "ready":
				return _pending("ecology_contribution_static_source_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var static_asset_id := String(static_compiled.get("assetId", ""))
			if not static_asset_id.is_empty():
				var registry: Variant = main.get("visual_asset_registry")
				var descriptor_current := false
				if is_instance_valid(registry) and registry.has_method(
						"describe_static_asset_without_instantiation") \
						and registry.has_method("static_asset_descriptor_is_current"):
					var descriptor: Dictionary = registry.call(
						"describe_static_asset_without_instantiation", static_asset_id)
					descriptor_current = String(descriptor.get("status", "")) == "ready" \
						and bool(registry.call("static_asset_descriptor_is_current", descriptor))
				if not descriptor_current:
					return _pending("ecology_contribution_rock_descriptor_stale", {
						"sourceId":source_id, "sourcePartId":source_part_id,
						"assetId":static_asset_id})
			var static_support_row: Dictionary = static_compiled.get("supportRow", {})
			var matching_support := false
			var owner_here := false
			for support_row_value: Variant in support_value:
				if not support_row_value is Dictionary:
					continue
				var support_row: Dictionary = support_row_value
				if support_row.get("geometryOwnerSection", null) == section_key:
					owner_here = true
				if support_row.get("worldBounds", null) == static_support_row.get(
						"conservativeWorldBounds", null) \
						and String(support_row.get("certifiedEnvelopeDigest", "")) \
						== String(static_support_row.get("certifiedEnvelopeDigest", "")):
					matching_support = true
			if static_support_row.is_empty() or not matching_support:
				return _pending("ecology_contribution_static_support_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var owner_section_value: Variant = static_compiled.get("geometryOwnerSection", null)
			var compatibility: Variant = static_compiled.get("compatibility", null)
			var static_input: Variant = static_compiled.get("input", null)
			var mesh_value: Variant = static_compiled.get("mesh", null)
			var material_value: Variant = static_compiled.get("material", null)
			if not compatibility is Dictionary or not compatibility.is_read_only():
				return _pending("ecology_contribution_static_compatibility_missing", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			if owner_here != (owner_section_value == section_key):
				return _pending("ecology_contribution_static_owner_mismatch", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			if owner_here:
				if not static_input is Dictionary or not static_input.is_read_only() \
						or not compatibility is Dictionary or not compatibility.is_read_only() \
						or not mesh_value is Mesh or not material_value is Material \
						or MeshFingerprint.inspect(mesh_value).get("contentDigest", "") \
						!= String(static_compiled.get("meshDigest", "")) \
						or _material_digest(material_value) \
						!= String(static_compiled.get("materialDigest", "")):
					return _pending("ecology_contribution_static_geometry_stale", {
						"sourceId":source_id, "sourcePartId":source_part_id})
			if owner_here:
				var batch_key := String(compatibility.get("batchKey", ""))
				if compatibility_by_key.has(batch_key) \
						and compatibility_by_key[batch_key] != compatibility:
					return {"status":"failed", "reason":"ecology_contribution_batch_conflict"}
				compatibility_by_key[batch_key] = compatibility
				mesh_bindings[String(static_compiled.get("meshKey", ""))] = mesh_value
				material_bindings[String(static_compiled.get("materialKey", ""))] = material_value
				inputs.append(static_input)
			continue
		var band_cache_key := identity_key + "|%d,%d,%d" % [
			section_key.x, section_key.y, section_key.z]
		var band_compiled_value: Variant = \
			_canonical_tree_band_artifact_by_member_section.get(band_cache_key, null)
		var compiled_value: Variant = band_compiled_value \
			if band_compiled_value is Dictionary else \
			_canonical_tree_artifact_by_member.get(identity_key, null)
		if not compiled_value is Dictionary:
			return _pending("ecology_contribution_compiled_member_missing", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		var compiled: Dictionary = compiled_value
		var is_band_compile := String(compiled.get("compileKind", "")) == "tree_band"
		if is_band_compile:
			if compiled.get("sectionKey", null) != section_key \
					or compiled.get("sourceChunkKey", null) \
					!= support_value[0].get("sourceOwnerChunk", null) \
					or String(compiled.get("sourceRevision", "")) != source_revision:
				return _pending("ecology_contribution_tree_band_artifact_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id,
					"sectionKey":section_key})
			var expected_overlay: Dictionary = compiled.get("overlayReceipt", {})
			var overlay_found := false
			for overlay_value: Variant in live_certificate.get(
					"treeSectionGeometryOverlays", []):
				if not overlay_value is Dictionary:
					continue
				var overlay: Dictionary = overlay_value
				if overlay.get("sourceChunkKey", null) == compiled.get(
						"sourceChunkKey", null) \
						and overlay.get("sectionKey", null) == section_key \
						and String(overlay.get("authorityDigest", "")) == String(
							compiled.get("bandAuthority", {}).get("authorityDigest", "")) \
						and overlay == expected_overlay:
					overlay_found = true
					break
			if not overlay_found or expected_overlay.is_empty():
				return _pending("ecology_contribution_tree_band_overlay_receipt_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id,
					"sectionKey":section_key})
		var job_key := String(compiled.get("jobKey", ""))
		var capture_identity := String(compiled.get("captureIdentity", ""))
		if capture_identity.is_empty() and not is_band_compile:
			return _pending("ecology_contribution_tree_capture_identity_missing", {
				"sourceId":source_id, "sourcePartId":source_part_id, "jobKey":job_key})
		if not is_band_compile and not tree_demands_by_capture.has(capture_identity):
			var retained_demand := _tree_compile_demand_for_capture(capture_identity,
				[section_key])
			if retained_demand.is_empty():
				return _pending("ecology_contribution_tree_section_demand_missing", {
					"sourceId":source_id, "sourcePartId":source_part_id,
					"sectionKey":section_key, "jobKey":job_key})
			tree_demands_by_capture[capture_identity] = retained_demand
		var current_demand: Dictionary = compiled if is_band_compile \
			else tree_demands_by_capture.get(capture_identity, {})
		if String(current_demand.get("jobKey", "")) != job_key:
			return _pending("ecology_contribution_tree_demand_job_changed", {
				"sourceId":source_id, "sourcePartId":source_part_id, "jobKey":job_key})
		var current_compile: Dictionary
		if is_band_compile:
			var band_queue_ref: Variant = compiled.get("queueRef", null)
			var band_queue: Object = band_queue_ref.get_ref() \
				if band_queue_ref is WeakRef else queue
			if not is_instance_valid(band_queue) or not band_queue.has_method(
					"poll_ecology_tree_source_band_compile"):
				return _pending("ecology_contribution_tree_band_queue_unavailable", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			current_compile = band_queue.call(
				"poll_ecology_tree_source_band_compile", job_key,
				String(compiled.get("consumerToken", "")))
		else:
			current_compile = _poll_tree_compile_demand(queue, current_demand)
		if String(current_compile.get("status", "")) != "ready":
			return _pending(String(current_compile.get("reason",
				"ecology_contribution_compiled_source_stale")), {
				"sourceId":source_id, "sourcePartId":source_part_id,
				"jobKey":job_key})
		var artifact: Dictionary = current_compile.get("artifact", {})
		if artifact.is_empty() or artifact != compiled.get("artifact", {}):
			return _pending("ecology_contribution_compiled_artifact_changed", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		var producer_row: Dictionary = compiled.get("producerRow", {})
		var tree_view: Dictionary = compiled.get("publicationView", {})
		var tree_publication_current := _candidate_publication_local_current(
			main, tree_view, String(compiled.get("publicationLeaseToken", "")),
			locally_current_publications)
		if String(tree_publication_current.get("status", "")) != "ready":
			return tree_publication_current
		var producer_current: Variant = main.call(
			"ecology_source_publication_record_is_current", tree_view,
			String(compiled.get("publicationLeaseToken", "")), producer_row) \
			if main.has_method("ecology_source_publication_record_is_current") else null
		if not producer_current is Dictionary or String(producer_current.get("status", "")) != "ready":
			return _pending(String(producer_current.get("reason",
				"ecology_contribution_source_currentness_pending")) \
				if producer_current is Dictionary else "ecology_contribution_source_currentness_unavailable", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		var source_manifest: Dictionary = compiled.get("sourceManifest", {})
		if String(source_manifest.get("sourceId", "")) != source_id \
				or String(source_manifest.get("sourceRevision", "")) != source_revision:
			return _pending("ecology_contribution_compiled_source_revision_stale", {
				"sourceId":source_id, "sourcePartId":source_part_id})
		var exact_manifest_member := _tree_source_manifest_has_exact_member(
			source_manifest, source_part_id, section_key, support_value)
		if String(exact_manifest_member.get("status", "")) != "ready":
			return _pending(String(exact_manifest_member.get("reason",
				"ecology_contribution_compiled_source_member_stale")), {
				"sourceId":source_id, "sourcePartId":source_part_id,
				"sectionKey":section_key})
		var resource_bindings: Dictionary = artifact.get("resourceBindings", {})
		var source_chunk: Vector2i = compiled.get("sourceChunkKey", Vector2i.ZERO)
		var geometry_added := false
		for batch_value: Variant in artifact.get("batches", []):
			if not batch_value is Dictionary or batch_value.get("sectionKey", null) != section_key:
				continue
			var batch: Dictionary = batch_value
			var batch_contributors: Dictionary = batch.get("contributors", {})
			var member_value: Variant = batch_contributors.get(identity_key, null)
			if not member_value is Dictionary: continue
			var member: Dictionary = member_value
			var batch_key := String(batch.get("batchKey", ""))
			var compatibility_value: Variant = batch.get("compatibilityKey", null)
			if batch_key.is_empty() or not compatibility_value is Dictionary \
					or String(compatibility_value.get("batchKey", "")) != batch_key:
				return _pending("ecology_contribution_batch_compatibility_invalid", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var compatibility: Dictionary = compatibility_value
			var mesh_key := String(compatibility.get("meshResourceKey", ""))
			var material_key := String(compatibility.get("materialKey", ""))
			var mesh_value: Variant = resource_bindings.get(mesh_key, null)
			var material_value: Variant = resource_bindings.get(material_key, null)
			if not mesh_value is Mesh or not material_value is Material \
					or MeshFingerprint.inspect(mesh_value).get("contentDigest", "") \
					!= String(compatibility.get("meshContentDigest", "")) \
					or _material_digest(material_value) != String(compatibility.get("materialDigest", \
					compatibility.get("materialContentDigest", ""))):
				return _pending("ecology_contribution_render_resource_stale", {
					"sourceId":source_id, "sourcePartId":source_part_id,
					"batchKey":batch_key})
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != compatibility:
				return {"status":"failed", "reason":"ecology_contribution_batch_conflict"}
			compatibility_by_key[batch_key] = compatibility
			mesh_bindings[mesh_key] = mesh_value
			material_bindings[material_key] = material_value
			var attributes: Variant = member.get("instanceAttributes", null)
			var count := int(member.get("instanceCount", 0))
			if not attributes is Array or attributes.get_typed_builtin() != TYPE_FLOAT \
					or not attributes.is_read_only() or count <= 0 \
					or attributes.size() != count * InstanceAttributes.FLOATS_PER_INSTANCE:
				return _pending("ecology_contribution_member_attribute_slice_invalid", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var segment_id := "ecology-tree-member:" + _value_digest([
				source_id, source_part_id, source_revision, section_key, batch_key])
			var input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
				"sourceId":source_id, "sourcePartId":source_part_id,
				"sourceRevision":source_revision, "ownerCell":Vector2i(batch.get("ownerCell", Vector2i.ZERO)),
				"sourceToWorld":Transform3D(Basis.IDENTITY, Grid.origin_for_key(section_key)),
				"meshLocalBounds":compatibility.get("meshLocalBounds", AABB()),
				"batchKey":batch_key, "segmentId":segment_id,
				"buffer":attributes, "instanceCount":count,
				"compatibility":compatibility}
			input.make_read_only()
			inputs.append(input)
			geometry_added = true
		var owned_here := false
		for support_row_value: Variant in support_value:
			if support_row_value.get("geometryOwnerSection", null) == section_key:
				owned_here = true
		if owned_here and not geometry_added:
			return _pending("ecology_contribution_owner_member_slice_missing", {
				"sourceId":source_id, "sourcePartId":source_part_id,
				"sourceChunkKey":source_chunk})
	if expected_provider_members.size() != authority_source_revisions.size():
		return _pending("ecology_contribution_provider_member_set_incomplete")
	inputs.make_read_only()
	authority_source_revisions.make_read_only()
	compatibility_by_key.make_read_only()
	mesh_bindings.make_read_only()
	material_bindings.make_read_only()
	support_ranges_by_source.make_read_only()
	var contribution := {"providerId":PROVIDER_ID, "sectionKey":section_key,
		"coverageRevision":coverage_revision, "authorityRevision":authority_revision,
		"supportCoverageIdentity":support_coverage_identity,
		"authoritySourceRevisions":authority_source_revisions,
		"supportRangesBySource":support_ranges_by_source,
		"inputs":inputs, "compatibilityByKey":compatibility_by_key,
		"materialBindings":material_bindings, "meshBindings":mesh_bindings,
		"resourceBindings":{}}
	contribution.resourceBindings.make_read_only()
	contribution.make_read_only()
	return {"status":"ready", "contribution":contribution}


func _tree_source_manifest_has_exact_member(source_manifest: Dictionary,
		source_part_id: String, section_key: Vector3i, support_rows: Array) -> Dictionary:
	var ownership_value: Variant = source_manifest.get("geometryOwnership", null)
	if source_part_id.is_empty() or not ownership_value is Array or support_rows.is_empty():
		return _pending("ecology_contribution_compiled_source_member_manifest_missing")
	var exact_member: Dictionary = {}
	var matching_members := 0
	for member_value: Variant in ownership_value:
		if not member_value is Dictionary:
			return _pending("ecology_contribution_compiled_source_member_manifest_invalid")
		var member: Dictionary = member_value
		if String(member.get("memberId", "")) != source_part_id:
			continue
		matching_members += 1
		exact_member = member
	if matching_members != 1:
		return _pending("ecology_contribution_compiled_source_member_manifest_ambiguous", {
			"sourcePartId":source_part_id, "matchingMemberCount":matching_members})
	var member_bounds: Variant = exact_member.get("conservativeWorldBounds", null)
	var member_owner: Variant = exact_member.get("geometryOwnerSectionKey", null)
	var member_owned_section: Variant = exact_member.get("ownedSectionKey", null)
	var member_support: Variant = exact_member.get("supportSectionKeys", null)
	if not member_bounds is AABB or not member_owner is Vector3i \
			or not member_owned_section is Vector3i \
			or member_owned_section != member_owner \
			or not member_support is Array or member_support.is_empty():
		return _pending("ecology_contribution_compiled_source_member_manifest_incomplete", {
			"sourcePartId":source_part_id})
	var manifest_support_keys: Array[String] = []
	for support_key_value: Variant in member_support:
		if not support_key_value is Vector3i:
			return _pending("ecology_contribution_compiled_source_member_support_invalid", {
				"sourcePartId":source_part_id})
		manifest_support_keys.append("%d,%d,%d" % [support_key_value.x,
			support_key_value.y, support_key_value.z])
	manifest_support_keys.sort()
	var matching_support_rows := 0
	for support_row_value: Variant in support_rows:
		if not support_row_value is Dictionary:
			return _pending("ecology_contribution_support_member_row_invalid", {
				"sourcePartId":source_part_id})
		var support_row: Dictionary = support_row_value
		if String(support_row.get("sourcePartId", "")) != source_part_id:
			continue
		matching_support_rows += 1
		var support_key: Variant = support_row.get("supportSectionKey", null)
		if not support_key is Vector3i:
			return _pending("ecology_contribution_support_member_section_mismatch", {
				"sourcePartId":source_part_id, "sectionKey":section_key,
				"supportSectionKey":support_key})
		var support_key_identity := "%d,%d,%d" % [support_key.x,
			support_key.y, support_key.z]
		if support_key != section_key or support_key_identity not in manifest_support_keys:
			return _pending("ecology_contribution_support_member_section_mismatch", {
				"sourcePartId":source_part_id, "sectionKey":section_key,
				"supportSectionKey":support_key})
		if String(support_row.get("sourceId", "")) \
				!= String(source_manifest.get("sourceId", "")) \
				or String(support_row.get("sourceRevision", "")) \
				!= String(source_manifest.get("sourceRevision", "")) \
				or String(support_row.get("memberId", "")) != source_part_id \
				or int(support_row.get("sourceInstance", -1)) != int(
				exact_member.get("instanceIndex", -2)) \
				or support_row.get("geometryOwnerSection", null) != member_owner \
				or support_row.get("worldBounds", null) != member_bounds \
				or support_row.get("sourceOwnerChunk", null) \
				!= source_manifest.get("sourceChunkKey", null) \
				or String(support_row.get("meshContentDigest", "")) \
				!= String(exact_member.get("meshContentDigest", "")) \
				or String(support_row.get("certifiedEnvelopeDigest", "")) \
				!= String(exact_member.get("certifiedEnvelopeDigest", "")) \
				or String(support_row.get("recipeSignature", "")) \
				!= String(exact_member.get("recipeSignature", "")) \
				or int(support_row.get("artifactGeneration", 0)) \
				!= int(exact_member.get("artifactGeneration", -1)):
			return _pending("ecology_contribution_compiled_source_member_mismatch", {
				"sourcePartId":source_part_id,
				"geometryOwnerSection":support_row.get("geometryOwnerSection", null),
				"manifestOwnerSection":member_owner})
	if matching_support_rows != 1:
		return _pending("ecology_contribution_support_member_row_ambiguous", {
			"sourcePartId":source_part_id, "matchingRowCount":matching_support_rows})
	return {"status":"ready", "sourcePartId":source_part_id,
		"instanceIndex":int(exact_member.get("instanceIndex", -1)),
		"geometryOwnerSection":member_owner}


func _candidate_publication_local_current(main: Object, view: Dictionary,
		lease_token: String, validated_publications: Dictionary) -> Dictionary:
	var publication_id := String(view.get("publicationId", ""))
	if publication_id.is_empty() or lease_token.is_empty() or view.is_empty():
		return _pending("ecology_contribution_publication_proof_missing")
	if validated_publications.has(publication_id):
		return {"status":"ready", "publicationId":publication_id,
			"cachedForCandidate":true}
	if not is_instance_valid(main) or not main.has_method(
			"ecology_source_publication_local_is_current"):
		return _pending("ecology_contribution_publication_currentness_unavailable")
	var current: Variant = main.call(
		"ecology_source_publication_local_is_current", view, lease_token)
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		var reason := String(current.get("reason",
			"ecology_contribution_publication_source_stale")) \
			if current is Dictionary else "ecology_contribution_publication_currentness_unavailable"
		return _pending(reason, {"publicationId":publication_id,
			"currentness":current})
	validated_publications[publication_id] = true
	return {"status":"ready", "publicationId":publication_id,
		"cachedForCandidate":false}


func _discover_static_prop_source_chunks(main: Object,
		requested_sections: Array[Vector3i]) -> Dictionary:
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return _pending("ecology_source_owner_discovery_chunk_map_unavailable")
	# Every current ecology render source is anchored to its producer chunk.
	# Surface props start at least two cells inside that owner; underground
	# props start at cell centers. The widest current producer footprint is the
	# two-member surface ore cluster (<3.687m from source anchor), while detail
	# meshes remain inside their chunk. Five meters is a conservative x/z
	# closure for all source kinds, including full underground snapshots.
	# This mirrors Minecraft's bounded section-neighborhood capture, without
	# assuming its block mesher or scanning unrelated resident owners.
	var source_chunks: Dictionary = {}
	var closure_chunks: Dictionary = {}
	var prior_owner_chunks: Dictionary = {}
	for section_key: Vector3i in requested_sections:
		var section_bounds := AABB(Grid.origin_for_key(section_key),
			Vector3.ONE * Grid.SECTION_SIZE_METERS)
		var closure_bounds := AABB(
			section_bounds.position - Vector3(STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS,
				0.0, STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS),
			section_bounds.size + Vector3(STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS * 2.0,
				0.0, STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS * 2.0))
		for chunk_key: Vector2i in Partitioner._stream_chunks_intersecting_bounds(closure_bounds):
			source_chunks[chunk_key] = true
			closure_chunks[chunk_key] = true
		var prior_support_value: Variant = _latest_support_ranges_by_section.get(section_key, {})
		if not prior_support_value is Dictionary:
			return _pending("ecology_source_owner_prior_support_invalid", {
				"section":section_key})
		for prior_source_value: Variant in prior_support_value:
			var prior_source_id := String(prior_source_value)
			if prior_source_id.is_empty():
				return _pending("ecology_source_owner_prior_support_source_invalid", {
					"section":section_key})
			var prior_rows: Variant = prior_support_value[prior_source_value]
			if not prior_rows is Array or prior_rows.is_empty():
				return _pending("ecology_source_owner_prior_support_rows_invalid", {
					"section":section_key, "sourceId":prior_source_id})
			var prior_owner: Variant = null
			var prior_prop_id := ""
			for prior_row_value: Variant in prior_rows:
				if not prior_row_value is Dictionary:
					return _pending("ecology_source_owner_prior_support_row_invalid", {
						"section":section_key, "sourceId":prior_source_id})
				var prior_row: Dictionary = prior_row_value
				var row_owner: Variant = prior_row.get("sourceOwnerChunk", null)
				var row_prop_id := String(prior_row.get("propId", ""))
				if not row_owner is Vector2i or row_prop_id.is_empty() \
						or String(prior_row.get("sourceId", "")) != prior_source_id:
					return _pending("ecology_source_owner_prior_support_identity_invalid", {
						"section":section_key, "sourceId":prior_source_id})
				if prior_owner == null:
					prior_owner = row_owner
					prior_prop_id = row_prop_id
				elif prior_owner != row_owner or prior_prop_id != row_prop_id:
					return _pending("ecology_source_owner_prior_support_owner_conflict", {
						"section":section_key, "sourceId":prior_source_id})
			# Keep deletion/replay demand even when the current owner snapshot no
			# longer contains the candidate or the owner lies outside this section's
			# geometric closure. Its explicit tombstone/removal proof is still needed.
			source_chunks[Vector2i(prior_owner)] = true
			prior_owner_chunks[Vector2i(prior_owner)] = true
	if source_chunks.size() > MAX_SOURCE_OWNER_DISCOVERY_CHUNKS:
		return _pending("ecology_source_owner_discovery_budget_exceeded", {
			"chunkCount":source_chunks.size(), "limit":MAX_SOURCE_OWNER_DISCOVERY_CHUNKS})
	var keys: Array[Vector2i] = []
	for key_value: Variant in source_chunks:
		keys.append(Vector2i(key_value))
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	for chunk_key: Vector2i in keys:
		var chunk_node: Node3D = chunks_value.get(chunk_key) as Node3D
		if not is_instance_valid(chunk_node):
			return _pending("ecology_source_owner_discovery_chunk_owner_missing", {
				"chunk":chunk_key})
		if not chunk_node.has_meta("static_ecology_source_value_snapshot"):
			return _pending("ecology_source_owner_discovery_snapshot_missing", {
				"chunk":chunk_key, "classification":"unknown_not_empty"})
		var snapshot_value: Variant = chunk_node.get_meta("static_ecology_source_value_snapshot")
		if not snapshot_value is Dictionary:
			return _pending("ecology_source_owner_discovery_snapshot_missing", {
				"chunk":chunk_key})
		var snapshot: Dictionary = snapshot_value
		var validation := _validate_snapshot(snapshot)
		var expected_world_id := "seed:%s:%d" % [String(main.get("seed_text")),
			int(main.get("seed_hash"))]
		var current_source_revision := String(main.call(
			"_ecology_chunk_source_revision", chunk_key)) \
			if main.has_method("_ecology_chunk_source_revision") else ""
		if validation.get("status") != "ready" or snapshot.get("chunk") != chunk_key \
				or int(snapshot.get("producerOwnerInstanceId", 0)) != chunk_node.get_instance_id() \
				or _world_id != expected_world_id \
				or String(snapshot.get("worldSeed", "")) != String(main.get("seed_text")) \
				or current_source_revision.is_empty() \
				or String(snapshot.get("sourceRevision", "")) != current_source_revision:
			return _pending("ecology_source_owner_discovery_snapshot_stale", {
				"chunk":chunk_key, "snapshotValidation":validation,
				"expectedWorldId":expected_world_id, "providerWorldId":_world_id,
				"snapshotWorldSeed":String(snapshot.get("worldSeed", "")),
				"currentWorldSeed":String(main.get("seed_text")),
				"snapshotSourceRevision":String(snapshot.get("sourceRevision", "")),
				"currentSourceRevision":current_source_revision})
	var result_chunks: Array[Vector2i] = []
	for key_value: Variant in source_chunks:
		result_chunks.append(Vector2i(key_value))
	result_chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	return {"status":"ready", "sourceChunks":result_chunks,
		"admittedOwnerKeys":result_chunks.duplicate(),
		"scannedChunkCount":keys.size(), "closureChunkCount":closure_chunks.size(),
		"closureMarginMeters":STATIC_PROP_SOURCE_CLOSURE_MARGIN_METERS,
		"priorOwnerChunkCount":prior_owner_chunks.size()}


func _chunks_for_section(section_key: Vector3i) -> Array[Vector2i]:
	var unique: Dictionary = {}
	for chunk_value: Variant in Grid.stream_chunk_keys_intersecting_section(section_key):
		if chunk_value is Vector2i:
			unique[chunk_value] = true
	var result: Array[Vector2i] = []
	for chunk_value: Variant in unique:
		result.append(Vector2i(chunk_value))
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y)
	return result


func _capture_tree_candidate(candidate: Dictionary, section_key := Vector3i.ZERO) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable")
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue):
		return _pending("ecology_tree_publication_queue_unavailable")
	var prop_id := String(candidate.get("propId", ""))
	var source_id := String(candidate.get("sourceId", ""))
	if prop_id.is_empty() or source_id.is_empty():
		return _pending("ecology_tree_candidate_identity_missing")
	var publication: Dictionary = _current_tree_publications(main).get(prop_id, {})
	if publication.is_empty() or bool(publication.get("ambiguous", false)):
		return _pending("ecology_tree_queue_geometry_not_committed", {"sourceId":source_id})
	if publication.has("compiled"):
		return _capture_compiled_tree_candidate(candidate, publication, section_key)
	var body_value: Variant = publication.get("body", null)
	var record_value: Variant = publication.get("record", null)
	if not body_value is StaticBody3D or not record_value is Dictionary \
			or String(body_value.get_meta("prop_id", "")) != prop_id:
		return _pending("ecology_tree_queue_geometry_not_committed", {"sourceId":source_id})
	var body: StaticBody3D = body_value
	var removed_snapshot := RemovedProps.capture_for_ids(main, [prop_id])
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("ecology_tree_removed_props_snapshot_unavailable", {"sourceId":source_id})
	var captured: Dictionary
	if bool(publication.get("prepared", false)):
		captured = TreeAdapter.capture_from_prepared_record(queue, main, _world_id,
			body, record_value, removed_snapshot)
	else:
		captured = TreeAdapter.capture_from_queue_record(queue, main, _world_id,
			body, removed_snapshot)
	if captured.get("status") == "ready":
		captured["bodyGlobalTransform"] = body.global_transform
		captured["bodyInstanceId"] = body.get_instance_id()
	return captured


## Build section-local instance inputs from the surface-detail records already
## emitted by the deterministic chunk detail producer. `binding_by_source`
## maps the record's meshSource + material identity to the actual production
## Mesh, stable mesh key, pipeline revision, and material key. No visual Node is
## scanned and no RNG is consumed.
static func prepare_surface_detail(snapshot: Dictionary, binding_by_source: Dictionary,
		chunk_to_world := Transform3D.IDENTITY, world_id := "",
		unsupported_detail_types: Array[String] = [],
		underground_required := true, removed_prop_ids: Dictionary = {}) -> Dictionary:
	var validation := _validate_snapshot(snapshot)
	if validation.get("status") != "ready":
		return validation
	snapshot = _freeze_value(snapshot)
	if not binding_by_source.is_read_only():
		return _failed("mutable_detail_binding_map")
	if world_id.strip_edges().is_empty():
		return _failed("surface_detail_world_identity_missing")
	var chunk_value: Variant = snapshot.get("chunk")
	if not chunk_value is Vector2i:
		return _failed("invalid_ecology_chunk_key")
	var chunk: Vector2i = chunk_value
	var source_revision := String(snapshot.get("sourceRevision", ""))
	if not _valid_transform(chunk_to_world):
		return _failed("invalid_surface_detail_chunk_transform")
	var source_to_world: Transform3D = chunk_to_world
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var material_resources_by_key: Dictionary = {}
	var mesh_resources_by_key: Dictionary = {}
	var source_revisions: Dictionary = {}
	var candidate_ids: Array[String] = []
	var unsupported_candidate_ids: Array[String] = []
	var candidates: Array = snapshot.get("candidates", [])
	for candidate_value: Variant in candidates:
		if not candidate_value is Dictionary:
			return _failed("invalid_ecology_candidate")
		var candidate: Dictionary = candidate_value
		var prop_id := String(candidate.get("propId", ""))
		if not prop_id.is_empty() and removed_prop_ids.has(prop_id):
			continue
		if String(candidate.get("kind", "")) != "surface_detail":
			continue
		var source_id := String(candidate.get("sourceId", ""))
		var detail_type := String(candidate.get("detailType", ""))
		var mesh_source := String(candidate.get("meshSource", ""))
		var candidate_revision := String(candidate.get("contentRevision", ""))
		var transform_value: Variant = candidate.get("transform")
		var source_mesh_bounds: Variant = candidate.get("meshBounds")
		var bounds_value: Variant = candidate.get("localBounds")
		var layer_values: Variant = candidate.get("renderLayers")
		var material_values: Variant = candidate.get("materials")
		if source_id.is_empty() or detail_type.is_empty() or mesh_source.is_empty() \
				or candidate_revision.is_empty() or not transform_value is Transform3D \
				or not source_mesh_bounds is AABB or not bounds_value is AABB \
				or not layer_values is Array \
				or layer_values.size() != 1 or not material_values is Array \
				or material_values.size() != 1:
			return _failed("incomplete_surface_detail_source_value")
		var stable_id_prefix := "%s:detail:%d,%d:%s:" % [
			String(snapshot.get("worldSeed", "")), chunk.x, chunk.y, detail_type]
		if not source_id.begins_with(stable_id_prefix) \
				or _candidate_digest(candidate) != candidate_revision:
			return _failed("surface_detail_identity_or_revision_mismatch")
		if candidate_ids.has(source_id):
			return _failed("duplicate_surface_detail_source_id")
		candidate_ids.append(source_id)
		if detail_type in unsupported_detail_types:
			unsupported_candidate_ids.append(source_id)
			continue
		var binding_key := _binding_key(mesh_source, String(material_values[0]))
		var binding_value: Variant = binding_by_source.get(binding_key)
		if not binding_value is Dictionary or not binding_value.is_read_only():
			return _pending("surface_detail_mesh_material_binding_missing", {"sourceId":source_id,
				"bindingKey":binding_key})
		var binding: Dictionary = binding_value
		var mesh_value: Variant = binding.get("mesh")
		var material_value: Variant = binding.get("material")
		var mesh_key := String(binding.get("meshResourceKey", ""))
		var material_key := String(binding.get("materialKey", ""))
		var material_digest := String(binding.get("materialContentDigest", ""))
		var pipeline_revision := String(binding.get("pipelineRevision", PIPELINE_REVISION))
		if not mesh_value is Mesh or not material_value is Material \
				or mesh_key.is_empty() or material_key.is_empty() \
				or material_digest.length() != 64 or not material_digest.is_valid_hex_number(false) \
				or pipeline_revision.is_empty() \
				or material_key != String(material_values[0]) \
				or mesh_source != String(binding.get("meshSource", mesh_source)):
			return _failed("surface_detail_binding_identity_mismatch")
		if _material_digest(material_value) != material_digest:
			return _pending("surface_detail_material_resource_changed", {"sourceId":source_id})
		var render_layer := _supported_surface_detail_layer(material_value,
			String(layer_values[0]))
		if render_layer.is_empty():
			return _pending("surface_detail_render_layer_not_supported", {"sourceId":source_id,
				"renderLayer":String(layer_values[0])})
		var mesh_bounds: AABB = mesh_value.get_aabb()
		if not _valid_bounds(mesh_bounds) or not _valid_transform(transform_value) \
				or not _valid_bounds(source_mesh_bounds) \
				or not mesh_bounds.is_equal_approx(source_mesh_bounds):
			return _failed("invalid_surface_detail_geometry")
		var captured_bounds: AABB = bounds_value
		if not (transform_value * source_mesh_bounds).is_equal_approx(captured_bounds):
			return _failed("surface_detail_bounds_disagree_with_mesh")
		var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh_value)
		if mesh_fingerprint.get("status") != "ready":
			return _pending("surface_detail_mesh_fingerprint_unavailable", {"sourceId":source_id,
				"reason":String(mesh_fingerprint.get("reason", "unknown"))})
		var digest := String(mesh_fingerprint.get("contentDigest", ""))
		var visibility_end := float(candidate.get("visibilityRangeEnd", 0.0))
		var fade_margin := float(binding.get("fadeMargin", 12.0))
		var cast_shadows := String(candidate.get("shadowCasting", "off")) != "off"
		var detail_world_transform := source_to_world * (transform_value as Transform3D)
		var detail_world_bounds: AABB = detail_world_transform * mesh_bounds
		var detail_resource_revision := ProducerDomainScript.digest_value([
			"detail-resource/v1", mesh_source, mesh_key, material_key,
			pipeline_revision, digest, material_digest])
		var bound_candidate_revision := ProducerDomainScript.static_member_content_revision(
			world_id, source_id, source_id, "details", {
				"sourceChunkKey":chunk, "worldTransform":detail_world_transform,
				"meshLocalBounds":mesh_bounds, "worldBounds":detail_world_bounds,
				"meshContentDigest":digest, "materialContentDigest":material_digest,
				"materialKey":material_key,
				"renderLayer":render_layer,
				"resourceDescriptorRevision":detail_resource_revision,
				"customData":candidate.get("customData", Color.TRANSPARENT),
				"instanceColor":candidate.get("instanceColor", Color.WHITE),
				"visibilityRangeEnd":visibility_end})
		if bound_candidate_revision.length() != 64:
			return _failed("surface_detail_bound_revision_failed")
		var compatibility := _compatibility(String(material_values[0]), material_key,
			material_digest,
			mesh_key, digest, pipeline_revision, render_layer, mesh_bounds,
			cast_shadows, visibility_end, fade_margin)
		if compatibility.is_empty():
			return _failed("surface_detail_compatibility_invalid")
		var batch_key := String(compatibility.batchKey)
		if compatibility_by_key.has(batch_key) and compatibility_by_key[batch_key] != compatibility:
			return _failed("surface_detail_batch_compatibility_conflict")
		compatibility_by_key[batch_key] = compatibility
		material_resources_by_key[String(compatibility.materialKey)] = binding.get("material")
		mesh_resources_by_key[mesh_key] = mesh_value
		var transform: Transform3D = transform_value
		var color_value: Variant = candidate.get("instanceColor")
		var custom_value: Variant = candidate.get("customData")
		if not color_value is Color or not custom_value is Color:
			return _failed("surface_detail_instance_variation_missing")
		var instance_buffer := _encode_instance(transform, custom_value, color_value)
		instance_buffer.make_read_only()
		var instance_input := {
			"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
			"sourceId":source_id,
			"sourcePartId":source_id,
			"sourceRevision":bound_candidate_revision,
			"ownerCell":chunk,
			"sourceToWorld":source_to_world,
			"meshLocalBounds":mesh_bounds,
			"batchKey":batch_key,
			"segmentId":"ecology-detail:" + (source_id + "\n" + bound_candidate_revision).sha256_text(),
			"buffer":instance_buffer,
			"instanceCount":1
		}
		instance_input.make_read_only()
		inputs.append(instance_input)
		source_revisions[source_id] = bound_candidate_revision
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.sourceId) < String(b.sourceId))
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	material_resources_by_key.make_read_only()
	mesh_resources_by_key.make_read_only()
	source_revisions.make_read_only()
	var partition_result: Dictionary = {}
	if inputs.is_empty():
		partition_result = {"status":"ready", "outputs":[], "sourceRevisions":{},
			"impactedSectionKeys":[], "inputInstanceCount":0, "outputInstanceCount":0}
	else:
		var partition_envelope: Dictionary = Partitioner.partition(inputs)
		if partition_envelope.get("status") != "ready":
			return _failed("surface_detail_partition_failed:" + String(partition_envelope.get("reason", "unknown")))
		partition_result = partition_envelope.get("result", {})
		if not partition_result is Dictionary or not partition_result.is_read_only():
			return _failed("surface_detail_partition_result_invalid")
	var sections := _section_membership(partition_result.get("outputs", []))
	return {
		"status":"prepared" if unsupported_candidate_ids.is_empty() else "prepared_partial",
		"schema":SCHEMA,
		"producerRevision":source_revision,
		"chunk":chunk,
		"candidateIds":candidate_ids,
		"unsupportedCandidateIds":unsupported_candidate_ids,
		"inputs":inputs,
		"partition":partition_result,
		"compatibilityByKey":compatibility_by_key,
		"materialBindings":material_resources_by_key,
		"meshBindings":mesh_resources_by_key,
		"sourceRevisions":source_revisions,
		"sections":sections,
		"censusStatus":"pending",
		"censusReason":"ecology_static_category_coverage_incomplete",
		"missingCategories":_missing_categories(snapshot, underground_required)
	}


## The complete domain provider must account for all deterministic static
## ecology sources, including explicit empties. Current producer snapshots are
## partial, so this response fails closed even when surface detail is compiled.
static func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	if String(snapshot.get("schema", "")) != "ecology-source-values/v1" \
			or String(snapshot.get("worldSeed", "")).is_empty() \
			or not snapshot.get("chunk") is Vector2i \
			or String(snapshot.get("sourceRevision", "")).is_empty() \
			or String(snapshot.get("contentRevision", "")).is_empty() \
			or not snapshot.get("candidates") is Array:
		return _failed("invalid_or_mutable_ecology_source_snapshot")
	for candidate_value: Variant in snapshot.candidates:
		if not candidate_value is Dictionary:
			return _failed("mutable_or_invalid_ecology_candidate")
		if String(candidate_value.get("contentRevision", "")) != _candidate_digest(candidate_value):
			return _failed("ecology_candidate_revision_mismatch")
	var snapshot_copy := snapshot.duplicate(true)
	var expected_snapshot_revision := String(snapshot_copy.get("contentRevision", ""))
	snapshot_copy.erase("contentRevision")
	# MainPlaytestTools adds this lifecycle field after the producer ledger has
	# sealed its digest. Freshness is checked against the live source authority,
	# never accepted from this advisory marker.
	snapshot_copy.erase("status")
	# Runtime ownership is validated separately from deterministic content.
	snapshot_copy.erase("producerOwnerInstanceId")
	if expected_snapshot_revision != _value_digest(snapshot_copy):
		return _failed("ecology_snapshot_revision_mismatch")
	return {"status":"ready"}


static func _freeze_value(value: Variant) -> Variant:
	if value is Dictionary:
		var frozen: Dictionary = {}
		for key: Variant in value:
			frozen[key] = _freeze_value(value[key])
		frozen.make_read_only()
		return frozen
	if value is Array:
		var frozen: Array = []
		for item: Variant in value:
			frozen.append(_freeze_value(item))
		frozen.make_read_only()
		return frozen
	return value


static func _missing_categories(snapshot: Dictionary,
		underground_required := true) -> Array[String]:
	var available: Array = snapshot.get("coverage", [])
	var complete: Variant = snapshot.get("completeCategories", [])
	var missing: Array[String] = []
	for category: String in REQUIRED_ECOLOGY_CATEGORIES:
		if category == "underground_props" and not underground_required:
			continue
		var covered: bool = category in available or category in complete
		if category == "trees_foliage_geometry":
			covered = _tree_family_proof_valid(snapshot)
		if not covered:
			missing.append(category)
	return missing


static func _missing_category_evidence(snapshot: Dictionary,
		missing_categories: Array[String]) -> Dictionary:
	var evidence := {}
	var candidates: Variant = snapshot.get("candidates", [])
	for category: String in missing_categories:
		var records: Array = []
		if candidates is Array:
			for candidate_value: Variant in candidates:
				if not candidate_value is Dictionary \
						or String(candidate_value.get("category", "")) != category:
					continue
				var candidate: Dictionary = candidate_value
				var missing_members: Array = []
				for member_value: Variant in candidate.get("missingMembers", []):
					if not member_value is Dictionary:
						continue
					var member: Dictionary = member_value
					missing_members.append({"memberId":String(member.get("memberId", "")),
						"reason":String(member.get("reason", ""))})
					if missing_members.size() >= 6:
						break
				records.append({"sourceId":String(candidate.get("sourceId", "")),
					"kind":String(candidate.get("kind", "")),
					"renderStatus":String(candidate.get("renderStatus", "")),
					"pendingReason":String(candidate.get("pendingReason", "")),
					"missingMembers":missing_members})
				if records.size() >= 12:
					break
		evidence[category] = {"candidateCount":records.size(),
				"candidates":records}
	evidence.make_read_only()
	return evidence


static func _section_membership(outputs: Array) -> Dictionary:
	var members: Dictionary = {}
	var revisions: Dictionary = {}
	for output_value: Variant in outputs:
		if not output_value is Dictionary:
			continue
		var output: Dictionary = output_value
		var key: Variant = output.get("sectionKey")
		var source_id := String(output.get("sourceId", ""))
		if not key is Vector3i or source_id.is_empty():
			continue
		if not members.has(key):
			members[key] = []
		members[key].append(source_id)
		revisions[source_id] = String(output.get("sourceRevision", ""))
	var keys: Array = members.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var sealed: Dictionary = {}
	for key: Vector3i in keys:
		var ids: Array = members[key]
		ids.sort()
		ids.make_read_only()
		var digest_rows: Array = []
		for source_id: String in ids:
			digest_rows.append([source_id, String(revisions[source_id])])
		sealed[key] = {"status":"complete", "sourcePartIds":ids,
			"coverageRevision":JSON.stringify([key.x, key.y, key.z, digest_rows]).sha256_text()}
		sealed[key].make_read_only()
	sealed.make_read_only()
	return sealed


static func _binding_key(mesh_source: String, material_id: String) -> String:
	return mesh_source + "|" + material_id


static func _render_layer(producer_layer: String) -> String:
	if producer_layer == "alpha_scissor":
		return "cutout"
	if producer_layer == "opaque":
		return "opaque"
	return ""


static func _encode_instance(transform: Transform3D, custom: Color, color: Color) -> Array[float]:
	var encoded: PackedFloat32Array = InstanceAttributes.encode(transform, custom, color)
	var result: Array[float] = []
	for value: float in encoded:
		result.append(value)
	return result


static func _compatibility(producer_material: String, material_key: String,
		material_content_digest: String, mesh_resource_key: String,
		mesh_digest: String, pipeline_revision: String,
		render_layer: String, mesh_bounds: AABB, cast_shadows: bool,
		visibility_end: float, fade_margin: float) -> Dictionary:
	if producer_material.is_empty() or material_key.is_empty() \
			or material_content_digest.length() != 64 \
			or not material_content_digest.is_valid_hex_number(false) \
			or mesh_resource_key.is_empty() \
			or mesh_digest.length() != 64 or pipeline_revision.is_empty() \
			or render_layer not in ["opaque", "cutout"] or not _valid_bounds(mesh_bounds) \
			or visibility_end < 0.0 or fade_margin < 0.0:
		return {}
	var mesh_key := "%s|pipeline=%s|layer=%s|sort=none" % [
		mesh_resource_key, pipeline_revision, render_layer]
	var result := {"materialKey":material_key + "|sha256=" + material_content_digest,
		# Native section backend tiers are silhouette/structural/detail/horizon.
		# Surface-detail meshes use the shared detail budget even though their
		# source authority is environment ecology.
		"renderTier":"detail",
		"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
		"meshResourceKey":mesh_resource_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "meshLocalBounds":mesh_bounds,
		"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
		"translucentSortPolicy":"none", "castShadows":cast_shadows,
		"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
		"batchKey":"", "compatibilityKey":""}
	var batch_key := SnapshotBuilder.batch_compatibility_key(result)
	if batch_key.is_empty():
		return {}
	result["batchKey"] = batch_key
	result["compatibilityKey"] = batch_key
	result.make_read_only()
	return result


func _capture_production_chunk(chunk_key: Vector2i,
		include_resource_bindings := true) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main):
		return _pending("ecology_main_authority_unavailable", {"chunk":chunk_key})
	var chunks_value: Variant = main.get("chunks")
	if not chunks_value is Dictionary:
		return _pending("ecology_chunk_owner_map_unavailable", {"chunk":chunk_key})
	var chunk_node: Node3D = chunks_value.get(chunk_key) as Node3D
	if not is_instance_valid(chunk_node):
		return _pending("ecology_chunk_owner_unavailable", {"chunk":chunk_key})
	var snapshot_value: Variant = chunk_node.get_meta("static_ecology_source_value_snapshot", {})
	if not snapshot_value is Dictionary:
		return _pending("ecology_chunk_source_snapshot_missing_or_stale", {"chunk":chunk_key})
	var snapshot: Dictionary = snapshot_value
	var candidate_prop_ids: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if not candidate_value is Dictionary:
			continue
		var candidate_prop_id := String(candidate_value.get("propId", ""))
		if not candidate_prop_id.is_empty() and candidate_prop_id not in candidate_prop_ids:
			candidate_prop_ids.append(candidate_prop_id)
	var removed_snapshot := RemovedProps.capture_for_ids(main, candidate_prop_ids)
	if not bool(removed_snapshot.get("ok", false)):
		return _pending("ecology_removed_props_snapshot_unavailable", {"chunk":chunk_key})
	var underground_required := true
	if main.has_method("visible_world_underground_visuals_required"):
		underground_required = bool(main.call("visible_world_underground_visuals_required"))
	if String(snapshot.get("contentScope", "complete")) == "surface_pending_underground" \
			and underground_required:
		return _pending("ecology_underground_snapshot_deferred_until_underground_view", {
			"chunk":chunk_key, "deferredCategories":snapshot.get("deferredCategories", [])})
	var expected_world_id := "seed:%s:%d" % [String(main.get("seed_text")),
		int(main.get("seed_hash"))]
	if _validate_snapshot(snapshot).get("status") != "ready" \
			or _world_id != expected_world_id \
			or snapshot.get("chunk") != chunk_key \
			or int(snapshot.get("producerOwnerInstanceId", 0)) != chunk_node.get_instance_id() \
			or String(snapshot.get("worldSeed", "")) != String(main.get("seed_text")) \
			or String(snapshot.get("sourceRevision", "")) != String(main.call(
				"_ecology_chunk_source_revision", chunk_key)):
		return _pending("ecology_chunk_source_snapshot_revision_stale", {"chunk":chunk_key,
			"snapshotProducerOwnerInstanceId":int(snapshot.get("producerOwnerInstanceId", 0)),
			"currentProducerOwnerInstanceId":chunk_node.get_instance_id(),
			"snapshotRemovedPropsRevision":int(snapshot.get("removedPropsRevision", -1)),
			"currentRemovedPropsRevision":int(main.get("removed_props_revision")),
			"snapshotSourceRevision":String(snapshot.get("sourceRevision", "")),
			"currentSourceRevision":String(main.call("_ecology_chunk_source_revision", chunk_key)),
			"snapshotValidation":_validate_snapshot(snapshot)})
	var removed_prop_ids: Dictionary = {}
	for prop_id_value: Variant in removed_snapshot.get("ids", []):
		removed_prop_ids[String(prop_id_value)] = true
	removed_prop_ids.make_read_only()
	if not include_resource_bindings:
		var census_resource_bindings: Variant = chunk_node.get_meta(
			"static_ecology_render_resource_bindings", {})
		if not census_resource_bindings is Dictionary:
			return _pending("ecology_static_prop_resource_binding_map_unavailable", {
				"chunk":chunk_key})
		return {"status":"ready", "snapshot":snapshot,
			"chunkToWorld":chunk_node.global_transform,
			"undergroundRequired":underground_required,
			"removedPropIds":removed_prop_ids,
			"removedSnapshot":removed_snapshot,
			"resourceBindings":census_resource_bindings,
			"chunkOwnerInstanceId":chunk_node.get_instance_id(),
			"chunkOwner":weakref(chunk_node)}
	var bindings: Dictionary = {}
	var resource_bindings_value: Variant = chunk_node.get_meta(
		"static_ecology_render_resource_bindings", {})
	if not resource_bindings_value is Dictionary:
		return _pending("ecology_static_prop_resource_binding_map_unavailable", {"chunk":chunk_key})
	var resource_bindings: Dictionary = resource_bindings_value.duplicate(false)
	for binding_value: Variant in resource_bindings.values():
		if not binding_value is Dictionary:
			return _pending("ecology_static_prop_resource_binding_unsealed", {"chunk":chunk_key})
		if not binding_value.is_read_only():
			binding_value.make_read_only()
	resource_bindings.make_read_only()
	var detail_bindings: Dictionary = {}
	var unsupported_detail_types: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "surface_detail":
			var candidate: Dictionary = candidate_value
			var detail_type := String(candidate.get("detailType", ""))
			var mesh_source := String(candidate.get("meshSource", ""))
			var material_values: Variant = candidate.get("materials", [])
			if detail_type.is_empty() or mesh_source.is_empty() \
					or not material_values is Array or material_values.size() != 1:
				unsupported_detail_types.append(detail_type)
				continue
			var material_key := String(material_values[0])
			var surface_index := int(candidate.get("surfaceIndex", -1))
			var binding_identity := mesh_source + "|" + material_key
			if detail_bindings.has(binding_identity):
				continue
			var mesh: Variant
			var material_value: Variant
			var mesh_resource_key := ""
			if surface_index >= 0:
				if not main.has_method("detail_mesh_surface") \
						or not main.has_method("detail_surface_material") \
						or not main.has_method("detail_surface_material_key"):
					unsupported_detail_types.append(detail_type)
					continue
				mesh = main.call("detail_mesh_surface", detail_type, surface_index)
				material_value = main.call("detail_surface_material", detail_type, surface_index)
				var actual_material_key := String(main.call(
					"detail_surface_material_key", detail_type, surface_index))
				if actual_material_key.is_empty() or actual_material_key != material_key:
					unsupported_detail_types.append(detail_type)
					continue
				mesh_resource_key = "environment.detail.%s.surface.%d/v1" % [detail_type, surface_index]
			else:
				# Contract fixtures may still exercise legacy single-surface inputs.
				# Production creator records always carry the actual surface index.
				mesh = main.call("detail_mesh", detail_type)
				material_value = main.call("detail_material", detail_type)
				mesh_resource_key = "environment.detail.%s/v1" % detail_type
			if not mesh is Mesh or not material_value is Material:
				unsupported_detail_types.append(detail_type)
				continue
			var material_digest := _material_digest(material_value)
			if material_digest.is_empty():
				unsupported_detail_types.append(detail_type)
				continue
			var binding := {"mesh":mesh, "material":material_value,
				"meshSource":mesh_source, "meshResourceKey":mesh_resource_key,
				"materialKey":material_key, "materialContentDigest":material_digest,
				"pipelineRevision":PIPELINE_REVISION, "fadeMargin":12.0}
			binding.make_read_only()
			bindings[binding_identity] = binding
			detail_bindings[binding_identity] = true
	bindings.make_read_only()
	unsupported_detail_types.sort()
	if not RemovedProps.is_current_for_ids(main, removed_snapshot, candidate_prop_ids):
		return _pending("ecology_removed_props_changed_during_capture", {"chunk":chunk_key})
	return {"status":"ready", "snapshot":snapshot, "bindings":bindings,
		"resourceBindings":resource_bindings,
		"chunkToWorld":chunk_node.global_transform,
		"unsupportedDetailTypes":unsupported_detail_types,
		"undergroundRequired":underground_required,
		"removedPropIds":removed_prop_ids,
		"removedSnapshot":removed_snapshot,
		"chunkOwnerInstanceId":chunk_node.get_instance_id(),
		"chunkOwner":weakref(chunk_node)}


## Build a census-only view of already committed tree queue records. No mesh
## fingerprint, instance encoding, or section partition is performed here.
func _current_tree_publications(main: Object) -> Dictionary:
	var publications: Dictionary = {}
	var live_owner_ids_by_source: Dictionary = {}
	# The production capture fixture deliberately keeps Main detached so its
	# normal gameplay lifecycle cannot run. Node.get_tree() emits an engine error
	# for a valid but detached node, so only query the scene tree after attachment.
	var scene_tree: SceneTree = main.get_tree() if main is Node and main.is_inside_tree() else null
	if scene_tree != null:
		for node_value: Node in scene_tree.get_nodes_in_group("generated_tree_trunks"):
			if not node_value is StaticBody3D or not main.is_ancestor_of(node_value):
				continue
			var live_source_id := String(node_value.get_meta("static_ecology_source_id", ""))
			if live_source_id.is_empty():
				continue
			if not live_owner_ids_by_source.has(live_source_id):
				live_owner_ids_by_source[live_source_id] = []
			live_owner_ids_by_source[live_source_id].append(node_value.get_instance_id())
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue):
		return publications
	var prepared_records: Variant = queue.get("prepared_section_value_records")
	if prepared_records is Array:
		for prepared_value: Variant in prepared_records:
			if not prepared_value is Dictionary:
				continue
			var prepared: Dictionary = prepared_value
			var prepared_body_ref := prepared.get("body") as WeakRef
			var prepared_body: Variant = prepared_body_ref.get_ref() if prepared_body_ref != null else null
			var prepared_prop_id := String(prepared.get("propId", ""))
			if not is_instance_valid(prepared_body) or not prepared_body is StaticBody3D \
					or int(prepared.get("bodyInstanceId", 0)) != prepared_body.get_instance_id() \
					or prepared_prop_id.is_empty():
				continue
			var previous: Dictionary = publications.get(prepared_prop_id, {})
			if previous.is_empty() or int(prepared.get("artifactGeneration", 0)) \
					> int(previous.get("record", {}).get("artifactGeneration", 0)):
				publications[prepared_prop_id] = {"record":prepared,
					"body":prepared_body, "prepared":true}
	var compiled_records: Variant = queue.get("compiled_tree_section_records")
	if compiled_records is Array:
		for compiled_value: Variant in compiled_records:
			if not compiled_value is Dictionary:
				continue
			var compiled_record: Dictionary = compiled_value
			var compiled_ref := compiled_record.get("body") as WeakRef
			var compiled_body: Variant = compiled_ref.get_ref() if compiled_ref != null else null
			var compiled_prop_id := String(compiled_record.get("propId", ""))
			if not is_instance_valid(compiled_body) or not compiled_body is StaticBody3D \
					or int(compiled_record.get("bodyInstanceId", 0)) != compiled_body.get_instance_id() \
					or compiled_prop_id.is_empty():
				continue
			var previous_compiled: Dictionary = publications.get(compiled_prop_id, {})
			if previous_compiled.is_empty() or int(compiled_record.get("artifactGeneration", 0)) \
					>= int(previous_compiled.get("record", {}).get("artifactGeneration", 0)):
				publications[compiled_prop_id] = {"record":compiled_record.get("record", {}),
					"body":compiled_body, "prepared":false,
					"compiled":compiled_record.get("compiled", {}),
					"compiledRecord":compiled_record,
					"liveOwnerInstanceIds":live_owner_ids_by_source.get(
						String(compiled_record.get("sourceId", "")), []).duplicate()}
	var records_value: Variant = queue.get("published_lod_records")
	if not records_value is Array:
		return publications
	for record_value: Variant in records_value:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		var body_reference := record.get("body") as WeakRef
		var body: Variant = body_reference.get_ref() if body_reference != null else null
		var request: Variant = record.get("request", {})
		if not is_instance_valid(body) or not body is StaticBody3D \
				or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or not request is Dictionary:
			continue
		var prop_id := String((request as Dictionary).get("treeId", ""))
		if prop_id.is_empty():
			continue
		if publications.has(prop_id) and (bool(publications[prop_id].get("prepared", false)) \
				or publications[prop_id].has("compiled")):
			continue
		if publications.has(prop_id):
			publications[prop_id] = {"ambiguous":true}
		else:
			publications[prop_id] = {"record":record, "body":body, "prepared":false}
	return publications


func _tree_census_source_revision(candidate: Dictionary,
		publication: Dictionary) -> String:
	if publication.has("compiled"):
		var compiled_values := _current_compiled_tree_values(candidate, publication)
		if compiled_values.get("status") != "ready": return ""
		return _tree_section_source_revision_for_values(candidate,
			String(compiled_values.get("recipeSignature", "")),
			String(compiled_values.get("renderLodTier", "")),
			compiled_values.bodyGlobalTransform, int(compiled_values.bodyInstanceId),
			String(compiled_values.get("compiledAttributeDigest", "")),
			String(compiled_values.get("compiledSourceRevision", "")))
	if publication.is_empty() or bool(publication.get("ambiguous", false)):
		return ""
	var record_value: Variant = publication.get("record", null)
	var body_value: Variant = publication.get("body", null)
	if not record_value is Dictionary or not body_value is StaticBody3D:
		return ""
	var record: Dictionary = record_value
	var body: StaticBody3D = body_value
	var prepared := bool(publication.get("prepared", false))
	var request: Variant = record.get("request", {})
	var members: Variant = record.get("sectionValueMembers", null)
	var tier := String(record.get("tier", ""))
	var recipe_signature := String(record.get("recipeSignature", ""))
	var prop_id := String(candidate.get("propId", ""))
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	if not is_instance_valid(main) or not request is Dictionary or prop_id.is_empty() \
			or String((request as Dictionary).get("treeId", "")) != prop_id \
			or String((request as Dictionary).get("worldSeed", "")) \
				!= String(main.get("seed_text")) \
			or String(body.get_meta("prop_id", "")) != prop_id \
			or not ((request as Dictionary).get("treeWorldPosition", Vector3.INF) is Vector3) \
			or not ((request as Dictionary).get("treeWorldPosition", Vector3.INF) as Vector3).is_equal_approx(body.global_position) \
			or bool(record.get("rebuildPending", false)) \
			or recipe_signature.is_empty() or tier.is_empty() \
			or tier != String((request as Dictionary).get("renderLodTier", "")) \
			or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or record.get("bodyGlobalTransform") != body.global_transform \
			or (prepared and (String(record.get("schema", "")) != "prepared-tree-section-artifact/v1" \
				or int(record.get("artifactGeneration", 0)) <= 0 \
				or int(record.get("bodyInstanceId", 0)) != body.get_instance_id() \
				or (int(body.get_meta("tree_section_recipe_input_expected_generation", 0)) > 0 \
					and int(record.get("producerGeneration", 0)) != int(body.get_meta(\
						"tree_section_recipe_input_expected_generation", 0))) \
				or not record.get("bodyGlobalTransform") is Transform3D \
				or not (record.bodyGlobalTransform as Transform3D).is_equal_approx(body.global_transform) \
				or recipe_signature != String(record.get("recipeSignature", "")))) \
			or not body.is_inside_tree() or body.is_queued_for_deletion() \
			or not members is Array or not members.is_read_only() or members.is_empty():
		return ""
	var bole_count := 0
	for member_value: Variant in members:
		if not member_value is Dictionary or not member_value.is_read_only():
			return ""
		var member: Dictionary = member_value
		var role := String(member.get("role", ""))
		if role == "bole":
			bole_count += 1
		if role not in ["bole", "branches", "foliage"] \
				or not member.get("mesh", null) is Mesh \
				or not member.get("material", null) is Material \
				or not member.get("localTransform", null) is Transform3D \
				or not member.get("transforms", null) is Array \
				or not member.get("colors", null) is Array \
				or not member.get("customData", null) is Array:
			return ""
	if bole_count != 1:
		return ""
	var candidate_revision := String(candidate.get("contentRevision", ""))
	if candidate_revision.is_empty():
		return ""
	var grouped := TreeAdapter._members_by_role(members)
	if grouped.get("status") != "ready":
		return ""
	var raw_member_revision := TreeAdapter.raw_member_content_revision(grouped.members)
	var producer_source_revision := TreeAdapter.source_revision_from_raw_members(
		_world_id, String(main.get("seed_text")), String(candidate.get("sourceId", "")),
		recipe_signature, tier,
		Grid.logical_owner_cell_for_world_position(body.global_position),
		body.global_transform, raw_member_revision)
	return _tree_section_source_revision_for_values(candidate, recipe_signature,
		tier, body.global_transform, body.get_instance_id(), raw_member_revision,
		producer_source_revision)


func _current_compiled_tree_values(candidate: Dictionary,
		publication: Dictionary) -> Dictionary:
	var main: Object = _main_authority_ref.get_ref() if _main_authority_ref != null else null
	var body_value: Variant = publication.get("body", null)
	var compiled_record_value: Variant = publication.get("compiledRecord", null)
	if not is_instance_valid(main) or not body_value is StaticBody3D \
			or not compiled_record_value is Dictionary:
		return _pending("ecology_compiled_tree_owner_unavailable")
	var body: StaticBody3D = body_value
	var compiled_record: Dictionary = compiled_record_value
	var input: Dictionary = compiled_record.get("record", {})
	var output: Dictionary = compiled_record.get("compiled", {})
	var source_id := String(candidate.get("sourceId", ""))
	var prop_id := String(candidate.get("propId", ""))
	var queue: Variant = main.get("tree_publication_queue")
	if not is_instance_valid(queue) or not queue.has_method("compiled_tree_section_record_for_body") \
			or source_id.is_empty() or prop_id.is_empty() \
		or String(body.get_meta("static_ecology_source_id", "")) != source_id \
			or String(body.get_meta("prop_id", "")) != prop_id \
			or not body.is_in_group("generated_tree_trunks") \
			or bool(body.get_meta("tree_publication_cancelled", false)) \
			or not input.is_read_only() or not output.is_read_only() \
			or int(input.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or not input.get("bodyGlobalTransform") is Transform3D \
			or not (input.bodyGlobalTransform as Transform3D).is_equal_approx(body.global_transform) \
			or int(compiled_record.get("bodyInstanceId", 0)) != body.get_instance_id() \
			or String(compiled_record.get("contentRevision", "")) != String(input.get("contentRevision", "")):
		return _pending("ecology_compiled_tree_owner_or_recipe_stale", {"sourceId":source_id})
	var current_owner_ids: Variant = publication.get("liveOwnerInstanceIds", [])
	if not current_owner_ids is Array or current_owner_ids.size() != 1 \
			or int(current_owner_ids[0]) != body.get_instance_id():
		return _pending("ecology_compiled_tree_live_owner_roster_ambiguous", {
			"sourceId":source_id, "ownerInstanceIds":current_owner_ids})
	var live_compiled: Dictionary = queue.call("compiled_tree_section_record_for_body", body)
	if live_compiled.is_empty() \
			or String(live_compiled.get("contentRevision", "")) != String(compiled_record.get("contentRevision", "")) \
			or int(live_compiled.get("artifactGeneration", 0)) != int(compiled_record.get("artifactGeneration", 0)):
		return _pending("ecology_compiled_tree_record_replaced", {"sourceId":source_id})
	var request: Variant = input.get("request", {})
	if not request is Dictionary or String(request.get("treeId", "")) != prop_id \
			or String(request.get("worldSeed", "")) != String(main.get("seed_text")) \
			or String(request.get("renderLodTier", "")) != String(input.get("renderLodTier", "")):
		return _pending("ecology_compiled_tree_request_stale", {"sourceId":source_id})
	var removed := RemovedProps.capture_for_ids(main, [prop_id])
	if not bool(removed.get("ok", false)) or (removed.get("ids", []) as Array).has(prop_id) \
			or not RemovedProps.is_current_for_ids(main, removed, [prop_id]):
		return _pending("ecology_compiled_tree_removed_or_snapshot_stale", {"sourceId":source_id})
	var manifest_value: Variant = output.get("sources", [])
	if not manifest_value is Array:
		return _pending("ecology_compiled_tree_manifest_missing", {"sourceId":source_id})
	var source_manifest: Dictionary = {}
	for source_value: Variant in manifest_value:
		if source_value is Dictionary and String(source_value.get("sourceId", "")) == source_id:
			source_manifest = source_value
			break
	if source_manifest.is_empty() or source_manifest.get("ownedSectionKeys", []).is_empty() \
			or String(source_manifest.get("recipeArtifactRevision", "")) != String(input.get("contentRevision", "")):
		return _pending("ecology_compiled_tree_source_manifest_stale", {"sourceId":source_id})
	var bindings: Variant = output.get("resourceBindings", {})
	if not bindings is Dictionary or not bindings.is_read_only() \
			or not _compiled_tree_resources_current(bindings):
		return _pending("ecology_compiled_tree_resource_fingerprint_stale", {"sourceId":source_id})
	return {"status":"ready", "record":input, "output":output,
		"sourceManifest":source_manifest, "body":body,
		"bodyGlobalTransform":body.global_transform,
		"bodyInstanceId":body.get_instance_id(),
		"renderLodTier":String(input.get("renderLodTier", "")),
		"recipeSignature":String(input.get("recipeSignature", "")),
		"compiledAttributeDigest":String(source_manifest.get("compiledAttributeDigest", "")),
		"compiledSourceRevision":String(source_manifest.get("sourceRevision", ""))}


func _compiled_tree_resources_current(bindings: Dictionary) -> bool:
	for key_value: Variant in bindings:
		var key := String(key_value)
		var resource: Variant = bindings[key_value]
		if key.begins_with("tree.runtime."):
			if not resource is Mesh: return false
			var report := MeshFingerprint.inspect(resource as Mesh)
			if report.get("status") != "ready" \
					or not key.contains(String(report.get("contentDigest", ""))):
				return false
		elif key.begins_with("tree.material."):
			if not resource is Material: return false
			var digest := _material_digest(resource as Material)
			if digest.is_empty() or not key.ends_with(digest): return false
		else:
			return false
	return true


func _capture_compiled_tree_candidate(candidate: Dictionary,
		publication: Dictionary, section_key := Vector3i.ZERO) -> Dictionary:
	var current := _current_compiled_tree_values(candidate, publication)
	if current.get("status") != "ready": return current
	var output: Dictionary = current.output
	var source_id := String(candidate.get("sourceId", ""))
	var compatibility: Dictionary = {}
	var meshes: Dictionary = {}
	var materials: Dictionary = {}
	var partition_outputs: Array[Dictionary] = []
	for batch_value: Variant in output.get("batches", []):
		if not batch_value is Dictionary: return _pending("ecology_compiled_tree_batch_invalid")
		var batch: Dictionary = batch_value
		if Vector3i(batch.get("sectionKey", Vector3i.ZERO)) != section_key:
			continue
		var contributors_value: Variant = batch.get("contributors", {})
		if not contributors_value is Dictionary:
			return _pending("ecology_compiled_tree_batch_contributors_invalid")
		var contributors: Dictionary = contributors_value
		var member_keys: Array[String] = []
		for member_key_value: Variant in contributors:
			var member_value: Variant = contributors[member_key_value]
			if member_value is Dictionary \
					and String(member_value.get("sourceId", "")) == source_id:
				member_keys.append(String(member_key_value))
		member_keys.sort()
		for member_key in member_keys:
			var contributor: Dictionary = contributors[member_key]
			var source_part_id := String(contributor.get("sourcePartId", ""))
			if source_part_id.is_empty() \
					or member_key != _source_part_identity_key(source_id, source_part_id):
				return _pending("ecology_compiled_tree_batch_member_identity_invalid", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var source_buffer: Variant = contributor.get("instanceAttributes", null)
			var count := int(contributor.get("instanceCount", -1))
			if not source_buffer is Array or not source_buffer.is_read_only() or count <= 0 \
					or source_buffer.size() != count * InstanceAttributes.FLOATS_PER_INSTANCE \
					or String(contributor.get("sourceRevision", "")) != String(current.compiledSourceRevision):
				return _pending("ecology_compiled_tree_batch_membership_invalid", {
					"sourceId":source_id, "sourcePartId":source_part_id})
			var buffer: Array[float] = []
			for component_value: Variant in source_buffer:
				if not component_value is float or not is_finite(float(component_value)):
					return _pending("ecology_compiled_tree_instance_attribute_invalid", {
						"sourceId":source_id, "sourcePartId":source_part_id})
				buffer.append(float(component_value))
			buffer.make_read_only()
			var batch_key := String(batch.get("batchKey", ""))
			var compatibility_value: Variant = batch.get("compatibilityKey", null)
			if batch_key.is_empty() or not compatibility_value is Dictionary \
					or not compatibility_value.is_read_only() \
					or String(compatibility_value.get("batchKey", "")) != batch_key:
				return _pending("ecology_compiled_tree_batch_compatibility_invalid")
			compatibility[batch_key] = compatibility_value
			var bindings: Dictionary = output.resourceBindings
			var mesh_key := String(batch.get("meshKey", ""))
			var material_key := String(batch.get("materialKey", ""))
			if not bindings.get(mesh_key) is Mesh or not bindings.get(material_key) is Material:
				return _pending("ecology_compiled_tree_resource_binding_missing")
			meshes[mesh_key] = bindings[mesh_key]
			materials[material_key] = bindings[material_key]
			var segment := {"ownerCell":batch.get("ownerCell", Vector2i.ZERO),
				"meshLocalBounds":compatibility_value.get("meshLocalBounds", AABB()),
				"buffer":buffer, "instanceCount":count}
			segment.make_read_only()
			partition_outputs.append({"sectionKey":batch.get("sectionKey", Vector3i.ZERO),
				"sourceId":source_id, "sourcePartId":source_part_id,
				"batchKey":batch_key,
				"segmentId":"%s:%s:%s:%s" % [source_id, source_part_id,
					String(batch.get("role", "")), batch.get("sectionKey")],
				"segment":segment})
	var source_manifest: Dictionary = current.sourceManifest
	if partition_outputs.is_empty() \
			and section_key in source_manifest.get("ownedSectionKeys", []):
		return _pending("ecology_compiled_tree_owned_section_batch_missing", {
			"sourceId":source_id, "section":section_key})
	partition_outputs.make_read_only()
	compatibility.make_read_only()
	meshes.make_read_only()
	materials.make_read_only()
	return {"status":"ready", "schema":TreeAdapter.SCHEMA,
		"worldId":_world_id, "sourceId":source_id,
		"sourceRevision":String(current.compiledSourceRevision),
		"producerRevision":String(current.recipeSignature),
		"rawMemberContentRevision":String(current.compiledAttributeDigest),
		"bodyGlobalTransform":current.bodyGlobalTransform,
		"bodyInstanceId":current.bodyInstanceId,
		"renderLodTier":current.renderLodTier,
		"sectionKeys":source_manifest.get("ownedSectionKeys", []),
		"supportSectionKeys":source_manifest.get("sectionKeys", []),
		"geometryOwnership":source_manifest.get("geometryOwnership", []),
		"emptyOwnedSection":partition_outputs.is_empty(),
		"compatibilityByKey":compatibility,
		"meshBindings":meshes, "materialBindings":materials,
		"partition":{"status":"ready", "outputs":partition_outputs}}


func _tree_section_source_revision(candidate: Dictionary,
		captured: Dictionary) -> String:
	var producer_revision := String(captured.get("producerRevision", ""))
	var tier := String(captured.get("renderLodTier", ""))
	var body_transform: Variant = captured.get("bodyGlobalTransform", null)
	var body_instance_id := int(captured.get("bodyInstanceId", 0))
	var raw_member_revision := String(captured.get("rawMemberContentRevision", ""))
	var producer_source_revision := String(captured.get("sourceRevision", ""))
	if producer_revision.is_empty() or tier.is_empty() \
			or not body_transform is Transform3D or body_instance_id <= 0 \
			or raw_member_revision.is_empty() or producer_source_revision.is_empty():
		return ""
	return _tree_section_source_revision_for_values(candidate, producer_revision,
		tier, body_transform as Transform3D, body_instance_id, raw_member_revision,
		producer_source_revision)


func _tree_section_source_revision_for_values(candidate: Dictionary,
		producer_revision: String, tier: String, body_transform: Transform3D,
		body_instance_id: int, raw_member_revision: String,
		producer_source_revision: String) -> String:
	if producer_revision.is_empty() or tier.is_empty() or body_instance_id <= 0 \
			or raw_member_revision.is_empty() or producer_source_revision.is_empty():
		return ""
	var candidate_revision := String(candidate.get("contentRevision", ""))
	return _value_digest([TREE_SECTION_SOURCE_REVISION_SCHEMA, _world_id,
		String(candidate.get("sourceId", "")), candidate_revision,
		producer_revision, tier, body_transform, body_instance_id,
		raw_member_revision, producer_source_revision])


## Census section ownership from committed queue values only. This mirrors the
## shared partitioner's center rule without fingerprinting, encoding attributes,
## building tree geometry, or invoking TreeAdapter.partition.
func _tree_census_section_keys(publication: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	if publication.has("compiled"):
		var compiled: Dictionary = publication.get("compiled", {})
		var sources: Variant = compiled.get("sources", [])
		if sources is Array:
			for source_value: Variant in sources:
				if source_value is Dictionary:
					for key_value: Variant in source_value.get("ownedSectionKeys", []):
						if key_value is Vector3i and key_value not in result:
							result.append(key_value)
		return result
	var body_value: Variant = publication.get("body", null)
	var record_value: Variant = publication.get("record", null)
	if not body_value is StaticBody3D or not record_value is Dictionary:
		return result
	var body: StaticBody3D = body_value
	var record: Dictionary = record_value
	var members_value: Variant = record.get("sectionValueMembers", null)
	if not members_value is Array or not members_value.is_read_only():
		return result
	for member_value: Variant in members_value:
		if not member_value is Dictionary:
			return []
		var member: Dictionary = member_value
		var mesh_value: Variant = member.get("mesh", null)
		var local_transform_value: Variant = member.get("localTransform", null)
		var transforms_value: Variant = member.get("transforms", null)
		var colors_value: Variant = member.get("colors", null)
		var custom_data_value: Variant = member.get("customData", null)
		if not mesh_value is Mesh or not local_transform_value is Transform3D \
				or not (local_transform_value as Transform3D).is_finite() \
				or not transforms_value is Array or not transforms_value.is_read_only() \
				or not colors_value is Array or not colors_value.is_read_only() \
				or not custom_data_value is Array or not custom_data_value.is_read_only() \
				or transforms_value.size() == 0 \
				or transforms_value.size() != colors_value.size() \
				or transforms_value.size() != custom_data_value.size():
			return []
		var mesh_bounds: AABB = (mesh_value as Mesh).get_aabb()
		if not _valid_bounds(mesh_bounds):
			return []
		for index: int in range(transforms_value.size()):
			var member_transform_value: Variant = transforms_value[index]
			if not member_transform_value is Transform3D \
					or not (member_transform_value as Transform3D).is_finite() \
					or not colors_value[index] is Color \
					or not custom_data_value[index] is Color:
				return []
			var world_transform: Transform3D = body.global_transform \
				* (local_transform_value as Transform3D) \
				* (member_transform_value as Transform3D)
			var world_bounds: AABB = world_transform * mesh_bounds
			if not _valid_bounds(world_bounds):
				return []
			var section_key := Grid.key_for_world_position(world_bounds.get_center())
			if section_key not in result:
				result.append(section_key)
	return result


func _compiled_tree_support_ranges(publication: Dictionary, source_id: String,
		source_revision: String) -> Dictionary:
	var compiled_value: Variant = publication.get("compiled", null)
	if not compiled_value is Dictionary:
		return _pending("ecology_tree_support_manifest_not_compiled", {"sourceId":source_id})
	var sources_value: Variant = compiled_value.get("sources", null)
	if not sources_value is Array:
		return _pending("ecology_tree_support_manifest_missing", {"sourceId":source_id})
	var manifest: Dictionary = {}
	for value: Variant in sources_value:
		if value is Dictionary and String(value.get("sourceId", "")) == source_id:
			manifest = value
			break
	if manifest.is_empty():
		return _pending("ecology_tree_support_manifest_source_missing", {"sourceId":source_id})
	var ownership: Variant = manifest.get("geometryOwnership", null)
	var transform_value: Variant = manifest.get("bodyGlobalTransform", null)
	if not ownership is Array or ownership.is_empty() or not transform_value is Transform3D \
			or not (transform_value as Transform3D).is_finite():
		return _pending("ecology_tree_support_members_missing", {"sourceId":source_id})
	var source_origin := (transform_value as Transform3D).origin
	var source_owner_chunk := Grid.chunk_key_for_world_position(source_origin)
	var by_section: Dictionary = {}
	for member_value: Variant in ownership:
		if not member_value is Dictionary:
			return _pending("ecology_tree_support_member_invalid", {"sourceId":source_id})
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var bounds: Variant = member.get("conservativeWorldBounds", null)
		var owner_section: Variant = member.get("geometryOwnerSectionKey", null)
		var member_index := int(member.get("instanceIndex", -1))
		if member_id.is_empty() or not bounds is AABB or not _valid_bounds(bounds) \
				or not owner_section is Vector3i or member_index < 0 \
				or String(member.get("certifiedEnvelopeDigest", "")).length() != 64:
			return _pending("ecology_tree_support_member_uncertified", {
				"sourceId":source_id, "memberId":member_id})
		var dependencies: Array[Vector2i] = \
			_stream_chunk_keys_intersecting_bounds(bounds).duplicate()
		if source_owner_chunk not in dependencies:
			dependencies.append(source_owner_chunk)
			dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return a.x < b.x if a.x != b.x else a.y < b.y)
		dependencies.make_read_only()
		for support_section: Vector3i in member.get("supportSectionKeys", []):
			if not Grid.keys_intersecting_bounds(bounds).has(support_section):
				return _pending("ecology_tree_support_member_sections_invalid", {
					"sourceId":source_id, "memberId":member_id})
			var row := {"sourceId":source_id, "sourcePartId":member_id,
				"sourceRevision":source_revision, "memberId":member_id,
				"instanceIndex":member_index,
				"propId":String(manifest.get("propId", source_id)),
				"sourceSegmentId":"ecology-static:%s:%s" % [member_id, source_revision],
				"sourceInstance":member_index, "ownerCell":source_owner_chunk,
				"sourceOwnerChunk":source_owner_chunk,
				"geometryOwnerSection":owner_section,
				"supportSectionKey":support_section, "worldBounds":bounds,
				"streamChunkDependencies":dependencies,
				"ownershipPolicy":STATIC_PROP_SUPPORT_POLICY,
				"certifiedEnvelopeDigest":String(member.certifiedEnvelopeDigest),
				"meshContentDigest":String(member.get("meshContentDigest", "")),
				"recipeSignature":String(manifest.get("recipeSignature", "")),
				"artifactGeneration":int(manifest.get("artifactGeneration", 0)),
				"certifiedEnvelopeProof":member.get("certifiedEnvelopeProof", {})}
			row.make_read_only()
			if not by_section.has(support_section): by_section[support_section] = []
			by_section[support_section].append(row)
	for rows: Array in by_section.values():
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("memberId", "")) < String(b.get("memberId", "")))
		rows.make_read_only()
	by_section.make_read_only()
	return {"status":"ready", "supportRangesBySection":by_section}


func _static_prop_source_revision(world_id: String, snapshot: Dictionary,
		candidate: Dictionary) -> String:
	var candidate_revision := String(candidate.get("contentRevision", ""))
	var source_id := String(candidate.get("sourceId", ""))
	var family := String(candidate.get("category", ""))
	if candidate_revision.is_empty() or source_id.is_empty() or family.is_empty():
		return ""
	# Candidate contentRevision seals the complete immutable realized-prop value,
	# including its transform and every member's mesh/material/layer attributes.
	# Producer-domain freshness is bound separately by the support-domain receipt.
	return _value_digest(["ecology-static-prop-render-content/v2",
		world_id, source_id, family, candidate_revision])


func _support_footprint_removal_revision(world_id: String, section_key: Vector3i,
		source_id: String, prior_rows: Array, replacement_source_id: String,
		replacement_rows: Array, replacement_source_revision: String) -> String:
	if world_id.is_empty() or source_id.is_empty() or prior_rows.is_empty() \
			or replacement_source_id.is_empty() or replacement_source_revision.is_empty():
		return ""
	var prior_source_revision := ""
	var prior_identities: Array = []
	for row_value: Variant in prior_rows:
		if not row_value is Dictionary or not row_value.is_read_only():
			return ""
		var row: Dictionary = row_value
		var row_source_id := String(row.get("sourceId", ""))
		var row_part_id := String(row.get("sourcePartId", ""))
		var row_revision := String(row.get("sourceRevision", ""))
		if row_source_id != source_id or row_part_id.is_empty() or row_revision.is_empty() \
				or not SectionSnapshot._validate_support_range(row, section_key,
					row_source_id, row_part_id, row_revision):
			return ""
		if prior_source_revision.is_empty():
			prior_source_revision = row_revision
		elif prior_source_revision != row_revision:
			return ""
		prior_identities.append([row_source_id, row_part_id])
	prior_identities.sort_custom(func(a: Array, b: Array) -> bool:
		return _source_part_identity_key(String(a[0]), String(a[1])) \
			< _source_part_identity_key(String(b[0]), String(b[1])))
	var replacement_identities: Array = []
	for row_value: Variant in replacement_rows:
		if not row_value is Dictionary or not row_value.is_read_only():
			return ""
		var row: Dictionary = row_value
		var row_source_id := String(row.get("sourceId", ""))
		var row_part_id := String(row.get("sourcePartId", ""))
		if row_source_id != replacement_source_id or row_part_id.is_empty() \
				or String(row.get("sourceRevision", "")) != replacement_source_revision \
				or not SectionSnapshot._validate_support_range(row, section_key,
					row_source_id, row_part_id, replacement_source_revision):
			return ""
		replacement_identities.append([row_source_id, row_part_id])
	replacement_identities.sort_custom(func(a: Array, b: Array) -> bool:
		return _source_part_identity_key(String(a[0]), String(a[1])) \
			< _source_part_identity_key(String(b[0]), String(b[1])))
	if prior_identities == replacement_identities \
			and source_id == replacement_source_id \
			and prior_source_revision == replacement_source_revision:
		return ""
	return _value_digest(["ecology-support-footprint-removal/v2", world_id,
		section_key, prior_identities, prior_source_revision,
		replacement_identities, replacement_source_revision])


func _static_prop_member_values_valid(candidate: Dictionary) -> bool:
	var members: Variant = candidate.get("renderMembers", null)
	var body_transform: Variant = candidate.get("transform", null)
	if not members is Array or members.is_empty() or not body_transform is Transform3D \
			or not _valid_transform(body_transform):
		return false
	var member_ids: Dictionary = {}
	var union_bounds := AABB()
	var has_bounds := false
	for member_value: Variant in members:
		if not member_value is Dictionary:
			return false
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var transform: Variant = member.get("transform", null)
		var mesh_bounds: Variant = member.get("meshBounds", null)
		var bounds: Variant = member.get("localBounds", null)
		if member_id.is_empty() or member_ids.has(member_id) \
				or String(member.get("meshContentDigest", "")).length() != 64 \
				or String(member.get("materialContentDigest", "")).length() != 64 \
				or not transform is Transform3D or not _valid_transform(transform) \
				or not mesh_bounds is AABB or not _valid_bounds(mesh_bounds) \
				or not bounds is AABB or not _valid_bounds(bounds) \
				or not ((transform as Transform3D) * (mesh_bounds as AABB)).is_equal_approx(bounds) \
				or String(member.get("materialKey", "")).is_empty() \
				or String(member.get("renderLayer", "")).is_empty():
			return false
		member_ids[member_id] = true
		union_bounds = bounds if not has_bounds else union_bounds.merge(bounds)
		has_bounds = true
	return has_bounds and union_bounds.is_equal_approx(candidate.get("localBounds", AABB()))


func _static_prop_support_ranges(snapshot: Dictionary, candidate: Dictionary,
		chunk_to_world: Transform3D, resource_bindings_value: Variant,
		world_id: String) -> Dictionary:
	if not resource_bindings_value is Dictionary:
		return _pending("ecology_static_prop_support_resource_bindings_missing")
	var source_id := String(candidate.get("sourceId", ""))
	var prop_id := String(candidate.get("propId", ""))
	var source_revision := _static_prop_source_revision(world_id, snapshot, candidate)
	var body_transform: Variant = candidate.get("transform", null)
	var source_owner_chunk_value: Variant = snapshot.get("chunk", null)
	var members_value: Variant = candidate.get("renderMembers", null)
	if source_id.is_empty() or prop_id.is_empty() or source_revision.is_empty() \
			or not body_transform is Transform3D or not _valid_transform(body_transform) \
			or not source_owner_chunk_value is Vector2i or not members_value is Array:
		return _pending("ecology_static_prop_support_source_identity_invalid", {
			"sourceId":source_id})
	var source_owner_chunk: Vector2i = source_owner_chunk_value
	var support_ranges_by_section: Dictionary = {}
	var members_seen: Dictionary = {}
	for index in range(members_value.size()):
		var member_value: Variant = members_value[index]
		if not member_value is Dictionary:
			return _pending("ecology_static_prop_support_member_invalid", {"sourceId":source_id})
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var binding_value: Variant = resource_bindings_value.get(source_id + "|" + member_id, null)
		if member_id.is_empty() or members_seen.has(member_id) \
				or not binding_value is Dictionary:
			return _pending("ecology_static_prop_support_member_binding_missing", {
				"sourceId":source_id, "memberId":member_id})
		members_seen[member_id] = true
		var mesh_value: Variant = binding_value.get("mesh", null)
		var member_transform: Variant = member.get("transform", null)
		if not mesh_value is Mesh or not member_transform is Transform3D \
				or not _valid_transform(member_transform):
			return _pending("ecology_static_prop_support_member_resource_invalid", {
				"sourceId":source_id, "memberId":member_id})
		var mesh_bounds: AABB = (mesh_value as Mesh).get_aabb()
		var declared_mesh_bounds: Variant = member.get("meshBounds", null)
		var declared_local_bounds: Variant = member.get("localBounds", null)
		if not _valid_bounds(mesh_bounds) or not declared_mesh_bounds is AABB \
				or not _valid_bounds(declared_mesh_bounds) \
				or not mesh_bounds.is_equal_approx(declared_mesh_bounds) \
				or not declared_local_bounds is AABB \
				or not (member_transform * declared_mesh_bounds).is_equal_approx(
					declared_local_bounds):
			return _pending("ecology_static_prop_support_mesh_bounds_invalid", {
				"sourceId":source_id, "memberId":member_id})
		var world_transform: Transform3D = chunk_to_world \
			* (body_transform as Transform3D) * (member_transform as Transform3D)
		var world_bounds: AABB = world_transform * mesh_bounds
		if not _valid_bounds(world_bounds):
			return _pending("ecology_static_prop_support_world_bounds_invalid", {
				"sourceId":source_id, "memberId":member_id})
		var owner_section := Grid.key_for_world_position(world_bounds.get_center())
		var source_segment_id := "ecology-static:%s:%s" % [member_id, source_revision]
		var dependencies: Array[Vector2i] = \
			_stream_chunk_keys_intersecting_bounds(world_bounds).duplicate()
		if source_owner_chunk not in dependencies:
			dependencies.append(source_owner_chunk)
			dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				if a.x != b.x: return a.x < b.x
				return a.y < b.y)
		dependencies.make_read_only()
		for support_section: Vector3i in Grid.keys_intersecting_bounds(world_bounds):
			var row := {"sourceId":source_id, "sourcePartId":member_id,
				"sourceRevision":source_revision, "memberId":member_id,
				"propId":prop_id,
				"sourceSegmentId":source_segment_id, "sourceInstance":index,
				"ownerCell":source_owner_chunk, "sourceOwnerChunk":source_owner_chunk,
				"geometryOwnerSection":owner_section,
				"supportSectionKey":support_section, "worldBounds":world_bounds,
				"streamChunkDependencies":dependencies,
				"ownershipPolicy":STATIC_PROP_SUPPORT_POLICY}
			row.make_read_only()
			if not support_ranges_by_section.has(support_section):
				support_ranges_by_section[support_section] = []
			support_ranges_by_section[support_section].append(row)
	for support_section_value: Variant in support_ranges_by_section:
		var support_rows: Array = support_ranges_by_section[support_section_value]
		support_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if String(a.get("memberId", "")) != String(b.get("memberId", "")):
				return String(a.get("memberId", "")) < String(b.get("memberId", ""))
			return int(a.get("sourceInstance", -1)) < int(b.get("sourceInstance", -1)))
		support_rows.make_read_only()
	support_ranges_by_section.make_read_only()
	return {"status":"ready", "sourceId":source_id,
		"sourceRevision":source_revision,
		"supportRangesBySection":support_ranges_by_section}


func _stream_chunk_keys_intersecting_bounds(bounds: AABB) -> Array[Vector2i]:
	if not _valid_bounds(bounds):
		return []
	var result: Array[Vector2i] = Partitioner._stream_chunks_intersecting_bounds(bounds)
	return result


## Validate resource availability and declared layer without inspecting resource
## contents. Fingerprints and stale-resource rejection remain contribution work.
func _static_prop_resources_are_renderable(resource_bindings: Variant,
		candidate: Dictionary) -> bool:
	if not resource_bindings is Dictionary:
		return false
	var source_id := String(candidate.get("sourceId", ""))
	for member_value: Variant in candidate.get("renderMembers", []):
		if not member_value is Dictionary:
			return false
		var member: Dictionary = member_value
		var member_id := String(member.get("memberId", ""))
		var binding_value: Variant = resource_bindings.get(source_id + "|" + member_id, null)
		if not binding_value is Dictionary or not binding_value.is_read_only():
			return false
		var mesh_value: Variant = binding_value.get("mesh", null)
		var material_value: Variant = binding_value.get("material", null)
		if not mesh_value is Mesh or not material_value is Material \
				or String(binding_value.get("materialKey", "")) \
					!= String(member.get("materialKey", "")) \
				or _supported_ecology_layer(material_value,
					String(member.get("renderLayer", ""))).is_empty():
			return false
	return true


func _detail_candidate_mesh_if_current(main: Object, candidate: Dictionary) -> Mesh:
	if not _detail_candidate_resource_is_current(main, candidate):
		return null
	var detail_type := String(candidate.get("detailType", ""))
	var surface_index := int(candidate.get("surfaceIndex", -1))
	var mesh: Variant = main.call("detail_mesh_surface", detail_type, surface_index) \
		if surface_index >= 0 else main.call("detail_mesh", detail_type)
	return mesh as Mesh if mesh is Mesh else null


static func _surface_detail_census_section_key(mesh: Mesh,
		source_to_world: Transform3D, local_transform: Transform3D) -> Vector3i:
	return Grid.key_for_world_position(
		source_to_world * local_transform * mesh.get_aabb().get_center())


func _detail_candidate_resource_is_current(main: Object, candidate: Dictionary) -> bool:
	var detail_type := String(candidate.get("detailType", ""))
	var material_keys: Variant = candidate.get("materials", null)
	var render_layers: Variant = candidate.get("renderLayers", null)
	var mesh_source := String(candidate.get("meshSource", ""))
	if detail_type.is_empty() or mesh_source.is_empty() \
			or not material_keys is Array or material_keys.size() != 1 \
			or not render_layers is Array or render_layers.size() != 1:
		return false
	var surface_index := int(candidate.get("surfaceIndex", -1))
	var mesh: Variant = null
	var material: Variant = null
	var material_key := String(material_keys[0])
	if surface_index >= 0:
		if not main.has_method("detail_mesh_surface") \
				or not main.has_method("detail_surface_material") \
				or not main.has_method("detail_surface_material_key"):
			return false
		mesh = main.call("detail_mesh_surface", detail_type, surface_index)
		material = main.call("detail_surface_material", detail_type, surface_index)
		if String(main.call("detail_surface_material_key", detail_type,
				surface_index)) != material_key:
			return false
	else:
		if not main.has_method("detail_mesh") or not main.has_method("detail_material"):
			return false
		mesh = main.call("detail_mesh", detail_type)
		material = main.call("detail_material", detail_type)
	if not mesh is Mesh or not material is Material:
		return false
	if _supported_surface_detail_layer(material, String(render_layers[0])).is_empty():
		return false
	if surface_index >= 0 and (mesh as Mesh).get_surface_count() <= 0:
		return false
	var bounds_value: Variant = candidate.get("localBounds", null)
	var transform_value: Variant = candidate.get("transform", null)
	var source_mesh_bounds: Variant = candidate.get("meshBounds", null)
	return bounds_value is AABB and transform_value is Transform3D \
		and source_mesh_bounds is AABB \
		and ((mesh as Mesh).get_aabb()).is_equal_approx(source_mesh_bounds) \
		and ((transform_value as Transform3D) * (source_mesh_bounds as AABB)).is_equal_approx(
			bounds_value)


func _production_chunk_owner_is_current(main: Object, chunk_key: Vector2i,
		production: Dictionary) -> bool:
	var chunks_value: Variant = main.get("chunks")
	var owner_reference := production.get("chunkOwner") as WeakRef
	var captured_owner: Variant = owner_reference.get_ref() if owner_reference != null else null
	if not chunks_value is Dictionary or not is_instance_valid(captured_owner) \
			or chunks_value.get(chunk_key, null) != captured_owner \
			or int(production.get("chunkOwnerInstanceId", 0)) != captured_owner.get_instance_id():
		return false
	var current_snapshot: Variant = captured_owner.get_meta("static_ecology_source_value_snapshot", {})
	var captured_snapshot: Variant = production.get("snapshot", {})
	if not current_snapshot is Dictionary or not captured_snapshot is Dictionary \
			or String(current_snapshot.get("contentRevision", "")) \
				!= String(captured_snapshot.get("contentRevision", "")) \
			or not RemovedProps.is_current_for_ids(main,
				production.get("removedSnapshot", {}),
				production.get("removedSnapshot", {}).get("checkedIds", [])):
		return false
	return true


func _legacy_visual_unit_owner_is_current(unit: Dictionary, main: Object) -> bool:
	var owner_ref := unit.get("chunkOwner") as WeakRef
	var chunk_owner: Node3D = owner_ref.get_ref() as Node3D if owner_ref != null else null
	var chunks_value: Variant = main.get("chunks") if is_instance_valid(main) else null
	var owner_key_value: Variant = unit.get("chunkOwnerKey", null)
	if not owner_key_value is Vector2i or int(unit.get("chunkOwnerInstanceId", 0)) <= 0:
		return false
	var owner_key := Vector2i(owner_key_value)
	return is_instance_valid(chunk_owner) and chunk_owner.is_inside_tree() \
		and chunk_owner.get_instance_id() == int(unit.get("chunkOwnerInstanceId", 0)) \
		and main is Node and (main as Node).is_ancestor_of(chunk_owner) \
		and chunks_value is Dictionary and chunks_value.get(owner_key) == chunk_owner


func _prepare_realized_static_props(snapshot: Dictionary, resource_bindings_value: Variant,
		chunk_to_world: Transform3D, world_id: String,
		underground_required := true, removed_prop_ids: Dictionary = {}) -> Dictionary:
	if not resource_bindings_value is Dictionary or not resource_bindings_value.is_read_only():
		return _pending("ecology_static_prop_resource_binding_map_unsealed", {
			"chunk":snapshot.get("chunk", Vector2i.ZERO)})
	var resource_bindings: Dictionary = resource_bindings_value
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var mesh_bindings: Dictionary = {}
	var material_bindings: Dictionary = {}
	var source_revisions: Dictionary = {}
	var support_ranges_by_section: Dictionary = {}
	for candidate_value: Variant in snapshot.get("candidates", []):
		if not candidate_value is Dictionary \
				or String(candidate_value.get("kind", "")) != "realized_static_prop":
			continue
		var candidate: Dictionary = candidate_value
		var source_id := String(candidate.get("sourceId", ""))
		var prop_id := String(candidate.get("propId", ""))
		if not prop_id.is_empty() and removed_prop_ids.has(prop_id):
			continue
		if String(candidate.get("category", "")) == "underground_props" \
				and not underground_required:
			continue
		if String(candidate.get("renderStatus", "")) != "ready":
			return _pending("ecology_static_prop_render_pending", {
				"sourceId":source_id,
				"reason":String(candidate.get("pendingReason", "unknown"))})
		var category := String(candidate.get("category", ""))
		var candidate_revision := String(candidate.get("contentRevision", ""))
		var body_transform_value: Variant = candidate.get("transform", null)
		var members_value: Variant = candidate.get("renderMembers", null)
		if source_id.is_empty() or candidate_revision.is_empty() \
				or not body_transform_value is Transform3D or not _valid_transform(body_transform_value) \
				or not members_value is Array or members_value.is_empty():
			return _pending("ecology_static_prop_candidate_incomplete", {"sourceId":source_id})
		var resolved_rows: Array[Dictionary] = []
		var source_revision := _static_prop_source_revision(world_id, snapshot, candidate)
		if source_revision.is_empty():
			return _failed("ecology_static_prop_source_revision_failed", {"sourceId":source_id})
		var source_owner_chunk := Vector2i(snapshot.get("chunk", Vector2i.ZERO))
		for member_index in range(members_value.size()):
			var member_value: Variant = members_value[member_index]
			if not member_value is Dictionary:
				return _pending("ecology_static_prop_member_invalid", {"sourceId":source_id})
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var binding_value: Variant = resource_bindings.get(source_id + "|" + member_id, null)
			if member_id.is_empty() or not binding_value is Dictionary:
				return _pending("ecology_static_prop_member_resource_missing", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_value: Variant = binding_value.get("mesh", null)
			var material_value: Variant = binding_value.get("material", null)
			if not mesh_value is Mesh or not material_value is Material:
				return _pending("ecology_static_prop_resource_type_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh_value)
			var mesh_digest := String(mesh_fingerprint.get("contentDigest", ""))
			var expected_mesh_digest := String(member.get("meshContentDigest", ""))
			var material_digest := _material_digest(material_value)
			if mesh_fingerprint.get("status") != "ready" \
					or mesh_digest != expected_mesh_digest \
					or material_digest.is_empty() \
					or material_digest != String(member.get("materialContentDigest", "")) \
					or mesh_digest != String(binding_value.get("meshContentDigest", "")) \
					or material_digest != String(binding_value.get("materialContentDigest", "")):
				return _pending("ecology_static_prop_resource_fingerprint_stale", {
					"sourceId":source_id, "memberId":member_id})
			var render_layer := _supported_ecology_layer(material_value,
				String(member.get("renderLayer", "")))
			if render_layer.is_empty():
				return _pending("ecology_static_prop_material_layer_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var local_member_transform: Variant = member.get("transform", null)
			var member_bounds_value: Variant = member.get("localBounds", null)
			var declared_mesh_bounds: Variant = member.get("meshBounds", null)
			var mesh_bounds: AABB = mesh_value.get_aabb()
			if not local_member_transform is Transform3D \
					or not _valid_transform(local_member_transform) \
					or not member_bounds_value is AABB \
					or not declared_mesh_bounds is AABB \
					or not _valid_bounds(declared_mesh_bounds) \
					or not _valid_bounds(mesh_bounds) \
					or not mesh_bounds.is_equal_approx(declared_mesh_bounds) \
					or not ((local_member_transform as Transform3D) \
						* (declared_mesh_bounds as AABB)).is_equal_approx(member_bounds_value):
				return _pending("ecology_static_prop_member_bounds_or_transform_invalid", {
					"sourceId":source_id, "memberId":member_id})
			var material_key := String(member.get("materialKey", ""))
			if material_key != String(binding_value.get("materialKey", "")):
				return _pending("ecology_static_prop_material_binding_identity_stale", {
					"sourceId":source_id, "memberId":member_id})
			var mesh_resource_key := "ecology.runtime.%s/v1" % mesh_digest
			var compatibility := _compatibility(material_key, material_key, material_digest,
				mesh_resource_key, mesh_digest, PIPELINE_REVISION, render_layer,
				mesh_bounds, true, 0.0, 0.0)
			if compatibility.is_empty():
				return _pending("ecology_static_prop_compatibility_unsupported", {
					"sourceId":source_id, "memberId":member_id})
			var compatibility_key := String(compatibility.batchKey)
			if compatibility_by_key.has(compatibility_key) \
					and compatibility_by_key[compatibility_key] != compatibility:
				return _failed("ecology_static_prop_batch_compatibility_conflict")
			compatibility_by_key[compatibility_key] = compatibility
			mesh_bindings[mesh_resource_key] = mesh_value
			material_bindings[String(compatibility.materialKey)] = material_value
			var member_world_transform: Transform3D = chunk_to_world \
				* (body_transform_value as Transform3D) * (local_member_transform as Transform3D)
			var member_world_bounds: AABB = member_world_transform * mesh_bounds
			var geometry_owner_section := Grid.key_for_world_position(member_world_bounds.get_center())
			var source_segment_id := "ecology-static:%s:%s" % [member_id, source_revision]
			var stream_dependencies := _stream_chunk_keys_intersecting_bounds(member_world_bounds)
			if source_owner_chunk not in stream_dependencies:
				stream_dependencies.append(source_owner_chunk)
				stream_dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
					if a.x != b.x: return a.x < b.x
					return a.y < b.y)
			stream_dependencies.make_read_only()
			for support_section: Vector3i in Grid.keys_intersecting_bounds(member_world_bounds):
				var support_row := {"sourceId":source_id, "sourcePartId":member_id,
					"sourceRevision":source_revision, "memberId":member_id,
					"propId":prop_id,
					"sourceSegmentId":source_segment_id, "sourceInstance":member_index,
					"ownerCell":source_owner_chunk, "sourceOwnerChunk":source_owner_chunk,
					"geometryOwnerSection":geometry_owner_section,
					"supportSectionKey":support_section, "worldBounds":member_world_bounds,
					"streamChunkDependencies":stream_dependencies,
					"ownershipPolicy":STATIC_PROP_SUPPORT_POLICY}
				support_row.make_read_only()
				if not support_ranges_by_section.has(support_section):
					support_ranges_by_section[support_section] = {}
				var section_supports: Dictionary = support_ranges_by_section[support_section]
				var source_supports: Array = section_supports.get(source_id, [])
				source_supports.append(support_row)
				section_supports[source_id] = source_supports
			resolved_rows.append({"memberId":member_id, "meshDigest":mesh_digest,
				"materialDigest":material_digest, "renderLayer":render_layer,
				"transform":local_member_transform, "meshBounds":mesh_bounds,
				"compatibility":compatibility, "meshResourceKey":mesh_resource_key,
				"materialKey":String(compatibility.materialKey),
				"sourceSection":geometry_owner_section})
		var producer_revision := String(snapshot.get("sourceRevision", ""))
		if source_revisions.has(source_id) and String(source_revisions[source_id]) != source_revision:
			return _failed("ecology_static_prop_source_revision_conflict", {"sourceId":source_id})
		source_revisions[source_id] = source_revision
		for row: Dictionary in resolved_rows:
			var local_transform: Transform3D = body_transform_value * row.transform
			var buffer: Array[float] = _encode_instance(local_transform, Color.TRANSPARENT, Color.WHITE)
			buffer.make_read_only()
			var input := {"instanceAttributeLayout":InstanceAttributes.LAYOUT_SCHEMA,
				"sourceId":source_id, "sourcePartId":row.memberId,
				"sourceRevision":source_revision,
				"ownerCell":Vector2i(snapshot.get("chunk", Vector2i.ZERO)),
				"sourceToWorld":chunk_to_world,
				"meshLocalBounds":row.meshBounds,
				"batchKey":String(row.compatibility.batchKey),
				"segmentId":"ecology-static:%s:%s" % [row.memberId, source_revision],
				"buffer":buffer, "instanceCount":1,
				"sectionKey":Vector3i(row.sourceSection)}
			input.make_read_only()
			inputs.append(input)
	inputs.make_read_only()
	for support_section_value: Variant in support_ranges_by_section:
		var source_map: Dictionary = support_ranges_by_section[support_section_value]
		for support_source_id: String in source_map:
			var support_rows: Array = source_map[support_source_id]
			support_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if String(a.get("memberId", "")) != String(b.get("memberId", "")):
					return String(a.get("memberId", "")) < String(b.get("memberId", ""))
				return String(a.get("sourceSegmentId", "")) < String(b.get("sourceSegmentId", "")))
			support_rows.make_read_only()
			source_map[support_source_id] = support_rows
		source_map.make_read_only()
	support_ranges_by_section.make_read_only()
	compatibility_by_key.make_read_only()
	mesh_bindings.make_read_only()
	material_bindings.make_read_only()
	source_revisions.make_read_only()
	return {"status":"ready", "inputs":inputs,
		"compatibilityByKey":compatibility_by_key, "meshBindings":mesh_bindings,
		"materialBindings":material_bindings, "sourceRevisions":source_revisions,
		"supportRangesBySection":support_ranges_by_section,
		"candidateIds":source_revisions.keys()}


static func _supported_ecology_layer(material: Material, declared_layer: String) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader != null and not shader.code.is_empty() \
				and not shader.code.contains("ALPHA") \
				and not shader.code.contains("discard") \
				and not shader.code.contains("blend_") \
				and declared_layer == "opaque":
			return "opaque"
		return ""
	if not material is BaseMaterial3D:
		return ""
	var base := material as BaseMaterial3D
	if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
			and base.albedo_color.a >= 0.999 and declared_layer == "opaque":
		return "opaque"
	if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
			and declared_layer == "cutout":
		return "cutout"
	return ""


static func _supported_surface_detail_layer(material: Material,
		declared_layer: String) -> String:
	if material is ShaderMaterial:
		var shader := (material as ShaderMaterial).shader
		if shader == null or shader.resource_path != \
				"res://resources/visual/detail_material.gdshader" \
				or shader.code.is_empty() or shader.code.contains("ALPHA") \
				or shader.code.contains("discard") or shader.code.contains("blend_"):
			return ""
		return "opaque" if declared_layer == "opaque" else ""
	if material is BaseMaterial3D:
		var base := material as BaseMaterial3D
		if base.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
				and base.albedo_color.a >= 0.999 and declared_layer == "opaque":
			return "opaque"
		if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
				and declared_layer == "alpha_scissor":
			return "cutout"
	return ""


static func _append_section_member(members_by_section: Dictionary, source_revisions: Dictionary,
		section_key: Vector3i, source_id: String, source_revision: String) -> bool:
	if source_id.is_empty() or source_revision.is_empty():
		return false
	if source_revisions.has(source_id) and String(source_revisions[source_id]) != source_revision:
		return false
	source_revisions[source_id] = source_revision
	if not members_by_section.has(section_key):
		members_by_section[section_key] = []
	var ids: Array = members_by_section[section_key]
	if source_id not in ids:
		ids.append(source_id)
	return true


static func _tree_family_proof_valid(snapshot: Dictionary) -> bool:
	var proof_value: Variant = snapshot.get("treeFamilyProof", null)
	if not proof_value is Dictionary or not bool(proof_value.get("producerComplete", false)):
		return false
	if String(proof_value.get("sourceRevision", "")) != String(snapshot.get("sourceRevision", "")) \
			or proof_value.get("chunk", null) != snapshot.get("chunk", null):
		return false
	var expected: Array[String] = []
	for candidate_value: Variant in snapshot.get("candidates", []):
		if candidate_value is Dictionary and String(candidate_value.get("kind", "")) == "trees_foliage":
			expected.append(String(candidate_value.get("sourceId", "")))
	expected.sort()
	var declared: Array[String] = []
	for source_id_value: Variant in proof_value.get("sourceIds", []):
		declared.append(String(source_id_value))
	declared.sort()
	if expected != declared:
		return false
	var payload: Dictionary = proof_value.duplicate(true)
	var recorded_digest := String(payload.get("contentRevision", ""))
	payload.erase("contentRevision")
	return not recorded_digest.is_empty() and recorded_digest == _value_digest(payload)


static func source_revisions_for_ids(source_ids: Array, all_revisions: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for source_id_value: Variant in source_ids:
		var source_id := String(source_id_value)
		if all_revisions.has(source_id):
			result[source_id] = all_revisions[source_id]
	return result


static func _material_digest(material: Material) -> String:
	var fingerprint: Dictionary = MaterialFingerprint.inspect(material)
	return String(fingerprint.get("contentDigest", "")) \
		if String(fingerprint.get("status", "")) == "ready" else ""


static func _candidate_digest(candidate: Dictionary) -> String:
	var value := candidate.duplicate(true)
	value.erase("contentRevision")
	return _value_digest(value)


static func _value_digest(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(JSON.stringify(_canonical(value)).to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var entries: Array = []
		for key: Variant in keys:
			entries.append([_canonical(key), _canonical(value[key])])
		return entries
	if value is Array:
		var entries: Array = []
		for item: Variant in value:
			entries.append(_canonical(item))
		return entries
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Color:
		return [value.r, value.g, value.b, value.a]
	if value is Transform3D:
		return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
			value.basis.y.x, value.basis.y.y, value.basis.y.z,
			value.basis.z.x, value.basis.z.y, value.basis.z.z,
			value.origin.x, value.origin.y, value.origin.z]
	if value is AABB:
		return [_canonical(value.position), _canonical(value.size)]
	return value


static func _valid_transform(transform: Transform3D) -> bool:
	return transform.origin.is_finite() and transform.basis.x.is_finite() \
		and transform.basis.y.is_finite() and transform.basis.z.is_finite() \
		and absf(transform.basis.determinant()) > 0.000001


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _tree_candidate_bounds_intersect_sections(world_bounds: AABB,
		requested_sections: Array[Vector3i]) -> bool:
	if not _valid_bounds(world_bounds):
		return false
	for section_key: Vector3i in requested_sections:
		var section_bounds := AABB(Grid.origin_for_key(section_key),
			Vector3.ONE * Grid.SECTION_SIZE_METERS)
		if world_bounds.intersects(section_bounds):
			return true
	return false


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


func _bounded_preparation_pending_details(result: Dictionary,
		family: String, source_chunk: Vector2i) -> Dictionary:
	var bounded: Dictionary = {"sourceChunkKey":source_chunk}
	var pending_sources: Array[Dictionary] = [result]
	for nested_key: String in ["details", "dependencyDetails", "registration", "result"]:
		var nested_value: Variant = result.get(nested_key, null)
		if nested_value is Dictionary:
			pending_sources.append(nested_value)
	for pending_source: Dictionary in pending_sources:
		for key: String in ["status", "reason", "dependency", "sourceId",
				"sourcePartId", "family", "disposition", "terminalFailure", "retryable"]:
			if bounded.has(key) or not pending_source.has(key):
				continue
			var value: Variant = pending_source.get(key)
			if value is String or value is bool or value is int or value is float:
				bounded[key] = value
	if family.is_empty():
		family = String(bounded.get("family", ""))
	if not family.is_empty():
		bounded["family"] = family
	return bounded


static func _failed(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"failed", "reason":reason, "retryable":false}
	result.merge(detail, true)
	return result
